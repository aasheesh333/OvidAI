#!/usr/bin/env node
/**
 * P7 Task 13 — SLA acceptance benchmark (runs ON THIS BOX).
 *
 *   node bench/sla.mjs [fixtureDir]
 *
 * Box class: 8 vCPU AMD EPYC-Milan, 22 GB RAM, 193 GB disk (virtio).
 * The spike's timings (the binding archive-format research) were measured on
 * the OLD, slower 2013 Xeon E5-2690 v2 box — its numbers are conservative
 * here; these thresholds are re-proved, not inherited.
 *
 * Requires:
 *   - TEST_DATABASE_URL / TEST_REDIS_URL (cloud/scripts/dev-services.sh)
 *   - a gen-ws.mjs fixture: `node bench/gen-ws.mjs /tmp/opencode/p7bench/ws`
 *     (or pass another dir / set OVID_BENCH_WS)
 *
 * Stages (the plan's acceptance criteria — thresholds are NOT relaxed on a
 * FAIL; the exact numbers are reported):
 *   1. packToStorage + hibernateWorkspace wall time (budget ≪ 180 s).
 *   2. manifest-first tree: 50× gateway inject() GET tree on the cold
 *      session → p95 < 100 ms, ZERO worker/extraction calls.
 *   3. extractOne via readWorkspaceFile: 100 random files, index cached
 *      (the production lazy path) → p95 < 500 ms; first call (cold index)
 *      reported separately; the workspace dir stays ABSENT.
 *   4. full hydrateWorkspace (default workers) → < 5 000 ms for ≤200 MB;
 *      recursive sha256/mode/mtime/symlink identity vs the pre-hibernate map.
 *   5. LRU pressure: two warm sessions, maxWarmBytes = 1.2× one workspace →
 *      enforceWarmCap enqueues exactly the least-recently-active session;
 *      running that job removes the oldest dir and leaves the newest intact.
 *
 * Every stage prints PASS/FAIL and the whole run writes
 * `bench/results-<ISO timestamp>.json` (gitignored). The process exits
 * nonzero if any stage FAILed.
 *
 * Excluded from `pnpm -r test` by design (slow, network-optional).
 *
 * The @ovid/* packages are imported from their compiled dist via relative
 * paths on purpose: @ovid/storage declares no dependency on @ovid/db /
 * @ovid/events / @ovid/queue / @ovid/gateway (the parallel-wave package-edge
 * rule), and this bench is not production code. Build the workspace first
 * (`pnpm -r build`) so the dists are current.
 */

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { performance } from "node:perf_hooks";

import { Redis } from "ioredis";

import {
  createDb,
  migrate,
  users,
  sessions,
  fileManifests,
  workspaceObjects,
  runs,
  eventMirror,
} from "../../db/dist/index.js";
import { createRedisEventLog } from "../../events/dist/index.js";
import { createQueues } from "../../queue/dist/index.js";
import { buildGateway } from "../../../apps/gateway/dist/app.js";
import { createTestVerifier } from "../../../apps/gateway/dist/auth.js";
import { createTicketStore } from "../../../apps/gateway/dist/tickets.js";
import {
  ACTIVITY_KEY_PREFIX,
  clearIndexCache,
  createActivityTracker,
  createFsStorage,
  enforceWarmCap,
  hibernateWorkspace,
  hydrateWorkspace,
  packToStorage,
  readWorkspaceFile,
  r2Keys,
  walkWorkspace,
  workspaceDir,
} from "../dist/index.js";

// ---------------------------------------------------------------------------
// Knobs / pinned thresholds
// ---------------------------------------------------------------------------

const SEED = 20261016;
const MANIFEST_P95_MS = 100;
const EXTRACT_ONE_P95_MS = 500;
const HYDRATE_MAX_MS = 5_000;
const MANIFEST_GETS = 50;
const EXTRACT_ONE_GETS = 100;

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

if (!TEST_DATABASE_URL || !TEST_REDIS_URL) {
  console.error(
    "sla.mjs requires TEST_DATABASE_URL and TEST_REDIS_URL " +
      "(run: bash cloud/scripts/dev-services.sh)",
  );
  process.exit(2);
}

const fixtureDir = resolve(
  process.argv[2] ?? process.env.OVID_BENCH_WS ?? "/tmp/opencode/p7bench/ws",
);

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function mulberry32(seed) {
  let a = seed >>> 0;
  return function next() {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const rand = mulberry32(SEED ^ 0x5a17);

function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const idx = Math.min(sorted.length - 1, Math.ceil(p * sorted.length) - 1);
  return sorted[idx];
}

function stats(samples) {
  const sorted = [...samples].sort((a, b) => a - b);
  return {
    count: sorted.length,
    p50Ms: round3(percentile(sorted, 0.5)),
    p95Ms: round3(percentile(sorted, 0.95)),
    maxMs: round3(sorted[sorted.length - 1] ?? 0),
    minMs: round3(sorted[0] ?? 0),
    meanMs: round3(sorted.reduce((n, v) => n + v, 0) / Math.max(1, sorted.length)),
  };
}

function round3(n) {
  return Math.round(n * 1000) / 1000;
}

function sha256Hex(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitForAsync(cond, what, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (await cond()) return;
    if (Date.now() >= deadline) throw new Error(`waitFor timed out: ${what}`);
    await sleep(25);
  }
}

function stamp(iso) {
  return iso.replace(/[:.]/g, "-");
}

const log = (msg) => console.log(msg);

// ---------------------------------------------------------------------------
// Fixture identity map (sha256 + metadata) — stage 4's ground truth
// ---------------------------------------------------------------------------

async function treeMap(dir) {
  const entries = await walkWorkspace(dir);
  const map = new Map();
  for (const e of entries) {
    const rec = { type: e.type, mode: e.mode, mtime: e.mtime, size: e.size };
    if (e.type === 0) rec.sha256 = sha256Hex(await readFile(e.abs));
    if (e.type === 2) rec.target = e.target;
    map.set(e.path, rec);
  }
  return map;
}

function compareTrees(pre, post) {
  const problems = [];
  for (const [path, a] of pre) {
    const b = post.get(path);
    if (b === undefined) {
      problems.push(`missing after hydrate: ${path}`);
      continue;
    }
    if (a.type !== b.type) problems.push(`type mismatch: ${path}`);
    if (a.mode !== b.mode) {
      problems.push(`mode mismatch: ${path} ${a.mode} !== ${b.mode}`);
    }
    // Symlink mtimes are NOT restorable through Node's fs API (`utimes`
    // follows the link; there is no portable lutimes), and the archive
    // extractor deliberately restores symlinks as target-only members. Their
    // identity check is the TARGET below; file/dir mtimes are exact.
    if (a.type !== 2 && a.mtime !== b.mtime) {
      problems.push(`mtime mismatch: ${path} ${a.mtime} !== ${b.mtime}`);
    }
    if (a.type === 0 && a.sha256 !== b.sha256) {
      problems.push(`content mismatch: ${path}`);
    }
    if (a.type === 2 && a.target !== b.target) {
      problems.push(`symlink target mismatch: ${path}`);
    }
  }
  for (const path of post.keys()) {
    if (!pre.has(path)) problems.push(`unexpected after hydrate: ${path}`);
  }
  return problems;
}

// ---------------------------------------------------------------------------
// SandboxEviction stub (ruling R1): fs-backed over THIS bench's fixture dirs
// only. `evictWorkspace` leaves the files for the hibernation engine, exactly
// like the production P2 seam.
// ---------------------------------------------------------------------------

function createBenchSandboxEviction(workspacesRoot) {
  /** @type {Map<string, {userId: string, sessionId: string, bytes: number, lastAccessMs: number}>} */
  const entries = new Map();
  const evictions = [];
  return {
    authoritative: true,
    register(entry) {
      entries.set(entry.sessionId, entry);
    },
    async listWarmWorkspaces() {
      const out = [];
      for (const entry of entries.values()) {
        const dir = workspaceDir(workspacesRoot, entry.userId, entry.sessionId);
        const exists = await stat(dir).then(
          (s) => s.isDirectory(),
          () => false,
        );
        if (exists) out.push({ ...entry });
      }
      return out;
    },
    async evictWorkspace(userId, sessionId) {
      const dir = workspaceDir(workspacesRoot, userId, sessionId);
      if (!dir.startsWith(resolve(workspacesRoot) + "/")) {
        throw new Error(`refusing to evict outside the bench root: ${dir}`);
      }
      evictions.push({ userId, sessionId, at: Date.now() });
      // Pack-safe destroy: kill jail/PTY (none here), LEAVE the files.
    },
    evictions,
  };
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

const startedAt = new Date().toISOString();
const runId = `${Date.now().toString(36)}-${process.pid}`;
const uid = `bench-${runId}`;
const uidB = `${uid}-b`;
const runRoot = resolve(`/tmp/opencode/p7bench/run-${runId}`);
const storageRoot = join(runRoot, "storage");
const workspacesRoot = join(runRoot, "workspaces");
const queuePrefix = `ovid-bench-${runId}`;

const results = {
  task: "P7-T13 SLA benchmark",
  box: "AMD EPYC-Milan 8 vCPU / 22 GB RAM / 193 GB disk (virtio)",
  spikeNote:
    "spike timings came from the older, slower 2013 Xeon E5-2690 v2 box — conservative for this box",
  startedAt,
  fixtureDir,
  thresholds: {
    manifestP95Ms: MANIFEST_P95_MS,
    extractOneP95Ms: EXTRACT_ONE_P95_MS,
    hydrateMaxMs: HYDRATE_MAX_MS,
  },
  fixture: null,
  stages: {},
  pass: false,
};

let db;
let redis;
let queues;
let app;
let storage;
let activity;
let sandbox;
let benchDbName = null;
let benchDbUrl = null;
const createdSids = [];

async function main() {
  // ---- preflight --------------------------------------------------------
  const fixtureStat = await stat(fixtureDir).catch(() => null);
  if (fixtureStat === null || !fixtureStat.isDirectory()) {
    throw new Error(
      `bench fixture ${fixtureDir} is missing — run: node bench/gen-ws.mjs ${fixtureDir}`,
    );
  }
  const fixtureEntries = await walkWorkspace(fixtureDir);
  const fixtureBytes = fixtureEntries
    .filter((e) => e.type === 0)
    .reduce((n, e) => n + e.size, 0);
  results.fixture = {
    dir: fixtureDir,
    entries: fixtureEntries.length,
    files: fixtureEntries.filter((e) => e.type === 0).length,
    dirs: fixtureEntries.filter((e) => e.type === 1).length,
    symlinks: fixtureEntries.filter((e) => e.type === 2).length,
    logicalBytes: fixtureBytes,
  };
  log(
    `[fixture] ${results.fixture.entries} entries / ${(fixtureBytes / 1024 / 1024).toFixed(1)} MB ` +
      `at ${fixtureDir}`,
  );

  await mkdir(storageRoot, { recursive: true });
  await mkdir(workspacesRoot, { recursive: true });

  // Dedicated Postgres database for the run (the T11 precedent): the dev
  // Postgres is shared with every other suite/lane, and stage 5's
  // enforceWarmCap scans ALL warm file_manifests rows. An isolated database
  // keeps this acceptance artifact reproducible without ever touching another
  // lane's rows. Dropped in the finally block.
  benchDbName = `ovid_bench_${runId.replace(/[^a-zA-Z0-9_]/g, "_")}`;
  const admin = createDb(TEST_DATABASE_URL);
  try {
    await admin.$client.unsafe(`CREATE DATABASE ${benchDbName}`);
  } finally {
    await admin.$client.end({ timeout: 5 });
  }
  const benchUrl = new URL(TEST_DATABASE_URL);
  benchUrl.pathname = `/${benchDbName}`;
  benchDbUrl = benchUrl.toString();

  await migrate(benchDbUrl);
  db = createDb(benchDbUrl);
  redis = new Redis(TEST_REDIS_URL);
  const events = createRedisEventLog(redis);
  storage = createFsStorage(storageRoot);
  activity = createActivityTracker(redis);
  sandbox = createBenchSandboxEviction(workspacesRoot);

  // A session row + user row (FKs) for the real gateway's ownership check.
  await users.ensure(db, uid, null);
  const session = await sessions.create(db, uid, "SLA bench");
  const sid = session.id;
  createdSids.push(sid);
  const dir = workspaceDir(workspacesRoot, uid, sid);
  const sessionB = await users.ensure(db, uidB, null).then(async () => {
    const s = await sessions.create(db, uidB, "SLA bench B");
    createdSids.push(s.id);
    return s;
  });
  const sidB = sessionB.id;

  // Hardlink copy: a full workspace per session with no extra disk cost.
  await mkdir(join(workspacesRoot, uid, "sessions"), { recursive: true });
  execFileSync("cp", ["-al", fixtureDir, dir], { timeout: 120_000 });
  // The sweeper's register step (reconcileWarmRegistry's upsertWarm arm): a
  // warm dir must have a warm row before hibernate can claim it.
  await fileManifests.upsertWarm(db, {
    sessionId: sid,
    userId: uid,
    workspaceBytes: fixtureBytes,
  });
  log(`[bench] session ${sid} seeded at ${dir}`);

  const deps = {
    db,
    events,
    storage,
    workspacesRoot,
    sandbox,
    activity,
    fileManifests,
    workspaceObjects,
    runs,
    eventMirror,
    stuckHibernationScan: {
      async listStuck() {
        return [];
      },
    },
  };

  // ---- stage 1: pack + hibernate ---------------------------------------
  {
    const preMap = await treeMap(dir);
    const packKey = `bench/pack-${runId}.tar.zst`;
    const packT0 = performance.now();
    const packReport = await packToStorage(dir, storage, packKey, { jobs: 4 });
    const packMs = performance.now() - packT0;
    await storage.delete(packKey);

    const hT0 = performance.now();
    const hibernate = await hibernateWorkspace(deps, {
      sessionId: sid,
      userId: uid,
      generation: 1,
      reason: "manual",
    });
    const hibernateMs = performance.now() - hT0;
    const dirGone = await stat(dir).then(
      () => false,
      () => true,
    );
    const row = await fileManifests.get(db, sid);
    const pass =
      hibernate.status === "hibernated" && dirGone && row?.state === "cold";

    results.stages.packHibernate = {
      pass,
      metrics: {
        packMs: round3(packMs),
        hibernateMs: round3(hibernateMs),
        totalMs: round3(packMs + hibernateMs),
        archiveBytes: packReport.bytes,
        archiveSha256: packReport.sha256Hex,
        entryCount: packReport.index.files.length,
        archiveBytesFromHibernate: hibernate.archiveBytes ?? null,
        rowState: row?.state ?? null,
        dirGone,
      },
      budget: "≪ 180 s idle window",
      note:
        "packMs = standalone packToStorage (jobs:4); hibernateMs includes " +
        "pack + upload + full re-download verify + cold marker + evict",
      preMap,
    };
    log(
      `[stage 1] ${pass ? "PASS" : "FAIL"} pack=${round3(packMs)} ms ` +
        `hibernate=${round3(hibernateMs)} ms archive=${(packReport.bytes / 1024 / 1024).toFixed(1)} MB`,
    );
  }
  const preMap = results.stages.packHibernate.preMap;

  // ---- stage 2: manifest-first tree (50× gateway inject) ----------------
  {
    let workerCalls = 0;
    const workerStub = {
      async getTree() {
        workerCalls += 1;
        throw new Error("worker.getTree called on the manifest-first path");
      },
      async getFile() {
        workerCalls += 1;
        throw new Error("worker.getFile called on the manifest-first path");
      },
      async putFile() {
        workerCalls += 1;
        throw new Error("worker.putFile called on the manifest-first path");
      },
    };

    queues = createQueues({ url: TEST_REDIS_URL }, { prefix: queuePrefix });
    app = buildGateway({
      db,
      queues,
      verifier: createTestVerifier(),
      tickets: createTicketStore(redis),
      keys: { getKeyForUser: async () => "bench-key" },
      mint: { ensureKey: async () => ({ key: "bench-key" }) },
      events,
      worker: workerStub,
      storage,
      activity,
    });

    const samples = [];
    let last = null;
    let ok = true;
    for (let i = 0; i < MANIFEST_GETS; i += 1) {
      const t0 = performance.now();
      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/sessions/${sid}/workspace/tree`,
        headers: { authorization: `Bearer test:${uid}` },
      });
      samples.push(performance.now() - t0);
      if (res.statusCode !== 200) ok = false;
      last = res.json();
    }
    const s = stats(samples);
    const pass =
      ok &&
      last?.source === "manifest" &&
      last?.state === "cold" &&
      workerCalls === 0 &&
      s.p95Ms < MANIFEST_P95_MS;

    results.stages.manifestTree = {
      pass,
      metrics: {
        ...s,
        workerCalls,
        source: last?.source ?? null,
        state: last?.state ?? null,
        treeFiles: last?.tree?.totals?.files ?? null,
        dirExists: await stat(dir).then(
          () => true,
          () => false,
        ),
      },
      threshold: `p95 < ${MANIFEST_P95_MS} ms`,
    };
    log(
      `[stage 2] ${pass ? "PASS" : "FAIL"} manifest tree n=${s.count} ` +
        `p50=${s.p50Ms} p95=${s.p95Ms} max=${s.maxMs} ms workerCalls=${workerCalls}`,
    );
  }

  // ---- stage 3: extractOne 100 random files, index cached ---------------
  {
    const filePaths = [...preMap.entries()]
      .filter(([, r]) => r.type === 0)
      .map(([p]) => p);
    const picks = [];
    for (let i = 0; i < EXTRACT_ONE_GETS; i += 1) {
      picks.push(filePaths[Math.floor(rand() * filePaths.length)]);
    }

    clearIndexCache();
    const firstPath = picks[0];
    const firstT0 = performance.now();
    const first = await readWorkspaceFile(
      { db, events, storage, workspacesRoot, activity, fileManifests, eventMirror },
      { userId: uid, sessionId: sid, path: firstPath },
    );
    const firstMs = performance.now() - firstT0;

    const samples = [];
    let mismatches = 0;
    let sources = new Set();
    for (const p of picks) {
      const t0 = performance.now();
      const r = await readWorkspaceFile(
        { db, events, storage, workspacesRoot, activity, fileManifests, eventMirror },
        { userId: uid, sessionId: sid, path: p },
      );
      samples.push(performance.now() - t0);
      sources.add(r.source);
      if (r.sha256Hex !== preMap.get(p).sha256) mismatches += 1;
    }
    const s = stats(samples);
    const dirAbsent = await stat(dir).then(
      () => false,
      () => true,
    );
    const pass =
      first.sha256Hex === preMap.get(firstPath).sha256 &&
      mismatches === 0 &&
      sources.size === 1 &&
      sources.has("archive") &&
      dirAbsent &&
      s.p95Ms < EXTRACT_ONE_P95_MS;

    results.stages.extractOne = {
      pass,
      metrics: {
        ...s,
        firstCallColdIndexMs: round3(firstMs),
        mismatches,
        sources: [...sources],
        dirAbsent,
      },
      threshold: `p95 < ${EXTRACT_ONE_P95_MS} ms`,
    };
    log(
      `[stage 3] ${pass ? "PASS" : "FAIL"} extractOne n=${s.count} ` +
        `p50=${s.p50Ms} p95=${s.p95Ms} max=${s.maxMs} ms ` +
        `first(cold index)=${round3(firstMs)} ms dirAbsent=${dirAbsent}`,
    );
  }

  // ---- stage 4: full hydrate + checksum identity ------------------------
  {
    const t0 = performance.now();
    const hydrate = await hydrateWorkspace(deps, {
      sessionId: sid,
      userId: uid,
      generation: 1,
      reason: "manual",
    });
    const hydrateMs = performance.now() - t0;
    const postMap = await treeMap(dir);
    const problems = compareTrees(preMap, postMap);
    const row = await fileManifests.get(db, sid);
    const pass =
      hydrate.status === "hydrated" &&
      hydrateMs < HYDRATE_MAX_MS &&
      problems.length === 0 &&
      row?.state === "warm";

    results.stages.fullHydrate = {
      pass,
      metrics: {
        hydrateMs: round3(hydrateMs),
        files: hydrate.files ?? null,
        rowState: row?.state ?? null,
        comparedEntries: postMap.size,
        problems: problems.slice(0, 20),
        problemCount: problems.length,
      },
      threshold: `< ${HYDRATE_MAX_MS} ms`,
    };
    log(
      `[stage 4] ${pass ? "PASS" : "FAIL"} hydrate=${round3(hydrateMs)} ms ` +
        `entries=${postMap.size} problems=${problems.length}`,
    );
    if (problems.length > 0) {
      for (const p of problems.slice(0, 10)) log(`           ${p}`);
    }
  }

  // ---- stage 5: LRU pressure -------------------------------------------
  {
    const rowA = await fileManifests.get(db, sid);
    const oneWorkspaceBytes = rowA?.workspaceBytes ?? fixtureBytes;
    const dirB = workspaceDir(workspacesRoot, uidB, sidB);
    await mkdir(join(workspacesRoot, uidB, "sessions"), { recursive: true });
    execFileSync("cp", ["-al", fixtureDir, dirB], { timeout: 120_000 });

    await fileManifests.upsertWarm(db, {
      sessionId: sidB,
      userId: uidB,
      workspaceBytes: oneWorkspaceBytes,
    });
    sandbox.register({
      userId: uid,
      sessionId: sid,
      bytes: oneWorkspaceBytes,
      lastAccessMs: Date.now(),
    });
    sandbox.register({
      userId: uidB,
      sessionId: sidB,
      bytes: oneWorkspaceBytes,
      lastAccessMs: Date.now() - 3_600_000,
    });
    // Deterministic LRU: A used now, B used an hour ago (activity wins over
    // the row.updatedAt fallback — both rows were just written).
    await redis.set(
      `${ACTIVITY_KEY_PREFIX}${sid}`,
      String(Date.now()),
      "EX",
      604_800,
    );
    await redis.set(
      `${ACTIVITY_KEY_PREFIX}${sidB}`,
      String(Date.now() - 3_600_000),
      "EX",
      604_800,
    );

    const captured = [];
    const warmDeps = {
      ...deps,
      queues: {
        hibernate: {
          async add(name, payload, opts) {
            captured.push({ name, payload, opts });
            return { id: opts.jobId };
          },
        },
      },
      diskProbe: async () => ({
        totalBytes: 193 * 1024 ** 3,
        freeBytes: 130 * 1024 ** 3,
        usedFraction: 0.33,
      }),
      stuckHydrationScan: { async listStuckHydrating() { return []; } },
    };
    const cfg = { maxWarmBytes: Math.floor(oneWorkspaceBytes * 1.2), diskAlertFraction: 0.8 };
    const cap = await enforceWarmCap(warmDeps, cfg);

    const only = captured[0];
    const enqueuedRight =
      captured.length === 1 &&
      only.payload.sessionId === sidB &&
      only.payload.reason === "pressure" &&
      only.payload.generation === 1;

    let hibernateB = null;
    if (enqueuedRight) {
      hibernateB = await hibernateWorkspace(warmDeps, only.payload);
    }
    const bGone = await stat(dirB).then(
      () => false,
      () => true,
    );
    const aIntact = await stat(join(dir, [...preMap.keys()].find((p) => preMap.get(p).type === 0)))
      .then((s) => s.isFile())
      .catch(() => false);
    const rowB = await fileManifests.get(db, sidB);
    const pass =
      enqueuedRight &&
      cap.evicted === 1 &&
      hibernateB?.status === "hibernated" &&
      bGone &&
      aIntact &&
      rowB?.state === "cold";

    results.stages.lruPressure = {
      pass,
      metrics: {
        maxWarmBytes: cfg.maxWarmBytes,
        oneWorkspaceBytes,
        evicted: cap.evicted,
        freedBytes: cap.freedBytes,
        enqueued: captured.map((c) => ({
          name: c.name,
          sessionId: c.payload.sessionId,
          generation: c.payload.generation,
          reason: c.payload.reason,
          jobId: c.opts?.jobId ?? null,
        })),
        oldestSession: sidB,
        oldestDirGone: bGone,
        newestDirIntact: aIntact,
        oldestRowState: rowB?.state ?? null,
        evictions: sandbox.evictions.length,
      },
      threshold: "exactly one pressure job for the least-recently-active session",
    };
    log(
      `[stage 5] ${pass ? "PASS" : "FAIL"} evicted=${cap.evicted} ` +
        `oldest=${only?.payload.sessionId === sidB ? "B" : "?"} ` +
        `oldestDirGone=${bGone} newestIntact=${aIntact}`,
    );
  }

  results.pass = Object.values(results.stages).every((s) => s.pass === true);
}

// ---------------------------------------------------------------------------
// Entry point: always write the results artifact, then exit per pass/fail.
// ---------------------------------------------------------------------------

try {
  await main();
} catch (err) {
  results.error = err instanceof Error ? `${err.stack ?? err.message}` : String(err);
  log(`[sla] ERROR: ${results.error}`);
} finally {
  results.finishedAt = new Date().toISOString();

  // Drop the (possibly large) in-memory maps before serializing.
  for (const stage of Object.values(results.stages)) delete stage.preMap;

  const resultsPath = resolve(
    new URL(".", import.meta.url).pathname,
    `results-${stamp(startedAt)}.json`,
  );
  await writeFile(resultsPath, JSON.stringify(results, null, 2), "utf8").catch((err) => {
    console.error(`[sla] failed to write ${resultsPath}:`, err);
  });
  log(`[sla] results: ${resultsPath}`);

  // Teardown: scoped queue keys only (never FLUSHDB), then connections.
  try {
    if (queues) {
      await queues.hibernate.obliterate({ force: true }).catch(() => {});
      await queues.hydrate.obliterate({ force: true }).catch(() => {});
      await queues.agentRuns.close().catch(() => {});
      await queues.hibernate.close().catch(() => {});
      await queues.hydrate.close().catch(() => {});
      await queues.schedules.close().catch(() => {});
    }
    if (app) await app.close().catch(() => {});
    if (redis && createdSids.length > 0) {
      await redis.del(createdSids.map((id) => `sess:${id}:events`)).catch(() => {});
      await redis
        .del(createdSids.map((id) => `${ACTIVITY_KEY_PREFIX}${id}`))
        .catch(() => {});
    }
    redis?.disconnect();
    if (db) await db.$client.end({ timeout: 5 }).catch(() => {});
    if (benchDbName !== null) {
      const admin = createDb(TEST_DATABASE_URL);
      try {
        await admin.$client.unsafe(
          `DROP DATABASE IF EXISTS ${benchDbName} WITH (FORCE)`,
        );
      } finally {
        await admin.$client.end({ timeout: 5 }).catch(() => {});
      }
    }
  } catch (err) {
    console.error("[sla] teardown warning:", err);
  }

  if (results.pass) {
    log("[sla] ALL STAGES PASS");
    process.exit(0);
  } else {
    log("[sla] FAIL — thresholds were NOT relaxed; see the numbers above");
    process.exit(1);
  }
}
