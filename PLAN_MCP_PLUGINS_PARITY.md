# Ovid ↔ DSH Web — MCP, Plugins, Codex/Claude-Code & Native-Linux Deep Parity Audit

> Read-mode audit only — **no code changed in this pass**. Scope: the user asked
> specifically about MCP realtime parity, Plugins parity (schema/hooks/install/run/edit),
> whether Codex/Claude Code and *their* MCP+plugins can be installed and run "same to
> same" as DSH web, native Linux commands/packages working 100%, and "all the features…
> compaction bagera sab kuchh" — i.e. a full feature-completeness pass on top of the
> existing `PLAN.md`/`PLAN_FIXES.md` history.
>
> Method: read every relevant Ovid source file (`mcp_service.dart`, `plugins_screen.dart`,
> `hook_service.dart`, `skills.dart`, `presets.dart`, `commands.dart`, `sandbox_service.dart`,
> `state.dart`, `agent_service.dart`, `health_service.dart`, `studio_screen.dart`), then
> cross-checked against the live `deepseek-ai/deepseek-harness` GitHub repo (package READMEs
> for `mcp/`, `hooks/`, `subagent/`, `preset/`, `compaction/`, `guard/`, `terminal/`,
> `sandbox/`, `interaction/commands/`) fetched fresh today, plus current upstream evidence on
> whether Claude Code / Codex CLIs can even run on Android.
>
> Baseline: branch `ci/verified-android-build-20260827` @ `56dd011`, 229 tests green,
> `flutter analyze` 0 issues (1 pre-existing unrelated warning noted in prior session).

---

## 0. Verdict up front

Ovid already tracks DSH closely at the **agent-loop / tool-surface** layer (run loop,
streaming, queue, todos, plan mode, compaction, jobs, glob/grep, goals, schedule,
subagent dispatch, workflow/ralph, sandbox exec) — this is genuinely ~90%+ parity and
well tested (see `PLAN.md` §3 for the existing matrix).

The gaps the user is pointing at — **MCP realtime, Plugins (schema/hooks), Codex/Claude
Code install, native Linux 100%** — are real and are concentrated in four places:

1. **MCP transport is stdio-only** — no HTTP/SSE servers, no auto-reconnect, no per-server
   timeout config, no duplicate-name rejection. DSH supports both transports with backoff.
2. **"Plugins" are a decorative catalog, not real installable bundles.** Installing a
   plugin in Ovid flips two booleans and (for MCP-category rows) connects a hardcoded
   server. It never fetches or mounts a plugin's *own* skills/commands/agents/hooks/MCP —
   which is the entire point of DSH's "everything is a plugin" model and of Claude Code's
   plugin format Ovid claims to read.
3. **Claude Code / Codex CANNOT physically run on Android** (upstream-confirmed, see §3) —
   so "install Codex/Claude Code and run their real MCP+plugins" is impossible as literally
   stated. What **is** achievable and is the correct interpretation: import/bridge their
   **config formats** (`.mcp.json`, `.claude/` skills+commands+hooks+plugins,
   `~/.codex/config.toml`) into Ovid's own engine — Ovid already does a *sliver* of this
   for MCP JSON; it does none of it for skills/commands/hooks/plugin bundles.
4. **The native Linux toolchain is missing a compiler, ripgrep, and common CLI tools** —
   `apt install` list is `nodejs npm python python-pip uv git curl zlib make binutils`.
   No `clang` (or any C/C++ compiler) means `node-gyp` native builds still fail even with
   exec bits and shebangs fixed. No `ripgrep` means Ovid's grep tool is a hand-rolled Dart
   regex engine, not the real `rg` DSH uses. No `openssh`, `rsync`, `jq`, `unzip`, `tmux`.

Everything below is organized so each gap has: what DSH does (with source), what Ovid
does today (file:line), and the fix shape — ready to become PR33+ without further research.

---

## 1. MCP — gap detail

### 1.1 What Ovid has today (confirmed good)

`lib/core/mcp_service.dart` + `McpServer` in `lib/core/state.dart`:

- Real stdio JSON-RPC 2.0 client: spawns the server **inside the native sandbox**
  (`SandboxService.I.spawn`), does `initialize → initialized → tools/list`.
- Correct error semantics: a JSON-RPC error or timeout surfaces as `MCP error: …`, never
  as a fake result or the literal text `null` (`McpRpcResult`, `_rpc`).
- **Realtime tool sync** — `notifications/tools/list_changed` triggers silent
  `_rediscoverTools` (this is genuine DSH parity, matches
  `dsh-mcp-client`'s "the model's tool set updates automatically").
- Server-death watcher drops a crashed server from `_running` immediately (no stale
  "connected" state with a dead pipe).
- 6000-char head+tail trim with an exact omission notice (spill-style), matches DSH's
  "tool results are bounded" behavior.
- Tool naming: `mcp__<server>__<tool>` — exactly DSH's/Claude Code's/Codex's shape.
- Lazy per-tool-call runtime ensure (`ensureRuntime('node'|'python')`) before spawning
  `npx`/`uvx` commands — good mobile-specific touch DSH doesn't need (desktop always has
  the runtime already).
- Import: `_parseMcpConfig` in `plugins_screen.dart` accepts Claude Code / Claude Desktop
  `mcpServers` JSON map AND (attempted) Codex TOML — genuinely useful cross-tool import.

### 1.2 What's missing vs. `@deepseek-ai/dsh-mcp-client` (confirmed via live package README)

| # | DSH behavior | Ovid today | Evidence |
|---|---|---|---|
| M1 | Two transports: `stdio` (command/args/env/cwd) **and** `streamable-http` (url/headers) | `McpServer` has only `command`/`args`/`envHint` — **no `url`, no `headers`, no `transport` field at all** | `state.dart` `class McpServer` (no url/headers/transport) |
| M2 | Auto-reconnect with exponential backoff (`initialDelayMs` 500 → `maxDelayMs` 30000, `maxAttempts` 10, resets after sustained uptime) | **None.** A crashed server just disappears from `_running`; the model gets `MCP error: server "x" is not connected (its process exited with code N at HH:MM)` and must re-trigger a tool call to force a fresh `connect()` | `mcp_service.dart` — `proc.exitCode.then(...)` only removes the entry, no retry scheduling |
| M3 | Per-server `toolCallTimeoutMs` (default 60000), configurable | Hardcoded 30s deadline for **every** RPC including `tools/call` (`_rpcTimeoutSeconds`) | `mcp_service.dart:_rpcTimeoutSeconds` |
| M4 | Duplicate server name at registration → "later one fails to load with a clear error" | Ovid silently keeps the first (`mcpServers.any((e) => e.name == pname)` dedupe-by-skip in marketplace import); no explicit reject-with-reason on `addCustomMcpServer` | `state.dart` `_mergeMarketplaceCatalog`, `addCustomMcpServer` |
| M5 | A server that lists the same tool twice → "tool list rejected as invalid, previous tool set stays active" | No validation — duplicate tool names from one server would just overwrite each other silently in the `Map` built from the list | `mcp_service.dart` `_rediscoverTools` (raw list→List, no name-uniqueness check) |
| M6 | `failOnStartupError` config (default false) — lets a deployment opt into "abort if this MCP server can't connect" | N/A — no equivalent knob (acceptable to skip; low value on mobile) | — |
| M7 | MCP **resources** and **prompts** — DSH explicitly states "only tools are bridged," so Ovid's tools-only scope is correct parity, not a gap | — | (no action needed) |

### 1.3 MCP fix shape (future PR)

- Add `transport` (`'stdio' | 'http'`), `url`, `headers` to `McpServer`; branch `connect()`
  on transport — `http` speaks streamable-HTTP JSON-RPC over `package:http` instead of
  spawning a process (no sandbox needed for HTTP servers — this also **fixes** the "MCP
  needs Studio opened once" requirement for HTTP-only servers).
- Add a reconnect scheduler: on unexpected exit (not user-initiated `disconnect()`),
  schedule `connect()` again with doubling backoff (500ms→30s), cap at 10 consecutive
  failures, reset the counter after N minutes of stable uptime. Surface reconnect attempts
  as a `_emit('think', …)` line so the user sees it happening instead of a silent stall.
- Make `toolCallTimeoutMs` a per-`McpServer` field (default 60000), separate from the
  handshake timeout (keep handshake at 30s).
- Reject (not silently skip) a duplicate server name on `addCustomMcpServer` with a
  clear return message; same for `_mergeMarketplaceCatalog`.

---

## 2. Plugins — the biggest real gap

### 2.1 What DSH means by "plugin" (confirmed via live packages + `dsh-claude-compat` README)

A DSH/Claude-Code-format plugin is a **directory** (or a marketplace-listed repo) that can
contain any of:

```
plugin-name/
├── .claude-plugin/plugin.json   ← manifest: name/version/description/author
├── commands/*.md                ← becomes /command-name AND a model skill
├── agents/*.md                  ← delegation-shim skill ("delegate with this persona")
├── skills/*/SKILL.md            ← model-loadable instruction bundles
├── hooks/hooks.json              ← real PreToolUse/PostToolUse/Stop/... blocking hooks
└── .mcp.json                     ← mcpServers this plugin wants connected
```

Installing a plugin means: **discover and mount every one of those pieces** — new
slash commands appear, new skills appear in the model's catalog, hooks start firing
(and can **deny** tool calls, not just observe), and MCP servers connect. This is exactly
what `dsh-claude-compat` (a real, shipped DSH plugin) does for `.claude/` directories, and
what `dsh-plugin-market` / `dsh-market` / `dsh-plugin-shop` (real marketplace plugins) list
and one-click install from npm/GitHub.

### 2.2 What Ovid's "plugin" is today

`PluginItem` (`state.dart`) has exactly five fields that matter at runtime:
`name, author, description, version, category, installed, enabled, installs, hooks`.

Reading `plugins_screen.dart` + `agent_service.dart` `agent_install_plugin` (both the UI
button and the model-facing tool path, lines ~5868 and ~6866):

```dart
plugin.installed = true;
plugin.enabled = true;
app.persistPluginState();
// MCP-category only: connects the ONE hardcoded McpServer with a matching name
// everything else: just a snackbar saying which of ~8 hardcoded tool names "unlocked"
```

The "tool gains" mapping (`_toolGainsFor` in `plugins_screen.dart`) is a **hardcoded
switch on plugin display name** — `'Web Search' => 'web_search'`, `'Code Runner' =>
'run_code'`, etc. Installing "PR Reviewer" or "Git Workbench" or "Translate Pro" (real
seeded catalog rows, `state.dart` ~line 2455+) does **nothing** functionally — no new
tool, no new skill, no new command. It is a demo catalog with real-looking metadata and a
fake changelog string (`plugins_screen.dart`: `'v${plugin.version} — stability fixes and
20% faster startup.'`).

Marketplace import (`_mergeMarketplaceCatalog`) reads a plugin entry's
`name/author/description/version/category/installs/hooks` straight from the
`marketplace.json` **inline JSON** — it never dereferences a plugin's `source` field
(`"./plugin"` or `"owner/repo"`) to fetch that plugin's *own* repo and read its
`commands/`, `agents/`, `skills/`, `hooks.json`, `.mcp.json`. So even a well-formed Claude
Code marketplace pointing at a real plugin repo only imports the one-line catalog
description — never the plugin's actual capability.

### 2.3 Plugin gap table

| # | DSH capability | Ovid today | Evidence |
|---|---|---|---|
| P1 | Plugin `source` (`owner/repo` or local dir) is fetched and its `commands/*.md`, `agents/*.md`, `skills/*/SKILL.md` are mounted as real skills/slash-commands | Never dereferenced — only inline marketplace-listing fields are read | `state.dart` `_mergeMarketplaceCatalog` (no fetch of `p['source']`) |
| P2 | Plugin `hooks.json` (or manifest `hooks` key) with real matcher/decision semantics — a hook can **deny** a tool call (`permissionDecision: "deny"`), block a prompt, or force continuation | Ovid's `hooks: Map<String,String>` (event→shell command) is **fire-and-observe only** — `HookService.fire()` return value is only ever used as *injected context text* on `on_pre_request`; nothing consults exit code to deny/block | `hook_service.dart` (no deny path); call sites `agent_service.dart:4446-4460,4817,5398` (all just append the returned string as context, never branch on failure to block) |
| P3 | Plugin `.mcp.json` → its MCP servers mount automatically on install | Only works if a same-named `McpServer` already happens to exist in Ovid's hardcoded seed list (`app.mcpServers.where((s) => s.name == match.name)`) | `agent_service.dart` `agent_install_plugin` case (~5868) |
| P4 | Installed-plugin skills/commands appear immediately in the model catalog and the `/` menu | Never happens — plugins never register a `SkillService` root | no plugin→`SkillService.addRoot` call anywhere (confirmed empty grep) |
| P5 | One-click install resolves and validates an npm spec or GitHub source before running anything ("safe-by-construction installs" — `dsh-plugin-market`) | "Install" is a local boolean flip; no validation, no real content ever downloaded for non-MCP plugins | `plugins_screen.dart` Install `onPressed` |
| P6 | Uninstall reverses exactly what install added (unmounts hooks/commands/skills/MCP) | `installed = false; enabled = false;` — correct for what little state exists, but there's nothing to unmount because nothing was ever mounted | `plugins_screen.dart` Uninstall `onPressed` |
| P7 | Hook hot-install: plugin hooks fire the moment they're installed, no restart | Actually true for Ovid **today**, because `HookService.hasHookListeners` reads `AppState.I.plugins` live — this is correct parity, just for a feature (P2) that can't block anything | `hook_service.dart` |

### 2.4 Plugin fix shape (future PRs — sequenced)

**PR-A (schema + fetch):** extend the marketplace fetch to, for each plugin entry with a
`source` pointing at a GitHub repo, optionally fetch `commands/*.md`, `agents/*.md`,
`skills/*/SKILL.md`, `hooks/hooks.json`, `.mcp.json` from that repo (same
raw.githubusercontent + jsdelivr/githack mirror strategy already used for
`marketplace.json` — reuse `fetchMarketplaceCatalog`'s URL-list pattern). Cache the fetched
files under `<workspace>/.plugins/<owner>_<repo>/`.

**PR-B (mount):** on install, call `SkillService.I.addRoot('<workspace>/.plugins/<id>')`
so its `commands/*.md`/`skills/*/SKILL.md` show up via the existing skill catalog +
`/`-menu (`user-invocable` commands already work through `SkillService.userSkills`) — this
reuses 100% of the existing skill plumbing, no new UI. On uninstall, `removeRoot` +
`reload()`.

**PR-C (real hook decisions):** extend `PluginItem.hooks` value from a bare command string
to `{command, blocking: bool}` (or parse a real `hooks.json` matcher/decision shape per
DSH). Wire `on_pre_request`/`on_post_tool`/tool-pre-execute call sites to check the hook's
**exit code**: 0 = allow (current behavior, inject stdout as context), 2 = deny (surface
"BLOCKED by hook: <stderr>" to the model exactly like the existing `run_shell` DENIED
path). This is the change that makes Ovid hooks *functionally* equivalent to
`dsh-hooks-claude-code`'s PreToolUse deny, not just an audit log.

**PR-D (drop the decorative catalog):** either (a) mark the remaining hardcoded
demo-only rows (`PR Reviewer`, `Web Clipper`, `Translate Pro`, `Git Workbench`, etc.) as
`category: 'Agent'`/`'Tool'` with an honest "installs a persona-preamble skill, no new
tool" behavior via PR-B, or (b) remove them from the seed catalog so nothing installable
is fake. Given the user's ask for "same to same," (a) is more valuable — turn every seeded
row into a real skill file so installing genuinely does something.

---

## 3. Codex / Claude Code — what's actually possible

### 3.1 The literal ask is not achievable, and here's the primary-source evidence

- `anthropics/claude-code#50270` (open, filed 2026-04-18): Claude Code ≥2.1.113 ships a
  **Bun-compiled native glibc binary**; Termux/Android reports `process.platform ===
  'android'` which isn't in Claude Code's platform map, and even when forced, "Android's
  kernel rejects `ET_EXEC` glibc ELF binaries." Community-maintained pinned/patched forks
  (`IronShing/termux-claude-code`, `bd-loser/claude-code-termux`) exist specifically
  *because* upstream does not work on Android — and they still require musl-loader
  gymnastics with no official support, security-patch lag, and a `claude-ssh` bug report
  confirms even Anthropic's own **Remote Host connector** cannot install the CLI on
  Termux/Android ("Native binaries for linux-arm64-android are not available on this
  release channel").
- Codex CLI (`@openai/codex`) is a Rust binary published only for
  `linux-{x64,arm64}-musl`; running it under Termux requires **PRoot** to fake
  `/etc/resolv.conf`/`/etc/ssl/certs` paths the static musl binary hardcodes, and even
  community Termux ports (`@jimohovb/codex-cli-termux`) are unofficial rebuilds, not
  upstream.
- Practical conclusion: **shipping actual Claude Code / Codex CLI binaries inside Ovid's
  sandbox is not something the app can make "just work"** — this is an upstream platform
  limitation (no Android release channel, Bionic-vs-glibc/musl loader mismatch), not a bug
  in Ovid. Attempting it means bundling third-party unofficial forks with known
  security-patch lag (the `IronShing` README explicitly documents CVEs the alternative
  fork ships fixes for) — a real supply-chain risk to put in a shipped APK.

### 3.2 What DSH itself does instead (and what Ovid should do)

DSH's own answer is `dsh-subagent-claude-code` / `dsh-subagent-codex`: run the **real,
separately-installed** CLI as a subagent backend over its official protocol (Agent SDK /
`app-server --stdio`) — DSH never bundles or reimplements either tool. On desktop this
works because the user's machine already has Claude Code/Codex installed natively.

On mobile there is no equivalent "already installed on this machine" — so the correct,
honest parity target is not "run Codex/Claude Code inside Ovid" but:

1. **Import their config formats losslessly** (partially done — see §3.3), so a user who
   has been using Claude Code/Codex on a desktop can bring their MCP servers, skills, and
   commands into Ovid without retyping anything.
2. **Match their MCP/plugin *wire behavior*** (tool naming `mcp__server__tool`, JSON-RPC
   semantics, marketplace manifest shape) closely enough that any *server* or *plugin*
   written for Claude Code/Codex/DSH runs unmodified in Ovid — this is achievable and is
   exactly §1 and §2 above.

### 3.3 Current import coverage vs. target

| Source format | Ovid reads it today? | Evidence |
|---|---|---|
| Claude Code / Claude Desktop `mcpServers` map JSON | Yes (`_parseMcpConfig` in `plugins_screen.dart`, also marketplace map-form) | `plugins_screen.dart` `_parseMcpConfig`, `state.dart` `_mergeMarketplaceCatalog` importMcp |
| Codex `config.toml` `[mcp_servers.*]` | Yes — a real regex-based TOML-table parser exists (`sectionRe` matches `[mcp_servers.<name>]`, extracts `command`/`args`). **Gap:** it never extracts an `env` table, so a Codex server needing an API key (e.g. `GITHUB_TOKEN`) imports with no env — the JSON path extracts `env` but the TOML path silently drops it | `plugins_screen.dart` `_parseMcpConfig` TOML branch — `_ImportedMcp(...)` call passes no `env:` argument |
| `.claude-plugin/marketplace.json` (Claude Code marketplaces) | Yes, one of three fetch paths | `state.dart` `fetchMarketplaceCatalog` `paths` list |
| `~/.claude/plugins` installed-plugin skills/commands/agents | No — this is exactly gap P1/P2 above | — |
| `.claude/settings.json` `hooks` (PreToolUse etc., real deny semantics) | No — Ovid's own hooks are observe-only (gap P2); importing Claude's hook *format* would need P2's exit-code branching first | — |
| `~/.codex/skills/*/SKILL.md`, `instructions.md` | No | — |

**Fix shape:** add an `env` line extractor (`^env\.([A-Za-z0-9_]+)\s*=\s*"([^"]*)"` or a
`[mcp_servers.name.env]` sub-table) to the existing TOML branch of `_parseMcpConfig` so
Codex-imported servers carry their API keys like the JSON path already does. Everything
else in this section is subsumed by the Plugin fixes in §2.4.

---

## 4. Native Linux commands & packages — "100%" gap

### 4.1 Current installed payload (confirmed exact)

Bootstrap payload (bundled in the APK, Termux-derived): `bash dash coreutils apt dpkg tar
curl zstd gpgv` + their shared libs + apt methods + terminfo (`sandbox_service.dart`
header comment, `_patchExtractedShebangs`).

Post-install `apt install` list (`sandbox_service.dart:548`):
```
nodejs npm python python-pip uv git curl zlib make binutils
```//
Deb-direct fallback list (`sandbox_service.dart` `_debDirectInstall` call): `nodejs npm
python python-pip uv git curl zlib` (same minus make/binutils).

### 4.2 What's missing for "native Linux commands and packages work 100%"

| Missing | Why it matters | Confirms as real gap because |
|---|---|---|
| **A C/C++ compiler** (`clang` — Termux dropped `gcc`, symlinks `cc`/`gcc`/`g++` onto `clang`) | `make`+`binutils` alone cannot compile anything — `node-gyp`/native npm addons (`bcrypt`, `sharp`, `better-sqlite3`, etc.) will still fail even with exec-bit/shebang fixes already shipped in PR22, because there is no compiler binary at all | User's own reported error included `node-gyp: Permission denied` — that's now *fixed* (exec bits), but the NEXT failure for the same class of package is "clang: not found" |
| **ripgrep (`rg`)** | Ovid's `fs_grep`/`fs_glob` are pure-Dart reimplementations (`agent_service.dart:_handleFsGrep/_handleFsGlob`) using `dart:core` `RegExp` — different regex dialect (no PCRE2/Rust-regex lookaround etc.), different perf characteristics, and NOT what a user means by "grep works like real Linux" when they run `rg` directly in the terminal | DSH's own `tool-fs-search` is explicitly "ripgrep-backed" (`rg --json`) — Ovid's is admittedly not, per `PLAN.md` line 176: "no ripgrep backend, no spill" |
| **openssh** (ssh/scp/sftp) | No SSH client at all — any workflow needing `git` over SSH, `scp` to a server, or `ssh` into infra fails outright | absent from apt list |
| **rsync** | No efficient file sync tool | absent |
| **jq** | JSON manipulation in shell scripts (extremely common in agent-authored bash) is unavailable — the agent has to fall back to python one-liners | absent |
| **unzip / zip standalone** | `archive` package handles this in-app, but shell scripts the agent writes (`unzip foo.zip`) will fail; only zstd is present for the sandbox's own bootstrap | absent from the apt list (only used internally, not installed as a user-facing binary) |
| **tmux / screen** | No terminal multiplexing — matters less since Ovid's own multi-tab terminal UI substitutes for this, but any agent-authored script assuming `tmux` exists fails | absent |
| **A persistent PTY** (see §5) | Every `run_shell`/terminal command is `bash -c '<cmd>'` as an **independent process** — `cd`, exported env vars, and shell state do NOT persist between commands in the Studio terminal tabs or between `run_shell` calls | `_TerminalPaneState._run` calls `SandboxService.I.exec(['bash', '-c', c], ...)` fresh every submit — confirmed no session-lived shell process |

### 4.3 Fix shape (future PR, low risk — pure package-list + verification additions)

1. Extend the `pkgs` string in `_installRuntimesWithRetry` (and the deb-direct fallback
   list) to: `nodejs npm python python-pip uv git curl zlib make binutils clang ripgrep
   openssh rsync jq unzip tmux`. Termux package names confirmed via the Termux wiki's own
   published `pkg install` list (all of these are real, correctly-named Termux packages).
2. Route `fs_grep`/`fs_glob` through the sandbox's real `rg`/`find` when
   `SandboxService.I.isInstalled` (shell out to `rg --json` / `find`), keeping the current
   pure-Dart implementation as the fallback for when the sandbox isn't installed yet (Android
   6 devices, or before first Studio open) — this is the direct fix for "grep 100% same as
   Linux."
3. Add `clang`, `ripgrep`, `openssh`, `jq` to `HealthService.probeRuntimes()`/`runChecks()`
   so the Health screen (and the agent, via a `doctor`-style read) can see and report on
   them individually, matching the existing per-binary probe pattern already used for
   node/python/git/curl.
4. Add a "compiler smoke test" (`echo 'int main(){return 0;}' > t.c && clang t.c -o t &&
   ./t`) to the health probes — parallel to the existing `libz.so.1`/`mkdtemp` smoke tests.

---

## 5. Everything else the user's "sab kuchh" sweep should cover

Cross-checked against live DSH package READMEs (`guard/`, `terminal/`, `preset/`,
`compaction/compaction-tool-result-pruner/`) not previously covered in `PLAN.md`:

| # | DSH feature | Ovid status | Fix shape |
|---|---|---|---|
| F1 | **Persistent PTY** (`ctx.terminals` — one long-lived shell process per session, interactive stdin, `TerminalWaitReason`, foreground-process-group signaling) | Missing — every terminal command is a fresh `bash -c` (see §4.2). No way to run `ssh`, a REPL, or anything needing continuous stdin | Spawn ONE long-lived `bash -i` per terminal tab via `SandboxService.spawn` (not `exec`), keep its `Process` alive, write commands to its `stdin`, read its `stdout`/`stderr` streams continuously. Bigger change — own PR. |
| F2 | **Repeat-tool-reminder guard** (`dsh-repeat-tool-reminder` — detects the model calling the same tool with identical canonicalized args 3/5/8× in a row, injects an escalating "stop repeating, re-read the result" nudge) | Missing entirely — confirmed zero matches for any repeat-detection logic | Track `(tool, canonicalArgs)` run-length per session in the agent loop; at configured thresholds inject a system/context note before the next model call. Small, self-contained addition. |
| F3 | **Tool-result pruner as a pre-compaction step** (`dsh-compaction-tool-result-pruner` — deterministically truncates oversized tool results to head/marker/tail BEFORE deciding whether full summarization is even needed) | Ovid's compaction goes straight to LLM summarization; no cheap model-free pre-pruning pass | Add a pure-Dart pass that rewrites any tool `content` over e.g. 8192 chars to head(4096)+marker+tail(1024) as part of `_maybeCompactLocked`, remeasure, and only summarize if still over threshold — mirrors `spillToolOutput`'s existing trim style, just applied proactively during compaction. |
| F4 | **Compaction convergence retry** — DSH retries summarization up to `compactionRetries` and **rejects a summary that doesn't shrink its source**, throwing rather than silently keeping an oversized context | Ovid's `_applyCompaction` accepts whatever the summarizer LLM returns with no size check or retry | After computing the new `s.compactedSummary`, compare `estimateMessageTokens(summary)` against the shadowed span's token count; if not smaller, retry once with a stricter instruction, then fall back to the model-free pruner (F3) instead of accepting a non-shrinking summary. |
| F5 | **Discoverable, user-authorable presets** (`dsh-agent-presets` scans a filesystem root; anyone can add a new preset directory, no code change) | Ovid's 4 presets (`standard/minimal/studio/code`) are a hardcoded `const List` in `presets.dart` — no user-authored custom preset path | Lower priority for mobile (no filesystem "drop a yaml file" UX makes sense on Android) — if pursued, expose "duplicate + edit persona/allowed-tools" from the existing `/preset` popup sheet, persisted in `SharedPreferences`, not a new file format. |
| F6 | **MCP resources/prompts** | Correctly out of scope — DSH itself only bridges tools | No action — false gap. |
| F7 | Compaction/session/hooks/spill/checkpoints/subagents/workflow/browser-automation/session-search/usage-metering | Already strong parity (see `PLAN.md` §0/§3) | No action — re-verified during this audit, no regressions found. |

---

## 6. Priority order for implementation (when you say go)

Ordered by (a) directness to the user's literal complaints and (b) risk/size:

1. **DONE (PR38)** — **Native Linux package list** (§4.3.1). Eager apt/deb-fallback
   lists now carry `ripgrep openssh rsync jq unzip tmux` alongside the existing
   node/python/git/curl/zlib/make/binutils set; Health screen probes and reports each
   individually with Repair wired. `clang`+`libllvm` (~60 MB) is deliberately NOT eager
   — `SandboxService.ensureCompiler()` installs it lazily, triggered from `run_shell`
   only when the command looks like a native build (`npm install`, `node-gyp`, `make`,
   `pip install`, etc.) via `_looksLikeNativeBuildCommand`. 8 new tests, 237 total.
2. **DONE (PR39)** — **Hook deny/block** (P2/PR-C, §2.4). New `on_pre_tool` GATING hook
   event (added to `PluginItem.hookEvents`) with `HookService.fireGate()`: exit code 2
   denies the tool call before `_dispatchInner` ever runs (DSH/Claude-Code PreToolUse
   parity), any other exit code allows. Fail-open on a hook that can't execute (no
   sandbox, exec error) so a broken hook script can never brick every tool call. Wired
   into `AgentService._dispatch` as an awaited pre-check; a denial reuses the existing
   `DENIED by …` prefix contract so the chat UI renders it exactly like a user-declined
   approval. 8 new tests, 245 total.
3. **DONE (PR40)** — **Plugin content mounting** (P1+P4, PR-A/PR-B, §2.4). Marketplace
   plugin entries now keep a normalized `owner/repo` `source` (a local `"./dir"` source
   is correctly dropped — nothing this client can fetch). `AppState.fetchPluginContent()`
   uses the unauthenticated GitHub tree API + raw.githubusercontent.com (same
   no-token shape as `fetchMarketplaceCatalog`) to download a plugin's own
   `commands/*.md` and `skills/*/SKILL.md` into a per-plugin cache dir. Both install
   paths (UI button and the `agent_install_plugin` model tool) trigger the fetch and
   report file counts honestly; `_refreshSkillRoots` mounts an installed+enabled
   plugin's cache dir into `SkillService` every run, so fetched commands appear in the
   `/`-menu and the model's skill catalog with zero new plumbing — reusing the existing
   skill-file scanner as-is. Uninstall reverses it (deletes the cache dir, unmounts).
   10 new tests, 255 total.
4. **DONE (PR41)** — **MCP HTTP/SSE transport + reconnect backoff** (M1+M2, §1.3).
   `McpServer` gains `transport`/`url`/`headers` fields ('stdio' default, so all 37
   existing seed entries compile unchanged). `McpService.connect()` branches:
   the http path performs initialize → notifications/initialized → tools/list as
   one POST per JSON-RPC message to the server URL (both plain-JSON and
   SSE `data:`-line responses parsed, taking the last event per the spec), with
   no sandbox needed. A connection-level failure on a previously-connected http
   server drops it and schedules automatic reconnect with doubling backoff
   (500ms → 30s, max 10 attempts, reset on a successful handshake) — DSH
   `dsh-mcp-client` parity; a non-2xx response stays a per-call error (server
   is up); a user `disconnect()` never triggers reconnect. Reconnect also
   applies to unexpected stdio process death (the death watcher now schedules
   it unless the user disconnected). Custom-server persistence round-trips
   transport/url/headers. UI: the Add-MCP dialog gains a URL field (env-JSON
   doubles as headers for http servers), and the pasted-config importer
   (`.mcp.json` / Claude Desktop / Codex TOML) now preserves `url`/`headers`
   and fixes the audit's §3.3 finding — Codex TOML `env.KEY = "value"` lines
   were silently dropped before. 13 new tests, 268 total.
5. **DONE (PR42)** — **ripgrep-backed fs_grep** (§4.3.2). The host-filesystem half of
   `fs_grep` now runs the REAL `rg` binary (eagerly installed by PR38) whenever the
   sandbox is present — DSH `tool-fs-search` parity ("grep 100% same as Linux"):
   real rust-regex engine, real performance, real binary detection, with flags that
   mirror the Dart walk's exact semantics (`-i`, `--hidden --no-ignore` so the
   workspace's `.dsh`/`.agents`/`.spill` dot-dirs stay searchable, `--max-filesize 2M`,
   `--max-count-total`, `-C`, `--glob`). Automatic fallback to the pure-Dart walk on
   any rg failure — including exit 2 (pattern valid in Dart RegExp but not
   rust-regex, e.g. lookarounds), so a dialect difference can never lose results.
   rg's "no matches" (exit 1) is a trusted verdict, not re-verified. Also strips the
   `ERROR: ld.so:` LD_PRELOAD loader warning from output — a real pollution source on
   the SELinux-blocked-shim devices PR22 documented. `fs_glob` deliberately stays on
   the Dart walk: rg's traversal defaults (hidden-file/gitignore skipping) would
   silently break skills/`.spill` discoverability, and the flags that disable that
   make rg's traversal equivalent to the existing walk — a tested source-contract,
   not an omission. 5 new tests (fake-prefix stub-rg behavioral tests), 273 total.
6. **DONE (PR45)** — **Repeat-tool-reminder (F2)**: `run.repeatKey` +
   `run.repeatStreak` on the run bucket track the STREAK of identical
   (tool, canonicalized-args) pairs — an actual loop, not "the same tool
   within the run". Reminders escalate per DSH thresholds: streak 3 ≈
   "looks looped", 5 ≈ "still repeating", 8 ≈ "hard stop" — matching
   remote control semantics (canonicalized args, per-run isolation, no
   cross-session bleed). 5 new tests, 285 total.
7. **DONE (PR43)** — **compaction pruner+retry (F3/F4)**: oversized tool
   results are rewritten into spill refs (head+marker+tail via the existing
   `spillToolOutput` path) BEFORE the summarizer is ever called, and summarization
   is skipped entirely when pruning alone drops pressure below threshold
   (DSH "pruner … before range selection … skips summarization when pressure
   becomes safe"). F4 adds a 2-attempt convergence loop inside
   `_summarizeCompactSpan`: a summary that does NOT shrink its source span is
   rejected once with a STRICTNESS note, then whatever comes back is accepted
   (history is never lost either way). 2 new tests (pruner-skips-summarizer,
   applyCompaction state flow), 275 total.
8. **DONE (PR44)** — **plugin hook `.mcp.json` auto-mount (P3)**:
   `fetchPluginContent` now also downloads `.mcp.json`; `mountPluginMcpServers`
   (a new AppState method) parses it, dedupes by server name, registers each
   server as a Custom MCP row (category `Plugin`, source `plugin:<owner_repo>`),
   and persists the connected-intent so it reconnects on next boot. Wired
   into BOTH install paths (Plugins-screen button and the
   `agent_install_plugin` model tool) with honest "Mounted N MCP server(s)"
   reporting. Test seam `pluginCacheRootOverrideForTest`; 5 new tests
   (valid mounts, missing/empty/malformed .mcp.json, name-dedup), 280 total.
9. **DONE (PR46)** — **Persistent PTY (F1)**: `lib/core/pty_service.dart`
   adds `PtyShell` (one long-lived non-interactive bash per session inside
   the sandbox, marker-based output framing: `__OVID_DONE_<id>__:<rc>`)
   with a promptless/echo-less protocol (no PS1 chatter, command echo
   stripped, stderr merged as `[stderr]` lines), and `PtyPool` per-session
   registry discarded by `cancelAllRuns` (panic-stop kills the shell too —
   the spawned process is registered in the kill registry). `run_shell`
   gains `persistent: true|false` (default off; only routed through the
   PTY when the sandbox exists — fresh-shell semantics stay the default
   for one-off work). Host-verified via real bash in tests (state persists
   across commands, rc parsing, timeout kill, registry wiring). 4 new
   tests, 289 total.

Each item ships as its own PR against `ci/verified-android-build-20260827`, same gate as
every prior fix in this repo: `flutter analyze` (0 issues) + `flutter test` (all green,
current baseline 273 as of PR42) + new regression tests per change + CI green (Build APK +
Device Test) before merge, per the pattern already established in `PLAN_FIXES.md`.

---

## 7. Status

PR38 (native Linux CLI parity), PR39 (hook deny/block gating), PR40 (plugin content
mounting), PR41 (MCP Streamable-HTTP transport + reconnect backoff), and PR42
(ripgrep-backed fs_grep) are implemented, tested (273/273 `flutter test`, 0
`flutter analyze` issues beyond the one pre-existing unrelated warning), and pushed.
PR43 (compaction pruner+retry) and PR44 (plugin .mcp.json auto-mount) are now DONE (280/273-branch baseline). All §6 items DONE (PR38–PR46). Head=289 tests green.

**Next step:** tell me which item from §6 to start on next (or say "continue down the
list") and I'll implement, test, and push it as the next PR on this thread's branch.
