import Foundation
import VeepooBleSDK

/// One manual ("online") measurement started from the app — same contract as Android.
///
/// Types: heartrate, bloodpressure, spo2, bodytemp, fatigue, bloodglucose, ecg, ptt, stress,
/// hrv, respiratory — records already in the backend `data[]` shape — plus bloodcomponent,
/// bodycomposition, gsr, met, emotion, checkup, which have no backend type yet (record is for
/// display). Live values go to `onUpdate`; `onDone` receives {success, type, record?, records?,
/// message?} exactly once. `records` (checkup only) = backend type → record per measured value.
final class HealthMeasure {
    // Measurement-only types (no backend `{type}` yet).
    static let bloodComponent = "bloodcomponent"
    static let bodyComposition = "bodycomposition"
    static let gsr = "gsr"
    static let met = "met"
    static let emotion = "emotion"
    static let checkup = "checkup"

    static let types = [HealthRecords.heartRate, HealthRecords.bloodPressure, HealthRecords.spo2,
                        HealthRecords.bodyTemp, HealthRecords.fatigue, HealthRecords.bloodGlucose, HealthRecords.ecg, "ptt",
                        HealthRecords.stress, HealthRecords.hrv, HealthRecords.respiratory,
                        bloodComponent, bodyComposition, gsr, met, emotion, checkup]

    /// Backend types that carry `source`.
    fileprivate static let withSource = [HealthRecords.heartRate, HealthRecords.bloodPressure, HealthRecords.spo2,
                                         HealthRecords.bodyTemp, HealthRecords.bloodGlucose]

    /// PTT has no final result event — capture this long, then build the record.
    private static let pttCapture: TimeInterval = 30

    /// Continuous measurements finish this long after the first valid value.
    private var settle: TimeInterval { type == HealthRecords.hrv ? 30 : 12 }

    let type: String
    private let peripheral: VPPeripheralBaseManage
    private let onUpdate: ([String: Any]) -> Void
    private let onDone: ([String: Any]) -> Void
    private var finished = false
    private var lastValue: Int?
    private var firstValueAt: Date?
    private var timeoutItem: DispatchWorkItem?
    private var glucoseCalibration: (open: Bool, value: Double)?
    private var pttWave: [Int] = []
    private var pttLast: VPPttValueModel?
    private var pttStartedAt: Date?

    // Temperature watches can briefly report "busy" while an automatic health
    // reading is finishing. They can also report the raw/skin value in an
    // earlier callback and omit it from the final (100%) callback.
    private static let temperatureMaxBusyRetries = 3
    private static let temperatureBusyRetryDelay: TimeInterval = 1.5
    private var temperatureBusyRetries = 0
    private var temperatureRetryItem: DispatchWorkItem?
    private var temperatureAttempt = 0
    private var lastTemperatureBase: Double?

    init(type: String, peripheral: VPPeripheralBaseManage,
         onUpdate: @escaping ([String: Any]) -> Void, onDone: @escaping ([String: Any]) -> Void) {
        self.type = type
        self.peripheral = peripheral
        self.onUpdate = onUpdate
        self.onDone = onDone
    }

    func start() {
        let timeout = DispatchWorkItem { [weak self] in self?.fail("Measurement timed out") }
        timeoutItem = timeout
        let seconds: TimeInterval
        switch type {
        case HealthMeasure.checkup: seconds = 180
        case HealthRecords.ecg, "ptt", HealthRecords.bloodGlucose, HealthMeasure.bloodComponent,
             HealthMeasure.bodyComposition, HealthMeasure.gsr: seconds = 120
        default: seconds = 90
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)

        switch type {
        case HealthRecords.heartRate:
            peripheral.veepooSDKTestHeartStart(true) { [weak self] state, value in
                DispatchQueue.main.async {
                    switch state.rawValue {
                    case 2: self?.fail("Watch is not worn correctly")
                    case 3: self?.fail("Watch is busy")
                    default:
                        if (30...250).contains(Int(value)) {
                            self?.continuous(Int(value)) { ["value": $0] }
                        } else {
                            self?.update(nil, nil)
                        }
                    }
                }
            }

        case HealthRecords.bloodPressure:
            peripheral.veepooSDKTestBloodStart(true, testMode: 0) { [weak self] state, progress, high, low in
                DispatchQueue.main.async {
                    switch state.rawValue {
                    case 1: self?.fail("Watch is busy")
                    case 2: self?.fail("Measurement failed — keep still and try again")
                    case 5: self?.fail("Blood pressure not supported")
                    case 4:
                        if high > 0 && low > 0 {
                            self?.succeed(["sbp": Int(high), "dbp": Int(low)])
                        } else {
                            self?.fail("Measurement failed")
                        }
                    default:
                        self?.update(Int(progress), high > 0 ? "\(high)/\(low)" : nil)
                    }
                }
            }

        case HealthRecords.spo2:
            peripheral.veepooSDKTestOxygenStart(true) { [weak self] state, value in
                DispatchQueue.main.async {
                    switch state.rawValue {
                    case 2: self?.fail("Watch is not worn correctly")
                    case 3: self?.fail("Watch is busy")
                    case 5: self?.fail("SpO2 not supported")
                    case 8: self?.fail("SpO2 temporarily unavailable")
                    case 6: self?.update(min(Int(value), 99), nil) // calibrating: value = progress
                    default:
                        if (70...100).contains(Int(value)) {
                            self?.continuous(Int(value)) { ["value": $0] }
                        } else {
                            self?.update(nil, nil)
                        }
                    }
                }
            }

        case HealthRecords.bodyTemp:
            startTemperature()

        case HealthRecords.fatigue:
            peripheral.veepooSDKTestFatigueStart(true) { [weak self] state, progress, value in
                DispatchQueue.main.async {
                    switch state.rawValue {
                    case 1: self?.fail("Watch is busy")
                    case 2: self?.fail("Measurement failed")
                    case 5: self?.fail("Fatigue measurement not supported")
                    case 4:
                        if value > 0 {
                            self?.succeed(["value": Int(value), "status": HealthRecords.fatigueStatus(Int(value))])
                        } else {
                            self?.fail("Measurement failed")
                        }
                    default:
                        self?.update(Int(progress), value > 0 ? Int(value) : nil)
                    }
                }
            }

        case HealthRecords.stress:
            peripheral.veepooSDK_stressTestStart(true) { [weak self] state, progress, value in
                DispatchQueue.main.async {
                    switch state {
                    case .noFunction: self?.fail("Stress measurement not supported")
                    case .deviceBusy: self?.fail("Watch is busy")
                    case .lowPower: self?.fail("Watch battery is low")
                    case .notWear: self?.fail("Watch is not worn correctly")
                    case .over: self?.fail("Stopped")
                    case .complete where progress >= 100 || value > 0:
                        if value > 0 {
                            self?.succeed(["value": Int(value), "status": HealthRecords.stressStatus(Int(value))])
                        } else {
                            self?.fail("Measurement failed")
                        }
                    default:
                        self?.update(Int(progress), nil)
                    }
                }
            }

        case HealthRecords.bloodGlucose:
            // Read the personal calibration first (optional fields), then measure.
            peripheral.veepooSDKBloodGlucosePersonal(withOpCode: 2, value: 0, open: false) { [weak self] success, value, model in
                DispatchQueue.main.async {
                    if success { self?.glucoseCalibration = (model == 1, Double(value)) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self, !self.finished else { return }
                self.peripheral.veepooSDKTestBloodGlucoseStart(true, isPersonalModel: false) { [weak self] state, progress, value, level in
                    DispatchQueue.main.async {
                        switch state.rawValue {
                        case 0: self?.fail("Blood glucose not supported")
                        case 3: self?.fail("Watch battery is low")
                        case 4: self?.fail("Watch is busy")
                        case 5: self?.fail("Watch is not worn correctly")
                        default:
                            // Reported ×100 (mmol/L).
                            let mmol = Double(value) / 100
                            self?.update(Int(progress), mmol > 0 ? mmol : nil)
                            if progress >= 100 && mmol > 0 {
                                var record: [String: Any] = ["value": HealthRecords.round2(mmol)]
                                let levels = ["", "low", "middle", "high"]
                                if level > 0 && Int(level) < levels.count { record["risk_level"] = levels[Int(level)] }
                                if let cal = self?.glucoseCalibration {
                                    record["calibration_open"] = cal.open
                                    if cal.value > 0 { record["calibration_value"] = HealthRecords.round2(cal.value) }
                                }
                                self?.succeed(record)
                            }
                        }
                    }
                }
            }

        case HealthRecords.ecg:
            peripheral.veepooSDKTestECGStart(true) { [weak self] state, progress, model in
                DispatchQueue.main.async {
                    switch state.rawValue {
                    case 2: self?.update(Int(progress), nil) // lead off — keep fingers on the electrode
                    case 3: self?.fail("Watch is busy")
                    case 5: self?.fail("ECG measurement failed")
                    case 7: self?.fail("ECG not supported")
                    case 6:
                        if let model = model, let record = HealthSync.ecgRecord(model, mode: "manual") {
                            self?.succeed(record.filter { $0.key != "time" })
                        } else {
                            self?.fail("ECG result was empty")
                        }
                    default:
                        self?.update(Int(progress), HealthRecords.int(model?.aveHeart))
                    }
                }
            }

        case "ptt":
            // The watch must be in PTT mode (started on the watch).
            peripheral.veepooSDKPTTTest(true, valueBlock: { [weak self] value in
                DispatchQueue.main.async { self?.onPtt(value: value) }
            }, signal: { [weak self] signals in
                DispatchQueue.main.async { self?.onPtt(signals: signals) }
            })

        case HealthRecords.hrv:
            // Continuous — the watch never stops it by itself.
            peripheral.veepooSDK_HRVTest(true) { [weak self] con, ack, value in
                DispatchQueue.main.async {
                    switch ack {
                    case .testing:
                        if con == 1 && value > 0 {
                            self?.continuous(Int(value)) { ["value": $0] }
                        } else {
                            self?.update(nil, nil)
                        }
                    case .lowPower: self?.fail("Watch battery is low")
                    case .notWear: self?.fail("Watch is not worn correctly")
                    default: self?.fail("Watch is busy")
                    }
                }
            }

        case HealthRecords.respiratory:
            peripheral.veepooSDKTestBreathingRateStart(true) { [weak self] state, progress, value in
                DispatchQueue.main.async {
                    switch state {
                    case .notWear: self?.fail("Watch is not worn correctly")
                    case .deviceBusy: self?.fail("Watch is busy")
                    case .over: self?.fail("Stopped")
                    case .failure: self?.fail("Measurement failed")
                    case .noFunction: self?.fail("Respiratory rate not supported")
                    case .complete:
                        if value > 0 {
                            self?.succeed(["value": Int(value)])
                        } else {
                            self?.fail("Measurement failed")
                        }
                    default:
                        self?.update(Int(progress), nil)
                    }
                }
            }

        case HealthMeasure.bloodComponent:
            peripheral.veepooSDKTestBloodAnalysisStart(true, isPersonalModel: false, progress: { [weak self] progress in
                DispatchQueue.main.async { self?.update(HealthMeasure.percent(progress), nil) }
            }, testResult: { [weak self] state, model in
                DispatchQueue.main.async {
                    switch state {
                    case .noFunction: self?.fail("Blood component not supported")
                    case .deviceBusy: self?.fail("Watch is busy")
                    case .over: self?.fail("Stopped")
                    case .lowPower: self?.fail("Watch battery is low")
                    case .notWear: self?.fail("Watch is not worn correctly")
                    case .complete:
                        if let m = model {
                            self?.succeed(HealthMeasure.bloodComponentMap(
                                uricAcid: m.uricAcidValue, tcho: m.totalCholesterolValue, tag: m.triglycerideValue,
                                hdl: m.highDensityLipoproteinValue, ldl: m.lowDensityLipoproteinValue))
                        } else {
                            self?.fail("Measurement failed")
                        }
                    default: self?.fail("Measurement failed")
                    }
                }
            })

        case HealthMeasure.bodyComposition:
            // lead 0 = fingers on the electrodes.
            peripheral.veepooSDKTestBodyCompositionStart(true, progress: { [weak self] lead, progress in
                DispatchQueue.main.async {
                    self?.update(HealthMeasure.percent(progress), nil, extra: ["leadOff": lead != 0])
                }
            }, testResult: { [weak self] state, model in
                DispatchQueue.main.async {
                    switch state {
                    case .noFunction: self?.fail("Body composition not supported")
                    case .deviceBusy: self?.fail("Watch is busy")
                    case .over: self?.fail("Stopped")
                    case .lowPower: self?.fail("Watch battery is low")
                    case .complete:
                        if let m = model {
                            let d = { (s: String?) in Double(s ?? "") ?? 0 }
                            self?.succeed(HealthMeasure.bodyCompositionMap([
                                d(m.bmi), d(m.bodyFatPercentage), d(m.fatMass), d(m.leanBodyMass), d(m.muscleRate),
                                d(m.muscleMass), d(m.subcutaneousFat), d(m.bodyMoisture), d(m.waterContent),
                                d(m.skeletalMuscleRate), d(m.boneMass), d(m.proportionOfProtein), d(m.proteinAmount),
                                d(m.basalMetabolicRate),
                            ]))
                        } else {
                            self?.fail("Measurement failed")
                        }
                    default: self?.fail("Measurement failed")
                    }
                }
            })

        case HealthMeasure.gsr:
            peripheral.veepooSDKTestGSRStart(true, progress: { [weak self] progress in
                DispatchQueue.main.async { self?.update(HealthMeasure.percent(progress), nil) }
            }, testResult: { [weak self] state, model in
                DispatchQueue.main.async {
                    switch state {
                    case .noFunction: self?.fail("GSR not supported")
                    case .deviceBusy: self?.fail("Watch is busy")
                    case .over: self?.fail("Stopped")
                    case .lowPower: self?.fail("Watch battery is low")
                    case .notWear: self?.fail("Watch is not worn correctly")
                    case .complete:
                        if let m = model {
                            self?.succeed(HealthMeasure.gsrMap(
                                emotion: Int(m.emotin_level), skinMoisture: Int(m.skin_moisture),
                                depressionRisk: Int(m.depression_risk), sns: Int(m.sns_activation),
                                cortisol: Int(m.cortisol_value)))
                        } else {
                            self?.fail("Measurement failed")
                        }
                    default: self?.fail("Measurement failed")
                    }
                }
            })

        case HealthMeasure.met:
            peripheral.veepooSDK_metTest(true) { [weak self] con, ack, progress, value in
                DispatchQueue.main.async {
                    switch ack {
                    case .testing:
                        guard con == 1 else { return }
                        // Reported ×10.
                        let met = HealthRecords.round2(Double(value) / 10)
                        self?.update(Int(progress), met > 0 ? met : nil)
                        if progress >= 100 {
                            if met > 0 { self?.succeed(["value": met]) } else { self?.fail("Measurement failed") }
                        }
                    case .lowPower: self?.fail("Watch battery is low")
                    case .notWear: self?.fail("Watch is not worn correctly")
                    default: self?.fail("Watch is busy")
                    }
                }
            }

        case HealthMeasure.emotion:
            // 0 is a valid emotion value.
            peripheral.veepooSDK_emotionTest(true) { [weak self] con, ack, progress, value in
                DispatchQueue.main.async {
                    switch ack {
                    case .testing:
                        guard con == 1 else { return }
                        self?.update(Int(progress), progress >= 100 ? Int(value) : nil)
                        if progress >= 100 { self?.succeed(["value": Int(value)]) }
                    case .lowPower: self?.fail("Watch battery is low")
                    case .notWear: self?.fail("Watch is not worn correctly")
                    default: self?.fail("Watch is busy")
                    }
                }
            }

        case HealthMeasure.checkup:
            peripheral.veepooSDK_healthGlanceTestStart(true, andProgress: { [weak self] progress in
                DispatchQueue.main.async { self?.update(Int(progress), nil) }
            }, andResult: { [weak self] state, model in
                DispatchQueue.main.async {
                    switch state {
                    case .noFunction: self?.fail("Checkup not supported")
                    case .deviceBusy: self?.fail("Watch is busy")
                    case .over: self?.fail("Stopped")
                    case .lowPower: self?.fail("Watch battery is low")
                    case .notWear: self?.fail("Watch is not worn correctly")
                    case .notLead: self?.fail("Keep your finger on the electrode")
                    case .complete:
                        if let m = model { self?.finishCheckup(m) } else { self?.fail("Measurement failed") }
                    default: self?.fail("Measurement failed")
                    }
                }
            })

        default:
            fail("Unsupported measurement type: \(type)")
        }
    }

    // MARK: - Checkup

    private func finishCheckup(_ m: VPHealthGlanceTestModel) {
        let has = { (bit: Int) in m.functionSupport & (1 << bit) != 0 }
        let c = CheckupBuilder()
        if has(0) { c.heartRate(Int(m.heartRate)) }
        if has(1) { c.spo2(Int(m.bloodOxygen)) }
        if has(3) { c.bloodPressure(Int(m.cuffBloodPressureHigh), Int(m.cuffBloodPressureLow), key: "blood_pressure_cuff") }
        if has(2) {
            let sbp = m.ppgBloodPressureHigh > 0 ? m.ppgBloodPressureHigh : m.systolicBloodPressure
            let dbp = m.ppgBloodPressureLow > 0 ? m.ppgBloodPressureLow : m.diastolicBloodPressure
            c.bloodPressure(Int(sbp), Int(dbp), key: "blood_pressure")
        }
        if has(4) && m.bloodSugarType != 0 { c.bloodGlucose(m.bloodSugar) }
        if has(5) { c.bodyTemp(m.bodyTemperature, base: m.orgTemperature) }
        if has(6) { c.stress(Int(m.stress)) }
        if has(7) { c.values["emotion"] = m.emotionLevel }
        if has(8) { c.fatigue(Int(m.fatigueLevel)) }
        if has(9) { c.hrv(Int(m.hrv)) }
        if has(10) {
            c.values[HealthMeasure.gsr] = HealthMeasure.gsrMap(
                emotion: m.emotionLevel, skinMoisture: Int(m.skinMoisture), depressionRisk: Int(m.depressionRisk),
                sns: Int(m.snsActivation), cortisol: Int(m.cortisolValue))
        }
        if has(11) {
            c.values[HealthMeasure.bloodComponent] = HealthMeasure.bloodComponentMap(
                uricAcid: m.uricAcid, tcho: m.totalCholesterol, tag: m.triglyceride,
                hdl: m.highDensityLipoprotein, ldl: m.lowDensityLipoprotein)
        }
        if has(12) {
            c.values[HealthMeasure.bodyComposition] = HealthMeasure.bodyCompositionMap([
                m.bmi, m.bodyFatPercentage, m.fatMass, m.leanBodyMass, m.muscleRate, m.muscleMass, m.subcutaneousFat,
                m.bodyMoisture, m.waterContent, m.skeletalMuscleRate, m.boneMass, m.proportionOfProtein,
                m.proteinAmount, m.basalMetabolicRate,
            ])
        }
        succeed(c.values, records: c.records)
    }

    /// Collects checkup values (flat, for display) and per-backend-type records.
    private final class CheckupBuilder {
        var values: [String: Any] = [:]
        var records: [String: [String: Any]] = [:]
        private let time = HealthRecords.now()

        private func record(_ type: String, _ fields: [String: Any]) {
            var r = fields
            if HealthMeasure.withSource.contains(type) { r["source"] = HealthRecords.online }
            r["time"] = time
            records[type] = r
        }

        func heartRate(_ v: Int) {
            guard (30...250).contains(v) else { return }
            values["heart_rate"] = v
            record(HealthRecords.heartRate, ["value": v])
        }

        func spo2(_ v: Int) {
            guard (70...100).contains(v) else { return }
            values["spo2"] = v
            record(HealthRecords.spo2, ["value": v])
        }

        /// Cuff (air pump) pressure wins over photoelectric for the backend record.
        func bloodPressure(_ sbp: Int, _ dbp: Int, key: String) {
            guard sbp > 0, dbp > 0 else { return }
            values[key] = ["sbp": sbp, "dbp": dbp]
            if key == "blood_pressure_cuff" || records[HealthRecords.bloodPressure] == nil {
                record(HealthRecords.bloodPressure, ["sbp": sbp, "dbp": dbp])
            }
        }

        func bloodGlucose(_ v: Double) {
            guard v > 0 else { return }
            values["blood_glucose"] = HealthRecords.round2(v)
            record(HealthRecords.bloodGlucose, ["value": HealthRecords.round2(v)])
        }

        func bodyTemp(_ v: Double, base: Double) {
            guard v > 0 else { return }
            values["body_temp"] = HealthRecords.round2(v)
            var fields: [String: Any] = ["value": HealthRecords.round2(v)]
            if base > 0 { fields["base_temp"] = HealthRecords.round2(base) }
            record(HealthRecords.bodyTemp, fields)
        }

        func stress(_ v: Int) {
            guard (1...100).contains(v) else { return }
            values["stress"] = v
            record(HealthRecords.stress, ["value": v, "status": HealthRecords.stressStatus(v)])
        }

        func fatigue(_ v: Int) {
            guard v > 0 else { return }
            values["fatigue"] = v
            record(HealthRecords.fatigue, ["value": v, "status": HealthRecords.fatigueStatus(v)])
        }

        func hrv(_ v: Int) {
            guard v > 0 else { return }
            values["hrv"] = v
            record(HealthRecords.hrv, ["value": v])
        }
    }

    private static func percent(_ progress: Progress?) -> Int? {
        guard let p = progress, p.totalUnitCount > 0 else { return nil }
        return Int(p.fractionCompleted * 100)
    }

    fileprivate static func bloodComponentMap(uricAcid: Double, tcho: Double, tag: Double, hdl: Double, ldl: Double) -> [String: Any] {
        ["uric_acid": HealthRecords.round2(uricAcid), "total_cholesterol": HealthRecords.round2(tcho),
         "triglyceride": HealthRecords.round2(tag), "hdl": HealthRecords.round2(hdl), "ldl": HealthRecords.round2(ldl)]
    }

    private static let bodyCompositionKeys = [
        "bmi", "body_fat_rate", "fat_mass", "lean_body_mass", "muscle_rate", "muscle_mass", "subcutaneous_fat",
        "body_water", "water_content", "skeletal_muscle_rate", "bone_mass", "protein_rate", "protein_mass",
        "basal_metabolic_rate",
    ]

    /// [values] in [bodyCompositionKeys] order.
    fileprivate static func bodyCompositionMap(_ values: [Double]) -> [String: Any] {
        var map: [String: Any] = [:]
        for (key, value) in zip(bodyCompositionKeys, values) { map[key] = HealthRecords.round2(value) }
        return map
    }

    /// depressionRisk 0 low · 1 medium · 2 high.
    fileprivate static func gsrMap(emotion: Int, skinMoisture: Int, depressionRisk: Int, sns: Int, cortisol: Int) -> [String: Any] {
        let risks = ["low", "medium", "high"]
        return ["emotion_level": emotion, "skin_moisture": skinMoisture,
                "depression_risk": risks.indices.contains(depressionRisk) ? risks[depressionRisk] : "unknown",
                "sns_activation": sns, "cortisol": cortisol]
    }

    private func onPtt(value: VPPttValueModel? = nil, signals: [NSNumber]? = nil) {
        guard !finished else { return }
        if pttStartedAt == nil { pttStartedAt = Date() }
        if let value = value { pttLast = value }
        if let signals = signals {
            let remaining = HealthRecords.maxArray - pttWave.count
            if remaining > 0 { pttWave.append(contentsOf: signals.prefix(remaining).map { $0.intValue }) }
            onUpdate(["kind": "measure", "type": type, "samples": signals.map { $0.intValue }])
        }
        let elapsed = Date().timeIntervalSince(pttStartedAt!)
        update(min(Int(elapsed / HealthMeasure.pttCapture * 100), 99), pttLast.map { Int($0.heart) })
        if elapsed >= HealthMeasure.pttCapture { finishPtt() }
    }

    private func finishPtt() {
        guard let last = pttLast, last.heart > 0 || !pttWave.isEmpty else { return fail("No PTT data — start PTT mode on the watch") }
        var record: [String: Any] = [
            "mode": "ptt", "heart_rate": Int(last.heart), "hrv": Int(last.hrv), "qt": Int(last.qt),
            "duration": Int(Date().timeIntervalSince(pttStartedAt ?? Date())),
        ]
        if last.frequency > 0 { record["frequency"] = Int(last.frequency) }
        if !pttWave.isEmpty { record["wave"] = pttWave }
        succeed(record)
    }

    /// User cancelled — stop the watch, report as not successful.
    func stop() { fail("Stopped") }

    // MARK: - Temperature

    private func startTemperature() {
        guard !finished else { return }
        temperatureRetryItem = nil
        temperatureAttempt += 1
        let attempt = temperatureAttempt
        peripheral.veepooSDK_temperatureTestStart(true) { [weak self] state, enable, progress, temp, original in
            DispatchQueue.main.async {
                // Ignore late callbacks from an attempt that was already retried.
                guard let self = self, !self.finished, attempt == self.temperatureAttempt else { return }
                // Values are reported ×10 (°C).
                if original > 0 { self.lastTemperatureBase = HealthRecords.round2(Double(original) / 10) }
                switch state.rawValue {
                case 0: self.fail("Temperature measurement not supported")
                case 9: self.fail("Watch is not worn correctly")
                default:
                    if !enable { return self.retryTemperatureAfterBusy() }
                    let value = Double(temp) / 10
                    var extra: [String: Any] = [:]
                    if let base = self.lastTemperatureBase { extra["base_temp"] = base }
                    self.update(progress, value > 0 ? value : nil, extra: extra)
                    if progress >= 100 && value > 0 {
                        var record: [String: Any] = ["value": HealthRecords.round2(value)]
                        if let base = self.lastTemperatureBase { record["base_temp"] = base }
                        self.succeed(record)
                    }
                }
            }
        }
    }

    private func retryTemperatureAfterBusy() {
        guard !finished, temperatureRetryItem == nil else { return }
        guard temperatureBusyRetries < HealthMeasure.temperatureMaxBusyRetries else {
            return fail("Watch is busy")
        }
        temperatureBusyRetries += 1
        update(nil, nil)
        let item = DispatchWorkItem { [weak self] in self?.startTemperature() }
        temperatureRetryItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + HealthMeasure.temperatureBusyRetryDelay, execute: item)
    }

    // MARK: - Helpers

    private func continuous(_ value: Int, build: (Int) -> [String: Any]) {
        lastValue = value
        if firstValueAt == nil { firstValueAt = Date() }
        let elapsed = Date().timeIntervalSince(firstValueAt!)
        update(min(Int(elapsed / settle * 100), 99), value)
        if elapsed >= settle { succeed(build(value)) }
    }

    private func update(_ progress: Int?, _ value: Any?, extra: [String: Any] = [:]) {
        guard !finished else { return }
        var event: [String: Any] = ["kind": "measure", "type": type]
        if let p = progress { event["progress"] = max(0, min(p, 100)) }
        if let v = value { event["value"] = v }
        event.merge(extra) { $1 }
        onUpdate(event)
    }

    private func succeed(_ values: [String: Any], records: [String: [String: Any]]? = nil) {
        guard !finished else { return }
        var record = values
        if HealthMeasure.withSource.contains(type) { record["source"] = HealthRecords.online }
        record["time"] = HealthRecords.now()
        var result: [String: Any] = ["success": true, "type": type == "ptt" ? HealthRecords.ecg : type, "record": record]
        if let records = records { result["records"] = records }
        finish(result)
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        // A continuous measurement stopped by the user still has a value.
        if message == "Stopped", let value = lastValue,
           [HealthRecords.heartRate, HealthRecords.spo2, HealthRecords.hrv].contains(type) {
            return succeed(["value": value])
        }
        // Stopping PTT early still keeps what was captured.
        if message == "Stopped", type == "ptt", pttLast != nil || !pttWave.isEmpty {
            return finishPtt()
        }
        finish(["success": false, "type": type == "ptt" ? HealthRecords.ecg : type, "message": message])
    }

    private func finish(_ result: [String: Any]) {
        finished = true
        timeoutItem?.cancel()
        temperatureRetryItem?.cancel()
        stopDevice()
        onDone(result)
    }

    private func stopDevice() {
        switch type {
        case HealthRecords.heartRate: peripheral.veepooSDKTestHeartStart(false) { _, _ in }
        case HealthRecords.bloodPressure: peripheral.veepooSDKTestBloodStart(false, testMode: 0) { _, _, _, _ in }
        case HealthRecords.spo2: peripheral.veepooSDKTestOxygenStart(false) { _, _ in }
        case HealthRecords.bodyTemp: peripheral.veepooSDK_temperatureTestStart(false) { _, _, _, _, _ in }
        case HealthRecords.fatigue: peripheral.veepooSDKTestFatigueStart(false) { _, _, _ in }
        case HealthRecords.stress: peripheral.veepooSDK_stressTestStart(false) { _, _, _ in }
        case HealthRecords.bloodGlucose: peripheral.veepooSDKTestBloodGlucoseStart(false, isPersonalModel: false) { _, _, _, _ in }
        case HealthRecords.ecg: peripheral.veepooSDKTestECGStart(false) { _, _, _ in }
        case "ptt": peripheral.veepooSDKPTTTest(false, valueBlock: nil, signal: nil)
        case HealthRecords.hrv: peripheral.veepooSDK_HRVTest(false, callBack: nil)
        case HealthRecords.respiratory: peripheral.veepooSDKTestBreathingRateStart(false) { _, _, _ in }
        case HealthMeasure.bloodComponent:
            peripheral.veepooSDKTestBloodAnalysisStart(false, isPersonalModel: false, progress: { _ in }, testResult: { _, _ in })
        case HealthMeasure.bodyComposition:
            peripheral.veepooSDKTestBodyCompositionStart(false, progress: { _, _ in }, testResult: { _, _ in })
        case HealthMeasure.gsr: peripheral.veepooSDKTestGSRStart(false, progress: nil, testResult: nil)
        case HealthMeasure.met: peripheral.veepooSDK_metTest(false, callBack: nil)
        case HealthMeasure.emotion: peripheral.veepooSDK_emotionTest(false, callBack: nil)
        case HealthMeasure.checkup: peripheral.veepooSDK_healthGlanceTestStart(false, andProgress: nil, andResult: nil)
        default: break
        }
    }
}
