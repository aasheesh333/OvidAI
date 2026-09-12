# Browser Desktop Compatibility — Task 4 Release Gate Audit

Date: 2026-09-12 · Branch `hoplite/gortyn-77773150` · Baseline `ef71433` · Task 4 verification commit (this commit)

This audit is the release gate for the Browser Desktop Compatibility project (spec
`docs/superpowers/specs/2026-09-10-browser-desktop-design.md`, plan
`docs/superpowers/plans/2026-09-10-browser-desktop.md`). It records the
automated verification matrix and the per-outcome evidence for the four promised
behaviors, then the device-only checklist with its execution status.

**Device checks were NOT executed.** No Android device or emulator is attached
to this environment. Every on-device row in §7 is marked `NOT EXECUTED`, not
`passed`. Nothing on-device was run and nothing on-device is claimed.

This is a test/docs-only task. No production behavior was changed. The new
end-to-end gate surfaced no defect, so no RED-first fix was required.

## 1. Verification matrix (exact counts)

All commands run with `/root/flutter/bin/flutter` on 2026-09-12,
working tree at baseline `ef71433` plus the Task 4 test/docs changes.
(The plan's `/home/ubuntu/sdk/flutter/bin/flutter` path does not exist on this
machine; the actual binary is `/root/flutter/bin/flutter`.)

`flutter --version`:

```text
Flutter 3.47.4 • channel stable • https://github.com/flutter/flutter.git
Framework • revision 9584c6713b (32 hours ago) • 2026-09-10 15:25:10 -0700
Engine • hash 0e228ec8c8d2abc9fcf1d053e8a40665bb859ec7 (revision 06a2e2a110) (8 days ago) • 2026-09-03 16:07:13.000Z
Tools • Dart 3.13.3 • DevTools 2.60.0
```

`ANDROID_HOME=/opt/android-sdk`, Java 17 present, Android SDK 36.0.0, licenses
accepted.

| Command | Result |
|---|---|
| `flutter test test/browser_desktop_parity_test.dart` | 6/6 passed (new) |
| `flutter test` (4 browser-desktop suites) | 32/32 passed (7 scale + 9 per-tab + 10 persistence + 6 parity) |
| `flutter test` (all files) | 987/987 passed (981 baseline + 6 new) |
| `flutter analyze --no-pub` | 2 pre-existing warnings, 0 errors (ran in 61.1 s) |
| `flutter build apk --debug` | FAILED (toolchain, see §8 — no APK produced, no SHA) |
| `git diff --check` | clean |

The focused set is `browser_desktop_scale`, `browser_desktop_per_tab`,
`browser_desktop_persistence`, and the new `browser_desktop_parity`.

`flutter analyze` reports only two pre-existing
`unawaited_return_in_try_block` warnings
(`lib/core/agent_service.dart:6780`, `lib/core/hook_service.dart:317`).
Neither file is touched by this task (test/docs-only); the new parity test
introduces no analyzer issue. There are no errors.

`pubspec.lock` was not dirtied: `git status` shows only the three intended
files (no lock bump to revert).

## 2. Readable scale, separate visual zoom (spec §5.1)

Desktop mode applies the desktop UA and `useWideViewPort(true)` for
layout/breakpoints, but does NOT enable `loadWithOverviewMode(true)` and does
NOT set root CSS zoom from `devW/1280`. The injected CSS scale is
`BrowserTab.userZoom` only (default 1.0, clamped 0.5–2.0).

`BrowserTab.userZoom` defaults to 1.0 and clamps to the readable range
(`lib/core/agent_service.dart:63-68`); `desktopMode` is a plain per-tab flag
(`:85-88`) defaulting from the global `AppState.I.browserDesktopMode` (`:87-88`).
The desktop UA constant is pinned (`:83-84`). The injected script is a pure
builder of the passed scale (`browserZoomScriptForTest`, `:1672-1673`), and
`_applyTabZoom` injects `tab.userZoom` — never `tab.zoom` (`:1679-1685`).
`setTabDesktopMode` only flips the flag and recreates the controller; it never
assigns a device-derived zoom (`:1707-1725`). The native desktop branch is
`useWideViewPort = true` + `loadWithOverviewMode = false` + `NORMAL`
(`OvidWebViewHandler.kt:95-98`); mobile is the inverse (`:99-103`).

The new gate pins the user outcome at runtime (no source-substring checks):
with `devW = 360` (old fit would be ~0.28) a desktop toggle leaves
`userZoom == 1.0`, `zoom == 1.0`, and the injected script at `"1.0"`; distinct
user zooms (1.5 / 0.7) survive opposite mode toggles; the post-restart sweep
asserts every restored tab injects exactly its own `userZoom` and none sits at
`360/1280`.

## 3. Per-tab native settings (spec §5.2)

`applyDesktopViewport` takes a tab/controller identity and applies settings to
that WebView only; there is no global companion static and no decor-view
traversal (`lib/core/agent_service.dart:1640-1666`,
`OvidWebViewHandler.kt:12-23`).

The Dart side always forwards the owning tab: `controllerForTab` targets the
fresh WebView with `tabId` + `webViewIdentifier` (`:1928-1934`), and the
`reload: false` / no-controller fallback still carries `tabId: tab.id`
(`:1721-1724`). A mode change recreates the controller for that tab only and
clears `controller` + `loadedOnce` so no stale settings leak (`:1687-1705`).
The native side resolves exactly one WebView from `webViewIdentifier` and
touches nothing when it is absent (`OvidWebViewHandler.kt:87-92`); the
`setDesktopViewport` handler echoes `tabId` and reports `applied` without
traversal (`:43-77`).

The new gate pins a mixed sequence on the `ovid/webview` channel: toggle A
sends `tabId == A`, a `browser_resize` on the active tab sends `logicalWidth`
with `tabId == A` while `userZoom` stays 1.4, then toggling B sends
`tabId == B` with A still desktop — B never moves A.

## 4. Persistence (spec §5.3)

Per-tab `desktopMode` and `userZoom` persist alongside URLs/active index and
restore on startup, falling back to the global default when absent
(`lib/core/agent_service.dart:1256-1304`, `:1349-1398`).

The v2 envelope carries `url` + `desktopMode` + `userZoom` per tab with a
`version` (`:1259-1271`); decode applies persisted mode/zoom and clamps zoom
through the `userZoom` setter (`:1291-1295`); missing fields keep the
constructor default (global mode, 1.0 zoom) (`:1273-1276`). Restore prefers the
v2 envelope and falls back to the legacy URL list (`:1349-1372`); persist
writes the authoritative v2 envelope plus the legacy URL list for older builds,
globally and per session (`:1374-1398`).

The new gate pins: a mixed two-tab configuration (desktop 1.5 / mobile 0.75,
active index 1) round-trips exactly; the full toggle → zoom → resize →
persist → clear → restore flow keeps both tabs' modes/zooms; and an
out-of-range zoom (9.0) clamps to 2.0 while a default tab keeps 1.0/mobile.

## 5. Resize drives layout, never visual shrink (spec §5.1, §5.4)

`browser_resize` sets the logical viewport width for media queries via the
per-tab native viewport API — it never shrinks the visual scale
(`lib/core/agent_service.dart:8136-8158`).

The handler derives the logical factor (`zoom = devW / w`) for
`logicalWidth` only (`:8145`), forwards `logicalWidth: w` with the active
tab's identity (`:8149-8154`), and reports that visual zoom stays at
`userZoom` (`:8156-8158`). The native `applyLogicalViewport` forces the layout
viewport to the requested width without changing the visual scale, which the
Dart side owns (`OvidWebViewHandler.kt:107-125`). The `browser_desktop` tool
surface keeps the same contract in its reply
(`desktopMode` + `userZoom`, `:8160-8170`).

The new gate pins: `browser_resize 1280x800` returns `1280x800`, leaves
`userZoom` at 1.4, and emits exactly one `setDesktopViewport` with
`logicalWidth == 1280` and the active tab's id.

## 6. UI contract (spec §5.4)

The desktop/mobile toggle stays per tab and the user-zoom control stays
independent of the mode: mode switches never assign `userZoom`, and resize
never assigns CSS zoom (see §2/§5 code points). The README now documents this
shipped contract (`README.md`, Browser section). No widget redesign was in
scope (spec §3 non-goal) and none was made.

## 7. Device-only checks

Status legend: `PASSED` = executed on a physical Android device/emulator;
`FAILED` = executed and failed; `NOT EXECUTED` = no device/emulator attached.

Environment: no Android device/emulator is attached to this environment.
Therefore **every row below is `NOT EXECUTED`**.

| # | Check | Status | Evidence / notes |
|---|---|---|---|
| 1 | Desktop-mode page renders desktop layout at a readable size (no ~28% shrink) on a phone-width device | NOT EXECUTED | No device. Automated runtime pins in `browser_desktop_parity_test.dart` (1.0 scale at devW 360) / `browser_desktop_scale_test.dart`. |
| 2 | User zoom control changes visual scale independently of desktop/mobile toggle | NOT EXECUTED | No device. Automated pins in `browser_desktop_parity_test.dart` (1.5/0.7 survive toggles) / `browser_desktop_scale_test.dart`. |
| 3 | Toggling tab A between desktop/mobile leaves tab B's layout and mode unchanged on-device | NOT EXECUTED | No device. Automated channel-identity pins in `browser_desktop_parity_test.dart` / `browser_desktop_per_tab_test.dart`. |
| 4 | `browser_resize` changes layout width without shrinking readable text on-device | NOT EXECUTED | No device. Automated `logicalWidth` + `userZoom`-untouched pins in `browser_desktop_parity_test.dart` / `browser_desktop_persistence_test.dart`. |
| 5 | Per-tab desktop mode + user zoom survive a real app restart | NOT EXECUTED | No device. Automated persist/clear/restore pins in `browser_desktop_parity_test.dart` / `browser_desktop_persistence_test.dart` (SharedPreferences mocks). |
| 6 | APK installs and launches on-device | NOT EXECUTED | No device; debug APK did not build in this environment (see §8). |

## 8. Debug APK artifact

The debug build **failed for toolchain reasons** and produced no APK. The
failure is recorded exactly rather than fabricating a SHA.

| Field | Value |
|---|---|
| Path | N/A (no APK produced) |
| Size (bytes) | N/A |
| SHA-256 | N/A (NOT EXECUTED — build failed, nothing to hash) |
| Build command | `flutter build apk --debug` (with `PATH=/root/flutter/bin:$PATH`, `ANDROID_HOME=/opt/android-sdk`) |
| Build time | 1026.7 s (Gradle `assembleDebug` failed with exit code 1) |
| Built from | baseline `ef71433` working tree + Task 4 test/docs changes |
| Failure | `Execution failed for task ':app:processDebugGoogleServices'. File google-services.json is missing. The Google Services Plugin cannot function without it. Searched locations: android/app/src/debug/google-services.json, android/app/src/debug/google-services.json, android/app/src/google-services.json, android/app/src/debug/google-services.json, android/app/src/Debug/google-services.json, android/app/google-services.json` |

The build first downloaded Gradle/AGP artifacts (Android SDK Platform 34 and
35 installs) and emitted the pre-existing minimum-SDK-23 deprecation warning
before failing on the missing `google-services.json`. That file is absent from
the checkout (`android/app/google-services.json` does not exist) and is
unrelated to this test/docs-only task, which touches no Android or Dart
production code. This is a buildability gap in this environment, not a gate
pass: on-device install/launch (§7 row 6) remains `NOT EXECUTED`.

Had the APK built, it would still be a workspace-bound, gitignored artifact
under `build/` (debug builds are not byte-reproducible across machines); the
SHA would pin that workspace artifact only.

## 9. Concerns and limitations

1. **No on-device verification.** Readable desktop rendering, per-tab viewport
   isolation on real WebViews, real-restart persistence, and install/launch
   remain unverified until a release owner with a device completes §7 —
   compounded here by the missing debug APK (§8).
2. **Debug APK missing.** `google-services.json` is absent from the checkout,
   so `assembleDebug` cannot succeed in this environment. A release owner
   should either provide the file or document the expected debug-build path
   before claiming the APK gate.
3. **Analyzer warnings stand.** The two `unawaited_return_in_try_block`
   warnings pre-date this task and are untouched; a future cleanup can `await`
   or restructure those returns without changing this gate.
4. **WebView flags apply at init.** A mode change still recreates the
   controller for that tab (existing pattern); a recreation failure leaves the
   tab usable in the other mode via the existing error path (spec §6).
5. **Unknown persisted zoom clamps.** Out-of-range values clamp to 0.5–2.0
   rather than erroring (spec §6); corrupt envelopes fall back to legacy/defaults.
6. **No engine change.** Desktop compatibility is UA + wide viewport +
   user zoom; sites requiring more than a desktop UA/viewport remain out of
   scope (spec §3 non-goal).

## 10. Gate decision

Automated gates are green where runnable: the new end-to-end suite (6/6), the
focused browser-desktop set (32/32), the full Flutter suite (987/987),
`flutter analyze` (0 errors; 2 pre-existing warnings), and
`git diff --check` (clean). The debug APK gate **did not pass** — the build
fails on the missing `google-services.json` (§8) — and the on-device checklist
(§7) is `NOT EXECUTED` because no Android device/emulator is attached.
Automated sign-off is therefore green; on-device release sign-off **and** the
APK buildability item must remain open until a release owner with the missing
config and hardware completes them.
