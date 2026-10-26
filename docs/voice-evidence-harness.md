# Voice Evidence Harness

This document records the on-device audio evidence gate and the attempts made to obtain real audio evidence on the emulator.

## Release Gate

Voice is gated by `kOvidVoiceEnabled` in `lib/core/voice_capability.dart`. The flag is `false` in this release, so the app reports voice unavailable regardless of device capability. The flag must stay off; the harness verifies it has not been bypassed.

## On-Device Speech Recognition

The native side uses Android's `SpeechRecognizer.createOnDeviceSpeechRecognizer`. It requires:

- Android 13+ (`Build.VERSION.SDK_INT >= 33`)
- `SpeechRecognizer.isOnDeviceRecognitionAvailable(context)`
- The requested locale to be in both `supportedOnDeviceLanguages` and `installedOnDeviceLanguages`

## Emulator Attempts

Attempts were made on the `ovid34` AVD (API 34, `google_apis` system image):

1. Booted the emulator and confirmed API 34.
2. Checked speech packages: `com.google.android.tts` and `com.google.android.googlequicksearchbox` are present.
3. Attempted to trigger language pack downloads via `com.google.recognition.action.DOWNLOAD_LANGUAGE`.
4. Tried to set system and per-app locales to `en-IN`.
5. Verified the emulator has no network access (`ping: Network is unreachable`).
6. Verified the system image has no baked-in on-device speech language packs.
7. Confirmed only the `google_apis` system image is available for API 34; no Play Store image is installed.

## Impossibility Proof

Real on-device audio evidence cannot be obtained on the current emulator because:

- The `google_apis` system image does not include pre-installed on-device STT language packs for `en-IN`, `hi-IN`, `pa-IN`, or `ta-IN`.
- The emulator has no network connectivity, so Play Services cannot download the packs.
- No Play Store system image is available to install an alternative image with packs baked in.
- The release flag `kOvidVoiceEnabled` remains off, so the app gate fails closed with a schema-valid `blocked` report.

## Physical Device Requirements

A physical device would need:

- Android 13 or later
- Google Play Services
- A network connection (for first-time pack download)
- Downloaded on-device speech recognition language packs for the target locales (`en-IN`, `hi-IN`, `pa-IN`, `ta-IN`)
- Installed TTS voices for the same locales

## Harness Tests

- Dart unit tests cover pause/resume edges, error paths, and privacy assertions.
- Python acceptance harness tests validate report schema, sanitized artifacts, and server audit contracts.
