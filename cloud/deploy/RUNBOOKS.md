# RUNBOOKS.md — incident + ops playbooks

Operational playbooks for the Ovid cloud stack on the production VPS. Two
parts:

- **Part 1 — Incidents** (what to do when something is broken now).
- **Part 2 — Ops** (scheduled maintenance and drills).

Every playbook has the same shape:

> **Symptom** (alert name or user report) → **Diagnose** (read-only commands
> and expected output) → **Act** (exact commands; destructive/live actions
> are flagged) → **Verify** → **Post-mortem hook**

The alert names in **Symptom** are the checks shipped by `@ovid/watch`
(`cloud/apps/watch`, installed per `cloud/deploy/monitoring/MONITORING.md`):
`gateway-health`, `queue-depth`, `worker-lag`, `disk-80`, `redis-mem-80`,
`spend-parity`. The external whole-box layer is UptimeRobot
(`HARDENING.md` item F); an on-box watcher cannot report its own host being
down.

---

## 0. SAFETY rule, facts, and command conventions

### 0.1 SAFETY (applies to every Act step)

**Never touch the live `ovid-gateway` stack without a timestamped backup and
config validation.** The live stack (Caddy, `ovid-gateway-postgres-1`,
`ovid-gateway-redis-1`, `ovid-gateway-mint-1`, `ovid-gateway-litellm-1`,
account-dev) serves existing users; the cloud stack (`ovid-cloud` compose
project + the host `ovid-worker.service`) is the new surface.

```bash
# Before editing ANY live-stack file (set FILE first):
FILE="${FILE:?set FILE to the live file you are editing}"
cp "$FILE" "$FILE.bak-$(date -u +%Y%m%dT%H%M%SZ)"
# Before applying a live compose change:
cd /opt/ovid-gateway && docker compose -p ovid-gateway config -q
# Before applying a Caddy change:
docker exec ovid-gateway-caddy-1 caddy validate \
  --config /etc/caddy/Caddyfile --adapter caddyfile
```

> **NEVER paste a `<placeholder>` from this file into a shell.** The shell reads
> `<x>` as *redirect stdin from a file named x* and `>` as a **truncating**
> redirect, so `cp f.bak-<TS> f` becomes `cp f` with stdout redirected at `f` —
> it **empties the file it was supposed to protect** before `cp` even fails.
> Every command below therefore assigns its inputs to `"${VAR:?}"` first: the
> `:?` makes the line abort loudly if the variable is unset instead of
> silently doing something destructive. `bash -n` cannot catch this class.

Hard prohibitions (data-loss / unrecoverable):

- Never `docker compose down -v`, `docker volume rm`, or
  `docker system prune --volumes` on either stack.
- Never `redis-cli FLUSHDB` / `FLUSHALL` on `redis-q`; queue jobs and the
  session event log are the only copy of in-flight work.
- Never delete `/workspaces/users/<uid>` directly — use hibernation or
  account deletion; a direct `rm` destroys user data.
- Never run two `ovid-worker` processes on one host: Lightpanda owns ports
  9400–9407 exclusively (`BROWSERS.md` §(b) OPS carries), and two workers
  would race the same run rows.
- Never weaken a threshold to silence an alert. Fix the condition or record
  an explicit, dated owner decision.

`[OWNER]` marks an action that changes the live stack, restarts a live
service, rotates a credential, or is otherwise activation-gated. On-call may
run read-only **Diagnose** commands freely; **Act** commands marked `[OWNER]`
need the owner in the incident channel (same gate style as `DEPLOY.md` §11
and `R2-PROVISIONING.md`).

### 0.2 Facts about this box (verified 2026-10-17)

**There is exactly ONE gateway env file:** `/opt/ovid-cloud/repo/cloud/deploy/.env`
(the compose `env_file: [.env]` resolved next to `docker-compose.yml`, and the
path `provision.sh` reads as `$SCRIPT_DIR/.env`). Do not create or source
`/opt/ovid-cloud/.env` — any command naming it is stale. The host worker's
environment is the separate `/opt/ovid-cloud/worker.env`
(`EnvironmentFile=` in `systemd/ovid-worker.service`).

- Cloud compose project: `ovid-cloud`; containers:
  `ovid-cloud-gateway-1`, `ovid-cloud-redis-q-1`, `ovid-cloud-redis-c-1`,
  `ovid-cloud-net-proxy-pg-1`, `ovid-cloud-net-proxy-mint-1`
  (`ovid-cloud-mint-1` only with the `mint` profile).
- Live compose project: `ovid-gateway`; postgres container
  `ovid-gateway-postgres-1`, redis `ovid-gateway-redis-1`, mint
  `ovid-gateway-mint-1` (host loopback `127.0.0.1:8090`), LiteLLM
  `ovid-gateway-litellm-1` (host loopback `127.0.0.1:4000`), Caddy
  `ovid-gateway-caddy-1`.
- Host loopback ports: gateway `127.0.0.1:8082` (health
  `/cloud/v1/health`), redis-q `127.0.0.1:6391`, redis-c `127.0.0.1:6393`,
  postgres proxy `127.0.0.1:5434`, mint-redis proxy `127.0.0.1:6392`.
- **`redis-cli` and `psql` are NOT installed on the host.** Use
  `docker exec <container> redis-cli …` / `docker exec <container> psql …`
  (verified: redis-cli 7.4.11, psql 16.15 in the live containers). Do not
  invent a host binary.
- Env files: `/opt/ovid-cloud/repo/cloud/deploy/.env` (gateway; contains
  `REDIS_Q_PASSWORD`, `REDIS_C_PASSWORD`, `OVID_MASTER_KEY`,
  `OVID_INTERNAL_TOKEN`, R2 credentials) and `/opt/ovid-cloud/worker.env`
  (host worker; loopback URLs). Both `chmod 600`.
- Queue prefix is `bull` in production (`bull:staging` in staging); the
  queue names are `agent-runs`, `schedules`, `hibernate`, `hydrate`,
  `plugin-installs`.
- Session event streams are `sess:{sessionId}:events`. **Shipped retention
  is exact `MAXLEN 10000` events** (`cloud/packages/events/src/eventLog.ts`),
  not the spec §6.2 "24 h / 50 MB" wording — the code is the authority.
- `redis-q` is `maxmemory 1400mb` + `noeviction` (`mem_limit 1536m`);
  `redis-c` is `maxmemory 256mb` + `allkeys-lru`, no AOF (`mem_limit 384m`).
- Sandbox uid block: `200000–209999` production (`220000–229999` staging).
  Env cgroups live at
  `/sys/fs/cgroup/ovid-sandboxes.slice/ovid-worker.service/sandbox-<uid>`.
- The P10 chaos suite is on disk (`cloud/apps/load/src/chaos/scenarios/`):
  Task-6 (`redis-q-restart`, `gateway-restart`, `postgres-restart`) and
  Task-7 (`worker-kill`, `disk-pressure`, `clock-skew`, landed in `212aa82`).
  `cloud/scripts/acceptance.sh` (Task 14) is also on disk (landed in
  `a28d737`). Run one scenario with
  `node cloud/apps/load/dist/chaosCli.js --scenario <name>`; they require the
  staging composition.

### 0.3 Common prelude

```bash
# Gateway/cloud secrets (needed for docker exec passwords)
set -a; . /opt/ovid-cloud/repo/cloud/deploy/.env; set +a

# Worker env — use this for HOST-side clients (it carries 127.0.0.1 URLs;
# the gateway .env carries compose DNS names like redis-q, unusable on the
# host). The template quotes OVID_SANDBOX_CPU_MAX, so a shell source is safe.
set -a; . /opt/ovid-cloud/worker.env; set +a
```

Read-only live-stack check used by several playbooks:

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
docker compose -p ovid-cloud ps
curl -sf http://127.0.0.1:8082/cloud/v1/health
# expected: {"status":"ok","checks":{"db":true,"redisQ":true}}
```

---

# Part 1 — Incidents

## I-1. Worker crash / restart loop

**Symptom.** `worker-lag` alert (oldest waiting job > 300 s) or
`queue-depth` rising; users report runs stuck at "queued"; `systemctl
status ovid-worker` shows `activating (auto-restart)` or a climbing
`NRestarts`.

**Diagnose (read-only).**

```bash
systemctl status ovid-worker --no-pager
systemctl show ovid-worker -p ActiveState,SubState,MainPID,NRestarts,MemoryCurrent,MemoryMax
journalctl -u ovid-worker -n 120 --no-pager
# Look for: "required", "OVID config:", "RootfsUnavailable", "EADDRINUSE",
# "OOM", or a stack trace immediately before each restart.

# Is the queue reachable and is work waiting?
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" ping
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" LLEN bull:agent-runs:wait

# OOM vs disk vs backend?
cat /sys/fs/cgroup/ovid-sandboxes.slice/ovid-worker.service/memory.events 2>/dev/null
df -h / /workspaces
docker compose -p ovid-cloud ps
```

**Act.**

- One-off crash (no repeating fatal line, queue/backends healthy):
  `sudo systemctl restart ovid-worker` **[OWNER]**.
- Repeating boot refusal: **stop the loop first** —
  `sudo systemctl stop ovid-worker` **[OWNER]** — fix the named env/rootfs
  problem, then start. Do not keep restarting a worker that refuses boot.
- OOM-killed: go to **I-8**; disk: **I-6**; redis-q down: **I-2**.
- Rootfs missing (`RootfsUnavailable`): check
  `readlink /opt/ovid-rootfs/current` and reinstall per **O-3**.

**Verify.**

```bash
systemctl is-active ovid-worker                 # active
journalctl -u ovid-worker -n 30 --no-pager      # "consuming agent-runs", no boot error
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" LLEN bull:agent-runs:wait
# expected: draining toward 0; `worker-lag` sends one RECOVERED notice
```

**Post-mortem hook.** First fatal line and timestamp; `NRestarts`; whether
the run rows were terminalized by the stale sweeper (**I-14**); rootfs
revision; any env edit that preceded the loop.

**Evidence.** Worker shutdown order (pty → sandbox manager → browser →
drain) is pinned in `cloud/apps/worker/src/main.ts`; the stale-run recovery
that rescues runs stranded by a crash is `cloud/apps/worker/src/staleRuns.ts`
and its real-Postgres/real-Redis test `staleRuns.test.ts`. The P10
`worker-kill` chaos scenario
(`cloud/apps/load/src/chaos/scenarios/workerKill.ts`, landed in `212aa82`)
exercises this crash path on staging.

---

## I-2. redis-q loss / unavailable

**Symptom.** `gateway-health` alert with `checks.redisQ:false` (gateway
returns 503); message sends fail; worker logs `ECONNREFUSED`/`ECONNRESET`;
`queue-depth` may read 0 because the queue is unreachable.

**Diagnose.**

```bash
docker compose -p ovid-cloud ps redis-q
docker compose -p ovid-cloud logs --tail=120 redis-q
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" ping
# expected: PONG
ss -tlnp | grep -E ':6391\b'                     # 127.0.0.1 only
curl -sf http://127.0.0.1:8082/cloud/v1/health   # 503 with redisQ:false
docker ps --filter name=ovid-gateway-postgres-1   # DB may still be healthy
```

If the container is up but auth fails, the password in
`/opt/ovid-cloud/repo/cloud/deploy/.env` and `/opt/ovid-cloud/worker.env`
diverged; do not rotate mid-incident — first confirm which value the container
was started with (`docker inspect ovid-cloud-redis-q-1` shows the command, not
the password; compare the two env files).

**Act.**

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
docker compose -p ovid-cloud restart redis-q       # [OWNER]
# If the container is gone/unhealthy:
docker compose -p ovid-cloud up -d redis-q         # [OWNER]
```

- **Never** add `-v`/`--volumes`; the `ovid-cloud_redis-q-data` volume
  holds the AOF. `docker compose down` without `-v` is acceptable only for a
  planned window, not for an incident.
- If the volume/AOF is corrupt, stop and restore from a filesystem snapshot
  or accept queue loss: in-flight jobs are lost, but the stale-run sweeper
  (**I-14**) terminalizes their run rows so clients do not wait forever.
- Gateway and worker reconnect automatically (ioredis); no restart is
  normally required once PING succeeds.

**Verify.**

```bash
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" ping   # PONG
curl -sf http://127.0.0.1:8082/cloud/v1/health                                             # ok
journalctl -u ovid-worker -n 20 --no-pager                                                 # no ECONNREFUSED
```

**Post-mortem hook.** Why the container stopped (host OOM, disk, docker
restart, manual change); AOF replay duration; number of jobs lost;
`gateway-health` recovery timestamp.

**Evidence.** `redis-q` is the AG3 queue: `noeviction`, AOF `everysec`,
loopback-only (`cloud/deploy/docker-compose.yml`); the health route probes
it directly (`cloud/apps/gateway/src/routes/health.ts`). The Task-6
`redis-q-restart` chaos scenario
(`cloud/apps/load/src/chaos/scenarios/redisQRestart.ts`) exercises this
precondition → inject → verify path on staging via
`node cloud/apps/load/dist/chaosCli.js --scenario redis-q-restart`.

---

## I-3. redis-q at the memory ceiling

**Symptom.** `redis-mem-80` alert (`used_memory / maxmemory > 80 %`); logs
contain `OOM command not allowed when used memory > 'maxmemory'`. This is
**by design** (AG3): writes fail loudly instead of silently evicting jobs or
events.

**Diagnose.**

```bash
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" INFO memory
# note used_memory, maxmemory (1468006400 = 1400 MiB), maxmemory_policy (noeviction)
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" INFO keyspace

# Queue backlog per queue (BullMQ key layout)
for q in agent-runs schedules hibernate hydrate plugin-installs; do
  echo "== $q"
  for k in wait active; do
    printf '  %-10s ' "$k"
    docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" LLEN "bull:$q:$k"
  done
  for k in completed failed delayed; do
    printf '  %-10s ' "$k"
    docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" ZCARD "bull:$q:$k"
  done
done

# Session event streams, largest first
docker exec ovid-cloud-redis-q-1 sh -c '
  redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" --scan --pattern "sess:*:events" |
  while read -r k; do
    printf "%s %s\n" "$(redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" XLEN "$k")" "$k"
  done' | sort -rn | head -20

# Read-only; can be slow on a 1400 MiB instance — run at low traffic.
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" --bigkeys
```

**Act (decision tree, in order).**

1. **Trim completed/failed job history** **[OWNER]** — this deletes live job
   records (BullMQ's own `clean` removes the ZSET entry and the job hash).
   Safe for `wait`/`active`/`delayed`, but irreversible: a job you later need
   for forensics is gone. Prefer trimming only `failed` first, and only when
   the queue is actually the memory pressure:

   ```bash
   set -a; . /opt/ovid-cloud/worker.env; set +a     # REDIS_Q_URL = 127.0.0.1:6391
   cd /opt/ovid-cloud/repo/cloud/packages/queue
   node --input-type=module -e '
   import { Queue } from "bullmq";
   for (const name of ["agent-runs","hibernate","hydrate","plugin-installs","schedules"]) {
     const q = new Queue(name, { connection: { url: process.env.REDIS_Q_URL } });
     console.log(name, "completed", await q.clean(0, 5000, "completed"),
                      "failed", await q.clean(0, 5000, "failed"));
     await q.close();
   }'
   ```

2. **Trim session event streams** **[OWNER]** to the shipped retention (exact
   `MAXLEN 10000`; keeps the newest events). This **discards live stream
   events** — a client reconnecting afterwards replays a shorter history, and
   a run's evidence may be gone. Never run it during an incident you are still
   diagnosing:

   ```bash
   docker exec ovid-cloud-redis-q-1 sh -c '
     redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" --scan --pattern "sess:*:events" |
     while read -r k; do
       redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" XTRIM "$k" MAXLEN 10000 >/dev/null
     done'
   ```

3. **Investigate a leak** before adding memory: a single growing stream
   family, a stuck consumer (`active` count pinned), or a job type whose
   payload carries large blobs. `XLEN`/`ZCARD` deltas over 10 minutes are
   the signal.
4. **Raise `--maxmemory` only with the slice/host budget.** `redis-q` has
   `mem_limit 1536m` in compose; raising `maxmemory` requires raising
   `mem_limit` too, and the 22 GB box budget in the spec §9 must absorb it.
   **[OWNER]** edit `docker-compose.yml`, `docker compose -p ovid-cloud
   config -q`, then `docker compose -p ovid-cloud up -d redis-q`.
   **Never** change `noeviction` to an eviction policy — that silently
   discards jobs/events and breaks AG3.

**Verify.**

```bash
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" INFO memory
# expected: used_memory/maxmemory below 80 % (watch sends one RECOVERED)
curl -sf http://127.0.0.1:8082/cloud/v1/health
```

**Post-mortem hook.** Which key family grew (streams vs queue history vs
payload size), growth rate, whether a consumer was stuck, and the chosen
budget change if any.

**Evidence.** `redis-mem-80` computes the ratio from `INFO memory` and never
hardcodes `maxmemory` (`cloud/apps/watch/src/checks.ts`); the AG3 rationale
is in `cloud/deploy/docker-compose.yml`. Stream retention is
`DEFAULT_MAX_LEN = 10_000` in `cloud/packages/events/src/eventLog.ts`.

---

## I-4. redis-c degradation

**Symptom.** Not user-facing: warm-workspace ordering degrades and worker
logs contain `redis-c error` / connection failures. `redis-c` is cache-class
(`allkeys-lru`, no AOF); losing its keys is safe — the warm LRU falls back to
`file_manifests.updated_at`.

**Diagnose.**

```bash
docker compose -p ovid-cloud ps redis-c
docker exec ovid-cloud-redis-c-1 redis-cli --no-auth-warning -a "$REDIS_C_PASSWORD" ping
docker exec ovid-cloud-redis-c-1 redis-cli --no-auth-warning -a "$REDIS_C_PASSWORD" INFO memory
# expected: maxmemory_policy:allkeys-lru, maxmemory 268435456 (256 MiB)
journalctl -u ovid-worker -n 80 --no-pager | grep -i 'redis-c\|activity'
ss -tlnp | grep -E ':6393\b'        # 127.0.0.1 only
```

**Act.**

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
docker compose -p ovid-cloud restart redis-c      # [OWNER]
docker compose -p ovid-cloud up -d redis-c        # [OWNER] if absent/unhealthy
```

- Do **not** point queue/event traffic at `redis-c`; it is cache-only.
- `REDIS_C_URL` unset makes the activity tracker share `redis-q` (documented
  dev fallback), but on a memory-tight production box that moves cache keys
  onto the `noeviction` queue redis — restore `redis-c` instead.
- Cache loss only affects idle-eviction precision; the sweeper uses
  `file_manifests.updated_at` when activity keys are missing.

**Verify.**

```bash
docker exec ovid-cloud-redis-c-1 redis-cli --no-auth-warning -a "$REDIS_C_PASSWORD" ping   # PONG
journalctl -u ovid-worker -n 40 --no-pager | grep -i 'warm sweep\|redis-c'
# expected: warm sweep resumes without repeated redis-c errors
```

**Post-mortem hook.** Why it stopped (host OOM/disk/docker), whether it was
ever resized, and whether the cache fallback masked a warm-eviction issue.

**Evidence.** `cloud/packages/storage/src/activity.ts` (7-day TTL, missing
key = UNKNOWN), `warmLru.ts` (row `updated_at` fallback), and the
`REDIS_C_URL` fallback notes in `cloud/apps/worker/src/main.ts` and
`cloud/apps/gateway/src/env.ts`.

---

## I-5. Postgres outage

**Symptom.** `gateway-health` alert with `checks.db:false`; every REST call
that touches Postgres fails (503/500); worker runs fail; WS replays may
still serve from Redis but new writes fail.

**Diagnose.**

```bash
docker ps --filter name=ovid-gateway-postgres-1 --format '{{.Names}}\t{{.Status}}'
docker exec ovid-gateway-postgres-1 sh -c 'pg_isready -U "${POSTGRES_USER:-postgres}"'
docker logs --tail=120 ovid-gateway-postgres-1
docker exec ovid-gateway-postgres-1 sh -c 'psql -U "${POSTGRES_USER:-postgres}" -d ovid_cloud -Atc "SELECT 1"'
df -h /                      # a full disk is a common Postgres failure
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" ping
```

Expected healthy: `accepting connections`, `SELECT 1` → `1`.

**Act.**

```bash
cd /opt/ovid-gateway
docker compose -p ovid-gateway restart postgres    # [OWNER]
```

- **Never** `docker compose down -v` or delete the postgres volume; that
  destroys the live databases (`litellm`, `ovid_account_dev`, `ovid_cloud`).
- If the data directory is corrupt, stop and restore per
  `cloud/deploy/backup/README.md` (owner-only; stop writers first).
- Gateway and worker reconnect on their own; restart them only if their
  connection pools stay wedged after Postgres is healthy.

**Verify.**

```bash
docker exec ovid-gateway-postgres-1 sh -c 'psql -U "${POSTGRES_USER:-postgres}" -d ovid_cloud -Atc "SELECT 1"'
curl -sf http://127.0.0.1:8082/cloud/v1/health    # db:true
journalctl -u ovid-worker -n 30 --no-pager        # no DB connection errors
```

**Post-mortem hook.** Disk/IO pressure, restart reason, replication/backup
state, and whether any run rows were stranded (**I-14**).

**Evidence.** Health route `cloud/apps/gateway/src/routes/health.ts`;
backup/restore procedures and the proven 2026-10-16 drill in
`cloud/deploy/backup/README.md`. The Task-6 `postgres-restart` chaos
scenario (`cloud/apps/load/src/chaos/scenarios/postgresRestart.ts`) covers
the staging form of this outage.

---

## I-6. Disk pressure / disk full

**Symptom.** `disk-80` alert; worker logs
`[warm-lru] disk usage … >= alert …`; a `system_note {code:"disk_pressure"}`
appears on the last evicted session; new sandboxes fail with
`sandbox_unavailable` (`minFreeGb` = 2); `ovid-cloud-backup.service` fails
its free-space guard.

**Diagnose (hotspots in order).**

```bash
df -h / /workspaces
df -h /opt/ovid-backups

# 1) warm workspaces (largest first)
du -xhd1 /workspaces 2>/dev/null | sort -h | tail -10
du -xhd1 /workspaces/users 2>/dev/null | sort -h | tail -10

# 2) docker logs (HARDENING E caps each container at 150 MB when applied)
du -sh /var/lib/docker/containers/*/*-json.log 2>/dev/null | sort -h | tail -10
docker system df

# 3) backups
du -xhd1 /opt/ovid-backups 2>/dev/null | sort -h | tail -10
systemctl status ovid-cloud-backup.service --no-pager
journalctl -u ovid-cloud-backup.service -n 50 --no-pager

# 4) R2 offload state: if OVID_R2_* is unset the backup is LOCAL ONLY
journalctl -u ovid-cloud-backup.service --since -7d --no-pager | grep -i 'R2\|LOCAL ONLY'
```

**Act.**

1. Let the warm LRU do its job: it hibernates the oldest warm sessions when
   disk usage crosses `OVID_DISK_ALERT_PCT` (default 80). Confirm it is
   running (`journalctl -u ovid-worker | grep 'warm sweep'`).
2. Lower the warm-cache ceiling **[OWNER]**: edit
   `OVID_MAX_WARM_GB` in `/opt/ovid-cloud/worker.env` (default 8; the
   8→12 retune is the owner's, never an incident reflex in the other
   direction without checking the backup floor), then
   `sudo systemctl restart ovid-worker`.
3. Prune backup runs past retention **[OWNER]** (the script already does
   this nightly; do not delete the newest run or the only copy):
   `find /opt/ovid-backups/pg -mindepth 1 -maxdepth 1 -type d -mtime +14`
   — inspect the list before deleting.
4. Cap docker logs if HARDENING E is not yet applied **[OWNER]**: create
   `/etc/docker/daemon.json` per `HARDENING.md` E, `systemctl restart
   docker` (all containers restart), and recreate the chatty containers on
   the next `up -d`. Existing containers keep their old config until
   recreated.
5. If the root filesystem is full and nothing can free space safely, stop
   new work (`sudo systemctl stop ovid-worker` **[OWNER]**) and escalate;
   Postgres/redis writes will fail hard.
6. **Never** delete `/workspaces/users/<uid>` or the newest backup run.
   Offload to R2 (backup env) or hibernate sessions instead.

**Verify.**

```bash
df -h / /workspaces        # both below 80 %
journalctl -u ovid-worker -n 40 --no-pager | grep 'warm sweep'
sudo systemctl start ovid-cloud-backup.service && journalctl -u ovid-cloud-backup.service -n 30 --no-pager
# expected: free-space gate passes, dumps written, zstd -t OK
```

**Post-mortem hook.** Which hotspot grew, whether warm eviction was keeping
up, whether log rotation was actually applied, and the backup free-space
floor (`BACKUP_MIN_FREE_MB`, default 2048).

**Evidence.** `cloud/packages/storage/src/warmLru.ts` (pressure path and
first-crossing log/note); `cloud/deploy/backup/pg_backup.sh` (free-space
guard, re-checked between dumps); HARDENING item E and H6.

---

## I-7. Leaked sandbox processes

**Symptom.** Host `ps` shows processes owned by the sandbox uid block after
their session ended; high CPU/PIDs; a jail cgroup still populated; possibly
`sandbox_busy` because slots are held.

**Diagnose.**

```bash
# Production uid block. Staging uses 220000-229999.
ps -eo uid,pid,ppid,etime,rss,cmd | awk '$1>=200000 && $1<210000'
# expected: no output between sessions (empty is healthy)

# Map a uid to its user (read-only)
SB_UID="${SB_UID:?set SB_UID to the sandbox uid from the ps output above}"
docker exec ovid-gateway-postgres-1 psql -U "${POSTGRES_USER:-postgres}" -d ovid_cloud -Atc \
  "SELECT uid FROM users WHERE sandbox_uid = $SB_UID"

# Env cgroups and their process counts
ls -d /sys/fs/cgroup/ovid-sandboxes.slice/ovid-worker.service/sandbox-* 2>/dev/null
for c in /sys/fs/cgroup/ovid-sandboxes.slice/ovid-worker.service/sandbox-*; do
  printf '%s procs=' "$c"; wc -l < "$c/cgroup.procs"
done

# Egress counters (nftables table may be absent pre-activation)
nft list table inet ovid_sandbox 2>/dev/null | grep -A2 counter
```

**Act.**

- Kill the whole env atomically via the cgroup (this is exactly what
  `SandboxManager.destroy()` does) **[OWNER]**:

  ```bash
  CGROOT=/sys/fs/cgroup/ovid-sandboxes.slice/ovid-worker.service
  SB_UID="${SB_UID:?set SB_UID to the sandbox uid from the ps output above}"
  echo 1 | sudo tee "$CGROOT/sandbox-$SB_UID/cgroup.kill"
  # poll until empty, then remove the env cgroup only if it has no children
  cat "$CGROOT/sandbox-$SB_UID/cgroup.procs"     # expected: empty
  sudo rmdir "$CGROOT/sandbox-$SB_UID"           # only if empty; EBUSY = still live
  ```

- If several envs are orphaned, the safest fix is a worker restart
  **[OWNER]**: `SandboxManager.recover()` kills env cgroups that have no
  workspace and re-warms the rest (`cloud/packages/sandbox/src/manager.ts`).
- Do **not** `kill -9` individual PIDs and assume the cgroup is clean; the
  leaf/env cgroup and its counters remain.

**Verify.**

```bash
ps -eo uid,pid,cmd | awk '$1>=200000 && $1<210000'    # empty
ls -d /sys/fs/cgroup/ovid-sandboxes.slice/ovid-worker.service/sandbox-* 2>/dev/null
journalctl -u ovid-worker -n 40 --no-pager | grep -i 'sandbox\|recover'
```

**Post-mortem hook.** Which tool/session left the process; whether
`destroy()`/`close()` ran; whether a PTY or spawned MCP process outlived its
leaf; nft counter evidence.

**Evidence.** `cloud/packages/sandbox/src/cgroups.ts` (`cgroup.kill` then
poll/rmdir), `manager.ts` (`killLeaves()` before the env cgroup;
`recover()` orphan rule), and the P2 host tests
(`cgroups.host.test.ts`, `manager.host.test.ts`).

---

## I-8. Sandbox slice OOM / cgroup exhaustion

**Symptom.** Runs die with `sandbox_unavailable` or tool exit codes; kernel
log shows `Killed process …`; the slice/unit `memory.events` shows
`oom_kill` increasing. The slice is capped at `MemoryMax=10G`,
`MemorySwapMax=0`; the worker unit at `MemoryMax=4096M`; each env at 512 MiB
and `pids.max=64`.

**Diagnose.**

```bash
systemctl status ovid-sandboxes.slice --no-pager
systemctl show ovid-sandboxes.slice -p MemoryCurrent,MemoryMax,CPUQuotaPerSecUSec
systemctl show ovid-worker -p MemoryCurrent,MemoryMax

cat /sys/fs/cgroup/ovid-sandboxes.slice/memory.events
cat /sys/fs/cgroup/ovid-sandboxes.slice/ovid-worker.service/memory.events

# Per-env OOM counters and current usage
for c in /sys/fs/cgroup/ovid-sandboxes.slice/ovid-worker.service/sandbox-*; do
  printf '%s ' "$c"
  cat "$c/memory.events" 2>/dev/null | tr '\n' ' '; echo
done

journalctl -k --since -2h --no-pager | grep -iE 'oom|killed process'
```

**Act.**

- Identify the offending uid from the kernel line (`Killed process <pid>
  (<comm>) total-vm…`) and the env `memory.events`, then destroy that
  session or the env per **I-7** **[OWNER]**.
- Reduce concurrency if the slice is repeatedly hitting its 10 G ceiling:
  `OVID_MAX_ACTIVE_SANDBOXES` (default 24) in
  `/opt/ovid-cloud/worker.env`, then `systemctl restart ovid-worker`
  **[OWNER]**.
- Do **not** raise `MemoryMax` on the slice/unit without redoing the
  capacity arithmetic (8 vCPU / 22 GB; worker 4 G + slice 10 G + live
  stack). The slice exists so a runaway jail OOM-kills inside it instead of
  taking the host.
- Do **not** raise per-env `OVID_SANDBOX_MEMORY_MAX_MB` casually: 24 × 512
  MiB is the binding case at the 10 G slice.

**Verify.**

```bash
cat /sys/fs/cgroup/ovid-sandboxes.slice/memory.events     # oom_kill stops increasing
journalctl -u ovid-worker -n 40 --no-pager                # runs completing
systemctl show ovid-worker -p MemoryCurrent,MemoryMax
```

**Post-mortem hook.** Workload (which command/package), peak `memory.current`,
whether pids or memory hit first, and whether concurrency or per-env caps
need an owner decision.

**Evidence.** `cloud/deploy/systemd/ovid-sandboxes.slice`,
`cloud/deploy/systemd/ovid-worker.service`, `cloud/packages/sandbox/src/config.ts`
(defaults), and HARDENING item H8.

---

## I-9. Browser pool exhaustion / memory alarm

**Symptom.** Browser tools fail with `BrowserPoolBusyError` — "The browser
pool is full … queued and timed out" or "The browser process died — retry";
screencasts pause (`screencast:false` or ladder step-down); worker RSS near
its 4 G unit cap; the P6 bench exits 1 with `VERDICT: REGRESSION — peak
exceeds the planned-peak alarm`.

**Diagnose.**

```bash
systemctl show ovid-worker -p MemoryCurrent,MemoryMax
# Unit cap is 4294967296 (4 G); the browser pool's share is ~2 G.

# Chromium/Lightpanda process tree under the worker
ps -eo pid,ppid,rss,cmd --forest | grep -A20 -E "chromium|lightpanda" | head -40

journalctl -u ovid-worker -n 100 --no-pager | grep -iE 'browser|screencast|lightpanda|EADDRINUSE'

# Owner-run bench (requires an installed chromium; exits 0 under 1300 MB,
# 1 over the alarm, 2 if chromium is missing)
node /opt/ovid-cloud/repo/cloud/scripts/browser-memory-bench.mjs
```

**Act.**

- Known lever: set `MAX_LIVE_BROWSERS=3` (from 4) in
  `/opt/ovid-cloud/worker.env`, then `systemctl restart ovid-worker`
  **[OWNER]**. This drops roughly one worst-case context.
- **Never raise the 1300 MB alarm threshold to make a run pass.** The
  dev-box bench measured a 1376 MB peak (chromium tree only, excluding the
  Lightpanda pool and tier-1 fallbacks), so the real headroom against the
  2048 MB pool ceiling is ~272–572 MB (`BROWSERS.md` §(c)).
- Idle contexts are evicted after `BROWSER_IDLE_EVICT_MS` (180 s) with
  storageState flushed first. Confirm the sweeper is running.
- **Stuck-context kill:** `[MAP P6 admin seam — NOT SHIPPED]`. There is no
  shipped admin/WS op to kill one context. The supported options are:
  (a) wait for idle eviction, (b) have the client `browser_detach` (stops
  the feed, not the context), or (c) restart `ovid-worker` **[OWNER]**,
  which closes the engine and flushes storageState **before** the queue
  drain (`BROWSERS.md` §(g) shutdown order). Do not reorder that shutdown.
- One worker/pool per host: ports 9400–9407 are exclusive; a second worker
  fails with `EADDRINUSE`.

**Verify.**

```bash
systemctl show ovid-worker -p MemoryCurrent,MemoryMax
journalctl -u ovid-worker -n 40 --no-pager | grep -iE 'browser|warm'
node /opt/ovid-cloud/repo/cloud/scripts/browser-memory-bench.mjs   # exit 0
```

**Post-mortem hook.** Peak RSS and context count; whether the workload was
the `/big` synthetic class; screencast cap (`MAX_ACTIVE_SCREENCASTS=3`) and
loadavg step-down (`OVID_SCREENCAST_LOAD_MAX=6.0`); whether the owner wants
the 4→3 lever permanently.

**Evidence.** `cloud/deploy/BROWSERS.md` §(c) (bench output and budget math),
§(g) (shutdown order, idle eviction); `cloud/scripts/browser-memory-bench.mjs`
(alarm 1300 MB, exit codes); `cloud/packages/browser/src/pool.ts:47,262`
(`BrowserPoolBusyError` — full/queue-timeout and process-death messages).

---

## I-10. R2 outage / degraded storage

**Symptom.** `attachment_unavailable` run failures; hibernate/hydrate jobs
fail; `verify-r2.mjs` prints `[FAIL]`; worker logs storage/R2 errors. Warm
sessions keep working; cold reads/hydration and backups to R2 do not.

**Diagnose.**

```bash
# Least-privilege probe (put/head/get/presign/delete; prints no secrets).
# [OWNER] — uses live credentials and writes one probe object.
cd /opt/ovid-cloud/repo
set -a; . /opt/ovid-cloud/repo/cloud/deploy/.env; set +a
node cloud/scripts/verify-r2.mjs
# expected: seven [ok] lines (config, put, head, get, presign, delete, gone), exit 0

journalctl -u ovid-worker -n 120 --no-pager | grep -iE 'r2|storage|hibernate|hydrate|attachment'
docker compose -p ovid-cloud ps
# Backup upload path
journalctl -u ovid-cloud-backup.service -n 60 --no-pager | grep -i 'R2'
```

**Act.**

- Transient Cloudflare/R2 errors: retry; the storage queues use BullMQ
  `attempts: 3` with exponential backoff, and run-level failures are loud
  (`attachment_unavailable`, hydrate failure). Do not hide them.
- **Do not flip `OVID_STORAGE_BACKEND=fs` in production** — the boot refuses
  it by design. If R2 is unavailable, degrade service (cold reads fail)
  rather than change the backend.
- Credential failure (403/401): rotate the R2 token per **I-13**, update
  **both** `/opt/ovid-cloud/repo/cloud/deploy/.env` and
  `/opt/ovid-cloud/worker.env`, restart the gateway and worker **[OWNER]**,
  re-run the probe.
- Once workspaces have been hibernated, R2 is the authority. Do not roll
  back to `fs`; the warm dirs are gone (`R2-PROVISIONING.md` rollback).

**Verify.**

```bash
node cloud/scripts/verify-r2.mjs                    # seven [ok]
cd /opt/ovid-cloud/repo/cloud
OVID_R2_ACCOUNT_ID=… OVID_R2_ACCESS_KEY_ID=… OVID_R2_SECRET_ACCESS_KEY=… \
OVID_R2_BUCKET=ovid-cloud \
pnpm --filter @ovid/storage exec vitest run src/r2.live.test.ts   # green, not skipped
# Then a hibernate → cold → hydrate smoke on a scratch session (R2-PROVISIONING §6.5)
```

**Post-mortem hook.** Cloudflare incident vs credential expiry vs bucket
lifecycle; which operation failed (put/get/presign); whether any workspace
is now unrecoverable (should be none — R2 is the durable copy).

**Evidence.** `cloud/scripts/verify-r2.mjs`, `R2-PROVISIONING.md` steps 5–6,
`cloud/packages/storage/src/storageEnv.ts` (production forbids `fs`),
`r2Adapter.ts`.

---

## I-11. mint outage

**Symptom.** Users cannot send messages: the gateway returns `409
key_not_minted` (non-402/429 mint failures collapse to this); `/usage` and
`/plans` fail; mint `/healthz` does not return 200.

**Diagnose.**

```bash
# Live Python mint (pre-P9 surface; P9 gateways call OVID_INTERNAL_MINT_URL)
curl -sf http://127.0.0.1:8090/healthz && echo ' MINT OK'
docker logs --tail=120 ovid-gateway-mint-1

# When the P9 TS mint is activated (compose profile `mint`, 8091/8092):
curl -sf http://127.0.0.1:8091/healthz && echo ' TS MINT OK'

# mint's Redis db2 (per-user provisioned keys) through the live stack.
# The live redis container has NO REDIS_PASSWORD env var — the password
# lives in /opt/ovid-gateway/.env, so source it on the host and pass -a.
set -a; . /opt/ovid-gateway/.env; set +a
docker exec ovid-gateway-redis-1 redis-cli --no-auth-warning -a "$REDIS_PASSWORD" -n 2 ping

# Gateway-side evidence
docker logs --tail=120 ovid-cloud-gateway-1 | grep -iE 'mint|key_not_minted'
```

**Act.**

```bash
cd /opt/ovid-gateway
docker compose -p ovid-gateway restart mint        # [OWNER] live Python mint
# or, once the TS mint is the active surface:
cd /opt/ovid-cloud/repo/cloud/deploy
docker compose -p ovid-cloud --profile mint up -d mint   # [OWNER]
```

- Do **not** change `OVID_INTERNAL_MINT_URL` (or
  `OVID_INTERNAL_API_SECRET`) during an incident; flipping the mint surface
  is a planned, owner-gated cutover (P9 Task 18). Both gateway and worker
  must carry the SAME secret as mint.
- mint's own dependency failures (LiteLLM admin API, Redis db2, Postgres)
  must be fixed at the dependency (**I-12**, **I-2**, **I-5**), not by
  restarting mint repeatedly.
- A 402/429 from mint is a plan/allowance response and is relayed verbatim;
  it is not an outage.

**Verify.**

```bash
curl -sf http://127.0.0.1:8090/healthz        # 200 {ok:true}
set -a; . /opt/ovid-gateway/.env; set +a
docker exec ovid-gateway-redis-1 redis-cli --no-auth-warning -a "$REDIS_PASSWORD" -n 2 ping   # PONG
# Send a real message from a test account; expected: 202/enqueue, no 409.
curl -sf http://127.0.0.1:8082/cloud/v1/health
```

**Post-mortem hook.** Which dependency failed (LiteLLM admin, Redis db2,
Postgres), whether key provisioning left partial rows (the gateway orders
mint before any write), and the user-visible error class.

**Evidence.** `cloud/apps/gateway/src/routes/messages.ts` step 4 (mint before
any write; 402/429 relayed, everything else 409); `cloud/apps/mint/src/app.ts`
(`/healthz`); `server/mint/README.md`.

---

## I-12. LiteLLM outage

**Symptom.** Runs fail after retries with `model_transient_exhausted`, or
immediately with `model_terminal`; chat completions return 502; the worker
log names `litellm=`. Key minting may still work, so the failure is at the
model call, not at send time.

**Diagnose.**

```bash
curl -sf http://127.0.0.1:4000/health/liveliness && echo ' LITELLM LIVE'
docker logs --tail=120 ovid-gateway-litellm-1

# Routing/auth check (master key from /opt/ovid-gateway/.env)
set -a; . /opt/ovid-gateway/.env; set +a
curl -s -o /dev/null -w '%{http_code}\n' \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  http://127.0.0.1:4000/v1/models        # 200 = routing/auth fine

journalctl -u ovid-worker -n 120 --no-pager | grep -iE 'litellm|model_|502|ECONNREFUSED'
docker inspect ovid-gateway-litellm-1 --format '{{.Image}}'
docker image inspect ghcr.io/berriai/litellm:main-latest --format '{{index .RepoDigests 0}}' 2>/dev/null
```

**Act.**

```bash
cd /opt/ovid-gateway
docker compose -p ovid-gateway restart litellm     # [OWNER]
```

- If the image was recently pulled/recreated and the failure started then,
  roll back to the pinned digest per `HARDENING.md` G (one-line compose
  edit + `docker compose config -q` + `up -d litellm`).
- **Never** run an unpinned `docker compose pull` on a production incident;
  `main-latest` can silently swap in untested code and forward-only
  migrations. Pin by digest.
- Provider-side outage (upstream 429/5xx) is not fixed by a restart; the
  worker's retry ladder (`model_transient_exhausted`, 5 attempts with
  3/9/27/60 s sleeps) is the designed behavior. Escalate to the provider /
  model-alias owner.

**Verify.**

```bash
curl -sf http://127.0.0.1:4000/health/liveliness
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://127.0.0.1:4000/v1/models
journalctl -u ovid-worker -n 30 --no-pager | grep -i litellm
# Then run a real chat completion / one agent run.
```

**Post-mortem hook.** Upstream vs local; image digest before/after; whether
a pull changed the digest; retry counts; provider status page.

**Evidence.** `cloud/apps/worker/src/runProcessor.ts` (retry ladder and
error codes), HARDENING item G (pin/upgrade/rollback), DEPLOY.md §0
(loopback 4000).

---

## I-13. Key rotation (credentials and envelope keys)

**Symptom.** After a rotation: 401/403 from mint/LiteLLM/R2, Firebase auth
failures, `decrypt` failures on BYOK rows, or browser-state blobs that
"start fresh". Also run this playbook proactively per `HARDENING.md` C
(the repo history was public; rotate exposed material).

**Diagnose (identify the secret before changing anything).**

```bash
# Which surface is failing?
curl -sf http://127.0.0.1:8082/cloud/v1/health
curl -sf http://127.0.0.1:8090/healthz
curl -sf http://127.0.0.1:4000/health/liveliness
node /opt/ovid-cloud/repo/cloud/scripts/verify-r2.mjs    # [OWNER] live creds

journalctl -u ovid-worker -n 100 --no-pager | grep -iE '401|403|decrypt|master|token'
docker logs --tail=100 ovid-cloud-gateway-1 | grep -iE '401|403|decrypt|master|token'
```

**Act — blast radius table.** Every rotation is **[OWNER]**. Back up both
env files first and validate before restart.

| Secret | Lives in | Blast radius / procedure |
|---|---|---|
| Firebase service-account key | `/opt/ovid-gateway/firebase-admin.json` (mounted read-only into the cloud gateway) | HARDENING C #1: generate a new private key, replace `chmod 600`, restart consumers, verify sign-in, delete the old key. Brief auth failures during the swap. |
| Android upload/signing key | owner secret store | HARDENING C #2 (Play App Signing / upload-key rotation). Not a server secret. |
| `OVID_MASTER_KEY` (64 hex) | `/opt/ovid-cloud/repo/cloud/deploy/.env` + `/opt/ovid-cloud/worker.env` | Envelope KEK for BYOK (`byok_keys`) **and** browser storageState (`KEK = sha256(OVID_MASTER_KEY)`). Rotating it makes existing BYOK rows undecryptable and browser logins unreadable. Procedure: stop gateway+worker, generate `openssl rand -hex 32`, update BOTH files, restart; users must re-enter BYOK keys; browser state starts fresh (loud log, never a crash). High effort — schedule, do not improvise. |
| `OVID_INTERNAL_TOKEN` | both env files | Gateway↔worker file service. Update both, restart gateway+worker; brief 401s on file reads. |
| `OVID_INTERNAL_API_SECRET` (≥32 bytes) | `/opt/ovid-cloud/repo/cloud/deploy/.env` (gateway + mint profile) **and** `/opt/ovid-cloud/worker.env` | HMAC-SHA256 for the internal mint API (gateway/worker → mint). All three holders must carry the **same** value: gateway `cloud/apps/gateway/src/env.ts:167`, worker `cloud/apps/worker/src/main.ts:269`, mint `cloud/apps/mint/src/env.ts:255`. A mismatch makes key minting fail with 401/409 `key_not_minted` and unattended runs lose their key. Generate `openssl rand -hex 32`, update all three files, then restart worker+gateway+mint together; verify with a real send and an unattended run. |
| `OVID_ADMIN_MASTER_KEY` | `/opt/ovid-cloud/repo/cloud/deploy/.env` (mint profile) | Bearer token for mint's `/admin` console (`cloud/apps/mint/src/adminRoutes.ts:47,79`; required at `cloud/apps/mint/src/env.ts:254`). Rotating it invalidates admin clients only — no user data or provider keys are re-encrypted. Update `.env`, restart mint, update the admin client's stored token; verify `/admin` with the new key and 401 with the old. |
| `REDIS_Q_PASSWORD` | `/opt/ovid-cloud/repo/cloud/deploy/.env` (compose) + `worker.env` (host) | Recreate `redis-q` with the new password and restart gateway/worker. Queue data survives (AOF volume); expect a short write outage. |
| `REDIS_C_PASSWORD` | both env files | Recreate `redis-c`; cache loss is safe. |
| R2 Access Key ID / Secret | both env files | Cloudflare R2 token (Object Read & Write on `ovid-cloud` only). Update both, restart gateway+worker, run `verify-r2.mjs` + `r2.live` suite. |
| `LITELLM_MASTER_KEY` | `/opt/ovid-gateway/.env` | HARDENING C: new value → `docker compose up -d litellm` → update admin clients. Seconds of LiteLLM downtime. |
| `LITELLM_SALT_KEY` | `/opt/ovid-gateway/.env` | HARDENING C: encrypts provider keys in the LiteLLM DB. Rotation requires re-entering every provider credential. High effort. |
| `POSTGRES_PASSWORD` / `DATABASE_URL` | live `.env`; cloud env for `ovid_cloud` | `ALTER ROLE … PASSWORD` inside the container → update env → recreate dependents. Brief DB-auth outage. |
| Firebase App Check / project ids | `.env` | Update only with a coordinated client release. |

Commands common to every rotation:

```bash
# 1. Timestamped backups (never skip)
cp /opt/ovid-cloud/repo/cloud/deploy/.env "/opt/ovid-cloud/repo/cloud/deploy/.env.bak-$(date -u +%Y%m%dT%H%M%SZ)"
cp /opt/ovid-cloud/worker.env "/opt/ovid-cloud/worker.env.bak-$(date -u +%Y%m%dT%H%M%SZ)"
# 2. Edit, keep 600
sudo chmod 600 /opt/ovid-cloud/repo/cloud/deploy/.env /opt/ovid-cloud/worker.env
# 3. Validate the compose view before applying
cd /opt/ovid-cloud/repo/cloud/deploy && docker compose -p ovid-cloud config -q
# 4. Restart ONLY the consumers named in the table [OWNER]
ROTATED="${ROTATED:?set ROTATED to the secret key name being rotated}"
case "$ROTATED" in
  OVID_MASTER_KEY|OVID_INTERNAL_TOKEN|REDIS_Q_PASSWORD|REDIS_C_PASSWORD|R2_ACCESS_KEY_ID|R2_SECRET_ACCESS_KEY)
    sudo systemctl restart ovid-worker
    docker compose -p ovid-cloud up -d gateway
    ;;
  OVID_INTERNAL_API_SECRET)
    sudo systemctl restart ovid-worker
    docker compose -p ovid-cloud up -d gateway
    docker compose -p ovid-cloud --profile mint up -d mint   # only if TS mint is active
    ;;
  OVID_ADMIN_MASTER_KEY)
    docker compose -p ovid-cloud --profile mint up -d mint   # only if TS mint is active
    ;;
  LITELLM_MASTER_KEY|LITELLM_SALT_KEY)
    docker compose -p ovid-gateway up -d litellm
    ;;
  POSTGRES_PASSWORD|DATABASE_URL)
    sudo systemctl restart ovid-worker
    docker compose -p ovid-cloud up -d gateway
    # plus every live-stack consumer of that role (see the table row)
    ;;
  FIREBASE_PROJECT_ID|OVID_APPCHECK_APPS)
    echo "no server restart: ship a coordinated client release" >&2
    ;;
  *)
    echo "no restart recipe for $ROTATED — follow the table's row" >&2
    exit 1
    ;;
esac
# 5. Record: secret, date, operator, verification evidence (never the value)
```

**Verify.** The failing surface's health endpoint, plus the narrow probe:
mint `/healthz`, LiteLLM `/v1/models`, `verify-r2.mjs`, a real sign-in, a
real chat run, and (for `OVID_MASTER_KEY`) one BYOK `POST /byok/:id/test`
with a re-entered key.

**Post-mortem hook.** Which secret, why (exposure/schedule/compromise), what
could not be re-encrypted (BYOK/browser state), and the rotation date
recorded in the owner's secret log.

**Evidence.** `HARDENING.md` C (exposed material and server inventory),
`cloud/packages/escrow/src/envelope.ts` (master-key shape),
`cloud/deploy/BROWSERS.md` §(e) (browser-state KEK), R2-PROVISIONING step 2.

---

## I-14. Stuck runs (`run_lost`)

**Symptom.** A user reports a run that never finishes; the client waits
forever. `runs.status='running'` with `started_at` older than
`OVID_RUN_STALE_MS` (default 600 000 ms = 10 min); no terminal event.

Why it happens: `agent-runs` uses BullMQ `attempts: 1`. An unknown/infra
error fails the job permanently (failed ≠ stalled), and a worker crash
mid-run also fails it rather than redelivering. `claimNext` claims only
`queued` rows, so a redelivery could not recover it anyway.

**Diagnose.**

```bash
docker exec ovid-gateway-postgres-1 sh -c \
  'psql -U "${POSTGRES_USER:-postgres}" -d ovid_cloud -c "
   SELECT id, session_id, status, started_at, attempts, last_error
     FROM runs
    WHERE status = '\''running'\''
      AND started_at < now() - interval '\''10 minutes'\''
    ORDER BY started_at LIMIT 20;"'

systemctl is-active ovid-worker
journalctl -u ovid-worker -n 80 --no-pager | grep -i 'stale-run sweep'
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" LLEN bull:agent-runs:wait
```

**Act.**

- The worker sweeps at boot and every 60 s. A restart triggers an immediate
  boot sweep **[OWNER]**:
  `sudo systemctl restart ovid-worker`.
- No manual SQL is needed. If you must terminalize a row by hand, do it only
  as a last resort and with a dump first **[OWNER]** — the supported path
  claims the row with the conditional `runs.finish(...)` **first**, then
  appends `run_failed {code:"run_lost"}` to the stream and mirrors it; a raw
  `UPDATE` skips both the claim and the events.
- **One worker per host.** The shipped sweeper is list-then-claim (bounded to
  100 rows per pass): `runs.finish` is a conditional `status='running'`
  transition, so only the winner appends/mirrors and two concurrent sweeps
  emit **exactly one** event per run. The one-worker rule exists for browser
  ports 9400–9407 and cgroup ownership, not to prevent double emission.

**Verify.**

```bash
journalctl -u ovid-worker -n 40 --no-pager | grep 'stale-run sweep'
# expected: "stale-run sweep (boot): terminalized N stranded run(s)"
docker exec ovid-gateway-postgres-1 sh -c \
  'psql -U "${POSTGRES_USER:-postgres}" -d ovid_cloud -Atc "
   SELECT count(*) FROM runs WHERE status = '\''running'\''
     AND started_at < now() - interval '\''10 minutes'\'';"'
# expected: 0
# Event check for a known session:
SID="${SID:?set SID to the session id}"
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" \
  XREVRANGE "sess:$SID:events" + - COUNT 5
# expected: run_failed with payload {"runId":"…","code":"run_lost"}
```

**Post-mortem hook.** What stranded the run (crash, infra throw, lost
enqueue), the sweeper pass that caught it, and whether the client received
the terminal event via replay.

**Evidence.** `cloud/apps/worker/src/staleRuns.ts`; real-Postgres/real-Redis
test `staleRuns.test.ts`; the boot+60 s interval wiring in
`cloud/apps/worker/src/main.ts`; BullMQ `attempts: 1` ruling in
`cloud/packages/queue/src/queues.ts`. The P10 `worker-kill` chaos scenario
(`cloud/apps/load/src/chaos/scenarios/workerKill.ts`, landed in `212aa82`)
covers this recovery path on staging.

---

## I-15. Stuck schedule runs

**Symptom.** A schedule occurrence stays `schedule_runs.status='running'`
with no live run behind it; the user gets no push/transcript result; a
one-off never completes.

The settle reconciler (`settleScheduleRuns`) runs every scheduler tick
(15 s) and closes occurrences whose bound run is terminal, or whose run is
missing/queued past the 2-minute lost-enqueue window. It is idempotent via a
`FOR UPDATE` re-check on the occurrence row.

**Diagnose.**

```bash
docker exec ovid-gateway-postgres-1 sh -c \
  'psql -U "${POSTGRES_USER:-postgres}" -d ovid_cloud -c "
   SELECT sr.id, sr.schedule_id, sr.status, sr.attempt, sr.started_at,
          sr.run_id, r.status AS run_status, r.last_error
     FROM schedule_runs sr
     LEFT JOIN runs r ON r.id = sr.run_id
    WHERE sr.status = '\''running'\''
      AND sr.started_at < now() - interval '\''10 minutes'\''
    ORDER BY sr.started_at LIMIT 20;"'

systemctl is-active ovid-worker
journalctl -u ovid-worker -n 120 --no-pager | grep -iE 'scheduler|settle|schedule'
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" ZCARD bull:schedules:delayed
```

**Act.**

- Restart the worker **[OWNER]**; boot runs `resyncScheduleMirror` (re-arms
  delayed mirror jobs with deterministic job ids) and the tick loop resumes
  settle. Rows whose bound run is missing or still `queued` close after the
  2-minute lost-enqueue window; a row whose bound run is genuinely
  `running` is not settleable until the stale-run sweeper terminalizes that
  run (default 10 min — **I-14**), so fix the run first if both are stuck.
- If a row is still `running` after two ticks and its run is genuinely
  absent, escalate to the controller/owner. A manual transition is
  **[OWNER]** and must preserve the bookkeeping:
  take a dump first, then in one transaction mark the occurrence
  `status='failed'`, set `finished_at`, and record the reason; do not delete
  the schedule or the occurrence row.
- Do not delete `schedules` rows to "reset" a schedule; use the app's
  pause/resume/cancel surface.

**Verify.**

```bash
docker exec ovid-gateway-postgres-1 sh -c \
  'psql -U "${POSTGRES_USER:-postgres}" -d ovid_cloud -Atc "
   SELECT count(*) FROM schedule_runs
    WHERE status = '\''running'\''
      AND started_at < now() - interval '\''10 minutes'\'';"'
# expected: 0
journalctl -u ovid-worker -n 40 --no-pager | grep -iE 'settle|schedule'
# expected: occurrences settle; recurring schedules either retry or end
# paused/retries_exhausted per the ladder
```

**Post-mortem hook.** Lost enqueue vs worker crash vs run failure class;
attempt/retry ladder position; whether the push/transcript fired exactly
once (the settle idempotence contract).

**Evidence.** `cloud/apps/worker/src/schedulerSettle.ts` (2-minute
lost-enqueue window, `FOR UPDATE` idempotence, retryable codes
`model_transient_exhausted`/`run_lost`), `schedulerTick.ts` (15 s tick),
`schedulerMirror.ts` (boot resync), and `schedulerSettle.test.ts`.

---

# Part 2 — Ops

## O-1. Quarterly backup/restore drill

**Symptom.** The quarterly drill is due (also run it after the first
timer-produced backup, or whenever a backup's restorability is in doubt).
Prove a backup restores, not just that it was written. Full procedure:
`cloud/deploy/backup/README.md` → "Restore to a FOREIGN postgres (drill /
disaster recovery)".

**Diagnose (read-only).** Confirm a current backup exists and the archive is
intact:

```bash
# 1. A current backup exists and is intact (zstd -t only reads)
TS="${TS:?set TS to a backup timestamp from: ls -1t /opt/ovid-backups/pg | head -3}"
ls -1t /opt/ovid-backups/pg | head -3
zstd -t "/opt/ovid-backups/pg/$TS/"*.dump.zst
```

**Act.**

```bash
# 2. Scratch restore target (loopback only; never the live port).
#    NOTE: 5434 is the cloud postgres proxy once the stack is activated —
#    use 5435 for the drill. (The 2026-10-16 pre-activation drill used 5434.)
docker run -d --name ovid-restore-drill -e POSTGRES_PASSWORD=drill \
  -p 127.0.0.1:5435:5432 postgres:16-alpine

# 3. Restore one database (litellm shown; repeat for ovid_cloud)
docker exec ovid-restore-drill psql -U postgres -d postgres -q \
  -c 'CREATE ROLE litellm LOGIN;'
zstd -dc "/opt/ovid-backups/pg/$TS/litellm.dump.zst" | \
  docker exec -i ovid-restore-drill psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q
```

**Verify.**

```bash
# 4. Prove schema + data
docker exec ovid-restore-drill psql -U postgres -d postgres -Atc \
  "SELECT count(*) FROM pg_tables WHERE schemaname='public'"       # expect > 0
docker exec ovid-restore-drill psql -U postgres -d postgres -Atc \
  'SELECT count(*) FROM "LiteLLM_SpendLogs"'                       # spot-check

# 5. Cleanup verified
docker rm -f ovid-restore-drill
```

**Committed-evidence rule.** Append the result to
`cloud/deploy/backup/README.md` §Verification log, newest first. The
**2026-10-16 Task-11 entry is the template**: one live `pg_backup.sh` run,
free-space gate value, `zstd -t` output, restore exit code, `pg_tables`
count, cleanup confirmation, and the full-detail report path. A drill that
is not recorded there did not happen.

**Post-mortem hook.** If the restore fails: which step (role creation,
ownership, corrupt dump, missing extension), and whether the backup timer
had been running at all.

---

## O-2. Dependency updates

**Symptom.** A scheduled update window, a security advisory, or `pnpm audit`
failing on high/critical.

**Diagnose (read-only).** Review what is outdated and read the changelogs
before changing anything:

```bash
cd /opt/ovid-cloud/repo/cloud
pnpm outdated
git status --short pnpm-lock.yaml   # clean before you start
```

**Act.** `pnpm up` rewrites the production checkout's dependency tree, so it
is **[OWNER]**. Prefer a separate checkout/worktree; run it here only with the
owner in the channel.

```bash
cd /opt/ovid-cloud/repo/cloud

# 1. [OWNER] Review/choose updates deliberately (interactive)
pnpm up --interactive

# 2. Reinstall exactly what the lockfile now records
pnpm install --frozen-lockfile
```

**Rules.** One dependency family per commit; the lockfile is
`cloud/pnpm-lock.yaml` — never hand-edit it, and never commit it from an
unrelated task. Read the changelog for `bullmq`, `ioredis`, `postgres`,
`fastify`, `playwright-core` (the playwright pin is exact `1.64.1` and a bump
must re-run the screencast probe test — `BROWSERS.md` §(a)); never update
`pnpm`/Node without re-running the rootfs smoke (**O-3**); never bump
LiteLLM's image here (see **O-4**).

**Verify.** All of the following must pass:

```bash
# 3. Security gate (fail on high/critical)
pnpm audit --prod --audit-level high

# 4. Full build + test
pnpm -r build
pnpm -r test

# 5. Typecheck gate (production sources; the CI-proven form)
pnpm -r exec tsc --noEmit -p tsconfig.json

# Optional stricter pass where the per-package config exists. NOTE:
# `packages/account` has no tsconfig.check.json as of 2026-10-17, so the
# bare recursive form fails there; run it per package rather than pretending
# it is workspace-wide.
for d in apps/* packages/*; do
  if [ -f "$d/tsconfig.check.json" ]; then
    ( cd "$d" && pnpm exec tsc -p tsconfig.check.json --noEmit )
  fi
done
```

**Acceptance smoke.** `cloud/scripts/acceptance.sh` is on disk (landed in
`a28d737`): run `bash cloud/scripts/acceptance.sh --quick` before committing
(`--quick` skips gates 5–7, the load/chaos/canary gates) and the full script
before a release. Also run one staging smoke (`cloud/scripts/staging.sh up` →
`live-check`) when the change touches runtime code.

**Post-mortem hook.** Which dependency families changed, the lockfile diff
size, which gate failed, and whether the change was reverted or rolled
forward.

---

## O-3. Rootfs rebuild + pin

**Symptom.** The monthly rebuild is due, a CVE affects the pinned toolchain
(`cloud/deploy/rootfs/versions.env`), or a session reports
`RootfsUnavailable`. Rebuild, then activate atomically and keep two
revisions.

**Diagnose (read-only).** Confirm the active revision and the pins you are
about to rebuild:

```bash
readlink /opt/ovid-rootfs/current
ls -1d /opt/ovid-rootfs/ubuntu-noble-min-*
cat /opt/ovid-cloud/repo/cloud/deploy/rootfs/versions.env
```

**Act.** The pipeline is shipped; `build.sh` is docker-only and safe to run.

```bash
cd /opt/ovid-cloud/repo/cloud/deploy/rootfs

# 1. Bump REVISION if rebuilding the same date (install.sh refuses to
#    overwrite an existing revision directory).
REVISION=3 bash build.sh
# Output:
#   dist/ubuntu-noble-min-YYYYMMDD-r3.tar.zst
#   dist/ubuntu-noble-min-YYYYMMDD-r3.manifest.json
#   dist/ubuntu-noble-min-YYYYMMDD-r3.SHA256SUMS
# build.sh verifies zstd -t, writes the manifest (base digest, toolchain
# pins, dpkg snapshot, builder commit) and removes build residue on failure.

# 2. Activate [OWNER] — install.sh verifies SHA256SUMS, extracts, flips the
#    `current` symlink atomically, prunes to 2 revisions, and runs the
#    smoke jail itself.
sudo bash install.sh
# Gate: "smoke-jail: OK (… node …, pnpm …, uv …)" and the gcc shim refusing
# with exit 126.
```

**Rollback (instant, no rebuild).**

```bash
PREV="${PREV:?set PREV to the previous revision from: ls -1d /opt/ovid-rootfs/ubuntu-noble-min-*}"
sudo ln -sfn "$PREV" /opt/ovid-rootfs/current.tmp
sudo mv -T /opt/ovid-rootfs/current.tmp /opt/ovid-rootfs/current
# Then restart the worker so new jails use it [OWNER]:
sudo systemctl restart ovid-worker
```

**Rules.** Never point `OVID_ROOTFS` at `/tmp/ovid-rootfs-test` (stale r1
scratch). `install.sh` refuses to install over an existing revision
directory; bump `REVISION`. Host-gated suites must point `OVID_ROOTFS` at
`/opt/ovid-rootfs/current`.

**Verify.**

```bash
# 3. Gates
readlink /opt/ovid-rootfs/current                 # ubuntu-noble-min-YYYYMMDD-r3
ls -1d /opt/ovid-rootfs/ubuntu-noble-min-*        # exactly 2 revisions
```

`smoke-jail.sh` green (run by `install.sh`); a real session executes
`node -e`, `python3 -V`, `pnpm -v`, `uv -V`, `git --version`; the gcc shim
still refuses.

**Post-mortem hook.** If the build/install/smoke fails: which pin or tool,
the builder commit, whether two revisions remain, and whether the worker was
restarted after the symlink flip.

**Evidence.** `cloud/deploy/rootfs/{build.sh,install.sh,smoke-jail.sh}`,
`versions.env`, DEPLOY.md §11 step 2, HARDENING H7. Current artifact:
`ubuntu-noble-min-20261017-r2`.

---

## O-4. LiteLLM image pin / upgrade

**Symptom.** LiteLLM runs `main-latest` (unpinned), an upstream security
release needs a digest bump, or a recent pull changed behavior. Keep it on a
pinned digest and upgrade deliberately. This playbook points at
`HARDENING.md` item G; it does not duplicate it.

**Diagnose (read-only).** Capture what is running now and compare it with the
compose pin:

```bash
cd /opt/ovid-gateway
docker inspect ghcr.io/berriai/litellm:main-latest --format '{{index .RepoDigests 0}}'
docker inspect ovid-gateway-litellm-1 --format '{{.Image}}'
```

**Act — pin (owner, brief downtime).**

```bash
cd /opt/ovid-gateway
# 1. Timestamped backup
cp docker-compose.yml "docker-compose.yml.bak-pin-$(date -u +%Y%m%dT%H%M%SZ)"
# 2. Edit image: to ghcr.io/berriai/litellm@sha256:<digest>
# 3. Validate + apply
docker compose -p ovid-gateway config -q
docker compose -p ovid-gateway up -d litellm
```

**Upgrade (deliberate).** `docker pull ghcr.io/berriai/litellm:main-latest`
→ note the new `RepoDigests[0]` → repeat the pin steps with the new digest →
smoke a chat completion → on trouble, roll back to the previous digest
(one-line edit). Never upgrade during an incident; LiteLLM runs
forward-only DB migrations.

**Rollback.** Restore the pinned compose file, then re-up LiteLLM:

```bash
cd /opt/ovid-gateway
TS="${TS:?set TS to the .bak-pin timestamp: ls -1 docker-compose.yml.bak-pin-*}"
cp "docker-compose.yml.bak-pin-$TS" docker-compose.yml
docker compose -p ovid-gateway config -q    # must be silent before up
docker compose -p ovid-gateway up -d litellm
```

**Verify.**

```bash
docker inspect ovid-gateway-litellm-1 --format '{{.Image}}'
curl -sf http://127.0.0.1:4000/health/liveliness && echo ' LIVE'
# Then smoke a real chat completion / one agent run.
```

**Post-mortem hook.** Upstream vs local; digest before/after; whether a pull
changed the digest; provider-status and migration state.

**Evidence.** `cloud/deploy/HARDENING.md` G (full rationale and commands).

---

## O-5. Monitoring install / self-test

**Symptom.** `@ovid/watch` is not installed or its timer is not firing, or
the alert path has never been proven end to end. The on-box layer is
`@ovid/watch`; the install, verification gate, and edge-behavior drill live
in `cloud/deploy/monitoring/MONITORING.md`. The external layer (UptimeRobot)
is `HARDENING.md` item F. Keep both: an on-box watcher cannot report a dead
box.

**Diagnose (read-only).**

```bash
systemctl list-timers ovid-cloud-watch.timer          # NEXT <= 60 s
journalctl -u ovid-cloud-watch.service -n 20 --no-pager
# expected: "[watch] pass: 6 checks, 0 alerts, 0 recoveries"
```

**Act.** Install the unit/timer per **MONITORING.md** install steps, then
prove the sink. `--self-test` sends one real alert; run it only with owner
approval:

```bash
sudo /usr/bin/node /opt/ovid-cloud/repo/cloud/apps/watch/dist/main.js --self-test   # [OWNER]
```

**Verify.** `list-timers` shows the next run within 60 s; the journal shows
the six-check pass line above; the self-test alert was received on the real
sink (owner confirmation, recorded in MONITORING.md's install log).

**Post-mortem hook.** If an alert did not arrive: which layer failed (on-box
timer, check, or edge), the delivery credential (Telegram/webhook), and the
timer's last successful pass.

---

## Appendix A — Command verification (2026-10-17)

Read-only checks run on this host. The cloud stack is **not activated**
here, so post-activation targets are marked as such; the command form and
tool availability are what is verified.

```text
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1       193G   64G  130G  33% /

$ ps -eo uid,pid,cmd | awk '$1>=200000 && $1<210000'
(no output — no sandbox processes; expected pre-activation)

$ nft list table inet ovid_sandbox
Error: No such file or directory   # table absent: cloud stack not activated

$ ls -d /sys/fs/cgroup/ovid-sandboxes.slice
ls: cannot access '/sys/fs/cgroup/ovid-sandboxes.slice': No such file or directory

$ systemctl list-timers ovid-cloud-backup.timer --no-pager
NEXT LEFT LAST PASSED UNIT ACTIVATES
0 timers listed.                    # backup timer not installed yet

$ docker exec ovid-gateway-redis-1 redis-cli --version
redis-cli 7.4.11

$ docker exec ovid-gateway-postgres-1 psql --version
psql (PostgreSQL) 16.15

$ node --version
v22.23.3

$ zstd --version
*** Zstandard CLI (64-bit) v1.5.5, by Yann Collet ***
```

Host PATH does **not** contain `redis-cli` or `psql`; every command above
uses `docker exec`, which is why the runbooks do too.

Script paths cited were checked with `test -f`:
`cloud/scripts/staging.sh`, `verify-r2.mjs`, `dev-services.sh`,
`browser-memory-bench.mjs`, `cloud/deploy/backup/pg_backup.sh`,
`cloud/deploy/rootfs/{build.sh,install.sh,smoke-jail.sh}`,
`cloud/deploy/net/install-nft.sh`,
`cloud/deploy/workspaces/setup-workspaces.sh`,
`cloud/deploy/systemd/{ovid-worker.service,ovid-sandboxes.slice}`,
`cloud/deploy/backup/{ovid-cloud-backup.service,ovid-cloud-backup.timer}`,
`cloud/deploy/monitoring/{MONITORING.md,ovid-cloud-watch.service,ovid-cloud-watch.timer,watch.env.example}`.

Commands that could **not** be executed here (no activated cloud stack):
every `docker exec ovid-cloud-*`, `systemctl * ovid-worker`, cgroup reads,
`nft list table inet ovid_sandbox`, `/workspaces` checks, the R2 live probe,
and the rootfs smoke. Their syntax follows the shipped scripts/units and
the commands already proven in DEPLOY.md / BROWSERS.md / R2-PROVISIONING.md.
The Task-6 and Task-7 chaos scenarios and `acceptance.sh` are on disk but
were not run here (the chaos scenarios require the staging composition).
