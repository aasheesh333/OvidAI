# PLAN_FIXES.md — User-Reported Fixes + Real-Linux Sandbox (PR22–PR28)

> Tracking file for the fix batch reported on-device. Update the STATUS
> column after every PR. Verification gate per PR:
> `flutter analyze` (0 issues) + `flutter test` (all green) + commit +
> push + CI green (Build APK + Device Test) on
> `ci/verified-android-build-20260827`.
> Baseline at start: 169 tests, commit `bdb0bbe` (PR21).

---

## Legend

- **DONE** — merged, CI green
- **WIP** — in progress
- **NEXT** — next up
- **—** — not started

---

## WS1 — Sandbox: "100% real Linux, all DSH shell commands" (PR22)

**User report (verbatim errors):**
```
npx/npm: /data/user/0/.../files/sandbox/usr/bin/env: bad interpreter
library "libz.so.1" not found
OpenSSL config error: fopen(/data/data/com.termux/files/usr/etc/tls/openssl.cnf)
sh: 1: node-gyp: Permission denied
EACCES: mkdtemp '/data/data/com.termux/files/usr/tmp/dsh-spill-XXXXXX'
npm EACCES: cache /data/data/com.termux/files/home/.npm/_cacache/tmp
```

**Root causes (researched, file:line evidence):**

| # | Cause | Evidence |
|---|---|---|
| 1 | `_patchExtractedShebangs` sed replaces `/data/data/com.termux/files` → `$PREFIX` but Termux scripts use `.../files/usr/bin/env` — prefix has NO `usr/` dir → `$PREFIX/usr/bin/env` never exists | `sandbox_service.dart:1164`; correct rewrites elsewhere: symlinks `:314-318`, deb copy `:1116` |
| 2 | Pre-`2f23a57` symlink Map bug lost 957/1177 symlinks (libz.so.1, env targets); `checkExisting()` never re-creates lost symlinks/exec bits | `sandbox_service.dart:211-239`, `:652-666` |
| 3 | `OPENSSL_CONF`/`npm_config_cache`/`TMPDIR`/`HOME` only injected via `_sandboxEnv` since `9278023`; **non-studio `job_start` spawns `/system/bin/sh` with NO env** | `agent_service.dart:7924-7928`; env map `sandbox_service.dart:1344-1394` |
| 4 | Exec bits only enforced on `bin/`, `lib/apt/methods`, `libexec`; nested `.bin` scripts (node-gyp) never chmod'd; shebang patch only chmods `$PREFIX/bin/*` | `sandbox_service.dart:1284-1294`, `:1166` |
| 5 | LD_PRELOAD termux-exec shim SELinux-blocked on many devices (documented) — compiled-in Termux paths surface without env overrides | `sandbox_service.dart:770-775` |

**Plan items:**

| ID | Item | Files | STATUS |
|---|---|---|---|
| S1 | Fix shebang sed: replace `/data/data/com.termux/files/usr/` → `$PREFIX/` (with `/usr` drop), fallback plain-prefix replace | `sandbox_service.dart` `_patchExtractedShebangs` | DONE |
| S2 | `$PREFIX/usr/bin` compat: create `$PREFIX/usr` symlink → `.` (so `sandbox/usr/bin/env` resolves) at install + self-heal | `sandbox_service.dart` install + `checkExisting` | DONE |
| S3 | Self-heal `checkExisting()`: re-run symlink creation pass + exec-bit chmod + shebang re-patch (idempotent repair for stale installs) | `sandbox_service.dart:211-239` | DONE |
| S4 | Exec bits: `_patchExtractedShebangs` chmod `-R +x` on `$PREFIX/lib/node_modules/.bin` + all nested `.bin` dirs; `_chmodTree` add `home/.npm`? (no — cache) | `sandbox_service.dart:1152-1168` | DONE |
| S5 | `job_start` non-studio: route through `SandboxService.I.shell/exec` (env-carrying) when sandbox installed; keep phone-terminal fallback only when NOT installed | `agent_service.dart:7915-7928` | DONE |
| S6 | `_sandboxEnv` harden: always set `OPENSSL_CONF` (create openssl.cnf if missing via `_ensureTlsConfig`), `TMPDIR`/`HOME`/`npm_config_cache`/`npm_config_tmp` unconditionally | `sandbox_service.dart:1344-1394` | DONE |
| S7 | Ensure `zlib` present: add `zlib` to apt pkg list + deb closure (Termux name `zlib`, NOT `zlib1g`) | `sandbox_service.dart:424` | DONE |
| S8 | Doctor surface: health check probe `env` resolution (`$PREFIX/bin/env` + `usr/bin/env`), `libz.so.1` link, `node -e` smoke; report + repair action | `health_service.dart` + `sandbox_service.dart` | DONE |
| S9 | Tests: unit tests for shebang rewrite mapping + `usr` compat path resolution (pure-Dart, temp dirs) | `test/core_regression_test.dart` | DONE |

**Target:** every DSH-web shell workload (npx, npm i, node-gyp builds,
openssl, mkdtemp, npm cache) runs inside the sandbox like real Linux.

---

## WS2 — @ mention fixes + queue model snapshot (PR23)

**User report:** "@ karne se kuchh bhi nhi ho rha" (typing @ does nothing)

**Root causes:**
1. Empty-suggestion gate: all 3 groups empty on fresh app (no files —
   workspace dir not created until first run; no other sessions; no
   subagents) → menu not rendered at all (`chat_screen.dart:3827`
   `suggestions.isNotEmpty`).
2. Directory descent broken: `@src/` insert keeps query `name/` but
   listing is non-recursive root-only + fuzzy requires `/` in candidate
   basename → matches nothing → menu dies mid-interaction
   (`chat_screen.dart:3484-3510`, `_fuzzyScore :3339`).
3. Queued messages bypass `expandReferences` (drain paths call runTask
   without `expandRefsFor` — `agent_service.dart:4222/4226`, mid-run
   drain `:3218-3238` injects raw).
4. Path traversal: mention regex `@([\w./:-]+)` allows `@../../secrets`
   reads (`agent_service.dart:1443`).

**Plan items:**

| ID | Item | Files | STATUS |
|---|---|---|---|
| M1 | Workspace warm-up: create session workspace dir at session creation (via `SandboxService.workDirFor`) so Files group is never empty; also on app start for active session | `state.dart` `newSession`/`_ensureActiveSession` or `agent_service.dart` init | — |
| M2 | Menu UX: when ALL groups empty → show a single hint row ("no files yet — agent work creates them; @session:<id> to cite chats") instead of nothing | `chat_screen.dart:3827` gate + `_mentionSuggestions` | — |
| M3 | Directory descent: track query segments; if query contains `/`, list that subdir (depth ≤3); fuzzy match on last segment; breadcrumb insert | `chat_screen.dart:3484-3510` | — |
| M4 | Mention state guard: include `_mentionStart` in change-guard (`:3568-3571`) | `chat_screen.dart` | — |
| M5 | Traversal guard: resolve mentions against workspace root, reject `..` escapes (both expand + suggestions) | `agent_service.dart:1442-1486` | — |
| M6 | Queued expansion: on drain (both paths), expand `@` refs for the running session before injecting | `agent_service.dart:3218-3238`, `:4222` | — |
| M7 | Boundary rule soften: also open menu when `@` follows `(`, `[`, `,`, `>` (common chat contexts) — keep word-char boundary | `chat_screen.dart:3560` | — |
| M8 | Tests: M3 descent listing, M5 traversal rejection, M6 queued expansion | `test/core_regression_test.dart` | — |

**Model snapshot (user ask):** "jab user model select kare aur request
bheje, response usi model se aaye jab tak next queue msg" — i.e. the
SELECTED MODEL must stick for the whole queued run.

**Current behavior (researched):** `_callLlmOnce` reads `session.model`
LIVE per request (`agent_service.dart:4421`) — a mid-run picker switch
changes the model of the NEXT request within the same run. Provider
resolved once at run start (`:3627`).

**Plan:**

| ID | Item | Files | STATUS |
|---|---|---|---|
| Q1 | Snapshot model at RUN START: capture `s.model` into the run bucket `_AgentRun` and use it for every `_callLlm` of that run (DSH prompt-assembly-boundary parity) | `agent_service.dart` `_AgentRun` + `_callLlmOnce` | — |
| Q2 | A NEW queued-message run re-resolves (new runTask) → uses the newly selected model; mid-run queue drain (path 1) uses the RUN'S snapshot, not live session model | same | — |
| Q3 | Test: model switch mid-run does not affect in-flight run; new queued run picks new model | `test` | — |

---

## WS3 — Plugin hooks system (PR24)

**User report:** "installed plugins jo har request pe trigger hote h like
hook wo bhi kaam nhi kr rha" — hook-style plugins don't fire.

**DSH reference (researched):** DSH hooks are Cordis event listeners
(`agent/pre-step`, `tools/pre-execute|execute|post-execute`, `llm/stream`,
`system-prompt/assemble`, `session/event`, `hook/invoked|result` session
events…). Ovid has NO hook field on `PluginItem` at all.

**Plan:**

| ID | Item | Files | STATUS |
|---|---|---|---|
| H1 | `PluginItem.hooks` field: `Map<String, String>` event → shell command (declared in plugin manifest `hooks: {on_request: "...", on_turn_start: "..."}`) | `state.dart` `PluginItem` + `_persistCustomPlugins`/`_persistPluginState` | — |
| H2 | Marketplace parse: read `hooks` map from plugin entries in `_mergeMarketplaceCatalog` | `state.dart:1724-1807` | — |
| H3 | HookService (new `lib/core/hook_service.dart`): fire(event, payload) → for each installed+enabled plugin with hooks[event], run its shell command via sandbox with env `OVID_HOOK_EVENT`, `OVID_HOOK_PAYLOAD` (JSON, 8KB cap), timeout 30s, capture stdout; failures logged to tool detail, never break the run | new file | — |
| H4 | Wire events: `turn_start`, `turn_end`, `pre_request` (inject stdout as system note ≤2KB), `post_tool` (append context), `session_start` | `agent_service.dart` `_runTaskBody` + `_dispatch` + session load | — |
| H5 | Ledger: `hook/invoked` + `hook/result` records in SessionLedger (DSH session-event parity) | `session_ledger.dart` + hook service | — |
| H6 | Plugins screen: show hook chips on plugin card (event names) | `plugins_screen.dart` | — |
| H7 | Settings toggle: master `hooksEnabled` (default ON) to kill-switch all hook execution | `state.dart` + `settings_screen.dart` | — |
| H8 | Tests: parse hooks from manifest; HookService fires command (fake shell via test seam); kill-switch blocks; ledger records | `test` | — |

---

## WS4 — File-edit visibility (DSH diff UX) (PR25)

**User report:** "jab ai live edit ya files create karti h to user ko
pata nahi chalta kya hua — DSH web jaisa karo"

**DSH reference:** write/edit derive replayable DIFF-CARD metadata; chat
rows show 8 diff-body lines before collapsing; details panel keeps full
diff; turn-end produced-files row (up to 6 chips + "+N files"); inline
clickable file paths.

**Plan:**

| ID | Item | Files | STATUS |
|---|---|---|---|
| D1 | Capture BEFORE content in `_writeWorkspaceFile` + `_handleFsEdit` (create/str_replace/insert): read old content pre-write, build unified-ish diff (+/- lines, cap 400 lines), attach to tool card `toolDetail` with `kind: 'edit'` | `agent_service.dart:1496-1516`, `:6316-6482` | — |
| D2 | Diff render already exists (`_DiffLine :2325-2356`) — feed it real diffs via toolDetail starting with `diff:` marker or structured `Message.toolDiff` field | `state.dart` Message + `chat_screen.dart` `_DetailBody` | — |
| D3 | Diff header: file path (tildified) + `+N/−M` line counts chip | `chat_screen.dart` `_ToolCard` collapsed row | — |
| D4 | Produced-files row (turn end): collect successful create/edit/str_replace/insert paths from `_runResolved.produced` (exists), render chips above turn tail, tap → Studio open | `agent_service.dart` turn-end + `chat_screen.dart` widget | — |
| D5 | Full-screen diff viewer: push page (pattern: `SubagentScreen.open`) with before/after panes + copy | new widget in `chat_screen.dart` | — |
| D6 | Tests: D1 diff builder (+ insert in middle, replace, create), D4 row data | `test` | — |

---

## WS5 — Compaction parity (PR26)

**User report:** "compaction bhi dsh web ki tarah kaam nahi kar rha"

**DSH reference:** threshold 0.8 / retain 0.16 (Ovid has this ✓);
checkpoint as user-role message with `<compacted-summary>` tags + fixed
8-section structure (Ovid: system note — OK but see D2); manual /compact
busy-guards; serialized lock; UI: collapsed checkpoint row + replaced
counts (Ovid has `_CompactionRow` ✓).

**Gaps found:**

| # | Gap | Evidence |
|---|---|---|
| 1 | Overflow-recovery rebuild does NOT re-inject `compactedSummary` system message (only sys + replay) | `agent_service.dart:3876-3879` vs `:3800-3809` |
| 2 | `measuredContextTokens` heuristic sums ALL messages ignoring `compactedAtCount` → after compaction the ring/meter can still show high pressure until next bill | `agent_service.dart:3317-3328` |
| 3 | No compaction lock — concurrent runs (parent + child, or workflow fan-out) can interleave compact/summarize on the same session | `_maybeCompact`/`forceCompact` |
| 4 | Summary framing differs from DSH checkpoint structure (fine, but make it a `<compacted-summary>` tagged block + 8-section template: objective/status/decisions/files/tasks/learnings/next steps/context notes) | `:3443-3459` |

**Plan:**

| ID | Item | Files | STATUS |
|---|---|---|---|
| C1 | Overflow rebuild: include compactedSummary system message (same as initial assembly) | `agent_service.dart:3876-3879` | — |
| C2 | Heuristic path: skip messages below `compactedAtCount`; add tool tokens replay estimate | `agent_service.dart:3317-3328` | — |
| C3 | Compaction lock: per-session `bool _compacting` guard; second caller no-ops | `_maybeCompact`/`forceCompact` | — |
| C4 | Summary template: 8-section DSH checkpoint inside `<compacted-summary>` tags | `:3443-3459` | — |
| C5 | /compact busy-guard: refuse when run active (DSH error codes busy|changed) | `commands.dart:127-139` | — |
| C6 | Tests: C1 (rebuild includes summary), C2 (post-compaction measurement drops), C3 (lock prevents double), C5 | `test` | — |

---

## WS6 — Header + browser mode + browser control (PR27–PR28)

### PR27 — Header cleanup + browser mode toggle

**User asks:** hide subagents icon + trajectory icon from header; make a
Settings toggle to switch browser mode mobile↔desktop permanently
(default MOBILE).

**Facts:** header actions at `chat_screen.dart:804-918` (subagents
`:805-852`, jobs `:853-901`, trajectory `:902-912`, studio `:913-918`);
screens stay reachable: subagents via `subagent_screen.dart:233` (already
has catalog button) + turn-strip open `:2143`; trajectory — need alt
entry (move to sidebar footer or overflow menu); no browser mode setting
exists; `BrowserTab.zoom` + devW/devH statics exist
(`agent_service.dart:35-44`), controller created at `:1152` — webview_flutter
4.8 has no UA setter on controller, but desktop mode can be emulated via
UA-less approach: zoom-based layout (existing `browser_resize` JS) +
`useWideViewPort`? (not exposed) → emulate by UA override not available in
webview_flutter — use zoom + viewport meta + desktop UA via JS
`navigator.userAgent` is read-only... → **desktop mode = zoom approach +
user-agent switch requires platform channel — keep it zoom-based
(logical viewport) and document**. WebView UA: webview_flutter 4.8
`WebViewController` has no setUserAgent — platform_interface does not
expose it. So: mobile(default)/desktop = logical viewport toggle
(zoom 1.0 vs e.g. 1280px logical width) applied to all new tabs +
agent `browser_resize` continues to work.

| ID | Item | Files | STATUS |
|---|---|---|---|
| B1 | Remove subagents + trajectory icons from AppBar actions (jobs badge stays) | `chat_screen.dart:804-918` | — |
| B2 | Trajectory alt entry: add to sidebar footer (before Settings) or chat overflow menu | `sidebar.dart` / `chat_screen.dart` | — |
| B3 | `AppState.browserDesktopMode` (default false = mobile) + `setBrowserDesktopMode` persisted pref | `state.dart` | — |
| B4 | Settings toggle: "Browser default mode — Mobile/Desktop" SwitchListTile in a Browser section | `settings_screen.dart` | — |
| B5 | Apply on controller creation: desktop → zoom = devW/1280 logical viewport (JS zoom), mobile → 1.0; apply to NEW tabs at creation + a note in agent system prompt ("browser default viewport is mobile|desktop") | `agent_service.dart:1219-1229` + system prompt | — |
| B6 | Tests: pref roundtrip + zoom default applied on new tab | `test` | — |

### PR28 — Browser: human-like control + missing tools

**User report:** "browser control is not like a real person — many tools
or features are not for the AI agent to control browser".

**Current tools (14):** navigate, click, evaluate, resize, read, scroll,
type, press_key, wait_for, snapshot, new_tab, switch_tab, list_tabs,
close_tab (+ legacy browser_open). **Missing vs a real-user toolset:**
hover, drag, select/dropdown, form fill (one call), back/forward/reload,
find-in-page, file upload, dialogs (alert/confirm), cookies/storage,
screenshot, console logs, network requests, fullscreen, print, geolocation
spoof.

webview_flutter 4.8 constraints (researched): no screenshot API, no
download delegate exposure, no dialog handler exposure (JS alerts auto-
dismiss silently?), no file-upload chooser bridging, no network
inspection. Available: `runJavaScript*`, `loadRequest`, `goBack/
goForward/reload` (WebViewController methods exist), `runJavaScriptReturningResult`.

| ID | Item | Files | STATUS |
|---|---|---|---|
| W1 | `browser_back`, `browser_forward`, `browser_reload` (controller methods) | `agent_service.dart` schemas + cases | — |
| W2 | `browser_hover(selector)` — JS dispatchEvent mouseover/mouseenter | schemas + `_handleBrowser*` | — |
| W3 | `browser_drag(from,to)` — JS pointer events sequence (pointerdown/move/up) | same | — |
| W4 | `browser_select(selector, value)` — JS set value + change event | same | — |
| W5 | `browser_fill(fields: {selector: value})` — multi-field one call (form parity) | same | — |
| W6 | `browser_find(text)` — JS window.find fallback + count via body text scan | same | — |
| W7 | `browser_console` — JS override console.log capture buffer (inject at page start via `addScriptToExecuteOnDocumentCreated` equivalent — webview_flutter: `runJavaScript` at navigate + onNavigationRequest hook to re-inject) + return last N lines | same + controllerForTab | — |
| W8 | `browser_cookies` — JS document.cookie read/`(set)` (cookie header via JS) | same | — |
| W9 | `browser_screenshot` — best effort: JS DOM-to-text outline (headings/links/buttons table) as "visual outline" (real pixel capture not exposed by webview_flutter 4.8; document limitation in tool description) | same | — |
| W10 | Human-like waits: click/type auto scroll-into-view + 150-400ms randomized delay + visibility check before click (report "element not visible" instead of blind dispatch) | `_handleBrowserClick/Type` | — |
| W11 | System prompt: browser tool guidance block (prefer read/snapshot → locate → act; verify after) | `agent_service.dart` sys prompt | — |
| W12 | Tests: W1 (controller method routing via fake), W2-W8 JS builders (string contains), W10 (not-visible path) | `test` | — |

**Explicitly deferred (platform API missing):** pixel screenshots,
download delegate, file chooser bridging, network request inspection,
print, fullscreen, geolocation spoof. To be revisited if the plugin
upgrades webview_flutter or a platform channel is added.

---

## Order of execution

1. **PR22 (WS1)** — sandbox fixes are the foundation for hooks (H3 runs
   shell) and DSH-parity shell work. Highest priority.
2. **PR23 (WS2)** — @ mentions + queue model snapshot.
3. **PR24 (WS3)** — plugin hooks (depends on S-items for reliable shell).
4. **PR25 (WS4)** — diff cards.
5. **PR26 (WS5)** — compaction parity.
6. **PR27 (WS6a)** — header + browser mode toggle (small, user-visible).
7. **PR28 (WS6b)** — browser control expansion.

## Progress log

- 2026-09-02: file created from research (5 subagent reports + direct
  verification). PR22–PR28 pending.
- 2026-09-02 PR22 DONE (code+tests, CI pending): S1 shebang rewrite
  (`files/usr/` → prefix, usr dropped; fallback plain), S2 `$PREFIX/usr`
  self-symlink at install, S3 `_selfHealSandbox` + public `selfHealNow`
  wired into `checkExisting` + Health `repair()` (usr link + libz/etc
  so-links + shebang re-patch + exec bits), S4 `.bin`/`*.sh` chmod in
  `_patchExtractedShebangs`, S5 `job_start` routes through sandbox spawn
  in EVERY mode when installed, S6 `_sandboxEnv` ensures tmp/cache dirs
  exist + `npm_config_tmp` added, S7 `zlib` in apt pkg list, S8 health
  probes (npx shebang chain, node libz smoke, TMPDIR/mkdtemp), S9 5
  tests. Tests 169 → 174.
