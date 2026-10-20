# W12 — Cloudflare CDN acceleration for Ovid Cloud objects

Status: code complete, owner-gated deployment. No Cloudflare API call was made
and no production/DNS change was performed by this workstream.

## What this is

R2 already stores every workspace archive, generated artifact and attachment.
Before W12 every download URL was a **presigned S3 GET**, which cannot be
edge-cached: each signature is unique, so every load is an origin read.

W12 adds a signed-token path through a Cloudflare Worker:

```
https://cdn.ovidsi.com/o/<base64url(r2-key)>?t=<hmac>&e=<expiry>
    [&d=attachment][&fn=<filename>][&ct=<type/subtype>][&c=immutable|short]
```

- `t` is HMAC-SHA256 over `(version, key, expiry, disposition, filename,
  content-type, cache-class)`.
- The gateway mints it; the Worker verifies it before touching R2 or the
  cache. A missing/tampered/expired token is `403` with `Cache-Control:
  no-store`.
- The raw R2 key is base64url-encoded (opaque) and the Worker re-validates it
  (no absolute paths, `..`, backslashes, control chars or empty segments).
- No bucket listing is ever exposed. A valid token is required for every
  object read.

The canonical presigned mint remains in place:

```
GET /cloud/v1/artifacts/:id/url?source=generated|uploaded
GET /cloud/v1/sessions/:id/artifacts/:artifactId/url
```

W12 adds, additively:

```
GET /cloud/v1/artifacts/:id/cdn-url?source=generated|uploaded[&download=1]
GET /cloud/v1/sessions/:id/attachments/:attachmentId/cdn-url[&download=1]
```

Both reuse the exact ownership/type/status validation and the single HEAD
availability proof of the canonical mint, and answer the same typed codes:
`artifact_unavailable` (404), `artifact_incomplete` (409),
`artifact_storage_unavailable` (503). When `OVID_CDN_BASE_URL` is unset they
answer `503 cdn_not_configured`; the client (`ArtifactVaultClient.
mintPreferredUrl`) falls back to the canonical mint. **Enabling or disabling
the CDN never breaks artifact access.**

## Cache policy

| Object kind | Key | Cache-Control |
|---|---|---|
| Generated artifact (`users/<uid>/artifacts/<sid>/<uuid>-<sha16>-<name>`) | write-once, content-addressed | `public, max-age=31536000, immutable` |
| Uploads, workspace archives, browser state | named/mutable | `public, max-age=60, s-maxage=60, must-revalidate` + ETag |
| Any error (403/404/405/416/503) | — | `no-store` |

The Worker validates the token **before** consulting the Cache API. Cache
entries are keyed by object identity (the opaque key) plus the signed content
type and cache class — never by the per-mint token — so a new 15-minute
capability for the same object is an edge hit while an invalid token can never
read that entry. `Range` requests and `HEAD` bypass the cache. Only `200`
object responses are written.

`Vary: Origin, Accept-Encoding` is set when CORS is configured;
`Vary: Accept-Encoding` otherwise. Error responses are never cached.

## What is deliberately NOT CDN-cached

- **Chat transcripts** (`GET /cloud/v1/sessions/:id/messages`). They are
  per-user and mutable. W12 instead adds an **ETag + `If-None-Match` → 304**
  with `Cache-Control: private, no-cache` and `Vary: Authorization`: an
  unchanged repeat load transfers no body, but no shared cache (Cloudflare
  included) may store it. Ownership is checked before the ETag comparison, so
  a foreign user still gets the same 404.
- Authenticated JSON API responses in general. Cloudflare does not cache
  responses to requests carrying `Authorization` unless explicitly told to;
  we do not add such a rule.
- The 304 win is bandwidth + client parse, not DB work: the gateway still
  reads the page and hashes it to decide. A CDN/edge cache of transcripts
  would be a privacy and freshness regression, so it is deliberately absent.
- Large tool outputs: they are already capped at 8 KiB in `tool_completed`
  events and are not inlined into message rows. Attachments are already
  metadata-only in `MessageDto`; their bytes live in R2 and are served through
  the CDN route. No transcript payload-offload was needed.

### Edge compression

The gateway returns JSON; compression is intentionally left to the edge:
- Cloudflare compresses cacheable and dynamic responses automatically for
  supported content types (gzip/brotli), subject to the zone's Brotli setting.
- For the Caddy-fronted API, add `encode zstd gzip` to the `api.ovidsi.com`
  site block (or keep it in the global options block). This is a deploy-time
  Caddy change, not applied by this workstream.
- The messages route sets `Vary: Accept-Encoding`, so a cache that does
  compress keys variants correctly.

### Client hookups (no edits to W9-owned chat_screen.dart)

- **Inline artifact images.** When the worker has `OVID_CDN_*`, the
  `artifact_created` event's `url` is already a signed CDN URL. The existing
  projection (`event_projection.dart`) puts it on `MessageAttachment.url`, and
  `cloudArtifactIdOf` now decodes the opaque CDN path to recover the artifact
  id, so the chip's re-mint path keeps working. No chat-screen change is
  needed.
- **Conditional GET for transcripts.** The server answers `ETag` /
  `304`. The chat client does not send `If-None-Match` yet. The intended hook
  (W9): an optional `ifNoneMatch` parameter on the messages loader (or an
  optional `headers` parameter on `CloudRestClient.getJson`), with the last
  ETag kept in MEMORY per (session, page window) — never persisted — and a 304
  reusing that in-memory page. Do not add a CDN cache rule for this route.
- **Artifact preview/download/share.** `ArtifactVaultClient.mintPreferredUrl`
  (added in `artifact_vault.dart`) prefers `/cdn-url` and falls back to the
  canonical `/url` on `cdn_not_configured`. Preview is inline; share/open-with
  request `download=1` (attachment disposition).

## Owner dashboard / DNS steps

1. **Generate the signing secret** (once, on a trusted machine):
   `openssl rand -base64 48` (must be >= 32 bytes). Store it in a password
   manager. You will set the same value in three places:
   - gateway `cloud/deploy/.env`: `OVID_CDN_SIGNING_SECRET=...`
   - host worker `/opt/ovid-cloud/worker.env`: same value
   - Cloudflare Worker secret: same value
   Do not commit any of them.
2. **Create the Worker**: Cloudflare dashboard → Workers & Pages → Create →
   Worker. Paste `cloud/deploy/cdn/worker.js` (or `wrangler deploy` from this
   directory once you add your account id). Name it e.g. `ovid-cdn`.
3. **Bind the bucket**: Worker → Settings → Bindings → Add → R2 bucket.
   Variable name **`BUCKET`**, bucket **`ovid-cloud`** (must match
   `OVID_R2_BUCKET`).
4. **Worker variables/secrets**:
   - `OVID_CDN_SIGNING_SECRET` — secret, same value as step 1.
   - `OVID_CDN_ALLOWED_ORIGINS` — optional comma-separated list, e.g.
     `https://ovidsi.com,https://app.ovidsi.com`. Needed only if a browser
     fetches images/HTML from the CDN. Android needs no CORS.
   - `OVID_CDN_MAX_TTL_SECONDS` — optional, default `3600`. Tokens with more
     remaining life than this are rejected.
   - `OVID_CDN_CACHE` — optional; set `off` to disable the Worker Cache API
     while keeping signed reads.
5. **Custom domain / DNS**: Worker → Settings → Domains & Routes → Add →
   Custom domain → `cdn.ovidsi.com`. Cloudflare creates the DNS record
   automatically when `ovidsi.com` is in the same account/zone. If it is not,
   create a proxied CNAME `cdn` → `<worker-name>.<account-subdomain>.
   workers.dev` (orange cloud). The Worker must be reachable on the custom
   domain for the Cache API to work.
6. **Keep the bucket private**: R2 → `ovid-cloud` → Settings. Do **not** enable
   public access or an `r2.dev` URL. The Worker is the only public read path.
7. **Cache rules**: do not add a Cloudflare Cache Rule that bypasses or
   overrides `cdn.ovidsi.com/o/*`. The Worker sets `Cache-Control` and uses the
   Cache API itself; a full-URL cache rule would fragment entries by token.
   Tiered Cache / Argo are compatible. Ensure the zone does not have a global
   "Bypass cache" rule for `cdn.ovidsi.com/*`.
8. **Gateway + worker env**: add the three variables from step 1/`README` to
   `cloud/deploy/.env` (gateway) and `/opt/ovid-cloud/worker.env` (host
   worker), then restart those services. If `OVID_CDN_BASE_URL` is unset the
   feature stays off and behavior is unchanged.
9. **Verify** (from a machine with a valid Firebase ID token):
   ```
   curl -s -H "Authorization: Bearer $TOKEN" \
     "https://api.ovidsi.com/cloud/v1/artifacts/$ID/cdn-url?source=generated"
   # → {"url":"https://cdn.ovidsi.com/o/...","expiresAt":"...","cacheClass":"immutable"}
   curl -sI "https://cdn.ovidsi.com/o/...?t=...&e=..."      # 200 + cache-control
   curl -s  "https://cdn.ovidsi.com/o/...?t=bad&e=..."      # 403
   curl -sI -H "Range: bytes=0-99" "<valid url>"            # 206
   ```
   Then repeat the mint and confirm the second request is served from the edge
   (Cloudflare analytics: cached vs origin).

## Secret rotation

Rotating `OVID_CDN_SIGNING_SECRET` invalidates every outstanding CDN URL
within its TTL (max 1 hour). Set the new value on the Worker first, then the
gateway and host worker, then restart. Presigned fallback URLs are unaffected.

## Local verification (no Cloudflare account)

The Worker is a dependency-free ES module. Its token logic is cross-checked
against the gateway implementation:

```bash
cd cloud
pnpm --filter @ovid/storage test -- cdn.test.ts cdnWorker.test.ts
pnpm --filter @ovid/gateway test -- artifactCdn.test.ts messagesEtag.test.ts
```

`cdnWorker.test.ts` drives `handleRequest` with a fake R2 binding and cache:
valid/tampered/expired tokens, traversal keys, HEAD, Range, 304, CORS,
attachment disposition, immutable vs short TTL, and cache-hit-without-token
rejection.

## Honest limits

- The URL query string carries a bearer capability; anyone with the URL can
  read the object until it expires. Keep TTLs short (default 15 min) and never
  log URLs.
- Browser HTML/SVG previews run with a restrictive `Content-Security-Policy:
  sandbox` on an isolated origin. Some previews that need same-origin storage
  or top-level navigation will not work; scripts inside the sandbox are
  allowed.
- Pure hash-only deduplication is not used: `workspace_objects.r2Key` is
  UNIQUE and object deletion is not refcounted. Keys are content-addressed
  (`<uuid>-<sha256[0..16]>-<name>`) and write-once, which is what justifies
  `immutable`.
- `Range` and `HEAD` are origin reads (not edge-cached). Media players that
  issue many ranges will not benefit from the object cache.
- Cloudflare's Cache API is per-colo and best-effort; a cold colo pays one
  origin read. This is normal edge behavior, not a correctness issue.
- The Worker does not transform images (no resizing/format conversion); it
  streams the stored bytes.

---

## Deployed state (2026-10-20)

Set up from the logged-in Cloudflare dashboard session on the VPS:

| Item | Value |
|---|---|
| Cloudflare account | `7fb570ac615a8e2a41a6aff7913114d5` |
| Zone | `ovidsi.com` (`649119932e1529b4b5f74977e329e681`) |
| Worker | `ovid-cdn` (version deployed via `wrangler deploy`) |
| R2 binding | `BUCKET` → `ovid-cloud` |
| Secret | `OVID_CDN_SIGNING_SECRET` set on the Worker |
| Custom domain | `cdn.ovidsi.com` attached to the Worker (cert issued) |
| Gateway/worker env | `OVID_CDN_BASE_URL=https://cdn.ovidsi.com`, `OVID_CDN_TTL_SECONDS=900`, same signing secret in `cloud/deploy/.env` and `/opt/ovid-cloud/worker.env` |
| Services restarted | `ovid-cloud-gateway-1` (healthy), `ovid-worker` (active) |

Verification performed:

- DNS: `cdn.ovidsi.com` resolves (Cloudflare anycast).
- Unsigned key → `403`; tampered token → `403`; expired token → `403`; no token → `403`.
- Valid signed token for a missing key → `404` (token accepted, object absent).
- Valid signed token for a real object → `200`, correct `Content-Type`, `Cache-Control: public, max-age=60, s-maxage=60, must-revalidate`, `ETag`, `X-Content-Type-Options: nosniff`.

Rollback: unset `OVID_CDN_BASE_URL` in both env files and restart; clients fall back to the
canonical presigned mint automatically. To disable at the edge, remove the custom domain or
delete the Worker — artifact access is unaffected because the presign path remains canonical.
