/**
 * McpRuntime (P5 Task 16) — the worker-side composition of the router,
 * contribution registry, installer and system bus.
 *
 * Gated on TEST_DATABASE_URL + TEST_REDIS_URL (real db + real Redis bus;
 * idempotent migrate only — parallel P5/P7 lanes share the dev services).
 *
 * Pinned here:
 * - `sandbox: null` still serves curated fetch (no sandbox needed) while the
 *   filesystem tool returns a clean `sandbox_unavailable` tool error (never a
 *   crash);
 * - router, bus and installer are one runtime instance (the installer reads
 *   the same db the router uses; shutdown closes the bus);
 * - shutdown is idempotent.
 */

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Redis } from "ioredis";
import { createDb, migrate, schema, type Db } from "@ovid/db";
import type { GuardedFetch, UserSystemBus } from "@ovid/mcp";
import { createMcpRuntime } from "./mcpRuntime.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";

let counter = 0;
function uid(prefix: string): string {
  counter += 1;
  return `${prefix}-${Date.now().toString(36)}-${counter}-${Math.random().toString(36).slice(2, 8)}`;
}

const fetchImpl: GuardedFetch = async () =>
  new Response("<html><body><h1>hello runtime</h1></body></html>", {
    status: 200,
    headers: { "content-type": "text/html" },
  });

let db: Db;
let redis: Redis;

async function seedUser(tier: "free" | "pro"): Promise<string> {
  const id = uid("mcp-runtime");
  await db.insert(schema.users).values({ uid: id, email: `${id}@test.local`, tier });
  return id;
}

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)("McpRuntime", () => {
  beforeAll(async () => {
    await migrate(TEST_DATABASE_URL!);
    db = createDb(TEST_DATABASE_URL!);
    redis = new Redis(TEST_REDIS_URL!);
  }, 60_000);

  afterAll(async () => {
    await redis?.quit();
    await db?.$client.end({ timeout: 5 });
  });

  it("sandbox null: curated fetch works, filesystem fails cleanly with sandbox_unavailable", async () => {
    const runtime = createMcpRuntime({
      db,
      redisQ: redis,
      masterKey: MASTER_KEY_HEX,
      sandbox: null,
      fetchImpl,
    });
    try {
      const id = await seedUser("free");
      const run = { sessionId: "s-runtime", runId: "r-runtime" };

      const fetched = await runtime.router.callTool(
        id,
        "mcp__fetch__fetch",
        { url: "https://example.com/page" },
        run,
      );
      expect(fetched.isError).toBe(false);
      expect(fetched.text).toContain("hello runtime");

      const fs = await runtime.router.callTool(
        id,
        "mcp__filesystem__read_file",
        { path: "notes.md" },
        run,
      );
      expect(fs.isError).toBe(true);
      expect(fs.text).toContain("sandbox_unavailable");
    } finally {
      await runtime.shutdown();
    }
  });

  it("router, bus and installer are one runtime instance; shutdown closes the bus idempotently", async () => {
    let busClosed = 0;
    const bus: UserSystemBus = {
      async publish() {},
      async request() {
        return null;
      },
      async close() {
        busClosed += 1;
      },
    };

    const runtime = createMcpRuntime({
      db,
      redisQ: redis,
      masterKey: MASTER_KEY_HEX,
      sandbox: null,
      fetchImpl,
      systemBus: bus,
    });

    // The three members share the runtime.
    expect(runtime.router).toBeDefined();
    expect(runtime.registry).toBeDefined();
    expect(runtime.installer).toBeDefined();
    expect(runtime.registry.list()).toEqual([]);

    // The installer is wired to the SAME db (a Free user is refused at the
    // transaction's job-start tier gate, before any source resolution).
    const id = await seedUser("free");
    const outcome = await runtime.installer.install({
      installId: "install-runtime-free",
      userId: id,
      pluginId: "acme/demo",
      mode: "install",
      source: { kind: "paste", label: "runtime", config: "{}" },
    });
    expect(outcome).toMatchObject({ status: "failed", reason: "pro_required" });

    await runtime.shutdown();
    expect(busClosed).toBe(1);
    await runtime.shutdown(); // idempotent — the bus closes once
    expect(busClosed).toBe(1);
  });
});
