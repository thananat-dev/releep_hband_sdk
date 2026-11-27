package com.releep.releep_hband_sdk

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.releep.releep_hband_sdk.core.GuardNotifications
import com.releep.releep_hband_sdk.core.HBandManager
import com.releep.releep_hband_sdk.core.PhoneFeatures
import com.releep.releep_hband_sdk.core.WatchSession
import com.releep.releep_hband_sdk.core.WebhookReporter
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONObject

/**
 * Flutter bridge for the Veepoo / HBand SDK.
 *
 * MethodChannel  releep_hband_sdk/method
 * EventChannel   releep_hband_sdk/scan        → scanned devices + {"finished": true}
 * EventChannel   releep_hband_sdk/connection  → connection state changes
 * EventChannel   releep_hband_sdk/events      → guard events (SOS / fall / status)
 * EventChannel   releep_hband_sdk/progress    → health sync progress + live measurement values
 * EventChannel   releep_hband_sdk/callBluetooth → watch call-Bluetooth (Classic / HFP) state
 */
class ReleepHbandSdkPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.NewIntentListener,
    HBandManager.Listener {

    companion object {
        private const val CHANNEL = "releep_hband_sdk"
        private const val REQ_PERMISSIONS = 0x4842
    }

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var scanChannel: EventChannel
    private lateinit var connectionChannel: EventChannel
    private lateinit var eventsChannel: EventChannel
    private lateinit var progressChannel: EventChannel
    private lateinit var callBtChannel: EventChannel

    private var scanSink: EventChannel.EventSink? = null
    private var connectionSink: EventChannel.EventSink? = null
    private var eventsSink: EventChannel.EventSink? = null
    private var progressSink: EventChannel.EventSink? = null
    private var callBtSink: EventChannel.EventSink? = null

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPermissionResult: Result? = null
    private var launchEmergencyEventId: String? = null
    private val main = Handler(Looper.getMainLooper())

    // ------------------------------------------------------------------
    // FlutterPlugin
    // ------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "$CHANNEL/method")
        methodChannel.setMethodCallHandler(this)
        scanChannel = EventChannel(binding.binaryMessenger, "$CHANNEL/scan")
        scanChannel.setStreamHandler(sinkHandler { scanSink = it })
        connectionChannel = EventChannel(binding.binaryMessenger, "$CHANNEL/connection")
        connectionChannel.setStreamHandler(sinkHandler { connectionSink = it })
        eventsChannel = EventChannel(binding.binaryMessenger, "$CHANNEL/events")
        eventsChannel.setStreamHandler(sinkHandler { eventsSink = it })
        progressChannel = EventChannel(binding.binaryMessenger, "$CHANNEL/progress")
        progressChannel.setStreamHandler(sinkHandler { progressSink = it })
        callBtChannel = EventChannel(binding.binaryMessenger, "$CHANNEL/callBluetooth")
        callBtChannel.setStreamHandler(sinkHandler { callBtSink = it })
        HBandManager.init(context)
        HBandManager.listener = this
        PhoneFeatures.btListener = { state -> emit { callBtSink?.success(state) } }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        scanChannel.setStreamHandler(null)
        connectionChannel.setStreamHandler(null)
        eventsChannel.setStreamHandler(null)
        progressChannel.setStreamHandler(null)
        callBtChannel.setStreamHandler(null)
        if (HBandManager.listener === this) HBandManager.listener = null
        PhoneFeatures.btListener = null
        // The guard keeps running natively (service) — only the bridge goes away.
    }

    private fun sinkHandler(assign: (EventChannel.EventSink?) -> Unit) =
        object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) = assign(events)
            override fun onCancel(arguments: Any?) = assign(null)
        }

    // ------------------------------------------------------------------
    // HBandManager.Listener (always delivered on the main thread)
    // ------------------------------------------------------------------

    override fun onScanResult(device: Map<String, Any?>) = emit { scanSink?.success(device) }

    override fun onScanFinished() = emit { scanSink?.success(mapOf("finished" to true)) }

    override fun onConnectionChanged(state: Map<String, Any?>) = emit { connectionSink?.success(state) }

    override fun onEvent(event: Map<String, Any?>) = emit { eventsSink?.success(event) }

    private fun emit(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    // ------------------------------------------------------------------
    // MethodChannel
    // ------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: Result) {
        try {
            handle(call, result)
        } catch (e: Exception) {
            result.error("HBAND_ERROR", e.message ?: e.javaClass.simpleName, null)
        }
    }

    private fun handle(call: MethodCall, result: Result) {
        when (call.method) {
            "initialize" -> {
                HBandManager.init(context)
                // Resume background guarding if a watch was paired before.
                if (WatchSession.isConfigured(context) && WatchSession.isGuardEnabled(context)) {
                    HBandManager.startGuard(context)
                }
                result.success(
                    mapOf(
                        "platform" to "android",
                        "session" to WatchSession.toMap(context),
                        "connection" to HBandManager.connectionState(),
                    )
                )
            }

            "checkPermissions" -> result.success(permissionStatus())
            "requestPermissions" -> requestPermissions(result)
            "isBluetoothEnabled" -> result.success(HBandManager.isBluetoothEnabled())

            "startScan" -> {
                if (!hasBlePermissions()) {
                    result.error("PERMISSION_DENIED", "Bluetooth permissions not granted", null)
                    return
                }
                if (!HBandManager.isBluetoothEnabled()) {
                    result.error("BLUETOOTH_OFF", "Bluetooth is turned off", null)
                    return
                }
                HBandManager.startScan(context, call.argument<Int>("timeoutSeconds") ?: 10)
                result.success(null)
            }

            "stopScan" -> {
                HBandManager.stopScan()
                result.success(null)
            }

            "connect" -> {
                val deviceId = call.argument<String>("deviceId")
                if (deviceId.isNullOrEmpty()) {
                    result.error("INVALID_ARGUMENT", "deviceId is required", null)
                    return
                }
                val password = call.argument<String>("password")
                    ?.takeIf { it.matches(Regex("\\d{4}")) } ?: WatchSession.DEFAULT_PASSWORD
                WatchSession.setAutoPairBt(context, call.argument<Boolean>("autoPairCallBluetooth") ?: true)
                HBandManager.connect(
                    context,
                    deviceId,
                    call.argument<String>("name"),
                    password,
                    call.argument<Boolean>("is24Hour") ?: true,
                ) { outcome -> main.post { result.success(outcome) } }
            }

            "disconnect" -> {
                HBandManager.disconnect(context)
                result.success(null)
            }

            "forgetWatch" -> {
                HBandManager.forgetWatch(context)
                result.success(null)
            }

            "getSession" -> result.success(WatchSession.toMap(context))
            "getConnectionState" -> result.success(HBandManager.connectionState())
            "readBattery" -> HBandManager.readBattery(context) { result.success(it) }

            "startGuard" -> result.success(HBandManager.startGuard(context))
            "stopGuard" -> {
                HBandManager.stopGuard(context)
                result.success(null)
            }
            "isGuardRunning" -> result.success(HBandManager.isGuardRunning())
            "setCallSosDetection" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                WatchSession.setCallSosDetection(context, enabled)
                HBandManager.syncCallSosDetector(context)
                // Enabling asks for READ_PHONE_STATE right away; returns the permission status.
                if (enabled) requestPermissions(result) else result.success(permissionStatus())
            }

            "setEmergencyNotification" -> {
                WatchSession.setEmergencyNotification(context, call.argument<Boolean>("enabled") ?: true)
                result.success(null)
            }

            "getEvents" -> result.success(HBandManager.events())
            "clearEvents" -> {
                HBandManager.clearEvents()
                result.success(null)
            }
            "acknowledgeEvent" -> result.success(
                HBandManager.acknowledge(call.argument<String>("id") ?: "")
            )
            "simulateEmergency" -> result.success(
                HBandManager.simulateEmergency(context, call.argument<String>("label"))
            )
            "getLaunchEmergencyEventId" -> {
                result.success(launchEmergencyEventId)
                launchEmergencyEventId = null
            }

            "getWebhookConfig" -> result.success(WebhookReporter.toMap(context))
            "setWebhookConfig" -> {
                WebhookReporter.configure(
                    context, call.argument<String>("url"), call.argument<Boolean>("enabled")
                )
                result.success(WebhookReporter.toMap(context))
            }
            "testWebhook" -> {
                val payload = JSONObject()
                    .put("message", "Test ping from releep_hband_sdk")
                    .put("watch", HBandManager.watchInfo(context))
                WebhookReporter.report(context, "TEST", payload, force = true) { success, code, message ->
                    result.success(mapOf("success" to success, "httpCode" to code, "message" to message))
                }
            }

            // ---- health data ----
            "getImei" -> result.success(HBandManager.imei(context))
            "getCapabilities" -> result.success(HBandManager.capabilities(context))
            "syncHealthData" -> {
                val types = call.argument<List<String>>("types")?.toSet()
                    ?: com.releep.releep_hband_sdk.health.HealthRecords.ALL_TYPES.toSet()
                HBandManager.syncHealth(
                    context,
                    call.argument<Int>("days") ?: 3,
                    types,
                    onProgress = { p -> emit { progressSink?.success(p) } },
                ) { outcome, error ->
                    main.post {
                        if (error != null) result.error(error, errorMessage(error), null) else result.success(outcome)
                    }
                }
            }
            "cancelHealthSync" -> {
                HBandManager.cancelSync()
                result.success(null)
            }
            "confirmHealthUpload" -> {
                com.releep.releep_hband_sdk.health.HealthSync.confirmUpload(context)
                result.success(null)
            }
            "startMeasurement" -> {
                val type = call.argument<String>("type") ?: ""
                HBandManager.startMeasure(
                    context,
                    type,
                    onUpdate = { u -> emit { progressSink?.success(u) } },
                ) { outcome, error ->
                    main.post {
                        if (error != null) result.error(error, errorMessage(error), null) else result.success(outcome)
                    }
                }
            }
            "stopMeasurement" -> {
                HBandManager.stopMeasure()
                result.success(null)
            }

            // ---- call Bluetooth (Classic / HFP) ----
            "getCallBluetoothState" -> result.success(PhoneFeatures.btState(context))
            "readCallBluetoothState" -> PhoneFeatures.readBtInfo(context, reply(result))
            "connectCallBluetooth" -> replyError(result, PhoneFeatures.connectBt(context))
            "disconnectCallBluetooth" -> replyError(result, PhoneFeatures.disconnectBt(context))

            // ---- contacts / SOS contacts ----
            "getContactSupport" -> result.success(PhoneFeatures.contactSupport(context))
            "getContacts" -> PhoneFeatures.readContacts(context, reply(result))
            "addContact" -> {
                val name = call.argument<String>("name")?.trim().orEmpty()
                val phone = call.argument<String>("phone")?.trim().orEmpty()
                if (name.isEmpty() || phone.isEmpty()) {
                    result.error("INVALID_ARGUMENT", "name and phone are required", null)
                    return
                }
                PhoneFeatures.addContact(context, name, phone, call.argument<Boolean>("sos") ?: false, reply(result))
            }
            "deleteContact" -> PhoneFeatures.deleteContact(context, call.argument<Int>("id") ?: -1, reply(result))
            "setSosContact" -> PhoneFeatures.setSosContact(
                context,
                call.argument<Int>("id") ?: -1,
                call.argument<Boolean>("enabled") ?: true,
                reply(result),
            )
            "getSosCallTimes" -> PhoneFeatures.readSosCallTimes(context, reply(result))
            "setSosCallTimes" -> PhoneFeatures.setSosCallTimes(context, call.argument<Int>("times") ?: 1, reply(result))

            "getRawFrames" -> result.success(HBandManager.rawFrames(call.argument<Int>("lines") ?: 30))

            "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())
            "requestIgnoreBatteryOptimizations" -> {
                result.success(requestIgnoreBatteryOptimizations())
            }

            else -> result.notImplemented()
        }
    }

    private fun <T> reply(result: Result): (T, String?) -> Unit = { value, error ->
        main.post {
            if (error != null) result.error(error, errorMessage(error), null) else result.success(value)
        }
    }

    private fun replyError(result: Result, error: String?) {
        if (error != null) result.error(error, errorMessage(error), null) else result.success(null)
    }

    private fun errorMessage(code: String) = when (code) {
        "NOT_READY" -> "Watch is not connected"
        "BUSY" -> "Another command is running on the watch"
        "UNSUPPORTED_TYPE" -> "This measurement type is not supported"
        "UNSUPPORTED" -> "The watch does not support this feature"
        "NOT_FOUND" -> "Contact not found on the watch"
        "TIMEOUT" -> "The watch did not answer"
        "WRITE_FAILED" -> "Could not send the command to the watch"
        "FAILED" -> "The watch rejected the command"
        else -> code
    }

    // ------------------------------------------------------------------
    // Permissions
    // ------------------------------------------------------------------

    private fun blePermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun granted(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED

    private fun hasBlePermissions() = blePermissions().all { granted(it) }

    private fun hasNotificationPermission() =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || granted(Manifest.permission.POST_NOTIFICATIONS)

    private fun permissionStatus(): Map<String, Any?> = mapOf(
        "bluetooth" to hasBlePermissions(),
        "notification" to hasNotificationPermission(),
        "phoneState" to (!WatchSession.isCallSosDetection(context) || granted(Manifest.permission.READ_PHONE_STATE)),
    )

    private fun requestPermissions(result: Result) {
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("NO_ACTIVITY", "Permissions can only be requested from the foreground", null)
            return
        }
        val missing = blePermissions().filterNot { granted(it) }.toMutableList()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !granted(Manifest.permission.POST_NOTIFICATIONS)
        ) {
            missing += Manifest.permission.POST_NOTIFICATIONS
        }
        if (WatchSession.isCallSosDetection(context) && !granted(Manifest.permission.READ_PHONE_STATE)) {
            missing += Manifest.permission.READ_PHONE_STATE
        }
        if (missing.isEmpty()) {
            result.success(permissionStatus())
            return
        }
        if (pendingPermissionResult != null) {
            result.error("IN_PROGRESS", "A permission request is already running", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(currentActivity, missing.toTypedArray(), REQ_PERMISSIONS)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQ_PERMISSIONS) return false
        HBandManager.syncCallSosDetector(context)
        pendingPermissionResult?.success(permissionStatus())
        pendingPermissionResult = null
        return true
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = context.getSystemService(PowerManager::class.java) ?: return false
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    private fun requestIgnoreBatteryOptimizations(): Boolean {
        val source = activity ?: context
        val intent = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${context.packageName}"),
        )
        if (activity == null) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            source.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    // ------------------------------------------------------------------
    // ActivityAware — permissions + "opened from emergency notification"
    // ------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addOnNewIntentListener(this)
        readEmergencyExtra(binding.activity.intent)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
        activity = null
    }

    override fun onNewIntent(intent: Intent): Boolean {
        readEmergencyExtra(intent)
        return false
    }

    private fun readEmergencyExtra(intent: Intent?) {
        val id = intent?.getStringExtra(GuardNotifications.EXTRA_EMERGENCY_EVENT_ID) ?: return
        intent.removeExtra(GuardNotifications.EXTRA_EMERGENCY_EVENT_ID)
        launchEmergencyEventId = id
        eventsSink?.success(mapOf("type" to "_OPEN_EMERGENCY", "id" to id))
    }
}
