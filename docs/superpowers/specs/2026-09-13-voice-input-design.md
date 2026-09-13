# Voice Input (Mic) — Design

**Date:** 2026-09-13
**Status:** Approved for implementation.

## 1. Goal

Make the microphone work: dictate prompts in the composer and in the control
overlay, using on-device speech recognition.

## 2. Outcomes

1. The composer mic records speech and inserts recognized text into the input.
2. The overlay mic does the same and sends or fills the overlay field.
3. Permission is requested cleanly and denial is handled honestly.

## 3. Non-Goals

- Cloud STT; prefer on-device.
- Wake-word / always-listening.
- Text-to-speech.

## 4. Current Failure Model (evidence)

- Composer mic is a no-op (`chat_screen.dart:4591-4599`,
  `onPressed: () {}`).
- No speech dependency in `pubspec.yaml`.
- Settings shows a static "Voice input / On" tile (`settings_screen.dart:162`).
- Overlay has no mic (`OvidAccessibilityService.kt:342-446`).

## 5. Design

- Add an on-device STT dependency (`speech_to_text`) and a small
  `VoiceInputService` wrapping permission + listen/stop + partial results.
- Composer mic toggles listening and appends recognized text to the field.
- Overlay mic (P2) uses the same service.
- Android manifest: `RECORD_AUDIO` permission + runtime request.

## 6. Testing

- Service unit test with a fake STT backend (permission denied, partials, stop).
- Widget test: composer mic toggles and inserts text.
- Full `flutter test` + `flutter analyze` green.
- Real recognition is a device row `NOT EXECUTED`.

## 7. Decisions

- On-device STT; graceful honest failure when unavailable.
- One shared service for composer + overlay.
