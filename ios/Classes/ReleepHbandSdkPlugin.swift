import Flutter
import UIKit
import UserNotifications

/// Flutter bridge for the Veepoo / HBand SDK (same contract as Android).
///
/// MethodChannel  releep_hband_sdk/method
/// EventChannel   releep_hband_sdk/scan        → scanned devices + {"finished": true}
/// EventChannel   releep_hband_sdk/connection  → connection state changes
/// EventChannel   releep_hband_sdk/events      → guard events (SOS / fall / status)
/// EventChannel   releep_hband_sdk/progress    → health sync progress + live measurement values
/// EventChannel   releep_hband_sdk/callBluetooth → watch call-Bluetooth (Classic / HFP) state
public class ReleepHbandSdkPlugin: NSObject, FlutterPlugin, HBandManagerListener, UNUserNotificationCenterDelegate {

    private var scanSink: FlutterEventSink?
    private var connectionSink: FlutterEventSink?
    private var eventsSink: FlutterEventSink?
    private var progressSink: FlutterEventSink?
    private var callBtSink: FlutterEventSink?
    private var launchEmergencyEventId: String?
    private let manager = HBandManager.shared

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = ReleepHbandSdkPlugin()
        let messenger = registrar.messenger()
        let method = FlutterMethodChannel(name: "releep_hband_sdk/method", binaryMessenger: messenger)
        registrar.addMethodCallDelegate(instance, channel: method)
        FlutterEventChannel(name: "releep_hband_sdk/scan", binaryMessenger: messenger)
            .setStreamHandler(SinkHandler { instance.scanSink = $0 })
        FlutterEventChannel(name: "releep_hband_sdk/connection", binaryMessenger: messenger)
            .setStreamHandler(SinkHandler { instance.connectionSink = $0 })
        FlutterEventChannel(name: "releep_hband_sdk/events", binaryMessenger: messenger)
            .setStreamHandler(SinkHandler { instance.eventsSink = $0 })
        FlutterEventChannel(name: "releep_hband_sdk/progress", binaryMessenger: messenger)
            .setStreamHandler(SinkHandler { instance.progressSink = $0 })
        FlutterEventChannel(name: "releep_hband_sdk/callBluetooth", binaryMessenger: messenger)
            .setStreamHandler(SinkHandler { instance.callBtSink = $0 })
        instance.manager.listener = instance
        PhoneFeatures.shared.btListener = { [weak instance] state in
            instance?.callBtSink?(state.compactMapValues { $0 })
        }

        // Handle taps on emergency notifications, unless the host app already
        // owns the notification delegate.
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = instance }
    }

    // MARK: - HBandManagerListener

    func onScanResult(_ device: [String: Any]) { scanSink?(device) }
    func onScanFinished() { scanSink?(["finished": true]) }
    func onConnectionChanged(_ state: [String: Any]) { connectionSink?(state) }
    func onEvent(_ event: [String: Any]) { eventsSink?(event) }

    // MARK: - MethodChannel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "initialize":
            manager.initialize()
            if HBandSession.isConfigured && HBandSession.guardEnabled { manager.startGuard() }
            result([
                "platform": "ios",
                "session": HBandSession.toMap() as Any,
                "connection": manager.connectionState().compactMapValues { $0 },
            ])

        case "checkPermissions":
            permissionStatus { result($0) }

        case "requestPermissions":
            requestPermissions { result($0) }

        case "isBluetoothEnabled":
            result(manager.isBluetoothEnabled)

        case "startScan":
            manager.initialize()
            if !manager.bluetoothAuthorized && manager.bluetoothAuthorizationDetermined {
                result(FlutterError(code: "PERMISSION_DENIED", message: "Bluetooth permission not granted", details: nil))
                return
            }
            if !manager.isBluetoothEnabled {
                result(FlutterError(code: "BLUETOOTH_OFF", message: "Bluetooth is turned off", details: nil))
                return
            }
            manager.startScan(timeout: TimeInterval(args["timeoutSeconds"] as? Int ?? 10),
                              watchId: args["watchId"] as? String, watchName: args["watchName"] as? String)
            result(nil)

        case "stopScan":
            manager.stopScan()
            result(nil)

        case "connect":
            guard let deviceId = args["deviceId"] as? String, !deviceId.isEmpty else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "deviceId is required", details: nil))
                return
            }
            var password = args["password"] as? String ?? HBandManager.defaultPassword
            if password.count != 4 || !password.allSatisfy({ $0.isNumber }) {
                password = HBandManager.defaultPassword
            }
            manager.connect(deviceId: deviceId, name: args["name"] as? String, password: password,
                            is24Hour: args["is24Hour"] as? Bool ?? true) { outcome in
                result(outcome.compactMapValues { $0 })
            }

        case "disconnect":
            manager.disconnect()
            result(nil)

        case "forgetWatch":
            manager.forgetWatch()
            result(nil)

        case "getSession":
            result(HBandSession.toMap())

        case "getConnectionState":
            result(manager.connectionState().compactMapValues { $0 })

        case "readBattery":
            manager.readBattery { result($0) }

        case "startGuard":
            result(manager.startGuard())

        case "stopGuard":
            manager.stopGuard()
            result(nil)

        case "isGuardRunning":
            result(manager.monitoring)

        case "setCallSosDetection":
            HBandSession.callSosDetection = args["enabled"] as? Bool ?? false
            manager.syncCallSosDetector()
            permissionStatus { result($0) } // no extra permission needed on iOS

        case "setEmergencyNotification":
            HBandSession.emergencyNotification = args["enabled"] as? Bool ?? true
            result(nil)

        case "getEvents":
            result(manager.eventList())

        case "clearEvents":
            manager.clearEvents()
            result(nil)

        case "acknowledgeEvent":
            result(manager.acknowledge(id: args["id"] as? String ?? ""))

        case "simulateEmergency":
            result(manager.simulateEmergency(label: args["label"] as? String))

        case "getLaunchEmergencyEventId":
            result(launchEmergencyEventId)
            launchEmergencyEventId = nil

        case "getWebhookConfig":
            result(WebhookReporter.toMap())

        case "setWebhookConfig":
            WebhookReporter.configure(url: args["url"] as? String, enabled: args["enabled"] as? Bool)
            result(WebhookReporter.toMap())

        case "testWebhook":
            let payload: [String: Any] = [
                "message": "Test ping from releep_hband_sdk",
                "watch": manager.watchInfo(),
            ]
            WebhookReporter.report(eventType: "TEST", payload: payload, force: true) { success, code, message in
                result(["success": success, "httpCode": code, "message": message])
            }

        // MARK: health data
        case "getImei":
            result(manager.imei)

        case "getCapabilities":
            result(manager.capabilities())

        case "syncHealthData":
            let types = Set((args["types"] as? [String]) ?? HealthRecords.allTypes)
            manager.syncHealth(days: args["days"] as? Int ?? 3, types: types,
                               onProgress: { [weak self] p in self?.progressSink?(p) }) { [weak self] outcome, error in
                if let error = error {
                    result(FlutterError(code: error, message: self?.errorMessage(error), details: nil))
                } else {
                    result(outcome)
                }
            }

        case "cancelHealthSync":
            manager.cancelSync()
            result(nil)

        case "confirmHealthUpload":
            HealthSync.confirmUpload()
            result(nil)

        case "startMeasurement":
            manager.startMeasure(type: args["type"] as? String ?? "",
                                 onUpdate: { [weak self] u in self?.progressSink?(u) }) { [weak self] outcome, error in
                if let error = error {
                    result(FlutterError(code: error, message: self?.errorMessage(error), details: nil))
                } else {
                    result(outcome)
                }
            }

        case "stopMeasurement":
            manager.stopMeasure()
            result(nil)

        // MARK: call Bluetooth + contacts
        case "getCallBluetoothState", "readCallBluetoothState":
            // iOS has no BT read command; the SDK pushes the state after the password check.
            result(phone.btState().compactMapValues { $0 })

        case "connectCallBluetooth":
            replyError(result, phone.connectBt())

        case "disconnectCallBluetooth":
            result(FlutterError(code: "UNSUPPORTED", message: "Unpair the watch in Settings → Bluetooth", details: nil))

        case "getContactSupport":
            result(phone.contactSupport())

        case "getContacts":
            phone.readContacts(reply(result))

        case "addContact":
            let name = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let phoneNumber = (args["phone"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !phoneNumber.isEmpty else {
                return result(FlutterError(code: "INVALID_ARGUMENT", message: "name and phone are required", details: nil))
            }
            phone.addContact(name: name, phone: phoneNumber, sos: args["sos"] as? Bool ?? false, reply(result))

        case "deleteContact":
            phone.deleteContact(id: args["id"] as? Int ?? -1, reply(result))

        case "setSosContact":
            phone.setSosContact(id: args["id"] as? Int ?? -1, enabled: args["enabled"] as? Bool ?? true, reply(result))

        case "getSosCallTimes":
            phone.readSosCallTimes(reply(result))

        case "setSosCallTimes":
            phone.setSosCallTimes(args["times"] as? Int ?? 1, reply(result))

        case "getRawFrames":
            // iOS has no SDK frame log; frames are inspected live by HBFrameSniffer.
            result(["incoming": [String](), "outgoing": [String]()])

        case "isIgnoringBatteryOptimizations":
            result(true)

        case "requestIgnoreBatteryOptimizations":
            result(false)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private var phone: PhoneFeatures { PhoneFeatures.shared }

    private func reply<T>(_ result: @escaping FlutterResult) -> (T?, String?) -> Void {
        return { [weak self] value, error in
            if let error = error {
                result(FlutterError(code: error, message: self?.errorMessage(error), details: nil))
            } else {
                result(value)
            }
        }
    }

    private func replyError(_ result: FlutterResult, _ error: String?) {
        if let error = error {
            result(FlutterError(code: error, message: errorMessage(error), details: nil))
        } else {
            result(nil)
        }
    }

    private func errorMessage(_ code: String) -> String {
        switch code {
        case "NOT_READY": return "Watch is not connected"
        case "BUSY": return "Another command is running on the watch"
        case "UNSUPPORTED_TYPE": return "This measurement type is not supported"
        case "UNSUPPORTED": return "The watch does not support this feature"
        case "NOT_FOUND": return "Contact not found on the watch"
        case "TIMEOUT": return "The watch did not answer"
        case "FAILED": return "The watch rejected the command"
        default: return code
        }
    }

    // MARK: - Permissions

    private func permissionStatus(_ completion: @escaping ([String: Any]) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let notification = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                completion(["bluetooth": self.manager.bluetoothAuthorized, "notification": notification])
            }
        }
    }

    private func requestPermissions(_ completion: @escaping ([String: Any]) -> Void) {
        // Creating the SDK's CBCentralManager triggers the Bluetooth prompt.
        manager.initialize()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            self.waitForBluetoothDecision(attempts: 40) {
                self.permissionStatus(completion)
            }
        }
    }

    /// Polls until the user answered the Bluetooth prompt (max ~20 s).
    private func waitForBluetoothDecision(attempts: Int, then done: @escaping () -> Void) {
        DispatchQueue.main.async {
            if self.manager.bluetoothAuthorizationDetermined || attempts <= 0 {
                done()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.waitForBluetoothDecision(attempts: attempts - 1, then: done)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["hband_emergency_event_id"] as? String {
            launchEmergencyEventId = id
            eventsSink?(["type": "_OPEN_EMERGENCY", "id": id])
        }
        completionHandler()
    }
}

/// Minimal FlutterStreamHandler that stores / clears the sink.
private final class SinkHandler: NSObject, FlutterStreamHandler {
    private let assign: (FlutterEventSink?) -> Void

    init(_ assign: @escaping (FlutterEventSink?) -> Void) {
        self.assign = assign
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        assign(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        assign(nil)
        return nil
    }
}
