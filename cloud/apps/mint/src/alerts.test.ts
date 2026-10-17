import { describe, expect, it } from "vitest";
import type { Redis } from "ioredis";
import { createAlerter } from "./alerts.js";
import { loadMintEnv } from "./env.js";

/**
 * The alert delivery path is fire-and-forget (mint.py's daemon thread), so
 * this file pins the two things that can go wrong quietly: the Redis SETNX
 * once-per-bucket guard, and the T3-review I1 carry — every outbound fetch
 * carries an AbortSignal timeout (Python pins 10 s on the alert client).
 */

function env(webhookUrl: string) {
  return loadMintEnv({
    NODE_ENV: "test",
    DATABASE_URL: "postgres://u:p@localhost:5432/test",
    LITELLM_MASTER_KEY: "sk-litellm",
    OVID_ADMIN_MASTER_KEY: "sk-admin",
    OVID_INTERNAL_API_SECRET: "sk-internal",
    FIREBASE_PROJECT_ID: "ovid-test",
    ALERT_WEBHOOK_URL: webhookUrl,
  });
}

function redisOnce(): Redis {
  let sent = false;
  return {
    set: async () => {
      if (sent) return null;
      sent = true;
      return "OK";
    },
  } as unknown as Redis;
}

describe("createAlerter", () => {
  it("sends at most once per bucket and carries an abort timeout", async () => {
    const calls: { url: string; init: RequestInit }[] = [];
    const alerter = createAlerter(redisOnce(), env("http://127.0.0.1:1/hook"), (async (url, init) => {
      calls.push({ url: String(url), init: init ?? {} });
      return new Response("{}", { status: 200 });
    }) as typeof fetch);

    await alerter("daily_spend", "over", 3600);
    await new Promise((resolve) => setTimeout(resolve, 0));
    await alerter("daily_spend", "over", 3600);
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(calls).toHaveLength(1);
    expect(calls[0].init.signal).toBeInstanceOf(AbortSignal);
  });

  it("never throws when delivery fails", async () => {
    const alerter = createAlerter(redisOnce(), env("http://127.0.0.1:1/hook"), (async () => {
      throw new Error("down");
    }) as typeof fetch);
    await expect(alerter("x", "y")).resolves.toBeUndefined();
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
});
