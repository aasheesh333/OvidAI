# P3 account lifecycle — deployment artifact, NOT activated

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
- `POST /account/login` or `/account/deletion/cancel`: a new login during grace
  cancels. A restored requesting session cannot cancel itself. Current client calls
  login before admitting an authenticated user when account deployment is enabled.
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

At expiry the worker checks Firebase last sign-in metadata, durably marks fencing,
disables sign-in, and re-reads metadata. A successful disable starts a 60-second
settlement interval. No key/data/auth deletion occurs during settlement. A late
grace login acknowledgement can still cancel. Only then does durable `deleting`
commit, followed by key blocking, data/cache cleanup, and Auth/profile removal.
Tokens needed for crash-safe cleanup are captured in the durable record before
effects, retained through failures, and removed on completion.

Firebase only provides **latest** sign-in metadata, not login history. A newer
login even after the deadline conservatively cancels when the worker cannot rule
out an earlier grace login. This may extend cancellation during worker downtime;
it deliberately prefers keeping an account to deleting a potentially cancelled
one. Same-second token timestamps require newer Firebase metadata to cancel.

**Activation-critical assumption:** production Firebase sign-in/disable and
last-sign-in visibility must be validated with concurrent staging sign-ins. A
60-second wait is not proof of a globally linearizable external identity service.
If that property cannot be established, add a durable pre-sign-in fence/event
integration before activation; do not claim an unconditional cross-service race
guarantee from fake tests. Gateway access must also be fenced as described below.

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

**Missing image cleanup adapter:** the account cleanup chain does not call an
external image-service/object-store deletion adapter. SQL/Redis/key cleanup alone
does not establish deletion of image assets or image-service metadata. End-to-end
account image cleanup remains incomplete and an activation blocker; it requires an
owned, idempotent external adapter and integration verification. The current
`deleted` checkpoint describes only this module's implemented cleanup chain.

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
before cleanup. Integrate explicit `/account/login` before new client cloud use.
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
3. Provision durable PostgreSQL storage/backups and run `schema.sql` explicitly
   (existing installations: see migration notes below).
   Complete and review the LiteLLM/app cleanup manifest; validate key block/delete,
   cache eviction, missing-key retry semantics and foreign-key ordering for the
   deployed LiteLLM release (`main-latest` is not a pinned contract). Supply and
   verify the missing external image cleanup adapter before activation.
4. Integrate all gateway/quota/write fences above, validate cancellation races
   against staging Firebase and SQL, and define backup/telemetry retention.
5. Install dependencies from `requirements.txt` in a dedicated runtime. Configure
   protected environment: `ACCOUNT_DATABASE_URL`, `LITELLM_DATABASE_URL`,
   `ACCOUNT_CLEANUP_MANIFEST`, `FIREBASE_PROJECT_ID`, `ACCOUNT_FIREBASE_APP_IDS`,
   `LITELLM_BASE`, `LITELLM_MASTER_KEY`, `REDIS_URL` and ADC credentials.
6. Only after these checks set `ACCOUNT_ACTIVATED=true`; run API with
   `uvicorn server.account.runtime:create_app --factory` on a private interface.
   Route only `/account/*` through Caddy and apply existing abuse/rate limiting.
7. Install the provided systemd worker service/timer under a least-privilege
   `ovid-account` OS user. `Persistent=true` plus durable due scanning catches up
   after restart. Alert on worker failure/overdue records. API and worker must use
   the same account database. Paths in units assume `/srv/ovid-account`.
8. Build with `OVID_ACCOUNT_ENABLED=true` only when the above is active. Missing
   server/attestation then blocks account entry; no fake cancellation fallback.

## Migration notes (artifacts only; not applied to a live database)

- Fresh database: `schema.sql` includes the original table and both due indexes.
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

Tests fake Firebase, storage and clock; API tests inject verified claims rather than
contacting Firebase. They do not prove live IAM, provider enablement, PostgreSQL
failover, LiteLLM cache semantics, or external Auth consistency. No live deletion
or deployment was used for verification.

Install `requirements.txt` plus pytest in a local test environment. SQL tests execute
the store's due query/upserts and repeatable migration on in-memory SQLite with
PostgreSQL-style JSON text extraction. They cover the original schema, preserved
legacy rows, retry ordering and 100 poison rows ahead of healthy work; they do not
validate PostgreSQL-specific locks, query plans or concurrent DDL.
