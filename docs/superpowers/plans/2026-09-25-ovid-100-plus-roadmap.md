# Ovid 78 → 100+ Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take Ovid from 78/100 to a trustworthy, better-than-CLI mobile vibe-coding agent by closing the five things holding the score down: no on-device verification, a god-class core, correctness debt, phone ergonomics, and non-distributability.

**Architecture:** Six independent subsystems, sequenced by dependency (0 → 1 → 2 → 3 → 5 → 4). Trust foundation (device verification, correctness, de-monolith) precedes feature/ergonomics work, which precedes distribution. Each phase keeps the existing, solid concurrency (`AgentRun`/`_RunCtx`/Zone), sandbox, device-control, and plugin/MCP primitives intact.

**Tech Stack:** Flutter/Dart (app), Kotlin (Android accessibility + channels), GitHub Actions CI, Firebase Test Lab / BrowserStack (device lab), `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-25-ovid-100-plus-roadmap-design.md`

## Global Constraints

- Every phase's release gate: `flutter analyze` = **0 issues** AND the full Flutter suite green. From Phase 0 onward the **device-lab job must also be green**.
- Follow the repo mandate: spec → RED test → implement → audit (`docs/superpowers/master-roadmap.md:5-21`).
- Refactors (Phase 2) must be **behaviour-preserving**, proven by characterization tests before and after each extraction.
- Do not add third-party network egress of code/secrets beyond the user's own configured providers.
- Preserve the existing package name `com.dhanuk.ovidai` and all fail-closed security defaults.
- Commit style: `type(scope): summary` matching the repo history (`feat`, `fix`, `refactor`, `test`, `docs`, `ci`).

---

## Phase 1 — Correctness debt (executable now)

**Why:** `docs/ENGINEERING_AUDIT.md` — 331 empty `catch (_) {}` across 27 files with no logging seam, 48 unguarded `firstWhere`, a known silent session-persist failure. These are the crashes/data-loss a user actually hits.

**Files:**
- Create: `lib/core/diag.dart` — the logging seam.
- Create: `test/diag_test.dart`
- Modify (batch): the 27 files under `lib/` with empty `catch (_) {}` → `catch (e) { Diag.swallow('context', e); }`
- Modify: unguarded `firstWhere` sites → `firstWhereOrNull` (from `package:collection`) + explicit null handling.
- Modify: session-persist failure surface in `lib/core/state.dart` (persist path) + a banner hook in the shell.
- Test: `test/diag_test.dart`, plus targeted RED tests per surfaced behaviour.

**Interfaces:**
- Produces: `Diag.swallow(String context, Object error, [StackTrace? st])` → void (records to a ring buffer + `debugPrint` in debug); `Diag.recent()` → `List<DiagEntry>` for tests/health screen; `Diag.onSwallow` test hook.
- Consumes: `package:collection` `firstWhereOrNull`.

### Task 1: The `Diag` logging seam

**Files:**
- Create: `lib/core/diag.dart`
- Test: `test/diag_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/diag_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/diag.dart';

void main() {
  setUp(Diag.resetForTest);

  test('swallow records context + error and is retrievable', () {
    Diag.swallow('mcp.connect', StateError('boom'));
    final recent = Diag.recent();
    expect(recent, hasLength(1));
    expect(recent.single.context, 'mcp.connect');
    expect(recent.single.error, contains('boom'));
  });

  test('ring buffer is bounded to 200 newest entries', () {
    for (var i = 0; i < 250; i++) {
      Diag.swallow('ctx', 'e$i');
    }
    final recent = Diag.recent();
    expect(recent.length, 200);
    expect(recent.last.error, contains('e249'));
    expect(recent.first.error, contains('e50'));
  });

  test('onSwallow hook fires for every swallow', () {
    final seen = <String>[];
    Diag.onSwallow = (entry) => seen.add(entry.context);
    Diag.swallow('a', 'x');
    Diag.swallow('b', 'y');
    expect(seen, ['a', 'b']);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/diag_test.dart`
Expected: FAIL — `diag.dart` / `Diag` not defined.

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/core/diag.dart
import 'package:flutter/foundation.dart';

/// One entry in the diagnostics ring buffer.
class DiagEntry {
  DiagEntry(this.context, this.error, this.stack, this.at);
  final String context;
  final String error;
  final StackTrace? stack;
  final DateTime at;
}

/// Central sink for otherwise-swallowed errors.
///
/// Replaces bare `catch (_) {}` blocks: behaviour stays fail-closed (the
/// error is still not rethrown), but it becomes observable — a bounded ring
/// buffer the health screen and tests can read, plus a debug log line. This
/// closes the "327 silent catches" finding without changing control flow.
class Diag {
  static const int _max = 200;
  static final List<DiagEntry> _ring = <DiagEntry>[];

  /// Test/diagnostic hook: called for every swallow.
  static void Function(DiagEntry entry)? onSwallow;

  static void swallow(String context, Object error, [StackTrace? stack]) {
    final entry = DiagEntry(context, '$error', stack, DateTime.now());
    _ring.add(entry);
    if (_ring.length > _max) _ring.removeRange(0, _ring.length - _max);
    if (kDebugMode) debugPrint('[diag] $context: $error');
    try {
      onSwallow?.call(entry);
    } catch (_) {
      // A misbehaving hook must never re-enter or crash the swallow path.
    }
  }

  static List<DiagEntry> recent() => List.unmodifiable(_ring);

  @visibleForTesting
  static void resetForTest() {
    _ring.clear();
    onSwallow = null;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/diag_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/core/diag.dart test/diag_test.dart
git commit -m "feat(diag): add bounded logging seam to replace silent catches"
```

### Task 2: Route empty catches through `Diag`

**Files:**
- Modify: every `lib/**/*.dart` containing `catch (_) {}` (27 files).
- Test: `test/diag_wired_test.dart`

- [ ] **Step 1: Write the failing test** (a guard-rail that keeps new bare catches out)

```dart
// test/diag_wired_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no bare empty catches remain in lib/ (use Diag.swallow)', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      // Allow the intentional guard inside Diag itself.
      if (f.path.endsWith('core/diag.dart')) continue;
      final matches = RegExp(r'catch \(_\) \{\}').allMatches(src).length;
      if (matches > 0) offenders.add('${f.path}: $matches');
    }
    expect(offenders, isEmpty, reason: 'bare catches:\n${offenders.join('\n')}');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/diag_wired_test.dart`
Expected: FAIL — ~27 offenders listed.

- [ ] **Step 3: Rewrite each site**

For each `catch (_) {}`, replace with a contextual swallow. Pattern:

```dart
// before
} catch (_) {}
// after (context = "<file-stem>.<nearest-method-or-purpose>")
} catch (e) {
  Diag.swallow('mcp_service.disconnect', e);
}
```

Add `import 'diag.dart';` (or the correct relative path) to each modified file. Keep behaviour identical — only the empty body changes. Do this file-by-file, running `dart analyze` after each.

- [ ] **Step 4: Run tests to verify they pass**

Run: `/root/flutter/bin/dart analyze lib test && /root/flutter/bin/flutter test test/diag_wired_test.dart`
Expected: analyze 0 issues; guard-rail test PASS.

- [ ] **Step 5: Commit**

```bash
git add lib test/diag_wired_test.dart
git commit -m "refactor(diag): route swallowed errors through Diag seam"
```

### Task 3: Guard unguarded `firstWhere`

**Files:**
- Modify: 48 `firstWhere` sites in `lib/`.
- Test: `test/first_where_guard_test.dart`

- [ ] **Step 1: Write the failing guard-rail test**

```dart
// test/first_where_guard_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no firstWhere without orElse in lib/ (prefer firstWhereOrNull)', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      for (final m in RegExp(r'\.firstWhere\(').allMatches(src)) {
        // Look ahead a little for an orElse: on the same call.
        final tail = src.substring(m.start, (m.start + 400).clamp(0, src.length));
        if (!tail.contains('orElse')) {
          offenders.add(f.path);
          break;
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/first_where_guard_test.dart`
Expected: FAIL — offender files listed.

- [ ] **Step 3: Convert each site**

Add `import 'package:collection/collection.dart';` where needed, then:

```dart
// before
final x = list.firstWhere((e) => e.id == id);
// after — explicit null handling at the call site
final x = list.firstWhereOrNull((e) => e.id == id);
if (x == null) {
  Diag.swallow('state.lookup', 'no element for $id');
  return; // or the correct fail-closed behaviour for that site
}
```

Where a site legitimately must throw on absence, keep `firstWhere` but add an explicit `orElse: () => throw StateError('<context>')` so the guard-rail passes and the failure is named.

- [ ] **Step 4: Run tests**

Run: `/root/flutter/bin/dart analyze lib test && /root/flutter/bin/flutter test test/first_where_guard_test.dart`
Expected: analyze 0; PASS.

- [ ] **Step 5: Commit**

```bash
git add lib test/first_where_guard_test.dart
git commit -m "refactor: guard firstWhere lookups (firstWhereOrNull + explicit handling)"
```

### Task 4: Surface session-persist failure

**Files:**
- Modify: `lib/core/state.dart` (the `persistSessions` path).
- Modify: `lib/ui/shell.dart` (banner surface).
- Test: `test/session_persist_failure_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// test/session_persist_failure_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(AppState.resetTestInstance);

  test('a persist failure sets a visible flag instead of being silent', () async {
    final app = AppState.createForTest();
    app.failNextPersistForTest = true; // new test seam
    await app.persistSessionsForTest();
    expect(app.persistError, isNotNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/session_persist_failure_test.dart`
Expected: FAIL — `failNextPersistForTest`/`persistError`/`persistSessionsForTest` not defined.

- [ ] **Step 3: Implement the surface**

In `state.dart`: add `String? persistError;` and a `@visibleForTesting bool failNextPersistForTest = false;`. In the persist path wrap the write in `try/catch`, and on failure set `persistError = '$e'`, `Diag.swallow('state.persistSessions', e)`, and `notifyListeners()`. Expose `@visibleForTesting Future<void> persistSessionsForTest() => persistSessions();`. In `shell.dart` render a dismissible banner when `persistError != null` that offers Retry (re-calls persist and clears the flag on success).

- [ ] **Step 4: Run tests**

Run: `/root/flutter/bin/flutter test test/session_persist_failure_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/state.dart lib/ui/shell.dart test/session_persist_failure_test.dart
git commit -m "fix(state): surface session-persist failure with a retry banner"
```

### Task 5: Phase 1 release gate

- [ ] **Step 1:** `/root/flutter/bin/dart analyze lib test` → 0 issues.
- [ ] **Step 2:** `/root/flutter/bin/flutter test` → all green.
- [ ] **Step 3:** Update the tracker in the spec: Phase 1 → **done**. Commit `docs`.

---

## Phase 0 — Real-device verification (needs cloud device-lab access)

**Why:** Every audit's §8 checklist is `NOT EXECUTED`. This is the #1 trust blocker; it also gates all later phases' release gates.

**Files:**
- Create: `.github/workflows/device-lab.yml` (Firebase Test Lab or BrowserStack physical ARM64).
- Create: `scripts/device_checklist.sh` — scripts each audit's §8 rows.
- Modify: each `docs/superpowers/audits/*.md` §8 table as rows pass.

**Tasks (expanded into their own plan when reached):**
- [ ] Provision device-lab credentials (secret) + a minimal real-device smoke that installs the release APK on API 31 and 34 and asserts the launcher opens.
- [ ] Script install → approve → session activation → restart promotion → disable/uninstall.
- [ ] Script Control-mode gesture smoke (tap/type/double-tap/drag on a known app) via the accessibility service.
- [ ] Script sandbox tool smoke (node/npm/python/git/curl) — reuse the base64 script already in `device-test.yml:87`.
- [ ] Script browser screenshot→vision round-trip.
- [ ] Flip each audit's `NOT EXECUTED` → `PASS`; record APK SHA-256.
- **DoD:** ≥2 Android versions full checklist PASS, pinned in CI. **Gate:** device-lab job green.

---

## Phase 2 — God-class refactor (behaviour-preserving)

**Why:** `lib/core/agent_service.dart` = 21,245 lines with a 206-case `_dispatchInner` switch and triplicated tool metadata (schema in `_coreTools`, roster gate in `_tools`, case in switch, approval set). A new tool needs 4 edits. Concurrency primitives are solid — keep them; extract the orchestration.

**Files (create):** `lib/core/agent/tool_registry.dart`, `lib/core/agent/llm_transport.dart`, `lib/core/agent/subagent_manager.dart`, `lib/core/agent/run_loop.dart`. `AgentService` becomes a thin coordinator.

**Tasks (own plan when reached — each is: characterization test → extract → prove identical):**
- [ ] Golden/characterization harness: record current tool-roster JSON, dispatch outcomes for a fixed script, and SSE parse results as fixtures.
- [ ] Extract `ToolRegistry`: each tool a self-describing handler (`AgentTool` at `agent_service.dart:21241` is the intended seam) carrying schema + gate + dispatch + approval-need. Retire the 206-case switch. Prove roster JSON byte-identical.
- [ ] Extract `LlmTransport` (OpenAI + Anthropic strategies) with the SSE parser + 2-layer retry. Prove parse fixtures identical.
- [ ] Extract `SubagentManager` (`_handleDispatchAgent`/`_runSubagentSession`).
- [ ] Extract `RunLoop` from `_runTaskBody` (~1,050 lines) into step objects.
- **DoD:** `agent_service.dart` < ~4k lines; no mega-switch; new tool = one file; suite + device-lab green.

---

## Phase 3 — Phone-coding ergonomics

**Why:** Turns "second tool" into "use instead of CLI" on mobile.

**Files:** `lib/ui/composer_*` (voice + chips), a new diff-review widget, checkpoint-restore UI over `SessionLedger`, reuse `lib/core/voice_input_service.dart`.

**Tasks (own plan when reached):**
- [ ] Voice-first composer: push-to-talk → task; hands-free approval ("haan/nahi").
- [ ] Per-hunk swipeable diff-review card for `fs_edit` changes (accept/reject).
- [ ] Quick-action chips (run tests / fix errors / commit / explain).
- [ ] Checkpoint/restore UI over the existing ledger.
- [ ] Code-aware composer input (monospace, tab, bracket matching).
- **DoD:** ship a non-trivial change with zero keyboard typing.

---

## Phase 5 — Moat features (better-than-CLI)

**Why:** Things a CLI structurally cannot do — this crosses 100.

**Tasks (own plan when reached):**
- [ ] Build→install→drive→fix loop: agent installs its own build on-device, drives via Control mode, reads failures via screenshot→vision, fixes.
- [ ] Background agents that keep running while the phone is locked (over `agent_notification_service.dart` keep-alive) with push-notification completion.
- [ ] Notification-driven approvals (over `pendingApprovalsElsewhere`).
- [ ] On-device screenshot debugging loop.
- **DoD:** end-to-end "build this repo, run it on my phone, fix the crash" demo.

---

## Phase 4 — Distribution + privacy (ship gate)

**Why:** `targetSdk = 28` (SELinux exec block) blocks Play; no privacy policy despite sensitive permissions; signing silently falls back to debug keystore.

**Tasks (own plan when reached):**
- [ ] `targetSdk` uplift via scoped-storage + exec-free sandbox path, OR a documented F-Droid/sideload release story.
- [ ] Permissions diet — drop `SEND_SMS`/`MANAGE_EXTERNAL_STORAGE` etc. if not essential.
- [ ] Privacy policy + Data Safety form.
- [ ] CI signing gate: release build **fails** when signing secrets are absent (currently silent debug-sign).
- **DoD:** uploadable AAB or clean F-Droid release with privacy policy; signing gate enforced.

---

## Self-review notes

- **Spec coverage:** every §5 phase in the spec maps to a phase here; Phase 1 is fully bite-sized (executable now), later phases are task-outlined and expand into their own plans when reached (per the writing-plans "split by subsystem" guidance).
- **Types:** `Diag.swallow(String, Object, [StackTrace?])`, `Diag.recent()`, `DiagEntry(context, error, stack, at)`, `AppState.persistError`, `AppState.persistSessionsForTest()` — used consistently across Task 1–5.
- **No placeholders** in Phase 1 tasks; later phases are deliberately outlines pending their own detailed plans.

## Progress tracker

- [ ] Phase 1 — Correctness debt
- [ ] Phase 0 — Real-device verification
- [ ] Phase 2 — God-class refactor
- [ ] Phase 3 — Phone-coding ergonomics
- [ ] Phase 5 — Moat features
- [ ] Phase 4 — Distribution + privacy
