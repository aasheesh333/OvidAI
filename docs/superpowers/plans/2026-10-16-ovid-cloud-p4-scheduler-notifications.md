# Ovid Cloud P4 — Muse-style Autonomous Scheduler + Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Users (or the agent on their behalf) describe WHAT to do and WHEN (one-off / interval / daily-at / cron); the server fires it autonomously with no user present, runs it as a normal agent run, and reports the result via FCM push, a WS system channel, and the in-app schedule feed — spec G8/D8/§8 in full.

**Architecture:** Postgres is the only authority: a `schedules` row carries `nextRunAt`; a worker tick every 15 s scans due schedules `FOR UPDATE SKIP LOCKED`, claims each occurrence at-most-once in the `schedule_runs` ledger (unique key `(schedule_id, scheduled_for)` — the spec's idempotency key), and enqueues a plain `agent-runs` job with prompt `[schedule: {title}] {description}`. A BullMQ delayed-job mirror of `nextRunAt` is a fast path only, rebuilt from Postgres at boot. Results are reconciled by a settle pass that reads terminal `runs` rows (works with ANY processor version — P1 v0 or P3 full agent-core), then advances/retries/pauses the schedule, writes transcript messages + session events, publishes WS `system` events, and pushes FCM. Missed-run catch-up, grace windows, `ran_late`, retry backoff and notification copy are exact ports of `lib/core/schedule_coordinator.dart` and `lib/core/background_notifications.dart` (AG4).

**Tech Stack:** Node 22, TypeScript strict, Vitest, Drizzle ORM (postgres.js), BullMQ 5, ioredis, Fastify 5, zod, firebase-admin (FCM), **luxon ^3.5** (tz math) + **cron-parser ^4.9** (5-field cron, tz-aware) — pinned; no other time library (Node 22 has no Temporal).

**Spec:** `docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md` — §8 (primary), §6.2 (approvals/notifications over WS), G8, §10 (`schedules`/`schedule_runs`/`devices` tables), §14 row P4. Also binding:
- Ledger ruling Q5 (`.superpowers/sdd/2026-10-15-ovid-cloud-p0-p1-spine/progress.md`): unattended runs require a previously-minted LiteLLM key; absent → `run_failed` `key_not_minted` + push asking the user to open the app once.
- Dart behavioral references (AG4 port sources, with their pinned test values): `lib/core/schedule_coordinator.dart` (+ `test/schedule_catchup_test.dart`, `test/schedule_coordinator_test.dart`), `lib/core/background_notifications.dart` (+ `test/background_notifications_test.dart`).

**P3 seam note (read before Tasks 7/13):** per the owner's wave order P3 (agent-core parity) executes BEFORE P4, but P3's internal interfaces were unknown when this plan was written. Two touch points adapt at implementation time: (a) **tool registration** — Task 13 pins tool names/input schemas/results and exports `createScheduleTools`; register them through whatever roster API P3 actually shipped (read `apps/worker/src/` for the tool-definition shape and adapt the wrapper only); (b) **approval timeout** — Task 7 pins `UnattendedApprovalHook`; call it from P3's approval-request timeout decision point (spec §6.2's 120 s default-deny). If P3 has NOT landed when a task executes: implement the module exactly as pinned, export it, leave it unwired in `main.ts` with a `// P4-SEAM:` comment, and report the gap to the controller. Everything else in P4 (tick, ledger, settle, REST, WS, push) works with the P1 v0 tool-less processor unchanged: scheduled runs execute via the existing `agent-runs` queue and are reconciled through the authoritative `runs` table.

## Global Constraints

Copied from the P1 plan (`docs/superpowers/plans/2026-10-15-ovid-cloud-p0-p1-spine.md`), still binding:

- Wire format: JSON, **camelCase**; ids are **UUIDv7** (`newId()` from `@ovid/db`); timestamps ISO-8601 UTC.
- New code only under `cloud/`; deploy target `/opt/ovid-cloud`. Never edit `/opt/ovid-gateway/docker-compose.yml` or the live Caddyfile; repo `cloud/deploy/*` artifacts may be edited but **activation stays owner-gated** (no `docker compose up`, no Caddy reloads in this plan).
- Route prefix: all new HTTP under `/cloud/v1/*`; WS at `/cloud/ws`. Gateway binds `127.0.0.1:8081`.
- Redis split (AG3): `redis-q` runs `maxmemory-policy noeviction`; tests use the dev services (`bash cloud/scripts/dev-services.sh` → `TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres`, `TEST_REDIS_URL=redis://127.0.0.1:6390`), never live ones.
- Auth on every REST/WS handshake: Firebase ID token + App Check; dev/test bypass `OVID_AUTH_MODE=test` (`Authorization: Bearer test:<uid>`); refused when `NODE_ENV=production`.
- Error envelope (REST): `{ "error": { "code": string, "message": string } }`. Codes this plan adds to P1's set: `tier_required` (403, cron on Free tier). Wrong-owner and unknown-id are both 404 `not_found` — never 403, no existence leaks.
- Commit after every task; run `pnpm -r build && pnpm -r test` from `cloud/` before committing.

New in P4:

- `@ovid/shared`, `@ovid/queue`, `@ovid/events` extensions are strictly **ADDITIVE**: existing exported names/signatures/union variants never change meaning; new union variants and new optional fields only (old payloads must still parse).
- All stored timestamps are UTC (`timestamptz(3)`); timezones exist ONLY inside `daily_at`/`cron` evaluation. Time libs pinned: `luxon@^3.5.0` (+ `@types/luxon`), `cron-parser@^4.9.0` (v4 API: `parseExpression(expr, { tz, currentDate })`).
- Every time-dependent module takes `clock?: () => Date`; tests use injected clocks — **no real waiting beyond ~2 s** (bounded `waitForAsync` for I/O settle only, gates/deferreds for ordering).
- Missed-run constants EXACTLY (Dart port): catch-up tolerance **2 min**; one-off grace **24 h** (run late, flag `ranLate`); recurring grace = `every`: `min(interval/2, 6 h)`, `daily_at`/`cron`: **6 h**; beyond grace → recurring `skipToNext`, one-off `pauseForReview`. `maxRetries` integer **0–3**; retry backoff `30_000 · 2^(attempt−1)` ms (30 s / 60 s / 120 s), then `pauseForReview`.
- Scheduler tick default **15 s** (`OVID_SCHEDULER_TICK_MS`, positive int, validated like `OVID_RUN_STALE_MS`); settle pass runs immediately before each tick. Postgres authoritative; the BullMQ mirror is never authoritative (a lost/duplicated mirror job must be unobservable).
- Claim ledger: `schedule_runs` unique index on `(schedule_id, scheduled_for)` IS the at-most-once idempotency key (spec §8). Queue adds keep P1's `jobId: runId` convention.
- Schedule-run prompt EXACTLY: `` `[schedule: ${title}] ${description}` `` (one helper, `schedulePrompt()`).
- Unattended runs use the previously-minted key only (ledger Q5): the tick never mints; a missing key surfaces as the processor's existing `run_failed {code:"key_not_minted"}`, which settle turns into a failed schedule run + the pinned open-the-app push.
- FCM: firebase-admin resolves credentials via `GOOGLE_APPLICATION_CREDENTIALS` (production: the existing `/opt/ovid-gateway/firebase-admin.json`, bind-mounted read-only like the gateway's — never copied into the repo). ALL tests stub `PushSender`; no test ever contacts FCM.
- WS `system` channel is best-effort live (pub/sub, NO replay, no seq): the REST feed (`GET /schedules/:id/runs`) is the durable source. Garbage on the bus channel is skipped, never crashes (Task 4-ruling hardening pattern).
- Cron triggers are Pro-only, enforced at ONE choke point (`scheduleService`, Task 5) so REST and agent tools cannot diverge: `users.tier === "free"` → `ScheduleError("tier_required")` → HTTP 403.

## Review Focus

1. **Double fire** — tick and BullMQ mirror (or two worker replicas, or a boot resync racing a live tick) process the same occurrence: exactly ONE agent run may exist per `(scheduleId, scheduledFor)`. Expected: the claim-ledger unique index makes the loser a silent `duplicate_claim`; the `FOR UPDATE SKIP LOCKED` row lock serializes the rest. Pinned by Task 4 (index conflict test), Task 8 (concurrent-fire race test), Task 14 flow d.
2. **Crash between claim and enqueue** — worker dies after the ledger row commits but before `agentRuns.add`: the occurrence must NOT be lost silently. Expected: settle's stale path (run row missing/queued past `SCHEDULE_ENQUEUE_LOST_MS`) treats it as retryable `run_lost` → retry ladder or `pauseForReview`. Pinned by Task 9 test (orphaned `running` schedule_run, `runId` null).
3. **DST transitions for `daily_at`/`cron`** — spring-forward gap and fall-back fold must each yield exactly one sane fire time (gap: luxon shifts forward; fold: earlier offset wins), stored UTC. Pinned by Task 1 tests (America/New_York 2026-03-08 02:30 and 2026-11-01 01:30).
4. **Tier and ownership abuse** — Free-tier user creating/patching a cron schedule gets 403 `tier_required`; user B reading/patching/deleting user A's schedule gets 404 `not_found` (never 403). Pinned by Task 5 (service) and Task 11 (route) tests.
5. **Dead FCM tokens / no devices** — an unregistered token is unbound (row deleted) and recorded, never retried into a storm; a user with zero devices still gets a `skipped_no_devices` notification record and the full in-app feed/WS story. Push failures NEVER fail a schedule run. Pinned by Task 7 tests.

---

### Task 1: `@ovid/shared` — trigger engine + missed-run policy (Dart port)

**Files:**
- Create: `cloud/packages/shared/src/triggers.ts`
- Test: `cloud/packages/shared/src/triggers.test.ts`
- Modify: `cloud/packages/shared/src/index.ts` (add `export * from "./triggers.js";`), `cloud/packages/shared/package.json` (add deps `luxon@^3.5.0`, `cron-parser@^4.9.0`; devDep `@types/luxon`)

**Interfaces:**
- Consumes: nothing new (zod already a dep).
- Produces (everything later tasks import from `@ovid/shared`):

```ts
// triggers.ts
export const SCHEDULE_TRIGGER_KINDS = ["at", "every", "daily_at", "cron"] as const;
export type ScheduleTrigger =
  | { kind: "at"; at: string }                       // ISO-8601 instant, stored UTC-normalized
  | { kind: "every"; seconds: number }               // integer ≥ 300
  | { kind: "daily_at"; time: string; tz: string }   // "HH:mm" (^[01]\d|2[0-3]):[0-5]\d$ + IANA tz
  | { kind: "cron"; expr: string; tz: string };      // 5-field cron + IANA tz
export const scheduleTriggerSchema: z.ZodType<ScheduleTrigger>; // discriminated union on "kind" + refinements below
export function isRecurringTrigger(trigger: ScheduleTrigger): boolean;      // everything but "at"
export function nextFireAfter(trigger: ScheduleTrigger, from: Date): Date | null;
export function nextIntervalSlot(scheduledFor: Date, seconds: number, now: Date): Date;
export function nextSlotAfterMissed(trigger: ScheduleTrigger, due: Date, now: Date): Date | null;
export function describeTrigger(trigger: ScheduleTrigger): string;          // deterministic human echo (templates pinned in Step 3)
export const MISSED_TOLERANCE_MS = 120_000;
export const ONE_OFF_GRACE_MS = 86_400_000;
export const RECURRING_GRACE_CAP_MS = 21_600_000;
export type MissedRunDecision = "onTime" | "runNow" | "skipToNext" | "pauseForReview";
export function graceMsFor(trigger: ScheduleTrigger): number;
export function decideMissedRun(trigger: ScheduleTrigger, due: Date, now: Date): MissedRunDecision;
export function scheduleRetryBackoffMs(attempt: number): number;            // 30_000 · 2^(attempt−1); attempt ≥ 1
```

- [ ] **Step 1: Write the failing tests** in `triggers.test.ts` — ports of the pinned Dart cases (`test/schedule_catchup_test.dart`) plus schema/DST coverage. Fixture: `const T = (iso: string) => new Date(iso);` and base `now = T("2026-10-13T12:00:00.000Z")`. Required cases (exact values):
  - schema: `{kind:"every",seconds:300}` parses; `{kind:"every",seconds:299}` rejects (min 300); `{kind:"every",seconds:300.5}` rejects (integer); `{kind:"daily_at",time:"09:00",tz:"Europe/Berlin"}` parses; `time:"24:00"` rejects; `tz:"Mars/Olympus"` rejects (luxon `Info.isValidTimezone`); `{kind:"cron",expr:"0 9 * * 1-5",tz:"UTC"}` parses; `expr:"* * * * * *"` (6-field) rejects (cron-parser throws); `{kind:"at",at:"not-a-date"}` rejects; two kinds at once / unknown kind rejects.
  - `nextFireAfter`: `{kind:"at",at:"2026-10-13T17:00:00Z"}` from 12:00Z → `17:00Z`; at ≤ from → `null`. `{kind:"every",seconds:300}` → `from + 300_000ms`. `daily_at 13:30 UTC` from 12:00Z → same day 13:30Z; `daily_at 08:00 UTC` → next day 08:00Z; `daily_at 12:00 UTC` from exactly 12:00:00.000Z → **next day** 12:00Z (strictly-after, Dart-pinned). `cron "0 9 * * *" tz UTC` from 12:00Z → next day 09:00Z.
  - DST (Review Focus 3): `daily_at 02:30 America/New_York` from `2026-03-07T12:00:00Z` → fires `2026-03-08T07:30:00Z` (gap day: luxon shifts the nonexistent 02:30 to 03:30 EDT = 07:30Z — pin whatever luxon produces, assert it is EXACTLY ONE fire on 2026-03-08 between 06:00Z and 08:00Z and that a second call from that instant yields 2026-03-09T06:30:00Z). Fold: `daily_at 01:30 America/New_York` from `2026-11-01T04:00:00Z` → `2026-11-01T05:30:00Z` (01:30 EDT, the EARLIER offset).
  - `nextIntervalSlot`: anchor `09:00Z`, seconds 3600, now `12:10Z` → `13:00Z` (Dart-pinned: skips every missed period).
  - `graceMsFor`: `every 3600` → 1_800_000; `every 86_400` → 21_600_000 (capped); `daily_at`/`cron` → 21_600_000; `at` → 86_400_000.
  - `decideMissedRun` (Dart-pinned): 1 min late → `onTime`; one-off 3 h late → `runNow`; one-off 48 h late → `pauseForReview`; `every 3600` 20 min late → `runNow`; `every 3600` 3 h late → `skipToNext`; `daily_at` 5 h late → `runNow`, 7 h late → `skipToNext`.
  - `nextSlotAfterMissed`: `every 3600` due 09:00Z now 12:10Z → 13:00Z; `daily_at 08:00 UTC` due yesterday now 12:00Z → tomorrow 08:00Z; `at` → `null`.
  - `scheduleRetryBackoffMs`: 1→30_000, 2→60_000, 3→120_000.
  - `describeTrigger` templates: at → `once at 2026-10-13T17:00:00.000Z`; every → `every 300 seconds`; daily_at → `daily at 09:00 (Europe/Berlin)`; cron → `cron '0 9 * * 1-5' (America/New_York)`.
- [ ] **Step 2: Run to verify fail.** `cd /root/OvidAI/cloud && pnpm install && pnpm --filter @ovid/shared test` — Expected: FAIL (module missing).
- [ ] **Step 3: Implement `triggers.ts`.** Approach: zod discriminated union with per-variant refinements (`every`: `z.number().int().min(300)`; `daily_at.time`: regex `^([01]\d|2[0-3]):[0-5]\d$`; `tz`: `Info.isValidTimezone` from luxon; `cron.expr`: try/catch `parseExpression`; `at`: `z.string().refine(s => !Number.isNaN(Date.parse(s)))`). `nextFireAfter`: `at` → strictly-after-or-null; `every` → `new Date(from.getTime() + seconds*1000)`; `daily_at` → luxon `DateTime.fromJSDate(from, {zone:tz}).set({hour,minute,second:0,millisecond:0})`, add 1 day while `<= from`, `.toUTC().toJSDate()`; `cron` → `parseExpression(expr, {tz, currentDate: from}).next().toDate()`. `decideMissedRun`/`graceMsFor`/`nextIntervalSlot`/`nextSlotAfterMissed`: direct ports of Dart `MissedRunPolicy.decide/graceFor/nextSlot` (late = `now - due`; `late <= tolerance` → onTime; `late <= grace` → runNow; else recurring → skipToNext, one-off → pauseForReview; `nextSlotAfterMissed` = recurring ? next slot : null). Add `export * from "./triggers.js";` to `index.ts`.
- [ ] **Step 4: Run to verify pass.** Same command — Expected: all PASS. Then `pnpm --filter @ovid/shared build && cd /root/OvidAI/cloud && npx tsc --noEmit -p packages/shared/tsconfig.json`.
- [ ] **Step 5: Commit.** `git add cloud/packages/shared && git commit -m "feat(cloud): shared schedule trigger engine + missed-run policy (Dart port)"`

### Task 2: `@ovid/shared` — schedule/notification protocol + WS system ops

**Files:**
- Create: `cloud/packages/shared/src/schedules.ts`, `cloud/packages/shared/src/notifications.ts`
- Test: `cloud/packages/shared/src/schedules.test.ts`, `cloud/packages/shared/src/notifications.test.ts`
- Modify: `cloud/packages/shared/src/ws.ts` + `ws.test.ts` (additive variants), `cloud/packages/shared/src/index.ts`

**Interfaces:**
- Consumes: Task 1 (`ScheduleTrigger`, `scheduleTriggerSchema`).
- Produces:

```ts
// schedules.ts
export type ScheduleAutonomy = "safe" | "auto";                 // safe = read-only roster projection (default); auto = stored grants, explicit opt-in
export type ScheduleStatus = "pending" | "paused" | "completed" | "failed" | "cancelled";
export type ScheduleRunStatus = "running" | "retry_scheduled" | "succeeded" | "failed" | "skipped";
export interface ScheduleLastResult { status: "succeeded" | "failed" | "skipped"; code: string | null; message: string | null; finishedAt: string; ranLate: boolean; }
export interface ScheduleDto {
  id: string; sessionId: string; title: string; description: string;
  trigger: ScheduleTrigger; autonomy: ScheduleAutonomy; status: ScheduleStatus;
  pausedReason: string | null; maxRetries: number; nextRunAt: string | null;
  lastResult: ScheduleLastResult | null; createdAt: string; updatedAt: string;
}
export interface ScheduleRunDto {
  id: string; scheduleId: string; scheduledFor: string; runId: string | null;
  status: ScheduleRunStatus; attempt: number; ranLate: boolean;
  error: string | null; startedAt: string | null; finishedAt: string | null;
}
export interface ScheduleUpdate { title?: string; description?: string; trigger?: ScheduleTrigger;
  autonomy?: ScheduleAutonomy; maxRetries?: number; sessionId?: string; status?: "pending" | "paused"; }
export const scheduleCreateRequestSchema: z.ZodType<{ title: string; description: string; trigger: ScheduleTrigger;
  autonomy?: ScheduleAutonomy; maxRetries?: number; sessionId?: string }>;   // .strict(); title 1..200; description 1..4000; maxRetries int 0..3 default-able
export const scheduleUpdateRequestSchema: z.ZodType<ScheduleUpdate>;         // .strict(); .refine(≥1 key present)
export const scheduleDtoSchema: z.ZodType<ScheduleDto>;
export const scheduleRunDtoSchema: z.ZodType<ScheduleRunDto>;
export function schedulePrompt(title: string, description: string): string;  // `[schedule: ${title}] ${description}`
export type ScheduleSystemEventType = "schedule_created" | "schedule_updated" | "schedule_deleted"
  | "schedule_run_started" | "schedule_run_succeeded" | "schedule_run_failed" | "schedule_run_paused";
export interface SystemEvent { type: ScheduleSystemEventType; scheduleId: string; ts: string; payload: Record<string, unknown>; }
export const systemEventSchema: z.ZodType<SystemEvent>;
export function systemEvent(input: unknown): SystemEvent;                    // zod parse, throws
// DeviceDto
export interface DeviceDto { token: string; platform: "android"; }
export const deviceRegisterRequestSchema: z.ZodType<{ token: string; platform: "android" }>; // .strict(); token 1..4096

// notifications.ts — vocabulary ported from lib/core/background_notifications.dart
export type NotificationKind = "agentFinished" | "agentFailed" | "agentNeedsInput" | "agentNeedsApproval"
  | "jobDone" | "scheduleSucceeded" | "scheduleFailed";
export type NotificationChannelKey = "agent_updates" | "scheduler_results" | "background_status";
export function notificationChannelFor(kind: NotificationKind): NotificationChannelKey; // schedule* → scheduler_results; all others → agent_updates
export function chatRoute(sessionId: string): string;      // `/c/${sessionId}`
export function scheduleRoute(sessionId: string): string;  // `/schedule/${sessionId}`
export function notificationSummary(text: string, opts?: { max?: number }): string;    // Dart port, default max 140

// ws.ts — ADDITIVE variants only
// WsClientMsg += { op: "subscribe_system" } | { op: "unsubscribe_system" }
// WsServerMsg += { op: "system_subscribed" } | { op: "system"; event: SystemEvent }
```

- [ ] **Step 1: Write the failing tests.**
  - `notifications.test.ts` (ports of `test/background_notifications_test.dart` summary cases): `notificationSummary("```\ncode\n```")` → `"[code]"` (code fences → ` [code] `, trimmed); markdown links `[t](u)` → `t`; images `![a](b)` removed; `*_`#>` stripped; whitespace collapsed; a 200-char input caps at 140 ending in `…` cut at the last space boundary (assert `length <= 140` and the exact Dart algorithm output on one >140 fixture); `max: 48` honored. `notificationChannelFor("scheduleSucceeded") === "scheduler_results"`, `("agentNeedsApproval") === "agent_updates"`. Routes: `chatRoute("s1") === "/c/s1"`, `scheduleRoute("s1") === "/schedule/s1"`.
  - `schedules.test.ts`: `schedulePrompt("Morning", "check inbox") === "[schedule: Morning] check inbox"`; `scheduleCreateRequestSchema` rejects empty title, `maxRetries: 4`, unknown keys (strict); accepts minimal `{title, description, trigger}` with autonomy/maxRetries/sessionId absent; `scheduleUpdateRequestSchema` rejects `{}` (≥1 key) and `{status:"cancelled"}`; `systemEvent` round-trips a valid event and rejects unknown `type` / missing `ts`; `wsClientMsg({op:"subscribe_system"})` parses; `wsServerMsg({op:"system", event: <valid SystemEvent>})` parses; ALL previously-valid ws messages still parse (regression pin for additivity).
- [ ] **Step 2: Run to verify fail.** `cd /root/OvidAI/cloud && pnpm --filter @ovid/shared test` — Expected: FAIL.
- [ ] **Step 3: Implement.** `notificationSummary` is a line-by-line port of the Dart function (same regexes, same >60%-cut rule: `cut.lastIndexOf(" ")` used only when the space is past `max*0.6`). ws.ts: add the two client and two server variants to the existing discriminated unions (do NOT touch existing variants). Export both new modules from `index.ts`.
- [ ] **Step 4: Run to verify pass.** Same command — all PASS; `pnpm --filter @ovid/shared build`.
- [ ] **Step 5: Commit.** `git add cloud/packages/shared && git commit -m "feat(cloud): shared schedule/notification protocol + WS system ops (additive)"`

### Task 3: `@ovid/db` — schedules / schedule_runs / devices / notifications schema + migration

**Files:**
- Modify: `cloud/packages/db/src/schema.ts` (append four tables + row types), `cloud/packages/db/drizzle/` (generated `0001_*.sql` + journal)
- Test: `cloud/packages/db/src/schemaTables.test.ts` (new; follows `repos.test.ts` setup conventions — real `TEST_DATABASE_URL`, `migrate()` in `beforeAll`)

**Interfaces:**
- Consumes: `@ovid/shared` types (Task 1/2) for `$type<>` annotations only.
- Produces (tables in `schema.ts`, exported via `schema` namespace + row types):

```ts
export const schedules: /* pgTable "schedules" */;      // ScheduleRow
export const scheduleRuns: /* pgTable "schedule_runs" */; // ScheduleRunRow
export const devices: /* pgTable "devices" */;           // DeviceRow
export const notifications: /* pgTable "notifications" */; // NotificationRow
export type ScheduleRow = typeof schedules.$inferSelect;
export type ScheduleRunRow = typeof scheduleRuns.$inferSelect;
export type DeviceRow = typeof devices.$inferSelect;
export type NotificationRow = typeof notifications.$inferSelect;
```

Column map (drizzle pg; timestamps `timestamptz(3)` via the existing local helper; snake_case columns per P1 convention):
- `schedules`: `id char(36) PK`; `user_id text NOT NULL → users.uid`; `session_id char(36) NOT NULL → sessions.id` (bound or dedicated — always materialized at creation); `title text NOT NULL`; `description text NOT NULL`; `trigger jsonb NOT NULL $type<ScheduleTrigger>`; `autonomy text NOT NULL DEFAULT 'safe'`; `status text NOT NULL DEFAULT 'pending'`; `paused_reason text NULL`; `max_retries integer NOT NULL DEFAULT 0`; `next_run_at timestamptz(3) NULL`; `last_result jsonb NULL $type<ScheduleLastResult>`; `created_at`/`updated_at` NOT NULL defaultNow. Indexes: `(user_id)`, `(status, next_run_at)`.
- `schedule_runs`: `id char(36) PK`; `schedule_id char(36) NOT NULL → schedules.id ON DELETE CASCADE`; `scheduled_for timestamptz(3) NOT NULL` (the occurrence — claim key); `run_id char(36) NULL → runs.id`; `status text NOT NULL` (ScheduleRunStatus); `attempt integer NOT NULL DEFAULT 1`; `ran_late boolean NOT NULL DEFAULT false`; `retry_at timestamptz(3) NULL`; `error text NULL`; `auto_denied jsonb NOT NULL DEFAULT '[]'::jsonb $type<Array<{toolName:string;summary:string;ts:string}>>`; `started_at`/`finished_at`/`created_at`. **`uniqueIndex("schedule_runs_claim_uq").on(schedule_id, scheduled_for)` — the claim ledger (spec §8 idempotency key).** Indexes: `(schedule_id, id)`, `(status, retry_at)`, `(run_id)`.
- `devices`: `token text PK` (FCM registration token); `user_id text NOT NULL → users.uid`; `platform text NOT NULL DEFAULT 'android'`; `created_at`/`updated_at`. Index `(user_id)`.
- `notifications`: `id char(36) PK`; `user_id text NOT NULL → users.uid`; `device_token text NULL` (null = no-device record); `kind text NOT NULL`; `channel text NOT NULL`; `title text NOT NULL`; `body text NOT NULL`; `route text NOT NULL`; `data jsonb NOT NULL $type<Record<string,string>>`; `status text NOT NULL DEFAULT 'sent'` (`sent|failed|skipped_no_devices`); `error text NULL`; `created_at`. Index `(user_id)`.

- [ ] **Step 1: Write the failing test** `schemaTables.test.ts`: after `migrate()`, (a) insert a minimal `schedules` row (needs `users.ensure` + `sessions.create` first) and read it back — `trigger` jsonb round-trips a `{kind:"every",seconds:300}` object, `status==='pending'`, `autonomy==='safe'`, `maxRetries===0`; (b) insert two `schedule_runs` rows with the SAME `(scheduleId, scheduledFor)` → second insert rejects with Postgres unique violation (`err.code === "23505"`) — the claim-ledger pin; (c) `devices.upsert`-style raw insert + `notifications` insert round-trip; (d) delete the schedule → its `schedule_runs` rows cascade to 0.
- [ ] **Step 2: Run to verify fail.** `cd /root/OvidAI/cloud && TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres pnpm --filter @ovid/db test` — Expected: FAIL (tables missing).
- [ ] **Step 3: Add the tables to `schema.ts`** exactly per the column map; regenerate the migration: `cd /root/OvidAI/cloud/packages/db && pnpm exec drizzle-kit generate` (produces `drizzle/0001_*.sql` + journal entry — commit the generated files as-is; `migrate()` picks them up). Export the four row types from `schema.ts` and re-export the types from `index.ts` alongside the existing `SessionRow` etc. (table objects stay behind the `schema` namespace — same pattern as P1).
- [ ] **Step 4: Run to verify pass.** Same test command — all PASS (existing `repos.test.ts`/`migrate-cli.test.ts` stay green: migration is additive).
- [ ] **Step 5: Commit.** `git add cloud/packages/db && git commit -m "feat(cloud): schedules + schedule_runs claim ledger + devices + notifications schema"`

### Task 4: `@ovid/db` — schedule/device/notification repos

**Files:**
- Create: `cloud/packages/db/src/scheduleRepos.ts`, `cloud/packages/db/src/deviceRepos.ts`
- Test: `cloud/packages/db/src/scheduleRepos.test.ts`, `cloud/packages/db/src/deviceRepos.test.ts`
- Modify: `cloud/packages/db/src/index.ts` (export both + row/settleable types)

**Interfaces:**
- Consumes: Task 3 tables; P1 `newId`, `users`, `sessions`, `runs` repos; `ScheduleTrigger`/`ScheduleLastResult` from `@ovid/shared`.
- Produces:

```ts
// scheduleRepos.ts
export type Tx = Parameters<Parameters<Db["transaction"]>[0]>[0];
export type DbOrTx = Db | Tx;   // every method below accepts either (transaction-safe)
export const schedules: {
  create(db: Db, input: { userId: string; sessionId: string; title: string; description: string;
    trigger: ScheduleTrigger; autonomy: string; maxRetries: number; nextRunAt: Date | null }): Promise<ScheduleRow>;
  get(db: DbOrTx, scheduleId: string, userId: string): Promise<ScheduleRow | null>;  // owner-scoped: null on wrong owner
  getById(db: DbOrTx, scheduleId: string): Promise<ScheduleRow | null>;              // internal (worker), NOT owner-scoped
  list(db: Db, userId: string, opts: { limit: number; cursor?: string | null; includeCancelled?: boolean }):
    Promise<{ rows: ScheduleRow[]; nextCursor: string | null }>;                     // keyset (updatedAt, id) desc — same cursor format as sessions.list ("<ms>~<id>")
  listPendingWithNextRun(db: Db): Promise<ScheduleRow[]>;                            // status='pending' AND next_run_at IS NOT NULL (boot mirror resync)
  claimDue(db: DbOrTx, now: Date, limit: number): Promise<ScheduleRow[]>;            // SQL pinned in Step 3
  update(db: DbOrTx, scheduleId: string, patch: Partial<{ title: string; description: string;
    trigger: ScheduleTrigger; autonomy: string; maxRetries: number; sessionId: string;
    status: string; pausedReason: string | null; nextRunAt: Date | null;
    lastResult: ScheduleLastResult | null }>): Promise<ScheduleRow | null>;          // also bumps updatedAt=now; null = row gone
};
export interface SettleableRunRow extends ScheduleRunRow {
  runStatus: string | null; runError: string | null;
  scheduleStatus: string; scheduleTitle: string; scheduleUserId: string;
  scheduleSessionId: string; scheduleTrigger: ScheduleTrigger; scheduleMaxRetries: number;
}
export const scheduleRuns: {
  claim(db: DbOrTx, input: { scheduleId: string; scheduledFor: Date; runId: string; ranLate: boolean }):
    Promise<ScheduleRunRow | null>;   // INSERT status='running', startedAt=now … ON CONFLICT (schedule_id, scheduled_for) DO NOTHING RETURNING *; null = lost the claim
  recordSkip(db: DbOrTx, input: { scheduleId: string; scheduledFor: Date }): Promise<ScheduleRunRow | null>; // same conflict rule, status='skipped'
  claimRetryDue(db: DbOrTx, scheduleId: string, now: Date): Promise<ScheduleRunRow | null>; // oldest status='retry_scheduled' AND retry_at<=now
  claimRetry(db: DbOrTx, scheduleRunId: string, runId: string): Promise<ScheduleRunRow | null>; // UPDATE … SET status='running', run_id, started_at=now, retry_at=NULL WHERE id AND status='retry_scheduled' RETURNING *; null = lost race
  scheduleRetry(db: DbOrTx, scheduleRunId: string, retryAt: Date): Promise<void>;    // attempt = attempt+1, status='retry_scheduled', retry_at
  finish(db: DbOrTx, scheduleRunId: string, status: "succeeded" | "failed", error?: string | null): Promise<void>; // finishedAt=now
  getByRunId(db: DbOrTx, runId: string): Promise<ScheduleRunRow | null>;
  appendAutoDenied(db: DbOrTx, scheduleRunId: string, entry: { toolName: string; summary: string; ts: string }): Promise<void>; // jsonb array_append
  listSettleable(db: DbOrTx, opts: { staleBefore: Date; limit: number }): Promise<SettleableRunRow[]>; // SQL pinned in Step 3
  listForSchedule(db: Db, scheduleId: string, opts: { limit: number; beforeId?: string | null }):
    Promise<{ rows: ScheduleRunRow[]; nextCursor: string | null }>;                  // newest-first keyset by id (messages.page pattern)
};
// deviceRepos.ts
export const devices: {
  upsert(db: Db, input: { token: string; userId: string; platform: string }): Promise<DeviceRow>; // ON CONFLICT (token) DO UPDATE user_id/platform/updated_at (token re-binds to newest user)
  removeByToken(db: Db, token: string, userId: string): Promise<void>;               // logout unbind / unregistered-token cleanup
  listForUser(db: Db, userId: string): Promise<DeviceRow[]>;
};
export const notifications: {
  record(db: Db, input: { userId: string; deviceToken: string | null; kind: string; channel: string;
    title: string; body: string; route: string; data: Record<string, string>; status: string; error?: string | null }): Promise<NotificationRow>;
};
```

- [ ] **Step 1: Write the failing tests** (real `TEST_DATABASE_URL`, fresh uids per test, no drops — gateway convention). `scheduleRepos.test.ts`: (a) `claim` twice for same `(scheduleId, scheduledFor)` → first returns a row with `status:'running'`, second returns `null` (ledger race without concurrency); (b) TRUE concurrency: two overlapping `db.transaction` calls each doing `claimDue(now,10)` then `claim` on the same due schedule → exactly one row exists afterwards (SKIP LOCKED pin: the second tx sees zero due rows or loses the claim); (c) `claimDue` ignores `status!=='pending'`, ignores `nextRunAt > now`, and INCLUDES a pending schedule whose `nextRunAt` is null but has a `retry_scheduled` run with `retryAt <= now`; (d) `claimRetry` on a non-`retry_scheduled` row → null; `scheduleRetry` bumps attempt 1→2 and sets status/retryAt; (e) `listSettleable` returns a `running` schedule_run joined to a `completed` run (with schedule fields populated), excludes one whose run is still `running`, and includes a stale orphan (`runId` null, `startedAt < staleBefore`); (f) `list` cursor: page 1 of 2 → `nextCursor` non-null, page 2 with cursor → remainder, no overlap; cancelled excluded unless `includeCancelled`. `deviceRepos.test.ts`: upsert twice same token different user → one row, latest userId; `removeByToken` with wrong userId → row survives; `notifications.record` round-trips jsonb `data`.
- [ ] **Step 2: Run to verify fail.** `TEST_DATABASE_URL=… pnpm --filter @ovid/db test` — Expected: FAIL (exports missing).
- [ ] **Step 3: Implement.** Pin these two SQL shapes (drizzle or `db.$client.unsafe` — builder choice, semantics fixed):
  - `claimDue`: `SELECT * FROM schedules WHERE status='pending' AND (next_run_at <= $1 OR id IN (SELECT schedule_id FROM schedule_runs WHERE status='retry_scheduled' AND retry_at <= $1)) ORDER BY next_run_at ASC NULLS LAST LIMIT $2 FOR UPDATE SKIP LOCKED`.
  - `listSettleable`: `SELECT sr.*, r.status AS run_status, r.last_error AS run_error, s.status AS schedule_status, s.title AS schedule_title, s.user_id AS schedule_user_id, s.session_id AS schedule_session_id, s.trigger AS schedule_trigger, s.max_retries AS schedule_max_retries FROM schedule_runs sr JOIN schedules s ON s.id = sr.schedule_id LEFT JOIN runs r ON r.id = sr.run_id WHERE sr.status='running' AND (r.status IN ('completed','failed','cancelled') OR (sr.started_at < $1 AND (sr.run_id IS NULL OR r.id IS NULL OR r.status='queued'))) ORDER BY sr.started_at ASC LIMIT $2` (default limit 100).
  Everything else follows the P1 repo idioms (conditional UPDATE … RETURNING for races, `newId()` for ids, keyset cursors copied from `sessions.list`/`messages.page`). Export from `index.ts`.
- [ ] **Step 4: Run to verify pass.** Same command — all PASS (whole `@ovid/db` suite green).
- [ ] **Step 5: Commit.** `git add cloud/packages/db && git commit -m "feat(cloud): schedule claim-ledger + due-scan + settle repos, devices, notifications"`

### Task 5: `@ovid/db` — scheduleService (CRUD domain logic, tier gate, dedicated sessions)

**Files:**
- Create: `cloud/packages/db/src/scheduleService.ts`
- Test: `cloud/packages/db/src/scheduleService.test.ts`
- Modify: `cloud/packages/db/src/index.ts`

**Interfaces:**
- Consumes: Task 4 repos; P1 `users.ensure` / `sessions.create` / `sessions.get`; Task 1 trigger engine.
- Produces (single choke point for BOTH the gateway routes and the agent tools):

```ts
export class ScheduleError extends Error {
  readonly code: "not_found" | "tier_required" | "invalid_trigger" | "bad_request";
  constructor(code: ScheduleError["code"], message: string);
}
export interface CreateScheduleArgs { userId: string; title: string; description: string;
  trigger: ScheduleTrigger; autonomy?: ScheduleAutonomy; maxRetries?: number;
  sessionId?: string | null; clock?: () => Date; }
export function createSchedule(db: Db, args: CreateScheduleArgs): Promise<ScheduleRow>;
export interface UpdateScheduleArgs { userId: string; scheduleId: string; patch: ScheduleUpdate; clock?: () => Date; }
export function updateSchedule(db: Db, args: UpdateScheduleArgs): Promise<ScheduleRow>;
export function cancelSchedule(db: Db, args: { userId: string; scheduleId: string }): Promise<void>; // soft delete: status='cancelled'
```

Behavior rules (all pinned by tests):
- `createSchedule`: fetches tier via `users.ensure(db, userId, null)` (idempotent, never clobbers email). `trigger.kind === "cron" && tier === "free"` → `ScheduleError("tier_required")` (Review Focus 4). `maxRetries` must be integer 0–3 (caller zod usually caught it; re-check → `bad_request`). Session: `sessionId` given → `sessions.get(db, sessionId, userId)`, null → `ScheduleError("not_found", "Session not found.")`; omitted/null → dedicated session `sessions.create(db, userId, title)`. `nextRunAt`: `at` → `new Date(trigger.at)`, rejected with `invalid_trigger` when `at <= now - ONE_OFF_GRACE_MS` ("at is more than 24 h in the past"); past-within-grace is ALLOWED (first tick fires it `ranLate` per policy); else → `nextFireAfter(trigger, now)`, null → `invalid_trigger`. Row: `status:'pending'`, `autonomy: args.autonomy ?? "safe"`, `maxRetries: args.maxRetries ?? 0`.
- `updateSchedule`: owner-scoped fetch → `not_found`. `status` `cancelled`/`completed`/`failed` → `bad_request` ("Schedule is not editable."). Empty patch → `bad_request`. Trigger change to `cron` re-checks tier. `status:"paused"` → `pausedReason:"user"`, `nextRunAt` KEPT (informational; `claimDue` filters on `status='pending'` so it cannot fire). `status:"pending"` (resume, valid only from `paused`; Dart `resumeStopped` port): recurring → `nextRunAt = nextFireAfter(trigger, now)`; one-off `at` in the future → `at`; one-off `at` in the past → `nextRunAt = now` (fires on the next tick as `onTime` — Dart "a missed one runs on the next tick"); `pausedReason` cleared. Trigger change while `pending` → recompute `nextRunAt` from now. `sessionId` rebind → ownership-checked like create.
- `cancelSchedule`: owner-scoped; idempotent (already-cancelled → no-op, no throw); sets `status:'cancelled'`, `pausedReason:null`.
- [ ] **Step 1: Write the failing tests** (real db): cron on `tier:'free'` user → throws `ScheduleError` code `tier_required`; same user with tier manually set to `'pro'` (`UPDATE users SET tier='pro'`) → creates OK; unbound create → a NEW session exists with `title === schedule.title` and `schedule.sessionId` points at it; bound create with someone else's sessionId → `not_found`; `at` 25 h past → `invalid_trigger`; `at` 3 h past → created with `nextRunAt === at`; `every 300` → `nextRunAt ≈ now+300s` (injected clock, exact); `maxRetries: 4` → `bad_request`; update `status:'paused'` then `'pending'` on a `daily_at 09:00 UTC` schedule at clock 12:00Z → `nextRunAt` = tomorrow 09:00Z; resume of past one-off → `nextRunAt === now`; update on cancelled → `bad_request`; cancel is idempotent; wrong-owner update/cancel → `not_found`.
- [ ] **Step 2: Run to verify fail.** `TEST_DATABASE_URL=… pnpm --filter @ovid/db test` — FAIL.
- [ ] **Step 3: Implement** per the rules above; export from `index.ts`.
- [ ] **Step 4: Run to verify pass.** All `@ovid/db` green.
- [ ] **Step 5: Commit.** `git add cloud/packages/db && git commit -m "feat(cloud): schedule service — tier gate, dedicated sessions, next-run computation"`

### Task 6: `@ovid/events` SystemBus + `@ovid/queue` schedules mirror queue

**Files:**
- Create: `cloud/packages/events/src/systemBus.ts`
- Test: `cloud/packages/events/src/systemBus.test.ts`
- Modify: `cloud/packages/events/src/index.ts`; `cloud/packages/queue/src/queues.ts` (+ `queues.test.ts` additive cases), `cloud/packages/queue/package.json` (add `"@ovid/shared": "workspace:*"` if absent)

**Interfaces:**
- Consumes: `SystemEvent`/`systemEventSchema` (Task 2); P1 `createQueues`/`withBlockingSafeRetries` internals.
- Produces:

```ts
// @ovid/events — systemBus.ts (channel key: `user:${uid}:system`)
export interface SystemBus {
  publish(uid: string, event: SystemEvent): Promise<void>;                        // PUBLISH JSON
  subscribe(uid: string, onEvent: (e: SystemEvent) => void): Promise<() => Promise<void>>; // dedicated duplicate() connection, same hardening as eventLog.subscribe: swallow connection errors, JSON.parse + systemEventSchema.safeParse with skip-on-garbage, contained consumer throws
}
export function createRedisSystemBus(redis: Redis): SystemBus;

// @ovid/queue — additive to queues.ts
export const SCHEDULES = "schedules";
export const SCHEDULE_FIRE_JOB_NAME = "schedule-fire";
export interface ScheduleFireJob { scheduleId: string; scheduledFor: string; }    // scheduledFor = ISO of the occurrence
export const scheduleFireJobSchema: z.ZodType<ScheduleFireJob>;
export interface ScheduleRunRef { scheduleId: string; scheduleRunId: string; autonomy: "safe" | "auto"; }
// AgentRunJob gains the OPTIONAL field `schedule?: ScheduleRunRef` (old payloads still parse — additivity pin)
// QueueServices gains `schedules: Queue<ScheduleFireJob>` (createQueues builds it with the same connection handling; defaultJobOptions {})
export function scheduleMirrorJobId(scheduleId: string, scheduledForMs: number): string; // `${scheduleId}:${scheduledForMs}`
export function addScheduleMirrorJob(queues: QueueServices, scheduleId: string, nextRunAt: Date, now: Date): Promise<void>;
// add(SCHEDULE_FIRE_JOB_NAME, {scheduleId, scheduledFor: nextRunAt.toISOString()}, { jobId: scheduleMirrorJobId(...), delay: Math.max(1, nextRunAt.getTime() - now.getTime()) }) — deterministic jobId makes re-adds idempotent
export function createScheduleFireWorker(connection: ConnectionOptions, processor: Processor<ScheduleFireJob>, opts?: { concurrency?: number }): Worker<ScheduleFireJob>;
```

- [ ] **Step 1: Write the failing tests.** `systemBus.test.ts` (real `TEST_REDIS_URL`): publish→subscribe delivers the event; a subscriber on a different uid receives nothing; garbage published raw on the channel (`redis.publish("user:x:system", "{oops")`) does NOT crash the listener and a valid event published afterwards still arrives; unsubscribe stops delivery and quits the connection (assert `PUBSUB CHANNELS user:*` drains — e2e pattern). `queues.test.ts` additions: `createQueues({url})` now exposes `schedules` with name `schedules`; `agentRunJobSchema` still parses a P1 payload WITHOUT `schedule` AND one WITH `{schedule:{scheduleId,scheduleRunId,autonomy:"safe"}}`; `scheduleMirrorJobId("s",123) === "s:123"`; `addScheduleMirrorJob` with `nextRunAt = now+5000` produces a delayed job (real redis: `getJobCounts().delayed === 1`, job id = mirror id; second identical add → still 1); a past `nextRunAt` → delay clamps to ≥1 (job immediately waitable). Cleanup: obliterate the `schedules` queue in `afterAll` (P1 discipline).
- [ ] **Step 2: Run to verify fail.** `TEST_REDIS_URL=redis://127.0.0.1:6390 pnpm --filter @ovid/events test && pnpm --filter @ovid/queue test` — FAIL.
- [ ] **Step 3: Implement** per signatures. `systemBus.ts` copies the `eventLog.subscribe` connection/teardown discipline (dedicated duplicate, error swallow, closed-flag unsubscribe). queues.ts: extend, don't restructure; keep the `attempts:1` ruling comment intact for agent-runs; `schedules` queue jobs use BullMQ defaults (delay per add).
- [ ] **Step 4: Run to verify pass.** Both suites green; `pnpm -r build` (gateway/worker still compile against the extended `QueueServices`).
- [ ] **Step 5: Commit.** `git add cloud/packages/events cloud/packages/queue && git commit -m "feat(cloud): user system bus + schedules mirror queue (additive)"`

### Task 7: `@ovid/worker` — notifier, FCM push, unattended-approval seam

**Files:**
- Create: `cloud/apps/worker/src/notify.ts`, `cloud/apps/worker/src/unattended.ts`
- Test: `cloud/apps/worker/src/notify.test.ts`, `cloud/apps/worker/src/unattended.test.ts`
- Modify: `cloud/apps/worker/src/index.ts` (export both), `cloud/apps/worker/package.json` (add `"firebase-admin": "^14.5.0"` — same pin as gateway)

**Interfaces:**
- Consumes: Task 4 repos (`devices`, `notifications`, `scheduleRuns.getByRunId/appendAutoDenied`, `sessions.get`), Task 2 notification vocabulary, `SystemBus`.
- Produces:

```ts
// notify.ts
export interface PushMessage { token: string; notification: { title: string; body: string };
  data: Record<string, string>; androidChannelId: string; } // androidChannelId = `ovid_${channelKey}.chime.v1` (Dart NotificationChannelIds formula, sound default chime)
export type PushOutcome = { ok: true } | { ok: false; code: "unregistered" | "invalid" | "error"; error?: string };
export interface PushSender { send(msg: PushMessage): Promise<PushOutcome>; }
export function createFcmPushSender(): PushSender;   // lazy getMessaging() (ADC via GOOGLE_APPLICATION_CREDENTIALS); credentials missing/unreadable → every send resolves {ok:false,code:"error"} and logs ONCE (never throws, never crashes the worker); messaging error code "registration-token-not-registered"/"invalid-registration-token" → {ok:false,code:"unregistered"}
export interface NotifierDeps { db: Db; push: PushSender; clock?: () => Date; }
export interface Notifier {
  notifyScheduleSucceeded(a: { userId: string; scheduleId: string; sessionId: string; title: string; summary: string | null }): Promise<void>;
  notifyScheduleFailed(a: { userId: string; scheduleId: string; sessionId: string; title: string; code: string; error: string | null }): Promise<void>; // code "key_not_minted" swaps in KEY_NOT_MINTED_PUSH_BODY
  notifyApprovalRequest(a: { userId: string; sessionId: string; sessionTitle: string; summary: string; question: boolean }): Promise<void>;
}
export function createNotifier(deps: NotifierDeps): Notifier;
export const KEY_NOT_MINTED_PUSH_BODY = "Your account needs a one-time sign-in before scheduled tasks can run. Open Ovid once to fix this."; // ledger Q5 pinned copy
// notifications.ts behavior (all pinned by tests):
//  title/body are Dart ports: succeeded → title `Scheduled task done: ${notificationSummary(title,{max:48})}`, body = summary blank ? "Tap to see the result." : notificationSummary(summary);
//  failed → title `Scheduled task failed: ${notificationSummary(title,{max:48})}`, body = code==="key_not_minted" ? KEY_NOT_MINTED_PUSH_BODY : notificationSummary(error ?? "Unknown error");
//  approval → question ? ("Ovid has a question", kind agentNeedsInput) : ("Ovid needs your approval", kind agentNeedsApproval); body = `${sessionTitle} — ${notificationSummary(summary)}` (empty title → no " — " prefix), route chatRoute(sessionId).
//  schedule notifications: route = scheduleRoute(sessionId); data = { kind, channel: notificationChannelFor(kind), route, sessionId, scheduleId, ts };
//  fan-out: devices.listForUser → one push.send per device; outcome unregistered → devices.removeByToken + record row status "failed" error "unregistered"; other failures → record "failed"; success → record "sent"; ZERO devices → one record row { deviceToken: null, status: "skipped_no_devices" } and NO send.
//  The notifier NEVER throws (all failures caught + console.error("[notify] …")) and never affects run/settle bookkeeping (Dart onResult contract).

// unattended.ts — the P3 approvals seam (see the P3 seam note in the header)
export const UNATTENDED_APPROVAL_TIMEOUT_MS = 120_000; // spec §6.2 default-deny timeout
export interface UnattendedApprovalHook {
  isUnattendedRun(runId: string): Promise<boolean>;    // scheduleRuns.getByRunId(runId) !== null
  onApprovalRequested(runId: string, req: { toolName: string; summary: string; question?: boolean }): Promise<void>; // unattended → notifier.notifyApprovalRequest (session title via sessions.get) ; attended → no-op
  onApprovalAutoDenied(runId: string, req: { toolName: string; summary: string }): Promise<void>; // unattended → scheduleRuns.appendAutoDenied(...) ; attended → no-op
}
export function createUnattendedApprovalHook(deps: { db: Db; notifier: Notifier }): UnattendedApprovalHook;
```

- [ ] **Step 1: Write the failing tests** (real db; `PushSender` stub capturing messages — NO firebase import in tests except a construction smoke of `createFcmPushSender()` with `GOOGLE_APPLICATION_CREDENTIALS` unset asserting `send` resolves `{ok:false,code:"error"}` and does not throw). `notify.test.ts`: (a) success copy: title `Scheduled task done: Morning report` (48-cap path with a 60-char title → ends `…`), body `Tap to see the result.` when summary null; summary with markdown → stripped per `notificationSummary`; route `/schedule/<sid>`; data.kind `scheduleSucceeded`; data.channel `scheduler_results`; androidChannelId `ovid_scheduler_results.chime.v1`; one `notifications` row status `sent` per device (2 devices → 2 rows, 2 sends). (b) failure copy incl. `KEY_NOT_MINTED_PUSH_BODY` for code `key_not_minted` (Review Focus: Q5) and `notificationSummary(error)` otherwise; kind `scheduleFailed`. (c) unregistered token → `devices.removeByToken` effect (row gone) + record status `failed` error `unregistered`; second device on same user still sent. (d) zero devices → exactly one record `{deviceToken:null,status:"skipped_no_devices"}`, zero sends. (e) `push.send` throwing (stub rejects) → notifier resolves (never throws) + record `failed`. (f) approval: question=true → kind `agentNeedsInput` title `Ovid has a question`; false → `agentNeedsApproval`; body `Sess — summary`; route `/c/<sid>`. `unattended.test.ts`: run created via `runs.create` on a plain session → `isUnattendedRun` false, hooks are no-ops (no notification rows); schedule_run claimed with that runId → true; `onApprovalRequested` records a notification (agentNeedsApproval) ; `onApprovalAutoDenied` appends to `auto_denied` jsonb (read back: `[{toolName,summary,ts}]`).
- [ ] **Step 2: Run to verify fail.** `TEST_DATABASE_URL=… pnpm --filter @ovid/worker test` — FAIL.
- [ ] **Step 3: Implement** per signatures; `createFcmPushSender` uses `getMessaging()` from `firebase-admin/messaging` lazily inside `send` (first call initializes via ADC); export both modules from `index.ts`.
- [ ] **Step 4: Run to verify pass.** Worker suite green; `pnpm --filter @ovid/worker build`.
- [ ] **Step 5: Commit.** `git add cloud/apps/worker && git commit -m "feat(cloud): FCM notifier (Dart copy port) + unattended approval hook seam"`

### Task 8: `@ovid/worker` — occurrence firing + 15 s tick

**Files:**
- Create: `cloud/apps/worker/src/schedulerTick.ts`
- Test: `cloud/apps/worker/src/schedulerTick.test.ts`
- Modify: `cloud/apps/worker/src/index.ts`

**Interfaces:**
- Consumes: Task 4 repos (`schedules.claimDue/getById/update`, `scheduleRuns.claim/claimRetryDue/claimRetry/recordSkip`, `runs.activeForSession/create`, `messages.append`, `users.ensure`), Task 1 policy, Task 2 `schedulePrompt`/`SystemEvent`, Task 6 `addScheduleMirrorJob`, `@ovid/queue` (`AGENT_RUN_JOB_NAME`, `QueueServices`), `SystemBus`.
- Produces:

```ts
export interface SchedulerDeps { db: Db; queues: QueueServices; system: SystemBus; clock?: () => Date; }
export type FireOutcome = "fired" | "retry_fired" | "skipped_next" | "paused" | "deferred_busy" | "duplicate_claim" | "not_due" | "not_found";
export function fireScheduleOccurrence(deps: SchedulerDeps, scheduleId: string, opts?: { expectedScheduledFor?: Date | null }): Promise<FireOutcome>;
export interface TickReport { fired: number; retried: number; skipped: number; paused: number; deferred: number; duplicates: number; }
export function runSchedulerTick(deps: SchedulerDeps): Promise<TickReport>;
export interface SchedulerLoopDeps extends SchedulerDeps, SettleDeps {}   // SettleDeps from Task 9
export function startSchedulerLoop(deps: SchedulerLoopDeps, opts?: { intervalMs?: number }): { stop(): void };
export const SCHEDULER_TICK_MS = 15_000;
export const TICK_BATCH_LIMIT = 50;
```

Algorithm for `fireScheduleOccurrence` — ONE db transaction per schedule, then post-commit side effects (the exact order is the contract; tests pin the outcomes):
1. `db.transaction`: `SELECT … FROM schedules WHERE id=$1 AND status='pending' FOR UPDATE SKIP LOCKED` (reuse `claimDue`-style locking via a dedicated `getById`-with-lock or raw SQL — locked row or return `"not_found"`/`"not_due"` when absent/not pending). If `expectedScheduledFor` is given and (`nextRunAt` null or `|nextRunAt − expected| > 1 ms`) → `"not_due"` (mirror raced the tick; Postgres already advanced).
2. **Retry pass first**: `claimRetryDue(scheduleId, now)` → if a row exists: busy check (`runs.activeForSession` non-null → rollback, `"deferred_busy"`); else append prompt message + `runs.create`, then `claimRetry(srId, run.id)` (null → `"duplicate_claim"`); commit → enqueue (step 5) → `"retry_fired"`.
3. **New-occurrence pass**: `nextRunAt` null or `> now` → `"not_due"`. Busy check → `"deferred_busy"` (row untouched — NO policy applied while the session is busy; Dart parity: busy defers, policy applies only when free). `decision = decideMissedRun(trigger, nextRunAt, now)`:
   - `onTime`/`runNow`: append prompt message (`role:"user"`, content `schedulePrompt(title, description)`), `runs.create`, `scheduleRuns.claim({scheduleId, scheduledFor: nextRunAt, runId: run.id, ranLate: decision === "runNow"})` — null → rollback message/run, `"duplicate_claim"` (Review Focus 1 backstop). Advance: recurring → `nextRunAt = trigger.kind === "every" ? nextIntervalSlot(scheduledFor, seconds, now) : nextFireAfter(trigger, now)`; one-off → `nextRunAt = null`. Commit → enqueue → `system.publish(uid, {type:"schedule_run_started", scheduleId, ts, payload:{scheduleRunId, runId, scheduledFor, ranLate, attempt}})` → `addScheduleMirrorJob` for the new `nextRunAt` → `"fired"`.
   - `skipToNext`: `recordSkip({scheduleId, scheduledFor: due})` (conflict → `"duplicate_claim"`); `update` `nextRunAt = nextSlotAfterMissed(trigger, due, now)`. Commit → publish `{type:"schedule_updated", payload:{reason:"skipped_missed", skippedFor: dueISO, nextRunAt}}` → mirror → `"skipped_next"`.
   - `pauseForReview`: `update` `{status:"paused", pausedReason:"missed_beyond_grace"}` (`nextRunAt` KEPT). Commit → publish `{type:"schedule_run_paused", payload:{reason:"missed_beyond_grace", scheduledFor: dueISO}}` → `"paused"`.
4. `runSchedulerTick`: short tx `claimDue(now, TICK_BATCH_LIMIT)` → commit → sequential `fireScheduleOccurrence(deps, row.id, {expectedScheduledFor: row.nextRunAt})` per row; tally outcomes into `TickReport`. Returns the report; individual fire errors are caught, `console.error("[scheduler] fire failed", …)`, and counted as nothing (next tick retries — Postgres is authoritative).
5. Enqueue (post-commit, both passes): `tier = (await users.ensure(db, schedule.userId, null)).tier`; `queues.agentRuns.add(AGENT_RUN_JOB_NAME, { runId: run.id, sessionId: schedule.sessionId, userId: schedule.userId, prompt: schedulePrompt(title, description), schedule: { scheduleId, scheduleRunId, autonomy: schedule.autonomy as "safe"|"auto" } }, { jobId: run.id, priority: tier === "free" ? 2 : 1 })`. **Add failure is caught + logged loudly (`[scheduler] enqueue failed`), never rethrown**: the run row stays `queued` and settle's stale path (Task 9, Review Focus 2) recovers the occurrence.
6. `startSchedulerLoop`: overlap-guarded `setInterval` (boolean flag, Dart `_ticking` port; a pass still running when the next fires is SKIPPED), each pass `await settleScheduleRuns(deps); await runSchedulerTick(deps);` inside try/catch (`console.error("[scheduler] pass failed", …)`); `stop()` clears the interval; interval `.unref()`; `opts.intervalMs ?? SCHEDULER_TICK_MS`.

- [ ] **Step 1: Write the failing tests** (`schedulerTick.test.ts`; real db + injected clock; `queues` = capturing stub with both `agentRuns.add` and `schedules.add` (extend the gateway `stubQueues` idea locally); `system` = capturing SystemBus stub). Cases: (a) **on-time fire**: `every 300` created at clock T0 (via `createSchedule`); tick at T0+300s → report `{fired:1,…0}`; exactly one `schedule_runs` row `{status:'running', ranLate:false, attempt:1}`; prompt message row content `[schedule: Morning] check inbox`; agent-runs add captured with `jobId===run.id`, payload `schedule.autonomy==='safe'`, priority 2 (free user); system publish `schedule_run_started`; mirror add captured with `jobId === scheduleMirrorJobId(id, nextRunAtMs)` and delay ≈ 300 s; schedule `nextRunAt === T0+600s` (interval anchored at the occurrence: fire at T0+900s instead → next = T0+1200s, NOT T0+1200+… — pin `nextIntervalSlot` anchoring). (b) **runNow/late**: tick at T0+300s+60s (late 60 s ≤ 2 min tolerance) → `ranLate:false` `onTime`; second schedule ticked 5 min late on `every 1800` (grace 900 s) → `ranLate:true`. (c) **skipToNext**: `every 300` (grace 150 s) ticked 7 h late → outcome `skipped_next`, schedule_run `status:'skipped'`, `nextRunAt` = first slot after now, ZERO agent-runs adds, system `schedule_updated` with `reason:'skipped_missed'`. (d) **pauseForReview**: one-off `at` ticked 25 h late → `paused`, schedule `{status:'paused', pausedReason:'missed_beyond_grace'}`, system `schedule_run_paused`, no run/message rows created. (e) **duplicate fire race (Review Focus 1)**: `await Promise.all([fire(deps,id), fire(deps,id)])` on a due schedule → outcomes are one `fired` + one of `duplicate_claim`/`not_due`; exactly ONE schedule_run, ONE runs row, ONE queue add. (f) **deferred busy**: an active run seeded on the session (`runs.create`) → tick returns `deferred:1`, nextRunAt untouched, nothing claimed; after `runs.finish(completed)` the next tick fires. (g) **retry fire**: schedule_run put in `retry_scheduled` (via `scheduleRuns.scheduleRetry`) with `retryAt <= now`, schedule `nextRunAt` null (one-off) → tick → `retried:1`, NEW run row + message, schedule_run `status:'running'`, `run_id` updated, attempt still 2, `retry_at` null. (h) **expectedScheduledFor stale mirror**: fire with `expectedScheduledFor` = an old occurrence → `not_due`, no side effects. (i) **enqueue failure**: stub `agentRuns.add` rejects once → outcome still `fired`, error logged, run row `queued` (settle recovers — cross-ref Task 9). (j) `runSchedulerTick` with 3 due schedules returns the summed report; `startSchedulerLoop` with `intervalMs: 5` + a counting clock → ≥2 passes after ~30 ms real wait, `stop()` ends it (bounded, <2 s).
- [ ] **Step 2: Run to verify fail.** `TEST_DATABASE_URL=… TEST_REDIS_URL=… pnpm --filter @ovid/worker test` — FAIL.
- [ ] **Step 3: Implement** exactly per the algorithm above. Note `SchedulerLoopDeps` references Task 9's `SettleDeps` — if executing strictly in order, import the type from `./schedulerSettle.js` (Task 9 creates it next; a one-task forward type import is fine because `pnpm -r build` runs after both land — if `tsc` blocks mid-task, stub the loop's settle call behind `deps.settleScheduleRuns ?? noop` until Task 9 and remove the stub there; do NOT weaken any other contract).
- [ ] **Step 4: Run to verify pass.** Worker suite green.
- [ ] **Step 5: Commit.** `git add cloud/apps/worker && git commit -m "feat(cloud): scheduler tick — due scan, claim ledger firing, missed-run policy, defer-when-busy"`

### Task 9: `@ovid/worker` — settle reconciler (results, retries, pause, transcript, push)

**Files:**
- Create: `cloud/apps/worker/src/schedulerSettle.ts`
- Test: `cloud/apps/worker/src/schedulerSettle.test.ts`
- Modify: `cloud/apps/worker/src/index.ts`

**Interfaces:**
- Consumes: Task 4 `scheduleRuns.listSettleable/scheduleRetry/finish`, `schedules.update`, `messages.append/page`; P1 `EventLog` + `eventMirror.put` (emit pattern = `runProcessor.ts`'s `emit`: `events.append` then `eventMirror.put`); Task 7 `Notifier`; Task 6 `SystemBus`; Task 1 `scheduleRetryBackoffMs`.
- Produces:

```ts
export interface SettleDeps { db: Db; events: EventLog; system: SystemBus; notifier: Notifier; clock?: () => Date; staleAfterMs?: number; }
export const SCHEDULE_ENQUEUE_LOST_MS = 120_000;                       // default staleAfterMs (Review Focus 2)
export const RETRYABLE_RUN_CODES = ["model_transient_exhausted", "run_lost"] as const;
export function classifyRunFailure(lastError: string | null): { retryable: boolean; code: string }; // "key_not_minted"/"model_terminal"/anything else/"" → not retryable, code = lastError ?? "unknown"
export function settleScheduleRuns(deps: SettleDeps): Promise<number>; // count settled; per-row errors caught+logged, never abort the pass
```

Per settleable row (from `listSettleable` with `staleBefore = now − (deps.staleAfterMs ?? SCHEDULE_ENQUEUE_LOST_MS)`):
- **Run `completed`** → `scheduleRuns.finish(succeeded)`; `summary` = newest message of the session when its role is `assistant` (`messages.page(db, sessionId, {limit:1})`) else null; `schedules.update(lastResult = {status:"succeeded", code:null, message:null, finishedAt: nowISO, ranLate})`; one-off (`scheduleTrigger.kind === "at"`) → additionally `status:"completed"`, `nextRunAt:null`. Session transcript: `events.append(sessionId, "system_note", {scheduleId, scheduleRunId, status:"succeeded"})` + `eventMirror.put` (the assistant message itself was already written by the run processor). System publish `schedule_run_succeeded` payload `{scheduleRunId, scheduledFor, summary, scheduleCompleted, autoDeniedApprovals: autoDenied.length}`. Push: `notifier.notifyScheduleSucceeded({userId: scheduleUserId, scheduleId, sessionId: scheduleSessionId, title: scheduleTitle, summary})`.
- **Run `failed`/`cancelled` OR stale orphan** (runId null / run missing / run `queued` past staleBefore) → `classifyRunFailure` (orphan/queued-stale → `{retryable:true, code:"run_lost"}`; cancelled → `{retryable:false, code:"cancelled"}`). If `retryable && row.attempt <= scheduleMaxRetries` → `scheduleRuns.scheduleRetry(id, new Date(now + scheduleRetryBackoffMs(row.attempt)))`; system publish `schedule_run_failed` payload `{scheduleRunId, scheduledFor, code, message, willRetry:true, retryAt, autoDeniedApprovals}`; NO push (Dart parity: intermediate retries don't notify); NO transcript write. Else (final): `scheduleRuns.finish(failed, code)`; `lastResult = {status:"failed", code, message, finishedAt, ranLate}`; one-off → schedule `status:"failed"`; recurring → `status:"paused"`, `pausedReason:"retries_exhausted"` (spec §8) + system publish `schedule_run_paused` `{reason:"retries_exhausted", code}`. Transcript: `messages.append({sessionId, role:"system", content:`Scheduled task failed: ${message ?? code}`})` + `system_note` event `{scheduleId, scheduleRunId, status:"failed", code}` + mirror. System publish `schedule_run_failed` `{…, willRetry:false, retryAt:null}`. Push: `notifier.notifyScheduleFailed({userId, scheduleId, sessionId, title, code, error: message})` — `code:"key_not_minted"` automatically carries the Q5 open-the-app body (Task 7).
- Settle is idempotent: every branch starts from a CONDITIONAL state transition (`finish`/`scheduleRetry` WHERE status='running'… implement `scheduleRuns.finish`/`scheduleRetry` calls as already-conditional in Task 4, or re-check via `claimRetry`-style guard here) so two overlapping settle passes cannot double-notify; a lost transition skips the row silently.

- [ ] **Step 1: Write the failing tests** (real db + capturing notifier/system/events stubs; seed schedules + claimed schedule_runs + run rows directly via repos). Cases: (a) success: run `completed` + assistant message seeded → settle returns 1; schedule_run `succeeded`; `lastResult.status==='succeeded'`; one-off schedule → `status:'completed'`, `nextRunAt:null`; recurring → stays `pending`; system `schedule_run_succeeded` with `summary === "Report ready"`; notifier got `{title, summary:"Report ready"}`; session `system_note` event appended AND mirrored (`eventMirror.readSince`); (b) `key_not_minted` (Q5): run failed lastError `key_not_minted` → final failure even with `maxRetries:3` (`classifyRunFailure` not retryable); notifier called with `code:"key_not_minted"`; schedule_run `failed` error `key_not_minted`; system message row content `Scheduled task failed: key_not_minted`; one-off → schedule `status:'failed'`; (c) retry ladder: run failed `model_transient_exhausted`, `maxRetries:2`, attempt 1, clock T → settle → schedule_run `{status:'retry_scheduled', attempt:2, retryAt:T+30_000}`; NO push; system `schedule_run_failed` `willRetry:true`; settle again immediately → row no longer settleable (returns 0 — idempotence pin); (d) exhaustion → pause: same row at attempt 3 (= maxRetries+1… pin: attempt 3 with maxRetries 2 → `3 <= 2` false) final → recurring schedule `{status:'paused', pausedReason:'retries_exhausted'}` + `schedule_run_paused` published + push `notifyScheduleFailed`; (e) orphan recovery (Review Focus 2): schedule_run `running`, `runId:null`, `startedAt = now−121s` → retry path when retries remain (code `run_lost`), else final; fresh orphan (`startedAt = now−1s`) → NOT settled (returns 0); (f) queued-stale: run row exists status `queued` older than staleAfter → same as orphan; run still `running` → untouched; (g) cancelled run → final failure code `cancelled`, not retryable; (h) `autoDenied` entries flow into the succeeded payload `autoDeniedApprovals: 2` (seed via `appendAutoDenied`); (i) notifier throwing → settle still completes the row (bookkeeping first-class, notification best-effort).
- [ ] **Step 2: Run to verify fail.** Worker suite — FAIL.
- [ ] **Step 3: Implement** per the branch rules; export from `index.ts`; remove the Task-8 forward-reference stub if one was needed.
- [ ] **Step 4: Run to verify pass.** Worker suite green; `pnpm -r build && pnpm -r test` (shared/db/queue/gateway unaffected but prove it).
- [ ] **Step 5: Commit.** `git add cloud/apps/worker && git commit -m "feat(cloud): schedule settle reconciler — retry ladder, pauseForReview, transcript + push reporting"`

### Task 10: `@ovid/worker` — mirror resync, main.ts wiring, deploy artifacts

**Files:**
- Create: `cloud/apps/worker/src/schedulerMirror.ts`
- Test: `cloud/apps/worker/src/schedulerMirror.test.ts`
- Modify: `cloud/apps/worker/src/main.ts` (+ `env` additions), `cloud/apps/worker/src/index.ts`, `cloud/deploy/docker-compose.yml` (worker service: add the SAME read-only firebase credentials volume as the gateway block, lines 94–99 — repo artifact only, NO activation), `cloud/deploy/DEPLOY.md` (§ env table: `OVID_SCHEDULER_TICK_MS` optional; note that the worker now also needs `GOOGLE_APPLICATION_CREDENTIALS` for FCM, same mount decision as §3)

**Interfaces:**
- Consumes: Task 4 `schedules.listPendingWithNextRun`; Task 6 `addScheduleMirrorJob`, `createScheduleFireWorker`, `SCHEDULE_FIRE_JOB_NAME`, `ScheduleFireJob`; Task 8 `SchedulerDeps`, `fireScheduleOccurrence`; Task 9 `settleScheduleRuns`; Task 7 `createNotifier`, `createFcmPushSender`, `createUnattendedApprovalHook`, `createScheduleTools` (Task 13 — wiring order: if Task 13 hasn't executed yet, wire tools in its own step there; main.ts changes are additive either way).
- Produces:

```ts
// schedulerMirror.ts
export function resyncScheduleMirror(deps: { db: Db; queues: QueueServices; clock?: () => Date }): Promise<number>; // listPendingWithNextRun → addScheduleMirrorJob per row (idempotent jobIds make re-adds no-ops) → count added-attempts
export function createScheduleFireProcessor(deps: SchedulerDeps): (job: { data: ScheduleFireJob }) => Promise<void>;
// processor: validate with scheduleFireJobSchema (invalid → log + COMPLETE, never retry — mirror is not authoritative);
// fireScheduleOccurrence(deps, scheduleId, { expectedScheduledFor: new Date(scheduledFor) }); every outcome (incl. not_due/duplicate_claim) is a normal completion; only infra throws propagate (BullMQ default handling).
// main.ts wiring (all pinned):
//  - loadWorkerEnv gains optional OVID_SCHEDULER_TICK_MS (positive int, default 15_000 — same validation pattern as OVID_RUN_STALE_MS).
//  - const system = createRedisSystemBus(redisQ);  const notifier = createNotifier({ db, push: createFcmPushSender() });
//  - boot: await resyncScheduleMirror({ db, queues, clock? }) BEFORE the loop starts (log count: `[scheduler] mirror resync: N delayed job(s)`).
//  - const loop = startSchedulerLoop({ db, queues, events, system, notifier }, { intervalMs: cfg.schedulerTickMs });
//  - const fireWorker = createScheduleFireWorker({ url: cfg.redisQUrl }, createScheduleFireProcessor({ db, queues, system })); fireWorker.on("error", …log…);
//  - shutdown(): loop.stop(); await fireWorker.close(); (added to the existing drain sequence BEFORE worker.close()).
//  - P3 seam wiring per the header note: register createScheduleTools({ db, system }) with P3's roster and pass createUnattendedApprovalHook({ db, notifier }) into P3's approval timeout point; if P3 hasn't landed, leave a `// P4-SEAM:` TODO and log `[scheduler] P3 tool/approval seam not wired`.
```

- [ ] **Step 1: Write the failing tests.** `schedulerMirror.test.ts` (real db + REAL redis queues via `createQueues({url: TEST_REDIS_URL})` — mirror behavior needs real delayed-job semantics): (a) seed 3 pending schedules (one with `nextRunAt` in the past → delay clamps to 1) + 1 paused + 1 pending-null-nextRunAt → `resyncScheduleMirror` returns 3 and `queues.schedules.getJobCounts()` shows `delayed + waiting === 3`; (b) resync twice → still 3 jobs (idempotent jobIds — boot-resync-after-crash pin); (c) `createScheduleFireProcessor`: job for a due occurrence → `fireScheduleOccurrence` ran (schedule_run row exists); job whose `scheduledFor` no longer matches (schedule advanced) → no-op completion, zero rows; malformed job data (`scheduleId: ""`) → completes without throwing; cleanup: `queues.schedules.obliterate({force:true})` + close (P1 discipline).
- [ ] **Step 2: Run to verify fail.** `TEST_DATABASE_URL=… TEST_REDIS_URL=… pnpm --filter @ovid/worker test` — FAIL.
- [ ] **Step 3: Implement** `schedulerMirror.ts`; rewire `main.ts` per the pinned list (keep the composition root untested-thin — the e2e exercises it; do not remove the stale-run sweeper).
- [ ] **Step 4: Verify.** Worker suite green; `pnpm -r build && pnpm -r test`; `node -e "1"`-level smoke of env validation: `OVID_SCHEDULER_TICK_MS=abc` → `loadWorkerEnv` throws with the variable name (unit case inside `schedulerMirror.test.ts` or the existing env test pattern — add it).
- [ ] **Step 5: Commit.** `git add cloud/apps/worker cloud/deploy && git commit -m "feat(cloud): boot mirror resync + schedule-fire worker + scheduler loop wiring"`

### Task 11: `@ovid/gateway` — REST `/cloud/v1/schedules` + `/cloud/v1/devices`

**Files:**
- Create: `cloud/apps/gateway/src/routes/schedules.ts`, `cloud/apps/gateway/src/routes/devices.ts`
- Test: `cloud/apps/gateway/src/routes/schedules.test.ts`, `cloud/apps/gateway/src/routes/devices.test.ts`
- Modify: `cloud/apps/gateway/src/app.ts` (GatewayDeps += `system: SystemBus`; register both route modules in the authenticated scope), `cloud/apps/gateway/src/main.ts` (`createRedisSystemBus(redisQ)` into deps), `cloud/apps/gateway/src/test/stubs.ts` (add `stubSystemBus()` capturing publishes; extend `stubQueues` with a `schedules` capture so the type stays assignable), every existing `buildGateway({...})` construction in gateway tests + `cloud/apps/e2e/src/spine.test.ts` (add `system: createRedisSystemBus(redis)` — e2e already creates `redis`; compile errors will list every site)

**Interfaces:**
- Consumes: Task 5 `scheduleService` + `ScheduleError`; Task 4 repos (`schedules.get/list`, `scheduleRuns.listForSchedule`, `devices`, `users.ensure`); Task 2 DTOs/schemas; `SystemBus`; P1 route plumbing (`sendError/badRequest/notFound/zodBadRequest/parsePageLimit/queryValue/isUuid`, `authHook` scope).
- Produces:

```ts
// schedules.ts
export function registerScheduleRoutes(app: FastifyInstance, deps: GatewayDeps): void;
export function toScheduleDto(row: ScheduleRow): ScheduleDto;
export function toScheduleRunDto(row: ScheduleRunRow): ScheduleRunDto;
// devices.ts
export function registerDevicesRoutes(app: FastifyInstance, deps: GatewayDeps): void;
```

Route contract (all inside the existing authenticated scope; every `:id` passes `isUuid` → else 404 `not_found` "Schedule not found."; `ScheduleError` maps: `not_found`→404, `tier_required`→403 `{code:"tier_required", message:"Cron schedules require Ovid Pro."}`, `invalid_trigger`/`bad_request`→400 with the error's message via `zodBadRequest`-style envelope):
- `POST /cloud/v1/schedules` — body `scheduleCreateRequestSchema` (strict; malformed → 400 via `zodBadRequest`); `users.ensure(db, uid, email)` FIRST (provisions the FK target, yields nothing further — the service re-reads tier); `createSchedule(db, {userId: uid, …body})`; publish `{type:"schedule_created", scheduleId, ts, payload:{schedule: dto}}` on `deps.system` for `uid`; → **201** `ScheduleDto`.
- `GET /cloud/v1/schedules?limit&cursor&includeCancelled=true|false` → `Page<ScheduleDto>` (`parsePageLimit` clamping; `includeCancelled` any value other than `"true"` = false).
- `GET /cloud/v1/schedules/:id` → `ScheduleDto` (owner-scoped, 404 rule).
- `GET /cloud/v1/schedules/:id/runs?limit&before` → `Page<ScheduleRunDto>` (404 ownership check first; `before` lenient-ignore like messages `beforeId`, uuid-guarded).
- `PATCH /cloud/v1/schedules/:id` — body `scheduleUpdateRequestSchema`; `updateSchedule`; publish `schedule_updated` `{schedule: dto, reason: patch.status === "pending" ? "resumed" : "patched"}`; → **200** `ScheduleDto`.
- `DELETE /cloud/v1/schedules/:id` — `cancelSchedule`; publish `schedule_deleted` `{scheduleId}`; → **204** (no body).
- `POST /cloud/v1/devices` — body `deviceRegisterRequestSchema`; `devices.upsert({token, userId: uid, platform})`; → **200** `DeviceDto`.
- `DELETE /cloud/v1/devices` — body `{token}` (zod strict, non-empty; token in the BODY — FCM tokens are not URL-safe); `devices.removeByToken(token, uid)`; → **204**. Wrong-owner delete = silent no-op 204 (no existence leaks).

- [ ] **Step 1: Write the failing tests** (inject-based like `sessions.test.ts`; real db; `stubSystemBus`, `stubVerifier`, `authHeaders`). Cases: create `every 300` → 201 with `status:"pending"`, `autonomy:"safe"`, `nextRunAt` ≈ now+300 s (ISO), dedicated `sessionId` that `GET /sessions/:id` confirms exists; create cron as free user → **403 `tier_required`**; create cron after `UPDATE users SET tier='pro'` → 201; create with unknown `sessionId` → 404; create with `{}` / `{title:""}` / unknown key / `maxRetries:9` → 400 `bad_request`; `GET /schedules` lists only the caller's (user B sees `items: []`), pagination via `nextCursor` works, cancelled hidden unless `includeCancelled=true`; `GET/PATCH/DELETE` as user B on A's schedule → 404 `not_found` (Review Focus 4), malformed `:id` (`"nope"`) → same 404; `PATCH {status:"paused"}` → 200 `pausedReason:"user"`; `PATCH {status:"pending"}` → `nextRunAt` recomputed; `PATCH {}` → 400; `DELETE` → 204 then `GET` list excludes it, second `DELETE` → 204 idempotent; `GET /:id/runs` after seeding two schedule_runs → newest-first page, `before` cursor splits; system bus captured `schedule_created`/`schedule_updated`/`schedule_deleted` publishes with matching `scheduleId` and the uid's channel. Devices: `POST` → 200 `{token, platform:"android"}`; re-POST same token → still one row (upsert); `POST {platform:"ios"}` → 400; `DELETE {token}` → 204 and row gone; `DELETE` with someone else's token → 204 but row SURVIVES.
- [ ] **Step 2: Run to verify fail.** `TEST_DATABASE_URL=… pnpm --filter @ovid/gateway test` — FAIL (plus compile failures at every `buildGateway` site missing `system` — fix them in this step as part of the wiring).
- [ ] **Step 3: Implement** routes + `app.ts`/`main.ts`/`stubs.ts`/e2e construction-site updates.
- [ ] **Step 4: Run to verify pass.** Gateway suite green; `pnpm -r build && pnpm -r test` (e2e spine still green — it constructs `buildGateway` too).
- [ ] **Step 5: Commit.** `git add cloud/apps/gateway cloud/apps/e2e && git commit -m "feat(cloud): schedules REST CRUD + runs feed + FCM device registration"`

### Task 12: `@ovid/gateway` — WS system channel

**Files:**
- Modify: `cloud/apps/gateway/src/ws.ts`, `cloud/apps/gateway/src/ws.test.ts`
- (No shared changes — Task 2 already added the ops; `WsDeps` gains `system: SystemBus`, structurally satisfied by `GatewayDeps`.)

**Interfaces:**
- Consumes: `SystemBus` (Task 6), `systemEvent`/`SystemEvent` + new ws ops (Task 2).
- Produces: `WsDeps.system: SystemBus`; behavior contract — client `{op:"subscribe_system"}` → server `{op:"system_subscribed"}` then `{op:"system", event}` frames for every bus event of the TICKET'S uid until `{op:"unsubscribe_system"}` or close; re-subscribe REPLACES (old bus subscription torn down — no connection leaks); at most one system subscription per socket; bus errors/garbage never kill the socket (Task 4-ruling hardening lives in the bus itself); teardown on close unsubscribes the bus listener (the existing `teardownAll` path).

- [ ] **Step 1: Write the failing tests** in `ws.test.ts` (existing harness: fake sockets + stub deps; add a `stubSystemBus` whose `subscribe` captures the callback and records unsubscribe): (a) `subscribe_system` → `system_subscribed` ack; a published `SystemEvent` → `{op:"system", event}` frame deep-equal; (b) events for a DIFFERENT uid are never delivered (bus stub keyed by uid — assert `subscribe` called with the ticket's uid); (c) `unsubscribe_system` → unsubscribe called, later publishes not forwarded; (d) re-`subscribe_system` → previous unsubscribed exactly once; (e) socket close → unsubscribed (no leaked bus connections — the P1 leak-class pin); (f) session `subscribe`/`event`/`pong` flows all still pass untouched (regression); (g) an `{op:"subscribe_system", extra:1}` frame — unknown keys on client msgs: follow the EXISTING ws schema's strictness behavior (zod object default strips; do not change it) and assert the ack still arrives.
- [ ] **Step 2: Run to verify fail.** `pnpm --filter @ovid/gateway test` — FAIL.
- [ ] **Step 3: Implement** in `ws.ts`: a `systemSub: {unsubscribe} | null` beside the `subs` map, handled inside the existing frame chain (ordering guarantee preserved); include `systemSub` teardown in `teardownAll`; send frames through the existing `send()` readyState-guarded choke point.
- [ ] **Step 4: Run to verify pass.** Gateway suite green.
- [ ] **Step 5: Commit.** `git add cloud/apps/gateway && git commit -m "feat(cloud): WS system channel — user-scoped schedule lifecycle events"`

### Task 13: `@ovid/worker` — agent schedule tools (P3 tool seam)

**Files:**
- Create: `cloud/apps/worker/src/scheduleTools.ts`
- Test: `cloud/apps/worker/src/scheduleTools.test.ts`
- Modify: `cloud/apps/worker/src/index.ts`; `cloud/apps/worker/src/main.ts` (register with P3's roster per the header seam note — additive to Task 10's wiring)

**Interfaces:**
- Consumes: Task 5 service; Task 4 repos; Task 1 `describeTrigger`/`nextFireAfter`; Task 2 DTOs + `SystemEvent`; `SystemBus`.
- Produces:

```ts
export interface ScheduleToolContext { userId: string; sessionId: string; }   // P3's roster supplies these per run
export interface ScheduleToolResult { content: string; structured?: unknown; isError?: boolean; }
export interface ScheduleTool {
  name: "schedule_create" | "schedule_list" | "schedule_update" | "schedule_delete";
  description: string;                    // tells the MODEL to parse natural language into structured trigger JSON itself, and to relay the needs_confirmation echo to the user verbatim
  inputSchema: z.ZodTypeAny;
  execute(input: unknown, ctx: ScheduleToolContext): Promise<ScheduleToolResult>;
}
export function createScheduleTools(deps: { db: Db; system: SystemBus; clock?: () => Date }): ScheduleTool[]; // [create, list, update, delete] in that order
```

Behavior (spec §8 creation path (b) — natural-language parsing is done BY the model; the tool takes structured trigger JSON and echoes it for confirmation BEFORE persisting):
- `schedule_create` input: `{ title (1..200), description (1..4000), trigger: scheduleTriggerSchema, autonomy?: "safe"|"auto" (default "safe"), maxRetries?: int 0..3 (default 0), sessionId?: string (default: DEDICATED session — NOT ctx.sessionId), confirmed?: boolean (default false) }`. `confirmed !== true` → persist NOTHING; call `createSchedule`'s validation only by computing `nextRunAt` with the same rules (tier gate INCLUDED — a free user gets the tier error even in preview) and return `{ content: `Please confirm: I will run "<description>" <describeTrigger(trigger)> (autonomy: <autonomy>, retries: <maxRetries>). First run: <nextRunAt ISO>. Say "confirm" to create it.`, structured: { status: "needs_confirmation", parsed: { title, description, trigger, autonomy, maxRetries, nextRunAt } } }`. `confirmed === true` → `createSchedule` → publish `schedule_created` → `{ content: `Schedule created: "<title>" <describeTrigger>.`, structured: { status: "created", schedule: <ScheduleDto> } }`.
- `schedule_list` input `{}` → `{ content: one line per schedule: "- <title> — <describeTrigger> — <status>, next <nextRunAt ISO or '—'>", or "No schedules." ; structured: { schedules: ScheduleDto[] } }` (excludes cancelled).
- `schedule_update` input `{ scheduleId, patch: scheduleUpdateRequestSchema }` → `updateSchedule` (persists directly — the model has already confirmed with the user in conversation) → publish `schedule_updated` → `{ content: `Schedule updated: "<title>".`, structured: { status: "updated", schedule } }`.
- `schedule_delete` input `{ scheduleId }` → `cancelSchedule` → publish `schedule_deleted` → `{ content: `Schedule deleted: "<title>".`, structured: { status: "deleted", scheduleId } }`.
- Errors: invalid input → `{ isError: true, content: "Invalid arguments: <zod issue summary>" }`; `ScheduleError` → `{ isError: true, content: <message> }` (tier_required message: `Cron schedules require Ovid Pro.`); wrong-owner id → `Schedule not found.` (no existence leaks, same wording as REST).

- [ ] **Step 1: Write the failing tests** (real db; capturing bus; injected clock): (a) `schedule_create` without `confirmed` → NO `schedules` row exists, `structured.status === "needs_confirmation"`, `parsed.nextRunAt` = exact ISO for an `every 300` at clock T0, content contains `every 300 seconds` and `Say "confirm"`; (b) with `confirmed: true` → row persisted, `schedule_created` published, content `Schedule created:`; (c) free-tier cron without confirmed → isError with the Pro message (gate fires in preview too); (d) `schedule_list` with 2 schedules + 1 cancelled → 2 entries, content lines contain titles; (e) `schedule_update` `{status:"paused"}` → row paused + `schedule_updated` published; (f) `schedule_delete` someone else's id → isError `Schedule not found.` and the row is untouched; (g) bad trigger JSON (`{kind:"every", seconds: 10}`) → isError, nothing persisted; (h) tool names/descriptions: `createScheduleTools(...).map(t => t.name)` equals `["schedule_create","schedule_list","schedule_update","schedule_delete"]`.
- [ ] **Step 2: Run to verify fail.** `TEST_DATABASE_URL=… pnpm --filter @ovid/worker test` — FAIL.
- [ ] **Step 3: Implement**; wire registration in `main.ts` per the seam note (P3 roster API if present; otherwise exported-unwired + `// P4-SEAM:` comment + one `[scheduler] P3 tool seam not wired` log line, and REPORT to the controller).
- [ ] **Step 4: Run to verify pass.** Worker suite green; `pnpm -r build && pnpm -r test`.
- [ ] **Step 5: Commit.** `git add cloud/apps/worker && git commit -m "feat(cloud): agent schedule tools with confirm-echo flow (spec §8 creation path b)"`

### Task 14: e2e — unattended scheduler suite

**Files:**
- Create: `cloud/apps/e2e/src/scheduler.test.ts`
- (No production code. If a flow exposes a real defect, fix it in the owning module inside this task's commits and say so in the report.)

**Interfaces:**
- Consumes: everything — real `buildGateway` (REST + WS system channel), real worker pieces (`runSchedulerTick`/`fireScheduleOccurrence`/`settleScheduleRuns`/`resyncScheduleMirror` + a real `createAgentRunsWorker` with the real `createAgentRunProcessor` against the SSE mock), real Postgres/Redis, stub `PushSender` (captures pushes), stub `KeyProvider`, `createRedisSystemBus` shared between gateway deps and scheduler deps (same instance discipline as the spine's `events`).
- Produces: the phase-level proof that a schedule fires unattended, runs, and reports (spec P4 row: "unattended autonomous tasks run and report").

Harness: copy `spine.test.ts` conventions wholesale (`describe.skipIf` on missing TEST_* URLs, `uid()` generator, SSE mock, `waitForAsync`, `api()` helper, queue obliterate + stream-key cleanup in `afterAll` — now obliterating BOTH `agent-runs` and `schedules`; add `user:*:system` pubsub-channel drain to the leak check). The scheduler is driven by **injected clocks + manual `runSchedulerTick`/`settleScheduleRuns` calls** (never `startSchedulerLoop` wall-time); the SSE mock's `sleep` injection keeps the retry ladder instant. WS system client: connect + `{op:"subscribe_system"}`, collect `{op:"system"}` frames.

- [ ] **Step 1: Write the five flows as failing tests** (they fail until the whole phase is wired — this task runs last):
  - **Flow A — full unattended cycle + notification records:** REST-create `every 300` schedule (title `Morning report`, description `check things`) for a fresh user; register a device (`POST /devices`); arm SSE deltas `["Report ready"]`; tick with clock `realNow + 301s` → `fired:1`; wait (bounded `waitForAsync`) for the real agent-runs worker to finish the run, then `settleScheduleRuns` with the same clock → 1. Assert: last SSE request's final message content === `[schedule: Morning report] check things` (prompt format pin); session transcript via REST `GET /sessions/:id/messages` = user `[schedule: …]` + assistant `Report ready`; `schedule_runs` row `succeeded`, `ranLate:false`; schedule `nextRunAt` advanced ~600 s; `notifications` row `kind:'scheduleSucceeded', status:'sent'` with `route === '/schedule/'+sessionId` (Review Focus 5 record pin); captured push message `data.kind === 'scheduleSucceeded'`, `androidChannelId === 'ovid_scheduler_results.chime.v1'`; WS system client saw `schedule_created`, `schedule_run_started`, `schedule_run_succeeded` (in that order, matching `scheduleId`).
  - **Flow B — key_not_minted (ledger Q5):** second user, KeyProvider stub returns `null`; one-off `at` schedule ≈ now+1 s; tick → fired; run fails (processor's existing path); settle → schedule_run `failed` error `key_not_minted`; schedule `status:'failed'` (one-off); push body === `KEY_NOT_MINTED_PUSH_BODY` (import the constant — copy pin); WS `schedule_run_failed` payload `{code:'key_not_minted', willRetry:false}`; session has a `system` role message `Scheduled task failed: key_not_minted`.
  - **Flow C — missed-run simulation (stop tick, advance clock, restart):** third user; `every 300` at T0; tick at T0+300s fires (settle to success so the session frees); advance clock to `T0+600s + 7h` (grace 150 s → beyond) → tick → `skipped:1`, schedule_run `skipped`, `nextRunAt` = first 300 s-slot after the advanced now, ZERO new agent-runs adds, WS `schedule_updated` `reason:'skipped_missed'`; one-off `at T1` for a fourth user, clock `T1+25h` → tick → `paused:1`, schedule `{status:'paused', pausedReason:'missed_beyond_grace'}`, WS `schedule_run_paused`; one-off `at T2` for a fifth user, clock `T2+3h` (within 24 h grace) → tick → `fired:1` with `ranLate:true` on the ledger row.
  - **Flow D — duplicate-fire prevention (Review Focus 1):** sixth user; due schedule; `await Promise.all([fireScheduleOccurrence(deps, id), fireScheduleOccurrence(deps, id)])` PLUS a mirror job processed concurrently (`createScheduleFireProcessor` invoked with the matching `ScheduleFireJob`) → exactly one `schedule_runs` row, one `runs` row, one agent-runs job for the occurrence (query by `sessionId`); outcomes contain exactly one `fired`.
  - **Flow E — retry ladder then pauseForReview:** seventh user; `every 300`, `maxRetries:1`; SSE mock arms `closeSocketAfterDeltas:1` (always transient); captured-`sleep` processor → run fails `model_transient_exhausted`; settle at clock T → schedule_run `retry_scheduled` attempt 2, `retryAt = T+30s` (exact); NO push yet; tick at `T+31s` → `retried:1` (new run row, same schedule_run id); fails again; settle → final: schedule_run `failed`, schedule `{status:'paused', pausedReason:'retries_exhausted'}`, WS `schedule_run_failed {willRetry:false}` then `schedule_run_paused {reason:'retries_exhausted'}`, ONE `scheduleFailed` push recorded (no push for the intermediate retry — assert notification rows count for this user === 1).
  - Cross-flow invariants at the end: `workerFailures`/`workerErrors` empty; every suite session's events replay cleanly (`events.readSince` ground truth for one flow).
- [ ] **Step 2: Run to verify fail/pass state.** `cd /root/OvidAI/cloud && TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres TEST_REDIS_URL=redis://127.0.0.1:6390 pnpm --filter @ovid/e2e test` — with Tasks 1–13 complete the flows should pass; any failure is a real defect: fix it in the owning module (never weaken an assertion; if an assertion contradicts this plan, the plan wins — escalate to the controller if the plan contradicts the spec).
- [ ] **Step 3: Full workspace gate.** `cd /root/OvidAI/cloud && pnpm -r build && pnpm -r test` — Expected: ALL packages green (shared, db, events, queue, gateway, worker, e2e), twice in a row for the e2e file (flakiness gate: rerun `pnpm --filter @ovid/e2e test` once).
- [ ] **Step 4: Commit.** `git add cloud && git commit -m "test(cloud): e2e unattended scheduler — fire, missed-run policy, claim-ledger races, retry ladder, push records"`

---

## Self-Review

**1. Spec coverage (§8 + §6.2 + G8 + Q5 ruling):**
- Model `{id,user_id,session_id?,title,description,trigger,autonomy,status,next_run_at,last_result,max_retries}` → Task 3 (session_id materialized at creation — documented deviation, superset of the spec's optional).
- Triggers `at`/`every`(min 300)/`daily_at`(tz)/`cron`(Pro, users.tier enforced) → Tasks 1, 5 (single choke point), 11, 13.
- Creation paths (a) screen CRUD → Task 11; (b) agent tools with parsed-trigger echo before persisting → Task 13; (c) REST → Task 11.
- Session binding optional / dedicated per-schedule session → Task 5.
- Execution: Postgres authoritative, 15 s tick, `FOR UPDATE SKIP LOCKED`, prompt `[schedule: {title}] {description}`, at-most-once claim keyed `(schedule_id, scheduled_for)` → Tasks 4, 8. BullMQ delayed mirror re-synced at boot, never authoritative → Tasks 6, 10.
- Autonomy `safe`/`auto` + approval auto-deny 120 s reported in result → Tasks 6 (`ScheduleRunRef` on the job), 7 (`UnattendedApprovalHook`, `auto_denied` → settle payload), 9 (report). Roster projection itself is P3's tool engine — seam documented (header + Tasks 7/13).
- Missed-run policy exact port (2 min / 24 h ran_late / ≤6 h runNow-skipToNext / pauseForReview) → Task 1 (values pinned from `test/schedule_catchup_test.dart`), applied Task 8, e2e Task 14 C.
- Retries 0–3, backoff 30/60/120 s, then pauseForReview → Tasks 1, 9.
- Result → FCM push + in-app feed (`GET /schedules/:id/runs`) + session message/events → Tasks 7, 9, 11.
- WS system events (7 lifecycle types, additive to shared) → Tasks 2, 6, 12; publishes from gateway (11), worker fire (8), settle (9), tools (13).
- Devices: `POST /cloud/v1/devices` + unbind → Task 11; FCM via firebase-admin + `GOOGLE_APPLICATION_CREDENTIALS` (existing `/opt/ovid-gateway/firebase-admin.json` mount pattern, no secrets in repo, tests stub) → Tasks 7, 10. Notification kinds/routes/summary ported from Dart → Task 2 + 7.
- Q5 ruling (key_not_minted → failed run + open-the-app push) → Tasks 7 (pinned body), 9 (classification), 14 flow B.
- e2e requirements (fires unattended, missed-run simulation, duplicate-fire prevention) → Task 14 flows A/C/D (+B/E beyond the brief).
- Gaps found and closed during review: boot-resync idempotence (Task 10 b), busy-session defer-before-policy (Task 8, Dart parity), resume semantics for missed one-offs (Task 5, Dart `resumeStopped` port).

**2. Step scan:** every task follows test-first with named cases and exact pinned values; implementation steps give signatures + the two SQL shapes + the fire algorithm (the parts an implementer cannot invent consistently). No "TBD"/"handle edge cases" lines. The Task 8→9 forward type reference has an explicit fallback instruction.

**3. Type consistency:** `SchedulerDeps`/`SettleDeps`/`Notifier`/`SystemBus`/`PushSender`/`ScheduleTool*`/`FireOutcome`/`TickReport`/`SettleableRunRow`/`ScheduleRunRef`/`scheduleMirrorJobId`/`addScheduleMirrorJob`/`schedulePrompt`/`describeTrigger`/`decideMissedRun`/`scheduleRetryBackoffMs`/`KEY_NOT_MINTED_PUSH_BODY`/`SCHEDULE_ENQUEUE_LOST_MS`/`UNATTENDED_APPROVAL_TIMEOUT_MS` — each defined in exactly one task's Produces and consumed under the same name elsewhere (checked pairwise: 1→5/8/9, 2→7/11/13, 4→5/7/8/9/10, 5→11/13, 6→7/8/10/12, 7→9/10, 8→10/14, 9→8/10/14).

**4. Review Focus:** all five lines own a named test in their task (1 → T4b/T8e/T14D; 2 → T9e/T8i; 3 → T1 DST cases; 4 → T5/T11; 5 → T7c/d/e).

**5. Proportion:** spec §8+§6.2 ≈ 60 lines; this plan is ~10× that — justified by the port obligations (AG4 exact values), the two-app wiring, and 5 e2e flows; code blocks are signatures/assertions, not bodies (the only algorithm written out is the fire transaction, which the signature does not determine).

**Known risks handed to the controller:** (a) P3's actual tool-roster/approval APIs are unknown at write time — Tasks 7/13 carry an adapt-or-document-unwired rule and must report which path they took; (b) `success summary = newest assistant message` is imprecise for schedules BOUND to busy shared sessions (documented in Task 9; dedicated sessions are exact); (c) e2e obliterates the shared dev-redis `schedules` queue — same pre-existing discipline/risk as P1's `agent-runs` (ledger minor, whole-branch).
