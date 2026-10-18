/**
 * P10 Task 10 — canary sweep CLI.
 *
 * Wraps an arbitrary command (the @ovid/e2e suite, a smoke10 load run, …) with
 * canary secrets injected into its environment, tees stdout/stderr, and greps
 * the captures plus any `--log` files.
 *
 *   node apps/load/dist/canaryCli.js \
 *     --captures-dir /tmp/ovid-canary \
 *     --log /tmp/ovid-canary/gateway.log \
 *     -- pnpm --filter @ovid/e2e test
 *
 * Exit codes: 0 = workload succeeded and zero leaks; 1 = leaks and/or a
 * non-zero workload exit. A failed workload is never reported as a pass.
 */

import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync, realpathSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Redis } from "ioredis";
import { createDb } from "@ovid/db";
import {
  CANARY_ROLES,
  byokKeysCorpus,
  createCanarySet,
  redisStreamsCorpus,
  runCanarySweep,
  sessionMirrorCorpus,
  type CanaryCorpus,
  type CanarySet,
  type RedisStreamReader,
} from "./canarySweep.js";

interface CliOptions {
  capturesDir: string;
  logFiles: string[];
  databaseUrl: string | null;
  redisUrl: string | null;
  command: string[];
  /** Provision isolated services and drive the shipped stack composition. */
  inProcessStack: boolean;
  /** A requested-but-unreadable corpus fails the run. */
  strict: boolean;
  /** Where the in-process stack test writes its proof JSON. */
  stackProofPath: string | null;
}

function usage(): string {
  return [
    "usage: canaryCli.js [--captures-dir <dir>] [--log <file>]... [--strict]",
    "                    [--database-url <postgres url>] [--redis-url <redis url>]",
    "                    [--in-process-stack [--stack-proof <file>]]",
    "                    -- <command> [args...]",
    "",
    "Injects one canary per secret role (master key, BYOK key, mint key,",
    "redis password, DB password, LiteLLM key), tees stdout/stderr, and greps",
    "the captures, --log files, session_event_mirror rows (--database-url), raw",
    "sess:*:events XRANGE payloads (--redis-url) and byok_keys rows.",
    "",
    "  --strict                 a requested corpus that cannot be read fails",
    "  --in-process-stack       provision an isolated Postgres database + Redis",
    "                           ACL user whose passwords are canaries, then run",
    "                           the shipped gateway/worker composition with",
    "                           DATABASE_URL/REDIS_Q_URL/OVID_MASTER_KEY/etc.",
    "                           set to canary values. --database-url and",
    "                           --redis-url must be ADMIN urls for disposable",
    "                           services (no command after --).",
    "",
    "Exit 0 only when the workload succeeds with zero leaks and (strict) every",
    "requested corpus was actually read.",
  ].join("\n");
}

function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = {
    capturesDir: resolve(process.cwd(), "canary-captures"),
    logFiles: [],
    databaseUrl: null,
    redisUrl: null,
    command: [],
    inProcessStack: false,
    strict: false,
    stackProofPath: null,
  };
  let index = 0;
  for (; index < argv.length; index += 1) {
    const arg = argv[index]!;
    if (arg === "--") {
      index += 1;
      break;
    }
    if (arg === "--help" || arg === "-h") {
      console.log(usage());
      process.exit(0);
    }
    if (arg === "--in-process-stack") {
      options.inProcessStack = true;
      continue;
    }
    if (arg === "--strict") {
      options.strict = true;
      continue;
    }
    const value = argv[index + 1];
    if (value === undefined) throw new Error(`canaryCli: missing value for ${arg}`);
    switch (arg) {
      case "--captures-dir":
        options.capturesDir = resolve(process.cwd(), value);
        index += 1;
        break;
      case "--log":
        options.logFiles.push(resolve(process.cwd(), value));
        index += 1;
        break;
      case "--database-url":
        options.databaseUrl = value;
        index += 1;
        break;
      case "--redis-url":
        options.redisUrl = value;
        index += 1;
        break;
      case "--stack-proof":
        options.stackProofPath = resolve(process.cwd(), value);
        index += 1;
        break;
      default:
        throw new Error(`canaryCli: unknown argument ${arg}\n${usage()}`);
    }
  }
  options.command = argv.slice(index);
  if (options.inProcessStack) {
    if (options.databaseUrl === null || options.redisUrl === null) {
      throw new Error(
        `canaryCli: --in-process-stack requires --database-url and --redis-url (admin URLs)\n${usage()}`,
      );
    }
    if (options.command.length > 0) {
      throw new Error(
        `canaryCli: --in-process-stack drives its own composition; no command after --\n${usage()}`,
      );
    }
  } else if (options.command.length === 0) {
    throw new Error(`canaryCli: missing command after --\n${usage()}`);
  }
  return options;
}

function spawnCommand(
  command: string,
  args: string[],
  env: Record<string, string>,
): Promise<number> {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, {
      env,
      stdio: ["inherit", "pipe", "pipe"],
    });
    // Piping through the patched process streams is what tees the child's
    // output into the capture files installed by runCanarySweep.
    child.stdout.pipe(process.stdout);
    child.stderr.pipe(process.stderr);
    child.on("error", reject);
    child.on("close", (code, signal) => {
      if (signal !== null) {
        console.error(`canary-sweep: workload killed by signal ${signal}`);
        resolvePromise(1);
        return;
      }
      resolvePromise(code ?? 1);
    });
  });
}

function envFromProcess(): Record<string, string> {
  return Object.fromEntries(
    Object.entries(process.env).filter(
      (entry): entry is [string, string] => entry[1] !== undefined,
    ),
  );
}

function sqlLiteral(value: string): string {
  return value.replace(/'/g, "''");
}

async function dropDatabaseAndRole(
  adminDatabaseUrl: string,
  database: string,
  role: string,
): Promise<void> {
  const admin = createDb(adminDatabaseUrl);
  try {
    await admin.$client.unsafe(`DROP DATABASE IF EXISTS "${database}" WITH (FORCE)`);
    await admin.$client.unsafe(`DROP ROLE IF EXISTS "${role}"`);
  } finally {
    await admin.$client.end({ timeout: 5 });
  }
}

async function scanKeys(redis: Redis, match: string): Promise<string[]> {
  const keys: string[] = [];
  let cursor = "0";
  do {
    const [next, batch] = await redis.scan(cursor, "MATCH", match, "COUNT", 200);
    cursor = next;
    keys.push(...batch);
  } while (cursor !== "0");
  return keys;
}

/**
 * The isolated services for one sweep run. The canary passwords are REAL
 * credentials: the Postgres role can only log in with the canary DB password,
 * and the Redis ACL user can only authenticate with the canary Redis password.
 * The stack therefore cannot accidentally run with the admin credentials.
 */
interface IsolatedStack {
  role: string;
  database: string;
  redisUser: string;
  redisDb: number;
  databaseUrl: string;
  redisUrl: string;
  adminRedis: Redis;
  cleanup(proof: StackProof | null, queuePrefix: string): Promise<void>;
}

async function provisionStack(
  adminDatabaseUrl: string,
  adminRedisUrl: string,
  canaries: CanarySet,
): Promise<IsolatedStack> {
  const suffix = randomUUID().replace(/-/g, "").slice(0, 10);
  const role = `ovid_canary_${suffix}`;
  const database = `ovid_canary_${suffix}`;
  const redisUser = `ovid_canary_${suffix}`;
  // A dedicated Redis DB index; never FLUSHDB. The dev server is shared, so
  // cleanup deletes only keys attributable to this run (see deleteStackKeys).
  const redisDb = 1 + (parseInt(suffix.slice(0, 4), 16) % 15);

  const adminDb = createDb(adminDatabaseUrl);
  try {
    await adminDb.$client.unsafe(
      `CREATE ROLE "${role}" LOGIN PASSWORD '${sqlLiteral(canaries.dbPassword)}'`,
    );
    await adminDb.$client.unsafe(`CREATE DATABASE "${database}" OWNER "${role}"`);
  } catch (err) {
    await adminDb.$client
      .unsafe(`DROP DATABASE IF EXISTS "${database}" WITH (FORCE)`)
      .catch(() => {});
    await adminDb.$client.unsafe(`DROP ROLE IF EXISTS "${role}"`).catch(() => {});
    throw err;
  } finally {
    await adminDb.$client.end({ timeout: 5 });
  }

  const adminRedis = new Redis(adminRedisUrl);
  try {
    await adminRedis.call(
      "ACL",
      "SETUSER",
      redisUser,
      "reset",
      "on",
      `>${canaries.redisPassword}`,
      "~*",
      "&*",
      "+@all",
    );
    await adminRedis.select(redisDb);
  } catch (err) {
    adminRedis.disconnect();
    await dropDatabaseAndRole(adminDatabaseUrl, database, role).catch(() => {});
    throw err;
  }

  const databaseUrl = new URL(adminDatabaseUrl);
  databaseUrl.username = role;
  databaseUrl.password = canaries.dbPassword;
  databaseUrl.pathname = `/${database}`;

  const redisUrl = new URL(adminRedisUrl);
  redisUrl.username = redisUser;
  redisUrl.password = canaries.redisPassword;
  redisUrl.pathname = `/${redisDb}`;

  return {
    role,
    database,
    redisUser,
    redisDb,
    databaseUrl: databaseUrl.toString(),
    redisUrl: redisUrl.toString(),
    adminRedis,
    async cleanup(proof, queuePrefix) {
      try {
        await deleteStackKeys(adminRedis, canaries, proof, queuePrefix);
      } catch {
        // Best effort: a failed key delete must not block the DB/role drop.
      }
      try {
        await adminRedis.call("ACL", "DELUSER", redisUser);
      } catch {
        // The server may have been restarted; the run is over either way.
      }
      adminRedis.disconnect();
      await dropDatabaseAndRole(adminDatabaseUrl, database, role);
    },
  };
}

/**
 * Delete only keys this run created. Never FLUSHDB: the Redis server is
 * shared with the dev stack and other suites.
 */
async function deleteStackKeys(
  redis: Redis,
  canaries: CanarySet,
  proof: StackProof | null,
  queuePrefix: string,
): Promise<void> {
  const keys = new Set<string>();
  if (proof !== null) {
    keys.add(`sess:${proof.sessionId}:events`);
    keys.add(`sess:${proof.sessionId}:live`);
    keys.add(`user:${proof.uid}:key`);
    for (const key of await scanKeys(redis, `sess:${proof.sessionId}:*`)) keys.add(key);
  } else {
    // No proof (the workload failed): delete only event streams that
    // demonstrably carry OUR throwaway canaries.
    for (const key of await scanKeys(redis, "sess:*:events")) {
      const entries = JSON.stringify(await redis.xrange(key, "-", "+"));
      if (CANARY_ROLES.some((role) => entries.includes(canaries[role]))) keys.add(key);
    }
  }
  for (const key of await scanKeys(redis, `*${queuePrefix}*`)) keys.add(key);
  if (keys.size > 0) await redis.del([...keys]);
}

interface StackProof {
  sessionId: string;
  uid: string;
  runId: string;
  byokId: string;
  terminalEvent: string;
  eventCount: number;
  mirrorRows: number;
  byokRows: number;
}

function readStackProof(path: string): StackProof {
  const parsed = JSON.parse(readFileSync(path, "utf8")) as Partial<StackProof>;
  for (const field of ["sessionId", "uid", "runId", "byokId", "terminalEvent"] as const) {
    if (typeof parsed[field] !== "string" || parsed[field] === "") {
      throw new Error(`canary stack proof ${path} is missing ${field}`);
    }
  }
  return parsed as StackProof;
}

/**
 * Independently prove the workload was not empty: the run row is completed,
 * the BYOK row exists, the DB mirror was written, and the Redis stream exists.
 * A canary sweep that "passed" over an empty database is a false green.
 */
async function verifyStackProof(
  proof: StackProof,
  databaseUrl: string,
  redis: Redis,
): Promise<{ mirrorRows: number; streamKeys: number }> {
  const db = createDb(databaseUrl);
  try {
    const runs = (await db.$client`
      SELECT status FROM runs WHERE id = ${proof.runId}
    `) as Array<{ status: string }>;
    if (runs.length !== 1 || runs[0]!.status !== "completed") {
      throw new Error(
        `canary stack run ${proof.runId} did not complete (status ${runs[0]?.status ?? "missing"})`,
      );
    }
    const byok = (await db.$client`
      SELECT id FROM byok_keys WHERE id = ${proof.byokId}
    `) as Array<{ id: string }>;
    if (byok.length !== 1) {
      throw new Error(`canary stack BYOK row ${proof.byokId} is missing`);
    }
    const [mirror] = (await db.$client`
      SELECT count(*)::int AS n FROM session_event_mirror WHERE session_id = ${proof.sessionId}
    `) as Array<{ n: number }>;
    if ((mirror?.n ?? 0) < 1) {
      throw new Error("canary stack wrote no session_event_mirror rows");
    }
    const streamKeys = await scanKeys(redis, `sess:${proof.sessionId}:events`);
    if (streamKeys.length === 0) {
      throw new Error("canary stack wrote no sess:*:events stream");
    }
    return { mirrorRows: mirror!.n, streamKeys: streamKeys.length };
  } finally {
    await db.$client.end({ timeout: 5 });
  }
}

async function runInProcessStackCli(options: CliOptions): Promise<number> {
  const canaries = createCanarySet();
  const stdoutCapture = join(options.capturesDir, "stdout.log");
  const stderrCapture = join(options.capturesDir, "stderr.log");
  const proofPath =
    options.stackProofPath ?? join(options.capturesDir, "stack-proof.json");
  const queuePrefix = `ovid-canary-${randomUUID().replace(/-/g, "").slice(0, 12)}`;

  const stack = await provisionStack(
    options.databaseUrl!,
    options.redisUrl!,
    canaries,
  );
  let scanDb: ReturnType<typeof createDb> | null = null;

  console.log(
    `canary-sweep: in-process stack: database=${stack.database} redis-db=${stack.redisDb}`,
  );
  console.log(
    `canary-sweep: injecting ${CANARY_ROLES.length} canaries (${CANARY_ROLES.join(", ")})`,
  );
  console.log(
    "canary-sweep: DATABASE_URL/REDIS_Q_URL carry canary passwords; " +
      "OVID_MASTER_KEY/OVID_INTERNAL_API_SECRET/LITELLM_MASTER_KEY are canaries",
  );

  let proof: StackProof | null = null;
  let exitCode = 1;
  try {
    scanDb = createDb(stack.databaseUrl);
    const scanClient = scanDb.$client;
    const result = await runCanarySweep({
      canaries,
      env: {
        ...envFromProcess(),
        DATABASE_URL: stack.databaseUrl,
        REDIS_Q_URL: stack.redisUrl,
        OVID_CANARY_STACK: "1",
        OVID_CANARY_PROOF_FILE: proofPath,
        OVID_CANARY_BYOK_KEY: canaries.byokKey,
        OVID_CANARY_QUEUE_PREFIX: queuePrefix,
      },
      captures: [stdoutCapture, stderrCapture],
      logFiles: options.logFiles,
      corpora: [
        sessionMirrorCorpus(async (sqlText) => {
          const rows = await scanClient.unsafe(sqlText);
          return rows as unknown as Array<Record<string, unknown>>;
        }),
        redisStreamsCorpus(stack.adminRedis as unknown as RedisStreamReader),
        byokKeysCorpus(async (sqlText) => {
          const rows = await scanClient.unsafe(sqlText);
          return rows as unknown as Array<Record<string, unknown>>;
        }),
      ],
      run: async (env) => {
        console.log(
          "canary-sweep: workload: shipped gateway + worker stack (e2e canary-stack test)",
        );
        exitCode = await spawnCommand(
          "pnpm",
          [
            "--filter",
            "@ovid/e2e",
            "exec",
            "vitest",
            "run",
            "src/security/canary-stack.test.ts",
          ],
          env,
        );
        if (exitCode !== 0) return;
        proof = readStackProof(proofPath);
        const verified = await verifyStackProof(
          proof,
          stack.databaseUrl,
          stack.adminRedis,
        );
        console.log(
          `canary-sweep: proof: run=${proof.runId} terminal=${proof.terminalEvent} ` +
            `byok=${proof.byokId} mirror=${verified.mirrorRows} streams=${verified.streamKeys}`,
        );
      },
    });

    console.log(`canary-sweep: scanned ${result.scanned} corpus location(s)`);
    console.log(`canary-sweep: workload exit=${exitCode}`);
    for (const location of result.missing) {
      console.error(`canary-sweep: MISSING ${location}`);
    }
    if (result.leaks.length > 0) {
      for (const leak of result.leaks) {
        console.error(`canary-sweep: LEAK ${leak.canary} at ${leak.where}`);
      }
      console.error(`canary-sweep: FAIL — ${result.leaks.length} leak(s)`);
      return 1;
    }
    if (exitCode !== 0) {
      console.error("canary-sweep: FAIL — workload failed (no leaks detected)");
      return 1;
    }
    if (result.missing.length > 0) {
      console.error(
        `canary-sweep: FAIL — ${result.missing.length} requested corpus location(s) missing`,
      );
      return 1;
    }
    console.log("canary-sweep: PASS — zero leaks");
    return 0;
  } finally {
    await scanDb?.$client.end({ timeout: 5 }).catch(() => {});
    await stack.cleanup(proof, queuePrefix).catch((err: unknown) => {
      console.error(
        `canary-sweep: cleanup failed: ${err instanceof Error ? err.message : String(err)}`,
      );
    });
  }
}

export async function runCanaryCli(argv: string[]): Promise<number> {
  const options = parseArgs(argv);
  await mkdir(options.capturesDir, { recursive: true });
  if (options.inProcessStack) return runInProcessStackCli(options);

  const stdoutCapture = join(options.capturesDir, "stdout.log");
  const stderrCapture = join(options.capturesDir, "stderr.log");

  // Extra corpora are opened lazily and closed after the scan. Neither is
  // needed when the flags are absent (local load smoke has no stack).
  const corpora: CanaryCorpus[] = [];
  let db: ReturnType<typeof createDb> | null = null;
  let redis: Redis | null = null;
  if (options.databaseUrl !== null) {
    db = createDb(options.databaseUrl);
    const client = db.$client;
    corpora.push(
      sessionMirrorCorpus(async (sqlText) => {
        const rows = await client.unsafe(sqlText);
        return rows as unknown as Array<Record<string, unknown>>;
      }),
      byokKeysCorpus(async (sqlText) => {
        const rows = await client.unsafe(sqlText);
        return rows as unknown as Array<Record<string, unknown>>;
      }),
    );
  }
  if (options.redisUrl !== null) {
    redis = new Redis(options.redisUrl);
    // ioredis' overloaded `scan` is structurally narrower than the sweep's
    // minimal reader shape; the runtime contract (SCAN + XRANGE) is identical.
    corpora.push(redisStreamsCorpus(redis as unknown as RedisStreamReader));
  }

  console.log(
    `canary-sweep: injecting ${CANARY_ROLES.length} canaries (${CANARY_ROLES.join(", ")})`,
  );
  console.log(`canary-sweep: workload: ${options.command.join(" ")}`);

  let exitCode = 1;
  try {
    const result = await runCanarySweep({
      env: envFromProcess(),
      captures: [stdoutCapture, stderrCapture],
      logFiles: options.logFiles,
      corpora,
      run: async (env) => {
        exitCode = await spawnCommand(options.command[0]!, options.command.slice(1), env);
      },
    });

    console.log(`canary-sweep: scanned ${result.scanned} corpus location(s)`);
    console.log(`canary-sweep: workload exit=${exitCode}`);
    for (const location of result.missing) {
      console.error(`canary-sweep: MISSING ${location}`);
    }
    if (result.leaks.length > 0) {
      for (const leak of result.leaks) {
        console.error(`canary-sweep: LEAK ${leak.canary} at ${leak.where}`);
      }
      console.error(`canary-sweep: FAIL — ${result.leaks.length} leak(s)`);
      return 1;
    }
    if (exitCode !== 0) {
      console.error("canary-sweep: FAIL — workload failed (no leaks detected)");
      return 1;
    }
    if (options.strict && result.missing.length > 0) {
      console.error(
        `canary-sweep: FAIL — ${result.missing.length} requested corpus location(s) missing`,
      );
      return 1;
    }
    if (options.strict && result.scanned === 0) {
      console.error("canary-sweep: FAIL — strict mode scanned no corpus location");
      return 1;
    }
    if (!options.strict && result.missing.length > 0) {
      console.error(
        `canary-sweep: WARN — ${result.missing.length} requested corpus location(s) missing (use --strict to fail)`,
      );
    }
    console.log("canary-sweep: PASS — zero leaks");
    return 0;
  } finally {
    if (redis !== null) redis.disconnect();
    if (db !== null) await db.$client.end({ timeout: 5 });
  }
}

const invokedPath = process.argv[1];
function isDirectInvocation(): boolean {
  if (invokedPath === undefined) return false;
  try {
    return realpathSync(invokedPath) === fileURLToPath(import.meta.url);
  } catch {
    return false;
  }
}

if (isDirectInvocation()) {
  runCanaryCli(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (err: unknown) => {
      console.error(`canaryCli: ${err instanceof Error ? err.message : String(err)}`);
      process.exit(2);
    },
  );
}
