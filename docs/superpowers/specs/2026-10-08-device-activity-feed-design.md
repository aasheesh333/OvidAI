# Device activity feed

**Status:** Approved design. This document specifies the private activity feed
and its foreground delivery behavior. It depends on the typed account-sync
contract and authorizes no production implementation or hosted execution.

## Purpose and boundary

The feed lets an enrolled device observe what happened on another device:
request lifecycle, tool/MCP/plugin/browser/build status, usage state, and
delivery state. An activity item is a private, typed, inert presentation
record. It is not a command, queue entry, recovery token, workflow definition,
or permission grant.

The initiating device remains the only execution site. A receiving device may
render, search, group, and acknowledge activity, but must not dispatch a model
request, repeat a paid request, resume a process, replay a tool, run an MCP or
plugin operation, open a browser action, build, clone, or execute text found in
an activity record.

Private activity and transcript text use the private account policy: transcript
text may contain secrets and is preserved as private account data. Activity
payloads should avoid duplicating transcript text unless needed for the typed
presentation contract; omission is not a redaction guarantee.

## Inert typed storage

Activity is stored separately from execution queues and provider request
objects. It uses the account-sync v1 envelope and canonical JSON contract
verbatim: exact camelCase names, `schemaVersion: 1`, UTF-8 RFC 8785
serialization, and rejection of every unknown field. The activity payload is
the following exact closed DTO; IDs are ASCII strings of 1–128 bytes,
timestamps are UTC RFC3339 values of at most 30 bytes, `title` is 0–256
Unicode scalar values, and `detail` is 0–2048:

```json
{
  "logicalRequestId": "opaque-stable-id-or-null",
  "attemptId": "opaque-stable-id-or-null",
  "kind": "request|tool|mcp|plugin|browser|build|system",
  "status": "queued|started|succeeded|failed|cancelled|interrupted|unknown",
  "updatedAt": "RFC3339",
  "title": "bounded text",
  "detail": "bounded text",
  "usageRecordId": "opaque-stable-id-or-null"
}
```

The wire DTO has no `display` extension fields: its exact payload fields are
`logicalRequestId`, `attemptId`, `kind`, `status`, `title`, `detail`, and
`usageRecordId`, with the bounds above. The account-sync replay envelope wraps
this payload and supplies `accountId`, `conversationId`, `createdAt`, and
`changeSequence`; upload omits server-derived fields. `schemaVersion` other
than integer 1, missing fields, wrong types, and unknown fields are rejected.

The allowlist excludes API keys, cookies, authorization headers, grants, local
paths, workspace contents, attachment bytes, raw provider errors, process
handles, and executable/instructional payloads. Provider/model identity is
portable metadata only. Any endpoint identity is passed through the account
sync endpoint validator before it is referenced. Activity storage preserves
status and provenance; it does not infer success, billing, or allowance from
missing fields.

## Identity, ordering, and conflicts

One logical request may have multiple attempt IDs. Each actual outbound
provider request has its own immutable attempt, while activity updates for one
record use a monotonic revision. Retries and reconnects reuse record identity
and never create a new execution attempt merely because delivery was retried.

The server assigns an account-scoped monotonic `changeSequence` to each
accepted activity insert, update, or tombstone. Feed order is this sequence,
then record ID as a deterministic tie-breaker; client timestamps and arrival
order do not define order. A client may display a local “event time” separately.

For a record ID, lower revisions are stale and ignored, equal revisions must
match immutable content, and higher revisions replace mutable fields only.
Conflicting immutable content is an integrity conflict: retain neither as a
silent merge, surface the conflict state, and require a fresh canonical replay.
An activity conflict never triggers the underlying operation.

## Primary delivery: foreground polling

Authenticated foreground polling is the primary transport because it works
through ordinary mobile lifecycle and proxy behavior and has one reconciliation
path. The client stores the last applied opaque cursor and polls:

- immediately on foreground/resume and after an explicit refresh;
- every **15 seconds** while foregrounded and connected;
- with exponential retry from **2 seconds to 60 seconds**, full jitter, and a
  retry reset after a successful response.

Each poll requests at most **100 changes** and **256 KiB canonical response
bytes**. The server returns records/tombstones, `next_cursor`, and a boolean
`has_more`. The client drains `has_more` pages before waiting for the next
interval, coalescing UI repaint to at most once per **250 ms**. Polling stops
when backgrounded, logged out, revoked, or fenced by deletion.

The client labels stale/disconnected state after **45 seconds** without a
successful response and keeps the outbox until each mutation receives a
terminal result. A `reset_required` response clears disposable account caches,
bootstraps state, and reconciles by stable IDs.

## SSE optimization

Authenticated foreground SSE is an optimization, not a correctness dependency.
After a successful poll establishes a cursor, the client may open
`GET /sync/v1/activity/stream?cursor=...` in the foreground. The request has
no body and the cursor is an opaque URL-encoded query value of at most 512
bytes. The response is `200 text/event-stream; charset=utf-8`,
`Cache-Control: no-store`, and each event is UTF-8 with LF line endings and a
blank LF terminator. Every application event has exactly one `event:` line and one `data:`
line; no `id:` or retry directive is sent. `data` is one canonical JSON object
with no newline and `schemaVersion: 1`.

Application frames are exactly:

```text
event: changes
data: {"schemaVersion":1,"nextCursor":"...","hasMore":false,"records":[]}

event: reset_required
data: {"schemaVersion":1,"code":"reset_required"}

: heartbeat

```

Heartbeat is the one permitted non-application frame: exactly one
`: heartbeat` comment plus a blank line every 30 seconds. A `changes` frame
contains at most 100 records and 256 KiB canonical
data; `hasMore` requires another poll/replay request, not another SSE frame.
The server closes after 15 minutes or 1 MiB total event data and sends no
application error frame. HTTP errors use the shared sync error DTO and status:
401 unauthenticated, 403 revoked/fenced, 409 cursor conflict, 410
`reset_required`, 429 rate limited, and 503 temporary failure. A malformed
frame, unknown field, wrong schema, or size violation causes the client to
discard the frame, close the stream, and replay from the last applied cursor.
The client still applies the same DTO validation and cursor replay logic as
polling.

On disconnect, heartbeat timeout, platform rejection, authentication error, or
network transition, the client closes SSE and immediately falls back to the
15-second polling schedule. Reconnect starts from the last applied cursor and
never assumes that an SSE event was delivered exactly once. SSE is disabled
after three failures in five minutes and retried after the next foreground
resume; polling continues throughout. No background SSE or background
execution is promised.

## Applying records and cache behavior

Applying a page is transactional with respect to the local typed activity
projection and cursor: validate all envelopes, apply accepted revisions and
tombstones idempotently, then persist the cursor. A failure leaves the prior
cursor available for replay. A page may be safely applied again.

Tombstones remove or hide the local activity projection and invalidate the
record cache, conversation/activity aggregate cache, search index, unread
counts, and any derived “last activity” value. An older page or outbox retry
cannot recreate it. Account switch, logout, revocation, deletion fencing,
cursor reset, and schema migration clear all account-keyed feed caches before
installing new state. The cache is never an authorization or deletion source.

Compaction may replace old detailed activity with an inert summary only when
the required transcript and usage records remain restorable and the client is
told that detail was compacted. The server retains replay tombstones for **30
days after the last cursor that could reference them expires**.

## Enrollment and revocation behavior

Only devices enrolled under the private account-sync contract can poll or open
SSE. Revocation immediately rejects both transports, invalidates stream/poll
leases, stops local delivery, and clears that device's private feed cache. It
does not delete account data. Re-enrollment uses a new device ID and a fresh
private-sync consent flow.

## Verification requirements

Tests must prove:

1. Deserializing, storing, applying, or replaying activity cannot dispatch any
   model/tool/MCP/plugin/browser/build/clone/orchestration operation.
2. Complete private transcript text remains available under private policy,
   while activity payloads reject credentials, paths, grants, handles, and
   executable state.
3. Server change-sequence ordering, revision rules, immutable conflicts,
   duplicate delivery, reordered pages, cursor reset, and tombstones are
   deterministic.
4. Polling is correct on its own at the exact intervals, page limits, retry
   bounds, stale threshold, and repaint coalescing limits.
5. SSE disconnect/reconnect, heartbeat timeout, repeated failures, lifecycle
   changes, and fallback preserve cursor correctness and never repeat an
   operation.
6. Tombstones invalidate every specified local cache and cannot be undone by
   stale pages or outbox retries.
7. Enrollment and revocation stop both polling and SSE and prevent late data
   publication.
