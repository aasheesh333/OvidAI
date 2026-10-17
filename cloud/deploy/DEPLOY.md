# Ovid Cloud — activation runbook (owner-run)

Deploys the Ovid Cloud stack **alongside** the live `ovid-gateway` stack on
the production VPS: the compose spine (`gateway`, `redis-q`, loopback
proxies `net-proxy-pg`/`net-proxy-mint`), the `ovid_cloud` database on the
live Postgres, the `https://api.ovidsi.com/cloud/*` route through the live
Caddy, nightly Postgres backups, and — P2 — the **host systemd worker**
(`ovid-worker.service` in `cloud/deploy/systemd/`) that runs user agent
sessions inside bwrap sandboxes.

Everything below is deliberately manual and ordered: each step has a
verification gate and a rollback. Read §0 (facts + port collision) before
starting. P2 (sandboxes) activation is §11 — it assumes the compose spine
is already up (§4–§6).

**There is exactly ONE gateway env file:**
`/opt/ovid-cloud/repo/cloud/deploy/.env`. The compose `env_file: [.env]`
resolves relative to `docker-compose.yml`, and `provision.sh` reads
`$SCRIPT_DIR/.env` — both land on that path. Do not create or fill
`/opt/ovid-cloud/.env`; any command naming it is stale. The host worker's
environment is a separate file: `/opt/ovid-cloud/worker.env`
(`EnvironmentFile=` in `systemd/ovid-worker.service`).

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
- **The box is 8 vCPU / 22 GB RAM** — the P2 capacity envelope (slice
  `CPUQuota=600%` + `MemoryMax=10G`, 24 concurrent sandboxes at 512 MiB) is
  derived from that; the arithmetic lives in the P2 plan's Global
  Constraints section and the per-env caps table in `HARDENING.md` item H.
- **`/workspaces` does not exist yet** — the XFS volume (project quotas for
  per-user workspace caps) is created by §11 step 3 and is a hard
  prerequisite for the P2 worker. Nothing else in this runbook needs it.
- P2 sandbox-hosting changes the box's threat model: a box that jails
  untrusted user code needs the `HARDENING.md` items **and** item H
  (sandbox surface) verified — see the cross-links there and in §11.

## 1. Layout + prerequisites

Checkout layout this runbook assumes (adjust unit paths if different):

```
/opt/ovid-cloud/
├── repo/                 # git clone of the OvidAI monorepo (this repo)
│   └── cloud/deploy/     # compose, Dockerfiles, provision.sh, backup/,
│                         # systemd/ (P2 units), workspaces/, rootfs/, net/
├── backup.env            # optional: BACKUP_*/OVID_R2_* for the timer (§8)
├── worker.env            # P2: the HOST worker's environment (§11 step 7)
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
| `GATEWAY_HOST_PORT` / `REDIS_Q_HOST_PORT` / `NET_PROXY_*_HOST_PORT` | leave `8082` / `6391` / `5434`+`6392` (see §0 + the proxy notes in `.env.example`) |
| everything else | template values are correct for this box |

`OVID_AUTH_MODE` must stay `firebase` with `NODE_ENV=production` (the gateway
refuses `test` auth in production). Most worker vars (`OVID_LITELLM_BASE`,
`OVID_RUN_STALE_MS`, …) live in `/opt/ovid-cloud/worker.env` (P2 — see §11
step 7 and `worker.env.example`). `OVID_DEFAULT_MODEL` is the exception:
`provision.sh` validates it in THIS file, so fill the same live LiteLLM alias
in both files.

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

**P4 — the host systemd worker also uses this file (FCM).** The worker sends
scheduled-task result pushes and unattended approval cards through Firebase
Cloud Messaging, which uses Application Default Credentials. There is no
container to mount into: `worker.env` sets
`GOOGLE_APPLICATION_CREDENTIALS=/opt/ovid-gateway/firebase-admin.json`
(direct host path, same file as the mount/copy decision above; keep the two
in sync if the copy variant is chosen). Missing/unreadable → pushes fail
soft and log once; runs, settle, and the API are unaffected.

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
docker compose up -d --build        # first run builds the gateway image (a few minutes)
docker compose ps                   # gate: redis-q, gateway, net-proxy-pg, net-proxy-mint
                                    # all Up; gateway (healthy)
docker compose logs -f gateway      # no crash loops (P2: the WORKER is not a compose
                                    # service — it runs as systemd ovid-worker, §11)
```

Startup order is enforced by `depends_on`: `redis-q` must be **healthy**
(auth'd `redis-cli ping`) before `gateway` starts. The host worker (§11)
reaches redis-q through the loopback port published by `redis-q` and the
live stack's postgres/mint-redis through the `net-proxy-pg`/`net-proxy-mint`
socat relays — all bound to `127.0.0.1` only.

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
#    The comment-only section at the BOTTOM of that file documents the
#    GLOBAL trusted_proxies block — already present in the live Caddyfile,
#    do NOT copy it (verify per cloud/deploy/HARDENING.md item D).
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

1. From a real app build (Firebase token + App Check): mint a WS ticket
   (`POST /cloud/v1/auth/ticket`, Firebase-authenticated → `{"ticket":…}`) →
   create session → POST message → connect WS `GET /cloud/ws?ticket=…` →
   watch replay + live deltas → run completes. (The WS path is deliberately
   NOT under `/cloud/v1` — `apps/gateway/src/routes/wsRoute.ts`; the Caddy
   `/cloud/*` handle covers both.)
2. Degradation spot-check (optional): `sudo systemctl stop ovid-worker` →
   message accepted, run stays `queued` (503-style behaviours documented in
   the P0 plan); `sudo systemctl start ovid-worker` → run picked up and
   processed. (P2: the worker is a systemd unit, not a compose service.)

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
- [ ] `docker compose ps`: redis-q (healthy), gateway (healthy),
      net-proxy-pg + net-proxy-mint Up; no restart loops in
      `docker compose logs`
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
      (`.env`, `worker.env`, `backup.env` are ignored / outside the repo)
- [ ] WS maxPayload 262144 configured (I2)
- [ ] per-connection subscription cap 64 (I3)
- [x] SIGTERM drain landed (P10 Task 2) — gateway `installShutdownHandlers`
      closes live WS with 1001 `"server restarting"`, drains via `app.close()`
      and hard-exits after 10 s; **worker** keeps its systemd
      `TimeoutStopSec=35`
- [x] mint deadline landed (P10 Task 2) — `GatewayDeps.mintTimeoutMs`
      (default 10000) bounds the internal-mint key-provisioning call
- [x] WS error logging landed (P10 Task 2) — caught WS/event-listener errors
      are logged `{err, sessionId, op}` through the gateway logger

(P2 sandbox activation has its own checklist: §11 step 8.)

## 10. Redeploys + decommission

- **Gateway / redis-q / proxies (compose services)**: `cd
  /opt/ovid-cloud/repo && git pull`, then `cd cloud && pnpm install
  --frozen-lockfile && pnpm -r build` (host build for migrate-cli), `cd
  deploy && ./provision.sh` (idempotent — applies new migrations),
  `docker compose up -d --build` (rebuilds the gateway image, rolling
  restart of the compose services only).
- **Worker (P2 — no longer a compose service)**: `cd
  /opt/ovid-cloud/repo && git pull && pnpm install --frozen-lockfile &&
  pnpm -r build && sudo systemctl restart ovid-worker`. The systemd unit
  (`cloud/deploy/systemd/`) runs the host-built `apps/worker/dist/main.js`
  directly — after a unit FILE changes, also `sudo systemd-analyze verify
  /etc/systemd/system/ovid-worker.service && sudo systemctl daemon-reload`
  before the restart. Gate: `journalctl -u ovid-worker -n 20` shows
  `consuming agent-runs` again.
- **Decommission**: §6 rollback (Caddy) → `docker compose down` (keep `-v`
  off to retain queue data) → §11 rollback (worker, nft table, /workspaces
  volume, units) → optionally `sudo systemctl disable --now
  ovid-cloud-backup.timer` → the `ovid_cloud` DB/role can stay dormant
  (backups keep covering it) or be dropped after a final manual dump.
- **Rollout / cutover**: [`ROLLOUT.md`](./ROLLOUT.md) is the owner's
  conditional cutover script (R0–R7) with the Q1/Q2/Q3 decision gates,
  per-step go/no-go, time budgets and rollback. No rollout step executes
  until its §0 decision log is dated and signed.
- **Incident + ops procedures**: [`RUNBOOKS.md`](./RUNBOOKS.md) is the
  symptom → diagnose → act → verify playbook set for both stacks
  (worker/redis/Postgres/disk/sandbox/browser/R2/mint/LiteLLM) plus the ops
  drills (backup restore, dependency updates, rootfs rebuild, LiteLLM pin).
  Use it before improvising during an incident; its opening SAFETY rule
  governs every Act step (timestamped backup + config validation before live
  changes).

## 11. P2 activation — sandbox worker on the host (owner-run, ordered)

**What this does.** Moves the worker out of compose onto host systemd
(`ovid-worker.service` in `cloud/deploy/systemd/`, parented by the
`ovid-sandboxes.slice` cgroup slice), creates the `/workspaces` XFS volume,
loads the sandbox egress nftables filter, and adds the loopback proxies the
host worker uses to reach the compose network. Every step is **owner-run**
(no task agent ever executes this section — the stop-condition is real: it
installs host packages/units, creates the workspaces volume, loads live nft
rules and transitions the worker deployment).

**Ordering prerequisite.** Steps 5–7 assume the compose spine is up (§4–§6:
gateway on 127.0.0.1:8082, redis-q, proxies). As of 2026-10-16 the P1 stack
was NEVER activated on this box (no `ovid-cloud-*` containers running) — in
that case run §2–§8 first (P1 activation, owner-run), or activate P2-only
with the gateway absent and **record that decision in the log below** (runs
will queue, nothing consumes them until the gateway routes messages).

**R2 is a BOOT dependency, not an optional later step.** Both
`cloud/apps/gateway/src/index.ts` and `cloud/apps/worker/src/main.ts` call
`createStorage(loadStorageEnv(env))` unconditionally at boot, and production
refuses the `fs` backend. The templates ship `NODE_ENV=production` +
`OVID_STORAGE_BACKEND=r2`, so a missing/empty `OVID_R2_*` block stops the
process at boot. The trap: `CHANGE_ME` is **non-empty** and therefore PASSES
the boot check, then fails at the first storage call. Only
`cloud/scripts/verify-r2.mjs` (`R2-PROVISIONING.md` step 5, seven `[ok]`
lines) proves the credentials. Complete R2 steps 1–5 before the first
`docker compose up` and before enabling the worker in step 7.

Each step has a gate; do not continue past a failed gate. Rollbacks are
per-step and safe in reverse order.

### Step 1 — host prerequisites

```bash
sudo apt-get install -y bubblewrap zstd xfs-progs util-linux
# (bwrap is likely already present from the Task-1 probe; nftables too —
#  install-nft.sh checks. node-pty compiles a native module in the host
#  build, so a C toolchain is needed: apt-get install -y build-essential
#  python3 make g++ if pnpm -r build fails on it.)

cd /opt/ovid-cloud/repo/cloud
corepack enable && pnpm install --frozen-lockfile && pnpm -r build
```

**Gate**: `pnpm -r build` exits 0 and `apps/worker/dist/main.js` exists.
**Decision to record**: `deploy/sandbox/MECHANISM.md`'s DECISION line — run
the probe (`sudo bash deploy/sandbox/sandbox-probe.sh`) if not yet filled;
it decides `OVID_SANDBOX_LAUNCH` (`setuid` default vs `rootmap`) in
`/opt/ovid-cloud/worker.env` (step 7) and branch-b AppArmor state
(HARDENING item H).
**Rollback**: none needed (host packages are inert until later steps).

### Step 2 — rootfs (bwrap jail filesystem)

```bash
cd /opt/ovid-cloud/repo/cloud/deploy/rootfs
./build.sh                 # ONLY if you want a fresh revision (docker-only,
                           # safe); the CURRENT artifact revision is
                           # dist/ubuntu-noble-min-20261017-r2.tar.zst (Task 10
                           # rebuild — carries the cache-prune shim) and is
                           # already built
sudo bash install.sh       # picks the newest dist/ tarball, installs under
                           # /opt/ovid-rootfs, flips `current` atomically,
                           # prunes to 2 revisions, then runs smoke-jail.sh
                           # itself
```

**Gate**: install.sh ends `==> running smoke-jail.sh` followed by
`smoke-jail: OK (...)` — pinned node/pnpm/uv versions match `versions.env`
AND the gcc shim refuses with the spec §7 copy, exit 126.
**Note (host-gated suites)**: any host-gated test run (e.g.
`OVID_SANDBOX_HOST_TESTS=1` suites) must point `OVID_ROOTFS` at an **r2**
extract — `/opt/ovid-rootfs/current` after this step — NOT
`/tmp/ovid-rootfs-test`, which is the stale **r1** scratch from earlier
tasks (no `cache-prune` in its `ovid` shim).
**Rollback**: back-flip the symlink to the previous revision (install.sh
keeps 2):
`sudo ln -sfn ubuntu-noble-min-<old> /opt/ovid-rootfs/current.tmp && sudo mv -T /opt/ovid-rootfs/current.tmp /opt/ovid-rootfs/current`

### Step 3 — /workspaces XFS volume (project quotas)

```bash
sudo bash /opt/ovid-cloud/repo/cloud/deploy/workspaces/setup-workspaces.sh
# optional: OVID_WORKSPACES_SIZE_GB=32 (default), image path and mount via
# the env vars documented in the script header
```

**Gate** (both must hold):
```bash
stat -fc %T /workspaces   # → xfs
mount | grep prjquota     # → the volume, mounted with prjquota
```
**Quota sanity check** (run once, right after the gate — [OWNER]; it writes a
throwaway tree outside `users/`):

```bash
# Scratch project id 999999 — never reuse a real per-user project id.
mkdir -p /workspaces/.quota-selftest
xfs_quota -x -c 'project -s -p /workspaces/.quota-selftest 999999' /workspaces
xfs_quota -x -c 'limit -p bhard=1m 999999' /workspaces
dd if=/dev/zero of=/workspaces/.quota-selftest/probe bs=1M count=8 conv=fsync 2>&1 | tail -1
# EXPECT: "No space left on device" (EDQUOT) — anything else means the byte
# convention is wrong and every user cap is off by 512×.
# Cleanup (always, even when the probe passed):
xfs_quota -x -c 'limit -p bhard=0 999999' /workspaces
xfs_quota -x -c 'project -C -p /workspaces/.quota-selftest 999999' /workspaces
rm -rf /workspaces/.quota-selftest
```

Why: `cloud/packages/sandbox/src/quota.ts` defers its byte-convention
re-verification to this activation gate. The probe is the only proof that the
cap the manager applies is the cap the filesystem enforces.

**Rollback**: `sudo umount /workspaces && sudo sed -i '\|/opt/ovid-workspaces.img|d' /etc/fstab` (delete the line added by the script; `sudo rm /opt/ovid-workspaces.img` only if the volume is being discarded for good — that destroys every user workspace).

### Step 4 — sandbox egress filter (nftables)

```bash
# 1. Author the worker env early (full secrets land in step 7):
sudo cp /opt/ovid-cloud/repo/cloud/deploy/worker.env.example /opt/ovid-cloud/worker.env
sudo chmod 600 /opt/ovid-cloud/worker.env
sudo $EDITOR /opt/ovid-cloud/worker.env   # set OVID_PUBLIC_IP — this box: 148.113.44.36

# 2. Render + validate + install (idempotent; re-runs re-render + restart the unit):
#    NOTE: sourcing worker.env in a shell requires the space-valued
#    OVID_SANDBOX_CPU_MAX to be quoted — worker.env.example ships it quoted;
#    the systemd EnvironmentFile consumer reads the value identically with
#    or without quotes. Keep it that way if you hand-edit.
sudo bash -c 'set -a; source /opt/ovid-cloud/worker.env; set +a; \
  bash /opt/ovid-cloud/repo/cloud/deploy/net/install-nft.sh'
```

**Gate**: script ends `table inet ovid_sandbox loaded:` + the table listing —
`nft list table inet ovid_sandbox` works, and every `counter` line reads
`counter packets 0 bytes 0` (freshly zeroed; nonzero counters expected only
over time — HARDENING item H has the monthly review).
**Rollback**: `sudo systemctl disable --now ovid-sandbox-nft && sudo nft delete table inet ovid_sandbox` (the unit's own ExecStop removes the table).

### Step 5 — systemd units (slice + worker)

```bash
cd /opt/ovid-cloud/repo/cloud/deploy/systemd
sudo install -m 644 ovid-sandboxes.slice ovid-worker.service /etc/systemd/system/
sudo systemd-analyze verify /etc/systemd/system/ovid-sandboxes.slice /etc/systemd/system/ovid-worker.service
# gate: no errors (warnings about ordering are acceptable — record them)
sudo systemctl daemon-reload
```

Do **not** enable the worker yet — the env (step 7) must exist first.
**Rollback**: `sudo rm /etc/systemd/system/ovid-sandboxes.slice /etc/systemd/system/ovid-worker.service && sudo systemctl daemon-reload`.

### Step 6 — compose transition (worker out, proxies in)

If a **P1 compose worker** is running on this box, retire it first — queue
data (the `ovid-cloud-redis-q-data` volume) is untouched either way:

```bash
docker ps --filter name=ovid-cloud-worker --format '{{.Names}}'   # is P1's worker up?
# from a checkout still holding the P1 compose file:
docker compose stop worker && docker compose rm -f worker
# or by container name once the P2 compose file is checked out:
#   docker stop ovid-cloud-worker-1 && docker rm ovid-cloud-worker-1
```

Then bring up the P2 compose (picks up redis-q's loopback port + the
`net-proxy-pg`/`net-proxy-mint` socat relays):

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
docker compose up -d
```

**Gates**:
```bash
curl -sf http://127.0.0.1:8082/cloud/v1/health            # → {"status":"ok",…}
redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" -p 6391 ping   # → PONG (auth'd)
psql "postgres://ovid_cloud:$OVID_CLOUD_DB_PASSWORD@127.0.0.1:5434/ovid_cloud" -c 'select 1'
                                                          # → 1 row (proxy → live pg)
ss -tlnp | grep -E ':(5434|6391|6392)\b'                  # → 127.0.0.1 binds ONLY
```
(`REDIS_Q_PASSWORD`/`OVID_CLOUD_DB_PASSWORD` are in `deploy/.env` — source it
in the shell running the gates.)
**Rollback**: the worker compose service is restorable from git history
(`git log -- cloud/deploy/docker-compose.yml`); `git checkout <P1-sha> --
cloud/deploy/docker-compose.yml cloud/deploy/Dockerfile.worker && docker
compose up -d --build` — and stop the systemd worker first (step 7 rollback)
so the two workers do not both consume the queue.

### Step 7 — worker env + enable

```bash
sudo $EDITOR /opt/ovid-cloud/worker.env   # complete every CHANGE_ME:
#   DATABASE_URL password = OVID_CLOUD_DB_PASSWORD (deploy/.env)
#   REDIS_Q_URL password  = REDIS_Q_PASSWORD        (deploy/.env)
#   REDIS_MINT_URL password = REDIS_PASSWORD        (/opt/ovid-gateway/.env)
#   OVID_DEFAULT_MODEL = a live LiteLLM alias; OVID_SANDBOX_LAUNCH per
#   MECHANISM.md DECISION; OVID_PUBLIC_IP already set in step 4
#   GOOGLE_APPLICATION_CREDENTIALS = /opt/ovid-gateway/firebase-admin.json
#   (P4 FCM pushes; see §3)
#   OVID_SCHEDULER_TICK_MS optional (default 15000; positive integer)
sudo chmod 600 /opt/ovid-cloud/worker.env

sudo systemctl enable --now ovid-worker ovid-sandbox-nft
```

**Gates**:
```bash
systemctl is-active ovid-worker ovid-sandbox-nft          # → active active
journalctl -u ovid-worker -n 50 --no-pager                 # → "consuming agent-runs" …
                                                          #   and NO "RootfsUnavailable"
cat /sys/fs/cgroup/ovid-sandboxes.slice/ovid-worker.service/cgroup.subtree_control
                                                          # → cpu memory pids
                                                          #   (leaf-first bootstrap ran)
systemctl show ovid-sandboxes.slice -p CPUQuotaPerSecUSec # → 6s (600%)
systemctl show ovid-worker -p MemoryMax                   # → 4294967296 (4G — G5)
```
**Rollback**: `sudo systemctl disable --now ovid-worker` (+ optionally
`sudo nft delete table inet ovid_sandbox` if the filter is being removed
too). The env file stays (harmless; contains secrets — `sudo rm` it if
decommissioning).

### Step 8 — functional smoke (owner, real session)

From a real app build (or the Task-14 e2e harness pointed at production —
real Firebase token + App Check): create session → POST a message whose
agent run executes `run_shell {command:"echo …"}` and `write_file` → watch
the WS event channel for the ordered `tool_started`/`tool_completed` events
→ open a terminal via `pty_open` and type.

**Gates (P2 checklist — all green = activated)**:
- [ ] Run completes; `tool_completed` for `run_shell` carries the echoed
      output; `write_file`'s file exists in the uid's workspace on
      `/workspaces`
- [ ] `tool_started`/`tool_completed` events arrived on the WS channel in
      order (replay + live)
- [ ] `pty_open` → terminal echoes; `/workspaces` file operations visible
      through it
- [ ] `nft list ruleset | grep -A2 counter` — the sandbox-uid drop counters
      ticked if anything probed a blocked address; no unrelated table changed
- [ ] HARDENING.md item H rows verified and dated

**P10 Task 2 landed**: gateway SIGTERM drain (WS 1001 `"server restarting"`,
≤10 s), mint deadline, and WS error logging are no longer deferred; the
**worker** drains in ≤30 s (unit `TimeoutStopSec=35`). Subscription cap 64
(I3) and WS maxPayload 262144 (I2) remain done.

## 12. P7 addendum — R2 storage, redis-c, /workspaces (owner-gated)

P7 adds workspace hibernation/hydration to R2, lazy per-file reads and an
internal worker file service. **Everything in this section is artifacts-only
until the owner explicitly approves activation.** The ordered, copy-paste
runbook (bucket, token, lifecycle, env, verify, activation) is
[`R2-PROVISIONING.md`](./R2-PROVISIONING.md). Do not create the bucket, mint
the token, run `docker compose up`, or flip `OVID_STORAGE_BACKEND=r2` before
that approval — same stop-condition precedent as §11 and the P1 activation.

### 12.1 What changed in the deploy artifacts

- **`docker-compose.yml`**
  - New `redis-c` service (spec §10): `redis:7-alpine`, `maxmemory 256mb`,
    `allkeys-lru`, AOF off, password `${REDIS_C_PASSWORD}`, `mem_limit 384m`,
    `ovid-cloud` network only. It publishes a LOOPBACK port
    (`127.0.0.1:${REDIS_C_HOST_PORT:-6393}`) so the host systemd worker can
    reach it, exactly like redis-q. It carries session-activity keys only;
    queue/event traffic stays on redis-q (`noeviction`).
  - `gateway.depends_on` gains `redis-c: service_started` (never
    `service_healthy`: activity bumps must not block REST — the tracker
    falls back to `REDIS_Q_URL` when `REDIS_C_URL` is unset).
  - `gateway.extra_hosts` gains `host.docker.internal:host-gateway`, so
    `OVID_WORKER_INTERNAL_URL=http://host.docker.internal:8091` reaches the
    HOST worker's file service.
  - The compose-worker VARIANT (not the landed deployment) is documented
    with its P7 needs: `${WORKSPACES_ROOT}:/workspaces` rw,
    `UV_THREADPOOL_SIZE: "8"`, `depends_on redis-c`.
- **`cloud/deploy/.env.example`** — new `# ── Storage (P7) ──` block:
  `OVID_STORAGE_BACKEND`, `OVID_R2_*`, `OVID_MAX_WARM_GB`,
  `OVID_DISK_ALERT_PCT`, `WORKSPACES_ROOT`, `OVID_INTERNAL_TOKEN`,
  `OVID_WORKER_FILE_PORT`, `OVID_WORKER_INTERNAL_URL`, `REDIS_C_*`, and the
  gateway caps. The INLINE CAP NAMES DIVERGE by design (P7 Task 12): the
  gateway reads `OVID_FILE_INLINE_MAX_BYTES`, the worker reads
  `OVID_INLINE_MAX_BYTES` — keep the values equal (default 1 MiB).
- **`cloud/deploy/worker.env.example`** — matching `Storage (P7)` block for
  the HOST worker (`/opt/ovid-cloud/worker.env`), including
  `REDIS_C_URL=…@127.0.0.1:6393` and `UV_THREADPOOL_SIZE=8`.
- **`cloud/scripts/verify-r2.mjs`** — owner-run, least-privilege probe
  (put/head/get/presign/delete; no list, no admin). See the runbook step 5.

### 12.2 Where the values go

| Consumer | File on the box | Notes |
| --- | --- | --- |
| gateway (compose) | `/opt/ovid-cloud/repo/cloud/deploy/.env` | `env_file: [.env]`; R2 + redis-c + token |
| worker (systemd) | `/opt/ovid-cloud/worker.env` | `EnvironmentFile=`; R2 + redis-c + token |

`OVID_R2_ACCOUNT_ID`, `OVID_R2_ACCESS_KEY_ID`,
`OVID_R2_SECRET_ACCESS_KEY`, `OVID_R2_BUCKET`, `OVID_INTERNAL_TOKEN` and
`REDIS_C_PASSWORD` must be IDENTICAL in both files. `chmod 600` both.
Agents/containers see only these env vars — they never see Cloudflare
credentials (spec §10/D7).

### 12.3 `/workspaces`

P2 already creates the XFS project-quota volume at `/workspaces`
(`deploy/workspaces/setup-workspaces.sh`, §11 step 3). P7 needs no new mount
for the host worker: warm session dirs live under
`/workspaces/users/{uid}/sessions/{sid}` and `OVID_WORKSPACES_ROOT` is
unchanged. `WORKSPACES_ROOT=/workspaces` in `.env.example` exists only for a
restored compose-worker variant.

### 12.4 Capacity note (owner decision at activation)

`OVID_MAX_WARM_GB` defaults to **8 GB** — the ONE warm-disk knob (ledger
ruling R2; P2's attach-guard reads the same variable, P7's LRU enforces it).
The 8 → 12 GB retune consideration is documented in P7 Task 10 and is the
owner's call at activation, coordinated with the backup free-space floor
(`BACKUP_MIN_FREE_MB`) and the 80 % disk alert.

### 12.5 Activation

Follow `R2-PROVISIONING.md` steps 1–6. Step 6 (live-box side effects +
credentials) is the explicit STOP: present the runbook to the owner and wait
for approval. Autonomous dry validation is only:

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
docker compose config -q          # no side effects
node --check ../scripts/verify-r2.mjs
```

