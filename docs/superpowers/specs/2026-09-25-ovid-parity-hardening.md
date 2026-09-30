# Ovid parity & hardening — audit findings + workstreams

**Status:** active · 2026-09-25
**Goal:** make Ovid a trustworthy drop-in for Claude Code / Codex / opencode users on
Android — every hook, plugin, MCP, skill, command, permission mode, subagent, control
mode and browser action either works as it does in Claude Code or is honestly gated;
inbuilt MCP/plugins that cannot run on Android are removed/gated; the agent's working
directory is cleanly separated from Ovid's own app and it asks the user when a folder is
needed.

This is evidence-based: every item cites the audit that found it. Verifiable fixes only;
no "100% bug-free" claim — we close concrete, cited defects with tests.

## Workstreams (priority order)

### WS1 — Security (highest impact)
- **Control→Full-Access child escalation.** `_resolveChildMode` (`agent_service.dart:19932`)
  forces a Control child to `drive`, which is UNCONFINED — a jailed Control parent spawns an
  unconfined, unprompted filesystem/network child. Fix: never upgrade; a Control child stays
  Control (or lower). Tested.
- **SSRF IP-encoding.** `isMetadataOrLinkLocalHost` (`agent_service.dart:15549`) misses
  decimal/octal/dotless IPv4 encodings of `169.254.169.254`. Harden to normalize numeric hosts.

### WS2 — Claude Code plugin/hook/command parity
- `plugin.json` `hooks` string value is a FILE path, not a dir (`plugin_adapters.dart:767`).
- inline `mcpServers` string path ignored; `commands`/`skills`/`agents` array pointers ignored (`:784,813`).
- command subdirectory namespace lost → collisions (`skills.dart:481,263`).
- UserPromptSubmit / SubagentStop cannot block via exit 2 (`plugin_manifest.dart:281`).
- hook `permissionDecision:"allow"` does not bypass the prompt (`hook_service.dart:1945`).
- `additionalContext` only extracted for session_start (`hook_service.dart:1111`).
- matcher unanchored substring (`Edit` matches `MultiEdit`) (`hook_service.dart:508`).

### WS3 — Claude Code agents as real subagents
- Plugin `agents/*.md` are injected as prompt text, not dispatched as isolated subagents;
  declared `model` ignored (`agent_service.dart:19529`). Wire `PluginAgent` → `dispatch_agent`.

### WS4 — Android inbuilt cleanup / honesty
- Playwright seed MCP cannot run on Android (needs browser binaries) — remove/hard-gate.
- Puppeteer/Postgres seed MCP: drop "still works" copy; sandbox-only `needsRuntime`.
- Docker (`localhost:2375`) / Obsidian (`file://`) / Redis (`localhost`) defaults meaningless on
  Android — require remote host or gate.
- MCP Server Hub / Voice Input rows install to nothing; Sandbox Runtime seeds `installed:true`
  prematurely — honesty fixes.

### WS5 — Browser correctness & gating
- `browser_open` returns a second unauthenticated fetch, not the rendered tab; redirect not
  re-gated (`agent_service.dart:12560`).
- host grant only on explicit navigation; in-page nav escapes to ungranted hosts.
- read-only deny-list holes: `hover`/`scroll`/`navigate`/tab ops allowed (`agent_service.dart:15845`).

### WS6 — Workspace separation
- No code guard preventing the agent (esp. Full Access on desktop) from touching Ovid's own
  tree; no structured "request working folder" tool (`state.dart:4987`, `agent_service.dart:4468`).

### WS7 — Control-mode robustness
- Gestures report success on dispatch, not completion (null `GestureResultCallback`); overlapping
  gestures fail (`OvidAccessibilityService.kt:1806`).
- `device_read` delta path under-guards when `package` absent (`agent_service.dart:17398`).

### WS8 — Plugin-contributed UI
- No mechanism for a plugin to render UI; even `NativePluginConfigField` is not rendered.
  Add a declarative settings-field renderer first (lightest safe path).

## Tracker
| WS | Status | Commits (CI-verified) |
|---|---|---|
| 1 Security | **done** | Control→drive escalation fixed; SSRF numeric-IP hardening (`4eef501`) |
| 2 CC hooks/commands | **done** | matcher anchoring, plugin.json string/array pointers, command sub-dir namespacing (`f989d0f`), UserPromptSubmit additionalContext injection (`1419c22`), `permissionDecision:"allow"` bypass + UserPromptSubmit exit-2 block (`09768e1`), SubagentStop exit-2 block (`4a58d51`). |
| 3 CC agents→subagents | **done** | plugin `agents/*.md` dispatched as REAL subagents — own persona/system prompt, own tool allowlist, own model pin; zero-nesting falls back to inline. |
| 4 Android inbuilt | **done** | Playwright + Puppeteer seeds removed (browser binaries can't run on Android); Postgres honest (`781bc0a`); Docker/Redis require a remote host + refuse loopback before dialing, Obsidian gated to app-accessible storage, K8s hint fixed (`28792cd`); backing-less catalog rows no longer offer Install and say what they are, Sandbox Runtime copy honest (`6938d93`). |
| 5 Browser | **done** | browser_open reads rendered tab (fixes double-fetch + redirect SSRF); hover blocked in read-only (`4d70bb2`); page-acting tools re-gate the tab's LIVE host, so in-page navigation can't escape to an ungranted host (`3b05379`). |
| 6 Workspace sep | **satisfied** | agent already runs in a per-session sandbox workspace (never the app's own tree, which isn't accessible on device); the inherited-folder prompt already instructs "ask the user which folder instead of assuming" (provenance fix). A structured folder-picker tool remains a nice-to-have. |
| 7 Control mode | **done** | gesture completion callback + bounded serialization, deadlock-safe off-main dispatch (`562b7c2`); `device_read` no longer skips the sensitive guard on a package-less payload (`c9e9e01`). |
| 8 Plugin UI | **done** | declarative settings-field contribution + schema-driven form; secrets via secure storage (`e189411`). |

## Follow-ups — all closed except one deliberate refusal

- **`request_working_folder` tool — DONE.** The prompt-level "ask the user which
  folder" instruction now has a real mechanism: the tool opens the native picker
  and pins the result to the RUN session (never "the active session"), marking it
  user-pinned. Refused in Read-Only, for subagents, and in plan mode.
- **Codex + generic-MCP settings fields — DONE**, and fixing it exposed a real
  leak: both adapters preserved unrecognized manifest keys verbatim, so a
  `configFields` entry with an inline secret `default` was persisted into the
  manifest blob and the §5.1 grant digest. Both now consume the declaration
  through `_addSettingsFields` (which drops inline secret values) and skip those
  keys in the unknown-fields loop.
- **Tool-schema truncation — DONE (found while doing the above).** The compactor's
  160-char description budget was silently cutting **40 of 104** advertised tool
  descriptions, including `run_shell`, `file_read`, `fs_edit`,
  `ask_user_question` and `exit_plan_mode` — guidance the model never received,
  surfacing as silent misuse rather than an error. Budget raised to 520/120 and
  the two still-long descriptions had their load-bearing constraint front-loaded;
  truncation is now ZERO, pinned by a test. Measured cost: roster ~8960 → ~10560
  tokens/request (+17%).

### Deliberately NOT done: WebView/JS plugin panels
A plugin-contributed UI panel that renders plugin-supplied HTML/JS is an
arbitrary-code-execution surface inside an app that also holds device control
(the accessibility service drives other apps), shell execution, stored provider
keys and a GitHub token. One compromised plugin could exfiltrate secrets or
drive the device. Claude Code itself has no plugin-contributed UI, so this is
beyond parity, not a gap against it. The declarative settings-field path (WS8)
covers the real need — configuration UI — with no code execution. If richer
plugin UI is ever wanted, the safe route is a constrained declarative schema
rendered by native widgets (list/form/chart), never a webview.
