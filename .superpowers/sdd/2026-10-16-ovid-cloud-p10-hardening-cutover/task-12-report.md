# Task 12 — Runbooks (incident + ops playbooks) — report

Status: DONE (docs-only; no code touched).

## Deliverables
- `cloud/deploy/RUNBOOKS.md` (new, 1522 lines) — two parts, every playbook
  shaped **Symptom → Diagnose → Act → Verify → Post-mortem hook**, plus a
  SAFETY section, environment facts, a common prelude, and an appendix of
  commands actually run on this host.
- `cloud/deploy/DEPLOY.md` — additive §10 cross-link to RUNBOOKS.md
  (6 added lines; no other change).
- `cloud/deploy/backup/README.md` — additive quarterly-drill template
  cross-link to RUNBOOKS.md O-1, with the post-activation port note
  (cloud postgres proxy owns 5434 → drill on 5435).

## Incidents covered (Part 1)
1. I-1 Worker crash / restart loop
2. I-2 redis-q loss / unavailable
3. I-3 redis-q at the memory ceiling (`noeviction`, AG3)
4. I-4 redis-c degradation (cache-class, allkeys-lru)
5. I-5 Postgres outage
6. I-6 Disk pressure / disk full (`OVID_DISK_ALERT_PCT`, `disk-80`)
7. I-7 Leaked sandbox processes
8. I-8 Sandbox slice OOM / cgroup exhaustion
9. I-9 Browser pool exhaustion / memory alarm (`MAX_LIVE_BROWSERS` 4→3;
   never raise the 1300 MB alarm; stuck-context kill marked
   `[MAP P6 admin seam — NOT SHIPPED]` with the shipped idle-evict/restart
   path)
10. I-10 R2 outage / degraded storage
11. I-11 mint outage
12. I-12 LiteLLM outage
13. I-13 Key rotation (blast-radius table: Firebase, `OVID_MASTER_KEY`,
    `OVID_INTERNAL_TOKEN`, `OVID_INTERNAL_API_SECRET`,
    `OVID_ADMIN_MASTER_KEY`, redis passwords, R2 token, LiteLLM master/salt,
    Postgres)
14. I-14 Stuck runs (`run_lost`, sweeper)
15. I-15 Stuck schedule runs (settle reconciler)

## Ops covered (Part 2)
- O-1 Quarterly backup/restore drill (committed-evidence rule; 2026-10-16
  entry is the template)
- O-2 Dependency updates (`pnpm up --interactive`, `pnpm audit --prod
  --audit-level high`, build/test, CI-proven typecheck)
- O-3 Rootfs rebuild + pin (build.sh → SHA256SUMS/manifest → install.sh
  atomic symlink + smoke-jail + keep 2 → rollback by re-pointing)
- O-4 LiteLLM image pin/upgrade (points at HARDENING G, does not duplicate)
- O-5 Monitoring install/self-test cross-ref (MONITORING.md + HARDENING F)

## Grounding / evidence
- Shipped code: `staleRuns.ts`, `schedulerSettle.ts`, `schedulerTick.ts`,
  `schedulerMirror.ts`, `warmLru.ts`, `cgroups.ts`, `manager.ts`,
  `eventLog.ts`, `packages/queue/src/queues.ts`, `apps/watch/src/*`,
  `routes/health.ts`, `routes/messages.ts`, `storageEnv.ts`, `r2Adapter.ts`.
- Shipped runbooks: `DEPLOY.md` §10–§12, `BROWSERS.md` §(b)/(c)/(g),
  `R2-PROVISIONING.md`, `HARDENING.md` C/E/G/H, `MONITORING.md`,
  `backup/README.md`.
- Evidence lines cite: `staleRuns.test.ts` (real Postgres + real Redis),
  `schedulerSettle.test.ts`, P2 host tests (`cgroups.host.test.ts`,
  `manager.host.test.ts`), `warmLru.test.ts`, the Task-6 chaos scenarios now
  on disk (`redis-q-restart`, `gateway-restart`, `postgres-restart`), the
  Task-11 watch dry validation, the 2026-10-16 backup restore drill, and the
  P6 dev-box bench output in BROWSERS.md §(c).

## Verification performed
- `bash -n` on all 44 fenced bash blocks in RUNBOOKS.md: clean.
- Nested `sh -c 'psql … '\''running'\'' …'` quoting executed against the
  live postgres container: correct output.
- Read-only host diagnostics run and pasted in Appendix A: `df -h /`
  (33% used), `ps` uid-range filter (empty), `nft list table inet
  ovid_sandbox` (absent — cloud stack not activated), cgroup slice (absent),
  `systemctl list-timers ovid-cloud-backup.timer` (0 listed),
  `redis-cli 7.4.11` / `psql 16.15` inside containers, node v22.23.3,
  zstd v1.5.5.
- All cited script paths checked with `test -f`; cited source paths checked
  by existence scan. Fixed one wrong citation (`cloud/apps/mint/README.md`
  → `server/mint/README.md`).

## Commands not runnable here (recorded honestly)
- The cloud stack is NOT activated on this box: no `ovid-cloud-*`
  containers, no `ovid-worker.service`, no `/workspaces`, no
  `/opt/ovid-rootfs`, no backup timer. Post-activation commands were not
  executed; their syntax follows the shipped scripts/units and existing
  runbooks.
- Host PATH has no `redis-cli`/`psql`; every command uses `docker exec`
  (verified). The live redis container has no `REDIS_PASSWORD` env var, so
  the mint-db2 command sources `/opt/ovid-gateway/.env` on the host.
- P10 Task-7 chaos (`worker-kill`, `disk-pressure`, `clock-skew`, landed in
  `212aa82`) and `cloud/scripts/acceptance.sh` (landed in `a28d737`) are on
  disk; they require the staging composition and were not run here.
- `packages/account` has no `tsconfig.check.json`, so the bare
  `pnpm -r --parallel exec tsc -p tsconfig.check.json` form fails there;
  O-2 uses the CI-proven `tsc --noEmit -p tsconfig.json` plus a per-package
  optional pass.

## Review fix round (2026-10-17)

`task-12-review.md` findings closed in this round. F1/F2/F3/F7 were already
fixed by the controller in `4aed770` and were not re-touched.

| Finding | Status | What changed / evidence |
|---|---|---|
| F5 (MEDIUM) | FIXED | I-14 now says list-then-**claim**: `runs.finish` is the conditional claim (`staleRuns.ts:54`), only the winner appends (`:58`) and mirrors (`:62`), so concurrent sweeps emit exactly one event; the one-worker rule is attributed to browser ports and cgroup ownership. The "emitted before `runs.finish`" wording was removed. |
| F6 (MEDIUM) | FIXED | Key-rotation table gained `OVID_INTERNAL_API_SECRET` (three holders: `gateway/src/env.ts:167`, `worker/src/main.ts:269`, `mint/src/env.ts:255`; ≥32 bytes) and `OVID_ADMIN_MASTER_KEY` (`mint/src/env.ts:254`, `adminRoutes.ts:47,79`), each with blast radius and restart/verify path. |
| L1 | FIXED | §0.2, I-1, I-14 and Appendix A no longer claim the Task-7 chaos suite/`acceptance.sh` are absent; they cite `212aa82` / `a28d737` and the scenario names/paths. |
| L2 | FIXED | I-9 Symptom uses the shipped `BrowserPoolBusyError` (`packages/browser/src/pool.ts:47,262`), not `browser_busy`. |
| L3 | FIXED | O-2 marks `pnpm up --interactive` **[OWNER]** and tells the operator to prefer a separate checkout/worktree. |
| L4 | FIXED | O-1…O-5 now use Symptom → Diagnose → Act → Verify → Post-mortem hook; O-5 gained Diagnose/Act/Verify/Post-mortem. |
| L5 | FIXED | I-13's restart block is a `case "$ROTATED"` that restarts only the consumers named in the table (worker/gateway, mint, litellm, or none). |
| L6 | FIXED | This report now states the real line count (1522). |
| L7 | FIXED | Unused `WPID` removed from I-9. |
| L8 | FIXED | DEPLOY.md now says the opening SAFETY rule governs every Act step, rather than claiming every step carries a backup. |

Not assigned in this round: F4 (eventLog retention owner-decision marker)
remains as reviewed — it was not in the controller's fix list and was not
changed.

## Commit
Original task commit: `cloud/deploy/RUNBOOKS.md`, `cloud/deploy/DEPLOY.md`,
`cloud/deploy/backup/README.md`. Fix-round pathspec:
`cloud/deploy/RUNBOOKS.md`, `cloud/deploy/DEPLOY.md`, and this report. No
code, no lockfile.
