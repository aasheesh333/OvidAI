# Native Prompt-Backed Plugins (NP5) Spec

**Date:** 2026-09-16
**Author:** opencode
**Status:** Approved for implementation (user waived review gates; rulings recorded in NP5 ledger)
**Scope:** NP5 only — 16 LLM-task plugins (below). Screen Awareness (screenshot attach flow), Email Drafts (needs send backend), Discord Bot Builder (needs API token → NP4), AutoGPT Bridge / LangChain MCP (triage in NP4 spec) are explicitly OUT.

---

## 1. Executive Summary

Sixteen seeded rows are really *model tasks*, not local computations: Translate Pro, Study Mode, Meeting Notes, Code Review AI, Test Writer, README Writer, Changelog Gen, Commit Msg Helper, Issue Triager, Release Notes, Data Analyst, Git Diff Explain, PR Reviewer, Tailwind Helper, Multi-Model Compare, Calendar & Tasks. Faking them with canned text would be a lie; shelling prompts through ad-hoc code in `AgentService` would tangle the agent loop.

This spec defines `NativePromptCapability`: capabilities declare prompt templates + JSON schemas, and **model execution lives in `AgentService`** (a `runPromptTool` helper mirroring the title-generation `_callLlm(..., includeTools: false)` pattern). No import cycle (`native_plugin.dart` stays LLM-free), hermetic tests via an override seam, honest token-bounded behavior.

---

## 2. Architecture & Data Flow

```
Chat & Agent Loop: plugin__translate_pro__translate / ... / catalog_configure_plugin
        │
        v
AgentService plugin__ dispatch (NP1 wiring, extended):
  capability is NativePromptCapability?
    YES → runPromptTool(): buildPrompt() → _callLlm(includeTools:false)
          → content text out (or honest model-failure string)
    NO  → existing capability.callTool() path (unchanged)
        │
        v
NativePromptRegistry entries in lib/core/native_plugins/prompt_utilities*.dart
```

New files: `lib/core/native_plugins/prompt_framework.dart` (marker interface + arg interpolation helper), `lib/core/native_plugins/prompt_dev.dart` (8 writing/dev plugins), `lib/core/native_plugins/prompt_knowledge.dart` (8 knowledge/productivity plugins). Modified: `lib/core/agent_service.dart` (`runPromptTool` + dispatch branch + `promptLlmForTest` seam), `lib/core/state.dart` (one wiring line).

---

## 3. Framework Contract

```dart
abstract class NativePromptCapability implements NativePluginCapability {
  /// System prompt framing the sub-task (stable, cacheable).
  String get taskSystemPrompt;

  /// Build the user message for [toolName] from validated [args].
  /// Must embed a token-bounded slice of user input (see §4).
  String buildPrompt(String toolName, Map<String, dynamic> args);

  /// Default callTool: prompt tools execute ONLY through the agent's
  /// runPromptTool path (needs a live model + session).
  @override
  Future<String> callTool(String toolName, Map<String, dynamic> args) async =>
      'Plugin "$pluginName" runs its tools through the agent — call '
      'plugin__<slug>__$toolName in chat, not directly.';
}
```

Agent-side `runPromptTool(capability, toolName, args)`:
1. Resolve provider + run session exactly like the title-generation call site (session's provider; null → honest `No provider configured for this session.`).
2. `promptLlmForTest ?? _callLlm(p, [{system: taskSystemPrompt}, {user: buildPrompt(...)}], session, includeTools: false)`.
3. Extract `choices[0].message.content` trimmed; empty → honest `The model returned no text.`; null result → `Model call failed: <lastError>.` Never a fake success.
4. No streaming, no tool use inside the sub-call, no transcript writes (invisible helper call, like title generation).

---

## 4. Cross-Cutting Rules

1. **Token bound.** Every template embeds at most `maxInputChars` (default 12000) of user content, head-truncated with an exact `[…N characters omitted…]` notice. Long diffs/transcripts/CSV stay bounded.
2. **Strict output shapes** where the outer model must act on the result (Calendar JSON, Study flashcards, Triage labels): templates demand the shape; `runPromptTool` returns raw text (no local JSON validation — the outer model handles it; a malformed shape is the sub-model's honest output, not our lie).
3. **No secrets, no network, no sandbox** in NP5 (pure prompt + optional local precompute for Data Analyst stats).
4. **Timeouts:** sub-calls ride the normal provider timeout/response-timeout machinery; no per-tool timeout args (unlike exec tools).
5. **Data Analyst hybrid:** parse CSV locally (column names, row count, numeric min/max/mean) with a small shared parser, embed the stats + bounded raw sample in the prompt; the model returns insights text.

---

## 5. Plugin Specifications (tool → args → template essence)

Writing/dev (`prompt_dev.dart`):
- **README Writer** `generate(repo_name, files_summary?, tone?)` → professional README sections from repo facts.
- **Changelog Gen** `generate(commits_text)` → Keep-a-Changelog entries grouped Added/Fixed/Changed.
- **Commit Msg Helper** `generate(diff)` → Conventional Commits one-liner + body.
- **Test Writer** `generate(code, framework?)` → unit tests with edge cases for the given code.
- **Code Review AI** `review(code, focus?)` → findings ordered by severity + suggested fixes.
- **Git Diff Explain** `explain(diff)` → plain-language walkthrough of what the diff does.
- **PR Reviewer** `review(pr_diff, checklist?)` → inline-style findings + approve/needs-work verdict.
- **Tailwind Helper** `generate(description)` → Tailwind classes + minimal markup.

Knowledge/productivity (`prompt_knowledge.dart`):
- **Translate Pro** `translate(text, target_lang, source_lang?)` → translation only, no commentary.
- **Study Mode** `flashcards(text, count=10)` → `Q: / A:` pairs; `quiz(text, count=5)` → numbered MCQs with answer key.
- **Meeting Notes** `summarize(transcript)` → minutes + decisions + action items with owners.
- **Data Analyst** `analyze(csv_text)` → local stats precompute + bounded sample → trends/insights text.
- **Issue Triager** `triage(title, body)` → `area: / severity: / priority: / labels:` strict lines.
- **Release Notes** `generate(pr_list)` → user-facing highlights + upgrade notes.
- **Calendar & Tasks** `parse_reminder(text)` → STRICT JSON `{title, when_text}` for the outer model to feed `schedule_create`; `list_help` → explains reminder syntax. (No direct schedule writes: the outer model owns the action.)
- **Multi-Model Compare** `compare(prompt, models?)` → agent fans out to ≤3 models (requested ids or session provider + 2 most-recent), sequential `_callLlm` calls, returns `## <model>\n<answer>` sections; honest per-model failure lines; max 3 enforced (`ArgumentError` beyond).

---

## 6. Registration & Install

- `registerPromptDev()` / `registerPromptKnowledge()`; both called from `registerAllNativePlugins()` (two lines).
- Install via existing `nativeCapability` routing; `_pluginToolNames` derives from `capability.tools` (no new code).
- No config fields in NP5 (no secrets) — `configure` no-ops; `catalog_configure_plugin` honesty rules from NP1/NP2 apply unchanged.

---

## 7. Verification Plan

- `test/native_plugins_prompt_test.dart` (TDD) with `promptLlmForTest` override (no network): per-tool prompt contains bounded input + truncation notice; strict-shape templates demand the shape; sub-call null → honest failure string; `compare` caps at 3 and labels sections; `parse_reminder` prompt demands strict JSON.
- Direct `capability.callTool` returns the agent-path message (no model touched).
- Roster halves (installed+enabled ↔ `plugin__translate_pro__translate` present).
- Gates: `dart analyze lib test` 0 issues; full `flutter test` green (only known pre-existing PR13 excepted).
