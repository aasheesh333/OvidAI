# Device Overlay + Human-Equivalent Actions — Task 5 Release Gate Audit

Date: 2026-09-12 · Branch `hoplite/gortyn-77773150` · Baseline `3d37317` · Task 5 verification commit (this commit)

This audit is the release gate for the Device Overlay + Human-Equivalent
Actions project (spec
`docs/superpowers/specs/2026-09-10-device-overlay-actions-design.md`). It
records the automated verification matrix and the per-outcome evidence for
the five promised behaviors (floating overlay, key events, long-press/scroll/
ancestor-click, honest submit + revalidation, cancellation), then the
device-only checklist with its execution status.

**Device checks were NOT executed.** No Android device or emulator is attached
to this environment. Every on-device row in §8 is marked `NOT EXECUTED`, not
`passed`. Nothing on-device was run and nothing on-device is claimed.

This is a test/docs-only task. No production behavior was changed. The new
end-to-end gate (8/8) surfaced no defect in the project surface — but the
full-suite run surfaced one deterministic failure **outside** the project's
files (see §1 and §10 item 1): the `onAgentExit` lifecycle test in
`core_regression_test.dart` fails because the Task 4 fix commit's added
`await` defers the exit callback past that test's synchronous expect.
Production behavior was proven intact with an awaited round-trip probe, so
this is a test-timing assumption break, not a production regression — but the
repo-wide gate is red until that test awaits the message round-trip, and the
fix is out of this task's commit scope.

## 1. Verification matrix (exact counts)

All commands run with `/root/flutter/bin/flutter` on 2026-09-12,
working tree at baseline `3d37317` plus the Task 5 test/docs changes.

`flutter --version`:

```text
Flutter 3.47.4 • channel stable • https://github.com/flutter/flutter.git
Framework • revision 9584c6713b (2 days ago) • 2026-09-10 15:25:10 -0700
Engine • hash 0e228ec8c8d2abc9fcf1d053e8a40665bb859ec7 (revision 06a2e2a110) (8 days ago) • 2026-09-03 16:07:13.000Z
Tools • Dart 3.13.3 • DevTools 2.60.0
```

`ANDROID_HOME=/opt/android-sdk`, Java 17 present.

| Command | Result |
|---|---|
| `flutter test test/device_overlay_actions_parity_test.dart` | 8/8 passed (new) |
| `flutter test` (5 overlay/device suites) | 89/89 passed (8 parity + 32 overlay + 21 tools + 16 cancel/submit + 12 native) |
| `flutter test` (all files) | 1105 passed, 1 failed of 1106 (failure named below, pre-existing at baseline) |
| `flutter analyze --no-pub` | 0 errors; 2 pre-existing warnings (ran in ~6 s) |
| `flutter build apk --debug` | FAILED (toolchain, see §9 — no APK produced, no SHA) |
| `:app:compileDebugKotlin -x processDebugGoogleServices` | BUILD SUCCESSFUL in 36 s |
| `git diff --check` | clean |

The single full-suite failure is deterministic, not flaky:

```text
test/core_regression_test.dart: Task 4: MCP import + runtime reliability
  Task 6: Recents survival + stop vs exit lifecycle
  onAgentExit registers exit callback and cancels runs
  Expected: true / Actual: <false> (test/core_regression_test.dart:11945)
```

It fails identically with the Task 5 parity file moved out of the tree, so
it is pre-existing at baseline `3d37317` and unrelated to this task. Cause:
the Task 4 fix commit (`3d37317`, production handler delegation) added
`if (await AgentService.I.handleDeviceOverlayMethodCall(call))` at the top
of the `ovid/native` handler (`lib/core/agent_notification_service.dart:100`),
so the `onAgentExit` arm (`:110`) now runs after an `await` boundary; the
test drives `onAgentExit` via `handlePlatformMessage` without awaiting the
round-trip and expects the exit callback synchronously (`:11945`). Before the
fix the handler body had no `await` and ran synchronously. A scratch probe
(register exit handler → `init()` → drive `onAgentExit` → await the reply)
passes, proving the production path still fires — only the test's synchronous
assumption broke. The scratch file was deleted after the probe; the
one-line fix (await the round-trip in that test) belongs to a follow-up, not
this commit. Neither brief-listed flaky test
(`agent HTTP fetch deadline covers headers and body in one window`,
`streams output and persists cd across commands`) failed in any run here.

`flutter analyze` reports only two pre-existing
`unawaited_return_in_try_block` warnings
(`lib/core/agent_service.dart:6971`, `lib/core/hook_service.dart:317`).
Neither is touched by this task (test/docs-only); the new parity test
introduces no analyzer issue (an initial 5-warning draft was fixed before
verification by dropping redundant null-assertions).

`pubspec.lock` was not dirtied: `git status` shows only the three intended
files (no lock bump to revert).

## 2. Overlay — send ≡ composer, X ≡ Stop, Control-only show (spec §5.1)

Dart send is exactly the composer path and X is exactly composer Stop:
`handleDeviceOverlayText` queues into the busy run or appends + starts a run
(`lib/core/agent_service.dart:968`), `handleDeviceOverlayStop` routes through
`stopRequested` — the bumped two-branch path (`:989`, via `:876`) — and the
native→Dart dispatcher is chainable (`:1003`). The production `ovid/native`
handler delegates to the overlay dispatcher first
(`lib/core/agent_notification_service.dart:100`, before `onAgentStop` at
`:103` and `onAgentExit` at `:110`). Show is guarded on an active Control
session (`:949`); hide is unguarded so no invisible touch target survives
(`:959`); method names are pinned constants (`:924-927`). Native window:
`TYPE_ACCESSIBILITY_OVERLAY` (`OvidAccessibilityService.kt:271`), show/hide
entry points (`:261`, `:295`), hidden removes the view (`:303`), 2×3 drag
handle via `updateViewLayout` (`:449`, `:499`), X/send morph via
`TextWatcher` on blank (`:419`), rounded container (`:354`), add/remove
failures stay honest (`BadTokenException`); routes `deviceOverlayShow/Hide`
in `MainActivity.kt:416-422`. No `SYSTEM_ALERT_WINDOW` in the manifest, the
service, or the activity.

The new gate pins at runtime: show-guard (silent for auto-mode and
session-less, `deviceOverlayShow` exactly once for Control, hide always
removes), busy overlay text joins the queue without starting a run, idle
overlay text appends a user message and starts a run, X aborts an in-flight
tap with the cancelled copy while preserving the queue, and both overlay
events delivered through the production handler behave identically
(send lands + starts a run; Stop aborts in-flight work) with the
delegate-first ordering source-pinned.

## 3. Key events — closed vocabulary, real mechanisms (spec §5.2)

`device_key` accepts only `enter | volume_up | volume_down | volume_mute |
media_play_pause | media_next | media_previous`: schema enum
(`lib/core/agent_service.dart:3281`), dispatch refusal naming the Android
inject limit (`:10822`), control-only + denylist gating (`:11440` and the
read-gate path). Native: `pressKey` (`OvidAccessibilityService.kt:888`),
`BAD_KEY` (`:897`), `adjustStreamVolume(STREAM_MUSIC)` (`:947`),
`dispatchMediaKeyEvent` (`:967-968`), enter via `Api30Actions.submit` with
focus/editable honesty (`:914-919`); route `deviceKey` in
`MainActivity.kt:403`.

The new gate pins at runtime: `f5` is refused with `BAD_KEY` + inject
wording and zero `deviceKey` channel calls; every vocabulary key dispatches
`deviceKey` exactly once with the key verbatim.

## 4. Long-press, scroll, ancestor-click (spec §5.3)

Long-press defaults 600 ms and clamps 200–3000 ms on both sides (Dart
`lib/core/device_control_service.dart:176`, native
`(durationMs ?: 600L).coerceIn(200L, 3000L)` at
`OvidAccessibilityService.kt:719`, node `ACTION_LONG_CLICK` + coordinate
`dispatchGesture` in `longPress(` at `:722`). Scroll requires a scrollable
node (`scrollNode(` at `:755`, `NOT_SCROLLABLE` at `:770`), directional
actions fall back below the API-M floor and name it (`:781`); routes
`deviceLongPress`/`deviceScroll` in `MainActivity.kt:372-399`. Tap walks up
to 3 ancestors attempting clicks (`:668-684`) and names the accepting level
or reports all refused (`:700-702`).

The new gate pins at runtime: default 600, clamps to 3000/200, node
passthrough reporting; scroll dispatches the direction verbatim, surfaces a
native `via backward fallback (below API 23)` narration as `fallback`, and
surfaces `NOT_SCROLLABLE` as `not scrollable`; ancestor-walk and clamp
shapes are source-pinned in the same test.

## 5. Honest submit + native revalidation (spec §5.4)

Submit contract: `typed=true` only when `SET_TEXT` is accepted,
`submitted=true` only when the IME action is accepted, API floor keeps typed
with an explicit message (native `:831-846`, Dart formatter
`lib/core/agent_service.dart:10713`). Revalidation: every node action
`refresh()`es first (tap/long-press/scroll/type), stale handles are refused
as `INVALID_NODE` with a re-read hint (`:660-662`, `:730-732`, `:765-767`,
`:816-829`), and type rechecks `isPassword` → `PASSWORD_FIELD` (`:108-110`,
`:831`) and `isEditable` → `NOT_EDITABLE` (`:832-833`) on the refreshed node.

The new gate pins at runtime: no-submit reports `(typed=true,
submitted=false)` with no implied submit; IME-accepted reports both true;
IME-refused reports the split plus the native reason verbatim; a superseded
type reports cancellation instead of typed text.

## 6. Cancellation — generational at the Dart layer (spec §5.5)

`DeviceControlService` carries a monotonic generation
(`lib/core/device_control_service.dart:72`): `beginDeviceGeneration` opens a
fresh one per run, `cancelDeviceActions` bumps on Stop (`:80`), and any
result landing after a bump is replaced by
`cancelled: superseded by a newer run/stop` (`:56-61`). Both Stop branches
bump (`stopRequested` at `lib/core/agent_service.dart:876-886`,
`cancelAllRuns` at `:891-894`); run entry opens a generation (`:5928`).
Reads stay unguarded for live-foreground verification. Dispatched gestures
run to completion (documented Android limit).

The new gate pins at runtime: a run-start bump supersedes an in-flight tap,
composer Stop supersedes a dispatched `device_tap` end to end, and an
untouched `key` call still returns the native result verbatim.

## 7. README

`README.md` gains a `Control mode device actions` section stating the
shipped surface: accessibility overlay (no new permission, Control-active
only, send ≡ composer, X ≡ Stop), the `device_key` / `device_long_press` /
`device_scroll` contracts with their honest refusal codes, ancestor fallback
and the `typed`/`submitted` split, `INVALID_NODE` revalidation, and
generational cancellation with the dispatched-gesture limit. Small and
factual; no other README sections changed.

## 8. Device-only checks

Status legend: `PASSED` = executed on a physical Android device/emulator;
`FAILED` = executed and failed; `NOT EXECUTED` = no device/emulator attached.

Environment: no Android device/emulator is attached to this environment.
Therefore **every row below is `NOT EXECUTED`**.

| # | Check | Status | Evidence / notes |
|---|---|---|---|
| 1 | Overlay appears over another app during Control mode, draggable by the dot handle, with no new permission prompt | NOT EXECUTED | No device. Automated pins in `device_overlay_actions_parity_test.dart` (show-guard, window-type/drag source pins) / `device_overlay_test.dart` (32/32). |
| 2 | Overlay send delivers text: idle starts a run, busy joins the queue | NOT EXECUTED | No device. Automated runtime pins in the parity test (queue + run-starter seams) / `device_overlay_test.dart`. |
| 3 | Overlay X stops the run and cancels pending device work | NOT EXECUTED | No device. Automated runtime pins in the parity test (in-flight tap superseded, production handler) / `device_overlay_test.dart`. |
| 4 | Overlay input focus + soft keyboard over other apps | NOT EXECUTED | No device. Spec §5.1 caveat: if a device refuses focus, the field degrades; persistent failure is a device caveat, never worked around with new permissions. |
| 5 | `device_key` enter/volume/media act on-device | NOT EXECUTED | No device. Automated vocabulary + dispatch pins in the parity test / `device_actions_tools_test.dart` (21/21). |
| 6 | `device_long_press` on node and coordinates with durations | NOT EXECUTED | No device. Automated clamp pins in the parity test / `device_actions_tools_test.dart`; native gesture path is source-pinned only. |
| 7 | `device_scroll` directions incl. below-API fallback naming | NOT EXECUTED | No device. Automated fallback-honesty pins in the parity test / `device_actions_tools_test.dart`. |
| 8 | Tap ancestor fallback clicks a stubborn row and names the level | NOT EXECUTED | No device. Source pins only (`OvidAccessibilityService.kt:668-702`); no hardware path exists in this environment. |
| 9 | `device_type` typed/submitted split on-device, incl. API < 30 floor | NOT EXECUTED | No device. Automated split pins in the parity test / `device_actions_cancel_submit_test.dart` (16/16). |
| 10 | Stop during an in-flight gesture: gesture completes (≤3 s), queued work cancelled | NOT EXECUTED | No device. Automated supersede pins in the parity test / `device_actions_cancel_submit_test.dart`; the in-flight-completes limit is documented, never executed here. |
| 11 | APK installs and launches on-device | NOT EXECUTED | No device; debug APK did not build in this environment (see §9). |

## 9. Debug APK artifact

The debug build **failed for toolchain reasons** and produced no APK. The
failure is recorded exactly rather than fabricating a SHA.

| Field | Value |
|---|---|
| Path | N/A (no APK produced) |
| Size (bytes) | N/A |
| SHA-256 | N/A (NOT EXECUTED — build failed, nothing to hash) |
| Build command | `flutter build apk --debug` (with `PATH=/root/flutter/bin:$PATH`, `ANDROID_HOME=/opt/android-sdk`) |
| Build time | 42.2 s (Gradle `assembleDebug` failed with exit code 1) |
| Built from | baseline `3d37317` working tree + Task 5 test/docs changes |
| Failure | `Execution failed for task ':app:processDebugGoogleServices'. File google-services.json is missing. The Google Services Plugin cannot function without it. Searched locations: /root/OvidAI/android/app/src/debug/google-services.json, /root/OvidAI/android/app/src/debug/google-services.json, /root/OvidAI/android/app/src/google-services.json, /root/OvidAI/android/app/src/debug/google-services.json, /root/OvidAI/android/app/src/Debug/google-services.json, /root/OvidAI/android/app/google-services.json` |

The `google-services.json` file is absent from the checkout
(`android/app/google-services.json` does not exist), is gitignored, and is
unrelated to this test/docs-only task. Per the brief it was NOT created or
fabricated. Kotlin compilation of the project's Android code succeeds
independently (`:app:compileDebugKotlin -x processDebugGoogleServices`
→ `BUILD SUCCESSFUL in 36s`; the exclusion skips only the missing-config
task, not code compilation). This is a buildability gap in this environment,
not a gate pass: on-device install/launch (§8 row 11) remains `NOT EXECUTED`.

Had the APK built, it would still be a workspace-bound, gitignored artifact
under `build/` (debug builds are not byte-reproducible across machines); the
SHA would pin that workspace artifact only.

## 10. Concerns and limitations

1. **Repo-wide suite is red on one deterministic failure (new, gating).**
   `core_regression_test.dart` → `onAgentExit registers exit callback and
   cancels runs` (`:11945`) fails because the Task 4 fix commit added an
   `await` at the top of the production `ovid/native` handler
   (`agent_notification_service.dart:100`), deferring the exit callback past
   the test's synchronous expect. Verified pre-existing at baseline (fails
   with Task 5 files moved out), production path proven intact by an awaited
   round-trip probe (passed, scratch file deleted). Fix: await the platform
   round-trip in that test — one line, but outside this task's commit scope;
   needs a follow-up before the repo gate can go green.
2. **No on-device verification.** Overlay visibility/drag/focus, key
   press effects, gesture durations, scroll fallbacks on old APIs, ancestor
   clicks, submit behavior, and in-flight cancellation remain unverified
   until a release owner with a device completes §8 — compounded here by the
   missing debug APK (§9). The overlay focus/keyboard caveat (spec §5.1)
   stands as a device caveat.
3. **Debug APK missing.** `google-services.json` is absent from the checkout,
   so `assembleDebug` cannot succeed in this environment. A release owner
   should either provide the file or document the expected debug-build path
   before claiming the APK gate.
4. **Analyzer warnings stand.** The two `unawaited_return_in_try_block`
   warnings pre-date this task and are untouched; a future cleanup can
   `await` or restructure those returns without changing this gate.
5. **Deferred minors carried from Tasks 1–4 (unchanged, test/docs-only task
   touches no production code):** Task 1 — ancestor-walk success path leaks
   one prefetched parent node (`:668-687` region), per-call direction set
   allocation, lowercase without `Locale.ROOT`, refusal count includes
   skipped non-clickables, long-press/swipe gesture-builder duplication;
   Task 2 — `dispatchMediaKeyEvent` fire-and-forget overclaims (no receiver
   confirmation signal exists), `adjustStreamVolume`/`dispatchMediaKeyEvent`
   catch only `SecurityException`, `volume_mute` one-way not stated in the
   tool description; Task 3 — run-start bump only source-pinned (no
   behavioral mid-flight test), fixed-delay supersede test, misplaced
   read-unguarded comment, duplicated `generation++`, screenshot
   `invokeMethod` widening; Task 4 — Dart show swallows native `UNAVAILABLE`
   (silent to caller), extra `isOverlayVisible()` seam with no Dart caller
   (harmless), X fallback to the first running session is the bumped path
   but reaches beyond active-only.
6. **No engine change.** This task adds one parity test file, this audit, and
   a README section; overlays, tools, cancellation, and honesty behavior are
   Tasks 1–4's, unchanged.

## 11. Gate decision

Project-surface gates are green: the new end-to-end suite (8/8), the focused
overlay/device set (89/89), `flutter analyze` (0 errors; 2 pre-existing
warnings), `:app:compileDebugKotlin` (`BUILD SUCCESSFUL`), and
`git diff --check` (clean). The debug APK gate **did not pass** — the build
fails on the missing `google-services.json` (§9) — the on-device checklist
(§8) is `NOT EXECUTED`, and the repo-wide suite is **red on one
deterministic, pre-existing failure** (§1, §10 item 1) whose fix is out of
this task's scope. Automated sign-off on the overlay/device-actions surface
is therefore green; repo-wide release sign-off must remain open until a
follow-up awaits the `onAgentExit` round-trip in `core_regression_test.dart`,
a release owner provides the missing build config, and §8 is completed with
hardware.

## 12. Addendum — §§1/10/11 superseded at `1f3401c` (history preserved above)

The red recorded in §1 and §§10–11 is superseded, not rewritten: at
`1f3401c` (`fix: flush event queue in onAgentExit handler test`) the
`onAgentExit` test-timing assumption was adapted with a `pumpEventQueue`
flush, and the full suite is green at **1106/1106**. The production path was
never regressed — only the test's synchronous expect needed the round-trip.

The gate still remains open on exactly two pre-existing, environment-bound
rows: the debug APK (missing gitignored `google-services.json` — never
created per policy, so `assembleDebug` cannot succeed here) and the
on-device checklist (§8, `NOT EXECUTED` — no hardware attached). No new
permissions, no behavior change beyond the test-timing fix.
