# Task 9 Report: Android Device-Control Bridge

## Status

Complete. The Android accessibility service, cached node-tree reader, action bridge, explicit screenshot path, manifest/resources, and tests are implemented.

## Implementation

- Added `OvidAccessibilityService` with event-only dirty marking and on-demand depth-first traversal.
- Added stable handles, retained `AccessibilityNodeInfo` copies, deterministic recycling on rebuild/unbind/destroy, full-window invalidation, and added/changed/removed deltas.
- Added node click, coordinate tap, text entry, guarded IME submit, swipe, global navigation, and explicit screenshot actions.
- Added native password-field refusal and refreshes retained nodes before typing.
- Isolated API 24 gesture calls and API 30 IME/screenshot calls behind SDK guards to preserve API 23 loading.
- Split accessibility metadata so `canTakeScreenshot` is present only in `xml-v30`; API 23 uses the base resource.
- Routed all eight device methods through the existing `ovid/native` handler without replacing SAF or foreground-service cases.
- Added source-contract coverage and executable JVM tests for stable keys/handles and full/delta state behavior.

## Verification

- Focused Flutter: `flutter test test/core_regression_test.dart --plain-name "CTRL2"` passed (1 test).
- Android JVM: `./gradlew :app:testDebugUnitTest` passed, including `OvidAccessibilityServiceStateTest` and existing SAF tests.
- Full Flutter: `flutter test test/core_regression_test.dart` passed (399 tests).
- Analyze: `flutter analyze` passed with no issues.
- Debug APK: `flutter build apk --debug` passed and produced `build/app/outputs/flutter-apk/app-debug.apk`.
- Diff check: `git diff --check` passed.

## Concerns

- Android 6 / API 23 can read the node tree, click semantic nodes, type text, and use global navigation. Coordinate gestures require the platform API introduced in Android 7 / API 24 and return `UNSUPPORTED` on API 23.
- IME Enter is attempted only on API 30+, where `ACTION_IME_ENTER` exists. Older devices still enter text and return an explicit message that submit was not performed.
- Screenshots remain explicit-only and return `UNSUPPORTED` below API 30; no action captures a screenshot automatically.
- The build retains pre-existing warnings about Flutter's future API 23 support and plugins using the legacy Kotlin Gradle plugin. They do not fail this build.
