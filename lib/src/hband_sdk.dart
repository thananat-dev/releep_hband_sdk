import 'dart:async';

import 'package:flutter/services.dart';

import 'health.dart';
import 'models.dart';
import 'phone.dart';

/// Entry point of the plugin. All methods are static; the native side keeps
/// a single watch session.
///
/// Typical flow:
/// ```dart
/// final init = await HBandSdk.initialize();
/// if (init.session == null) {
///   await HBandSdk.requestPermissions();
///   HBandSdk.scanResults.listen(...);
///   await HBandSdk.startScan();
///   await HBandSdk.connect(device, password: '0000');
/// }
/// HBandSdk.events.where((e) => e.isEmergency).listen(showAlert);
/// ```
abstract final class HBandSdk {
  static const _method = MethodChannel('releep_hband_sdk/method');
  static const _scan = EventChannel('releep_hband_sdk/scan');
  static const _connection = EventChannel('releep_hband_sdk/connection');
  static const _events = EventChannel('releep_hband_sdk/events');
  static const _progress = EventChannel('releep_hband_sdk/progress');
  static const _callBt = EventChannel('releep_hband_sdk/callBluetooth');

  static Stream<Map<dynamic, dynamic>>? _scanRaw;
  static Stream<HBandConnectionState>? _connectionStream;
  static Stream<Map<dynamic, dynamic>>? _eventsRaw;
  static Stream<Map<dynamic, dynamic>>? _progressRaw;
  static Stream<HBandCallBluetoothState>? _callBtStream;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Initialises the native SDK. If a watch was paired before, the guard
  /// resumes automatically (reconnect + SOS/fall monitoring).
  static Future<HBandInitResult> initialize() async =>
      HBandInitResult.fromMap(await _method.invokeMapMethod('initialize'));

  // ---------------------------------------------------------------------------
  // Permissions / Bluetooth
  // ---------------------------------------------------------------------------

  static Future<HBandPermissionStatus> checkPermissions() async =>
      HBandPermissionStatus.fromMap(await _method.invokeMapMethod('checkPermissions'));

  /// Android: BLE scan/connect (+ location on Android 11-) and notifications.
  /// iOS: Bluetooth prompt + notification authorisation.
  static Future<HBandPermissionStatus> requestPermissions() async =>
      HBandPermissionStatus.fromMap(await _method.invokeMapMethod('requestPermissions'));

  static Future<bool> isBluetoothEnabled() async =>
      await _method.invokeMethod<bool>('isBluetoothEnabled') ?? false;

  // ---------------------------------------------------------------------------
  // Scan
  // ---------------------------------------------------------------------------

  /// Devices found while scanning. Each device is emitted once per scan.
  static Stream<HBandDevice> get scanResults =>
      _scanStream.where((m) => m['finished'] != true).map(HBandDevice.fromMap);

  /// Emits when a scan ends (timeout or [stopScan]).
  static Stream<void> get scanFinished => _scanStream.where((m) => m['finished'] == true);

  static Stream<Map<dynamic, dynamic>> get _scanStream =>
      _scanRaw ??= _scan.receiveBroadcastStream().cast<Map<dynamic, dynamic>>().asBroadcastStream();

  /// Throws [PlatformException] with code `PERMISSION_DENIED` or `BLUETOOTH_OFF`.
  ///
  /// [watchId] / [watchName]: the watch being looked for (MAC + name). On iOS a
  /// watch whose link iOS already holds (e.g. connected for calls) does not
  /// advertise; with these it is still reported, as [watchId], when no saved
  /// session identifies it.
  static Future<void> startScan({
    Duration timeout = const Duration(seconds: 10),
    String? watchId,
    String? watchName,
  }) =>
      _method.invokeMethod('startScan', {
        'timeoutSeconds': timeout.inSeconds,
        if (watchId != null && watchId.isNotEmpty) 'watchId': watchId,
        if (watchName != null && watchName.isNotEmpty) 'watchName': watchName,
      });

  static Future<void> stopScan() => _method.invokeMethod('stopScan');

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  static Stream<HBandConnectionState> get connectionState => _connectionStream ??= _connection
      .receiveBroadcastStream()
      .map((e) => HBandConnectionState.fromMap(e as Map))
      .asBroadcastStream();

  /// Connects, verifies the 4-digit [password] (factory default `0000`) and,
  /// on success, saves the session and starts the background guard.
  ///
  /// [autoPairCallBluetooth] (Android): once the session is ready the plugin pairs /
  /// connects the watch's call Bluetooth by itself (Android shows its pairing dialog
  /// the first time only). The choice is saved and also used by background reconnects.
  static Future<HBandConnectResult> connect(
    HBandDevice device, {
    String password = '0000',
    bool is24Hour = true,
    bool autoPairCallBluetooth = true,
  }) => connectById(
    device.deviceId,
    name: device.name,
    password: password,
    is24Hour: is24Hour,
    autoPairCallBluetooth: autoPairCallBluetooth,
  );

  static Future<HBandConnectResult> connectById(
    String deviceId, {
    String? name,
    String password = '0000',
    bool is24Hour = true,
    bool autoPairCallBluetooth = true,
  }) async => HBandConnectResult.fromMap(
    await _method.invokeMapMethod('connect', {
          'deviceId': deviceId,
          'name': name,
          'password': password,
          'is24Hour': is24Hour,
          'autoPairCallBluetooth': autoPairCallBluetooth,
        }) ??
        const {},
  );

  /// Drops the link and stops the guard but keeps the saved session.
  static Future<void> disconnect() => _method.invokeMethod('disconnect');

  /// Disconnects, clears the saved session and stops all background work.
  static Future<void> forgetWatch() => _method.invokeMethod('forgetWatch');

  static Future<HBandSession?> getSession() async =>
      HBandSession.fromMap(await _method.invokeMapMethod('getSession'));

  static Future<HBandConnectionState> getConnectionState() async =>
      HBandConnectionState.fromMap(await _method.invokeMapMethod('getConnectionState') ?? const {});

  /// Null when the watch is not ready or does not answer in time.
  static Future<HBandBattery?> readBattery() async =>
      HBandBattery.fromMap(await _method.invokeMapMethod('readBattery'));

  // ---------------------------------------------------------------------------
  // Guard
  // ---------------------------------------------------------------------------

  /// Starts SOS/fall monitoring + auto-reconnect (Android: foreground service).
  /// Returns false when no watch is paired.
  static Future<bool> startGuard() async => await _method.invokeMethod<bool>('startGuard') ?? false;

  static Future<void> stopGuard() => _method.invokeMethod('stopGuard');

  static Future<bool> isGuardRunning() async => await _method.invokeMethod<bool>('isGuardRunning') ?? false;

  /// Also treats an outgoing call placed through the watch's call Bluetooth
  /// as SOS. For watches that only dial their SOS contact and send nothing over BLE
  /// (e.g. VANTA). Any outgoing call while the watch is the phone's call headset
  /// counts — meant for SOS-only watches. Saved; on by default.
  ///
  /// Android: needs the phone-state permission — [requestPermissions] asks for it,
  /// and enabling asks right away (needs a foreground activity); check
  /// [HBandPermissionStatus.phoneState] in the result.
  /// iOS: no permission needed, but calls are only seen while the app process
  /// runs (foreground, or background kept alive by the BLE link).
  static Future<HBandPermissionStatus> setCallSosDetection(bool enabled) async {
    return HBandPermissionStatus.fromMap(
      await _method.invokeMapMethod('setCallSosDetection', {'enabled': enabled}),
    );
  }

  /// Whether the plugin posts its own "Emergency from watch" notification for an
  /// emergency (SOS / fall). Saved, kept across [forgetWatch]; on by default. Turn it
  /// off when the app shows its own alert — detection, [events], the saved feed
  /// and the webhook are unchanged.
  static Future<void> setEmergencyNotification(bool enabled) =>
      _method.invokeMethod('setEmergencyNotification', {'enabled': enabled});

  /// Live guard events (emergencies, reminders, status lines). Re-emitted
  /// when the webhook delivery status of an event changes.
  static Stream<HBandEvent> get events =>
      _eventsStream.where((m) => m['type'] != '_OPEN_EMERGENCY').map(HBandEvent.fromMap);

  /// Emits the event id when the app is opened from an emergency notification.
  static Stream<String> get emergencyNotificationTaps =>
      _eventsStream.where((m) => m['type'] == '_OPEN_EMERGENCY').map((m) => m['id'] as String);

  static Stream<Map<dynamic, dynamic>> get _eventsStream =>
      _eventsRaw ??= _events.receiveBroadcastStream().cast<Map<dynamic, dynamic>>().asBroadcastStream();

  /// Recent feed (max 100), newest first.
  static Future<List<HBandEvent>> getEvents() async {
    final list = await _method.invokeListMethod<Map<dynamic, dynamic>>('getEvents') ?? const [];
    return list.map(HBandEvent.fromMap).toList();
  }

  static Future<void> clearEvents() => _method.invokeMethod('clearEvents');

  /// Marks an emergency as handled by the user.
  static Future<bool> acknowledgeEvent(String id) async =>
      await _method.invokeMethod<bool>('acknowledgeEvent', {'id': id}) ?? false;

  /// Sends a fake emergency through the full pipeline (feed, webhook, alert).
  static Future<HBandEvent> simulateEmergency({String? label}) async =>
      HBandEvent.fromMap(await _method.invokeMapMethod('simulateEmergency', {'label': label}) ?? const {});

  /// Event id if the app was cold-started from an emergency notification.
  static Future<String?> getLaunchEmergencyEventId() =>
      _method.invokeMethod<String>('getLaunchEmergencyEventId');

  // ---------------------------------------------------------------------------
  // Webhook
  // ---------------------------------------------------------------------------

  static Future<HBandWebhookConfig> getWebhookConfig() async =>
      HBandWebhookConfig.fromMap(await _method.invokeMapMethod('getWebhookConfig'));

  /// Events are POSTed natively (also in the background) when enabled.
  static Future<HBandWebhookConfig> setWebhookConfig({String? url, bool? enabled}) async =>
      HBandWebhookConfig.fromMap(
        await _method.invokeMapMethod('setWebhookConfig', {'url': url, 'enabled': enabled}),
      );

  /// Sends a TEST event even when delivery is switched off.
  static Future<HBandWebhookResult> testWebhook() async =>
      HBandWebhookResult.fromMap(await _method.invokeMapMethod('testWebhook'));

  // ---------------------------------------------------------------------------
  // Health data (for api/smartwatch_vp_insert/{type})
  // ---------------------------------------------------------------------------

  /// Backend `imei`: the watch MAC in upper case, e.g. `76:EA:BE:E7:93:61`.
  static Future<String?> getImei() => _method.invokeMethod<String>('getImei');

  /// Features the connected watch reports as supported.
  static Future<HBandCapabilities> getCapabilities() async =>
      HBandCapabilities.fromMap(await _method.invokeMapMethod('getCapabilities'));

  /// Reads the watch history (up to [days], limited by what the watch keeps)
  /// and returns records per backend type. Only one sync / measurement can
  /// run at a time; throws [PlatformException] `NOT_READY` or `BUSY`.
  ///
  /// Re-syncing is safe: the backend skips records whose `time` already exists.
  static Future<HBandHealthSyncResult> syncHealthData({int days = 3, List<String>? types}) async =>
      HBandHealthSyncResult.fromMap(
        await _method.invokeMapMethod('syncHealthData', {'days': days, 'types': types}),
      );

  /// Stops a running sync after the current step; the result has `cancelled: true`.
  static Future<void> cancelHealthSync() => _method.invokeMethod('cancelHealthSync');

  /// Call after the records of the last [syncHealthData] reached the backend.
  /// RR interval is read incrementally: without this confirmation the next
  /// sync reads the same blocks again, so nothing is lost when an upload fails.
  static Future<void> confirmHealthUpload() => _method.invokeMethod('confirmHealthUpload');

  /// Progress of [syncHealthData].
  static Stream<HBandSyncProgress> get syncProgress =>
      _progressStream.where((m) => m['kind'] == 'sync').map(HBandSyncProgress.fromMap);

  /// Measures one value now (see [HBandMeasureType]). Completes when the watch
  /// finishes, fails, times out, or [stopMeasurement] is called (heart rate /
  /// SpO2 / HRV / PTT keep the last value when stopped early).
  static Future<HBandMeasureResult> startMeasurement(String type) async =>
      HBandMeasureResult.fromMap(await _method.invokeMapMethod('startMeasurement', {'type': type}));

  static Future<void> stopMeasurement() => _method.invokeMethod('stopMeasurement');

  // One call per value — same as [startMeasurement] with the matching [HBandMeasureType].
  static Future<HBandMeasureResult> measureHeartRate() => startMeasurement(HBandMeasureType.heartRate);
  static Future<HBandMeasureResult> measureBloodPressure() => startMeasurement(HBandMeasureType.bloodPressure);
  static Future<HBandMeasureResult> measureSpo2() => startMeasurement(HBandMeasureType.spo2);
  static Future<HBandMeasureResult> measureBodyTemp() => startMeasurement(HBandMeasureType.bodyTemp);
  static Future<HBandMeasureResult> measureFatigue() => startMeasurement(HBandMeasureType.fatigue);
  static Future<HBandMeasureResult> measureBloodGlucose() => startMeasurement(HBandMeasureType.bloodGlucose);
  static Future<HBandMeasureResult> measureEcg() => startMeasurement(HBandMeasureType.ecg);
  static Future<HBandMeasureResult> measurePtt() => startMeasurement(HBandMeasureType.ptt);
  static Future<HBandMeasureResult> measureStress() => startMeasurement(HBandMeasureType.stress);
  static Future<HBandMeasureResult> measureHrv() => startMeasurement(HBandMeasureType.hrv);
  static Future<HBandMeasureResult> measureRespiratory() => startMeasurement(HBandMeasureType.respiratory);
  static Future<HBandMeasureResult> measureBloodComponent() => startMeasurement(HBandMeasureType.bloodComponent);
  static Future<HBandMeasureResult> measureBodyComposition() => startMeasurement(HBandMeasureType.bodyComposition);
  static Future<HBandMeasureResult> measureGsr() => startMeasurement(HBandMeasureType.gsr);
  static Future<HBandMeasureResult> measureMet() => startMeasurement(HBandMeasureType.met);
  static Future<HBandMeasureResult> measureEmotion() => startMeasurement(HBandMeasureType.emotion);
  static Future<HBandMeasureResult> measureCheckup() => startMeasurement(HBandMeasureType.checkup);

  /// Live values / progress / ECG waveform of the running measurement.
  static Stream<HBandMeasureUpdate> get measurementUpdates =>
      _progressStream.where((m) => m['kind'] == 'measure').map(HBandMeasureUpdate.fromMap);

  static Stream<Map<dynamic, dynamic>> get _progressStream =>
      _progressRaw ??= _progress.receiveBroadcastStream().cast<Map<dynamic, dynamic>>().asBroadcastStream();

  // ---------------------------------------------------------------------------
  // Call Bluetooth + contacts (SOS calls are placed by the watch through the phone)
  // ---------------------------------------------------------------------------

  /// Last known call-Bluetooth state (no watch command).
  static Future<HBandCallBluetoothState> getCallBluetoothState() async =>
      HBandCallBluetoothState.fromMap(await _method.invokeMapMethod('getCallBluetoothState'));

  /// Asks the watch for its call-Bluetooth state.
  static Future<HBandCallBluetoothState> readCallBluetoothState() async =>
      HBandCallBluetoothState.fromMap(await _method.invokeMapMethod('readCallBluetoothState'));

  /// Pairs / connects the watch's call Bluetooth with this phone. Android shows the
  /// system pairing dialog the first time; on iOS this switches the watch's call
  /// Bluetooth on and the user pairs it in Settings → Bluetooth.
  /// Follow the result on [callBluetoothState]. With `autoPairCallBluetooth` (see [connect])
  /// Android does this by itself; call it to retry, e.g. after the user dismissed the dialog.
  static Future<void> connectCallBluetooth() => _method.invokeMethod('connectCallBluetooth');

  /// Android only. Also pauses auto-pairing until the next watch connection.
  static Future<void> disconnectCallBluetooth() => _method.invokeMethod('disconnectCallBluetooth');

  /// Call-Bluetooth changes (the watch reports them on its own, e.g. after pairing).
  static Stream<HBandCallBluetoothState> get callBluetoothState => _callBtStream ??= _callBt
      .receiveBroadcastStream()
      .map((e) => HBandCallBluetoothState.fromMap(e as Map<dynamic, dynamic>))
      .asBroadcastStream();

  static Future<HBandContactSupport> getContactSupport() async =>
      HBandContactSupport.fromMap(await _method.invokeMapMethod('getContactSupport'));

  /// Contacts stored on the watch. Throws [PlatformException] `NOT_READY`, `BUSY`,
  /// `UNSUPPORTED`, `TIMEOUT` or `FAILED`.
  static Future<List<HBandContact>> getContacts() async => _contacts(await _method.invokeListMethod('getContacts'));

  /// Adds a contact; with [sos] the watch calls it when SOS is pressed. Returns the new list.
  static Future<List<HBandContact>> addContact({required String name, required String phone, bool sos = false}) async =>
      _contacts(await _method.invokeListMethod('addContact', {'name': name, 'phone': phone, 'sos': sos}));

  static Future<List<HBandContact>> deleteContact(HBandContact contact) async =>
      _contacts(await _method.invokeListMethod('deleteContact', {'id': contact.id}));

  /// Marks / unmarks [contact] as an SOS contact. Returns the new list.
  static Future<List<HBandContact>> setSosContact(HBandContact contact, bool enabled) async =>
      _contacts(await _method.invokeListMethod('setSosContact', {'id': contact.id, 'enabled': enabled}));

  /// How many rounds the watch calls the SOS contacts, with the allowed range.
  static Future<HBandSosCallTimes> getSosCallTimes() async =>
      HBandSosCallTimes.fromMap(await _method.invokeMapMethod('getSosCallTimes'));

  static Future<HBandSosCallTimes> setSosCallTimes(int times) async =>
      HBandSosCallTimes.fromMap(await _method.invokeMapMethod('setSosCallTimes', {'times': times}));

  static List<HBandContact> _contacts(List<dynamic>? list) => [
    for (final item in list ?? const []) HBandContact.fromMap(item as Map<dynamic, dynamic>),
  ];

  // ---------------------------------------------------------------------------
  // Diagnostics / platform specifics
  // ---------------------------------------------------------------------------

  /// Last raw BLE frames (`incoming` watch→phone, `outgoing` phone→watch).
  static Future<({List<String> incoming, List<String> outgoing})> getRawFrames({int lines = 30}) async {
    final map = await _method.invokeMapMethod<String, dynamic>('getRawFrames', {'lines': lines});
    List<String> read(String key) => (map?[key] as List?)?.cast<String>() ?? const [];
    return (incoming: read('incoming'), outgoing: read('outgoing'));
  }

  /// Android only (iOS always returns true).
  static Future<bool> isIgnoringBatteryOptimizations() async =>
      await _method.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? true;

  /// Android only: opens the "allow background run" system dialog.
  static Future<bool> requestIgnoreBatteryOptimizations() async =>
      await _method.invokeMethod<bool>('requestIgnoreBatteryOptimizations') ?? false;
}
