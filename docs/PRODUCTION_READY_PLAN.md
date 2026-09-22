# Production-Ready Plan: Queued Behaviour & Plugin Lifecycle

## 1. Executive Summary & Root Cause Analysis

### Queued Behaviour Bugs & Vulnerabilities
1. **Index-ID Desynchronization in `steerQueuedMessage`**:
   - `steerQueuedMessage(int index)` rotated `_queue`, but only ran `_syncQueueIds` which appended IDs at the end without updating existing ordering.
   - Consequently, IDs became misaligned with the array indices. Any subsequent mutation by ID (`removeQueuedMessageById`, `editQueuedMessageById`) modified or deleted the wrong queued item.
   - **Fix Applied**: `steerQueuedMessage` now correctly rotates both `run.queue` and `run.queueIds` synchronously in `lib/core/agent_service.dart`.

2. **Cross-Session Queue Bleed in Composer**:
   - `enqueueMessage(text)` previously operated strictly on `_runResolved` (the active UI session), ignoring background sessions or child tasks.
   - When users switched chats or worked in subagents, prompts enqueued to the wrong session bucket.
   - **Fix Applied**: Added `sessionId` parameter to `AgentService.I.enqueueMessage(text, {String? sessionId})` and wired `chat_screen.dart` to pass `s.id`.

### Superpowers Plugin Hook Auto-Run Root Cause & Fix
Superpowers plugin ka **automatic hook** (`session-start`) auto-run hone mein do critical gaps the:

1. **Missing / Unexpanded `CLAUDE_PLUGIN_ROOT` in Execution Payload**:
   - **Condition**: Script (`run-hook.cmd session-start` ya extensionless sibling `run-hook`) manual run karne par 100% working thi (Exit Code: 0, valid JSON `hookSpecificOutput.additionalContext`).
   - **Root Cause**: Plugin manifest command string mein `${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.cmd` declare karta hai. Jab Ovid hook command ko shell (`bash -c`) mein pass karta tha, tab agar executable path parameter level par proactively expand na ho, toh literal `$CLAUDE_PLUGIN_ROOT` ya unresolved path ki wajah se command fail-open ho kar silently skip ho jaati thi.
   - **Fix Applied**: `lib/core/hook_service.dart` ke `_exec` mein `resolveHookPayload(hook)` ke baad `expandPluginRoot(command, root)` proactively execute karwaya gaya hai. Isse entrypoint exact resolved absolute disk path ke sath dispatch hota hai aur environment variable map (`CLAUDE_PLUGIN_ROOT: root`) properly subprocess ko supply hota hai.

2. **Hook Execution Lifecycle & Dispatcher Context Injection**:
   - **Root Cause**: Ovid ke session lifecycle engine (`SessionLifecycleService.I.sessionStarted`) mein session start trigger hota tha, lekin `sessionContextFor(sessionId)` se aane wala output model request pipeline mein properly inject aur hold hona ensure hona zaroori tha.
   - **Fix & Verification**: `HookService.I.fire('session_start', sessionId)` ab session context extract karke `_sessionContexts[sessionId]` mein cache karta hai aur `agent_service.dart` line 7544 par LLM request ke front mein standing context inject karta hai.

---

## 2. Multi-Phase Production Roadmap

### Phase 1: Queue Core Correctness (Completed in Codebase)
- [x] Correct index & ID alignment in `steerQueuedMessage`.
- [x] Add explicit `sessionId` routing to `enqueueMessage`.
- [x] Protect against cross-session queue pollution in UI send actions.

### Phase 2: Session-Start Hook Hardening (Completed in Codebase)
- [x] Proactively expand `${CLAUDE_PLUGIN_ROOT}` and related tokens in hook entrypoints (`hook_service.dart`).
- [x] Pass complete runtime environment (`CLAUDE_PLUGIN_ROOT`, `PLUGIN_ROOT`, `PLUGIN_SESSION`, `PLUGIN_WORKSPACE`) to subprocess execution.
- [x] Ensure `session_start` output standing context is available for LLM inference requests.

### Phase 3: Durability & Persistence (Next Steps)
- [ ] Serialize `AgentRun.queue` into persistent storage (`session_ledger` / `SharedPreferences`).
- [ ] Hydrate pending queues across Android app restarts and process reclaims.

### Phase 4: UI/UX Refinement
- [ ] Add undo action or confirmation dialog on "Clear all" queued messages.
- [ ] Support drag-and-drop reordering for queue rows in `_QueueDock`.

### Phase 5: Session Isolation & Restart Sharing (Completed in Codebase)
Full design + risk register: `docs/superpowers/plans/2026-09-22-session-isolation-and-queue.md`.

The contract: **a session is an isolated world while the app runs** (own sandbox
workspace, own Studio repo/branch/open files, own browser tabs *and* own cookie
jar), and **once per app restart the accumulated DATA is merged** so repos and
logins are available everywhere; then the sessions diverge again. Sharing moves
**data only** — logins (cookies) and the Studio repo/branch. Tabs, open pages,
the active tab, open Studio files/buffers and the recorded visit history are
never carried into another session (pinned by a source-contract test).

- [x] Native `OvidBrowserProfiles` (AndroidX WebKit multi-profile) + six
      `ovid/webview` channel methods; every call degrades to a no-op when the
      WebView has no profile support.
- [x] `BrowserProfileId` — deterministic, provider-safe profile name per session
      id, so isolation survives a restart with no bookkeeping.
- [x] `CookieMerge` — pure, unit-tested cookie-header arithmetic (a jar cannot be
      enumerated, so the merge replays recorded origins).
- [x] `SessionBrowserProfiles` + `SessionDataSharing` services.
- [x] Bind-before-load ordering: `setProfile` must precede *any* navigation or
      JavaScript evaluation, so the profile bind, UA, viewport and load are
      sequenced in one awaited helper, with stale-controller re-checks.
- [x] `navigateTab` as the single navigation entry point (browser UI, agent
      tools, dev-server tabs); exactly two raw loads remain, both guarded.
- [x] Per-session Studio binding rebind (`refreshStudioBindingForActiveSession`)
      and restart backfill of `(repo, branch)` into sessions that have none.
- [x] Session-scoped Stop: the composer red button calls
      `stopRequested(sessionId:)`, never `hardStopAll()`.
- [x] Settings: *Share browser logins on restart* / *Share Studio repo on
      restart* (both default ON) + *Share session data now*; *Clear cookies*
      clears every session profile.
- [x] Deleting a session deletes its browser profile (cookies + web storage),
      plus its tab prefs and visit record; a delete the platform refuses (a live
      WebView still holds the profile) is queued and retried at the next launch.
- [x] Native hardening: `bindProfile` replies a plain bool; `deleteProfile` is
      not preceded by `getProfile`; `clearCookies` with no origins really wipes
      the jar; the cookie merge writes ONE cookie per `setCookie` call.
- [x] Visit records are per session (`ovid_browser_cookie_origins_<id>`); only
      the merge/clear paths union them, so no chat can read another's visits.
- [x] Startup task `session.shareOnRestart`, ordered after session restore and
      GitHub token restore.
- [x] System prompt states the isolation model so the agent cannot claim a login
      that lives in another chat.
- [x] `test/session_browser_profiles_test.dart` (logic + source contracts).

### Phase 6: Queue Durability & Isolation (next)
- [ ] Persist `AgentRun.queue` (+ `queueIds`) so a process reclaim does not lose
      queued prompts; hydrate per session on restore.
- [ ] Surface per-session queue length in the sidebar so a background chat's
      pending work is visible.
- [ ] Queue steering parity check against DSH for the "steer to front" gesture.
