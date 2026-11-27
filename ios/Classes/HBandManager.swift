import CoreBluetooth
import Foundation
import UIKit
import JL_BLEKit
import UserNotifications
import VeepooBleSDK

/// Receives everything the manager produces (always on the main thread).
protocol HBandManagerListener: AnyObject {
    func onScanResult(_ device: [String: Any])
    func onScanFinished()
    func onConnectionChanged(_ state: [String: Any])
    func onEvent(_ event: [String: Any])
}

/// Native core of the plugin on iOS — same behaviour and channel contract as
/// the Android HBandManager:
///
/// - Scan / connect / password check / disconnect / forget.
/// - Saved session + auto-restore (SDK automaticConnection while the app
///   lives, plus a scan-and-reconnect watchdog after relaunch).
/// - SOS / fall detection channels:
///   1. Raw frame signature 8F 08 03 (HBFrameSniffer) — SOS press or fall on
///      the tested VIGOR firmware.
///   2. `receiveDeviceSOSCommand` — SDK SOS push (other firmwares).
///   3. `veepooSDK_listenReminderEventReport` — fall push when supported.
///   4. CallSosDetector — an outgoing call through the watch's call Bluetooth
///      (watches that only dial their SOS contact, e.g. VANTA).
final class HBandManager {

    static let shared = HBandManager()

    // MARK: Event types / states (shared with Android + Dart)

    static let eventEmergencyAlarm = "EMERGENCY_ALARM"
    static let eventSosPressed = "SOS_PRESSED"
    static let eventFallDetected = "FALL_DETECTED"
    static let eventSedentary = "SEDENTARY_REMIND"
    static let eventStatus = "STATUS"

    static let stateDisconnected = "disconnected"
    static let stateConnecting = "connecting"
    static let stateVerifying = "verifying"
    static let stateReady = "ready"
    static let statePasswordFailed = "passwordFailed"
    static let stateFailed = "failed"

    static let defaultPassword = "0000"
    private static let emergencyDedupe: TimeInterval = 10
    private static let watchdogInterval: TimeInterval = 15
    private static let connectTimeout: TimeInterval = 45
    /// A silent reconnect that has not reached "ready" by then is dropped and retried.
    private static let restoreTimeout: TimeInterval = 25
    /// A watch paired before connects in a few seconds; past this the attempt
    /// has stalled (JieLi auth fails once, then the SDK never continues) →
    /// drop the link and connect again, like tapping connect a second time.
    private static let knownWatchAttemptTimeout: TimeInterval = 15
    private static let knownWatchRetries = 2
    private static let maxEvents = 100
    private static let persistedEventsKey = "releep_hband_guard_events.emergencies"

    weak var listener: HBandManagerListener?

    var ble: VPBleCentralManage { VPBleCentralManage.sharedBleManager() }
    private var sdkReady = false

    // scan
    private var scanning = false
    private var internalScan = false // restore scan — not forwarded to Flutter
    private var scanTimer: Timer?
    private var scannedModels: [String: VPPeripheralModel] = [:]

    // connection
    private(set) var state = HBandManager.stateDisconnected
    private var stateMessage: String?
    private var currentScanId: String?
    private var currentName: String?
    private var pendingPassword = HBandManager.defaultPassword
    private var triedCustomPassword = false
    private var customPasswordInFlight = false
    private var pendingConnect: (([String: Any?]) -> Void)?
    private var connectTimer: Timer?
    private var restoreTimer: Timer?
    private var connectRetriesLeft = 0
    /// Set while a stalled attempt is dropped, so its failure callbacks do
    /// not end the connect that is about to be retried.
    private var retryingConnect = false
    private var restoreInProgress = false

    // guard
    private(set) var monitoring = false
    private var watchdog: Timer?
    private var lastEmergencyAt: Date = .distantPast
    private var events: [GuardEvent] = []

    private init() {}

    // MARK: - Init

    func initialize() {
        guard !sdkReady else { return }
        sdkReady = true
        loadPersistedEvents()
        let ble = self.ble
        ble.isLogEnable = false
        ble.automaticConnection = true
        // Required since SDK 2.0: command + data handling after password check.
        ble.peripheralManage = VPPeripheralManage.shareVPPeripheralManager()
        PhoneFeatures.shared.attach()

        ble.vpBleConnectStateChangeBlock = { [weak self] connectState in
            DispatchQueue.main.async { self?.onGlobalConnectState(connectState.rawValue) }
        }
        // A watch SOS call may have started while the app was suspended.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { _ in
            CallSosDetector.shared.checkOngoingCalls()
        }
    }

    var isBluetoothEnabled: Bool {
        initialize()
        return ble.centralManager?.state == .poweredOn
    }

    var bluetoothAuthorized: Bool {
        if #available(iOS 13.1, *) {
            return CBCentralManager.authorization == .allowedAlways
        }
        return true
    }

    var bluetoothAuthorizationDetermined: Bool {
        if #available(iOS 13.1, *) {
            return CBCentralManager.authorization != .notDetermined
        }
        return true
    }

    // MARK: - Scan

    func startScan(timeout: TimeInterval, silent: Bool = false, watchId: String? = nil, watchName: String? = nil) {
        initialize()
        if scanning { stopScan() }
        scanning = true
        internalScan = silent
        if !silent { scannedModels.removeAll() }
        var seen = Set<String>()
        let report: (VPPeripheralModel, String) -> Void = { [weak self] model, id in
            guard let self = self, self.scanning, !id.isEmpty, seen.insert(id).inserted else { return }
            self.scannedModels[id] = model
            if self.internalScan {
                self.onRestoreScanResult(model, id: id)
            } else {
                let name = model.deviceName?.isEmpty == false ? model.deviceName : model.peripheral?.name
                self.listener?.onScanResult([
                    "deviceId": id,
                    "name": (name?.isEmpty == false ? name! : "Unknown"),
                    "rssi": model.rssi?.intValue ?? -100,
                ])
            }
        }
        ble.veepooSDKStartScanDeviceAndReceiveScanningDevice { model in
            guard let model = model else { return }
            DispatchQueue.main.async { report(model, model.deviceAddress ?? "") }
        }
        // A watch whose link iOS already holds (e.g. connected for calls) stops
        // advertising, so the scan above never sees it — offer it from the system.
        if let (model, id) = systemLinkedWatch(watchId: watchId, watchName: watchName) {
            report(model, id)
        } else if !silent && watchId == nil {
            // Manual scan for a new watch: list every Veepoo watch iOS holds. No
            // MAC without advertising → reported by its CoreBluetooth id.
            let linked = linkedWatchPeripherals()
            NSLog("HBand linked by iOS (manual scan): %@",
                  linked.map { "\($0.name ?? "?") \($0.identifier.uuidString)" }.description)
            for peripheral in linked {
                guard let model = VPPeripheralModel(peripher: peripheral) else { continue }
                let mac = model.deviceAddress ?? ""
                report(model, mac.isEmpty ? peripheral.identifier.uuidString : mac)
            }
        }
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: min(max(timeout, 3), 120), repeats: false) { [weak self] _ in
            self?.stopScan()
        }
    }

    func stopScan() {
        scanTimer?.invalidate()
        scanTimer = nil
        guard scanning else { return }
        ble.veepooSDKStopScanDevice()
        scanning = false
        if internalScan {
            internalScan = false
            if restoreInProgress && pendingConnect == nil && state != HBandManager.stateReady {
                restoreFailed()
            }
        } else {
            listener?.onScanFinished()
        }
    }

    // MARK: - Connect

    func connect(deviceId: String, name: String?, password: String, is24Hour: Bool,
                 completion: @escaping ([String: Any?]) -> Void) {
        initialize()
        guard pendingConnect == nil else {
            completion(result(false, "Another connection is in progress"))
            return
        }
        guard let model = scannedModels[deviceId] else {
            completion(result(false, "Device not found — scan again before connecting"))
            return
        }
        stopScan()
        // A manual connect replaces a silent reconnect still in progress.
        restoreTimer?.invalidate()
        restoreTimer = nil
        restoreInProgress = false
        pendingConnect = completion
        let id = deviceId.uppercased()
        let knownWatch = HBandSession.isConfigured && (id == HBandSession.scanId?.uppercased()
            || id == HBandSession.deviceId?.uppercased()
            || id == HBandSession.peripheralId?.uppercased()
            || model.peripheral?.identifier.uuidString == HBandSession.peripheralId)
        // A new watch may wait for the user to confirm on the watch: one long attempt.
        connectRetriesLeft = knownWatch ? HBandManager.knownWatchRetries : 0
        retryingConnect = false
        // Manual pairing → let the watch show its confirmation prompt.
        ble.deviceShowConfirm = true
        let begin = { [weak self] in
            guard let self = self else { return }
            self.armConnectTimer(knownWatch ? HBandManager.knownWatchAttemptTimeout : HBandManager.connectTimeout) {
                self.retryStalledConnect(model: model, scanId: deviceId, name: name, password: password, is24Hour: is24Hour)
            }
            self.startConnect(model: model, scanId: deviceId, name: name ?? model.deviceName, password: password, is24Hour: is24Hour)
        }
        begin()
        retryConnect = begin
    }

    private var retryConnect: (() -> Void)?

    private func armConnectTimer(_ seconds: TimeInterval, onStall: @escaping () -> Void) {
        connectTimer?.invalidate()
        connectTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self = self, self.pendingConnect != nil else { return }
            onStall()
        }
    }

    private func retryStalledConnect(model: VPPeripheralModel, scanId: String, name: String?, password: String, is24Hour: Bool) {
        guard pendingConnect != nil else { return }
        guard connectRetriesLeft > 0, let again = retryConnect else {
            setState(HBandManager.stateFailed, "Connection timed out")
            finishConnect(false, "Connection timed out")
            return
        }
        connectRetriesLeft -= 1
        NSLog("HBand connect stalled — dropping the link and retrying (%d left)", connectRetriesLeft)
        recordStatus("Connect stalled — retrying")
        retryingConnect = true
        ble.veepooSDKDisconnectDevice()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.pendingConnect != nil else { return }
            self.retryingConnect = false
            again()
        }
    }

    private func startConnect(model: VPPeripheralModel, scanId: String, name: String?, password: String, is24Hour: Bool) {
        if ble.isConnected, currentScanId != nil, currentScanId != scanId {
            ble.veepooSDKDisconnectDevice()
        }
        currentScanId = scanId
        currentName = name
        pendingPassword = password
        triedCustomPassword = false
        ble.is24HourFormat = is24Hour
        setState(HBandManager.stateConnecting, nil)
        ble.veepooSDKConnectDevice(model) { [weak self] connectState in
            DispatchQueue.main.async { self?.onConnectBlock(connectState.rawValue) }
        }
    }

    /// DeviceConnectState of the connect call.
    private func onConnectBlock(_ raw: Int) {
        if retryingConnect { return }
        switch raw {
        case 0: // BlePoweredOff
            fail("Bluetooth is turned off")
        case 1: // BleConnecting
            setState(HBandManager.stateConnecting, nil)
        case 2: // BleConnectSuccess — SDK now sends the default password itself
            setState(HBandManager.stateVerifying, nil)
        case 3: // BleConnectFailed
            fail("Connect failed")
        case 4: // BleVerifyPasswordSuccess
            onSessionReady()
        case 5: // BleVerifyPasswordFailure
            verifyCustomPasswordOrFail()
        case 6: // BleConnectTimeout
            fail("Connection timed out")
        case 7: // BleConfirmTimeout
            fail("Not confirmed on the watch in time")
        default:
            break
        }
    }

    /// VPDeviceConnectState — fires for every link change, also SDK auto-reconnects.
    private func onGlobalConnectState(_ raw: Int) {
        switch raw {
        case 0: // DisConnect
            // A sync waiting on a dead link would stay BUSY until every step
            // timed out — end it now.
            activeSync?.abort("watch disconnected")
            if state == HBandManager.stateReady {
                setState(HBandManager.stateDisconnected, "Watch disconnected")
                recordStatus("Watch disconnected — auto-reconnecting")
            }
        case 3: // VerifyPasswordSuccess (also after SDK auto-reconnect)
            if state != HBandManager.stateReady { onSessionReady() }
        case 4: // VerifyPasswordFailure
            if pendingConnect == nil { verifyCustomPasswordOrFail() }
        default:
            break
        }
    }

    /// The SDK always tries "0000" first; retry once with the user's password.
    private func verifyCustomPasswordOrFail() {
        // Both the connect block and the global state block report failures.
        if customPasswordInFlight { return }
        let password = pendingConnect != nil ? pendingPassword : HBandSession.password
        guard password != HBandManager.defaultPassword, !triedCustomPassword else {
            ble.veepooSDKDisconnectDevice()
            setState(HBandManager.statePasswordFailed, "Wrong watch password")
            if pendingConnect != nil { finishConnect(false, "Wrong watch password") } else { restoreFailed() }
            return
        }
        triedCustomPassword = true
        customPasswordInFlight = true
        pendingPassword = password
        setState(HBandManager.stateVerifying, nil)
        let verify = SynchronousPasswordType(rawValue: 0)! // VerifyPasswordType
        ble.veepooSDKSynchronousPassword(with: verify, password: password) { [weak self] outcome in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.customPasswordInFlight = false
                // 1 = PasswordValidationSuccess, 6 = PasswordValidationAllSuccess
                if outcome.rawValue == 1 || outcome.rawValue == 6 {
                    self.onSessionReady()
                } else {
                    self.verifyCustomPasswordOrFail()
                }
            }
        }
    }

    private func onSessionReady() {
        // Connect block + global state block can both report success.
        if state == HBandManager.stateReady && pendingConnect == nil { return }
        restoreTimer?.invalidate()
        restoreTimer = nil
        restoreInProgress = false
        let model = ble.peripheralModel
        // A watch connected through the link iOS holds was reported by its
        // CoreBluetooth id — keep its real MAC instead, like Android.
        let mac = connectedMac()
        let scanId = mac ?? currentScanId ?? HBandSession.scanId ?? model?.deviceAddress ?? ""
        NSLog("HBand session id %@ (MAC %@, sdk address %@, peripheral %@)", scanId, mac ?? "unknown",
              model?.deviceAddress ?? "nil", model?.peripheral?.identifier.uuidString ?? "nil")
        currentScanId = scanId
        HBandSession.save(
            scanId: scanId,
            deviceId: mac ?? model?.deviceAddress ?? scanId,
            name: currentName ?? model?.deviceName ?? "",
            password: pendingPassword,
            deviceNumber: Int(model?.deviceNumber ?? 0),
            firmware: model?.deviceVersion,
            firmwareTest: model?.deviceTestVersion,
            peripheralId: model?.peripheral?.identifier.uuidString
        )
        // Further reconnects are silent.
        ble.deviceShowConfirm = false
        setState(HBandManager.stateReady, nil)
        recordStatus("Watch session ready (\(HBandSession.name))")
        finishConnect(true, nil)
        PhoneFeatures.shared.onSessionReady()
        if HBandSession.guardEnabled { startMonitoring() }
    }

    private func fail(_ message: String) {
        setState(HBandManager.stateFailed, message)
        if pendingConnect != nil { finishConnect(false, message) } else { restoreFailed() }
    }

    private func finishConnect(_ success: Bool, _ message: String?) {
        connectTimer?.invalidate()
        connectTimer = nil
        retryConnect = nil
        retryingConnect = false
        guard let cb = pendingConnect else { return }
        pendingConnect = nil
        cb(result(success, message))
    }

    private func result(_ success: Bool, _ message: String?) -> [String: Any?] {
        ["success": success, "state": state, "message": message]
    }

    /// Drops the link but keeps the saved session (no auto-reconnect).
    func disconnect() {
        initialize()
        cancelHealthWork()
        stopGuard()
        ble.veepooSDKDisconnectDevice()
        setState(HBandManager.stateDisconnected, nil)
    }

    /// Disconnects, clears the saved session and stops all background work.
    func forgetWatch() {
        initialize()
        cancelHealthWork()
        stopMonitoring()
        stopScan()
        ble.veepooSDKDisconnectDevice()
        pendingConnect = nil
        restoreTimer?.invalidate()
        restoreTimer = nil
        restoreInProgress = false
        currentScanId = nil
        currentName = nil
        clearEvents()
        PhoneFeatures.shared.reset()
        HBandSession.forget()
        setState(HBandManager.stateDisconnected, nil)
        recordStatus("Watch forgotten — scan and connect a new watch")
    }

    // MARK: - Guard

    @discardableResult
    func startGuard() -> Bool {
        initialize()
        guard HBandSession.isConfigured else { return false }
        HBandSession.guardEnabled = true
        startMonitoring()
        return true
    }

    func stopGuard() {
        HBandSession.guardEnabled = false
        stopMonitoring()
    }

    private func startMonitoring() {
        guard HBandSession.isConfigured else { return }
        let firstStart = !monitoring
        monitoring = true

        _ = HBFrameSniffer.install { [weak self] frame in
            DispatchQueue.main.async { self?.onFrame(frame) }
        }
        let peripheral = ble.peripheralManage
        peripheral?.receiveDeviceSOSCommand = { [weak self] in
            DispatchQueue.main.async { self?.onSdkSos() }
        }
        let remindSupported = peripheral?.peripheralModel?.isSupportReminderEvent ?? false
        if remindSupported {
            peripheral?.veepooSDK_listenReminderEventReport { [weak self] list in
                DispatchQueue.main.async { list?.forEach { self?.onReminder($0) } }
            }
        }
        CallSosDetector.shared.onSos = { [weak self] in self?.onCallSos() }
        CallSosDetector.shared.start()
        if firstStart {
            recordStatus("Monitoring started" +
                (remindSupported ? " (fall push supported)" : " (fall push not supported by firmware)"))
        }
        if watchdog == nil {
            watchdog = Timer.scheduledTimer(withTimeInterval: HBandManager.watchdogInterval, repeats: true) { [weak self] _ in
                self?.watchdogTick()
            }
        }
        if state != HBandManager.stateReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.autoRestore() }
        }
    }

    private func stopMonitoring() {
        watchdog?.invalidate()
        watchdog = nil
        guard monitoring else { return }
        monitoring = false
        ble.peripheralManage?.receiveDeviceSOSCommand = nil
        CallSosDetector.shared.stop()
        recordStatus("Monitoring stopped")
    }

    /// Applies the call-SOS setting while the guard runs.
    func syncCallSosDetector() {
        if !HBandSession.callSosDetection {
            CallSosDetector.shared.stop()
        } else if monitoring {
            CallSosDetector.shared.start()
        }
    }

    private func watchdogTick() {
        guard monitoring, state != HBandManager.stateReady, pendingConnect == nil, !restoreInProgress, !isBusy else { return }
        autoRestore()
    }

    /// After a relaunch the SDK has no peripheral yet: scan for the saved watch
    /// and reconnect silently. While the app lives the SDK reconnects itself.
    private func autoRestore() {
        guard monitoring, HBandSession.isConfigured, !restoreInProgress, pendingConnect == nil else { return }
        if ble.isConnected && state == HBandManager.stateReady { return }
        guard isBluetoothEnabled else { return }
        restoreInProgress = true
        recordStatus("Auto-restoring watch session…")
        startScan(timeout: 12, silent: true)
    }

    private func onRestoreScanResult(_ model: VPPeripheralModel, id: String) {
        guard id == HBandSession.scanId || id == HBandSession.deviceId else { return }
        stopScanSilently()
        ble.deviceShowConfirm = false
        startConnect(model: model, scanId: id, name: HBandSession.name,
                     password: HBandSession.password, is24Hour: true)
        // The first link after install can stall (JieLi pairing fails once and
        // the SDK never reports success). Without this the restore stays "in
        // progress" forever and the watchdog never retries.
        restoreTimer?.invalidate()
        restoreTimer = Timer.scheduledTimer(withTimeInterval: HBandManager.restoreTimeout, repeats: false) { [weak self] _ in
            guard let self = self, self.restoreInProgress, self.pendingConnect == nil,
                  self.state != HBandManager.stateReady else { return }
            NSLog("HBand auto-restore stalled — dropping the link and retrying")
            self.recordStatus("Reconnect stalled — retrying")
            self.ble.veepooSDKDisconnectDevice()
            self.restoreFailed()
        }
    }

    /// Veepoo services, to find the watch among the peripherals iOS holds.
    private static let watchServices = [
        "F0080001-0451-4000-B000-000000000000",
        "F0020001-0451-4000-B000-000000000000",
        "FEE7",
    ].map { CBUUID(string: $0) }

    /// The watch looked for, when iOS already holds its link, with the id to
    /// report it as. The saved session identifies it (peripheral id saved at the
    /// last connect, else its name); without one, [watchId] / [watchName] from
    /// Flutter do.
    private func linkedWatchPeripherals() -> [CBPeripheral] {
        guard let central = ble.centralManager, central.state == .poweredOn else { return [] }
        return central.retrieveConnectedPeripherals(withServices: HBandManager.watchServices)
    }

    private func systemLinkedWatch(watchId: String?, watchName: String?) -> (VPPeripheralModel, String)? {
        let isSessionWatch = HBandSession.isConfigured && (watchId == nil
            || watchId?.uppercased() == HBandSession.scanId?.uppercased()
            || watchId?.uppercased() == HBandSession.deviceId?.uppercased())
        let id = isSessionWatch ? HBandSession.scanId : watchId
        let peripheralId = isSessionWatch ? HBandSession.peripheralId : nil
        let name = isSessionWatch && !HBandSession.name.isEmpty ? HBandSession.name : watchName
        guard let id = id, !id.isEmpty else { return nil }

        let linked = linkedWatchPeripherals()
        NSLog("HBand linked by iOS: %@ (looking for %@ name=%@ peripheralId=%@)",
              linked.map { "\($0.name ?? "?") \($0.identifier.uuidString)" }.description,
              id, name ?? "nil", peripheralId ?? "nil")
        let found: CBPeripheral?
        if let peripheralId = peripheralId {
            found = linked.first { $0.identifier.uuidString == peripheralId }
        } else {
            let named = linked.filter { name != nil && !name!.isEmpty && $0.name == name }
            found = named.count == 1 ? named[0] : nil
        }
        guard let found = found, let model = VPPeripheralModel(peripher: found) else { return nil }
        recordStatus("Watch linked by iOS — connecting without scan")
        return (model, id)
    }

    private func stopScanSilently() {
        scanTimer?.invalidate()
        scanTimer = nil
        ble.veepooSDKStopScanDevice()
        scanning = false
        internalScan = false
    }

    private func restoreFailed() {
        restoreTimer?.invalidate()
        restoreTimer = nil
        restoreInProgress = false
        if state != HBandManager.statePasswordFailed {
            setState(HBandManager.stateDisconnected, "Watch not reachable — retrying")
        }
    }

    // MARK: - SOS / fall detection

    private func onFrame(_ frame: Data) {
        let bytes = [UInt8](frame)
        guard bytes.count >= 3, bytes[0] == 0x8F, bytes[1] == 0x08, bytes[2] == 0x03 else { return }
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: ",")
        emitEmergency(HBandManager.eventEmergencyAlarm,
                      "Emergency alarm from watch (SOS press or fall detection)",
                      ["detection": "frame-signature",
                       "possibleTriggers": ["SOS button press", "fall detection"],
                       "rawFrame": hex])
    }

    private func onSdkSos() {
        emitEmergency(HBandManager.eventSosPressed, "SOS button pressed on watch",
                      ["detection": "sdk-sos-listener"])
    }

    /// From [CallSosDetector]: the watch placed an outgoing call over call Bluetooth.
    private func onCallSos() {
        emitEmergency(HBandManager.eventSosPressed, "SOS call placed by watch",
                      ["detection": "hfp-outgoing-call"])
    }

    private func onReminder(_ model: VPReminderEventModel) {
        let payload: [String: Any] = [
            "detection": "sdk-remind-event",
            "remindEvent": model.type == .fall ? "FALL" : "SEDENTARY",
            "eventTimestampSeconds": model.timestamp,
        ]
        if model.type == .fall {
            emitEmergency(HBandManager.eventFallDetected, "Fall detected by watch", payload)
        } else {
            record(HBandManager.eventSedentary, "Sedentary reminder", payload, alert: false)
        }
    }

    private func emitEmergency(_ type: String, _ detail: String, _ payload: [String: Any]) {
        let now = Date()
        guard now.timeIntervalSince(lastEmergencyAt) >= HBandManager.emergencyDedupe else { return }
        lastEmergencyAt = now
        record(type, detail, payload, alert: true)
    }

    func simulateEmergency(label: String?) -> [String: Any] {
        record(HBandManager.eventEmergencyAlarm, label ?? "SIMULATED emergency",
               ["detection": "simulated", "simulated": true], alert: true).toMap()
    }

    // MARK: - Feed

    final class GuardEvent {
        let id: String
        let type: String
        let timestamp: Date
        let detail: String
        let data: [String: Any]
        var webhookStatus: String
        var acknowledged: Bool

        init(id: String = UUID().uuidString, type: String, timestamp: Date = Date(),
             detail: String, data: [String: Any], webhookStatus: String = "not sent",
             acknowledged: Bool) {
            self.id = id
            self.type = type
            self.timestamp = timestamp
            self.detail = detail
            self.data = data
            self.webhookStatus = webhookStatus
            self.acknowledged = acknowledged
        }

        func toMap() -> [String: Any] {
            [
                "id": id,
                "type": type,
                "timestamp": Int64(timestamp.timeIntervalSince1970 * 1000),
                "detail": detail,
                "webhookStatus": webhookStatus,
                "acknowledged": acknowledged,
                "data": data,
            ]
        }
    }

    func eventList() -> [[String: Any]] { events.reversed().map { $0.toMap() } }

    func clearEvents() {
        events.removeAll()
        persistEmergencyEvents()
    }

    func acknowledge(id: String) -> Bool {
        guard let event = events.first(where: { $0.id == id }) else { return false }
        event.acknowledged = true
        persistEmergencyEvents()
        return true
    }

    private func isEmergencyType(_ type: String) -> Bool {
        type == HBandManager.eventEmergencyAlarm ||
        type == HBandManager.eventSosPressed ||
        type == HBandManager.eventFallDetected
    }

    private func loadPersistedEvents() {
        guard let raw = UserDefaults.standard.data(forKey: HBandManager.persistedEventsKey),
              let list = try? JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else { return }
        for item in list {
            guard let id = item["id"] as? String,
                  let type = item["type"] as? String,
                  isEmergencyType(type),
                  !events.contains(where: { $0.id == id }) else { continue }
            let milliseconds = (item["timestamp"] as? NSNumber)?.doubleValue ?? 0
            events.append(GuardEvent(
                id: id,
                type: type,
                timestamp: Date(timeIntervalSince1970: milliseconds / 1000),
                detail: item["detail"] as? String ?? "",
                data: item["data"] as? [String: Any] ?? [:],
                webhookStatus: item["webhookStatus"] as? String ?? "not sent",
                acknowledged: item["acknowledged"] as? Bool ?? false
            ))
        }
        if events.count > HBandManager.maxEvents {
            events.removeFirst(events.count - HBandManager.maxEvents)
        }
    }

    private func persistEmergencyEvents() {
        let list = events
            .filter { isEmergencyType($0.type) && ($0.data["simulated"] as? Bool != true) }
            .map { $0.toMap() }
        guard let raw = try? JSONSerialization.data(withJSONObject: list) else { return }
        UserDefaults.standard.set(raw, forKey: HBandManager.persistedEventsKey)
    }

    /// Adds a status line to the feed (used by PhoneFeatures).
    func note(_ text: String) { recordStatus(text) }

    private func recordStatus(_ text: String) {
        record(HBandManager.eventStatus, text, [:], alert: false, report: false)
    }

    @discardableResult
    private func record(_ type: String, _ detail: String, _ payload: [String: Any],
                        alert: Bool, report: Bool = true) -> GuardEvent {
        var data = payload
        if report { data["watch"] = watchInfo() }
        let event = GuardEvent(type: type, detail: detail, data: data, acknowledged: !alert)
        events.append(event)
        if events.count > HBandManager.maxEvents { events.removeFirst(events.count - HBandManager.maxEvents) }
        NSLog("[HBand] EVENT \(type): \(detail)")

        if report {
            if WebhookReporter.isEnabled {
                event.webhookStatus = "sending…"
                WebhookReporter.report(eventType: type, payload: data) { [weak self] success, _, message in
                    event.webhookStatus = success ? "sent (\(message))" : "failed (\(message))"
                    self?.listener?.onEvent(event.toMap())
                }
            } else {
                event.webhookStatus = "webhook off"
            }
        }
        if alert && HBandSession.emergencyNotification { postEmergencyNotification(event) }
        if alert { persistEmergencyEvents() }
        listener?.onEvent(event.toMap())
        return event
    }

    private func postEmergencyNotification(_ event: GuardEvent) {
        let content = UNMutableNotificationContent()
        content.title = "🆘 Emergency from watch"
        content.body = event.detail
        content.sound = .defaultCritical
        content.userInfo = ["hband_emergency_event_id": event.id]
        if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }
        let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Health data (sync history / manual measurement)

    private var activeSync: HealthSync?
    private var activeMeasure: HealthMeasure?

    /// A sync or measurement owns the SDK — it can only run one command at a time.
    var isBusy: Bool { activeSync != nil || activeMeasure != nil }

    var isReady: Bool { state == HBandManager.stateReady && ble.isConnected }

    /// Backend `imei`: the watch MAC in upper case (SDK deviceAddress after the password check).
    var imei: String? {
        // Never the CoreBluetooth UUID: the backend keys the watch by its MAC.
        if let mac = connectedMac() { return mac }
        guard let saved = HBandSession.deviceId, HBandManager.isMac(saved) else { return nil }
        return saved.uppercased()
    }

    /// MAC ("85:D7:5F:52:E6:18") of the connected watch: the SDK address read from
    /// advertising / the password check, else — for a Jieli watch iOS already linked,
    /// which never advertised — the BLE address its chip reports. nil if unknown.
    private func connectedMac() -> String? {
        if let address = ble.peripheralModel?.deviceAddress, HBandManager.isMac(address) {
            return address.uppercased()
        }
        guard ble.isConnected,
              let raw = ble.peripheralManage?.mAssist?.mCmdManager.outputDeviceModel().bleAddr else { return nil }
        let hex = raw.replacingOccurrences(of: ":", with: "").uppercased()
        guard hex.count == 12, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        let mac = stride(from: 0, to: 12, by: 2).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 2)])
        }.joined(separator: ":")
        return mac == "00:00:00:00:00:00" ? nil : mac
    }

    static func isMac(_ value: String) -> Bool {
        value.range(of: "^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", options: .regularExpression) != nil
    }

    func syncHealth(days: Int, types: Set<String>,
                    onProgress: @escaping ([String: Any]) -> Void,
                    completion: @escaping ([String: Any]?, String?) -> Void) {
        initialize()
        guard isReady else { return completion(nil, "NOT_READY") }
        guard !isBusy else { return completion(nil, "BUSY") }
        let sync = HealthSync(ble: ble, days: days, types: types, onProgress: onProgress) { [weak self] result in
            self?.activeSync = nil
            completion(result, nil)
        }
        activeSync = sync
        sync.start()
    }

    func cancelSync() { activeSync?.cancel() }

    func startMeasure(type: String,
                      onUpdate: @escaping ([String: Any]) -> Void,
                      completion: @escaping ([String: Any]?, String?) -> Void) {
        initialize()
        guard HealthMeasure.types.contains(type) else { return completion(nil, "UNSUPPORTED_TYPE") }
        guard isReady, let peripheral = ble.peripheralManage else { return completion(nil, "NOT_READY") }
        guard !isBusy else { return completion(nil, "BUSY") }
        let measure = HealthMeasure(type: type, peripheral: peripheral, onUpdate: onUpdate) { [weak self] result in
            self?.activeMeasure = nil
            completion(result, nil)
        }
        activeMeasure = measure
        measure.start()
    }

    func stopMeasure() { activeMeasure?.stop() }

    private func cancelHealthWork() {
        activeSync?.cancel()
        activeMeasure?.stop()
    }

    /// Which data the connected watch reports as supported.
    func capabilities() -> [String: Any] {
        let m = ble.peripheralModel
        return [
            "bodytemp": (m?.temperatureType ?? 0) > 0,
            "bloodglucose": (m?.bloodGlucoseType ?? 0) > 0,
            "ecg": (m?.ecgType ?? 0) > 0,
            "bloodpressure": m?.isSupportBPTest ?? false,
            "hrv": m?.isSupportHRVTest ?? false,
            "preciseSleep": (m?.sleepType ?? 0) == 1,
            "stress": (m?.stressType ?? 0) > 0,
            "reminderEvent": m?.isSupportReminderEvent ?? false,
            "watchDays": Int(m?.saveDays ?? 0),
            "temperatureType": Int(m?.temperatureType ?? 0),
            "bloodGlucoseType": Int(m?.bloodGlucoseType ?? 0),
            "measurements": measurements(m),
        ]
    }

    /// `HealthMeasure` types the connected watch can measure on demand.
    private func measurements(_ m: VPPeripheralModel?) -> [String] {
        guard let m = m else { return [] }
        let supported: [(String, Bool)] = [
            (HealthRecords.heartRate, true),
            (HealthRecords.bloodPressure, m.isSupportBPTest),
            (HealthRecords.spo2, m.oxygenType != 0),
            (HealthRecords.bodyTemp, m.temperatureType > 0),
            (HealthRecords.fatigue, true),
            (HealthRecords.bloodGlucose, m.bloodGlucoseType > 0),
            (HealthRecords.ecg, m.ecgType > 0),
            ("ptt", m.ecgType > 0),
            (HealthRecords.stress, m.stressType > 0),
            (HealthRecords.hrv, m.isSupportHRVTest),
            // Breathing rate uses the SpO2 sensor (SDK: "no SpO2 function").
            (HealthRecords.respiratory, m.oxygenType != 0),
            (HealthMeasure.bloodComponent, m.bloodAnalysisType > 0),
            (HealthMeasure.bodyComposition, m.bodyCompositionType > 0),
            (HealthMeasure.gsr, m.gsrType > 0),
            (HealthMeasure.met, m.isSupportMetTest),
            (HealthMeasure.emotion, m.isSupportEmotionTest),
            (HealthMeasure.checkup, m.supportHealthGlanceTest),
        ]
        return supported.filter { $0.1 }.map { $0.0 }
    }

    // MARK: - Info

    func watchInfo() -> [String: Any] {
        let number = HBandSession.deviceNumber
        return [
            "sn": number > 0 ? String(number) : "unknown",
            "mac": HBandSession.deviceId ?? "",
            "name": HBandSession.name,
            "firmware": HBandSession.firmware ?? "",
            "firmwareTest": HBandSession.firmwareTest ?? "",
        ]
    }

    func connectionState() -> [String: Any?] {
        [
            "state": state,
            "deviceId": HBandSession.deviceId ?? currentScanId,
            "name": currentName ?? (HBandSession.isConfigured ? HBandSession.name : nil),
            "message": stateMessage,
            "guardRunning": monitoring,
        ]
    }

    private func setState(_ newState: String, _ message: String?) {
        guard newState != state || message != stateMessage else { return }
        state = newState
        stateMessage = message
        listener?.onConnectionChanged(connectionState().compactMapValues { $0 })
    }

    func readBattery(_ completion: @escaping ([String: Any]?) -> Void) {
        initialize()
        guard state == HBandManager.stateReady, let peripheral = ble.peripheralManage else {
            completion(nil)
            return
        }
        var answered = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if !answered { answered = true; completion(nil) }
        }
        peripheral.veepooSDKReadDeviceBatteryAndChargeInfo { isPercent, chargeState, isLow, battery in
            DispatchQueue.main.async {
                guard !answered else { return }
                answered = true
                completion([
                    "isPercent": isPercent,
                    "percent": isPercent ? Int(battery) : 0,
                    "level": isPercent ? 0 : Int(battery),
                    "isLow": isLow,
                    "charging": chargeState.rawValue == 1,
                ])
            }
        }
    }
}

// MARK: - Session persistence

enum HBandSession {
    private static let defaults = UserDefaults.standard
    private static let prefix = "releep_hband_session."

    static var isConfigured: Bool { !(scanId ?? "").isEmpty }

    /// Address seen while scanning (used to find the watch again).
    static var scanId: String? { defaults.string(forKey: prefix + "scanId") }
    /// Address reported by the SDK after the password check (may differ).
    static var deviceId: String? { defaults.string(forKey: prefix + "deviceId") }
    static var name: String { defaults.string(forKey: prefix + "name") ?? "" }
    static var password: String { defaults.string(forKey: prefix + "password") ?? HBandManager.defaultPassword }
    static var deviceNumber: Int { defaults.integer(forKey: prefix + "deviceNumber") }
    static var firmware: String? { defaults.string(forKey: prefix + "firmware") }
    static var firmwareTest: String? { defaults.string(forKey: prefix + "firmwareTest") }
    /// CoreBluetooth id of the watch, to find it when iOS already holds its link.
    static var peripheralId: String? { defaults.string(forKey: prefix + "peripheralId") }
    /// Watch (scanId) that already got the default SOS call count.
    static var sosDefaultAppliedFor: String? {
        get { defaults.string(forKey: prefix + "sosDefaultAppliedFor") }
        set { defaults.set(newValue, forKey: prefix + "sosDefaultAppliedFor") }
    }

    static var guardEnabled: Bool {
        get { defaults.object(forKey: prefix + "guardEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: prefix + "guardEnabled") }
    }

    /// Report an outgoing call through the watch's call Bluetooth as SOS ([CallSosDetector]).
    static var callSosDetection: Bool {
        get { defaults.object(forKey: prefix + "callSosDetection") as? Bool ?? true }
        set { defaults.set(newValue, forKey: prefix + "callSosDetection") }
    }

    /// Post the plugin's own local notification for an emergency (kept across "forget").
    static var emergencyNotification: Bool {
        get { defaults.object(forKey: prefix + "emergencyNotification") as? Bool ?? true }
        set { defaults.set(newValue, forKey: prefix + "emergencyNotification") }
    }

    static func save(scanId: String, deviceId: String, name: String, password: String,
                     deviceNumber: Int, firmware: String?, firmwareTest: String?, peripheralId: String?) {
        defaults.set(scanId, forKey: prefix + "scanId")
        defaults.set(deviceId, forKey: prefix + "deviceId")
        defaults.set(name, forKey: prefix + "name")
        defaults.set(password.isEmpty ? HBandManager.defaultPassword : password, forKey: prefix + "password")
        if deviceNumber > 0 { defaults.set(deviceNumber, forKey: prefix + "deviceNumber") }
        if let firmware = firmware, !firmware.isEmpty { defaults.set(firmware, forKey: prefix + "firmware") }
        if let test = firmwareTest, !test.isEmpty { defaults.set(test, forKey: prefix + "firmwareTest") }
        if let id = peripheralId, !id.isEmpty { defaults.set(id, forKey: prefix + "peripheralId") }
    }

    static func forget() {
        for key in ["scanId", "deviceId", "name", "password", "deviceNumber", "firmware", "firmwareTest",
                    "peripheralId", "sosDefaultAppliedFor", "guardEnabled"] {
            defaults.removeObject(forKey: prefix + key)
        }
    }

    static func toMap() -> [String: Any]? {
        guard isConfigured else { return nil }
        return [
            "deviceId": deviceId ?? scanId ?? "",
            "name": name,
            "deviceNumber": deviceNumber,
            "firmware": firmware ?? "",
            "firmwareTest": firmwareTest ?? "",
            "guardEnabled": guardEnabled,
            "callSosDetection": callSosDetection,
        ]
    }
}

// MARK: - Webhook

enum WebhookReporter {
    private static let defaults = UserDefaults.standard
    private static let urlKey = "releep_hband_webhook.url"
    private static let enabledKey = "releep_hband_webhook.enabled"

    static var url: String { defaults.string(forKey: urlKey) ?? "" }
    static var enabledFlag: Bool { defaults.bool(forKey: enabledKey) }
    static var isEnabled: Bool { enabledFlag && !url.isEmpty }

    static func configure(url: String?, enabled: Bool?) {
        if let url = url { defaults.set(url.trimmingCharacters(in: .whitespaces), forKey: urlKey) }
        if let enabled = enabled { defaults.set(enabled, forKey: enabledKey) }
    }

    static func toMap() -> [String: Any] { ["url": url, "enabled": enabledFlag] }

    /// POSTs {event, timestamp, timestampIso, platform, ...payload}. Wrapped in
    /// a background task so it completes when the app was woken by BLE.
    static func report(eventType: String, payload: [String: Any], force: Bool = false,
                       completion: ((Bool, Int, String) -> Void)? = nil) {
        guard let target = URL(string: url), !url.isEmpty, force || isEnabled else {
            DispatchQueue.main.async { completion?(false, 0, "webhook off") }
            return
        }
        var body = payload
        body["event"] = eventType
        body["timestamp"] = Int64(Date().timeIntervalSince1970 * 1000)
        body["timestampIso"] = ISO8601DateFormatter().string(from: Date())
        body["platform"] = "ios"

        var request = URLRequest(url: target, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "hband-webhook") {
            UIApplication.shared.endBackgroundTask(task)
        }
        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let success = (200..<300).contains(code)
            let message = success ? "HTTP \(code)" : (error?.localizedDescription ?? "HTTP \(code)")
            DispatchQueue.main.async {
                completion?(success, code, message)
                UIApplication.shared.endBackgroundTask(task)
            }
        }.resume()
    }
}
