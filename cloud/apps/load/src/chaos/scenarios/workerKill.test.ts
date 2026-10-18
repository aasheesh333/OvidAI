import { describe, expect, it, vi } from "vitest";
import {
  evaluateStagingTarget,
  evaluateWorkerKillGate,
  evaluateWorkerKillOutcome,
  evaluateWorkerProcessIdentity,
  restoreWorkerIfKilled,
  type WorkerKillClientState,
} from "./workerKill.js";

/**
 * Review Focus #3 for worker-kill: every clause is a proven-vulnerable-state
 * check, and the outcome evaluator refuses a vacuous "the process died" pass.
 * Fakes only — the scenario itself never runs against a real stack here.
 */

const held: WorkerKillClientState = {
  runStarted: true,
  deltaSeen: true,
  terminal: false,
};

const healthyGate = {
  clients: [{ ...held }],
  gateReleased: false,
  healthStatus: "ok" as const,
  workerAlive: true,
  targetProblems: [] as string[],
  workerIdentityProblems: [] as string[],
  runStatus: "running",
  // A real staging pidfile yields a pid; null is the unreadable case, which
  // has its own rejection test below.
  workerPid: 4242,
};

describe("evaluateStagingTarget", () => {
  const stagingEnv = {
    STAGING_GATEWAY_URL: "http://127.0.0.1:18082",
    STAGING_WORKER_PIDFILE: "/tmp/opencode/ovid-staging-worker.pid",
  };

  it("accepts a loopback staging gateway and a staging-named pidfile", () => {
    expect(evaluateStagingTarget(stagingEnv)).toEqual([]);
  });

  it("rejects the production API host (never kill a live process)", () => {
    const problems = evaluateStagingTarget({
      ...stagingEnv,
      STAGING_GATEWAY_URL: "https://api.ovidsi.com",
    });
    expect(problems.join(" ")).toContain("production");
  });

  it("rejects a pidfile that is not staging-scoped", () => {
    const problems = evaluateStagingTarget({
      ...stagingEnv,
      STAGING_WORKER_PIDFILE: "/run/ovid-worker.pid",
    });
    expect(problems.join(" ")).toContain("staging");
  });

  it("rejects a non-loopback gateway even when it is not the literal production host", () => {
    const problems = evaluateStagingTarget({
      ...stagingEnv,
      STAGING_GATEWAY_URL: "https://203.0.113.10",
    });
    expect(problems.join(" ")).toContain("loopback");
  });

  it("rejects a missing pidfile or gateway URL", () => {
    expect(evaluateStagingTarget({}).length).toBeGreaterThan(0);
  });
});

describe("evaluateWorkerProcessIdentity (F3 ground truth)", () => {
  it("accepts dist/main.js with an apps/worker cwd", () => {
    expect(
      evaluateWorkerProcessIdentity({
        cmdline: "node dist/main.js",
        cwd: "/root/OvidAI/cloud/apps/worker",
      }),
    ).toEqual([]);
  });

  it("rejects a live pid that is not the worker entrypoint", () => {
    const problems = evaluateWorkerProcessIdentity({
      cmdline: "node /opt/ovid/prod-server.js",
      cwd: "/root/OvidAI/cloud/apps/worker",
    });
    expect(problems.join(" ")).toContain("dist/main.js");
  });

  it("rejects a worker entrypoint running outside an apps/worker checkout", () => {
    const problems = evaluateWorkerProcessIdentity({
      cmdline: "node dist/main.js",
      cwd: "/opt/ovid/prod/apps/gateway",
    });
    expect(problems.join(" ")).toContain("apps/worker");
  });

  it("rejects an unreadable /proc entry (the pid is gone)", () => {
    expect(evaluateWorkerProcessIdentity(null).length).toBeGreaterThan(0);
  });
});

describe("evaluateWorkerKillGate", () => {
  it("passes with a gated run in flight, worker alive, and a staging target", () => {
    expect(evaluateWorkerKillGate(healthyGate).ok).toBe(true);
  });

  it("rejects an unreadable staging pidfile — no proven kill target", () => {
    const result = evaluateWorkerKillGate({ ...healthyGate, workerPid: null });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("pidfile");
  });

  it("rejects a run that has not started", () => {
    const result = evaluateWorkerKillGate({
      ...healthyGate,
      clients: [{ ...held, runStarted: false }],
    });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("run_started");
  });

  it("rejects a run that never streamed a delta", () => {
    expect(
      evaluateWorkerKillGate({
        ...healthyGate,
        clients: [{ ...held, deltaSeen: false }],
      }).ok,
    ).toBe(false);
  });

  it("rejects a run that already reached a terminal event (the vacuous kill)", () => {
    const result = evaluateWorkerKillGate({
      ...healthyGate,
      clients: [{ ...held, terminal: true }],
    });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("terminal");
  });

  it("rejects a released mock gate", () => {
    expect(
      evaluateWorkerKillGate({ ...healthyGate, gateReleased: true }).ok,
    ).toBe(false);
  });

  it("rejects a dead worker before the kill", () => {
    expect(
      evaluateWorkerKillGate({ ...healthyGate, workerAlive: false }).ok,
    ).toBe(false);
  });

  it("rejects a non-staging target", () => {
    const result = evaluateWorkerKillGate({
      ...healthyGate,
      targetProblems: ["production gateway host"],
    });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("production");
  });

  it("rejects a pid that is not the staging worker (stale/reused pidfile)", () => {
    const result = evaluateWorkerKillGate({
      ...healthyGate,
      workerIdentityProblems: ["pid cmdline 'node other.js' is not the staging worker"],
    });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("staging worker");
  });

  it("rejects a held run that is not running at kill time", () => {
    const result = evaluateWorkerKillGate({
      ...healthyGate,
      runStatus: "failed",
    });
    expect(result.ok).toBe(false);
    expect(result.detail).toContain("running");
  });
});

describe("evaluateWorkerKillOutcome", () => {
  const recovered = {
    stayedDeadMs: 20_000,
    requiredDeadMs: 20_000,
    runLostSeen: true,
    runLostCode: "run_lost",
    runLostAfterRestart: true,
    recoveryMs: 42_000,
    recoveryBudgetMs: 95_000,
    runRowStatus: "failed",
    runFailedEventsInStream: 1,
    runFailedEventsInMirror: 1,
    freshRunCompleted: true,
    workerAlive: true,
  };

  function assertion(state: typeof recovered, name: string) {
    return evaluateWorkerKillOutcome(state).find((entry) => entry.name === name);
  }

  it("passes the full recovery path", () => {
    const assertions = evaluateWorkerKillOutcome(recovered);
    expect(assertions.every((entry) => entry.passed)).toBe(true);
  });

  it("fails when the worker did not stay dead for the window", () => {
    expect(
      assertion({ ...recovered, stayedDeadMs: 3_000 }, "worker-stays-dead")?.passed,
    ).toBe(false);
  });

  it("fails when the client never saw run_lost (the vacuous recovery)", () => {
    expect(
      assertion({ ...recovered, runLostSeen: false }, "run-lost-emitted")?.passed,
    ).toBe(false);
  });

  it("fails when run_failed carries a different code", () => {
    expect(
      assertion({ ...recovered, runLostCode: "run_failed_other" }, "run-lost-emitted")
        ?.passed,
    ).toBe(false);
  });

  it("fails when recovery exceeds the stale+sweep+slack budget", () => {
    expect(
      assertion({ ...recovered, recoveryMs: 120_000 }, "run-lost-within-budget")?.passed,
    ).toBe(false);
  });

  it("fails when run_lost was emitted before the restart (pre-restart sweeper)", () => {
    expect(
      assertion(
        { ...recovered, runLostAfterRestart: false, recoveryMs: -1_000 },
        "run-lost-within-budget",
      )?.passed,
    ).toBe(false);
  });

  it("fails when the run row is still running", () => {
    expect(
      assertion({ ...recovered, runRowStatus: "running" }, "run-row-failed")?.passed,
    ).toBe(false);
  });

  it("fails when run_failed was emitted twice (claim-then-emit regression)", () => {
    expect(
      assertion(
        { ...recovered, runFailedEventsInStream: 2 },
        "exactly-one-run-failed",
      )?.passed,
    ).toBe(false);
    expect(
      assertion(
        { ...recovered, runFailedEventsInMirror: 0 },
        "exactly-one-run-failed",
      )?.passed,
    ).toBe(false);
  });

  it("fails when a fresh run cannot complete after the restart", () => {
    expect(
      assertion({ ...recovered, freshRunCompleted: false }, "fresh-run-completes")
        ?.passed,
    ).toBe(false);
  });

  it("fails when the restarted worker is not alive", () => {
    expect(
      assertion({ ...recovered, workerAlive: false }, "worker-restarted")?.passed,
    ).toBe(false);
  });
});

describe("restoreWorkerIfKilled (F7)", () => {
  it("does nothing when the scenario never killed the worker", async () => {
    const workerAlive = vi.fn(async () => false);
    const workerStart = vi.fn(async () => {});
    await restoreWorkerIfKilled({ workerAlive, workerStart }, false);
    expect(workerStart).not.toHaveBeenCalled();
  });

  it("starts the worker when inject threw after the kill", async () => {
    const workerAlive = vi.fn(async () => false);
    const workerStart = vi.fn(async () => {});
    await restoreWorkerIfKilled({ workerAlive, workerStart }, true);
    expect(workerStart).toHaveBeenCalledWith({
      OVID_RUN_STALE_MS: "15000",
    });
  });

  it("does not restart an already-live worker", async () => {
    const workerAlive = vi.fn(async () => true);
    const workerStart = vi.fn(async () => {});
    await restoreWorkerIfKilled({ workerAlive, workerStart }, true);
    expect(workerStart).not.toHaveBeenCalled();
  });
});
