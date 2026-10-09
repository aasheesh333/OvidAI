# Account restore consent

**Status:** Client and server restore-consent behavior is implemented locally
and covered by local tests (observational `POST /account/login`; explicit
`POST /account/deletion/cancel {"consent": true}` as the only restore mutation).
Production activation remains blocked per
`docs/superpowers/plans/2026-10-09-account-deployment-readiness.md`. This
document authorizes no deployment, migration, credential activation, or commit.

## Goal and defect

Account deletion is a server-owned, cancellable lifecycle. A deletion request
creates a durable 24-hour grace period. During that period the account owner
may explicitly choose to restore the account, but merely observing or
re-establishing an ordinary authenticated session must not express that
choice.

The original defect (now fixed locally) conflated authentication with restoration:

- the client account-session/login path called `POST /account/login` before it
  admitted an authenticated user;
- the server's `Lifecycle.login()` was mutating: for a pending request it could
  call `_cancel()` and transition the durable row to `cancelled`;
- the login screen told users that signing in before the deadline would cancel
  deletion, so a routine sign-in, token refresh, or restored Firebase session
  could be interpreted as consent;
- the server also exposed `POST /account/deletion/cancel` to the same mutating
  operation, but the client did not reserve that operation for an explicit
  restore action.

This is unsafe because sign-in is observational authentication, not an
account-recovery decision. A user may sign in only to inspect the deletion
deadline, may be testing another provider, or may have a restored session
without intending to retain the account.

## Normative target

The following rules are mandatory for the implementation that follows this
specification:

1. **Ordinary login is observational.** `POST /account/login` must either be
   removed from the restore mutation path or become a status/eligibility
   acknowledgement that cannot change `pending` to `cancelled`. It may verify
   identity, account generation, disabled/fenced state, and the server's
   current deletion status. It must not re-enable a fenced account, alter the
   deletion row, extend the deadline, or authorize account restoration.
2. **Cancellation requires explicit consent.** Only
   `POST /account/deletion/cancel` may cancel a pending deletion, or a
   worker-fenced deletion that is still within the configured settlement
   interval. The request must be initiated by a visible account-restore
   control after the user has been shown the pending state and server deadline.
   Authentication and token refresh are prerequisites, not consent.
3. **Consent is bounded by the server deadline.** The server owns the exact
   `delete_after` value: `requested_at + 86,400` server seconds. The client
   must not calculate, extend, or substitute a local deadline. A cancel at or
   before the accepted deadline is serialized against worker finalization by
   the account UID lock. A request after irreversible deletion is rejected and
   never presents a cancelled-success state.
4. **No implicit restoration from background activity.** Firebase auth-state
   listeners, token refresh, app resume, cloud binding, ordinary gateway
   access, retries, and restored local sessions must not call the cancel route.
5. **Fail closed for protected access.** When the server reports a pending
   deletion, the client gate must not admit the protected account experience as
   restored. It shows the pending deadline and an explicit restore action (or
   sign-out). Only a confirmed `cancelled` response may make the account
   ready. A network error, timeout, malformed response, or ambiguous outcome
   leaves the account unready and the deletion status unclaimed.

## State and API contract

The durable lifecycle remains server-owned with these relevant states:

```text
active -> pending -> fenced -> deleting -> deleted
             |          |
             +-> cancelled
```

`pending -> cancelled` (and the explicitly permitted fenced-settlement
recovery) is a deliberate restoration mutation. It is not an effect of
authentication. The server response continues to be the canonical object
`{state, delete_after, request_id}`; clients must validate the state and
timestamp shape and must not infer success from HTTP transport success alone.

### Observational login/status

The authenticated login gate may call a status endpoint to learn whether the
account is active, pending, fenced, deleting, or deleted. That endpoint must:

- derive the UID from verified identity, never request JSON;
- enforce App Check and account-generation/disabled checks;
- return the existing server deadline without changing it;
- return `pending` unchanged for a pending deletion;
- never call `_cancel()`, `admin.enable()`, or any other restoration effect;
- distinguish “pending; explicit restore required” from an unavailable or
  deleted account with typed error responses.

If a compatibility `POST /account/login` remains, its contract must be
observational and its name/documentation must not imply cancellation. The
preferred mutation surface is exclusively:

```http
POST /account/deletion/cancel
Authorization: Bearer <fresh identity token>
X-Firebase-AppCheck: <attestation>
```

The cancel route requires a fresh, supported identity proof and must be
serialized under the same UID lock as worker finalization. It accepts only a
pending row or a fenced row still inside settlement; it rejects `deleting` and
`deleted`. It persists the cancelled intent before attempting to re-enable a
worker-fenced Firebase user.
If re-enable fails, the durable cancelled state is retained for retry; the
client must not claim that protected access is ready until the server confirms
the account can be admitted. Cancellation must be idempotent for an already
cancelled record and must reject `deleting`/`deleted` without converting the
result into success.

## Worker and race semantics

The 24-hour deadline is a server invariant, not a client timer. The worker is
the only actor allowed to finalize deletion. It may receive a stale due-list
entry, run concurrently with a cancel request, restart, or lose an external
service response. Every attempt re-reads the durable row while holding the UID
lock and honors durable retry fields.

At the deadline the worker must:

1. re-read the row and refuse to finalize a durable `cancelled` record;
2. inspect the authoritative identity metadata according to the existing
   last-login race policy;
3. durably establish the fence before irreversible cleanup;
4. disable the identity and re-read metadata after disabling;
5. retain the configured settlement interval before entering `deleting`;
6. permit an explicit cancel request to win whenever the lock and lifecycle
   state allow it before irreversible cleanup; and
7. perform checkpointed, retryable data/key/auth cleanup only after the
   deletion fence is durable.

The implementation must not use a client acknowledgement, local clock, or
ordinary login event as evidence of cancellation. If a worker crash, lost
response, or external identity race leaves the outcome uncertain, the durable
record remains retryable and the system prefers retaining the account over
deleting an account whose explicit cancellation may have won. Existing
settlement and checkpoint behavior remains part of this contract; the consent
fix must not weaken it.

## Client login gate and account UI

The client flow must separate identity authentication from account restoration:

1. Firebase sign-in completes and the client records the identity generation.
2. The login gate performs observational account status/eligibility checking.
3. For `active`, the gate may mark the account ready and continue normal cloud
   binding.
4. For `pending`, the gate remains in an account-not-ready restore screen. It
   displays the exact UTC deadline and explains that signing in did not cancel
   deletion. The primary action is an explicit, unambiguous control such as
   **Restore account**; the secondary action signs out.
5. Tapping **Restore account** may require fresh provider/phone
   reauthentication, then calls only `/account/deletion/cancel`. It must show
   progress and prevent duplicate submissions.
6. The gate admits the protected app only after a valid `cancelled` response
   and a fresh identity-generation check. A late response from a signed-out or
   switched account cannot mark the new account ready.
7. For `fenced`, `deleting`, or `deleted`, the gate shows the server error and
   offers sign-out/retry as appropriate; it does not offer a false restoration
   success.

The account deletion panel uses the same explicit cancel contract. Its pending
state may offer **Restore account** and refresh status, but refreshing status
must remain read-only. Copy must say that the account remains scheduled until
the user explicitly chooses restoration; it must not imply that ordinary login
is consent.

## Failure handling and security properties

- A cancel transport timeout has unknown outcome. The client shows that status
  could not be confirmed, keeps the account gated, and offers status refresh.
- A non-success response, invalid JSON, invalid state, UID mismatch, stale
  identity generation, or missing App Check never becomes a cancellation
  success.
- Repeated explicit taps are safe through request serialization/idempotency;
  they must not move `delete_after` or create a second grace period.
- Background cloud binding starts only after the account is ready. It cannot be
  used to bypass the restore gate or to cancel implicitly.
- The server continues to reject gateway/quota writes for pending, fenced,
  deleting, and deleted accounts according to the existing access contract.
- Logs and analytics must not record bearer tokens, credentials, or raw
  identity data beyond the existing bounded account event policy. Restore
  events should distinguish explicit cancel attempts from observational login
  checks.

## Verification requirements

### Server tests

Add or update focused lifecycle/API tests proving:

1. An observational login/status call against `pending` returns `pending`,
   leaves the row pending, preserves the original `delete_after`, and does not
   call `admin.enable()`.
2. Repeated ordinary login, token refresh, app resume, and access checks cannot
   cancel a deletion.
3. An explicit `/account/deletion/cancel` request with valid fresh identity
   cancels exactly once and is idempotent on retry.
4. Missing/stale reauthentication, unsupported identity, wrong UID, disabled
   account, and malformed requests cannot cancel.
5. A cancel at the exact deadline races deterministically with the worker under
   the UID lock; it either commits cancellation before fencing or receives the
   correct fenced/deleting response, never a fabricated success.
6. A stale due-list item, worker restart, crash, lost external response, and
   retry backoff cannot bypass a committed cancellation or delete before the
   durable deadline/settlement rules.
7. A failed re-enable retains durable cancelled intent and retries safely.
8. Cleanup checkpoints remain ordered and auth deletion cannot occur after an
   incomplete data/key cleanup.

### Client tests

Add or update focused Flutter tests proving:

1. A pending account shown in the login gate remains unready after ordinary
   sign-in; no cancel request is made.
2. The exact server UTC deadline is displayed and is not recomputed from the
   device clock.
3. The explicit restore control calls `/account/deletion/cancel` only after
   user action and, when required, fresh reauthentication.
4. Only a confirmed `cancelled` response admits the protected child; errors,
   timeouts, malformed responses, sign-out, account switches, and stale late
   responses keep it gated.
5. Duplicate restore taps are coalesced/disabled and status refresh is
   observational.
6. Active accounts continue through the normal gate, while fenced/deleting/
   deleted accounts cannot enter through ordinary login.
7. The account deletion panel's pending copy and actions distinguish refresh,
   explicit restore, and sign-out.

## Deployment and rollout

The server API, client gate, and worker must be upgraded as one compatibility
change. Before enabling the client flag or route, staging must prove that:

- the deployed route sends ordinary login/status traffic to the observational
  handler and only the explicit account action reaches the cancel mutation;
- API and worker binaries share the same lifecycle schema and lock behavior;
- concurrent sign-in, explicit cancel, deadline expiry, disable, restart, and
  cleanup are exercised against the actual Firebase Admin integration;
- proxy routing, App Check, no-store behavior, rate limits, and observability
  distinguish status checks from cancel attempts; and
- an older client cannot silently restore an account through a compatibility
  login endpoint. If that cannot be guaranteed, disable the old route before
  exposing the new client.

Production activation remains blocked until the existing account deployment
requirements are satisfied: durable PostgreSQL state, reviewed cleanup
manifest, Firebase Admin permissions, gateway/access fences, supervised
worker timers, backups/retention, and staging validation of external identity
consistency. No production deletion or restoration is performed by this
specification.
