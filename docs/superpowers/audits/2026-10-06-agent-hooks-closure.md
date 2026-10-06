# Agent hooks closure — can the tool-capable evaluator be safely wired?

Date: 2026-10-06
Owner files: `lib/core/hook_service.dart`, `lib/core/plugin_adapters.dart`,
`test/wave2_hooks_agent_test.dart`, `test/parallel_hooks_contract_test.dart`
Evidence read (not modified): `lib/core/agent_service.dart`,
`lib/core/native_plugin.dart`, `lib/core/native_plugins/utility_cancellation_bridge.dart`,
`lib/core/mcp_service.dart`, `lib/core/sandbox_service.dart`,
`lib/core/device_control_service.dart`, `lib/ui/chat_screen.dart`

## Verdict

**NO — a safe production wiring is not possible today.** `HookService.agentHookEvaluator`
stays `null` in production and agent-type hooks continue to fail open with an
honest ledger note (`hook_service.dart:2147-2153`). No stub was added. The exact
architecture change required is specified in §4.

The three named blockers are all still present and each independently makes a
bounded, cancellable, non-publishing wiring impossible. The evaluation contract
already defines the bounds it needs (`budget`, `cancelled`, `approvedTools`), so
wiring any current code path would violate that contract rather than fulfil it.

## 1. What is wired today

- The adapter accepts `type: agent` hooks and records an optional compatibility
  issue, so the declaration is visible but inert (`plugin_adapters.dart:409-415`).
- `HookService` evaluates agent hooks only through an injected
  `AgentHookEvaluator` (`hook_service.dart:87-88`, field at `:347-356`). Null →
  fail-open ledger note (`:2147-2153`). It never falls back to the prompt-only
  evaluator (`:352-355`).
- The evaluation contract already supplies bounds and a fence:
  `AgentHookEvaluation.budget` (`:2166-2168`), `approvedTools` parsed and
  allow-listed (`:2155-2164`), `cancelled` from `_beginAgentEval`
  (`:734-738`, `:2165`, `:2182`), and late-result drop via
  `Future.any` (`:2184-2192`). Fencing is driven by registry change, disable,
  session generation and budget expiry (`:422-463`, `:745-756`).
- `AgentService` wires only prompt hooks (`agent_service.dart:932-939`) and the
  user-stop checker (`:943-944`). There is **no** production assignment of
  `agentHookEvaluator` anywhere in `lib/`; this is pinned by the new
  wiring-pin test in `test/wave2_hooks_agent_test.dart`.

## 2. The three blockers (all still present)

### Blocker A — Detached approvals are unreachable

- Every tool goes through `_maybeApprove` (`agent_service.dart:13192`, `:16907`)
  which routes to `_askUser` (`:17356`).
- `_askUser` parks an `ApprovalRequest` on `_runResolved.pendingApproval`
  (`:17384`; getter `:1183-1200`). Outside a run Zone, `_runResolved` falls back
  to `_run`, keyed by the **active** session (`:1129-1131`, `:1157`).
- For a hook evaluation this is wrong or dead:
  - `SessionStart`/`Stop`/`Notification` hooks run outside the active run zone
    (or for a non-active session). The card is parked on the active session's
    bucket, or on the `''` bucket when no session is active — which no UI watches
    (`chat_screen.dart:7139` reads `AgentService.I.pendingApproval`).
  - `mode` (used by `_maybeApprove`/`_askUser`) also resolves to the active
    session's mode (`agent_service.dart:962-968`), so the wrong policy applies.
  - A detached/subagent-shaped run auto-approves (`running.isSubagent` → true,
    `:17036-17040`) or auto-denies after a 5s no-UI grace (`:17423-17441`) —
    silently, which is not an honest decision.
- There is no approval channel addressable to a specific evaluation. **Blocked.**

### Blocker B — Native/MCP calls lack per-evaluation cancellation

- The contract requires stopping promptly when `evaluation.cancelled` completes
  (`hook_service.dart:33-38`, `:82-88`).
- **LLM:** `_callLlm`/`_callLlmOnce` cancel via
  `_TransportOwner(_runResolved, epoch)` and the run-wide `_cancelRequested`
  (`agent_service.dart:12157-12226`) — run generation, not an evaluation token.
- **Native tools:** `NativePluginCapability.callTool(String, Map)` has no
  cancellation parameter (`native_plugin.dart:44`). The bridge that would add
  one is documented but explicitly not integrated, and its tokens are keyed by
  run key/session (`utility_cancellation_bridge.dart:8-23`, `:85-135`).
- **MCP:** `McpService.callTool` takes no cancellation token
  (`mcp_service.dart:2756`); only a per-call timeout (`:1964`).
- **Sandbox:** cancellation is `SandboxService.killRunProcesses(key)`, keyed by
  run key and killing the run's whole process set (`sandbox_service.dart:2674-2690`).
- **Device:** generation-based, bumped by a run Stop
  (`device_control_service.dart:136`).
- Net: a fence completing cannot abort in-flight tool work. **Blocked.**

### Blocker C — Dispatch publishes to session state

- `_dispatch` mutates the live run: `_runResolved.steps += 1` (`:13120`),
  `toolMs` (`:13286`), and appends session-ledger `tool_start`/`checkpoint`/
  `tool_end` entries (`:13123-13134`, `:13176-13185`, `:13219-13227`).
- It fires `pre_tool`/`post_tool` hooks for the session
  (`:13140-13213`, `:13230-13249`) and `_emit`s user-facing `think` text
  (e.g. `:17033`, `:17413-17416`). `_callLlm` also `_emit`s retry/recovery
  text (`:12195-12220`).
- There is no publication-free dispatch path. Running a hook's tools through
  `_dispatch` would inject ledger entries and chat events for internal
  evaluation work. **Blocked.**

## 3. Why a "narrow but safe" wiring does not exist

Restricting agent hooks to run-zone events (e.g. `pre_tool`) does not help: the
nested evaluation's tool calls would still (a) increment the parent run's
step/tool accounting, (b) write session-ledger entries, (c) be uncancellable
per-evaluation, and (d) re-enter `_maybeApprove`/`pre_tool` hooks recursively.
Dropping tool execution entirely would not be an agent hook and would
misrepresent agent semantics — explicitly forbidden (`hook_service.dart:352-355`).

## 4. Exact architecture change required

Land all four before wiring `HookService.agentHookEvaluator`.

1. **Per-evaluation cancellation token, threaded end to end.**
   - Extend `NativePluginCapability.callTool` with
     `{UtilityCancellation? cancellation}` (`native_plugin.dart:44`); every
     concrete capability already declares and forwards this parameter.
   - Give `McpService.callTool` (`mcp_service.dart:2756`) an optional token that
     aborts/closes the RPC stream.
   - Add an evaluation-scoped sandbox process key (e.g. `hook-eval:<evalId>`)
     and `killRunProcesses` it on fence, distinct from the session run key.
   - Thread the token into `_callLlm`/`_callLlmOnce` transport ownership so a
     fence aborts the HTTP stream, not just the run generation.
   - A controller-owned runner bridges `AgentHookEvaluation.cancelled` to all of
     the above.

2. **A detached, addressable approval channel.**
   - Decide what an agent hook's tool approval means: either (a) an explicit
     product decision that hook tools run under a fixed, non-interactive policy
     bounded by `approvedTools` and the plugin capability grant, or (b) an
     evaluation-addressed approval surface the UI can render independently of the
     active session, with policy resolved from the evaluation's session.
   - `_askUser`/`_maybeApprove` must accept an explicit session/policy owner and
     must never park on `_run` keyed to the wrong active session.

3. **A publication-free dispatch path.**
   - Extract the tool-execution core from `_dispatch` so an evaluation can run a
     tool with an isolated `AgentRun` bucket and no ledger
     `tool_start`/`tool_end`/`checkpoint`, no `_emit`, and no
     `pre_tool`/`post_tool` hook recursion — while still enforcing the same
     permission/read-only/plan/sandbox policy.
   - Evaluation tool activity belongs in the hook ledger HookService already
     writes, not the chat transcript.

4. **Bounded loop + honest failure.**
   - A controller-owned runner that builds tool schemas strictly from
     `approvedTools`, loops under `evaluation.budget`, checks
     `evaluation.cancelled` between every step and aborts in-flight work via (1),
     and returns `AgentHookVerdict` or null. It never touches the transcript.

## 5. What was NOT done

No `agentHookEvaluator` assignment was added; no stub. Production behavior is
unchanged. The only additions are this audit and a wiring-pin test that fails if
`AgentService` ever assigns the evaluator without the infrastructure above.

## 6. Verification

- `flutter test test/wave2_hooks_agent_test.dart test/parallel_hooks_contract_test.dart`
  → all passed (50 tests; +1 wiring pin over the 49 baseline).
- Scoped `dart analyze` on the owned files → no issues.
