# Studio + Browser — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL:
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans. Checkbox (`- [ ]`) syntax.

**Goal:** Studio-only folder picker, external GitHub login, login dot, fresh
tabs + shared data, working Google sign-in.

**Spec:** `docs/superpowers/specs/2026-09-13-studio-browser-design.md`

## Global Constraints

- No DSH references in `lib/`/`test/`.
- RED test first; full `flutter test` + `flutter analyze` green.
- Flutter binary `/root/flutter/bin/flutter`.
- Device rows `NOT EXECUTED`.

---

### Task 1: Studio-only folder picker
**Files:** `lib/ui/studio_screen.dart`, `lib/ui/chat_screen.dart`
- [ ] RED: no non-Studio entry opens a folder picker.
- [ ] Gate on Studio mode; update stale comments.
- [ ] GREEN.

### Task 2: External GitHub login
**Files:** `lib/ui/github_login_sheet.dart`
- [ ] RED: launch uses `LaunchMode.externalApplication`.
- [ ] Implement with `url_launcher`.
- [ ] GREEN.

### Task 3: Login dot
**Files:** `lib/ui/studio_screen.dart`
- [ ] RED: green when logged in, red when not.
- [ ] Replace the status text with the dot.
- [ ] GREEN.

### Task 4: Fresh tabs, shared data
**Files:** `lib/core/agent_service.dart`
- [ ] RED: new session has empty tabs; cookies shared; deleted-session tabs purged.
- [ ] Implement.
- [ ] GREEN.

### Task 5: Google sign-in
**Files:** `lib/core/agent_service.dart`, `OvidWebViewHandler.kt`
- [ ] Pin UA/cookie settings; prefer external browser for OAuth.
- [ ] Implement.

### Task 6: Verify + audit
- [ ] Full `flutter test` + `flutter analyze`; `git diff --check`.
- [ ] Audit `docs/superpowers/audits/2026-09-13-studio-browser.md`.
