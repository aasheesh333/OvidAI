# Device Overlay + Human-Equivalent Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A draggable floating Ovid textbox outside the app (accessibility overlay, X hard-stop ⇄ send-to-queue) plus human-equivalent device actions (key events, long-press, scroll, ancestor-click, honest submit, revalidation, cancellation).

**Architecture:** `OvidAccessibilityService` hosts a `TYPE_ACCESSIBILITY_OVERLAY` window (no new permission) bridged over `ovid/native`; new `device_key`/`device_long_press`/`device_scroll` tools beside the existing surface; generational cancellation in `DeviceControlService`.

**Spec:** `docs/superpowers/specs/2026-09-10-device-overlay-actions-design.md`

## Global Constraints

- No new manifest permissions (in particular no `SYSTEM_ALERT_WINDOW`); overlay lives only while the accessibility service is bound.
- Overlay send ≡ composer send (idle starts a run, busy joins the queue); overlay X ≡ composer Stop + `cancelDeviceActions()`.
- Closed key vocabulary (`enter|volume_up|volume_down|volume_mute|media_play_pause|media_next|media_previous`); unknown keys refused with the Android-limitation reason.
- Every new tool: control-mode-only, denied in read-only + plan gates, in `_mutatingTools`, denylist-checked on the live foreground.
- Honest reporting everywhere: submitted/typed split, named fallbacks, `INVALID_NODE` + re-read hint, superseded → `cancelled`.
- Preserve all green tests (full `flutter test` 1017/1017 at baseline `b1b53e7`).
- Flutter binary `/root/flutter/bin/flutter`, `ANDROID_HOME=/opt/android-sdk` (this PC).
- Device/emulator checks are NOT EXECUTED anywhere (no hardware); Kotlin device behavior asserted by source pins + `compileDebugKotlin` when possible.

---

### Task 1: Native action core (long-press, scroll, ancestor-click, revalidation)

**Files:**
- Modify: `android/app/src/main/kotlin/com/dhanuk/ovidai/OvidAccessibilityService.kt`
- Modify: `android/app/src/main/kotlin/com/dhanuk/ovidai/MainActivity.kt` (route new channel methods)
- Create: `test/device_actions_native_test.dart` (source pins)

**Interfaces:**
- `longPress(handle?, x?, y?, durationMs)`, `scrollNode(handle, direction)`, `tap` gains ancestor-click fallback (≤3 levels, named level), every node action `refresh()`es + revalidates (`INVALID_NODE`/`PASSWORD_FIELD`/`NOT_EDITABLE`/`NOT_SCROLLABLE`).

- [ ] **Step 1: Write failing tests** — source pins for the new methods, fallback, revalidation codes.
- [ ] **Step 2: Run RED.**
- [ ] **Step 3: Implement** Kotlin + channel routes (keep existing method names/shapes).
- [ ] **Step 4: Run GREEN + `compileDebugKotlin` if toolchain allows (record honestly otherwise), analyze.**
- [ ] **Step 5: Commit** `feat: native long-press scroll ancestor-click revalidation`

---

### Task 2: Key events + new tools surface

**Files:**
- Modify: `android/.../OvidAccessibilityService.kt` (key dispatch), `MainActivity.kt` (`deviceKey` route)
- Modify: `lib/core/device_control_service.dart` (`key/longPress/scroll` methods)
- Modify: `lib/core/agent_service.dart` (schema for `device_key`/`device_long_press`/`device_scroll`, gates, dispatch, result strings)
- Create: `test/device_actions_tools_test.dart`

**Interfaces:**
- `device_key {key}` closed vocabulary; `device_long_press {node?,x?,y?,duration_ms?}` (default 600, clamp 200–3000); `device_scroll {node, direction}` (up/down/left/right with named forward/backward fallback).

- [ ] **Step 1: Write failing tests** — vocabulary refusal, gates (control-only, read-only/plan denied, mutating), arg validation/clamps, honest result strings.
- [ ] **Step 2: Run RED.**
- [ ] **Step 3: Implement** native + Dart + schema/dispatch.
- [ ] **Step 4: Run GREEN + touched suites, analyze.**
- [ ] **Step 5: Commit** `feat: device key long-press scroll tools`

---

### Task 3: Cancellation + honest submit contract

**Files:**
- Modify: `lib/core/device_control_service.dart` (generation tokens, `beginDeviceGeneration`, `cancelDeviceActions`)
- Modify: `lib/core/agent_service.dart` (bump on run start/Stop; overlay-X path; submit result strings verbatim)
- Create: `test/device_actions_cancel_submit_test.dart`

**Interfaces:**
- Superseded in-flight calls report `cancelled: superseded by a newer run/stop`; submit reports `typed`/`submitted`/`message` split incl. API-floor message.

- [ ] **Step 1: Write failing tests** — generation supersede, Stop bumps, submit-field matrix.
- [ ] **Step 2: Run RED.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run GREEN + touched suites, analyze.**
- [ ] **Step 5: Commit** `feat: device action cancellation and submit honesty`

---

### Task 4: Floating overlay (native window + queue/stop wiring)

**Files:**
- Modify: `android/.../OvidAccessibilityService.kt` (overlay window: rounded field, 2×3 handle drag, X⇄send morph, show/hide/text/stop channel methods)
- Modify: `android/.../MainActivity.kt` (`deviceOverlay` routes)
- Modify: `lib/core/agent_service.dart` (overlay send ≡ composer send; X ≡ Stop + cancel; show-guard: active control session only)
- Create: `test/device_overlay_test.dart` (Dart-side wiring via seams/fake channel + source pins)

**Interfaces:**
- `deviceOverlayShow/Hide` (Dart→native), `deviceOverlayText(text)` + `deviceOverlayStop()` (native→Dart). Overlay hidden removes the window (no invisible touch target).

- [ ] **Step 1: Write failing tests** — channel contract, send≡composer mapping, X≡Stop mapping, show-guard, source pins (overlay type, drag, morph).
- [ ] **Step 2: Run RED.**
- [ ] **Step 3: Implement** native window + Dart wiring.
- [ ] **Step 4: Run GREEN + touched suites, analyze.**
- [ ] **Step 5: Commit** `feat: floating control overlay with queue and stop`

---

### Task 5: Verification, audit, README

**Files:**
- Create: `test/device_overlay_actions_parity_test.dart`
- Create: `docs/superpowers/audits/2026-09-10-device-overlay-actions.md`
- Modify: `README.md`

- [ ] **Step 1: Add end-to-end test** (overlay contract + key/scroll/long-press/cancel/submit composition).
- [ ] **Step 2: Run full verification** (`flutter test`, analyze, `build apk --debug` (expected to fail on missing gitignored `google-services.json` — record honestly), `git diff --check`).
- [ ] **Step 3: Write audit + README; mark device checks NOT EXECUTED.**
- [ ] **Step 4: Commit** `docs: verify overlay and device actions`

---

## Execution Order

```text
1 native action core -> 2 key/tools surface -> 3 cancel/submit -> 4 overlay -> 5 verification
```
