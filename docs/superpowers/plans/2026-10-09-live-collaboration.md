# Live collaboration implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement authenticated private `/chat/{SessionToken}` sessions with one owner, at most nine additional participants, ordered inert events, cursor replay, and participant-local model execution/usage attribution.

**Architecture:** Add a typed collaboration domain to the existing account server runtime. PostgreSQL is authoritative for sessions, membership, capacity, event sequences, idempotency, cursors, leases, quotas, and lifecycle fences. Flutter owns typed session projections and a foreground transport; model execution remains in the initiating device's existing agent/provider path.

**Tech Stack:** Python, FastAPI, psycopg/PostgreSQL, pytest/httpx; Dart/Flutter, existing account/auth/reset/runtime services, fake clocks, temporary storage, and loopback transports.

**Spec:** `docs/superpowers/specs/2026-10-09-live-collaboration-design.md`

## Global constraints

- Maximum is **10 active participants total, including the owner**; capacity admission is one serialized durable transaction.
- Every read, write, replay, stream, and membership operation requires authenticated private membership and current lifecycle/membership generations.
- The server stores, orders, and relays inert typed events; it never executes model, tool, MCP/plugin, browser, build, clone, shell, or agent work.
- Participant-local model execution is attributed to the initiating participant; receiving an event never invokes execution or queues remote work.
- Private transcript text is preserved for authorized members but is excluded from URLs, logs, traces, analytics, metrics labels, errors, and exports.
- Credentials, cookies, grants, auth headers, refresh tokens, credential-bearing endpoint userinfo, paths, workspace contents, handles, attachments, raw session JSON, and runtime queues are excluded.
- Use closed `schemaVersion: 1` DTOs, canonical UTF-8 bytes, opaque session tokens, opaque cursors, idempotency keys, and fixed non-sensitive errors.
- Limits: 1 MiB compressed request, 8 MiB decompressed batch, 100 events/batch, 256 KiB/event, 256 KiB replay page, 60 appends/minute/session, 120 replays/minute/session, 2 streams/session, 1 stream/participant, 10,000 events/rolling 24 hours/session, and 100 MiB retained/session.
- Polling is correct without SSE; use 15-second connected polling, 2–60 second full-jitter backoff, 45-second stale threshold, and bounded stream leases/buffers.
- Preserve all existing working-tree edits. No production calls, paid calls, credential printing, deployment, or commit is authorized by this plan.

## Prerequisites and sequencing

1. Review and approve the normative spec above.
2. Complete or expose the existing authenticated account admission/App Check adapter in `server/account/runtime.py`, `server/account/domain.py`, and `server/account/api.py` without changing `/account/login` semantics.
3. Complete the account-scoped usage attempt boundary described by `docs/superpowers/specs/2026-10-08-device-execution-and-usage-design.md`; collaboration consumes its typed usage projection and does not create a second provider transport.
4. Verify account-switch/sign-out/reset callback fencing in `lib/core/account_session.dart`, `lib/core/firebase_service.dart`, `lib/core/reset_coordinator.dart`, and `lib/core/state.dart`.
5. Resolve contract fixtures before server/client implementation. Use local PostgreSQL only when explicitly supplied through a disposable test DSN.

## File map

### Server collaboration domain

- `server/collaboration/dto.py`: closed request, membership, event, replay, and error DTOs.
- `server/collaboration/canonical.py`: canonical JSON bytes and bounded decoding.
- `server/collaboration/policy.py`: membership, capacity, quotas, cursor, and retention policy.
- `server/collaboration/repository.py`: typed authority interface with no executable callbacks.
- `server/collaboration/postgres.py`: transactional PostgreSQL implementation and locks.
- `server/collaboration/api.py`: authenticated `/chat` routes and safe response mapping.
- `server/collaboration/runtime.py`: explicit account-runtime composition.
- `server/collaboration/stream.py`: optional bounded SSE gateway after polling is correct.
- `server/collaboration/retention.py`: cursor-aware compaction and cleanup.
- `server/collaboration/tests/*.py`: contract, repository, API, stream, lifecycle, and cleanup tests.
- `server/account/migrations/004_live_collaboration.sql`, `server/account/schema.sql`: schema and migration parity.
- `server/account/runtime.py`, `server/account/composition.py`, `server/account/retention.py`: explicit mounting and deletion/retention checkpoints.

### Flutter collaboration domain

- `lib/core/collaboration/dto.dart`: immutable wire DTOs.
- `lib/core/collaboration/canonical.dart`: client canonicalization parity.
- `lib/core/collaboration/store.dart`: durable account/session projection and cursor.
- `lib/core/collaboration/client.dart`: authenticated HTTP/poll/SSE transport.
- `lib/core/collaboration/coordinator.dart`: foreground lifecycle, retry, and generation fencing.
- `lib/core/collaboration/execution_bridge.dart`: local-only request publication and usage attribution boundary.
- `lib/ui/shared_conversation_screen.dart`, `lib/ui/chat_screen.dart`: collaboration presentation and explicit local-send behavior.
- `test/collaboration_*.dart`: DTO, store, client, coordinator, execution isolation, and UI tests.

## Implementation waves

### Wave 0 — Contract fixtures and threat-boundary tests

**Prerequisites:** Approved spec; no production code changes in this wave.

**Paths:** Create `server/collaboration/CONTRACT.md`, `test/fixtures/collaboration/v1.json`, `server/collaboration/tests/test_contract_vectors.py`, and `test/collaboration_contract_vectors_test.dart`.

- [ ] Freeze exact camelCase envelopes for create, membership, append, replay, reset, close, and errors.
- [ ] Include vectors for Unicode ordering, explicit null/zero, maximum bounds, unknown-field rejection, private text preservation, malicious endpoint metadata, opaque token/cursor handling, and idempotent retry.
- [ ] State which event kinds are presentation-only and prove no vector contains a command, callback, provider request, process handle, or queue.
- [ ] Make Python and Dart compare against fixed canonical UTF-8 strings/digests rather than independently deriving expected values.
- [ ] Run `python -m pytest server/collaboration/tests/test_contract_vectors.py -q` and `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/collaboration_contract_vectors_test.dart`; missing codecs are expected until Waves 1 and 5.

### Wave 1 — Server typed contract and policy

**Depends on:** Wave 0.

**Paths:** Create `server/collaboration/__init__.py`, `dto.py`, `canonical.py`, `policy.py`, `errors.py`, `tests/test_dto.py`, `tests/test_policy.py`; add no route yet.

- [ ] Add failing tests for every required/unknown field, server-derived field, bound, enum, timestamp, token, cursor, and event-kind rule.
- [ ] Implement immutable DTOs, canonical bytes, bounded gzip decode, fixed errors, endpoint metadata validation, and typed policy values for all global limits.
- [ ] Test private transcript text remains verbatim while credentials, runtime fields, executable payloads, and unsafe endpoints fail before persistence.
- [ ] Test owner-inclusive capacity math, duplicate active membership, expired invitation, revocation status, cursor binding, and rate-limit boundary values.
- [ ] Run `python -m pytest server/collaboration/tests/test_dto.py server/collaboration/tests/test_policy.py server/collaboration/tests/test_contract_vectors.py -q`.

### Wave 2 — Durable PostgreSQL authority and atomic capacity

**Depends on:** Wave 1.

**Paths:** Create `server/collaboration/repository.py`, `server/collaboration/postgres.py`, `server/collaboration/tests/test_repository.py`, `server/collaboration/tests/test_postgres.py`, `server/account/migrations/004_live_collaboration.sql`; modify `server/account/schema.sql`.

- [ ] Define typed interfaces: `create_session(uid, owner) -> Session`; `admit_member(session_id, requester, invitation, idempotency_key) -> Membership`; `append_events(session_id, member, idempotency_key, events) -> AppendResult`; `replay(session_id, member, cursor, limit, max_bytes) -> EventPage`; `close(session_id, owner) -> None`; `delete_session(session_id) -> None`.
- [ ] Add schema for sessions, memberships, invitations, events, idempotency, cursors, stream leases, rate windows, retention markers, and permanent tombstones, keyed by account/session.
- [ ] Allocate event sequence, event row, idempotency result, and relevant quota mutation in one transaction.
- [ ] Serialize the active-member count and member insert under the session authority; use two independent connections to prove only one of two concurrent boundary joins succeeds.
- [ ] Test duplicate event IDs, lower/equal/higher revisions where applicable, ordered sequences, lost responses, restart/reopen, cross-account isolation, close fencing, and cleanup idempotency.
- [ ] Run `python -m pytest server/collaboration/tests/test_repository.py server/collaboration/tests/test_postgres.py -q` with an explicit local disposable `COLLABORATION_TEST_DATABASE_URL`.

### Wave 3 — Authenticated HTTP routes and account composition

**Depends on:** Waves 1–2 and account admission prerequisite.

**Paths:** Create `server/collaboration/api.py`, `server/collaboration/runtime.py`, `server/collaboration/tests/test_api.py`, `server/collaboration/tests/test_runtime.py`; modify `server/account/runtime.py` and `server/account/composition.py`.

- [ ] Mount `POST /chat`, `GET/POST /chat/{SessionToken}`, member revoke, event append/replay, and owner close routes only through explicit runtime composition.
- [ ] Reuse verified account identity/App Check and hold the account lifecycle admission through each short repository transaction; never accept owner/account IDs from request bodies.
- [ ] Enforce no-store responses, strict body limits, safe errors, membership generation checks, session state checks, idempotency, and cursor binding.
- [ ] Test missing identity/App Check, wrong account, non-member, revoked member, expired invitation, capacity full, malformed token/cursor, oversize body, invalid gzip, duplicate retry, and closed session.
- [ ] Prove importing collaboration modules does not connect, migrate, start workers, or execute events.
- [ ] Run `python -m pytest server/collaboration/tests/test_api.py server/collaboration/tests/test_runtime.py -q`.

### Wave 4 — Lifecycle fencing, retention, and account deletion

**Depends on:** Waves 2–3.

**Paths:** Create `server/collaboration/retention.py`, `server/collaboration/tests/test_lifecycle.py`, `server/collaboration/tests/test_cleanup.py`; modify `server/account/composition.py`, `server/account/retention.py`, `server/account/runtime.py`, and `server/account/tests/test_worker.py`.

- [ ] Fence close, member revocation, account switch/deletion, and generation changes before every delayed publication and callback.
- [ ] Implement cursor-aware event retention, replay-visible compaction markers, bounded quotas, stream lease invalidation, and permanent tombstones.
- [ ] Add the named mandatory deletion checkpoint `live_collaboration`; remove events, memberships, invitations, cursors, leases, idempotency, indexes, quotas, and projections before final account deletion.
- [ ] Test worker restart between checkpoints, failure/retry, stale writes after close/deletion, mismatched authority identity, old cursors, and two server instances observing revocation.
- [ ] Run `python -m pytest server/collaboration/tests/test_lifecycle.py server/collaboration/tests/test_cleanup.py server/account/tests/test_worker.py -q`.

### Wave 5 — Flutter DTOs and durable inert projection

**Depends on:** Waves 0–2; approved account-root/fencing prerequisite.

**Paths:** Create `lib/core/collaboration/dto.dart`, `canonical.dart`, `store.dart`, `test/collaboration_dto_test.dart`, `test/collaboration_store_test.dart`.

- [ ] Implement immutable DTOs and canonical bytes matching the shared fixtures; reject server fields on upload and unknown fields everywhere.
- [ ] Implement `CollaborationStore.open(accountRoot, ownerFence)`, `applyPage(EventPage)`, `installBootstrap(SessionState)`, `clearSession()`, and `close()` with durable cursor/revision commits.
- [ ] Keep projection code typed and inert: it may update messages, status, usage, presence, membership, and cursors but has no executor/provider/queue dependency.
- [ ] Test crash-before-cursor-commit, duplicate/reordered pages, stale pages, malformed events, account/session mismatch, close tombstone, and reopening without replaying work.
- [ ] Run `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/collaboration_dto_test.dart test/collaboration_store_test.dart test/collaboration_contract_vectors_test.dart`.

### Wave 6 — Flutter authenticated transport and foreground coordinator

**Depends on:** Waves 3 and 5.

**Paths:** Create `lib/core/collaboration/client.dart`, `coordinator.dart`, `test/collaboration_client_test.dart`, `test/collaboration_coordinator_test.dart`; modify `lib/core/account_session.dart`, `lib/core/firebase_service.dart`, and `lib/core/reset_coordinator.dart` only at explicit lifecycle hooks.

- [ ] Implement authenticated create/join/append/poll/close operations with opaque token handling, no-store expectations, bounded gzip, cursor replay, and typed error mapping.
- [ ] Implement foreground polling at 15 seconds, full-jitter 2–60 second backoff, stale detection, bounded page draining, and optional stream negotiation only after polling is correct.
- [ ] Capture account/session/membership generations at each operation and discard stale results before store publication; cancel on sign-out, account switch, reset, revocation, close, and deletion.
- [ ] Test reconnect, lost response/idempotent retry, reset-required bootstrap, revoked membership, stale callback, offline/online transitions, and no unbounded queue/buffer.
- [ ] Run `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/collaboration_client_test.dart test/collaboration_coordinator_test.dart`.

### Wave 7 — Local execution bridge and usage attribution

**Depends on:** Existing usage-accounting prerequisite plus Waves 5–6.

**Paths:** Create `lib/core/collaboration/execution_bridge.dart`, `test/collaboration_execution_isolation_test.dart`, `test/collaboration_usage_attribution_test.dart`; modify `lib/core/agent_service.dart`, `lib/core/usage_attempt_recorder.dart`, and `lib/core/state.dart` only at reviewed local publication boundaries.

- [ ] Publish a local participant's message/status/usage projection only after the existing local request/attempt recorder has captured the attempt boundary.
- [ ] Include participant ID, source device, logical request ID, attempt ID, requested/reported model, outcome, provenance, and available timing/usage without prompt bodies, credentials, raw errors, or provider headers.
- [ ] Make the bridge accept local typed results only; it must not accept remote event payloads as executable requests or expose a method that enqueues remote work.
- [ ] Test ordinary requests, retries, child/fan-out attribution, reported model, zero/null/estimated/unknown usage, cancellation/interruption, account switch, and stale callback fencing.
- [ ] Test receiving a remote event with spies proving no provider, tool, MCP/plugin, browser, build, clone, shell, or agent execution occurs.
- [ ] Run `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/collaboration_execution_isolation_test.dart test/collaboration_usage_attribution_test.dart`.

### Wave 8 — Collaboration UI and optional SSE

**Depends on:** Waves 4, 6, and 7.

**Paths:** Modify `lib/ui/shared_conversation_screen.dart`, `lib/ui/chat_screen.dart`; create `test/collaboration_ui_test.dart`; create `server/collaboration/stream.py` and `server/collaboration/tests/test_stream.py` only after polling is green.

- [ ] Render private membership, owner/member state, ordered messages, model status, participant attribution, usage provenance, cursors, reset state, and capacity errors without exposing tokens or secrets.
- [ ] Ensure “send” on the current device calls only that device's local execution path; remote messages render as inert history/status.
- [ ] Add bounded SSE with exact heartbeat/framing, 15-minute/1 MiB close, 512-byte cursor query, shared leases, generation rechecks, revocation close, and no application command frames.
- [ ] Test UI lifecycle, owner-inclusive capacity, revocation/close, remote-event non-execution, private text display, unknown usage labels, reconnect, and SSE-disabled correctness.
- [ ] Run `python -m pytest server/collaboration/tests/test_stream.py -q` and `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/collaboration_ui_test.dart`.

### Wave 9 — Integrated verification and release-readiness review

**Depends on:** Waves 0–8.

**Paths:** Create `server/collaboration/tests/test_integration.py`, `test/collaboration_integration_test.dart`, `server/collaboration/README.md`; modify `server/account/README.md` and the relevant deployment/runbook documentation.

- [ ] Run server unit, repository, API, lifecycle, cleanup, stream, and integration suites against fake identities and disposable local PostgreSQL only.
- [ ] Run Flutter collaboration suites with the shared lock and concurrency one, plus targeted static analysis.
- [ ] Exercise two independent server instances for atomic capacity, ordered append, rate limits, lease invalidation, and revocation propagation.
- [ ] Assert distinctive transcript, token, endpoint, credential, request-body, and raw-error sentinels are absent from logs, traces, errors, metrics labels, and exports.
- [ ] Review the final diff for production-code scope, schema/migration parity, lifecycle cleanup coverage, and the invariant that no receiving event can execute work.

## Completion criteria

The implementation is ready for separate review only when every wave's focused
tests pass, integration tests prove the hard 10-person capacity invariant and
ordered cursor replay, lifecycle tests prove stale callbacks cannot publish,
and execution-isolation tests prove that remote events never cause local or
server-side work. Activation, deployment, and production migration remain
separate decisions after this plan is implemented and reviewed.
