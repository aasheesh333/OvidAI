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
import { realpathSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { Redis } from "ioredis";
import { createDb } from "@ovid/db";
import {
  CANARY_ROLES,
  redisStreamsCorpus,
  runCanarySweep,
  sessionMirrorCorpus,
  type CanaryCorpus,
  type RedisStreamReader,
} from "./canarySweep.js";

interface CliOptions {
  capturesDir: string;
  logFiles: string[];
  databaseUrl: string | null;
  redisUrl: string | null;
  command: string[];
}

function usage(): string {
  return [
    "usage: canaryCli.js [--captures-dir <dir>] [--log <file>]...",
    "                    [--database-url <postgres url>] [--redis-url <redis url>]",
    "                    -- <command> [args...]",
    "",
    "Injects one sk-CANARY-<uuid> per secret role (master key, BYOK key,",
    "mint key, redis password, DB password), tees stdout/stderr, and greps the",
    "captures, --log files, session_event_mirror rows (--database-url) and raw",
    "sess:*:events XRANGE payloads (--redis-url). Exit 0 only when the workload",
    "succeeds with zero leaks.",
  ].join("\n");
}

function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = {
    capturesDir: resolve(process.cwd(), "canary-captures"),
    logFiles: [],
    databaseUrl: null,
    redisUrl: null,
    command: [],
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
      default:
        throw new Error(`canaryCli: unknown argument ${arg}\n${usage()}`);
    }
  }
  options.command = argv.slice(index);
  if (options.command.length === 0) {
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

export async function runCanaryCli(argv: string[]): Promise<number> {
  const options = parseArgs(argv);
  await mkdir(options.capturesDir, { recursive: true });
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
      env: Object.fromEntries(
        Object.entries(process.env).filter(
          (entry): entry is [string, string] => entry[1] !== undefined,
        ),
      ),
      captures: [stdoutCapture, stderrCapture],
      logFiles: options.logFiles,
      corpora,
      run: async (env) => {
        exitCode = await spawnCommand(options.command[0]!, options.command.slice(1), env);
      },
    });

    console.log(`canary-sweep: scanned ${result.scanned} corpus location(s)`);
    console.log(`canary-sweep: workload exit=${exitCode}`);
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
