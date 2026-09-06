# Task 10 Report: Device-Wide Control Tools, Safety, Disclosure, and Screenshot Fallback

## Status

Implemented the complete Dart-side device control surface and Control-mode disclosure flow.

## RED Evidence

Command:

`/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name 'CTRL3|CTRL4|SAFE1|CTRL5|CTRL6|CTRL7'`

Initial result: compilation failed because `kControlModeDisclosure`, `kDeniedControlPackages`, `kDeniedControlDomains`, and `DeviceControlService.setMethodChannelForTest` did not exist. This established that the new safety constants and platform-channel seam were absent before implementation.

The first disclosure widget run also exposed a real bottom-sheet overflow. The mode picker was made scrollable and the test was rerun.

## Implementation

- Added `DeviceControlService` over `MethodChannel('ovid/native')`, including an injectable test channel, full/delta reads, compact node formatting, sensitive-target checks, and native action methods.
- Added complete schemas and dispatch for `device_read`, `device_tap`, `device_type`, `device_swipe`, `device_system_nav`, and `device_screenshot`.
- Added all six tools to the Read-Only and plan-mode mutating gates, required `AgentMode.control`, and denied subagent use.
- Added live foreground package checks before actions, plus active Ovid browser-tab URL checks for denied financial domains. Native password-field refusal remains the final `device_type` defense.
- Mutating actions fail closed when the live foreground package cannot be verified.
- Kept node/delta reads primary. No action or empty read implicitly invokes screenshot capture.
- Copied explicit screenshots from native cache into a containment-checked `device-screenshots/` path in the session workspace, recorded the produced file, and returned a `read_image` instruction.
- Emitted a `shell` event for every successful device tool action.
- Added prominent `Not now` / `Enable Control` disclosure for both `/permission control confirm` and mode-picker selection. Accessibility Settings opens only after acceptance. Control remains selected when the service is disabled and an inline retry action is shown.
- Restored the deferred `activeSessionId` cleanup in the existing CTRL1 test.

## GREEN Evidence

- Focused Task 10 tests: 6 passed.
- `flutter test test/core_regression_test.dart`: 405 passed.
- Full `flutter test`: 405 passed.
- `flutter analyze`: no issues found.
- `./gradlew :app:testDebugUnitTest`: BUILD SUCCESSFUL.
- `flutter build apk --debug`: built `build/app/outputs/flutter-apk/app-debug.apk`.
- `git diff --check`: passed.
- `reference-web` scan under `lib/` and `test/`: zero matches.

## Android Aggregate Test Concern

`./gradlew testDebugUnitTest` reached and passed `:app:testDebugUnitTest`, then failed in the third-party `flutter_plugin_android_lifecycle:testDebugUnitTest` Mockito setup (`FlutterLifecycleAdapterTest.java:26`). The isolated application JVM suite passes, and the debug APK builds successfully. Existing Gradle warnings also note deprecated Kotlin plugin configuration in several dependencies.
