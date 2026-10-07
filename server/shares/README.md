# W12 hosted conversation shares

Standalone FastAPI router and SQLite repository, now composed by the configured
account application factory. **Not deployed.** No live share endpoint is assumed. The app's session actions menu
opens a frozen preview; create is unavailable without `OVID_SHARE_BASE_URL`.

## Integration contract

The host supplies an existing FastAPI app, a persistent local database path, the
actual HTTPS deployment base, and a synchronous verified-UID callback:

```python
from server.shares.api import router
from server.shares.repository import ShareRepository
from server.account.domain import identity

repository = ShareRepository(config.share_database_path)

def verified_uid(token, attestation):
    # Use the existing account FirebaseAdmin adapter, with disabled-token
    # recovery explicitly OFF. identity() enforces social/phone-only policy.
    claims = firebase_admin_adapter.verify(token, attestation, allow_disabled=False)
    uid = identity(claims)
    account_admission.require_active(uid)  # host-owned durable deletion fence
    return uid

app.include_router(router(repository, verified_uid, config.share_base_url))
```

`config`, `firebase_admin_adapter`, and `account_admission` above are host-owned
integration objects, not exports from this package. Do not substitute an
unverified JWT decoder, a UID header, or a request-body owner field. Callback
exceptions fail authentication closed. App Check enforcement belongs in this
callback; the app uses the public `CloudAppCheck` helper in production.

The configured base is the externally reachable prefix **before** `/shares` and
`/s`. If it has a path prefix, mount/proxy these routes under that prefix. The
server constructs links from configuration only, never Host/Forwarded headers.
The Dart client requires HTTPS and accepts only an exact configured-base URL
with the returned opaque token. Build with
`--dart-define=OVID_SHARE_BASE_URL=<actual configured deployment base>` only after
the routes and viewer are reachable. There is intentionally no gateway default.

Endpoints:

* `POST /shares`: Firebase bearer token; optional attestation header as required
  by verifier. JSON `{session_id, request_id, messages: [{role, content}]}`.
  Returns 201 `{id, url, session_id, request_id, created_at, expires_at}`.
* `GET /shares?session_id=...`: owner-only active receipts, optionally scoped to
  session. Returns `{shares: [...]}`. No public enumeration endpoint.
* `DELETE /shares/{id}`: owner-only; idempotent 204 for an owned receipt, 404 for
  unknown/wrong owner. Erases the snapshot body immediately.
* `GET /s/{id}`: anonymous static HTML, 404 for unknown/revoked/expired IDs.
* `POST /shares/{id}/fork`: authenticated recipient fork; JSON
  `{request_id}` returns 201 `{session_id}`. The request is idempotent per
  recipient and rejects revoked or expired snapshots. The source snapshot and
  source owner's session are never mutated.

Session IDs group the authenticated owner's uploads; they do not authorize
access to any server-side session. The server stores only the submitted snapshot
and never reads another conversation using that ID.

## Durability, cleanup and limits

SQLite uses one connection per operation, parameterized SQL, full synchronous
commits and `BEGIN IMMEDIATE` for all mutations. Run on persistent local storage
shared by the API processes on the same host, not ephemeral container files or
network filesystems. Back up the database under the account-data retention policy.
Keep filesystem access restricted to the service account.

Tokens have 256 random bits (43 base64url characters). `(owner_uid, request_id)`
is unique: identical retries return the same immutable receipt, changed content
or retries of revoked/expired receipts return 409. The app retains the request
ID across uncertain create retries and lists existing links on sheet reopen.
Owner-only receipts include the request ID so Refresh can reconcile a lost
creation response; it is never included in the public viewer. There are at most
100 active shares and 1,000 total durable receipts per owner. Revocation and
expiry do not reset the durable budget, preserving deduplication history without
unbounded storage growth. At that limit creation returns 429; reads, revocation
and account cleanup remain available. Configure gateway request-rate limits
before public deployment.

Creation samples expiry/quota time after acquiring the write transaction, so a
queued retry cannot receive an already-expired success receipt. A purged body is
terminal even if the wall clock subsequently moves backward: it is excluded from
active lists/quota and cannot be replayed. Internal Python callers passing model
instances receive full schema/content revalidation, including nested messages.
Configured TTL must be finite and positive.

Defaults: 30-day expiry, 500 messages, 20,000 Unicode characters per message,
200,000 UTF-8 content bytes, 1,500,000 raw request bytes. Schedule
`repository.purge_expired()` to erase expired content; expiry is enforced on reads
even if maintenance is delayed. Minimal ownership/idempotency receipts persist
until account cleanup. Revocation clears the content but retains its receipt.

**Configured account integration:** `server.account.runtime.build()` now calls
`repository.delete_account(uid)` in the durable `data:shares` stage after the
deletion fence and before Firebase identity deletion. It atomically erases every owned
share and records a permanent UID tombstone, preventing in-flight verified
creates from restoring data. The method is idempotent; do not call it on logout
or during the cancellable deletion grace period. The host admission callback
must also reject fenced/deleting accounts before this cleanup stage begins.
`server.shares.runtime.mount_shares` supplies that composition and holds the
account lock through the entire owner operation; `runtime.create_app()` mounts
the configured HTTPS base's path prefix. `server.account.retention` supplies
bounded expiry sweeps. See [deployment commands](../account/DEPLOYMENT.md) for
mandatory authoritative store configuration, provisioning and repeatable timers.

## Public content boundary

The app copies only completed `MsgKind.text` user/assistant rows, never serialized
sessions. It excludes reasoning, streaming, tools, artifacts/images, attachment
metadata/bytes, titles, provider config, compacted summaries and system prompt
snapshots. Known embedded private-context, background-agent, credential, private
path and base64 envelopes cause the entire row to be omitted; the server rejects
these envelopes independently and rejects all non-allowlisted fields. The
preview shows exactly the text sent. Arbitrary personal information or secrets
written as ordinary prose cannot be reliably inferred; users must review it.
Legacy rows have no durable human-vs-internal provenance bit, so known internal
envelopes are explicitly excluded in both app and server policies.

The viewer renders escaped plain text, including literal Markdown. It has no
scripts, external resources, clickable user URLs, agent execution or attachments.
All route responses (including validation/auth/errors/revoke) send
`Cache-Control: no-store, private`, noindex/noarchive, no-referrer, nosniff and a
restrictive CSP. Configure the reverse proxy/CDN to honor these headers and
disable caching and token-bearing access logs for `/s/*` and `/shares*`. Do not
export the viewer to a static CDN bucket: revocation requires a fresh repository
lookup on each request. Already copied/downloaded text cannot be withdrawn.

## Verification

```sh
/tmp/opencode/images-venv/bin/python -m unittest discover -s server/shares/tests -v
/tmp/opencode/images-venv/bin/python -m unittest discover -s server/shares/tests -p 'parallel_shares_*.py' -v
/root/flutter/bin/flutter test --no-pub test/conversation_share_service_test.dart test/conversation_share_sheet_test.dart test/conversation_share_sidebar_test.dart
```

External gate: mount/proxy routes, wire verified account admission and cleanup,
schedule expired-content maintenance, configure persistent storage/cache policy,
then verify real Firebase/App Check, anonymous open, and revoke against the actual
public deployment. Mocked endpoints and local tests do not prove hosting.
