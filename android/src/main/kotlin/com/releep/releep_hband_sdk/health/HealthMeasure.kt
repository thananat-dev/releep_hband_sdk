package com.releep.releep_hband_sdk.health

import android.os.Handler
import android.os.Looper
import com.releep.releep_hband_sdk.health.HealthRecords.BLOOD_GLUCOSE
import com.releep.releep_hband_sdk.health.HealthRecords.BLOOD_PRESSURE
import com.releep.releep_hband_sdk.health.HealthRecords.BODY_TEMP
import com.releep.releep_hband_sdk.health.HealthRecords.ECG
import com.releep.releep_hband_sdk.health.HealthRecords.FATIGUE
import com.releep.releep_hband_sdk.health.HealthRecords.HEART_RATE
import com.releep.releep_hband_sdk.health.HealthRecords.HRV
import com.releep.releep_hband_sdk.health.HealthRecords.ONLINE
import com.releep.releep_hband_sdk.health.HealthRecords.RESPIRATORY
import com.releep.releep_hband_sdk.health.HealthRecords.SPO2
import com.releep.releep_hband_sdk.health.HealthRecords.STRESS
import com.veepoo.protocol.VPOperateManager
import com.veepoo.protocol.listener.IMiniCheckupOptListener
import com.veepoo.protocol.listener.base.IBleWriteResponse
import com.veepoo.protocol.listener.data.IBloodComponentDetectListener
import com.veepoo.protocol.listener.data.IBloodGlucoseChangeListener
import com.veepoo.protocol.listener.data.IBodyComponentDetectListener
import com.veepoo.protocol.listener.data.IBreathDataListener
import com.veepoo.protocol.listener.data.IECGDetectListener
import com.veepoo.protocol.listener.data.IEmotionDetectListener
import com.veepoo.protocol.listener.data.IGsrDetectListener
import com.veepoo.protocol.listener.data.IHrvDetectListener
import com.veepoo.protocol.listener.data.IMetDetectListener
import com.veepoo.protocol.listener.data.IPressureDetectListener
import com.veepoo.protocol.model.datas.BloodComponent
import com.veepoo.protocol.model.datas.BodyComponent
import com.veepoo.protocol.model.datas.BreathData
import com.veepoo.protocol.model.datas.EcgDetectInfo
import com.veepoo.protocol.model.datas.EcgDetectResult
import com.veepoo.protocol.model.datas.EcgDetectState
import com.veepoo.protocol.model.datas.EcgDiagnosis
import com.veepoo.protocol.model.datas.GsrDetectResult
import com.veepoo.protocol.model.datas.MealInfo
import com.veepoo.protocol.model.datas.MiniCheckupDetailData
import com.veepoo.protocol.model.datas.MiniCheckupResultData
import com.veepoo.protocol.model.enums.DetectState
import com.veepoo.protocol.model.enums.EAdcType
import com.veepoo.protocol.model.enums.EBloodComponentDetectState
import com.veepoo.protocol.model.enums.EBPDetectModel
import com.veepoo.protocol.model.enums.EBPDetectStatus
import com.veepoo.protocol.model.enums.EBloodGlucoseRiskLevel
import com.veepoo.protocol.model.enums.EBloodGlucoseStatus
import com.veepoo.protocol.model.enums.EDeviceStatus
import com.veepoo.protocol.model.enums.EFunctionStatus
import com.veepoo.protocol.model.enums.EHeartStatus
import com.veepoo.protocol.model.enums.EMiniCheckupTestErrorCode
import com.veepoo.protocol.model.enums.EmotionDetectState
import com.veepoo.protocol.model.enums.GsrDetectAck
import com.veepoo.protocol.model.enums.HrvDetectState
import com.veepoo.protocol.model.enums.MetDetectState
import com.veepoo.protocol.model.enums.PressureDetectState

/**
 * One manual ("online") measurement started from the app.
 *
 * Types: heartrate, bloodpressure, spo2, bodytemp, fatigue, bloodglucose,
 * ecg, ptt, stress, hrv, respiratory — records already in the backend
 * `data[]` shape (`source` = online where the backend has it, `time` = now) —
 * plus bloodcomponent, bodycomposition, gsr, met, emotion, checkup, which have
 * no backend type yet (record is for display). Live values go to [onUpdate];
 * [onDone] receives {success, type, record?, records?, message?} exactly once.
 * `records` (checkup only) = backend type → record for each value it measured.
 */
class HealthMeasure(
    val type: String,
    private val onUpdate: (Map<String, Any?>) -> Unit,
    private val onDone: (Map<String, Any?>) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val manager = VPOperateManager.getInstance()
    private val write = IBleWriteResponse { }
    private var finished = false
    private var lastValue: Any? = null
    private var firstValueAt = 0L

    // Temperature watches can briefly report "device busy" while an automatic
    // health reading is finishing. They can also report the raw/skin value in
    // an earlier callback and omit it from the final (100%) callback.
    private var temperatureBusyRetries = 0
    private var temperatureRetryScheduled = false
    private var lastTemperatureBase: Double? = null
    /** Callbacks of an attempt that was already retried are ignored. */
    private var temperatureAttempt = 0
    private val temperatureRetry = Runnable { startTemperatureMeasurement() }

    // ECG accumulation
    private val wave = ArrayList<Int>()
    private var ecgFrequency = 0
    private var lastEcgState: EcgDetectState? = null
    private var pttStartedAt = 0L

    companion object {
        // Measurement-only types (no backend `{type}` yet).
        const val BLOOD_COMPONENT = "bloodcomponent"
        const val BODY_COMPOSITION = "bodycomposition"
        const val GSR = "gsr"
        const val MET = "met"
        const val EMOTION = "emotion"
        const val CHECKUP = "checkup"

        val TYPES = listOf(
            HEART_RATE, BLOOD_PRESSURE, SPO2, BODY_TEMP, FATIGUE, BLOOD_GLUCOSE, ECG, "ptt", STRESS,
            HRV, RESPIRATORY, BLOOD_COMPONENT, BODY_COMPOSITION, GSR, MET, EMOTION, CHECKUP,
        )

        private fun timeoutFor(type: String): Long = when (type) {
            CHECKUP -> 180_000
            ECG, "ptt", BLOOD_GLUCOSE, BLOOD_COMPONENT, BODY_COMPOSITION, GSR -> 120_000
            else -> 90_000
        }

        /** Continuous measurements finish this long after the first valid value. */
        private fun settleMs(type: String): Long = if (type == HRV) 30_000L else 12_000L

        /** Backend types that carry `source`. */
        private val WITH_SOURCE = listOf(HEART_RATE, BLOOD_PRESSURE, SPO2, BODY_TEMP, BLOOD_GLUCOSE)

        /** PTT has no final result event — capture this long, then build the record. */
        private const val PTT_CAPTURE_MS = 30_000L

        private const val TEMPERATURE_MAX_BUSY_RETRIES = 5
        private const val TEMPERATURE_BUSY_RETRY_MS = 3_000L
    }

    private val timeout = Runnable { fail("Measurement timed out") }

    fun start() {
        main.postDelayed(timeout, timeoutFor(type))
        when (type) {
            HEART_RATE -> manager.startDetectHeart(write) { data ->
                main.post {
                    when (data.heartStatus) {
                        EHeartStatus.STATE_HEART_WEAR_ERROR -> fail("Watch is not worn correctly")
                        EHeartStatus.STATE_HEART_BUSY -> fail("Watch is busy")
                        EHeartStatus.STATE_LOW_BATTERY -> fail("Watch battery is low")
                        else -> if (data.data in 30..250) {
                            continuous(data.data) { v -> mapOf("value" to v) }
                        } else {
                            update(null, null)
                        }
                    }
                }
            }

            BLOOD_PRESSURE -> manager.startDetectBP(write, { data ->
                main.post {
                    when (data.status) {
                        EBPDetectStatus.STATE_BP_BUSY -> fail("Watch is busy")
                        EBPDetectStatus.STATE_BP_LOW_BATTERY -> fail("Watch battery is low")
                        EBPDetectStatus.STATE_BP_CHARGING -> fail("Watch is charging")
                        EBPDetectStatus.STATE_BP_WEAR_OFF -> fail("Watch is not worn correctly")
                        else -> {
                            update(data.progress, if (data.highPressure > 0) "${data.highPressure}/${data.lowPressure}" else null)
                            if (data.progress >= 100 && data.highPressure > 0 && data.lowPressure > 0) {
                                succeed(mapOf("sbp" to data.highPressure, "dbp" to data.lowPressure))
                            }
                        }
                    }
                }
            }, EBPDetectModel.DETECT_MODEL_PUBLIC)

            SPO2 -> manager.startDetectSPO2H(write) { data ->
                main.post {
                    when (data.deviceState) {
                        EDeviceStatus.BUSY -> fail("Watch is busy")
                        EDeviceStatus.CHARGING -> fail("Watch is charging")
                        EDeviceStatus.CHARG_LOW -> fail("Watch battery is low")
                        EDeviceStatus.UNPASS_WEAR -> fail("Watch is not worn correctly")
                        else -> {
                            val progress = if (data.isChecking) data.checkingProgress else null
                            if (data.value in 70..100) {
                                continuous(data.value, progress) { v -> mapOf("value" to v) }
                            } else {
                                update(progress, null)
                            }
                        }
                    }
                }
            }

            BODY_TEMP -> startTemperatureMeasurement()

            FATIGUE -> manager.startDetectFatigue(write) { data ->
                main.post {
                    when (data.deviceState) {
                        EDeviceStatus.BUSY -> fail("Watch is busy")
                        EDeviceStatus.UNPASS_WEAR -> fail("Watch is not worn correctly")
                        else -> {
                            update(data.progress, if (data.value > 0) data.value else null)
                            if (data.progress >= 100 && data.value > 0) {
                                succeed(mapOf("value" to data.value, "status" to HealthRecords.fatigueStatus(data.value)))
                            }
                        }
                    }
                }
            }

            BLOOD_GLUCOSE -> {
                // Read the personal calibration first (optional fields), then measure.
                try {
                    manager.readBloodGlucoseAdjustingData(write, glucoseListener)
                } catch (_: Throwable) {
                }
                main.postDelayed({
                    if (!finished) manager.startBloodGlucoseDetect(write, glucoseListener)
                }, 1_500)
            }

            ECG -> manager.startDetectECG(write, true, ecgListener)

            STRESS -> manager.startDetectPressure(write, pressureListener)

            "ptt" -> manager.startReadPttSignData(write, EAdcType.ADC_DATA_FILTERING, ecgListener)

            HRV -> manager.startDetectHrv(write, hrvListener)

            RESPIRATORY -> manager.startDetectBreath(write, breathListener)

            BLOOD_COMPONENT -> manager.startDetectBloodComponent(write, false, bloodComponentListener)

            BODY_COMPOSITION -> manager.startDetectBodyComponent(write, bodyComponentListener)

            GSR -> manager.startDetectGsr(write, gsrListener)

            MET -> manager.startDetectMet(write, metListener)

            EMOTION -> manager.startDetectEmotion(write, emotionListener)

            CHECKUP -> manager.startMiniCheckup(write, checkupListener)

            else -> fail("Unsupported measurement type: $type")
        }
    }

    /** User cancelled — stop the watch, report as not successful. */
    fun stop() = fail("Stopped")

    // ------------------------------------------------------------------

    private fun startTemperatureMeasurement() {
        if (finished) return
        temperatureRetryScheduled = false
        val attempt = ++temperatureAttempt
        manager.startDetectTempture(write) { data ->
            main.post {
                if (finished || attempt != temperatureAttempt) return@post
                android.util.Log.d("HBandMeasure", "temperature attempt=$attempt oprate=${data.oprate} " +
                    "deviceState=${data.deviceState} progress=${data.progress} " +
                    "temp=${data.tempture} base=${data.temptureBase}")
                if (data.temptureBase > 0) {
                    lastTemperatureBase = HealthSync.round2(data.temptureBase.toDouble())
                }
                when {
                    data.oprate == 0 -> fail("Temperature measurement not supported")
                    data.deviceState in 1..7 -> retryTemperatureAfterBusy()
                    data.deviceState == 8 -> fail("Watch battery is low")
                    data.deviceState == 9 -> fail("Temperature sensor error")
                    else -> {
                        update(
                            data.progress,
                            data.tempture.takeIf { it > 0 },
                            lastTemperatureBase?.let { mapOf("base_temp" to it) } ?: emptyMap(),
                        )
                        if (data.progress >= 100 && data.tempture > 0) {
                            succeed(
                                mutableMapOf<String, Any?>(
                                    "value" to HealthSync.round2(data.tempture.toDouble()),
                                ).apply {
                                    lastTemperatureBase?.let { this["base_temp"] = it }
                                },
                            )
                        }
                    }
                }
            }
        }
    }

    private fun retryTemperatureAfterBusy() {
        if (temperatureRetryScheduled || finished) return
        if (temperatureBusyRetries >= TEMPERATURE_MAX_BUSY_RETRIES) {
            fail("Watch is busy")
            return
        }
        temperatureBusyRetries++
        temperatureRetryScheduled = true
        // Stop our own pending test first: a start sent while one is still
        // open is answered "busy" again.
        try { manager.stopDetectTempture(write, null) } catch (_: Exception) {}
        update(null, null)
        main.postDelayed(temperatureRetry, TEMPERATURE_BUSY_RETRY_MS)
    }

    /** For values that keep streaming: finish [SETTLE_MS] after the first valid one. */
    private fun continuous(value: Int, progress: Int? = null, build: (Int) -> Map<String, Any?>) {
        lastValue = value
        if (firstValueAt == 0L) firstValueAt = System.currentTimeMillis()
        val elapsed = System.currentTimeMillis() - firstValueAt
        val settle = settleMs(type)
        update(progress ?: ((elapsed * 100) / settle).toInt().coerceAtMost(99), value)
        if (elapsed >= settle || (progress != null && progress >= 100)) succeed(build(value))
    }

    private fun update(progress: Int?, value: Any?, extra: Map<String, Any?> = emptyMap()) {
        if (finished) return
        onUpdate(
            mapOf(
                "kind" to "measure",
                "type" to type,
                "progress" to progress?.coerceIn(0, 100),
                "value" to value,
            ) + extra
        )
    }

    private fun succeed(values: Map<String, Any?>, records: Map<String, Map<String, Any?>>? = null) {
        if (finished) return
        val record = LinkedHashMap<String, Any?>(values)
        if (type in WITH_SOURCE) record["source"] = ONLINE
        record["time"] = HealthRecords.now()
        val result = mutableMapOf<String, Any?>("success" to true, "type" to recordType(), "record" to record)
        if (records != null) result["records"] = records
        finish(result)
    }

    private fun fail(message: String) {
        if (finished) return
        // A continuous measurement stopped by the user still has a value.
        if (message == "Stopped" && lastValue is Int && type in listOf(HEART_RATE, SPO2, HRV)) {
            succeed(mapOf("value" to lastValue))
            return
        }
        if (message == "Stopped" && type == "ptt" && (wave.isNotEmpty() || lastEcgState != null)) {
            finishPtt()
            return
        }
        finish(mapOf("success" to false, "type" to recordType(), "message" to message))
    }

    private fun recordType() = if (type == "ptt") ECG else type

    private fun finish(result: Map<String, Any?>) {
        finished = true
        main.removeCallbacks(timeout)
        main.removeCallbacks(temperatureRetry)
        stopDevice()
        onDone(result)
    }

    private fun stopDevice() {
        try {
            when (type) {
                HEART_RATE -> manager.stopDetectHeart(write)
                BLOOD_PRESSURE -> manager.stopDetectBP(write, EBPDetectModel.DETECT_MODEL_PUBLIC)
                SPO2 -> manager.stopDetectSPO2H(write) { }
                BODY_TEMP -> manager.stopDetectTempture(write, null)
                FATIGUE -> manager.stopDetectFatigue(write) { }
                STRESS -> manager.stopDetectPressure(write)
                BLOOD_GLUCOSE -> manager.stopBloodGlucoseDetect(write, glucoseListener)
                ECG -> manager.stopDetectECG(write, true, ecgListener)
                "ptt" -> manager.stopReadPttSignData(write, EAdcType.ADC_DATA_FILTERING, ecgListener)
                HRV -> manager.stopDetectHrv(write, hrvListener)
                RESPIRATORY -> manager.stopDetectBreath(write, breathListener)
                BLOOD_COMPONENT -> manager.stopDetectBloodComponent(write)
                BODY_COMPOSITION -> manager.stopDetectBodyComponent(write)
                GSR -> manager.stopDetectGsr(write)
                MET -> manager.stopDetectMet(write)
                EMOTION -> manager.stopDetectEmotion(write)
                CHECKUP -> {
                    main.removeCallbacks(checkupFallback)
                    manager.stopMiniCheckup(write, checkupListener)
                }
            }
        } catch (_: Throwable) {
        }
    }

    // ---- HRV (continuous — the watch never stops it by itself) ----

    private val hrvListener = object : IHrvDetectListener {
        override fun onHrvDetect(hrv: Int) {
            main.post {
                if (hrv > 0) continuous(hrv) { v -> mapOf("value" to v) } else update(null, null)
            }
        }

        override fun onDetectFailed(state: HrvDetectState) {
            main.post {
                fail(when (state) {
                    HrvDetectState.BUSY -> "Watch is busy"
                    HrvDetectState.LOW_POWER -> "Watch battery is low"
                    HrvDetectState.WEAR_OFF -> "Watch is not worn correctly"
                    else -> "Measurement failed"
                })
            }
        }

        override fun onDetectStop() {
            main.post { fail("Stopped") }
        }
    }

    // ---- respiratory rate ----

    private val breathListener = object : IBreathDataListener {
        override fun onDataChange(data: BreathData) {
            main.post {
                if (data.functionStateEnum == EFunctionStatus.UNSUPPORT) return@post fail("Respiratory rate not supported")
                when (data.deviceStateEnum) {
                    EDeviceStatus.BUSY -> fail("Watch is busy")
                    EDeviceStatus.CHARGING -> fail("Watch is charging")
                    EDeviceStatus.CHARG_LOW -> fail("Watch battery is low")
                    EDeviceStatus.UNPASS_WEAR -> fail("Watch is not worn correctly")
                    else -> {
                        update(data.progressValue, data.value.takeIf { it > 0 })
                        if (data.progressValue >= 100) {
                            if (data.value > 0) succeed(mapOf("value" to data.value)) else fail("Measurement failed")
                        }
                    }
                }
            }
        }
    }

    // ---- blood component ----

    private val bloodComponentListener = object : IBloodComponentDetectListener {
        override fun onDetecting(progress: Int, value: BloodComponent) {
            main.post { update(progress, null) }
        }

        override fun onDetectComplete(value: BloodComponent) {
            main.post { succeed(bloodComponentMap(value.uricAcid, value.tCHO, value.tAG, value.hDL, value.lDL)) }
        }

        override fun onDetectFailed(state: EBloodComponentDetectState) {
            main.post {
                fail(when (state) {
                    EBloodComponentDetectState.LOW_POWER -> "Watch battery is low"
                    EBloodComponentDetectState.BUSY, EBloodComponentDetectState.DETECTING -> "Watch is busy"
                    EBloodComponentDetectState.WEAR_ERROR -> "Watch is not worn correctly"
                    else -> "Measurement failed"
                })
            }
        }

        override fun onDetectStop() {
            main.post { fail("Stopped") }
        }
    }

    // ---- body composition (fingers on the electrodes) ----

    private val bodyComponentListener = object : IBodyComponentDetectListener {
        override fun onDetecting(progress: Int, leadState: Int) {
            main.post { update(progress, null, mapOf("leadOff" to (leadState != 0))) }
        }

        override fun onDetectSuccess(value: BodyComponent) {
            main.post {
                succeed(bodyCompositionMap(
                    value.BMI, value.bodyFatRate, value.fatRate, value.FFM, value.muscleRate, value.muscleMass,
                    value.subcutaneousFat, value.bodyWater, value.waterContent, value.skeletalMuscleRate,
                    value.boneMass, value.proteinProportion, value.proteinMass, value.basalMetabolicRate,
                ))
            }
        }

        override fun onDetectFailed(state: DetectState) {
            main.post {
                fail(when (state) {
                    DetectState.BUSY -> "Watch is busy"
                    DetectState.LOW_POWER -> "Watch battery is low"
                    else -> "Measurement failed"
                })
            }
        }

        override fun onDetectStop() {
            main.post { fail("Stopped") }
        }
    }

    // ---- GSR (skin conductance) ----

    private val gsrListener = object : IGsrDetectListener {
        override fun onGsrDetectProgress(progress: Int) {
            main.post { update(progress, null) }
        }

        override fun onGsrDetectSuccess(result: GsrDetectResult) {
            main.post {
                succeed(gsrMap(
                    result.emotionLevel, result.skinMoisture, result.depressionRisk.ordinal,
                    result.snsActivation, result.cortisolValue,
                ))
            }
        }

        override fun onGsrDetectFailed(ack: GsrDetectAck) {
            main.post {
                fail(when (ack) {
                    GsrDetectAck.BUSY_MEASURING_PRESSURE, GsrDetectAck.BUSY_MEASURING_OTHER -> "Watch is busy"
                    GsrDetectAck.LOW_BATTERY -> "Watch battery is low"
                    GsrDetectAck.WEARING_CHECK_FAILED -> "Watch is not worn correctly"
                    else -> "Measurement failed"
                })
            }
        }

        override fun onGsrDetectStop() {
            main.post { fail("Stopped") }
        }
    }

    // ---- MET ----

    private val metListener = object : IMetDetectListener {
        override fun onMetDetect(progress: Int, met: Float) {
            main.post {
                update(progress, met.takeIf { it > 0 }?.let { HealthSync.round2(it.toDouble()) })
                if (progress >= 100) {
                    if (met > 0) succeed(mapOf("value" to HealthSync.round2(met.toDouble()))) else fail("Measurement failed")
                }
            }
        }

        override fun onDetectFailed(state: MetDetectState) {
            main.post {
                fail(when (state) {
                    MetDetectState.BUSY -> "Watch is busy"
                    MetDetectState.LOW_POWER -> "Watch battery is low"
                    MetDetectState.WEAR_OFF -> "Watch is not worn correctly"
                    else -> "Measurement failed"
                })
            }
        }

        override fun onDetectStop() {
            main.post { fail("Stopped") }
        }
    }

    // ---- emotion (0 is a valid value) ----

    private val emotionListener = object : IEmotionDetectListener {
        override fun onEmotionDetect(progress: Int, emotion: Int) {
            main.post {
                update(progress, if (progress >= 100) emotion else null)
                if (progress >= 100) succeed(mapOf("value" to emotion))
            }
        }

        override fun onDetectFailed(state: EmotionDetectState) {
            main.post {
                fail(when (state) {
                    EmotionDetectState.BUSY -> "Watch is busy"
                    EmotionDetectState.LOW_POWER -> "Watch battery is low"
                    EmotionDetectState.WEAR_OFF -> "Watch is not worn correctly"
                    else -> "Measurement failed"
                })
            }
        }

        override fun onDetectStop() {
            main.post { fail("Stopped") }
        }
    }

    // ---- mini checkup (several values in one run) ----

    /** Some watches send only the short result — finish with it if no detail follows. */
    private var checkupBasic: MiniCheckupResultData? = null
    private val checkupFallback = Runnable { checkupBasic?.let { finishCheckupBasic(it) } }

    private val checkupListener = object : IMiniCheckupOptListener {
        override fun onMiniCheckupTestProgress(progress: Int) {
            main.post { update(progress, null) }
        }

        override fun onMiniCheckupStopSuccess() {
            main.post { fail("Stopped") }
        }

        override fun onMiniCheckupTestFailed(code: EMiniCheckupTestErrorCode) {
            main.post {
                fail(when (code) {
                    EMiniCheckupTestErrorCode.FUNCTION_NOT_SUPPORT -> "Checkup not supported"
                    EMiniCheckupTestErrorCode.DEVICE_BUSY -> "Watch is busy"
                    EMiniCheckupTestErrorCode.LOW_POWER -> "Watch battery is low"
                    EMiniCheckupTestErrorCode.WEARING_ABNORMALITY -> "Watch is not worn correctly"
                    EMiniCheckupTestErrorCode.ECG_LEAD_DETACHMENT -> "Keep your finger on the electrode"
                    else -> "Measurement failed"
                })
            }
        }

        override fun onMiniCheckupSuccess(data: MiniCheckupResultData) {
            main.post {
                if (finished) return@post
                checkupBasic = data
                main.removeCallbacks(checkupFallback)
                main.postDelayed(checkupFallback, 2_000)
            }
        }

        override fun onMiniCheckupDetailTestSuccess(data: MiniCheckupDetailData) {
            main.post {
                main.removeCallbacks(checkupFallback)
                finishCheckupDetail(data)
            }
        }
    }

    private fun finishCheckupBasic(d: MiniCheckupResultData) {
        val c = CheckupBuilder()
        c.heartRate(d.heartRate)
        c.spo2(d.bloodOxygen)
        c.bloodPressure(d.systolicBloodPressure, d.diastolicBloodPressure, "blood_pressure")
        c.bloodGlucose(d.bloodGlucose)
        c.bodyTemp(d.bodyTemperature, null)
        c.stress(d.stress)
        c.fatigue(d.fatigue)
        c.hrv(d.hrv)
        c.values["emotion"] = d.emotion
        succeed(c.values, c.records)
    }

    private fun finishCheckupDetail(d: MiniCheckupDetailData) {
        val c = CheckupBuilder()
        c.heartRate(d.heartRate)
        c.spo2(d.bloodOxygen)
        d.bpAirPump?.let { c.bloodPressure(it.systolicBloodPressure, it.diastolicBloodPressure, "blood_pressure_cuff") }
        d.bpPhotoelectric?.let { c.bloodPressure(it.systolicBloodPressure, it.diastolicBloodPressure, "blood_pressure") }
        if (d.bloodGlucoseType != 0) c.bloodGlucose(d.bloodGlucose)
        c.bodyTemp(d.bodyTemperature, d.originalTemperature)
        c.stress(d.stress)
        c.fatigue(d.fatigue)
        c.hrv(d.hrv)
        c.values["emotion"] = d.emotion
        d.bloodComponent?.let {
            c.values[BLOOD_COMPONENT] = bloodComponentMap(it.uricAcid, it.gettCHO(), it.gettAG(), it.gethDL(), it.getlDL())
        }
        d.bodyComponent?.let {
            c.values[BODY_COMPOSITION] = bodyCompositionMap(
                it.bmi, it.bodyFatRate, it.fatRate, it.ffm, it.muscleRate, it.muscleMass, it.subcutaneousFat,
                it.bodyWater, it.waterContent, it.skeletalMuscleRate, it.boneMass, it.proteinProportion,
                it.proteinMass, it.basalMetabolicRate,
            )
        }
        d.skinElectricity?.let {
            c.values[GSR] = gsrMap(
                it.emotion, it.skinMoistureContent, it.depressionRisk, it.sympatheticActivity, it.cortisolConcentration,
            )
        }
        succeed(c.values, c.records)
    }

    /** Collects checkup values (flat, for display) and per-backend-type records. */
    private class CheckupBuilder {
        val values = LinkedHashMap<String, Any?>()
        val records = LinkedHashMap<String, Map<String, Any?>>()
        private val time = HealthRecords.now()

        private fun record(type: String, fields: Map<String, Any?>) {
            val r = LinkedHashMap<String, Any?>(fields)
            if (type in WITH_SOURCE) r["source"] = ONLINE
            r["time"] = time
            records[type] = r
        }

        fun heartRate(v: Int) {
            if (v !in 30..250) return
            values["heart_rate"] = v
            record(HEART_RATE, mapOf("value" to v))
        }

        fun spo2(v: Int) {
            if (v !in 70..100) return
            values["spo2"] = v
            record(SPO2, mapOf("value" to v))
        }

        /** Cuff (air pump) pressure wins over photoelectric for the backend record. */
        fun bloodPressure(sbp: Int, dbp: Int, key: String) {
            if (sbp <= 0 || dbp <= 0) return
            values[key] = mapOf("sbp" to sbp, "dbp" to dbp)
            if (key == "blood_pressure_cuff" || BLOOD_PRESSURE !in records) {
                record(BLOOD_PRESSURE, mapOf("sbp" to sbp, "dbp" to dbp))
            }
        }

        fun bloodGlucose(v: Float) {
            if (v <= 0f) return
            val value = HealthSync.round2(v.toDouble())
            values["blood_glucose"] = value
            record(BLOOD_GLUCOSE, mapOf("value" to value))
        }

        /** -273.15 = not supported. */
        fun bodyTemp(v: Float, base: Float?) {
            if (v <= 0f) return
            val value = HealthSync.round2(v.toDouble())
            values["body_temp"] = value
            val fields = mutableMapOf<String, Any?>("value" to value)
            if (base != null && base > 0f) fields["base_temp"] = HealthSync.round2(base.toDouble())
            record(BODY_TEMP, fields)
        }

        fun stress(v: Int) {
            if (v !in 1..100) return
            values["stress"] = v
            record(STRESS, mapOf("value" to v, "status" to HealthRecords.stressStatus(v)))
        }

        fun fatigue(v: Int) {
            if (v <= 0) return
            values["fatigue"] = v
            record(FATIGUE, mapOf("value" to v, "status" to HealthRecords.fatigueStatus(v)))
        }

        fun hrv(v: Int) {
            if (v <= 0) return
            values["hrv"] = v
            record(HRV, mapOf("value" to v))
        }
    }

    private fun bloodComponentMap(uricAcid: Float, tcho: Float, tag: Float, hdl: Float, ldl: Float) = mapOf(
        "uric_acid" to HealthSync.round2(uricAcid.toDouble()),
        "total_cholesterol" to HealthSync.round2(tcho.toDouble()),
        "triglyceride" to HealthSync.round2(tag.toDouble()),
        "hdl" to HealthSync.round2(hdl.toDouble()),
        "ldl" to HealthSync.round2(ldl.toDouble()),
    )

    private fun bodyCompositionMap(
        bmi: Float, bodyFat: Float, fatMass: Float, leanMass: Float, muscleRate: Float, muscleMass: Float,
        subcutaneousFat: Float, bodyWater: Float, waterContent: Float, skeletalMuscle: Float, boneMass: Float,
        proteinRate: Float, proteinMass: Float, bmr: Float,
    ): Map<String, Any?> = mapOf(
        "bmi" to bmi, "body_fat_rate" to bodyFat, "fat_mass" to fatMass, "lean_body_mass" to leanMass,
        "muscle_rate" to muscleRate, "muscle_mass" to muscleMass, "subcutaneous_fat" to subcutaneousFat,
        "body_water" to bodyWater, "water_content" to waterContent, "skeletal_muscle_rate" to skeletalMuscle,
        "bone_mass" to boneMass, "protein_rate" to proteinRate, "protein_mass" to proteinMass,
        "basal_metabolic_rate" to bmr,
    ).mapValues { HealthSync.round2((it.value as Float).toDouble()) }

    /** [depressionRisk] 0 low · 1 medium · 2 high. */
    private fun gsrMap(emotion: Int, skinMoisture: Int, depressionRisk: Int, sns: Int, cortisol: Int) = mapOf(
        "emotion_level" to emotion,
        "skin_moisture" to skinMoisture,
        "depression_risk" to (listOf("low", "medium", "high").getOrNull(depressionRisk) ?: "unknown"),
        "sns_activation" to sns,
        "cortisol" to cortisol,
    )

    // ---- stress ----

    private val pressureListener = object : IPressureDetectListener {
        override fun onDetecting(progress: Int) {
            main.post { update(progress, null) }
        }

        override fun onDetectSuccess(value: Int) {
            main.post {
                if (value > 0) {
                    succeed(mapOf("value" to value, "status" to HealthRecords.stressStatus(value)))
                } else {
                    fail("Measurement failed")
                }
            }
        }

        override fun onDetectFailed(state: PressureDetectState) {
            main.post {
                fail(when (state) {
                    PressureDetectState.BUSY -> "Watch is busy"
                    PressureDetectState.LOW_POWER -> "Watch battery is low"
                    PressureDetectState.WEAR_OFF -> "Watch is not worn correctly"
                    else -> "Measurement failed"
                })
            }
        }

        override fun onDetectStop() {
            main.post { fail("Stopped") }
        }
    }

    // ---- blood glucose ----

    private var glucoseCalibration: Pair<Boolean, Float>? = null

    private val glucoseListener = object : IBloodGlucoseChangeListener {
        override fun onDetectError(code: Int, status: EBloodGlucoseStatus?) {
            main.post {
                fail(
                    when (status) {
                        EBloodGlucoseStatus.NONSUPPORT -> "Blood glucose not supported"
                        EBloodGlucoseStatus.LOW_POWER -> "Watch battery is low"
                        EBloodGlucoseStatus.BUSY -> "Watch is busy"
                        EBloodGlucoseStatus.WEARING_ERROR -> "Watch is not worn correctly"
                        else -> "Blood glucose error ($code)"
                    }
                )
            }
        }

        override fun onBloodGlucoseDetect(progress: Int, value: Float, risk: EBloodGlucoseRiskLevel?) {
            main.post {
                update(progress, if (value > 0) value else null)
                if (progress >= 100 && value > 0) {
                    val record = mutableMapOf<String, Any?>("value" to HealthSync.round2(value.toDouble()))
                    if (risk != null && risk != EBloodGlucoseRiskLevel.NONE) record["risk_level"] = risk.name.lowercase()
                    glucoseCalibration?.let { (open, v) ->
                        record["calibration_open"] = open
                        if (v > 0) record["calibration_value"] = HealthSync.round2(v.toDouble())
                    }
                    succeed(record)
                }
            }
        }

        override fun onBloodGlucoseStopDetect() {}
        override fun onBloodGlucoseAdjustingSettingSuccess(open: Boolean, value: Float) {}
        override fun onBloodGlucoseAdjustingSettingFailed() {}
        override fun onBloodGlucoseAdjustingReadSuccess(open: Boolean, value: Float) {
            glucoseCalibration = open to value
        }

        override fun onBloodGlucoseAdjustingReadFailed() {}
        override fun onBGMultipleAdjustingReadSuccess(open: Boolean, a: MealInfo?, b: MealInfo?, c: MealInfo?) {}
        override fun onBGMultipleAdjustingReadFailed() {}
        override fun onBGMultipleAdjustingSettingSuccess() {}
        override fun onBGMultipleAdjustingSettingFailed() {}
    }

    // ---- ECG / PTT ----

    private val ecgListener = object : IECGDetectListener {
        override fun onEcgDetectInfoChange(info: EcgDetectInfo?) {
            info?.let { ecgFrequency = it.frequency }
        }

        override fun onEcgDetectStateChange(state: EcgDetectState?) {
            state ?: return
            main.post {
                if (state.deviceState == EDeviceStatus.BUSY) return@post fail("Watch is busy")
                if (state.deviceState == EDeviceStatus.UNPASS_WEAR) return@post fail("Watch is not worn correctly")
                lastEcgState = state
                update(state.progress, state.hr1.takeIf { it > 0 })
            }
        }

        override fun onEcgDetectResultChange(result: EcgDetectResult?) {
            result ?: return
            main.post { finishEcg(HealthSync.ecgRecord(result, ecgMode())) }
        }

        override fun onEcgDetectDiagnosisChange(diagnosis: EcgDiagnosis?) {
            diagnosis ?: return
            main.post { finishEcg(HealthSync.ecgDiagnosisRecord(diagnosis, ecgMode())) }
        }

        override fun onEcgADCChange(filtered: IntArray?, original: IntArray?) {
            val samples = filtered ?: original ?: return
            main.post {
                if (finished) return@post
                if (wave.size < HealthRecords.MAX_ARRAY) wave.addAll(samples.take(HealthRecords.MAX_ARRAY - wave.size))
                onUpdate(mapOf("kind" to "measure", "type" to type, "samples" to samples.toList()))
                if (type == "ptt") {
                    if (pttStartedAt == 0L) pttStartedAt = System.currentTimeMillis()
                    val elapsed = System.currentTimeMillis() - pttStartedAt
                    update(((elapsed * 100) / PTT_CAPTURE_MS).toInt().coerceAtMost(99), lastEcgState?.hr1?.takeIf { it > 0 })
                    if (elapsed >= PTT_CAPTURE_MS) finishPtt()
                }
            }
        }
    }

    private fun ecgMode() = if (type == "ptt") "ptt" else "manual"

    private fun finishPtt() {
        val state = lastEcgState
        if (wave.isEmpty() && (state == null || state.hr1 <= 0)) {
            return fail("No PTT data — start PTT mode on the watch")
        }
        val record = mutableMapOf<String, Any?>(
            "mode" to "ptt",
            "heart_rate" to (state?.hr1 ?: 0),
            "hrv" to (state?.hrv ?: 0),
            "resp_rate" to (state?.br1 ?: 0),
            "qt" to (state?.qtc ?: 0),
            "duration" to ((System.currentTimeMillis() - pttStartedAt) / 1000).toInt(),
        )
        if (ecgFrequency > 0) record["frequency"] = ecgFrequency
        if (wave.isNotEmpty()) record["wave"] = wave.toList()
        succeed(record)
    }

    private fun finishEcg(record: MutableMap<String, Any?>?) {
        if (record == null) return fail("ECG result was empty")
        if (record["wave"] == null && wave.isNotEmpty()) record["wave"] = wave.toList()
        if ((record["frequency"] as? Int ?: 0) <= 0 && ecgFrequency > 0) record["frequency"] = ecgFrequency
        succeed(record.filterKeys { it != "time" })
    }
}
