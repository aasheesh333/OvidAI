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
| WS | Status |
|---|---|
| 1 Security | in progress |
| 2 CC hooks/commands | pending |
| 3 CC agents→subagents | pending |
| 4 Android inbuilt | pending |
| 5 Browser | pending |
| 6 Workspace sep | pending |
| 7 Control mode | pending |
| 8 Plugin UI | pending |
