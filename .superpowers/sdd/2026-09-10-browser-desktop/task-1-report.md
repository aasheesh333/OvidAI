# Task 1 Report — Readable scale and separate user zoom

Plan: `docs/superpowers/plans/2026-09-10-browser-desktop.md` (Task 1)
Spec: `docs/superpowers/specs/2026-09-10-browser-desktop-design.md` §5.1
Branch: `hoplite/gortyn-77773150` · Baseline: `d2b0f58`

## What was implemented

Desktop mode no longer shrinks content to `devW/1280` (~0.28 on a phone). Visual
scale is now a separate, user-controlled value:

1. `BrowserTab.userZoom` added (`lib/core/agent_service.dart`): default `1.0`,
   clamped to `0.5..2.0` in the setter (`minUserZoom`/`maxUserZoom`). `zoom`
   remains the **logical** viewport factor that feeds `logicalWidth/Height`
   (media queries) and `browser_resize` — it is no longer the visual scale.
2. `_applyTabZoom` injects `browserZoomScriptForTest(tab.userZoom)`; the JS
   builder is a pure `@visibleForTesting` static so the injected value is
   testable without a WebView platform.
3. `setTabDesktopMode` no longer sets `tab.zoom` from `devW/1280` (nor resets it
   to `1.0` on mobile). It keeps desktop UA + `applyDesktopViewport(desktop)` +
   controller recreation only.
4. Controller init (`controllerForTab`, `!tab.loadedOnce` branch) no longer sets
   `tab.zoom = devW/1280`; desktop mode still sets the desktop UA before first
   load.
5. `browser_desktop` tool result now reports `userZoom` (the visual scale)
   instead of the logical `zoom`.
6. Existing desktop tests updated deliberately:
   - `BRD:` renamed/asserts desktop mode leaves `zoom`/`userZoom` at `1.0`.
   - `PR27` "new tabs render at a readable scale (no device-derived zoom)".
   - `BRD2` asserts `_applyTabZoom` uses `tab.userZoom` (never `tab.zoom`), the
     builder injects `style.zoom`, and `setTabDesktopMode` has no `devW / 1280`.

## What was tested and results

| Command | Result |
|---|---|
| `flutter test test/browser_desktop_scale_test.dart` | **7/7 pass** |
| `flutter test test/core_regression_test.dart` | **557/557 pass** |
| `flutter test` (full suite) | **962/962 pass** (baseline 955 + 7 new) |
| `flutter analyze` | **No issues found** |
| `git diff --check` | clean |

Targeted desktop check: `flutter test test/core_regression_test.dart --name "BRD|readable scale"` → 3/3 pass.

## TDD evidence

**RED** — `flutter test test/browser_desktop_scale_test.dart` before implementation:

```
test/browser_desktop_scale_test.dart:46:11: Error: The setter 'userZoom' isn't defined for the type 'BrowserTab'.
test/browser_desktop_scale_test.dart:47:18: Error: The getter 'userZoom' isn't defined for the type 'BrowserTab'.
...
00:00 +0 -1: Some tests failed.
```

Missing `userZoom`, missing `browserZoomScriptForTest`, and the source still
contained `devW / 1280` — i.e. the feature was absent, as expected.

**GREEN** — same command after implementation:

```
00:00 +7: injected CSS scale source no longer injects devW/1280 as a visual scale
00:00 +7: All tests passed!
```

## Files changed

- `lib/core/agent_service.dart` — `BrowserTab.userZoom` + clamp; `browserZoomScriptForTest`; `_applyTabZoom` uses `userZoom`; removed `devW/1280` from `setTabDesktopMode` and controller init; `browser_desktop` result reports `userZoom`.
- `test/browser_desktop_scale_test.dart` — new (7 tests: default, clamp, desktop-mode non-shrink, mode-toggle preserves user zoom, injected scale equals `userZoom`, `_applyTabZoom` wiring, no `devW/1280`).
- `test/core_regression_test.dart` — 3 desktop tests updated deliberately.

## Self-review findings

- Diff reviewed: only the browser-scale sites in `agent_service.dart` plus the
  three desktop tests changed. No other regions touched.
- `devW / 1280` no longer appears as executable code anywhere in `lib/` (only a
  historical comment in `setTabDesktopMode`); verified by grep and by a test.
- `browser_resize` is untouched: it still sets `tab.zoom = devW/w` for the
  logical viewport and still injects `style.zoom` for immediate effect. Its
  logical-width semantics are preserved.
- `@visibleForTesting` use within the defining library analyzes clean.

## Issues / concerns

- **`browser_resize` still visually shrinks.** Task 1 removed the desktop-mode
  shrink only. `browser_resize` continues to inject `tab.zoom` directly; on the
  next page load `_applyTabZoom` re-applies `userZoom`, so the two can disagree
  until the native per-tab viewport work (Task 2, spec §5.2/§5.1) routes
  `browser_resize` through the native viewport API and stops the visual shrink.
  Left intentionally within Task 1's boundary; flagged for Task 2.
- **Native/device behavior NOT EXECUTED.** The wide-viewport/UA effect on a real
  Android WebView is not verifiable in headless tests; only Dart-side scale
  behavior is covered.
- **Persistence NOT in scope.** `userZoom` is not persisted yet (Task 3).
- The `browser_desktop` tool result string changed from `zoom=` to `userZoom=`;
  no test asserted the old text (grep confirmed), but this is an
  agent/user-visible string change.
