## 0.0.2

* Sleep: precise sleep segments linked by `lastType` / `nextType` (iOS) or `laster` / `next`
  (Android) are joined into one record per night (start of the first segment, end of the last,
  durations for the whole night, scores of the last segment, new `segments` field).
  `awakeShort` = `getUpDuration`, `rem` = REM minutes of the curve.
* Sleep: `sleep_line` is one digit per minute on both platforms; corrupt segments (longer than
  24 h or in the future) are skipped.
* Body temperature measurement (Android + iOS): retries up to 3 times when the watch is busy and
  keeps `base_temp` from earlier callbacks.
* History sync: a step is given up after 30 s without progress instead of its full timeout.
* RR interval only reads blocks not read before. New `HBandSdk.confirmHealthUpload()`: call it
  after the sync's records reached the backend; until then the same blocks are read again.

## 0.0.1

* On-demand measurement: added `hrv`, `respiratory`, `bloodcomponent`, `bodycomposition`, `gsr`,
  `met`, `emotion`, `checkup` (Android + iOS), one `HBandSdk.measureXxx()` call per value,
  `HBandCapabilities.measurements` / `canMeasure`, `HBandMeasureResult.records` /
  `toInsertRequests`, `HBandMeasureUpdate.leadOff`.
* SOS call count defaults to 1: set once per paired watch after its first session (Android + iOS);
  a count changed later with `setSosCallTimes` is kept, forget + re-pair applies it again.
* `setEmergencyNotification(bool)` (Android + iOS): turns off the plugin's own "Emergency from
  watch" notification for apps that show their own SOS alert. Saved, kept across `forgetWatch`,
  on by default; detection, events, the saved feed and the webhook are unchanged.
* iOS: a watch whose link iOS already holds (connected for calls) no longer advertises; scans now
  also report it from the system. `startScan` takes optional `watchId` / `watchName` to find it
  when no saved session identifies it.
* iOS: the session id and `getImei()` are always the watch MAC (as on Android), never the
  CoreBluetooth UUID. A watch found through the system link is listed by its UUID until it is
  connected; its MAC is then read from the chip and saved.

## 0.0.1

* TODO: Describe initial release.
