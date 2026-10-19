# Recovery acceptance status

This is a coordination checklist, not release approval. The earlier emulator
smoke log does not verify subsequent branch changes. The emulator is currently
closed for resource headroom; the inference proxy is working and out of scope.

## Integrated recovery changes

- `24dd9b96`: corrected the App Check plan to the owner's current sideload
  decision and recorded the limits of smoke/capacity evidence.
- `2d95f30f`: reviewed Studio mutation synchronization for participating
  same-process write/move/delete/mkdir operations. Parent independently ran
  47 storage tests (22 database-dependent tests skipped) and 3 worker HTTP
  tests. No push or production deployment of this recovery commit yet.
- Studio's original agent-versus-editor race remains **partial**: raw sandbox,
  shell/MCP writes, other worker processes, and workspace lifecycle operations
  do not participate in this lock. Do not call it filesystem compare-and-swap.

## In-flight recovery and release blockers

| Area | Actual state | Before acceptance |
|---|---|---|
| Chat rich events/history | Integrated on main at `e1877491` (Wave 1b projection/history/cursors/drafts fencing + safe gating of destructive history actions). Parent independently reran the 13 gating assertions on the merged tree: 13 passed | Full Dart suite and emulator runtime reload/reconnect still pending |
| Destructive history actions | GATED server-side (typed 409 after ownership checks, before any write) and hidden in the cloud UI, with no-side-effect snapshot regressions. Ordinary send/outbox Retry/Discard retained | Real enablement requires the shared session-lock + atomic truncate/replacement/outbox design recorded in 06-contract-leftovers.md |
| Account-scoped drafts | Agent reproduced cross-account leakage and implemented owner fences | Review commits and independently verify cold/mounted account transitions |
| Memory isolation | Current shared-workspace namespaces cannot provide hard private-memory separation | New private DB repository/adapter, owner-checked session scope by default, explicit shared opt-in, Memory OFF disables tools; no workspace fallback |
| Legacy memory | Existing `.ovid/memory` / session-memory files may be accessible through generic shared filesystem tools | Preserve files; no automatic import/deletion/move. Quarantine/import requires a separate reviewed plan. No overall hard-isolation claim while legacy data remains exposed |
| Settings / BYOK | Recovery edits and tests preserved; implementation still in progress | Validate owner keys and ordinary-send billing/routing; validate denied tools and settings; regenerate remains unavailable rather than using incomplete BYOK logic |
| Artifact Vault | Design approved; account inventory/client implementation in progress | Canonical upload/generated IDs, owned bounded pagination, scoped mint URLs, truthful object-availability errors, account-change fencing, no local fallback on cloud errors |
| Capacity | 20- and 200-user stub-model runs completed per agent; 200-user measurement lasted 120 seconds after ramp/settle | Review exact workload, actual browser proof and Redis growth before any 1,800+ run; no claim from connected sockets alone |

## Capacity evidence boundaries

The capacity agent reports a 60-second, 20-user baseline with 42 accepted and
completed runs and no request/run failures. The recorded p95 send acceptance was
47 ms. This is **not** a 1,800-user result. Its original pacing was 20–60 seconds
of think time after an approximately ten-second stream, rather than a 20–60
second start-to-start interval. A targeted pacing correction is being tested.

The smoke's Studio reads used the worker's internal file path, not the gateway's
public Studio API. Browser attachment attempts did not prove live Chromium
contexts or streamed frames. Later measurements must record actual model
streams, tool results, browser state/frames, errors, duration, resource usage,
and teardown. Inherited larger runs had failures and cannot be called passing.

All capacity traffic uses isolated test services with a stub model. Mandatory
per-run admission/ban/deletion/quota checks must remain active. An inherited
success-cache bypass was reproduced and removed on the capacity branch, with
focused tests reported; it is not merged or deployed as a performance feature.

## Still-open product contracts

A read-only coverage map of integration commit `d6e99c7f` found these separate
unfinished areas; the existence of isolated server tests is not end-to-end proof:

- Full cloud sharing snapshots and server-backed continuation/fork.
- Sidebar search over cloud messages, not only a local cache.
- Worker image-generation/edit tools and resulting receipts/artifacts.
- Production MCP/plugin tool contribution plus a gated management/OAuth client.
- Real cloud collaboration inference, not a throwing client-side runner.
- Durable asynchronous background subagent orchestration. Live child cards are
  useful UI but do not convert an awaited in-process child into a durable job.
- Final performance, accessibility, small-screen and signed-APK verification.

## Integration order

1. Finish safe chat-action gating and review chat/history recovery.
2. Reconcile generated attachment migration 0018 after deployed 0017; do not
   rewrite the deployed migration or snapshot.
3. Generate private-memory migration 0019 from the reconciled schema/snapshot;
   review ownership, lifecycle, revision/limit checks and actual privacy tests.
4. Integrate Settings and Artifact Vault additively; review shared exports and
   authentication/account-transition hooks.
5. Rebuild and run integrated focused/full suites in a coordinated test window,
   not during timed capacity measurements.
6. Only then consider a backed-up production deploy and later emulator acceptance.
   Do not represent the working tree or agent handbacks as a completed release.
