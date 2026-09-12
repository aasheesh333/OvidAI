# Android Control Overlay + Human-Equivalent Device Actions Design

**Date:** 2026-09-12
**Status:** Approved by product direction (accessibility-overlay textbox outside Ovid; closed-vocabulary key events; long-press/scroll/ancestor-click; honest submit; native revalidation; cancellation).

## 1. Goal

While Control mode drives the device in other apps, the user can steer
Ovid without returning to it: a small draggable floating textbox lives
outside Ovid. Beside it, the agent's hands become human-equivalent —
key events, long-press, node scroll, click fallback, honest submit
reporting, revalidation before every touch, and real cancellation.

## 2. User Outcomes

1. A floating Ovid field is visible over other apps during Control
   mode: rounded, draggable by a 2×3 dot handle, with an X that
   hard-stops the run — and when text is typed the X becomes a colored
   send icon that queues the text into the next AI request.
2. The agent can press keys (enter, volume, media), long-press, scroll
   a node, and click a stubborn row via its ancestors — each reported
   honestly (what happened, at which level, with what fallback).
3. A typed submit reports `typed` and `submitted` separately; a submit
   that could not run says why instead of claiming success.
4. Stale nodes and sensitive targets are refused natively before
   anything touches the screen; Stop truly cancels pending device
   work.

## 3. Non-Goals

- Arbitrary keycode injection (Android denies `INJECT_EVENTS` to apps;
  §5.2 is a closed vocabulary mapped to real mechanisms).
- Recalling an already-dispatched gesture (impossible); cancellation
  covers Dart-awaited results and queued work.
- `SYSTEM_ALERT_WINDOW` permission and Play-sensitive overlay flows.
- iOS equivalents.

## 4. Current Failure Model (evidence)

- No overlay exists: no `TYPE_APPLICATION_OVERLAY` /
  `TYPE_ACCESSIBILITY_OVERLAY` window, no `SYSTEM_ALERT_WINDOW`
  declaration (`AndroidManifest.xml` has neither).
- `OvidAccessibilityService` has tap/click, type+IME-enter submit,
  swipe, systemNav, screenshot — but no long-press, no scroll
  actions, no ancestor fallback, and `tap()` never `refresh()`es the
  node (`OvidAccessibilityService.kt:370-391`).
- No key-event path beyond IME enter and systemNav; no
  `device_key`/`device_long_press`/`device_scroll` tools
  (`agent_service.dart` tool schema has `device_read/tap/type/swipe/
  system_nav/screenshot` only).
- No generation/cancellation for in-flight `device_*` Dart calls
  (`DeviceControlService` is direct channel passthrough,
  `device_control_service.dart:75-103`).
- `device_type` result contract (`typed`/`submitted`/`message`) exists
  natively but is not pinned by a spec-level honesty contract.

## 5. Architecture

### 5.1 Overlay (no new permission)

- Host: `OvidAccessibilityService` adds a `TYPE_ACCESSIBILITY_OVERLAY`
  window — creatable from an accessibility service with no manifest
  permission, touchable, and alive exactly while the service is bound
  (Control mode's existing gate). No `SYSTEM_ALERT_WINDOW`.
- Layout: rounded container, `EditText` (single-line, IME send),
  2×3 dot drag handle (touch-drag → `WindowManager.updateViewLayout`),
  trailing `ImageButton`: X (empty field) ⇄ colored send arrow
  (non-empty field, `TextWatcher` morph).
- Channel (`ovid/native`): Dart→native `deviceOverlay(show|hide)`;
  native→Dart `deviceOverlayText(text)` on send, `deviceOverlayStop()`
  on X. While hidden the window is removed (no invisible touch
  target).
- Dart: send ≡ composer send — if the active session is idle the text
  starts a run, if busy it joins the per-session queue (§5.1 of the
  control spec); X ≡ composer Stop (`stopRequested` two-branch) plus
  `cancelDeviceActions()`. No active control session → overlay never
  shown (Dart guards `show`).
- Input-focus risk: overlay `EditText` needs input focus + soft
  keyboard over other apps. If the device refuses focus, the field
  still accepts taps by bringing up the keyboard via
  `InputMethodManager.showSoftInput`; persistent failure on a device
  is reported by the audit as a device-NOT-EXECUTED caveat, never
  worked around with new permissions.

### 5.2 Key events (closed vocabulary, real mechanisms)

`device_key {key}` where `key` ∈ `enter | volume_up | volume_down |
volume_mute | media_play_pause | media_next | media_previous`:

- `enter`: IME-enter on the focused editable node (existing
  `Api30Actions.submit` path, API-gated with honest message).
- `volume_*`: `AudioManager.adjustStreamVolume(STREAM_MUSIC, …)`.
- `media_*`: `AudioManager.dispatchMediaKeyEvent` to the active
  session (play/pause/next/prev only).
- Anything else → `BAD_KEY` refusal naming the Android limitation
  (apps cannot inject arbitrary keycodes). Denylist + control-mode +
  read-only/plan gates apply uniformly.

### 5.3 Long-press, scroll, ancestor-click

- `device_long_press {node?, x?, y?, duration_ms?}`: node →
  `ACTION_LONG_CLICK`; coords → `dispatchGesture` stroke of
  `duration_ms` (default 600, clamped 200–3000).
- `device_scroll {node, direction}`: `direction` ∈
  `forward|backward|up|down|left|right`; node must be scrollable
  (else `NOT_SCROLLABLE`); up/down/left/right fall back to
  forward/backward below their API floor with the fallback named in
  the result.
- `tap(handle)`: node not clickable or click refused → walk up to 3
  ancestors attempting `ACTION_CLICK` on clickable ones; result names
  the level that accepted (`clicked ancestor 2 (LinearLayout)`) or
  reports all levels refused.

### 5.4 Honest submit + native revalidation

- Submit contract (pinned, mostly existing): `typed=true` only when
  `ACTION_SET_TEXT` accepted; `submitted=true` only when the IME
  action accepted; submit on API < 30 → `typed=true`,
  `submitted=false`, message names the API floor; Dart tool strings
  surface all three fields verbatim.
- Before every node action (tap/click/type/scroll/long-press):
  `node.refresh()`; stale → `INVALID_NODE` + "re-read" hint;
  `type` re-checks `isPassword` (refuse `PASSWORD_FIELD`) and
  `isEditable` (refuse `NOT_EDITABLE`) on the refreshed node.
- Denylist (`isSensitiveTarget`) is evaluated on the live foreground
  package for every action, as today.

### 5.5 Cancellation

- `DeviceControlService` carries a monotonic `deviceGeneration`,
  bumped by `beginDeviceGeneration()` on every new run and every
  Stop. Each Dart `device_*` call captures the generation; if it
  differs when the native result lands, the result is discarded and
  the tool reports `cancelled: superseded by a newer run/stop`.
- Overlay X and composer Stop both bump the generation
  (`cancelDeviceActions`). Already-dispatched gestures run to
  completion (documented Android limit); everything Dart-awaited or
  queued is cancellable.

## 6. Error Handling

- Service unbound → overlay calls report unavailable; tools keep the
  existing not-bound message + settings link.
- Overlay window add/remove wrapped: `BadTokenException`/state
  races → honest unavailable, never a crash.
- Durable-recording-style persistence is NOT in scope: overlay text
  is transient (cleared on send); nothing queued survives restart
  beyond the normal session queue.

## 7. Testing

- Dart unit/widget-source: closed key vocabulary (unknown key
  refused); long-press/scroll/ancestor/revalidation/submit
  contracts via the service source + fake channel results;
  generation-cancel supersede behavior; overlay queue ≡ composer
  path and X ≡ Stop path (seam-level, no hardware).
- Kotlin: source-level pins (overlay type, drag, morph, actions,
  refresh, denylist) + `compileDebugKotlin` when the toolchain
  allows; device behavior NOT EXECUTED everywhere (no hardware).
- Regression: full suite green per task; gates (read-only/plan/
  control-only) pinned.

## 8. Decisions

- Accessibility overlay, not `SYSTEM_ALERT_WINDOW`.
- Overlay send ≡ composer send; overlay X ≡ Stop + cancel.
- Closed key vocabulary; arbitrary keycodes refused honestly.
- Cancellation is generational at the Dart layer.
