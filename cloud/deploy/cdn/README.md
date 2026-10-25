# W12 — grant-backed Cloudflare CDN reads for Ovid Cloud objects

**Status: source/template documentation only; deployment and release acceptance
are pending.** This revision did not run Cloudflare, R2, gateway/worker,
DNS, deploy, restart, test, build, or typecheck commands. It does not establish
that a Worker, route, bucket, secret, or live v2 configuration exists. Keep CDN
enablement owner-gated and do not treat these examples as release evidence.

All example CDN/gateway hostnames below use `.invalid` and all credentials are
placeholders. Replace them only through an authorized deployment process; never
commit real secrets, internal addresses, tokens, or filled environment files.

## v2 security and URL contract

Use a **dedicated, isolated CDN/preview origin**, represented here by
`https://cdn.example.invalid`. It must be a different origin from the web app
and API. Do not alias it to an application origin or rely on application cookies
for authorization. The CSP sandbox described below is defense in depth, not a
substitute for origin isolation.

On the v2 CDN path, generated artifacts are served through a frozen
immutable-share copy and a durable grant. A v2 URL has this shape:

```text
https://cdn.example.invalid/o/<base64url(frozen-r2-key)>?t=<hmac>&e=<expiry>
    &c=immutable&g=<grantId>&v=<sha256>
    [&d=attachment][&fn=<filename>][&ct=<type/subtype>]
```

`g` and `v` are mandatory together. The HMAC-SHA256 canonical string contains,
in order, `v2`, key, expiry, disposition, filename, content type, cache class,
grant id, and version hash. The Worker rejects grantless v1 URLs, mismatched
cache classes, mutable/short-cache reads, invalid keys, bad signatures, and
expired or over-TTL capabilities. A valid v2 signature is necessary but not
sufficient: the grant must also be active on every object request.

Mutable uploads/attachments, workspace archives, and browser state do **not**
use this grant-backed edge-read path. Their existing short presigned-S3 path
remains canonical. The additive HTTP routes are:

```text
GET    /cloud/v1/artifacts/:id/cdn-url?source=generated|uploaded[&download=1]
GET    /cloud/v1/sessions/:id/attachments/:attachmentId/cdn-url[&download=1]
DELETE /cloud/v1/artifact-shares/:grantId
DELETE /cloud/v1/artifacts/:id?source=generated|uploaded
```

For `source=uploaded` and session attachments, the `cdn-url` routes still return
a short presigned URL after ownership/status/HEAD checks. Generated CDN mints
require storage, CDN configuration, and grant configuration. With no CDN base
URL they return `503 cdn_not_configured`; with CDN configured but no usable
grant credential they return `503 cdn_grant_not_configured`.

## Exact configuration by consumer

The following are the source-defined names. “Required for v2” means required to
operate the documented grant-backed deployment; it does not mean every variable
is unconditionally required at process boot.

| Consumer | Setting | Kind and requirement |
|---|---|---|
| Gateway + host worker | `OVID_CDN_BASE_URL` | Public deployment config. Set to the isolated CDN **origin**, with no path/query/fragment. Empty/unset disables CDN minting. |
| Gateway + host worker + Cloudflare Worker | `OVID_CDN_SIGNING_SECRET` | **Secret; never commit.** Required for v2 and must be identical in all three. Gateway/host startup requires at least 32 UTF-8 bytes when the base URL is set. |
| Gateway + host worker + Cloudflare Worker | `OVID_CDN_GRANT_INTERNAL_SECRET` | **Secret; never commit.** Required for this v2 recipe and must be identical in all three; at least 32 UTF-8 bytes. The source fallback to `OVID_INTERNAL_API_SECRET` is described below, but an explicit dedicated value avoids accidental drift. |
| Gateway + host worker | `OVID_CDN_TTL_SECONDS` | Public capability lifetime. Default `900`; a positive integer is required when non-empty, then clamped to `60..3600`. |
| Host worker only | `OVID_GATEWAY_INTERNAL_URL` | Deployment-specific internal base URL used for grant **creation**. Required for host-worker CDN publication. It is optional at general worker boot, but CDN publication fails closed without it. |
| Cloudflare Worker only | `OVID_CDN_GRANT_CHECK_URL` | Public deployment config, not a credential. Full grant **assertion** URL ending in `/internal/cdn-grants/assert-active`; required for every v2 edge read. HTTP(S) only, with no query or fragment. |
| Cloudflare Worker only | `BUCKET` | R2 binding name required by `worker.js`; bind it to the same private bucket as `OVID_R2_BUCKET`. This is a binding, not an environment secret. |
| Cloudflare Worker only | `OVID_CDN_MAX_TTL_SECONDS` | Optional public var; default/fallback `3600`. Reject a valid signature whose remaining lifetime exceeds this positive numeric limit. Keep it at least as large as `OVID_CDN_TTL_SECONDS`. |
| Cloudflare Worker only | `OVID_CDN_CACHE` | Optional public var. Exact value `off` disables Worker Cache API reads/writes; signed grant checks still occur. |
| Cloudflare Worker only | `OVID_CDN_ALLOWED_ORIGINS` | Optional comma-separated public origin allowlist for browser CORS. It does not replace signed URLs or grant checks. |

`OVID_CDN_GRANT_CHECK_URL` is not read by the gateway or host worker, and
`OVID_GATEWAY_INTERNAL_URL` is not a Cloudflare Worker variable. Do not copy one
into another consumer and assume it has an effect.

### Secret handling and fallback

Generate independent signing and grant secrets on a trusted operator machine,
for example with `openssl rand -hex 32`, and store them in the approved secret
stores. The same signing value belongs in gateway, host worker, and Cloudflare
secret storage; the same grant value belongs in those same three consumers.
Never place either value in Wrangler `[vars]`, a committed `.env` file, a URL, a
log, or a report. Use interactive `wrangler secret put` or the dashboard for the
edge secrets during an authorized deployment.

At gateway/host configuration load, the grant credential resolves as follows
when the dedicated variable is unset:

```text
OVID_CDN_GRANT_INTERNAL_SECRET, otherwise OVID_INTERNAL_API_SECRET
```

The edge has the same fallback. When a base URL enables CDN configuration, a
non-empty resolved value shorter than 32 bytes makes gateway/host configuration
loading throw. This documentation nevertheless treats explicit
`OVID_CDN_GRANT_INTERNAL_SECRET` agreement across all three as the v2 deployment
requirement, rather than relying on a shared fallback or changing the unrelated
internal-API credential.

`wrangler.toml`, `.env.example`, and `worker.env.example` contain public
placeholders and commented secret placeholders only. Their presence does not
configure or deploy anything.

## Startup and request failure behavior

`loadCdnConfig`, used by gateway and host worker, has these source-defined
rules:

- Empty `OVID_CDN_BASE_URL` returns no CDN config and is not itself a boot
  error.
- A configured base URL must be absolute HTTP(S), have no query/fragment, and
  be an origin with no non-root path. Invalid values fail configuration load.
- With a base URL, a missing/short `OVID_CDN_SIGNING_SECRET` fails configuration
  load; it must be at least 32 UTF-8 bytes.
- With a base URL configured, non-empty `OVID_CDN_TTL_SECONDS` must be a
  positive integer. Valid values are clamped to `60..3600`; malformed values
  fail configuration load.
- With a base URL configured, a non-empty resolved grant secret shorter than 32
  UTF-8 bytes fails configuration load.

At the edge, a missing signing secret returns `503 cdn_not_configured` before
token verification; a missing R2 binding returns the same error after a
successful grant assertion. Missing/invalid grant-check configuration, a short
grant secret, a network error, the two-second assertion timeout, malformed JSON,
and non-2xx assertion responses other than 403/404 fail closed as
`503 grant_check_unavailable`. An assertion 403/404 or a successful response
whose `active` member is not boolean `true` denies the read as
`403 grant_revoked`. Errors use `Cache-Control: no-store`.

For host-worker grant creation, an absent `OVID_GATEWAY_INTERNAL_URL` or a
secret shorter than 32 bytes produces typed `cdn_grant_not_configured` when CDN
publication is attempted. Grant-create non-2xx responses, network/timeout
failures, and invalid success payloads produce `cdn_grant_unavailable`; there
is no grantless-v1 fallback.

`OVID_GATEWAY_INTERNAL_URL` is parsed by `loadWorkerEnv` as an absolute HTTP(S)
base URL without credentials, query, or fragment. An invalid configured value
fails worker startup. An unset value does not prevent unrelated worker startup,
but the grant factory refuses CDN publication as above. Use an origin/base
value, not the full create path; the factory supplies `/internal/cdn-grants`.

## Root routes, listener, and reverse proxy

The gateway mounts grant routes on the **root Fastify instance**, before and
outside the authenticated `/cloud/v1` scope, only when its composed CDN config
has a grant credential of at least 32 bytes. There is intentionally no public
grantless route.

| Operation | Caller | Exact root path | Strict JSON body | Signed identity |
|---|---|---|---|---|
| Create immutable grant | Host worker | `POST /internal/cdn-grants` | `actorUserId`, `artifactId`, `displayName` only | `<actorUserId>:<artifactId>` |
| Assert active grant/version | Cloudflare Worker | `POST /internal/cdn-grants/assert-active` | `grantId`, `versionHash` only | `<grantId>:<versionHash>` |

Both send `X-Ovid-Timestamp: base64(decimal epoch seconds)` and
`X-Ovid-Signature: base64(HMAC-SHA256(secret, payload))`, where payload is:

```text
POST
<exact-root-path>
<signed-identity>
<decimal-epoch-seconds>
```

The gateway accepts signatures only inside its ±300-second window, so the
worker, gateway, and edge need correct clocks. The host-worker create timeout
is 5,000 ms; the edge assertion timeout is fixed at 2,000 ms and is not a
Wrangler variable.

The grant endpoints must be reachable from their respective service callers
without becoming browser APIs. The host worker needs create access and the
Cloudflare Worker needs assert access. Use private service networking where
possible. If a reverse proxy is needed, expose only the exact required POST
paths on a controlled internal/service hostname, retain HMAC and network
restrictions, and do not proxy a blanket `/internal/*` tree or add Firebase user
auth to these service routes.

Proxy requirements:

- Forward the method, body, `X-Ovid-Timestamp`, and `X-Ovid-Signature` unchanged.
- Preserve the exact root path. Do not strip it, add `/cloud/v1`, rewrite it, or
  append a query; the path and identity are HMAC-covered.
- Do not cache create/assert responses. Assertion responses are `no-store`.
- The existing documented `/cloud/*` reverse-proxy matcher does not cover these
  root paths; a separate, narrowly matched owner-controlled rule is required.
- Do not expose the gateway host port directly to the internet.

For the compose listener, the source composition uses `HOST=0.0.0.0` and
`PORT=8081` inside the gateway container, with only the configured host-side
loopback publication (`GATEWAY_HOST_PORT`, default `8082`) for the reverse
proxy. Bare-metal defaults differ (`127.0.0.1:8081`); whichever deployment is
used, the proxy and service callers must target the actual reachable listener.
No listener/proxy reachability was checked for this documentation revision.

## Grant-before-cache, revoke, and delete semantics

The edge performs token validation and the synchronous grant assertion before
R2 access, before every Worker Cache API lookup, and before either the cache or
R2 `If-None-Match` path can return 304. Grant answers are not cached. A revoked
or deleted grant therefore denies a subsequent request before a warm edge cache
hit or 304; if the grant service cannot be checked, the request fails closed
instead of using cached bytes.

`DELETE /cloud/v1/artifact-shares/:grantId` releases the owned grant. Deleting a
generated artifact first tombstones the source and synchronously closes its
dependent grants before source-byte deletion. Physical share-copy cleanup and
source storage failures have separate lifecycle handling; a successful grant
revocation is the access fence, not proof that every byte was physically
removed. Real revoke/delete behavior against a deployed warm Worker remains an
acceptance item, not a claim of this document.

Only successful, non-range GET object responses are candidates for the Worker
Cache API. Cache identity is the opaque object key plus signed content type and
cache class, not the bearer token. Immutable-share object responses use
`Cache-Control: public, max-age=31536000, immutable`; errors are `no-store`.
Revocation cannot recall bytes already downloaded by a client.

### HEAD, range, and revalidation

- `HEAD` still performs the grant check, then uses R2 `head`, bypasses the
  Worker cache, and returns 200 with metadata when the object exists.
- A single-range **GET** still performs the grant check, bypasses the Worker
  cache, resolves the range with R2 HEAD/GET, and returns 206. Malformed,
  multiple, or unsatisfiable ranges return 416 with `no-store`.
- A `Range` header on HEAD does not turn HEAD into a range GET; use GET when
  verifying 206 behavior.
- `If-None-Match` on GET can return 304 only after a fresh grant assertion.
  HEAD does not use the GET 304 path.
- `OVID_CDN_CACHE=off` disables cache reads/writes, not grant checks, HEAD, or
  range support.

### Active content and response headers

`text/html`, `application/xhtml+xml`, `image/svg+xml`, `text/xml`, and
`application/xml` are active types. Minting and edge response construction
force `Content-Disposition: attachment` for them even if inline was requested.
The edge also sends `X-Content-Type-Options: nosniff`, a restrictive CSP
`sandbox`, and `Referrer-Policy: no-referrer`; all object responses set
`Accept-Ranges: bytes`. Keep this content on the dedicated isolated origin and
verify the actual deployed headers before enablement.

## Authorized deployment handoff (not performed)

After the release blockers are resolved and an owner authorizes deployment:

1. Choose the isolated CDN origin and a private/restricted grant-service path.
   Configure the root listener/proxy rules above before setting the edge URL.
2. Bind `BUCKET` to the intended private bucket; do not enable public bucket or
   `r2.dev` access. Replace every Wrangler placeholder outside committed docs.
3. Provision the two secrets identically in their three consumers. Set the edge
   `OVID_CDN_GRANT_CHECK_URL` to the exact assertion URL and host-worker
   `OVID_GATEWAY_INTERNAL_URL` to the grant-create base.
4. Set matching CDN base/TTL values in gateway and host worker. Ensure
   `OVID_CDN_MAX_TTL_SECONDS` is not lower than the minted TTL. Do not add cache
   rules that bypass the Worker or serve `/o/*` without its grant check.
5. Rebuild and compare generated DB/storage/gateway/worker artifacts through
   the authorized release process, then perform the normal coordinated service
   rollout. Source edits and example files alone do not update generated dist
   or any running service.

### Pending real acceptance checklist

No item below was executed for this revision:

- Root listener and narrow reverse-proxy reachability for both exact paths;
  preservation of method/body/HMAC headers and no browser-facing grant route.
- Signed create/assert requests, wrong-secret/wrong-identity/timestamp denial,
  clock agreement, and 5 s create/2 s assert timeout fail-closed behavior.
- Deployed Worker binding, public vars, secret agreement, isolated custom
  origin, private R2 access, and minted v2 `g`/`v` claims.
- Warm-cache plain GET and conditional GET after grant revocation and after
  generated-artifact deletion: neither may return cached 200/304. Repeat with
  the grant service unavailable and require 503 rather than cached content.
- HEAD 200/metadata, single-range GET 206, invalid/unsatisfiable range 416, GET
  304 only while the grant is active, and the configured cache-off behavior.
- Active-content attachment/CSP/nosniff/referrer headers and origin isolation.
- Real R2 immutable-share copy metadata/SHA/HEAD evidence and deletion/late-PUT
  behavior, plus the separate generated-dist and full execution-matrix gates.

## Rotation and rollback

Rotate `OVID_CDN_SIGNING_SECRET` coordinately across edge, gateway, and host
worker; disagreement makes newly checked signatures fail. Rotate
`OVID_CDN_GRANT_INTERNAL_SECRET` coordinately across the same three consumers;
create/assert disagreement fails closed. Neither rotation recalls downloaded
bytes. Changing a source/example file is not a rotation.

For an authorized rollback, disabling CDN minting by unsetting the base URL in
gateway and host worker follows their normal configuration/release procedure.
That does not remove an already deployed Worker, cached data, grants, or stored
bytes; those require their own verified cleanup and acceptance steps.

## Verification status

This was a static source/documentation update under the heavy-command pause.
No tests, test runners, builds, typechecks, Cloudflare/R2 calls, deploys, service
actions, or live acceptance checks were run. Older deployed-state notes and
older test logs are not evidence for v2 or for this revision. Generated dist
rebuild/compare and all real gateway/R2/Cloudflare acceptance remain **pending**.
