# Control Mode + Overlay — Design

**Date:** 2026-09-13
**Status:** Approved for implementation.

## 1. Goal

Make Control mode trustworthy and unobtrusive: request the accessibility
permission **once**, show the floating overlay **only when the app is
minimized**, make the overlay professional and see-through with live feedback, let
the AI surface questions/notices through the overlay, and ensure the model knows
it is in control mode.

## 2. Outcomes

1. Switching to Control shows the disclosure + accessibility deep-link only the
   first time; later switches with the service already enabled do not re-prompt
   or re-open Settings.
2. The overlay is visible only while the app is backgrounded/minimized and
   Control mode is active; it hides when the app returns to the foreground.
3. Overlay opacity is reduced so the content behind stays legible; the cross
   icon is clear and professional; a light live-control indicator shows the app
   is being controlled.
4. The AI receives a positive control-mode briefing and does not get confused.
5. When the AI asks a question or posts a notice in control mode, it appears in
   the overlay (and can be answered there).
6. The overlay has a mic affordance.

## 3. Non-Goals

- `SYSTEM_ALERT_WINDOW`; keep `TYPE_ACCESSIBILITY_OVERLAY`.
- Replacing the device-control tool set.
- On-device verification without hardware.

## 4. Current Failure Model (evidence)

- `_enableControlMode` (`chat_screen.dart:5982-6015`) **always** shows the
  disclosure and **always** calls `openAccessibilitySettings()`, with no
  `isEnabled()` check and no persisted acceptance.
- Overlay show/hide is run-scoped (`agent_service.dart:5974-5976` show at run
  start; `:6678` hide at run end; mode exit `:660-665`, `:2745-2748`; stop
  `:889-907`). No `AppLifecycleState` gates it.
- Overlay native layout (`OvidAccessibilityService.kt:342-446`): near-black
  `0xE61A1A1A` (≈90% opaque) rounded container, drag handle, single-line
  `EditText`, X/send morph. No status/feedback, no question area, no mic.
- System prompt gives only `Access mode: CONTROL — <hint>`
  (`agent_service.dart:6120`); no control-mode briefing.
- Questions render only in `_ApprovalDock`/`_QuestionsCard`; no overlay channel
  to push them.
- `DeviceControlService.isEnabled()` (`device_control_service.dart:111-113`) is
  used only by the warning banner, not by `_enableControlMode`.

## 5. Design

### 5.1 One-time permission
Persist a control-disclosure-accepted flag and query `isEnabled()`:
`_enableControlMode` shows the disclosure only when not yet accepted, and
deep-links to Settings only when `isEnabled()` is false. If already enabled,
switch mode silently.

### 5.2 Background-only overlay
Track `AppLifecycleState` (already observed in `shell.dart:59-93`). Show the
overlay only when `mode == control && lifecycle != resumed`; hide on resume.
Keep the run-scoped show/hide as the inner gate.

### 5.3 Overlay polish
Reduce the container background alpha (captured target from the DSH-style
overlay pass); add a clear cross icon; add a subtle live-control indicator
(pulse/dot). Keep drag + text send.

### 5.4 Control-mode briefing
Add a control-mode block to the system prompt (parallel to the `safe` MODE
RESTRICTIONS block `:6121-6128`) describing expected device-control behavior and
the node-tree tools.

### 5.5 Overlay questions/notices
Add a Dart→native channel to push a question/notice payload (text + optional
options) into the overlay, and a native→Dart path to return the answer, wired to
`pendingApproval`/`_askQuestions`.

### 5.6 Overlay mic
Add a mic button to the overlay that uses the shared voice-input service (P5).

## 6. Testing

- `_enableControlMode`: no re-prompt when accepted + enabled.
- Lifecycle gate: overlay shows only when backgrounded.
- Overlay payload: question pushed/answered round-trip.
- Prompt: control-mode briefing present only in control.
- Full `flutter test` + `flutter analyze` green.

## 7. Decisions

- Acceptance is persisted; permission is queried, not assumed.
- Overlay visibility is app-state-gated, not run-gated alone.
- Questions/notices are pushed to the overlay; answering is supported.
- Mic is shared with P5.
