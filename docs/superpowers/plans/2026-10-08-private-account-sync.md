# Private Account Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use superpowers:subagent-driven-development only if delegation is explicitly requested. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let explicitly enrolled devices view the same account's private transcripts, portable provider metadata, observational usage, and inert activity, with durable delivery and deterministic deletion.

**Architecture:** Add a typed sync domain mounted by the existing account runtime, using account PostgreSQL for records, change sequences, enrollment, quotas, and leases. Flutter owns separate DTOs, account-scoped projections, a durable outbox, an authenticated client, and a foreground coordinator. Execution stays on the initiating device; receiving records only updates presentation.

**Tech Stack:** Python, FastAPI, psycopg/PostgreSQL, pytest/httpx; Dart/Flutter, existing HTTP/filesystem/crypto facilities, fake clocks and loopback transports. RFC 8785 canonical UTF-8 JSON and gzip are protocol requirements, not interchangeable with ordinary JSON serialization.

**Normative specs (read both in full):**
- `docs/superpowers/specs/2026-10-08-private-account-sync-design.md`
- `docs/superpowers/specs/2026-10-08-device-activity-feed-design.md`

**Status:** Planning deliverable only. This document does not authorize production implementation, endpoint activation, migration execution against deployed databases, deployment, or commits. Commands below are future local TDD instructions, not commands run while authoring this plan.

## Global constraints

- No hosted execution. No server, receiving client, sync callback, replay, reconnect, retry, or compactor may start/resume/retry a model request, tool, MCP/plugin operation, browser action, build, clone, shell process, or agent orchestration. Existing remote provider/MCP behavior is outside sync.
- No credential synchronization/restoration: API keys, cookies, grants, auth headers, refresh tokens, and endpoint userinfo are excluded. Credentials must be re-entered locally. Do not sync local credential-presence flags as evidence of availability on another device.
- Preserve complete private transcript text, including secret-like text. Do not use `server/shares/snapshot.py`, public-share filtering, raw session JSON, or runtime/session reconstruction as the private contract. Transcript text is not secret-free.
- DTOs are closed, exact camelCase, integer `schemaVersion: 1`; reject unknown/missing fields, wrong types, invalid bounds, unpaired surrogates, NaN/Infinity. Upload omits `accountId` and `changeSequence`; server replay supplies them. Copy every payload field/bound/enum from the normative account spec, including nullable fields.
- RFC 8785 canonical UTF-8 bytes are used for hashing, persistence, replay, and quota accounting; key order follows UTF-16, not Python Unicode code-point ordering. Integer validation must reject booleans in Python.
- Gzip is the required v1 codec. Limits: **1 MiB compressed request; 8 MiB canonical decompressed batch; 100 records/batch; 256 KiB canonical/record; 10,000 accepted records/rolling 24 hours; 100 MiB retained canonical/account**. Compression/splitting does not increase allowance. Duplicates are not charged twice; rejected records are not charged; deletion/conflict tombstones remain admissible when retained bytes are full.
- Limits: **10 enrolled devices; 60 uploads/minute/account; 30 uploads/minute/device; 120 replay requests/minute/account; 2 streams/account; 1 stream/device**. Use shared durable enforcement, not process-local counters in a stateless API tier.
- Primary transport is foreground polling: immediate resume/refresh, **15 seconds** connected interval, exponential **2–60 seconds with full jitter**, stale after **45 seconds**, at most **100 changes and 256 KiB canonical response bytes/page**, drain `has_more`, UI repaint at most once/**250 ms**.
- SSE is optional after a successful poll: exact feed-spec framing, **512-byte** maximum cursor query, heartbeat every **30 seconds**, close after **15 minutes or 1 MiB total event data**. Disable after **three failures in five minutes**, retry at next foreground resume. Correctness must pass with SSE disabled.
- Tombstones last **30 days after the last cursor that could reference them expires**, not 30 days from deletion. Account tombstones are permanent. Activity detail may compact after 30 days; required transcript/usage stays restorable and compaction is replay-visible and quota-transactional.
- Authentication, App Check, account admission/generation fencing, enrollment and revocation apply to every endpoint and every publication. Self-revocation requires fresh account reauthentication. Cursors are positions, never credentials.
- Responses, including errors and SSE, are private with `Cache-Control: no-store`. No payloads, transcripts, endpoints/URLs/query strings, auth headers, cookies, raw errors, or request bodies in logs/traces/analytics/support exports. Only approved metrics and rotating-secret account/device hashes.
- Preserve unrelated working-tree changes. This checkout already has edits in `lib/core/state.dart`, `lib/core/agent_service.dart`, reset/usage/UI files and tests. Re-read those files before future integration; do not revert them or treat this plan as permission to replace them.
- No production calls, paid calls, credential printing, hosted execution, deployments, pushes, or commits. Tests use fake identities, fake clocks, local temporary storage and loopback services only. No new public sharing behavior or encrypted credential-sync design is included.

## Context and prerequisite decisions

The older `docs/superpowers/specs/2026-10-08-private-activity-sync-draft.md` is **non-normative**. Its snake_case envelope, optional unknown-field handling and SSE-first proposal must not enter implementation.

Existing integration points:
- `server/account/runtime.py:build/create_app` builds the lifecycle and mounts shares. `server/shares/runtime.py:mount_shares` demonstrates authenticated admission held through repository work; reuse the admission pattern, not share DTO/filtering.
- `server/account/postgres.py:PostgresStore.locked` owns session advisory UID locks; `server/account/domain.py:Lifecycle.access` gates account access. Keep the account lock through the short repository operation; do not hold it across a long-lived stream.
- `server/account/composition.py:CleanupData.required_deletion_steps` supplies mandatory cleanup checkpoints even for old aggregate `data` checkpoints. Add sync explicitly.
- `server/account/stores.py` describes image/share SQLite authorities. Sync uses the account PostgreSQL authority, not another incidental SQLite store or Redis cache. Do not change the image/share configuration format simply to mount sync.
- `lib/core/account_session.dart`, `lib/core/firebase_service.dart`, `lib/ui/login_gate.dart` own authentication/readiness. `lib/core/state.dart`, `lib/core/usage_attempt_store.dart`, and `lib/core/reset_coordinator.dart` own account-local data/lifecycle. `lib/core/session_ledger.dart` also contains recovery data and is not safe to serialize wholesale.
- Account restore consent is a separate prerequisite: `docs/superpowers/specs/2026-10-08-account-restore-consent-design.md`. Current `/account/login` and `/account/deletion/cancel` share the mutating handler; sync must never call either to restore readiness implicitly. Integration/activation depends on observational login and explicit restore consent being fixed and verified independently.

### Task 0 — Freeze interoperability fixtures and resolve spec gaps

**Dependencies:** None. Independent pure DTO tests may proceed from unambiguous fields, but affected wire/repository features cannot be accepted until this task's decisions are approved.

**Files:** Create `server/sync/CONTRACT.md`, `test/fixtures/private_sync/v1.json`, `server/sync/tests/test_contract_vectors.py`, `test/private_sync_contract_vectors_test.dart`. Propose corrections in the two normative spec paths above only with separate approval; this planning task does not modify them.

- [ ] Record the following discrepancies and obtain explicit contract decisions instead of silently widening v1:
  1. Feed JSON and account payload require `updatedAt`, but the feed's prose “exact payload fields” omits it. Recommend keeping required `updatedAt` as both concrete DTOs show.
  2. `reset_required` and SSE HTTP 410/409 are required by feed/replay semantics but absent from the account error-code enumeration. Define the approved reset response and cursor-conflict code without inventing another error envelope.
  3. Define batch/request/result, enrollment/consent/idempotency, state/bootstrap, cursor acknowledgement, retention-marker and compaction-summary envelopes; their shapes are not specified. In particular, bounded `/state` summaries plus a current cursor alone cannot restore older transcripts: approve paginated consistent snapshot hydration before advancing to the live cursor, within the existing routes.
  4. Define record revision bounds and immutable/mutable field matrix for all five record types, envelope identity fields, reference validation, equal-revision differing mutable data, tombstone-target rules, and deletion-versus-late-update precedence. Transcript message ID, kind, text and parent are already immutable; never relax them.
  5. Define cursor lifetime/expiry, snapshot retention across pages, lease expiry, and SSE heartbeat timeout. These affect the 30-days-after-last-cursor tombstone horizon and must be shared by server/client tests.
  6. Reconcile “one 256 KiB record” with “256 KiB canonical response including wrapper”: define progress/individual hydration behavior when wrapping a maximum-size record exceeds a page. Do not spin on an empty `has_more` page, truncate text, or silently lower a normative quota.
  7. Specify canonical byte charging for upload versus server-enriched replay, compressed decode resource ceilings before validation, count charging for accepted updates, idempotency-key scope/lifetime, and how the 10-device limit maps to the closed error set.
- [ ] Store approved examples for all five upload/replay DTOs, errors, poll page (`next_cursor`/`has_more`) and SSE data (`nextCursor`/`hasMore`); normalize only inside client types. Include Unicode, non-BMP key sorting, explicit zero versus null, secret-like private text, malicious endpoint, and unknown-field rejection.
- [ ] Add tests reading the same fixture file in both languages. Use exact expected canonical bytes/digests rather than independently deriving both “expected” and “actual” from the same serializer.

```python
# server/sync/tests/test_contract_vectors.py
def test_canonical_vectors_match_shared_fixture():
    import json
    from pathlib import Path
    from server.sync.canonical import canonical_bytes
    vectors = json.loads(Path('test/fixtures/private_sync/v1.json').read_text())
    for vector in vectors['canonical']:
        assert canonical_bytes(vector['value']).decode('utf-8') == vector['utf8']
```

**TDD:** `python -m pytest server/sync/tests/test_contract_vectors.py -q` and `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/private_sync_contract_vectors_test.dart`. Initially fail for missing codecs; pass after Tasks S1/F1. Record decisions and review, not a commit. Fixture agreement is not a replacement for resolving the listed ambiguities.

## Work breakdown and dependency graph

Server owns `server/sync/` and account runtime/router/schema/migration integration. Flutter owns `lib/core/private_sync/`, the account/reset hooks, and UI. Test files listed below are new unless explicitly called existing. Source files listed as create do not exist at planning time.

```text
0 -> S1 -> S2 -> S3 -> S4 -> S5
                       \----------> S6 (also needs S4/S5 for final lifecycle tests)
0 -> F1 -> F2 -> F3
       \------> F4 (S4 contracts) -> F5 (F2/F3 and S5 contracts)
F1/F3 -> F6 (existing request accounting prerequisite)
F2/F5/F6 + S6 + restore-consent prerequisite -> F7 -> F8
S1..S6 + F1..F8 -> V1
```

S/F lanes can be implemented independently against approved fixtures. Do not modify shared `state.dart`, account runtime/composition, or UI entry points concurrently. Each task follows red → minimal implementation → green → focused review; there are no commit steps.

## Server lane — account authority, router, schema, migrations

### Task S1 — Closed records, endpoint policy, canonical codec and errors

**Depends on:** 0 for resolved contract details.

**Create:** `server/sync/__init__.py`, `server/sync/dto.py`, `server/sync/canonical.py`, `server/sync/endpoints.py`, `server/sync/errors.py`, `server/sync/tests/test_dto.py`, `server/sync/tests/test_endpoints.py`.

**Interfaces:** `parse_upload(value: object) -> UploadRecord`; `parse_replay(value: object) -> ReplayRecord`; immutable typed payload classes for transcript/providerMetadata/usage/activity/tombstone; `canonical_bytes(value: object) -> bytes`; `validate_endpoint(value: str, provider_id: str) -> str`; `SyncError(code, retry_after_seconds=None)` with fixed non-sensitive messages and exact error serializer. These names are shared with later server tasks.

- [ ] Write parameterized tests for every required/unknown field, type, enum and inclusive bound in the normative DTOs; distinct upload/replay key sets; valid UTC timestamps; ASCII IDs; scalar rather than UTF-16 text length; null versus zero; version integer 1 versus `true`/`1.0`.
- [ ] Run `python -m pytest server/sync/tests/test_dto.py server/sync/tests/test_endpoints.py server/sync/tests/test_contract_vectors.py -q`; confirm failures describe missing parser/codec behavior.
- [ ] Implement immutable DTOs and RFC 8785 codec; no `json.dumps(sort_keys=True)` substitute. Since v1 DTO numbers are bounded integers, test that narrower domain while proving RFC string escaping/UTF-16 ordering. Reject duplicate JSON keys at request decode. Canonicalize endpoints before persistence and on import: explicit provider scheme policy, no userinfo/fragments/control characters, case-insensitive and percent-decoded sensitive query-key checks plus provider equivalents, normalized host/port/path/non-secret query.
- [ ] Prove private text survives verbatim while runtime fields and unsafe endpoints fail; errors never interpolate input. Example assertions:

```python
record = parse_upload(vectors['privateTranscriptUpload'])
assert record.payload.text == vectors['privateTranscriptText']
assert canonical_bytes(record.to_wire()) == vectors['privateTranscriptCanonical'].encode()
with pytest.raises(SyncError):
    parse_upload({**vectors['privateTranscriptUpload'], 'runtimeQueue': []})
```

- [ ] Rerun the command to PASS. Review imports: DTO/storage domain cannot import executor, public snapshot, provider request or process modules.

### Task S2 — PostgreSQL authority and explicit schema migrations

**Depends on:** S1; approved identity/revision/cursor/quota matrix from 0.

**Create:** `server/sync/repository.py`, `server/sync/postgres.py`, `server/account/migrations/003_private_sync.sql`, `server/sync/tests/test_repository.py`, `server/sync/tests/test_postgres.py`. **Modify:** `server/account/schema.sql` (fresh installs).

**Interfaces:** `SyncRepository.admit_batch(uid, device_id, idempotency_key, records) -> BatchResult`; `changes(uid, device_id, cursor, limit=100, max_bytes=262144) -> ChangePage`; `bootstrap(uid, device_id, cursor=None) -> StatePage`; `delete_account(uid) -> None`. `BatchResult`, `ChangePage`, `StatePage` are typed structures frozen in 0, not generic runtime maps. `PostgresSyncRepository` implements these interfaces using the account database DSN.

- [ ] Add repository contract tests (in-memory fake for domain tests; real local PostgreSQL for transactional evidence): at-least-once duplicate, stale revision, equal/different immutable identity, mutable update, rollback, two concurrent writers, sequence ordering, lost response/restart, same ID in different accounts, no owner override.
- [ ] Run `python -m pytest server/sync/tests/test_repository.py server/sync/tests/test_postgres.py -q`. PostgreSQL tests use an explicitly supplied **local disposable** `SYNC_TEST_DATABASE_URL`; no fallback to `ACCOUNT_DATABASE_URL`. Missing local PostgreSQL is a reported blocked integration check, never a claimed pass.
- [ ] Add tables/indexes for `sync_accounts` (sequence/permanent fence), `sync_devices`, `sync_records`, `sync_changes`, `sync_idempotency`, `sync_ingest`, `sync_cursors`, `sync_leases`, `sync_rate_windows`, `sync_conflicts`, `sync_retention_markers`. Key all user rows by UID; unique `(uid, record_id)` and `(uid, change_sequence)`. Store canonical bytes plus digest and typed lookup columns; JSONB reserialization must not change replay bytes. Store safe conflict identities/revisions/digests rather than logging payloads.
- [ ] Allocate change sequence, mutate record, append change, account quota and idempotency result in one transaction. Failed admission must not consume quota or publish a sequence. Preserve canonical revision on duplicate. Hard conflict never chooses a winner or silently merges text.
- [ ] Make schema and migration definitions equivalent; tests apply fresh schema and upgrade a pre-sync schema, verify preserved lifecycle rows, constraints, and second-apply behavior. No automatic startup DDL or production migration command.

```python
first = repository.admit_batch(uid, device, 'batch-1', [record])
again = repository.admit_batch(uid, device, 'batch-1', [record])
assert first == again
assert repository.bootstrap(uid, device).accepted_record_count == 1
```

`accepted_record_count` above is a test projection on `StatePage` only if approved by 0; otherwise assert through repository test inspection, never add a wire field for testing.

- [ ] Rerun focused tests to PASS, including two independent connections/processes; a fake repository cannot prove database serialization.

### Task S3 — Quotas, enrollment, revocation and cursor/retention policy

**Depends on:** S2.

**Create:** `server/sync/policy.py`, `server/sync/retention.py`, `server/sync/tests/test_policy.py`, `server/sync/tests/test_retention.py`. **Modify:** `server/sync/repository.py`, `server/sync/postgres.py` (policy transactions).

**Interfaces:** `SyncRepository.enroll(uid, consent, device_name, idempotency_key) -> DeviceEnrollment`; `revoke(uid, requester_device_id, target_device_id, idempotency_key, fresh_auth) -> None`; `SyncRetention.compact(uid, now) -> None`; clock and randomness injected. `DeviceEnrollment` exposes server-issued ID/name/creation and authorization metadata approved in 0.

- [ ] Write failing tests: missing consent, server ownership, 10th/11th device, idempotent enrollment, self-revoke without fresh auth, cross-account revoke, lost-device revoke via authenticated security surface, never-recycled IDs, and invalidated existing leases.
- [ ] Write boundary tests for all byte/count/rate quotas at limit and limit+1, Unicode canonical bytes, rolling 24-hour expiry, duplicates, updates, partial batch outcomes, full retained quota admitting deletion/conflict tombstones, and shared counters across API instances.
- [ ] Run `python -m pytest server/sync/tests/test_policy.py server/sync/tests/test_retention.py -q` and confirm red assertions before implementing policy.
- [ ] Enforce quotas and enrollment under serialized account admission. Return per-record accepted/duplicate/rejected/conflict/retryable results; typed quota errors carry bounded retry time (oldest ingest admission expiry where applicable). Provider endpoint rejection affects its record, not otherwise valid siblings.
- [ ] Implement opaque account-bound cursor positions/expiry and consistent bounded bootstrap from 0. Reject malformed/expired cursors with the approved reset response. Compact activity older than 30 days into approved inert per-request summaries, transactionally emit markers and adjust quotas; retain required transcript/usage and tombstones through their cursor-aware horizon. Explicit user-visible retention only for canonical transcript/provider history.

```python
with pytest.raises(SyncError) as failure:
    repository.enroll(uid, False, 'phone', 'no-consent')
assert failure.value.code == 'invalid_request'
```

- [ ] Rerun to PASS; prove older upload/page cannot resurrect a tombstoned ID, and revocation does not delete account records.

### Task S4 — Authenticated bounded sync router and account runtime composition

**Depends on:** S1–S3.

**Create:** `server/sync/api.py`, `server/sync/runtime.py`, `server/sync/tests/test_api.py`, `server/sync/tests/test_runtime.py`. **Modify:** `server/account/runtime.py:create_app/build`, `server/account/composition.py:CleanupData.__init__` to accept the sync authority for both API and worker. Existing dependencies suffice unless the canonical codec requires a reviewed dependency; then pin it in `server/account/requirements.txt` and document why.

**Interfaces:** `router(repository, verify, admission) -> APIRouter`; `mount_sync(app, repository, lifecycle, admin) -> None`. Verification uses the existing Admin/App Check interface; admission holds `Lifecycle.access` through each short read/write transaction. Repository inputs receive server-derived UID, never request-supplied account identity.

- [ ] Add route tests for `POST /sync/v1/records`, `GET /sync/v1/changes`, `GET /sync/v1/state`, `POST /sync/v1/devices`, `DELETE /sync/v1/devices/{device_id}`: missing identity/App Check, wrong owner/device, no consent, absent mutation key, pending/fenced/deleted account, revoked device, bounded pages and strict body validation.
- [ ] Run `python -m pytest server/sync/tests/test_api.py server/sync/tests/test_runtime.py -q`; confirm missing route/behavior failures.
- [ ] Decode gzip with incremental bounds; reject oversized compressed/body-count limits early and measure quotas only on validated canonical records. Reject malformed/trailing compression and decompression resource abuse according to 0; preserve individual oversized-record partial results in an otherwise valid batch. Replace framework validation errors with the closed safe error DTO (no echoed body/value). Set no-store on success and failure.
- [ ] Mount only from explicit account factory composition behind disabled-by-default sync activation. Importing modules must not connect, provision, migrate or start background jobs. Validate schema readiness at explicit startup; use the same repository authority for API and cleanup worker. Do not repurpose share storage or alter `/account/login` semantics here.

```python
response = client.post('/sync/v1/records', content=b'not-gzip')
assert response.headers['cache-control'] == 'no-store'
assert set(response.json()) == {'schemaVersion', 'code', 'message', 'retryAfterSeconds'}
```

- [ ] Test log/trace capture with distinctive transcript/token/endpoint sentinels; none may appear. Configure allowed route/status/latency/quota/cursor/error metrics with rotating-secret identity hashes; disable body/query logging in the documented proxy policy. Rerun to PASS.

### Task S5 — Optional foreground stream gateway

**Depends on:** S4 and approved stream lease/timeout details from 0.

**Create:** `server/sync/stream.py`, `server/sync/tests/test_stream.py`. **Modify:** `server/sync/api.py` (stream route), `server/sync/postgres.py` (cross-instance leases).

**Interfaces:** `GET /sync/v1/activity/stream?cursor=...` reuses verified admission, repository changes and shared leases. Stream event content is exactly `changes`, `reset_required`, or the specified heartbeat comment; no runnable callbacks in repository APIs.

- [ ] Write fake-clock/ASGI tests for cursor 512/513 bytes, exact LF frames, MIME/no-store, application schema and bounds, 30-second heartbeat, 15-minute/1-MiB close, per-device/account stream limits, and authentication/reset HTTP mappings approved in 0.
- [ ] Run `python -m pytest server/sync/tests/test_stream.py -q` and confirm red.
- [ ] Implement bounded event encoding and shared revocable leases. Acquire account lock for each authorization/page read, release before awaiting network output; propagate revocation/fence invalidations across API instances, recheck before every publication, cancel pending writes, release leases on all closes. Never hold deletion's UID lock for the stream lifetime.

```python
assert heartbeat_bytes == b': heartbeat\n\n'
assert b'\nid:' not in changes_bytes
assert b'\nretry:' not in changes_bytes
```

- [ ] Prove revocation/fence stops already-open streams and leased polls, `hasMore` requires polling, slow consumers cannot grow unbounded buffers, and no application error frames are invented. Rerun to PASS.

### Task S6 — Mandatory deletion cleanup, retention wiring and migration runbook

**Depends on:** S2–S5.

**Modify:** `server/account/composition.py:required_deletion_steps/prepare/validate_context`, `server/account/runtime.py:build`, `server/account/retention.py`, `server/account/README.md`, `server/account/DEPLOYMENT.md`. **Create:** `server/sync/README.md`, `server/sync/tests/test_cleanup.py`. **Extend existing tests:** `server/account/tests/test_worker.py`, `server/account/tests/parallel_account_cleanup_test.py`.

**Interfaces:** mandatory named `private_sync` cleanup checkpoint calls `SyncRepository.delete_account(uid)`. Persist/bind sync authority identity and schema version in cleanup context with an explicit compatibility transition for pre-sync in-progress jobs; mismatched authorities fail closed. Account tombstone remains sufficient to reject every late request.

- [ ] Add tests for cleanup after old aggregate `data` checkpoints, worker restart between sync cleanup and Auth deletion, failure/retry, changed authority identity, fenced late upload/poll/SSE, and old account writes after deletion.
- [ ] Run `python -m pytest server/sync/tests/test_cleanup.py server/account/tests/test_worker.py server/account/tests/parallel_account_cleanup_test.py -q`; confirm expected failures.
- [ ] Under durable account fence, invalidate leases then remove all private records/change logs, metadata, usage/activity, enrollment, cursors, idempotency/outbox-equivalent delivery state, indexes/cache projections, quotas and conflicts. Persist only reviewed permanent account tombstone metadata. Cleanup is idempotent; Firebase deletion stays after all mandatory data/key checkpoints. No new finalize endpoint or execution worker.

```python
assert 'private_sync' in dict(cleanup.required_deletion_steps())
assert admin.deleted_uids == []  # injected sync cleanup failure
```

- [ ] Wire scheduled retention as inert database maintenance through existing explicit retention entry point; document schema-first/API-worker compatibility, backups, cursor/tombstone horizons, redacted proxy settings and local staging verification. Never execute activation/migrations during this plan task.
- [ ] Rerun to PASS. Regression-test existing account/share/image cleanup authority semantics; report any prerequisite consent defect separately.

## Flutter lane — DTO, projection store, outbox, client, coordinator, UI

### Task F1 — Portable immutable DTOs and endpoint/JCS parity

**Depends on:** 0; interoperates with S1 without depending on a running server.

**Create:** `lib/core/private_sync/dto.dart`, `lib/core/private_sync/canonical.dart`, `lib/core/private_sync/endpoint_policy.dart`, `lib/core/private_sync/protocol.dart`, `test/private_sync_dto_test.dart`, `test/private_sync_endpoint_policy_test.dart`.

**Interfaces:** `SyncUploadRecord.fromJson`, `SyncReplayRecord.fromJson`, typed payload classes and `toJson`; `canonicalSyncBytes(Object value) -> Uint8List`; `canonicalProviderEndpoint(String value, String providerId) -> String`. `protocol.dart` defines approved `SyncBatchResult`, `SyncChangePage`, `SyncStatePage`, `SyncEnrollment`, `SyncFailure` and normalizes poll/SSE naming internally without changing wire spellings.

- [ ] Add shared-fixture and field-boundary tests, including supplementary Unicode, lone surrogate rejection, huge/negative integers, booleans as numeric values, unsupported versions, wrong replay owner and upload-supplied server fields.
- [ ] Run `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/private_sync_dto_test.dart test/private_sync_endpoint_policy_test.dart test/private_sync_contract_vectors_test.dart`; confirm red.
- [ ] Implement immutable closed types and codec. Endpoint import is validated again; never hydrate `ProviderConfig` from a generic network map. Preserve transcript text; reject extra `apiKey`, `path`, `runtimeQueue`, `attachmentBytes` fields rather than “sanitizing” raw sessions.

```dart
expect(SyncUploadRecord.fromJson(privateTranscript).toJson(), privateTranscript);
expect(() => SyncUploadRecord.fromJson({...privateTranscript, 'apiKey': 'x'}),
    throwsFormatException);
```

- [ ] Rerun to PASS and confirm byte-for-byte parity with Python fixtures. Usage provenance is preserved, never converted to allowance or measured zero.

### Task F2 — Durable account-scoped typed projection and cache invalidation

**Depends on:** F1 and approved bootstrap/marker/tombstone semantics from 0.

**Create:** `lib/core/private_sync/store.dart`, `lib/core/private_sync/cache.dart`, `test/private_sync_store_test.dart`, `test/private_sync_cache_test.dart`.

**Interfaces:** `PrivateSyncStore.open(Directory accountRoot, bool Function() ownerFence)`; `applyPage(SyncChangePage page) -> Future<void>`; `installState(SyncStatePage page) -> Future<void>`; `clearAccount()`, `close()`; read-only `cursor`, `revision`, `records`. `PrivateSyncCache.invalidateRecord(String id)` and `clearAccount()` cover record, aggregate, conversation/activity, search, unread, last-activity projections. No AppState/runtime object deserializer.

- [ ] Write crash/reopen tests: failed write before cursor commit, duplicate page, reordering, stale/equal/higher revision, immutable conflict, wrong account, schema migration, compaction marker and deletion followed by stale page. Use injected persistence failure, not only an in-memory happy path.
- [ ] Run `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/private_sync_store_test.dart test/private_sync_cache_test.dart`; confirm red.
- [ ] Implement account-root typed persistence with flushed journal transactions/atomic snapshot replacement following `usage_attempt_store.dart` durability patterns. Validate complete page before apply, commit record changes/tombstones/cache revision/cursor together, keep previous cursor on failure; reject sequence regression. Keep deletion barriers independently of disposable presentation caches so reset cannot resurrect old records. Install complete consistent bootstrap before publishing its new cursor.

```dart
final before = store.cursor;
disk.failNextCommit = true;
await expectLater(store.applyPage(page), throwsA(isA<FileSystemException>()));
expect(store.cursor, before);
```

- [ ] Verify tombstones invalidate every listed derived cache; owner fence checked before durable write and after every asynchronous boundary. Reopen proves no partial commit. Rerun to PASS; store has no dependency on executors/session recovery.

### Task F3 — Durable outbox and delivery-only retry

**Depends on:** F1/F2.

**Create:** `lib/core/private_sync/outbox.dart`, `test/private_sync_outbox_test.dart`.

**Interfaces:** `PrivateSyncOutbox.enqueue(SyncUploadRecord record, String idempotencyKey) -> Future<void>`; `pendingBatch() -> Future<List<SyncOutboxEntry>>`; `acknowledge(SyncBatchResult result) -> Future<void>`; `clearAccount()`, `close()`. `SyncOutboxEntry` holds typed DTO/schema/source device/idempotency key/delivery state plus bounded retry metadata; never a callback or operation object.

- [ ] Write tests for restart before send, lost acknowledgement after server commit, partial batch results, retryable versus terminal rejection/conflict, durable keys/IDs, revoked old device, tombstone pruning of older queued writes, account switch during queued disk write, and outbox disk failure.
- [ ] Run `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/private_sync_outbox_test.dart`; confirm red.
- [ ] Persist before acknowledging enqueue; retry canonical DTO with the same key/ID. Accepted/duplicate terminal acknowledgement removes delivery work durably; rejection/conflict remains visible as a terminal diagnostic without automatic resubmission. Retryable outcomes stay queued with bounded retry scheduling. Never mint a new execution attempt on delivery retry. Pause/quarantine old-device entries after revocation; re-enrollment must not replay them under the revoked ID.

```dart
await outbox.enqueue(record, 'stable-key');
await outbox.close();
final pending = await reopened.pendingBatch();
expect(pending.single.idempotencyKey, 'stable-key');
expect(pending.single.record.recordId, record.recordId);
```

- [ ] Prove offline persistence and duplicate acknowledgement are idempotent and quota-limited batch formation does not truncate an oversized record. Rerun to PASS.

### Task F4 — Authenticated HTTP/gzip client and strict SSE parser

**Depends on:** F1, approved S4/S5 protocol fixtures.

**Create:** `lib/core/private_sync/client.dart`, `lib/core/private_sync/sse.dart`, `test/private_sync_client_test.dart`, `test/private_sync_sse_test.dart`.

**Interfaces:** `PrivateSyncClient` accepts injectable HTTP client/base URI, `idToken(bool forceRefresh)`, App Check, and account-generation guard. Methods `enroll`, `revoke`, `upload`, `changes`, `state`, `activityStream` return F1 typed responses/stream events. `SyncSseDecoder` accepts bounded byte chunks and emits validated change/reset events; heartbeat is transport metadata only.

- [ ] Add loopback/mock HTTP tests for auth headers, gzip, idempotency keys, no transcript in URL, all typed errors, malformed/sensitive server body, stale same-UID generation response, mixed batch results, and no accidental restore route calls.
- [ ] Add chunk-split SSE tests across UTF-8 and line boundaries, unknown event/fields, duplicate `event`/`data`, forbidden `id`/`retry`, invalid JSON/version, multiline data and byte overflow. Require exact application frames and heartbeat shape.
- [ ] Run `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/private_sync_client_test.dart test/private_sync_sse_test.dart`; confirm red.
- [ ] Implement bounded response reads, strict validation, safe fixed error mapping, injectable cancellation, identity/generation checks before request and publication, canonical gzip upload. Validate endpoint on imported provider metadata. Bad SSE frame is discarded and stream closed; retain last applied cursor for polling.

```dart
expect(request.headers['Authorization'], 'Bearer fake-token');
expect(request.headers['Content-Encoding'], 'gzip');
expect(request.url.query, isNot(contains(privateTextSentinel)));
expect(cancelRouteCalls, 0);
```

- [ ] Rerun to PASS; private DTO/client exceptions must not print raw response bodies or tokens. No live API/model requests.

### Task F5 — Foreground polling coordinator and optional SSE optimization

**Depends on:** F2/F3/F4; approved timeout from 0.

**Create:** `lib/core/private_sync/coordinator.dart`, `test/private_sync_coordinator_test.dart`, `test/private_sync_delivery_inertness_test.dart`.

**Interfaces:** `PrivateSyncCoordinator` consumes client/store/outbox plus fakeable clock, jitter and lifecycle/connectivity inputs. Methods `bindAccount`, `setForeground(bool)`, `refresh()`, `revoke()`, `stop()`, `dispose()`; exposes delivery status and coalesced projection revision. All callbacks capture account generation. No execution-service dependency.

- [ ] Write deterministic fake-clock tests for immediate foreground/refresh, 15-second cadence, serialized polls, 100/256-KiB pages, immediate `has_more` draining, 2–60-second full-jitter retry/reset, 45-second stale label, and 250-ms repaint coalescing.
- [ ] Test polling alone first; then SSE after first successful poll, heartbeat timeout, disconnect/platform rejection/network transition, malformed frame, three failures/five minutes, next-resume re-enable and fallback without cursor advancement. An auth failure still gates delivery pending valid auth; fallback must not bypass authorization.
- [ ] Run `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/private_sync_coordinator_test.dart test/private_sync_delivery_inertness_test.dart`; confirm red.
- [ ] Implement one reconciliation path for poll/SSE; apply page transaction before moving cursor, bootstrap on reset, maintain stable-ID reconciliation and outbox while offline. Stop timers/streams on background/logout/revocation/fence, fence late callbacks, clear disposable caches before installing new account state. Account-level terminal failures stop delivery rather than retrying forever.

```dart
clock.elapse(const Duration(seconds: 45));
expect(coordinator.status.isStale, isTrue);
expect(executionSpy.dispatchCount, 0);
```

- [ ] Inertness test mounts actual client/store/coordinator with execution-boundary spies and sends request/tool/MCP/plugin/browser/build activity, secret-like transcript, duplicates, reconnect and restart. All dispatch counts stay zero; at least one projection must change so the test is not vacuous. Rerun to PASS.

### Task F6 — Device-originated export adapters, not runtime replay

**Depends on:** F1/F3 and existing request-accounting model/store completion from `docs/superpowers/plans/2026-10-08-request-accounting.md`.

**Create:** `lib/core/private_sync/exporter.dart`, `lib/core/private_sync/activity_recorder.dart`, `test/private_sync_exporter_test.dart`, `test/private_sync_activity_recorder_test.dart`. **Modify narrowly:** `lib/core/state.dart` (committed transcript/provider/usage observation), `lib/core/session_ledger.dart` (typed observation hook only), `lib/core/agent_service.dart` (device-side lifecycle observations only).

**Interfaces:** `PrivateSyncExporter` converts explicit transcript fields, validated metadata and `UsageAttempt` snapshots to F1 DTOs; `PrivateActivityRecorder.record` accepts typed kind/status/IDs/timestamps/bounded safe presentation fields and enqueues inert activity. Both require enrolled-device/account-generation context and persist stable export-ID mappings in the account sync journal.

- [ ] Write tests for complete private text, multiple attempts under one request, reported versus requested model, null/zero/provenance, stable IDs across restart/update, one enqueue on duplicate observation, and no local paths/commands/provider errors/credential maps exported.
- [ ] Run `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/private_sync_exporter_test.dart test/private_sync_activity_recorder_test.dart`; confirm red.
- [ ] Implement explicit field-by-field mapping; never call session `toJson()` as the export. Observe finalized local message text; locally edited accepted transcript becomes a new immutable message record rather than replacing text. Bound activity descriptions without exporting executable arguments. Source events may come from device request/tool/MCP/plugin/browser/build lifecycle, but network-received records never re-enter these observation hooks.

```dart
expect(exported.payload.text, localMessage.text);
expect(exported.toJson().containsKey('workspacePath'), isFalse);
expect(cloudAllowanceAfterImport, cloudAllowanceBeforeImport);
```

- [ ] Test imported usage is observational, imported IDs do not re-export/loop, provider credentials are not hydrated, and failures only mark sync delivery unhealthy rather than rerun operations. Rerun to PASS; reconcile edits with existing in-progress accounting changes.

### Task F7 — Account readiness, lifecycle/reset and app composition

**Depends on:** F2–F6/S6; independent restore-consent prerequisite verified before integration acceptance.

**Create:** `lib/core/private_sync/integration.dart`, `test/private_sync_account_lifecycle_test.dart`. **Modify:** `lib/core/state.dart` (account root/generation and disposal), `lib/core/reset_coordinator.dart` (canonical private-sync store), `lib/core/settings_state_integration.dart` (reset adapter), `lib/main.dart` (lifecycle wiring), `lib/ui/login_gate.dart` (post-readiness binding). **Extend existing:** `test/reset_account_signout_test.dart`, `test/reset_coordinator_test.dart`.

**Interfaces:** `PrivateSyncIntegration` owns one account-generation-scoped store/outbox/coordinator bundle. Receives confirmed account readiness and device enrollment; does not acknowledge login or cancel deletion itself. Reset adapter stages/stops, deletes, verifies disk/cache erasure, and rolls back only non-destructive prepare effects according to existing reset contracts.

- [ ] Write tests for no bind before account-ready + explicit enrollment, account A→B, logout/login same UID, revocation, fence, schema migration, reset-required, reset abort/failure and late disk/HTTP/SSE callbacks.
- [ ] Run `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/private_sync_account_lifecycle_test.dart test/reset_account_signout_test.dart test/reset_coordinator_test.dart`; confirm red sync-specific assertions.
- [ ] Stop producers and transport before flushing/closing old account stores. Clear account-keyed records/aggregates/search/activity/unread caches before publishing new state. On deletion/reset erase and verify outbox, cursor, enrollment and all projections; ordinary offline failure retains outbox. Revocation prevents queued writes and clears revoked-device views without deleting server account records.

```dart
await integration.signOut();
latePoll.complete(oldAccountPage);
await pumpEventQueue();
expect(newAccountView.records, isEmpty);
expect(cancelDeletionCalls, 0);
```

`signOut()` is the integration's app-side account teardown entry point; implement it as `stop`/close/cache-clear orchestration, not a server mutation.

- [ ] Wire foreground callbacks only after ready/enrolled; no background execution promise. Rerun to PASS and inspect for same-UID generation races and missing canonical reset-store enumeration.

### Task F8 — Consent/device management, read-only restored views and conflict UI

**Depends on:** F7; S3/S4 enrollment/error contract.

**Create:** `lib/ui/private_sync_settings_screen.dart`, `lib/ui/private_activity_screen.dart`, `lib/ui/private_conversation_screen.dart`, `lib/ui/private_sync_conflict_sheet.dart`, `test/private_sync_settings_screen_test.dart`, `test/private_activity_screen_test.dart`, `test/private_sync_conflict_sheet_test.dart`, `test/private_conversation_screen_test.dart`. **Modify:** `lib/ui/settings_screen.dart` (account navigation), `lib/ui/sidebar.dart` (private synced-view navigation). Keep synced views read-only rather than hydrating active `Session` execution state.

**Interfaces:** Widgets consume immutable projection snapshots, coordinator delivery status, enrollment metadata and explicit user-action callbacks. Conflict sheet consumes safe local/canonical IDs/revisions; keep-local invokes exporter with a new stable record/message ID on the initiating device, never overwrites conflicted identity or starts execution.

- [ ] Add widget tests for scope disclosure before enrollment (complete private transcript may include secrets, metadata/usage/activity, device-local execution and local key re-entry), cancelled consent, 10-device limit, list/revoke/lost-device management, fresh self-reauthentication, local credential availability only, and enrollment failure remaining unenrolled.
- [ ] Add tests for server sequence then record-ID ordering, grouped activity, event time distinct from replay order, stale/disconnected/offline/retry/quota/conflict states, unknown usage, compacted-detail marker, tombstone removal/unread/search invalidation, and private transcript including secret-like text.
- [ ] Run `flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/private_sync_settings_screen_test.dart test/private_activity_screen_test.dart test/private_sync_conflict_sheet_test.dart test/private_conversation_screen_test.dart`; confirm red.
- [ ] Implement explicit consent and reauthentication flows; never make mere sign-in enroll a device or restore an account. Show **“Sync conflict — transcript unchanged”**, local/canonical IDs and revisions without transcript quotes; actions exactly **“Keep canonical”**, **“Keep local as a new message”**, **“Dismiss”**. No overwrite action. Activity integrity conflict triggers canonical replay, not underlying work.

```dart
expect(find.text('Sync conflict — transcript unchanged'), findsOneWidget);
expect(find.text('Overwrite'), findsNothing);
expect(find.text(secretTranscriptInConflict), findsNothing);
```

- [ ] Verify keep-local adds a new identity without changing the canonical message, keep-canonical resolves local pending delivery, dismiss preserves canonical text, and restored UI cannot run tools/recover queues. Rerun to PASS.

## Task V1 — Cross-lane verification and completion report

**Depends on:** All server/Flutter tasks plus approved contract decisions and readiness prerequisite.

**Create:** `server/sync/tests/test_two_device_contract.py`, `test/private_sync_two_device_test.dart`. **Update:** `server/sync/README.md` with actual verification outcomes and remaining activation prerequisites; do not claim production readiness from fakes.

- [ ] Build a local two-device scenario: enroll, private transcript/metadata/usage/activity upload, offline retry, reordered replay, reconnect, conflict resolution with new ID, reset/bootstrap, compaction marker, tombstone, remote revocation, account fence and cleanup restart. Use shared contract vectors, a loopback server and disposable local PostgreSQL. Prove request/execution spies remain zero on the receiving side and server allowance is unchanged.
- [ ] Run new focused integration tests red before completing the final wiring, then green:

```bash
python -m pytest server/sync/tests/test_two_device_contract.py -q
flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter test --concurrency=1 test/private_sync_two_device_test.dart
```

- [ ] Run combined server regressions once after integration:

```bash
python -m pytest server/sync/tests server/account/tests server/shares/tests/test_shares.py -q
```

- [ ] Run the focused Flutter suites from F1–F8, grouped under the same `flock /tmp/opencode/parallel-flutter.lock` and `--concurrency=1`. Do not start a concurrent whole-repository suite. Run targeted analysis:

```bash
flock /tmp/opencode/parallel-flutter.lock /root/flutter/bin/flutter analyze lib/core/private_sync lib/ui/private_sync_settings_screen.dart lib/ui/private_activity_screen.dart lib/ui/private_conversation_screen.dart lib/ui/private_sync_conflict_sheet.dart lib/core/state.dart lib/core/reset_coordinator.dart lib/core/settings_state_integration.dart lib/main.dart lib/ui/login_gate.dart lib/ui/settings_screen.dart lib/ui/sidebar.dart lib/core/agent_service.dart lib/core/session_ledger.dart
git diff --check
git status --short
```

- [ ] Review import/call graphs for no sync→execution path; inspect serialized fixtures and captured diagnostics for excluded fields. Verify no public redaction is applied to private text and no private data is routed to share caches. Inspect local persistence crash evidence, multi-process quota/sequence tests, cleanup ordering and schema upgrade evidence.
- [ ] Report per-task test commands/results, skipped/blocked local PostgreSQL checks, unresolved contract approvals, restore-consent prerequisite status, and source/test completion separately from deployment/device verification. No production migrations, endpoints, credentials, hosted execution, commits or pushes are performed by this plan.

## Spec coverage / acceptance map

| Normative requirement | Tasks / evidence |
| --- | --- |
| Closed envelopes/payloads, exact types/bounds, full private text | 0, S1, F1, F6; shared golden vectors and unknown-field tests |
| Endpoint validation twice; no credentials/raw runtime serialization | S1, F1, F4, F6, F8; endpoint and exporter tests |
| Device-side execution and inert receipt/retry | S1–S6 import boundary, F2–F6 inertness spies, F8 read-only view, V1 |
| Auth, consent, enrollment limit, reauth, revocation/lost device | S3–S5, F4/F7/F8 |
| Stable IDs, revisions, immutable conflicts and conflict UX | 0, S2, F2/F3/F6/F8 |
| Replay ordering, reset and complete bounded bootstrap | 0, S2/S3, F2/F4/F5, V1 |
| Canonical quotas, gzip, rolling ingest, partial batches, rate limits | 0, S1–S4, F1/F3/F4 |
| Poll cadence, retry/stale/repaint bounds and drain semantics | F5 with polling-only tests |
| Exact optional SSE protocol, limits, fallback, lifecycle | 0, S5, F4/F5 |
| Transactional page/cursor apply and complete cache invalidation | F2/F5/F7/F8 |
| Tombstone horizons, compaction markers, no resurrection | 0, S2/S3/S6, F2/F3/F7, V1 |
| Server-owned deletion, permanent fence, cleanup before Auth | S4/S6, F7, V1; old-checkpoint and restart tests |
| Observational usage; server-owned allowance | S1, F1/F6/F8, V1 |
| No-store and redacted observability/error mapping | 0, S1/S4/S5, F4, V1 |
| Separate account runtime/router/schema/migration vs Flutter layers | S1–S6 vs F1–F8; explicit dependency graph above |

## Plan-authoring review

- The two approved specs are normative; the older draft supplies no implementation choices.
- Protocol gaps are identified in Task 0 rather than treated as settled. Affected features remain gated on approved resolutions; the rest of the implementation plan has exact paths, dependency boundaries and red/green commands.
- This artifact alone is the requested change. Future execution requires its own authorization; no implementation or commit is part of this planning task.
