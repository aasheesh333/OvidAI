# Task 2 Report — Per-tab native viewport settings

Plan: `docs/superpowers/plans/2026-09-10-browser-desktop.md` (Task 2)
Spec: `docs/superpowers/specs/2026-09-10-browser-desktop-design.md` §5.2
Branch: `hoplite/gortyn-77773150` · Baseline: `e82425e`

## What was implemented

Native WebView viewport settings are now per-tab; toggling one tab cannot
change another.

1. `BrowserTab.id` (`lib/core/agent_service.dart`): a stable, launch-unique
   identity assigned at construction (`_nextTabId++`). WebViews never outlive
   the launch, so this is sufficient and does not interact with Task 3
   persistence.
2. `AgentService.webViewIdentifierFor(tab)`: resolves a tab's native WebView
   identifier via `AndroidWebViewController.webViewIdentifier` (null on
   non-Android / no controller).
3. `AgentService.applyDesktopViewport(enabled, {tabId, webViewIdentifier})`:
   sends the tab identity with the channel payload. Identity keys are omitted
   when absent, so the legacy bool-only payload (and its existing test) still
   holds.
4. `setTabDesktopMode` and `controllerForTab` both pass `tabId: tab.id` +
   `webViewIdentifierFor(tab)`, so the setting is scoped to the target tab
   (including the fresh controller after a mode-change recreate).
5. `OvidWebViewHandler.kt`: removed the global companion static
   (`desktopEnabled`, `lastDesktopViewport`, `applyToWebView`) and the
   decor-view `traverseAndApply`. The handler now resolves the single native
   WebView from the passed `webViewIdentifier` via
   `WebViewFlutterAndroidExternalApi.getWebView` and applies settings to that
   view only. No identifier → `applied: false`, and nothing is touched.
6. Desktop flags are now `useWideViewPort(true)` + `loadWithOverviewMode(false)`
   (no overview auto-fit); mobile restores the platform defaults
   (`useWideViewPort(false)` + `loadWithOverviewMode(true)`).
   `setSupportMultipleWindows(true)` (platform default) is applied for both.
   The desktop UA is owned by Dart (`setUserAgent`) only — the native UA write
   was removed, so nothing can leak across a recreate.
7. `MainActivity.kt`: passes the `FlutterEngine` to `OvidWebViewHandler` so the
   handler can resolve WebViews by identifier.

## What was tested and results

| Command | Result |
|---|---|
| `flutter test test/browser_desktop_per_tab_test.dart` | **9/9 pass** |
| `flutter test test/browser_desktop_scale_test.dart` | **7/7 pass** |
| `flutter test test/core_regression_test.dart` | **557/557 pass** |
| `flutter test` (full suite) | **971/971 pass** (baseline 962 + 9 new) |
| `flutter analyze` | **No issues found** |
| `./gradlew :app:compileDebugKotlin` | **BUILD SUCCESSFUL** |
| `git diff --check` | clean |

## TDD evidence

**RED** — `flutter test test/browser_desktop_per_tab_test.dart` before
implementation:

```
test/browser_desktop_per_tab_test.dart:77:34: Error: The getter 'id' isn't defined for the type 'BrowserTab'.
...
00:00 +0 -1: Some tests failed.
```

The feature was absent: no `BrowserTab.id`, no per-tab named payload, and the
native handler still held the companion static + decor-view traversal.

**GREEN** — same command after implementation:

```
00:00 +9: All tests passed!
```

## Files changed

- `lib/core/agent_service.dart` — `BrowserTab.id`; `webViewIdentifierFor`;
  per-tab `applyDesktopViewport` payload; identity at both call sites.
- `android/app/src/main/kotlin/com/dhanuk/ovidai/OvidWebViewHandler.kt` —
  per-WebView resolution, no companion static / traversal; corrected desktop
  viewport flags; no native UA write.
- `android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt` — pass
  `FlutterEngine`.
- `test/browser_desktop_per_tab_test.dart` — new (9 tests).

## Self-review findings

- Diff reviewed: only the browser viewport sites in `agent_service.dart`, the
  two Kotlin files, and the new test. `.superpowers/brainstorm/` untouched.
- The existing core-regression tests were not modified: the bool-only
  `applyDesktopViewport(true/false)` payload is preserved by omitting null
  identity keys, so `PR10: real desktop viewport platform channel…` and
  `applyDesktopViewport dispatches setDesktopViewport…` stay green unchanged.
- `grep` confirms `traverseAndApply`, `decorView`, `desktopEnabled`, and
  `lastDesktopViewport` are gone from the Kotlin handler.
- Kotlin compiles (`compileDebugKotlin`), so the new external-API import and
  constructor change are valid.

## Issues / concerns

- **Native/device behavior NOT EXECUTED.** Resolving `webViewIdentifier` to the
  live WebView and the on-screen effect of `useWideViewPort` /
  `loadWithOverviewMode` require a real Android device/emulator; only Dart-side
  payloads, source invariants, and Kotlin compilation are verified here.
- **Deprecated external API.** `WebViewFlutterAndroidExternalApi.getWebView(
  FlutterEngine, long)` is the only lookup overload usable from the app module
  (the non-deprecated one needs a `FlutterPluginBinding` we don't hold); it is
  `@Suppress("DEPRECATION")`. A future webview_flutter_android bump should
  migrate to the binding overload.
- **Ordering assumption.** `webViewIdentifier` is assigned synchronously in
  Dart at controller construction, and the `ovid/webview` call is queued after
  the Pigeon `create` message and before `loadRequest`, so the native WebView
  should exist when the handler runs. This ordering is not device-verified; if
  a race ever drops a setting, `applied: false` is returned and the next
  navigation re-applies via `controllerForTab`.
- **Mobile `layoutAlgorithm`** stays `NARROW_COLUMNS` (pre-existing behavior);
  the brief's "mobile: defaults" was applied to the two viewport flags only.
