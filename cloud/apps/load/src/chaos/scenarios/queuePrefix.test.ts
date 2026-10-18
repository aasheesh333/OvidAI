import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { createQueues } from "@ovid/queue";
import {
  STAGING_QUEUE_PREFIX,
  createScenarioQueues,
} from "./redisQRestart.js";

/**
 * H2: redis-q-restart must read the SAME queue keys the staging gateway and
 * worker write. Both mains call `createQueues`/`createAgentRunsWorker` with no
 * `prefix`, so BullMQ's default `"bull"` applies. `.env.staging` records
 * `BULL_PREFIX=bull` to match; it once said `bull:staging`, which made tooling
 * inspect an empty `bull:staging:agent-runs` (staging is isolated by its own
 * redis-q instance, not by the prefix).
 *
 * This test pins the derivation against the mains' real source calls (a future
 * `prefix` threading change fails here) and against BullMQ's actual default.
 */

const here = dirname(fileURLToPath(import.meta.url));
const gatewayMainPath = resolve(here, "../../../../gateway/src/index.ts");
const workerMainPath = resolve(here, "../../../../worker/src/main.ts");

describe("redis-q queue prefix matches the running stack (H2)", () => {
  it("the gateway and worker mains construct agent-runs with NO prefix", () => {
    const gateway = readFileSync(gatewayMainPath, "utf8");
    const worker = readFileSync(workerMainPath, "utf8");

    // The calls the scenario derives from must still exist in this shape.
    expect(gateway).toMatch(
      /createQueues\(\{ url: cfg\.redisQUrl \}, \{ withPluginInstalls: true \}\)/,
    );
    expect(worker).toMatch(/createQueues\(\s*\{ url: cfg\.redisQUrl \},/);
    // The call may carry trailing OPTIONS (the concurrency unlock added a
    // per-run `{ concurrency }` third argument); the shape that matters is
    // the connection object plus the processor, with no `prefix`.
    expect(worker).toMatch(
      /createAgentRunsWorker\(\s*\{ url: cfg\.redisQUrl \},\s*processor,/,
    );

    // A `prefix` in any of these calls would move jobs off BullMQ's default
    // key layout, making the scenario's waiting-count gate read an empty queue.
    expect(gateway).not.toMatch(/createQueues\([^;]*?prefix/);
    expect(worker).not.toMatch(/createQueues\([^;]*?prefix/);
    expect(worker).not.toMatch(/createAgentRunsWorker\([^;]*?prefix/);
  });

  it("createScenarioQueues agrees with BullMQ's default 'bull'", async () => {
    const queues = createScenarioQueues("redis://127.0.0.1:1");
    try {
      expect(STAGING_QUEUE_PREFIX).toBe("bull");
      expect(queues.agentRuns.opts.prefix).toBe("bull");
      expect(queues.agentRuns.toKey("wait")).toBe("bull:agent-runs:wait");
      expect(queues.agentRuns.opts.prefix).toBe(STAGING_QUEUE_PREFIX);
      expect(queues.agentRuns.toKey("wait")).not.toContain("bull:staging");
    } finally {
      await Promise.allSettled(
        Object.values(queues)
          .filter((queue): queue is NonNullable<typeof queue> => queue !== undefined)
          .map((queue) => queue.close()),
      );
    }
  });

  it("the scenario constructs its queues without a prefix of its own", () => {
    expect(createScenarioQueues.toString()).not.toContain("prefix");
  });
});
