import Foundation
import VeepooBleSDK

/// Backend `{type}` names + record helpers (same contract as Android HealthRecords).
enum HealthRecords {
    static let heartRate = "heartrate"
    static let spo2 = "spo2"
    static let bloodPressure = "bloodpressure"
    static let bodyTemp = "bodytemp"
    static let respiratory = "respiratory"
    static let hrv = "hrv"
    static let fatigue = "fatigue"
    static let stepCount = "stepcount"
    static let calorie = "calorie"
    static let battery = "battery"
    static let sleep = "sleep"
    static let sport = "sport"
    static let ecg = "ecg"
    static let bloodGlucose = "bloodglucose"
    static let rrInterval = "rrinterval"
    static let heartWarning = "heartwarning"
    static let stress = "stress"

    static let allTypes = [heartRate, spo2, bloodPressure, bodyTemp, respiratory, hrv, fatigue, stepCount,
                           calorie, battery, sleep, sport, ecg, bloodGlucose, rrInterval, heartWarning, stress]

    static let online = "online"
    static let offline = "offline"
    static let maxArray = 200_000

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = pattern
        return f
    }

    static let timeFormat = formatter("yyyy-MM-dd HH:mm:ss")
    static let dateFormat = formatter("yyyy-MM-dd")

    static func now() -> String { timeFormat.string(from: Date()) }

    static func format(_ date: Date) -> String { timeFormat.string(from: date) }

    /// "yyyy-MM-dd" + "HH:mm" → "yyyy-MM-dd HH:mm:00"
    static func time(date: String, clock: String) -> String? {
        let parts = clock.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let s = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        return String(format: "%@ %02d:%02d:%02d", date, h, m, s)
    }

    /// Parses the various SDK date strings ("2023-03-24 14:38:42", "2017/02/09 01:15", ...).
    static func parse(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm"] {
            if let d = formatter(pattern).date(from: value) { return d }
        }
        return nil
    }

    static func fatigueStatus(_ value: Int) -> String {
        value <= 1 ? "good" : (value == 2 ? "middle" : "bad")
    }

    /// Stress 0–100 (SDK scale) → backend status.
    static func stressStatus(_ value: Int) -> String {
        value < 40 ? "good" : (value < 70 ? "middle" : "bad")
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    static func int(_ any: Any?) -> Int? {
        switch any {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Double(s).map { Int($0) }
        default: return nil
        }
    }

    static func double(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func averageNonZero(_ any: Any?) -> Int? {
        guard let list = any as? [Any] else { return nil }
        let values = list.compactMap { int($0) }.filter { $0 > 0 }
        return values.isEmpty ? nil : values.reduce(0, +) / values.count
    }

    static func intArray(_ any: Any?) -> [Int]? {
        guard let list = any as? [Any] else { return nil }
        let values = list.compactMap { int($0) }
        return values.isEmpty ? nil : Array(values.prefix(maxArray))
    }
}

/// Records per type; same `time` → last one wins (the backend also de-duplicates on time).
final class RecordBag {
    private var byType: [String: [String: [String: Any]]] = [:]
    private var order: [String: [String]] = [:]

    func put(_ type: String, _ record: [String: Any], key: String? = nil) {
        guard let k = key ?? (record["time"] as? String) else { return }
        if byType[type]?[k] == nil { order[type, default: []].append(k) }
        byType[type, default: [:]][k] = record
    }

    func putIfAbsent(_ type: String, _ record: [String: Any]) {
        guard let k = record["time"] as? String, byType[type]?[k] == nil else { return }
        put(type, record, key: k)
    }

    func records(_ type: String) -> [[String: Any]] {
        (order[type] ?? []).compactMap { byType[type]?[$0] }
    }

    func toMap() -> [String: [[String: Any]]] {
        var out: [String: [[String: Any]]] = [:]
        for type in byType.keys {
            out[type] = records(type).sorted {
                String(describing: $0["time"] ?? $0["startTime"] ?? "") < String(describing: $1["time"] ?? $1["startTime"] ?? "")
            }
        }
        return out
    }
}

/// Reads the watch history step by step (the SDK runs one command at a time)
/// into the SDK database, then queries it per day and builds backend records.
final class HealthSync {
    private let ble: VPBleCentralManage
    private let days: Int
    private let types: Set<String>
    private let onProgress: ([String: Any]) -> Void
    private let onDone: ([String: Any]) -> Void

    private let bag = RecordBag()
    private var errors: [String: String] = [:]
    private var skipped: [String] = []
    private var batteryPercent: Int?
    private var cancelled = false
    private var ended = false
    private var stepTimeout: DispatchWorkItem?
    private var stepIndex = 0

    /// A step whose watch stops answering is given up after this long without
    /// any progress, instead of waiting for its full timeout (up to minutes).
    private static let idleLimit: TimeInterval = 30
    private var idleTimeout: DispatchWorkItem?
    private var idleLimitForStep: TimeInterval = 0
    private var onIdle: (() -> Void)?
    private var currentStage: String?
    private let started = Date()

    private struct Step {
        let name: String
        let timeout: TimeInterval
        let wanted: Set<String>
        let supported: () -> Bool
        let run: (@escaping (String?) -> Void) -> Void
        /// False when the SDK gives no progress while the step runs: then only
        /// the full timeout applies, not [idleLimit].
        var reportsProgress: Bool = true
    }

    private var steps: [Step] = []

    init(ble: VPBleCentralManage, days: Int, types: Set<String>,
         onProgress: @escaping ([String: Any]) -> Void, onDone: @escaping ([String: Any]) -> Void) {
        self.ble = ble
        self.days = days
        self.types = types
        self.onProgress = onProgress
        self.onDone = onDone
        let H = HealthRecords.self
        steps = [
            Step(name: "battery", timeout: 10, wanted: [H.battery, H.stepCount, H.calorie], supported: { true }, run: readBattery),
            Step(name: "daily", timeout: 240,
                 wanted: [H.heartRate, H.bloodPressure, H.stepCount, H.calorie, H.sleep, H.bloodGlucose, H.bodyTemp, H.heartWarning, H.ecg],
                 supported: { true }, run: readAll),
            Step(name: "spo2", timeout: 120, wanted: [H.spo2, H.respiratory], supported: { true }, run: readOxygen),
            Step(name: "hrv", timeout: 120, wanted: [H.hrv], supported: { true }, run: readHrv),
            Step(name: "temperature", timeout: 120, wanted: [H.bodyTemp],
                 supported: { [weak self] in (self?.model?.temperatureType ?? 0) > 0 && self?.model?.temperatureType != 5 },
                 run: readTemperature),
            Step(name: "database", timeout: 30, wanted: Set(H.allTypes), supported: { true }, run: queryDatabase),
            Step(name: "rrinterval", timeout: 180, wanted: [H.rrInterval], supported: { true }, run: readRrInterval),
            Step(name: "sport", timeout: 120, wanted: [H.sport], supported: { true }, run: readSport, reportsProgress: false),
            Step(name: "heartwarning", timeout: 10, wanted: [H.heartWarning], supported: { true }, run: readHeartWarning),
        ]
    }

    private var model: VPPeripheralModel? { ble.peripheralModel }
    private var tableId: String { model?.deviceAddress ?? "" }
    private var peripheral: VPPeripheralBaseManage? { ble.peripheralManage }

    private var readDays: Int {
        let saved = Int(model?.saveDays ?? 3)
        return max(1, min(days, saved > 0 ? saved : 3))
    }

    /// Dates to query, today first ("yyyy-MM-dd").
    private var queryDates: [String] {
        (0..<readDays).compactMap { offset in
            Calendar.current.date(byAdding: .day, value: -offset, to: Date()).map { HealthRecords.dateFormat.string(from: $0) }
        }
    }

    func start() { DispatchQueue.main.async { self.next() } }

    func cancel() { cancelled = true }

    /// The watch link dropped: stop now with what was read so far instead of
    /// waiting for every remaining step to time out (minutes of `BUSY`).
    func abort(_ reason: String) {
        DispatchQueue.main.async {
            guard !self.ended else { return }
            self.stepTimeout?.cancel()
            self.clearIdle()
            self.errors["link"] = reason
            self.finish(cancelledByUser: false)
        }
    }

    // MARK: - Runner

    private func next() {
        if ended { return }
        if cancelled { return finish(cancelledByUser: true) }
        guard stepIndex < steps.count else { return finish(cancelledByUser: false) }
        let step = steps[stepIndex]
        stepIndex += 1
        if step.wanted.isDisjoint(with: types) { return next() }
        if !step.supported() {
            skipped.append(step.name)
            return next()
        }
        var answered = false
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, !answered else { return }
            answered = true
            self.clearIdle()
            self.errors[step.name] = "timeout"
            self.next()
        }
        stepTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + step.timeout, execute: timeout)
        currentStage = step.name
        idleLimitForStep = step.reportsProgress ? min(HealthSync.idleLimit, step.timeout) : step.timeout
        onIdle = { [weak self] in
            guard let self = self, !answered else { return }
            answered = true
            timeout.cancel()
            self.clearIdle()
            self.errors[step.name] = "timeout (no response for \(Int(self.idleLimitForStep)) s)"
            self.next()
        }
        progress(step.name, nil)
        armIdle()
        step.run { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self, !answered else { return }
                answered = true
                timeout.cancel()
                self.clearIdle()
                if let error = error { self.errors[step.name] = error }
                // Short gap: the SDK needs a moment between commands.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.next() }
            }
        }
    }

    /// (Re)starts the no-progress timer of the running step. Main thread only.
    private func armIdle() {
        idleTimeout?.cancel()
        guard let fire = onIdle else { return }
        let item = DispatchWorkItem { fire() }
        idleTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + idleLimitForStep, execute: item)
    }

    private func clearIdle() {
        idleTimeout?.cancel()
        idleTimeout = nil
        onIdle = nil
        currentStage = nil
    }

    private func progress(_ stage: String, _ fraction: Double?) {
        // Any sign of life from the running step restarts its idle timer.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.ended, stage == self.currentStage else { return }
            self.armIdle()
        }
        let index = Double(steps.firstIndex { $0.name == stage } ?? 0)
        let overall = (index + min(max(fraction ?? 0, 0), 1)) / Double(steps.count)
        var event: [String: Any] = ["kind": "sync", "stage": stage, "progress": overall]
        if let f = fraction { event["stageProgress"] = f }
        DispatchQueue.main.async { self.onProgress(event) }
    }

    private func finish(cancelledByUser: Bool) {
        guard !ended else { return }
        ended = true
        clearIdle()
        // RR bookmarks wait for the app to confirm the upload (confirmUpload).
        if types.contains(HealthRecords.rrInterval) {
            HealthSync.pendingRr = rrPending
            rrPending.removeAll()
        }
        let records = bag.toMap().filter { types.contains($0.key) }
        onDone([
            "success": errors.isEmpty && !cancelledByUser,
            "cancelled": cancelledByUser,
            "records": records,
            "counts": records.mapValues { $0.count },
            "errors": errors,
            "skipped": skipped,
            "durationMs": Int(Date().timeIntervalSince(started) * 1000),
        ])
    }

    /// SDK read blocks report state 2 (complete) / 3 (invalid) when done.
    private func readState(_ stage: String, _ done: @escaping (String?) -> Void)
        -> (VPReadDeviceBaseDataState, UInt, UInt, UInt) -> Void {
        var finished = false
        return { [weak self] state, totalDay, currentDay, dayProgress in
            guard !finished else { return }
            switch state.rawValue {
            case 2:
                finished = true
                done(nil)
            case 3:
                finished = true
                done("not supported")
            default:
                let total = max(Double(totalDay), 1)
                self?.progress(stage, (Double(currentDay) + Double(dayProgress) / 100) / total)
            }
        }
    }

    // MARK: - Steps

    private func readBattery(_ done: @escaping (String?) -> Void) {
        guard let peripheral = peripheral else { return done("not ready") }
        peripheral.veepooSDKReadDeviceBatteryAndChargeInfo { [weak self] isPercent, _, _, battery in
            let percent = isPercent ? Int(battery) : Int(battery) * 25
            self?.batteryPercent = percent
            self?.bag.put(HealthRecords.battery, ["value": percent, "time": HealthRecords.now()])
            done(nil)
        }
    }

    private func readAll(_ done: @escaping (String?) -> Void) {
        guard let peripheral = peripheral else { return done("not ready") }
        peripheral.veepooSdkStartReadDeviceAllData(readStateChange: readState("daily", done))
    }

    private func readOxygen(_ done: @escaping (String?) -> Void) {
        guard let peripheral = peripheral else { return done("not ready") }
        peripheral.veepooSdkStartReadDeviceOxygenData(readState("spo2", done))
    }

    private func readHrv(_ done: @escaping (String?) -> Void) {
        guard let peripheral = peripheral else { return done("not ready") }
        peripheral.veepooSdkStartReadDeviceHrvData(readState("hrv", done))
    }

    private func readTemperature(_ done: @escaping (String?) -> Void) {
        guard let peripheral = peripheral else { return done("not ready") }
        peripheral.veepooSdkStartReadDeviceTemperatureData(readState("temperature", done))
    }

    // MARK: Database → records

    private func queryDatabase(_ done: @escaping (String?) -> Void) {
        guard !tableId.isEmpty else { return done("no device address") }
        let group = DispatchGroup()
        for (index, date) in queryDates.enumerated() {
            queryOriginal(date)
            queryBlood(date)
            queryOxygen(date)
            queryHrv(date)
            queryTemperature(date)
            queryGlucose(date)
            querySleep(date)
            queryOfflineEcg(date)
            if index == 0, types.contains(HealthRecords.stepCount) || types.contains(HealthRecords.calorie) {
                group.enter()
                VPDataBaseOperation.veepooSDKGetStepData(withDate: date, andTableID: tableId,
                                                         changeUserStature: UInt(model?.deviceStature ?? 175)) { [weak self] dict in
                    self?.addCurrentSteps(dict)
                    group.leave()
                }
            }
            progress("database", Double(index + 1) / Double(queryDates.count))
        }
        // A night's segments can be stored under different dates.
        flushSleepNights()
        group.notify(queue: .main) { done(nil) }
    }

    private var dailySteps: [String: Int] = [:]
    private var dailyKcal: [String: Double] = [:]
    private var dailyDistance: [String: Double] = [:]

    private func queryOriginal(_ date: String) {
        guard let dict = VPDataBaseOperation.veepooSDKGetOriginalData(withDate: date, andTableID: tableId) as? [String: [String: Any]] else { return }
        for clock in dict.keys.sorted() {
            guard let item = dict[clock], let time = HealthRecords.time(date: date, clock: clock) else { continue }
            // heartValue first, then ppgs, then ecgs (as documented by the SDK).
            let heart = HealthRecords.int(item["heartValue"]).flatMap { $0 > 0 ? $0 : nil }
                ?? HealthRecords.averageNonZero(item["ppgs"])
                ?? HealthRecords.averageNonZero(item["ecgs"])
            if let heart = heart, (30...250).contains(heart) {
                bag.put(HealthRecords.heartRate, ["value": heart, "source": HealthRecords.offline, "time": time])
            }
            let sbp = HealthRecords.int(item["systolic"]) ?? 0
            let dbp = HealthRecords.int(item["diastolic"]) ?? 0
            if sbp > 0 && dbp > 0 {
                bag.putIfAbsent(HealthRecords.bloodPressure, ["sbp": sbp, "dbp": dbp, "source": HealthRecords.offline, "time": time])
            }
            if let stress = HealthRecords.int(item["stress"]), (1...100).contains(stress) {
                bag.putIfAbsent(HealthRecords.stress, ["value": stress, "status": HealthRecords.stressStatus(stress), "time": time])
            }
            let step = HealthRecords.int(item["stepValue"]) ?? 0
            let kcal = HealthRecords.double(item["calValue"]) ?? 0
            let dist = HealthRecords.double(item["disValue"]) ?? 0
            if step > 0 || kcal > 0 {
                dailySteps[date, default: 0] += step
                dailyKcal[date, default: 0] += kcal
                dailyDistance[date, default: 0] += dist
                if dailySteps[date]! > 0 {
                    bag.putIfAbsent(HealthRecords.stepCount, [
                        "value": dailySteps[date]!, "distance": HealthRecords.round2(dailyDistance[date]!),
                        "source": HealthRecords.offline, "time": time,
                    ])
                }
                if dailyKcal[date]! > 0 {
                    bag.putIfAbsent(HealthRecords.calorie, [
                        "value": HealthRecords.round2(dailyKcal[date]!), "source": HealthRecords.offline, "time": time,
                    ])
                }
            }
        }
    }

    private func addCurrentSteps(_ dict: [AnyHashable: Any]?) {
        guard let dict = dict else { return }
        let time = HealthRecords.now()
        if let step = HealthRecords.int(dict["Step"]), step > 0 {
            var record: [String: Any] = ["value": step, "source": HealthRecords.online, "time": time]
            if let dis = HealthRecords.double(dict["Dis"]) { record["distance"] = HealthRecords.round2(dis) }
            if let b = batteryPercent { record["battery_level"] = b }
            bag.put(HealthRecords.stepCount, record)
        }
        if let cal = HealthRecords.double(dict["Cal"]), cal > 0 {
            var record: [String: Any] = ["value": HealthRecords.round2(cal), "source": HealthRecords.online, "time": time]
            if let b = batteryPercent { record["battery_level"] = b }
            bag.put(HealthRecords.calorie, record)
        }
    }

    private func queryBlood(_ date: String) {
        let list = VPDataBaseOperation.veepooSDKGetBloodData(withDate: date, andTableID: tableId) as? [[String: Any]] ?? []
        for item in list {
            guard let clock = item["Time"] as? String, let time = HealthRecords.time(date: date, clock: clock) else { continue }
            let sbp = HealthRecords.int(item["systolic"]) ?? 0
            let dbp = HealthRecords.int(item["diastolic"]) ?? 0
            guard sbp > 0, dbp > 0 else { continue }
            let manual = (item["isManual"] as? String) == "Y"
            bag.put(HealthRecords.bloodPressure, [
                "sbp": sbp, "dbp": dbp, "source": manual ? HealthRecords.online : HealthRecords.offline, "time": time,
            ])
        }
    }

    private func queryOxygen(_ date: String) {
        let list = VPDataBaseOperation.veepooSDKGetDeviceOxygenData(withDate: date, andTableID: tableId) as? [[String: Any]] ?? []
        for item in list {
            guard let clock = item["Time"] as? String, let time = HealthRecords.time(date: date, clock: clock) else { continue }
            if let value = HealthRecords.int(item["OxygenValue"]), (50...100).contains(value) {
                var record: [String: Any] = ["value": value, "source": HealthRecords.offline, "time": time]
                let extras = ["apnea_result": "ApneaResult", "is_hypoxia": "IsHypoxia", "hypoxia_time": "HypoxiaTime",
                              "hypopnea": "Hypopnea", "cardiac_load": "CardiacLoad", "hr_variation": "HRV"]
                for (field, key) in extras {
                    if let v = HealthRecords.int(item[key]) { record[field] = v }
                }
                bag.put(HealthRecords.spo2, record)
            }
            if let rate = HealthRecords.int(item["RespirationRate"]), rate > 0 {
                bag.put(HealthRecords.respiratory, ["value": rate, "time": time])
            }
        }
    }

    private func queryHrv(_ date: String) {
        let list = VPDataBaseOperation.veepooSDKGetDeviceHrvData(withDate: date, andTableID: tableId) as? [[String: Any]] ?? []
        for item in list {
            guard let clock = item["time"] as? String, let time = HealthRecords.time(date: date, clock: clock),
                  let value = HealthRecords.int(item["hrvValue"]), value > 0 else { continue }
            // "hearts" = RR intervals / 10 → bpm = 60000 / RR
            var bpm = 0
            if let rr = (item["hearts"] as? [Any])?.compactMap({ HealthRecords.double($0) }).filter({ $0 > 0 }), !rr.isEmpty {
                let avgRr = rr.reduce(0, +) / Double(rr.count) * 10
                if avgRr > 0 { bpm = Int(60_000 / avgRr) }
            }
            bag.put(HealthRecords.hrv, ["value": value, "bpm": bpm, "hrv_type": 1, "time": time])
        }
    }

    private func queryTemperature(_ date: String) {
        let list = VPDataBaseOperation.veepooSDKGetDeviceTemperatureData(withDate: date, andTableID: tableId) as? [[String: Any]] ?? []
        for item in list {
            guard let h = HealthRecords.int(item["hour"]), let m = HealthRecords.int(item["minute"]),
                  let value = HealthRecords.double(item["value"]), value > 0 else { continue }
            let time = String(format: "%@ %02d:%02d:00", date, h, m)
            var record: [String: Any] = ["value": HealthRecords.round2(value), "source": HealthRecords.offline, "time": time]
            // Skin temperature key is undocumented ("…riginalValue…").
            if let key = item.keys.first(where: { $0.lowercased().contains("riginal") }),
               let base = HealthRecords.double(item[key]), base > 0 {
                record["base_temp"] = HealthRecords.round2(base)
            }
            bag.put(HealthRecords.bodyTemp, record)
        }
    }

    private func queryGlucose(_ date: String) {
        let list = VPDataBaseOperation.veepooSDKGetDeviceBloodGlucoseData(withDate: date, andTableID: tableId) as? [[String: Any]] ?? []
        let levels = ["", "low", "middle", "high"]
        for item in list {
            guard let clock = item["time"] as? String, let time = HealthRecords.time(date: date, clock: clock) else { continue }
            let values = (item["bloodGlucoses"] as? [Any])?.compactMap { HealthRecords.double($0) }.filter { $0 > 0 } ?? []
            guard !values.isEmpty else { continue }
            var record: [String: Any] = [
                "value": HealthRecords.round2(values.reduce(0, +) / Double(values.count)),
                "source": HealthRecords.offline, "time": time,
            ]
            if let level = HealthRecords.int((item["bloodGlucoseLevels"] as? [Any])?.first), level > 0, level < levels.count {
                record["risk_level"] = levels[level]
            }
            bag.put(HealthRecords.bloodGlucose, record)
        }
    }

    /// Precise sleep curve → one digit per minute (0 deep, 1 light, 2 REM,
    /// 3 insomnia, 4 awake). Newer firmware writes a hex string, 4 chars
    /// (16 bits) per minute with state = value >> 13; older ones already write
    /// 1 char per minute. Both platforms send this same format.
    static func preciseLine(_ line: String, minutes: Int) -> String {
        let chars = Array(line)
        guard minutes > 0, chars.count >= minutes * 2 else { return line }
        let step = chars.count / minutes
        return String(stride(from: 0, through: chars.count - step, by: step).map { i -> Character in
            let state = (chars[i].hexDigitValue ?? 0) >> 1
            return Character(String(min(state, 4)))
        })
    }

    /// One precise sleep segment as stored by the watch.
    private struct SleepSegment {
        let start: Date
        let end: Date
        let date: String
        let model: VPAccurateSleepModel
        let line: String // 1 digit per minute
        var linksPrevious: Bool { HealthRecords.int(model.lastType) == 1 }
        /// 255 = the watch does not know yet (night still going on).
        var linksNext: Bool { HealthRecords.int(model.nextType) == 1 }
    }

    /// Precise segments of every queried date, joined into nights by [flushSleepNights].
    private var sleepSegments: [SleepSegment] = []

    private func querySleep(_ date: String) {
        if (model?.sleepType ?? 0) == 1 {
            for s in VPDataBaseOperation.veepooSDKGetAccurateSleepData(withDate: date, andTableID: tableId) ?? [] {
                guard let start = HealthRecords.parse(s.sleepTime), let end = HealthRecords.parse(s.wakeTime),
                      HealthSync.saneSleep(start, end) else { continue }
                let minutes = Int(end.timeIntervalSince(start) / 60)
                sleepSegments.append(SleepSegment(start: start, end: end, date: date, model: s,
                                                  line: HealthSync.preciseLine(s.sleepLine ?? "", minutes: minutes)))
            }
            return
        }
        let list = VPDataBaseOperation.veepooSDKGetSleepData(withDate: date, andTableID: tableId) as? [[String: Any]] ?? []
        for item in list {
            guard let start = HealthRecords.parse(item["SLEEP_TIME"] as? String),
                  let end = HealthRecords.parse(item["WAKE_TIME"] as? String),
                  HealthSync.saneSleep(start, end) else { continue }
            let deep = Int(((HealthRecords.double(item["DEEP_HOUR"]) ?? 0) * 60).rounded())
            let light = Int(((HealthRecords.double(item["LIGHT_HOUR"]) ?? 0) * 60).rounded())
            let total = (HealthRecords.int(item["SLE_HOUR"]) ?? 0) * 60 + (HealthRecords.int(item["SLE_MINUTE"]) ?? 0)
            let line = item["SLE_LINE"] as? String ?? ""
            let record: [String: Any] = [
                "allSleep": total > 0 ? total : deep + light,
                "deepSleep": deep,
                "lightSleep": light,
                "rem": 0,
                // Normal curve: 1 char = 5 minutes; 2 = awake.
                "awakeShort": line.filter { $0 == "2" }.count * 5,
                "startTime": Int64(start.timeIntervalSince1970 * 1000),
                "endTime": Int64(end.timeIntervalSince1970 * 1000),
                "sleep_date": date,
                "sleep_quality": HealthRecords.int(item["SLEEP_LEVEL"]) ?? 0,
                "wake_count": HealthRecords.int(item["WakeUpTime"]) ?? 0,
                "sleep_line": line,
            ]
            if (record["allSleep"] as? Int ?? 0) > 0 {
                bag.put(HealthRecords.sleep, record, key: String(describing: record["startTime"]!))
            }
        }
    }

    /// Drops corrupt segments (e.g. year 2039, months long): end after start,
    /// at most 24 h, not in the future.
    static func saneSleep(_ start: Date, _ end: Date) -> Bool {
        end > start && end.timeIntervalSince(start) <= 24 * 3600 && start <= Date().addingTimeInterval(3600)
    }

    /// Joins linked segments (lastType / nextType) into one record per night:
    /// start of the first, end of the last, curve joined (gaps = awake),
    /// durations for the whole night, scores and other values of the last.
    private func flushSleepNights() {
        var seen = Set<Date>()
        let segments = sleepSegments.sorted { $0.start < $1.start }.filter { seen.insert($0.start).inserted }
        sleepSegments.removeAll()
        var night: [SleepSegment] = []
        for segment in segments {
            if let previous = night.last, previous.linksNext || segment.linksPrevious, segment.start >= previous.end {
                night.append(segment)
            } else {
                if !night.isEmpty { addSleepNight(night) }
                night = [segment]
            }
        }
        if !night.isEmpty { addSleepNight(night) }
    }

    private func addSleepNight(_ night: [SleepSegment]) {
        guard let first = night.first, let last = night.last else { return }
        var line = first.line
        for (previous, segment) in zip(night, night.dropFirst()) {
            let gap = Int(segment.start.timeIntervalSince(previous.end) / 60)
            if gap > 0 { line += String(repeating: "4", count: gap) }
            line += segment.line
        }
        let m = last.model
        func sum(_ value: (VPAccurateSleepModel) -> String?) -> Int {
            night.reduce(0) { $0 + (HealthRecords.int(value($1.model)) ?? 0) }
        }
        // Some firmwares put the whole night's totals in the last segment
        // (longer than that segment itself); otherwise add the segments up.
        let lastSpan = Int(last.end.timeIntervalSince(last.start) / 60)
        let cumulative = night.count > 1 && (HealthRecords.int(m.sleepDuration) ?? 0) > lastSpan + 1
        func total(_ value: @escaping (VPAccurateSleepModel) -> String?) -> Int {
            cumulative ? (HealthRecords.int(value(m)) ?? 0) : sum(value)
        }
        let rem = line.filter { $0 == "2" }.count
        var record: [String: Any] = [
            "allSleep": total { $0.sleepDuration },
            "deepSleep": total { $0.deepDuration },
            "lightSleep": total { $0.lightDuration },
            "rem": rem,
            "awakeShort": total { $0.getUpDuration },
            "startTime": Int64(first.start.timeIntervalSince1970 * 1000),
            "endTime": Int64(last.end.timeIntervalSince1970 * 1000),
            "sleep_date": last.date,
            "sleep_line": line,
            "segments": night.count,
        ]
        let ints: [(String, String?)] = [
            ("sleep_quality", m.sleepQuality), ("wake_count", m.getUpTimes),
            ("fall_asleep_score", m.fallAsleepScore), ("deep_score", m.deepScore),
            ("sleep_efficiency_score", m.sleepEfficiencyScore), ("sleep_time_score", m.sleepTimeScore),
            ("getup_score", m.getUpScore), ("insomnia_score", m.insomniaScore),
            ("insomnia_times", m.insomniaTimes), ("insomnia_length", m.insomniaDuration),
        ]
        for (field, value) in ints {
            if let v = HealthRecords.int(value) { record[field] = v }
        }
        // TODO(after a real multi-segment night): confirm which of sum / last
        // matches the watch, then drop the `cumulative` guess.
        NSLog("HBand sleep night %@ segments=%d cumulative=%d allSleep sum=%d last=%d rem(line)=%d otherDuration=%d",
              last.date, night.count, cumulative ? 1 : 0, sum { $0.sleepDuration },
              HealthRecords.int(m.sleepDuration) ?? 0, rem, total { $0.otherDuration })
        if (record["allSleep"] as? Int ?? 0) > 0 {
            bag.put(HealthRecords.sleep, record, key: String(describing: record["startTime"]!))
        }
    }

    private func queryOfflineEcg(_ date: String) {
        for ecg in VPDataBaseOperation.veepooSDKGetDeviceOffStoreECG(withDate: date, andTableID: tableId) ?? [] {
            if let record = HealthSync.ecgRecord(ecg, mode: "auto") { bag.put(HealthRecords.ecg, record) }
        }
    }

    /// Shared with live ECG measurement.
    static func ecgRecord(_ m: VPECGTestDataModel, mode: String) -> [String: Any]? {
        let wave = HealthRecords.intArray(m.filterSignals) ?? HealthRecords.intArray(m.originalSignals)
        let heart = HealthRecords.int(m.aveHeart) ?? 0
        guard heart > 0 || wave != nil else { return nil }
        let time = HealthRecords.parse(m.testTime).map(HealthRecords.format) ?? HealthRecords.now()
        var record: [String: Any] = ["mode": mode, "heart_rate": heart, "time": time]
        let ints: [(String, String?)] = [
            ("resp_rate", m.aveResRate), ("hrv", m.aveHrv), ("qt", m.aveQT), ("duration", m.duration),
            ("frequency", m.frequency), ("lead_sign", m.lead), ("pwv", m.avePWV),
        ]
        for (field, value) in ints {
            if let v = HealthRecords.int(value) { record[field] = v }
        }
        let results = [m.result1, m.result2, m.result3, m.result4, m.result5, m.result6, m.result7, m.result8]
        let result8 = results.compactMap { HealthRecords.int($0) }
        if result8.count == 8 { record["result8"] = result8 }
        if let wave = wave { record["wave"] = wave }
        return record
    }

    // MARK: RR interval (two bytes per value, little endian, ms)

    // RR interval: the watch makes one block per minute (1440 a day) and the
    // read can start at any block. Remember the last block read per watch and
    // day so each sync only transfers the new blocks.
    private static let rrBookmarkKey = "releep_hband_sync.rrBookmarks"
    private static let rrBlocksPerDay = 1440
    /// Bookmarks reached in this run, saved when the sync ends.
    private var rrPending: [String: Int] = [:]

    private func rrKey(_ date: String) -> String { "\(tableId)|\(date)" }

    private func readRrInterval(_ done: @escaping (String?) -> Void) {
        guard let peripheral = peripheral else { return done("not ready") }
        let dates = queryDates
        let saved = UserDefaults.standard.dictionary(forKey: HealthSync.rrBookmarkKey) as? [String: Int] ?? [:]
        func read(_ day: Int) {
            guard day < dates.count else { return done(nil) }
            let key = rrKey(dates[day])
            let last = saved[key] ?? 0
            // A past day that was read to its end cannot get new blocks.
            if last >= HealthSync.rrBlocksPerDay { return read(day + 1) }
            var maxBlock = last
            var dayDone = false
            peripheral.veepooSDK_readRRIntervalData(withDayNumber: day, blockNumber: last + 1) { [weak self] object, progress, error in
                DispatchQueue.main.async {
                    guard let self = self, !dayDone else { return }
                    if error != nil {
                        // Also reported when there is no new block yet: keep the bookmark.
                        dayDone = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { read(day + 1) }
                        return
                    }
                    if let rr = object as? VPRRIntervalDataModel {
                        self.addRr(rr)
                        maxBlock = max(maxBlock, rr.blockNumber)
                    }
                    let fraction = progress?.fractionCompleted ?? 0
                    self.progress("rrinterval", (Double(day) + fraction) / Double(dates.count))
                    if fraction >= 1 {
                        dayDone = true
                        self.rrPending[key] = day > 0 ? HealthSync.rrBlocksPerDay : maxBlock
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { read(day + 1) }
                    }
                }
            }
        }
        read(0)
    }

    /// RR bookmarks of the last sync, saved by [confirmUpload].
    private static var pendingRr: [String: Int] = [:]

    /// The app uploaded the last sync's records: remember how far RR interval
    /// was read so the next sync only reads new blocks; an unconfirmed run is
    /// read again. Main thread.
    static func confirmUpload() {
        let confirmed = pendingRr
        pendingRr = [:]
        guard !confirmed.isEmpty else { return }
        var saved = UserDefaults.standard.dictionary(forKey: rrBookmarkKey) as? [String: Int] ?? [:]
        saved.merge(confirmed) { max($0, $1) }
        let oldest = Calendar.current.date(byAdding: .day, value: -4, to: Date()) ?? Date()
        saved = saved.filter { key, _ in
            guard let date = key.split(separator: "|").last.flatMap({ HealthRecords.dateFormat.date(from: String($0)) }) else { return false }
            return date >= oldest
        }
        UserDefaults.standard.set(saved, forKey: rrBookmarkKey)
    }

    private func addRr(_ rr: VPRRIntervalDataModel) {
        guard let time = HealthRecords.time(date: rr.date, clock: rr.time) else { return }
        let bytes = [UInt8](rr.dataConvertStream)
        var values: [Int] = []
        var i = 0
        while i + 1 < bytes.count {
            let v = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            if v > 0 { values.append(v) }
            i += 2
        }
        guard !values.isEmpty else { return }
        bag.put(HealthRecords.rrInterval, ["rr_arry": Array(values.prefix(HealthRecords.maxArray)), "time": time])
    }

    // MARK: Sport sessions

    private func readSport(_ done: @escaping (String?) -> Void) {
        guard let peripheral = peripheral else { return done("not ready") }
        peripheral.readDeviceSportCRCArr { [weak self] success, crcs in
            guard success, let crcs = crcs, !crcs.isEmpty else { return done(success ? nil : "not supported") }
            peripheral.readDeviceSport(withCRC: crcs) { sports, gpsSports in
                DispatchQueue.main.async {
                    sports?.forEach { self?.addSport($0) }
                    gpsSports?.forEach { self?.addGpsSport($0) }
                    done(nil)
                }
            }
        }
    }

    private func addSport(_ s: VPDeviceSportModel) {
        guard let start = HealthRecords.parse(s.beginTime) else { return }
        let time = HealthRecords.format(start)
        guard s.totalStep > 0 || s.totalDis > 0 || s.totalCal > 0 || s.totalTime > 0 else { return }
        var record: [String: Any] = [
            "time": time,
            "sport_type": Int(s.type),
            "duration": Int(s.totalTime),
            "steps": Int(s.totalStep),
            "distance": HealthRecords.round2(Double(s.totalDis) / 1000), // m → km
            "calories": Int(s.totalCal), // kcal
            "avg_heartrate": Int(s.averHeart),
            "pause_count": Int(s.pauseCount),
            "pause_time": Int(s.pauseTotalTime),
            "sport_count": Int(s.totalSport),
        ]
        if s.averPace > 0 { record["pace"] = Int(s.averPace) }
        if let end = HealthRecords.parse(s.endTime), end >= start { record["end_time"] = HealthRecords.format(end) }
        bag.put(HealthRecords.sport, record)
    }

    private func addGpsSport(_ s: VPDeviceSportWithGPSModel) {
        guard s.startTimestamp > 0 else { return }
        let start = Date(timeIntervalSince1970: TimeInterval(s.startTimestamp))
        var record: [String: Any] = [
            "time": HealthRecords.format(start),
            "duration": Int(s.duration),
            "steps": Int(s.step),
            "distance": HealthRecords.round2(Double(s.dis) / 1000), // m → km
            "calories": HealthRecords.round2(Double(s.cal) / 1000), // cal → kcal
            "avg_heartrate": Int(s.aveHeart),
            "sport_count": Int(s.sport),
        ]
        if s.avePace > 0 { record["pace"] = Int(s.avePace) }
        if s.stopTimestamp >= s.startTimestamp {
            record["end_time"] = HealthRecords.format(Date(timeIntervalSince1970: TimeInterval(s.stopTimestamp)))
        }
        bag.put(HealthRecords.sport, record)
    }

    // MARK: Heart-rate alarm thresholds → warning events from synced HR

    private func readHeartWarning(_ done: @escaping (String?) -> Void) {
        guard let peripheral = peripheral else { return done("not ready") }
        peripheral.veepooSDKSettingDeviceHeartAlarm(with: VPDeviceHeartAlarmModel(), settingMode: 2, successResult: { [weak self] alarm in
            DispatchQueue.main.async {
                if let self = self, let alarm = alarm, alarm.isOpen, alarm.heartMaxValue > 0 {
                    let high = Int(alarm.heartMaxValue)
                    let low = Int(alarm.heartMinValue)
                    for hr in self.bag.records(HealthRecords.heartRate) {
                        guard let value = hr["value"] as? Int else { continue }
                        let type: String? = value > high ? "high" : (low > 0 && value < low ? "low" : nil)
                        guard let warning = type else { continue }
                        self.bag.put(HealthRecords.heartWarning, [
                            "value": value, "warning_type": warning, "heart_high": high, "heart_low": low,
                            "time": hr["time"] ?? HealthRecords.now(),
                        ])
                    }
                }
                done(nil)
            }
        }, failureResult: {
            done("read failed")
        })
    }
}
