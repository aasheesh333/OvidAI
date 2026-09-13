# 24/7 Background Operation — Design

**Date:** 2026-09-13
**Status:** Approved for implementation.

## 1. Goal

Keep Ovid running as a personal always-on agent for as long as possible — until
the user stops it from the notification (in-app stop), powers off the phone, or
force-quits — using a hardened foreground service, boot restart, and battery
exemption, with honest disclosure of Android/OEM limits.

## 2. Outcomes

1. While Ovid is active (running or keep-alive), a foreground service with a
   persistent notification keeps the process alive with a partial wake lock.
2. The notification offers **Stop** (end the current run, keep the app ready) and
   **Exit** (stop the service and finish), plus an in-app control.
3. After a reboot the service/agent resumes automatically (boot receiver).
4. The app prompts for battery-optimization exemption so OEM killers are less
   likely to kill it.
5. Honest limits are documented: Doze, Android 14+ `dataSync` FGS time limits,
   and aggressive OEM killers can still stop it.

## 3. Non-Goals

- Guaranteeing survival of force-quit (impossible by Android design).
- Background location/camera/etc.
- Bypassing OS battery policy.

## 4. Current Failure Model (evidence)

- `AgentForegroundService.kt` exists (`foregroundServiceType="dataSync"`,
  `START_STICKY`, partial wake lock, notification with Stop/Exit;
  `AndroidManifest.xml:70-74`). Started/updated from
  `agent_notification_service.dart` and `MainActivity.kt:235-292`.
- **No** `BOOT_COMPLETED` receiver (`AndroidManifest.xml:87-89` only declares
  `AgentStopReceiver`) → no restart after reboot.
- No battery-optimization exemption request.
- Keep-alive setting `AppState.keepAliveEnabled` (`state.dart:3516-3534`).
- No in-app UI to stop the foreground service directly.

## 5. Design

### 5.1 Foreground service hardening
Keep `dataSync` FGS; ensure it is started whenever Ovid is active and re-asserted
on task removal. Add an Android 14+ `dataSync` timeout handling path (re-start /
notify) and a clear channel.

### 5.2 Boot restart
Add a `BOOT_COMPLETED` (and `QUICKBOOT_POWERON`) receiver that, if keep-alive is
enabled, starts the service.

### 5.3 Battery exemption
Prompt for `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` and deep-link to the OEM
autostart settings where possible; disclose what it does.

### 5.4 In-app stop
Add an in-app control (Settings/health) mirroring the notification Stop/Exit.

## 6. Testing

- Unit: keep-alive → service start/update/stop intent sequences.
- Manifest/Kotlin pins for the boot receiver + FGS type.
- Full `flutter test` + `flutter analyze` green.
- Device rows `NOT EXECUTED`; OEM behavior disclosed.

## 7. Decisions

- Best-effort always-on, never a guarantee.
- Stop ≠ Exit: Stop ends the run, Exit stops the service.
- Boot restart only when keep-alive is enabled.
