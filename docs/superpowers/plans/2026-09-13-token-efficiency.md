# Token Efficiency (No-Folder) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL:
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans. Checkbox (`- [ ]`) syntax.

**Goal:** Reduce the fixed per-request token cost, especially with no folder.

**Spec:** `docs/superpowers/specs/2026-09-13-token-efficiency-design.md`

## Global Constraints

- No DSH references in `lib/`/`test/`.
- RED test first; full `flutter test` + `flutter analyze` green.
- Flutter binary `/root/flutter/bin/flutter`.

---

### Task 1: Measure the baseline
**Files:** analysis only (`agent_service.dart`)
- [ ] Dump a representative no-folder payload; record tool-schema + prompt tokens.
- [ ] Record in the audit.

### Task 2: Mode-aware tool gate
**Files:** `lib/core/agent_service.dart` (`_tools`)
- [ ] RED: read-only mode excludes device tools; control includes them.
- [ ] Implement the gate.
- [ ] GREEN.

### Task 3: Trim redundant schemas
**Files:** `lib/core/agent_service.dart`
- [ ] RED: exposed tool set unchanged for active modes.
- [ ] Remove duplicates/legacy stubs.
- [ ] GREEN.

### Task 4: Re-measure + verify + audit
- [ ] Record the delta.
- [ ] Full `flutter test` + `flutter analyze`; `git diff --check`.
- [ ] Audit `docs/superpowers/audits/2026-09-13-token-efficiency.md`.
