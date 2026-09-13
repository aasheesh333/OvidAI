# Control Mode + Overlay — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL:
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans. Checkbox (`- [ ]`) syntax.

**Goal:** One-time control permission, background-only professional overlay with
live feedback + questions + mic, and a control-mode briefing for the model.

**Spec:** `docs/superpowers/specs/2026-09-13-control-mode-overlay-design.md`

## Global Constraints

- Keep `TYPE_ACCESSIBILITY_OVERLAY`; no `SYSTEM_ALERT_WINDOW`.
- No DSH references in `lib/`/`test/`.
- RED test first; full `flutter test` + `flutter analyze` green.
- Flutter binary `/root/flutter/bin/flutter`.

---

### Task 1: One-time control permission
**Files:** `lib/ui/chat_screen.dart` (`_enableControlMode`),
`lib/core/state.dart` (persisted flag), `lib/core/device_control_service.dart`
- [ ] RED: accepted + enabled → no disclosure, no Settings deep-link.
- [ ] Persist acceptance; gate disclosure/deep-link on `isEnabled()`.
- [ ] GREEN.

### Task 2: Background-only overlay
**Files:** `lib/ui/shell.dart` (lifecycle), `lib/core/agent_service.dart`
- [ ] RED: overlay hidden while resumed, shown when backgrounded in control.
- [ ] Gate show/hide on `AppLifecycleState`.
- [ ] GREEN.

### Task 3: Overlay polish (opacity, cross, live indicator)
**Files:** `android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt`
- [ ] Lower background alpha; clearer cross icon; add live-control indicator.
- [ ] Pin in `test/device_overlay_test.dart`.

### Task 4: Control-mode briefing
**Files:** `lib/core/agent_service.dart` (system prompt ~`:6107-6205`)
- [ ] RED: briefing present only in control mode.
- [ ] Add the control-mode block.
- [ ] GREEN.

### Task 5: Overlay questions/notices
**Files:** `agent_service.dart`, `MainActivity.kt`,
`OvidAccessibilityService.kt`, `chat_screen.dart`
- [ ] RED: push a question to the overlay and answer it back.
- [ ] Add Dart→native push + native→Dart answer wiring to `pendingApproval`.
- [ ] GREEN.

### Task 6: Overlay mic
**Files:** `OvidAccessibilityService.kt`, `agent_service.dart`
- [ ] Add mic button using the P5 voice-input service (after P5 lands).

### Task 7: Verify + audit
- [ ] Full `flutter test` + `flutter analyze`; `git diff --check`.
- [ ] Audit `docs/superpowers/audits/2026-09-13-control-mode-overlay.md`.
