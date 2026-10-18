import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { runCanaryCli } from "./canaryCli.js";
import { CanaryCorpusMissingError, runCanarySweep } from "./canarySweep.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;

/**
 * P10 Task 10 — canary leak sweep.
 *
 * The sweep's job is narrow and mechanical: inject `sk-CANARY-<uuid>` values
 * into the workload environment, run it with stdout/stderr teed to capture
 * files, then grep every configured corpus. A canary occurrence is a leak;
 * silence is only a pass when a corpus was actually scanned.
 */

const tempDirs: string[] = [];

async function capturePaths(): Promise<{ dir: string; stdout: string; stderr: string }> {
  const dir = await mkdtemp(join(tmpdir(), "ovid-canary-"));
  tempDirs.push(dir);
  return { dir, stdout: join(dir, "stdout.log"), stderr: join(dir, "stderr.log") };
}

afterEach(async () => {
  while (tempDirs.length > 0) {
    await rm(tempDirs.pop()!, { recursive: true, force: true });
  }
});

describe("runCanarySweep", () => {
  it("detects a planted leak", async () => {
    const paths = await capturePaths();
    let injected = "";

    const result = await runCanarySweep({
      captures: [paths.stdout, paths.stderr],
      run: async (env) => {
        injected = env.OVID_MASTER_KEY!;
        process.stdout.write(`debug: master key is ${injected}\n`);
      },
    });

    expect(injected).toMatch(/^c0de[0-9a-f]{60}$/);
    expect(result.leaks).toEqual([
      { canary: injected, where: `capture:${paths.stdout}` },
    ]);
    // The capture is a real tee: the workload's output is preserved.
    expect(await readFile(paths.stdout, "utf8")).toContain(injected);
    expect(result.missing).toEqual([]);
  });

  it("injects every role under a REAL service config name (no invented canary vars)", async () => {
    const paths = await capturePaths();
    let seen: Record<string, string> = {};

    const result = await runCanarySweep({
      captures: [paths.stdout, paths.stderr],
      run: async (env) => {
        seen = env;
      },
    });

    // Standalone variables the shipped gateway/worker/mint read.
    expect(seen.OVID_MASTER_KEY).toBe(result.canaries.masterKey);
    expect(seen.OVID_INTERNAL_API_SECRET).toBe(result.canaries.mintKey);
    expect(seen.LITELLM_MASTER_KEY).toBe(result.canaries.litellmKey);
    expect(seen.OVID_LITELLM_MASTER_KEY).toBe(result.canaries.litellmKey);
    // The master key canary satisfies the shipped 64-hex validator.
    expect(seen.OVID_MASTER_KEY).toMatch(/^[0-9a-f]{64}$/);
    // The roles without a standalone config var must NOT invent one.
    expect(seen).not.toHaveProperty("OVID_CANARY_BYOK_KEY");
    expect(seen).not.toHaveProperty("OVID_CANARY_MINT_KEY");
    expect(seen).not.toHaveProperty("OVID_CANARY_DB_PASSWORD");
    expect(seen).not.toHaveProperty("REDIS_PASSWORD");
  });

  it("clean workload reports zero", async () => {
    const paths = await capturePaths();

    const result = await runCanarySweep({
      captures: [paths.stdout, paths.stderr],
      run: async () => {
        process.stdout.write("run completed: 3 events, 0 failures\n");
        process.stderr.write("warning: nothing to report\n");
      },
    });

    expect(result.leaks).toEqual([]);
    expect(result.missing).toEqual([]);
    expect(result.scanned).toBeGreaterThanOrEqual(2);
  });

  it("strict mode fails when a requested log corpus is missing", async () => {
    const paths = await capturePaths();
    const missingLog = join(paths.dir, "DOES-NOT-EXIST.log");

    // Non-strict: reported, not fatal (the CLI decides).
    const relaxed = await runCanarySweep({
      captures: [paths.stdout, paths.stderr],
      logFiles: [missingLog],
      run: async () => {},
    });
    expect(relaxed.missing).toEqual([`log:${missingLog}`]);

    // Strict: a scan that never looked at a requested surface is a failure.
    await expect(
      runCanarySweep({
        captures: [paths.stdout, paths.stderr],
        logFiles: [missingLog],
        strict: true,
        run: async () => {},
      }),
    ).rejects.toBeInstanceOf(CanaryCorpusMissingError);
  });

  it("greps extra corpora and log files with their location", async () => {
    const paths = await capturePaths();
    const logPath = join(paths.dir, "gateway.log");
    const { writeFile } = await import("node:fs/promises");
    let injected = "";

    const result = await runCanarySweep({
      captures: [paths.stdout, paths.stderr],
      logFiles: [logPath],
      corpora: [
        {
          where: "session_event_mirror",
          read: () => `{"payload":{"text":"leaked ${injected}"}}`,
        },
      ],
      run: async (env) => {
        injected = env.OVID_MASTER_KEY!;
        await writeFile(logPath, `worker boot key=${injected}\n`, "utf8");
      },
    });

    expect(result.leaks).toEqual([
      { canary: injected, where: `log:${logPath}` },
      { canary: injected, where: "session_event_mirror" },
    ]);
    expect(result.missing).toEqual([]);
  });

  it.skipIf(TEST_DATABASE_URL === undefined || TEST_REDIS_URL === undefined)(
    "in-process stack mode drives the shipped gateway/worker with canary config",
    async () => {
      const dir = await mkdtemp(join(tmpdir(), "ovid-canary-stack-"));
      tempDirs.push(dir);

      const code = await runCanaryCli([
        "--in-process-stack",
        "--captures-dir",
        dir,
        "--database-url",
        TEST_DATABASE_URL!,
        "--redis-url",
        TEST_REDIS_URL!,
      ]);

      const stdout = await readFile(join(dir, "stdout.log"), "utf8");
      const stderr = await readFile(join(dir, "stderr.log"), "utf8");
      expect(code, `stdout:\n${stdout}\nstderr:\n${stderr}`).toBe(0);
      // The capture is the CHILD stack test's output (the CLI's own PASS line
      // is printed after the tee is restored). The proof file is the
      // authoritative evidence that the workload was non-empty.
      expect(stdout).toContain("src/security/canary-stack.test.ts");
      expect(stdout).toContain("1 passed");
      const proof = JSON.parse(
        await readFile(join(dir, "stack-proof.json"), "utf8"),
      ) as {
        terminalEvent: string;
        runId: string;
        byokId: string;
        mirrorRows: number;
      };
      expect(proof.terminalEvent).toBe("run_completed");
      expect(proof.runId).not.toBe("");
      expect(proof.byokId).not.toBe("");
      expect(proof.mirrorRows).toBeGreaterThan(0);
    },
    180_000,
  );
});
