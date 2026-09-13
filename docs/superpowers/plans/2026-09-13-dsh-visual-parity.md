# DSH Web Visual Parity (Home + Chat + Theme) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make Ovid's home/empty state, chat transcript, and theme visually
match the captured DSH web reference; add DSH features Ovid lacks; keep Ovid's
AppBar and composer unchanged.

**Architecture:** Update `Aether` values; restyle transcript widgets to captured
geometry; add a shared compact-number formatter; add a persisted recent-models
list; bound the question card; remove the preview pill.

**Tech Stack:** Flutter/Dart, `theme.dart`, `chat_screen.dart`,
`usage_screen.dart`, `state.dart`, widget/unit tests.

**Spec:** `docs/superpowers/specs/2026-09-13-dsh-visual-parity-design.md`

## Global Constraints

- No DSH references in `lib/`/`test/`; reimplement with `Aether`.
- AppBar and composer structure/behavior unchanged.
- RED test first for behavior changes.
- Full `flutter test` green + `flutter analyze` clean.
- Flutter binary `/root/flutter/bin/flutter`.
- Reference capture (Phase 0) gates implementation.

---

## Phase 0 — Reference capture

### Task 0.1: Install + run DSH web
- [ ] `npx @deepseek-ai/dsh web --no-open --port 3080` in the background.
- [ ] Configure InferHub as a pi-ai provider; verify with one message.
- [ ] Confirm `http://127.0.0.1:3080` loads in the VNC Chrome.

### Task 0.2: Capture 20+ message session
- [ ] Send 20+ realistic vibe-coder messages covering all states in spec §4.
- [ ] Screenshot + measure each state (fonts, sizes, colors, spacing, motion).
- [ ] Write `docs/superpowers/reference/2026-09-13-dsh-web-visual-reference.md`.
- [ ] Enumerate the DSH-feature gap list (spec §6.8).

---

## Phase 1 — Implementation

### Task 1: Theme palette
**Files:** `lib/core/theme.dart`; test `test/theme_parity_test.dart`
- [ ] RED: assert captured palette values.
- [ ] Update `Aether` values (dark first); keep token names.
- [ ] GREEN.

### Task 2: Shared compact-number formatter
**Files:** new `lib/core/format.dart` (or existing util); callers
`usage_screen.dart`, `chat_screen.dart`, `agent_service.dart`
- [ ] RED: K/M/B boundaries + `.0` trimming.
- [ ] Implement `formatCompactCount`.
- [ ] Replace ad-hoc formatters in usage/time/chat.
- [ ] GREEN.

### Task 3: Transcript geometry + typography
**Files:** `lib/ui/chat_screen.dart` (`_MessageView`, `_ReasoningCard`,
`_ToolCard`, `_OvidCodeBox`, `_OvidInlineCodeBuilder`, markdown)
- [ ] RED/widget pin for the captured geometry.
- [ ] Apply captured values; remove residual heavy borders.
- [ ] GREEN.

### Task 4: Streaming + thinking animation
**Files:** `lib/ui/chat_screen.dart`
- [ ] Match captured timing/easing with existing primitives.
- [ ] Widget test for the indicator.

### Task 5: Home/empty state
**Files:** `lib/ui/chat_screen.dart` (`_EmptyState`)
- [ ] RED: `preview` pill absent.
- [ ] Match reference; remove pill.
- [ ] GREEN.

### Task 6: Hint opacity + scrollable question box
**Files:** `lib/ui/chat_screen.dart`
- [ ] RED: hint has faint color; question card scrolls under tall content.
- [ ] Apply.
- [ ] GREEN.

### Task 7: Recent models (max 10)
**Files:** `lib/core/state.dart`, `lib/ui/chat_screen.dart`
- [ ] RED: recents persist, de-dupe, cap at 10, render first.
- [ ] Implement.
- [ ] GREEN.

### Task 8: DSH feature gaps
**Files:** per captured list
- [ ] Implement each captured missing feature with its own RED test.

### Task 9: Verify + audit
- [ ] Full `flutter test` + `flutter analyze`; `git diff --check`.
- [ ] Side-by-side screenshots; audit
      `docs/superpowers/audits/2026-09-13-dsh-visual-parity.md`.
