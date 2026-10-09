# Device execution and request usage accounting

Status: usage design approved in conversation; written specification awaiting review.

## Product boundary

Ovid remains a device-executed application. Builds, repository clones, shell
processes, browser automation, MCP/plugin execution, tools, and agent orchestration
run on the initiating user's device. Existing remote model-provider calls remain
remote model calls; synchronizing history does not introduce hosted agents or
cloud builds.

Account synchronization stores and relays private conversations, portable
provider metadata, usage records, and activity updates so the same signed-in
account can see them on another device. Receiving an activity record never
dispatches a tool, resumes a process, replays a queue, or repeats a paid request.
Workspaces must be created or cloned independently on each device.

Private transcript synchronization is distinct from public snapshot sharing and
from operational activity summaries. A metadata-only projection does not satisfy
conversation restoration. Conversely, raw local session serialization is not a
portable sync contract: it mixes messages with paths, grants and runtime state.

Separate subsequent specifications will cover sync storage/transport and live
shared conversations. Shared conversations have at most **10 participants total,
including the owner**, with each user's initiated model requests attributed to
that user. Device execution remains required there too.

## This implementation slice

Implement complete local model-request accounting as the foundation for later
account sync. This slice adds no hosted execution, credential uploads, sync
endpoint, account-deletion activation, or change to retry policy.

### Record identity and lifecycle

- A logical request ID groups one user/helper invocation and its retries.
- Each new outbound provider request has its own immutable attempt ID. This
  includes compatibility fallbacks and retries that issue another HTTP request.
- An attempt is durably recorded before dispatch. Its dispatch stage distinguishes
  local preparation from possible upstream transmission. An interrupted record
  cannot establish zero charge merely because no response arrived.
- Updates upsert by attempt ID with a monotonic revision. Repeated completion
  callbacks or later sync delivery must not append a second request.
- Record source device, session/run association when present, request purpose,
  requested model, provider-reported model when available, timestamps and elapsed
  transport time. Do not persist request bodies, credentials or raw errors in the
  usage record.
- Distinguish pending, succeeded, failed, cancelled and interrupted/unknown
  outcomes. Outcome is separate from usage availability and charge certainty.

### Tokens and money

Each token field has a nullable value and provenance: provider-reported, locally
estimated, derived, unknown, or legacy-unspecified. Explicit provider zero stays
zero. Deriving a total from components preserves whether any component was
estimated or unavailable; missing components do not become zero.

Legacy records retain their values with legacy-unspecified provenance: earlier
integer values cannot retrospectively be certified as measured. Stable migration
IDs are persisted once; identical legacy rows are not automatically collapsed,
because they may represent separate requests.

Reported model determines attribution when available. Otherwise display requested
identity with unresolved attribution, particularly for Auto aliases. Preserve the
requested model for routing. A provider-reported model is not an independent audit
of the upstream implementation.

Local pricing produces explicitly estimated cost only when sufficient usage and
pricing are available. Unknown price is null, not free. Server-confirmed Ovid
allowance and billing remain separate authorities and are never reconstructed
from client estimates or differences between concurrent allowance snapshots.

### Capture and persistence

Use a small dedicated usage model/store instead of expanding the large agent
service with a second accounting subsystem. A shared attempt recorder is called
at the actual outbound transport boundaries for OpenAI-compatible and Anthropic
requests, including nested fallbacks. Main-loop statistics remain session
analytics; remove their duplicate usage-log append when transport capture owns it.

Cover ordinary turns, child agents, title generation, compaction, prompt hooks,
prompt tools and fan-out. Every actual outbound retry is a separate attempt;
validation rejected before transport is not counted as a provider request.

Persistence is account-scoped and bounded. Pending records cannot silently fall
out of the retained history. Surface storage failure, retained-history limits and
incomplete capture rather than claiming all-time complete totals. Account changes
fence callbacks using the existing account token; previous-owner results must
never enter the new account. On restart, unresolved attempts become interrupted
or unknown; loading records never resends the model request.

The usage store exposes a revision that changes on inserts and updates. Existing
consumers watching only list length and last entry must adopt that revision.

### UI

Show observed attempts and their model breakdown across cloud, free and custom
providers. Keep the server allowance panel distinct from client request history.
Separate measured, estimated, legacy and unavailable usage; unknown attempts count
toward request activity but do not imply known zero tokens. Label request counts
as attempts where retries are included. Clearly label costs as estimated or
server-confirmed and history as retained records, not all-time usage.

### Verification

Use loopback OpenAI/Anthropic SSE fixtures and deterministic persistence tests:

1. Auto request resolves to reported model without altering request routing.
2. Zero, missing, mixed-provenance and usage-only events remain distinguishable.
3. Helpers, fan-out and children record requests without a main-loop append.
4. Retries and compatibility fallbacks produce distinct attempts grouped by one
   logical request; duplicate callbacks produce one record per attempt.
5. Timeout, cancellation and partial streams retain available measurements and
   unknown billing status; reconnect/restart never repeats an operation.
6. Migration preserves legacy values, duplicate legacy rows and stable IDs.
7. Account switch and same-account re-login reject stale result publication.
8. Updates invalidate aggregate caches; cloud history does not alter allowance.
9. Unknown costs and capped/incomplete history are accurately rendered.
10. Source device metadata and receiving a record cannot trigger execution.

Run focused Flutter tests with the shared Flutter lock and concurrency one, plus
targeted analysis. Integrated review follows before release. No test result alone
establishes deployed sync or real-device acceptance.

## Subsequent sync design decisions

Use authenticated, account-scoped durable records with idempotency, replay cursors,
bounded compressed payloads, quotas and deletion tombstones. Compare cursor-based
HTTP with foreground SSE plus cursor replay; choose a protocol in its own spec.
The server may authenticate, order, store and relay data without executing tasks.
Device-local account generation tokens are callback fences, not shared server
authorization credentials.

Credentials, browser cookies, permission grants and live process handles are not
ordinary sync metadata. Provider endpoint strings also require validation because
URLs can contain credentials. Cross-device API-key restoration requires a separate
explicit choice between local re-entry and an encrypted credential-sync design;
this specification does not authorize uploading keys.

Current account-scoped memory roots in AppState must be preserved. Audits of
MemoryStore alone do not establish that its caller supplies a device-global root.
