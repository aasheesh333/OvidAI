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

## Review Follow-Up

The Task 10 review identified inaccurate disclosure copy, metadata-only image handling, a screenshot-directory symlink escape, incomplete schemas, and unhandled Accessibility Settings launch errors.

### Follow-Up RED Evidence

- Focused Flutter tests initially failed to compile because the provider-consumable image queue did not exist.
- The screenshot symlink regression demonstrated that the previous lexical destination could follow `device-screenshots` outside the workspace.
- The disclosure UI test reproduced an uncaught `PlatformException(SETTINGS_FAILED)` from the settings launch.
- The focused Android test initially failed to compile because password refusal was embedded in the Android node method and had no pure action-policy seam.

### Follow-Up Changes

- Replaced the inaccurate privacy claim with explicit disclosure that screen structure and screenshots may be stored in the chat/workspace, are sent to the selected provider, and are subject to that provider's retention policy.
- `device_screenshot` and `read_image` now stage actual base64 `image_url` content in the current run's next [OI]-compatible chat-completions request. Known text-only or unknown models get an honest unsupported response instead.
- Screenshot capture now canonicalizes the workspace, rejects a symlinked capture directory, verifies canonical containment, uses an unpredictable filename, and creates it exclusively before streaming bytes.
- Every device schema now sets `additionalProperties: false`; `device_tap` publishes `anyOf` for either `node` or the `x`/`y` pair while retaining runtime validation.
- Initial and retry Accessibility Settings launch failures are caught. Control remains selected; the UI displays a controlled snackbar and inline retry/error state.
- Added a pure Android password-refusal policy seam and JVM regression coverage.

### Follow-Up GREEN Evidence

- Focused Flutter review tests (`CTRL3|CTRL4|SAFE1|CTRL5|CTRL6|CTRL7`): 8 passed.
- Focused Android password-refusal JVM test: passed.
- `flutter test test/core_regression_test.dart`: 407 passed.
- Full `flutter test`: 407 passed.
- `flutter analyze`: no issues found.
- `./gradlew :app:testDebugUnitTest`: BUILD SUCCESSFUL.
- `flutter build apk --debug`: built `build/app/outputs/flutter-apk/app-debug.apk`.
- `git diff --check`: passed.
- `reference-web` scan under `lib/` and `test/`: zero matches.
- Aggregate `./gradlew testDebugUnitTest` still fails only in the third-party `flutter_plugin_android_lifecycle` Mockito test described above; the application JVM suite completes successfully.
