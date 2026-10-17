import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { plugins, users, type Db } from "@ovid/db";
import type { QueueServices, PluginInstallJob } from "@ovid/queue";
import { createEnvelopeCrypto, PRO_REQUIRED_MESSAGE } from "@ovid/mcp";
import {
  pluginDtoSchema,
  pluginInstallResponseSchema,
  type PluginDto,
} from "@ovid/shared";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";

// Plugin routes (P5 Task 15): tier gate at request time, queued-row + job
// enqueue against the plugin-installs queue (fake queue, real priority rule),
// sealed user config, masked DTOs (no manifest, no config values).

const TEST_DATABASE_URL_ = TEST_DATABASE_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";

interface PluginAdd {
  name: string;
  data: PluginInstallJob;
  opts: { jobId?: string; priority?: number } & Record<string, unknown>;
}

/** Capturing pluginInstalls queue (BullMQ-shaped add) writing into `sink`. */
function stubPluginInstalls(
  sink: PluginAdd[],
): { queue: NonNullable<QueueServices["pluginInstalls"]>; adds: PluginAdd[] } {
  return {
    adds: sink,
    queue: {
      add: async (name: string, data: PluginInstallJob, opts?: Record<string, unknown>) => {
        sink.push({ name, data, opts: (opts ?? {}) as PluginAdd["opts"] });
        return { id: data.installId, name, data };
      },
    } as unknown as NonNullable<QueueServices["pluginInstalls"]>,
  };
}

describe.skipIf(!TEST_DATABASE_URL_)("gateway plugin routes (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;
  let bare: FastifyInstance;
  const adds: PluginAdd[] = [];
  const crypto = createEnvelopeCrypto(MASTER_KEY_HEX);

  beforeAll(async () => {
    db = await openTestDb();
    const queues = { ...stubQueues().queues, pluginInstalls: stubPluginInstalls(adds).queue };
    app = buildGateway({
      db,
      queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      crypto,
    });
    // P1-only composition: no crypto, no pluginInstalls queue.
    bare = buildGateway({
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
    });
  }, 60_000);

  afterAll(async () => {
    await app?.close();
    await bare?.close();
    await closeDb(db);
  });

  async function seedTier(uid: string, tier: "free" | "pro"): Promise<void> {
    await users.ensure(db, uid, `${uid}@stub.test`);
    await db.$client.unsafe("UPDATE users SET tier = $1 WHERE uid = $2", [tier, uid]);
  }

  async function install(uid: string, source: unknown) {
    return app.inject({
      method: "POST",
      url: "/cloud/v1/plugins/install",
      headers: authHeaders(uid),
      payload: { source },
    });
  }

  it("install as free → 402 pro_required with the exact message", async () => {
    const uid = testUid("plg-free");
    await seedTier(uid, "free");
    const res = await install(uid, { kind: "github", owner: "acme", repo: "sample-plugin" });
    expect(res.statusCode).toBe(402);
    expect(res.json()).toEqual({ error: { code: "pro_required", message: PRO_REQUIRED_MESSAGE } });
    expect(adds.length).toBe(0);
  });

  it("install as pro → 202 {installId,status:queued}; row queued; job priority 1", async () => {
    const uid = testUid("plg-pro");
    await seedTier(uid, "pro");
    const source = { kind: "github" as const, owner: "acme", repo: "sample-plugin" };
    const res = await install(uid, source);
    expect(res.statusCode).toBe(202);
    const answer = pluginInstallResponseSchema.parse(res.json());
    expect(answer.status).toBe("queued");

    // The plugins row exists with status queued (the worker moves it on).
    const rows = (await db.$client.unsafe(
      "SELECT id, plugin_id, status, source FROM plugins WHERE user_id = $1",
      [uid],
    )) as { id: string; plugin_id: string; status: string; source: Record<string, unknown> }[];
    expect(rows.length).toBe(1);
    expect(rows[0]!.id).toBe(answer.installId);
    expect(rows[0]!.plugin_id).toBe("acme/sample-plugin"); // canonical at enqueue
    expect(rows[0]!.status).toBe("queued");

    // The enqueued job (canonical pluginId — install() enforces the match).
    expect(adds.length).toBe(1);
    const add = adds[0]!;
    expect(add.name).toBe("plugin-install");
    expect(add.data).toEqual({
      installId: answer.installId,
      userId: uid,
      pluginId: "acme/sample-plugin",
      mode: "install",
      source,
    });
    expect(add.opts.priority).toBe(1); // pro
    expect(add.opts.jobId).toBe(answer.installId);

    // GET list + GET by id: masked DTOs, no manifest, no config.
    const list = await app.inject({
      method: "GET",
      url: "/cloud/v1/plugins",
      headers: authHeaders(uid),
    });
    expect(list.statusCode).toBe(200);
    const items = (list.json() as unknown[]).map((i) => pluginDtoSchema.parse(i));
    expect(items.length).toBe(1);
    expect(items[0]!.id).toBe(answer.installId);
    expect(items[0]!.pluginId).toBe("acme/sample-plugin");
    expect(items[0]!.status).toBe("queued");
    expect(items[0]!.source).toEqual({ kind: "github", label: "acme/sample-plugin" });

    const one = await app.inject({
      method: "GET",
      url: `/cloud/v1/plugins/${answer.installId}`,
      headers: authHeaders(uid),
    });
    expect(one.statusCode).toBe(200);
    expect(pluginDtoSchema.parse(one.json()).id).toBe(answer.installId);
  });

  it("DELETE enqueues uninstall; a pro-downgraded FREE user gets priority 2 (tier read at request time)", async () => {
    const uid = testUid("plg-down");
    await seedTier(uid, "pro");
    const source = { kind: "npm" as const, package: "@acme/tools" };
    const res = await install(uid, source);
    const { installId } = pluginInstallResponseSchema.parse(res.json());
    expect(adds.at(-1)!.opts.priority).toBe(1);

    // Downgrade AFTER install — the uninstall path re-reads the tier.
    await db.$client.unsafe("UPDATE users SET tier = 'free' WHERE uid = $1", [uid]);
    const del = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/plugins/${installId}`,
      headers: authHeaders(uid),
    });
    expect(del.statusCode).toBe(202);
    const answer = pluginInstallResponseSchema.parse(del.json());

    const add = adds.at(-1)!;
    expect(add.name).toBe("plugin-install");
    expect(add.data.mode).toBe("uninstall");
    expect(add.data.installId).toBe(answer.installId);
    expect(add.data.installId).not.toBe(installId); // a NEW transaction id
    expect(add.data.pluginId).toBe("acme/tools"); // scoped npm name → publisher/name
    expect(add.data.userId).toBe(uid);
    expect(add.data.source).toBeUndefined();
    expect(add.opts.priority).toBe(2); // free at request time

    const rows = (await db.$client.unsafe(
      "SELECT status FROM plugins WHERE id = $1",
      [installId],
    )) as { status: string }[];
    expect(rows[0]!.status).toBe("uninstalling");
  });

  it("PATCH /plugins/:id/config seals values into config_sealed; never echoed", async () => {
    const uid = testUid("plg-cfg");
    await seedTier(uid, "pro");
    const res = await install(uid, { kind: "github", owner: "acme", repo: "cfg-plugin" });
    const { installId } = pluginInstallResponseSchema.parse(res.json());

    const patched = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/plugins/${installId}/config`,
      headers: authHeaders(uid),
      payload: { config: { API_KEY: "cfg-secret-42aa", OTHER: "cfg-other-43bb" } },
    });
    expect(patched.statusCode).toBe(200);
    const dto = pluginDtoSchema.parse(patched.json());
    expect(dto.id).toBe(installId);
    expect(JSON.stringify(patched.body)).not.toContain("cfg-secret-42aa");
    expect(JSON.stringify(patched.body)).not.toContain("cfg-other-43bb");

    const rows = (await db.$client.unsafe(
      "SELECT config_sealed AS sealed FROM plugins WHERE id = $1",
      [installId],
    )) as { sealed: { wrappedDek: string; iv: string; ciphertext: string; tag: string } | null }[];
    expect(rows[0]!.sealed).not.toBeNull();
    expect(JSON.stringify(rows[0]!.sealed)).not.toContain("cfg-secret-42aa");
    const plain = JSON.parse(crypto.decrypt(rows[0]!.sealed!, `plugins:${installId}`)) as Record<
      string,
      string
    >;
    expect(plain.API_KEY).toBe("cfg-secret-42aa");
    expect(plain.OTHER).toBe("cfg-other-43bb");

    // GET list masks config values too.
    const list = await app.inject({
      method: "GET",
      url: "/cloud/v1/plugins",
      headers: authHeaders(uid),
    });
    expect(JSON.stringify(list.body)).not.toContain("cfg-secret-42aa");
  });

  it("wrong owner → 404 on get/delete; DELETE enqueues nothing for a foreign id", async () => {
    const uid = testUid("plg-own");
    const other = testUid("plg-foe");
    await seedTier(uid, "pro");
    await seedTier(other, "pro");
    const res = await install(uid, { kind: "github", owner: "acme", repo: "owned-plugin" });
    const { installId } = pluginInstallResponseSchema.parse(res.json());
    const before = adds.length;

    const got = await app.inject({
      method: "GET",
      url: `/cloud/v1/plugins/${installId}`,
      headers: authHeaders(other),
    });
    expect(got.statusCode).toBe(404);

    const del = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/plugins/${installId}`,
      headers: authHeaders(other),
    });
    expect(del.statusCode).toBe(404);
    expect(adds.length).toBe(before); // nothing enqueued for a foreign row
  });

  it("malformed install body → 400; unknown plugin id → 404", async () => {
    const uid = testUid("plg-bad");
    await seedTier(uid, "pro");
    for (const payload of [
      {},
      { source: { kind: "tarball", url: "https://x.test/p.tgz" } },
      { source: { kind: "github" } },
      { source: { kind: "npm", package: "x" }, extra: 1 },
    ]) {
      const res = await install(uid, payload);
      expect(res.statusCode).toBe(400);
    }
    const missing = await app.inject({
      method: "GET",
      url: "/cloud/v1/plugins/not-a-uuid",
      headers: authHeaders(uid),
    });
    expect(missing.statusCode).toBe(404);
  });

  it("install/config on a gateway composed without the queue/crypto → 503 unavailable", async () => {
    const uid = testUid("plg-bare");
    await seedTier(uid, "pro");
    const installRes = await bare.inject({
      method: "POST",
      url: "/cloud/v1/plugins/install",
      headers: authHeaders(uid),
      payload: { source: { kind: "github", owner: "acme", repo: "bare-plugin" } },
    });
    expect(installRes.statusCode).toBe(503);
    expect(installRes.json()).toEqual({
      error: { code: "unavailable", message: "Plugin installs are not configured." },
    });

    // The queue-wired app has crypto; the bare one has neither — a config
    // PATCH on an EXISTING row must refuse loudly (503) without the crypto.
    const row = await plugins.upsert(db, {
      userId: uid,
      pluginId: "acme/bare-plugin",
      version: "pending",
      source: { kind: "github", owner: "acme", repo: "bare-plugin" },
      status: "active",
    });
    const patched = await bare.inject({
      method: "PATCH",
      url: `/cloud/v1/plugins/${row.id}/config`,
      headers: authHeaders(uid),
      payload: { config: { A: "b" } },
    });
    expect(patched.statusCode).toBe(503);
    expect(patched.json()).toEqual({
      error: { code: "unavailable", message: "Plugin config sealing is not configured." },
    });
  });
});
