# Task 4 fix report — round 2

- **Plan:** `docs/superpowers/plans/2026-10-16-ovid-cloud-p10-hardening-cutover.md`, Task 4
- **Review:** `.superpowers/sdd/2026-10-16-ovid-cloud-p10-hardening-cutover/task-4-review.md`
- **Branch:** `feat/ovid-cloud`
- **Base commit:** `4ff039a` (fixed C1/I2/I3 and the mock's `tool_calls` half of I4)
- **Scope:** `cloud/apps/load/` only (`canarySweep.ts` / `canaryCli.ts` untouched)

Remaining findings addressed: **I1**, **I5**, and the **second half of I4** (held spike).

## I1 — `smoke.test.ts` was not the plan's integration test

**Open:** The plan's Step 4 requires composing the real `buildGateway` + worker
in-process "exactly like spine.test.ts" (real queue, real WS route, real event
log), gated by `describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)`, with
10 users / 20 s and `chunkDelayMs: 20`. The committed test was a hand-written
mock gateway + in-memory `EventLog`, always ran, and used 6 users / 3 s / 5 ms.

**Change** (`cloud/apps/load/src/smoke.test.ts`):
- Added a second tier: `describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)`
  that composes, exactly like `apps/e2e/src/spine.test.ts`:
  - `buildGateway({ db, queues, verifier: createTestVerifier(), tickets, keys,
    mint, events, system: createRedisSystemBus(redis) }).listen(0)`
  - `createQueues({url}, {prefix: <suite-unique>})` +
    `createAgentRunsWorker(connection, createAgentRunProcessor(...), {prefix})`
  - `createRedisEventLog(redis)` created once and shared by gateway and worker
  - in-process mock LiteLLM (`chunkDelayMs: 20`, 3 deltas)
  - real `/cloud/v1/auth/ticket`, `/cloud/v1/sessions`,
    `/cloud/v1/sessions/:id/messages`, and `/cloud/ws` routes
  - a dedicated BullMQ prefix and the caller-supplied isolated
    `TEST_DATABASE_URL` / `TEST_REDIS_URL` (never the shared dev DB or the live
    `ovid-gateway-*` containers); cleanup deletes only this suite's streams and
    obliterates only its own queue prefix.
- Profile is the plan's: `users: 10`, `durationMs: 20_000`, `rampMs: 1_000`,
  `chunkDelayMs: 20`. It also exercises reconnect (`reconnectEveryMs: 10_000`),
  the schedule tier (`schedules: 1`), and the held spike
  (`atMs: 8_000`, `extraConcurrentRuns: 5`, `durationMs: 1_000`).
- The old self-contained test is retained and labelled
  `load harness (unit: self-contained mock gateway)`.
- Removed the unused `wsServerMsg` import; the header comment now states the
  two tiers and no longer implies the unit mock is the integration proof.

**Proving test:** `smoke.test.ts > load harness integration (real gateway +
worker + Postgres/Redis) > 10 users / 20 s: zero loss/dups vs the real event
log, floor held, spike held`. It asserts every plan Step 4 item:
`integrity.lostEvents === 0`, `duplicateEvents === 0`, `gapsVsMirror === 0`,
`runsCompleted === runsStarted`, `eventDelivery.p95Ms <= 250`,
`harness.latencyFloorP95Ms <= 50`, `harness.maxPendingFrames <= 32`, plus the
positive-data gates `runsStarted > 0` and `eventDelivery.samples > 0`.
The mirror read settles only until the worker's `eventMirror.put` catches up
with the Redis stream; a persistent gap still fails `gapsVsMirror`.

**Ran / skipped:** the integration test **RAN** with an isolated database and
Redis (see gates). Without `TEST_DATABASE_URL`/`TEST_REDIS_URL` it is
**SKIPPED by design** (the unit tier still runs).

## I5 — schedules were created under the wrong uid

**Open:** `scenario.ts` created schedules with `Bearer test:${runTag}-sched`
while the referenced session belonged to `runTag-u0`. The schedule service
owner-scopes the session (`scheduleService.ts:134-137`), so creation 404'd,
the tier recorded NOT EXERCISED, and `fired/duplicated/missed = 0/0/0`
**passed** their `eq 0` thresholds.

**Change** (`cloud/apps/load/src/scenario.ts`):
- `sessionOwners[]` is recorded in parallel with `sessions[]` in `runUser`.
- `createSchedules` picks the session **and its owner uid** and sends
  `Authorization: Bearer test:<ownerUid>`.
- Added `scheduleRuns.created` to `LoadReport` (schedules actually created).
- `checkThresholds` now gates `scheduleRuns.created > 0` on
  `whenProfileFieldPositive: "schedules"` (present in `SMOKE_THRESHOLDS`, and
  therefore inherited by `FULL_THRESHOLDS`). When the profile declares
  schedules, `created === 0` is a **FAIL** — a 0/0/0 ledger can no longer read
  as PASS. The gate is skipped only when the profile creates no schedules;
  a profile-less `checkThresholds` call still evaluates it (missing context
  cannot hide a dead measurement).
- Loud notes now distinguish the three cases:
  - creation failed / zero created → `schedule tier: NOT EXERCISED — created=0
    of N; scheduleRuns.created fails the positive-data gate`
  - no Postgres or a read error → `fired/duplicated/missed are NOT MEASURED
    (the zeros are placeholders)`
  - ledger read but empty → `0 occurrences in this window (a genuine zero,
    not an unobservable ledger)`.
- `cli.ts` renders `scheduleRuns.created` in the report table.

**Proving tests:**
- Integration: `schedules: 1` against the real schedule route →
  `report.scheduleRuns.created === 1` and no `schedule tier: NOT EXERCISED`
  note. The pre-fix `-sched` identity would 404 and yield `created = 0`.
- `thresholds.test.ts`:
  - `schedules>0 with zero created FAILS even when the ledger counters are 0/0/0`
  - `the schedule-created gate does not apply when the profile creates none`

## I4 (second half) — the spike is not held

**Open:** `spike.durationMs` was never read, `target.mockLlmUrl` was unused in
`scenario.ts`, and the burst was just `extraConcurrentRuns` sends within 5 s.
`spikeDrainMs` therefore could only ever be 0 and admission could not be
pushed over `OVID_MAX_ACTIVE_SANDBOXES`.

**Change** (`cloud/apps/load/src/mockServer.ts`, `scenario.ts`):
- The mock now exposes a documented HTTP control surface (same arm/release
  mechanics as the in-process `arm()`):
  - `POST /_control/arm` body `MockLlmScript` → `{gateId}`
  - `POST /_control/release` body `{gateId?}` → `{released, heldRequests}`
  - `GET /_control/status` → `{armed, gateId, requestsSeen, heldRequests,
    totalHeldRequests}`
- Added `gateMarker`: when set, `gateAfterDeltas` is honoured only for
  requests whose last user message starts with the marker. The scenario arms
  `"[spike]"`, so steady-state runs keep streaming while the spike is parked.
- `scenario.fireSpike` now:
  1. arms the mock **before** the burst;
  2. fires `extraConcurrentRuns` spike prompts within 5 s (unchanged cadence);
  3. holds the gate for `spike.durationMs`;
  4. reads `/_control/status` (`heldRequests`), then releases;
  5. always releases in `finally` if the body throws.
- `spikeEndedAt` is now the **release** instant, so `spikeDrainMs` measures
  release → last spike `run_started` (the plan's "queued runs started after
  spike ends"). When runs started before release the report says drain 0 is
  real; when no start was observed it says NOT MEASURED.
- New `admission.spikeHeldRequests` field plus a `FULL_THRESHOLDS`
  positive-data gate (`> 0` whenever the profile has a spike), so an
  unreachable/old mock control surface is a FAIL, not a silent 0.
- If the composition has no sandbox admission, the report explicitly states
  that the parked burst did **not** saturate `OVID_MAX_ACTIVE_SANDBOXES`
  rather than implying it did.

**Proving tests:**
- Unit: `HTTP control surface holds only gateMarker requests until release
  (spike hold seam)` — arms a gate, proves a `[spike]` request parks after its
  first delta while a plain request completes, observes `heldRequests > 0`,
  releases, and proves the parked stream completes.
- Integration: the real-composition run asserts `spike.runs > 0` **and**
  `spike.heldRequests > 0`; the evidence line shows `spike.runs=5
  spike.held=5`.
- `thresholds.test.ts`: `a spike with zero held requests FAILS` and
  `the spike-hold gate does not apply to a profile with no spike`.

## Gates

All commands run from `/root/OvidAI/cloud`.

### Build

```
$ pnpm --filter @ovid/load build
$ tsc -p tsconfig.json
```
exit 0.

### Typecheck (tests included)

```
$ pnpm --filter @ovid/load exec tsc -p tsconfig.check.json --noEmit
```
exit 0, no output.

### Tests — no services (integration skipped by design)

```
$ pnpm --filter @ovid/load test
 Test Files  12 passed (12)
      Tests  172 passed | 5 skipped (177)
```

The 5 skips are the real-composition test (no `TEST_DATABASE_URL` /
`TEST_REDIS_URL`) plus the existing service-gated chaos/canary legs.

### Tests — isolated services (real-composition test RAN)

Isolation used for this run: throwaway database
`ovid_load_t4_round2` in the disposable `ovid-dev-pg` container and dedicated
Redis logical db 7 on `ovid-dev-redis` (no `FLUSHDB`; only this suite's
stream keys and queue prefix are deleted). The live `ovid-gateway-*` stack was
not touched.

```
$ TEST_DATABASE_URL='postgres://postgres:ovid@127.0.0.1:5433/ovid_load_t4_round2' \
  TEST_REDIS_URL='redis://127.0.0.1:6390/7' \
  OVID_TEST_QUEUE_PREFIX='ovid-load-t4-full2' \
  pnpm --filter @ovid/load test
 Test Files  12 passed (12)
      Tests  177 passed (177)
```

Exact integration evidence line from that run:

```
load integration: runsStarted=55 runsCompleted=55 delivery.p95=3ms samples=260 integrity={"lostEvents":0,"duplicateEvents":0,"gapsVsMirror":0} floor.p95=0.061459999999897263ms pending=0 schedules.created=1 spike.runs=5 spike.held=5 spike.drainMs=0
```

The `spike.drainMs=0` is accompanied by the explicit report note that the
in-process composition has no sandbox admission, so the held burst did not
queue any run at release; it is not a silent zero.

## Still not measurable

- **Exact sandbox admission queue depth.** `SandboxManager` keeps its FIFO
  queue internal (`packages/sandbox/src/manager.ts`); no wire/stat surface
  exposes it. `admission.queuedAtCap` remains the documented
  accepted-not-started **proxy** (session turn queue + sandbox admission), and
  `maxObservedActiveSandboxes` remains the `tool_started`/`tool_completed`
  proxy.
- **Saturating `OVID_MAX_ACTIVE_SANDBOXES` in the in-process integration
  test.** That composition intentionally has no sandbox/tool roster (same as
  `spine.test.ts`), so the held spike proves the hold seam but cannot exceed
  the cap. The report says so (`spike.held=5`, `drain=0`, plus the explicit
  "admission path was NOT saturated" note). Cap saturation is only observable
  in the full staging run, where `spikeHeldRequests > 0` and
  `spikeDrainMs` are now both real measurements.
- **Schedule claim ledger without Postgres.** When no database is configured
  or the read fails, the counters are not observable; the report now says
  `NOT MEASURED (the zeros are placeholders)` and the `scheduleRuns.fired > 0`
  gate fails. With a database the ledger is read for the created schedule ids
  only.
- **The integration tier itself** is skipped when `TEST_DATABASE_URL` /
  `TEST_REDIS_URL` are absent, by design (the plan's `skipIf`).
