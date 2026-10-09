# Private account sync

**Status:** Approved design. This document specifies private, account-scoped
storage and synchronization only. It authorizes no production implementation,
endpoint activation, hosted execution, or credential restoration.

## Goal and boundary

The same signed-in account can view its private conversations, portable provider
metadata, usage history, and activity records on another enrolled device.
Execution remains local to the device that initiated it. Builds, repository
clones, shell/browser/MCP/plugin work, local files, process state, and agent
orchestration do not move to the server. The server stores, orders, deletes,
and relays typed records; it never starts, resumes, retries, or replays a
model, tool, MCP, browser, build, clone, or orchestration operation.

Private sync is separate from public share snapshots. Public-share filtering
must not be applied to private transcript rows, and raw local session JSON is
not a sync contract.

## Security and privacy policy

Private transcript text is user data and **may contain secrets**. The private
sync policy is to preserve the complete private transcript for the account,
including text that would be rejected by public-sharing policy. This is not a
claim that transcript text is secret-free. Clients must show the private-sync
scope at enrollment and must not place transcript content in URLs, logs,
analytics, cache keys, or error messages.

The sync boundary still excludes credentials and device execution state:

- API keys, cookies, grants, authorization headers, refresh tokens, and
  credential-bearing endpoint userinfo never enter ordinary sync records.
- Process handles, local paths, workspace contents, attachment bytes, raw
  session serialization, executable instructions, and runtime queues are not
  portable fields.
- Provider endpoint metadata is admitted only after endpoint validation (below).

## Normative v1 wire contract

The API accepts only the following closed DTOs. Field names are exactly the
camelCase names below. A missing required field, wrong JSON type, out-of-range
value, or unknown field is rejected. `schemaVersion` must equal integer `1`;
other versions return `schema_version_unsupported`. There is no generic
map-to-runtime-state conversion. `accountId` and `changeSequence` are
server-generated and occur only in stored/replayed records.

```json
{
  "schemaVersion": 1,
  "recordId": "opaque-stable-id",
  "accountId": "server-derived",
  "sourceDeviceId": "opaque-stable-id",
  "recordType": "transcript|providerMetadata|usage|activity|tombstone",
  "conversationId": "opaque-stable-id-or-null",
  "createdAt": "RFC3339",
  "revision": 1,
  "changeSequence": 42,
  "payload": {}
}
```

Upload DTOs omit `accountId` and `changeSequence`; replay DTOs include them.
IDs are non-empty ASCII strings of 1–128 bytes. Timestamps are UTC RFC3339
values of at most 30 bytes. Integers use the stated non-negative bounds below;
all text bounds are Unicode scalar values. `recordId` is immutable and globally
unique within an account; retries reuse it. `revision` is monotonic for that
record. A record has one of these exact payloads (no additional fields):

```text
TranscriptPayload { messageId:string[1..128], parentMessageId:string[1..128]|null,
  kind:"user"|"assistant"|"system"|"tool", text:string[0..262144],
  providerMetadataRecordId:string[1..128]|null, requestPurpose:string[0..128]|null,
  displayTitle:string[0..256]|null }
ProviderMetadataPayload { providerId:string[1..64], modelId:string[1..128]|null,
  endpoint:string[1..2048], requestPurpose:string[0..128]|null,
  displayName:string[0..256]|null, supportsStreaming:boolean }
UsagePayload { logicalRequestId:string[1..128], attemptId:string[1..128],
  requestedModel:string[1..128]|null, reportedModel:string[1..128]|null,
  outcome:"pending"|"succeeded"|"failed"|"cancelled"|"interrupted"|"unknown",
  inputTokens:integer[0..2147483647]|null, outputTokens:integer[0..2147483647]|null,
  totalTokens:integer[0..4294967295]|null,
  usageProvenance:"providerReported"|"locallyEstimated"|"derived"|"unknown"|"legacyUnspecified",
  startedAt:timestamp|null, completedAt:timestamp|null,
  elapsedMilliseconds:integer[0..604800000]|null }
ActivityPayload { logicalRequestId:string[1..128]|null, attemptId:string[1..128]|null,
  kind:"request"|"tool"|"mcp"|"plugin"|"browser"|"build"|"system",
  status:"queued"|"started"|"succeeded"|"failed"|"cancelled"|"interrupted"|"unknown",
  updatedAt:timestamp, title:string[0..256], detail:string[0..2048],
  usageRecordId:string[1..128]|null }
TombstonePayload { targetRecordId:string[1..128], deletionRevision:integer[1..2147483647],
  deletedAt:timestamp, reason:"user"|"account"|"retention"|"conflict"|"admin" }
```

Transcript text is complete private account data, including secret-like text;
public-share redaction is never applied. Provider endpoints pass the validator
below. Usage provenance never establishes allowance or billing. Activity is
inert and tombstones have no executable payload.

Every accepted DTO is serialized for hashing, quota accounting, storage, and
replay as RFC 8785 JSON Canonicalization Scheme, encoded as UTF-8, with keys
ordered by its lexicographic UTF-16 rule, no insignificant whitespace, and no
NaN, Infinity, or unpaired surrogates. The canonical bytes are the quota unit.

Typed storage is separate from execution storage and code paths. The sync
repository contains canonical DTOs and projections only; no method in its
write, read, merge, or replay path accepts a runnable callback, command,
process handle, serialized queue, or provider request object. Receiving a
record can update a transcript/activity index, but cannot dispatch work.

## Endpoint validation

Provider endpoint values are metadata, not arbitrary URLs. Before admission,
the validator must:

1. parse the value as an absolute URL with an allowed scheme (`https` by
   default; any non-HTTPS scheme requires an explicit provider policy);
2. reject username/password userinfo, fragments, embedded credentials, and
   control characters;
3. reject query parameters that are credential-shaped (`key`, `token`, `secret`,
   `auth`, and provider-specific equivalents) unless a provider policy proves
   they are non-secret;
4. canonicalize host, port, path, and non-sensitive query fields; and
5. store only the canonical credential-free endpoint identity.

Validation is performed before persistence and again on import. A failed
validation rejects only that record with a typed error; it is never silently
stored as a raw string. API credentials remain local and must be re-entered on
each device unless a separate encrypted credential-sync design is approved.

## Enrollment, authorization, and revocation

An account may enroll a device through the existing authenticated account
runtime. Enrollment displays the private-sync scope, creates a server-issued
opaque device ID, records a device name and creation time, and grants read/write
sync permission only after explicit confirmation. The server derives the
account binding from the verified token and never trusts a submitted owner ID.

The account has a finite device limit of **10 enrolled devices**. Enrollment
fails with a typed limit error until an existing device is revoked. A device
may list its own enrollment metadata but cannot mint or alter another device.

`DELETE /sync/v1/devices/{device_id}` immediately revokes that device's read
and write authorization, invalidates its stream/poll leases, and prevents new
outbox writes from being accepted. Revocation does not delete account records.
The device being revoked may be the current device only after a fresh account
reauthentication. A lost-device flow uses the same authenticated revocation
operation from another enrolled device or the account security surface.
Re-enrollment creates a new device ID; old IDs are never recycled.

## Ordering, conflict handling, and delivery

Upload is at-least-once. The server deduplicates by `(accountId, recordId)`
and returns the canonical stored revision. All mutations require an
idempotency key. Per-record results distinguish accepted, duplicate, rejected,
conflict, and retryable outcomes.

The server assigns an account-scoped monotonic change sequence to every
accepted insert, update, and tombstone. This server sequence, rather than
client clocks or arrival order, defines replay order. Records with independent
IDs may arrive in any order. For one ID, a lower revision is ignored as a
stale duplicate; an equal revision must have identical immutable content; a
higher revision may replace only mutable fields. Different immutable content
for the same ID is a hard integrity conflict and is retained for audit/error
handling without choosing a winner. Clients surface the conflict and do not
 silently merge transcript text. Transcript `messageId`, `kind`, `text`, and
 parent identity are immutable after first acceptance. The conflict UI must
 show “Sync conflict — transcript unchanged,” identify local and canonical IDs
 and revisions without quoting transcript text, and provide “Keep canonical,”
 “Keep local as a new message,” and “Dismiss”; it must not offer overwrite.
 Keeping local creates a new record ID on the initiating device and never
 mutates the conflicted ID.

Each device keeps a durable outbox containing typed DTO, schema version, source
device, idempotency key, and local delivery state. Offline and retry paths only
re-submit DTOs. They never invoke the operation represented by a record.

Replay uses an opaque cursor and bounded page. An expired or malformed cursor
returns `reset_required`; the client bootstraps state and reconciles by stable
record IDs rather than guessing a position. Cursors are positions, not bearer
authorization credentials.

## API contract

- `POST /sync/v1/records`: authenticated bounded batch upload with explicit
  per-record results.
- `GET /sync/v1/changes?cursor=...`: authenticated replay page containing
  account-sequenced records and tombstones.
- `GET /sync/v1/state`: authenticated bootstrap containing current cursor,
  enrollment metadata, retention/compaction markers, and bounded summaries;
  it never returns raw session serialization.
- `POST /sync/v1/devices`: authenticated enrollment with explicit private-sync
  consent.
- `DELETE /sync/v1/devices/{device_id}`: authenticated revocation.

Responses are private and `Cache-Control: no-store`; sensitive content is not
cached by shared intermediaries. Credentials and transcript content never
appear in URLs. Existing account authentication, account-generation fences,
and the server-owned deletion lifecycle gate every endpoint.

Errors are JSON objects with exactly `schemaVersion` (1), `code`, `message`,
and `retryAfterSeconds`. `code` is one of `invalid_request`, `unauthenticated`,
`device_revoked`, `account_fenced`, `not_found`, `integrity_conflict`,
`payload_too_large`, `schema_version_unsupported`, `invalid_record`,
`endpoint_rejected`, `rate_limited`, `quota_exhausted`, or
`temporarily_unavailable`; `message` is a fixed non-sensitive string of at
most 160 characters; `retryAfterSeconds` is an integer 0..86400 or null.
Error bodies never contain DTOs, transcript text, endpoints, credentials,
request bodies, or raw provider errors. HTTP mappings are 400 for invalid
request, 401 for unauthenticated, 403 for revoked/fenced, 404 for not found,
409 for integrity conflict, 413 for size, 422 for schema/record/endpoint
errors, 429 for rate/quota errors, and 503 for temporary failure.

Deployment is a stateless authenticated sync router/API tier with a durable
account-partitioned record store, change log, quota ledger, and stream gateway.
No service worker can launch device operations. Per account, limits are 60
upload requests/minute, 120 replay requests/minute, and 2 concurrent streams;
per device, 30 upload requests/minute and 1 concurrent stream. Rate limits
return 429 and bounded retry time. Observability records route, status,
latency, byte/count quotas, cursor result, error code, and rotating-secret
hashes of account/device IDs only. Payloads, transcript text, URLs, query
strings, authorization headers, cookies, request bodies, and raw provider
errors are redacted from logs, traces, analytics, and support exports.

## Exact quotas and codec

The initial contract uses **gzip** (`Content-Encoding: gzip`) as the sole
required compression codec. Servers may negotiate zstd later; clients must
fall back to gzip and must never treat compression as quota capacity.

Quotas are charged after decompression, DTO validation, and canonical
serialization:

- request body: at most **1 MiB compressed**;
- batch: at most **8 MiB canonical decompressed bytes** and **100 records**;
- one record: at most **256 KiB canonical bytes**;
- account ingest: **10,000 accepted records per rolling 24 hours**;
- retained private sync data: **100 MiB canonical bytes per account**.

Transcript text counts in canonical UTF-8 bytes. Tombstones count until their
retention horizon. Rejected records do not consume ingest quota; accepted
duplicates do not consume it twice. Usage and activity records count as normal
records. A valid batch is partially applicable, with oversized records
rejected individually. The server is the quota authority and returns typed
quota errors with retry timing where applicable.
Ingest exhaustion returns `quota_exhausted` with the time until the oldest
admission expires. Retained-byte exhaustion rejects ordinary writes until
retention or compaction frees space; compression or splitting cannot evade it.
Deletion/conflict tombstones remain admissible.

## Deletion, cache invalidation, and tombstones

Account deletion uses the existing cancellable server-owned lifecycle. Once the
durable deletion fence commits, new writes, reads, polls, and streams are
rejected. Cleanup removes transcript, metadata, usage, activity, outbox,
cursor, enrollment, server indexes, and all sync/cache projections, then
writes a permanent account tombstone sufficient to reject late requests.
Firebase identity deletion remains ordered after durable data cleanup.

Record deletion is an account-scoped tombstone with stable ID, deletion
revision/time, and reason class. Tombstones are replayable, idempotent, and
never executable. A receiving client deletes/hides the local typed projection,
invalidates record and aggregate caches, acknowledges the tombstone, and never
recreates the deleted record from an older outbox or page. The server retains
tombstones for **30 days after the last cursor that could reference them
expires**; account tombstones are permanent. Canonical transcript and provider
records remain until account deletion or an explicit user-visible retention
action required by the 100 MiB limit. After 30 days, activity detail may be
compacted into one inert summary per logical request, retaining status,
timestamps, and usage references; transcript and usage records required to
restore the supported view must remain. Compaction emits a replayable marker,
is transactional with quota accounting, and cannot remove a tombstone before
its horizon.

Local caches are disposable projections, never authorities. Any account
switch, logout, revocation, deletion fence, cursor reset, or schema migration
clears account-keyed record, aggregate, search, and activity caches before a
new account snapshot is installed.

## Credential policy

Ordinary sync may show “credential available locally,” but it neither uploads
nor restores credentials. Cross-device credential restoration requires a
separate design covering encrypted ciphertext, consent, key enrollment,
revocation, recovery, server metadata, and deletion. Until then, local
re-entry is the only supported path.

## Verification requirements

Before implementation approval, tests must prove:

1. Complete private transcript text, including secret-like text, survives
   typed round-trip while public redaction rules are not applied.
2. Raw sessions, credentials, paths, grants, executable state, and invalid
   endpoint URLs are rejected.
3. Typed storage cannot invoke execution and rejects runnable/runtime objects.
4. Enrollment limits, consent, revocation, lost-device recovery, and account
   binding behave deterministically.
5. Reordering, duplicate uploads, stale revisions, immutable conflicts, cursor
   reset, and tombstone replay are deterministic and idempotent.
6. Exact compressed/decompressed/record/ingest/retention quotas and partial
   batches are enforced using canonical bytes.
7. Account deletion fences late writes and deletes all data and cache
   projections without recreation.
8. Usage attribution remains observational and never changes server allowance.
