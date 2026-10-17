# Internal mint authentication (P9 Task 9)

`POST /internal/mint-key` on mint's **admin listener** (port 8092) is the
server-to-server provisioning surface used by the gateway and the worker.
It replaces the pre-P9 flow in which the gateway forwarded the caller's
Firebase ID token and App Check token to the public mint endpoint.

## Design

- **One shared secret**, `OVID_INTERNAL_API_SECRET` (env only, ≥ 32 bytes).
- **Per-request HMAC-SHA256** over the exact bytes:

  ```
  METHOD\nPATH\nUID\nTIMESTAMP
  ```

  - `METHOD` is upper-case (`POST`).
  - `PATH` is the route path only (`/internal/mint-key`); queries are not
    part of the contract.
  - `UID` is the body uid — the identity the request acts on.
  - `TIMESTAMP` is decimal epoch seconds.
- **Headers** (base64):

  | Header              | Value                              |
  | ------------------- | ---------------------------------- |
  | `X-Ovid-Timestamp`  | `base64(decimal epoch seconds)`    |
  | `X-Ovid-Signature`  | `base64(HMAC-SHA256(secret, body))`|

  A plain-decimal timestamp is also accepted on verify (same signed value).
- **Window**: ±300 s (`INTERNAL_WINDOW_S`). The verifier compares against
  mint's clock; a skewed host fails closed.
- **Constant-time compare** (`timingSafeEqual`); malformed, missing, stale,
  wrong-secret and uid-swapped requests all answer the same `401
  {"detail":"unauthorized"}`.
- **Replays inside the window are accepted and idempotent by design.** The
  route mints one key per `(uid, platform)` under the existing mint lock, so
  a replayed request returns the same key and creates nothing new. There is
  deliberately no nonce store: it would add a shared Redis dependency to the
  trusted surface without changing the outcome.

The implementation lives in `packages/shared/src/internalAuth.ts` (sign +
verify) and is consumed by:

- `apps/mint/src/internalRoutes.ts` (admin listener only),
- `apps/gateway/src/internalMint.ts` (gateway → mint),
- `apps/worker/src/keyResolver.ts` (unattended-run minting).

## Threat model

| Threat | Mitigation |
| --- | --- |
| Public internet reaches the route | The admin listener is bound to loopback / the compose-internal network; Caddy never routes `/admin` or `/internal`. The route is **never** registered on `publicApp` (pinned by a 404 test). |
| Stolen client token used to mint for someone else | The gateway signs its **own verified uid**; no client token crosses the boundary. The signature binds the uid in the body, so swapping it invalidates the request. |
| Replay of a captured request | Accepted only inside ±300 s, and idempotent (returns the same key). A capture outside the window is rejected. |
| Secret leakage via logs/URLs | The secret travels only in the HMAC key; it is never in a URL, body or log line. Route logs carry `{uid, status}` only. |
| Timing oracle | `timingSafeEqual` on equal-length buffers; all failures share one body. |
| A compromised gateway/worker mints arbitrary keys | Accepted: both are trusted same-host processes. The blast radius is bounded by the existing ban/free-cap/deletion-fence ladder, which the internal route runs. |
| Caller-supplied BYOK endpoint used to reach internal services | The worker re-validates every decrypted endpoint through the same SSRF classifier at use time (`isNonPublicAddress`) and routes it through the guarded egress; a user endpoint is never added to the trusted provider-origin allowlist. |

## Rotation

1. Generate a new secret: `openssl rand -hex 32`.
2. Set `OVID_INTERNAL_API_SECRET` in mint's env, the gateway's `.env` and the
   worker's `worker.env` — all three must match.
3. Rolling restart **mint → gateway → worker**. During the overlap a caller
   with the old secret gets `401` until its restart; there is no dual-secret
   acceptance window (the surface is internal and the restart is seconds).

No key material is derived from the secret, so rotation needs no data
migration.

## Why not mTLS

Both processes live on one compose network on one host; the boundary is the
network namespace, not the internet. mTLS would add a CA, per-process
certificates, expiry monitoring and a rotation runbook without adding a
boundary that the network does not already provide. HMAC over a
pre-provisioned secret is the smallest mechanism that authenticates the
caller and binds the request contents. If the services ever span hosts, this
decision should be revisited (mTLS or a service mesh), and the HMAC contract
can stay as the request-level integrity layer.

## Failure semantics

- Gateway: non-2xx from mint becomes `MintInternalError`; `402`/`429` are
  relayed verbatim, anything else collapses to `409 key_not_minted`.
- Worker, unattended run with no db2 key: `401/402/403` → `null` (the run
  fails `key_not_minted`, reason logged); network/5xx → throw so BullMQ
  retries (infrastructure, not a policy answer).
- Worker, attended run with no db2 key: `null` without an internal call
  (P4's contract is unchanged).
