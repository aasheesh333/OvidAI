# Ovid Cloud — conditional rollout plan (R0–R7)

**Status: NOT EXECUTED.** This file is the owner's cutover script. It was
written and dry-validated (artifact existence + `bash -n` only) on 2026-10-17.
No Caddy change, compose command, container stop, or store action was run
while producing it.

**Execution rule.** Every step below is **owner-present, per-step go/no-go** —
the same shape as P1 Task 11 Step 6. An agent may run the read-only
verification commands; an agent may **not** execute a rollout step. A step is
executed only after the owner answers the three gates in §0, signs the
decision log, and says "go" for that step. Stop immediately on a failed gate
and follow that section's rollback.

**What "conditional" means.** Q1, Q2 and Q3 are owner decisions, not
assumptions. Every downstream section is written as branches. The answer rows
in §0 are deliberately empty; nothing in this file preselects a branch.

---

## 0. Owner decision gates — fill these in before anything else

The rollout is blocked until **all three** gates have a dated owner answer and
the decision log at the end of this section is signed. The answers drive R5
and R6; R0–R4 are branch-independent.

### Q1 — clean break (CB) vs installed base (IB)

| Branch | What it means | What must be true before R5 |
|---|---|---|
| **CB — clean break** | Forced update from day one: the thin client is the only supported client. Old installed builds are cut off by a **gateway min-app-version gate** plus a store listing that says "required update". No dual-stack window; the Python routes can be decommissioned on the R6 schedule. | The server-driven min-version gate is **not shipped as of 2026-10-17** (P8 Task 20 prepares the hook, it does not enable it). CB is **not executable** until that gate lands, is tested against an old build, and the owner confirms the forced-update listing copy. Until then, choose IB or defer. |
| **IB — installed base** | Dual-stack window: Python routes stay live, `/cloud/*` is additive, and old builds keep working (spec §13.2). A forced-update wave runs at **T + `[owner: ___ weeks]`**; after it completes, R6 proceeds. IB adds a **compat-matrix test row** to the acceptance run (old-build routes still healthy while both stacks are live). | The compat-matrix row must be added to `cloud/scripts/acceptance.sh` (or run as a documented manual gate) **before** R5-IB starts. It is not in the landed script today. |

**Owner answer (fill in — do not pre-fill):**

| Gate | Answer | Forced-update wave (IB only) | Date | Initials |
|---|---|---|---|---|
| Q1 | ☐ CB ☐ IB ☐ defer | T + ______ weeks | | |

### Q2 — launch point / Play deadline

Locked mechanics (not owner choices):

1. Internal track first, then closed track, then **production staged rollout
   `10% → 50% → 100%`**, with a **48 h soak at each step** (10% for 48 h,
   then 50% for 48 h, then 100%).
2. **R4 (spec R6: Play Data Safety form + privacy policy) is a hard gate
   BEFORE the first store submission.** The submission step is blocked until
   R4 is dated and signed.
3. Abort criteria are in R5 (crash rate, `run_failed` rate, alert windows).

Owner inputs (all blank):

| Input | Owner answer |
|---|---|
| Internal-track duration | ______ |
| Closed-track size (testers) | ______ |
| Production submission date (first 10%) | ______ |
| Play deadline (hard date, if any) | ______ |
| Crash-rate abort threshold | ______ % |

**Owner answer row (fill in):**

| Gate | Launch point | Play deadline | Date | Initials |
|---|---|---|---|---|
| Q2 | | | | |

### Q3 — staging story

| Branch | What it means | Evidence / extra work |
|---|---|---|
| **SM — same machine** | Staging runs on this VPS on the loopback-only ports (`gateway 127.0.0.1:18082`, Postgres 15432, redis-q 16379, mint 18091/18092), with maintenance windows. This is what Tasks 1–12 actually used. | Evidence: `cloud/scripts/staging.sh`, `cloud/deploy/docker-compose.staging.yml`, and the Task 1/4/6/7 reports (`.superpowers/sdd/2026-10-16-ovid-cloud-p10-hardening-cutover/`). Live-unaffected checks (`staging.sh live-check`) are the guard. |
| **2M — second machine** | Staging moves to a second host. The compose file is location-transparent; only `.env.staging` URLs and the nftables uid-range install change. | Before trusting it: run the Task 5 smoke (`load --profile smoke10`) and the Task 6 chaos `all` scenario set **once on the second machine**; record the reports. No production Caddy/DNS change either way. |

**Owner answer (fill in — do not pre-fill):**

| Gate | Answer | Second machine (if 2M) | Date | Initials |
|---|---|---|---|---|
| Q3 | ☐ SM ☐ 2M | host: ______ | | |

### Decision log (signature blocks the rollout)

| Date | Gate | Answer | Signed by |
|---|---|---|---|
| | Q1 | | |
| | Q2 | | |
| | Q3 | | |
| | R0 blocking state confirmed | | |

**Owner signature:** ______________________________  **Date:** ______________

> No rollout step executes until this line is dated and signed. This is the
> same decision-log shape as `HARDENING.md` §"Decision log".

---

## R0 — Hardening gate

**Entry criteria.** §0 signed. Repo at `/opt/ovid-cloud/repo`; owner has read
`cloud/deploy/HARDENING.md`. The box will host untrusted user sandboxes, so
the Phase-0 items are blocking, not advisory (spec R3/R5).

**Steps.** Execute the items exactly as written in `HARDENING.md` — this file
does not duplicate their commands.

- [ ] **A — disable novnc + vncserver@1 + vsftpd** (`[OWNER]`). Removes the
      internet-exposed **root** desktop and the plaintext FTP path.
- [ ] **B — SSH key-only** (`[OWNER]`), after proving a key login from every
      owner device. Confirms effective `sshd -T` values (the cloud-init
      drop-in currently forces password auth on).
- [ ] **C — secret rotation** (`[OWNER]`). Firebase service-account key,
      Android signing keystore/Play App Signing, and any other credential
      exposed while the repo was public. **C runs last in R0** because
      rotation is not cleanly reversible.
- [ ] **D — Caddy `trusted_proxies`** — **already done** (verified
      2026-10-16; `HARDENING.md` decision log). Re-verify only.
- [ ] **E — Docker log rotation** (`[OWNER]`). `/etc/docker/daemon.json`
      with `max-size=50m`, `max-file=3`; restart docker in the window.
- [ ] **F — external uptime alerting installed** (`[OWNER]`).
      UptimeRobot monitor 1 (`/healthz`) now; monitor 2
      (`/cloud/v1/health`) at R2. On-box `@ovid/watch` install is R2.
- [ ] **G — pin `litellm:main-latest` to the running digest** (`[OWNER]`),
      batched with E (both briefly interrupt LiteLLM/docker).

Read-only verification (safe; run before and after the items):

```bash
systemctl is-enabled novnc vncserver@1 vsftpd
ss -tlnp | grep -E ':(21|5901|6080)\b' || echo "no exposed VNC/FTP listeners"
sudo sshd -T | grep -Ei 'passwordauthentication|kbdinteractiveauthentication|permitrootlogin'
sudo ufw status numbered
cat /etc/docker/daemon.json
docker inspect ovid-gateway-litellm-1 --format '{{.Config.Image}}'
curl -sS -o /dev/null -w '%{http_code}\n' https://api.ovidsi.com/healthz
```

**Time budget.** One maintenance window, ~1 hour (E + G cause brief
LiteLLM/docker downtime; A + B are minutes; C is owner-scheduled and can
extend the window).

**Rollback.** Per `HARDENING.md`: A = re-enable/start the units and re-add the
ufw rules; B = restore the drop-in (keep a key path open until verified);
C = **forward-only** — restore from the password manager only if a new secret
was recorded wrongly; E = remove `daemon.json` and restart docker; G = restore
`docker-compose.yml.bak-pin-<TS>` and `docker compose up -d litellm`.

**Decision point.** All six boxes checked and their verification lines
recorded in `HARDENING.md` → proceed to R1. **If A or B is unchecked, STOP:**
do not route user traffic to a box with a root desktop or password SSH open.

---

## R1 — Cloud-stack activation

**Entry criteria.** R0 signed. `cloud/deploy/.env` authored from
`.env.example` with real secrets; `/opt/ovid-cloud/repo` checked out at the
release commit. This section applies **only if the stack was not already
activated in an earlier phase**.

**Steps.** Follow `DEPLOY.md` §§1–9 in order, gates included:

1. §1 layout/prerequisites; §2 `.env` (secrets — never commit); §3 Firebase
   credentials; §4 database provisioning (idempotent `./provision.sh`).
2. §5 start the compose spine; gate:
   `curl -sS http://127.0.0.1:8082/cloud/v1/health` →
   `{"status":"ok","checks":{"db":true,"redisQ":true}}`.
3. §6 route `https://api.ovidsi.com/cloud/*` — **the only live-stack change
   in R1** (`[OWNER]`): timestamped Caddy backup → insert the
   `caddy-snippet.conf` `handle /cloud/*` block → `caddy validate` →
   `caddy reload` → health through the public route.
4. §7 functional smoke (real app build); §8 nightly backups; §9 verification
   checklist.

```bash
cd /opt/ovid-cloud/repo/cloud/deploy
./provision.sh
docker compose up -d
curl -sS http://127.0.0.1:8082/cloud/v1/health
curl -sS https://api.ovidsi.com/cloud/v1/health
```

**Prerequisite outside this budget.** `DEPLOY.md` §11 (P2 sandbox worker:
host systemd unit, `/workspaces`, nftables egress, rootfs) and §12 (P7 R2 /
redis-c / warm LRU) are separately owner-run. Agent runs need the P2 worker;
complete §11 before R3. It is not part of R1's 2-hour budget.

**Time budget.** 2 hours.

**Rollback.** `DEPLOY.md` §10 decommission: restore the Caddy backup and
reload (§6 rollback), `docker compose down` **without `-v`** (retains queue
data), reverse §11 (worker unit, nft table, `/workspaces`, rootfs), disable
the backup timer if it was just installed. The `ovid_cloud` DB/role may stay
dormant.

**Decision point.** DEPLOY §9 checklist all green, public health 200, and the
live stack (`/v1/models`, `/healthz`) unchanged → proceed to R2. Any failed
gate → rollback and stop.

---

## R2 — Monitoring live

**Entry criteria.** R1 green (cloud health reachable through the public
route). Telegram bot token/chat id known from mint's env. Owner present.

**Steps** (`[OWNER]` — installs systemd units and sends one real alert):

1. Install `@ovid/watch` exactly per
   `cloud/deploy/monitoring/MONITORING.md` (state dir, `watch.env`, units,
   `systemctl enable --now ovid-cloud-watch.timer`).
2. Run the real-sink self-test and have the owner confirm receipt in Telegram:
   `sudo /usr/bin/node /opt/ovid-cloud/repo/cloud/apps/watch/dist/main.js --self-test`.
3. Add UptimeRobot **monitor 2** — `https://api.ovidsi.com/cloud/v1/health`
   (`HARDENING.md` item F, step 3) and confirm both monitors are UP.
4. Record the verification block in `MONITORING.md` §Verification log.

```bash
systemctl list-timers ovid-cloud-watch.timer          # NEXT <= 60 s
journalctl -u ovid-cloud-watch.service -n 20 --no-pager
# expected: "[watch] pass: 6 checks, 0 alerts, 0 recoveries"
```

**Time budget.** 30 minutes.

**Rollback.** `sudo systemctl disable --now ovid-cloud-watch.timer`
(`[OWNER]`); the state file and units may stay installed. Delete UptimeRobot
monitor 2 if it was added. No user-facing impact.

**Decision point.** Owner confirms the Telegram self-test and both monitors
UP → proceed to R3. A silent monitor is a failed gate; do not proceed on
"journal looked fine".

---

## R3 — Thin-client internal track

**Entry criteria.** R1 + R2 green; R0 signed; P8 thin-client build available;
§0 answered. No Caddy change is made in R3.

**Steps.**

1. Bring the staging composition up on the loopback ports and confirm it is
   isolated (`staging.sh guard` refuses production values):

   ```bash
   bash cloud/scripts/staging.sh guard
   bash cloud/scripts/staging.sh up
   bash cloud/scripts/staging.sh mock-start
   bash cloud/scripts/staging.sh worker-start
   curl -sf http://127.0.0.1:18082/cloud/v1/health
   ```

2. Point an internal device at the staging gateway **without touching Caddy**.
   Use an SSH tunnel on the workstation plus `adb reverse` for a physical
   device (emulator: `10.0.2.2` instead):

   ```bash
   ssh -N -L 18082:127.0.0.1:18082 root@STAGING_HOST    # replace STAGING_HOST
   adb reverse tcp:18082 tcp:18082
   curl -sf http://127.0.0.1:18082/cloud/v1/health
   ```

3. Build and distribute to internal testers:

   ```bash
   flutter build apk --debug \
     --dart-define=OVID_CLOUD_REST_BASE=http://127.0.0.1:18082/cloud/v1 \
     --dart-define=OVID_CLOUD_WS_URL=ws://127.0.0.1:18082/cloud/ws
   ```

4. Soak for **1 week** across the internal group: chat streaming, reconnect/
   replay, Studio, terminal, schedules, browser attach, push. Keep R2 alerts
   live and watch the load/chaos reports.

**Time budget.** 1 week soak (plus setup, ~1 hour).

**Abort criteria.** Any `lostEvents > 0` from the load harness, **or** any
health-degraded incident lasting **> 5 minutes** (`gateway-health` /
`queue-depth` / `worker-lag` alert), stops the track. Re-run the failed
workload after the fix; do not "soak through" a data-loss event.

**Rollback.** Stop distributing the internal build and tear staging down
(`staging.sh worker-stop graceful && staging.sh mock-stop && staging.sh down`).
No production change to revert. Under IB, old installed builds are unaffected;
under CB there is no old-build fallback, so a CB abort returns to R3 planning.

**Decision point.** One clean week + Q2 answered → proceed to R4.

---

## R4 — R6 privacy gate (hard gate before any store submission)

**Entry criteria.** R3 clean. Owner available for policy review.

**Steps** (`[OWNER]`; documentation/store-console only — no server change):

- [ ] **Play Data Safety form** updated for the thin client: data now
      processed on Ovid infrastructure (chat content, files, browser state,
      schedules, billing identifiers), retention/deletion behaviour, and
      encryption in transit/at rest.
- [ ] **Privacy policy** updated to match the Data Safety answers and the
      account-deletion lifecycle.
- [ ] **Store listing copy** reviewed: it must not mention an on-device
      terminal/Linux (Play policy; see `lib/core/distribution.dart` and the
      P8 plan's global constraints).
- [ ] Owner review recorded in the decision log below.

**Time budget.** Owner-scheduled; ~1 day of review (no server window).

**Rollback.** Documentation-only: revert the policy/listing text before
submission. After submission, a correction is a new store-console revision.

**Decision point.** **This section must be dated and signed before R5's first
submission.** If any box is unchecked, R5 does not start — regardless of Q2's
deadline. This is spec R6 and it is deliberately not negotiable.

| Date | Item | Reviewer | Result |
|---|---|---|---|
| | Data Safety | | |
| | Privacy policy | | |
| | Listing copy | | |

**Owner signature:** ______________________________  **Date:** ______________

---

## R5 — Store rollout (per Q2; enforcement per Q1)

**Entry criteria.** R4 signed; §0 answered; R3 soak clean; release commit
built from the same commit as the staging smoke; `ACCEPTANCE_REQUIRE_FULL_SECURITY=1`
run green (R7 may be run before R5 as a pre-submission gate, then repeated at
R7).

**Steps.**

1. **Internal track** for the Q2 duration; keep the R3 observability.
2. **Closed track** of the Q2 size; same soak discipline.
3. **Production staged rollout: 10% → 50% → 100%**, **48 h soak per step**.
   Do not advance a step with an open abort signal.
4. **Q1 enforcement:**
   - **CB:** publish the "required update" listing and enable the
     min-version gate. As of 2026-10-17 the gate is **not shipped** (P8
     Task 20 prepares the hook only). CB cannot start until it exists and has
     been proven to reject an old build; a listing-only "required update" is
     not enforcement.
   - **IB:** keep the Python routes live and `/cloud/*` additive; run the
     forced-update wave at T + the Q1 interval; add the compat-matrix row to
     acceptance before the wave.

**Abort criteria (any one halts the staged rollout):**

- Crash rate above the Q2 threshold.
- `run_failed` rate **> 1% of runs** over a rolling window.
- `queue-depth` or `worker-lag` alerts firing for **> 2 consecutive watch
  windows** (i.e. not a single transient edge).
- Any data-loss signal (`lostEvents > 0`) or a security/privacy regression.

**Time budget.** Q2-dependent; the minimum is internal + closed + three 48 h
soaks (6 days) after R4.

**Rollback.** Halt the staged rollout in Play Console (set the new release to
0% and resume the previous release). Server routes are additive through R5,
so the previous app build keeps working under IB. Under CB, halt the rollout
and publish a fixed build; do not decommission anything until R6's own gate.

**Decision point.** 100% for 48 h with no abort signal → proceed to R6.

---

## R6 — Python decommission (per P9)

**Entry criteria.** R5 at 100% and stable for 48 h; Q1 answered (CB: forced
update proven; IB: forced-update wave complete); P9's decommission runbook is
landed and reviewed.

**The runbook is P9's, not this file's.** P9 Task 18 produces
`cloud/deploy/DECOMMISSION.md` and `cloud/deploy/caddy-flips/` (plus the
conditional migration scripts under `cloud/scripts/migrate/`). **Those paths
do not exist on disk as of 2026-10-17** (checked). Until they land, this
section is a schedule and a rollback contract only — do not improvise the
flips from this file. Source of truth for the procedure:
`docs/superpowers/plans/2026-10-16-ovid-cloud-p9-money-accounts.md` Task 18
and spec §13.4.

**Order (spec §13.4, least money-critical first; mint + images last):**

1. `account-dev` (account routes, shares, reports; the P9 runbook also
   deletes `/sync/v1/*` + `/chat*` **only when Q1=CB and old builds are
   force-updated**, or leaves them until the forced-update wave under IB).
2. shares.
3. reports.
4. collab — **n/a** in the landed P9 design (never deployed; no container to
   stop).
5. billing.
6. images.
7. mint **last**.

**Per-service pattern (execute from `DECOMMISSION.md`, not here):**

1. Timestamped Caddyfile backup
   (`/opt/ovid-gateway/caddy`, `Caddyfile.bak-$(date -u +%Y%m%dT%H%M%SZ)`).
2. Flip **one** route group to the TS surface.
3. `caddy validate` → `caddy reload` (container binary, per `DEPLOY.md` §6).
4. Smoke the flipped routes; then **observe 72 h**.
5. Only after a clean observation: remove that Python container.

All of the above is `[OWNER]` (live traffic + container stops).

**Time budget.** 72 h observation per service; six active groups ≈ 18 days
minimum. Do not compress a soak to hit a date.

**Rollback (per service).** Restore the timestamped Caddy backup → validate →
reload → `docker compose up -d <service>` in `/opt/ovid-gateway` (P9's exact
rollback; the containers are only removed after the soak, so the image/config
is still present). Re-run the service's smoke before resuming the schedule.

**Decision point.** Each service's smoke + 72 h observation clean → next
service. Any regression → roll back that service, pause the schedule, and do
not touch the next group.

---

## R7 — Final acceptance + release evidence

**Entry criteria.** R6 complete (or, under IB, the forced-update wave complete
and the Python routes already dark). Production-shaped configuration in
place: production env values, release commit, staging composition isolated
from live traffic.

**Steps.**

1. Run the one-command acceptance gate against the production-shaped config:

   ```bash
   bash cloud/scripts/acceptance.sh
   ```

   Gate ordering is load-bearing (staging up before the full security suite);
   `staging.sh guard` refuses production values, so "production-shaped" means
   the production release commit and env shape on the staging ports — never
   the live compose project.

2. Confirm the run wrote and commit the evidence file:
   `cloud/apps/load/reports/RELEASE-EVIDENCE-<YYYYMMDD>.md` (produced by
   execution; the directory does not exist yet).
3. Fill the `HARDENING.md` §"Decision log" rows for A/B/C/E/G and the
   `MONITORING.md` verification log.
4. Fill the `RUNBOOKS.md` verification lines for the drills actually run
   (backup restore, dependency update, rootfs pin, LiteLLM pin) and confirm
   `KEY-ROTATION.md`'s drill evidence is current.
5. Sign the release record below.

**Time budget.** 1–2 hours (plus any failure triage).

**Rollback.** None — R7 is read-only verification. A failed gate stops the
release; do not weaken a gate to green (Task 14's rule).

**Decision point.** All gates PASS, evidence committed, decision logs filled →
the rollout is complete. Any FAIL → stop and triage.

| Date | Acceptance run | Evidence file | HARDENING log | RUNBOOKS lines | Signed |
|---|---|---|---|---|---|
| | | | | | |

---

## Appendix A — cited artifacts (dry validation)

`test -f` was run over every path below on 2026-10-17. **PENDING** entries are
cited in the text as "to be produced by …" and are not pretended to exist.

| Artifact | Status |
|---|---|
| `cloud/deploy/DEPLOY.md` | exists |
| `cloud/deploy/HARDENING.md` | exists |
| `cloud/deploy/RUNBOOKS.md` | exists |
| `cloud/deploy/KEY-ROTATION.md` | exists |
| `cloud/deploy/R2-PROVISIONING.md` | exists |
| `cloud/deploy/monitoring/MONITORING.md` | exists (real path; the brief's `cloud/deploy/MONITORING.md` does not exist) |
| `cloud/deploy/monitoring/ovid-cloud-watch.service` | exists |
| `cloud/deploy/monitoring/ovid-cloud-watch.timer` | exists |
| `cloud/deploy/monitoring/watch.env.example` | exists |
| `cloud/deploy/caddy-snippet.conf` | exists |
| `cloud/deploy/provision.sh` | exists |
| `cloud/deploy/backup/README.md` | exists |
| `cloud/deploy/backup/pg_backup.sh` | exists |
| `cloud/deploy/systemd/ovid-worker.service` | exists |
| `cloud/deploy/systemd/ovid-sandboxes.slice` | exists |
| `cloud/deploy/net/install-nft.sh` | exists |
| `cloud/deploy/workspaces/setup-workspaces.sh` | exists |
| `cloud/deploy/rootfs/build.sh` | exists |
| `cloud/deploy/rootfs/install.sh` | exists |
| `cloud/deploy/rootfs/smoke-jail.sh` | exists |
| `cloud/deploy/docker-compose.staging.yml` | exists |
| `cloud/scripts/acceptance.sh` | exists |
| `cloud/scripts/staging.sh` | exists |
| `cloud/scripts/verify-r2.mjs` | exists |
| `cloud/apps/load/src/cli.ts` | exists |
| `cloud/apps/load/src/chaosCli.ts` | exists |
| `cloud/apps/load/dist/cli.js` | exists |
| `cloud/apps/load/dist/chaosCli.js` | exists |
| `lib/core/distribution.dart` | exists |
| `docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md` | exists |
| `docs/superpowers/plans/2026-10-16-ovid-cloud-p9-money-accounts.md` | exists |
| `docs/superpowers/plans/2026-10-16-ovid-cloud-p8-flutter-thin-client.md` | exists |
| `.superpowers/sdd/2026-10-16-ovid-cloud-p10-hardening-cutover/task-1-report.md` | exists |
| `.superpowers/sdd/2026-10-16-ovid-cloud-p10-hardening-cutover/task-6-report.md` | exists |
| `.superpowers/sdd/2026-10-16-ovid-cloud-p10-hardening-cutover/task-7-report.md` | exists |
| `.superpowers/sdd/2026-10-16-ovid-cloud-p10-hardening-cutover/task-10-report.md` | exists |
| `.superpowers/sdd/2026-10-16-ovid-cloud-p10-hardening-cutover/task-11-report.md` | exists |
| `.superpowers/sdd/2026-10-16-ovid-cloud-p10-hardening-cutover/task-14-report.md` | exists |
| `.superpowers/sdd/2026-10-16-ovid-cloud-p10-hardening-cutover/task-5-report.md` | **PENDING — to be produced by Task 5** |
| `cloud/deploy/DECOMMISSION.md` | **PENDING — P9 Task 18** |
| `cloud/deploy/caddy-flips/` | **PENDING — P9 Task 18** |
| `cloud/scripts/migrate/` | **PENDING — P9 Task 18** |
| min-version / forced-update hook | **PENDING — P8 Task 20 prepares it; not enabled** |
| `cloud/apps/load/reports/RELEASE-EVIDENCE-<YYYYMMDD>.md` | **PENDING — produced by executing `acceptance.sh`** |

Artifact check command (re-runnable):

```bash
for f in \
  cloud/deploy/DEPLOY.md cloud/deploy/HARDENING.md cloud/deploy/RUNBOOKS.md \
  cloud/deploy/KEY-ROTATION.md cloud/deploy/R2-PROVISIONING.md \
  cloud/deploy/monitoring/MONITORING.md \
  cloud/deploy/monitoring/ovid-cloud-watch.service \
  cloud/deploy/monitoring/ovid-cloud-watch.timer \
  cloud/deploy/monitoring/watch.env.example cloud/deploy/caddy-snippet.conf \
  cloud/deploy/provision.sh cloud/deploy/backup/README.md \
  cloud/deploy/backup/pg_backup.sh cloud/deploy/systemd/ovid-worker.service \
  cloud/deploy/systemd/ovid-sandboxes.slice cloud/deploy/net/install-nft.sh \
  cloud/deploy/workspaces/setup-workspaces.sh cloud/deploy/rootfs/build.sh \
  cloud/deploy/rootfs/install.sh cloud/deploy/rootfs/smoke-jail.sh \
  cloud/deploy/docker-compose.staging.yml cloud/scripts/acceptance.sh \
  cloud/scripts/staging.sh cloud/scripts/verify-r2.mjs \
  cloud/apps/load/src/cli.ts cloud/apps/load/src/chaosCli.ts \
  cloud/apps/load/dist/cli.js cloud/apps/load/dist/chaosCli.js \
  lib/core/distribution.dart \
  docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md \
  docs/superpowers/plans/2026-10-16-ovid-cloud-p9-money-accounts.md \
  docs/superpowers/plans/2026-10-16-ovid-cloud-p8-flutter-thin-client.md; do
  test -f "$f" && echo "OK      $f" || echo "MISSING $f"
done
```

## Appendix B — dry validation record

- **2026-10-17:** every non-mutating fenced `bash` block in this file passes
  `bash -n`; the artifact loop above reports OK for every `exists` row.
- No rollout step was executed. The only commands run by the author were
  `test -f`, `grep`, `sed`, `bash -n`, and the two git commit commands.
