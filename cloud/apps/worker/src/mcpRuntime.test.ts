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
import { createDb, migrate, newId, schema, type Db } from "@ovid/db";
import {
  createEnvelopeCrypto,
  type EgressRequest,
  type GuardedFetch,
  type ProviderEgress,
  type UserSystemBus,
} from "@ovid/mcp";
import { createMcpToolProvider } from "./mcpTools.js";
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
      legacyProviderFetchForTest: true,
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

  it("activates only current rows and executes generic REST through pinned egress with redacted output", async () => {
    const id = await seedUser("free");
    const connectionId = newId();
    const secret = "exa-plaintext-runtime-canary";
    const crypto = createEnvelopeCrypto(MASTER_KEY_HEX);
    await db.insert(schema.mcpServers).values({
      id: connectionId,
      userId: id,
      name: "exa",
      transport: "native",
      curatedId: "exa",
      providerId: "exa",
      enabled: true,
      agentEnabled: true,
      authState: "configured",
      healthState: "never_checked",
      configVersion: 1,
      disconnectGeneration: 0,
      secretsSealed: crypto.encrypt(
        JSON.stringify({ api_key: secret }),
        `mcp_servers:${connectionId}`,
      ),
    });

    const requests: EgressRequest[] = [];
    let closed = 0;
    const providerEgress: ProviderEgress = {
      async request(request) {
        requests.push(request);
        return {
          status: 200,
          headers: new Headers({ "content-type": "application/json" }),
          body: new ReadableStream<Uint8Array>({
            start(controller) {
              controller.enqueue(new TextEncoder().encode(JSON.stringify({
                results: [{ title: "sanitized" }],
                echo: secret,
              })));
              controller.close();
            },
          }),
          origin: new URL("https://api.exa.ai"),
          remoteAddress: "203.0.113.10",
        };
      },
      async close() {
        closed += 1;
      },
    };
    const runtime = createMcpRuntime({
      db,
      redisQ: redis,
      masterKey: MASTER_KEY_HEX,
      sandbox: null,
      providerEgress,
    });
    try {
      const root = await runtime.activation.snapshotForRun({
        userId: id,
        runId: "run-root",
        sessionId: "session-root",
        isSubagent: false,
        allow: [],
        deny: [],
        mode: "auto",
        planMode: false,
        unattended: false,
      });
      expect(root.operations.some((operation) => operation.modelName === "mcp__exa__search")).toBe(true);
      expect(JSON.stringify(root)).not.toContain(secret);
      const provider = createMcpToolProvider(runtime.router, {
        snapshotFor: async () => root,
        revalidate: (snapshot, call) => runtime.activation.revalidate(snapshot, call),
      });
      const tools = await provider.tools(root);
      expect(JSON.stringify(await provider.specs(root))).not.toContain(secret);
      const search = tools.find((tool) => tool.name === "mcp__exa__search")!;
      const result = await search.execute({ query: "typed search" }, {
        uid: id,
        sessionId: "session-root",
        runId: "run-root",
        mode: "auto",
        planMode: false,
        unattended: false,
        isSubagent: false,
        depth: 0,
        callKey: "run-root:call-1",
        signal: new AbortController().signal,
      });
      expect(result.isError).not.toBe(true);
      expect(result.content).toContain("sanitized");
      expect(result.content).not.toContain(secret);
      expect(requests).toHaveLength(1);
      expect(requests[0]).toMatchObject({
        originKey: "exa",
        method: "POST",
        privileged: true,
      });
      expect(requests[0]!.url.origin).toBe("https://api.exa.ai");

      await db.$client`
        UPDATE mcp_servers
        SET agent_enabled = false, config_version = config_version + 1
        WHERE id = ${connectionId} AND user_id = ${id}`;
      expect(await runtime.activation.revalidate(root, {
        connectionId,
        operationId: "search",
      })).toBe("stale");
      const afterDisable = await runtime.activation.snapshotForRun({
        userId: id,
        runId: "run-after-disable",
        sessionId: "session-root",
        isSubagent: false,
        allow: [],
        deny: [],
        mode: "auto",
        planMode: false,
        unattended: false,
      });
      expect(afterDisable.operations).toEqual([]);
    } finally {
      await runtime.shutdown();
    }
    expect(closed).toBe(1);
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
      legacyProviderFetchForTest: true,
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
