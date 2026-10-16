# Ovid Cloud P7 — StateHydrator + Cloudflare R2 (Hibernation & Lazy Hydration) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Idle workspaces evict to Cloudflare R2 within ~3 minutes, Studio opens instantly from a Postgres-resident ≤5 KB file-tree manifest, single files lazy-extract from the archive in <500 ms, full hydration restores a ≤200 MB workspace in <5 s, and artifacts/browser states flow through the same R2 client with presigned URLs.

**Architecture:** New package `cloud/packages/storage` (`@ovid/storage`) holds everything: the `ovid-ws-grouped-v1` archive codec (grouped zstd-9 frames + compact JSON index + 24 B footer, per the BINDING spike), a `StorageAdapter` seam with an R2 impl (`@aws-sdk/client-s3`, S3-compatible) and a filesystem impl (tests/dev, credential-free), the hibernation engine (pack → stream to multipart upload → verify by re-download sha256 → crash-safe local evict → Postgres rows), the hydration engine (parallel `extractAll` via `worker_threads`, or lazy `extractOne` per file with a worker-side index cache), a warm-cache LRU + disk-pressure guard + 30 s idle sweeper (consuming P2's workspace enumeration/eviction seam — Cross-plan contract 1), and the artifacts pipeline. Worker exposes an internal file-service (tree/read/write) that the gateway proxies behind auth; the gateway serves the manifest-first tree from Postgres with zero extraction and presigns artifact URLs. Two new Postgres tables (`file_manifests`, `workspace_objects`) and two new BullMQ queues (`hibernate`, `hydrate`) extend the P1 spine additively.

**Tech Stack:** Node 22 built-in zstd (`node:zlib` zstd 1.5.7 — no native deps, no CLI spawn), AWS SDK v3 (`@aws-sdk/client-s3`, `@aws-sdk/lib-storage`, `@aws-sdk/s3-request-presigner`), `node:worker_threads`, Drizzle ORM (Postgres 16), BullMQ 5, ioredis, Fastify 5, Vitest, zod.

**Spec:** `docs/superpowers/specs/2026-10-15-ovid-cloud-migration-design.md` — G7, §6.1 (StateHydrator), §10 (R2 layout + hydration SLAs), §14 P7 row, §11 (secrets).

**Research (BINDING):** `.superpowers/sdd/2026-10-15-ovid-cloud-p0-p1-spine/research/p7-archive-format-spike.md` — the measured winner is the **grouped-frames format "OVIDWS-G1"** (NOT frame-per-file). Its §9.1 byte layout, §9.2 implementation surface, §9.3 eviction/hydration flow, and §8 bug list (two-pass extraction, solo-frames-don't-shatter-groups, RFC-8878 FCS table) are the authority for the codec; this plan restates the load-bearing constants but the executor MUST read the report. The spike's scratch dir (`/tmp/opencode/r2proto`) did not survive the box migration — implement from §9.1/§9.2, not from the prototype. Spike timings were measured on the OLD, slower box (2013 Xeon E5-2690 v2, virtio); this box is 8 vCPU AMD EPYC-Milan / 22 GB / 193 GB disk (faster per core, fewer cores) — Task 13 re-proves every SLA here.

## Global Constraints

- Wire format: JSON, **camelCase**; ids are **UUIDv7**; timestamps ISO-8601 UTC. Route prefix `/cloud/v1/*`.
- New code only under `cloud/`; deploy target `/opt/ovid-cloud`. Never touch the live `/opt/ovid-gateway` stack.
- `@ovid/shared` extensions are **ADDITIVE**: new event-type union members / enum entries / exports only; never modify or remove existing types, members, or schemas.
- Error envelope (REST): `{ "error": { "code": string, "message": string } }`. Existing codes kept (`unauthenticated`, `forbidden`, `not_found`, `bad_request`, `internal`, `unavailable`); this plan adds exactly one: `invalid_state` (409, workspace state conflicts).
- **Exact size/checksum arithmetic:** byte sizes are integers end-to-end (Postgres `bigint`, JS `number` only after a `Number.isSafeInteger` assertion at the repo boundary); sha256 values are lowercase-hex strings compared exactly; never parse a checksum or size as a float, never round.
- SLAs from spec §10 are **acceptance criteria**, proven by Task 13 on this box class: manifest-first tree **<100 ms** (from Postgres, zero extraction), single-file extract **<500 ms**, full hydrate **<5 s for ≤200 MB** (parallel frame workers mandated — spike §5.3: single-threaded is borderline).
- **No credentials in logs/events/repo:** R2 secrets come only from env (`OVID_R2_ACCOUNT_ID`, `OVID_R2_ACCESS_KEY_ID`, `OVID_R2_SECRET_ACCESS_KEY`, `OVID_R2_BUCKET`); error messages carry variable NAMES never values; presigned URLs are capabilities — never log them or put them in Postgres; events carry a presigned URL only in the `artifact_created` payload (short-lived, client-facing by design).
- **StorageAdapter keeps tests credential-free:** every unit/e2e test runs against `createFsStorage`; R2 is covered by contract tests through the same harness plus `describe.skipIf`-gated live tests that run only when all four `OVID_R2_*` vars are present.
- zstd via **Node 22 built-ins only** (`zlib.zstdCompress/zstdCompressSync/zstdDecompressSync`, bundled zstd 1.5.7 — spike: CLI-per-file spawn is 9× too slow, Node is byte-competitive). The `zstd` CLI (1.5.5 on this box) is allowed in TEST FIXTURES only (RFC-8878 frame pinning).
- R2 key layout EXACTLY per spec §10: `users/{uid}/workspaces/{session_id}.tar.zst`, `users/{uid}/workspaces/{session_id}.manifest.json`, `users/{uid}/browser/{profile_id}.zst`, `users/{uid}/artifacts/{…}` (pinned in Task 1 as `users/{uid}/artifacts/{sessionId}/{artifactId}-{sanitizedName}`).
- **Warm-workspace layout (controller ruling R1):** `/workspaces/users/{uid}/sessions/{sessionId}/workspace` — per-user uid dir (nft/cgroup keyed), per-session workspace inside it, equal to P2's `workspaceDir(userId, sessionId)` seam. P7 NEVER raw-walks `users/*/sessions/*` to enumerate or evict: it consumes the `SandboxEviction` seam from `@ovid/sandbox` (`listWarmWorkspaces()` + `evictWorkspace(userId, sessionId)` — Cross-plan contract 1). Postgres `file_manifests`/`workspace_objects` remain the authority.
- Production boundary: tests never touch `/workspaces`, `/opt/ovid-cloud`, or a live R2 bucket — tmp dirs + dev services only. Test env URLs (from `cloud/scripts/dev-services.sh`): `TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres`, `TEST_REDIS_URL=redis://127.0.0.1:6390`.
- **One warm-disk knob (controller ruling R2): `OVID_MAX_WARM_GB`, default 8** (the P1-era ledger Q8 ruling; the 8→12 GB retune consideration for this box is documented in Task 10 and decided by the owner at activation). P7's StateHydrator LRU (Task 10) OWNS enforcement; P2's attach-guard reads the same `OVID_MAX_WARM_GB` env var as an advisory check (its default may differ — reconcile to ONE value at deploy). Disk alert at **80 %** used, coordinated with the P1 backup script's 2048 MB free-floor.
- Commit after every task; run `pnpm -r build && pnpm -r test` from `cloud/` before committing. Node 22, pnpm workspaces, TypeScript `strict`, ESM (`"type": "module"`, `.js` import specifiers), tests colocated as `src/<module>.test.ts`.

## Cross-plan contracts (coordinate via controller; P2/P6 plans were being written in parallel)

1. **P2 SandboxManager** (controller ruling R1; P2's in-flight revision G1) owns the warm-workspace layout `workspaceDir(userId, sessionId)` = `{WORKSPACES_ROOT}/users/{uid}/sessions/{sessionId}/workspace` (per-user uid dir keyed by nft/cgroup; per-session workspace inside it) and exposes the enumeration/eviction seam P7 consumes as `SandboxEviction` (Task 8): `listWarmWorkspaces()` → per-session warm entries `{userId, sessionId, bytes, lastAccessMs}` and `evictWorkspace(userId, sessionId)` → pack-safe destroy via SandboxManager (kill jail/PTY/background jobs, LEAVE files). P7's sweeper/LRU NEVER raw-walks `users/*/sessions/*` — Postgres `file_manifests`/`workspace_objects` stay the authority; Task 1's pure `workspaceDir()` must equal P2's seam (pinned by an equality test once P2 lands). Until P2 lands, the worker wires `createNoopSandboxEviction()` (empty list, logged evicts, TODO(P2) markers). P2 admission control (`MAX_ACTIVE_SANDBOXES`) may call `enforceWarmCap()` (Task 10) to free slots under pressure. Warm-disk knob (ruling R2): one env var `OVID_MAX_WARM_GB`; P7's LRU owns enforcement (default 8), P2's attach-guard reads the same var — reconcile to ONE value at deploy.
2. **P6 browser-engine** fulfills its storageState seam with `createBrowserStateBlobStore()` (Task 1): P6 owns zstd-9 + AES-256-GCM envelope encryption + the `browser_states` table; P7 only stores/loads the opaque blob at `users/{uid}/browser/{profileId}.zst`.
3. **P3 agent-core** must keep the `ensureWarm` hook in the run processor (Task 11) so tool runs never execute against a cold workspace.
4. **redis-c** (spec §10's cache instance, `allkeys-lru`) is introduced by this plan's deploy task for activity keys; P1 shipped only redis-q. Activity keys are cache-class: eviction fails safe (fallback to `fileManifests.updatedAt`, and the hibernate job re-verifies before destroying anything).
5. **Worker relocation:** P2's spike moves the worker to a host systemd service; the gateway→worker file-service URL is env-driven (`OVID_WORKER_INTERNAL_URL`) so that move is config-only (`host-gateway`).
6. **P8 thin-client** (controller ruling R3): `StorageAdapter.presignPut(key, ttlSeconds)` (Tasks 1/2 — same `@aws-sdk/s3-request-presigner`, `PutObjectCommand`) exists so P8-T3's presigned-R2-PUT attachment-upload assumption (`uploadUrl`, key `users/{uid}/sessions/{sessionId}/uploads/{attachmentId}`) holds. P8's approved gateway-presigner fallback (ledger P8-Q3) remains available if P8 signs at the gateway instead. The fs impl returns the documented `file://` pseudo-URL (uploads in fs mode go through `adapter.put`).

## Review Focus

1. **Path traversal / key injection** — `?path=../../etc/passwd`, absolute paths, `%2e%2e`, a `uid`/`sessionId` segment containing `..`, or a warm-read symlink pointing outside the workspace. Expected: 400/404 envelope, zero reads/writes outside the session workspace, zero R2 keys outside `users/{uid}/…`. Pinned by Task 1 (key/segment guards), Task 9 (realpath jail on warm reads, `assertSafeRelPath`), Task 11 (file-service guards), Task 12 (route-level validation before any proxy).
2. **Corrupt or truncated archives** — bit-rot in R2, a partial multipart upload, a flipped byte in the index or footer. Expected: typed errors (`ArchiveCorruptError`/`ArchiveTruncatedError`/`HashMismatchError`), destination never receives garbage (temp+rename), hibernation NEVER deletes local data before a full re-download sha256 verify passes. Pinned by Task 5 (corruption matrix mirroring spike §7.2) and Task 8 (verify-before-delete + injected-verify-failure test).
3. **Hibernate/activity race** — the user returns at t≈179 s, or a run starts between sweeper-enqueue and job execution. Expected: the job re-verifies (fresh activity OR active run → no-op `skipped`); a jail with a running run is never destroyed (AG1). Pinned by Task 8 tests.
4. **Worker crash mid-hibernate/mid-hydrate** — killed after upload but before the Postgres flip, or mid-extract. Expected: `hibernating` + dir present → back to `warm` (re-pack later); `hibernating` + dir gone + verified archive → `cold` (rebuilt from the archive index); partial extraction dir → wiped and retried cleanly; no data loss, no zombie state. Pinned by Task 8 (`reconcileStuckHibernations`) and Task 9 (hydrate failure path).
5. **Disk pressure / warm-cap overrun** — Σ warm bytes above the `OVID_MAX_WARM_GB` cap (default 8), or the filesystem above 80 %. Expected: least-recently-active sessions evicted first, bounded evictions per sweep (no thrash), the 80 % alert fires with ~38 GB free — long before the P1 backup script's 2048 MB abort floor. Pinned by Task 10 tests (injected disk probe + tiny caps).

---

### Task 1: `@ovid/storage` scaffold — StorageAdapter, fs adapter, key layout, contract harness

**Files:**
- Create: `cloud/packages/storage/package.json` (name `@ovid/storage`, mirror `cloud/packages/queue/package.json` shape; deps `@ovid/shared: workspace:*`; devDeps `@types/node ^22.20.5`, `typescript ^5.6.0`, `vitest ^2.1.9`), `tsconfig.json` (extends `../../tsconfig.base.json`), `src/index.ts`
- Create: `cloud/packages/storage/src/errors.ts`, `src/keys.ts`, `src/workspacePaths.ts`, `src/adapter.ts`, `src/fsAdapter.ts`, `src/rangeReader.ts`, `src/browserState.ts`, `src/contract.ts`
- Test: `cloud/packages/storage/src/{keys.test.ts,fsAdapter.test.ts,rangeReader.test.ts,browserState.test.ts}`

**Interfaces:**
- Consumes: P1 workspace (`pnpm-workspace.yaml` and `vitest.workspace.ts` already glob `packages/*` — no registration edits needed).
- Produces (exact names later tasks import from `@ovid/storage`):

```ts
// errors.ts — every error carries a stable `code` string (goes into logs, never secrets)
export class StorageError extends Error { readonly code: string;
  constructor(message: string, opts?: { code?: string; cause?: unknown }) }
export class KeyLayoutError extends StorageError {}        // code "key_layout"
export class NotFoundError extends StorageError {}          // code "not_found"
export class WorkspaceStateError extends StorageError {}    // code "workspace_state"

// keys.ts — spec §10 layout, EXACT strings
export const r2Keys: {
  workspaceArchive(userId: string, sessionId: string): string;   // `users/${uid}/workspaces/${sid}.tar.zst`
  workspaceManifest(userId: string, sessionId: string): string;  // `users/${uid}/workspaces/${sid}.manifest.json`
  browserState(userId: string, profileId: string): string;       // `users/${uid}/browser/${profileId}.zst`
  artifact(userId: string, sessionId: string, artifactId: string, name: string): string;
  // `users/${uid}/artifacts/${sid}/${artifactId}-${sanitizeArtifactName(name)}`
};
export function assertSafeSegment(segment: string): void;
// throws KeyLayoutError on: empty, ".", "..", containing "/", "\\", control chars, or > 255 UTF-8 bytes
export function sanitizeArtifactName(name: string): string;
// [^A-Za-z0-9._-] → "_", collapse runs, strip leading dots, truncate to 80 chars, "" → "artifact"
export function assertSafeRelPath(rel: string): string;
// throws KeyLayoutError on: empty, absolute ("/" or drive), any ".." segment, "\\", control chars,
// > 4096 bytes; returns the "."-normalized POSIX-relative path

// workspacePaths.ts — layout per controller ruling R1 (converged with P2's per-session dirs):
//   /workspaces/users/{uid}/sessions/{sessionId}/workspace  ({uid} = per-user dir keyed by nft/cgroup)
export function workspaceDir(workspacesRoot: string, userId: string, sessionId: string): string;
// path.join(root, "users", uid, "sessions", sid, "workspace") AFTER assertSafeSegment on both ids;
// MUST equal P2's @ovid/sandbox workspaceDir(userId, sessionId) seam (contract 1) — pinned by an
// equality test once P2 lands; P7 keeps this pure helper so its suites run before P2 does
export const sessionWorkspacePath: typeof workspaceDir;  // rename alias (ledger continuity)

// adapter.ts
export interface PutResult { key: string; bytes: number }
export interface HeadResult { bytes: number; sha256Hex: string | null; etag: string | null;
  metadata: Record<string, string> }
export interface StorageAdapter {
  readonly kind: "fs" | "r2";
  put(key: string, body: NodeJS.ReadableStream | Buffer | Uint8Array,
      opts?: { contentType?: string; sha256Hex?: string; metadata?: Record<string, string> }): Promise<PutResult>;
  get(key: string): Promise<NodeJS.ReadableStream | null>;      // null = missing
  getBuffer(key: string): Promise<Buffer | null>;
  head(key: string): Promise<HeadResult | null>;
  delete(key: string): Promise<void>;                            // idempotent
  presignGet(key: string, ttlSeconds: number): Promise<string>;
  presignPut(key: string, ttlSeconds: number): Promise<string>;   // ruling R3: powers P8-T3 attachment
                                                                   // uploads (contract 6)
  readerSpec(key: string): Promise<ReaderSpec | null>;           // range-read handle spec; null = missing
}
export function createFsStorage(rootDir: string): StorageAdapter;
// fs semantics: key → path.join(rootDir, key) after per-segment assertSafeSegment;
// put streams via pipeline to `${path}.part-${pid}` then rename (atomic); sha256Hex computed while
// streaming and returned in head() (persisted in a `${path}.sha256` sidecar); metadata persisted as
// `${path}.meta.json`; presignGet/presignPut return `file://${absPath}#ovid-exp=${Math.floor(Date.now()/1000)+ttl}`
// (documented NOT capability URLs — fs adapter is for tests/dev only; uploads in fs mode go through
// `put`, and the R2-backed adapter signs real GET/PUT URLs)

// rangeReader.ts
export interface RangeReader { size(): Promise<number>; read(offset: number, length: number): Promise<Buffer> }
export type ReaderSpec =
  | { kind: "fs"; path: string }
  | { kind: "r2"; endpoint: string; region: string; bucket: string; key: string;
      accessKeyId: string; secretAccessKey: string };
export class FdReader implements RangeReader {
  constructor(path: string); size(): Promise<number>; read(offset: number, length: number): Promise<Buffer>;
  close(): Promise<void> }  // fs.open + filehandle.read (pread); read() resolves exactly `length` bytes or throws StorageError on short read past EOF
export function openReader(spec: ReaderSpec): Promise<RangeReader>;  // fs branch here; r2 branch added in Task 2

// browserState.ts — the P6 seam (P6 does zstd+encrypt; we store opaque bytes)
export interface BrowserStateBlobStore {
  save(userId: string, profileId: string, zstdBytes: Uint8Array): Promise<{ key: string; bytes: number; sha256Hex: string }>;
  load(userId: string, profileId: string): Promise<Buffer | null>;
  remove(userId: string, profileId: string): Promise<void>; }
export function createBrowserStateBlobStore(storage: StorageAdapter): BrowserStateBlobStore;
// profileId validated with /^[A-Za-z0-9_-]{1,64}$/ → KeyLayoutError otherwise

// contract.ts — shared adapter contract, run by fs tests here and R2 live tests in Task 2
export function describeStorageContract(name: string,
  make: () => Promise<{ adapter: StorageAdapter; cleanup: () => Promise<void> }>): void;
```

- [ ] **Step 1: Write the failing key-layout tests** (`src/keys.test.ts`): `r2Keys.workspaceArchive("u1","s1") === "users/u1/workspaces/s1.tar.zst"`; `.workspaceManifest` / `.browserState("u1","p1") === "users/u1/browser/p1.zst"`; `.artifact("u1","s1","0192c…","my shot.png") === "users/u1/artifacts/s1/0192c…-my_shot.png"`; `assertSafeSegment` throws `KeyLayoutError` for `"", ".", "..", "a/b", "a\\b", "a\nb"`, accepts `"01J…-uuid7"`; `assertSafeRelPath("a/./b") === "a/b"`, throws for `"/etc/passwd"`, `"../x"`, `"a/../..\\b"`, `""`; `sanitizeArtifactName("../../x y?.bin")` contains no dot-dot and matches `/^[A-Za-z0-9._-]+$/`.
- [ ] **Step 2: Run to verify failure.** Run: `cd /root/OvidAI/cloud && pnpm install && pnpm --filter @ovid/storage exec vitest run src/keys.test.ts` — Expected: FAIL (module not found).
- [ ] **Step 3: Implement** `errors.ts`, `keys.ts`, `workspacePaths.ts` per the signatures above; export from `src/index.ts` (placeholder `export const PKG = "storage"` is NOT needed — index re-exports modules).
- [ ] **Step 4: Write fs-adapter contract + unit tests** (`src/fsAdapter.test.ts`): run `describeStorageContract("fs", …)` over `createFsStorage(mkdtemp)` AND pin fs specifics: put of a multi-chunk `Readable` → `head().bytes` equals total, `head().sha256Hex` equals an independently computed `crypto.createHash("sha256")` hex; `get` stream reassembles to identical bytes; missing key → `get/getBuffer/head/readerSpec` all resolve `null`, `delete` resolves (idempotent); `put` with key `"../escape"` rejects with `KeyLayoutError` and writes nothing outside root; interrupted put leaves no `${path}` (only a `.part-` file). Contract body (shared): Buffer put + stream put round-trips, presignGet/presignPut non-empty strings (fs: `file://` pseudo-URLs; the R2 impl signs real URLs — Task 2), metadata round-trip via head, delete-then-get null.
- [ ] **Step 5: Run to verify failure, implement `adapter.ts` + `fsAdapter.ts` + `contract.ts`, run to verify pass.** Run: `pnpm --filter @ovid/storage exec vitest run src/fsAdapter.test.ts` — Expected: first FAIL, then PASS.
- [ ] **Step 6: RangeReader + browser-state tests and impl.** `src/rangeReader.test.ts`: write a 10 KB buffer to a tmp file; `FdReader.size() === 10240`; `read(4096, 100)` equals the exact slice; `read(10200, 100)` rejects `StorageError` (short read past EOF); `openReader({kind:"fs",…})` returns an FdReader. `src/browserState.test.ts`: save→load byte-identical with sha256Hex matching; load missing → null; profileId `"../evil"` → `KeyLayoutError`; key used equals `r2Keys.browserState`.
- [ ] **Step 7: Verify + commit.** Run: `pnpm -r build && pnpm -r test` (workspace green). Commit: `git add cloud/packages/storage && git commit -m "feat(cloud): @ovid/storage scaffold — StorageAdapter, fs adapter, R2 key layout"`

### Task 2: R2 StorageAdapter — S3 multipart streaming, presigned GET, range reader

**Files:**
- Create: `cloud/packages/storage/src/r2Adapter.ts`, `src/storageEnv.ts`
- Modify: `cloud/packages/storage/src/rangeReader.ts` (add `R2Reader` + the `r2` branch of `openReader`), `src/index.ts`
- Test: `cloud/packages/storage/src/{r2Adapter.test.ts,r2.live.test.ts,storageEnv.test.ts}`

**Interfaces:**
- Consumes: Task 1 (`StorageAdapter`, `ReaderSpec`, `describeStorageContract`, `StorageError`).
- Produces:

```ts
// r2Adapter.ts
export interface R2Config { accountId: string; accessKeyId: string; secretAccessKey: string;
  bucket: string; endpoint?: string }
export function r2Endpoint(accountId: string): string;   // `https://${accountId}.r2.cloudflarestorage.com`
export function loadR2Config(env: NodeJS.ProcessEnv): R2Config;
// reads OVID_R2_ACCOUNT_ID / OVID_R2_ACCESS_KEY_ID / OVID_R2_SECRET_ACCESS_KEY / OVID_R2_BUCKET;
// throws Error naming the FIRST missing var (values never appear in the message)
export const R2_PART_SIZE = 8 * 1024 * 1024;   // 8 MiB — spike §7.3: min part 5 MiB, ≤10k parts ⇒ ≤80 GB objects
export const R2_QUEUE_SIZE = 2;                // in-flight parts cap ≈ 16 MB RAM
export function createR2Storage(cfg: R2Config,
  opts?: { partSizeBytes?: number; queueSize?: number; maxAttempts?: number }): StorageAdapter;
// S3Client { region: "auto", endpoint: cfg.endpoint ?? r2Endpoint(accountId), credentials,
//   maxAttempts: opts?.maxAttempts ?? 4 }  (SDK standard-mode retries)
// put → @aws-sdk/lib-storage Upload { queueSize, partSize, leavePartsOnError: false,
//   params: { Bucket, Key, Body, ContentType, Metadata: { sha256?: hex, ...lowercased metadata } } }
//   (multipart ETags are NOT object hashes — caller-supplied sha256Hex travels in Metadata.sha256)
// head → HeadObject; sha256Hex = Metadata?.sha256 ?? null; missing key (NotFound/404) → null, never throw
// presignGet → getSignedUrl(GetObjectCommand, { expiresIn: ttlSeconds })
// presignPut → getSignedUrl(PutObjectCommand, { expiresIn: ttlSeconds }) — ruling R3 / contract 6:
//   the reusable PUT presigner P8-T3 assumes for attachment uploads (fs impl: pseudo-URL, Task 1)
// readerSpec → head() then { kind: "r2", endpoint, region: "auto", bucket, key, accessKeyId, secretAccessKey }

// rangeReader.ts addition
export class R2Reader implements RangeReader { constructor(spec: Extract<ReaderSpec, { kind: "r2" }>);
  size(): Promise<number>; read(offset: number, length: number): Promise<Buffer>; close(): Promise<void> }
// size() = HeadObject ContentLength; read() = GetObject { Range: `bytes=${offset}-${offset+length-1}` },
// collects Body stream to one Buffer, asserts exact length (short body → StorageError "r2_short_read")

// storageEnv.ts
export type StorageBackend = "fs" | "r2";
export interface StorageEnv { backend: StorageBackend; r2?: R2Config; fsRoot?: string }
export function loadStorageEnv(env: NodeJS.ProcessEnv): StorageEnv;
// OVID_STORAGE_BACKEND explicit ("fs"|"r2"); when unset: "r2" iff all four OVID_R2_* present, else "fs".
// backend "fs" requires OVID_FS_STORAGE_ROOT (non-empty). NODE_ENV === "production" && backend "fs"
// → throw (same fail-loud mindset as the gateway's test-auth-in-production gate).
export function createStorage(env: StorageEnv): StorageAdapter;  // fs → createFsStorage, r2 → createR2Storage
```

- [ ] **Step 1: Write failing config/env tests** (`r2Adapter.test.ts`, `storageEnv.test.ts`, no network): `loadR2Config` with one var missing throws a message containing the var NAME and not any other var's value; `r2Endpoint("abc") === "https://abc.r2.cloudflarestorage.com"`; `loadStorageEnv({})` → `{backend:"fs"}` fails (no `OVID_FS_STORAGE_ROOT`) — with it set → fs; all four R2 vars → r2 auto-detect; `NODE_ENV=production` + fs → throws; **presign is offline-computable**: `createR2Storage({accountId:"a",accessKeyId:"k",secretAccessKey:"s",bucket:"b"}).presignGet("users/u/x.tar.zst", 60)` resolves a URL whose origin is `https://a.r2.cloudflarestorage.com`, path contains the key, and query contains `X-Amz-Signature` and `X-Amz-Expires=60` (getSignedUrl signs locally — pin that no request is made by asserting it resolves with unreachable-account fake creds); `presignPut("users/u/x.bin", 60)` resolves with the same offline-signed shape (origin/path/`X-Amz-Signature`/`X-Amz-Expires=60`) under the same fake creds — the P8-T3 seam (ruling R3).
- [ ] **Step 2: Run to verify failure.** Run: `pnpm --filter @ovid/storage exec vitest run src/r2Adapter.test.ts src/storageEnv.test.ts` — Expected: FAIL.
- [ ] **Step 3: Install deps + implement.** Run: `cd /root/OvidAI/cloud && pnpm --filter @ovid/storage add @aws-sdk/client-s3 @aws-sdk/lib-storage @aws-sdk/s3-request-presigner` (resolves latest 3.x, caret-pinned). Implement `r2Adapter.ts`, `storageEnv.ts`, the `R2Reader`/`openReader` r2 branch per signatures.
- [ ] **Step 4: Run to verify pass.** Same command as Step 2 — Expected: PASS.
- [ ] **Step 5: Write the live contract test** (`r2.live.test.ts`):

```ts
const cfg = (() => { try { return loadR2Config(process.env); } catch { return null; } })();
describeStorageContract.skipIf(cfg === null)("r2-live", async () => {
  const adapter = createR2Storage(cfg!);
  const prefix = `users/_test-${uuidv7()}`;           // scoped probe keys; cleanup deletes each key
  return { adapter: scoped(adapter, prefix), cleanup: … };
});
```

`scoped` prefixes every key and `cleanup` deletes the probe objects; the suite is the SAME contract body the fs adapter passed (put stream/buffer, head sha256+metadata, get, delete idempotent, presignGet fetchable via global `fetch` → 200 + identical bytes, readerSpec→openReader→`read(off,len)` exact slice). File header comment: skipped in CI (no credentials); runs on the box after Task 14 provisioning.
- [ ] **Step 6: Verify + commit.** Run: `pnpm -r build && pnpm -r test` (live suite reports skipped without `OVID_R2_*`). Commit: `git add cloud/packages/storage cloud/pnpm-lock.yaml && git commit -m "feat(cloud): R2 StorageAdapter — S3 multipart streaming, presigned GET, range reader"`

### Task 3: `@ovid/shared` — workspace/artifact protocol (ADDITIVE)

**Files:**
- Create: `cloud/packages/shared/src/workspace.ts`
- Modify: `cloud/packages/shared/src/events.ts` (extend union + enum array only), `src/index.ts` (add `export * from "./workspace.js"`)
- Test: `cloud/packages/shared/src/workspace.test.ts`; extend `events.test.ts`

**Interfaces:**
- Consumes: nothing (zod already a dep).
- Produces (imported by Tasks 4, 6, 9, 11, 12, 13):

```ts
// events.ts — ADD to the SessionEventType union AND the sessionEventSchema enum array (both lists, same order):
//   "artifact_created" | "workspace_hibernated" | "workspace_hydrated"

// workspace.ts
export const UI_MANIFEST_MAX_BYTES = 5120;             // spec G7 "<5 KB" — the PRUNED tree (spike §9.3/§9.4)
export const DEFAULT_FILE_INLINE_MAX_BYTES = 1_048_576;
export const DEFAULT_PRESIGN_TTL_SECONDS = 3600;
export const DEFAULT_HYDRATE_WAIT_MS = 20_000;
export type FileNodeType = "dir" | "file" | "symlink";
export interface FileTreeNode { name: string; path: string; type: FileNodeType;
  sizeBytes?: number; mtime?: string;                   // mtime ISO-8601, second precision (spike §9.1)
  children?: FileTreeNode[];                            // dirs only, present when within depth budget
  files?: number; bytes?: number; dirs?: number;        // dir rollups (present on pruned dirs)
  omitted?: number }                                    // siblings dropped to stay ≤ budget
export interface UiManifest { version: 1; generatedAt: string; truncated: boolean;
  totals: { files: number; dirs: number; bytes: number }; roots: FileTreeNode[] }
export type WorkspaceState = "warm" | "hydrating" | "cold" | "hibernating";
export interface WorkspaceTreeResponse { sessionId: string; state: WorkspaceState; generation: number;
  source: "manifest" | "live"; tree: UiManifest }
export interface WorkspaceFileResponse { path: string; sizeBytes: number; contentType: string;
  encoding: "utf8" | "base64"; content: string }
export interface WorkspaceFileRedirect { path: string; sizeBytes: number; contentType: string;
  downloadUrl: string; expiresAt: string }
export interface PutWorkspaceFileBody { path: string; contentBase64?: string; contentUtf8?: string } // exactly one content field
export interface WorkspaceFileWriteResponse { path: string; sizeBytes: number; sha256: string }
export interface ArtifactDto { id: string; sessionId: string; name: string; sizeBytes: number;
  contentType: string; createdAt: string }
export interface ArtifactUrlResponse { url: string; expiresAt: string }
// zod schemas (z.ZodType<T> pattern, .strict() on request bodies): uiManifestSchema (+ recursive
// fileTreeNodeSchema via z.lazy), workspaceTreeResponseSchema, workspaceFileResponseSchema,
// workspaceFileRedirectSchema, putWorkspaceFileBodySchema (.refine exactly one of contentBase64/contentUtf8),
// workspaceFileWriteResponseSchema, artifactDtoSchema, artifactUrlResponseSchema,
// artifactCreatedPayloadSchema = z.object({ artifactId, name, sessionId, sizeBytes: z.number().int().nonnegative(),
//   contentType, url, expiresAt }).strict(),
// workspaceStatePayloadSchema = z.object({ generation: z.number().int().nonnegative(),
//   archiveBytes: z.number().int().nonnegative().optional(), ms: z.number().int().nonnegative().optional() }).strict()
```

- [ ] **Step 1: Write failing tests** (`workspace.test.ts`): every schema round-trips a valid literal (`.parse` deep-equal); `putWorkspaceFileBodySchema` rejects `{path:"a"}` (no content), `{path:"a",contentBase64:"x",contentUtf8:"y"}` (both), accepts each single-content form; `sizeBytes: 1.5` rejected by `artifactCreatedPayloadSchema` (`.int()`); existing spine schemas still pass (import from `./rest.js` — additive check). `events.test.ts` additions: `sessionEvent({…,type:"artifact_created",…})` parses; all SEVEN old types still parse (pin no regression); the enum array and TS union have identical membership (compile-time via a typed const list).
- [ ] **Step 2: Run to verify failure.** Run: `pnpm --filter @ovid/shared exec vitest run` — Expected: FAIL.
- [ ] **Step 3: Implement** `workspace.ts` + the additive `events.ts` edits + `index.ts` export.
- [ ] **Step 4: Run to verify pass.** Run: `pnpm --filter @ovid/shared exec vitest run && pnpm -r build` — Expected: PASS; downstream packages still compile (db repos import `SessionEventType`).
- [ ] **Step 5: Commit.** `git add cloud/packages/shared && git commit -m "feat(cloud): shared workspace protocol — artifact/hydration events, tree + file DTOs"`

### Task 4: Archive codec, write path — streaming pack (OVIDWS-G1), index, footer, uiTree/liveTree

**Files:**
- Create: `cloud/packages/storage/src/archive/format.ts`, `src/archive/memberStream.ts`, `src/archive/pack.ts`, `src/archive/readIndex.ts`, `src/archive/uiTree.ts`
- Modify: `cloud/packages/storage/src/index.ts`
- Test: `cloud/packages/storage/src/archive/{pack.test.ts,readIndex.test.ts,uiTree.test.ts}`

**Interfaces:**
- Consumes: Task 1 (`StorageAdapter`, `RangeReader`, `FdReader`, `StorageError` subclasses), Task 3 (`UiManifest`, `FileTreeNode`, `UI_MANIFEST_MAX_BYTES`).
- Produces (byte layout = spike §9.1 verbatim — the report is binding):

```ts
// format.ts — pinned constants (spike §9.1/§5.2)
export const ARCHIVE_MAGIC = "OVIDWS01"; export const ARCHIVE_END_MAGIC = "OVIDEND1";
export const FORMAT_NAME = "ovid-ws-grouped-v1"; export const ARCHIVE_VERSION = 1;
export const ZSTD_LEVEL = 9;                    // G7; spike §4.5: L19 = 6.7× pack time, keep 9
export const GROUP_MAX = 4 * 1024 * 1024;       // 4 MiB sweet spot; HARD ceiling 16 MiB (extractOne SLA dial)
export const SOLO_MAX = 256 * 1024;
export const HARD_GROUP_MAX_CEILING = 16 * 1024 * 1024;
export const FOOTER_LEN = 24; export const MEMBER_HEADER_LEN = 32;

// memberStream.ts — header32 (LE): nameLen u32 | targetLen u32 | mode u32 | mtimeSec u32 |
//   size u64 (BigInt64LE) | type u8 (0=file,1=dir,2=symlink) | flags u8 | rsv u8[6] (zero)
export interface MemberHeader { nameLen: number; targetLen: number; mode: number;
  mtimeSec: number; size: number; type: 0 | 1 | 2; flags: number }
export function encodeMemberHeader(h: MemberHeader): Buffer;                 // exactly 32 bytes
export function decodeMemberHeader(buf: Buffer, offset?: number): MemberHeader;

// pack.ts
export interface FrameRec { offset: number; length: number; decSize: number; members: number }
export interface FileRec { path: string; type: 0 | 1 | 2; size: number; mode: number; mtime: number;
  frameIndex: number; offsetInFrame: number; lengthInFrame: number; hashB64: string; target?: string }
export interface ArchiveIndex { archiveVersion: 1; format: "ovid-ws-grouped-v1"; zstdLevel: number;
  createdAt: string; frames: FrameRec[]; files: FileRec[] }
export function encodeIndexWire(index: ArchiveIndex): Buffer;
// compact-array JSON per spike §9.1: {"archiveVersion":1,"format":…,"zstdLevel":9,"checksumFlag":true,
//  "createdAt":…,"groupMax":…,"soloMax":…,"frames":[[offset,length,decSize,members],…],
//  "files":[[path,type,size,mode,mtime,frameIndex,offsetInFrame,lengthInFrame,hashB64,target?],…]}
export function decodeIndexWire(buf: Buffer): ArchiveIndex;   // → object form; throws ArchiveCorruptError on bad shape
export interface PackReport { bytes: number; sha256Hex: string; index: ArchiveIndex;
  frames: number; files: number; dirs: number; symlinks: number; ms: number }
export function pack(wsDir: string, sink: Writable, opts?: { level?: number; groupMax?: number;
  soloMax?: number; jobs?: number; now?: () => Date }): Promise<PackReport>;
export function packToStorage(wsDir: string, storage: StorageAdapter, key: string,
  opts?: Parameters<typeof pack>[2]): Promise<PackReport>;   // PassThrough bridge: pack ⇄ storage.put stream, no temp file (spike §7.3)

// readIndex.ts
export function readFooter(r: RangeReader): Promise<{ indexFrameLen: number; indexHash: Buffer }>;
// last 24 B: indexFrameLen u64 LE | indexHash = sha256(uncompressed index JSON)[0..8] | "OVIDEND1";
// bad tail magic → ArchiveTruncatedError("bad tail magic: archive truncated or corrupt")
export function readIndex(r: RangeReader): Promise<ArchiveIndex>;
// footer + pread index frame + zstdDecompressSync({params:{[ZSTD_d_windowLogMax]:27}}) +
// verify sha256(indexJson)[0..8] === footer.indexHash (mismatch → ArchiveCorruptError) + verify head magic + decodeIndexWire
export const manifest: typeof readIndex;   // spike §9.2 alias

// uiTree.ts
export function uiTree(index: ArchiveIndex, opts?: { depth?: number; maxBytes?: number; now?: () => Date }): UiManifest;
export function liveTree(wsDir: string, opts?: { depth?: number; maxBytes?: number; now?: () => Date }): Promise<UiManifest>;
// BOTH: depth default 2, maxBytes default UI_MANIFEST_MAX_BYTES. Deterministic sibling order:
// subdirs first (name asc, byte-wise), then files by sizeBytes desc, then name asc. When the
// serialized budget would be exceeded: drop remaining siblings into parent's `omitted` count and
// set truncated=true — NEVER emit > maxBytes (assert in tests). Deeper levels carry dir rollups
// {files, bytes, dirs}. mtime → ISO string, second precision.
```

Packer algorithm (pinned decisions; body from spike §3/§9.1): walk `wsDir` recursively collecting entries in **byte-wise path order** (Buffer.compare on relative POSIX paths; note `"dir" < "dir.x" < "dir/f"`); files ≤ `soloMax` append to the pending group accumulator; payload > `groupMax` flushes a frame; files > `soloMax` are written **immediately as their own single-member frame WITHOUT touching the pending accumulator** (spike bug #2 — flushing shatters groups and loses ~1.8 MB); dirs & symlinks always ride in groups; hardlinks (nlink>1) archived as independent full copies; files > 2 GiB → `StorageError` code `"unsupported_size"` (workspace quotas are ≤2 GB); per frame: `windowLog = clamp(ceil(log2(decSize)), 17, 27)`, `ZSTD_c_compressionLevel: level ?? 9`, `ZSTD_c_checksumFlag: 1`, FCS flag on; `jobs > 1` → async `zlib.zstdCompress` on the libuv pool (byte-identical output, spike §4.4 — document `UV_THREADPOOL_SIZE ≥ jobs`); running `crypto.Hash("sha256")` over every chunk pushed; backpressure: `await drain` when `sink.write` returns false; layout = `ARCHIVE_MAGIC ‖ frames… ‖ zstdFrame(indexJson) ‖ footer`. `mtime = Math.floor(stat.mtimeMs / 1000)`; symlink = `lstat` + `readlink` (never follow); dir mode from stat.

- [ ] **Step 1: Write failing pack tests** (`pack.test.ts`) over a seeded fixture dir built in `beforeAll` (files of sizes [0, 1, 1024, 262_143, 262_145, 5_000_000 B], nested dirs, one symlink, one `chmod 0o755` file, fixed mtimes via `utimes`): pack to a tmp file via `createWriteStream`; assert (a) first 8 bytes `OVIDWS01`, last 8 `OVIDEND1`; (b) `readIndex(FdReader)` round-trips: `files.length === 7` (+dirs), every `hashB64` equals independent `sha256(content).toString("base64url")`; (c) **grouping**: the 5 MB file occupies a solo frame (`frames[i].members === 1`), the small files share ≥1 group frame whose `decSize ≤ GROUP_MAX`, and the solo frame did NOT flush the small-file group (frame count equals the expected minimum — pin exact count for the fixture); (d) `sha256Hex` equals an independent hash of the archive file; (e) **determinism**: re-pack with the same `now()` → byte-identical file; (f) `packToStorage` with `createFsStorage` → object head bytes === report.bytes; (g) >2 GiB → fake via `opts` injection is NOT possible — instead unit-test the guard by packing a dir containing a sparse 2.1 GiB file (`fs.truncate`) → rejects code `unsupported_size`.
- [ ] **Step 2: Run to verify failure.** Run: `pnpm --filter @ovid/storage exec vitest run src/archive/pack.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement** `format.ts`, `memberStream.ts`, `pack.ts`, `readIndex.ts` per the pinned layout; run to verify pass (same command).
- [ ] **Step 4: Write failing readIndex corruption guards** (`readIndex.test.ts`): truncate the archive by 1 byte → `readIndex` rejects `ArchiveTruncatedError` with message containing `bad tail magic`; flip one byte inside footer `indexHash` → `ArchiveCorruptError`; flip one byte in the compressed index frame → `ArchiveCorruptError` (zstd xxh64 or indexHash); flip one byte in an UNRELATED file record's payload region → open SUCCEEDS (spike §7.2 last row — detection is per-use); head magic `XVIDWS01` → `ArchiveCorruptError`.
- [ ] **Step 5: Run, implement any gaps, verify pass.** Same command + `src/archive/pack.test.ts`.
- [ ] **Step 6: Write failing uiTree tests** (`uiTree.test.ts`): over the pack fixture index — depth-2 shape (roots = top-level entries; nested dirs at depth 2 carry `files/bytes/dirs` rollups, no `children`); `Buffer.byteLength(JSON.stringify(uiTree(index))) ≤ UI_MANIFEST_MAX_BYTES`; a synthetic 5 000-file index (generated FileRecs) → still ≤ 5120 bytes with `truncated === true` and `omitted` counts summing correctly; `totals` exact (files/dirs/bytes as integers); determinism (same input → identical JSON); `liveTree` over the fixture dir deep-equals `uiTree` of its index (modulo `generatedAt`).
- [ ] **Step 7: Implement `uiTree.ts`, verify pass, commit.** Run: `pnpm --filter @ovid/storage exec vitest run src/archive && pnpm -r build && pnpm -r test`. Commit: `git add cloud/packages/storage && git commit -m "feat(cloud): OVIDWS-G1 archive packer — grouped zstd frames, index, footer, uiTree"`

### Task 5: Archive codec, read path — extractOne, parallel extractAll, structural recovery, corruption matrix

**Files:**
- Create: `cloud/packages/storage/src/archive/extract.ts`, `src/archive/extractWorker.ts` (worker_threads entry), `src/archive/recover.ts`, `src/archive/zstdFrames.ts`
- Modify: `cloud/packages/storage/src/errors.ts` (add error classes), `src/index.ts`
- Test: `cloud/packages/storage/src/archive/{extract.test.ts,recover.test.ts,zstdFrames.test.ts}`

**Interfaces:**
- Consumes: Task 4 (everything), Task 1 (`ReaderSpec`, `openReader`).
- Produces:

```ts
// errors.ts additions
export class ArchiveCorruptError extends StorageError {}     // code "archive_corrupt"
export class ArchiveTruncatedError extends StorageError {}   // code "archive_truncated"
export class HashMismatchError extends StorageError {}       // code "hash_mismatch"
export class FileNotInArchiveError extends StorageError {}   // code "file_not_in_archive"
export class FileTooLargeError extends StorageError {}       // code "file_too_large" (carries sizeBytes)

// extract.ts
export interface FileContent { rec: FileRec; bytes: Buffer }
export function extractFile(r: RangeReader, index: ArchiveIndex, path: string): Promise<FileContent>;
// Map lookup on index.files by path (exact, normalized) → FileNotInArchiveError; pread(frameOffset,
// frameLength) → ONE zstdDecompressSync (frame xxh64 guards corruption → ArchiveCorruptError wrapping
// the zstd "Data corruption detected" message) → slice [offsetInFrame, +lengthInFrame) →
// sha256 === rec.hashB64 else HashMismatchError(`HASH MISMATCH for '<path>' …`)
export function extractOne(r: RangeReader, index: ArchiveIndex, path: string, dest: string): Promise<void>;
// extractFile + ATOMIC write: mkdir -p dirname, write `${dest}.part-${pid}`, chmod rec.mode,
// rename over dest, utimes(dest, mtimeSec); on ANY error remove the temp file — dest never exists
// partially (spike §9.1 reader invariants)
export interface ExtractReport { files: number; bytes: number; ms: number }
export function extractAll(spec: ReaderSpec, index: ArchiveIndex, destDir: string,
  opts?: { workers?: number; restoreMeta?: boolean }): Promise<ExtractReport>;
// workers default Math.min(4, Math.max(1, os.availableParallelism() - 2)); restoreMeta default true.
// ALWAYS two-pass (spike bug #1): pass 1 creates ALL dirs path-sorted (mkdir -p; chmod/utimes deferred
// to the end so dir modes don't block writes into them); pass 2 = disjoint frame ranges, one
// worker_thread per range (workers=1 → in-process), each thread calls openReader(spec) for its OWN
// reader, decompresses its frames, writes members (files via temp+rename when restoreMeta, symlink()
// for type 2 — unlink target first), posts {files, bytes} back; threads are order-independent by
// construction. Any thread error → terminate all, reject with the typed error, leave partial tree
// (caller — Task 9 — wipes and retries).
export function extractAllInProcess(spec: ReaderSpec, index: ArchiveIndex, destDir: string,
  opts?: { restoreMeta?: boolean }): Promise<ExtractReport>;  // single-reader sequential path (workers=1)

// zstdFrames.ts — RFC 8878 frame-header parsing (spike §8 bug #3: the FCS table)
export interface ZstdFrameHeader { magic: number; totalHeaderLen: number; contentSize: number | null;
  singleSegment: boolean; checksumFlag: boolean; windowSize: number | null }
export function parseZstdFrameHeader(buf: Buffer, offset?: number): ZstdFrameHeader;
// FCS field size by code: 0 → (singleSegment ? 1 : 0) bytes; 1 → 2 bytes (value = stored + 256);
// 2 → 4 bytes; 3 → 8 bytes. Skippable frames (magic & 0xFFFFFFF0 === 0x184D2A50) → contentSize null,
// caller skips by frame-description length.

// recover.ts — index-free structural recovery (spike §7.1: 91/91 frames, exact walk end)
export function scanFrames(r: RangeReader): Promise<Array<{ offset: number; length: number;
  contentSize: number | null; checksumFlag: boolean }>>;
// sequential walk from byte 8: parseZstdFrameHeader → per-block 3-byte headers (Last_Block bit,
// Block_Type, Block_Size) → +3-byte xxh64 when checksumFlag; skippable frames handled; truncated
// frame (blocks overrun EOF) → ArchiveTruncatedError(`frame at <off> truncated`)
export function recoverIndex(r: RangeReader): Promise<ArchiveIndex>;
// scanFrames → decompress every frame → parse member streams (decodeMemberHeader) → rebuild
// frames[]/files[] with re-computed hashB64; result has createdAt "" (documented), archiveVersion 1,
// format FORMAT_NAME — deep-equal to the original index modulo createdAt (test-pinned)
```

- [ ] **Step 1: Write failing zstdFrames tests** (`zstdFrames.test.ts`) — the FCS-table pin the spike demands: shell out to `zstd` CLI (1.5.5, fixtures only) to compress buffers of sizes 100 B (`--ultra -22 --single-segment`? no — plain `zstd -9` small input sets single-segment), 1 KB, 65_791 B, 65_792 B, 100 KB, 10 MB (`zstd -9 -f`); for each: `parseZstdFrameHeader` returns `contentSize === exact input length` and `checksumFlag` matches `--check`/`--no-check` variants; also parse a Node-`zstdCompressSync` 4 MiB frame (our packer's shape) → contentSize exact. These assertions FAIL against a wrong FCS table by construction.
- [ ] **Step 2: Run to verify failure, implement `zstdFrames.ts`, verify pass.** Run: `pnpm --filter @ovid/storage exec vitest run src/archive/zstdFrames.test.ts`.
- [ ] **Step 3: Write failing extract tests** (`extract.test.ts`) over a richer fixture (reuse Task 4's builder + a 300-file nested tree with mixed modes/mtimes/symlinks): `extractFile` exact bytes + `rec` for a small grouped file AND a solo file; unknown path → `FileNotInArchiveError`; `extractOne` restores mode (`stat.mode & 0o7777`) and mtimeSec and parent dirs are created; **corruption matrix (spike §7.2)** — copies of the archive with: (a) 1 byte flipped mid-frame → `extractFile` rejects with message containing `Data corruption detected`, dest NOT created, no `.part-` leftovers; (b) 1 byte flipped in the target's `hashB64` inside the index → `HashMismatchError` with message containing `HASH MISMATCH`; (c) truncation mid-frame → extract rejects, never writes garbage; (d) **extractAll** with workers 1 and 4 over the full fixture → recursive comparison (content sha256 per file, dir set, symlink targets via `lstat/readlink`, modes, mtimeSec) is EXACT — plus one `diff -rq --no-dereference fixture extracted` child_process assertion exits 0; (e) a corrupt byte + `extractAll` → rejects and the partial tree is left for the caller (assert rejection type only).
- [ ] **Step 4: Run to verify failure; implement `extract.ts` + `extractWorker.ts`; verify pass.** Run: `pnpm --filter @ovid/storage exec vitest run src/archive/extract.test.ts`.
- [ ] **Step 5: Write failing recovery tests** (`recover.test.ts`): pack fixture → flip bytes inside the index frame (readIndex now throws) → `recoverIndex(FdReader)` succeeds and its `files`/`frames` deep-equal the original index's (excluding `createdAt`); `extractOne` using the RECOVERED index returns exact bytes; `scanFrames` frame count === `index.frames.length` and the walk ends exactly at the index-frame offset (footer math).
- [ ] **Step 6: Implement `recover.ts`, verify pass, commit.** Run: `pnpm --filter @ovid/storage exec vitest run src/archive && pnpm -r build && pnpm -r test`. Commit: `git add cloud/packages/storage && git commit -m "feat(cloud): archive reader — extractOne/extractAll parallel, structural recovery, corruption matrix"`

### Task 6: `@ovid/db` — `file_manifests` + `workspace_objects` tables and repos

**Files:**
- Modify: `cloud/packages/db/src/schema.ts` (append two tables + row types), `cloud/packages/db/src/repos.ts` (append two repo namespaces), `cloud/packages/db/src/index.ts` (export new row types)
- Create: `cloud/packages/db/drizzle/0001_*.sql` (generated)
- Test: extend `cloud/packages/db/src/repos.test.ts` (or add `reposStorage.test.ts` — follow the existing `TEST_DATABASE_URL` skip-gating + `migrate()` beforeAll convention)

**Interfaces:**
- Consumes: Task 3 (`UiManifest`, `WorkspaceState` types for `$type<>` annotations); existing `sessions`/`users` FK targets, `newId()`, `timestamptz` helper.
- Produces:

```ts
// schema.ts additions
export const fileManifests = pgTable("file_manifests", {
  sessionId: char("session_id", { length: 36 }).primaryKey().references(() => sessions.id),
  userId: text("user_id").notNull().references(() => users.uid),
  generation: integer("generation").notNull().default(0),
  state: text("state").notNull(),                        // WorkspaceState string
  uiTree: jsonb("ui_tree").notNull().$type<UiManifest>(),
  archiveKey: text("archive_key"),                       // null until first hibernate
  archiveBytes: bigint("archive_bytes", { mode: "number" }),
  archiveSha256: text("archive_sha256"),                 // 64-char lowercase hex
  entryCount: integer("entry_count"),
  workspaceBytes: bigint("workspace_bytes", { mode: "number" }),  // last du of the warm dir (LRU accounting)
  updatedAt: timestamptz("updated_at").notNull().defaultNow(),
}, (t) => [index("file_manifests_user_id_idx").on(t.userId), index("file_manifests_state_idx").on(t.state)]);

export const workspaceObjects = pgTable("workspace_objects", {
  id: char("id", { length: 36 }).primaryKey(),           // UUIDv7
  userId: text("user_id").notNull().references(() => users.uid),
  sessionId: char("session_id", { length: 36 }).references(() => sessions.id),
  kind: text("kind").notNull(),                          // "workspace_archive" | "workspace_manifest" | "artifact"
  r2Key: text("r2_key").notNull().unique(),
  bytes: bigint("bytes", { mode: "number" }).notNull(),
  sha256: text("sha256").notNull(),                      // lowercase hex — exact string comparisons only
  contentType: text("content_type"),
  generation: integer("generation"),                     // archives only
  status: text("status").notNull().default("active"),    // "active" | "deleted"
  meta: jsonb("meta").$type<Record<string, unknown>>(),
  createdAt: timestamptz("created_at").notNull().defaultNow(),
}, (t) => [index("workspace_objects_session_id_idx").on(t.sessionId),
           index("workspace_objects_user_id_kind_idx").on(t.userId, t.kind)]);
export type FileManifestRow = typeof fileManifests.$inferSelect;
export type WorkspaceObjectRow = typeof workspaceObjects.$inferSelect;

// repos.ts additions (namespaces `fileManifests` / `workspaceObjects` — same table-name/repo-name
// pattern as `sessions`; index.ts already exports `* as schema` for the tables)
export const fileManifests: {
  get(db: Db, sessionId: string): Promise<FileManifestRow | null>;
  upsertWarm(db: Db, i: { sessionId: string; userId: string; workspaceBytes: number | null }): Promise<FileManifestRow>;
    // INSERT (state 'warm', generation default 0, uiTree EMPTY tree literal) ON CONFLICT (sessionId)
    // DO UPDATE state='warm', workspace_bytes, updated_at — NEVER touches generation/archive fields
  beginHibernation(db: Db, sessionId: string): Promise<boolean>;  // UPDATE … SET state='hibernating' WHERE session_id=$1 AND state='warm' RETURNING id — race-safe claim
  markCold(db: Db, i: { sessionId: string; generation: number; archiveKey: string; archiveBytes: number;
    archiveSha256: string; entryCount: number; uiTree: UiManifest }): Promise<void>;  // one UPDATE: state 'cold', workspace_bytes NULL
  beginHydration(db: Db, sessionId: string): Promise<boolean>;    // WHERE state='cold' → 'hydrating'
  markWarm(db: Db, i: { sessionId: string; workspaceBytes: number | null }): Promise<void>;  // state 'warm'
  listWarmForLru(db: Db): Promise<Array<{ sessionId: string; userId: string; generation: number;
    workspaceBytes: number | null; updatedAt: Date }>>;           // state='warm' ORDER BY updated_at ASC LIMIT 1000
  remove(db: Db, sessionId: string): Promise<void>;
};
export const workspaceObjects: {
  putArchive(db: Db, i: { userId: string; sessionId: string; generation: number; archiveKey: string;
    manifestKey: string; bytes: number; sha256: string; entryCount: number }): Promise<void>;
    // upsert BOTH the archive row (kind workspace_archive, meta {entryCount, zstdLevel: 9}) and the
    // sidecar row (kind workspace_manifest, sha256 of sidecar bytes, bytes) ON CONFLICT (r2_key) DO UPDATE
    // (keys are stable per session; generation is bumped in place)
  registerArtifact(db: Db, i: { id: string; userId: string; sessionId: string; r2Key: string;
    bytes: number; sha256: string; contentType: string; meta: { name: string } }): Promise<WorkspaceObjectRow>;
  listArtifacts(db: Db, sessionId: string, opts: { limit: number; beforeId?: string | null }):
    Promise<{ rows: WorkspaceObjectRow[]; nextCursor: string | null }>;  // kind='artifact' AND status='active', newest-first keyset by id (messages.page convention)
  getArtifact(db: Db, artifactId: string, userId: string): Promise<WorkspaceObjectRow | null>;  // ownership-scoped
};
```

All `bytes`-typed inputs asserted with `Number.isSafeInteger(x) && x >= 0` at the repo boundary (throw on violation — Global Constraints exact-arithmetic rule).

- [ ] **Step 1: Write failing repo tests** (gated on `TEST_DATABASE_URL`, `migrate()` in beforeAll, fresh session/user rows per test): upsertWarm creates row (state warm, generation 0) then re-upsert with new workspaceBytes preserves generation/archive fields; beginHibernation true from warm / false from cold / false twice concurrently (second caller false — race pin); markCold → get shows state cold + exact archive fields; beginHydration true from cold only; markWarm resets state; listWarmForLru returns only warm rows ordered by updatedAt; putArchive twice (generation 1, 2) → single archive row with generation 2 (upsert on r2_key) + manifest row; registerArtifact + listArtifacts keyset paging (3 artifacts, limit 2 → nextCursor → last item) + getArtifact wrong user → null; safe-integer guard: `bytes: 1.5` throws.
- [ ] **Step 2: Run to verify failure.** Run: `bash cloud/scripts/dev-services.sh && cd cloud && TEST_DATABASE_URL=postgres://postgres:ovid@127.0.0.1:5433/postgres pnpm --filter @ovid/db exec vitest run` — Expected: FAIL (tables missing).
- [ ] **Step 3: Add schema + repos; generate migration.** Run: `cd cloud/packages/db && pnpm exec drizzle-kit generate` → creates `drizzle/0001_*.sql` + journal entry; eyeball the SQL (two CREATE TABLEs, FKs, indexes — no destructive statements).
- [ ] **Step 4: Run tests to verify pass.** Same command as Step 2 — Expected: PASS (migrate applies 0001).
- [ ] **Step 5: Commit.** `git add cloud/packages/db && git commit -m "feat(cloud): file_manifests + workspace_objects tables and repos"`

### Task 7: `@ovid/queue` hibernate/hydrate queues + session activity tracker

**Files:**
- Modify: `cloud/packages/queue/src/queues.ts` (additive), `cloud/packages/queue/src/index.ts` if needed (check: index re-exports queues.js)
- Create: `cloud/packages/storage/src/activity.ts`
- Test: extend `cloud/packages/queue/src/queues.test.ts`; create `cloud/packages/storage/src/activity.test.ts`
- Test (queue): extend existing `TEST_REDIS_URL`-gated suite.

**Interfaces:**
- Consumes: existing queue conventions (`withBlockingSafeRetries`, `AGENT_RUN_JOB_DEFAULTS` pattern).
- Produces:

```ts
// @ovid/queue additions
export const HIBERNATE = "hibernate"; export const HYDRATE = "hydrate";
export const HIBERNATE_JOB_NAME = "hibernate-workspace"; export const HYDRATE_JOB_NAME = "hydrate-workspace";
export type HibernateReason = "idle" | "pressure" | "manual";
export type HydrateReason = "run" | "open" | "write" | "manual";
export interface HibernateJob { sessionId: string; userId: string; generation: number; reason: HibernateReason }
export interface HydrateJob { sessionId: string; userId: string; generation: number; reason: HydrateReason }
export const hibernateJobSchema: z.ZodType<HibernateJob>;   // generation: z.number().int().min(1)
export const hydrateJobSchema: z.ZodType<HydrateJob>;       // generation: z.number().int().min(0)
export const STORAGE_JOB_DEFAULTS = { attempts: 3, backoff: { type: "exponential", delay: 5_000 } } as const;
export const STORAGE_JOB_CONCURRENCY = 2;                   // pack/extract are CPU+IO heavy; 8-core box
export function storageJobId(sessionId: string, generation: number): string;  // `${sessionId}:${generation}` (spike §9.3 idempotent retries)
// QueueServices EXTENDED (additive): { agentRuns; hibernate: Queue<HibernateJob>; hydrate: Queue<HydrateJob> }
// createQueues builds all three with defaultJobOptions { ...STORAGE_JOB_DEFAULTS }
export function createHibernateWorker(connection: ConnectionOptions, processor: Processor<HibernateJob>,
  opts?: { concurrency?: number }): Worker<HibernateJob>;
export function createHydrateWorker(connection: ConnectionOptions, processor: Processor<HydrateJob>,
  opts?: { concurrency?: number }): Worker<HydrateJob>;

// @ovid/storage activity.ts
export const ACTIVITY_KEY_PREFIX = "ovid:activity:";        // key: `ovid:activity:${sessionId}` → value: epoch-ms string
export const ACTIVITY_TTL_SECONDS = 604_800;                // 7 d, refreshed on bump
export interface ActivityTracker {
  bump(sessionId: string): Promise<void>;                   // SET key <Date.now()> EX ttl
  read(sessionId: string): Promise<number | null>;          // epoch ms or null (missing/evicted)
  readMany(sessionIds: string[]): Promise<Map<string, number>>;  // MGET batches of 500
}
export function createActivityTracker(redis: { set(k: string, v: string, mode: "EX", ttl: number): unknown;
  get(k: string): unknown; mget(...ks: string[]): unknown }, opts?: { keyPrefix?: string; ttlSeconds?: number;
  clock?: () => Date }): ActivityTracker;   // structural ioredis-shaped interface — no runtime dep
```

- [ ] **Step 1: Write failing queue tests** (extend `queues.test.ts`, `TEST_REDIS_URL`-gated): `createQueues({url})` exposes `hibernate`/`hydrate` Queue instances with names `"hibernate"`/`"hydrate"`; `hibernate.add(HIBERNATE_JOB_NAME, job, { jobId: storageJobId(sid, g) })` twice → second add returns the SAME job id and `getJobCount()` unchanged (dedupe pin); job schema round-trips and rejects `generation: 1.5`; `agentRuns` behavior unchanged (existing tests still pass — additive check); `createHibernateWorker` consumes an added job (processor receives exact payload).
- [ ] **Step 2: Write failing activity tests** (`activity.test.ts`, real ioredis against `TEST_REDIS_URL`, unique key prefix per run): bump→read round-trip (clock injected → exact ms); read missing → null; `PTTL` > 0 after bump (TTL set); readMany over 3 keys (one missing) → Map without the missing key.
- [ ] **Step 3: Run both to verify failure.** Run: `bash cloud/scripts/dev-services.sh && cd cloud && TEST_REDIS_URL=redis://127.0.0.1:6390 pnpm --filter @ovid/queue test && TEST_REDIS_URL=redis://127.0.0.1:6390 pnpm --filter @ovid/storage exec vitest run src/activity.test.ts` — Expected: FAIL.
- [ ] **Step 4: Implement; verify pass; commit.** Run: same as Step 3 → PASS, then `pnpm -r build && pnpm -r test`. Commit: `git add cloud/packages/queue cloud/packages/storage && git commit -m "feat(cloud): hibernate/hydrate queues + session activity tracker"`

### Task 8: Hibernation engine — pack, verified upload, crash-safe evict

**Files:**
- Create: `cloud/packages/storage/src/hibernate.ts`
- Modify: `cloud/packages/storage/src/index.ts`
- Test: `cloud/packages/storage/src/hibernate.test.ts`

**Interfaces:**
- Consumes: Tasks 1–7 (`packToStorage`, `pack`, `uiTree`, `readIndex`, `r2Keys`, `workspaceDir`, `StorageAdapter`, `fileManifests`/`workspaceObjects` repos, `HibernateJob`, `ActivityTracker`, `EventLog`, `Db`).
- Produces:

```ts
export const HIBERNATE_IDLE_MS = 180_000;                 // G7: 3-min idle
export interface WarmWorkspaceEntry { userId: string; sessionId: string; bytes: number;
  lastAccessMs: number | null }
export interface SandboxEviction {                        // seam CONSUMED from @ovid/sandbox (ruling R1, contract 1)
  listWarmWorkspaces(): Promise<WarmWorkspaceEntry[]>;    // per-session warm entries w/ sizes/lastAccess
  evictWorkspace(userId: string, sessionId: string): Promise<void>; }
  // evictWorkspace = pack-safe destroy via SandboxManager: kill jail/PTY/background jobs for the
  // session, LEAVE files. P7 ships the pre-P2 stand-in:
export function createNoopSandboxEviction(log?: (msg: string) => void): SandboxEviction;
  // listWarmWorkspaces() → [] (sweeper registers nothing until P2 lands — logged once) +
  // evictWorkspace resolves + logs (TODO(P2) markers)
export interface HibernateDeps { db: Db; events: EventLog; storage: StorageAdapter;
  workspacesRoot: string; sandbox: SandboxEviction; activity: ActivityTracker; clock?: () => Date }
export interface HibernateResult { status: "hibernated" | "skipped";
  reason?: "not_warm" | "stale_generation" | "active_run" | "recent_activity" | "already_cold";
  generation?: number; archiveBytes?: number; ms?: number }
export function hibernateWorkspace(deps: HibernateDeps, job: HibernateJob,
  opts?: { idleMs?: number }): Promise<HibernateResult>;
export function reconcileStuckHibernations(deps: HibernateDeps,
  opts: { stuckAfterMs: number }): Promise<{ resetToWarm: number; closedToCold: number }>;
// crash recovery (worker boot + sweeper): rows state='hibernating' with updatedAt older than
// stuckAfterMs: dir EXISTS → markWarm (re-pack later); dir GONE → readIndex(readerSpec(archiveKey))
// verifies the archive → markCold with a rebuilt uiTree + putArchive row (rare, ~1 s); no archive →
// remove row + append system_note {code:"workspace_lost"}.
```

Algorithm (pinned order — spike §9.3, crash-safe): **(1) verify:** `runs.activeForSession(db, sessionId) !== null` → `skipped active_run` (AG1); `activity.read` fresher than `idleMs` → `skipped recent_activity`; dir missing → row cold ? `skipped already_cold` : `skipped not_warm`. **(2) claim:** row must exist with `generation + 1 === job.generation` (else `skipped stale_generation` — dedupes re-deliveries) and `beginHibernation` must return true (else `skipped not_warm`). **(3)** `sandbox.evictWorkspace(userId, sessionId)` (the P2 seam — ruling R1). **(4)** `pack(dir, …)` streaming via `packToStorage` to `r2Keys.workspaceArchive` — PackReport. **(5)** sidecar: `storage.put(r2Keys.workspaceManifest, encodeIndexWire-bytes-as-JSON, {contentType:"application/json"})` — the sidecar holds the SAME compact-array index JSON bytes the footer hashes (`encodeIndexWire(report.index)`). **(6) verify before delete:** `head(archiveKey).bytes === report.bytes` AND full re-download stream sha256 === `report.sha256Hex` AND `readIndex(await storage.readerSpec(archiveKey))` succeeds. R2 has zero egress fees — full re-hash is affordable and is the ONLY guarantee strong enough to delete local data (per-file hashes protect hydration, but a corrupt upload would otherwise destroy the only copy). Any failure → `markWarm` (restore prior workspaceBytes) + throw `StorageError` (BullMQ attempts:3 retries). **(7)** PG: `fileManifests.markCold({generation: job.generation, archiveKey, archiveBytes, archiveSha256, entryCount, uiTree: uiTree(report.index)})` + `workspaceObjects.putArchive(…)`. **(8)** ONLY NOW `fs.rm(dir, {recursive: true, force: true})`. **(9)** `events.append(sessionId, "workspace_hibernated", {generation, archiveBytes, ms})` + `eventMirror.put`. Local data is deleted strictly after the verified upload AND the durable cold marker (crash between 7 and 8 → `reconcileStuckHibernations` closes it).

- [ ] **Step 1: Write failing tests** (`hibernate.test.ts` — `TEST_DATABASE_URL`+`TEST_REDIS_URL` gated; fs adapter over mkdtemp; workspacesRoot mkdtemp; stub `SandboxEviction` recording `evictWorkspace` calls; real `createRedisEventLog` + `createActivityTracker`): **happy path** — seeded dir (nested files, symlink, exec bit, placed at `workspaceDir(root, uid, sid)`) + warm row (upsertWarm) + activity aged 200 s (clock injected) → `hibernateWorkspace` → result `hibernated`; `evictWorkspace` called exactly once with `(userId, sessionId)` BEFORE pack (ordering pin); archive + sidecar exist in fs storage under the EXACT spec keys; `workspace_objects` archive row bytes/sha256 match an independent hash of the stored archive file; `file_manifests` state cold, generation 1, `uiTree` parses via `uiManifestSchema`; dir is GONE; `workspace_hibernated` event readable via `events.readSince` with exact payload. **verify-blocks**: active run row (insert runs row status running) → `skipped active_run` and dir intact; activity 10 s old → `skipped recent_activity`; stale `job.generation` (row.generation+2) → `skipped stale_generation`; **verify failure** — wrap the adapter so the re-download returns one flipped byte → rejects `StorageError`, row back to `warm`, dir INTACT, no cold marker; **idempotent re-delivery** — call twice with the same job → second `skipped already_cold`; **reconcile** — simulate crash: state hibernating + updatedAt 20 min old (clock) + dir present → `resetToWarm: 1`; second fixture: dir removed but archive+sidecar in storage and row hibernating-old → `closedToCold: 1` with rebuilt uiTree.
- [ ] **Step 2: Run to verify failure.** Run: `bash cloud/scripts/dev-services.sh && cd cloud && TEST_DATABASE_URL=… TEST_REDIS_URL=… pnpm --filter @ovid/storage exec vitest run src/hibernate.test.ts` — Expected: FAIL.
- [ ] **Step 3: Implement `hibernate.ts`** per the pinned algorithm; export from index.
- [ ] **Step 4: Run to verify pass** (same command) — Expected: PASS.
- [ ] **Step 5: Commit.** `pnpm -r build && pnpm -r test` then `git add cloud/packages/storage && git commit -m "feat(cloud): hibernation engine — pack, verified upload, crash-safe evict"`

### Task 9: Hydration engine (full + lazy single-file) and artifacts pipeline

**Files:**
- Create: `cloud/packages/storage/src/hydrate.ts`, `src/artifacts.ts`
- Modify: `cloud/packages/storage/src/index.ts`
- Test: `cloud/packages/storage/src/{hydrate.test.ts,artifacts.test.ts}`

**Interfaces:**
- Consumes: Tasks 1–8 (`extractAll`, `extractFile`, `readIndex`, `decodeIndexWire`, `openReader`, repos, `HydrateJob`, events).
- Produces:

```ts
// hydrate.ts
export interface HydrateDeps { db: Db; events: EventLog; storage: StorageAdapter;
  workspacesRoot: string; activity: ActivityTracker; clock?: () => Date }
export interface HydrateResult { status: "hydrated" | "skipped";
  reason?: "already_warm" | "stale_generation" | "no_archive"; files?: number; ms?: number }
export function hydrateWorkspace(deps: HydrateDeps, job: HydrateJob,
  opts?: { workers?: number }): Promise<HydrateResult>;
export function awaitWarm(db: Db, hydrateQueue: { add(name: string, job: HydrateJob,
    opts: { jobId: string }): unknown; }, ref: { sessionId: string; userId: string },
  opts: { reason: HydrateReason; timeoutMs: number; pollMs?: number; clock?: () => Date }): Promise<{ generation: number }>;
// no row OR state warm → resolve {generation: row?.generation ?? 0} (disk is the truth downstream);
// cold → hydrateQueue.add(HYDRATE_JOB_NAME, {…ref, generation: row.generation, reason},
//   {jobId: storageJobId(sid, g)}) then poll fileManifests.get every pollMs (default 250) until
//   state warm → resolve; hydrating → poll only; timeout → throw WorkspaceStateError("hydrate_timeout").
// Concurrent callers dedupe through the jobId (BullMQ returns the existing job).
export interface ReadFileResult { bytes: Buffer; sizeBytes: number; sha256Hex: string;
  contentType: string; source: "warm" | "archive" }
export function readWorkspaceFile(deps: HydrateDeps, ref: { userId: string; sessionId: string; path: string },
  opts?: { maxBytes?: number }): Promise<ReadFileResult>;
export function writeWorkspaceFile(deps: HydrateDeps, ref: { userId: string; sessionId: string; path: string },
  content: Buffer): Promise<{ path: string; sizeBytes: number; sha256Hex: string }>;
export function contentTypeFor(name: string): string;   // small ext map (.ts .js .mjs .json .md .txt .html .css .csv .log → text-ish; .png .jpg .webp .gif .pdf .zip .tar .gz .so → binary); default "application/octet-stream"
export function shouldPresign(contentType: string, sizeBytes: number, inlineMaxBytes: number): boolean;
// true iff sizeBytes > inlineMaxBytes OR contentType is not text/* and not in
// {application/json, application/javascript, application/xml, image/svg+xml}
export function clearIndexCache(): void;                // test seam
export const INDEX_CACHE_MAX_ENTRIES = 8;               // per process, keyed `${sessionId}:${generation}`, FIFO-evict
```

Pinned behavior: **hydrateWorkspace** — row missing/no archiveKey → `skipped no_archive`; state !== cold → `skipped already_warm` (warm) / `skipped stale_generation` (job.generation ≠ row.generation) / `skipped already_warm` (hydrating — another job owns it); `beginHydration` claim false → skipped; `dir` exists (crash remnant) → `fs.rm` recursive FIRST (clean retry); `mkdir -p` dir; `readerSpec(archiveKey)` → `readIndex` → verify `index` shape; `extractAll(spec, index, dir, {workers: default})`; on ANY failure → rm partial dir, `markCold`-restore (state back to cold via a `markColdRetry`-style UPDATE state='cold'), throw (attempts:3). Whole-archive re-hash is deliberately NOT repeated here — hibernate verified it at upload, and per-frame xxh64 + per-file sha256 guard every read (spike §9.1 double layer). Success → `du(dir)` → `markWarm({workspaceBytes})` → `activity.bump` → event `workspace_hydrated {generation, ms}` + mirror. **awaitWarm** is shared by the worker (`ensureWarm`, Task 11) and the gateway (PUT/hydrate flows, Task 12). **readWorkspaceFile** — `assertSafeRelPath(path)`; dir = `workspaceDir(root, userId, sessionId)`; if dir exists (warm truth): full = join(dir, path); `fs.realpath(full)` MUST start with `fs.realpath(dir) + path.sep` (symlink-escape guard) else `NotFoundError`; stat: dir/symlink → `NotFoundError` (v1 serves regular files only); size > maxBytes → `FileTooLargeError` (carries sizeBytes); read + sha256 → source "warm". Else if row?.archiveKey: index = cache ?? sidecar `getBuffer(manifestKey)`→`decodeIndexWire` ?? `readIndex(readerSpec(archiveKey))` (indexHash-verified fallback); rec size check → `extractFile` → source "archive" (dir stays ABSENT — the Studio lazy path). Else `NotFoundError`. **writeWorkspaceFile** — requires the dir to exist (warm); `assertSafeRelPath`; mkdir -p parent; temp+rename inside the workspace; chmod 0o644; sha256 of content; `activity.bump`; refresh `fileManifests.upsertWarm` workspaceBytes ONLY if cheap — pin: do NOT re-du on every write (sweeper refreshes; document). **registerArtifact**:

```ts
// artifacts.ts
export interface ArtifactDeps { db: Db; events: EventLog; storage: StorageAdapter;
  presignTtlSeconds?: number /* default DEFAULT_PRESIGN_TTL_SECONDS */; clock?: () => Date }
export interface ArtifactInput { userId: string; sessionId: string; name: string; contentType?: string;
  sourcePath?: string; content?: Buffer }              // exactly one of sourcePath | content
export interface ArtifactRecord { id: string; key: string; sizeBytes: number; sha256Hex: string;
  contentType: string; url: string; expiresAt: string }
export function registerArtifact(deps: ArtifactDeps, input: ArtifactInput): Promise<ArtifactRecord>;
// id = newId() (UUIDv7); contentType ?? contentTypeFor(name); key = r2Keys.artifact(uid, sid, id, name);
// stream file (sourcePath) or Buffer via storage.put with sha256Hex computed on the fly;
// workspaceObjects.registerArtifact row; events.append "artifact_created"
//   {artifactId, name, sessionId, sizeBytes, contentType, url: presignGet(key, ttl), expiresAt}
//   + eventMirror.put; returns the record. NEVER logs the url.
```

- [ ] **Step 1: Write failing hydrate tests** (`hydrate.test.ts`, same gated harness as Task 8): **round-trip** — seed dir → hibernate (call Task 8) → `hydrateWorkspace` → `status hydrated`, tree checksum-identical (recursive sha256 map equal to pre-hibernate map, modes + symlink targets + mtimeSec equal); state warm; `workspace_hydrated` event emitted; dir du recorded in row. **skips** — warm → `already_warm`; job.generation mismatch → `stale_generation`; no row → `no_archive`. **crash remnant** — pre-create a junk dir at the target path with state cold → hydrate wipes and extracts cleanly. **failure path** — corrupt the stored archive (flip a byte) → rejects `ArchiveCorruptError`/`HashMismatchError`, state back to `cold`, partial dir removed. **awaitWarm** — cold row + stub queue recording adds: two concurrent `awaitWarm` → exactly ONE `add` (jobId dedupe), both resolve when a background `hydrateWorkspace` flips state; timeout (stub queue, no worker) → rejects `WorkspaceStateError` code `hydrate_timeout`; warm row → resolves without any add. **readWorkspaceFile** — after hibernate (dir absent): 20 random files exact bytes + `source:"archive"` + dir STILL absent after reads (zero-extraction pin); `../escape` and absolute → `KeyLayoutError`; symlink planted in a warm dir pointing to `/etc/hostname` → `NotFoundError`; oversize vs `maxBytes` → `FileTooLargeError`; unknown path → `FileNotInArchiveError`. **writeWorkspaceFile** — warm write → read-back exact; cold (no dir) → `WorkspaceStateError` code `not_warm`. **index cache** — two consecutive cold reads → sidecar `getBuffer` called once (counting adapter wrapper); `clearIndexCache()` resets.
- [ ] **Step 2: Write failing artifact tests** (`artifacts.test.ts`): register from Buffer → object exists at exact key, row bytes/sha256 exact integers, event payload validates against `artifactCreatedPayloadSchema`, `url` starts with `file://` (fs adapter), `expiresAt ≈ now+ttl` (clock injected); register from `sourcePath` (temp file) → identical; both content fields → throws; contentType defaults from `contentTypeFor` (`"shot.png"` → `image/png`); `shouldPresign` table: (text/plain, 100, 1 MiB) false; (application/json, 100) false; (image/png, 100) true; (text/plain, 2 MiB, 1 MiB) true; `listArtifacts`/`getArtifact` via repos return the row.
- [ ] **Step 3: Run to verify failure.** Run: gated vitest on both files — Expected: FAIL.
- [ ] **Step 4: Implement `hydrate.ts` + `artifacts.ts`; verify pass.** Same command — PASS.
- [ ] **Step 5: Commit.** `pnpm -r build && pnpm -r test` then `git add cloud/packages/storage && git commit -m "feat(cloud): hydration engine — full + lazy single-file, artifacts pipeline"`

### Task 10: Warm-cache LRU, disk-pressure guard, idle sweeper (single `OVID_MAX_WARM_GB` knob — ruling R2)

**Files:**
- Create: `cloud/packages/storage/src/warmLru.ts`, `src/sweeper.ts`
- Modify: `cloud/packages/storage/src/index.ts`
- Test: `cloud/packages/storage/src/{warmLru.test.ts,sweeper.test.ts}`

**Interfaces:**
- Consumes: Tasks 7–9 (`HibernateJob`, `storageJobId`, `fileManifests` repos, `HibernateDeps`, `reconcileStuckHibernations`) + the `SandboxEviction` seam (Task 8 — supplied by P2's SandboxManager per contract 1; `createNoopSandboxEviction()` until P2 lands).
- Produces:

```ts
// warmLru.ts
export const MAX_WARM_GB_DEFAULT = 8;            // Q8-design ruling default (ruling R2); the 8→12 retune
                                                 // consideration for this box is below — owner decides at activation
export const DISK_ALERT_PCT_DEFAULT = 80;
export const SWEEP_INTERVAL_MS = 30_000;        // spike §9.3
export const IDLE_THRESHOLD_MS = 180_000;       // G7 3-min idle
export const STUCK_STATE_MS = 900_000;          // hibernating/hydrating rows older than this → reconcile
export const WARM_DU_REFRESH_MS = 600_000;      // refresh warm-row workspaceBytes at most every 10 min in reconcile
export function maxWarmBytesFromEnv(env: NodeJS.ProcessEnv): number;      // OVID_MAX_WARM_GB — the ONE warm-disk knob (ruling R2, shared with P2's attach-guard; P7's LRU OWNS enforcement), positive integer GB → bytes (× 1024³, integer math)
export function diskAlertFractionFromEnv(env: NodeJS.ProcessEnv): number; // OVID_DISK_ALERT_PCT, integer 1..99 → /100
export interface WarmConfig { maxWarmBytes: number; diskAlertFraction: number }
export type WarmDeps = HibernateDeps & { queues: { hibernate: { add(name: string, job: HibernateJob,
  opts: { jobId: string }): unknown } }; diskProbe?: (path: string) => Promise<DiskUsage> }  // probe injectable for tests
export interface DiskUsage { totalBytes: number; freeBytes: number; usedFraction: number }
export function du(dir: string): Promise<number>;            // recursive sum of FILE st.size (relative ordering is what LRU needs; documented underestimate vs du --block-size); used ONLY on session workspace dirs P7 owns the path of via workspaceDir (hydrate markWarm) — LRU sizes come from the seam, never from raw enumeration (ruling R1)
export function statfsUsage(path: string): Promise<DiskUsage>;  // fsPromises.statfs → integer bytes; usedFraction = (total-free)/total (float ONLY here — compared against the alert fraction, never stored)
export function reconcileWarmRegistry(deps: WarmDeps, cfg: WarmConfig,
  opts?: { now?: Date }): Promise<{ registered: number; reset: number; totalWarmBytes: number; disk: DiskUsage }>;
// CONSUME the P2 seam (ruling R1 — NEVER raw-walk `${workspacesRoot}/users/*/sessions/*`):
// entries = deps.sandbox.listWarmWorkspaces() ↔ PG warm rows:
//   entry without row → upsertWarm(entry.bytes)  [registers never-hibernated sessions into the LRU]
//   row warm without entry → archiveKey verified present → markCold (uiTree rebuilt from sidecar/index);
//     no archive → remove row + system_note {code:"workspace_lost"} (should be impossible — log loudly)
//   row warm with entry and updatedAt older than WARM_DU_REFRESH_MS → refresh workspaceBytes = entry.bytes
//   delegates hibernating/hydrating stuck rows (> STUCK_STATE_MS) to reconcileStuckHibernations
export function enforceWarmCap(deps: WarmDeps, cfg: WarmConfig,
  opts?: { maxEvictions?: number /* default 8 per pass — anti-thrash bound */ }): Promise<{ evicted: number; freedBytes: number }>;
// WHILE (Σ workspaceBytes of warm rows > maxWarmBytes) OR (disk.usedFraction ≥ diskAlertFraction):
//   pick the warm session with the OLDEST activity (activity.readMany; missing key → row.updatedAt
//   fallback) → hibernateQueue.add(HIBERNATE_JOB_NAME, {sessionId, userId, generation: row.generation+1,
//   reason: "pressure"}, {jobId: storageJobId(sid, g)}) → count its workspaceBytes as freed, remove
//   from the candidate set; stop when under both thresholds or maxEvictions hit or no candidates.
// First crossing of the disk alert (per process) ALSO logs a console.warn and appends ONE system_note
// {code:"disk_pressure", usedPct} to the most-evicted session — coordination note: 80 % of 193 GB
// leaves ~38 GB free, far above the P1 backup script's BACKUP_MIN_FREE_MB=2048 abort floor, so
// hibernation relief always fires before backups would refuse to run.

// sweeper.ts
export function sweepWorkspaces(deps: WarmDeps, cfg: WarmConfig,
  opts?: { now?: Date }): Promise<{ registered: number; enqueuedIdle: number; enqueuedPressure: number }>;
// = reconcileWarmRegistry, then for every warm row: lastActivity = activity ?? row.updatedAt;
// now - lastActivity ≥ IDLE_THRESHOLD_MS → enqueue hibernate (reason "idle", generation+1,
// storageJobId dedupe), then enforceWarmCap. NEVER throws (caller = setInterval; log and continue).
```

**`OVID_MAX_WARM_GB` = 8 default + the 8→12 retune consideration (ruling R2 — one knob, one owner):** the P1-era ledger Q8 ruling set the default to 8 GB and made retuning an owner-at-activation decision; this plan ships **8** as the default and owns enforcement of the single env knob `OVID_MAX_WARM_GB` (P2's attach-guard reads the same var as an advisory check — reconcile to ONE value at deploy; a mismatch logs loudly). **Retune consideration to present to the owner at activation:** this box has 193 GB disk (≈4.3× the old box's 45 GB free envelope) but only 8 vCPU/22 GB RAM, and the ledger revised the concurrent-sandbox budget to ~24. Free-tier workspace quota is 500 MB ⇒ **24 × 500 MB = 12 GB**: at `OVID_MAX_WARM_GB=12` every admitted Free-tier session can stay warm simultaneously, so LRU eviction only triggers for Pro (2 GB) workspaces or disk pressure — no evict/rehydrate churn under the admission cap (each churn costs ~7 s pack CPU + a full hydrate on an 8-core box); at 8 GB the cap sits below the admission budget and Free-tier sessions may thrash under a full load; 16 GB+ would crowd store/backup growth on a box that also hosts the live production stack. Disk budget check either way: 80 % alert = ~154 GB used; current usage 57 GB + rootfs ≤3 GB×2 + per-user stores ≤10 GB + backups ~10 GB + images/PG growth leaves >25 GB headroom above even a 12 GB cap (≈6 % of disk), and `enforceWarmCap`'s disk branch is the backstop when growth surprises.

**Idle-trigger choice (pins the brief's "pick and justify"): worker sweeper tick scanning `last_activity`, NOT BullMQ delayed-job re-arm.** (1) One arbiter: idle timeout, LRU cap, disk pressure, and P2's future admission pressure all reduce to "enqueue hibernate for the least-recently-active warm session" — a single sweeper with one view of warm bytes/disk; delayed-job re-arm covers only the idle case and needs a second, uncoordinated mechanism for pressure. (2) Cost: activity events are high-frequency (every keystroke on P2's PTY, every P6 screencast frame); re-arming a delayed job per event means remove+add churn against redis-q — the authoritative noeviction store (AG3 hygiene) — while one `SET … EX` per event on redis-c is O(1) and eviction-safe. (3) Crash-safety: sweeper state is fully derivable (disk + PG + activity keys); a delayed-job registry drifts after crashes/redeploys. Worst-case trigger latency = 180 s idle + 30 s tick ≈ 210 s — the spike's §9.3 flow makes the same call; G7's "3 minutes" is the idle threshold, eviction completes seconds later (pack ~7 s + upload).

- [ ] **Step 1: Write failing warmLru tests** (`warmLru.test.ts`, gated harness + injected `diskProbe` + stub hibernate queue recording adds; **stub `SandboxEviction`** over an in-memory entries map — `listWarmWorkspaces()` returns fabricated `{userId, sessionId, bytes}` for s1/s2/s3, `evictWorkspace` records calls; ruling R1: no raw dir enumeration anywhere in the suite): `du` sums file bytes exactly over a mkdtemp session dir (integer; util still used by hydrate markWarm); `reconcileWarmRegistry` registers 3 seam entries (rows appear, warm, `workspaceBytes` exact from `entry.bytes`) and re-runs idempotently (`registered: 0` second pass); row-without-seam-entry + verified archive → markCold; row-without-entry + no archive → row removed + `workspace_lost` system_note; `enforceWarmCap` with `maxWarmBytes` = 1.5× smallest entry → evicts ONLY the least-recently-active (activity: s2 oldest) → one add with `reason:"pressure"`, `generation: row.generation+1`, `jobId === storageJobId(...)`; disk branch: probe returns usedFraction 0.85 ≥ cfg 0.8 → evicts oldest regardless of byte cap; `maxEvictions: 2` caps adds at 2 (anti-thrash); `maxWarmBytesFromEnv({OVID_MAX_WARM_GB:"12"}) === 12*1024**3`, `{}` → default 8, `{"0"}`/`{"x"}` → throw.
- [ ] **Step 2: Write failing sweeper tests** (`sweeper.test.ts`): clock injected, activity s1=now−10 s, s2=now−200 s → sweep enqueues hibernate for s2 only (`reason:"idle"`), s1 untouched; activity missing for s3 + row.updatedAt now−200 s → enqueued (fallback pin); fresh session with NO row but dir present → registered then evaluated in the SAME pass; stuck `hibernating` row (updatedAt now−20 min, dir present) → reset to warm (delegation pin); sweep with a throwing diskProbe → resolves (never throws) and logs.
- [ ] **Step 3: Run to verify failure; implement; verify pass.** Run: `bash cloud/scripts/dev-services.sh && cd cloud && TEST_DATABASE_URL=… TEST_REDIS_URL=… pnpm --filter @ovid/storage exec vitest run src/warmLru.test.ts src/sweeper.test.ts`.
- [ ] **Step 4: Commit.** `pnpm -r build && pnpm -r test` then `git add cloud/packages/storage && git commit -m "feat(cloud): warm-cache LRU, disk-pressure guard, idle sweeper"`

### Task 11: Worker — internal file service, StateHydrator wiring, `ensureWarm` run hook

**Files:**
- Create: `cloud/apps/worker/src/fileService.ts`
- Modify: `cloud/apps/worker/src/main.ts` (wiring), `cloud/apps/worker/src/runProcessor.ts` (hook), `cloud/apps/worker/package.json` (deps: `@ovid/storage workspace:*`, `fastify ^5` — match gateway's pinned major)
- Test: `cloud/apps/worker/src/fileService.test.ts`; extend `runProcessor.test.ts`

**Interfaces:**
- Consumes: Tasks 8–10 engines; Task 7 queues; `liveTree` (Task 4); existing `loadWorkerEnv`/`main` pattern (staleRuns sweeper interval shape).
- Produces:

```ts
// fileService.ts — internal HTTP, ovid-cloud network ONLY (never host-published)
export interface FileServiceDeps { db: Db; events: EventLog; storage: StorageAdapter;
  workspacesRoot: string; activity: ActivityTracker; internalToken: string; inlineMaxBytes: number;
  port: number; host?: string /* default "0.0.0.0" (container-internal) */ }
export function buildFileService(deps: FileServiceDeps): FastifyInstance;  // inject()-testable, unlistened
// preHandler: header `x-ovid-internal-token` must equal deps.internalToken → else 401 envelope;
// `x-ovid-user-id` required (gateway already enforced ownership — documented trust boundary).
// GET  /internal/sessions/:sid/tree → 200 { tree: await liveTree(workspaceDir(…)) } | 404 not_found (no dir)
// GET  /internal/sessions/:sid/file?path=… → readWorkspaceFile({userId, sessionId, path}, {maxBytes: inlineMaxBytes})
//    → shouldPresign(contentType, sizeBytes, inlineMaxBytes) is FALSE →
//        200 { kind:"content", path, sizeBytes, sha256Hex, contentType, contentBase64 }
//      TRUE (binary or oversize — incl. FileTooLargeError, whose sizeBytes fills the shape) →
//        200 { kind:"redirect", path, sizeBytes, contentType, downloadUrl, expiresAt }  — SEE PIN below
//    → FileNotInArchive/NotFound → 404 not_found; KeyLayoutError → 400 bad_request
// PUT  /internal/sessions/:sid/file?path=…  body { contentBase64 } → writeWorkspaceFile
//    → 200 { path, sizeBytes, sha256 } | 409 { error:{ code:"not_warm" } } | 400 | 404
// PIN (oversize/binary files → kind:"redirect"): WARM files stream from disk (registerArtifact with
//   sourcePath); COLD files are extracted buffered (registerArtifact with content) under
//   REDIRECT_MAX_BYTES = 64 MiB — beyond that (cold only) answer 413 { error:{ code:"file_too_large" } }
//   (worker mem_limit is 2 g; extractFile buffers whole members). The redirect registers an artifact
//   and returns its presigned url + expiresAt — reuses the artifacts pipeline, no second presign
//   mechanism, and the artifact row is a feature (download history); documented as such.
// runProcessor.ts addition:
//   RunDeps += { ensureWarm?: (sessionId: string, userId: string) => Promise<void>;
//                activity?: ActivityTracker }
//   after claimNext succeeds: await deps.ensureWarm?.(sessionId, userId) inside try/catch —
//   rejection → emit run_failed {runId, code:"hydrate_failed", message} + runs.finish(failed) + RETURN
//   (same shape as the key_not_minted path); activity?.bump(sessionId) after claim and after finish.
// main.ts wiring (composition root — untested-thin per P1 precedent, e2e covers):
//   loadStorageEnv(process.env) → createStorage; REDIS_C_URL (optional; falls back to REDIS_Q_URL with
//   a console.warn — activity keys are cache-class, spec §10 redis-c); createActivityTracker(redisC);
//   WORKSPACES_ROOT (default "/workspaces"), OVID_MAX_WARM_GB/OVID_DISK_ALERT_PCT → WarmConfig;
//   OVID_INTERNAL_TOKEN required, OVID_WORKER_FILE_PORT default 8091; sandbox = createNoopSandboxEviction()
//   (TODO(P2) comment); createQueues now yields hibernate/hydrate; createHibernateWorker(processor =
//   validate-with-hibernateJobSchema then hibernateWorkspace) + createHydrateWorker(hydrateWorkspace);
//   ensureWarm = (sid, uid) => awaitWarm(db, queues.hydrate, {sessionId:sid,userId:uid},
//     {reason:"run", timeoutMs: OVID_HYDRATE_TIMEOUT_MS default 60_000});
//   buildFileService(...).listen({port, host}); sweepWorkspaces interval — EXACT staleRuns pattern:
//   once at boot ("boot" label) then setInterval 30_000 ("interval"), errors logged never fatal,
//   .unref(), cleared in shutdown(); reconcileStuckHibernations once at boot before the first sweep;
//   shutdown closes: sweeper interval, both storage workers, fileService, redisC, redisQ, redisMint, db.
```

- [ ] **Step 1: Write failing fileService tests** (`fileService.test.ts`, gated harness, `buildFileService(...).inject()`): wrong/missing token → 401 envelope; warm session (seeded dir + row) GET tree → 200 with `uiManifestSchema`-valid tree, `source` shape per live tree; GET file warm → `kind:"content"`, base64 decodes to exact bytes, sha256Hex exact; GET file cold (hibernate first) → exact bytes, `source` archive, **dir still absent after the call**; GET `?path=../x` → 400 `bad_request`; GET unknown path → 404 `not_found`; GET binary/oversize cold file (plant a 2 MB `.png`, inlineMaxBytes 1 MiB) → `kind:"redirect"` with `file://` url + an artifact row created; PUT warm → 200 + read-back exact; PUT cold (no dir) → 409 `not_warm`; PUT with bad base64 → 400.
- [ ] **Step 2: Write failing runProcessor hook tests** (extend `runProcessor.test.ts` with its existing stub transport): `ensureWarm` resolves → run proceeds unchanged; `ensureWarm` rejects → exactly one `run_failed` event with `code:"hydrate_failed"`, run row failed, transport NEVER called; `ensureWarm` undefined → v0 behavior identical (backward-compat pin); `activity.bump` called when tracker provided.
- [ ] **Step 3: Run to verify failure.** Run: `bash cloud/scripts/dev-services.sh && cd cloud && TEST_DATABASE_URL=… TEST_REDIS_URL=… pnpm --filter @ovid/worker test` — Expected: FAIL.
- [ ] **Step 4: Implement fileService + runProcessor hook + main wiring** (install deps first: `pnpm --filter @ovid/worker add @ovid/storage fastify@^5` — align fastify major with `cloud/apps/gateway/package.json`); verify pass (same command).
- [ ] **Step 5: Env-validation tests + impl** (extend the existing `loadWorkerEnv` tests): `OVID_INTERNAL_TOKEN` missing → throws naming the var; `OVID_MAX_WARM_GB="x"` → throws; `NODE_ENV=production` + fs backend → throws (from `loadStorageEnv`); `OVID_WORKER_FILE_PORT` default 8091.
- [ ] **Step 6: Commit.** `pnpm -r build && pnpm -r test` then `git add cloud/apps/worker && git commit -m "feat(cloud): worker internal file service + StateHydrator wiring"`

### Task 12: Gateway — workspace tree/file REST, manual hydrate/hibernate, artifact URLs, activity bumps

**Files:**
- Create: `cloud/apps/gateway/src/workerClient.ts`, `src/routes/workspace.ts`, `src/routes/artifacts.ts`
- Modify: `cloud/apps/gateway/src/app.ts` (deps + registration), `src/env.ts`, `src/main.ts` (wiring), `src/ws.ts` (NO — see pin), `src/routes/messages.ts` (activity bump), `cloud/apps/gateway/package.json` (dep `@ovid/storage workspace:*`)
- Test: `cloud/apps/gateway/src/routes/{workspace.test.ts,artifacts.test.ts}`; extend `env.test.ts` pattern if present (else inline in workspace.test.ts)

**Interfaces:**
- Consumes: Task 9 (`awaitWarm`, `shouldPresign` constants), Task 6 repos, Task 3 DTO schemas, Task 2 (`createStorage`/presign), Task 7 (`ActivityTracker`, queues.hydrate), existing gateway plumbing (`GatewayDeps`, `authHook`, `sendError/notFound/badRequest/isUuid/queryValue/parsePageLimit`).
- Produces:

```ts
// workerClient.ts
export interface WorkerFileContent { kind: "content"; path: string; sizeBytes: number; sha256Hex: string;
  contentType: string; contentBase64: string }
export interface WorkerFileRedirect { kind: "redirect"; path: string; sizeBytes: number; contentType: string;
  downloadUrl: string; expiresAt: string }
export interface WorkerClient {
  getTree(userId: string, sessionId: string): Promise<{ tree: UiManifest }>;          // throws WorkerUnavailableError on connect/timeout
  getFile(userId: string, sessionId: string, path: string): Promise<WorkerFileContent | WorkerFileRedirect>;
  putFile(userId: string, sessionId: string, path: string, contentBase64: string): Promise<{ path: string; sizeBytes: number; sha256: string }>;
}
export class WorkerUnavailableError extends Error {}
export function createWorkerClient(cfg: { baseUrl: string; token: string; timeoutMs?: number /* default 10_000 */ }): WorkerClient;
// global fetch + AbortSignal.timeout; headers x-ovid-internal-token / x-ovid-user-id; 404/400/409
// responses returned as typed results ({ status, body }) — pin: methods resolve with
// { ok: true, value } | { ok: false, status: number, error: ApiError } discriminated results instead
// of throwing for HTTP-level errors; only transport failures throw WorkerUnavailableError.

// app.ts — GatewayDeps additions:
//   storage: StorageAdapter; activity: ActivityTracker; worker: WorkerClient;
//   inlineMaxBytes: number; presignTtlSeconds: number; hydrateWaitMs: number;
// registerWorkspaceRoutes(scope, deps) + registerArtifactRoutes(scope, deps) inside the AUTHENTICATED scope.

// routes/workspace.ts
export function registerWorkspaceRoutes(app: FastifyInstance, deps: GatewayDeps): void;
// GET /sessions/:id/workspace/tree — isUuid → 404; sessions.get(owner) → 404; fileManifests.get:
//   row && (state "cold" || state "hydrating") → 200 WorkspaceTreeResponse {source:"manifest",
//     state, generation, tree: row.uiTree (validate uiManifestSchema; invalid → log + 500 internal)}
//     — ZERO worker calls, ZERO extraction (the <100 ms SLA path)
//   else (no row | warm | hibernating) → worker.getTree → {source:"live", state:"warm", generation: row?.generation ?? 0}
//   WorkerUnavailableError → 503 unavailable. activity.bump NOT on tree (passive view).
// GET /sessions/:id/workspace/file?path=… — owner 404 gate; assertSafeRelPath (KeyLayoutError → 400);
//   activity.bump(sessionId) (Studio interaction = activity); ALWAYS proxy worker.getFile (worker owns
//   warm-vs-cold); content → WorkspaceFileResponse {encoding: text/* or json-ish ? "utf8" : "base64",
//   content: decoded utf8 or raw base64}; redirect → WorkspaceFileRedirect passthrough;
//   worker 404 → 404 not_found; worker 400 → 400; worker 413 → 413 passthrough (code file_too_large);
//   unavailable → 503.
// PUT /sessions/:id/workspace/file — zod putWorkspaceFileBodySchema (400 on fail); decoded content
//   ≤ inlineMaxBytes×8 (pin: PUT cap = 8 MiB via OVID_PUT_MAX_BYTES default 8_388_608; over → 400
//   bad_request "file too large"); owner gate; assertSafeRelPath; awaitWarm(db, deps.queues.hydrate, …,
//   {reason:"write", timeoutMs: deps.hydrateWaitMs}) — timeout (WorkspaceStateError hydrate_timeout) →
//   202 {status:"hydrating"} (client listens for workspace_hydrated and retries); then worker.putFile;
//   worker 409 not_warm (eviction race) → awaitWarm ONCE more → putFile again → still failing → 503;
//   200 WorkspaceFileWriteResponse; activity.bump.
// POST /sessions/:id/workspace/hydrate — owner gate; row: warm → 200 {status:"warm"}; cold → enqueue
//   hydrate (reason "manual", jobId storageJobId) → 202 {status:"hydrating"}; hydrating → 202;
//   no row → 200 {status:"warm"} (never hibernated; disk truth) ; hibernating → 409 invalid_state.
// POST /sessions/:id/workspace/hibernate — owner gate; row: warm → enqueue hibernate (reason "manual",
//   generation row.generation+1) → 202 {status:"hibernating"}; cold → 200 {status:"cold"};
//   hydrating|hibernating → 409 invalid_state; NO row → 409 invalid_state (message: workspace not
//   registered — sweeper registers within 30 s; documented).
// routes/artifacts.ts
export function registerArtifactRoutes(app: FastifyInstance, deps: GatewayDeps): void;
// GET /sessions/:id/artifacts?limit&cursor → owner gate → workspaceObjects.listArtifacts →
//   Page<ArtifactDto> (parsePageLimit/queryValue conventions; createdAt ISO)
// GET /sessions/:id/artifacts/:artifactId/url → owner gate + getArtifact(id, uid) → 404 |
//   deps.storage.presignGet(row.r2Key, deps.presignTtlSeconds) → 200 {url, expiresAt} — url never logged
// messages.ts: after the successful queue add → void deps.activity.bump(sessionId).catch(() => {})
// ws.ts: NO bump (passive watching is not activity — pinned in Task 10's trigger rationale);
//   the ActivityTracker dep is threaded through GatewayDeps only; P2 (pty) and P6 (browser) add their
//   own bumps at their channels (documented seam).
// env.ts — GatewayEnv additions: workerInternalUrl (requiredUrl in firebase mode), internalToken
//   (required in firebase mode), fileInlineMaxBytes (OVID_FILE_INLINE_MAX_BYTES default 1_048_576,
//   positive int), putMaxBytes (OVID_PUT_MAX_BYTES default 8_388_608), presignTtlSeconds
//   (OVID_PRESIGN_TTL_SECONDS default 3600, clamp 60..86400), hydrateWaitMs (OVID_HYDRATE_WAIT_MS
//   default 20_000, positive int), redisCUrl (REDIS_C_URL optional, falls back to redisQUrl).
// main.ts: createStorage(loadStorageEnv(env)) for presign, createActivityTracker(redisC),
//   createWorkerClient({baseUrl: env.workerInternalUrl, token: env.internalToken}).
```

- [ ] **Step 1: Write failing workspace-route tests** (`workspace.test.ts` — `buildGateway(deps).inject()`, real dev PG/redis, fs storage, and a STUB worker: a `node:http` server on an ephemeral port recording every request, wired as `workerInternalUrl`): **manifest path** — seed session + `fileManifests.markCold`-shaped row (cold, uiTree literal): GET tree → 200 `source:"manifest"`, tree deep-equals row.uiTree, **stub request log EMPTY (zero-extraction pin)**; response validated by `workspaceTreeResponseSchema`; **live path** — warm row → proxied, `source:"live"`; stub down (closed port) → 503 `unavailable`; **file GET** — content form (text) → `encoding:"utf8"`; redirect form passthrough; worker 404 → 404 envelope; `?path=../x` → 400 with NO stub call; owner mismatch → 404 on every route (never 403 — existing convention); **PUT** — warm row + stub 200 → 200 write response, activity key bumped (redis assert); cold row: stub a slow hydrate by flipping the row to warm mid-poll → PUT proceeds; timeout (row stays cold, hydrateWaitMs=300) → 202 `{status:"hydrating"}` and a hydrate job is visible on the real `queues.hydrate` (getJob by storageJobId); oversize content → 400; both content fields → 400; **hydrate/hibernate POSTs** — state-table assertions per pin (200/202/409 exact codes), hibernate enqueue visible with `reason:"manual"` and `generation: row.generation+1`.
- [ ] **Step 2: Write failing artifact-route tests** (`artifacts.test.ts`): register 3 artifacts via the Task 9 engine (fs storage) → GET list → `Page<ArtifactDto>` newest-first, keyset cursor works (limit 2); GET url → 200 `{url: "file://…", expiresAt}`; wrong owner → 404; unknown artifactId → 404.
- [ ] **Step 3: Run to verify failure.** Run: `bash cloud/scripts/dev-services.sh && cd cloud && TEST_DATABASE_URL=… TEST_REDIS_URL=… pnpm --filter @ovid/gateway test` — Expected: FAIL.
- [ ] **Step 4: Implement** workerClient + routes + app/env/main/messages edits (`pnpm --filter @ovid/gateway add @ovid/storage`); verify pass (same command); existing gateway suites still green (additive check).
- [ ] **Step 5: Commit.** `pnpm -r build && pnpm -r test` then `git add cloud/apps/gateway && git commit -m "feat(cloud): gateway workspace tree/file/hydrate REST + artifact URLs"`

### Task 13: SLA benchmark + storage e2e (acceptance on THIS box)

**Files:**
- Create: `cloud/packages/storage/bench/gen-ws.mjs`, `cloud/packages/storage/bench/sla.mjs`
- Modify: `cloud/packages/storage/package.json` (script `"bench:sla": "node bench/sla.mjs"`, `"bench:gen": "node bench/gen-ws.mjs"`)
- Create: `cloud/apps/e2e/src/storage.e2e.test.ts`; modify `cloud/apps/e2e/package.json` (dep `@ovid/storage workspace:*`)

**Interfaces:**
- Consumes: everything (engines, gateway `buildGateway`, worker `buildFileService`, repos, queues, fs adapter).
- Produces: the SLA acceptance artifact (`bench/results-<date>.json`) + the e2e suite. NOT imported by production code.

`gen-ws.mjs <targetDir>` — deterministic seeded workspace ≈190 MB / ≈11–12 k entries following spike §2 (mulberry32 seed, fixed mtimes): real `npm install --no-audit --no-fund express rxjs lodash axios chalk commander uuid zod moment debug ws typescript webpack` into `app/node_modules` (produces the realistic small-file shape + `.bin` symlinks); synthetic: 180 TS modules 6–45 KB token-soup, git repo (5 churn commits + `git gc --aggressive`), 24 dist chunks 150 KB–1.5 MB + source maps, 3×5 MB JSONL, 60 JSON fixtures, 2 MB CSV, 27 MB uncompressed tarball of its own tree, 10 MB `/dev/urandom` blob (ratio-1.0 worst case), copies of 3–4 host `.so` files (~6 MB), 90 synthetic `@fakeorg/*` packages. `--synthetic-only` flag skips npm (registry down) and inflates the synthetic corpus to ≈200 MB with a loud warning. Prints totals (entries/files/dirs/symlinks/logical bytes).

`sla.mjs` — requires `TEST_DATABASE_URL` + `TEST_REDIS_URL` (dev services) and `bench:gen` output; fs adapter + tmp roots; stages (each prints PASS/FAIL + writes `bench/results-<ISO date>.json`; process exits nonzero on any FAIL):
1. `packToStorage` + `hibernateWorkspace` wall time (report; budget: ≪ 180 s idle window).
2. **Manifest-first:** 50× gateway `inject()` GET tree on the cold session (real PG row) → p50/p95/max; **FAIL if p95 ≥ 100 ms**; assert zero worker/extraction calls (no dir exists).
3. **extractOne:** 100 random files via `readWorkspaceFile` cold (index cached — production path) → p50/p95/max; **FAIL if p95 ≥ 500 ms**; also report first-call (cold index) separately; assert dir still absent at the end.
4. **Full hydrate:** `hydrateWorkspace` (default workers) → **FAIL if ≥ 5 000 ms** for the ≤200 MB workspace; assert checksum-identical tree (recursive sha256 map vs pre-hibernate map) and modes/mtimes/symlinks.
5. **LRU pressure:** second seeded session, `maxWarmBytes` = 1.2× one workspace → `enforceWarmCap` (bench-local fs-backed `SandboxEviction` stub over the bench fixture dirs only — production consumes `@ovid/sandbox`'s seam, ruling R1) → exactly the least-recently-active session got a pressure hibernate job; run it → oldest dir gone, newest intact.
Header comment records the box class (EPYC-Milan 8c/22 GB/193 GB) and that spike numbers came from a slower box (conservative). Excluded from `pnpm -r test` (slow, network-optional).

`storage.e2e.test.ts` — follows `spine.test.ts` conventions (real gateway + real worker file service composed in-process over real dev PG/Redis, `TEST_*` env gating, ephemeral ports, deterministic bounded waits): (a) create session (test auth) → seed workspace dir → sweeper `reconcileWarmRegistry` registers it via a test-local fs-backed `SandboxEviction` stub that lists ONLY the e2e's own fixture dirs (production consumes `@ovid/sandbox`'s seam — ruling R1) → GET tree live; (b) POST hibernate → poll to cold → assert dir gone + archive/sidecar in fs storage + GET tree `source:"manifest"` with the stub-worker call counter at zero; (c) GET file cold → bytes sha256-identical to the seeded file, tree still manifest-only; (d) PUT file cold → 202 or 200 path → poll warm → GET file returns the NEW bytes → POST hibernate again → cold GET file still returns the new bytes (write survived re-hibernation; generation 2); (e) POST hydrate → warm → full-tree checksum identity; (f) `registerArtifact` (worker-side) → `artifact_created` event on the session stream (readSince) with url/expiresAt → GET `/artifacts` lists it → GET `/artifacts/:id/url` presigns.

- [ ] **Step 1: Write gen-ws.mjs; run it.** Run: `cd /root/OvidAI/cloud/packages/storage && node bench/gen-ws.mjs /tmp/opencode/p7bench/ws` — Expected: totals printed, ≈190 MB, ≈11–12 k entries (or `--synthetic-only` fallback documented).
- [ ] **Step 2: Write sla.mjs; run it.** Run: `bash cloud/scripts/dev-services.sh && cd cloud && TEST_DATABASE_URL=… TEST_REDIS_URL=… pnpm --filter @ovid/storage bench:sla` — Expected: all five stages PASS on this box; `bench/results-*.json` written (gitignored — add `bench/results-*.json` to `cloud/.gitignore`); numbers reported to the controller for the ledger (if stage 2–4 FAIL: do NOT relax thresholds — report to the controller; the spike margin says EPYC should beat the 2013 Xeon numbers).
- [ ] **Step 3: Write the e2e suite; run to verify pass.** Run: `TEST_DATABASE_URL=… TEST_REDIS_URL=… pnpm --filter @ovid/e2e test` — Expected: spine suite + storage suite PASS.
- [ ] **Step 4: Full workspace check + commit.** Run: `pnpm -r build && pnpm -r test`. Commit: `git add cloud/packages/storage/bench cloud/packages/storage/package.json cloud/apps/e2e cloud/.gitignore && git commit -m "test(cloud): P7 SLA benchmark + storage e2e (manifest/lazy/full/LRU)"`

### Task 14: Deploy artifacts + owner-gated R2 provisioning runbook

**Files:**
- Create: `cloud/scripts/verify-r2.mjs`, `cloud/deploy/R2-PROVISIONING.md`
- Modify: `cloud/deploy/.env.example`, `cloud/deploy/docker-compose.yml`, `cloud/deploy/DEPLOY.md` (addendum §R2/redis-c/workspaces volume)
- No production side effects until the owner-gated activation step (P1 Task 11 pattern: artifacts autonomous, activation paused).

**Interfaces:**
- Consumes: Task 2 (`loadR2Config`, `createR2Storage` from `@ovid/storage/dist`).
- Produces: runnable deploy artifacts + the owner runbook.

`.env.example` additions (template values only, `CHANGE_ME`/commented conventions preserved): `# ── Storage (P7) ──` block with `OVID_STORAGE_BACKEND=r2`, `OVID_R2_ACCOUNT_ID=CHANGE_ME`, `OVID_R2_ACCESS_KEY_ID=CHANGE_ME`, `OVID_R2_SECRET_ACCESS_KEY=CHANGE_ME` (note: `openssl`-generated Cloudflare token pair; the backup script's `AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY` may carry the SAME values), `OVID_R2_BUCKET=ovid-cloud`, `WORKSPACES_ROOT=/workspaces`, `OVID_MAX_WARM_GB=8` (the ONE warm-disk knob, ruling R2 — shared with P2's attach-guard; P7's LRU owns enforcement; the 8→12 GB retune consideration is in the P7 plan Task 10 and decided by the owner at activation), `OVID_DISK_ALERT_PCT=80`, `OVID_WORKER_FILE_PORT=8091`, `OVID_INTERNAL_TOKEN=CHANGE_ME` (`openssl rand -hex 32`), `OVID_WORKER_INTERNAL_URL=http://worker:8091` (gateway-side; comment: after P2 moves the worker to host systemd, point at the host-gateway address), `REDIS_C_URL=redis://:CHANGE_ME@redis-c:6379`, `REDIS_C_PASSWORD=CHANGE_ME`, optional-with-defaults comments for `OVID_FILE_INLINE_MAX_BYTES`, `OVID_PUT_MAX_BYTES`, `OVID_PRESIGN_TTL_SECONDS`, `OVID_HYDRATE_WAIT_MS`, `OVID_HYDRATE_TIMEOUT_MS`, `OVID_FS_STORAGE_ROOT` (dev only).

`docker-compose.yml` additions: **redis-c** service (mirror redis-q's shape: `redis:7-alpine`, `--maxmemory 256mb --maxmemory-policy allkeys-lru --appendonly no --requirepass ${REDIS_C_PASSWORD:?…}`, volume `redis-c-data`, `networks: [ovid-cloud]` only, `mem_limit: 384m`, healthcheck like redis-q); **worker**: `volumes: - ${WORKSPACES_ROOT:-/workspaces}:/workspaces` (rw) + `environment: UV_THREADPOOL_SIZE: "8"` (pack async-compress + libuv headroom, spike §4.4) + `depends_on: redis-c: {condition: service_healthy}`; **gateway**: `depends_on` add `redis-c: {condition: service_started}` (activity bumps only — degraded redis-c must not block REST; tracker falls back to redis-q URL when `REDIS_C_URL` unset).

`cloud/scripts/verify-r2.mjs` (autonomous artifact; runs ONLY when the owner supplies env — never in CI): loads `@ovid/storage` dist, `loadR2Config(process.env)` (missing → exit 1 naming the var), then: put 1 KiB probe at `users/_probe/{uuidv7}.txt` → head (bytes+metadata) → getBuffer byte-compare → presignGet(60) → global `fetch` → 200 + identical bytes → delete → head null. Prints one `[ok]/[FAIL]` line per check, masks everything except `accountId` first 8 chars + bucket; exit nonzero on any FAIL. Least-privilege note printed: only object read/write on the bucket is exercised (no list/admin needed).

`R2-PROVISIONING.md` (owner runbook — activation GATED, explicit stop-condition like P1 Task 11 Step 6): (1) Cloudflare dashboard → R2 → **Create bucket `ovid-cloud`** (spec §10/D7; no CORS configuration needed — all access is server-side via the S3 API); (2) **API token, least privilege**: R2 → Manage API Tokens → Create API Token → permissions **Object Read & Write**, apply to **bucket `ovid-cloud` only**, no account-admin permissions, TTL per owner policy → copy Access Key ID + Secret (secret shown once) into `/opt/ovid-cloud/.env` (`chmod 600`); agents/containers see only the env vars (D7: agents never see Cloudflare credentials); (3) **lifecycle rules**: bucket settings → add rule **AbortIncompleteMultipartUpload: 7 days** (critical — crashed multipart packs otherwise leak invisible storage forever); for the backup prefix: the P1 script uploads under `pg/{TS}/` (spec §10 writes `backups/pg/…` — flagged to the controller; the rule targets the ACTUAL prefix): recommend **no expiration** (backups), optional transition to an infrequent-access class when available; (4) fill the `.env` storage block (list vars + generation commands); (5) verify: `cd /opt/ovid-cloud && node cloud/scripts/verify-r2.mjs` → all `[ok]`; then run the Task 2 live contract test once (`OVID_R2_* … pnpm --filter @ovid/storage exec vitest run src/r2.live.test.ts`); (6) **ACTIVATION (owner approval required — stop-condition: live-box side effects + credentials):** `docker compose config -q` → `docker compose up -d` (redis-c, worker volume, env) → create `/workspaces` on the box → migrate (`node packages/db/dist/migrate-cli.js "$DATABASE_URL"` applies 0001) → smoke: manual POST hibernate/hydrate round-trip on a scratch session → `r2.live` suite green → flip `OVID_STORAGE_BACKEND=r2` permanently and re-run verify.

- [ ] **Step 1: Write artifacts** (`verify-r2.mjs`, `R2-PROVISIONING.md`, `.env.example` block, compose edits, DEPLOY.md addendum).
- [ ] **Step 2: Dry validation (autonomous, no side effects).** Run: `cd /root/OvidAI/cloud/deploy && docker compose config -q && node --check ../scripts/verify-r2.mjs` — Expected: both exit 0. Run `grep -c CHANGE_ME .env.example` → new placeholders present; `git diff` review: NO real values anywhere.
- [ ] **Step 3: verify-r2 negative path test (autonomous).** Run: `env -u OVID_R2_ACCOUNT_ID node cloud/scripts/verify-r2.mjs` — Expected: exit 1, message names `OVID_R2_ACCOUNT_ID`, prints no secret material.
- [ ] **Step 4: Commit artifacts.** `pnpm -r build && pnpm -r test` then `git add cloud/deploy cloud/scripts && git commit -m "chore(cloud): R2 deploy artifacts + owner provisioning runbook (activation gated)"`.
- [ ] **Step 5: ACTIVATION — STOP. Owner-gated.** Present `R2-PROVISIONING.md` to the owner; do not run any live step (bucket, token, compose up, /workspaces, backend flip) without explicit owner approval, per the P1 Task 11 precedent.

---

## Self-Review

**1. Spec coverage.** G7 (3-min idle → R2, <5 KB manifest-first, per-file lazy extraction): Tasks 4/5 (format), 8 (eviction), 9 (lazy), 10 (180 s + sweeper), 12 (tree from PG). §6.1 StateHydrator (grouped zstd frames + JSON frame index — as REVISED by the binding spike to grouped-frames OVIDWS-G1; manifest in Postgres; R2 keys under `users/{uid}/…`): Tasks 1, 4, 6, 8. §10 R2 layout: Task 1 keys (exact) + Task 14 lifecycle; hydration SLAs: Task 13 proves all three on this box; owner provisions via `OVID_R2_*`: Tasks 2/14. §10 tables `file_manifests` + `workspace_objects`: Task 6. §14 P7 row deliverables: 3-min eviction (T8/T10), instant studio open (T12 manifest path), lazy files (T9/T11/T12), artifacts (T9/T12), runbook owner task (T14), hibernate/hydrate queues (T7), browser storageState seam (T1). Ledger Q8 ruling honored: Task 10 (`OVID_MAX_WARM_GB` single knob, default 8 per the ruling, the 8→12 retune consideration documented for the owner at activation + disk alert 80 % + backup-floor coordination). Brief scope items: streaming pack w/o temp file (T4 `packToStorage` + T2 Upload), corruption→clean errors (T5), fs adapter for credential-free tests (T1), contract+skipIf live tests (T2), PUT write-through choice documented (T12: full-hydrate-then-write, rationale in T9 `awaitWarm` + T12 PUT pin), manual hydrate/hibernate controls (T12), e2e list (T13 items a–f map 1:1 to the brief's e2e sentence), runbook least-privilege/CORS/lifecycle/env/verify (T14).
**Gaps found & fixed during review:** (a) oversize/binary COLD file couldn't be presigned per-member — resolved in T11 via registerArtifact redirect (documented, reuses pipeline); (b) warm-never-hibernated sessions had no PG row for the sweeper/LRU — resolved by `reconcileWarmRegistry` disk enumeration (T10) and gateway no-row handling (T12); (c) sidecar-vs-archive index source for the lazy path — pinned sidecar-first with indexHash-verified archive fallback (T9).

**2. Step scan.** Every step names one artifact + one checkable result (test names/assertions, exact commands, expected FAIL/PASS). No "handle edge cases" lines: edge behavior is pinned in Interfaces blocks (crash windows, race skips, atomic writes, dedupe jobIds). Code bodies appear only where signature+tests don't determine them (packer grouping algorithm, hibernate step order, FCS table, sweeper arbitration) — those are algorithm pins from the binding spike, not transcripts.

**3. Type consistency.** Cross-task name audit performed: `StorageAdapter.put/get/getBuffer/head/delete/presignGet/presignPut/readerSpec` identical in T1/T2 (presignPut per ruling R3 — consumed by P8-T3 per contract 6)/T8/T9/T11/T12; `ReaderSpec`/`openReader` defined T1, extended T2, consumed T5 (`extractAll(spec,…)`) and T8/T9; `ArchiveIndex/FrameRec/FileRec/PackReport` T4 → T5/T8/T9; `encodeIndexWire` T4 → T8 sidecar (same bytes the footer hashes) → T9 `decodeIndexWire`; `UiManifest` T3 → T4 (`uiTree`/`liveTree`) → T6 (`$type<UiManifest>`) → T11/T12 wire; `WorkspaceState` T3 → T6 state column → T8/T9/T10 transitions → T12 responses; `HibernateJob/HydrateJob/storageJobId/HIBERNATE_JOB_NAME/HYDRATE_JOB_NAME` T7 → T8/T9/T10/T11/T12 identical; `awaitWarm(db, hydrateQueue, ref, opts)` signature identical in T9 (def), T11 (ensureWarm wiring), T12 (PUT/hydrate); `fileManifests.beginHibernation/markCold/beginHydration/markWarm/upsertWarm/listWarmForLru/remove` + `workspaceObjects.putArchive/registerArtifact/listArtifacts/getArtifact` identical T6 → T8/T9/T10/T12; `HibernateDeps` ⊂ `WarmDeps` (T10 alias) ⊂ fileService deps (T11); events `artifact_created/workspace_hibernated/workspace_hydrated` union (T3) = emitted types (T8/T9) = e2e assertions (T13). One deliberate deviation flagged in-place: T7's `createActivityTracker` takes a structural redis interface (no ioredis runtime dep) — callers pass real `Redis` instances (T11/T12), tests pass real ioredis (dev redis).

**4. Review Focus mapping.** #1 traversal → T1 keys tests, T9 realpath-jail + `assertSafeRelPath` tests, T11 file-service 400/404 tests, T12 route-validation-before-proxy tests. #2 corruption → T5 corruption matrix (spike §7.2 mirror), T4 readIndex guards, T8 verify-failure test. #3 hibernate/activity race → T8 active_run + recent_activity + stale_generation tests, T10 sweeper freshness tests. #4 crash windows → T8 `reconcileStuckHibernations` tests + ordering pin, T9 crash-remnant + failure-restore tests, T10 stuck-state delegation test. #5 disk/LRU → T10 `enforceWarmCap` byte+disk branches, anti-thrash bound, backup-floor coordination note. All five owned with concrete tests — none deferred.

**5. Proportion.** 14 tasks for a plan whose binding inputs span a 439-line research report, two new DB tables, two new queues, a new package (~15 modules), two app integrations, deploy + runbook. Code blocks are signatures/constants/test assertions, not implementations; the codec's algorithmic detail is restated only where the spike marks it as a caught bug (grouping shatter, two-pass extraction, FCS table) — the report remains the byte-level authority and travels with the plan.

**Execution handoff:** the controller batches commits and chooses the execution method (this plan was written by a dispatched plan-writer; no git commands were run).

**Post-verification revisions (2026-10-16, controller rulings R1–R3):** **R1** — warm-workspace layout converged to `/workspaces/users/{uid}/sessions/{sessionId}/workspace`; `sessionWorkspacePath` renamed `workspaceDir` (+ alias) matching P2's seam; the sweeper/LRU now consume the `SandboxEviction` seam (`listWarmWorkspaces()` / `evictWorkspace(userId, sessionId)`, pack-safe destroy via P2's SandboxManager) instead of raw-walking `users/*/sessions/*` (T1/T8/T10/T11/T13); Postgres `file_manifests`/`workspace_objects` authority unchanged. **R2** — one warm-disk knob `OVID_MAX_WARM_GB`, default 8 per the P1-era ledger Q8 ruling, with the 8→12 GB retune consideration stated for the owner at activation; P7's StateHydrator LRU owns enforcement, P2's attach-guard reads the same env var (Global Constraints, Cross-plan contract 1, T10/T11/T14). **R3** — `presignPut(key, ttlSeconds)` added to `StorageAdapter` (T1 interface + fs pseudo-URL, T2 R2 impl via `PutObjectCommand` + offline-signing test) plus Cross-plan contract 6 so P8-T3's presigned-R2-PUT attachment-upload assumption holds; P8's approved gateway-presigner fallback (ledger P8-Q3) remains noted.
