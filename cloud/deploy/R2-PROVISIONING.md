# R2 provisioning + P7 storage activation (OWNER RUNBOOK)

**Status: GATED. Do not run the steps marked LIVE until the owner explicitly
approves activation.** This document is the P7 Task 14 deliverable: the
artifacts (env templates, `redis-c`, worker wiring, `verify-r2.mjs`) are
committed, but every step that touches Cloudflare or the live box is
owner-run. Same precedent as the P1 Task 11 activation and `DEPLOY.md` §11.

- **Autonomous / safe:** authoring `.env` files on paper, reading this
  document, `docker compose config -q`, `node --check`.
- **LIVE (owner approval required):** creating the bucket, minting the API
  token, writing real secrets, `docker compose up`, creating `/workspaces`,
  running migrations, restarting the worker, flipping the backend.

Related: `DEPLOY.md` §12 (what changed), `cloud/deploy/.env.example`,
`cloud/deploy/worker.env.example`, `cloud/scripts/verify-r2.mjs`.

**Env file paths (canonical).** The gateway env is
`/opt/ovid-cloud/repo/cloud/deploy/.env` — the compose `env_file: [.env]`
next to `docker-compose.yml`, which is also the `$SCRIPT_DIR/.env` that
`provision.sh` reads. Do not create `/opt/ovid-cloud/.env`; that path is
stale. The host worker env is `/opt/ovid-cloud/worker.env`.

---

## Step 1 — Create the bucket (LIVE, owner)

Cloudflare dashboard → **R2** → **Create bucket**.

| Setting | Value |
| --- | --- |
| Name | `ovid-cloud` |
| Location hint | closest to the VPS (optional) |
| Default storage class | Standard |

- **No CORS configuration is needed.** All access is server-side through the
  S3 API (gateway, host worker, `verify-r2.mjs`, backups). Browsers and
  agents never talk to R2 directly (spec §10/D7).
- Do **not** enable public access / a public `r2.dev` URL. Objects are
  private; reads are presigned by the gateway.

## Step 2 — API token, least privilege (LIVE, owner)

R2 → **Manage API Tokens** → **Create API Token**.

- Permissions: **Object Read & Write**.
- Scope: **Apply to specific buckets only → `ovid-cloud`**.
- **No account-admin / billing / bucket-admin permission.**
- TTL: per owner policy (rotate on the same schedule as the other deploy
  secrets; record the expiry in the owner's secret log).
- Copy the **Access Key ID** and **Secret Access Key** — Cloudflare shows the
  secret **once**. (These are Cloudflare-generated; `openssl` is only used
  for the OTHER secrets below.)

Store them in `/opt/ovid-cloud/repo/cloud/deploy/.env` (gateway) and
`/opt/ovid-cloud/worker.env` (host worker), then `chmod 600` both:

```bash
sudo install -m 600 /dev/null /opt/ovid-cloud/repo/cloud/deploy/.env   # if not present
sudo install -m 600 /dev/null /opt/ovid-cloud/worker.env               # if not present
```

**Agents and containers see only the environment variables** — they never
receive Cloudflare credentials, and neither file may be committed or pasted
into tickets (D7).

## Step 3 — Lifecycle rules (LIVE, owner)

Bucket → **Settings → Object lifecycle rules**.

1. **AbortIncompleteMultipartUpload: 7 days — REQUIRED.**
   Crashed/interrupted multipart packs otherwise leak invisible storage
   forever (aborted parts are not listed as objects but are billed). The
   uploader sets `leavePartsOnError: false`; this rule is defense in depth.
2. **Backup prefix:** the P1 backup script uploads under **`pg/{TS}/…`**
   (see `cloud/deploy/backup/pg_backup.sh`). The spec writes
   `backups/pg/…`; the rule must target the **actual** prefix. Recommended:
   **no expiration** for `pg/` (backups are the recovery floor); optionally
   transition to an infrequent-access class when available.
3. Workspace/archive objects under `users/` follow application lifetime
   (hibernation + artifacts); no bucket-wide expiration rule. Do not add one
   without an owner decision.

## Step 4 — Fill the storage block (LIVE, owner)

Edit both files. The shared values must match.

### 4.1 `/opt/ovid-cloud/repo/cloud/deploy/.env` (gateway)

Copy the `# ── Storage (P7) ──` block from
`cloud/deploy/.env.example` and fill:

| Variable | Value / how to generate |
| --- | --- |
| `OVID_STORAGE_BACKEND` | `r2` |
| `OVID_R2_ACCOUNT_ID` | R2 dashboard account id (hex, not the email) |
| `OVID_R2_ACCESS_KEY_ID` | token Access Key ID (step 2) |
| `OVID_R2_SECRET_ACCESS_KEY` | token Secret Access Key (step 2) |
| `OVID_R2_BUCKET` | `ovid-cloud` |
| `OVID_INTERNAL_TOKEN` | `openssl rand -hex 32` — the SAME value in worker.env |
| `OVID_WORKER_FILE_PORT` | `8091` |
| `OVID_WORKER_INTERNAL_URL` | `http://host.docker.internal:8091` (the worker is HOST systemd; the gateway declares `host.docker.internal:host-gateway`) |
| `REDIS_C_URL` | `redis://:<REDIS_C_PASSWORD>@redis-c:6379` |
| `REDIS_C_PASSWORD` | `openssl rand -hex 24` |
| `REDIS_C_HOST_PORT` | `6393` (loopback publication for the host worker) |
| `OVID_MAX_WARM_GB` | `8` (owner may retune to 12 at activation — see §6.5) |
| `OVID_DISK_ALERT_PCT` | `80` |

The backup block at the bottom of the same file may reuse the SAME R2 token
(`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` = the Access Key ID / Secret
Access Key) — one token, two consumers. The backup script's aws CLI needs
the bucket-scoped read/write permission it already has.

### 4.2 `/opt/ovid-cloud/worker.env` (host systemd worker)

Copy the `# ── Storage (P7) ──` block from
`cloud/deploy/worker.env.example`. Same R2 values and
`OVID_INTERNAL_TOKEN` / `REDIS_C_PASSWORD`, plus:

| Variable | Value |
| --- | --- |
| `OVID_STORAGE_BACKEND` | `r2` |
| `REDIS_C_URL` | `redis://:<REDIS_C_PASSWORD>@127.0.0.1:6393` (loopback, NOT `redis-c`) |
| `OVID_WORKER_FILE_PORT` | `8091` |
| `UV_THREADPOOL_SIZE` | `8` |
| `OVID_MAX_WARM_GB` | `8` (same value as gateway) |
| `OVID_DISK_ALERT_PCT` | `80` |
| `OVID_INLINE_MAX_BYTES` | optional; default `1048576` |

**Inline-cap name divergence (P7 Task 12):** the gateway reads
`OVID_FILE_INLINE_MAX_BYTES`; the worker reads `OVID_INLINE_MAX_BYTES`.
Keep the two VALUES equal (default 1 MiB) or the gateway may inline a file
the worker refuses to serve inline. Both names are documented in
`.env.example` with this note.

`/workspaces` is already the P2 XFS project-quota mount
(`deploy/workspaces/setup-workspaces.sh`, `DEPLOY.md` §11 step 3). No P7
mount is needed for the host worker; `OVID_WORKSPACES_ROOT=/workspaces/users`
is unchanged.

## Step 5 — Verify the credentials (LIVE, owner)

Build the storage dist once if the deployed checkout has none:

```bash
cd /opt/ovid-cloud/repo
pnpm --filter @ovid/storage build
```

Run the least-privilege probe (put 1 KiB → head → get → presigned GET →
delete → head-null; it prints only the account id's first 8 chars and the
bucket, never the token or URL):

```bash
cd /opt/ovid-cloud/repo
set -a; . /opt/ovid-cloud/repo/cloud/deploy/.env; set +a
node cloud/scripts/verify-r2.mjs
```

Expected: seven `[ok]` lines (`config`, `put`, `head`, `get`, `presign`,
`delete`, `gone`) and exit 0. Any `[FAIL]` prints the variable/check that
failed and exits 1. The probe object lives at
`users/_probe/<uuidv7>.txt` and is deleted on every path.

Then run the P7 live contract suite once (it exercises the full adapter:
multipart upload, readers, presign-PUT):

```bash
cd /opt/ovid-cloud/repo/cloud
OVID_R2_ACCOUNT_ID=… OVID_R2_ACCESS_KEY_ID=… OVID_R2_SECRET_ACCESS_KEY=… \
OVID_R2_BUCKET=ovid-cloud \
pnpm --filter @ovid/storage exec vitest run src/r2.live.test.ts
```

Expected: green (not skipped). The suite's cleanup lists and deletes its
`users/_test-<uuid>/` prefix — Cloudflare's bucket-scoped **Object Read &
Write** permission covers that. If a narrower custom policy is used, add
`ListBucket` on `ovid-cloud` only; nothing else (no account admin) is
needed.

## Step 6 — ACTIVATION (STOP — owner approval required)

> **STOP CONDITION.** Do not proceed past this line without explicit owner
> approval. Steps 6.1–6.6 have live-box side effects and consume real
> credentials. Present this runbook to the owner first.

Prerequisites: steps 1–5 green; both env files filled and `chmod 600`;
`/opt/ovid-cloud/repo` checked out at the activated commit.

### 6.1 Dry validation (no side effects)

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
docker compose config -q
node --check ../scripts/verify-r2.mjs
```

### 6.2 Bring up redis-c + the updated gateway

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
docker compose up -d --build
```

`--build` is REQUIRED: the P7 gateway imports `@ovid/storage` (and other
lanes' packages), and Compose would otherwise reuse a pre-P7 image that does
not contain them. (This matches `DEPLOY.md`'s first-run command.)

This starts `redis-c` (plus the existing services) and recreates the gateway
with the `redis-c` dependency and `host.docker.internal` mapping. It does
**not** start the worker (host systemd).

Gates:

```bash
docker compose ps                                  # redis-c healthy, gateway up
redis-cli --no-auth-warning -a "$REDIS_C_PASSWORD" -p 6393 ping   # → PONG
ss -tlnp | grep -E ':(6393|8082)\b'                # loopback binds only
```

### 6.3 `/workspaces`

Already created by `DEPLOY.md` §11 step 3. If this is a fresh box, run
`deploy/workspaces/setup-workspaces.sh` (owner-gated) and re-check:

```bash
stat -fc %T /workspaces          # → xfs
mount | grep prjquota            # → the volume, mounted with prjquota
```

### 6.4 Migrations

P7's tables (`file_manifests`, `workspace_objects`) are migrations
**0006/0007**; the CLI applies every pending migration in the journal:

```bash
cd /opt/ovid-cloud/repo/cloud
node packages/db/dist/migrate-cli.js "$DATABASE_URL"
```

(Plan text said "applies 0001"; that is stale — the journal is authoritative
and the CLI applies all pending entries.)

### 6.5 Smoke: hibernate/hydrate round-trip

Restart the worker so it picks up `worker.env`:

```bash
sudo systemctl restart ovid-worker
systemctl is-active ovid-worker                    # → active
ss -tlnp | grep ':8091\b'                          # worker file service
journalctl -u ovid-worker -n 80 --no-pager          # no boot refusal
```

From a real client (or the e2e harness against production), on a scratch
session:

1. Seed a file in the warm workspace.
2. `POST /cloud/v1/sessions/:id/hibernate` (or wait for the 180 s idle
   sweeper) → poll state to `cold`; the local warm dir disappears.
3. `GET` the session tree → `source:"manifest"` with no worker call.
4. `GET` the seeded file cold → byte-identical.
5. `POST /cloud/v1/sessions/:id/hydrate` → state `warm`; full-tree checksum
   matches the pre-hibernate tree.
6. `GET /cloud/v1/artifacts` → the hibernation/sidecar artifacts listed and
   presignable.

If the host firewall blocks container → host traffic on 8091, allow the
Docker bridge interface only (the file service is token-gated, but it must
never be internet-reachable).

### 6.6 Confirm and make permanent

- `r2.live` suite green (step 5).
- `node cloud/scripts/verify-r2.mjs` green again.
- Confirm `OVID_STORAGE_BACKEND=r2` is in BOTH live env files (the templates
  already ship `r2`; activation makes it permanent).
- Record in the owner log: bucket, token TTL/rotation date, the chosen
  `OVID_MAX_WARM_GB` (8 default; the 8 → 12 GB retune is the owner's call —
  P7 Task 10 budget math, coordinated with the backup free-space floor and
  the 80 % disk alert), and the date/time of activation.

### Rollback

- Worker: `sudo systemctl stop ovid-worker`; restore the previous
  `worker.env` and `systemctl start ovid-worker`.
- Compose: `docker compose stop redis-c` (the gateway falls back to
  `REDIS_Q_URL` only when `REDIS_C_URL` is unset — remove that line and
  restart the gateway if redis-c must be retired).
- Storage: leave `OVID_STORAGE_BACKEND=r2` set only once verified; to roll
  back before any hibernation, revert both env files to the pre-P7 values
  and restart. Once workspaces have been hibernated, R2 is the authority —
  do NOT roll back to fs (the warm dirs are gone).

## Owner-gate checklist (copy into the approval thread)

- [ ] Step 1: bucket `ovid-cloud` created; public access off; no CORS.
- [ ] Step 2: token = Object Read & Write on `ovid-cloud` ONLY; no
      account-admin; TTL recorded; secret stored in both env files
      (`chmod 600`).
- [ ] Step 3: `AbortIncompleteMultipartUpload: 7 days` on the bucket;
      `pg/` has no expiration.
- [ ] Step 4: `.env` and `worker.env` storage blocks filled; shared values
      identical; inline caps both set to the same value; `OVID_MAX_WARM_GB`
      chosen (8 or 12).
- [ ] Step 5: `verify-r2.mjs` all `[ok]`; `r2.live.test.ts` green.
- [ ] Step 6.1: `docker compose config -q` + `node --check` exit 0.
- [ ] Step 6.2: redis-c healthy on 127.0.0.1:6393; gateway recreated.
- [ ] Step 6.3: `/workspaces` XFS + prjquota.
- [ ] Step 6.4: migrations applied.
- [ ] Step 6.5: hibernate → cold → manifest tree → cold file read →
      hydrate → checksum-identical warm tree; artifacts presign.
- [ ] Step 6.6: backend permanently `r2` in both env files; owner log
      updated (bucket, token TTL, warm-GB choice, timestamp).
