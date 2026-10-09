# Live collaboration sessions

**Status:** Design specification. This document authorizes no production
implementation, endpoint activation, migration, deployment, or commit.

## Goal and boundary

Add authenticated private live collaboration at `/chat/{SessionToken}`. A
session has one owner and at most nine additional participants, for a hard
maximum of **10 participants total**. The session server authenticates every
request, verifies private membership, orders and relays inert collaboration
events, and exposes cursor-based replay. It never executes a model, tool,
MCP/plugin, browser action, build, clone, shell process, or agent orchestration.

The participant's device remains the execution authority. A participant may
send a prompt or other model request to its own local runtime; the resulting
request and usage are attributed to that participant and published as safe
session events. A remote participant's event can update presentation, but it
cannot cause the receiving device to execute work.

This feature is distinct from public share snapshots and from account-wide
private sync. The session token identifies a collaboration session, not an
account credential or a bearer capability that bypasses authentication.

## Session identity and membership

- `SessionToken` is an opaque, high-entropy, server-issued identifier safe to
  place in a route after authentication. It is not logged, rendered into
  analytics, or reused as an account/device identifier.
- The owner creates the session and is the only participant who can change
  membership, close the session, or transfer ownership if transfer is later
  approved. Ownership transfer is not part of v1.
- Joining requires an authenticated account identity plus an owner-issued,
  expiring invitation or an equivalent authenticated membership grant. The
  server derives the account/user binding from verified authentication and
  never trusts a submitted owner ID or participant ID.
- Membership records contain session ID, account/user ID, role, status,
  creation/revocation times, and a membership generation. Revocation stops
  new writes and replay/stream publication immediately after the current
  bounded operation observes the generation change.
- Every read, write, cursor replay, stream, and membership operation checks
  authenticated identity, active membership, session lifecycle, and the
  current membership/session generation.
- The owner counts toward the 10-person limit. A join that would exceed the
  limit is rejected; reconnecting an already-active member does not consume a
  second slot.

## Atomic capacity invariant

Capacity admission is serialized by the session authority. The membership
check, active-member count, invitation consumption (when applicable), member
insert, and membership generation update occur in one transaction under the
session lock/row lock. No API-instance-local counter is authoritative.

The transaction must either admit exactly one new member while preserving
`active_members <= 10`, or admit none. Concurrent joins at the boundary must
produce at most the remaining number of successful admissions. Revoked or
expired memberships free capacity only after their durable status transition
commits. Failed requests do not consume capacity or publish membership events.

## Event log and cursors

The session owns an append-only, account/session-scoped event log with a
monotonic `eventSequence`. The sequence is allocated in the same transaction
as the event mutation. The log is ordered by sequence, never by client clocks,
arrival timestamps, or event IDs.

Events are inert data. The v1 event envelope is closed and contains only:

```json
{
  "schemaVersion": 1,
  "eventId": "opaque-id",
  "sessionId": "server-derived",
  "eventSequence": 42,
  "senderParticipantId": "server-derived",
  "kind": "message|modelStatus|usage|presence|membership|system",
  "createdAt": "RFC3339 UTC",
  "payload": {}
}
```

Unknown fields, unknown kinds, wrong types, invalid bounds, duplicate event
IDs, and client-supplied server fields are rejected. A client retry uses an
idempotency key and stable client event ID; it returns the original result and
does not append a second event.

The server exposes an opaque cursor representing a position, never a
credential. Replay returns events strictly after the cursor, in ascending
`eventSequence`, with bounded event count and canonical byte size. A cursor is
bound to the authenticated session membership and expires according to the
retention policy. Expired or malformed cursors return a typed reset response;
clients bootstrap the current bounded session state before resuming.

Live delivery may use foreground polling first and an optional authenticated
SSE stream later. Polling remains correct with streams disabled. Streams have
bounded leases and buffers, recheck membership/lifecycle before every
publication, and close on revocation, session closure, lease expiry, byte/time
limits, or client disconnect. A slow client never causes unbounded server
memory growth.

## Private payload policy

Session messages are private user data and may contain secret-like text. They
must not appear in URLs, logs, traces, analytics, metrics labels, error
messages, or support exports. The server must preserve private message text
verbatim for authorized session members; public-share redaction is not applied.

Portable provider/model metadata is descriptive only and must exclude API keys,
cookies, grants, authorization headers, refresh tokens, credential-bearing
endpoint userinfo, local paths, workspace contents, process handles,
attachments, raw session serialization, executable instructions, and runtime
queues. Endpoint metadata is admitted only after the existing credential-free
endpoint validation policy is applied.

Model metadata may include provider ID, requested model, provider-reported
model when available, streaming capability, and a display-safe name. It must
not include prompts, completion text, request headers, credentials, raw
provider errors, or hidden provider configuration.

## Participant-local execution and attribution

Each participant's local runtime remains responsible for model execution. A
local request follows the existing request/attempt accounting boundary before
transport and records the initiating participant, source device, logical
request ID, attempt ID, requested model, provider-reported model, outcome,
token provenance, and available timing/usage fields.

The session event contains only the approved usage projection and safe status
metadata. Retries are distinct attempts grouped under one logical request.
Unknown or interrupted usage remains unknown; it is never represented as zero.
The server does not calculate allowance, billing, or token totals from
concurrent events. A receiving participant may render another participant's
attribution but may not replay the request, invoke a provider, or merge the
remote request into its local execution queue.

The event consumer must be structurally unable to call an executor: event
repositories and projection stores accept typed data only, not callbacks,
provider request objects, commands, process handles, or serialized queues.

## Lifecycle fencing

Session lifecycle states are `active`, `closing`, and `closed`. Closing is an
atomic durable fence: it prevents new joins, event appends, and stream/poll
publication, invalidates active leases, and then permits bounded cleanup. A
closed session rejects all later mutation and membership requests.

Every asynchronous callback captures the session generation and participant
membership generation at admission. Before persistence, publication, or local
projection, it verifies that both generations still match and that the
session is active. A result from a prior owner, account, membership, device,
or session generation is discarded. Account sign-out, account switch,
participant revocation, session close, and app reset all cancel or fence local
callbacks before clearing account/session data.

Deletion removes event payloads, membership/invitation state, cursors, leases,
idempotency records, indexes, and derived projections under the same durable
session fence. A permanent tombstone prevents late writes or replay from
recreating the session. Cleanup is idempotent and does not execute any
operation represented by an event.

## Limits and retention

The following v1 limits are hard requirements and must be enforced durably:

- 10 active participants per session, including the owner.
- 1 MiB compressed request body; 8 MiB canonical decompressed batch.
- 100 events per append batch; 256 KiB canonical event; 256 KiB canonical
  replay page.
- 60 append requests/minute/session; 120 replay requests/minute/session; 2
  live streams/session; 1 stream/participant.
- 10,000 accepted events/session/rolling 24 hours and 100 MiB retained
  canonical event data/session, with deletion/tombstone lifecycle records
  remaining admissible when retention is full.
- Poll interval is 15 seconds while connected, with reconnect backoff of
  2–60 seconds and full jitter. A connection is stale after 45 seconds.
- SSE, if enabled, sends a heartbeat every 30 seconds and closes after
  15 minutes or 1 MiB event data. Correctness cannot depend on SSE.
- Cursors and event retention are cursor-aware. Events may be compacted only
  through an explicit replay-visible marker after every cursor that could
  reference them has expired. Required conversation and usage projections
  remain available for the approved session lifetime.

All byte limits use canonical UTF-8 bytes. Compression does not increase a
quota. Rate limits and capacity are shared durable state, not process-local
memory.

## API shape

The exact HTTP envelope and authentication adapter must follow the existing
account runtime conventions, but v1 requires these operations under the
session route:

- `POST /chat` creates a session and returns an opaque `sessionToken`, owner
  membership, lifecycle state, and current cursor.
- `GET /chat/{SessionToken}` returns bounded authorized session state and
  membership metadata.
- `POST /chat/{SessionToken}/members` admits an authenticated join or creates
  an owner invitation under the atomic capacity transaction.
- `DELETE /chat/{SessionToken}/members/{participantId}` revokes a member.
- `POST /chat/{SessionToken}/events` appends validated inert events with an
  idempotency key.
- `GET /chat/{SessionToken}/events?cursor=...` replays ordered events.
- Optional `GET /chat/{SessionToken}/events/stream?cursor=...` provides bounded
  authenticated SSE delivery after polling correctness is complete.
- `POST /chat/{SessionToken}/close` lets the owner begin the lifecycle fence.

All responses and errors use `Cache-Control: no-store`. Errors have fixed,
non-sensitive messages and never echo payloads, tokens, transcript text,
credentials, provider URLs, or raw upstream errors.

## Verification requirements

Tests must use fake identities, fake clocks, temporary storage, local ASGI/
loopback transports, and deterministic concurrency barriers. No test may make
a paid provider call or contact a production service.

1. Two concurrent joins at 9 active members yield exactly one success.
2. The owner counts toward capacity; duplicate reconnects do not consume a
   slot; revocation frees one slot only after commit.
3. Unauthenticated, wrong-account, non-member, expired-invitation, revoked,
   closing, and closed requests cannot read, append, join, or stream.
4. Event batches reject unknown fields, server-supplied fields, oversized
   canonical bytes, invalid compression, duplicate IDs, and executable or
   credential-bearing payload fields.
5. Retries are idempotent; accepted events receive unique monotonic sequences
   and replay returns exactly ordered pages without gaps or duplicates.
6. Malformed/expired cursors return reset; bootstrap plus replay recovers the
   authorized projection without executing an event.
7. A receiving client renders messages, model status, usage, membership, and
   presence without invoking a model/tool/MCP/plugin/browser/build/clone,
   changing a local queue, or creating a provider request.
8. Local requests attribute usage to the initiating participant; retries,
   provider-reported models, zero/null/estimated/unknown values, cancellation,
   interruption, and account/session switches remain distinguishable.
9. Closing, revocation, account switch, sign-out, reset, and deletion fence
   already-open streams and delayed callbacks; no stale event is published.
10. Retention, byte/count/rate limits, stream limits, cursor expiry,
    compaction markers, idempotency replay, and cleanup are correct across
    restart and two independent server instances.
11. Logs, traces, metrics, errors, and exports contain no session token,
    transcript sentinel, credential sentinel, provider URL, request body, or
    raw provider error.
