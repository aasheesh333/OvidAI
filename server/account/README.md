# P3 account lifecycle — deployment artifact, NOT activated

The account app now directly composes the concrete PostgreSQL private-sync
repository, optional PostgreSQL/SQLite live collaboration, and image/share cleanup authorities.
`*_CONFIGURED` retains cleanup responsibility independently of `*_ACTIVATED`
HTTP routes. Stable authority UUIDs, bounded sync/PostgreSQL collaboration retention, a configuration CLI,
and Docker/systemd/Caddy templates are documented in [DEPLOYMENT.md](DEPLOYMENT.md).
Local code tests and deployment artifacts are not evidence of real activation.

`LIVE_COLLABORATION_BACKEND=sqlite|postgres` defaults to SQLite for existing
installations. PostgreSQL uses the same account database and lifecycle schema,
requires the UUID suffix of the persisted `collaboration:postgres:<uuid>` identity,
and rejects a configured SQLite path. Runtime does not migrate/provision PostgreSQL
or fall back to SQLite. See the deployment guide for exact fresh-schema, offline
SQLite import, full-process restart and rollback-boundary commands. Cleanup refuses
to resume across backend/authority changes or unbound legacy PostgreSQL contexts
without an explicit reconciliation plan.

This is real server code and executable fake-backed tests. It has **not** been
deployed or run against production users/databases. The Flutter deletion action
is visibly unavailable until built with `--dart-define=OVID_ACCOUNT_ENABLED=true`.
Do not enable that flag before the server and gateway integration below are ready.

## Ownership inspected (2026-10-03)

- `/opt/ovid-gateway/verifier/mint.py`: FastAPI verifies Firebase JWTs using public
  keys, owns Redis UID/key/tier mapping and calls LiteLLM. No deletion service,
  Firebase Admin credentials, revoked-token checks, or expiry worker in source.
- Live verifier Dockerfile installs FastAPI/PyJWT/Redis/httpx, not Firebase Admin
  or PostgreSQL client. Source is outside this repository; no live files changed.
- Caddy routes `/mint`, `/usage`, `/upgrade` and `/v1/*`; no `/account/*` route.
- Redis: AOF enabled, every-second fsync, **allkeys-lru** eviction. Lifecycle state
  therefore lives in PostgreSQL, not Redis. Existing LiteLLM/Postgres can host a
  separately permissioned account database without adding a Firebase Functions bill.
- App uses Firebase Auth for name/email/photo; local preferences, SQLite/files and
  secure storage own workspace/BYOK/plugin state. No Ovid Firestore/Storage sync
  implementation was found. Firebase plugin tools access users' external projects;
  those projects are not Ovid account storage.
- The account protocol now supports social + phone identities listed below.
  This allowlist does not enable providers in Firebase or implement client flows.
  GitHub workspace login is a separate integration.
- Firebase JSON is injected by CI. No local config, Firebase/GCloud CLI or logged-in
  console was available to verify provider enablement. No secrets were read/output.

## Protocol

All routes require Firebase bearer identity and an App Check token for an explicitly
allowed app ID. Admin SDK validates project issuer/audience/expiry, revocation and
disabled users. UID is derived from the token; request payload UID is rejected.
New requests and ordinary gateway access accept only `google.com`, `github.com`,
`apple.com`, `microsoft.com`, `facebook.com`, `twitter.com`, `yahoo.com`, and `phone`.
Anonymous, custom, and unlisted providers are rejected.

**Password migration:** verified `password` credentials may read an existing
deletion receipt, replay a recorded request ID, or cancel/recover an existing
deletion under the same grace/fence rules. They cannot start a new deletion,
enter via login without a deletion record, or pass the ordinary access guard.
Keep password verification for this narrow recovery path: rejecting it globally
would strand legacy users whose account the worker disabled, including a persisted
cancellation whose re-enable failed. A cancellation response is not permission to
use gateway resources; those still require a supported social/phone sign-in.
This module neither creates Firebase users nor changes project provider settings.

- `POST /account/deletion {"request_id":"client-random-id"}`: auth_time no older
  than 5 minutes, checked after the UID lock and again after the Admin lookup.
  Returns pending + Unix `delete_after`
  exactly 86,400 seconds after server acceptance. Duplicate/pending requests cannot
  extend the deadline. Coalesced IDs are persisted before returning the original
  receipt and remain bound to it after cancellation/restart. Completed request IDs
  cannot resurrect deletion, including after a later request supersedes the receipt.
- `GET /account/deletion`: active/pending/cancelled/fenced/deleting/deleted status.
- `POST /account/login`: observational. Returns the current deletion state; it
  never cancels deletion or re-enables a fenced account. The client calls it
  before admitting an authenticated user when account deployment is enabled, and
  a pending account stays gated after ordinary sign-in.
- `POST /account/deletion/cancel {"consent":true}`: the only restore mutation.
  Requires auth_time no older than 5 minutes (checked under the UID lock) and App
  Check. Accepted only for `pending` rows before the server `delete_after`
  deadline, or worker-fenced rows inside the settlement interval; `deleting` and
  `deleted` are rejected. The client calls it only from an explicit
  "Restore account" action.
- No public finalize/admin deletion endpoint. Only the server worker finalizes.

The server returns `{state, delete_after, request_id}`. Errors never represent
success. Client displays server-confirmed UTC deadlines and signs out after a
retained request. A local sign-out failure does not invalidate that receipt.

## Serialization, retry and race behavior

PostgreSQL session advisory locks serialize the entire operation per UID, including
external calls. Checkpoints commit independently under that lock; no distributed
transaction is claimed. Due lists are advisory: every worker re-reads under lock.
Multiple processes/restarts safely repeat idempotent effects. No expiry TTL drops
pending work. A cancellation intent is persisted before re-enabling a worker-fenced
Firebase account, so re-enable failures cannot turn into deletion.

Worker selection is limited to 100 due records, ordered by `next_attempt`, then
`attempts`, deadline and UID. Both retry fields are durable JSON checkpoint fields
(missing fields default to zero for old rows). Every eligible attempt persists a
retry deadline before external effects, including cancellation re-enable recovery.
Failures back off 60 seconds exponentially to one hour, measured again from the
end of a failed call; crashes retain the pre-effect deadline. Attempt counts include
successful fencing passes. Successful fencing schedules the settlement boundary.
Workers recheck eligibility and retry time under the UID lock, so a stale due list
cannot bypass backoff. Unattempted work sorts ahead of retried poison rows even
when another timer tick happens after their backoff expires. There is no permanent
attempt cutoff. Explicit cancellation can still recover immediately during backoff.

At expiry the worker durably marks fencing and disables sign-in. A successful
disable starts a 60-second settlement interval. No key/data/auth deletion occurs
during settlement. An explicit `/account/deletion/cancel` committed under the UID
lock during settlement can still restore; Firebase sign-in metadata is never
treated as cancellation. Only then does durable `deleting`
commit, followed by key blocking, data/cache cleanup, and Auth/profile removal.
Tokens needed for crash-safe cleanup are captured in the durable record before
effects, retained through failures, and removed on completion.

The gateway adapter exposes separately durable `data:gateway`, `data:sql`, and
`data:redis` checkpoints, followed by the existing aggregate `data` checkpoint.
A SQL/Redis failure or process exit after an acknowledged, saved key deletion no
longer replays that gateway operation on restart. SQL cleanup remains one ordered
transaction; Redis partial deletion remains retryable. Old aggregate `data`
checkpoints are honored. No schema migration is needed for these JSON checkpoints.
Upgrade API/worker together: older workers do not honor the new substage markers.
An effect followed by a lost response or failed checkpoint is still an unknown
outcome requiring the deployed adapter's retry contract. HTTP 404 is not silently
treated as proof of successful key/cache cleanup.

Authentication is not consent. The worker does not read Firebase last-login
metadata as a cancellation signal; only a durable `cancelled` row committed under
the UID lock stops cleanup. Worker downtime therefore does not convert ordinary
sign-ins into restoration, and an explicit cancel that wins the lock is honored.

**Activation-critical assumption:** production Firebase disable and explicit
cancel/re-enable must be validated with concurrent staging sign-ins and cancel
requests. A 60-second wait is not proof of a globally linearizable external
identity service. Do not claim an unconditional cross-service race guarantee from
fake tests. Gateway access must also be fenced as described below.

## Data scope and manifest

Implemented cleanup adapters:

1. Firebase Admin deletes the UID, which removes Firebase profile name/email/photo
   URL/provider links. It does not delete the upstream Google account or image.
2. LiteLLM enumerates **all** UID-owned keys from its database, blocks them via
   `/key/block`, then deletes via `/key/delete` for cache invalidation.
3. An explicit ordered SQL manifest removes all UID/token-scoped records in one
   database transaction: keys, user/profile rows, spend/request logs and additional
   app tables. It requires `keys`, `users`, `spend_logs` roles; no guessed deployed
   schema or silently empty cleanup is accepted.
4. Redis removes `user:{uid}:*`, `freecap:{uid}:*`, `abuse:uid:{uid}`, `mintlock:{uid}`,
   membership of `ovid:uids`, and UID memberships in `ipacct:*`. Shared IP counters
   are not deleted, since they belong to multiple users and expire independently.
5. Minimal lifecycle tombstone (UID, request IDs, deadline, state, checkpoints and
   login timestamps) remains for idempotency and anti-resurrection. No email/photo
   or key tokens remain after completion. Decide retention before production.

**Configured image/share integration:** `runtime.build()` now requires
`ACCOUNT_STORE_CONFIG` and composes the gateway with the authoritative local
image ledger and share repository. Durable `data:images` and `data:shares` stages
call their idempotent `delete_account(uid)` hooks before `data`/Auth completion.
In-progress legacy rows with aggregate `data` still run these new required stages.
Persisted store UUIDs bind cleanup context to the selected authorities; a different
configured identity on retry fails before any further effects. Local image cleanup
removes replay/private cost and fences the UID, retaining minimal accounting and
unresolved reservation tombstones. This does not delete provider-side images,
external object stores, SQLite free pages/WAL, backups or proxy caches.

See [DEPLOYMENT.md](DEPLOYMENT.md) for the mandatory inventory, provisioning,
application/router factory, retention timer, migration and exact host commands.
No default SQLite path or empty newly-created store can satisfy normal startup.

`ACCOUNT_CLEANUP_MANIFEST` is a JSON file reviewed against the deployed schema:
`{"scopes":[...]}`. Each scope has `table`, `column`, `kind` (`uid` or `token`) and
`role`. The one `keys` scope also supplies `token_column` and uses `kind: uid`.
Identifiers allow only SQL identifier characters and are quoted. UID/token values
are parameterized. Put dependent/token tables before keys/users to satisfy FKs.
Unknown scopes are not discovered by deleting arbitrary tables. Startup validates
configured columns. Inventory every UID-bearing app table, Redis prefix, model
cache, request log and object bucket before signing off this manifest.

**Outside current server ownership:** local chats/files/BYOK secrets and plugin
credentials on every device; external repositories, provider accounts/data;
upstream model-provider retention; unlinked Analytics/Crashlytics events; backups
and proxy logs. No remote local-device erase is claimed. Define backup expiration
and reapply tombstones after restore; assess telemetry deletion separately if
identifiers are linked later. No Firestore/Storage adapter is needed for the
inspected app, but adding cloud sync requires adding its cleanup before activation.

## Gateway/quota integration contract (isolated module)

Use the same `Lifecycle` instance/store configuration in mint and quota work:

```python
claims = account_admin.verify(id_token, app_check_token)
with account_lifecycle.access(claims) as uid:
    # Existing mint/upgrade/quota mutation executes entirely inside this lock.
    # Preserve existing quota checks; never accept UID from request JSON.
    result = mint_or_update_for_uid(uid)
```

Integrate this guard in `/mint`, `/upgrade`, UID-mutating admin endpoints and any
future app-data writer. Paid webhooks must obey tombstones too. Pending/deleting
accounts cannot mint new keys; background `/usage` must not cancel deletion.
Guard `/v1/*` authenticated access by resolved key-owner UID so old cached keys or
older clients cannot write/spend after fencing. Drain in-flight UID-owned writes
before cleanup. Call observational `/account/login` before new client cloud use;
it never cancels deletion.
Do not hold locks in mutually inverted orders with quota locks. This branch does
not modify a nonexistent tracked mint module or the live `/opt` implementation.

## Activation requirements (all currently blocked/unperformed)

1. Confirm the intended social/phone provider enablement in the actual Firebase
   project, Android signing fingerprints, OAuth client/platform configuration;
   validate real login and reauth. Coordinate password retirement with existing
   deletion/fence recovery; this allowlist does not configure Firebase.
2. Supply Firebase Admin application-default credentials with Auth read/update/
   delete permissions, never client credentials. Register Play Integrity App Check
   for the signed Android build. Client now includes the App Check SDK; server
   allowlist requires `ACCOUNT_FIREBASE_APP_IDS`.
3. Provision durable PostgreSQL storage/backups and run `schema.sql`, then
   `schema_private_sync.sql` (PostgreSQL only), explicitly (existing
   installations: see migration notes below).
   Complete and review the LiteLLM/app cleanup manifest; validate key block/delete,
   cache eviction, missing-key retry semantics and foreign-key ordering for the
   deployed LiteLLM release (`main-latest` is not a pinned contract). Supply and
    verify configured image/share authority paths and provider/backup retention
    before activation.
4. Integrate all gateway/quota/write fences above, validate cancellation races
   against staging Firebase and SQL, and define backup/telemetry retention.
5. Install dependencies from `requirements.txt` in a dedicated runtime. Configure
   protected environment: `ACCOUNT_DATABASE_URL`, `LITELLM_DATABASE_URL`,
   `ACCOUNT_CLEANUP_MANIFEST`, `FIREBASE_PROJECT_ID`, `ACCOUNT_FIREBASE_APP_IDS`,
    `LITELLM_BASE`, `LITELLM_MASTER_KEY`, `REDIS_URL`, `ACCOUNT_STORE_CONFIG`,
    `SHARE_BASE_URL` and ADC credentials.
6. Only after these checks set `ACCOUNT_ACTIVATED=true`; run API with
   `uvicorn server.account.runtime:create_app --factory` on a private interface.
    Use DEPLOYMENT.md's exact account/sync/chat/share Caddy route template and
    apply the host's abuse/rate limiting without logging credential-bearing paths.
7. Install the provided systemd worker service/timer under a least-privilege
   `ovid-account` OS user. `Persistent=true` plus durable due scanning catches up
   after restart. Alert on worker failure/overdue records. API and worker must use
    the same account database and provisioned image/share stores. Units require
    explicit host drop-ins; no installation/storage paths are assumed. Install
    the bounded image/share retention timer as described in DEPLOYMENT.md.
8. Build with `OVID_ACCOUNT_ENABLED=true` only when the above is active. Missing
   server/attestation then blocks account entry; no fake cancellation fallback.

## Migration notes (artifacts only; not applied to a live database)

- Fresh database: apply `schema.sql` (original table and both due indexes), then
  `schema_private_sync.sql` (PostgreSQL-only private-sync tables; identical to
  `migrations/003_private_sync.sql`). `schema.sql` stays portable account-lifecycle
  DDL and must not gain PostgreSQL-only sync objects.
- Existing database without private sync: explicitly apply
  `migrations/003_private_sync.sql` (additive, repeatable, one transaction).
- PostgreSQL collaboration: explicitly deploy `schema_collaboration.sql` via
  `server.collaboration.migrate ... schema`, or apply equivalent
  `migrations/004_live_collaboration.sql` to the lifecycle schema. SQLite data is
  imported separately while every consumer is offline; changing the backend flag
  alone does not migrate data or cleanup checkpoints. See DEPLOYMENT.md.
- Existing database: explicitly apply `migrations/002_retry_schedule.sql`. It adds
  only a repeatable expression index, keeps the old index, and changes no records,
  columns, states, deadlines, recovery flags or cleanup context. Standard index
  creation can block writers; schedule it in an appropriate maintenance window.
- The application also operates correctly on the original four-column schema
  before the index is installed. JSON `attempts`/`next_attempt` default to zero;
  `request_aliases` defaults to an empty list. No destructive backfill is needed.
- Upgrade API and worker together after draining older processes. An old binary
  ignores backoff and may discard new JSON fields when replacing a request; mixed
  versions or rollback lose the repaired fairness/idempotency guarantees. Preserve
  records and indexes on rollback; upgrade again before relying on those guarantees.
- Previously coalesced IDs were never recorded by the old binary, so they cannot be
  reconstructed by a migration. The alias guarantee applies to IDs accepted by the
  repaired code; existing canonical IDs and `previous_requests` remain honored.

## Local verification

```sh
python -m pytest -q server/account/tests
```

Unit tests fake Firebase, storage and clock; runtime integration tests also exercise
real PostgreSQL in isolated schemas when `COLLAB_TEST_POSTGRES_DSN` and
`SYNC_TEST_DATABASE_URL` name a disposable test database. API tests inject verified
claims rather than contacting Firebase. They do not prove live IAM, provider enablement, PostgreSQL
failover, LiteLLM cache semantics, or external Auth consistency. No live deletion
or deployment was used for verification.

Install `requirements.txt` plus pytest in a local test environment. SQL tests execute
the store's due query/upserts and repeatable migration on in-memory SQLite with
PostgreSQL-style JSON text extraction. They cover the original schema, preserved
legacy rows, retry ordering and 100 poison rows ahead of healthy work; they do not
validate PostgreSQL-specific locks, query plans or concurrent DDL.

`tests/parallel_account_cleanup_test.py` also executes the real lifecycle,
gateway, SQL-manifest and Redis adapters with disk-backed SQLite checkpoints and
SQL transactions, controlled HTTP transport, and Firebase/Redis doubles. It covers
SQL rollback, partial Redis deletion, process-exit recovery, unresolved gateway
outcomes, exact fractional grace/settlement boundaries and cancellation aliases.
These fixtures establish local behavior, not deployed backend acceptance.
