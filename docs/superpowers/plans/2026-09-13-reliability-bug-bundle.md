# Reliability Bug Bundle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the concrete reliability failures reported on-device (sandbox
apt/ovid-pkg noise, CRLFile, inbuilt plugin install routing, marketplace parse,
provider/model identity, `gh` install).

**Architecture:** Small, targeted fixes at the exact branch points identified in
the design; each with a RED test first.

**Tech Stack:** Flutter/Dart, `sandbox_pkg.dart` generated shell, `AppState`,
`plugins_screen.dart`, host `/bin/sh` + stubs for script tests.

**Spec:** `docs/superpowers/specs/2026-09-13-reliability-bug-bundle-design.md`

## Global Constraints

- RED test first for every behavior change.
- No DSH references in `lib/`/`test/`.
- Keep full `flutter test` green and `flutter analyze` clean.
- Never claim on-device success; device rows `NOT EXECUTED`.
- Flutter binary `/root/flutter/bin/flutter`.

---

### Task 1: ovid-pkg index probe order (`.gz` first)

**Files:**
- Modify: `lib/core/sandbox_pkg.dart` (`_fetch_index`, ~`:125-135`)
- Test: `test/ovid_pkg_test.dart`

**Steps:**
- [ ] RED: assert the generated script tries `Packages.gz` before `Packages.xz`.
- [ ] Change `_fetch_index` order to `.gz` → `.xz` → plain; suppress expected
      probe stderr (`2>/dev/null`) so a working fallback prints no error.
- [ ] GREEN + full `ovid_pkg_test.dart`.

### Task 2: Commit the apt CRLFile fix

**Files:**
- Verify: `lib/core/sandbox_service.dart` (`aptConfigText`), `test/studio_git_reliability_test.dart`

**Steps:**
- [ ] Confirm no active `Acquire::https::CRLFile` directive and the pin passes.
- [ ] Commit (bundled with the P0 branch).

### Task 3: Inbuilt plugin/MCP install routing

**Files:**
- Modify: `lib/ui/plugins_screen.dart` (Install branch ~`:1332-1359`)
- Possibly: `lib/core/state.dart` (`installPlugin` / enable path)
- Test: `test/plugins_ui_github_only_test.dart` or a new focused test

**Steps:**
- [ ] Read `AppState.installPlugin` and the inbuilt seed to pin enable semantics.
- [ ] RED: inbuilt row install calls the direct path; the add sheet is NOT opened.
- [ ] Implement the inbuilt branch (honest result message).
- [ ] GREEN.

### Task 4: Marketplace object-form `source` + real parse errors

**Files:**
- Modify: `lib/core/state.dart` (`_mergeMarketplaceCatalog`, `_githubPluginSource`)
- Test: `test/` marketplace-focused test

**Steps:**
- [ ] RED: object-form `source` (`url`/`github`/`local`) merges; malformed file
      surfaces the parse error, not "No marketplace.json found".
- [ ] Accept `String` or `Map` source shapes; stop swallowing to "not found".
- [ ] GREEN.

### Task 5: Provider/model identity ambiguity

**Files:**
- Modify: `lib/core/state.dart` (`_inferProviderId` + callers)
- Test: provider/model focused test

**Steps:**
- [ ] RED: two providers with the same model id do not silently first-match.
- [ ] Return null on ambiguity; keep stored `providerId` authoritative.
- [ ] GREEN + regression on `lastSelectedProviderId` restore.

### Task 6: `gh` install failure investigation

**Files:**
- Investigate: `lib/core/sandbox_pkg.dart`, `lib/core/sandbox_service.dart`

**Steps:**
- [ ] Reproduce (device or sandbox-equivalent); capture stderr.
- [ ] Fix root cause or document the exact blocker honestly.

### Task 7: Verify + audit

**Steps:**
- [ ] Full `flutter test` + `flutter analyze`.
- [ ] `git diff --check`.
- [ ] Audit note `docs/superpowers/audits/2026-09-13-reliability-bug-bundle.md`.
