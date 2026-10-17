# Ovid 100-user staging load report — TEMPLATE (not an executed run)

> **STATUS: NOT EXECUTED.** This is the report skeleton for P10 Task 5. The
> 100-user run is blocked on `cloud/deploy/Dockerfile.mint`, which is being
> written by P9 Task 18 and does not exist yet. `staging.sh up` cannot compose
> the mint service without it. Do **not** copy measured values into this file.
> At execution, write the dated report to
> `cloud/apps/load/reports/load-<YYYYMMDD>-100u.md` (the CLI `--out` path) and
> commit that file instead of this template.
>
> Owner gate (Q3): default is same-machine staging in a maintenance window
> (~45 min: up → run → down). If the production cloud stack is serving real
> traffic, the window start is `[OWNER]` (a 100-user run competes for the
> 8 cores). If Q3 says "second machine", run the identical compose file there
> and record the box in §2.

## 1. Profile echo

- profile: `apps/load/profiles/full100.json`
- expected echo (the CLI prints `profile: {...}` in the report):

```json
{
  "users": 100,
  "durationMs": 1800000,
  "rampMs": 300000,
  "runsPerUserEveryMs": 90000,
  "sandboxDutyCycle": 0.35,
  "browserUsers": 4,
  "schedules": 10,
  "reconnectEveryMs": 60000,
  "spike": { "atMs": 900000, "extraConcurrentRuns": 16, "durationMs": 300000 }
}
```

Expected load shape (from the plan): steady-state in-flight ≈ 100 × (run wall
≈ 45 s) / 90 s ≈ 40–50 runs (spec band 30–50); sandbox-executing instantaneous
≈ duty × in-flight ≈ 14–18 (band 10–20, cap 24); the spike pushes demand to
≈ 30 > `OVID_MAX_ACTIVE_SANDBOXES=24`.

## 2. Box facts (8 vCPU / 22 GB expectation)

Record the verbatim output of:

```bash
nproc
free -g
uname -r
```

- nproc: `<fill in>`
- free -g: `<fill in>`
- uname -r: `<fill in>`
- location (same-machine staging or second machine): `<fill in>`

## 3. Exact commands

All commands run from `/root/OvidAI/cloud` (the CLI resolves `scripts/staging.sh`
from this cwd; `--profile`/`--out` paths are cwd-relative).

```bash
cd /root/OvidAI/cloud

# Preflight: isolation guard, compose up (waits for mint boot re-sync and
# gateway health), mock LiteLLM on 0.0.0.0:14000, host staging worker.
bash scripts/staging.sh guard
bash scripts/staging.sh up
bash scripts/staging.sh mock-start
bash scripts/staging.sh worker-start --env OVID_RUN_STALE_MS=600000

# Live-stack baseline (read-only; StartedAt + health of the live stack).
bash scripts/staging.sh live-check --write-baseline /tmp/ovid-live-baseline.txt

# Dry validation: 10 users / 120 s against staging, SMOKE_THRESHOLDS.
# No report is written for a failed dry; fix first, then re-run.
node apps/load/dist/cli.js load \
  --profile smoke10 \
  --target staging \
  --thresholds smoke \
  --out /tmp/load-smoke10-$(date -u +%Y%m%d).md

# Full 100-user run (30 min + ramp). Operator observes only; do not touch the
# stack. During the run, `docker stats --no-stream` must show no restarts.
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

The CLI exits 0 only when `checkThresholds(report, FULL_THRESHOLDS)` returns
an empty array; any FAIL row must be committed with the failure (never edit a
threshold to pass).

## 4. Threshold table (all mandatory)

`FULL_THRESHOLDS` in `cloud/apps/load/src/thresholds.ts`. Fill in `Measured`
and `Result` from the CLI output / JSON report.

| Metric | Required | Measured | Result | Rationale |
|---|---|---|---|---|
| `eventDelivery.p95Ms` | ≤ 250 | `<fill>` | `<PASS/FAIL>` | loopback + mock-LLM pacing excluded (append-ts → client receipt) |
| `eventDelivery.p99Ms` | ≤ 1000 | `<fill>` | `<PASS/FAIL>` | steady-state window only |
| `integrity.lostEvents` | = 0 | `<fill>` | `<PASS/FAIL>` | ground-truth `readSince` diff |
| `integrity.duplicateEvents` | = 0 | `<fill>` | `<PASS/FAIL>` | ground-truth `readSince` diff |
| `integrity.gapsVsMirror` | = 0 | `<fill>` | `<PASS/FAIL>` | `session_event_mirror` diff |
| `admission.rejectedAtCap` | = 0 | `<fill>` | `<PASS/FAIL>` | admission queues, never rejects (§9) |
| `runsFailed` | = 0 | `<fill>` | `<PASS/FAIL>` | G1/AG1 — no expected failures in a clean run |
| `replay.p95Ms` | ≤ 2000 | `<fill>` | `<PASS/FAIL>` | §6.2 reconnect contract (≤1000 missed) |
| `admission.queuedAtCap` | > 0 | `<fill>` | `<PASS/FAIL>` | the spike must actually hit the cap (precondition) |
| `admission.spikeDrainMs` | ≤ 600000 | `<fill>` | `<PASS/FAIL>` | all queued runs started after the spike ends (§9) |
| `memory.gatewayMaxRssMb` | ≤ 921 | `<fill>` | `<PASS/FAIL>` | 90% of the 1g gateway limit (revised §9) |
| `memory.workerMaxRssMb` | ≤ 2048 | `<fill>` | `<PASS/FAIL>` | worker ~2 GB share of the 4096M unit (revised §9) |
| `memory.hostMemAvailableMinMb` | ≥ 2048 | `<fill>` | `<PASS/FAIL>` | host envelope for the whole run (revised §9) |
| `scheduleRuns.duplicated` | = 0 | `<fill>` | `<PASS/FAIL>` | §8 claim ledger — no duplicate `(schedule_id, scheduled_for)` |
| `scheduleRuns.missed` | = 0 | `<fill>` | `<PASS/FAIL>` | §8 claim ledger (±1 catch-up tolerance) |
| `harness.maxPendingFrames` | ≤ 64 | `<fill>` | `<PASS/FAIL>` | Review Focus #2 — client event queues drain at 100 users |
| `harness.latencyFloorP95Ms` | ≤ 50 | `<fill>` | `<PASS/FAIL>` | Review Focus #2 — the harness is not the bottleneck |

### 4a. Positive-data gates (T6 review)

These are not performance limits. They prove the run produced the data the
limits are evaluated against, because several metrics default to `0` on absent
data and would otherwise pass vacuously. All are mandatory.

| Metric | Required | Why |
|---|---|---|
| `eventDelivery.samples` | > 0 | `eventDeliveryStats([])` returns zeroed p50/p95/p99 |
| `runsStarted` | > 0 | a dead scenario starts no runs |
| `runsCompleted` | > 0 | `runsFailed = 0` must not pass with zero completed runs |
| `harness.invalidFrames` | = 0 | no off-contract server frame was silently accepted |
| `replay.samples` | > 0 | `replay.p95Ms` defaults to 0 when no replay was measured |
| `admission.spikeRuns` | > 0 | `admission.spikeDrainMs` defaults to 0 when no spike fired |
| `scheduleRuns.fired` | > 0 | schedule counters default to 0 when the ledger was not read |
| `runsFailedUnattributed` | = 0 | a `run_failed` without `payload.runId` must not vanish from `runsFailed` |
| `memory.gatewayMaxRssMb` | > 0 | the docker-stats sampler actually observed the gateway |
| `memory.workerMaxRssMb` | > 0 | the worker RSS sampler actually observed the worker |
| `memory.hostMemAvailableMinMb` | > 0 | `/proc/meminfo` was actually sampled |

## 5. Live-unaffected before/after

Record the verbatim `live-check` output, or state that the command exited 0
with no `StartedAt` drift:

```
BEFORE (staging.sh live-check --write-baseline):
<fill in>

AFTER (staging.sh live-check --baseline):
<fill in>
```

Also record whether `docker stats` showed any restart during the run:
`<fill in>`.

## 6. Harness floor

- `harness.latencyFloorP95Ms`: `<fill>` (must be ≤ 50)
- `harness.maxPendingFrames`: `<fill>` (must be ≤ 64)
- `harness.invalidFrames`: `<fill>` (must be 0)

## 7. Anomalies (verbatim)

Record any anomaly from the report's `notes` array verbatim, including
`browser tier: NOT EXERCISED (...)` if the browser channel was unavailable
(the plan requires a loud note, never a silent zero), and any
`drain timed out`, `ground truth read failed`, `send failed`, or replay
delivery note.

```
<fill in, or "none">
```

## 8. Result

- `checkThresholds(FULL_THRESHOLDS)`: `<empty array → PASS / list → FAIL>`
- Overall: `<PASS / FAIL>`
