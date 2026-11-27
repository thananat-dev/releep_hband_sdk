package com.releep.releep_hband_sdk.health

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.releep.releep_hband_sdk.core.WatchSession
import com.releep.releep_hband_sdk.health.HealthRecords.BATTERY
import com.releep.releep_hband_sdk.health.HealthRecords.BLOOD_GLUCOSE
import com.releep.releep_hband_sdk.health.HealthRecords.BLOOD_PRESSURE
import com.releep.releep_hband_sdk.health.HealthRecords.BODY_TEMP
import com.releep.releep_hband_sdk.health.HealthRecords.CALORIE
import com.releep.releep_hband_sdk.health.HealthRecords.ECG
import com.releep.releep_hband_sdk.health.HealthRecords.HEART_RATE
import com.releep.releep_hband_sdk.health.HealthRecords.HEART_WARNING
import com.releep.releep_hband_sdk.health.HealthRecords.HRV
import com.releep.releep_hband_sdk.health.HealthRecords.OFFLINE
import com.releep.releep_hband_sdk.health.HealthRecords.ONLINE
import com.releep.releep_hband_sdk.health.HealthRecords.RESPIRATORY
import com.releep.releep_hband_sdk.health.HealthRecords.RR_INTERVAL
import com.releep.releep_hband_sdk.health.HealthRecords.SLEEP
import com.releep.releep_hband_sdk.health.HealthRecords.STRESS
import com.releep.releep_hband_sdk.health.HealthRecords.SPO2
import com.releep.releep_hband_sdk.health.HealthRecords.SPORT
import com.releep.releep_hband_sdk.health.HealthRecords.STEP_COUNT
import com.veepoo.protocol.VPOperateManager
import com.veepoo.protocol.listener.base.IBleWriteResponse
import com.veepoo.protocol.listener.data.IECGReadDataListener
import com.veepoo.protocol.listener.data.IHeartWaringDataListener
import com.veepoo.protocol.listener.data.IOriginData3Listener
import com.veepoo.protocol.listener.data.IOriginDataListener
import com.veepoo.protocol.listener.data.IRRIntervalProgressListener
import com.veepoo.protocol.listener.data.ISleepDataListener
import com.veepoo.protocol.listener.data.ISportModelOriginListener
import com.veepoo.protocol.listener.data.ITemptureDataListener
import com.veepoo.protocol.model.DayState
import com.veepoo.protocol.model.datas.EcgDetectResult
import com.veepoo.protocol.model.datas.EcgDiagnosis
import com.veepoo.protocol.model.datas.HRVOriginData
import com.veepoo.protocol.model.datas.OriginData
import com.veepoo.protocol.model.datas.OriginData3
import com.veepoo.protocol.model.datas.OriginHalfHourData
import com.veepoo.protocol.model.datas.RRIntervalData
import com.veepoo.protocol.model.datas.SleepData
import com.veepoo.protocol.model.datas.SleepPrecisionData
import com.veepoo.protocol.model.datas.SportModelGPSWatchOriginHeadData
import com.veepoo.protocol.model.datas.SportModelOriginHeadData
import com.veepoo.protocol.model.datas.SportModelOriginItemData
import com.veepoo.protocol.model.datas.Spo2hOriginData
import com.veepoo.protocol.model.datas.TemptureData
import com.veepoo.protocol.model.datas.TimeData
import com.veepoo.protocol.model.enums.EBloodGlucoseRiskLevel
import com.veepoo.protocol.model.enums.EECGResultType
import com.veepoo.protocol.model.settings.ReadOriginSetting
import com.veepoo.protocol.shareprence.VpSpGetUtil

/**
 * Reads the watch history step by step and turns it into backend records.
 *
 * The Veepoo SDK cannot run two commands at once, so the steps run strictly
 * one after another. Every step has a timeout and is skipped when the
 * watch does not support it; failures are reported per step and never abort
 * the whole sync.
 *
 * Callbacks ([onProgress], [onDone]) are delivered on the main thread.
 */
class HealthSync(
    private val context: Context,
    private val days: Int,
    private val types: Set<String>,
    private val onProgress: (Map<String, Any?>) -> Unit,
    private val onDone: (Map<String, Any?>) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val manager = VPOperateManager.getInstance()
    private val sp = VpSpGetUtil.getVpSpVariInstance(context)
    private val bag = RecordBag()
    private val errors = LinkedHashMap<String, String>()
    private val skipped = ArrayList<String>()
    private var batteryPercent: Int? = null
    private var cancelled = false
    private var ended = false
    private var stepTimeout: Runnable? = null
    private var stepIndex = 0
    private val started = System.currentTimeMillis()

    private class Step(
        val name: String,
        val timeoutMs: Long,
        val wanted: Set<String>,
        val supported: () -> Boolean,
        val run: (done: (String?) -> Unit) -> Unit,
        /** False when the SDK gives no progress while the step runs: only the full timeout applies. */
        val reportsProgress: Boolean = true,
    )

    /**
     * A step whose watch stops answering is given up after this long without
     * any progress, instead of waiting for its full timeout (up to minutes).
     */
    private val idleLimitMs = 30_000L
    private var idleTimeout: Runnable? = null
    private var idleLimitForStep = 0L
    private var currentStage: String? = null

    private val watchDays: Int
        get() = WatchSession.watchDays(context).coerceAtLeast(1)

    private val readDays: Int
        get() = days.coerceIn(1, watchDays)

    private val steps: List<Step> = listOf(
        Step("battery", 10_000, setOf(BATTERY, STEP_COUNT, CALORIE), { true }, ::readBattery),
        Step("steps", 10_000, setOf(STEP_COUNT, CALORIE), { true }, ::readCurrentSteps),
        Step(
            "daily", 180_000,
            setOf(HEART_RATE, BLOOD_PRESSURE, SPO2, RESPIRATORY, HRV, STEP_COUNT, CALORIE, BODY_TEMP, BLOOD_GLUCOSE, HEART_WARNING, STRESS),
            { true }, ::readDaily,
        ),
        Step("sleep", 90_000, setOf(SLEEP), { true }, ::readSleep),
        Step(
            "temperature", 90_000, setOf(BODY_TEMP),
            { sp.isSupportReadTempture && sp.temperatureType != 5 }, ::readTemperature,
        ),
        Step("rrinterval", 120_000, setOf(RR_INTERVAL), { true }, ::readRrInterval),
        Step("sport", 90_000, setOf(SPORT), { sp.isSupportSportModel }, ::readSport),
        Step("ecg", 90_000, setOf(ECG), { sp.isSupportECG }, ::readEcg, reportsProgress = false),
        Step("heartwarning", 10_000, setOf(HEART_WARNING), { true }, ::readHeartWarning),
    )

    fun start() = main.post { next() }

    fun cancel() {
        cancelled = true
    }

    /**
     * The watch link dropped: stop now with what was read so far instead of
     * waiting for every remaining step to time out (minutes of `BUSY`).
     */
    fun abort(reason: String) = main.post {
        if (ended) return@post
        stepTimeout?.let { main.removeCallbacks(it) }
        clearIdle()
        errors["link"] = reason
        finish(cancelledByUser = false)
    }

    // ------------------------------------------------------------------

    private fun next() {
        if (ended) return
        if (cancelled) return finish(cancelledByUser = true)
        if (stepIndex >= steps.size) return finish(cancelledByUser = false)
        val step = steps[stepIndex++]
        if (step.wanted.none { it in types }) return next()
        if (safe { step.supported() } != true) {
            skipped += step.name
            return next()
        }
        var answered = false
        val timeout = Runnable {
            if (!answered) {
                answered = true
                clearIdle()
                errors[step.name] = "timeout"
                next()
            }
        }
        stepTimeout = timeout
        main.postDelayed(timeout, step.timeoutMs)
        currentStage = step.name
        idleLimitForStep = if (step.reportsProgress) minOf(idleLimitMs, step.timeoutMs) else step.timeoutMs
        idleTimeout = Runnable {
            if (!answered) {
                answered = true
                main.removeCallbacks(timeout)
                clearIdle()
                errors[step.name] = "timeout (no response for ${idleLimitForStep / 1000} s)"
                next()
            }
        }
        progress(step.name, null)
        armIdle()
        try {
            step.run { error ->
                main.post {
                    if (answered) return@post
                    answered = true
                    main.removeCallbacks(timeout)
                    clearIdle()
                    if (error != null) errors[step.name] = error
                    // Short gap: the SDK needs a moment between commands.
                    main.postDelayed({ next() }, 150)
                }
            }
        } catch (e: Throwable) {
            Log.e(TAG, "step ${step.name} failed: $e")
            if (!answered) {
                answered = true
                main.removeCallbacks(timeout)
                clearIdle()
                errors[step.name] = e.message ?: e.javaClass.simpleName
                next()
            }
        }
    }

    /** (Re)starts the no-progress timer of the running step. Main thread only. */
    private fun armIdle() {
        val idle = idleTimeout ?: return
        main.removeCallbacks(idle)
        main.postDelayed(idle, idleLimitForStep)
    }

    private fun clearIdle() {
        idleTimeout?.let { main.removeCallbacks(it) }
        idleTimeout = null
        currentStage = null
    }

    private fun progress(stage: String, fraction: Float?) {
        // Any sign of life from the running step restarts its idle timer.
        main.post { if (!ended && stage == currentStage) armIdle() }
        val stageIndex = steps.indexOfFirst { it.name == stage }.coerceAtLeast(0)
        val overall = (stageIndex + (fraction ?: 0f).coerceIn(0f, 1f)) / steps.size
        main.post {
            onProgress(
                mapOf(
                    "kind" to "sync",
                    "stage" to stage,
                    "stageProgress" to fraction?.toDouble(),
                    "progress" to overall.toDouble(),
                )
            )
        }
    }

    private fun finish(cancelledByUser: Boolean) {
        if (ended) return
        ended = true
        clearIdle()
        // A sleep step that timed out still returns the segments read so far.
        flushSleepNights()
        // RR bookmarks wait for the app to confirm the upload (confirmUpload).
        stashRrBookmarks()
        val records = bag.toMap().filterKeys { it in types }
        onDone(
            mapOf(
                "success" to (errors.isEmpty() && !cancelledByUser),
                "cancelled" to cancelledByUser,
                "records" to records,
                "counts" to records.mapValues { it.value.size },
                "errors" to errors,
                "skipped" to skipped,
                "durationMs" to (System.currentTimeMillis() - started),
            )
        )
    }

    private inline fun <T> safe(block: () -> T): T? = try {
        block()
    } catch (_: Throwable) {
        null
    }

    private val write = IBleWriteResponse { }

    // ------------------------------------------------------------------
    // Steps
    // ------------------------------------------------------------------

    private fun readBattery(done: (String?) -> Unit) {
        manager.readBattery(write) { data ->
            val percent = if (data.isPercent) data.batteryPercent else data.batteryLevel * 25
            batteryPercent = percent
            bag.put(BATTERY, mutableMapOf("value" to percent, "time" to HealthRecords.now()))
            done(null)
        }
    }

    private fun readCurrentSteps(done: (String?) -> Unit) {
        manager.readSportStep(write) { data ->
            val time = HealthRecords.now()
            if (data.step > 0) {
                bag.put(STEP_COUNT, mutableMapOf<String, Any?>(
                    "value" to data.step, "distance" to data.dis, "source" to ONLINE, "time" to time,
                ).withBattery())
            }
            if (data.kcal > 0) {
                bag.put(CALORIE, mutableMapOf<String, Any?>(
                    "value" to data.kcal, "source" to ONLINE, "time" to time,
                ).withBattery())
            }
            done(null)
        }
    }

    private fun MutableMap<String, Any?>.withBattery(): MutableMap<String, Any?> {
        batteryPercent?.let { this["battery_level"] = it }
        return this
    }

    // ---- 5-minute daily data: HR, BP, steps, kcal, temp, SpO2, HRV, glucose ----

    private val dailySteps = HashMap<String, Int>()
    private val dailyKcal = HashMap<String, Double>()
    private val dailyDistance = HashMap<String, Double>()

    private fun readDaily(done: (String?) -> Unit) {
        val setting = ReadOriginSetting(0, 1, false, readDays)
        val protocol = safe { sp.originProtocolVersion } ?: 0
        if (protocol == 3 || protocol == 5) {
            manager.readOriginDataBySetting(write, object : IOriginData3Listener {
                override fun onOriginFiveMinuteListDataChange(list: MutableList<OriginData3>?) {
                    list?.sortedBy { HealthRecords.time(it.date, it.getmTime()) }?.forEach { onOrigin3(it) }
                }

                override fun onOriginHalfHourDataChange(data: OriginHalfHourData?) {}

                override fun onOriginHRVOriginListDataChange(list: MutableList<HRVOriginData>?) {
                    list?.forEach { onHrv(it) }
                }

                override fun onOriginSpo2OriginListDataChange(list: MutableList<Spo2hOriginData>?) {
                    list?.forEach { onSpo2(it) }
                }

                override fun onReadOriginProgressDetail(day: Int, date: String?, all: Int, current: Int) {}
                override fun onReadOriginProgress(p: Float) = progress("daily", p)
                override fun onReadOriginComplete() = done(null)
                override fun onReadTimeout(code: Int) = done("watch timeout ($code)")
            }, setting)
        } else {
            manager.readOriginDataBySetting(write, object : IOriginDataListener {
                override fun onOringinFiveMinuteDataChange(data: OriginData?) {
                    data?.let { onOrigin(it) }
                }

                override fun onOringinHalfHourDataChange(data: OriginHalfHourData?) {}
                override fun onReadOriginProgressDetail(day: Int, date: String?, all: Int, current: Int) {}
                override fun onReadOriginProgress(p: Float) = progress("daily", p)
                override fun onReadOriginComplete() = done(null)
                override fun onReadTimeout(code: Int) = done("watch timeout ($code)")
            }, setting)
        }
    }

    /** Shared part of OriginData / OriginData3. Steps & kcal become daily running totals. */
    private fun onOriginCommon(data: OriginData, time: String, heart: Int?) {
        val date = time.substring(0, 10)
        if (heart != null && heart in 30..250) {
            bag.put(HEART_RATE, mutableMapOf("value" to heart, "source" to OFFLINE, "time" to time))
        }
        if (data.highValue > 0 && data.lowValue > 0) {
            bag.put(BLOOD_PRESSURE, mutableMapOf(
                "sbp" to data.highValue, "dbp" to data.lowValue, "source" to OFFLINE, "time" to time,
            ))
        }
        if (data.stepValue > 0 || data.calValue > 0) {
            val steps = (dailySteps[date] ?: 0) + data.stepValue
            val kcal = (dailyKcal[date] ?: 0.0) + data.calValue
            val dist = (dailyDistance[date] ?: 0.0) + data.disValue
            dailySteps[date] = steps
            dailyKcal[date] = kcal
            dailyDistance[date] = dist
            if (steps > 0) {
                bag.putIfAbsent(STEP_COUNT, mutableMapOf(
                    "value" to steps, "distance" to round2(dist), "source" to OFFLINE, "time" to time,
                ))
            }
            if (kcal > 0) {
                bag.putIfAbsent(CALORIE, mutableMapOf("value" to round2(kcal), "source" to OFFLINE, "time" to time))
            }
        }
        if (data.temperature > 0) {
            bag.putIfAbsent(BODY_TEMP, mutableMapOf<String, Any?>(
                "value" to round2(data.temperature), "source" to OFFLINE, "time" to time,
            ).apply { if (data.baseTemperature > 0) this["base_temp"] = round2(data.baseTemperature) })
        }
    }

    private fun onOrigin(data: OriginData) {
        val time = HealthRecords.time(data.date, data.getmTime()) ?: return
        onOriginCommon(data, time, data.rateValue)
    }

    private fun onOrigin3(data: OriginData3) {
        val time = HealthRecords.time(data.date, data.getmTime()) ?: return
        // OriginData3 keeps heart rate in arrays (getPpgs, fallback getEcgs).
        val heart = HealthRecords.averageNonZero(data.ppgs)
            ?: HealthRecords.averageNonZero(data.ecgs)
            ?: data.rateValue.takeIf { it > 0 }
        onOriginCommon(data, time, heart)
        HealthRecords.averageNonZero(data.resRates)?.let {
            bag.putIfAbsent(RESPIRATORY, mutableMapOf("value" to it, "time" to time))
        }
        val glucose = safe { data.bloodGlucose } ?: 0f
        if (glucose > 0f) {
            val record = mutableMapOf<String, Any?>("value" to round2(glucose.toDouble()), "source" to OFFLINE, "time" to time)
            safe { data.bloodGlucoseRiskLevel }?.takeIf { it != EBloodGlucoseRiskLevel.NONE }?.let {
                record["risk_level"] = it.name.lowercase()
            }
            bag.putIfAbsent(BLOOD_GLUCOSE, record)
        }
        val stress = safe { data.pressure } ?: 0
        if (stress in 1..100) {
            bag.putIfAbsent(STRESS, mutableMapOf(
                "value" to stress, "status" to HealthRecords.stressStatus(stress), "time" to time,
            ))
        }
    }

    private fun onSpo2(data: Spo2hOriginData) {
        val time = HealthRecords.time(data.date, data.getmTime()) ?: return
        if (data.oxygenValue in 50..100) {
            bag.put(SPO2, mutableMapOf(
                "value" to data.oxygenValue,
                "source" to OFFLINE,
                "apnea_result" to data.apneaResult,
                "is_hypoxia" to data.isHypoxia,
                "hypoxia_time" to data.hypoxiaTime,
                "hypopnea" to data.hypopnea,
                "cardiac_load" to data.cardiacLoad,
                "hr_variation" to data.gethRVariation(),
                "time" to time,
            ))
        }
        if (data.respirationRate > 0) {
            bag.put(RESPIRATORY, mutableMapOf("value" to data.respirationRate, "time" to time))
        }
    }

    private fun onHrv(data: HRVOriginData) {
        val time = HealthRecords.time(data.date, data.getmTime()) ?: return
        if (data.hrvValue <= 0) return
        val bpm = data.rate?.split(',', ' ', ';')?.mapNotNull { it.trim().toIntOrNull() }?.filter { it > 0 }
            ?.takeIf { it.isNotEmpty() }?.average()?.toInt() ?: 0
        bag.put(HRV, mutableMapOf("value" to data.hrvValue, "bpm" to bpm, "hrv_type" to data.hrvType, "time" to time))
    }

    // ---- sleep ----

    private fun readSleep(done: (String?) -> Unit) {
        manager.readSleepData(write, object : ISleepDataListener {
            override fun onSleepDataChange(day: String?, data: SleepData?) {
                data?.let { onSleep(it) }
            }

            override fun onSleepProgress(p: Float) = progress("sleep", p)
            override fun onSleepProgressDetail(day: String?, packageNumber: Int) {}
            override fun onReadSleepComplete() {
                // A night's segments can arrive under different days.
                flushSleepNights()
                done(null)
            }
        }, readDays)
    }

    /**
     * Precise sleep curve → one digit per minute (0 deep, 1 light, 2 REM,
     * 3 insomnia, 4 awake). Newer firmware writes a hex string, 4 chars
     * (16 bits) per minute with state = value >> 13; older ones already write
     * 1 char per minute. Both platforms send this same format.
     */
    private fun preciseLine(line: String, minutes: Int): String {
        if (minutes <= 0 || line.length < minutes * 2) return line
        val step = line.length / minutes
        return (0..line.length - step step step).joinToString("") { i ->
            minOf((line[i].digitToIntOrNull(16) ?: 0) shr 1, 4).toString()
        }
    }

    /** Drops corrupt segments (e.g. year 2039, months long): at most 24 h, not in the future. */
    private fun saneSleep(start: Long, end: Long): Boolean =
        end > start && end - start <= 24 * 3_600_000L && start <= System.currentTimeMillis() + 3_600_000L

    private class SleepSegment(val start: Long, val end: Long, val data: SleepPrecisionData, val line: String) {
        val linksPrevious get() = data.laster == 1
        /** 255 = the watch does not know yet (night still going on). */
        val linksNext get() = data.next == 1
    }

    /** Precise segments of every day read, joined into nights by [flushSleepNights]. */
    private val sleepSegments = ArrayList<SleepSegment>()

    private fun onSleep(data: SleepData) {
        val start = HealthRecords.millis(data.sleepDown) ?: return
        val end = HealthRecords.millis(data.sleepUp) ?: return
        if (!saneSleep(start, end) || data.allSleepTime <= 0) return
        val line = data.sleepLine ?: ""
        if (data is SleepPrecisionData) {
            sleepSegments += SleepSegment(start, end, data, preciseLine(line, ((end - start) / 60_000).toInt()))
            return
        }
        // Normal curve: 1 char = 5 minutes; 2 = awake.
        val record = mutableMapOf<String, Any?>(
            "allSleep" to data.allSleepTime,
            "deepSleep" to data.deepSleepTime,
            "lightSleep" to data.lowSleepTime,
            "rem" to 0,
            "awakeShort" to line.count { it == '2' } * 5,
            "startTime" to start,
            "endTime" to end,
            "sleep_date" to data.date,
            "sleep_quality" to data.sleepQulity,
            "wake_count" to data.wakeCount,
            "sleep_line" to line,
        )
        bag.put(SLEEP, record, key = start.toString())
    }

    /**
     * Joins linked segments (laster / next) into one record per night: start
     * of the first, end of the last, curve joined (gaps = awake), durations
     * for the whole night, scores and other values of the last.
     */
    private fun flushSleepNights() {
        val segments = sleepSegments.sortedBy { it.start }.distinctBy { it.start }
        sleepSegments.clear()
        var night = ArrayList<SleepSegment>()
        for (segment in segments) {
            val previous = night.lastOrNull()
            if (previous != null && (previous.linksNext || segment.linksPrevious) && segment.start >= previous.end) {
                night += segment
            } else {
                if (night.isNotEmpty()) addSleepNight(night)
                night = arrayListOf(segment)
            }
        }
        if (night.isNotEmpty()) addSleepNight(night)
    }

    private fun addSleepNight(night: List<SleepSegment>) {
        val first = night.first()
        val last = night.last()
        val line = StringBuilder(first.line)
        night.zipWithNext { previous, segment ->
            val gap = ((segment.start - previous.end) / 60_000).toInt()
            if (gap > 0) line.append("4".repeat(gap))
            line.append(segment.line)
        }
        val d = last.data
        // Some firmwares put the whole night's totals in the last segment
        // (longer than that segment itself); otherwise add the segments up.
        val lastSpan = ((last.end - last.start) / 60_000).toInt()
        val cumulative = night.size > 1 && d.allSleepTime > lastSpan + 1
        fun total(value: (SleepPrecisionData) -> Int) = if (cumulative) value(d) else night.sumOf { value(it.data) }
        val rem = line.count { it == '2' }
        val record = mutableMapOf<String, Any?>(
            "allSleep" to total { it.allSleepTime },
            "deepSleep" to total { it.deepSleepTime },
            "lightSleep" to total { it.lowSleepTime },
            "rem" to rem,
            "awakeShort" to total { it.getUpDuration },
            "startTime" to first.start,
            "endTime" to last.end,
            "sleep_date" to d.date,
            "sleep_line" to line.toString(),
            "segments" to night.size,
            "sleep_quality" to d.sleepQulity,
            "wake_count" to d.wakeCount,
            "fall_asleep_score" to d.fallAsleepScore,
            "deep_score" to d.deepScore,
            "sleep_efficiency_score" to d.sleepEfficiencyScore,
            "sleep_time_score" to d.sleepTimeScore,
            "getup_score" to d.getUpScore,
            "insomnia_score" to d.insomniaScore,
            "insomnia_times" to d.insomniaTimes,
            "insomnia_length" to d.insomniaLength,
        )
        // TODO(after a real multi-segment night): confirm which of sum / last
        // matches the watch, then drop the `cumulative` guess.
        Log.d(TAG, "sleep night ${d.date} segments=${night.size} cumulative=$cumulative " +
            "allSleep sum=${night.sumOf { it.data.allSleepTime }} last=${d.allSleepTime} " +
            "rem(line)=$rem otherDuration=${total { it.otherDuration }}")
        if (record["allSleep"] as Int > 0) bag.put(SLEEP, record, key = first.start.toString())
    }

    // ---- temperature (devices whose temperatureType != 5) ----

    private fun readTemperature(done: (String?) -> Unit) {
        manager.readTemptureDataBySetting(write, object : ITemptureDataListener {
            override fun onTemptureDataListDataChange(list: MutableList<TemptureData>?) {
                list?.forEach { t ->
                    val time = HealthRecords.time(null, t.getmTime()) ?: return@forEach
                    if (t.tempture > 0) {
                        bag.put(BODY_TEMP, mutableMapOf<String, Any?>(
                            "value" to round2(t.tempture.toDouble()),
                            "source" to if (t.isFromHandler) ONLINE else OFFLINE,
                            "time" to time,
                        ).apply { if (t.baseTempture > 0) this["base_temp"] = round2(t.baseTempture.toDouble()) })
                    }
                }
            }

            override fun onReadOriginProgressDetail(day: Int, date: String?, all: Int, current: Int) {}
            override fun onReadOriginProgress(p: Float) = progress("temperature", p)
            override fun onReadOriginComplete() = done(null)
            override fun onReadTimeout(code: Int) = done("watch timeout ($code)")
        }, ReadOriginSetting(0, 1, false, readDays))
    }

    // ---- RR interval, one day after another ----

    // RR interval: the watch makes one block per minute (1440 a day) and the
    // read can start at any block. Remember the last block read per watch and
    // day so each sync only transfers the new blocks.
    private val rrPrefs by lazy { rrPrefs(context) }
    /** Bookmarks reached in this run, saved when the sync ends. */
    private val rrPending = HashMap<String, Int>()

    private fun rrDate(daysAgo: Int) = rrDateKey(daysAgo)

    private fun rrKey(date: String) = "rr|${WatchSession.mac(context)}|$date"

    private fun readRrInterval(done: (String?) -> Unit) {
        val dayStates = listOf(DayState.TODAY, DayState.YESTERDAY, DayState.BEFORE_YESTERDAY).take(readDays)
        fun read(index: Int) {
            if (index >= dayStates.size) return done(null)
            val key = rrKey(rrDate(index))
            val last = rrPrefs.getInt(key, 0)
            // A past day that was read to its end cannot get new blocks.
            if (last >= RR_BLOCKS_PER_DAY) return read(index + 1)
            manager.readRRIntervalByDay(write, object : IRRIntervalProgressListener {
                override fun onReadRRIntervalProgressChanged(p: Float, data: RRIntervalData?) {
                    progress("rrinterval", (index + p) / dayStates.size)
                }

                override fun onReadRRIntervalComplete(state: DayState?, list: MutableList<RRIntervalData>?) {
                    var maxBlock = last
                    list?.forEach { rr ->
                        maxBlock = maxOf(maxBlock, rr.blockNumber)
                        val time = HealthRecords.time(null, rr.date) ?: return@forEach
                        val values = HealthRecords.clip(rr.data?.filter { it > 0 }?.toIntArray()) ?: return@forEach
                        bag.put(RR_INTERVAL, mutableMapOf("rr_arry" to values, "time" to time))
                    }
                    rrPending[key] = if (index > 0) RR_BLOCKS_PER_DAY else maxBlock
                    main.postDelayed({ read(index + 1) }, 100)
                }
            }, dayStates[index], if (last > 0) last + 1 else 0)
        }
        read(0)
    }

    /**
     * Keeps this run's RR bookmarks until the app confirms that the records
     * reached the backend ([confirmUpload]); an unconfirmed run is read again.
     */
    private fun stashRrBookmarks() {
        if (RR_INTERVAL !in types) return
        pendingRr = HashMap(rrPending)
        rrPending.clear()
    }

    // ---- sport sessions ----

    private fun readSport(done: (String?) -> Unit) {
        manager.readSportModelOrigin(write, object : ISportModelOriginListener {
            override fun onReadOriginProgress(p: Float) = progress("sport", p)
            override fun onReadOriginProgressDetail(day: Int, date: String?, all: Int, current: Int) {}

            override fun onHeadChangeListListener(head: SportModelOriginHeadData?) {
                head ?: return
                addSport(
                    head.startTime, head.stopTime, head.sportType, head.sportTime, head.stepCount,
                    head.distance, head.kcals, head.averRate, head.pauseCount, head.pauseTime, head.peisu, head.sportCount,
                )
            }

            override fun onGPSWatchSportModeHeadChange(head: SportModelGPSWatchOriginHeadData?) {
                head ?: return
                // GPS heads report distance in m and calories in cal.
                addSport(
                    head.startTime, head.stopTime, head.sportType, head.sportTime, head.stepCount,
                    head.distance / 1000.0, head.calories / 1000.0, head.averRate, head.pauseCount, head.pauseTime,
                    null, head.sportCount,
                )
            }

            override fun onItemChangeListListener(items: MutableList<SportModelOriginItemData>?) {}
            override fun onReadOriginComplete() = done(null)
        })
    }

    private fun addSport(
        start: TimeData?, stop: TimeData?, type: Int, seconds: Int, steps: Int, distanceKm: Double,
        kcal: Double, avgHr: Int, pauseCount: Int, pauseTime: Int, pace: Int?, sportCount: Int,
    ) {
        val time = HealthRecords.time(null, start) ?: return
        if (steps <= 0 && distanceKm <= 0 && kcal <= 0 && seconds <= 0) return
        val record = mutableMapOf<String, Any?>(
            "time" to time,
            "sport_type" to type,
            "duration" to seconds,
            "steps" to steps,
            "distance" to round2(distanceKm),
            "calories" to round2(kcal),
            "avg_heartrate" to avgHr,
            "pause_count" to pauseCount,
            "pause_time" to pauseTime,
            "sport_count" to sportCount,
        )
        HealthRecords.time(null, stop)?.takeIf { it >= time }?.let { record["end_time"] = it }
        if (pace != null && pace > 0) record["pace"] = pace
        bag.put(SPORT, record)
    }

    // ---- ECG measured on the watch (offline store) ----

    private fun readEcg(done: (String?) -> Unit) {
        manager.readECGData(
            write, TimeData(0, 0, 0, 0, 0, 0), com.veepoo.protocol.model.enums.EEcgDataType.ALL,
            object : IECGReadDataListener {
                override fun readDataFinish(list: MutableList<EcgDetectResult>?) {
                    list?.forEach { r ->
                        ecgRecord(r, if (r.type == EECGResultType.DATA_FORM_APP) "manual" else "auto")
                            ?.let { bag.put(ECG, it) }
                    }
                    done(null)
                }

                override fun readDiagnosisDataFinish(list: MutableList<EcgDiagnosis>?) {
                    list?.forEach { d -> ecgDiagnosisRecord(d, "auto")?.let { bag.put(ECG, it) } }
                    done(null)
                }
            },
        )
    }

    // ---- heart-rate alarm thresholds → warning events from synced HR ----

    private fun readHeartWarning(done: (String?) -> Unit) {
        manager.readHeartWarning(write, IHeartWaringDataListener { data ->
            if (data != null && data.isOpen && data.heartHigh > 0) {
                for (hr in bag.records(HEART_RATE)) {
                    val value = (hr["value"] as? Number)?.toInt() ?: continue
                    val type = when {
                        value > data.heartHigh -> "high"
                        data.heartLow > 0 && value < data.heartLow -> "low"
                        else -> null
                    } ?: continue
                    bag.put(HEART_WARNING, mutableMapOf(
                        "value" to value, "warning_type" to type,
                        "heart_high" to data.heartHigh, "heart_low" to data.heartLow, "time" to hr["time"],
                    ))
                }
            }
            done(null)
        })
    }

    companion object {
        private const val TAG = "HBandSync"
        private const val RR_BLOCKS_PER_DAY = 1440

        /** RR bookmarks of the last sync, saved by [confirmUpload]. */
        private var pendingRr: Map<String, Int> = emptyMap()

        private fun rrPrefs(context: Context) =
            context.getSharedPreferences("releep_hband_sync", Context.MODE_PRIVATE)

        private fun rrDateKey(daysAgo: Int): String {
            val cal = java.util.Calendar.getInstance().apply { add(java.util.Calendar.DAY_OF_YEAR, -daysAgo) }
            return java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(cal.time)
        }

        /**
         * The app uploaded the last sync's records: remember how far RR interval
         * was read so the next sync only reads new blocks. Main thread.
         */
        fun confirmUpload(context: Context) {
            val confirmed = pendingRr
            pendingRr = emptyMap()
            if (confirmed.isEmpty()) return
            val prefs = rrPrefs(context)
            val keep = (0..3).map { rrDateKey(it) }.toSet()
            val editor = prefs.edit()
            prefs.all.keys.filter { it.startsWith("rr|") && it.substringAfterLast('|') !in keep }.forEach { editor.remove(it) }
            confirmed.forEach { (k, v) -> editor.putInt(k, maxOf(v, prefs.getInt(k, 0))) }
            editor.apply()
        }

        fun round2(v: Double): Double = Math.round(v * 100.0) / 100.0

        /** Shared with live ECG measurement. */
        fun ecgRecord(r: EcgDetectResult, mode: String): MutableMap<String, Any?>? {
            val time = HealthRecords.time(null, r.timeBean) ?: HealthRecords.now()
            val wave = HealthRecords.clip(r.filterSignals) ?: HealthRecords.clip(r.originSign)
            if (r.aveHeart <= 0 && wave == null) return null
            return mutableMapOf<String, Any?>(
                "mode" to mode,
                "heart_rate" to r.aveHeart,
                "resp_rate" to r.aveResRate,
                "hrv" to r.aveHrv,
                "qt" to r.aveQT,
                "duration" to r.duration,
                "frequency" to r.frequency,
                "lead_sign" to r.leadSign,
                "time" to time,
            ).apply {
                r.result8?.let { this["result8"] = it.toList() }
                r.diseaseResult?.let { this["disease_result"] = it.toList() }
                wave?.let { this["wave"] = it }
            }
        }

        fun ecgDiagnosisRecord(d: EcgDiagnosis, mode: String): MutableMap<String, Any?>? {
            val time = HealthRecords.time(null, d.timeBean) ?: HealthRecords.now()
            val wave = HealthRecords.clip(d.filterSignals)
            if (d.heartRate <= 0 && wave == null) return null
            return mutableMapOf<String, Any?>(
                "mode" to mode,
                "heart_rate" to d.heartRate,
                "resp_rate" to d.respRate,
                "hrv" to d.hrv,
                "qt" to d.qtTime,
                "duration" to d.duration,
                "frequency" to d.frequency,
                "disease_risk" to d.diseaseRisk,
                "pressure_index" to d.pressureIndex,
                "fatigue_index" to d.fatigueIndex,
                "myocarditis_risk" to d.myocarditisRisk,
                "chd_risk" to d.chdRisk,
                "angiosclerotic_risk" to d.angioscleroticRisk,
                "qrs_time" to d.qrsTime,
                "qrs_amp" to d.qrsAmp,
                "pwv" to d.pwvMeanVal,
                "st_amp" to d.stMeanAmp,
                "sdnn" to d.diseaseSdnn,
                "rmssd" to d.diseaseRmssd,
                "time" to time,
            ).apply {
                d.diagnosis8?.let { this["result8"] = it.toList() }
                d.diseaseResult?.let { this["disease_result"] = it.toList() }
                wave?.let { this["wave"] = it }
            }
        }
    }
}
