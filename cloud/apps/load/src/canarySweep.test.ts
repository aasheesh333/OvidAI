import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { runCanarySweep } from "./canarySweep.js";

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

    expect(injected).toMatch(/^sk-CANARY-[0-9a-f-]{36}$/);
    expect(result.leaks).toEqual([
      { canary: injected, where: `capture:${paths.stdout}` },
    ]);
    // The capture is a real tee: the workload's output is preserved.
    expect(await readFile(paths.stdout, "utf8")).toContain(injected);
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
    expect(result.scanned).toBeGreaterThanOrEqual(2);
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
  });
});
