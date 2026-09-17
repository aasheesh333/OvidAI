# Native Prompt-Backed Plugins (NP5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 16 LLM-task plugins as `NativePromptCapability` declarations whose execution runs through a new `AgentService.runPromptTool` helper (sub-model call, no tools, no transcript writes), so every row installs via `nativeCapability` routing and exposes real `plugin__<slug>__<tool>` tools.

**Architecture:** `lib/core/native_plugins/prompt_framework.dart` holds the marker interface + shared interpolation/truncation helper; `prompt_dev.dart` / `prompt_knowledge.dart` hold 8 capabilities each; `AgentService` gains `runPromptTool` + a `plugin__` dispatch branch for prompt capabilities + `promptLlmForTest` seam; `registerAllNativePlugins()` gains two lines.

**Tech Stack:** Dart, Flutter, existing `_callLlm` machinery, `NativePluginRegistry`.

**Spec:** `docs/superpowers/specs/2026-09-16-native-prompt-plugins-design.md`

## Global Constraints

- Zero new pubspec dependencies; zero network/sandbox code in capabilities (model does the work).
- `native_plugin.dart` stays LLM-free (no import cycle): all `_callLlm` use lives in `agent_service.dart`.
- Tool naming strictly follows `plugin__<plugin_slug>__<tool_name>`.
- Token bound: at most 12000 input chars per template (`maxInputChars`, overridable per tool), head-truncated with exact `[…N characters omitted…]` notice.
- Honest failures only: null sub-result → `Model call failed: <lastError>.`; empty content → `The model returned no text.`; no provider → `No provider configured for this session.`
- Error taxonomy: `ArgumentError` = bad/missing args (thrown by `buildPrompt`, surfaced by dispatch).
- `flutter analyze` must report 0 issues, and all tests must pass.

---

### Task 1: Prompt Framework + Agent Execution Path

**Files:**
- Create: `lib/core/native_plugins/prompt_framework.dart`
- Modify: `lib/core/agent_service.dart`
- Create: `test/native_plugins_prompt_test.dart` (grows in Tasks 2–3)

**Interfaces:**
- Produces:
  ```dart
  abstract class NativePromptCapability implements NativePluginCapability {
    String get taskSystemPrompt;
    String buildPrompt(String toolName, Map<String, dynamic> args);
    int get maxInputChars => 12000;
    @override
    Future<String> callTool(String toolName, Map<String, dynamic> args) async =>
        'Plugin "$pluginName" runs its tools through the agent — call '
        'plugin__<slug>__$toolName in chat, not directly.';
  }

  /// Shared head-truncation with exact omission notice.
  String boundInput(String text, [int max = 12000]);
  ```
- Produces (agent_service.dart):
  ```dart
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(
    ProviderConfig p,
    List<Map<String, dynamic>> msgs,
    ChatSession session,
  )? promptLlmForTest;

  Future<String> runPromptTool(
    NativePromptCapability cap,
    String toolName,
    Map<String, dynamic> args,
  );
  ```
  `runPromptTool`: resolve session (`_runSession` → active session fallback, same source the roster uses) and provider via `AppState.I.providerForSession(session)`; null/unconfigured → honest `No provider configured for this session.`; build messages `[{role: system, content: cap.taskSystemPrompt}, {role: user, content: cap.buildPrompt(toolName, args)}]`; call `promptLlmForTest ?? (p, msgs, s) => _callLlm(p, msgs, s, includeTools: false)`; extract `choices[0].message.content` trimmed; empty → `The model returned no text.`; null → `Model call failed: ${lastError ?? 'unknown'}.`
- Dispatch: in the `plugin__` branch, after resolving the capability, `if (cap is NativePromptCapability) return runPromptTool(cap, tool, cleanArgs);` else existing path. (Timeout-strip for `_timeout_seconds` keeps working — ignore it on this path; sub-calls ride provider timeouts.)

- [ ] **Step 1: Write the failing tests**

In `test/native_plugins_prompt_test.dart` (mirror `test/native_plugin_agent_test.dart` setup: mock prefs/secure, `AppState.resetTestInstance`, registry `clearForTest` teardown):
```dart
test('prompt capability advertises tools and refuses direct callTool', ...);
// register a tiny throwaway TestPromptCapability with one tool;
// expect registry has it; await cap.callTool(...) contains
// 'through the agent'
test('runPromptTool returns model text via the override seam', ...);
// promptLlmForTest returns choices/content 'HELLO'; install+enable a row
// named like the capability; dispatch 'plugin__<slug>__<tool>' via
// AgentService dispatchForTest (same entry Task-3 tests use); expect
// 'HELLO'; assert captured system prompt == taskSystemPrompt
test('runPromptTool is honest on null and empty results', ...);
// override returns null → contains 'Model call failed'; returns empty
// content → contains 'no text'
test('input bound truncates with exact omission notice', ...);
// boundInput('x'*13000) length <= 12000 + notice; contains omitted count
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugins_prompt_test.dart`
Expected: FAIL (files not found)

- [ ] **Step 3: Implement framework + agent path**

Create `prompt_framework.dart`; add `promptLlmForTest` + `runPromptTool` + dispatch branch in `agent_service.dart` (place the `is NativePromptCapability` check FIRST inside the existing `plugin__` case, before generic handling).

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/native_plugins_prompt_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/core/native_plugins/prompt_framework.dart lib/core/agent_service.dart test/native_plugins_prompt_test.dart
git commit -m "feat(plugin): prompt-capability framework with agent-side model execution"
```

---

### Task 2: Writing/Dev Prompt Plugins (8)

**Plugins:** README Writer, Changelog Gen, Commit Msg Helper, Test Writer, Code Review AI, Git Diff Explain, PR Reviewer, Tailwind Helper.

**Files:**
- Create: `lib/core/native_plugins/prompt_dev.dart`
- Modify: `test/native_plugins_prompt_test.dart`

**Interfaces:**
- Consumes: `NativePromptCapability`, `boundInput` from Task 1.
- Produces: 8 capability classes + `registerPromptDev()`. Exact plugin names (match seeds): `'README Writer'`, `'Changelog Gen'`, `'Commit Msg Helper'`, `'Test Writer'`, `'Code Review AI'`, `'Git Diff Explain'`, `'PR Reviewer'`, `'Tailwind Helper'`. Slugs derive via `slugify` (`readme_writer`, `changelog_gen`, `commit_msg_helper`, `test_writer`, `code_review_ai`, `git_diff_explain`, `pr_reviewer`, `tailwind_helper`).

- [ ] **Step 1: Write the failing tests**

Append: per plugin one test asserting `buildPrompt` embeds the bounded input and the tool schema requires the documented args; one end-to-end dispatch test per plugin through `promptLlmForTest` echo override (override returns `'ECHO:' + user-msg-length` or similar deterministic marker — assert the tool result contains the marker, proving template→model→result flow); `ArgumentError` test for a missing required arg (e.g. `generate` without `diff`).

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugins_prompt_test.dart`
Expected: FAIL (classes not defined)

- [ ] **Step 3: Implement `prompt_dev.dart`**

Each capability: `pluginName`, `taskSystemPrompt` (stable framing), `tools` with JSON schemas per spec §5 (writing/dev), `buildPrompt` switching on `toolName` (unknown → `ArgumentError`), all user content via `boundInput`, `configFields` → `const []`, `configure` no-op. Tool list per plugin (single-tool plugins except where spec says otherwise): README `generate(repo_name, files_summary?, tone?)`; Changelog `generate(commits_text)`; Commit `generate(diff)`; TestWriter `generate(code, framework?)`; CodeReview `review(code, focus?)`; GitDiff `explain(diff)`; PRReviewer `review(pr_diff, checklist?)`; Tailwind `generate(description)`. `registerPromptDev()` registers all 8 with defaults.

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/native_plugins_prompt_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/core/native_plugins/prompt_dev.dart test/native_plugins_prompt_test.dart
git commit -m "feat(plugin): eight writing/dev prompt-backed plugins"
```

---

### Task 3: Knowledge/Productivity Prompt Plugins (8)

**Plugins:** Translate Pro, Study Mode, Meeting Notes, Data Analyst, Issue Triager, Release Notes, Calendar & Tasks, Multi-Model Compare.

**Files:**
- Create: `lib/core/native_plugins/prompt_knowledge.dart`
- Modify: `test/native_plugins_prompt_test.dart`

**Interfaces:**
- Consumes: framework from Task 1.
- Produces: 8 capability classes + `registerPromptKnowledge()`. Exact names: `'Translate Pro'`, `'Study Mode'`, `'Meeting Notes'`, `'Data Analyst'`, `'Issue Triager'`, `'Release Notes'`, `'Calendar & Tasks'`, `'Multi-Model Compare'`.
- Special cases (do NOT implement as plain templates):
  - **Data Analyst** `analyze(csv_text)`: compute column stats LOCALLY (names, row count, numeric min/max/mean — small shared parser in this file), embed stats + bounded raw sample; model returns insights text.
  - **Calendar & Tasks** `parse_reminder(text)`: template demands STRICT JSON `{title, when_text}` (outer model feeds `schedule_create`); `list_help`: static syntax help, no model call needed (return directly from `buildPrompt`? No — `buildPrompt` builds; execution still goes through the sub-call. Simplest honest: `list_help` template is static text; the sub-call echoes it back. Accept the tiny model hop for uniformity — note it in code comment.)
  - **Multi-Model Compare** `compare(prompt, models?)`: NOT a plain template. Implementation lives mostly agent-side: extend `runPromptTool`?? No — keep framework untouched. Instead the capability's tool schema takes `prompt` + optional `models` (≤3, else `ArgumentError` in `buildPrompt`); execution needs fan-out. Ruling (plan-level): implement fan-out INSIDE the capability? It cannot call `_callLlm` (LLM-free rule). Resolution: `MultiModelCompareCapability.buildPrompt` encodes `FANOUT:<modelA>,<modelB>|<prompt>` envelope; `runPromptTool` (Task-1 code, already landed) detects the `FANOUT:` prefix, splits models (max 3 enforced again agent-side), runs sequential sub-calls (requested ids resolved via `AppState.I.providerById`, fallback session provider + recent models — reuse the model-selector's recent list if reachable, else session provider repeated? NO repetition: distinct providers only; fewer than requested → honest shortfall line), and returns `## <model>\n<answer>` sections with per-model failure lines. Task 3 therefore touches `agent_service.dart` (fan-out block inside `runPromptTool`) + tests it. This is the plan-mandated exception to "framework untouched".

- [ ] **Step 1: Write the failing tests**

Append: per-plugin template tests (bounded input, strict-shape demand for `parse_reminder`/flashcards/quiz/triage); Data Analyst stats correctness on a 3-column CSV fixture (no model needed for the stats half); `compare` fan-out test via `promptLlmForTest` recording calls (2 models → 2 calls, `##` sections, max-3 enforcement, one-model-fails → failure line + other section intact); `ArgumentError` on 4 models.

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugins_prompt_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement `prompt_knowledge.dart` + fan-out block**

Eight capabilities per spec §5 (knowledge/productivity) with schemas; `registerPromptKnowledge()`. Fan-out: `FANOUT:` envelope parsing + sequential calls in `runPromptTool` (agent_service.dart addition with tests). Translate `translate(text, target_lang, source_lang?)`; Study `flashcards(text, count=10)` + `quiz(text, count=5)`; Meeting `summarize(transcript)`; Analyst `analyze(csv_text)`; Triager `triage(title, body)`; Release `generate(pr_list)`; Calendar `parse_reminder(text)` + `list_help`; Compare `compare(prompt, models?)`.

- [ ] **Step 4: Run test to verify it passes**

Run: `/root/flutter/bin/flutter test test/native_plugins_prompt_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/core/native_plugins/prompt_knowledge.dart lib/core/agent_service.dart test/native_plugins_prompt_test.dart
git commit -m "feat(plugin): eight knowledge/productivity prompt-backed plugins"
```

---

### Task 4: Registration Wiring + Full Verification

**Files:**
- Modify: `lib/core/state.dart` (two lines in `registerAllNativePlugins`)
- Test: integration assertions + full suite

**Interfaces:**
- Consumes: `registerPromptDev()`, `registerPromptKnowledge()`; `registerAllNativePlugins()` at `lib/core/state.dart:1273`.

- [ ] **Step 1: Write the failing integration test**

Append to `test/native_plugins_prompt_test.dart`: all 16 names registered after `registerPromptDev(); registerPromptKnowledge();`; roster halves for one dev + one knowledge tool (installed+enabled → `plugin__readme_writer__generate` / `plugin__translate_pro__translate` present; disabled → absent). Follow the Task-3 (NP1) roster-test pattern.

- [ ] **Step 2: Run test to verify it fails**

Run: `/root/flutter/bin/flutter test test/native_plugins_prompt_test.dart`
Expected: FAIL on roster halves until wired (if green already, note it and proceed)

- [ ] **Step 3: Wire registration + verify**

Add both register calls to `registerAllNativePlugins()` with imports. Run focused test.

- [ ] **Step 4: Run gates**

Run: `/root/flutter/bin/dart analyze lib test` → 0 issues. Run: `/root/flutter/bin/flutter test` → all green (only known pre-existing PR13 excepted; verify any other failure against its base).

- [ ] **Step 5: Commit and push**

```bash
git add lib/core/state.dart test/native_plugins_prompt_test.dart
git commit -m "feat(plugin): bootstrap prompt-backed capabilities on app initialization"
git push origin hoplite/gortyn-77773150
```

---

## Self-Review

**1. Spec coverage:** §3 interface+runPromptTool+seam → Task 1. §4 token bound/strict shapes/no-secrets/timeouts/analyst hybrid → asserted in Tasks 2–3 tests. §5 dev 8 → Task 2; knowledge 8 (incl. analyst/triager/calendar/compare specials) → Task 3. §6 wiring/install (no new code — NP1 mechanism) → Task 4. §7 verification → Task 4 gates.
**2. Placeholder scan:** exact commands/messages/shapes/commits throughout; no TBD/TODO.
**3. Type consistency:** `NativePromptCapability` members identical Tasks 1–3; `boundInput` shared; `FANOUT:` envelope is the single Task-1-code touchpoint in Task 3 (documented exception); plugin names match seeds verbatim; `promptLlmForTest` signature mirrors `titleLlmForTest` (`(p, msgs, s) → Map?`).
