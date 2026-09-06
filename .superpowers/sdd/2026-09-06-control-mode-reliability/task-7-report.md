# Task 7 Report: Page File Selector and SAF Export

## Overview

Implemented Task 7 without adding a second native channel handler:

- Added Android WebView `setOnShowFileSelector` wiring in the existing
  `AgentService.controllerForTab` path.
- Delegated user page file selection to the existing `file_picker` dependency.
- Honored WebView multi-select requests and returned Android content URIs when
  available, with `file:` URI fallback for ordinary paths.
- Added production `AgentService.exportFileToSaf`, plus the requested testing
  wrapper, with lexical and canonical symlink containment checks before any
  native call.
- Added `safExportFile` to the existing `ovid/native` method channel in
  `MainActivity`.
- Implemented `ACTION_CREATE_DOCUMENT` with a pending method result and
  `onActivityResult`; source bytes are copied only after the user selects a
  destination, and cancellation, launch failure, missing sources, and copy
  errors are surfaced distinctly.
- Declared `webview_flutter_android` directly because the Dart code consumes
  `AndroidWebViewController`.
- Accepted Flutter's required `minSdk = flutter.minSdkVersion` migration after
  the direct Gradle build proved current plugins declare a minimum API of 24.

Existing uncapped streaming download/upload behavior and canonical symlink
containment were preserved.

## TDD Evidence

### RED

The brief's required test was added first and failed because the production
seam did not exist:

```text
Error: The method 'exportFileToSafForTest' isn't defined for the type 'AgentService'.
```

Additional RED cycles caught two important omissions before implementation:

- The first export implementation used lexical containment only. SAF2 created
  an in-workspace symlink to an outside file and failed with `exported` instead
  of rejecting the path.
- SAF4 failed until `MainActivity` had an Activity Result callback that opened
  the selected content URI and copied the source stream.
- SAF5 failed until the page file URI normalizer and Android chooser wiring
  existed.
- A final review RED cycle caught that the initial helper was only named
  `exportFileToSafForTest`; the production `exportFileToSaf` API is now the
  implementation and the test method is a delegating seam.

### GREEN

Focused Task 7 tests pass:

```text
flutter test test/core_regression_test.dart --plain-name "SAF"
00:12 +5: All tests passed!
```

SAF1-SAF5 cover lexical escape rejection, symlink escape rejection before the
channel is called, native success/cancellation propagation, post-result byte
copy markers, content URI/file URI mapping, multi-select wiring, and chooser
event logging.

## Verification

- `/home/ubuntu/sdk/flutter/bin/flutter test`: **396 tests passed**.
- `/home/ubuntu/sdk/flutter/bin/flutter analyze`: **No issues found**.
- `/home/ubuntu/sdk/flutter/bin/flutter build apk --debug`: **passed**.
- `git diff --check`: **clean**.
- `reference-web` scan in `lib/` and `test/`: **zero matches**.
- APK: `build/app/outputs/flutter-apk/app-debug.apk`.

## Self-review

- `MainActivity` continues to own the single `ovid/native` channel handler.
- `safExportFile` does not report success when the chooser merely opens; the
  pending result resolves only after the destination is selected and the full
  source stream is copied.
- SAF copying runs on a worker thread so uncapped exports do not block the
  activity UI thread; the pending method result is completed on the UI thread.
- The source is checked with `File.isFile`, and the Dart caller performs both
  lexical and canonical workspace containment checks before native invocation.
- Destination names are reduced to a basename before being placed in
  `EXTRA_TITLE`, avoiding path injection into the system picker.
- The native result is consumed once. Unrelated activity results continue to
  Flutter's superclass implementation.
- No file-size cap or whole-file buffering was introduced in the existing
  browser download/upload paths.

## Concerns

- The test environment cannot open a real Android DocumentsUI or WebView, so
  the actual picker UX and content-provider copy are verified by the Android
  compile plus focused contract tests rather than an emulator integration test.
- The app uses `FlutterActivity`, which exposes the legacy
  `startActivityForResult`/`onActivityResult` lifecycle rather than
  `ComponentActivity`'s `ActivityResultContracts` API. The implementation
  retains the Flutter-compatible callback path and resolves the pending
  method result only after copy completion.
- The file chooser intentionally catches picker failures and returns an empty
  selection, matching WebView's cancel contract; the transcript event is only
  emitted for returned URIs.
- Current Flutter plugins no longer permit the prior API 23 app minimum, so the
  debug APK now targets Flutter's API 24 minimum. The existing sandbox
  preflight's Android 6 diagnostic remains valid for hosts/tests but Android 6
  can no longer install this build.

## Commit

`feat: page file chooser integration and SAF export support` (this task commit).
