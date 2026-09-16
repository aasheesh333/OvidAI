# Native Sandbox-Backed Plugins (NP3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement in-process native capabilities for `Shell History`, `Git Workbench`, and `PDF Tools` backed by `SandboxService.I.exec` behind an injectable `SandboxRunner`, so all three install via `nativeCapability` routing and expose real `plugin__<slug>__<tool>` agent tools.

**Architecture:** New `lib/core/native_plugins/sandbox_utilities.dart` holds the `SandboxRunner` typedef plus three `NativePluginCapability` classes; `registerSandboxUtilities()` is wired into the existing `registerAllNativePlugins()` in `lib/core/state.dart`. Tests use fake runners keyed on command signature — never a live sandbox.

**Tech Stack:** Dart, Flutter, existing `SandboxService`, `NativePluginRegistry`, `NativePluginConfigStore`, `SharedPreferences` (via the store).

**Spec:** `docs/superpowers/specs/2026-09-16-native-sandbox-plugins-design.md`

## Global Constraints

- Zero new pubspec dependencies; zero PRoot/Node/python-toolchain code of our own (sandbox binaries only).
- Tool naming strictly follows `plugin__<plugin_slug>__<tool_name>` (slugs via `NativePluginRegistry.slugify`: `shell_history`, `git_workbench`, `pdf_tools`).
- Presence gate message is exactly `Sandbox is not installed — open Studio once to install it, then retry.`
- Timeouts clamped 5..600s; reads default 60s, `clone`/`push`/`merge`/`compress` default 300s.
- Output truncated at 6000 chars head+tail with an exact omission notice (MCP trim convention).
- Error taxonomy: `ArgumentError` = bad/missing args; `FormatException` = malformed content; exec failures pass through verbatim.
- `flutter analyze` must report 0 issues, and all tests must pass.

---

### Task 1: SandboxRunner + Shell History

**Files:**
- Create: `lib/core/native_plugins/sandbox_utilities.dart` (typedef + first capability)
- Create: `test/native_plugins_sandbox_test.dart` (grows in Tasks 2–3)

**Interfaces:**
- Produces:
  ```dart
  typedef SandboxRunner =
      Future<String> Function(
        List<String> args, {
        String? cwd,
        Duration? timeout,
      });

  Future<String> defaultSandboxRunner(
    List<String> args, {
    String? cwd,
    Duration? timeout,
  }) =>
      SandboxService.I.exec(
        args,
        cwd: cwd,
      ).timeout(timeout ?? const Duration(seconds: 60));

  class ShellHistoryCapability implements NativePluginCapability {
    ShellHistoryCapability({
      SandboxRunner? runner,
      bool Function()? isSandboxInstalled,
    });
    // pluginName 'Shell History', configFields const [], tools:
    // search(query, limit=50), recent(limit=20)
  }

  void registerSandboxUtilities(); // registers Shell History in this task
  ```
- Consumes: `NativePluginCapability`, `NativePluginRegistry`, `NativePluginConfigStore` from `lib/core/native_plugin.dart`; `SandboxService` from `lib/core/sandbox_service.dart`.

- [ ] **Step 1: Write the failing tests**

In `test/native_plugins_sandbox_test.dart`, with a fake runner keyed on
command signature plus `isSandboxInstalled` override:
```dart
test('shell history presence gate returns the exact Studio message', () async {
  final cap = ShellHistoryCapability(
    runner: (_, {cwd, timeout}) async => 'unused',
    isSandboxInstalled: () => false,
  );
  expect(
    await cap.callTool('search', {'query': 'git'}),
    'Sandbox is not installed — open Studio once to install it, then retry.',
  );
});

test('shell history search filters newest-first with limit', () async {
  // fake runner returns canned history for `cat <file>`; assert newest
  // matching lines first and length == limit
});

test('shell history reports honestly when no history file exists', () async {
  // fake runner: HISTFILE echo empty + cat throws/empty; expect the
  // 'No shell history file found in the sandbox yet' message
});

test('shell history rejects an empty query', () async {
  // expect ArgumentError for search with {'query': '  '}
});

test('shell history recent returns the tail', () async {
  // fake newest-5000-lines input; expect last `limit` lines newest-first
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugins_sandbox_test.dart`
Expected: FAIL (file not found)

- [ ] **Step 3: Implement typedef + default runner + ShellHistoryCapability**

Create `lib/core/native_plugins/sandbox_utilities.dart`:
- `SandboxRunner` typedef and `defaultSandboxRunner` exactly as above.
- `ShellHistoryCapability`:
  - `pluginName` → `'Shell History'`; `configFields` → `const []`; `configure` → no-op (`async {}`).
  - `tools` → `search` (required `query` string, optional `limit` int default 50) and `recent` (optional `limit` int default 20) with JSON-schema maps.
  - `callTool`: unknown tool → `ArgumentError`; presence gate first (exact message); resolve history file via runner `['bash', '-c', 'echo $HISTFILE']` (non-empty stdout wins) else `~/.bash_history`; read newest 5000 lines via `['bash', '-c', 'tail -n 5000 <file>']`; filter/sort in Dart; absent-file (empty probe output or empty read) → the exact absent message; truncate output at 6000 chars with omission notice.
  - `limit` tolerant-parsed like NP2 (`num` or numeric `String`, else `FormatException`; clamp 1..500).
- `registerSandboxUtilities()` registers `ShellHistoryCapability()` with defaults.

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/native_plugins_sandbox_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/core/native_plugins/sandbox_utilities.dart test/native_plugins_sandbox_test.dart
git commit -m "feat(plugin): native Shell History capability on SandboxRunner"
```

---

### Task 2: Git Workbench

**Files:**
- Modify: `lib/core/native_plugins/sandbox_utilities.dart`
- Modify: `test/native_plugins_sandbox_test.dart`

**Interfaces:**
- Consumes: `SandboxRunner`, file from Task 1; `NativePluginConfigStore.I.read/save` for `default_path`.
- Produces:
  ```dart
  class GitWorkbenchCapability implements NativePluginCapability {
    GitWorkbenchCapability({
      SandboxRunner? runner,
      bool Function()? isSandboxInstalled,
    });
    // pluginName 'Git Workbench'
    // configFields: [NativePluginConfigField(key: 'default_path',
    //   label: 'Default working directory', secret: false)]
    // tools: status, log, branch, clone, commit, push
  }
  ```
  `registerSandboxUtilities()` also registers `GitWorkbenchCapability()`.

- [ ] **Step 1: Write the failing tests**

Append to `test/native_plugins_sandbox_test.dart`:
```dart
test('git workbench presence gate returns the exact Studio message', ...);
test('git status/log/branch happy paths', ...);
// fake runner asserts exact argv:
//   status → ['git', '-C', '<path>', 'status', '--short', '--branch']
//   log → ['git', '-C', '<path>', 'log', '--oneline', '-n', '20']
//   branch → ['git', '-C', '<path>', 'branch', '-a']
test('git clone/commit/push validate args', ...);
// clone missing url → ArgumentError; commit missing message → ArgumentError
test('git surfaces backend errors verbatim', ...);
// fake runner returns 'fatal: not a git repository (exit code 128)' +
// non-zero shape; expect the text passed through, not a fake success
test('git default_path falls back and overrides', ...);
// with no path arg and no configured default_path → runner receives no
// cwd (exec defaults to sandbox home); with configured default_path →
// runner receives cwd == configured value; explicit path arg wins
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugins_sandbox_test.dart`
Expected: FAIL (GitWorkbenchCapability not defined)

- [ ] **Step 3: Implement GitWorkbenchCapability**

- `pluginName` → `'Git Workbench'`; `configFields` → single non-secret `default_path`; `configure` → `NativePluginConfigStore.I.save(pluginName: pluginName, fields: configFields, values: values)` (unknown keys throw via the store — no extra code).
- `tools` → `status` (optional `path`), `log` (optional `path`, optional `limit` default 20), `branch` (optional `path`), `clone` (required `url`, optional `path` destination), `commit` (optional `path`, required `message`), `push` (optional `path`, optional `remote` default `'origin'`, optional `branch`) — each with JSON-schema maps.
- `callTool`: unknown tool → `ArgumentError`; presence gate first (exact message); resolve working dir = explicit `path` arg → stored `default_path` (via `NativePluginConfigStore.I.read(pluginName: pluginName, key: 'default_path')`) → null (omit `cwd` so exec defaults to sandbox home).
  - `status` → `['git', '-C', dir, 'status', '--short', '--branch']` (omit `-C dir` when dir is null).
  - `log` → `['git', '-C', dir, 'log', '--oneline', '-n', '$limit']` (`limit` tolerant-parsed 1..200, default 20).
  - `branch` → `['git', '-C', dir, 'branch', '-a']` plus a `current: <name>` marker line parsed from the `* ` line (when parseable; otherwise raw output).
  - `clone` → `['git', 'clone', url, if (dest != null) dest]` with `timeout_seconds` default 300.
  - `commit` → `['git', '-C', dir, 'add', '-A']` then `['git', '-C', dir, 'commit', '-m', message]`; return combined outputs.
  - `push` → `['git', '-C', dir, 'push', remote, if (branch != null) branch]` with `timeout_seconds` default 300.
  - Every tool accepts optional `timeout_seconds` (tolerant-parsed, clamped 5..600; default 60 except clone/push 300) and forwards it to the runner; truncate at 6000 chars with omission notice.
- Extend `registerSandboxUtilities()` to register the new capability.

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/native_plugins_sandbox_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/core/native_plugins/sandbox_utilities.dart test/native_plugins_sandbox_test.dart
git commit -m "feat(plugin): native Git Workbench capability on SandboxRunner"
```

---

### Task 3: PDF Tools

**Files:**
- Modify: `lib/core/native_plugins/sandbox_utilities.dart`
- Modify: `test/native_plugins_sandbox_test.dart`

**Interfaces:**
- Consumes: `SandboxRunner`, file from Tasks 1–2.
- Produces:
  ```dart
  class PdfToolsCapability implements NativePluginCapability {
    PdfToolsCapability({
      SandboxRunner? runner,
      bool Function()? isSandboxInstalled,
    });
    // pluginName 'PDF Tools', configFields const []
    // tools: merge, split, compress, extract_text, info
  }
  ```
  `registerSandboxUtilities()` also registers `PdfToolsCapability()`.

- [ ] **Step 1: Write the failing tests**

Append to `test/native_plugins_sandbox_test.dart`:
```dart
test('pdf tools presence gate returns the exact Studio message', ...);
test('pdf tools route pypdf-present and qpdf-missing', ...);
// fake runner: `command -v python3` ok + import check ok,
// `command -v qpdf` fails → merge invokes python3, never qpdf
test('pdf tools report honestly when no backend exists', ...);
// both probes fail → exact 'No PDF backend in the sandbox ...' message
test('pdf split rejects malformed ranges', ...);
// ranges 'a-b', '0', '5-2' → FormatException; '1,3-4' ok
test('pdf merge requires two or more inputs', ...);
// single input → ArgumentError
test('pdf compress reports sizes honestly', ...);
// fake `stat -c%s` (or wc -c) values in/out; expect both byte counts
// in the result text
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugins_sandbox_test.dart`
Expected: FAIL (PdfToolsCapability not defined)

- [ ] **Step 3: Implement PdfToolsCapability**

- `pluginName` → `'PDF Tools'`; `configFields` → `const []`; `configure` → no-op.
- `tools` → `merge` (required `inputs` list, required `output`), `split` (required `input`, required `ranges` string, optional `out_prefix`), `compress` (required `input`, required `output`), `extract_text` (required `input`, optional `pages` string), `info` (required `input`) — each with JSON-schema maps.
- `callTool`: unknown tool → `ArgumentError`; presence gate first (exact message); backend probe per invocation via runner: `['bash', '-c', 'command -v python3 && python3 -c "import pypdf"']` ok → pypdf; else `['bash', '-c', 'command -v qpdf']` ok → qpdf; else the exact neither-backend message.
  - Shared range parser: comma list of `N` / `N-M`, 1-based, `N>=1`, `M>=N` else `FormatException` (reuse the tolerant int parsing convention from NP2).
  - `merge`: `inputs.length < 2` → `ArgumentError`. pypdf: `['python3', '-c', <merger script with argv inputs+output>]`; qpdf: `['qpdf', '--empty', '--pages', ...inputs, '--', output]`. Default 300s timeout.
  - `split`: parse ranges; default `out_prefix` = input basename minus extension; one output per range `<prefix>-<i>.pdf`. pypdf: per-range page extraction; qpdf: `['qpdf', input, '--pages', input, <range>, '--', out]`.
  - `compress`: pypdf re-write / qpdf `--linearize` + `--object-streams=generate`; report input/output byte sizes via runner `stat -c%s` (fallback `wc -c < file` when stat fails); never claim a reduction the numbers do not show. Default 300s timeout.
  - `extract_text`: pages syntax = split ranges, null = all; return text + `{pages, chars}` stats line. No model call.
  - `info`: page count + byte size + producer/title when readable (pypdf `PdfReader` metadata; qpdf `--show-all-data` parse best-effort).
  - Every tool accepts optional `timeout_seconds` (tolerant-parsed, clamped 5..600; default 60 except merge/compress 300) and truncates at 6000 chars with omission notice.
- Extend `registerSandboxUtilities()` to register the new capability.

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/native_plugins_sandbox_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/core/native_plugins/sandbox_utilities.dart test/native_plugins_sandbox_test.dart
git commit -m "feat(plugin): native PDF Tools capability on SandboxRunner"
```

---

### Task 4: Registration Wiring + Full Verification

**Files:**
- Modify: `lib/core/state.dart` (one line in `registerAllNativePlugins`)
- Test: new integration assertions + full suite

**Interfaces:**
- Consumes: `registerSandboxUtilities()` from Task 1–3; `registerAllNativePlugins()` at `lib/core/state.dart:1273`.

- [ ] **Step 1: Write the failing integration test**

Append to `test/native_plugins_sandbox_test.dart`:
```dart
test('sandbox capabilities register and route through install truth', () async {
  registerSandboxUtilities();
  addTearDown(NativePluginRegistry.I.clearForTest);
  for (final name in ['Shell History', 'Git Workbench', 'PDF Tools']) {
    expect(NativePluginRegistry.I.has(name), isTrue);
  }
  // Roster truth (Task-3 pattern): an installed+enabled row advertises
  // plugin__git_workbench__clone; disabled it does not.
});
```
(Follow the exact Task-3 roster-test pattern from `test/native_plugin_agent_test.dart` for the installed/enabled halves.)

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugins_sandbox_test.dart`
Expected: FAIL (registration exists from Tasks 1–3, so this step fails on the roster halves until wiring is verified — if green already, note it and proceed)

- [ ] **Step 3: Wire registration + verify**

Add `registerSandboxUtilities();` to `registerAllNativePlugins()` in `lib/core/state.dart` (after the three existing register calls) with the matching import. Run the focused test.

- [ ] **Step 4: Run gates**

Run: `/root/flutter/bin/dart analyze lib test`
Expected: 0 issues.
Run: `/root/flutter/bin/flutter test`
Expected: all green (only the known pre-existing PR13 MCP-timeout failure excepted; verify any other failure against its base before claiming pre-existing).

- [ ] **Step 5: Commit and push**

```bash
git add lib/core/state.dart test/native_plugins_sandbox_test.dart
git commit -m "feat(plugin): bootstrap sandbox capabilities on app initialization"
git push origin hoplite/gortyn-77773150
```

---

## Self-Review

**1. Spec coverage:** §2 typedef/registration → Tasks 1+4. §3 presence/timeout/truncation/taxonomy/paths/gating → asserted in every task's tests. §4.1 → Task 1. §4.2 (+ `default_path` config) → Task 2. §4.3 (+ backend probe order) → Task 3. §5 one-line wiring + install routing (no new code — NP1 mechanism) → Task 4. §6 verification → Task 4 gates.

**2. Placeholder scan:** no TBD/TODO; every step has exact commands, exact messages, exact argv shapes, exact commit messages.

**3. Type consistency:** `SandboxRunner` signature identical in Tasks 1–3; `registerSandboxUtilities()` grows monotonically; `NativePluginConfigStore.I.save/read` signatures match the landed Task-1 implementation (`save(pluginName:, fields:, values:)`, `read(pluginName:, key:, secret:)`); `pluginName` strings match the seeds (`Shell History`, `Git Workbench`, `PDF Tools`); slugs derive from the same `slugify`.
