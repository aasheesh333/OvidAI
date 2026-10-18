# Ovid Cloud — owner-gate checklist (single consolidated gate)

**Status: NOT EXECUTED.** This file is the one place the owner works through
at the end of the program. It consolidates the owner gates already written in
[`DEPLOY.md`](./DEPLOY.md), [`ROLLOUT.md`](./ROLLOUT.md),
[`RUNBOOKS.md`](./RUNBOOKS.md), [`R2-PROVISIONING.md`](./R2-PROVISIONING.md),
[`BROWSERS.md`](./BROWSERS.md), [`HARDENING.md`](./HARDENING.md),
[`KEY-ROTATION.md`](./KEY-ROTATION.md), and
`.superpowers/sdd/2026-10-16-ovid-cloud-p0-p1-spine/WAVE-MERGER.md`. It does
not replace those documents; it tells the owner what to do, in what order, and
which value must match which other value.

---

## 1. Read me first

**The hard rule: nothing here is safe to run out of order.** The order below
is **dependency-ordered, not severity-ordered**. A later gate assumes every
earlier gate passed. If a gate fails, stop and use that gate's rollback — do
not continue and come back.

**Who may run what.** An agent may run read-only diagnosis. `[OWNER]` marks a
row that mutates the live stack, creates a volume or unit, generates or
supplies a secret, writes to a store/console, or spends money. Those rows run
only with the owner present (same stop-condition as `DEPLOY.md` §11 and
`R2-PROVISIONING.md` §6).

**Never, in any row:**

- `docker compose down -v`, `docker volume rm`, or `docker system prune --volumes`
  on either stack (`RUNBOOKS.md` §0.1).
- `redis-cli FLUSHDB` / `FLUSHALL` on `redis-q` — queue jobs and the session
  event log are the only copy of in-flight work.
- Delete `/workspaces/users/<uid>` directly — use hibernation or account
  deletion.
- Run two `ovid-worker` processes on one host (Lightpanda owns ports
  9400–9407 exclusively).
- Weaken a threshold to make a gate pass.
- Write cloud secrets into `/opt/ovid-gateway/.env` unless a step explicitly
  says a live-stack consumer needs that value.

**Box facts already recorded in the repo** (re-verify read-only before
trusting them): `OVID_PUBLIC_IP=148.113.44.36`; 8 vCPU / 22 GB RAM / 193 GB
disk; Ubuntu 24.04; live stack `/opt/ovid-gateway` (Caddy host-network, mint
8090, LiteLLM 4000, account-dev 8080, postgres/redis with no host ports);
cloud gateway publishes on `127.0.0.1:8082` (8081 is the live Caddy admin
listener); redis-q 6391, redis-c 6393, postgres proxy 5434, mint-redis proxy
6392. `redis-cli` and `psql` are **not** installed on the host — use the
container forms in `RUNBOOKS.md` §0.2. See `DEPLOY.md` §0 and `RUNBOOKS.md`
§0.2 for the authoritative facts.

**Status snapshot.** As recorded on 2026-10-16/17, the cloud stack was **not
activated** on this box (no `ovid-cloud-*` containers). Before assuming
otherwise, run the read-only check:

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
docker compose -p ovid-cloud ps
curl -sf http://127.0.0.1:8082/cloud/v1/health
```

**Pre-flight conflicts before the first build.** Items 1 and 4 were fixed in
the templates/docs (this audit); items 2 and 3 remain owner work:

1. **Env-file path — RESOLVED.** The canonical gateway env is
   `/opt/ovid-cloud/repo/cloud/deploy/.env` (compose `env_file: [.env]`
   resolved next to `docker-compose.yml`; `provision.sh` reads
   `$SCRIPT_DIR/.env`). Every deploy doc now names that path. Do **not**
   create `/opt/ovid-cloud/.env`. The host worker file is separate and
   correct: `/opt/ovid-cloud/worker.env`.
2. **Lockfile.** `DEPLOY.md` §1/§11 step 1 uses
   `pnpm install --frozen-lockfile`, but the binding wave-merger says a fresh
   checkout **fails by design** until the lockfile is regenerated. Complete
   §7's lockfile regeneration **before** the first activation build.
3. **R2 is a boot dependency, not a later option.** The gateway
   (`cloud/apps/gateway/src/index.ts`) and the worker
   (`cloud/apps/worker/src/main.ts`) both call
   `createStorage(loadStorageEnv(env))` unconditionally at boot. The templates
   ship `NODE_ENV=production` + `OVID_STORAGE_BACKEND=r2`, and production
   refuses the `fs` backend. A **missing/empty** `OVID_R2_*` block stops both
   processes. Note the trap: `CHANGE_ME` is non-empty, so it passes the boot
   check and fails at the first storage call — only `verify-r2.mjs` (§5 step 5)
   proves the credentials. Complete R2 steps 1–5 before the first
   `docker compose up` and before enabling the worker.
4. **`provision.sh` requires `OVID_DEFAULT_MODEL` in the gateway `.env` —
   RESOLVED in the template.** `provision.sh` line 67 requires `DATABASE_URL`,
   `OVID_CLOUD_DB_PASSWORD`, `REDIS_Q_PASSWORD` **and**
   `OVID_DEFAULT_MODEL`; `.env.example` now carries
   `OVID_DEFAULT_MODEL=CHANGE_ME` for that reason. Fill it with the SAME live
   LiteLLM alias as `worker.env`'s `OVID_DEFAULT_MODEL` before running
   `./provision.sh`, or it dies with `OVID_DEFAULT_MODEL missing/empty`.

`[UNVERIFIED — confirm before running]` marks a command this checklist could
not prove against the checkout. Every other command is copied from a repo
artifact and its referenced script path was checked with `test -f`.

---

## 2. Blocking product decisions

These are questions, not recommendations. Each has an empty `Answer:` line.
Q1/Q2/Q3 are the three gates in `ROLLOUT.md` §0; Q6/Q7/Q8 come from
`docs/superpowers/HANDOFF-ovid-cloud-resume.md` and the P9/P7 plans and must be
added to the same decision log. Nothing downstream may preselect a branch.

### Q1 — clean break (CB) vs installed base (IB)

**QUESTION:** On launch day, does the thin client become the only supported
client (CB), or do old installed builds keep working through a dual-stack
window (IB)?

| Option | What it means | Consequence |
|---|---|---|
| **CB — clean break** | Forced update from day one; old builds cut off by a gateway min-app-version gate plus a "required update" store listing. | No dual-stack window; Python routes can be decommissioned on the R6 schedule. **Not executable today:** the min-version gate is not shipped (P8 Task 20 prepares the hook only). CB stays blocked until the gate lands, is tested against an old build, and the owner confirms the listing copy. A listing-only "required update" is not enforcement. |
| **IB — installed base** | `/cloud/*` is additive; Python routes stay live; a forced-update wave runs at `T + ____ weeks`. | Requires a compat-matrix test row (old-build routes healthy while both stacks are live) added to `cloud/scripts/acceptance.sh` or run as a documented manual gate **before** R5-IB. That row is not in the landed script today. |
| **Defer** | No branch chosen. | Blocks R3/R5/R6. R0–R2 can still proceed; R4's content is branch-independent but it still follows R3. |

`Answer: ______`  (CB / IB / defer; if IB, forced-update wave T + ____ weeks)

### Q2 — launch point / Play deadline

**QUESTION:** What are the internal-track duration, closed-track size, first
production submission date, hard Play deadline (if any), and crash-rate abort
threshold?

Locked mechanics (not choices): internal track → closed track → production
staged rollout `10% → 50% → 100%` with a **48 h soak at each step**; R4 (Play
Data Safety + privacy policy) is a hard gate before the first submission;
after R4, the soak minimum is three 48 h steps (6 days), plus the owner-set
internal and closed-track durations.

| Input | Owner answer |
|---|---|
| Internal-track duration | ______ |
| Closed-track size (testers) | ______ |
| Production submission date (first 10%) | ______ |
| Play deadline (hard date, if any) | ______ |
| Crash-rate abort threshold | ______ % |

`Answer: ______`  (record the five inputs above; no store submission happens without this)

### Q3 — staging story

**QUESTION:** Does staging run on this same VPS (SM) or on a second machine
(2M)?

| Option | What it means | Consequence |
|---|---|---|
| **SM — same machine** | Staging uses the loopback-only ports on this VPS: gateway `127.0.0.1:18082`, Postgres 15432, redis-q 16379, mint 18091/18092, mock LiteLLM `0.0.0.0:14000`. | This is what Tasks 1–12 actually used. It requires a maintenance window: the 100-user run competes for the same 8 cores and will starve concurrent work. `staging.sh live-check` is the live-unaffected guard. |
| **2M — second machine** | The compose file is location-transparent; `.env.staging` URLs and the nftables uid-range install change. | Before trusting it, run the Task 5 smoke (`load --profile smoke10`) and the Task 6 chaos `all` scenario set **once on the second machine**, and record the reports. No production Caddy/DNS change either way. Costs a second host. |

`Answer: ______`  (SM / 2M; if 2M, host: ______)

### Q6 — collaboration v2

**QUESTION:** Does collaboration v2 get ported/redesigned, or cut?

| Option | What it means | Consequence |
|---|---|---|
| **A — port/redesign** | Shared server-run sessions: `collabSessions`/`collabMembers`/`collabInvites`, gateway `/cloud/v1/collab/*` routes, WS presence/fanout, 10-member cap, billing attributed to the initiator, approvals only to the session owner. | Executes P9 Conditional Section A (A1–A3) plus e2e. Adds schema, routes, and money-attribution work. |
| **B — cut entirely** | No collab tables; remove `/s/{token}/{invite}` and the invite parameter; keep the `collab_message`/`collab_participant` report enum values for client compatibility; remove the `server/collaboration` decommission line (never deployed). | One commit; less surface. The shipped client currently gates collab execution OFF and shows a read-only message. |
| **Defer / flag-off** | Keep the shipped default: collab execution is flag-gated OFF (`Distribution.cloudExecution`), read-only message. Reversible in P8 Task 20. | P9 Conditional Section A must not dispatch. Users see read-only collaboration. |

`Answer: ______`  (A / B / defer)

### Q7 — Dart/Flutter SDK in cloud workspaces

**QUESTION:** Should the sandbox rootfs include the Dart/Flutter SDK so users
can run those toolchains in cloud workspaces?

| Option | What it means | Consequence |
|---|---|---|
| **Include** | Add the SDK to the rootfs image. | Roughly 3 GB image growth (per the handoff), longer rootfs build/distribution, and a Flutter project can exceed the Free 500 MB / Pro 2048 MB workspace quotas. Every jail pays the image size. |
| **Exclude (current state)** | The pinned rootfs has Node, pnpm, uv/Python, git and basic tools; `cloud/deploy/rootfs/versions.env` contains no Dart/Flutter. | Users cannot run `dart`/`flutter` in cloud workspaces. No image growth. |
| **Add later / on demand** | Separate opt-in layer or a later rootfs revision. | More work later; does not block launch. |

`Answer: ______`  (include / exclude / add later)

### Q8 — warm-disk budget

**QUESTION:** What should `OVID_MAX_WARM_GB` be at activation: the default 8,
the considered 12, or something larger?

| Option | What it means | Consequence |
|---|---|---|
| **8 GB (default)** | LRU cap below the admission budget. | Free-tier sessions may evict/rehydrate under a full load (each churn costs roughly 7 s of pack CPU plus a full hydrate on an 8-core box). Safest for the shared box. |
| **12 GB** | 24 admitted Free sessions × 500 MB = 12 GB, so every admitted Free session can stay warm; LRU then triggers mainly for Pro (2 GB) workspaces or disk pressure. | Less churn. Fits the 32 GB `/workspaces` volume and the 193 GB disk with the documented headroom; coordinate with `BACKUP_MIN_FREE_MB=2048` and the 80 % disk alert. |
| **16 GB+** | Larger warm cache. | Crowds per-user stores, backups, and the live production stack sharing the box. Not recommended by the P7 budget math. |

`Answer: ______`  (8 / 12 / other)

### Decision log

`ROLLOUT.md` §0 requires a dated signature before any rollout step. Add
Q6/Q7/Q8 to the same log.

| Date | Gate | Answer | Signed by |
|---|---|---|---|
| | Q1 | | |
| | Q2 | | |
| | Q3 | | |
| | Q6 | | |
| | Q7 | | |
| | Q8 | | |
| | R0 blocking state confirmed | | |

**Owner signature:** ______________________________  **Date:** ______________

### Where these decisions land in the rollout

`ROLLOUT.md` is the cutover script; this is only the map. Q1/Q2 drive R5 and
R6; Q3 branches R3; Q6 gates P9 Conditional Section A; Q7 scopes the rootfs;
Q8 sets the warm cap. The branch-independent order is:

| Stage | What it is | Cross-link |
|---|---|---|
| R0 | Hardening gate (A/B/C/E/G below) | `ROLLOUT.md` R0, `HARDENING.md` |
| R1 | Cloud-stack activation (compose spine, DB, Caddy `/cloud/*`) | `DEPLOY.md` §§1–9 |
| R2 | Monitoring live (on-box `@ovid/watch` + UptimeRobot) | `MONITORING.md`, §8 below |
| R3 | Thin-client internal track (staging; Q3 branch) | `ROLLOUT.md` R3, §6 below |
| R4 | Play Data Safety + privacy policy — **hard gate before submission** | `ROLLOUT.md` R4 |
| R5 | Store rollout `10/50/100`, 48 h soaks (Q2; Q1 enforcement) | `ROLLOUT.md` R5 |
| R6 | Python decommission (P9 runbook; Q1/Q6) | `DECOMMISSION.md` |
| R7 | Final acceptance + release evidence | `cloud/scripts/acceptance.sh` |

---

## 3. Blocking infrastructure gates (dependency order)

Sources: [`DEPLOY.md`](./DEPLOY.md) §11, [`HARDENING.md`](./HARDENING.md),
[`BROWSERS.md`](./BROWSERS.md) §(b)–(d),
[`R2-PROVISIONING.md`](./R2-PROVISIONING.md). Each numbered gate below has
the exact commands and its own rollback in the source section; do not compress
steps or skip a gate.

### 3.0 Ordered gate table

| # | Gate | Why it is here in the order | Owner |
|---|---|---|---|
| 0 | ~~Quiet tree + lockfile regeneration~~ **DONE** | Landed in `873d993`; a scratch `pnpm install --frozen-lockfile --offline` exits 0 with "Lockfile is up to date". Nothing to run. See §7. | — |
| 1 | bwrap probe → fill `MECHANISM.md` DECISION — **DONE 2026-10-18** | Branch a passed: unprivileged bwrap as uid 200000, `uid_map` `0 200000 1`, host file owner 200000, no AppArmor denial. S5 (ctty) and S6 (cpu.max ratio 0.49) pass. **`DECISION: setuid`** — no AppArmor profile, no rootmap launcher. The run also found and fixed a usrmerge bug in the probe itself. | `[OWNER]` (done) |
| 2 | R1 compose spine, or an explicit P2-only decision | §11 steps 5–7 assume the compose spine (gateway, redis-q, proxies) is up. If activating P2-only with the gateway absent, record that decision in the log. **PREPARED 2026-10-18:** `provision.sh` created the `ovid_cloud` role+DB and applied every migration; the compose env is filled and `docker compose config` is clean. **The `up -d --build` itself is awaiting the owner's explicit go-ahead** (it starts production services against the live Postgres/LiteLLM). | `[OWNER]` |
| 2a | R2 credentials: bucket, token, both env blocks, verified — **DONE 2026-10-18** | Bucket `ovid-cloud` (APAC, Standard, no public URL, no CORS); token `ovid-cloud-worker` = Object Read & Write, **scoped to that bucket only**, TTL Forever; 7-day multipart-abort lifecycle rule enabled; `verify-r2.mjs` 7/7 `[ok]` and `r2.live.test.ts` 10/10 green against the real bucket. Repo `cloud/deploy/.env` filled 0600. **Remaining:** copy the block into the live `/opt/ovid-cloud/worker.env` (gate 9). See §5. | `[OWNER]` (done) |
| 3 | §11 step 2 — rootfs install — **DONE 2026-10-18** | `ubuntu-noble-min-20261017-r2` installed and activated at `/opt/ovid-rootfs/current`; `smoke-jail.sh` OK (node v22.20.0, pnpm 10.34.0, uv 0.13.1, Python 3.12.3, gcc shim exit 126). The run also fixed a real smoke-jail bug: it compared `uv -V`'s whole line and could never pass. | `[OWNER]` (done) |
| 4 | §11 step 3 — `/workspaces` XFS volume — **DONE 2026-10-18** | 32 GB image at `/opt/ovid-workspaces.img`, `mkfs.xfs`, fstab line, mounted with `prjquota`. `stat -fc %T /workspaces` → `xfs`. | `[OWNER]` (done) |
| 5 | §11 step 3 — XFS EDQUOT sanity check — **DONE 2026-10-18** | 1 MiB project hard limit, 8 MiB `dd` → `dd: error writing …: No space left on device`, exactly 1048576 bytes written. Byte convention is correct (not off by 512×). Scratch project id 999999 cleaned up. | `[OWNER]` (done) |
| 6 | §11 step 4 — nftables egress filter — **DONE 2026-10-18** | `table inet ovid_sandbox` loaded for uid 200000-209999: RFC1918/CGNAT/loopback/link-local + seven IPv6 ranges + own public IP, all `counter … drop` at zero. Unit installed and enabled. | `[OWNER]` (done) |
| 7 | §11 step 5 — systemd slice + worker units — **DONE 2026-10-18** | `ovid-sandboxes.slice` and `ovid-worker.service` installed, `systemd-analyze verify` clean, `daemon-reload` done. Worker is **disabled and inactive**, as required until gate 10. | `[OWNER]` (done) |
| 8 | §11 step 6 — compose transition | Retire a P1 compose worker if present, bring up redis-q/proxies. | `[OWNER]` |
| 9 | §11 step 7 — fill `worker.env` | Every `CHANGE_ME`; see §4 for matching secrets. | `[OWNER]` |
| 10 | §11 step 7 — enable worker + nft unit | The first moment the host worker consumes the queue. | `[OWNER]` |
| 11 | §11 step 8 — functional smoke | Real session, `run_shell`, `write_file`, WS events, PTY, HARDENING H rows. | `[OWNER]` |
| 12 | Lightpanda install — **DONE 2026-10-18** | Pinned 1.0.1 sha256-verified at `/opt/ovid-browsers/lightpanda-1.0.1/lightpanda`; `lightpanda version` → 1.0.1, including as uid 230000. | `[OWNER]` (done) |
| 13 | Chromium install — **DONE 2026-10-18** | `chromium-1248` + `chromium_headless_shell-1248` at `/opt/ovid-browsers/ms-playwright`; both report 156.0.8078.4 and execute as uid 230000 (traversal + exec verified). | `[OWNER]` (done) |
| 14 | Browser gated suites + memory bench | Re-prove Lightpanda 1.0.1 and measure the chromium tree on this box before activation. | `[OWNER]` |
| 15 | Browser egress uid **wiring** | Code fix landed (`469d3f9`): browsers now drop to uid 230000 with no root fallback. Remaining owner work is host state — set the uid in worker.env, re-run `install-nft.sh`, confirm `/opt/ovid-browsers` is traversable by 230000, then verify `ps` + `nft`. See 3.13. | `[OWNER]` |
| 16 | R0 hardening A / B / C / E / F / G | Hard gate before real users; independent of the P2 order, but E+G batch into the activation window and C runs last. | `[OWNER]` |
| 17 | Browser per-host consent | NOT blocking activation (browser tools are not yet dispatched), but must be decided BEFORE they are wired: the on-device build required the user to grant each host a page-acting tool touches, and the server has only SSRF/egress control. See 3.15. | `[OWNER]` |

### 3.1 Gate 0 — quiet tree + lockfile — **ALREADY DONE, skip it**

Landed 2026-10-18 (commit `873d993`). The frozen install now resolves every
importer: a scratch copy carrying only the 19 manifests runs
`pnpm install --frozen-lockfile --offline` → "Lockfile is up to date,
resolution step is skipped", 380 packages, exit 0. The test-typecheck debt that
went with it is also zero and CI now enforces it. See §7 for the proofs.

**Start at Gate 1 (the bwrap probe).**

### 3.2 Gate 1 — bwrap probe (fills `MECHANISM.md` DECISION) — **DONE 2026-10-18**

**Result: `DECISION: setuid` (branch a).** Unprivileged bwrap as uid 200000
works with no AppArmor profile and no rootmap launcher: inside the jail
`uid=0`, `uid_map` is `0 200000 1`, and the file the jail writes is owned by
200000 on the host. No AppArmor denial appeared in dmesg. S5 (controlling
terminal + `stty size 24 80`) and S6 (`cpu.max` 50000/100000 → ratio 0.49)
both pass. Evidence: `cloud/deploy/sandbox/MECHANISM.md`, log
`/tmp/ovid-probe-final2.log`.

The first run failed all three branches with
`bwrap: execvp /bin/sh: No such file or directory` — a probe bug, not a host
one: Ubuntu 24.04 is usrmerge, so `/bin`, `/sbin`, `/lib`, `/lib64` are
symlinks into `/usr` and `--ro-bind /bin /bin` does not reconstruct them.
The probe now binds `/usr` and recreates the symlinks (commit `31e3674`).
Production is unaffected — the real invocation binds a complete rootfs at `/`.

<details><summary>Original run instructions (kept for re-runs)</summary>

Run from the repo root (`/opt/ovid-cloud/repo`):

```bash
sudo bash cloud/deploy/sandbox/sandbox-probe.sh 2>&1 | \
  tee /tmp/ovid-probe-$(date -u +%Y%m%dT%H%M%S).log
```

Source: `cloud/deploy/sandbox/MECHANISM.md`. The probe installs `bubblewrap`
via apt if absent, and on branch b installs/loads the `ovid-sandbox` AppArmor
profile. Expected gate: exactly one branch passes; the log shows
`uid=0(root)` inside the uid-200000 jail, `uid_map` line `0 200000 1`, and the
`touch` file owned by 200000 on the host. Fill the `DECISION:` line from the
log.

**Rootmap consequence (no longer applicable).** Had the probe selected
`DECISION: rootmap`, `createRootmapLauncher` in
`cloud/packages/sandbox/src/launcher.ts` is a throwing stub and §11 step 7
could not enable the worker until it was implemented. The host chose
`setuid`, so the working default stands.

</details>

### 3.3 Gate 2 — R1 compose spine (or P2-only decision)

Follow `DEPLOY.md` §§2–6. The minimum sequence:

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
cp .env.example .env && chmod 600 .env     # then fill every CHANGE_ME (§4)
./provision.sh --dry-run                   # validates, mutates nothing
./provision.sh                             # creates role/DB, applies migrations
docker compose up -d --build
curl -sf http://127.0.0.1:8082/cloud/v1/health
```

Gate: `{"status":"ok","checks":{"db":true,"redisQ":true}}`. The Caddy
`/cloud/*` route (§6) is a live-stack change and is part of R1; if you choose
P2-only activation with the gateway absent, record that decision in the log
and expect runs to queue until the gateway consumes them.

**Before `./provision.sh`:** it requires `OVID_DEFAULT_MODEL` in the gateway
`.env` even though the template says worker vars moved to `worker.env` (see
pre-flight conflict 4). Add the same live LiteLLM alias to both files.

**Do not run `docker compose up` until R2 steps 1–5 are done (§5).** Both the
gateway and the worker call `loadStorageEnv` at boot; the templates ship
`NODE_ENV=production` + `OVID_STORAGE_BACKEND=r2`; production refuses `fs`; a
missing/empty `OVID_R2_*` block is a boot refusal. `CHANGE_ME` is non-empty,
so it boots and then fails at the first storage call — run the probe before
trusting it.

### 3.4 Gate 3 — §11 step 2, rootfs install

```bash
cd /opt/ovid-cloud/repo/cloud/deploy/rootfs
sudo bash install.sh
```

`build.sh` is only needed for a fresh revision; the current artifact
`dist/ubuntu-noble-min-20261017-r2.tar.zst` is already built (verified on
disk). Gate: `install.sh` ends with `smoke-jail: OK (...)` and the gcc shim
refuses with exit 126. Rollback: back-flip `/opt/ovid-rootfs/current` to the
previous revision (the script keeps two).

### 3.5 Gate 4 — §11 step 3, `/workspaces` XFS volume

```bash
sudo bash /opt/ovid-cloud/repo/cloud/deploy/workspaces/setup-workspaces.sh
stat -fc %T /workspaces          # → xfs
mount | grep prjquota            # → the volume, mounted with prjquota
```

Optional: `OVID_WORKSPACES_SIZE_GB=32` (default) and the image/mount env vars
documented in the script header. Rollback: `sudo umount /workspaces` and
remove the `/etc/fstab` line the script added; deleting
`/opt/ovid-workspaces.img` destroys every user workspace.

### 3.6 Gate 5 — XFS EDQUOT sanity check (P2 final-review carry)

Run immediately after Gate 4. It writes a throwaway tree outside `users/`.

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
re-verification to this activation gate.

### 3.7 Gate 6 — §11 step 4, nftables egress filter

Author the worker env early (full secrets land at Gate 9), set
`OVID_PUBLIC_IP=148.113.44.36`, then render/validate/install:

```bash
sudo cp /opt/ovid-cloud/repo/cloud/deploy/worker.env.example /opt/ovid-cloud/worker.env
sudo chmod 600 /opt/ovid-cloud/worker.env
sudo $EDITOR /opt/ovid-cloud/worker.env      # set OVID_PUBLIC_IP at minimum

sudo bash -c 'set -a; source /opt/ovid-cloud/worker.env; set +a; \
  bash /opt/ovid-cloud/repo/cloud/deploy/net/install-nft.sh'
```

Keep `OVID_SANDBOX_CPU_MAX` quoted (the template ships it quoted) if you
source the file in a shell. Gate: the script ends with
`table inet ovid_sandbox loaded:` and `nft list table inet ovid_sandbox`
works with every `counter` line at `counter packets 0 bytes 0` on a fresh
load. Rollback: `sudo systemctl disable --now ovid-sandbox-nft && sudo nft
delete table inet ovid_sandbox`.

**Browser egress uid.** Fill `OVID_BROWSER_EGRESS_UID=230000` — the
contradiction in 3.13 is resolved in code (`469d3f9`): the browser engine now
drops to that uid with no root fallback, so the rendered rule actually
matches. The renderer still requires a single uid or range **>= 100000** and
rejects overlap with the sandbox range. Set it in worker.env and re-run
`install-nft.sh` in the same window so the ruleset and the engine agree; see
3.13 for the four-step verification.

### 3.8 Gate 7 — §11 step 5, systemd units

```bash
cd /opt/ovid-cloud/repo/cloud/deploy/systemd
sudo install -m 644 ovid-sandboxes.slice ovid-worker.service /etc/systemd/system/
sudo systemd-analyze verify /etc/systemd/system/ovid-sandboxes.slice /etc/systemd/system/ovid-worker.service
sudo systemctl daemon-reload
```

Gate: no errors (ordering warnings are acceptable; record them). Do **not**
enable the worker yet. Rollback: remove both unit files and
`systemctl daemon-reload`.

### 3.9 Gate 8 — §11 step 6, compose transition

If a P1 compose worker is running, retire it first (queue data in
`ovid-cloud-redis-q-data` is untouched). The first form works only from a
checkout that still holds the P1 compose file; the second works by container
name once the P2 compose file is checked out:

```bash
docker ps --filter name=ovid-cloud-worker --format '{{.Names}}'
# P1 checkout:
docker compose stop worker && docker compose rm -f worker
# P2 checkout (by container name):
docker stop ovid-cloud-worker-1 && docker rm ovid-cloud-worker-1
```

Then bring up the P2 compose:

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
docker compose up -d
```

Gates from `DEPLOY.md` §11 step 6:

```bash
curl -sf http://127.0.0.1:8082/cloud/v1/health            # → {"status":"ok",…}
redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" -p 6391 ping   # → PONG
psql "postgres://ovid_cloud:$OVID_CLOUD_DB_PASSWORD@127.0.0.1:5434/ovid_cloud" -c 'select 1'
ss -tlnp | grep -E ':(5434|6391|6392)\b'                  # → 127.0.0.1 binds ONLY
```

**Host-binary caveat:** `redis-cli` and `psql` are **not installed on the
host** (`RUNBOOKS.md` §0.2), so the middle two commands as written are
`[UNVERIFIED — confirm before running]`. Use the verified container forms:

```bash
docker exec ovid-cloud-redis-q-1 redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" ping
docker exec ovid-gateway-postgres-1 sh -c 'psql -U "$POSTGRES_USER" -d ovid_cloud -Atc "SELECT 1"'
```

(`REDIS_Q_PASSWORD`/`OVID_CLOUD_DB_PASSWORD` are in the gateway env; source it
in the shell running the gates.)

### 3.10 Gate 9/10 — §11 step 7, worker env + enable

```bash
sudo $EDITOR /opt/ovid-cloud/worker.env
sudo chmod 600 /opt/ovid-cloud/worker.env
sudo systemctl enable --now ovid-worker ovid-sandbox-nft
```

Complete every `CHANGE_ME` in `worker.env.example`; the matching requirements
are in §4. The non-secret required values are: `OVID_PUBLIC_IP=148.113.44.36`;
`OVID_DEFAULT_MODEL` = a live LiteLLM alias (also required in the gateway
`.env` by `provision.sh`; see pre-flight conflict 4); `OVID_SANDBOX_LAUNCH` per
the probe DECISION; `GOOGLE_APPLICATION_CREDENTIALS=/opt/ovid-gateway/firebase-admin.json`;
`OVID_LIGHTPANDA_BIN` and `PLAYWRIGHT_BROWSERS_PATH` (Gates 12–13);
`OVID_ROOTFS=/opt/ovid-rootfs/current` (never `/tmp/ovid-rootfs-test`);
`OVID_MAX_WARM_GB` per Q8; `OVID_DISK_ALERT_PCT=80`.

Gates:

```bash
systemctl is-active ovid-worker ovid-sandbox-nft            # → active active
journalctl -u ovid-worker -n 50 --no-pager                  # → "consuming agent-runs" …, no RootfsUnavailable
cat /sys/fs/cgroup/ovid-sandboxes.slice/ovid-worker.service/cgroup.subtree_control
                                                           # → cpu memory pids
systemctl show ovid-sandboxes.slice -p CPUQuotaPerSecUSec  # → 6s (600%)
systemctl show ovid-worker -p MemoryMax                    # → 4294967296 (4G)
```

Rollback: `sudo systemctl disable --now ovid-worker` (and optionally delete
the nft table). The env file stays; `sudo rm` it only when decommissioning.

### 3.11 Gate 11 — §11 step 8, functional smoke

From a real app build (or the e2e harness pointed at production with a real
Firebase token + App Check): create a session → POST a message whose run
executes `run_shell {command:"echo …"}` and `write_file` → watch the WS
channel for ordered `tool_started`/`tool_completed` → open a terminal via
`pty_open` and type. All five gates in `DEPLOY.md` §11 step 8 must be green,
including `HARDENING.md` item H rows dated.

### 3.12 Gates 12/13 — Lightpanda + Chromium

```bash
# From the repo root. Pinned Lightpanda 1.0.1, checksum-verified, idempotent.
bash cloud/deploy/install-lightpanda.sh

# Chromium 156.0.8078.4 into the shared browser root.
PLAYWRIGHT_BROWSERS_PATH=/opt/ovid-browsers/ms-playwright \
  node cloud/node_modules/playwright-core/cli.js install chromium --with-deps
```

The Chromium command is `[UNVERIFIED — confirm before running]`: the referenced
`cloud/node_modules/playwright-core/cli.js` does **not** exist in this
checkout (no `node_modules`), and the wave-merger notes that a fresh checkout's
`pnpm install` is what creates the `@ovid/browser` link. Run it only after the
lockfile regeneration and install in §7.

Then re-prove the pinned behaviors on the box before activation:

```bash
OVID_LIGHTPANDA_BIN=/opt/ovid-browsers/lightpanda-1.0.1/lightpanda \
  PLAYWRIGHT_BROWSERS_PATH=/opt/ovid-browsers/ms-playwright \
  pnpm --filter @ovid/browser test
```

The real-binary gated suites must be green. Any divergence: stop, escalate,
do not activate. Also run the memory bench (Gate 14 / §8).

### 3.13 Gate 15 — browser egress uid (**RESOLVED in code; one owner step left**)

**Former blocker, now fixed** (commit `469d3f9`, P6 egress-uid fix). The
contradiction was real: `BROWSERS.md` §(d) called
`OVID_BROWSER_EGRESS_UID` "the worker uid", the worker runs `User=root`
(uid 0), the parser requires **>= 100000** and a keyspace distinct from the
sandbox range (200000–209999 prod / 220000–229999 staging), and **no browser
process ever dropped uid** — so the rendered `meta skuid <range>` rules
matched nothing.

What the fix does now:

- Browsers run under a **dedicated uid** (`OVID_BROWSER_EGRESS_UID`, ship
  value `230000`), applied to **both** engines. Lightpanda spawns with
  `{uid, gid}` directly. Playwright 1.64.1 has no `uid` launch option, so
  Chromium goes through a generated root-owned 0755 `setpriv` shim used as
  `executablePath`: it chowns Playwright's root-created `--user-data-dir`,
  then `exec setpriv --reuid=<uid> --regid=<uid> --clear-groups <chromium>`.
  Every child (zygote, renderers, crashpad) inherits the uid. Verified on the
  host with real Chromium 156.0.8078.4: all processes at uid/gid 230000.
- **No silent root fallback.** Engine construction throws when the worker is
  non-root, the uid is invalid or overlaps the sandbox block, `setpriv` is
  missing, Chromium is missing/non-executable, or a probe fails.
- **Production refuses the inert combination.** `OVID_BROWSER_UID_DROP=disabled`
  is rejected when `NODE_ENV=production`; a uid set together with `disabled`
  is refused outright ("the rendered nftables browser rule would be inert");
  and production requires the uid to be present.

**The one remaining owner step** — the code and the ruleset must agree, and
the ruleset is host state:

1. Set `OVID_BROWSER_EGRESS_UID=230000` in `/opt/ovid-cloud/worker.env`
   (both templates now ship it).
2. Re-run `cloud/deploy/net/install-nft.sh` so the browser rule keys the same
   uid the engine now applies.
3. Confirm `/opt/ovid-browsers` and the installed Chromium are
   traversable/executable by uid 230000 (production installs there, not under
   `/root` — a `0700 /root` path would fail the boot probe, loudly).
4. Verify after the worker starts: `ps -eo uid,cmd | grep -E 'chromium|lightpanda'`
   shows **only** 230000, and `nft list table inet ovid_sandbox` shows the
   matching `meta skuid` range.

Record the uid and the `ps`/`nft` evidence in the decision log.

### 3.14 Gate 16 — R0 hardening (A/B/C/E/F/G)

These are independent of the P2 order but are a hard gate before real users
(`ROLLOUT.md` R0). Execute exactly as written in `HARDENING.md`; do not
duplicate the commands here.

| Item | Action | Note |
|---|---|---|
| A | Disable `novnc`, `vncserver@1`, `vsftpd`; close ufw 6080/5901/21/40000:50000. | Removes the internet-exposed **root** desktop and plaintext FTP. |
| B | SSH key-only, after proving a key login from **every** owner device. | The cloud-init drop-in currently forces password auth on; verify effective `sshd -T`. |
| C | Rotate exposed secrets: Firebase service-account key, Android signing keystore/Play App Signing, any other credential exposed while the repo was public. | **Runs last in R0**; rotation is not cleanly reversible. |
| D | Caddy `trusted_proxies` | **Already done** (verified 2026-10-16). Re-verify only; no action. |
| E | Docker log rotation: create `/etc/docker/daemon.json` with `max-size=50m`, `max-file=3`; restart docker. | Restarts every container; batch with G in the activation window. Existing containers keep their old config until recreated. |
| F | External uptime alerting: UptimeRobot monitor 1 (`https://api.ovidsi.com/healthz`) now; monitor 2 (`/cloud/v1/health`) at R2. | Owner account action; the DOWN-alert test and monitor 2 are in §8.2. |
| G | Pin `litellm:main-latest` to the running digest. | Brief LiteLLM downtime; batch with E. Never run an unpinned `docker compose pull` in an incident. |

Gate: all seven R0 boxes checked and their verification lines recorded in
`HARDENING.md` §"Decision log" (D is already verified). If any of A, B, C, E,
F or G is unchecked, stop and do not route user traffic.

### 3.15 Gate 17 — browser per-host consent (**decide before browser tools are wired**)

**Not blocking activation today** — the browser tools are defined in
`@ovid/browser` but are not yet dispatched by `runProcessor`, so the gap below
cannot be exercised. It becomes live the moment someone wires them in, which
is why it must be decided before that happens.

The on-device client enforced a USER-CONSENT boundary the server does not have:

- `browser_open`/`browser_navigate` gated the host being navigated TO, but a
  click, a JS redirect or a `target=_blank` can move the tab elsewhere
  afterwards. So 15 "page-acting" tools (`browser_read`, `evaluate`, `click`,
  `type`, `fill`, `screenshot`, `cookies`, `download`, `upload`, …) re-probed
  the tab's LIVE `location.host` and required the user to have granted THAT
  host. Without it the model could grant one host and then walk to any other.
- The server has `guardUrl` → `assertPublicHost` (`packages/browser/src/sessionOps.ts`),
  which is SSRF/egress control: it refuses non-public addresses and non-http
  schemes. It knows nothing about which hosts the user approved, and there is
  no per-host grant concept anywhere in `packages/browser` or
  `packages/agent-core`. The P6 plan never mentions grants or consent, so this
  was dropped silently rather than decided.

| Option | What it means | Consequence |
|---|---|---|
| **A. Re-implement server-side** | The session records its approved host set; a page-acting tool whose live host is not in it raises an approval through the existing P3 approvals machinery | Restores the on-device guarantee. Costs a per-tool host probe and an approval round-trip on host change. |
| **B. Accept egress-only** | The tool call itself is the user's consent boundary; nftables + SSRF are the safety net | Simpler and arguably fine now that the browser is server-side and the user watches tool calls. But it IS a reduction from the on-device build — say so in the spec rather than leaving it implicit. |

`Answer: ______` (A / B)

---

## 4. Secrets the owner must generate or supply

This is the section most likely to cause a production incident. Read 4.0
before writing any file.

### 4.0 Canonical env files and the path conflict

| Consumer | File the code actually reads | Source |
|---|---|---|
| Gateway + mint (compose) | `/opt/ovid-cloud/repo/cloud/deploy/.env` | `docker-compose.yml` `env_file: [.env]`; `provision.sh` requires `$SCRIPT_DIR/.env` |
| Host worker (systemd) | `/opt/ovid-cloud/worker.env` | `systemd/ovid-worker.service` `EnvironmentFile=` |
| Live Python stack | `/opt/ovid-gateway/.env` | **Read-only source** for `REDIS_PASSWORD` and `LITELLM_MASTER_KEY`; do not write cloud secrets here |

**Canonical path:** `/opt/ovid-cloud/repo/cloud/deploy/.env` — the compose
`env_file: [.env]` resolved next to `docker-compose.yml`, and
`provision.sh`'s `$SCRIPT_DIR/.env`. It is the only gateway env file; do
**not** create `/opt/ovid-cloud/.env`. A split copy produces the classic
failure: the gateway starts with one password while the worker uses another.
The host worker file is `/opt/ovid-cloud/worker.env`.

Generation commands (all from the templates):

```bash
openssl rand -hex 32   # OVID_MASTER_KEY, OVID_INTERNAL_TOKEN, OVID_INTERNAL_API_SECRET, OVID_ADMIN_MASTER_KEY
openssl rand -hex 24   # OVID_CLOUD_DB_PASSWORD, REDIS_Q_PASSWORD, REDIS_C_PASSWORD (alphanumeric only)
```

`OVID_CLOUD_DB_PASSWORD` must be alphanumeric — `provision.sh` validates it
before quoting it into SQL.

### 4.1 Secret / matching matrix

Each row is an owner action (`[OWNER]`). "Gateway env" means the canonical
compose file in 4.0.

| Secret | Generate / supply | Where it goes | Must match | Divergence / absence failure mode | Owner |
|---|---|---|---|---|---|
| `OVID_MASTER_KEY` | `openssl rand -hex 32` (exactly 64 hex chars) | Gateway env **and** `/opt/ovid-cloud/worker.env`. The escrow package is in-process; the rotation CLI reads the same value from the environment. | Gateway == worker. The same key is the KEK for BYOK envelopes, MCP/plugin sealed columns, and browser storageState (`KEK = sha256(OVID_MASTER_KEY)`). | Empty: gateway refuses boot in `firebase` mode; worker refuses boot because `OVID_BROWSER_STATE_DIR` is set. Mismatch: BYOK decrypt fails (`500 BYOK key could not be decrypted`), MCP/plugins fail closed, browser logins "start fresh". Rotation makes existing BYOK rows and browser blobs unreadable — plan it, never improvise. | `[OWNER]` |
| `OVID_CLOUD_DB_PASSWORD` | `openssl rand -hex 24` | Gateway env as `OVID_CLOUD_DB_PASSWORD` **and** embedded in the gateway `DATABASE_URL`; worker `DATABASE_URL` (via `127.0.0.1:5434`). | All three occurrences must be identical. `provision.sh` creates the role with this value. | `provision.sh` refuses a `CHANGE_ME`. A mismatch between the role password and either URL gives Postgres `28P01`; gateway health `db:false` (503), migrations and worker runs fail. | `[OWNER]` |
| `REDIS_Q_PASSWORD` | `openssl rand -hex 24` | Gateway env as `REDIS_Q_PASSWORD` **and** in `REDIS_Q_URL`; worker `REDIS_Q_URL`. The redis-q container receives it from the compose env. | Gateway var == gateway URL == worker URL == container password. | Gateway health `redisQ:false` (503); worker `NOAUTH`/`WRONGPASS`; messages enqueue nowhere and runs never start. Queue data itself is not lost (AOF volume), but the stack is down until the values agree. | `[OWNER]` |
| `REDIS_C_PASSWORD` | `openssl rand -hex 24` | Gateway env as `REDIS_C_PASSWORD` **and** in `REDIS_C_URL` (`redis-c:6379`); worker `REDIS_C_URL` (`127.0.0.1:6393`). | Password must match; the host/URL legitimately differs by consumer. | Cache auth errors; activity tracking and warm-LRU ordering degrade. The worker falls back to `REDIS_Q_URL` only when `REDIS_C_URL` is **unset**, not when the password is wrong. | `[OWNER]` |
| `OVID_INTERNAL_TOKEN` | `openssl rand -hex 32` | Gateway env **and** worker env. | Gateway == worker. | Gateway→worker file service returns 401; lazy file reads, artifact listing, and file operations fail. Gateway refuses boot in `firebase` mode if empty; worker refuses boot if empty. | `[OWNER]` |
| `OVID_INTERNAL_API_SECRET` | `openssl rand -hex 32` (must be >= 32 bytes) | Gateway env (shared by gateway + mint) **and** worker env. | Gateway == mint == worker. | Mint rejects the HMAC; unattended key minting fails; gateway collapses the failure to `409 key_not_minted`; scheduled/unattended runs cannot mint. Gateway/worker refuse boot if empty or shorter than 32 bytes. | `[OWNER]` |
| `OVID_ADMIN_MASTER_KEY` | `openssl rand -hex 32` | Gateway env only (the mint admin console reads it). | No second file; it must match whatever the owner uses as the admin bearer token. | Mint refuses boot if absent (`requiredString`). A wrong value gives 401 on `/admin`; no end-user impact until the console is used. | `[OWNER]` |
| Firebase credentials | Supplied: existing `/opt/ovid-gateway/firebase-admin.json`; rotate per `HARDENING.md` C #1 if exposed. Also fill the mint's `FIREBASE_PROJECT_ID` and `OVID_APPCHECK_APPS=android:…,web:…` (`.env.example` Mint block). | Gateway bind-mounts the JSON read-only to `/etc/ovid/firebase-admin.json` (default `FIREBASE_CREDENTIALS_HOST_PATH=/opt/ovid-gateway/firebase-admin.json`); the host worker reads the host path directly via `GOOGLE_APPLICATION_CREDENTIALS`. The gateway's App Check verifier uses the same service account (no separate app-id allowlist env). | The container mount and the worker host path must be the **same** file (or the copy variant must keep both copies in sync and both rotated). | Gateway cannot verify Google ID tokens / App Check (auth failures / 401s). Worker FCM pushes fail soft and log once; runs/settle/API are unaffected. A stale copy after rotation breaks whichever consumer still points at it; a missing `FIREBASE_PROJECT_ID`/`OVID_APPCHECK_APPS` stops mint at boot. | `[OWNER]` |
| R2 credentials | Supplied by Cloudflare: `OVID_R2_ACCOUNT_ID` (hex account id, not email), `OVID_R2_ACCESS_KEY_ID`, `OVID_R2_SECRET_ACCESS_KEY`; `OVID_R2_BUCKET=ovid-cloud`. | Gateway env **and** worker env. The backup block may reuse the same token as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. | Account id, key id, secret, and bucket must be identical in both files. | A **missing/empty** block fails loudly at boot; the `fs` backend is refused in production. `CHANGE_ME` is non-empty and passes boot, then fails at runtime — run `verify-r2.mjs`. A wrong/expired token gives 403 on hibernate/hydrate/attachments; backups stay local-only when the `AWS_*` pair is unset. | `[OWNER]` |
| `LITELLM_MASTER_KEY` | Supplied from `/opt/ovid-gateway/.env` (read it there; never commit it). | Gateway env as `LITELLM_MASTER_KEY` (the mint service uses it for LiteLLM's admin API) **and** as `OVID_LITELLM_MASTER_KEY` (gateway + worker account-cleanup key block/delete); worker env also carries `OVID_LITELLM_MASTER_KEY`. | All three names must carry the same live LiteLLM master key. | Mint cannot call LiteLLM admin; key provisioning fails; gateway returns `409 key_not_minted`; users cannot send. Account cleanup key block/delete fails and retries (the worker template ships `OVID_LITELLM_MASTER_KEY=CHANGE_ME`, which is non-empty and will be used — no boot refusal catches it). Do not rotate without `HARDENING.md` C and the LiteLLM upgrade/pin procedure. | `[OWNER]` |
| `REDIS_PASSWORD` (live-stack) | Supplied from `/opt/ovid-gateway/.env`. | Embedded in `REDIS_MINT_URL` / `REDIS_DB2_URL` in the gateway env and in worker `REDIS_MINT_URL` (db **2**). | Must equal the live mint Redis password. | Mint key reads/writes fail; gateway mint calls fail; users see `409 key_not_minted`. Do not "fix" by editing the live Redis password during an incident. | `[OWNER]` |

**Not a secret, but required and easy to miss:** `OVID_PUBLIC_IP=148.113.44.36`
in `worker.env` (nft renderer and SSRF self-block) and
`OVID_BROWSER_EGRESS_UID` (blocked by 3.13).

### 4.2 Rules for every secret row

- Back up both env files before editing; keep `600`:
  `cp <file> "<file>.bak-$(date -u +%Y%m%dT%H%M%SZ)"`.
- Never commit, paste into a ticket, or pass on a command line (the rotation
  CLI deliberately reads named env vars, not argv).
- After editing, validate the compose view before restarting:
  `cd /opt/ovid-cloud/repo/cloud/deploy && docker compose -p ovid-cloud config -q`.
- Restart only the consumers named in the row. The cloud gateway is a compose
  service (`docker compose -p ovid-cloud up -d gateway`); the worker is
  `sudo systemctl restart ovid-worker`.
- **Do not follow `KEY-ROTATION.md` §3 literally for the cloud master key.**
  It names `/opt/ovid-gateway/.env` and
  `docker compose -f /opt/ovid-gateway/docker-compose.yml up -d gateway worker`.
  Those are the live Python stack's paths/services, not the cloud stack's.
  The cloud consumers are the gateway env and `/opt/ovid-cloud/worker.env`
  (`RUNBOOKS.md` I-13). Mark that command `[UNVERIFIED — wrong stack for the
  cloud key; do not run]`.
- Record: secret name, date, operator, verification evidence — never the
  value (`RUNBOOKS.md` I-13).
- **`OVID_LITELLM_MASTER_KEY` is a second env name, not a second secret.**
  The gateway and host worker read it for account cleanup (key block/delete,
  `/key/list?user_id=`); the mint reads `LITELLM_MASTER_KEY`. Fill both with
  the same live value. The worker template ships it as `CHANGE_ME` (non-empty,
  so it is used rather than warned about) — a real 401 source.
- **Gateway LiteLLM base.** The gateway's account cleanup defaults to
  `http://127.0.0.1:4000`, which is host-loopback and wrong inside the
  container. Set `OVID_LITELLM_BASE=http://ovid-gateway-litellm-1:4000`
  (the value the mint's `LITELLM_BASE` already uses) in the gateway env; the
  host worker keeps `http://127.0.0.1:4000`.
- **Account deletion is opt-in.** `OVID_ACCOUNT_FIREBASE_APP_IDS` is empty by
  default. Do not enable it until `OVID_LITELLM_MASTER_KEY` and the real R2
  block are set; otherwise cleanup warns loudly and private objects under
  `users/{uid}/` survive (`.env.example` P9 carries).

---

## 5. R2 provisioning (P7 storage activation)

Source: [`R2-PROVISIONING.md`](./R2-PROVISIONING.md). **Everything here is
artifacts-only until the owner explicitly approves activation.** Do not create
the bucket, mint the token, run `docker compose up`, or flip
`OVID_STORAGE_BACKEND=r2` before that approval.

**Ordering warning:** approval cannot be deferred past R1/P2. The gateway and
worker both call `loadStorageEnv` at boot, and production refuses the `fs`
backend, so steps 1–5 below are a **hard prerequisite** for the first
`docker compose up` and for enabling `ovid-worker` (see §3 Gate 2a). The
"artifacts-only until approval" rule means the owner approves R2 *before*
those boots — not that R2 can be skipped. `CHANGE_ME` is non-empty and passes
the boot check; step 5's `verify-r2.mjs` (seven `[ok]` lines, exit 0) is the
real gate.

| Step | Action | Gate / detail | Owner |
|---|---|---|---|
| 1 | Create the R2 bucket `ovid-cloud` (Cloudflare dashboard). | No CORS; **no public access / `r2.dev` URL**; default storage class Standard. | `[OWNER]` **DONE 2026-10-18** |
| 2 | Create a least-privilege API token. | **Object Read & Write**, scoped to `ovid-cloud` only; **no account-admin/billing/bucket-admin**; record TTL/expiry. Cloudflare shows the secret once. Store in both env files; `chmod 600`. | `[OWNER]` **DONE** — token `ovid-cloud-worker`, TTL Forever, repo `.env` 0600 |
| 3 | Lifecycle rules. | **AbortIncompleteMultipartUpload: 7 days — required.** `pg/{TS}/…` (the actual backup prefix) has no expiration. `users/` follows application lifetime; no bucket-wide expiration without an owner decision. | `[OWNER]` **DONE** — default + `abort-incomplete-multipart-7d`, no expiration rule |
| 4 | Fill the `Storage (P7)` block in both env files. | See the value list below; shared values must be identical. | `[OWNER]` repo `.env` done; `worker.env` at gate 9 |
| 5 | Verify the credentials. | `verify-r2.mjs` must print seven `[ok]` lines (config, put, head, get, presign, delete, gone) and exit 0; `r2.live.test.ts` must be green (not skipped). | `[OWNER]` **DONE** — 7/7 and 10/10 |
| 6.1 | Dry validation (no side effects). | `docker compose config -q`; `node --check ../scripts/verify-r2.mjs`. | no |
| 6.2 | Bring up redis-c + updated gateway. | `docker compose up -d --build` (`--build` is required for the P7 imports). Gate: redis-c healthy, gateway up, `:6393` loopback only. | `[OWNER]` |
| 6.3 | `/workspaces`. | Already created by §3 Gate 4; re-check `stat -fc %T /workspaces` → xfs and that the mount options contain `prjquota`. | no |
| 6.4 | Migrations. | `node packages/db/dist/migrate-cli.js "$DATABASE_URL"` (journal 0006/0007; the CLI applies every pending entry). Source the env first. | `[OWNER]` |
| 6.5 | Hibernate/hydrate smoke. | Restart the worker; `systemctl is-active ovid-worker`; confirm the `:8091` listener exists; journal shows no boot refusal. Then seed a file, hibernate, read the cold file, hydrate, checksum the tree, list artifacts. | `[OWNER]` |
| 6.6 | Confirm and make permanent. | `r2.live` green, `verify-r2.mjs` green again, `OVID_STORAGE_BACKEND=r2` in **both** files, owner log updated (bucket, token TTL, warm-GB choice, timestamp). | no (record only) |

**Step 4 value list.** Gateway: `OVID_STORAGE_BACKEND=r2`,
`OVID_R2_ACCOUNT_ID`, `OVID_R2_ACCESS_KEY_ID`, `OVID_R2_SECRET_ACCESS_KEY`,
`OVID_R2_BUCKET=ovid-cloud`, `OVID_INTERNAL_TOKEN`,
`OVID_WORKER_FILE_PORT=8091`,
`OVID_WORKER_INTERNAL_URL=http://host.docker.internal:8091`,
`REDIS_C_URL=redis://:<REDIS_C_PASSWORD>@redis-c:6379`,
`REDIS_C_PASSWORD`, `REDIS_C_HOST_PORT=6393`, `OVID_MAX_WARM_GB` (Q8),
`OVID_DISK_ALERT_PCT=80`. Worker: same shared values plus
`REDIS_C_URL=redis://:<REDIS_C_PASSWORD>@127.0.0.1:6393`,
`UV_THREADPOOL_SIZE=8`, `OVID_WORKER_FILE_PORT=8091`,
`OVID_HYDRATE_TIMEOUT_MS` (optional; default 60000).

**Inline-cap divergence (deliberate, P7 Task 12):** the gateway reads
`OVID_FILE_INLINE_MAX_BYTES`, the worker reads `OVID_INLINE_MAX_BYTES`. Keep
the **values** equal (default `1048576`), or the gateway may inline a file the
worker refuses to serve inline.

**Commands with known path/cwd issues:**

```bash
# Step 5 build. R2-PROVISIONING says `cd /opt/ovid-cloud/repo`; the pnpm
# workspace is cloud/, so this is [UNVERIFIED — wrong cwd; use .../repo/cloud].
cd /opt/ovid-cloud/repo/cloud
pnpm --filter @ovid/storage build

# Step 5 probe (from the repo root; the script path is repo-relative).
cd /opt/ovid-cloud/repo
set -a; . /opt/ovid-cloud/repo/cloud/deploy/.env; set +a   # canonical path per §4.0
node cloud/scripts/verify-r2.mjs

# Step 5 live suite.
cd /opt/ovid-cloud/repo/cloud
OVID_R2_ACCOUNT_ID=… OVID_R2_ACCESS_KEY_ID=… OVID_R2_SECRET_ACCESS_KEY=… \
OVID_R2_BUCKET=ovid-cloud \
pnpm --filter @ovid/storage exec vitest run src/r2.live.test.ts
```

R2-PROVISIONING step 2's `install -m 600 /dev/null` target is the canonical
gateway env `/opt/ovid-cloud/repo/cloud/deploy/.env` (§4.0). Do not create
`/opt/ovid-cloud/.env`.

**Rollback.** Worker: stop it, restore the previous `worker.env`, start it.
Compose: `docker compose stop redis-c` (the gateway falls back to
`REDIS_Q_URL` only when `REDIS_C_URL` is unset). Storage: once workspaces have
been hibernated, R2 is the authority — **do not** roll back to `fs` (the warm
dirs are gone).

The owner-gate checklist to paste into the approval thread is at the end of
`R2-PROVISIONING.md`; use it verbatim.

---

## 6. Staging bring-up + the 100-user run

Source: `cloud/apps/load/reports/load-100u-template.md` §3,
`cloud/scripts/staging.sh`, `cloud/deploy/docker-compose.staging.yml`.
The template's "blocked on Dockerfile.mint" status is **stale**:
`cloud/deploy/Dockerfile.mint` now exists and the staging compose builds it
(`dockerfile: deploy/Dockerfile.mint`). No executed 100-user evidence exists
yet.

**Run this only when the box is otherwise idle.** The run competes for the
same 8 cores as the live stack; starting it during concurrent work will starve
both. The template budgets a ~45-minute window (up → run → down). Q3 decides
whether this happens on this box (SM) or a second machine (2M).

Prerequisites: copy the staging templates to the git-ignored operator files
and keep them `600`:

- `cloud/deploy/.env.staging.example` → `cloud/deploy/.env.staging`
- `cloud/deploy/.env.staging.mint.example` → `cloud/deploy/.env.staging.mint`

The templates already contain staging-only literals (no `CHANGE_ME`);
`staging.sh guard` refuses production-valued or non-loopback values.

Exact sequence (same commands as the template; only the checkout root differs
— the template used `/root/OvidAI/cloud`):

```bash
cd /opt/ovid-cloud/repo/cloud

# Preflight: isolation guard, compose up (waits for mint boot re-sync and
# gateway health), mock LiteLLM on 0.0.0.0:14000, host staging worker.
bash scripts/staging.sh guard
bash scripts/staging.sh up
bash scripts/staging.sh mock-start
bash scripts/staging.sh worker-start --env OVID_RUN_STALE_MS=600000

# Live-stack baseline (read-only; StartedAt + health of the live stack).
bash scripts/staging.sh live-check --write-baseline /tmp/ovid-live-baseline.txt

# Dry validation: 10 users / 120 s against staging, SMOKE_THRESHOLDS.
node apps/load/dist/cli.js load \
  --profile smoke10 \
  --target staging \
  --thresholds smoke \
  --out /tmp/load-smoke10-$(date -u +%Y%m%d).md

# Full 100-user run (30 min + 5 min ramp). Operator observes only; do not
# touch the stack. `docker stats --no-stream` must show no restarts.
node apps/load/dist/cli.js load \
  --profile apps/load/profiles/full100.json \
  --target staging \
  --thresholds full \
  --out apps/load/reports/load-$(date -u +%Y%m%d)-100u.md \
  --json apps/load/reports/load-$(date -u +%Y%m%d)-100u.json

# Post-run live check: StartedAt must be unchanged vs the baseline.
bash scripts/staging.sh live-check --baseline /tmp/ovid-live-baseline.txt

# Teardown (keep the volume for forensics; -v only with owner OK).
bash scripts/staging.sh worker-stop graceful
bash scripts/staging.sh mock-stop
bash scripts/staging.sh down
```

| Row | Action | Gate | Owner |
|---|---|---|---|
| 6a | Bring staging up (`guard` + `up`) | `guard` exits 2 on any production value; `up` waits for mint boot re-sync + gateway health on 18082. | `[OWNER]` |
| 6b | Start mock LiteLLM (`mock-start`) | The one non-loopback bind (`0.0.0.0:14000`); keep 14000 closed externally. | `[OWNER]` |
| 6c | Start the host staging worker (`worker-start`) | Requires root for bwrap/cgroups; uses `/workspaces-staging`, uid base 220000, file-service port 18093. | `[OWNER]` |
| 6d | Run `smoke10` | No report is written for a failed dry; fix first. | `[OWNER]` |
| 6e | Run the full 100-user profile | Exits 0 only when every `FULL_THRESHOLDS` gate passes; commit the dated report, never edit a threshold to pass. | `[OWNER]` |
| 6f | Teardown (`worker-stop graceful` + `mock-stop` + `down`) | Keep named volumes unless the owner explicitly approves `-v`. | `[OWNER]` |

Facts the report must capture: `nproc`, `free -g`, `uname -r`, location
(SM/2M); the profile echo (100 users, 1,800,000 ms, 300,000 ms ramp, 90 s run
cadence, 4 browser users, 10 schedules, 60 s reconnect, spike at 900 s);
the `FULL_THRESHOLDS` table; positive-data gates; before/after `live-check`;
harness floor; anomalies (including `browser tier: NOT EXERCISED` — a loud
note, never a silent zero). The CLI is
`cloud/apps/load/dist/cli.js`; the report path is
`cloud/apps/load/reports/load-<YYYYMMDD>-100u.md`.

---

## 7. Wave-merger items — **ALL THREE ARE DONE** (nothing for you to run)

Source: `.superpowers/sdd/2026-10-16-ovid-cloud-p0-p1-spine/WAVE-MERGER.md`
(the binding checklist, now CLOSED).

These three were listed here as `[QUIET TREE]` work. All three landed on
2026-10-18 and are verified. **Do not redo them** — this section now exists only
so the reasoning is on record and so a stale copy of this doc cannot send you
down a path that is already finished.

| Item | Status | Proof |
|---|---|---|
| 7.1 Lockfile regeneration | **DONE** — commit `873d993` | A scratch copy carrying only the 19 manifests runs `pnpm install --frozen-lockfile --offline` → "Lockfile is up to date, resolution step is skipped", 380 packages, exit 0. |
| 7.2 Test-source typecheck debt | **DONE** — 174 → **0**; commits `6aba5c9`, `9c96acd`, `4c08119`, `ee3e211`, `1487667`, + the e2e/mint/worker batch | `pnpm -r --parallel exec tsc -p tsconfig.check.json --noEmit` → **exit 0**. CI now enforces it (commit `f71ed7a` switched the Typecheck step from `tsconfig.json` to `tsconfig.check.json`, so `*.test.ts` is gated). |
| 7.3 Duplicate SSRF classifier | **DONE** — commit `37aee77` | There were **FOUR** copies, not two (`agent-core/src/ssrf.ts`, `escrow/src/address.ts`, `mcp/src/ssrf.ts`, `browser/src/url.ts`). All now import `@ovid/shared`'s `netAddress.ts`. Differential test: 0 differences across 167,840 inputs. Adding a reserved prefix is now a one-file change. |

**What this means for §3.1 (Gate 0):** the "quiet tree + lockfile regeneration"
gate is already satisfied — skip straight to the bwrap probe.

### 7.4 The one genuinely unproven deploy step

**A real `docker compose build` has never been run.** The static audit
(`cloud/deploy/DOCKERFILE-AUDIT.md`) proves both runtime import maps are
complete — every `@ovid/*` package imported at runtime has both its
`package.json` and its `dist` COPY — and the `node-pty` toolchain gap in both
BUILD stages is fixed (commit `45c7033`). With the lockfile now valid, the
build should succeed. It is still **unverified**, and it is the first thing
that will fail if anything is wrong.

```bash
cd /opt/ovid-cloud/repo/cloud
docker compose -f deploy/docker-compose.yml build gateway mint
```

Expect a few minutes (native `node-pty` compile). If it fails, the error names
the missing COPY or the missing importer — the audit tells you which one it
would be.

---

## 8. Post-launch / monitoring

Source: [`MONITORING.md`](./monitoring/MONITORING.md),
`BROWSERS.md` §(c), `RUNBOOKS.md` I-3/I-9, `ROLLOUT.md` R5/R7.

### 8.1 Bench re-baseline (P6 final-review item)

The dev-box run recorded **1376 MB peak for the chromium tree only** (4 live
contexts on `/big`, 60 s scroll; excludes the Lightpanda pool and tier-1
fallbacks). That is above the 1300 MB alarm, so the bench's verdict was
`REGRESSION — investigate before activation`. Add the Lightpanda pool
(100–400 MB) and up to two tier-1 fallbacks (≤100 MB each): the real
worst-case headroom against the 2048 MB hard pool ceiling is **~272–572 MB**,
not the bare 672 MB arithmetic. At the component level the measured tree is a
**~2× miss**, not ~6%. The owner re-runs it **on this box** at activation and
treats a peak > 1300 MB as an investigate-first gate; never raise the
threshold to make a run pass.

```bash
cd /opt/ovid-cloud/repo
node cloud/scripts/browser-memory-bench.mjs
# exits 0 under 1300 MB, 1 over the alarm, 2 if chromium is missing, 3 error
```

Run on an otherwise-idle box (CPU contention pollutes the measurement; the
process-tree RSS is isolated from concurrent test chromium). Known levers:
`MAX_LIVE_BROWSERS` 4→3 (drops roughly one worst-case context) and/or a
lighter fixture if the owner judges `/big` unrepresentative. Paste the ladder
and peak into `BROWSERS.md` §(c).

| Row | Action | Gate | Owner |
|---|---|---|---|
| 8a | Re-run the memory bench after Chromium install | Exit 0; if peak > 1300 MB, investigate before activation. | `[OWNER]` |

### 8.2 Alert thresholds and the two monitoring layers

`@ovid/watch` runs every 60 s on the box and alerts through mint's Telegram
bot (plus an optional webhook). UptimeRobot is the external whole-box layer; a
same-box watcher cannot report a dead box. Keep both.

| Check | Meaning | Threshold (env) |
|---|---|---|
| `gateway-health` | `GET /cloud/v1/health` returns `{"status":"ok"}` | must be ok (`GATEWAY_HEALTH_URL`) |
| `queue-depth` | BullMQ waiting jobs per queue | `> 50` (`WATCH_QUEUE_WAITING`) |
| `worker-lag` | age of the oldest waiting job | `> 300 s` (`WATCH_WORKER_LAG_S`) |
| `disk-80` | filesystem used % at `WATCH_DISK_PATH` | `> 80 %` (`WATCH_DISK_PCT`) |
| `redis-mem-80` | `used_memory / maxmemory` from `INFO memory` | `> 80 %` (`WATCH_REDIS_MEM_PCT`) |
| `spend-parity` | daily drift between the TS-mint ledger (`pool:{uid}:spend` in redis db2) and LiteLLM `LiteLLM_SpendLogs` | `> max(100 ¢, 2 %)` (`WATCH_SPEND_DRIFT_CENTS`, `WATCH_SPEND_DRIFT_PCT`) |

Alerts are edge-triggered: unknown/ok→fail alerts immediately; fail→fail is
silent until `WATCH_REPEAT_AFTER_S` (default 1800 s); fail→ok sends one
recovery. A silent monitor is a failed gate.

| Row | Action | Gate | Owner |
|---|---|---|---|
| 8b | Install `@ovid/watch` and run the real-sink self-test | Follow `MONITORING.md` exactly. Fill `watch.env` including `ALERT_TELEGRAM_BOT_TOKEN`, `ALERT_TELEGRAM_CHAT_ID`, `WATCH_LITELLM_DATABASE_URL` (read-only LiteLLM DB, host `127.0.0.1:5434`, db `litellm`), `REDIS_MINT_URL` (db2), `REDIS_Q_URL` (6391), `WATCH_QUEUE_PREFIX=bull`. `--self-test` sends one real alert; the owner confirms receipt. | `[OWNER]` |
| 8c | Add UptimeRobot monitor 2 | `https://api.ovidsi.com/cloud/v1/health`, HTTP(s), 5 min, name `ovid-cloud-health`; confirm both monitors UP. Monitor 1 (`/healthz`) is installed under R0 item F (an owner action); add monitor 2 here. | `[OWNER]` |

`WATCH_LITELLM_DATABASE_URL` needs a **read-only** LiteLLM DB credential. The
template's `readonly` role must exist, or supply an existing read-only
credential; never point the watcher at the live superuser. If either ledger
seam is missing while `WATCH_SPEND_PARITY=on`, the check fails loudly — that is
intentional (a blind money check is worse than a noisy one).

Install commands (from `MONITORING.md`; run only with owner approval because
step 3 sends a real alert):

```bash
sudo install -d -m 755 /var/lib/ovid-cloud-watch
sudo cp /opt/ovid-cloud/repo/cloud/deploy/monitoring/watch.env.example /opt/ovid-cloud/watch.env
sudo $EDITOR /opt/ovid-cloud/watch.env
sudo chmod 600 /opt/ovid-cloud/watch.env
sudo cp /opt/ovid-cloud/repo/cloud/deploy/monitoring/ovid-cloud-watch.service \
        /opt/ovid-cloud/repo/cloud/deploy/monitoring/ovid-cloud-watch.timer \
        /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ovid-cloud-watch.timer
sudo /usr/bin/node /opt/ovid-cloud/repo/cloud/apps/watch/dist/main.js --self-test
systemctl list-timers ovid-cloud-watch.timer        # NEXT <= 60 s
journalctl -u ovid-cloud-watch.service -n 20 --no-pager
# expected: "[watch] pass: 6 checks, 0 alerts, 0 recoveries"
```

### 8.3 Event-log retention divergence

The shipped retention is **exact `MAXLEN 10000` events** per session stream
(`DEFAULT_MAX_LEN = 10_000` in `cloud/packages/events/src/eventLog.ts`),
deliberately **not** `MAXLEN ~`. The spec (§6.2) says "24 h / 50 MB"; the code
is the authority (`RUNBOOKS.md` §0.2). Do not silently "fix" one to match the
other: the trim is exact and the queue Redis is `maxmemory 1400mb` +
`noeviction`, so changing retention changes memory pressure.

**This is an open owner decision, not a settled fact.** The spec and the code
disagree, and only you can pick which is the product requirement:

| Option | What it means | Consequence |
|---|---|---|
| **A. Accept the shipped value** | `MAXLEN 10000` is the contract; amend spec §6.2 to match | Cheapest. But a heavy session (many tool calls, long runs) can exceed 10 000 events, so an early part of a transcript is silently unavailable to replay. Check whether P8's transcript projection or P9's audit needs deep history. |
| **B. Implement the spec** | Change `DEFAULT_MAX_LEN` to a 24 h / 50 MB policy | Needs a size- or age-based trim (not a fixed count) and a re-derived redis-q memory budget: at 50 MB × concurrent sessions the 1400 MB `noeviction` ceiling is the binding constraint. |
| **C. Defer** | Ship A, revisit after the 100-user run produces real per-session event counts | Reasonable if the load run will answer it empirically. |

`Answer: ______` (A / B / C — and if B, the memory budget owner)

Manual trim (only if a stream family is at the memory ceiling; this mutates
live data and must use the shipped retention):

```bash
docker exec ovid-cloud-redis-q-1 sh -c '
  redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" --scan --pattern "sess:*:events" |
  while read -r k; do
    redis-cli --no-auth-warning -a "$REDIS_Q_PASSWORD" XTRIM "$k" MAXLEN 10000 >/dev/null
  done'
```

| Row | Action | Gate | Owner |
|---|---|---|---|
| 8d | Trim session streams to the shipped `MAXLEN 10000` | Only under `redis-mem-80` pressure; investigate the leak first; never change `noeviction`. | `[OWNER]` |

### 8.4 R5 abort criteria and R7 acceptance

R5 halts on any one of: crash rate above the Q2 threshold; `run_failed` rate
**> 1 % of runs** over a rolling window; `queue-depth` or `worker-lag` alerts
for **> 2 consecutive watch windows**; any `lostEvents > 0` or security/privacy
regression. Do not advance a staged rollout with an open abort signal.

R7 final acceptance (verification, not a live-stack mutation: the full run
brings the staging composition up and tears it down; run after R6, or before
R5 as a pre-submission gate and repeat at R7):

```bash
cd /opt/ovid-cloud/repo
bash cloud/scripts/acceptance.sh
```

Gate: all gates PASS, evidence written and committed to
`cloud/apps/load/reports/RELEASE-EVIDENCE-<YYYYMMDD>.md`; fill the
`HARDENING.md` decision log (A/B/C/E/G), the `MONITORING.md` verification log,
the `RUNBOOKS.md` drill lines actually run, and confirm `KEY-ROTATION.md`'s
drill evidence is current. A failed gate stops the release — do not weaken a
gate to green.

| Row | Action | Gate | Owner |
|---|---|---|---|
| 8e | Run the full acceptance script and commit the evidence | `cloud/scripts/acceptance.sh` exits 0; evidence file exists; logs signed. | `[OWNER]` |

### 8.5 Recurring after launch

- Monthly: HARDENING H3 nft counter review, H6 `/workspaces` budget, H7 rootfs
  rebuild cadence.
- Quarterly: backup/restore drill (`RUNBOOKS.md` O-1).
- On schedule: key rotation (`RUNBOOKS.md` I-13, `KEY-ROTATION.md`), LiteLLM
  digest pin/upgrade (`RUNBOOKS.md` O-4), dependency updates (`O-2`).

---

## 9. What is ALREADY done and needs no owner action

Do not redo these. They are artifacts/code, verified on disk or recorded as
complete in the cited review.

- **All cloud deploy artifacts are written and present on disk.** Compose
  (`docker-compose.yml`, `docker-compose.staging.yml`), Dockerfiles
  (`Dockerfile.gateway`, `Dockerfile.mint`), systemd units
  (`ovid-sandboxes.slice`, `ovid-worker.service`), nft renderer/installer
  (`net/install-nft.sh`, `renderNftCli.js`, golden), workspaces script
  (`workspaces/setup-workspaces.sh`), rootfs pipeline
  (`rootfs/{build,install,smoke-jail}.sh`, `versions.env`), backup
  (`backup/pg_backup.sh`, `README.md`), monitoring units, `staging.sh`,
  `acceptance.sh`, `verify-r2.mjs`, `browser-memory-bench.mjs`, and the load
  CLI/profile. Each path was checked with `test -f`.
  **All of them are now tracked in git** — `Dockerfile.mint`,
  `DECOMMISSION.md`, `caddy-flips/` and `docker-compose.staging.yml` were
  committed by P9-T18 and the wave-merger. Before activation, just confirm the
  release tree is clean (`git status`) rather than hunting for untracked deploy
  files.
- **Rootfs revision r2 is already built.** `cloud/deploy/rootfs/dist/`
  contains `ubuntu-noble-min-20261017-r2.tar.zst` (plus manifest and
  SHA256SUMS) and the r1 predecessor. `DEPLOY.md` §11 step 2 says a fresh
  `build.sh` is optional; install it (Gate 3), do not rebuild it.
- **P2 final review is READY**, 16/16 tasks review-gated, zero fix-now code
  items. Its three carry items are landed/routed: the XFS EDQUOT row (commit
  `1d076bd`, now `DEPLOY.md` §11 step 3), the PTY offset-reassembly contract
  (routed to P8-T15), and the rootmap-stub warning (3.2 above).
- **P6 final review is READY** after fix commit `e553356`; the only remaining
  P6 item is the lockfile importer edge, routed to the wave-merger (§7.1).
  The egress defaults now include CGNAT and the seven IPv6 ranges; the
  duplicate-classifier and browser-uid items are wave-merger/owner items, not
  P6 code defects.
- **P10's artifacts and task-level reviews are landed** (not a claim that the
  final acceptance has run): the staging composition, one-command acceptance
  script, runbooks, and the capacity convergence (`slice 10G`,
  `worker 4096M`, `MAX_WARM_GB=8`, `MAX_ACTIVE_SANDBOXES=24`,
  `MAX_TIER1_PROCESSES=8`). The R7 acceptance execution and its evidence file
  remain owner gates (8.4).
- **HARDENING item D (Caddy `trusted_proxies`) is already live and verified**
  identical to Cloudflare's list. Re-verify only; do not re-add it.
- **Compose stack limits/healthchecks and the Redis split are done**:
  gateway 1g/1cpu, redis-q 1536m + `noeviction` + AOF, redis-c 384m +
  `allkeys-lru`, net proxies 128m/0.5cpu, loopback-only publications, compose
  healthchecks. Do not re-do these in the activation window.
- **The env-example duplicate `OVID_MAX_WARM_GB` is fixed** (commit `0bc12a4`):
  all four templates have zero duplicate keys and source cleanly.
- **The `@ovid/load` typecheck debt is fixed** (commit `bad63b4`), and the
  workspace-wide test-source debt is now **0** too (§7.2): CI gates
  `tsconfig.check.json`, so `*.test.ts` cannot drift again.
- **P9 decommission artifacts now exist on disk**:
  `cloud/deploy/DECOMMISSION.md` and `cloud/deploy/caddy-flips/` (verified).
  They are written, not executed; execution stays owner-gated.
- **The Firebase Admin credentials file already exists** at
  `/opt/ovid-gateway/firebase-admin.json`; the mount-vs-copy decision is
  documented in `DEPLOY.md` §3. Do not create a second copy unless you choose
  the copy variant.
- **The live stack is healthy** (`https://api.ovidsi.com/healthz` → 200 per
  `HARDENING.md`/`RUNBOOKS.md`). Re-check read-only; do not mutate it.

**Still not done (the actual owner work):** the Q1/Q2/Q3/Q6/Q7/Q8 answers; the
remaining secrets in §4 (`OVID_MASTER_KEY`, `OVID_INTERNAL_TOKEN`,
`REDIS_C_PASSWORD`, …); the bwrap probe; P2 activation Gates 3–11; the browser
installs and egress-uid resolution; staging + the 100-user run; monitoring
install; R0 items A/B/C/E/F/G; R4 store paperwork; R5 submissions; R6
decommission; R7 evidence.

**Done since this list was written:** lockfile regeneration (§7.1) and
**R2 provisioning (§5 steps 1–3, 5)** — bucket, scoped token, lifecycle rule,
and a real-bucket verification (7/7 probe + 10/10 live suite) all completed
2026-10-18.

---

## Appendix — source map

| Section | Primary sources |
|---|---|
| Read me / facts | `DEPLOY.md` §0, `RUNBOOKS.md` §0, `HARDENING.md` current state |
| Product decisions | `ROLLOUT.md` §0, `docs/superpowers/HANDOFF-ovid-cloud-resume.md`, P9 plan Conditional A, P7 plan Task 10 |
| Infrastructure gates | `DEPLOY.md` §11, `HARDENING.md` A–H, `BROWSERS.md` §(b)–(d), `sandbox/MECHANISM.md` |
| Secrets | `.env.example`, `worker.env.example`, `RUNBOOKS.md` I-13, `KEY-ROTATION.md`, `HARDENING.md` C |
| R2 | `R2-PROVISIONING.md`, `.env.example` Storage block, `worker.env.example` Storage block |
| Staging / 100u | `cloud/apps/load/reports/load-100u-template.md`, `cloud/scripts/staging.sh`, `docker-compose.staging.yml` |
| Wave merger | `.superpowers/sdd/2026-10-16-ovid-cloud-p0-p1-spine/WAVE-MERGER.md` (and the 2026-10-15 copy's status block) |
| Post-launch | `monitoring/MONITORING.md`, `BROWSERS.md` §(c), `RUNBOOKS.md` I-3/I-9/O-1–O-5, `ROLLOUT.md` R5/R7 |
| Already done | P2/P6 final reviews, `progress.md`, commits `1d076bd`/`0bc12a4`/`bad63b4`, on-disk artifact checks |
