# Voice Input (Mic) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL:
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans. Checkbox (`- [ ]`) syntax.

**Goal:** Working on-device speech-to-text in the composer and (via P2) the
overlay.

**Spec:** `docs/superpowers/specs/2026-09-13-voice-input-design.md`

## Global Constraints

- No DSH references in `lib/`/`test/`.
- RED test first; full `flutter test` + `flutter analyze` green.
- Flutter binary `/root/flutter/bin/flutter`.
- Real recognition `NOT EXECUTED` (device).

---

### Task 1: VoiceInputService + permission
**Files:** new `lib/core/voice_input_service.dart`, `AndroidManifest.xml`,
`pubspec.yaml`
- [ ] Add `speech_to_text`; add `RECORD_AUDIO`.
- [ ] RED: fake backend covers permission denied / partials / stop.
- [ ] Implement the service.
- [ ] GREEN.

### Task 2: Composer mic
**Files:** `lib/ui/chat_screen.dart` (`_InputBar` mic)
- [ ] RED: mic toggles listening and inserts recognized text.
- [ ] Wire the mic button.
- [ ] GREEN.

### Task 3: Overlay mic
**Files:** `OvidAccessibilityService.kt`, `agent_service.dart`
- [ ] Wire the overlay mic to the service (after P2 Task 6).

### Task 4: Verify + audit
- [ ] Full `flutter test` + `flutter analyze`; `git diff --check`.
- [ ] Audit `docs/superpowers/audits/2026-09-13-voice-input.md`.
