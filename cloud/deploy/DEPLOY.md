# Ovid Cloud — activation runbook (owner-run)

Deploys the Ovid Cloud P0 spine (`gateway`, `worker`, `redis-q`) **alongside**
the live `ovid-gateway` stack on the production VPS, provisions the
`ovid_cloud` database on the live Postgres, routes `https://api.ovidsi.com/cloud/*`
through the live Caddy, and installs nightly Postgres backups.

Everything below is deliberately manual and ordered: each step has a
verification gate and a rollback. Read §0 (facts + port collision) before
starting.

---

## 0. Facts about this box (verified 2026-10-16)

- Live compose project `ovid-gateway` at `/opt/ovid-gateway`: caddy
  (**host network**), mint `127.0.0.1:8090`, litellm `127.0.0.1:4000`,
  account-dev `127.0.0.1:8080`, postgres + redis (**no host ports**, reachable
  only on the docker network `ovid-gateway_internal` under the DNS names
  `ovid-gateway-postgres-1`, `ovid-gateway-redis-1`, `ovid-gateway-mint-1`,
  `ovid-gateway-litellm-1`). Live databases: `litellm`, `ovid_account_dev`,
  `postgres`.
- **⚠ Host port 8081 is NOT free.** The live Caddy itself listens on
  `127.0.0.1:8081` (admin-dashboard site block at the bottom of the Caddyfile
  → LiteLLM UI). The gateway therefore publishes on
  `127.0.0.1:${GATEWAY_HOST_PORT}` — **default 8082** — and the Caddy snippet
  proxies `/cloud/*` to `127.0.0.1:8082`. Inside its container the gateway
  listens on `0.0.0.0:8081` (fixed; `HOST=0.0.0.0` is required because
  docker-proxy forwards published ports to the container's bridge IP, never
  its loopback). If 8082 is ever taken, change `GATEWAY_HOST_PORT` in `.env`
  **and** the port in the Caddyfile snippet together.
- `/opt/ovid-gateway/firebase-admin.json` exists (Firebase Admin SDK
  credentials) — see §3 for the mount-vs-copy decision.
- Disk at task time: ~44 GB free. Backups go to `/opt/ovid-backups/pg` with a
  2 GB free-space guard (see `backup/README.md`).

## 1. Layout + prerequisites

Checkout layout this runbook assumes (adjust unit paths if different):

```
/opt/ovid-cloud/
├── repo/                 # git clone of the OvidAI monorepo (this repo)
│   └── cloud/deploy/     # compose, Dockerfiles, provision.sh, backup/
├── backup.env            # optional: BACKUP_*/OVID_R2_* for the timer (§8)
└── (repo/cloud/deploy/.env — the filled deploy env, git-ignored, §2)
```

Prerequisites on the box: `docker` + compose plugin (v5 verified), `zstd`,
Node 22 + `corepack enable` (for the host-side build provision.sh needs),
`openssl`. The live `ovid-gateway` stack must be **up and healthy**
(`docker ps`), and `ovid-gateway_internal` must exist
(`docker network inspect ovid-gateway_internal`).

```bash
git clone <repo-url> /opt/ovid-cloud/repo        # or: git pull if it exists
cd /opt/ovid-cloud/repo/cloud
corepack enable && pnpm install --frozen-lockfile && pnpm -r build
```

## 2. Author `.env` (secrets — never commit, never paste into tickets)

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
cp .env.example .env && chmod 600 .env
```

Fill every `CHANGE_ME` (the template comments explain each var):

| Var | How to fill |
| --- | --- |
| `OVID_CLOUD_DB_PASSWORD` | `openssl rand -hex 24` (alphanumeric only — provision.sh validates) |
| `DATABASE_URL` | same password, verbatim template otherwise |
| `REDIS_Q_PASSWORD` + `REDIS_Q_URL` | fresh `openssl rand -hex 24`, kept equal |
| `REDIS_MINT_URL` | password = `REDIS_PASSWORD` from `/opt/ovid-gateway/.env` (db **2** selector is part of the template URL) |
| `OVID_DEFAULT_MODEL` | a model alias configured in the live LiteLLM (dashboard via SSH tunnel on `127.0.0.1:8081`) |
| `GATEWAY_HOST_PORT` | leave `8082` (see §0) |
| everything else | template values are correct for this box |

`OVID_AUTH_MODE` must stay `firebase` with `NODE_ENV=production` (the gateway
refuses `test` auth in production). `OVID_RUN_STALE_MS` stays commented unless
overriding (an **empty** value makes the worker refuse to boot).

## 3. GOOGLE_APPLICATION_CREDENTIALS — mount vs copy (owner decision)

The gateway verifies Google ID tokens via firebase-admin and needs a
credentials file inside the container.

- **Mount (default, recommended):** compose bind-mounts
  `${FIREBASE_CREDENTIALS_HOST_PATH:-/opt/ovid-gateway/firebase-admin.json}`
  **read-only** to `/etc/ovid/firebase-admin.json`; `.env`'s
  `GOOGLE_APPLICATION_CREDENTIALS` already points there. No copy, no drift —
  but the ovid-cloud stack depends on that file staying put (it is also used
  by account-dev, so it is not going anywhere).
- **Copy:** `install -m 600 /opt/ovid-gateway/firebase-admin.json
  /opt/ovid-cloud/firebase-admin.json`, then set
  `FIREBASE_CREDENTIALS_HOST_PATH=/opt/ovid-cloud/firebase-admin.json` in
  `.env`. Rotation now means rotating **both** copies — document it wherever
  credentials are rotated.

Either way the file is read-only inside the container and never enters the
repo/image.

## 4. Provision the database (idempotent)

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
./provision.sh --dry-run     # validates env/infra/build/compose, mutates NOTHING
./provision.sh               # real run
```

The real run: creates Postgres role `ovid_cloud` (LOGIN, password from
`OVID_CLOUD_DB_PASSWORD`) **if absent**, creates database `ovid_cloud`
(owner `ovid_cloud`) **if absent**, applies drizzle migrations via
`packages/db/dist/migrate-cli.js` in an **ephemeral, read-only-mounted
`node:22-alpine` container** on `ovid-gateway_internal`, then re-validates
`docker compose config -q`. Re-running at any time is safe (existence guards +
migration journal). It never touches other databases/roles or any live
container.

Gate: output ends with `compose config OK` + the next-steps block.

## 5. Start the stack

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
docker compose up -d --build        # first run builds both images (a few minutes)
docker compose ps                   # gate: all three Up, gateway (healthy)
docker compose logs -f gateway worker   # no crash loops; worker logs "consuming agent-runs"
```

Startup order is enforced by `depends_on`: `redis-q` must be **healthy**
(auth'd `redis-cli ping`) before `gateway` starts; `worker` waits for
`redis-q` healthy + `gateway` *started* (its health is deliberately not a
gate — a degraded gateway must not stop run processing).

Loopback smoke (before any Caddy change — public traffic is untouched):

```bash
curl -sf http://127.0.0.1:8082/cloud/v1/health
# gate: {"status":"ok","checks":{"db":true,"redisQ":true}}
```

`status:"degraded"` (503) → check `docker compose logs gateway`; the
`checks` object says which backend (db / redisQ) is failing.

Rollback for this step alone: `docker compose down` (add `-v` only if you
also want to discard queue data — normally you don't).

## 6. Route `https://api.ovidsi.com/cloud/*` (the only live-stack change)

The Caddyfile is bind-mounted **read-only** into `ovid-gateway-caddy-1`, so
edits happen on the host and are picked up by `caddy reload` (no container
restart, zero downtime for existing connections).

```bash
cd /opt/ovid-gateway/caddy

# 1. Timestamped backup (rollback anchor)
cp Caddyfile "Caddyfile.bak-$(date -u +%Y%m%dT%H%M%S)"

# 2. Insert the snippet: open deploy/caddy-snippet.conf and copy its
#    `handle /cloud/* { … }` block INTO the api.ovidsi.com site block,
#    immediately AFTER the `import ovid_public` line. The file header
#    explains placement, why `handle` (not handle_path), and the port.
$EDITOR Caddyfile

# 3. Validate with the container's own caddy binary (same version/config
#    path as the running server):
docker exec ovid-gateway-caddy-1 caddy validate \
  --config /etc/caddy/Caddyfile --adapter caddyfile
# gate: "Valid configuration"

# 4. Reload (SIGHUP-free admin-API reload; other site blocks keep serving):
docker exec ovid-gateway-caddy-1 caddy reload \
  --config /etc/caddy/Caddyfile --adapter caddyfile

# 5. Health through the public route:
curl -sf https://api.ovidsi.com/cloud/v1/health
# gate: {"status":"ok","checks":{"db":true,"redisQ":true}}
curl -s -o /dev/null -w '%{http_code}\n' https://api.ovidsi.com/v1/models   # gate: live stack unaffected (200/401)
```

**Rollback (cold-followable):**

```bash
cd /opt/ovid-gateway/caddy
cp Caddyfile.bak-<TIMESTAMP> Caddyfile
docker exec ovid-gateway-caddy-1 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec ovid-gateway-caddy-1 caddy reload  --config /etc/caddy/Caddyfile --adapter caddyfile
curl -s -o /dev/null -w '%{http_code}\n' https://api.ovidsi.com/cloud/v1/health   # expect 404 again
curl -sf https://api.ovidsi.com/v1/models >/dev/null && echo "live stack OK"
```

## 7. Functional smoke (manual, owner)

1. From a real app build (Firebase token + App Check): create session →
   POST message → watch WS `/cloud/v1/ws?ticket=…` replay + live deltas →
   run completes. (Ticket flow: `POST /cloud/v1/ws/tickets` first.)
2. Degradation spot-check (optional): `docker compose stop worker` → message
   accepted, run stays `queued` (503-style behaviours documented in the P0
   plan); `docker compose start worker` → run picked up and processed.

## 8. Nightly backups

```bash
sudo install -d -m 700 /opt/ovid-backups/pg
sudo cp /opt/ovid-cloud/repo/cloud/deploy/backup/ovid-cloud-backup.{service,timer} \
  /etc/systemd/system/
# optional offsite/config overrides:
sudo $EDITOR /opt/ovid-cloud/backup.env    # chmod 600; template: .env.example "Backups"
sudo systemctl daemon-reload
sudo systemctl enable --now ovid-cloud-backup.timer
systemctl list-timers ovid-cloud-backup.timer          # gate: next run 03:30 UTC
sudo systemctl start ovid-cloud-backup.service         # first run NOW (manual gate)
journalctl -u ovid-cloud-backup.service -n 50          # gate: "done: … in /opt/ovid-backups/pg/<ts>"
```

Then **run one restore drill** (scratch postgres, foreign-host flavour) per
`backup/README.md` §"Restore to a FOREIGN postgres" and delete the scratch
container. Dumps cover all live DBs (litellm, ovid_account_dev, postgres,
ovid_cloud) — 14-day local retention, optional R2 offsite.

## 9. Verification checklist (all gates green = activated)

- [ ] `./provision.sh --dry-run` clean **before** the real run; real run ends
      `compose config OK`
- [ ] `docker compose ps`: redis-q (healthy), gateway (healthy), worker Up;
      no restart loops in `docker compose logs`
- [ ] `curl -sf http://127.0.0.1:8082/cloud/v1/health` → `status:"ok"`
- [ ] `caddy validate` passed **before** reload; public
      `https://api.ovidsi.com/cloud/v1/health` → `status:"ok"`
- [ ] Existing routes unaffected: `/v1/models`, `/mint`, `/healthz` behave as
      before the reload
- [ ] Functional smoke (§7) passes with a real Firebase token
- [ ] `systemctl list-timers` shows next backup ≤ 24 h away; first manual run
      produced `<ts>/*.dump.zst` passing `zstd -t`
- [ ] Restore drill (§8) verified `\dt` count > 0 on a scratch postgres
- [ ] No secrets committed: `cd /opt/ovid-cloud/repo && git status` clean
      (`.env`, `backup.env` are ignored / outside the repo)

## 10. Redeploys + decommission

- **Redeploy** (new code): `cd /opt/ovid-cloud/repo && git pull`, then
  `cd cloud && pnpm install --frozen-lockfile && pnpm -r build` (host build
  for migrate-cli), `cd deploy && ./provision.sh` (idempotent — applies new
  migrations), `docker compose up -d --build` (rebuilds images, rolling
  restart of gateway/worker only).
- **Decommission**: §6 rollback (Caddy) → `docker compose down` (keep `-v`
  off to retain queue data) → optionally
  `sudo systemctl disable --now ovid-cloud-backup.timer` → the `ovid_cloud`
  DB/role can stay dormant (backups keep covering it) or be dropped after a
  final manual dump.
