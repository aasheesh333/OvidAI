# Ovid — Production Hardening Plan (branch `hoplite/gortyn-77773150` @ 2ac8936)

## Context
User wants: (1) fix P0 bug — Ovid Cloud "Auto" + manual models never load in the app;
(2) full audit of every screen (45+) for bugs, UI/UX defects, must-have UX features;
(3) security hardening; (4) performance for ~10M DAU; (5) Claude Code MCP + plugin parity
with usage tracking. Server runs on VPS 103.216.171.23 (`/opt/ovid-gateway`: Caddy → mint
:8090 / LiteLLM :4000, Postgres, Redis via docker compose). SSH is not reachable from this
cloud container (raw TCP unsupported) — user chose to run a Claude Code session ON the VPS
for server-side work. Repo work happens here.

## Phase 0 — Immediate ops (user)
- Rotate VPS root password (it was pasted in chat); move to SSH keys, `PermitRootLogin prohibit-password`.
- Install Claude Code on VPS, run session in `/opt/ovid-gateway` for Phase 1B.

## Phase 1 — P0: model catalog (`GET https://api.ovidsi.com/v1/models` → 503 `catalog_unavailable`)
Root cause chain (confirmed in code):
- `server/images/verifier.py:102-120` (`models` handler in `mount_images`, live on mint via
  `server/images/deploy/images_gateway.py:527` + `Caddyfile.snippet:12-16`) swallows every error,
  including 401 from LiteLLM, into a 503 with no logging.
- Most likely LiteLLM rejects the user's stored virtual key (expired/deleted/over budget); client
  `lib/core/ovid_cloud_service.dart:564-570` only clears `_keyIdentity` on 401/403, so it retries
  the dead key forever; `/mint` returns the same Redis-cached key.
- `lib/ui/chat_screen.dart:2455,2676` hide even seeded `auto` unless status == ready.

### 1A. Repo fixes (here)
- verifier.py: `except ImageError` → real status (401 `sign_in_required`/`key_invalid`, 402/429 budget);
  log upstream status + exception class; keep 503 only for upstream 5xx/timeout. Add tests in
  `server/images/tests/test_verifier.py` for 200 / 401 / budget / 5xx / timeout.
- ovid_cloud_service.dart: on 401 OR repeated `catalog_unavailable`, clear key & re-mint once
  (bounded backoff, single-flight); persist last-good catalog and serve it while stale.
- chat_screen.dart picker: always show `auto` + cached models with a "catalog stale — retry" banner.
- Normalize mint-returned `base_url` (ovid_cloud_service.dart:484) via the same normalizer as `state.dart:189`.
- Remove/wire dead `refreshOvidCloudModels` (state.dart:6622).

### 1B. VPS (Claude Code session on server)
Diagnose with: `docker compose ps/logs mint litellm`, direct LiteLLM `/v1/models` with master key
and a real user key, `/key/info` for expiry/budget/blocked, then mint :8090 and Caddy.
Fix: re-issue invalid keys in live `/opt/ovid-gateway/verifier/mint.py` (`/mint` validates stored
key via `/key/info`, re-mints if invalid/expired/over-budget); deploy patched verifier; verify the
LiteLLM `auto` alias + manual models exist. Keep APP check behaviour intact.

## Phase 2 — Claude Code MCP + plugin parity (`lib/core/mcp_service.dart`, `hook_service.dart`, `plugin_adapters.dart`, `agent_service.dart`)
Already done (keep): stdio, Streamable HTTP, legacy SSE, PKCE OAuth, `.mcp.json`/Codex TOML,
`${VAR}`/`${CLAUDE_PLUGIN_ROOT}`, list_changed, reconnect, commands/skills/agents, 13 hook events.
Work items (ordered by plugin breakage impact):
1. **PostToolUse contract**: await hooks (not fire-and-forget, agent_service.dart:13586); pass full
   `tool_input` + untruncated `tool_response`; honour `decision:block`/exit-2/`additionalContext`.
2. **Claude Code tool-name + input aliasing**: map Glob, Grep, WebFetch, Task, MultiEdit,
   NotebookEdit; translate `fs_edit {path,old_str,new_str}` ↔ `{file_path,old_string,new_string}`
   both ways (tool_input and `updatedInput`); `Write` vs `Edit` on create (hook_service.dart:1033).
3. **MCP client capabilities**: answer server→client requests (`ping`, `roots/list`,
   `sampling/createMessage` with user approval, `elicitation/create` via sheet) — fix early-return at
   mcp_service.dart:2738; advertise capabilities + protocol `2025-06-18`; progress/logging notifications.
4. **Remote OAuth**: RFC 9728/8414 discovery from `WWW-Authenticate`, dynamic client registration,
   `resource` param, `app_links` redirect callback (replace paste flow in `mcp_oauth_sheet.dart`).
5. MCP image results to vision models; raise 6000-char cap to token-based limit (~25k tokens, configurable).
6. MCP prompts as `/mcp__server__prompt` slash commands; `@server:resource` mentions.
7. Plugin format: `${CLAUDE_PLUGIN_DATA}`, `${CLAUDE_SKILL_DIR}`, `!`cmd`` + `@file` in commands,
   `model` for commands/skills, `allowed-tools` = pre-approval (not restriction), agent
   `disallowedTools`/`permissionMode`, marketplace `ref/sha`, git/git-subdir/npm sources, default
   branch detection (plugin_source_resolver.dart:445), output styles, `userConfig`; unknown
   hook events → warn + forward-compatible passthrough.
8. **Usage tracking**: new `lib/core/tool_usage_store.dart` fed from existing `tool_end`
   (agent_service.dart:13511), `hook/result` (hook_service.dart:2429) and skill/command load points;
   key `{pluginId, mcpServerId, tool}`; daily rollups (count, errors, p50/p95 ms) persisted;
   surface on plugin + MCP detail pages and Usage screen; optional Firebase `logEvent` (exists, unused).

## Phase 3 — Security (ranked)
- H1: Plugin grants, custom MCP list, permission mode out of SharedPreferences → secure storage
  (or HMAC with Keystore key verified on load) (`plugin_permissions.dart:350`, `state.dart:9404`);
  git token via credential-helper pipe, not `$PREFIX/.ovid-git-credentials`.
- H2: Approval digest must include SHA-256 of the full plugin content tree; re-verify on activation
  (`plugin_permissions.dart:54-92`).
- M1 per-plugin `CLAUDE_ENV_FILE` scoping + deny PATH/NODE_PATH/PYTHONPATH/HOME/GIT_*/npm_config_*.
- M2 FileProvider → `cache/outgoing-shares/` only; validate NativeShare.kt sources.
- M3 SSRF guard resolves DNS and checks all addresses (incl. IPv6 ULA, mapped, 100.64/10).
- M4 scrub secrets from MCP args/url; M5 `catalog_add_mcp` stdio always needs user approval.
- M7 cert pinning for api.ovidsi.com / ovidsi.com with backup pins.
- M8 rate limits on `/account/*`, `/shares`, `/s/{token}` (Caddy `rate_limit` + app-level).
- Low: release `debugPrint`/`print` → `Diag`; FastAPI docs off; zip-slip check in bootstrap extract.
- Server: fix `verifier.py` error swallowing (Phase 1), never log keys.

## Phase 4 — Performance for 10M DAU (highest leverage first)
Screen count: 42 full screens + ~25 sheets + ~30 dialogs (Navigator.push, no router).
1. **Streaming rebuild storm (P0)**: `ChatScreen.build` (chat_screen.dart:1190, 790-line build) listens
   to both global notifiers; every token (16ms throttle, agent_service.dart:12835) rebuilds the whole
   screen. Fix: split into `ValueListenableBuilder`/`Selector` slices — live-bubble notifier for streaming
   text only; app bar, composer, panels, sidebar listen to narrow notifiers. Cache parsed markdown per
   message id+hash (chat_screen.dart:8510); use `StringBuffer` snapshot without full `toString()` per token.
2. Give `_ChatTextScaler` `==`/`hashCode` (chat_screen.dart:63) so MediaQuery doesn't invalidate all text.
3. **History storage (P0)**: move sessions out of SharedPreferences `setStringList` (state.dart:4956,
   3074) into SQLite (already a dependency; reuse `session_search.dart` FTS DB): one row per session +
   per-message rows, incremental writes, lazy load, JSON decode in `compute()` isolate; one-time migration.
4. Startup: move `SandboxService.checkExisting()` recursive deletes (sandbox_service.dart:577) off the
   pre-`runApp` path to a background isolate after first frame.
5. Sidebar → `ListView.builder` (sidebar.dart:177); `MediaQuery.sizeOf` (shell.dart:210, chat_screen.dart:1207);
   remove sync IO in build/keystrokes (chat_screen.dart:5143,5201,5852; studio_editor.dart:510);
   cap live WebViews (LRU, browser_screen.dart:558); model picker `ListView.builder`; memoize
   `activeSession`/`rootSessions` (state.dart:6050) and usage aggregation; avatar `cacheWidth`;
   kill 3s poll timer (shell.dart:91).
6. Longer term (separate PRs): split `agent_service.dart` (23.7k LOC) / `state.dart` (10.8k) into
   domain services with scoped notifiers.

## Phase 5 — UI/UX fixes & must-have features
P0:
- Localization scaffold: `flutter_localizations` + `intl`, ARB (en + hi first), extract 310+ strings
  incrementally (start with chat, settings, login, errors).
- Shared `friendlyError(e)` mapper + `ErrorRetryView`; replace raw `'$e'` snackbars (schedule_screen.dart:41,
  subagent_screen.dart:113, plugins_screen.dart:1299, studio_screen.dart:1209, shared_conversation_screen.dart:73 …).
- Account deletion must be enabled in release (`OVID_ACCOUNT_ENABLED`, account_service.dart:58) — Play policy.
P1:
- Contrast: darken light-mode faint text (theme.dart:49) to ≥4.5:1; primary-button red ≥4.5:1; min font 11–12.
- 48dp message action targets (chat_screen.dart:4659); Semantics for messages + live-region on stream end.
- Model errors as error card with Retry (agent_service.dart:11122); `RefreshIndicator` on Usage/Billing/Plugins/Sync.
- Shared-conversation screen: markdown, role styling, lazy list, retry.
- Telemetry consent: single-show guard, non-dismissible until answered (shell.dart:101).
- Hide dev-only Collaboration/Private-sync internals behind "Advanced"; fix copy (settings_screen.dart:371) and unify brand name.
- Offline banner in chat; `ErrorWidget.builder` for release.
Features: full-text chat search (wire existing `session_search.dart` FTS into sidebar), share button in
chat header (use unused `ChatShareButton`), Android `ACTION_SEND` share-to-Ovid, camera capture in attach
sheet, haptics, code syntax highlighting, LaTeX, pin/archive chats, Today/Yesterday grouping, starter prompts,
TTS read-aloud. Remove dead code (`HealthScreen`, unused `chat_layout.dart` redesign widgets, shell drawer).

## Execution order / PRs
1. PR-1 (P0 bug): Phase 1A + server tests; VPS session applies 1B. Ship first.
2. PR-2 perf core: Phase 4 items 1-2, 4-5.  3. PR-3 SQLite history migration (Phase 4.3).
4. PR-4 MCP/plugin parity items 1-3 + usage tracking (Phase 2.1-2.3, 2.8).  5. PR-5 security H1/H2/M1-M5.
6. PR-6 UX P0/P1 + l10n scaffold.  7. PR-7 remaining parity (OAuth discovery, plugin format) + features.
Each PR stays on its own branch off `hoplite/gortyn-77773150`.

## Verification
- Server: `pytest server/images/tests` (new verifier tests); on VPS: `curl -H "Authorization: Bearer <user key>"
  https://api.ovidsi.com/v1/models` → 200 with `auto` + manual models; missing token → 401 not 503.
- App: `flutter analyze`, `python tool/run_flutter_suite.py`; new widget tests: picker shows `auto` +
  cached models when catalog fails, re-mint after catalog 401; hook tests for PostToolUse block +
  tool_input aliasing; MCP tests for `ping`/`roots/list`/elicitation responses; usage-store rollup tests;
  SQLite migration test from SharedPreferences fixture.
- Perf: profile-mode build on low-end Android, stream a 4k-token answer — target no frames >16ms in
  chat bubble, rebuild count of `ChatScreen` ≈ 0 during stream (debug rebuild counter test).
- CI: GitHub Actions `Validate and Build Android` green on each PR.


