# Partial closure status — all-store reset, utility cancellation, agent hooks

Date: 2026-10-06
Repo: `/root/OvidAI`
Branch: `hoplite/gortyn-77773150`
Committed anchor: `HEAD 130ea5d`
Working-tree snapshot: `2026-10-06T16:47:51Z` (18:47 CEST)
Method: read-only source inspection plus `git status` / `git diff HEAD`. No
source file was modified by this audit and no test was executed for this audit.
The working tree changed repeatedly *during* the audit (modified files grew from
9 to 21, untracked tests from 7 to 18, and `lib/core/hook_service.dart` was
rewritten twice while this doc was being written), so every working-tree claim
here is explicitly a point-in-time observation.

## Read this first: two states, one moving

This doc reports two distinct states and never merges them:

- **COMMITTED (`130ea5d`)** — stable, byte-verified.
- **WORKING TREE (uncommitted)** — a large, *actively changing* concurrent
  closure effort. During this inspection the modified-file set grew from 9 to 21
  (and untracked tests from 7 to 18) in roughly ten minutes. Every working-tree
  claim below is a point-in-time snapshot, not a final state. Re-run
  `git status` before relying on it.

Files central to the three items and their working-tree status at the snapshot:

| File | Working-tree status |
|---|---|
| `lib/core/settings_state_integration.dart` | unchanged vs HEAD (md5 `26bd6ca7…`) — reset wiring unchanged |
| `lib/core/agent_service.dart` | unchanged vs HEAD (md5 `2030f869…`) — agent wiring unchanged |
| `lib/core/reset_coordinator.dart` | unchanged vs HEAD (md5 `3e3bc0c9…`) |
| `lib/core/native_plugin.dart` | unchanged vs HEAD (md5 `0bc663d0…`) — cancellation interface unchanged |
| `lib/core/native_plugins/utility_cancellation_bridge.dart` | unchanged vs HEAD (md5 `343e26fa…`) |
| `lib/core/hook_service.dart` | **modified** (in progress) — adds `AgentHookEvaluation.isCancelled`; `agentHookEvaluator` still unassigned |

So the *integration seams* for all three items are still at HEAD; the
concurrent work is filling in the owner-level APIs and per-capability behavior
that those seams will need.

---

## (A) All-store reset readback

### Committed coordinator and wiring

- `lib/core/reset_coordinator.dart` — `ResetCoordinator` with a
  `prepare → commit → verifyDeleted` lifecycle; `success == verifiedComplete`
  only when every store's readback proves deletion (`reset_coordinator.dart:99-102`,
  `:236-245`). `ResetStoreKind` enumerates exactly seven stores (`:8-19`).
- `lib/core/settings_state_integration.dart:10` binds `reset: _resetAllData`;
  `_resetAllData` (`:34-178`) builds `ResetCoordinator.canonical` for all seven
  stores and runs it under `_withSettingsBarrier`.

### Per-store status at the coordinator wiring (COMMITTED)

| Store | `onDelete` | `onVerifyDeleted` | Readback status |
|---|---|---|---|
| `sessions` | deletes workspaces + prefs + in-memory/deferred state (`:55-74`) | prefs keys absent AND `sessions` empty AND no deferred snapshot AND `activeSessionId == null` (`:75-83`) | **implemented** |
| `memory` | `MemoryStore.deleteAll()` (`:119`) | `!root.existsSync()` (`:120-121`) | **implemented** |
| `account` | **no-op** (`:132`) | `!FirebaseService.I.isSignedIn` (`:133`) | readback present, **delete is a no-op** |
| `imageReceipts` | `ImageReceiptStore.redactAccount` (`:138-142`) | every row `receipt == null` (`:143-148`) | **implemented** (tombstones retained by design) |
| `search` | `SessionSearch.I.clear()` (`:88`) | **throws `UnsupportedError`** (`:89-94`) | **UNSUPPORTED** |
| `ledger` | `SessionLedger.I.delete(id)` per id (`:104-108`) | **throws `UnsupportedError`** (`:109-114`) | **UNSUPPORTED** |
| `shares` | **no-op** (`:153`) | **throws `UnsupportedError`** (`:154-160`) | **UNSUPPORTED** |

Two consequences that must not be glossed over:

1. Because `search`, `ledger` and `shares` `verifyDeleted` always throw,
   `ResetReport.verifiedComplete` (and therefore `SettingsResetResult.success`)
   is **always false** for the wired reset. The all-store reset cannot currently
   report success. `_resetAllData` then skips `_ensureActiveSession()` since
   `result.completed` never contains `sessions` (`:169`).
2. `account`'s `onDelete` is a documented no-op: `FirebaseService.I.signOut()`
   awaits `AppState.transitionSessionAccount`, which awaits the barrier that is
   calling it (deadlock), so a signed-in user's reset truthfully reports
   `account` as failed (`:123-134`).

### Owner-level readback APIs added in the WORKING TREE (uncommitted)

The owner APIs the three unsupported stores need now exist, but are **not yet
consumed** by the coordinator:

| Owner | New API (working tree) | Notes |
|---|---|---|
| `SessionSearch` | `storedRowCount()` `session_search.dart:113`; `isEmpty()` `:119` | real FTS row-count readback |
| `SessionLedger` | `storedSessionIds()` `session_ledger.dart:410`; `isEmpty()` `:429` | enumerates the ledger dir; digest names counted non-empty but unattributable |
| `SessionBrowserProfiles` | `profileCount()` `session_browser_profiles.dart:288`; `isEmpty()` `:294`; `deleteAll()` `:304` | readback throws when provider is down rather than lying empty |
| `ConversationShareService` | `localShareCount()` `conversation_share_service.dart:205`; `clearLocal()` `:210` | always `0` / documented no-op: server shares are a separate owner and are **not** deleted |
| `FirebaseService` | `signOutLocal()` `firebase_service.dart:438` | barrier-safe local sign-out intended to replace the `account` no-op |

`lib/core/settings_state_integration.dart` does **not** reference any of these
(`grep` for `storedRowCount|storedSessionIds|profileCount|deleteAll|localShareCount|clearLocal|signOutLocal`
finds none). The untracked tests `test/reset_search_readback_test.dart`,
`reset_ledger_readback_test.dart`, `reset_shares_readback_test.dart`,
`reset_browser_profiles_test.dart`, `reset_account_signout_test.dart` pin the
owner APIs only; none asserts the coordinator consumes them.

### (A) answer

- **Readback implemented at the coordinator (committed):** `sessions`, `memory`,
  `image-receipts`, and `account` (readback only — delete is a no-op).
- **Still reported unsupported at the coordinator:** `search`, `ledger`,
  `shares` (each `onVerifyDeleted` throws `UnsupportedError`).
- **Owner-level readback now exists for all three (uncommitted working tree),
  but is unwired**, so the coordinator's verdict is unchanged. Also unwired:
  `signOutLocal()`, which is why `account` still cannot be reset.
- The committed reset therefore still cannot report `success`.

---

## (B) Utility cancellation

### Committed baseline (`130ea5d`)

- Shared interface gained an optional token:
  `NativePluginCapability.callTool(..., {UtilityCancellation? cancellation})`
  (`native_plugin.dart:45-49`).
- `UtilityCancellationBridge` (`utility_cancellation_bridge.dart`) is wired:
  - `plugin__` dispatch opens/closes a token per run
    (`agent_service.dart:14168-14178`),
  - run Stop signals it in `_cancelBucket` (`agent_service.dart:2215`,
    next to `SandboxService.I.killRunProcesses`).
- **Honored by exactly 6 of 57 `callTool` overrides** — those that forward the
  token to `runBoundedUtility`/`boundedUtilityRequest`:
  `data_utilities.dart:140,1038`, `dev_utilities.dart:99,357`,
  `web_and_db_utilities.dart:286,1050`.
- The other **51 accept-and-ignore**: they declare the parameter but never read
  it (verified by `grep`: only those 6 sites pass `cancellation:` to a bounded
  helper).
- Stale comment: `utility_limits.dart:41-43` still claims "the shared
  NativePluginCapability interface currently has no cancellation parameter" —
  no longer true.

### WORKING TREE (uncommitted, in progress)

A concurrent effort is expanding coverage across many files. At the snapshot,
files with cancellation now actually used include:

| File | Honoring mechanism (working tree) |
|---|---|
| `data_utilities.dart` | `_throwIfCancelled` + `runBoundedUtility` + `whenCancelled` (all overrides) |
| `dev_utilities.dart` | `runBoundedUtility` / `_runPlatformUtility` (all overrides) |
| `web_and_db_utilities.dart` | `boundedUtilityRequest(cancellation:)` |
| `misc_utilities.dart` | `runBoundedUtility` / `boundedUtilityRequest` / `_throwIfCancelled` |
| `rest_engine.dart` | `RestApiCapability.callTool` now forwards to `boundedUtilityRequest` + post-response check |
| `rest_descriptors_infra.dart` | delegates `cap.callTool(..., cancellation:)` |
| `rest_descriptors_dev.dart` | delegates `delegate.callTool(..., cancellation:)` |
| `rest_descriptors_backend.dart` | delegates `... cancellation:` at some sites (partial) |
| `rest_descriptors_aimedia.dart` | only `StripeCapability` forwards (`:857`) |
| `sandbox_utilities.dart` | zone token + `_runCancellable` |
| `mcp_service.dart` | `McpService.callTool` accepts a token and returns a cancelled result |

Known **accept-and-ignore** at the snapshot:

- `prompt_framework.dart:23-32` — prompt tools only return a "call through the
  agent" message; the token is unused.
- `rest_descriptors_aimedia.dart` — `DalleCapability` (`:411`),
  `ElevenLabsCapability` (`:483`), `NotionSyncCapability` (`:571`),
  `GoogleDriveCapability` (`:702`), `YouTubeSummarizerCapability` (`:877`)
  declare the token but do not forward it.
- `rest_descriptors_backend.dart` — several of its 10 overrides still declare
  and ignore the token (only some delegate sites forward it).

Important wiring gap even in the working tree: **MCP cancellation is not wired
into the agent Stop path.** `McpService.callTool` gained a `cancellation`
parameter, but the `agent_service.dart` MCP call sites
(`:14035`, `:14119`, and the `mcp_` branch) pass only `timeout:`, never a token.
So a run Stop still cannot abort an in-flight MCP call through the bridge.

New untracked tests at the snapshot: `rest_cancellation_test.dart`,
`web_db_utilities_cancel_test.dart`, `dev_utilities_cancel_test.dart`,
`data_utilities_cancel_test.dart`, `mcp_eval_cancellation_test.dart`,
`rest_descriptors_aimedia_cancel_test.dart`,
`rest_descriptors_dev_cancel_test.dart`,
`rest_descriptors_infra_cancel_test.dart`. `test/_scratch_cancel_probe_test.dart`
is a debug scratch file (contains `print` probes) and is hygiene debt, not a
real test.

### (B) answer

- **Committed:** 6 overrides honor cancellation; 51 accept-and-ignore; bridge
  wired for the native `plugin__` path only.
- **Working tree (uncommitted, in progress):** most touched native utility /
  REST files now honor it; a full override-by-override tally is not stable
  because the tree is changing.
- **Still accept-and-ignore at the snapshot:** `prompt_framework.dart`, five of
  six `rest_descriptors_aimedia.dart` capabilities, and part of
  `rest_descriptors_backend.dart`.
- **Not wired regardless of file changes:** MCP cancellation (service supports
  it, agent dispatch never passes a token).

---

## (C) Agent-hooks tool-capable evaluator

### Status: STILL UNWIRED (production behavior unchanged)

- `HookService.agentHookEvaluator` is declared and defaults to `null`
  (`hook_service.dart:356` at HEAD; `:373` in the working tree); when null, agent
  hooks fail open with an honest ledger note (`hook_service.dart:2146-2153` at
  HEAD; `:2163` in the working tree).
- No production assignment exists anywhere in `lib/` (`grep` finds only the
  declaration and the fail-open read). `AgentService` assigns only
  `promptHookEvaluator` (`agent_service.dart:934`).
- The wiring pin `test/wave2_hooks_agent_test.dart:125-140` asserts
  `AgentService` does **not** contain `agentHookEvaluator =`. That pin is
  unchanged in the working tree (the concurrent diff only appends new tests
  about `e.isCancelled`, `wave2_hooks_agent_test.dart:290+`).
- Working-tree groundwork (uncommitted, still not a wiring): `hook_service.dart`
  now adds `AgentHookEvaluation.isCancelled` — a `Future<bool>` that resolves
  `true` only on a fence (plugin removed, hooks disabled, session end, budget
  expiry) and `false` on a normal verdict, so a future evaluator can bridge it
  into per-tool tokens without cancelling them after success. This is the
  contract half of Blocker B; no evaluator assignment accompanies it.

### Exact reason (committed audit, still authoritative)

`docs/superpowers/audits/2026-10-06-agent-hooks-closure.md` (tracked) gives
three blockers, all still present in the committed code:

- **Blocker A — detached approvals unreachable.** `_dispatch → _maybeApprove →
  _askUser` parks the request on the active session's bucket, which is wrong or
  dead for SessionStart/Stop/Notification evaluations
  (`agent_service.dart:13192`, `:16907`, `:17356`, `:17384`).
- **Blocker B — no per-evaluation cancellation.** The contract requires prompt
  stop on `evaluation.cancelled` (`hook_service.dart:33-38`, `:82-88`).
- **Blocker C — dispatch publishes to session state.** `_dispatch` mutates the
  live run, writes session-ledger entries, fires `pre_tool`/`post_tool` hooks
  and `_emit`s chat text (`agent_service.dart:13120`, `:13286`, `:13123-13134`,
  `:13140-13213`). No publication-free dispatch path exists.

### Nuance: Blocker B is now partially stale

The committed audit says `NativePluginCapability.callTool` "has no cancellation
parameter" and the bridge is "explicitly not integrated". Both statements are
now false: the parameter exists (`native_plugin.dart:45-49`) and the bridge is
wired for the native `plugin__` path (`agent_service.dart:14168-14178`,
`:2215`). The uncommitted working tree extends this to more native/REST
capabilities, gives `McpService.callTool` a token, and adds the explicit
`AgentHookEvaluation.isCancelled` fence signal (`hook_service.dart`).

That is **not** sufficient to wire the evaluator: there is still no
controller-owned runner that bridges `AgentHookEvaluation.cancelled` /
`isCancelled` into an in-flight evaluation, MCP is unwired from the agent Stop
path, several capabilities still ignore the token, and Blockers A and C are
untouched. The verdict in the closure audit — no safe production wiring today —
stands; only its Blocker-B wording needs refreshing.

### (C) answer

Unwired. `agentHookEvaluator` remains `null` in production; agent hooks
continue to fail open with a ledger note. Reason: detached approvals
(Blocker A) and publication-free dispatch (Blocker C) are still absent, and
per-evaluation cancellation (Blocker B) is only partially available even in the
uncommitted working tree.

---

## Bottom line

| Item | Committed `130ea5d` | Working tree (uncommitted, in progress) |
|---|---|---|
| (A) All-store reset readback | 4 stores wired (3 with real readback + account readback-only); `search`/`ledger`/`shares` throw `UnsupportedError`; reset can never report success | Owner readback APIs added for all three + `signOutLocal`; **not yet consumed** by `settings_state_integration.dart` |
| (B) Utility cancellation | 6/57 overrides honor; bridge wired for native `plugin__` only | Coverage being expanded across native + REST + MCP; MCP still not wired into agent Stop; some overrides still ignore |
| (C) Agent-hooks evaluator | Unwired, fail-open | Unwired (no assignment); `hook_service.dart` adds the `isCancelled` fence signal as Blocker-B groundwork; audit Blockers A/C stand, Blocker-B wording now partially stale |

No item is fully closed in the committed code. The working tree is closing
(A) and (B) at the owner level but has not yet updated the integration seams;
(C) is deliberately still unwired.
