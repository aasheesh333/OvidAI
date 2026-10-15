# Ovid Cloud P0+P1 — VPS Provisioning & Cloud Spine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the hardened infra foundation and the end-to-end server-side chat spine: a thin client sends a prompt over REST, a detached BullMQ worker runs the model turn via LiteLLM, streams events over a replayable WebSocket channel, and persists everything in Postgres — no tools yet.

**Architecture:** New pnpm/TypeScript monorepo at `cloud/` (packages: shared, db, events, queue; apps: gateway, worker). Gateway = Fastify HTTP+WS, stateless, auth via firebase-admin. Worker = BullMQ consumer hosting the v0 agent-run processor. Durable event log = Redis Streams (`redis-q`, noeviction); authoritative state = Postgres (`ovid_cloud` DB on the existing gateway Postgres container). Live Python stack at `/opt/ovid-gateway` is untouched except additive changes (new DB, new Caddy route).

**Tech Stack:** Node 22, pnpm workspaces, TypeScript strict, Vitest, Drizzle ORM (postgres.js driver), BullMQ 5, ioredis, Fastify 5, @fastify/websocket, firebase-admin, zod, Docker Compose, Caddy.

**Spec:** `docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md`

## Global Constraints

- Wire format: JSON, **camelCase**; ids are **UUIDv7** (time-sortable); timestamps ISO-8601 UTC.
- New code only under `cloud/`; deploy target `/opt/ovid-cloud`. Never edit `/opt/ovid-gateway/docker-compose.yml` or the live Caddyfile without a timestamped backup + `docker compose config` / `caddy validate` check first.
- Route prefix: all new HTTP under `/cloud/v1/*`; WS at `/cloud/ws`. Gateway binds `127.0.0.1:8081`.
- Redis split (AG3): `redis-q` (BullMQ + Streams + tickets) runs `maxmemory-policy noeviction`; caches go to a separate instance. Tests use disposable services, never the live ones.
- Auth on every REST/WS handshake: Firebase ID token + App Check (firebase-admin). Dev/test bypass `OVID_AUTH_MODE=test` (header `x-test-uid`); gateway must refuse to start with test mode when `NODE_ENV=production`.
- Retry policy for model calls (spec §6.1): 5 attempts, backoff 3/9/27/60 s, transient = network error, 429, 5xx; 4xx (except 429) is terminal.
- Event ordering guarantee: per-session monotonic `seq` (Redis Stream ID); clients replay with `lastEventId` and dedupe by `seq`.
- Error envelope (REST): `{ "error": { "code": string, "message": string } }`; codes used in this plan: `unauthenticated`, `forbidden`, `not_found`, `key_not_minted`, `run_conflict`, `unavailable`.
- Commit after every task; run `pnpm -r build && pnpm -r test` from `cloud/` before committing.

## Review Focus

1. **Replay/live race on reconnect** — an event published between the replay read and the live subscription must not be lost or duplicated; a client reconnecting with a stale `lastEventId` gets exactly-once ordering. Expected: subscribe-first, then replay, dedupe by `seq`. Pinned by Task 8 tests.
2. **Malformed SSE from the model gateway** — partial lines, `:` keep-alives, mid-stream socket close. Expected: no crash; mid-stream close counts as transient and retries; garbage lines are skipped. Pinned by Task 9 tests.
3. **Cross-user access** — valid Firebase token, someone else's `sessionId`. Expected: 404 on REST, WS subscribe rejected with `forbidden` event, zero leaked events. Ticket replay after use → rejected. Pinned by Tasks 6–8 tests.
4. **Double-send to one session** — two prompts posted before the first run finishes. Expected: single active run per session; second is accepted and queued in order (not dropped, not run concurrently). Pinned by Tasks 7/9 tests.
5. **redis-q at maxmemory under noeviction** — job adds and XADDs must fail loudly (REST 503 `unavailable`, run stays `queued`), never silently drop; `/cloud/v1/health` reports the degraded state. Pinned by Tasks 5/10 tests.

---

### Task 1: Monorepo scaffold + CI

**Files:**
- Create: `cloud/pnpm-workspace.yaml`, `cloud/package.json`, `cloud/tsconfig.base.json`, `cloud/vitest.workspace.ts`, `cloud/.gitignore`
- Create: `cloud/packages/{shared,db,events,queue}/package.json` + `src/index.ts` + `tsconfig.json` (each)
- Create: `cloud/apps/{gateway,worker}/package.json` + `src/index.ts` + `tsconfig.json` (each)
- Create: `cloud/scripts/dev-services.sh`
- Create: `.github/workflows/cloud.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: workspace layout every later task assumes; `pnpm -r build` / `pnpm -r test` entrypoints; dev-services script exporting Postgres on `127.0.0.1:5433` and Redis on `127.0.0.1:6390`.

- [ ] **Step 1: Scaffold workspace.** Root `cloud/package.json`: `{ "private": true, "scripts": { "build": "pnpm -r build", "test": "pnpm -r test" } }`; `pnpm-workspace.yaml`: `packages: ["packages/*", "apps/*"]`. `tsconfig.base.json`: `strict: true, target: "ES2022", module: "NodeNext", moduleResolution: "NodeNext", declaration: true, outDir: dist, rootDir: src`. Each package: `name` `@ovid/<name>` (apps: `@ovid/gateway`, `@ovid/worker`), `type: "module"`, `main: "dist/index.js"`, `types: "dist/index.d.ts"`, `exports` map, deps `workspace:*` as needed, scripts `build: tsc -p tsconfig.json`, `test: vitest run`. `src/index.ts` per package exports a placeholder (`export const PKG = "<name>"`).
- [ ] **Step 2: Smoke test in one package.** `cloud/packages/shared/src/index.test.ts`:

```ts
import { expect, it } from "vitest";
import { PKG } from "./index.js";
it("shared package exports placeholder", () => expect(PKG).toBe("shared"));
```

- [ ] **Step 3: Verify green.** Run: `corepack enable pnpm || npm i -g pnpm; cd cloud && pnpm install && pnpm -r build && pnpm -r test` — Expected: build OK, 1 test PASS.
- [ ] **Step 4: dev-services script.** `cloud/scripts/dev-services.sh`: idempotently `docker run -d --name ovid-dev-pg -e POSTGRES_PASSWORD=ovid -p 127.0.0.1:5433:5432 postgres:16-alpine` and `docker run -d --name ovid-dev-redis -p 127.0.0.1:6390:6379 redis:7-alpine` (skip if containers exist; `wait-for` loops using `pg_isready`/`redis-cli ping`); prints `TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres` and `TEST_REDIS_URL=redis://127.0.0.1:6390`.
- [ ] **Step 5: CI workflow.** `.github/workflows/cloud.yml`: on push/PR paths `cloud/**` + the workflow file; job `cloud`: Node 22, services `postgres:16-alpine` (5432) and `redis:7-alpine` (6379) with health options; env `TEST_DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres`, `TEST_REDIS_URL=redis://localhost:6379`; steps: checkout → `corepack enable` → `pnpm install --frozen-lockfile` → `pnpm -r build` → `tsc --noEmit` per package → `pnpm -r test`.
- [ ] **Step 6: Verify script works.** Run: `bash cloud/scripts/dev-services.sh && docker exec ovid-dev-redis redis-cli ping` — Expected: `PONG`.
- [ ] **Step 7: Commit.** `git add cloud .github/workflows/cloud.yml && git commit -m "chore(cloud): pnpm monorepo scaffold, dev services, CI"`.

### Task 2: `@ovid/shared` — protocol types & schemas

**Files:**
- Create: `cloud/packages/shared/src/{events.ts,rest.ts,ws.ts,index.ts}`
- Test: `cloud/packages/shared/src/{events.test.ts,rest.test.ts,ws.test.ts}`

**Interfaces:**
- Consumes: Task 1 workspace.
- Produces (later tasks import from `@ovid/shared`):

```ts
// events.ts
export type SessionEventType =
  | "run_started" | "message_delta" | "message_completed"
  | "run_started_retry" | "run_failed" | "run_completed" | "system_note";
export interface SessionEvent {
  sessionId: string; seq: string; type: SessionEventType;
  payload: Record<string, unknown>; ts: string;
}
export function sessionEvent(input: unknown): SessionEvent;             // zod parse, throws
export const sessionEventSchema: z.ZodType<SessionEvent>;

// rest.ts
export interface SessionDto { id: string; title: string | null; createdAt: string; updatedAt: string; }
export interface MessageDto { id: string; sessionId: string; role: "user" | "assistant" | "system" | "tool"; content: string; createdAt: string; }
export interface Page<T> { items: T[]; nextCursor: string | null; }
export interface SendMessageResponse { runId: string; userMessageId: string; status: "queued"; }
export interface ApiError { error: { code: string; message: string } }

// ws.ts — client→server messages on the multiplexed socket
export type WsClientMsg =
  | { op: "subscribe"; sessionId: string; lastEventId?: string | null }
  | { op: "unsubscribe"; sessionId: string }
  | { op: "ping" };
export type WsServerMsg =
  | { op: "subscribed"; sessionId: string }
  | { op: "event"; event: SessionEvent }
  | { op: "pong" }
  | { op: "error"; code: string; message: string; sessionId?: string };
export function wsClientMsg(input: unknown): WsClientMsg;
export function wsServerMsg(input: unknown): WsServerMsg;
```

- [ ] **Step 1: Write failing schema tests.** `events.test.ts`: valid envelope round-trips (`sessionEvent({...}) ` deep-equals input); rejects unknown `type`; rejects missing `seq`; rejects non-object `payload`. `ws.test.ts`: each `op` variant parses; `{op:"nope"}` throws; `subscribe` without `lastEventId` parses with field `undefined`. `rest.test.ts`: export schemas `sessionDtoSchema`, `messageDtoSchema`, `pageSchema(inner)` exist and reject a `Page` with non-array `items`.
- [ ] **Step 2: Run to verify fail.** `cd cloud && pnpm --filter @ovid/shared test` — Expected: FAIL (exports missing).
- [ ] **Step 3: Implement** the interfaces above as zod schemas + inferred types in the listed files; `index.ts` re-exports all three modules. Use `z.string().uuid()`-free id validation (UUIDv7: just nonempty string) — ids are validated at DB boundary, not wire.
- [ ] **Step 4: Run to verify pass.** Same command — Expected: all PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): shared protocol schemas (events, REST DTOs, WS ops)"`.

### Task 3: `@ovid/db` — Drizzle schema, migrations, repositories

**Files:**
- Create: `cloud/packages/db/src/{schema.ts,client.ts,repos.ts,index.ts}`, `cloud/packages/db/drizzle/` (generated SQL), `cloud/packages/db/drizzle.config.ts`
- Test: `cloud/packages/db/src/repos.test.ts`

**Interfaces:**
- Consumes: `@ovid/shared` (role/type unions).
- Produces:

```ts
// schema.ts — tables: users, sessions, messages, runs, sessionEventMirror
// columns (drizzle pg): users(uid text pk, email text null, tier text default 'free', bannedAt timestamptz null, createdAt)
// sessions(id char(36) pk, userId text ref users.uid, title text null, mode text default 'auto', createdAt, updatedAt, archivedAt null)
// messages(id char(36) pk, sessionId ref, role text, content text, createdAt)  — id = UUIDv7 (keyset cursor)
// runs(id char(36) pk, sessionId ref, status text /* queued|running|completed|failed|cancelled */,
//      promptMessageId char(36) null, attempts int default 0, lastError text null, startedAt null, finishedAt null, createdAt)
// sessionEventMirror(sessionId text, seq text, type text, payload jsonb, ts timestamptz; pk (sessionId, seq))

// client.ts
export function createDb(databaseUrl: string): Db;   // postgres.js + drizzle
export type Db = ReturnType<typeof drizzle>;

// repos.ts
export function newId(): string;                     // UUIDv7 (crypto.randomUUID is v4 — use `uuidv7` npm dep)
export const sessions: {
  create(db: Db, userId: string, title?: string | null): Promise<SessionRow>;
  get(db: Db, sessionId: string, userId: string): Promise<SessionRow | null>; // null on wrong owner (404 rule)
  list(db: Db, userId: string, limit: number, cursor?: string | null): Promise<{ rows: SessionRow[]; nextCursor: string | null }>;
  touch(db: Db, sessionId: string): Promise<void>;
};
export const messages: {
  append(db: Db, m: { sessionId: string; role: MessageRole; content: string }): Promise<MessageRow>;
  page(db: Db, sessionId: string, opts: { limit: number; beforeId?: string | null }): Promise<{ rows: MessageRow[]; nextCursor: string | null }>; // newest-first keyset
};
export const runs: {
  create(db: Db, r: { sessionId: string; promptMessageId: string }): Promise<RunRow>;      // status 'queued'
  activeForSession(db: Db, sessionId: string): Promise<RunRow | null>;                       // queued|running
  claimNext(db: Db, runId: string): Promise<boolean>;  // UPDATE … SET status='running', startedAt=now WHERE id=$1 AND status='queued' RETURNING — false = lost race
  finish(db: Db, runId: string, status: "completed" | "failed" | "cancelled", lastError?: string | null): Promise<void>;
  bumpAttempt(db: Db, runId: string): Promise<number>;
};
export const eventMirror: {
  put(db: Db, e: SessionEvent): Promise<void>;         // onConflict (sessionId,seq) do nothing
  readSince(db: Db, sessionId: string, lastSeq: string | null, limit: number): Promise<SessionEvent[]>;
};
```

- [ ] **Step 1: Write failing repo tests** (`repos.test.ts`, guarded `describe.skipIf(!process.env.TEST_DATABASE_URL)`): migrate fresh schema per run (drizzle-kit `migrate` programmatically against a per-test schema via `pgSchema` search_path — simplest: drop/recreate all tables in `beforeAll`). Tests: session create/get/list-with-cursor paging (3 pages of 2); `get` with wrong userId → null; messages append + `page` newest-first with `beforeId` keyset; `runs.create` → `activeForSession` returns it; `claimNext` twice → second false; `finish` clears `activeForSession`; `eventMirror.put` idempotent on same seq; `readSince(null)` returns all in seq order, `readSince(seq2)` returns after seq2.
- [ ] **Step 2: Run to verify fail.** `bash cloud/scripts/dev-services.sh; cd cloud && TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres pnpm --filter @ovid/db test` — Expected: FAIL (modules missing).
- [ ] **Step 3: Implement** schema/client/repos + add deps (`drizzle-orm`, `postgres`, `uuidv7`, `drizzle-kit` dev). Generate migration SQL: `pnpm --filter @ovid/db exec drizzle-kit generate`. Export a `migrate(dbUrl)` helper used by tests and deploy.
- [ ] **Step 4: Run to verify pass.** Same test command — Expected: all PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): db schema, migrations, session/message/run/event repos"`.

### Task 4: `@ovid/events` — Redis Streams event log

**Files:**
- Create: `cloud/packages/events/src/{eventLog.ts,index.ts}`
- Test: `cloud/packages/events/src/eventLog.test.ts`

**Interfaces:**
- Consumes: `SessionEvent`, `SessionEventType` from `@ovid/shared`.
- Produces:

```ts
export interface EventLog {
  append(sessionId: string, type: SessionEventType, payload: Record<string, unknown>): Promise<SessionEvent>; // XADD + PUBLISH
  readSince(sessionId: string, lastSeq: string | null, limit: number): Promise<SessionEvent[]>; // XRANGE
  subscribe(sessionId: string, onEvent: (e: SessionEvent) => void): Promise<() => Promise<void>>; // PSUBSCRIBE; returns unsubscribe
}
export function createRedisEventLog(redis: IORedis, opts?: { maxLen?: number }): EventLog; // maxLen default 10000, approximate trim (MAXLEN ~)
```

Stream key `sess:{sessionId}:events`; live channel `sess:{sessionId}:live`; envelope stored as single JSON field `e`. `append` fills `seq` (stream id) and `ts`.

- [ ] **Step 1: Write failing tests** (`skipIf(!TEST_REDIS_URL)`): append returns increasing seqs; readSince(null) returns all; readSince(seq1) excludes seq1; subscribe receives appended events; unsubscribe stops delivery; trim: with `maxLen: 5`, after 12 appends `readSince(null)` length ≤ 6 (approximate trim tolerance).
- [ ] **Step 2: Run to verify fail.** `TEST_REDIS_URL=redis://127.0.0.1:6390 pnpm --filter @ovid/events test` — Expected: FAIL.
- [ ] **Step 3: Implement** `createRedisEventLog` with ioredis (separate connection for the subscriber — ioredis pub/sub mode blocks commands).
- [ ] **Step 4: Run to verify pass.** Expected: all PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): Redis Streams session event log with live fanout"`.

### Task 5: `@ovid/queue` — BullMQ definitions

**Files:**
- Create: `cloud/packages/queue/src/{queues.ts,index.ts}`
- Test: `cloud/packages/queue/src/queues.test.ts`

**Interfaces:**
- Consumes: nothing (job payloads are plain JSON).
- Produces:

```ts
export const AGENT_RUNS = "agent-runs";
export interface AgentRunJob { runId: string; sessionId: string; userId: string; prompt: string; }
export const agentRunJobSchema: z.ZodType<AgentRunJob>;
export interface QueueServices { agentRuns: Queue<AgentRunJob>; }
export function createQueues(connection: ConnectionOptions): QueueServices;
export function createAgentRunsWorker(connection: ConnectionOptions, processor: Processor<AgentRunJob>, opts?: { concurrency?: number }): Worker<AgentRunJob>; // default concurrency 8
```

Job options set at add-time by callers: `jobId: runId` (idempotent adds), `priority` (1 = Pro, 2 = Free), `attempts: 5`, `backoff: { type: "custom" }` — but note: model-call retries live inside the processor (spec backoff 3/9/27/60); BullMQ `attempts: 1` for agent-runs to avoid double retry layers; stalled-job recovery (`stalledInterval: 30_000`) redelivers crashed runs.

- [ ] **Step 1: Write failing tests** (`skipIf(!TEST_REDIS_URL)`): add job with `jobId: runId` twice → second add returns same job (dedupe); `agentRunJobSchema` rejects missing `prompt`; worker created via `createAgentRunsWorker` processes an added job (await `worker.on("completed")` with 5 s timeout); `attempts` config equals 1.
- [ ] **Step 2: Run to verify fail**, then **Step 3: Implement**, then **Step 4: verify pass** (`pnpm --filter @ovid/queue test`). Deps: `bullmq`, `zod`.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): BullMQ agent-runs queue definitions"`.

### Task 6: Gateway auth — Firebase verification + WS tickets

**Files:**
- Create: `cloud/apps/gateway/src/{env.ts,auth.ts,tickets.ts}`
- Test: `cloud/apps/gateway/src/{auth.test.ts,tickets.test.ts}`

**Interfaces:**
- Consumes: `@ovid/events` (nothing), ioredis for tickets; firebase-admin.
- Produces:

```ts
// env.ts
export interface GatewayEnv { nodeEnv: string; port: number; authMode: "firebase" | "test"; databaseUrl: string; redisQUrl: string; redisMintUrl: string; mintBaseUrl: string; }
export function loadGatewayEnv(raw: NodeJS.ProcessEnv): GatewayEnv; // throws if authMode 'test' && nodeEnv 'production'

// auth.ts
export interface AuthPrincipal { uid: string; email: string | null; authTime: number; }
export type Verifier = (idToken: string, appCheckToken: string | null) => Promise<AuthPrincipal>;
export function createFirebaseVerifier(app: App): Verifier;      // verifyIdToken + appCheck().verifyToken (App Check required when header present in prod; reject missing in prod)
export function createTestVerifier(): Verifier;                  // parses 'x-test-uid'-style token "test:<uid>"; never constructed when authMode firebase
export function authHook(verifier: Verifier): Fastify preHandlerHookHandler; // reads Authorization Bearer + X-Firebase-AppCheck; 401 {error:{code:'unauthenticated'}} on failure; decorates request.principal

// tickets.ts
export interface TicketStore { mint(uid: string): Promise<string>; verify(ticket: string): Promise<{ uid: string } | null>; } // single-use, 60s TTL, Redis key ws:ticket:{t}
export function createTicketStore(redis: IORedis): TicketStore;
```

- [ ] **Step 1: Write failing tests.** `auth.test.ts`: with a stub `Verifier`, missing header → 401 envelope `unauthenticated`; verifier throw → 401; success decorates `request.principal.uid`. `loadGatewayEnv` throws when `NODE_ENV=production` + `OVID_AUTH_MODE=test`. `tickets.test.ts` (TEST_REDIS_URL): mint→verify returns uid; second verify → null (single-use); verify unknown → null; TTL set (redis `pttl` > 0 and ≤ 60000).
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (firebase-admin initialized from ADC `GOOGLE_APPLICATION_CREDENTIALS`) → **Step 4: Verify pass** (`pnpm --filter @ovid/gateway test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): gateway auth (Firebase ID+App Check) and single-use WS tickets"`.

### Task 7: Gateway REST — sessions, messages, run enqueue, key provisioning

**Files:**
- Create: `cloud/apps/gateway/src/{app.ts,routes/sessions.ts,routes/messages.ts,routes/health.ts,keys.ts}`
- Test: `cloud/apps/gateway/src/routes/{sessions.test.ts,messages.test.ts}`

**Interfaces:**
- Consumes: `createDb`/repos (`@ovid/db`), `createQueues` (`@ovid/queue`), auth/tickets (Task 6), `@ovid/shared` DTOs.
- Produces:

```ts
// app.ts
export interface GatewayDeps { db: Db; queues: QueueServices; verifier: Verifier; tickets: TicketStore; keys: KeyProvider; mint: MintProvisioner; clock?: () => Date; }
export function buildGateway(deps: GatewayDeps): FastifyInstance; // routes registered under /cloud/v1; inject()-testable

// keys.ts — worker & gateway share this interface (exported from gateway for now; moves to @ovid/shared in P9)
export interface KeyProvider { getKeyForUser(uid: string): Promise<string | null>; }       // reads mint Redis db2 GET user:{uid}:key
export interface MintProvisioner { ensureKey(idToken: string, appCheck: string | null): Promise<{ key: string }>; } // POST {mintBaseUrl}/mint forwarding Authorization + X-Firebase-AppCheck; throws on non-2xx passthrough (402/429 envelopes relayed)
export function createMintRedisKeyProvider(redisMint: IORedis): KeyProvider;
export function createHttpMintProvisioner(mintBaseUrl: string): MintProvisioner;

// routes (all behind authHook):
// GET    /cloud/v1/health            → { status:"ok"|"degraded", checks:{ db, redisQ } } (503 when degraded)
// POST   /cloud/v1/auth/ticket       → { ticket } (for WS)
// POST   /cloud/v1/sessions          { title? } → 201 SessionDto
// GET    /cloud/v1/sessions?limit&cursor → Page<SessionDto>   (limit default 30, max 100)
// GET    /cloud/v1/sessions/:id      → SessionDto | 404 not_found (wrong owner = 404)
// POST   /cloud/v1/sessions/:id/messages { content } → 202 SendMessageResponse
//        flow: ensureKey (503/402 passthrough; failure → 409 {code:'key_not_minted'}) → messages.append(user) →
//        runs.create → queues.agentRuns.add({runId,sessionId,userId,prompt:content},{jobId:runId,priority: tier==='free'?2:1})
//        → sessions.touch → 202. Redis add failure → 503 unavailable (message row stays; no run).
// GET    /cloud/v1/sessions/:id/messages?limit&before → Page<MessageDto> (newest-first)
```

- [ ] **Step 1: Write failing route tests** (Fastify `inject`, stub deps: in-memory `Verifier`, real db against TEST_DATABASE_URL behind skipIf, stub `QueueServices` capturing adds, stub `KeyProvider`/`MintProvisioner`). `sessions.test.ts`: create → 201 with UUIDv7-shaped id; list paging cursor walks; other user's session → 404; unauthenticated → 401. `messages.test.ts`: send → 202 `{status:'queued', runId}` and one queue add with `jobId===runId`, priority 2 for free tier / 1 for pro (stub users.tier); send when `ensureKey` throws → 409 `key_not_minted` and no queue add; second send while run active → 202 with new runId (queued behind, Review Focus #4 — ordering guaranteed by FIFO + claimNext); GET messages newest-first with `before` keyset; empty `content` → 400.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** → **Step 4: Verify pass** (`pnpm --filter @ovid/gateway test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): gateway REST — sessions, message send/enqueue, key provisioning passthrough"`.

### Task 8: Gateway WS — multiplexed subscribe with replay-then-live

**Files:**
- Create: `cloud/apps/gateway/src/{ws.ts,routes/wsRoute.ts}`
- Test: `cloud/apps/gateway/src/ws.test.ts`

**Interfaces:**
- Consumes: `TicketStore` (Task 6), `EventLog` (`@ovid/events`), `Db`+`sessions` repo (ownership check), `WsClientMsg`/`WsServerMsg` (`@ovid/shared`).
- Produces:

```ts
// ws.ts
export interface WsDeps { tickets: TicketStore; events: EventLog; db: Db; }
export function handleWsConnection(socket: WebSocket, url: URL, deps: WsDeps): Promise<void>;
// handshake: ?ticket= verified once (single-use) → principal; invalid → send {op:'error',code:'unauthenticated'} then close 4401.
// subscribe: ownership check via sessions.get(sessionId, uid) → null ⇒ {op:'error',code:'forbidden',sessionId} (no close, other subs survive).
// ordering: events.subscribe() FIRST, buffer live events; then readSince(lastEventId ?? null, 500) → flush replay; then flush buffer, dedupe by seq (string compare on stream ids: split '-' numeric); subsequent live events pass through.
// ping → pong; malformed JSON → {op:'error',code:'bad_message'}; 30s server ping interval, close on 2 missed pongs.
// wsRoute.ts registers GET /cloud/ws on the fastify websocket plugin, delegating to handleWsConnection.
```

- [ ] **Step 1: Write failing tests.** Harness: real `buildGateway` with test verifier + real redis (skipIf TEST_REDIS_URL) + stub db ownership map; client = `ws` npm over `server.listen(0)`. Cases: ticket handshake success + replay of 3 pre-existing events in seq order; reconnect with `lastEventId` of event#2 → receives only #3 then live #4 (Review Focus #1); event appended between subscribe and replay flush arrives exactly once (test by appending from a concurrent task during handshake — deterministic version: stub EventLog whose `readSince` awaits a promise resolved after `subscribe` delivers one live event; assert single copy, correct order); ticket reuse → 4401 close; someone else's session → `{op:'error',code:'forbidden'}` and connection stays open; malformed frame → `bad_message`.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** → **Step 4: Verify pass**. Add dep `ws` (dev+prod for client tests), `@fastify/websocket`.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): WS multiplexed session event channel with replay-then-live dedupe"`.

### Task 9: Worker agent-run processor v0 (tool-less streaming loop)

**Files:**
- Create: `cloud/apps/worker/src/{main.ts,runProcessor.ts,liteLlm.ts,index.ts}`
- Test: `cloud/apps/worker/src/{runProcessor.test.ts,liteLlm.test.ts}`

**Interfaces:**
- Consumes: `@ovid/db` (`runs`, `messages`, `eventMirror`), `@ovid/events` (`EventLog`), `@ovid/queue` (`AgentRunJob`), `KeyProvider` shape from Task 7 (import type; duplicated into `@ovid/shared` in P9).
- Produces:

```ts
// liteLlm.ts
export interface ChatMessage { role: "system" | "user" | "assistant"; content: string; }
export interface StreamHandlers { onDelta(text: string): void; }
export interface ModelTransport {
  stream(req: { baseUrl: string; apiKey: string; model: string; messages: ChatMessage[] }, h: StreamHandlers, signal: AbortSignal): Promise<{ finishReason: string | null }>;
}
export function createOpenAiTransport(fetchImpl?: typeof fetch): ModelTransport; // POST {baseUrl}/chat/completions, stream:true, stream_options:{include_usage:true}; SSE parse: skip ':' keep-alives and blank lines; buffer partial lines across chunks; data:[DONE] ends; non-2xx → throw TransientModelError for 429/5xx/network, TerminalModelError otherwise
export class TransientModelError extends Error {}
export class TerminalModelError extends Error {}

// runProcessor.ts
export interface RunDeps { db: Db; events: EventLog; keys: KeyProvider; transport: ModelTransport; litellmBaseUrl: string; defaultModel: string; sleep?: (ms: number) => Promise<void>; }
export function createAgentRunProcessor(deps: RunDeps): (job: { data: AgentRunJob }) => Promise<void>;
// semantics: claimNext(runId) false → return (duplicate/stale). key null → events.append run_failed {code:'key_not_minted'} + runs.finish('failed').
// history: messages.page(all, oldest-first, cap last 100) → ChatMessages. events: run_started {runId}.
// loop: attempt 1..5; per attempt bumpAttempt; transport.stream publishing message_delta {runId, text} per delta;
// success → messages.append(assistant, full text) → message_completed {messageId, content} → runs.finish('completed') → run_completed {runId}.
// TransientModelError → events.append('run_started_retry',{attempt,nextBackoffMs}) ; backoff 3/9/27/60 s (injectable sleep); attempt 5 → run_failed {code:'model_transient_exhausted'} + finish('failed').
// TerminalModelError → run_failed {code:'model_terminal', message} + finish('failed') immediately.
// Every appended event also mirrored via eventMirror.put (history beyond stream retention).
// main.ts: wiring (loadEnv → createDb/EventLog/queues → createAgentRunsWorker(processor) → graceful shutdown on SIGTERM: worker.close()).
```

- [ ] **Step 1: Write failing tests.** `liteLlm.test.ts`: local `http.createServer` emitting SSE in awkward chunks (split mid-`data:` line, a `:keep-alive`, a blank line, `[DONE]`) → deltas concatenated exactly; 429 → `TransientModelError`; 400 → `TerminalModelError`; server closes socket mid-stream → `TransientModelError`. `runProcessor.test.ts` (TEST_DATABASE_URL+TEST_REDIS_URL, stub transport/sleep/clock): happy path event sequence is exactly `run_started, message_delta+, message_completed, run_completed` with assistant message persisted; transient failures ×2 then success → 2 `run_started_retry` events, backoff sleeps [3000, 9000]; 5 transients → `run_failed(model_transient_exhausted)`, run status failed, 5 attempts; terminal → immediate `run_failed(model_terminal)`; missing key → `run_failed(key_not_minted)`; duplicate job (run already claimed) → no events appended.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** → **Step 4: Verify pass** (`pnpm --filter @ovid/worker test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): worker v0 agent-run processor — LiteLLM SSE streaming, retries, event emission"`.

### Task 10: End-to-end integration test

**Files:**
- Create: `cloud/apps/e2e/package.json` (workspace app, test-only), `cloud/apps/e2e/src/spine.test.ts`
- Modify: `cloud/pnpm-workspace.yaml` (already covered by `apps/*`)

**Interfaces:**
- Consumes: `buildGateway` (Tasks 6–8), `createAgentRunProcessor` + `createAgentRunsWorker` (Task 9), all repos.
- Produces: the regression harness every later plan extends.

- [ ] **Step 1: Write the e2e test** (skipIf TEST_DATABASE_URL/TEST_REDIS_URL; mock LiteLLM = `http.createServer` with valid SSE; mint stubs). Flow: build gateway (test auth) listening on port 0; start worker against same db/redis/queues; REST: create session → POST message → 202; WS: ticket → subscribe with `lastEventId:null` → assert ordered `run_started → deltas → message_completed → run_completed`; GET messages shows user+assistant; **disconnect WS mid-run** (use a slow mock transport), reconnect with last received `lastEventId`, assert remaining events arrive exactly once (Review Focus #1 at integration level); **redis-q degraded**: pause via `CLIENT PAUSE`/maxmemory trick or stub queue add to throw → REST send returns 503 `unavailable`, health endpoint reports `degraded` (Review Focus #5).
- [ ] **Step 2: Run to verify fail, then make wiring fixes** (this task may only fix integration wiring — no behavior changes in units; unit tests must stay green). Run: `pnpm --filter @ovid/e2e test` — Expected: PASS.
- [ ] **Step 3: Full check.** `cd cloud && pnpm -r build && pnpm -r test` — Expected: all green.
- [ ] **Step 4: Commit.** `git commit -m "test(cloud): spine e2e — REST send, WS replay/live, degradation behavior"`.

### Task 11: Deploy artifacts — compose, Caddy route, provisioning runbook

**Files:**
- Create: `cloud/deploy/{docker-compose.yml,Dockerfile.gateway,Dockerfile.worker,.env.example,provision.sh,caddy-snippet.conf,DEPLOY.md}`
- Create: `cloud/deploy/backup/{pg_backup.sh,ovid-cloud-backup.service,ovid-cloud-backup.timer}`

**Interfaces:**
- Consumes: built apps (Tasks 1–10).
- Produces: repeatable deploy to `/opt/ovid-cloud`; `ovid_cloud` DB provisioned on the existing Postgres; `/cloud/*` routed by the live Caddy.

- [ ] **Step 1: Compose.** Services: `gateway` (127.0.0.1:8081, healthcheck `GET /cloud/v1/health`, `mem_limit: 1g`, restart unless-stopped), `worker` (no ports, `mem_limit: 2g`), `redis-q` (image `redis:7-alpine`, command `--maxmemory-policy noeviction --appendonly yes --appendfsync everysec --requirepass ${REDIS_Q_PASSWORD}`, volume, `mem_limit: 1536m`, healthcheck `redis-cli -a … ping`), external network `ovid-gateway_default` (alias access to `ovid-gateway-postgres-1` and `ovid-gateway-mint-1` and mint's redis). `.env.example` lists every var: `DATABASE_URL`, `REDIS_Q_URL`, `REDIS_MINT_URL`, `MINT_BASE_URL`, `OVID_LITELLM_BASE`, `OVID_DEFAULT_MODEL`, `GOOGLE_APPLICATION_CREDENTIALS`, `OVID_AUTH_MODE`, `NODE_ENV`.
- [ ] **Step 2: provision.sh.** Idempotent: `docker exec ovid-gateway-postgres-1 psql -U <user> -tc "SELECT 1 FROM pg_database WHERE datname='ovid_cloud'"` → create DB + role `ovid_cloud` with password from env if absent; run migrations (`pnpm --filter @ovid/db exec tsx src/migrate-cli.ts "$DATABASE_URL"` — add this tiny CLI to `@ovid/db` in this task); validate compose (`docker compose config -q`).
- [ ] **Step 3: Caddy snippet + DEPLOY.md.** `caddy-snippet.conf`: inside the existing `api.ovidsi.com` site block: `handle_path /cloud/* { reverse_proxy 127.0.0.1:8081 }` (WS upgrades work through reverse_proxy by default). DEPLOY.md runbook: backup live Caddyfile (`cp Caddyfile Caddyfile.bak-$(date -u +%Y%m%dT%H%M%S)`) → insert snippet → `caddy validate` → `caddy reload` → `curl -sf https://api.ovidsi.com/cloud/v1/health`; rollback = restore backup + reload. Compose up: `docker compose -f cloud/deploy/docker-compose.yml up -d --build`; smoke: ticket+session+message via curl against staging route with a test Firebase token (documented manual step, owner).
- [ ] **Step 4: Backups.** `pg_backup.sh`: `pg_dump` `ovid_cloud` **and** the LiteLLM DB → `zstd -9` → if `OVID_R2_*` env set, upload via `aws s3 cp --endpoint-url` (R2 S3 API); else keep local `/opt/ovid-backups/pg/` with 14-day retention; lockfile guard; exit nonzero on failure (timer `OnFailure` logging). Timer: nightly 03:30 UTC.
- [ ] **Step 5: Verify (dry, non-disruptive).** `docker compose -f cloud/deploy/docker-compose.yml config -q` → OK; `bash -n` on scripts; run `pg_backup.sh` once manually against the live Postgres (read-only operation) → expect a `.dump.zst` that passes `zstd -t`. **Do NOT reload Caddy or create the DB in this step** — activation is Step 6 with the owner.
- [ ] **Step 6: Activate (with owner present).** Run `provision.sh`, compose up, Caddy snippet insert + validate + reload, health curl. Expected: `{"status":"ok"}` from `https://api.ovidsi.com/cloud/v1/health`. Install backup timer (`systemctl enable --now ovid-cloud-backup.timer`).
- [ ] **Step 7: Commit.** `git commit -m "feat(cloud): deploy compose, provisioning, Caddy route, nightly backups"`.

### Task 12: Phase-0 hardening checklist (owner tasks + automatable bits)

**Files:**
- Create: `cloud/deploy/HARDENING.md`

**Interfaces:**
- Consumes: nothing. Produces: the audited checklist closing spec §11 VPS-hardening items; automatable parts scripted where safe.

- [ ] **Step 1: Write HARDENING.md** with checkbox items, each with exact commands and an "owner decision" flag where destructive: (a) **owner** disable `novnc.service`, `vncserver@1.service`, `vsftpd.service` (spec §11; docs record root VNC as previously "accepted risk" — needs explicit re-confirm before disabling); (b) **owner** SSH key-only (`PasswordAuthentication no`) after verifying key login works; (c) **owner** secret rotation checklist per HARDENING_TRACKER public-repo note (Firebase config, signing key, LiteLLM master key, Redis passwords); (d) **automatable** Cloudflare `trusted_proxies` for Caddy (snippet in `caddy-snippet.conf`: `servers { trusted_proxies static <CF ranges file> }` — include the official Cloudflare CIDR list fetch step); (e) **automatable** docker log rotation (`/etc/docker/daemon.json` `log-opts max-size 50m max-file 3` — requires docker restart, flag owner); (f) **owner** uptime alerting for `/cloud/v1/health` + existing `/healthz` (any external pinger; document free option); (g) pin `litellm:main-latest` → current digest in `/opt/ovid-gateway/docker-compose.yml` (owner-approved edit with backup).
- [ ] **Step 2: Apply the two automatable, non-disruptive items now**: add trusted_proxies snippet to `cloud/deploy/caddy-snippet.conf` (applied at next reload) and write `cloud/deploy/backup/README.md` restore procedure (test a restore of the Task-11 backup into a scratch DB: `docker run --rm postgres:16-alpine` + `pg_restore`/`psql` + `zstd -d`; expect tables present).
- [ ] **Step 3: Commit.** `git commit -m "docs(cloud): Phase-0 hardening checklist + backup restore verification"`.

---

## Self-Review Notes (completed per writing-plans skill)

- **Spec coverage:** P0 items (dual Redis, noeviction, backups, healthchecks, hardening, compose) → Tasks 11–12; P1 spine (auth, schema, streams, BullMQ, REST/WS, replay, v0 loop, LiteLLM) → Tasks 2–10. Spec §6.2 ticket flow → Task 6/8; §9 tier priority → Task 7 (priority 1/2); Review Focus items each pinned (noted inline). Scheduler (§8), tools, sandbox, browser, R2, thin client, money ports → later plans per spec §14 (intentionally out of scope here).
- **Type consistency:** `SessionEvent.seq:string` used identically in events/ws/worker; `AgentRunJob` defined once (queue) consumed by gateway Task 7 + worker Task 9; `KeyProvider` defined Task 7, imported by Task 9 (flagged for relocation to shared in P9).
- **Proportion:** bodies omitted except SSE-parse/replay-order semantics where tests alone don't pin the algorithm.
