# Ovid Cloud P9 — Money & Accounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The TS backend owns all money and account surfaces — mint (LiteLLM key provisioning, plans-as-data, windows, anti-abuse, admin console), Play Billing (verify + RTDN), the images ledger/gateway, BYOK escrow, account deletion, shares and reports — and the Python services are decommissioned in spec §13 order; the LiteLLM Python hook (`ovid_pools.py` + `ovid_plans.py`) stays untouched and reads the Redis db2 key-space the new TS mint maintains.

**Architecture:** New app `cloud/apps/mint` (Fastify, two listeners: **public** `127.0.0.1:8091` for the byte-compatible client contracts `/mint /usage /plans /upgrade /v1/models /v1/images/* /billing/*`, and **admin/internal** `127.0.0.1:8092` for `/admin/* /images/admin/* /internal/*`, never routed by Caddy — the localhost-only console rule). A separate app (not folded into the gateway) because: money code has a different security posture (LiteLLM master key, admin master key, internal HMAC secret — none of which belong in the stateless chat gateway), it owns background loops (slow-mode sweeper 30 s, spend monitor 5 min, card-manager probes), and it mirrors the Python topology so Caddy flips per route group (`@mint`/`@usage`/`@images`/`/billing/*`) strangler-style with mint LAST. Postgres (`ovid_cloud`) is the durable authority for plans/settings/overrides/purchases/ledgers; **Redis db2 is a request-time projection** re-synced at boot and on every change, Postgres wins disagreements (Ruling Q4). Gateway/worker key flows switch from client-token forwarding to server-to-server internal minting (Ruling Q5). `img-edit-shim` stays untouched (Ruling Q9). Account lifecycle, shares and reports mount on the gateway at their exact legacy paths; the deletion sweeper runs in the worker.

**Tech Stack:** Node 22, pnpm workspaces, TypeScript strict, Vitest, Fastify 5, Drizzle ORM (postgres.js), ioredis, decimal.js (all money), firebase-admin, googleapis (androidpublisher v3), google-auth-library (RTDN OIDC), node:crypto (AES-256-GCM envelopes, HMAC), BullMQ 5, zod. Python side (read-only): `server/mint/litellm_hook/ovid_pools.py` + `ovid_plans.py` for the hook-contract harness.

**Spec:** `docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md` (D2/D3/D6/D7, G9–G11, §10, §13). Binding ledger rulings Q4/Q5/Q9 in `.superpowers/sdd/2026-10-15-ovid-cloud-p0-p1-spine/progress.md`. Python contracts to preserve: `server/mint/mint.py` + `README.md`, `server/billing/`, `server/images/` (incl. `deploy/images_gateway.py`), `server/account/`, `server/shares/`, `server/reports/`, `server/sync/endpoints.py` (canonicalizer only — sync itself is DELETED per D6, not ported).

## Global Constraints

- Monorepo conventions copied from the P1 plan: new code only under `cloud/`; wire format JSON **camelCase**, ids **UUIDv7**, timestamps ISO-8601 UTC **for NEW endpoints only** — every legacy port (`/mint /usage /plans /upgrade /billing/* /v1/images/* /v1/models /shares /s/* /v1/reports /account/*` and all admin APIs) keeps its **exact** Python snake_case shapes, status codes, headers and error strings; commit after every task; `cd cloud && pnpm -r build && pnpm -r test` green before each commit.
- MONEY: exact decimal arithmetic only — **decimal.js pinned as the representation** (never binary floats, never integer-microdollar truncation: the Python contracts store arbitrary-digit decimal strings and `round(x, 6)` half-even). All money crosses module boundaries as decimal.js values or exact strings; float-typed legacy JSON fields (`daily_spent_usd` etc.) are produced via `pyRound6()` (half-even) from decimal.js. Ported from `server/images/service.py:money/discounted/exact_sum` semantics.
- **Redis db2 key-shape compatibility with `ovid_pools.py`/`ovid_plans.py` is a HARD contract.** The hook is NOT modified. Exact key inventory: `config:limits` (hash: `plans`, `auto_oss_members`, `free_monthly_cap_usd`, `normal_rpm/tpm/parallel`, `slow_rpm/tpm/parallel`, `hard_ceiling_mult`, `est_input_tokens`, `est_output_tokens`, `est_image_tokens`), `config:base_daily_usd`, `config:model_groups`, `user:{uid}:tier|dailyUsd|pools|monthlyCapUsd|banned|email|keyid|key|web:keyid|web:key`, `email:{email}`, `pool:{uid}:start|spend|auto`, `pools:slow` (hash uid→until-epoch), `pools:slow_pending` (set), `usagecache:{uid}` (15 s), `audit:admin` (capped 5000), `config:reapply_status`, `config:reset_status`, `ovid:uids` (set), plus anti-abuse keys `mintrate:{ip}:{win}`, `ipacct:{ip}`, `ipnew:{ip}:{win}`, `abuse:uid:{uid}`, `abuse:ip:{ip}`, `ban:ip:{ip}`, `newkeys:{win}`, `mintlock:{ns}{uid}`, `alertsent:{kind}:{bucket}`, `spend:daybase:{day}`. Value formats: numbers as Python-`str()`-equivalent strings (floats keep `.0`), epochs as int/`.3f` strings parseable by `float()`, JSON with the exact field names `ovid_plans.py` reads.
- Client-visible error contracts preserved VERBATIM: hook-side 429 `daily_limit_reached` (`error.type`, `provider_specific_fields.resets_at`, headers `x-ovid-error`/`x-ovid-resets-at`/`retry-after` — pinned by the real-hook harness, Task 17); 402 `image_limit_reached`/`budget_exceeded`, 402 `"monthly free limit reached"` from `/mint`; 409 `image_request_pending` + `receipt` body; `X-Ovid-Gateway: 2` + `Cache-Control: no-store` on `/v1/models` and catalog responses; billing status matrix (200/202/400/401/403/409/503 with exact codes); shares/reports/account `detail`-style bodies and hardened headers.
- Secrets via env ONLY, never code or DB: `LITELLM_MASTER_KEY`, `OVID_ADMIN_MASTER_KEY` (console), `OVID_INTERNAL_API_SECRET`, `OVID_MASTER_KEY` (escrow, 64-hex = 32 bytes), `OVID_PLAY_SERVICE_ACCOUNT_FILE`, `GOOGLE_APPLICATION_CREDENTIALS`, `INFERHUB_API_KEY`, `OVID_RTDN_*`, alert tokens. A test greps every new source file for secret literals (port of the mint README rule).
- Production boundary: NO `docker compose up`, NO Caddy `reload`, NO migration script execution, NO container stops without the owner present — activation steps are explicitly gated like P1 Task 11 Step 6 ("pause for explicit owner approval").
- Test env URLs (disposable services only, never live): `TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres`, `TEST_REDIS_URL=redis://127.0.0.1:6390`, `TEST_MINT_REDIS_URL=redis://127.0.0.1:6390/9` (db2-projection tests flush db9 only; the db index is URL-carried, code never hardcodes 2). Start via `bash cloud/scripts/dev-services.sh`.
- Every ported contract carries tests derived from the Python suites — named per task below (`server/mint/tests/*`, `server/billing/tests/test_billing.py`, `server/images/tests/*`, `server/account/tests/*`, `server/shares/tests/*`, `server/reports/tests/test_reports.py`, `server/sync/tests/test_endpoints.py`).
- `img-edit-shim` container and `server/mint/litellm_hook/*` are NOT modified by any task. LiteLLM is not re-implemented (NG5).

## Review Focus

1. **Redis db2 shape drift silently disarms the unmodified Python hook** — a wrong field name, `0` vs `0.0`, or non-`float()`-parseable epoch in `config:limits`/`user:{uid}:pools`/`pool:{uid}:start` makes the hook fail open (allowance unenforced) with zero errors anywhere. Expected: hook reads TS-written state identically to Python-written state. Pinned by Task 4 shape-contract tests + Task 17 real-hook harness running `ovid_pools.py` against TS-written db2.
2. **Binary-float contamination at money boundaries** — `JSON.parse` of `usage.cost`, the ×0.30 discount, budget sums, `round(x,6)` in `/usage`, EXAT arithmetic. Expected: exact decimal digits end-to-end, Python-identical strings for `charged`. Pinned by Task 1 golden vectors from `test_costing.py`, Task 12 exact-sum/reservation tests, Task 5 `pyRound6` half-even tests.
3. **Tier lifecycle races** — missed RTDN must never leave a paid tier forever; revoke/refund must be sticky against later Play reads; redelivered notifications must be idempotent; another account replaying a purchase token gets 409. Expected: self-expiring Redis key EXAT expiry+600 s, Postgres ledger authoritative. Pinned by Task 10 tests (ported `test_billing.py` matrix + EXAT/sticky/redelivery).
4. **Banned or deleting users keep spending through cached LiteLLM keys** — the documented Python defect: auto-ban (`record_strike`) only set the Redis flag; only admin ban blocked keys. Expected: EVERY ban path blocks the LiteLLM keys (`/key/block`), deletion fences mint/upgrade/billing/images admission, and old keys stop working after the fence. Pinned by Task 7 auto-ban-blocks-keys test and Task 15 fence/access-guard/checkpoint tests.
5. **Image receipts/idempotency regressions double-charge or lose paid work across crash windows** — an `unknown` reservation must never expire or auto-resubmit, replay must return the original result, settlement after account deletion must charge but not republish. Expected: exactly the Python ledger semantics. Pinned by Task 12/13 tests ported from `parallel_images_receipts_test.py` + `test_gateway_admission.py`.

---

### Task 1: `@ovid/money` — exact decimal core

**Files:**
- Create: `cloud/packages/money/package.json`, `tsconfig.json`, `src/{index.ts,money.ts,pyCompat.ts}`
- Test: `cloud/packages/money/src/{money.test.ts,pyCompat.test.ts}`

**Interfaces:**
- Consumes: Task-1-style workspace scaffolding (P1 convention); dep `decimal.js`.
- Produces (imported by Tasks 5, 10, 12, 13, 14 as `@ovid/money`):

```ts
export type Money = Decimal;                       // decimal.js instance, always finite, >= 0, normalized via money()
export class InvalidMoneyError extends Error {}    // callers map to their contract (images: 502 invalid_image_response)
export function money(value: string | number | Decimal): Money;   // port of service.py money(): rejects float/bool-typed JS numbers that are non-finite, negative, >128 digits, exponent outside ±128; strings/ints parsed exactly
export function discounted(value: Money): Money;   // value × Decimal("0.30") at precision = digits(value)+2, ROUND_HALF_EVEN (Python localcontext parity)
export function exactSum(values: Money[]): Money;  // precision = max(adjusted) - min(exponent) + len(str(n)) + 2
export function positiveCost(value: unknown, bound?: Money | null): Money | null; // port of costing.positive_cost: null on bool/non-finite/negative/zero; >SANITY_MAX(1000) null when no bound; min(value,bound) otherwise
export const SANITY_MAX: Money;                    // Decimal("1000")
export function pyRound(value: Money | number, places: number): number; // Python round(): ROUND_HALF_EVEN, then Number
export function pyRound6(value: Money | number): number;                // pyRound(v, 6) — /usage float fields
export function pyNumStr(n: number): string;       // Python str(float) parity for bounded settings values: 3 → "3.0", 0.15 → "0.15"
```

- [ ] **Step 1: Write failing tests** (`money.test.ts`). Golden vectors transcribed from `server/images/tests/test_costing.py` and `service.py` semantics: `money("0.1")×discounted → "0.0300"` (exact string via `.toString()`, digits+2 precision); `money(0.1 as number-float)` — JS numbers ARE accepted only via `String(value)` conversion pin: `money(0.1).toString() === "0.1"`; rejects: negative, `"1e400"`, `Infinity`, NaN, bool-shaped, 129-digit strings → `InvalidMoneyError`; `exactSum([money("0.1"),money("0.2")]).toString() === "0.3"` (the float-poisoning canary); `positiveCost("0", null) === null`, `positiveCost("1500", null) === null`, `positiveCost("1500", money("1000")).toString() === "1000"`, `positiveCost(true as unknown) === null`. `pyCompat.test.ts`: `pyRound(2.5, 0) === 2` and `pyRound(3.5, 0) === 4` (half-even, NOT half-up); `pyRound6(1.234567895)` matches Python `round(1.234567895, 6)`; `pyNumStr(3) === "3.0"`, `pyNumStr(0.15) === "0.15"`, `pyNumStr(100000) === "100000.0"`.
- [ ] **Step 2: Run to verify fail.** `cd cloud && pnpm install && pnpm --filter @ovid/money test` — Expected: FAIL (modules missing).
- [ ] **Step 3: Implement.** Package scaffold per P1 Task-1 conventions (`name: "@ovid/money"`, `type: module`, build `tsc -p tsconfig.json`, test `vitest run`); add to no other package yet. Configure decimal.js per call via `Decimal.clone({ precision, rounding: Decimal.ROUND_HALF_EVEN })` — never mutate global config.
- [ ] **Step 4: Run to verify pass.** Same command — Expected: PASS. Then `pnpm -r build && pnpm -r test`.
- [ ] **Step 5: Commit.** `git add cloud/packages/money && git commit -m "feat(cloud): @ovid/money exact decimal core (Python Decimal parity, golden vectors)"`

### Task 2: `@ovid/db` — money & accounts schema + repos

**Files:**
- Modify: `cloud/packages/db/src/schema.ts`, `cloud/packages/db/src/repos.ts`, `cloud/packages/db/src/index.ts`
- Create: `cloud/packages/db/drizzle/` (new generated migration), `cloud/packages/db/src/moneyRepos.ts`
- Test: `cloud/packages/db/src/moneyRepos.test.ts`

**Interfaces:**
- Consumes: `Db`, `newId()` (existing); `@ovid/money` types appear only as strings in columns.
- Produces (drizzle tables + repo namespaces; exact DDL column details are builder latitude per spec §16, the SHAPES below are authoritative):

```ts
// schema.ts additions (all timestamptz precision 3 like existing; money columns are `text` holding exact decimal strings; epoch-second columns are bigint):
// plans(id text pk, name text, priceUsd text, enabled boolean, aliases jsonb string[], windowHours integer, mult text, slowMode boolean, autoOss boolean, position integer)
// mintSettings(id integer pk default 1 /*singleton*/, baseDailyUsd text, scalars jsonb, autoOssMembers jsonb, updatedAt)
// userPlanOverrides(uid text pk → users.uid, dailyUsd text null, monthlyCapUsd text null, pools jsonb null /*{mult?,window_hours?,slow_mode?,auto_oss?} snake_case = Redis shape*/, updatedAt)
// users ALTER: + tierExpiresAt timestamptz(3) null, + bannedReason text null ("admin"|"auto")
// mintAudit(id char(36) pk uuidv7, at, actor text, action text, target jsonb null, before jsonb null, after jsonb null, ip text null)
// billingPurchases(token text pk, uid text null, productId text, tier text, status text /*active|pending|expired|revoked|replaced*/, expiresAt bigint null, autoRenewing boolean, linkedToken text null, accountHash text null, updatedAt bigint)  + index(uid)
// imageJobs(account text, request text, fingerprint text, state text /*pending|unknown|done|failed*/, reserved text, charged text default '0', actual text null, response jsonb null, servedModel text null, budgetWindow text, replayUntil bigint null, receiptUntil bigint null, createdAt bigint; pk(account,request)) + partial indexes on replayUntil/receiptUntil
// imageDeletedAccounts(account text pk, deletedAt bigint)
// imageCards(model text pk, fingerprint text, state text, card jsonb, priced boolean null, editTransport text null, updatedAt bigint, probedAt bigint null)
// imageCardHistory(id char(36) pk, model text, fingerprint text, state text, card jsonb, at bigint)
// imageProbeLog(id char(36) pk, model text, probe text, ok boolean, errorClass text null, latencyMs integer null, costUsd text, at bigint)
// imageProbeState(model text pk, attempts integer, nextAttemptAt bigint, lastError text null)
// shares(token char(43) pk, ownerUid text, sessionId text, requestId text, content jsonb null /*{messages:[{role,content}]}*/, messageCount integer, createdAt, expiresAt, revokedAt null, purgedAt null, forkOfToken char(43) null; unique(ownerUid,requestId)) + index(ownerUid)
// shareForks(token char(43), recipientUid text, requestId text, sessionId text, createdAt; pk(token,recipientUid,requestId))
// reports(id char(36) pk uuidv7, reporterUid text, requestId text, kind text, reason text, details text, excerpt text, targetId text null, model text null, status text default 'open', createdAt; unique(reporterUid,requestId))
// accountDeletions(uid text pk, state text, deleteAfter bigint, record jsonb, updatedAt)
// byokKeys(id char(36) pk uuidv7, userId text → users.uid, providerId text, endpoint text, label text null, wrappedDek text, iv text, ciphertext text, tag text, status text default 'active', lastTestAt null, lastTestOk boolean null, createdAt) + index(userId)

// moneyRepos.ts
export const plansRepo: {
  list(db: Db): Promise<PlanRecord[]>;                       // ordered by position
  upsert(db: Db, p: PlanRecord): Promise<void>;
  setEnabled(db: Db, id: string, enabled: boolean): Promise<void>;
  getSettings(db: Db): Promise<MintSettingsRecord | null>;
  saveSettings(db: Db, s: MintSettingsRecord): Promise<void>; // upsert singleton
  getOverride(db: Db, uid: string): Promise<OverrideRecord | null>;
  saveOverride(db: Db, uid: string, o: Partial<OverrideRecord> | null): Promise<void>; // null fields = clear
  allUids(db: Db): Promise<string[]>;                         // users with any state (replaces ovid:uids scans for reapply-all)
};
export const billingPurchases: {
  get(db: Db, token: string): Promise<PurchaseRow | null>;
  record(db: Db, token: string, ent: EntitlementFields, now: number, uid?: string | null): Promise<PurchaseRow>; // upsert; STICKY revoked/replaced never overwritten; linkedToken → old token set replaced/tier free/autoRenewing false; owner mismatch with explicit uid → throws PurchaseConflictError
  mark(db: Db, token: string, status: "revoked" | "replaced", now: number): Promise<PurchaseRow | null>;
  effective(db: Db, uid: string, now: number): Promise<PurchaseRow | null>; // best active unexpired: highest TIER_RANK then latest expiry
};
export const imageJobsRepo: { /* consumed via the Task-12 ImageLedger wrapper; raw row access for migration scripts */ };
export const sharesRepo: {
  create(db, ownerUid, body, opts: { now; ttlSeconds }): Promise<ShareReceiptRow>;  // dedup on (ownerUid,requestId): identical → same receipt; changed content or revoked/expired → ShareConflictError(409)
  list(db, ownerUid, sessionId?: string | null): Promise<ShareReceiptRow[]>;        // active only
  update(db, ownerUid, token, body): Promise<ShareReceiptRow>;
  revoke(db, ownerUid, token): Promise<void>;                                        // idempotent for owner; wrong owner/unknown → ShareNotFoundError(404); clears content
  fork(db, recipientUid, token, requestId): Promise<{ sessionId: string }>;          // idempotent per (token,recipient,requestId); revoked/expired → ShareConflictError
  publicSnapshot(db, token): Promise<{ messages: { role: string; content: string }[] } | null>; // null on unknown/revoked/expired/purged
  purgeExpired(db, limit: number): Promise<number>;
  deleteAccount(db, uid): Promise<void>;                                             // erase content + permanent tombstone semantics (rows kept, content null, purgedAt set)
  counts(db, ownerUid): Promise<{ active: number; lifetime: number }>;
};
export const reportsRepo: {
  create(db, reporterUid, body): Promise<{ id: string; created: boolean }>;          // dedup on (reporterUid,requestId) → created:false
  listOpen(db, limit: number): Promise<ReportRow[]>;
};
export const byokKeysRepo: {
  create(db, row: ByokKeyInsert): Promise<ByokKeyRow>;
  list(db, userId: string): Promise<ByokKeyRow[]>;                                   // never selects ciphertext into gateway responses (route-level projection)
  get(db, id: string, userId: string): Promise<ByokKeyRow | null>;                   // null on wrong owner
  remove(db, id: string, userId: string): Promise<boolean>;
  setTestResult(db, id: string, ok: boolean, at: Date): Promise<void>;
};
export const accountDeletions: {
  due(db: Db, now: number): Promise<string[]>;   // exact Python ordering: next_attempt, attempts, delete_after, uid; LIMIT 100; eligibility = (state in pending/fenced/deleting AND delete_after<=now) OR (state='cancelled' AND record->>'fence_owned'='true')
  get(db: Db, uid: string): Promise<DeletionRecord | null>;
  save(db: Db, row: DeletionRecord): Promise<void>;
};
export function withUidLock<T>(db: Db, uid: string, fn: (tx: Db) => Promise<T>): Promise<T>; // dedicated connection: SET lock_timeout='30s'; SELECT pg_advisory_lock(hashtextextended($uid, 714031)); … unlock in finally (same seed 714031 as Python)
```

- [ ] **Step 1: Write failing repo tests** (`moneyRepos.test.ts`, `describe.skipIf(!process.env.TEST_DATABASE_URL)`, drop/recreate schema in `beforeAll` per existing `repos.test.ts` pattern): plans upsert/list order + settings singleton round-trip; `billingPurchases.record` sticky — record active then record with status expired over a `revoked` row → stays revoked/tier free; linkedToken marks old row replaced; `effective` picks higher tier then later expiry; conflicting uid → `PurchaseConflictError`; shares create-dedup (same requestId+content → identical receipt; changed content → conflict), quota counts, revoke keeps receipt row, purgeExpired clears content past expiry, deleteAccount tombstones; reports dedup `created:false`; byokKeys wrong-owner get → null; `withUidLock` serializes two concurrent increments (second sees first's write); accountDeletions.due ordering with 3 rows (poison row with high attempts sorts after unattempted).
- [ ] **Step 2: Verify fail.** `bash cloud/scripts/dev-services.sh; cd cloud && TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres pnpm --filter @ovid/db test` — Expected: FAIL.
- [ ] **Step 3: Implement** schema + repos; generate migration: `pnpm --filter @ovid/db exec drizzle-kit generate`; export from `index.ts`.
- [ ] **Step 4: Verify pass.** Same command — Expected: PASS (existing repos tests stay green).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): db schema+repos for plans, billing, images ledger, shares, reports, deletions, byok"`

### Task 3: `cloud/apps/mint` scaffold + LiteLLM admin client

**Files:**
- Create: `cloud/apps/mint/package.json`, `tsconfig.json`, `src/{index.ts,main.ts,env.ts,app.ts,litellmAdmin.ts,alerts.ts}`
- Test: `cloud/apps/mint/src/{env.test.ts,litellmAdmin.test.ts,app.test.ts}`
- Modify: `cloud/deploy/docker-compose.yml` (add `mint` service — build only, activation stays owner-gated), `cloud/deploy/.env.example`

**Interfaces:**
- Consumes: `@ovid/db`, `@ovid/money`, ioredis, firebase-admin (P1 gateway pattern).
- Produces:

```ts
// env.ts
export interface MintEnv {
  nodeEnv: string; host: string; publicPort: number;   // default 8091
  adminPort: number;                                    // default 8092
  databaseUrl: string; redisDb2Url: string;             // URL carries the db selector (prod: …/2; tests: …/9)
  litellmBaseUrl: string; litellmMasterKey: string;
  adminMasterKey: string;                               // OVID_ADMIN_MASTER_KEY (console)
  internalApiSecret: string;                            // OVID_INTERNAL_API_SECRET (Task 9)
  firebaseProjectId: string; appcheckEnabled: boolean; appcheckApps: Record<string, "android" | "web">; // OVID_APPCHECK_APPS "android:<id>,web:<id>"
  allowTestUpgrade: boolean; publicBaseUrl: string;     // default "https://cloud.dhanuksoftwares.com/v1"
  alertTelegramBotToken: string; alertTelegramChatId: string; alertWebhookUrl: string; dailySpendAlertUsd: number;
  mintStateDir: string; reapplySyncMax: number; auditMax: number; usageCacheS: number; sweepS: number;
  webTeamDailyUsd: number;
  abuse: { mintCallsPerIp: number; mintWindowS: number; newAccountsPerIpPerWindow: number; signupVelocityWindowS: number; ipAccountWindowS: number; abuseStrikeLimit: number; abuseWindowS: number; globalNewkeysPerWindow: number; newkeyWindowS: number }; // defaults 40/3600/12/600/86400/20/3600/500/3600 exactly as mint.py
  play: { serviceAccountFile: string | null; packageName: string; products: Record<string, string> | null; rtdnAudience: string | null; rtdnServiceAccount: string | null; rtdnSharedSecret: string | null; requireAccountId: boolean };
  images: { maxUpstreamCostUsd: string | null; inferhubApiKey: string | null; directEditHosts: string; editCostUsd: string | null; probeKey: string | null; probeMaxUsd: number; probeDailyUsd: number; probeTtlS: number; probeStaggerS: number; probeMaxSizes: number };
}
export function loadMintEnv(raw: NodeJS.ProcessEnv): MintEnv; // throws naming the offending var; refuses allowTestUpgrade when nodeEnv==="production"

// litellmAdmin.ts — thin typed wrapper over the on-box LiteLLM admin API (all calls carry Authorization: Bearer masterKey)
export interface LiteLlmAdmin {
  keyGenerate(body: Record<string, unknown>): Promise<{ key: string; token?: string }>;
  keyUpdate(body: Record<string, unknown>): Promise<void>;          // non-2xx logged, not thrown (Python parity: key/update failures print status)
  keyInfo(key: string): Promise<KeyInfo | null>;                    // 404/401/403 → null
  keyBlock(key: string): Promise<number>; keyUnblock(key: string): Promise<number>; keyDelete(keys: string[]): Promise<number>; // return status
  userInfo(userId: string): Promise<{ spend: number; budget_duration?: string | null } | null>;
  userUpdate(body: Record<string, unknown>): Promise<number>;
  teamNew(body: Record<string, unknown>): Promise<{ team_id: string }>; teamUpdate(body: Record<string, unknown>): Promise<number>;
  spendLogs(params: { key: string; start_date: string; end_date: string }): Promise<SpendLogRow[]>;
  modelInfo(): Promise<ModelInfoRow[]>;                              // GET /model/info
  globalSpend(): Promise<number>;
  rawModels(authorizationHeader: string): Promise<{ status: number; body: unknown; text: string }>; // GET /v1/models with the USER's key (Task 6 passthrough)
}
export function createLiteLlmAdmin(baseUrl: string, masterKey: string, fetchImpl?: typeof fetch): LiteLlmAdmin;

// alerts.ts — port of mint.py alert(): at most once per everyS per kind via Redis SETNX alertsent:{kind}:{bucket}; logs "[mint] ALERT {kind}: …"; fires Telegram/webhook without awaiting (never throws)
export function createAlerter(redis: Redis, env: MintEnv): (kind: string, message: string, everyS?: number) => Promise<void>;

// app.ts
export interface MintDeps { db: Db; redis: Redis; litellm: LiteLlmAdmin; env: MintEnv; alerter: Alerter; verifyIdentity: MintIdentityVerifier; clock?: () => Date; fetchImpl?: typeof fetch; }
export function buildMintApps(deps: MintDeps): { publicApp: FastifyInstance; adminApp: FastifyInstance }; // both inject()-testable; error handler maps HttpContractError {status, detail|body, headers} verbatim (legacy shapes, NOT the /cloud ApiError envelope)
export class HttpContractError extends Error { constructor(readonly status: number, readonly detail: string, readonly headers?: Record<string, string>) } // FastAPI HTTPException parity: body {"detail": string}
```

- [ ] **Step 1: Write failing tests.** `env.test.ts`: defaults match mint.py (publicPort 8091, adminPort 8092, abuse defaults, `PUBLIC_BASE_URL` default); throws on missing `LITELLM_MASTER_KEY`/`OVID_ADMIN_MASTER_KEY`/`OVID_INTERNAL_API_SECRET`; `ALLOW_TEST_UPGRADE=true` + `NODE_ENV=production` → throws. `litellmAdmin.test.ts` (local `http.createServer` mock per P1 Task-9 pattern): keyGenerate posts `/key/generate` with Bearer master key and returns `{key,token}`; keyUpdate 4xx → resolves (logged) not throws; keyInfo 404 → null; spendLogs maps query params `key/start_date/end_date`; rawModels forwards the user's Authorization untouched. `app.test.ts`: `buildMintApps` → publicApp inject `GET /healthz` → `{"ok":true}`; adminApp inject unknown route → 404; a route throwing `HttpContractError(429,"x")` → body `{"detail":"x"}`.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (deps: fastify, ioredis, firebase-admin, decimal.js, zod, `workspace:*` @ovid/db/@ovid/money/@ovid/shared; compose service `mint`: build `Dockerfile.mint`, ports `127.0.0.1:8091:8091` and `127.0.0.1:8092:8092`, external network `ovid-gateway_default` for redis/litellm access, `mem_limit: 1g`, volume `mintdata:/data` — DO NOT `up`, activation is Task 18) → **Step 4: Verify pass** (`pnpm --filter @ovid/mint test`) → **Step 5: Commit.** `git commit -m "feat(cloud): mint app scaffold, env, LiteLLM admin client, alerts"`

### Task 4: Settings authority (Postgres) + Redis db2 projection + plan math port

**Files:**
- Create: `cloud/apps/mint/src/{planMath.ts,settings.ts,projection.ts}`
- Test: `cloud/apps/mint/src/{planMath.test.ts,settings.test.ts,projection.test.ts,hookContract.test.ts}`

**Interfaces:**
- Consumes: `plansRepo` (Task 2), `pyNumStr/pyRound` (`@ovid/money`), Redis (db2 URL from env).
- Produces (used by Tasks 5–10, 13):

```ts
// planMath.ts — faithful TS port of server/mint/ovid_plans.py. Field names inside these structures stay snake_case (wire-compat with the hook's JSON reads); this is a documented exception to camelCase.
export interface PlanData { id: string; name: string; price_usd: number; enabled: boolean; aliases: string[]; window_hours: number; mult: number; slow_mode: boolean; auto_oss: boolean; }
export interface Settings { free_daily_usd: number; free_monthly_cap_usd: number; est_input_tokens: number; est_output_tokens: number; est_image_tokens: number; slow_rpm: number; slow_tpm: number; slow_parallel: number; normal_rpm: number; normal_tpm: number; normal_parallel: number; hard_ceiling_mult: number; auto_oss_members: { model: string; weight: number }[]; plans: PlanData[]; }
export interface Pools { plan_id: string; window_hours: number; all: number; slow_mode: boolean; auto_oss: boolean; }
export type PoolsOverride = { mult?: number | null; window_hours?: number | null; slow_mode?: boolean | null; auto_oss?: boolean | null };
export function seedPlans(paidWindowHours?: number): PlanData[];          // exact ovid_plans.seed_plans values (free 1×24h; starter 3× price 5 alias 3x; pro 23× price 25 alias 7x auto_oss; max 43× price 60 alias 15x auto_oss)
export function parseSettings(hash: Record<string, string>, baseRaw: string | null, seeds?: Partial<Settings>): Settings; // unset → seeds; invalid stored plans → seedPlans; invalid members → []
export function serializeSettings(s: Settings): { baseDaily: string; fields: Record<string, string> }; // scalars via pyNumStr; plans/auto_oss_members via JSON.stringify with keys sorted like Python json.dumps(sort_keys=True) for plan objects
export function validateSettings(s: Settings): Settings;                  // bounds per SCALARS/PLAN_NUMBERS tables; 'free' required + must stay enabled; unique ids+aliases
export function validatePlan(p: unknown): PlanData; export function validateMembers(m: unknown): { model: string; weight: number }[];
export function findPlan(s: Settings, tier: string | null | undefined): PlanData; // id or alias; unknown → free; disabled plans still apply to their users
export function storedTier(p: PlanData): string;                          // first alias else id
export function windowStr(hours: number): string;                         // `${h/24}d` when h%24===0 && h>=48 else `${h}h`
export function userPools(s: Settings, plan: PlanData, freeDaily: number, override?: PoolsOverride | null): Pools; // all = pyRound6(freeDaily*mult*hours/24)
export function keyBudget(pools: Pools, s: Settings): number;             // slow_mode → pyRound6(all*hard_ceiling_mult)
export function poolState(pools: Pools, spent: number, capLeft?: number | null): { all: { cap: number; spent: number; remaining: number }; slow_mode: boolean };
export function decide(pools: Pools, spent: number): { action: "allow" } | { action: "reject"; code: "daily_limit_reached" };
export function pickAutoMember(members: { model: string; weight: number }[], known: Set<string> | null, rng?: () => number): [string, string[]] | null; // weighted pick; rest sorted by weight desc
export const AUTO_MODEL = "auto";
export const DB2 = { LIMITS_HASH: "config:limits", BASE_BUDGET_KEY: "config:base_daily_usd", SLOW_HASH: "pools:slow", SLOW_PENDING: "pools:slow_pending", MODEL_GROUPS_KEY: "config:model_groups" };
export function poolKeys(uid: string): { start: string; spend: string; auto: string }; // pool:{uid}:start|spend|auto

// settings.ts — Postgres = durable authority (Ruling Q4)
export function getSettings(deps: { db: Db }): Promise<Settings>;              // plansRepo → Settings; seeds applied when table empty (ensureDefaultSettings: ADD-only, never overwrites)
export function storeSettings(deps: { db: Db; redis: Redis }, s: Settings): Promise<Settings>; // validateSettings → save Postgres → publishToRedis → drop usagecache:* for affected? (no: cache TTL 15 s rides out)
export function getOverride(deps, uid): Promise<PoolsOverride | null>;
export function userFreeDaily(deps, uid): Promise<number>;                     // override dailyUsd ?? free_daily_usd

// projection.ts — the db2 request-time projection
export interface ReconcileReport { rewritten: string[]; identical: number; conflictsResolvedFromPostgres: number; }
export function createProjection(deps: { db: Db; redis: Redis }): {
  publishSettings(): Promise<void>;                 // HSET config:limits + SET config:base_daily_usd from serializeSettings(getSettings())
  resyncAtBoot(): Promise<ReconcileReport>;         // full re-publish; any db2 value disagreeing with Postgres is overwritten from Postgres (Q4: Postgres wins) and counted
  publishUserTier(uid: string, tier: string | null, expiresAtEpoch: number | null): Promise<void>; // SET user:{uid}:tier (+ tier_expires_at) EXAT expiresAt+600, or DEL both when tier null/free
  publishUserState(uid: string): Promise<void>;     // dailyUsd/pools/monthlyCapUsd/banned/email keys from Postgres overrides + users row
  publishModelGroups(names: string[]): Promise<void>; // SET config:model_groups = JSON array sorted (only when changed)
  importFromRedisOnce(): Promise<{ imported: { users: number; plans: boolean; settings: boolean } }>; // ONE-SHOT seeding mode (Task 18 migration): reads live db2 into Postgres for rows that don't exist yet; never deletes Redis keys
};
```

- [ ] **Step 1: Write failing tests.** `planMath.test.ts` — ports of `server/mint/tests/test_limits.py` + `test_hook.py` plan-math cases: findPlan by alias `7x`→pro; unknown tier→free; disabled plan still applies to its current user; storedTier(pro)==="7x"; windowStr(24)==="24h", (720)==="30d", (36)==="36h"; userPools(0.15 base, pro mult 23, 24h).all===3.45 and override mult 2 wins; keyBudget slow_mode ×3 ceiling; decide at exact boundary (spent===all → reject unless slow_mode); pickAutoMember with known-set filtering, weight ordering of fallbacks, `null` when no usable member; validateSettings rejects missing free plan, duplicate alias, free disabled; validatePlan bounds (`mult` 0..100000, window_hours int coercion). `settings.test.ts` (TEST_DATABASE_URL): seeds written once on empty tables, second `getSettings` never re-seeds over edited values; storeSettings round-trip survives a fresh process (re-read from Postgres). `projection.test.ts` (TEST_MINT_REDIS_URL, FLUSHDB db9 in beforeAll): publishSettings then **hookContract.test.ts** assertions — `HGETALL config:limits` has EXACTLY the 13 field names from the Global Constraints inventory; `plans` field JSON-parses to objects whose keys are exactly `{id,name,price_usd,enabled,aliases,window_hours,mult,slow_mode,auto_oss}`; `free_monthly_cap_usd` parses via `parseFloat` and `Number.isFinite`; `config:base_daily_usd === "0.15"`; publishUserTier("u","7x",now+3600) → `GET user:u:tier === "7x"` and PTTL ∈ (3_590_000, 4_200_000] (expiry+600 skew); publishUserTier free → both keys deleted; resyncAtBoot over a hand-corrupted `config:limits` (wrong mult in Redis) → Redis overwritten from Postgres, `conflictsResolvedFromPostgres >= 1`; publishModelGroups writes sorted JSON array string, no-op when unchanged (SET call count 0 on second publish).
- [ ] **Step 2: Verify fail.** `TEST_DATABASE_URL=… TEST_MINT_REDIS_URL=redis://127.0.0.1:6390/9 pnpm --filter @ovid/mint test` — Expected: FAIL.
- [ ] **Step 3: Implement.** Serialization parity rules: plan objects serialize with sorted keys and `pyNumStr`-equivalent number formatting inside JSON (write a `pyJsonStringify` helper: numbers via pyNumStr, strings/bools/arrays standard); epoch values as `String(Math.floor(seconds))` or `.toFixed(3)` where Python does. `importFromRedisOnce` is insert-if-absent only.
- [ ] **Step 4: Verify pass.** Same command — Expected: PASS.
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): plans-as-data in Postgres, db2 projection with boot resync, ovid_plans math port"`

### Task 5: Windows machinery + `/usage`

**Files:**
- Create: `cloud/apps/mint/src/{windows.ts,usage.ts,catalog.ts}`
- Test: `cloud/apps/mint/src/{windows.test.ts,usage.test.ts}`

**Interfaces:**
- Consumes: Task 4 (`getSettings`, `userPools`, `poolKeys`, projection), Task 3 (`LiteLlmAdmin.spendLogs/keyInfo/userInfo/modelInfo`), `@ovid/money` (`pyRound6`).
- Produces (used by Tasks 6–8, 10, 13):

```ts
// windows.ts — ports of mint.py window_bounds/current_window_start/hook_spend/reset_window_user
export function currentWindowStart(deps, uid: string, pools: Pools): Promise<Date | null>;   // expired → DEL start/spend/auto, null
export function windowBounds(deps, uid: string, pools: Pools, opts?: { create?: boolean; firstUse?: Date | null }): Promise<{ start: Date; end: Date }>; // SETNX pool:{uid}:start floor(epoch) EX window secs; firstUse anchors start at earliest request
export function hookSpend(deps, uid: string): Promise<number>;                               // GET pool:{uid}:spend → float-or-0
export function resetWindowUser(deps, uid: string, opts?: { resetMonthFree?: boolean }): Promise<{ keys: number; errors: number }>; // DEL spend/auto/usagecache; SET start=now(.3f) EX window; HDEL pools:slow; SREM pools:slow_pending; reapplyUser(extra {spend:0}, forceDuration true; user budget restarted unless free&&!resetMonthFree); DEL legacy freecap:{uid}:{YYYY-MM}
export function dropUsageCache(deps, uids: string[]): Promise<void>;                         // DEL usagecache:{uid}
export function effectiveTier(deps, uid: string): Promise<string>;                           // findPlan(getSettings(), GET user:{uid}:tier).id — missing key = free
export function freeCapUsd(deps, uid: string): Promise<number>;
export function monthSpent(deps, uid: string): Promise<number>;                              // LiteLLM /user/info spend, 0 on error (fail-soft like Python)
export function freeCapRemaining(deps, uid: string): Promise<number>;
export function tierBudget(deps, uid: string, tier: string): Promise<{ budget: number; duration: string }>;
export function userBudgetTarget(deps, uid: string, tier: string): Promise<{ budget: number; duration: string }>; // free → (freeCapUsd, "30d") else tierBudget
export function reapplyUser(deps, uid: string, opts?: { extra?: Record<string, unknown>; forceDuration?: boolean; userExtra?: Record<string, unknown> | null; userForceDuration?: boolean }): Promise<{ keys: number; errors: number }>; // budget_duration sent ONLY when it changes (LiteLLM clock-restart rule) — port ensure_user_budget/apply_key_budget exactly
// usage.ts
export interface UsageBody { tier: string; is_paid: boolean; daily_spent_usd: number; daily_budget_usd: number; daily_remaining_usd: number; month_free_spent_usd: number; month_free_cap_usd: number; requests_today: number; budget_window: string; remaining_pct: number; plan: string; plan_name: string; window: string; resets_at: string; today: { requests: number; input_tokens: number; output_tokens: number; images: number; auto_requests: number; by_model: Record<string, { requests: number; input_tokens: number; output_tokens: number; images: number; via_auto: number }> }; remaining_fraction: number; pools: { class: "all"; remaining_fraction: number; resets_at: string; slow_mode: boolean }[]; models: UsageModelEntry[]; [billingField: string]: unknown /* Task 10 merges billing_enabled/plan_*/plans */ }
export function computeUsage(deps, uid: string): Promise<{ body: UsageBody; detail: AdminUsageDetail }>; // spend = max(logged spend-logs sum, hook counter); window anchored at earliest spend-log when no live window; free cap_left applied for free plan; syncs slow mode when crossed (Task 7 syncSlowMode)
export function registerUsageRoutes(publicApp: FastifyInstance, deps: MintDeps): void; // POST /usage: 401 "missing bearer id token" / "missing app check token" shapes; usagecache:{uid} 15 s (USAGE_CACHE_S) honored and invalidated by resetWindow/dropUsageCache
// catalog.ts — model catalog + hook publication
export function catalogFor(deps): Promise<Catalog>;                    // LiteLLM /model/info → groups {name, legacy prices, underlying, kind chat|image}; publishes config:model_groups (sorted JSON) when changed
export function refreshModelGroups(deps): Promise<void>;
export function availableModels(deps): { model: string }[];            // wrappable by Task 13's PublicCatalog.usage (image masking)
```

- [ ] **Step 1: Write failing tests** — ports of `server/mint/tests/test_usage.py` + window cases from `test_limits.py` (mock LiteLLM via `http.createServer`; TEST_MINT_REDIS_URL db9; TEST_DATABASE_URL): windowBounds creates start with NX + TTL≈window secs and anchors at `firstUse` when earlier; expired window cleared (start/spend/auto deleted) then recreated; computeUsage body has EXACTLY the README field set (assert `Object.keys(body)` sorted equals the pinned list) with a pro user fixture reproducing the README example numbers (tier "7x", is_paid true, budget 3.45 at 0.15 base, remaining_fraction rounded 4, pools single `class:"all"`, resets_at ISO `…Z` with `+00:00` replaced); by_model attributes via_auto from `pool:{uid}:auto` hash capped at (requests − via_auto); images counted from call_type set + group kind; `daily_spent_usd === pyRound6(max(logSpend, hookCounter))`; models[] entries carry `remaining_messages` floor(rem/cost+1e-9) for chat, `remaining_images` for image kind, `null` when unpriced, auto entry `estimate:"conservative"` + sorted `members` when auto_oss; 15-s cache: second POST /usage within TTL serves cached body (LiteLLM mock call count 0), resetWindowUser drops it; reapplyUser sends `budget_duration` only on change (capture POST bodies: second call body has no budget_duration); resetWindowUser zeroes key spend with forceDuration and leaves free-plan user budget untouched without resetMonthFree.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (spend-log attribution ports `attribute_row`/`count_usage`/`model_estimates` including `_public_for` alias mapping and the image-alias "dearest private backend" pricing) → **Step 4: Verify pass** (`pnpm --filter @ovid/mint test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): mint window machinery, /usage contract port with 15s cache, model-group publication"`

### Task 6: Public mint endpoints — `/mint`, `/upgrade`, `/plans`, `/v1/models`

**Files:**
- Create: `cloud/apps/mint/src/{mintRoutes.ts,verifier.ts,keyMint.ts}`
- Test: `cloud/apps/mint/src/{mintRoutes.test.ts,keyMint.test.ts}`

**Interfaces:**
- Consumes: Tasks 3–5; firebase-admin (ID token + App Check, replacing mint.py's raw-JWKS verification; same allowlist env semantics).
- Produces:

```ts
// verifier.ts
export interface MintIdentity { uid: string; email: string | null; platform: "android" | "web"; }
export type MintIdentityVerifier = (headers: { authorization: string; appcheck: string; xff: string; xRealIp: string }) => Promise<MintIdentity>;
export function createMintVerifier(env: MintEnv): MintIdentityVerifier; // 401 HttpContractError("missing bearer id token"/"missing app check token"/"invalid app check token: …"); platform from OVID_APPCHECK_APPS appId map else ":web:" heuristic; rememberEmail side effect (user:{uid}:email + email:{email} index, Postgres users.email authoritative)
// keyMint.ts — port of litellm_mint_or_get, STRICTLY idempotent per (uid, platform)
export const KEY_NAMESPACES = ["", "web:"] as const;
export function litellmMintOrGet(deps, uid: string, tier: string, platform: "android" | "web"): Promise<string>; // Redis keys user:{uid}:{ns}keyid/key; race lock SET mintlock:{ns}{uid} NX EX 30 with 20×250 ms wait then 409 "key creation in progress, retry"; unusable stored key (401/403/404/expired) → /key/delete + re-issue; /key/generate body {user_id, max_budget, budget_duration, metadata:{tier,ovid_uid,platform}, models:[…public groups + "ovid-image"], rpm/tpm/max_parallel (slow-mode aware), team_id for web via webTeamId}; global new-key breaker (Task 7) inside the lock
export function webTeamId(deps): Promise<string>;   // config:web_team_id / team/new "ovid-web" max_budget=WEB_TEAM_DAILY_USD duration "1d", budget re-synced on change
export function userKeyIds(deps, uid: string): Promise<Record<string, string>>; // {ns: keyid} across android+web
// mintRoutes.ts
export function registerMintRoutes(publicApp: FastifyInstance, deps: MintDeps): void;
// POST /mint → 200 {key, tier: storedTier(plan), base_url: env.publicBaseUrl}; error ladder EXACT: 401s (verifier), 403 "account suspended" (banned), 429 "too many requests from this network — retry later" (per-IP), 429 signup-velocity message, 503 "sign-ups are temporarily paused — please try again shortly" (breaker), 402 "monthly free limit reached" (free + cap exhausted), 409 lock-race
// POST /upgrade → ALLOW_TEST_UPGRADE gate: 403 "test upgrade is disabled"; else body {tier} resolves via findPlan (disabled/unknown → free), SET tier via projection.publishUserTier (Postgres users.tier first), reapplyUser, → {ok:true, tier: storedTier}
// GET /plans → {"plans":[{id,name,price_usd,aliases,window}]} enabled only
// GET /v1/models → sanitized passthrough: rawModels(user Authorization) → 200 rows [{model:id}] filtered through PublicCatalog masking hook (Task 13 wraps; base version strips nothing but reshapes to {object:"list",data:[{id,object:"model",owned_by:"ovid"}]}); error mapping port of _catalog_error: budget-ish 400/401/403/429 → 402 {"error":{"code":"budget_exceeded"}}; 401/403 → 401 key_invalid; 429 → 429 rate_limited; else 503 catalog_unavailable — ALL with headers {"Cache-Control":"no-store","X-Ovid-Gateway":"2"}
```

- [ ] **Step 1: Write failing tests** — ports of `server/mint/tests/test_limits.py` (mint paths) + `test_admin.py` (set-tier→mint interplay): first /mint creates exactly one key (mock LiteLLM captures one /key/generate), second /mint returns the SAME key with /key/update refresh and NO budget_duration when unchanged; concurrent double-mint for a brand-new uid → one /key/generate, loser waits and gets the key (drive the lock by pre-setting `mintlock:{uid}` and having the first GET return the key after N polls); lock timeout → 409 exact detail; banned uid → 403 "account suspended"; free user with monthSpent ≥ cap → 402 "monthly free limit reached"; web platform → key stored under `user:{uid}:web:keyid` and team_id present in generate body; /upgrade with ALLOW_TEST_UPGRADE=false → 403; with true, tier "7x" → users.tier pro + Redis tier "7x" + reapply captured; unknown tier → free; /plans hides disabled plan; /v1/models budget-429-with-"budget"-text → 402 budget_exceeded + `X-Ovid-Gateway: 2` header, plain 500 → 503 catalog_unavailable; secret-literal grep test over `src/**` (README rule).
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (firebase-admin lazily initialized from `GOOGLE_APPLICATION_CREDENTIALS`; App Check via `getAppCheck().verifyToken` with app-id allowlist mapping to platform) → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): mint public endpoints — idempotent per-UID key minting, /usage-adjacent /plans /upgrade /v1/models"`

### Task 7: Anti-abuse, ban-that-blocks, slow-mode sweeper, spend monitor

**Files:**
- Create: `cloud/apps/mint/src/{antiAbuse.ts,slowMode.ts,background.ts}`
- Test: `cloud/apps/mint/src/{antiAbuse.test.ts,slowMode.test.ts}`

**Interfaces:**
- Consumes: Tasks 3–6 (`alerter`, `userKeyIds`, `reapplyUser`, `computeUsage`, LiteLlmAdmin).
- Produces:

```ts
// antiAbuse.ts — exact ports incl. the shared-IP-safe design notes (mint.py:790-864)
export function clientIp(xff: string, xRealIp: string): string;                     // first XFF hop, else x-real-ip, else "unknown"
export function isBanned(deps, uid: string, ip: string): Promise<boolean>;          // user:{uid}:banned OR ban:ip:{ip}
export function recordStrike(deps, uid: string, ip: string): Promise<void>;         // INCR abuse:uid:{uid} EX ABUSE_WINDOW_S; at limit → set banned "auto" + **block LiteLLM keys via setKeyBlocked(uid,true)** (THE PYTHON BUG FIX: auto-ban only set the flag) + alerter("auto_ban", …, 600); advisory INCR abuse:ip:{ip}
export function setKeyBlocked(deps, uid: string, blocked: boolean): Promise<void>;  // /key/block|unblock for every namespace keyid
export function enforceIpSignupQuota(deps, uid: string, ip: string): Promise<void>; // SISMEMBER ipacct:{ip} → pass; INCR ipnew:{ip}:{floor(now/600)}; over 12 → alert + HttpContractError(429, "sign-ups from this network are busy right now — please retry in a few minutes"); SADD ipacct + EXPIRE 86400
export function enforceMintRateLimit(deps, ip: string): Promise<void>;              // INCR mintrate:{ip}:{floor(now/3600)}; over 40 → HttpContractError(429, "too many requests from this network — retry later")
export function checkNewKeyBreaker(deps): Promise<void>;                            // INCR newkeys:{win}; over 500 → SET alert:newkey_spike + alert + HttpContractError(503, "sign-ups are temporarily paused — please try again shortly")
// slowMode.ts
export function inSlowMode(deps, uid: string): Promise<boolean>;                    // HGET pools:slow uid > now
export function rateLimits(deps, uid: string): Promise<{ rpm_limit: number; tpm_limit: number; max_parallel_requests: number }>;
export function syncSlowMode(deps, uid: string, slow: boolean, until: Date): Promise<boolean>; // HSET/HDEL pools:slow (until as `${epoch.toFixed(3)}`), push rate limits to all keys on change; returns changed
export function sweepSlowMode(deps): Promise<{ checked: number; lifted: number }>;  // drain pools:slow_pending via computeUsage; lift expired pools:slow entries + push normal limits
// background.ts
export function startMintBackgroundLoops(deps): { stop(): Promise<void> };          // sweeper every MINT_SWEEP_S (30 s): sweepSlowMode + refreshModelGroups; spend monitor every 300 s: globalSpend vs spend:daybase:{YYYYMMDD} (SETNX EX 3d) → alert("daily_spend", …, 86400) at DAILY_SPEND_ALERT_USD; loops never throw (catch+log per Python)
```

- [ ] **Step 1: Write failing tests** — ports of the anti-abuse cases in `server/mint/tests/test_limits.py` + `test_admin.py` ban cases, PLUS Review Focus #4: `recordStrike` ×(limit−1) → not banned, keys untouched; strike #limit → `user:{uid}:banned === "auto"` AND mock LiteLLM received `/key/block` for BOTH android and web keyids AND alert fired once (second auto-ban within 600 s bucket → no second alert); returning user on `ipacct` never throttled; 13th new signup in window → 429 with the exact message and IP NOT banned (`ban:ip:{ip}` absent); 41st mint call/hour → 429 exact message; breaker 501st new key → 503 exact message + `alert:newkey_spike` set; syncSlowMode on → HSET pools:slow with `.3f` epoch + /key/update bodies carry slow_rpm/tpm/parallel; sweep lifts expired entries and pushes normal limits; spend monitor: daybase SETNX once, alert at threshold once per day bucket.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): mint anti-abuse ports, ban that blocks LiteLLM keys, slow-mode sweeper, spend monitor"`

### Task 8: Owner admin console + `/admin/*` JSON API

**Files:**
- Create: `cloud/apps/mint/src/{adminRoutes.ts,adminAudit.ts,adminConsole.html.ts}` (the HTML page as a template-literal module or `adminConsole.html` + raw import — builder choice, must be served byte-stable)
- Test: `cloud/apps/mint/src/{adminRoutes.test.ts,adminAudit.test.ts}`

**Interfaces:**
- Consumes: Tasks 3–7 (settings/projection/reapply/resetWindow/setKeyBlocked/alerter), `mintAudit` table + `audit:admin` Redis list.
- Produces:

```ts
export function requireAdmin(env: MintEnv, authorization: string): void;  // missing → HttpContractError(401,"missing authorization"); wrong → 403; timingSafeEqual on UTF-8 buffers, length-guarded
export function audit(deps, action: string, opts?: { target?: unknown; before?: unknown; after?: unknown; ip?: string }): Promise<void>; // INSERT mintAudit + LPUSH audit:admin JSON + LTRIM 0 AUDIT_MAX-1 + append admin-audit.jsonl in MINT_STATE_DIR (fs.appendFile, errors logged not thrown)
export function registerAdminRoutes(adminApp: FastifyInstance, deps: MintDeps): void;
// Exact endpoint surface (mint.py table + README), all Bearer master-key:
// GET/POST /admin/settings — partial update {free_daily_usd, scalars…, plans, auto_oss_members}; POST validates via validateSettings, stores to Postgres, re-publishes db2, re-applies to every key by default (?reapply=false opt-out); auto_oss_members validated against LiteLLM /model/info (unknown model → 400)
// GET/POST /admin/plans, POST /admin/plans/{id}/enable|/disable — plans-as-data CRUD (disable = stop selling: vanishes from /plans, /upgrade falls back to free, existing users keep it)
// GET /admin/models — LiteLLM models + prices + per-message/image estimates (est_input_tokens/est_output_tokens/est_image_tokens driven)
// GET /admin/user?q= — uid or email lookup (email:{email} index / users.email) → plan, overrides, window, allowance spent/cap/left %, slow mode, auto routing, usage (computeUsage detail), backstop, keys, per-model table
// POST /admin/user/update (= alias POST /admin/set-tier) — body {uid, tier?, daily_usd?, monthly_cap_usd?, pools?{mult,window_hours,slow_mode,auto_oss}, clear_daily_usd?, clear_monthly_cap_usd?, clear_pools?}; unknown tier → 400 "unknown plan"; pools fields validated (400 with Python message shapes); writes Postgres overrides + users.tier, publishes db2, reapplyUser, dropUsageCache, audit before/after
// POST /admin/reset-window {uid}|{} + GET /admin/reset-status — single uid inline; {} = ALL users background when > REAPPLY_SYNC_MAX(200) with progress JSON {state,total,done,users,keys,errors,at} in config:reset_status; optional reset_month_free
// POST /admin/reset-usage — legacy alias: window reset + monthly backstop (free users' LiteLLM user spend zeroed)
// POST /admin/ban /admin/unban — {uid?, ip?}: uid → users.bannedAt/bannedReason + Redis flag + setKeyBlocked + audit; ip → SETEX ban:ip:{ip} 30d / DEL
// POST /admin/set-base-budget — legacy: sets free_daily_usd
// GET /admin/audit?limit=100, GET /admin/reapply-status, POST /admin/sweep (sweepSlowMode now), GET /admin/export (settings + all user states JSON)
// GET /admin and /admin/ui — the ported single-page HTML console (sections per README: global limits, plans, auto-oss members, model prices, user, all-users reset, IP ban, audit log); responses no-store + Content-Security-Policy "frame-ancestors 'none'" + nosniff; pure client of this JSON API; note served on the admin listener only (localhost/SSH-tunnel rule; Caddy never routes /admin)
export function reapplyAll(deps, uids?: string[] | null): Promise<{ mode: "sync" | "background"; users: number; keys?: number; errors?: number }>; // progress in config:reapply_status every 25 users
```

- [ ] **Step 1: Write failing tests** — ports of `server/mint/tests/test_admin.py`: no auth → 401, wrong key → 403 (and requireAdmin uses timingSafeEqual — assert equal-length wrong key still 403, no throw); settings POST partial update keeps other fields, re-publishes db2 (HGETALL diff), re-applies (mock /key/update per user per namespace); invalid plan id (uppercase) → 400 with message "plan id must be 1-32 chars of a-z 0-9 _ -"; plans disable → GET /plans excludes, existing user keeps allowance; user/update tier + clear_daily_usd combos write Postgres AND db2 AND reapply; unknown tier → 400 "unknown plan"; reset-window single: pool keys cleared, start≈now, /key/update spend:0 + budget_duration present, usagecache dropped, /usage resets_at moved; reset-window all with 3 users → config:reset_status ends state done users 3; ban → Redis flag + /key/block captured + audit row with before/after; unban → /key/unblock; audit list capped (write 5001 with AUDIT_MAX=5000 → LLEN 5000) and JSONL file gains a line; export shape contains settings+users; console GET → 200 text/html with `frame-ancestors 'none'` and `no-store`.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (background runs via `setImmediate`-spawned promise chains with status-key progress; no threads needed) → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): owner admin console port — plans-as-data, overrides, bans, window resets, audit (JSONL+Redis+Postgres)"`

### Task 9: Internal server-to-server minting + gateway/worker key-flow swap (Ruling Q5)

**Files:**
- Create: `cloud/apps/mint/src/{internalAuth.ts,internalRoutes.ts}`; `cloud/packages/shared/src/internalAuth.ts`; `cloud/apps/gateway/src/internalMint.ts`; `cloud/apps/worker/src/keyResolver.ts`
- Modify: `cloud/packages/shared/src/{keys.ts,index.ts}` (add interfaces; update the types-only header comment), `cloud/apps/gateway/src/{app.ts,env.ts,routes/messages.ts,keys.ts}` (replace `createHttpMintProvisioner` usage; delete that factory), `cloud/apps/worker/src/{main.ts,runProcessor.ts}` (`RunDeps.keys` accepts `KeyResolver`), `cloud/packages/queue/src/queues.ts` (`AgentRunJob.byokKeyId?: string | null` additive optional), `cloud/deploy/{docker-compose.yml,.env.example}`
- Test: `cloud/apps/mint/src/internalRoutes.test.ts`, `cloud/apps/gateway/src/internalMint.test.ts`, `cloud/apps/worker/src/keyResolver.test.ts`

**Interfaces:**
- Consumes: Task 6 `litellmMintOrGet`, Task 11's `ByokKeyProvider` (interface pinned HERE, implemented in Task 11), gateway auth principal.
- Produces:

```ts
// @ovid/shared internalAuth.ts — HMAC request signing (single host, docker-internal network).
// CHOSEN DESIGN: shared secret + per-request HMAC-SHA256 over "METHOD\nPATH\nUID\nTIMESTAMP" with a ±300 s window (INTERNAL_WINDOW_S=300), base64 headers X-Ovid-Timestamp / X-Ovid-Signature, timingSafeEqual verify, secret env-only (OVID_INTERNAL_API_SECRET, ≥32 bytes). mTLS-lite rejected: both processes live on one compose network; certs would add rotation infrastructure without adding a boundary. Documented in cloud/docs/internal-mint-auth.md (created in this task).
export const INTERNAL_WINDOW_S = 300;
export function signInternalRequest(secret: string, method: string, path: string, uid: string, timestamp: number): string;
export function verifyInternalRequest(secret: string, method: string, path: string, uid: string, timestampHeader: string, signatureHeader: string, now: number): boolean;
// @ovid/shared keys.ts additions
export type ResolvedKey =
  | { kind: "litellm"; key: string; baseUrl: string }
  | { kind: "byok"; byokKeyId: string; providerId: string; endpoint: string; apiKey: string };
export interface KeyResolver { resolveForRun(uid: string, ctx: { unattended: boolean; byokKeyId?: string | null }): Promise<ResolvedKey | null>; }
export interface InternalMintProvisioner { ensureKeyForUid(uid: string, opts?: { platform?: "android" | "web" }): Promise<{ key: string; tier: string; baseUrl: string }>; }
export class MintInternalError extends Error { readonly status: number; readonly body: unknown; } // relayed 402/403/429 envelopes
export interface ByokKeyProvider { getDecrypted(byokKeyId: string, uid: string): Promise<{ providerId: string; endpoint: string; apiKey: string } | null>; } // Task 11 implements

// mint internalRoutes.ts (admin listener ONLY — never registered on publicApp; test pins that publicApp.inject POST /internal/mint-key → 404)
export function registerInternalRoutes(adminApp: FastifyInstance, deps: MintDeps): void;
// POST /internal/mint-key {uid, platform?} → 200 {key, tier, baseUrl}; same ban/free-cap/lock ladder as /mint but WITHOUT Firebase (uid is trusted from the signed caller): 403 banned, 402 free cap exhausted (body {"detail":"monthly free limit reached"}), 409 lock race, 401/403 on bad signature (indistinguishable bodies)

// gateway internalMint.ts
export function createInternalMintProvisioner(baseUrl: string, secret: string, fetchImpl?: typeof fetch): InternalMintProvisioner; // baseUrl = mint admin listener (http://ovid-mint:8092); non-2xx → MintInternalError{status,body}
// gateway wiring: GatewayDeps.mint: InternalMintProvisioner; messages.ts calls ensureKeyForUid(principal.uid) — the gateway's OWN verified principal, no client-token forwarding; MintInternalError 402/429 relayed verbatim (existing pattern), any other failure → 409 {code:"key_not_minted"}

// worker keyResolver.ts
export interface KeyResolverDeps { redisMint: Redis; internalMint: { baseUrl: string; secret: string }; byok: ByokKeyProvider | null; litellmBaseUrl: string; fetchImpl?: typeof fetch; }
export function createServerKeyResolver(deps: KeyResolverDeps): KeyResolver;
// order: (1) ctx.byokKeyId → byok.getDecrypted (null → fall through, log); (2) GET user:{uid}:key from mint db2; (3) miss AND ctx.unattended → POST /internal/mint-key (signed); attended miss → null (run_failed key_not_minted + push notification is P4's contract, unchanged); (4) internal 402/403 → null with the reason logged (never surfaced as infra error)
// runProcessor.ts: RunDeps.keys: KeyResolver; litellm kind → existing transport; byok kind → transport.baseUrl = endpoint (P3 owns provider-native transports; P9 only resolves and passes ResolvedKey through — alignment note in the file header)
```

- [ ] **Step 1: Write failing tests.** `internalRoutes.test.ts`: valid signature → 200 with key from mocked litellmMintOrGet; timestamp 301 s old → 401; wrong secret → 401; right secret wrong uid in signature (uid swapped in body) → 401; replay of an identical valid request within window → still 200 (idempotent by design — document); route absent on publicApp (404). `internalMint.test.ts` (gateway): 402 from mint → MintInternalError status 402 body preserved; messages route with stub provisioner throwing 402 → response relays the billing envelope; throwing 500 → 409 key_not_minted (existing behavior kept). `keyResolver.test.ts`: byokKeyId present + provider returns record → kind byok with decrypted fields; no byok → Redis key returned kind litellm; Redis miss + unattended → internal mint called (mock fetch captures signature headers verifying against the secret) → litellm key; Redis miss + attended → null, no internal call; internal 402 → null.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (+ `cloud/docs/internal-mint-auth.md`: threat model, rotation = env change + rolling restart of mint/gateway/worker, why not mTLS) → **Step 4: Verify pass** (`pnpm --filter @ovid/mint --filter @ovid/gateway --filter @ovid/worker --filter @ovid/shared test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): server-to-server key minting (HMAC internal API), gateway+worker swap off client-token forwarding"`

### Task 10: Play Billing — verify, RTDN, durable ledger, self-expiring tier keys

**Files:**
- Create: `cloud/apps/mint/src/billing/{domain.ts,products.ts,play.ts,service.ts,routes.ts,tierSink.ts,pushAuth.ts}`
- Test: `cloud/apps/mint/src/billing/{domain.test.ts,service.test.ts,routes.test.ts,tierSink.test.ts}`

**Interfaces:**
- Consumes: Tasks 2–5 (`billingPurchases` repo, `projection.publishUserTier`, `reapplyUser`, `effectiveTier`, usage route merge point), `users` repo (tier), googleapis + google-auth-library.
- Produces:

```ts
// domain.ts — port of server/billing/domain.py
export class BillingError extends Error { constructor(readonly status: number, readonly code: string) }
export interface Entitlement { status: "active" | "pending" | "expired" | "revoked" | "replaced"; tier: string; product_id: string; expires_at: number | null; auto_renewing: boolean; linked_token: string | null; account_hash: string | null; acknowledged: boolean; test_purchase: boolean; state: string; }
export const ENTITLED_STATES: ReadonlySet<string>; // ACTIVE, IN_GRACE_PERIOD, CANCELED (access until expiry)
export function parsePlayTime(value: string | null): number | null; // Z-suffix, nanosecond truncation to µs like Python
export function evaluate(resource: unknown, products: Record<string, string>, now: number): Entitlement; // unknown products never grant; highest TIER_RANK then latest expiry wins; auto_renewing false when CANCELED; no line items → BillingError(400,"unknown_product"); non-dict → BillingError(502,"play_invalid_response")
// products.ts
export const TIERS = ["free", "3x", "7x", "15x"] as const; export const TIER_RANK: Record<string, number>;
export const DEFAULT_PRODUCTS: Record<string, string>; // ovid_plus_monthly→3x, ovid_pro_monthly→7x, ovid_max_monthly→15x
export function loadProducts(env: { OVID_PLAY_PRODUCTS?: string }): Record<string, string>; // invalid JSON / free mapping → throw
export function accountHash(uid: string): string;    // sha256("ovid:"+uid) lower-hex — matches lib/core/play_billing.dart ovidPlayAccountId
export const DEFAULT_PLAN_FEATURES: Record<string, string[]>; // verbatim copy from products.py
// play.ts
export interface PlayDeveloperApi { getSubscription(purchaseToken: string): Promise<unknown> } // androidpublisher v3 purchases.subscriptionsv2.get via googleapis; auth from OVID_PLAY_SERVICE_ACCOUNT_FILE JSON (env-path only)
export function createPlayApi(packageName: string, serviceAccountFile: string): PlayDeveloperApi; // Google failures → BillingError(503,"play_unavailable"); auth failures → BillingError(503,"play_auth_failed")
// tierSink.ts
export const TIER_SKEW_SECONDS = 600;
export function createTierSink(deps): (uid: string, tier: string, expiresAt: number | null) => Promise<void>; // Postgres users.tier (+tierExpiresAt) FIRST, then projection.publishUserTier (Redis SET EXAT expiry+600 / DEL both keys on free), then reapplyUser(uid) so LiteLLM budgets follow the tier (the README's set_user_tier path — reuses /upgrade's budget machinery)
// pushAuth.ts
export function pubsubPushVerifier(env: MintEnv): (headers: Record<string,string>, query: Record<string,string>) => Promise<boolean>; // OIDC preferred: google-auth-library verifyIdToken audience=OVID_RTDN_AUDIENCE, claims.email===OVID_RTDN_SERVICE_ACCOUNT && email_verified===true; fallback OVID_RTDN_SHARED_SECRET vs ?secret= timingSafeEqual; NEITHER configured → always false (fail closed)
// service.ts
export interface BillingService { configured: boolean; verify(uid: string, body: unknown): Promise<{ status: number; payload: Record<string, unknown> }>; notify(envelope: unknown): Promise<void>; usageFields(uid: string | null): Promise<Record<string, unknown>>; }
export function createBillingService(deps): BillingService;
// routes.ts
export function registerBillingRoutes(publicApp: FastifyInstance, deps: MintDeps, billing: BillingService): void;
// POST /billing/verify: identity via Task-6 verifier + isBanned → 403 account_blocked; exact status matrix from server/billing/README.md (200 ok/status/tier/product_id/expires_at/auto_renewing/acknowledge — acknowledge===active ONLY; 202 pending; 400 invalid_request/wrong_package/unknown_product; 401 sign_in_required; 403 account_mismatch/account_blocked; 409 purchase_owned_by_another_account; 503 billing_unavailable/play_unavailable/play_auth_failed); Cache-Control no-store; unexpected → 503 billing_unavailable
// POST /billing/rtdn: pushAuth fail → 403 empty; malformed envelope JSON → 204; foreign packageName → 204; voidedPurchaseNotification → mark revoked (sticky) + apply owner; testNotification/no purchaseToken → 204; subscriptionNotification → re-read Play, record (unbound tokens stored uid=null, applied at verify), notificationType 12 → mark revoked, linkedPurchaseToken → old token replaced + old owner re-applied; BillingError from Play (503) propagates as 503 so Pub/Sub retries; success → 204; redelivery idempotent (record is an upsert, apply is a recompute)
// usage merge: registerUsageRoutes gains an optional billing hook — payload = {...body, ...billing.usageFields(uid)} adding billing_enabled/plan_expires_at/plan_auto_renews/plan_product_id/plans[] exactly per README
```

- [ ] **Step 1: Write failing tests** — port the FULL matrix of `server/billing/tests/test_billing.py` (FakePlay → stub `PlayDeveloperApi`; clock injected): evaluate: ACTIVE+expiry future → active with tier; CANCELED → active but auto_renewing false; IN_GRACE_PERIOD → active; PENDING → pending/free; expiry past → expired; nanosecond timestamp parsed; two line items → higher tier then later expiry wins; unknown productId only → 400 unknown_product; verify: happy path 200 acknowledge true + tier sunk; account_hash mismatch → 403 account_mismatch (constant-time compare); missing hash + requireAccountId → 403; token owned by other uid → 409 purchase_owned_by_another_account; pending → 202 acknowledge false; not configured → 503 billing_unavailable; wrong package → 400 wrong_package; rtdn: valid OIDC (stubbed verifier) renewed → tier refreshed; revoked type 12 → sticky (a later ACTIVE re-read keeps revoked); voidedPurchase → revoked; linkedPurchaseToken → old token replaced + both owners recomputed; malformed → 204; foreign package → 204; Play 503 → 503 (Pub/Sub retry semantics); same notification twice → identical end state, no duplicate effect (capture sink calls); pushAuth: no env → false for a valid-looking bearer; audience/email/email_verified all enforced; tierSink: paid → `GET user:{uid}:tier` and PTTL ∈ (expiry+600−10 s, expiry+600] window (Review Focus #3), Postgres users.tier set, reapplyUser called; free → both Redis keys deleted, users.tierExpiresAt null; usageFields merge appears in POST /usage body with `billing_enabled:false` when unconfigured.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): Play Billing verify+RTDN port — durable ledger, sticky revoke/replace, self-expiring tier keys"`

### Task 11: BYOK escrow — envelope crypto, endpoint canonicalizer, gateway routes, worker decrypt

**Files:**
- Create: `cloud/packages/escrow/package.json`, `tsconfig.json`, `src/{index.ts,envelope.ts,endpoints.ts}`; `cloud/apps/gateway/src/routes/byok.ts`
- Test: `cloud/packages/escrow/src/{envelope.test.ts,endpoints.test.ts}`, `cloud/apps/gateway/src/routes/byok.test.ts`

**Interfaces:**
- Consumes: `@ovid/db` byokKeysRepo, gateway authHook/principal, node:crypto; worker `ByokKeyProvider` (interface from Task 9).
- Produces:

```ts
// @ovid/escrow endpoints.ts — verbatim wire-contract port of server/sync/endpoints.py (D3)
export const MAX_ENDPOINT_LENGTH = 2048;
export interface EndpointPolicy { allowedSchemes: ReadonlySet<"https" | "http">; nonSecretQueryKeys: ReadonlySet<string>; }
export const DEFAULT_ENDPOINT_POLICY: EndpointPolicy; // https-only
export class EndpointRejectedError extends Error { readonly code = "endpoint_rejected"; } // never echoes the input
export function validateEndpoint(value: unknown, providerId: string, opts?: { policy?: EndpointPolicy; policies?: Record<string, EndpointPolicy> }): string;
// rules ported EXACTLY: printable ASCII 0x21–0x7E minus forbidden \ < > " { } | ^ ` #; hand-written URL grammar (NOT the WHATWG parser — same parser-confusion rationale); scheme https (+http only via policy); authority: no @ or %, strict IPv6 compressed form, reg-name labels ≤63, all-digit hosts must be strict dotted-quad (no octal/hex/short/int forms); default port dropped; percent-normalization of unreserved + upper-cased escapes; repeated full-decode (≤8 rounds, '+'→space) for sensitive-name and secret-value checks; sensitive name parts (key,token,secret,passw,pwd,auth,sig,credential,bearer,jwt,session,cookie) + exact {pass,otp} with nonSecretQueryKeys exemption; secret value regexes (sk-, AKIA, gh[pousr]_, AIza, xox[abprs]-, JWT eyJ…, "bearer "); azure/azureopenai provider rejects ?code=; RFC 3986 dot-segment removal; result ≤2048
// @ovid/escrow envelope.ts — spec §11 AES-256-GCM envelope
export interface EncryptedEnvelope { wrappedDek: string; iv: string; ciphertext: string; tag: string; } // all base64
export interface EnvelopeCrypto { encrypt(plaintext: string, recordId: string): EncryptedEnvelope; decrypt(e: EncryptedEnvelope, recordId: string): string; }
export function createEnvelopeCrypto(masterKeyHex: string): EnvelopeCrypto; // 64-hex master key (OVID_MASTER_KEY); per-record random 32-byte DEK; DEK wrapped with AES-256-GCM under the master key (own IV); payload encrypted under the DEK; AAD = UTF-8 recordId on BOTH layers (record-swap across rows fails auth); decrypt failure throws EnvelopeAuthError
// gateway routes/byok.ts — NEW endpoint conventions (camelCase, UUIDv7 ids, /cloud ApiError envelope)
export function registerByokRoutes(app: FastifyInstance, deps: ByokDeps): void;
// POST /cloud/v1/byok {providerId, endpoint, apiKey, label?} → validateEndpoint (400 endpoint_rejected), encrypt, insert → 201 {id, providerId, endpoint, label, createdAt, status:"untested"} — plaintext NEVER echoed or logged
// GET /cloud/v1/byok → {items:[{id, providerId, endpoint, label, status, lastTestAt, lastTestOk, createdAt}]}
// DELETE /cloud/v1/byok/:id → 204 (own rows only; other owner → 404 not_found)
// POST /cloud/v1/byok/:id/test → decrypt, DNS-resolve endpoint host, reject RFC1918/169.254/127/::1/metadata (SSRF guard, spec §11), port 443/80 only, minimal provider probe (OpenAI-compatible GET /models with the key, 10 s timeout) → 200 {ok:true|false, error?:string(sanitized)} + setTestResult
// worker provider: createByokKeyProvider(db, crypto): ByokKeyProvider — getDecrypted(id, uid) with owner check, null on missing/inactive/auth-failure (logged, never thrown into runs)
```

- [ ] **Step 1: Write failing tests.** `endpoints.test.ts`: port EVERY case of `server/sync/tests/test_endpoints.py` (the vectors are the contract — transcribe: canonical https rewrite, default-port strip, IPv6 compression, octal-IP reject, `API%5FKey` sensitive-name reject, layered-encoding reject, azure `?code=` reject, dot-segment removal, forbidden chars, 2049-length reject, fragment reject, credential-in-path reject). `envelope.test.ts`: round-trip; decrypt with a different recordId → `EnvelopeAuthError`; tampered ciphertext byte → auth error; two encryptions of the same plaintext differ (random DEK/IV); non-64-hex master key → constructor throws. `byok.test.ts` (gateway inject, stub crypto ok, TEST_DATABASE_URL): POST valid → 201 camelCase body, DB row holds no plaintext (select ciphertext ≠ apiKey, and apiKey string absent from every text column); POST `http://evil` → 400 endpoint_rejected; GET list excludes ciphertext fields; other user's id DELETE → 404; test route with a stub fetch → setTestResult persisted; SSRF: endpoint resolving to 127.0.0.1/10.x/169.254.169.254 → 400 with code `endpoint_rejected` at probe time (no fetch issued — assert stub call count 0).
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (package `@ovid/escrow` per P1 scaffold conventions; gateway env adds `OVID_MASTER_KEY` required in firebase mode; worker env likewise) → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): BYOK escrow — AES-256-GCM envelopes, endpoint canonicalizer port, /cloud/v1/byok routes, worker decrypt provider"`

### Task 12: Images ledger + money rules (Postgres port)

**Files:**
- Create: `cloud/apps/mint/src/images/{types.ts,ledger.ts,costing.ts}`
- Test: `cloud/apps/mint/src/images/{ledger.test.ts,costing.test.ts}`

**Interfaces:**
- Consumes: `@ovid/money` (ALL arithmetic), `imageJobsRepo`/`imageDeletedAccounts` (Task 2), Db.
- Produces:

```ts
// types.ts
export const IMAGE_ALIAS = "ovid-image";
export const SIZES = ["1024x1024", "1536x1024", "1024x1536", "2048x2048"] as const;
export const REPLAY_RETENTION = 86400; export const RECEIPT_RETENTION = 90 * 86400;
export class ImageError extends Error { constructor(readonly status: number, readonly code: string, readonly opts?: { receipt?: Receipt | null; retryAfterSeconds?: number | null; detail?: Record<string, unknown> | null }) } // retryAfterSeconds bounded via capacityRetrySeconds ONLY when status 503 && code image_capacity_unavailable
export class UpstreamError extends Error { constructor(readonly status: number) }
export class UpstreamNotAccepted extends UpstreamError {} // adapter-VERIFIED nonacceptance only
export interface Receipt { account_id: string; request_id: string; fingerprint: string; state: "pending" | "unknown" | "confirmed" | "failed"; charged: string | null; model?: string; } // snake_case = wire contract; charged exact decimal string
// ledger.ts — port of service.py Ledger onto Postgres (imageJobsRepo); same-transaction admission via withUidLock(db, `img:${account}`) or SELECT … FOR UPDATE inside a tx (builder choice; must serialize concurrent begin() for one account)
export interface ImageLedger {
  begin(account: string, request: string, fingerprint: string, reservation: Money, budget: Money, budgetWindow: string): Promise<Record<string, unknown> | null>; // existing row: fingerprint mismatch → ImageError(409,"idempotency_conflict"); done → replay response; receipt expired → 410 image_receipt_expired; pending/unknown → 409 image_request_pending + receipt; failed → 409 image_request_failed + receipt. Admission sum: exactSum(reserved for pending/unknown in window-or-unresolved + charged) + reservation > budget → ImageError(402,"image_limit_reached"). Deleted account → 410 image_account_deleted. Returns null on fresh admission (state pending)
  settle(account, request, actual: Money, response: object, servedModel?: string | null): Promise<Record<string, unknown>>; // done is idempotent (returns stored response); failed row → 409 image_request_failed; charges discounted(actual) exact string; sets replayUntil=now+24h, receiptUntil=now+90d; deleted account → charge commits, response withheld, throws 410 image_account_deleted AFTER commit
  unknown(account, request): Promise<void>;  // pending → unknown ONLY (never expires, never auto-resubmits)
  fail(account, request): Promise<void>;     // pending → failed, reserved "0", receiptUntil=now+90d
  receipt(account, request): Promise<Receipt>; // 404 image_request_not_found; past receiptUntil → 410 image_receipt_expired; deleted account → 410 image_account_deleted
  replay(account, request): Promise<Record<string, unknown>>; // done + within replayUntil → {...response, receipt}; blob purged/expired → 410 image_replay_expired (+receipt when still valid); pending/unknown → 409 image_request_pending; failed → 409 image_request_failed
  spent(account, opts?: { includePending?: boolean; budgetWindow?: string | null }): Promise<Money>;
  purgeExpired(limit?: number): Promise<number>; // 1..10000 batch bound; clears response past replayUntil, actual past receiptUntil; NEVER touches dedup rows/charges/unresolved reservations
  deleteAccount(account: string): Promise<void>; // idempotent tombstone + null blobs + replayUntil/receiptUntil=0
}
export function createImageLedger(db: Db, opts?: { clock?: () => number; replayRetention?: number; receiptRetention?: number }): ImageLedger; // invalid retention (replay > receipt, non-finite, ≤0) → constructor throws
// costing.ts — port of images/costing.py determination ORDER
export const COST_HEADER = "x-litellm-response-cost";
export function headerCost(headers: Record<string, string> | null, bound?: Money | null): Money | null;
export function normalizePrices(info: unknown): Partial<Record<"input_cost_per_token" | "output_cost_per_token" | "input_cost_per_image" | "output_cost_per_image", Money>>; // positive ≤1 only
export function priceStatus(info: unknown, headerSeen?: boolean): { priced: boolean; costSource: "tokens" | "per_image" | "header" | null; warnings: string[] }; // UNPRICED_WARNING verbatim
export function tokenCost(usage: unknown, prices: ReturnType<typeof normalizePrices>, n?: number, bound?: Money | null): Money | null; // tokens (input_tokens|prompt_tokens, output_tokens|completion_tokens, 0..10M, non-bool) else n×(per-image prices), n clamped 1..64
export function spendDeltaCost(before: number | null, after: number | null, bound?: Money | null): Money | null;
export function determineCost(opts: { headers?; usage?; prices?: unknown | (() => unknown); n?: number; spendBefore?: number | null; spendRead?: (() => Promise<number | null>) | null; spendWait?: number; spendPoll?: number; sleep?: (s: number) => Promise<void>; bound?: Money | null }): Promise<{ cost: Money | null; source: "header" | "tokens" | "spend_delta" | null }>; // header → tokens → bounded spend-delta poll → (null,null): NEVER fabricate
export function parseModelInfo(payload: unknown): Record<string, unknown>; // first deployment with a price wins
export class PriceBook { constructor(fetch: () => Promise<Record<string, unknown>>, opts?: { ttl?: number; missInterval?: number; clock?: () => number }); get(model: string): Promise<ReturnType<typeof normalizePrices> | undefined>; refresh(): Promise<void>; } // stale-while-revalidate, errors keep previous data
```

- [ ] **Step 1: Write failing tests** — ports of `server/images/tests/test_costing.py`, `test_images.py` (ledger half), `parallel_images_receipts_test.py`, `parallel_images_retention_test.py` (TEST_DATABASE_URL): money vectors per Task 1 but through ImageError mapping (invalid upstream cost → 502 invalid_image_response); begin/settle happy path: `charged === discounted(actual).toString()` exact string (e.g. actual "0.10" → "0.0300"); replay of done returns original + receipt, second settle returns stored result and CANNOT overwrite the charge; fingerprint conflict → 409 idempotency_conflict; budget: two concurrent begins where second's reservation overdraws → 402 image_limit_reached (drive with two promises + lock); pending/unknown count as reserved in `spent(includePending)`; unknown never expires: clock +100 d → receipt still 200-state unknown, replay → 409 image_request_pending; fail → reserved "0", receipt kept 90 d, replay → 409 image_request_failed; retention: replay after 24 h → 410 image_replay_expired with receipt still present; receipt after 90 d → 410 image_receipt_expired; purgeExpired batch bound validation (0, 10001 → throw) and never removes tombstones/charges; deleteAccount → receipt/replay 410 image_account_deleted, settle of pre-deletion pending charges but returns 410 and stores no blob (Review Focus #5); determineCost order: header beats tokens beats spend-delta; unpriced → {cost:null}; spend-delta polls until spendWait then null; bool/NaN/negative rejected at every source; tokenCost per-image fallback only when no token counts.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): images ledger on Postgres — exact-decimal reservations/settlement, receipts, retention, tombstones"`

### Task 13: Images HTTP surface — capabilities, generations/edits, DirectEdit, receipts at zero quota

**Files:**
- Create: `cloud/apps/mint/src/images/{auth.ts,admission.ts,directEdit.ts,service.ts,routes.ts,catalog.ts,validateImage.ts}`
- Test: `cloud/apps/mint/src/images/{routes.test.ts,directEdit.test.ts,admission.test.ts}`

**Interfaces:**
- Consumes: Task 12 ledger/costing, Tasks 5–6 (effectiveTier, tierBudget, freeCapRemaining, user key/keyid from db2, LiteLlmAdmin), Task 3 app; the untouched `img-edit-shim` container sits in the LiteLLM path for multipart edits (Ruling Q9 — no code here talks to the shim directly; LiteLLM's `api_base` already points at it).
- Produces:

```ts
// auth.ts — port of verifier.py VerifierAuth
export interface ImagesIdentity { uid: string; keyId: string; tier: string; }
export interface ImagesAuth { authenticate(headers: Record<string, string>): Promise<ImagesIdentity>; verifyIdentity(headers: Record<string, string>): Promise<ImagesIdentity>; } // verifyIdentity = receipt reads: full auth WITHOUT the free-quota gate; authenticate adds: free tier + freeCapRemaining<=0 → ImageError(402,"image_limit_reached")
export function createImagesAuth(deps): ImagesAuth; // Bearer + AppCheck via Task-6 verifier; banned → 403 image_access_denied; x-ovid-key must equal user:{uid}:key (timingSafeEqual) else 401 sign_in_required; LiteLLM /key/info: blocked or "ovid-image" NOT in info.models → 403 image_access_denied (explicit scope mandatory); user_id/metadata.ovid_uid mismatch → 403; expired key → 401
// admission.ts — port of images_gateway.admission
export function createAdmission(deps): (identity: ImagesIdentity, fn: (ctx: { window: string; budget: Money }) => Promise<Record<string, unknown>>) => Promise<Record<string, unknown>>; // tierBudget − current key spend; free cap check → 402 image_limit_reached; remaining ≤ 0 → 402; window id `${uid}:${duration}`
// directEdit.ts — port of directedit.py (JSON edit transport; the shim keeps handling the LiteLLM multipart path)
export interface DirectEdit { hasKey: boolean; target(params: Record<string, unknown> | null): { url: string; model: string } | null; post(params, prompt, size, imageDataUrl): Promise<{ status: number; headers: Record<string,string>; json(): Promise<unknown> }>; settlementCost(responseJson: unknown, bound: Money): Money; }
export function createDirectEdit(env: MintEnv, opts?: { fetchImpl?: typeof fetch }): DirectEdit; // https only, host ∈ OVID_IMAGE_DIRECT_EDIT_HOSTS (default "api.inferhub.dev"), from discovered api_base NEVER user input, no query/fragment/credentials/port≠443; INFERHUB_API_KEY only in Authorization; edit cost = min(OVID_IMAGE_EDIT_COST_USD ?? bound, bound); settlement uses usage.cost when positive finite else flat
// catalog.ts — port of catalog.py PublicCatalog (private backend names + prices never cross the boundary)
export class PublicCatalog { constructor(privateNames: Set<string>, available: () => boolean); usage(rows: { model: string }[]): { model: string }[]; models(rows): { object: "list"; data: { id: string; object: "model"; owned_by: "ovid"; output_modality?: "image" }[] }; }
// service.ts — port of deploy/images_gateway.py LiteLLMImageService.execute pipeline (validation → task/routing (Task 14) → ledger.begin(reservation = discounted(MAX_UPSTREAM)) → per-candidate: cooldown skip, direct-vs-LiteLLM forward, _NotServed(no_capacity|pre-provider codes) → continue, ambiguous → unknown/409, cost determination → settle; exhausted: all-capacity → 503 image_capacity_unavailable + Retry-After + receipt; else 502/503 image_unavailable + receipt)
export class LiteLlmImageService { constructor(deps, opts?: { clock?: () => number }); execute(account, request, operation, body, budget: Money, opts?: { budgetWindow?: string }): Promise<Record<string, unknown>>; catalog(): Promise<CatalogBody>; get cooldowns(): CapacityCooldowns; }
// routes.ts
export function registerImagesRoutes(publicApp: FastifyInstance, deps: MintDeps, service: LiteLlmImageService | null, admission: ReturnType<typeof createAdmission> | null): void;
// GET /v1/images/capabilities → catalog body {model, operations(legacy generate/edit size sets), availability:"unknown", schema:2, catalog_hash, models:[publicCard…]} with ETag `"<catalog_hash>"` + If-None-Match → 304; ALL backends in cooldown → 503 image_capacity_unavailable + Retry-After + error.retryAfterSeconds; service or admission null → 503 image_unavailable for every route (mount rule)
// POST /v1/images/generations | /v1/images/edits → Content-Type must be application/json else 415 invalid_image_request; raw body > 16 MB×4/3+64 KB → 413 image_too_large; request id from `Idempotency-Key` header ([A-Za-z0-9_.:-]{8,128} else 400 invalid_request_id); body allowlist {model,prompt,size,requirements,preference}(+{image,mask,images} for edits); success → {model:"ovid-image", data:[{b64_json, mime_type}], receipt}
// GET /v1/images/requests/:requestId → {receipt}; GET /v1/images/requests/:requestId/result → stored response + receipt — BOTH work at ZERO quota (verifyIdentity path) and return 404/410 per ledger
// error bodies EXACT: {"error":{"code", retryAfterSeconds?, …detail},"receipt"?} + Cache-Control no-store; unexpected errors collapse to 401/403 image_access_denied or 503 image_unavailable (never echo JWT/DB/provider errors)
// GET /v1/models wrapping: Task-6 passthrough filtered via PublicCatalog.models with the image alias REMOVED from the text catalog (capability endpoint advertises it) — headers {"Cache-Control":"no-store","X-Ovid-Gateway":"2"}
```

- [ ] **Step 1: Write failing tests** — ports of `server/images/tests/test_gateway_admission.py`, `test_direct_edit.py`, `test_verifier.py`, `test_gateway_capability_routing.py`, `wave2_cleanup_images_test.py` (mock LiteLLM + mock provider via fetch stubs; mock transport sequences exactly like the Python `self.transport([...])` harness): structured no_capacity 503 (`error.type:"no_capacity"` or message match) → cooldown set → next candidate tried; all candidates capacity-refused → 503 image_capacity_unavailable with bounded Retry-After (1..120, default 30, never copied from unstructured text) + receipt state failed + `error.retryAfterSeconds`; ambiguous 502 mid-chain → 409 image_request_pending + reservation retained, NO fallback; pre-provider 400 codes (`not_an_image_model`/`unsupported_modality`/`unsupported_n`) → fallback allowed; cooldown expires without a paid probe (clock advance); receipt GET at zero remaining budget → 200 (verifyIdentity, no admission call — assert admission stub not invoked); result GET after replay expiry → 410 image_replay_expired; capabilities ETag round-trip → 304; catalog_hash changes when a card changes; auth: wrong x-ovid-key → 401; key without `ovid-image` in models → 403 image_access_denied; banned → 403; 415 on text/plain POST; 413 on oversized body; edit data-URL validation (non-image bytes → 400 invalid_image); directEdit: host not in allowlist → target null (falls back to LiteLLM path), settlement uses usage.cost when present else flat min(editCost,bound); X-Ovid-Gateway:2 on /v1/models and capabilities responses.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (image validation: PNG/JPEG/WebP single-frame ≤4096² ≤16 MB — use `sharp` or pure-header sniffing? PIN: `image-size` + magic-byte checks, full decode NOT required beyond header+truncation sanity; document deviation from PIL `im.load()` — truncation detected via complete-file marker check per format) → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): images gateway HTTP surface — capabilities ETag, generations/edits, DirectEdit, zero-quota receipts"`

### Task 14: Image capability cards, routing, probes, card manager, images admin

**Files:**
- Create: `cloud/apps/mint/src/images/{capabilities.ts,routing.ts,cardStore.ts,probes.ts,cardManager.ts,adminRoutes.ts,extraction.ts}`
- Test: `cloud/apps/mint/src/images/{capabilities.test.ts,routing.test.ts,probes.test.ts,cardManager.test.ts}`

**Interfaces:**
- Consumes: Task 12/13 (types, ledger, service), `imageCards*` repos (Task 2), LiteLlmAdmin (`/model/info`), db2 projection.
- Produces:

```ts
// capabilities.ts — port of capabilities.py (pure)
export const CARD_SCHEMA = 1; export const PUBLIC_SCHEMA = 2;
export const OPERATIONS = ["generate","edit","inpaint","outpaint","reference_style","multi_image","remove_background","transparent_output","upscale","variations"] as const;
export function slugFor(model: string): string;                       // "ovid-image:img-" + sha256("ovid-slug|"+model).hex.slice(0,6)
export function cardFingerprint(model: string, params?: Record<string, unknown>): string; // sha256 over {model, litellm_model, api_base(rstrip /), provider, edit_transport?} sorted-keys JSON
export function defaultCard(model: string, fingerprint?: string): Card;  // conservative generate-only 1024x1024
export function supports(card: Card, op: string): boolean; export function maxInputs(card: Card): number;
export function mergeFacts(card: Card, facts: Partial<Card>): Card;      // trust order probed > declared > inferred, never downgrades
export function assignCostTiers(cards: Card[]): void;                    // median rules: ≤0.6×median low, ≥1.8×median high, single-cost → all med
export function deriveTags(card: Card): string[]; export function finalize(card: Card): Card;
export function publicCard(card: Card): PublicCard;                      // allow-list projection ONLY: slug, tags, operations{confidence verified|estimated, max_inputs, max_n}, sizes, aspect_ratios, max_n, input{max_images,formats}, output_formats, text_rendering level, quality, speed (fast ≤8000 / medium ≤25000 / slow), latency_p50_s, cost_tier, verified(state==="probed") — never provider name/URL/price
export function catalogHash(publicCards: PublicCard[]): string;          // sha256 of sorted-by-slug compact JSON, first 32 hex
export function legacyCard(model: string, sizes: string[], edit: boolean): Card;
// routing.ts — port of routing.py
export interface Task { operation: string; size: string | null; aspect_ratio: string | null; n_inputs: number; mask: boolean; transparent: boolean; text_rendering: boolean; preference: "balanced"|"quality"|"speed"|"cost"; }
export function taskFromRequest(operation: "generate"|"edit", body: Record<string, unknown>): Task; // ValueError→ ImageError(400,"invalid_image_request") at the caller; exact validation rules (requirements allowlist, preference set, mask→inpaint, multi-image→multi_image, ratio regex, ≤8 extra images)
export function missing(card: Card, task: Task): string[];               // includes "unpriced" (never-serves gate) and direct-transport transparency refusal
export function score(card: Card, task: Task): number;                   // weight tables verbatim; +3×text need; +0.15 probed
export function pickBackends(task: Task, cards: Card[], unavailable?: (model: string) => boolean): Card[]; // deterministic: capable+unblocked, -score, stable ties
export function alternatives(task: Task, cards: Card[]): string[];       // cooldown-blind slugs for 422 bodies
export function parseModel(value: unknown): string | null;               // "ovid-image"→null auto; "ovid-image:img-xxxxxx"→slug; else throw
// cardStore.ts — Postgres port of cardstore.py
export interface CardStore { get(model): Promise<Card|null>; all(): Promise<Card[]>; put(card): Promise<void>; history(model, limit?): Promise<{fingerprint,state,at}[]>; logProbe(model, probe, ok, errorClass, latencyMs, costUsd: Money): Promise<void>; spentSince(epoch: number): Promise<Money>; probeState(model): Promise<{attempts,nextAttemptAt,lastError}>; setProbeState(model, attempts, nextAttemptAt, lastError?): Promise<void>; }
export function createCardStore(db: Db, clock?: () => number): CardStore; // spentSince = exactSum over costUsd text (NOT SQL float SUM)
// probes.ts — port of probes.py budget-capped runner
export class ProbeRunner { constructor(transport: ProbeTransport, store: CardStore, opts?: { perProbeCap?: number; dailyCap?: number; maxSizes?: number; clock? }); run(card: Card): Promise<{ card: Card; spent: Money; stop?: string; incomplete?: boolean; transient?: boolean }>; } // defaults 0.50/5.00/4 (OVID_PROBE_MAX_USD/OVID_PROBE_DAILY_USD); estimate_exceeds_cap skip without spending; daily budget stop; verdict classes unsupported/transient/auth/budget/inconclusive; transient NEVER changes the capability; one probe run at a time (in-process mutex)
// cardManager.ts — port of cardmanager.py: discovery from LiteLLM /model/info (image-kind groups), fingerprint change → re-extract+re-probe, TTL week, stagger, unpriced warning (priceStatus), tick/due/reprobe/refresh; background loop inside the mint process (started by main.ts, interval 60 s, never on a request path)
export class CardManager { observe(discovered): void; card(model, params?): Card; cards(names?): Card[]; reprobe(model): boolean; due(): Card[]; tick(discover?): Promise<void>; refresh(name): Promise<void>; start(discover: () => Promise<Discovered[]>, intervalS?: number): void; stop(): void; }
// adminRoutes.ts (admin listener 8092, master-key auth via requireAdmin)
export function registerImagesAdminRoutes(adminApp: FastifyInstance, deps, manager: CardManager, opts?: { wake?: () => void; refreshPrices?: () => Promise<void> }): void;
// GET /images/admin/cards → {schema:1, cards:[card+history+probe_state], probe_spend_24h_usd, probe_budget:{probes_enabled, probe_spend_24h_usd, probe_daily_cap_usd, probe_daily_left_usd, probe_per_call_cap_usd}} no-store; POST /images/admin/refresh-prices → {refreshed, priced:{model:bool}}; POST /images/admin/reprobe {model} → 202 {queued} | 404 unknown_model | 400 invalid_request
```

- [ ] **Step 1: Write failing tests** — ports of `server/images/tests/test_capability_cards.py`, `test_routing.py`, `test_probes.py`, `test_provider_agnostic.py`, `test_provider_adapters.py`: slug stability across restarts + opacity (no provider substring); fingerprint changes on api_base trailing-slash-insensitive equality and edit_transport toggle; publicCard allow-list (a card poisoned with provider keys leaks nothing — assert exact key set); catalogHash deterministic + order-insensitive; mergeFacts never downgrades probed with inferred; cost-tier median boundaries (0.6×/1.8×); routing: pick_backends deterministic ordering, cooldown-blocked model skipped never ranked, unpriced card never picked (Review: unpriced-never-serves), text_rendering need adds 3×weight, 422 alternatives list; taskFromRequest validation matrix (bad preference/ratio/9-images/mask+edit→inpaint); probes: estimate over cap → no spend + warning; daily cap reached → stop "daily_budget"; transient 503 leaves capability unchanged; auth 401 → probe_stop auth warning text verbatim; cardManager tick: new model → default card → extraction → probe scheduling with stagger; fingerprint change → state reset; admin cards auth (no key → 403 forbidden body `{"error":{"code":"forbidden"}}`), reprobe unknown → 404.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (extraction.ts ports static extraction from litellm_params/model names — keep the Python heuristics verbatim) → **Step 4: Verify pass.**
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): image capability cards, deterministic routing, budget-capped probes, images admin"`

### Task 15: Account lifecycle — state machine, routes, durable worker, cleanup adapters

**Files:**
- Create: `cloud/packages/account/package.json`, `tsconfig.json`, `src/{index.ts,domain.ts,store.ts,adapters.ts}`; `cloud/apps/gateway/src/routes/account.ts`; `cloud/apps/worker/src/accountSweep.ts`
- Test: `cloud/packages/account/src/{domain.test.ts,store.test.ts,adapters.test.ts}`, `cloud/apps/gateway/src/routes/account.test.ts`, `cloud/apps/worker/src/accountSweep.test.ts`

**Interfaces:**
- Consumes: `@ovid/db` (accountDeletions, withUidLock, all uid-bearing tables), firebase-admin (gateway/worker), LiteLlmAdmin, mint db2 Redis, Task 11 byok repo, Task 12/16 ledger+shares deleteAccount, R2 client (P7's `workspace_objects`/`file_manifests` + S3 delete; if P7 has not landed, the adapter interface still ships with a no-op R2 stub behind an injected `R2Deleter` — pin the seam, not the dependency).
- Produces:

```ts
// @ovid/account domain.ts — port of server/account/domain.py (constants VERBATIM)
export const GRACE_SECONDS = 86400; export const RECENT_AUTH_SECONDS = 300; export const FENCE_SETTLE_SECONDS = 60; export const RETRY_SECONDS = 60; export const MAX_RETRY_SECONDS = 3600;
export const IDENTITY_PROVIDERS: ReadonlySet<string>; // google.com, github.com, apple.com, microsoft.com, facebook.com, twitter.com, yahoo.com, phone
export class AccountError extends Error { constructor(readonly code: string, readonly status?: number) } // default 409
export function identity(claims: Claims, opts?: { allowLegacyPassword?: boolean }): string; // uid regex [A-Za-z0-9_-]{1,128} else invalid_identity 401; provider allowlist else unsupported_identity 403
export function authTime(claims: Claims): number;   // reauthentication_required 401 when missing/non-finite
export interface PublicState { state: "active"|"pending"|"cancelled"|"fenced"|"deleting"|"deleted"; delete_after: number | null; request_id: string | null; } // snake_case wire contract
export interface Lifecycle {
  request(claims: Claims, requestId: string): Promise<PublicState>;  // requestId regex {8,100}; recent-auth ≤5 min checked under the UID lock AND after the admin lookup; previous_requests → request_already_completed; alias/pending coalescing; fenced/deleting/deleted → deletion_in_progress; delete_after = accept+86400, duplicates never extend
  status(claims): Promise<PublicState>;
  login(claims): Promise<PublicState>;                                // observational; never cancels; disabled token without owned fence → account_unavailable 403; deleting/deleted → deletion_in_progress
  cancel(claims): Promise<PublicState>;                               // recent-auth under lock; persisted intent BEFORE re-enable; pending before deadline OR fenced within 60-s settlement; deleting/deleted rejected
  access<T>(claims: Claims, fn: (uid: string) => Promise<T>): Promise<T>; // quota/mint guard: any state not cancelled/active → AccountError("account_deletion_pending", 403); holds the UID lock across fn
  finalize(uid: string, opts?: { scheduled?: boolean }): Promise<PublicState>; // _attempt semantics: eligibility recheck under lock, attempts++, backoff 60×2^min(n-1,6) capped 3600 persisted BEFORE effects, crash keeps pre-effect deadline; pending→fenced (fence_owned from admin user state) → disable → fence_at → 60-s settlement → deleting → cleanup_context prepared+validated → checkpointed steps keys→data(staged)→auth → deleted, cleanup_context dropped
}
export function createLifecycle(deps: { store: DeletionStore; admin: AdminAdapter; data: DataAdapter; clock?: () => number }): Lifecycle;
// store.ts
export interface DeletionStore { locked<T>(uid: string, fn: (s: { get(uid): Promise<DeletionRecord|null>; save(row): Promise<void> }) => Promise<T>): Promise<T>; due(now: number): Promise<string[]>; }
export function createPostgresDeletionStore(databaseUrl: string): DeletionStore; // dedicated connection per lock (never pooled while locked), lock_timeout 30 s, pg_advisory_lock(hashtextextended(uid, 714031)) — Task 2 withUidLock reused
// adapters.ts
export interface AdminAdapter { user(uid): Promise<{ disabled: boolean; lastLoginMs: number } | null>; disable(uid): Promise<void>; enable(uid): Promise<void>; delete(uid): Promise<void>; }
export function createFirebaseAdmin(app: App, allowedAppIds: Set<string>): AdminAdapter & { verify(token: string, attestation: string, opts?: { allowDisabled?: boolean }): Promise<Claims> }; // disabled-token recovery semantics ported (check_revoked false path + tokens_valid_after comparison → revoked_token)
export interface CleanupStep { name: string; run(uid: string, ctx: CleanupContext): Promise<void>; }
export interface DataAdapter { prepare(uid): Promise<CleanupContext>; validateContext?(ctx): void; revokeKeys(uid, ctx): Promise<void>; requiredDeletionSteps?: CleanupStep[]; deletionSteps(): CleanupStep[]; }
export function createCloudCleanup(deps: { db: Db; redisDb2: Redis; litellm: LiteLlmAdmin; r2: R2Deleter; images: { deleteAccount(uid): Promise<void> }; shares: { deleteAccount(uid): Promise<void> }; byok: { deleteAccount(uid): Promise<void> } }): DataAdapter;
// checkpoint stages (durable, ordered, idempotent, each retried until saved — "data:<name>" markers in record.completed):
// keys: enumerate ALL uid keys from Postgres state (keyids in db2 + LiteLLM /key/info by user) → /key/block each, captured in cleanup_context BEFORE effects
// data:gateway (/key/delete all tokens — cache eviction), data:sessions (sessions/messages/session_events/runs + Redis stream DEL sess:*), data:workspaces (R2 objects under users/{uid}/ + workspace_objects + file_manifests), data:schedules (schedules/schedule_runs), data:browser (browser_states + R2 users/{uid}/browser/*), data:byok (byokKeys rows), data:images (ledger deleteAccount), data:shares (sharesRepo.deleteAccount), data:reports (reports rows), data:sql (users/plan overrides/audit-by-target retention per tombstone policy), data:redis (SCAN-del user:{uid}:*, freecap:{uid}:*, abuse:uid:{uid}, mintlock:{uid}, usagecache:{uid}; SREM ovid:uids, ipacct:* memberships; shared IP counters NOT deleted)
// auth: firebase delete last; tombstone row (uid, request ids, deadline, state, checkpoints) retained — no email/photo/tokens remain
// gateway routes/account.ts (LEGACY exact paths, registered on the gateway OUTSIDE the /cloud/v1 prefix; response bodies {state, delete_after, request_id}; errors as HTTPException-parity {"detail": code} with the Python status codes)
export function registerAccountRoutes(app: FastifyInstance, deps): void; // POST /account/deletion, GET /account/deletion, POST /account/login, POST /account/deletion/cancel (body {consent:true} else 400 explicit_consent_required; disabled-token allowance ONLY on cancel/status/receipt-replay per the password-migration rule)
// worker accountSweep.ts
export function startAccountDeletionSweeper(deps: { lifecycle: Lifecycle; store: DeletionStore; intervalMs?: number }): { stop(): Promise<void> }; // every 30 s: due(now) → finalize(uid, {scheduled:true}) each, errors logged without UID/credential content, retried via durable backoff; runs once at boot
// gateway/mint integration: /mint, /upgrade, /billing/verify and images admission call lifecycle.access (or a lightweight tombstone check via accountDeletions.get when the lock is too heavy for the hot path — PIN: tombstone check for /mint hot path, full access() lock for admin mutations and billing verify)
```

- [ ] **Step 1: Write failing tests** — ports of `server/account/tests/test_lifecycle.py`, `test_worker.py`, `test_adapters.py`, `test_api.py`, `parallel_account_cleanup_test.py` (fake Admin/Data adapters + injected clock; store tests on TEST_DATABASE_URL): request sets delete_after = now+86400 exactly; duplicate request_id returns the original receipt and cannot extend the deadline; second id while pending coalesces into aliases and stays bound after cancel; completed id → request_already_completed even after a newer request; re-auth 301 s old → reauthentication_required (both check points); cancel after deadline → deletion_in_progress; cancel inside the 60-s settlement window with fence_owned → restores + admin.enable called exactly once, intent persisted before enable (crash between → still cancelled on retry); login never mutates state (assert record unchanged) and never re-enables; finalize: pending→fenced→(disable)→settlement→deleting→steps→deleted with each checkpoint saved (kill-and-resume simulation: throw inside step N, re-run → completed steps NOT re-executed — capture adapter call counts); backoff: failure → next_attempt = now+60×2^n capped 3600 measured from attempt end; due ordering puts unattempted before poison rows; keys stage blocks BEFORE deletes; data:redis patterns exact (SCAN match list asserted); tombstone survives completion (row present, no cleanup_context, no email); gateway routes: snake_case bodies, 401/403/409 detail codes, cancel without consent → 400; sweeper: two due rows both finalized, one throwing row doesn't stop the other and is retried after backoff.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (package `@ovid/account` scaffold; gateway env unchanged — routes reuse the gateway's firebase verifier mapped to Claims; worker main.ts wires the sweeper) → **Step 4: Verify pass** (`pnpm --filter @ovid/account --filter @ovid/gateway --filter @ovid/worker test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): account deletion lifecycle — state machine port, legacy routes, durable sweeper, cloud cleanup adapters"`

### Task 16: Shares + reports ports (gateway, legacy paths)

**Files:**
- Create: `cloud/apps/gateway/src/shares/{routes.ts,snapshot.ts,viewer.ts,headers.ts}`; `cloud/apps/gateway/src/routes/reports.ts`
- Test: `cloud/apps/gateway/src/shares/{routes.test.ts,snapshot.test.ts}`, `cloud/apps/gateway/src/routes/reports.test.ts`

**Interfaces:**
- Consumes: `sharesRepo`/`reportsRepo` (Task 2), gateway verifier (firebase), Task 15 `lifecycle.access` as the admission callback, env `OVID_SHARE_BASE_URL`, `OVID_ANDROID_PACKAGE_NAME` (default com.dhanuk.ovidai), `OVID_ANDROID_RELEASE_CERT_SHA256`.
- Produces:

```ts
// snapshot.ts — port of shares/snapshot.py
export const PRIVATE_TEXT: RegExp;   // copied VERBATIM (think/analysis/reasoning/system-reminder tags, subagent/schedule/plugin/context/system/attachments brackets, "Background subagent ", credential prefixes, PEM private-key, data:…;base64,, sk-/gh?_ tokens, /data/(user|data)/, /root/, /home/, file:// — case-insensitive)
export function parseCreateShare(body: unknown): CreateShare;  // zod extra-forbid equivalents: session_id/request_id ^[A-Za-z0-9_-]{1,128}$, messages 1..500 of {role: user|assistant, content 1..20000 non-blank, PRIVATE_TEXT reject}, total content ≤200000 UTF-8 bytes; raw body bound 1_500_000 bytes enforced at the route (413 snapshot_too_large); validation failures → 422 {"detail":"invalid_snapshot"} (never echo rejected content)
// headers.ts
export const SHARES_HEADERS: Record<string, string>; // Cache-Control no-store,private,max-age=0; Pragma; X-Robots-Tag noindex,nofollow,noarchive; nosniff; no-referrer; CSP default-src 'none'; style-src 'unsafe-inline'; base-uri/form-action/frame-ancestors 'none'; sandbox
export const OPEN_APP_SCRIPT: string;                 // verbatim intent script; export function pageCsp(): string — "script-src 'sha256-<b64(sha256(script))>'" computed at module load
// viewer.ts
export function landingPage(opts: { title; heading; lead; body; host; path; play; status? }): { html: string; csp: string }; // exact structure incl. data-pkg/data-play attributes, escaped text, CTA links
export function playStoreUrl(shareToken: string, invite?: string): string; // referrer=share_token(+invite) urlencoded
// routes.ts
export function registerSharesRoutes(app: FastifyInstance, deps: SharesDeps): void;
// LEGACY paths on the gateway root (NOT /cloud/v1): POST /shares 201 {id,url,session_id,request_id,created_at,expires_at} (url = configured base + "/s/" + token, never Host headers); GET /shares?session_id= owner-only active receipts {shares:[…+request_id]}; PUT /shares/{token}; DELETE /shares/{token} 204 idempotent-owned / 404; POST /shares/{token}/fork {request_id} → 201 {session_id} idempotent per recipient, revoked/expired → 409; GET /s/{token} HTML viewer (escaped <pre> rows, 404 page for unknown/revoked/expired); GET /s/{token}.json; GET /s/{token}/{invite} invite landing (43-char tokens validated, NO lookup, 10-member cap enforced by join not here); GET /.well-known/assetlinks.json (503 android_release_fingerprint_not_configured until env set; colon-hex fingerprint validation; Cache-Control public,max-age=3600)
// tokens: 43-char base64url from 32 random bytes (crypto.randomBytes(32).toString("base64url")); TTL 30 d default; quotas 100 active / 1000 lifetime per owner → 429 on create only (reads/revoke/cleanup always work); revocation/expiry do NOT reset the lifetime budget; expiry sampled INSIDE the write transaction (queued retry never gets a born-expired receipt); purged body terminal even if the clock moves back
// auth: Bearer + AppCheck via the gateway verifier mapped to the shares verify_uid contract; every owner operation wrapped in lifecycle.access (deletion fence)
// reports.ts
export function registerReportsRoutes(app: FastifyInstance, deps): void;
// POST /v1/reports (legacy path; Caddy adds an exact-match rule ahead of LiteLLM /v1/* in Task 18) → 201 {"id"} first time / 200 on (reporter,request_id) dedup; body EXACT: request_id ^[A-Za-z0-9_-]{16,64}$, kind ∈ {ai_output, shared_conversation, collab_message, collab_participant}, reason ∈ {sexual, child_safety, hate, violence, self_harm, illegal, misleading, privacy, spam, other}, details ≤1000, excerpt ≤4000, target_id/model ≤128 optional; extra fields rejected; headers {Cache-Control: no-store, X-Content-Type-Options: nosniff}; reporter identity ONLY from the verified token
```

- [ ] **Step 1: Write failing tests** — ports of `server/shares/tests/test_shares.py` + `parallel_shares_invariants.py` and `server/reports/tests/test_reports.py`: create→receipt fields + url built from config base only (Host header spoof ignored); dedup identical retry → same immutable receipt; changed content same request_id → 409; revoked receipt retry → 409; 101st active → 429 while GET/DELETE still work; lifetime 1000 budget not reset by revoke/expire; token format `^[A-Za-z0-9_-]{43}$`; PRIVATE_TEXT matrix — each envelope class rejected with 422 invalid_snapshot and NO content echoed; 200 001-byte total → 422; raw 1.5 MB+1 → 413 snapshot_too_large; viewer: escaped `<script>` renders inert, headers exact (assert every SHARES_HEADERS entry + PAGE_CSP with the computed sha256), 404 page for revoked/expired/unknown; fork idempotent per recipient, revoked → 409, source snapshot unmutated; assetlinks 503 → configured 200 with fingerprints upper-cased, invalid fingerprint → 503; purge_expired erases content, receipt rows persist; deleteAccount tombstone blocks in-flight creates; reports: 201 then 200 dedup, unknown kind → 422-shape rejection, reporter uid from token only (body uid field ignored/rejected), details 1001 chars rejected; fenced (deletion-pending) user → 403 on create via lifecycle.access.
- [ ] **Step 2: Verify fail** → **Step 3: Implement** (Fastify raw-body capture with the 1.5 MB bound before JSON parse; `rawBody` via `addContentTypeParser`) → **Step 4: Verify pass** (`pnpm --filter @ovid/gateway test`).
- [ ] **Step 5: Commit.** `git commit -m "feat(cloud): shares + reports ports — 43-char tokens, quotas, screening, hardened viewer, assetlinks"`

### Task 17: e2e money-path integration — TS mint through the REAL Python hook

**Files:**
- Create: `cloud/apps/e2e/src/money.test.ts`, `cloud/apps/e2e/hook-contract/{conftest.py,test_hook_contract.py,README.md}`
- Modify: `cloud/apps/e2e/package.json` (no new runtime deps; the pytest harness shells out)

**Interfaces:**
- Consumes: `buildMintApps` (Tasks 3–8, 10, 13), `createBillingService`, gateway `buildGateway` + `createInternalMintProvisioner`, worker `createServerKeyResolver`, the UNMODIFIED `server/mint/litellm_hook/ovid_pools.py` + `server/mint/ovid_plans.py`, disposable Postgres/Redis.
- Produces: the money-path regression harness every later phase extends; proof that the hook contract holds end-to-end (Review Focus #1).

- [ ] **Step 1: Write the TS e2e** (`money.test.ts`, `describe.skipIf(!TEST_DATABASE_URL || !TEST_MINT_REDIS_URL)`, mock LiteLLM admin+proxy via `http.createServer`): flow — build mint apps (test-mode verifier stub for Firebase) listening on port 0; `POST /mint` → key + tier; seed spend by writing `pool:{uid}:spend` via a simulated hook success event OR by driving the pytest harness (Step 2); `POST /usage` → remaining_fraction reflects the spend; `POST /billing/verify` with stubbed Play (active, 3x) → Redis `user:{uid}:tier === "3x"` with PTTL ≈ expiry+600, Postgres users.tier starter, mock LiteLLM captured `/key/update` with the new budget (tier change visible in enforcement); internal mint: worker `createServerKeyResolver` with empty db2 + unattended → signed `POST /internal/mint-key` → key identical to `/mint`'s (idempotency across paths); free-cap exhausted → gateway messages route relays 402 envelope; ban → `/key/block` captured and `/mint` 403.
- [ ] **Step 2: Write the real-hook harness** (`hook-contract/test_hook_contract.py`, run via `python3 -m pytest` from the repo root; skipped in CI when `HOOK_CONTRACT_REDIS_URL` unset or python3/deps missing — the Vitest wrapper test shells out and asserts exit code, and SKIPS loudly with a printed warning when unavailable): TS side writes settings/tier/pools/window state into the disposable Redis via `projection.publishSettings()`+`publishUserTier` (driven by a tiny TS script `cloud/apps/e2e/hook-contract/seed.ts` run with tsx); pytest then instantiates `OvidPools(redis_client=redis.asyncio against HOOK_CONTRACT_REDIS_URL)` — assertions: (a) pre-call under allowance → data passes through unchanged; (b) spend ≥ allowance (non-slow plan) → `ProxyException` with `type == "daily_limit_reached"`, code 429, headers `x-ovid-error`/`x-ovid-resets-at` (ISO `…Z`)/`retry-after` ≥ 1, `provider_specific_fields == {"ovid_error": …, "resets_at": …}`; (c) slow-mode plan over allowance → allowed, uid added to `pools:slow_pending` after a simulated success event with `response_cost`; (d) auto_oss plan + model "auto" + `config:model_groups` published by TS → rewritten to a member with `data["fallbacks"] == [{picked: [others]}]` and `metadata.ovid_auto`; member absent from model_groups → skipped; empty/invalid members → plain auto, never fails; (e) success accounting: `INCRBYFLOAT pool:{uid}:spend` equals the cost string exactly and TTL ≈ window end; `pool:{uid}:auto` HINCRBY per served model; (f) settings parse: `parse_settings(HGETALL config:limits, GET config:base_daily_usd)` over TS-written values equals the Python-seeded baseline field-for-field (the shape-drift canary).
- [ ] **Step 3: Run both.** `cd cloud && TEST_DATABASE_URL=… TEST_MINT_REDIS_URL=redis://127.0.0.1:6390/9 HOOK_CONTRACT_REDIS_URL=redis://127.0.0.1:6390/9 pnpm --filter @ovid/e2e test` — Expected: PASS (harness ran, not skipped — assert on the wrapper's "executed" flag when python3 exists; dev boxes have it). Then full `pnpm -r build && pnpm -r test`.
- [ ] **Step 4: Fix wiring only** (no behavior changes in units; unit suites stay green).
- [ ] **Step 5: Commit.** `git commit -m "test(cloud): money-path e2e + real Python hook contract harness against TS-written db2"`

### Task 18: Decommission runbook, deploy artifacts, activation (owner-gated)

**Files:**
- Create: `cloud/deploy/{DECOMMISSION.md,Dockerfile.mint,caddy-flips/}`, `cloud/scripts/migrate/{importRedisDb2.ts,importImagesLedger.ts,importSharesSqlite.ts,verifyMigration.ts,seedFresh.ts}` (scripts WRITTEN and unit-tested here, EXECUTED only at the owner-gated step)
- Modify: `cloud/deploy/{docker-compose.yml,.env.example,DEPLOY.md}`, `cloud/apps/mint/src/main.ts` (wire projection resync-at-boot, background loops, card manager, billing/images mounts, `MINT_PROJECTION_MODE=import-first|authoritative` env, default `authoritative`)

**Interfaces:**
- Consumes: everything above; live-stack facts: Caddy site `api.ovidsi.com` with `@images`(/v1/images/*,/v1/models→8090), `@mint`(/mint,/healthz,/upgrade→8090), `@usage`(→8090), `@account`(/account/*,/sync/v1/*,/chat*,/shares*,/s/*,assetlinks→8080 account-dev), `@api`(/v1/*→LiteLLM 4000), containers `ovid-gateway-{caddy,mint,litellm,account-dev,redis,img-edit-shim,postgres}`.
- Produces: the executed cutover (owner present) and `DECOMMISSION.md` as the auditable runbook.

- [ ] **Step 1: Write DECOMMISSION.md** — per-route-group flip procedure, each: timestamped Caddyfile backup (`cp Caddyfile Caddyfile.bak-$(date -u +%Y%m%dT%H%M%S)`), edit, `caddy validate`, `caddy reload`, smoke curls with expected outputs, rollback (restore backup + reload + re-smoke). Flip order (spec §13.4, least money-critical first): (1) `@account` group → gateway `127.0.0.1:8081` for /account/*, /shares*, /s/*, assetlinks — and DELETE the /sync/v1/* + /chat* rules (sync is deleted per D6; **GATED on owner Q1** — installed app builds using sync must be force-updated first or the rules stay until forced-update ships); (2) NEW exact-path rule `/v1/reports` ahead of `@api` → gateway; (3) NEW `/billing/*` → mint-ts 8091; (4) `@images` → mint-ts 8091; (5) `@mint`+`@usage`+`/healthz`+`/upgrade` → mint-ts 8091 (LAST); (6) stop containers in order: `account-dev` (after 1–2 soak), `mint` (after 4–5 soak); KEEP `litellm`, `img-edit-shim`, `redis`, `postgres`, `caddy` (Python hook stays per D2/G10). Soak = ≥24 h with alert watch between money groups. Dual-run rule: while both mints are up they share db2 + LiteLLM; TS mint MUST boot in `import-first` mode the first time (Step 3) and must never FLUSH db2.
- [ ] **Step 2: Write migration scripts + unit tests** (run against fixture DBs in tests, never live here): `importRedisDb2.ts` — reads live-shaped db2 (config:limits/base, per-user tier/dailyUsd/pools/monthlyCapUsd/banned/email/keyids, ovid:uids) into Postgres insert-if-absent; `importImagesLedger.ts` — SQLite `image_jobs`+`image_deleted_accounts` → imageJobs/imageDeletedAccounts preserving pending/unknown reservations, exact charged/actual strings, replay/receipt deadlines, tombstones (the README's coordinated-upgrade rules: drain first, never convert unknown→failed); `importSharesSqlite.ts` — shares SQLite → Postgres incl. lifetime-budget rows; `verifyMigration.ts` — dual-run verification: row-count parity per table, sampled receipt equality (exact strings), `config:limits` field-by-field equality Postgres↔Redis, `/usage` body equality for N sampled uids between Python :8090 and TS :8091 (read-only POSTs); `seedFresh.ts` — clean-break seeding (seed plans/settings, no user data). Script tests use temp SQLite fixtures + disposable Redis/Postgres.
- [ ] **Step 3: CONDITIONAL gate (owner question Q1 — clean break vs installed base).** PAUSE and ask the owner. Clean break → run `seedFresh.ts` only, skip imports, mark migration scripts dormant. Installed base → drain image workers, run `importRedisDb2.ts` + `importImagesLedger.ts` + `importSharesSqlite.ts`, then `verifyMigration.ts` with zero mismatches required before any flip; first TS mint boot with `MINT_PROJECTION_MODE=import-first`.
- [ ] **Step 4: Deploy artifacts (dry).** `Dockerfile.mint` (node:22-slim, pnpm fetch/build, `node dist/main.js`); compose `mint` service finalized (both ports 127.0.0.1-bound, `mintdata` volume for audit JSONL + limits.json mirror, env block in `.env.example`: every var from Task 3 + `MINT_PROJECTION_MODE`, `OVID_MASTER_KEY` for worker/gateway, `HOOK`-untouched note); `docker compose config -q`; `bash -n` on scripts; NO up, NO reload, NO script execution against live data.
- [ ] **Step 5: Commit.** `git commit -m "docs(cloud): P9 decommission runbook, caddy flips, conditional migration scripts (execution owner-gated)"`
- [ ] **Step 6: ACTIVATE (owner present — stop-condition: side effects outside the repo).** With the owner: run Step-3 branch, `docker compose up -d --build mint`, flip groups 1→5 per DECOMMISSION.md with smokes and soak windows, then container stops. Abort/rollback at any failed smoke. Record the activation in the SDD ledger.

---

## Conditional Section A: Collaboration v2 (OWNER Q6 GATE — do not dispatch until answered)

**Gate:** owner question Q6 (port/redesign vs cut) is PENDING in the SDD ledger. Nothing in Tasks 1–18 depends on this section; Task 16 already ports the `/s/{token}/{invite}` landing page and the reports `collab_*` kinds so either variant starts from a consistent base. Record the owner's answer in the ledger, then execute exactly one variant.

**Variant A — shared server-run sessions (spec §14 P9 "collab v2"):** members watch and steer ONE server-run session; the run executes on the initiator's key/allowance (billing attribution to the initiator — the worker's `resolveForRun` uses the initiator uid; members never spend); approvals route to the session OWNER only (gateway WS `system` channel presence/approval semantics from P1/P3); member cap 10 (enforced at join, matching the invite-landing copy); invite tokens reuse the 43-char base64url generator.
- A1: `@ovid/db` tables `collabSessions` (id uuidv7, hostUid, sessionId ref, title, status active|closed, createdAt), `collabMembers` (sessionId, uid, role owner|member, joinedAt, revokedAt; pk(sessionId,uid)), `collabInvites` (token char(43) pk, sessionId, createdBy, expiresAt, revokedAt) + repos; tests: cap-10 join, revoke, idempotent invite accept.
- A2: gateway routes `/cloud/v1/collab/*` (NEW conventions: camelCase, ApiError envelope): POST sessions (binds an existing owned session), POST invites, POST join {inviteToken}, DELETE members/me, DELETE members/:uid (owner only), POST close, GET state; WS `system`-channel presence + event fanout to members (subscribe by collab session → same EventLog replay/dedupe machinery, ownership check extended to active members); steering = member POST message appended with `authorUid` metadata, single-active-run rule unchanged (queued behind the host's run).
- A3: attribution + approvals e2e: member-steered run spends the HOST's allowance (hook counter lands on host uid — assert db2 `pool:{host}:spend`), approval request events deliver only to the owner connection, member disconnect never kills the run (AG1); tests extend `cloud/apps/e2e`.
**Variant B — cut entirely:**
- B1: remove collab surface: no tables ship (drop `collabSessions/Members/Invites` from any migration drafted under Variant A), remove `/s/{token}/{invite}` route + the `invite` param of `playStoreUrl` (Task 16 code deleted in this task, tests updated), keep the reports `collab_message|collab_participant` enum values (client compatibility, server accepts and stores), delete `server/collaboration` decommission line from DECOMMISSION.md (never deployed — nothing to stop), record the cut in the ledger. One task, one commit: `git commit -m "chore(cloud): collab v2 cut per owner Q6 — invite landing removed, report kinds kept"`.

## Conditional Section B: Data migration scope (OWNER Q1 GATE)

**Gate:** owner question Q1 (clean break vs installed base) is PENDING. Task 18 Step 3 is the decision point; this section only records the two branch contents so the executor cannot improvise.
- **Clean break (thin-client-only launch):** run `seedFresh.ts` (seed plans/settings/products), owner sets live values in the ported admin console (free allowance 0.50 live / 0.15 seed decision, paid windows 720 h vs 24 h — the console edits are the migration), no user-data imports, `verifyMigration.ts` runs in settings-only mode (config:limits + /plans + /usage-shape equality for one synthetic user). Python containers stop after soak; existing Redis db2 user state is abandoned with the Python stack (documented data-loss boundary in DECOMMISSION.md, owner-acknowledged).
- **Installed base:** full Task-18 Step-2/3 pipeline (drain → import → verify → import-first boot → flips with 24 h soaks). Extra verification: `verifyMigration.ts` `/usage` equality sample ≥ 20 live uids, image ledger pending/unknown reservation count parity (MUST be exact — unresolved money), shares lifetime-budget parity (quota regressions would lock users out), and a rollback plan per flip (Python container restarts stay possible until the mint image is deleted — last step, after a 7-day soak, owner-gated).

---

## Self-Review Notes (completed per writing-plans skill)

- **Spec coverage:** D2 (mint/hook contracts) → Tasks 4–8, 17; D3 (BYOK escrow, SSRF-guarded probe) → Task 11; D6 (sync deleted, shares/reports ported, collab gated) → Tasks 16, 18 flip (1), Conditional A; D7/G9 tier gates ride on users.tier + Task 10 sink; G10 (Python decommissioned, hook + img-edit-shim kept) → Tasks 17–18 + Global Constraints; G11 unaffected (no new hot-path services; mint calls are cached/idempotent); §10 money tables → Task 2 (plans/usage windows via db2 + billing_purchases/image_jobs/shares/reports/account_deletions/byok_keys); §13 strangler order → Task 18 (account-dev → shares → reports → collab(n/a) → billing → images → mint LAST). Rulings: Q4 (Postgres authority, db2 projection, boot+change resync, Postgres wins, admin console ported) → Tasks 4, 8; Q5 (server-to-server minting) → Task 9; Q9 (shim untouched, contract surface ported) → Tasks 12–14 + constraints. Anti-abuse/ban/slow-mode/window/backstop/plans-as-data/auto-oss publication → Tasks 4–8. Billing verify+RTDN full matrix incl. OIDC fail-closed, sticky states, EXAT+600 → Task 10. Images: Decimal-exact ×0.30, cost order, 409+receipts, cards/ETag, no_capacity cooldowns/fallback, unpriced gate, probe budgets, retention → Tasks 12–14. Account state machine incl. 24 h/60 s/5 min constants, advisory locks, cloud-store checkpoints → Task 15. Shares/reports contract details (43-char tokens, quotas, TTLs, regexes, headers, assetlinks) → Task 16.
- **Step scan:** every step names one artifact with exact signatures/values; bodies omitted except where the contract IS the value list (key inventory, constants, error strings). Conditional sections carry explicit gates, not TBDs. Two builder choices are pinned with rationale (decimal.js over micro-USD in Global Constraints; HMAC over mTLS in Task 9); one deliberate deviation documented in-task (image decode without PIL `im.load()`, Task 13 Step 3).
- **Type consistency:** `Settings/PlanData/Pools` snake_case fields defined Task 4 and consumed unchanged in Tasks 5–8, 13 (`tierBudget` returns `{budget,duration}` everywhere); `ResolvedKey/KeyResolver/ByokKeyProvider/InternalMintProvisioner` defined in Task 9's Produces and implemented by Task 11 (`createByokKeyProvider`) — names cross-checked; `ImageLedger`/`Receipt`/`ImageError` defined Task 12, consumed Task 13/14/15 (`images.deleteAccount`); `Entitlement` fields (Task 10) match `billingPurchases.record`'s `EntitlementFields` (Task 2); `PublicState` snake_case (Task 15) matches the Python `public()` keys; `TIER_SKEW_SECONDS=600`, `GRACE_SECONDS=86400`, `FENCE_SETTLE_SECONDS=60`, `RECENT_AUTH_SECONDS=300`, `REPLAY_RETENTION=86400`, `RECEIPT_RETENTION=7776000`, probe caps 0.50/5.00, cooldown bound 1..120/default 30, abuse knobs 40/12/20/500 — all copied from the Python sources, single occurrence each.
- **Review Focus:** all five lines pinned to owning tasks (1→T4 hookContract.test.ts + T17 harness; 2→T1 golden vectors + T12 exact strings + T5 pyRound6; 3→T10 EXAT/sticky/redelivery; 4→T7 auto-ban-blocks-keys + T15 fence/checkpoints; 5→T12/T13 receipts & reservations).
- **Proportion:** ~18 tasks for a phase covering seven Python services; contracts are carried as signature lists + pinned values + ported-test inventories rather than code bodies. The Python suites named per task are the test oracle; the plan decides names, shapes, values and gates — the implementers write the code.
- **Known risks carried:** P3/P4/P5 plans were written in parallel — Task 9's `RunDeps.keys`/`AgentRunJob.byokKeyId` and Task 15's worker wiring must be reconciled with P3's KeyResolver seam and P4's maintenance/schedules queues at dispatch time (noted in-file); the live stack currently mounts images on Python mint but NOT billing (verified read-only on the box 2026-10-16), so flip group (3) is an activation, not a migration — DECOMMISSION.md says so.
