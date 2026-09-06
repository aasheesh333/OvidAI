# Security + Stability Fix Plan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close verified Critical security gaps and stability bugs with zero DSH-web references.

**Architecture:** Minimal per-bucket fixes in `agent_service.dart` dispatch gates plus `containedPath` reuse; DSH scrub is comment/identifier reword only, no behavior change.

**Tech Stack:** Flutter/Dart, `flutter test`, `flutter analyze`.

**Spec:** Branch `hoplite/gortyn-77773150` @ `b2c7c9b`; gate files `lib/core/agent_service.dart`, `lib/core/sandbox_service.dart`, `lib/core/state.dart`; tests in `test/core_regression_test.dart`.

## Global Constraints

- Flutter path is `/home/ubuntu/sdk/flutter/bin/flutter` (`flutter` not in PATH).
- TDD RED→GREEN required; verification-before-completion required.
- Copyright rule: zero DSH-web comments/references user-visible + code; keep legitimate `deepseek-*` model/provider names only.
- Frequent commits; do not break 302 green tests.
- Bare `echo`/`printf` shell output = fake work, forbidden.

---

### Task 1: Gate fix — `run_code` blocked in plan mode + Read-Only mode

**Files:**
- Modify: `lib/core/agent_service.dart:8279-8298` (`_mutatingTools`), `lib/core/agent_service.dart:7158-7204` (`_readOnlyBlock`)
- Test: `test/core_regression_test.dart` (append to PR48 group or new `Security gates` group)

**Interfaces:**
- Consumes: `AgentService.dispatchForTest(name, args)`, `AgentService.setRunSessionForTest(id)`, `ChatSession(id, title, model, mode)`.
- Produces: `_mutatingTools` contains `run_code`; `_readOnlyBlock('run_code', ...)` returns non-null denial in `AgentMode.safe`.

- [ ] **Step 1: Write the failing test**

```dart
test('SEC1: run_code is blocked in plan mode and Read-Only mode', () async {
  final app = AppState.I;
  final s = ChatSession(id: 'sec1', title: 'S', model: 'm', mode: 'safe');
  app.sessions.insert(0, s);
  app.activeSessionId = s.id;
  AgentService.setRunSessionForTest(s.id);
  addTearDown(() {
    AgentService.setRunSessionForTest('');
    app.sessions.removeWhere((x) => x.id == 'sec1');
  });
  final ro = await AgentService.I.dispatchForTest('run_code', {'code': '1+1', 'lang': 'python'});
  expect(ro, contains('READ-ONLY MODE'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "SEC1"`
Expected: FAIL — `run_code` falls through to approval/exec instead of `READ-ONLY MODE`.

- [ ] **Step 3: Write minimal implementation**

```dart
static const _mutatingTools = {
  'file_write',
  'fs_edit',
  'run_shell',
  'run_code', // <-- add
  'commit',
  ...
};
```

and in `_readOnlyBlock` switch add:

```dart
case 'run_code':
  return roDenied;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "SEC1"`
Expected: PASS; then full file still green.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "SEC: block run_code in plan + read-only gates"
```

### Task 2: Gate fix — `dispatch_agent`/`workflow`/`ralph` blocked in plan mode + Read-Only

**Files:**
- Modify: `lib/core/agent_service.dart:8279-8298`, `lib/core/agent_service.dart:7158-7204`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: same as Task 1.
- Produces: `_mutatingTools` contains `dispatch_agent`, `workflow`, `ralph`; `_readOnlyBlock` denies all three in safe mode.

- [ ] **Step 1: Write the failing test**

```dart
test('SEC2: spawn tools blocked in plan + read-only', () async {
  final app = AppState.I;
  final s = ChatSession(id: 'sec2', title: 'S', model: 'm', mode: 'safe');
  app.sessions.insert(0, s);
  app.activeSessionId = s.id;
  AgentService.setRunSessionForTest(s.id);
  addTearDown(() {
    AgentService.setRunSessionForTest('');
    app.sessions.removeWhere((x) => x.id == 'sec2');
  });
  expect(await AgentService.I.dispatchForTest('dispatch_agent', {'prompt': 'hi'}), contains('READ-ONLY MODE'));
  expect(await AgentService.I.dispatchForTest('workflow', {'goal': 'hi'}), contains('READ-ONLY MODE'));
  expect(await AgentService.I.dispatchForTest('ralph', {'goal': 'hi'}), contains('READ-ONLY MODE'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "SEC2"`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

Add `'dispatch_agent', 'workflow', 'ralph'` to `_mutatingTools` and to the `_readOnlyBlock` denied cases.

- [ ] **Step 4: Run test to verify it passes**

Run: same filter. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "SEC: block dispatch_agent/workflow/ralph in plan + read-only gates"
```

### Task 3: `read_attachment` path traversal via `containedPath`

**Files:**
- Modify: `lib/core/agent_service.dart:5970-5989` (`read_attachment` case)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `AgentService.containedPath(Directory, String)` (existing, tested at `test/core_regression_test.dart:2614`), `sessionWorkDirForTest()`.
- Produces: `read_attachment` with `../` outside workspace returns escape error, never reads outside.

- [ ] **Step 1: Write the failing test**

```dart
test('SEC3: read_attachment refuses workspace escape', () async {
  final app = AppState.I;
  final s = ChatSession(id: 'sec3', title: 'S', model: 'm', mode: 'auto');
  app.sessions.insert(0, s);
  app.activeSessionId = s.id;
  AgentService.setRunSessionForTest(s.id);
  addTearDown(() {
    AgentService.setRunSessionForTest('');
    app.sessions.removeWhere((x) => x.id == 'sec3');
  });
  final res = await AgentService.I.dispatchForTest('read_attachment', {'filename': '../../etc/passwd'});
  expect(res, contains('escapes the session workspace'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "SEC3"`
Expected: FAIL — returns `No file ... in the session workspace` (or reads outside) instead of escape error.

- [ ] **Step 3: Write minimal implementation**

```dart
case 'read_attachment':
  final fname = args['filename'] as String;
  _emit('shell', 'reading: $fname');
  try {
    final work = await _sessionWorkDir();
    final safe = containedPath(work, fname);
    if (safe == null) {
      return 'path escapes the session workspace: $fname — use a path inside the workspace.';
    }
    final f = File(safe);
    ...
```

- [ ] **Step 4: Run test to verify it passes**

Run: same filter. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "SEC: read_attachment workspace containment"
```

### Task 4: Subagent destructive-command bypass — check before auto-approve

**Files:**
- Modify: `lib/core/agent_service.dart:7122-7136` (`_maybeApprove`)
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `AgentService.isDestructiveCommand(String)` (existing).
- Produces: destructive `run_shell`/`job_start`/`run_code` still requires approval even in subagent sessions (no silent auto-true).

- [ ] **Step 1: Write the failing test**

```dart
test('SEC4: destructive gate runs before subagent auto-approve', () {
  final src = File('lib/core/agent_service.dart').readAsStringSync();
  final maybeIdx = src.indexOf('Future<bool> _maybeApprove');
  final subIdx = src.indexOf('running.isSubagent');
  final destIdx = src.indexOf('_isDestructiveCommand(summary)');
  expect(maybeIdx, greaterThanOrEqualTo(0));
  expect(subIdx, greaterThan(maybeIdx));
  expect(destIdx, greaterThan(maybeIdx));
  expect(destIdx, lessThan(subIdx), reason: 'destructive check must come BEFORE subagent early-return');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "SEC4"`
Expected: FAIL — `destIdx > subIdx` today.

- [ ] **Step 3: Write minimal implementation**

Move the destructive-command block above the `running.isSubagent` early return in `_maybeApprove`:

```dart
Future<bool> _maybeApprove(String tool, String summary, String detail) async {
  // Destructive commands always confirm — no mode skips this gate,
  // including unattended subagent sessions.
  if ((tool == 'run_shell' || tool == 'job_start' || tool == 'run_code') &&
      (_isDestructiveCommand(summary) || _isDestructiveCommand(detail))) {
    return await _askUser(...);
  }
  final running = _runSession;
  if (running != null && running.isSubagent) return true;
  ...
```

- [ ] **Step 4: Run test to verify it passes**

Run: same filter. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "SEC: destructive gate before subagent auto-approve"
```

### Task 5: Browser interactive + memory/goal/schedule writes blocked in gates

**Files:**
- Modify: `lib/core/agent_service.dart:8279-8298`, `lib/core/agent_service.dart:7158-7204`
- Test: `test/core_regression_test.dart`

**Interfaces:**
- Consumes: `dispatchForTest`.
- Produces: `browser_click`, `browser_type`, `browser_evaluate`, `browser_press_key`, `browser_fill`, `browser_drag`, `browser_select`, `memory_save`, `create_goal`, `update_goal`, `schedule_create`, `schedule_delete` denied in safe mode and blocked in plan mode.

- [ ] **Step 1: Write the failing test**

```dart
test('SEC5: interactive browser + state writes blocked read-only', () async {
  final app = AppState.I;
  final s = ChatSession(id: 'sec5', title: 'S', model: 'm', mode: 'safe');
  app.sessions.insert(0, s);
  app.activeSessionId = s.id;
  AgentService.setRunSessionForTest(s.id);
  addTearDown(() {
    AgentService.setRunSessionForTest('');
    app.sessions.removeWhere((x) => x.id == 'sec5');
  });
  expect(await AgentService.I.dispatchForTest('browser_click', {'x': 1, 'y': 1}), contains('READ-ONLY MODE'));
  expect(await AgentService.I.dispatchForTest('memory_save', {'content': 'x'}), contains('READ-ONLY MODE'));
  expect(await AgentService.I.dispatchForTest('schedule_create', {'title': 'x', 'when': 'later'}), contains('READ-ONLY MODE'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/home/ubuntu/sdk/flutter/bin/flutter test test/core_regression_test.dart --plain-name "SEC5"`
Expected: FAIL.

- [ ] **Step 3: Write minimal implementation**

Add the 12 names to `_mutatingTools` and to the `_readOnlyBlock` denied cases (browser reads like `browser_read`/`browser_snapshot`/`browser_navigate` stay allowed).

- [ ] **Step 4: Run test to verify it passes**

Run: same filter. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/agent_service.dart test/core_regression_test.dart
git commit -m "SEC: block interactive browser + state writes in read-only/plan gates"
```

### Task 6: DSH-reference scrub (comments + identifiers, no behavior change)

**Files:**
- Modify: `lib/**`, `test/**` — reword `DSH`/`dsh-` comments to neutral wording; rename `_DshMarkdown` → `_OvidMarkdown`, `_DshCodeBox` → `_OvidCodeBox`, `_DshInlineCodeBuilder` → `_OvidInlineCodeBuilder`, `dsh-state-dot-chase` → `ovid-state-dot-chase`, etc.
- Keep: legitimate `deepseek-*` model/provider names only.

**Interfaces:**
- Consumes: `rg -n "DSH|dsh-" lib test` hit list.
- Produces: `rg -n "DSH|dsh-" lib test` returns only legitimate `deepseek-*` keeps; `flutter analyze` clean; `flutter test` green.

- [ ] **Step 1: List hits**

Run: `rg -n "DSH|dsh-" lib test | head -50`
Expected: comment + identifier hits, no user-visible copy except reworded.

- [ ] **Step 2: Reword comments in small batches**

Replace `DSH X parity` → `web-IDE X parity` or behavior-only wording, e.g. `// DSH turn-process folding` → `// Turn-process folding`.

- [ ] **Step 3: Rename identifiers with replaceAll**

```bash
# example
rg -l "_DshMarkdown" lib test
```

Rename consistently, update all call sites.

- [ ] **Step 4: Verify**

Run: `/home/ubuntu/sdk/flutter/bin/flutter analyze && /home/ubuntu/sdk/flutter/bin/flutter test`
Expected: No issues; all tests passed.

- [ ] **Step 5: Commit**

```bash
git add lib test
git commit -m "CHORE: remove DSH-web references (comments + identifiers)"
```

## Self-Review

1. Spec coverage: SEC1 run_code gates; SEC2 spawn gates; SEC3 traversal; SEC4 destructive-before-autoapprove; SEC5 browser/state gates; Task 6 scrub. `events.clear()` parallel clobber and `runTask` wrong-session fallback and `killAllProcesses` global scope are documented follow-ups, not in this batch — correct, they need ownership design, not one-line gate fixes.
2. Placeholder scan: no TBD/TODO; every step has exact code, exact paths, exact commands.
3. Type consistency: `dispatchForTest(String, Map<String,dynamic>) → Future<String>`; `containedPath(Directory, String) → String?`; `isDestructiveCommand(String) → bool`; test session constructor `ChatSession(id, title, model, mode)` matches existing tests at `test/core_regression_test.dart:2390-2441`.
