import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import type { FastifyInstance, InjectOptions } from "fastify";
import { newId, users, type Db } from "@ovid/db";
import { createEnvelopeCrypto } from "@ovid/mcp";
import { buildGateway } from "../app.js";
import { closeDb, openTestDb, TEST_DATABASE_URL, testUid } from "../test/db.js";
import {
  authHeaders,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";

// Exercise the route against an explicit supported catalog fixture. Candidate
// and blocked IDs stay outside this set and must never become agent-callable.
vi.mock("@ovid/mcp", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@ovid/mcp")>();
  return {
    ...actual,
    CURATED_IDS: ["github"],
    CURATED_MANIFEST: [{
      curatedId: "github",
      displayName: "GitHub",
      description: "Supported test catalog entry",
      credentialFields: [{ key: "GITHUB_TOKEN", label: "GitHub token", secret: true }],
      tools: [],
    }],
  };
});

const TEST_DATABASE_URL_ = TEST_DATABASE_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";
const CREATE_SECRET = "create-parity-secret-must-not-leak-7f21";
const CANONICAL_DIGEST = `sha256:${"a".repeat(64)}`;

describe.skipIf(!TEST_DATABASE_URL_)("gateway MCP connection contract parity (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;
  let now = new Date("2026-10-24T12:00:00.000Z");
  const extraApps: FastifyInstance[] = [];
  const crypto = createEnvelopeCrypto(MASTER_KEY_HEX);
  const warnings: unknown[] = [];

  interface HealthProbeInput {
    connectionId: string;
    userId: string;
    providerId: string;
    transport: string;
    configVersion: number;
    disconnectGeneration: number;
    config: Record<string, unknown> | null;
    secrets?: Record<string, unknown>;
  }

  interface HealthProbeResult {
    state: "checking" | "healthy" | "degraded" | "needs_auth" | "unavailable";
  }

  function gatewayDeps() {
    return {
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      crypto,
      clock: () => now,
      logger: {
        warn(obj: unknown, msg?: string) {
          warnings.push({ obj, msg });
        },
      },
    };
  }

  function appWithHealth(check: (input: HealthProbeInput) => Promise<HealthProbeResult>): FastifyInstance {
    const healthApp = buildGateway({
      ...gatewayDeps(),
      connectionHealth: { check },
    });
    extraApps.push(healthApp);
    return healthApp;
  }

  beforeAll(async () => {
    db = await openTestDb();
    app = buildGateway(gatewayDeps());
  }, 60_000);

  afterAll(async () => {
    await Promise.all(extraApps.map((extra) => extra.close()));
    await app?.close();
    await closeDb(db);
  });

  async function seedPro(uid: string): Promise<void> {
    await users.ensure(db, uid, `${uid}@stub.test`);
    await db.$client.unsafe("UPDATE users SET tier = 'pro' WHERE uid = $1", [uid]);
  }

  async function postConnection(uid: string, payload: NonNullable<InjectOptions["payload"]>) {
    return app.inject({
      method: "POST",
      url: "/cloud/v1/mcp/connections",
      headers: authHeaders(uid),
      payload,
    });
  }

  async function storedRows(uid: string): Promise<unknown[]> {
    return db.$client.unsafe("SELECT id FROM mcp_servers WHERE user_id = $1", [uid]);
  }

  async function createConfigured(uid: string): Promise<string> {
    const created = await postConnection(uid, {
      providerId: "github",
      secrets: { GITHUB_TOKEN: CREATE_SECRET },
    });
    expect(created.statusCode, created.body).toBe(201);
    return created.json().connectionId as string;
  }

  async function getConnection(uid: string, id: string, target = app) {
    return target.inject({
      method: "GET",
      url: `/cloud/v1/mcp/connections/${id}`,
      headers: authHeaders(uid),
    });
  }

  async function patchConnection(
    uid: string,
    id: string,
    payload: NonNullable<InjectOptions["payload"]>,
  ) {
    return app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${id}`,
      headers: authHeaders(uid),
      payload,
    });
  }

  async function postHealth(
    uid: string,
    id: string,
    target = app,
    payload?: InjectOptions["payload"],
  ) {
    return target.inject({
      method: "POST",
      url: `/cloud/v1/mcp/connections/${id}`,
      headers: authHeaders(uid),
      ...(payload === undefined ? {} : { payload }),
    });
  }

  it("defaults an omitted name from the catalog or provider ID without an empty name", async () => {
    const uid = testUid("parity-default-name");
    await seedPro(uid);

    const curated = await postConnection(uid, {
      providerId: "github",
      secrets: { GITHUB_TOKEN: CREATE_SECRET },
    });
    expect(curated.statusCode, curated.body).toBe(201);
    expect(curated.json()).toMatchObject({
      providerId: "github",
      name: "GitHub",
      agentEnabled: false,
      healthState: "never_checked",
    });
    expect(curated.json().name.trim()).not.toBe("");
    expect(curated.body).not.toContain(CREATE_SECRET);

    const custom = await postConnection(uid, {
      providerId: "local-custom",
      transport: "stdio",
      config: { command: "local-command" },
    });
    expect(custom.statusCode, custom.body).toBe(201);
    expect(custom.json()).toMatchObject({ providerId: "local-custom", name: "local-custom" });
    expect(custom.json().name.trim()).not.toBe("");
  });

  it("admits create-time agent opt-in only after the same provider and auth gates as PATCH", async () => {
    const successUid = testUid("parity-create-active");
    await seedPro(successUid);
    const activated = await postConnection(successUid, {
      providerId: "github",
      secrets: { GITHUB_TOKEN: CREATE_SECRET },
      agentEnabled: true,
    });
    expect(activated.statusCode, activated.body).toBe(201);
    expect(activated.json()).toMatchObject({
      providerId: "github",
      name: "GitHub",
      enabled: true,
      agentEnabled: true,
      authState: "configured",
      healthState: "never_checked",
      lastCheckedAt: null,
      lastSuccessAt: null,
      hasSecrets: true,
    });
    expect(activated.body).not.toContain(CREATE_SECRET);
    expect(JSON.stringify(warnings)).not.toContain(CREATE_SECRET);

    const missingUid = testUid("parity-create-auth");
    await seedPro(missingUid);
    const missing = await postConnection(missingUid, {
      providerId: "github",
      agentEnabled: true,
    });
    expect(missing.statusCode, missing.body).toBe(409);
    expect(missing.json().error.code).toBe("auth_required");
    expect(await storedRows(missingUid)).toHaveLength(0);

    for (const providerId of ["vercel", "dropbox", "unregistered-custom"]) {
      const uid = testUid(`parity-create-unsupported-${providerId}`);
      await seedPro(uid);
      const unsupported = await postConnection(uid, {
        providerId,
        transport: "stdio",
        config: { command: "candidate-command" },
        agentEnabled: true,
      });
      expect(unsupported.statusCode, unsupported.body).toBe(409);
      expect(unsupported.json().error.code).toBe("provider_unsupported");
      expect(await storedRows(uid)).toHaveLength(0);
    }
  });

  it("fails approved-source creation closed without silently using arbitrary custom config", async () => {
    for (const withArbitraryConfig of [false, true]) {
      const uid = testUid(`parity-approved-source-${withArbitraryConfig}`);
      await seedPro(uid);
      const res = await postConnection(uid, {
        providerId: "approved-plugin",
        name: "Approved plugin",
        approvedSourceId: "source-fixture",
        approvedDigest: CANONICAL_DIGEST,
        secrets: { TOKEN: CREATE_SECRET },
        agentEnabled: true,
        ...(withArbitraryConfig ? {
          transport: "http",
          config: { url: "https://unapproved-arbitrary.example.test/mcp" },
        } : {}),
      });
      expect(res.statusCode, res.body).toBe(503);
      expect(res.json()).toEqual({
        error: {
          code: "approved_source_unavailable",
          message: "Approved-source connection creation is not available.",
        },
      });
      expect(res.body).not.toContain(CREATE_SECRET);
      expect(res.body).not.toContain("unapproved-arbitrary");
      expect(await storedRows(uid)).toHaveLength(0);
    }

    const malformedUid = testUid("parity-approved-source-malformed");
    await seedPro(malformedUid);
    const malformed = await postConnection(malformedUid, {
      providerId: "approved-plugin",
      approvedSourceId: "source-without-digest",
    });
    expect(malformed.statusCode, malformed.body).toBe(400);
    expect(await storedRows(malformedUid)).toHaveLength(0);
  });

  it("requires an owner-scoped UUID and a strictly empty body before any health probe", async () => {
    const uid = testUid("parity-health-body-owner");
    const other = testUid("parity-health-other-owner");
    await seedPro(uid);
    await seedPro(other);
    const id = await createConfigured(uid);
    let probes = 0;
    const healthApp = appWithHealth(async () => {
      probes += 1;
      return { state: "healthy" };
    });

    for (const payload of [{}, { unexpected: true }]) {
      const res = await postHealth(uid, id, healthApp, payload);
      expect(res.statusCode, res.body).toBe(400);
      expect(res.json().error.code).toBe("bad_request");
    }
    expect((await postHealth(other, id, healthApp)).statusCode).toBe(404);
    expect((await postHealth(uid, "not-a-uuid", healthApp)).statusCode).toBe(404);
    const unauthenticated = await healthApp.inject({
      method: "POST",
      url: `/cloud/v1/mcp/connections/${id}`,
    });
    expect(unauthenticated.statusCode).toBe(401);
    expect(probes).toBe(0);
    expect((await getConnection(uid, id)).json()).toMatchObject({
      healthState: "never_checked",
      lastCheckedAt: null,
      lastSuccessAt: null,
    });
  });

  it("returns explicit unavailable without an adapter, never healthy from configured auth", async () => {
    const uid = testUid("parity-health-unavailable");
    await seedPro(uid);
    const id = await createConfigured(uid);
    now = new Date("2026-10-24T12:10:00.000Z");

    const res = await postHealth(uid, id);
    expect(res.statusCode, res.body).toBe(200);
    expect(res.json()).toMatchObject({
      connectionId: id,
      providerId: "github",
      authState: "configured",
      healthState: "unavailable",
      lastCheckedAt: now.toISOString(),
      lastSuccessAt: null,
      configVersion: 1,
      disconnectGeneration: 0,
    });
    expect(res.body).not.toContain(CREATE_SECRET);
    expect(JSON.stringify(warnings)).not.toContain(CREATE_SECRET);
    expect((await getConnection(uid, id)).json()).toMatchObject({
      healthState: "unavailable",
      lastCheckedAt: now.toISOString(),
      lastSuccessAt: null,
    });

    const customUid = testUid("parity-health-unsupported");
    await seedPro(customUid);
    const custom = await postConnection(customUid, {
      providerId: "unregistered-custom",
      transport: "stdio",
      config: { command: "local-command" },
    });
    expect(custom.statusCode, custom.body).toBe(201);
    const unsupported = await postHealth(customUid, custom.json().connectionId);
    expect(unsupported.statusCode, unsupported.body).toBe(200);
    expect(unsupported.json().healthState).toBe("unavailable");
  });

  it("short-circuits disabled, disconnected, and unauthenticated connections without probing", async () => {
    let probes = 0;
    const healthApp = appWithHealth(async () => {
      probes += 1;
      return { state: "healthy" };
    });

    const disabledUid = testUid("parity-health-disabled");
    await seedPro(disabledUid);
    const disabledId = await createConfigured(disabledUid);
    expect((await patchConnection(disabledUid, disabledId, { enabled: false })).statusCode).toBe(200);
    const disabled = await postHealth(disabledUid, disabledId, healthApp);
    expect(disabled.statusCode, disabled.body).toBe(200);
    expect(disabled.json()).toMatchObject({
      enabled: false,
      healthState: "disabled",
      lastCheckedAt: null,
      lastSuccessAt: null,
    });

    const disconnectedUid = testUid("parity-health-disconnected");
    await seedPro(disconnectedUid);
    const disconnectedId = await createConfigured(disconnectedUid);
    const removed = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/mcp/connections/${disconnectedId}`,
      headers: authHeaders(disconnectedUid),
    });
    expect(removed.statusCode).toBe(204);
    const disconnected = await postHealth(disconnectedUid, disconnectedId, healthApp);
    expect(disconnected.statusCode, disconnected.body).toBe(200);
    expect(disconnected.json()).toMatchObject({
      enabled: false,
      agentEnabled: false,
      authState: "revoked",
      healthState: "revoked",
      disconnectGeneration: 1,
      lastSuccessAt: null,
    });

    const missingUid = testUid("parity-health-missing-auth");
    await seedPro(missingUid);
    const missing = await postConnection(missingUid, { providerId: "github" });
    expect(missing.statusCode, missing.body).toBe(201);
    now = new Date("2026-10-24T12:11:00.000Z");
    const needsAuth = await postHealth(missingUid, missing.json().connectionId, healthApp);
    expect(needsAuth.statusCode, needsAuth.body).toBe(200);
    expect(needsAuth.json()).toMatchObject({
      authState: "missing",
      healthState: "needs_auth",
      lastCheckedAt: now.toISOString(),
      lastSuccessAt: null,
    });
    expect(probes).toBe(0);
  });

  it("persists real adapter outcomes and preserves the last actual success", async () => {
    const uid = testUid("parity-health-adapter-results");
    await seedPro(uid);
    const id = await createConfigured(uid);
    const inputs: HealthProbeInput[] = [];
    const healthApp = appWithHealth(async (input) => {
      inputs.push(input);
      return { state: inputs.length === 1 ? "healthy" : "degraded" };
    });

    now = new Date("2026-10-24T12:12:00.000Z");
    const healthyAt = now.toISOString();
    const healthy = await postHealth(uid, id, healthApp);
    expect(healthy.statusCode, healthy.body).toBe(200);
    expect(healthy.json()).toMatchObject({
      healthState: "healthy",
      lastCheckedAt: healthyAt,
      lastSuccessAt: healthyAt,
    });

    now = new Date("2026-10-24T12:13:00.000Z");
    const degraded = await postHealth(uid, id, healthApp);
    expect(degraded.statusCode, degraded.body).toBe(200);
    expect(degraded.json()).toMatchObject({
      healthState: "degraded",
      lastCheckedAt: now.toISOString(),
      lastSuccessAt: healthyAt,
    });
    expect(inputs).toHaveLength(2);
    expect(inputs[0]).toMatchObject({
      connectionId: id,
      userId: uid,
      providerId: "github",
      configVersion: 1,
      disconnectGeneration: 0,
      secrets: { GITHUB_TOKEN: CREATE_SECRET },
    });
    expect(inputs[0]).not.toHaveProperty("secretsSealed");
    expect(healthy.body).not.toContain(CREATE_SECRET);
    expect(degraded.body).not.toContain(CREATE_SECRET);

    const checkingUid = testUid("parity-health-checking");
    await seedPro(checkingUid);
    const checkingId = await createConfigured(checkingUid);
    const checkingApp = appWithHealth(async () => ({ state: "checking" }));
    const checking = await postHealth(checkingUid, checkingId, checkingApp);
    expect(checking.statusCode, checking.body).toBe(200);
    expect(checking.json()).toMatchObject({ healthState: "checking", lastSuccessAt: null });
  });

  it("sanitizes adapter failures to unavailable without secret-bearing DTOs or logs", async () => {
    const uid = testUid("parity-health-adapter-error");
    await seedPro(uid);
    const id = await createConfigured(uid);
    warnings.length = 0;
    const healthApp = appWithHealth(async () => {
      throw new Error(`provider leaked ${CREATE_SECRET}`);
    });
    now = new Date("2026-10-24T12:14:00.000Z");

    const res = await postHealth(uid, id, healthApp);
    expect(res.statusCode, res.body).toBe(200);
    expect(res.json()).toMatchObject({
      healthState: "unavailable",
      lastCheckedAt: now.toISOString(),
      lastSuccessAt: null,
    });
    expect(res.body).not.toContain(CREATE_SECRET);
    expect(JSON.stringify(warnings)).not.toContain(CREATE_SECRET);
  });

  it("uses the same legacy unknown auth projection for every health response", async () => {
    const variants = [
      {
        name: "valid",
        plaintext: { GITHUB_TOKEN: CREATE_SECRET } as unknown,
        envelope: "valid",
        expectedAuth: "configured",
        expectedHealth: "healthy",
      },
      {
        name: "missing",
        plaintext: null as unknown,
        envelope: "missing",
        expectedAuth: "missing",
        expectedHealth: "needs_auth",
      },
      {
        name: "incomplete",
        plaintext: { UNRELATED: "not-a-github-token" } as unknown,
        envelope: "valid",
        expectedAuth: "missing",
        expectedHealth: "needs_auth",
      },
      {
        name: "malformed-json",
        plaintext: "not-json" as unknown,
        envelope: "valid",
        expectedAuth: "missing",
        expectedHealth: "needs_auth",
      },
      {
        name: "malformed-envelope",
        plaintext: null as unknown,
        envelope: "malformed",
        expectedAuth: "missing",
        expectedHealth: "needs_auth",
      },
    ] as const;
    const probedUsers: string[] = [];
    const healthApp = appWithHealth(async (input) => {
      probedUsers.push(input.userId);
      return { state: "healthy" };
    });
    let validId = "";
    let validUid = "";

    for (const [index, variant] of variants.entries()) {
      const uid = testUid(`parity-health-legacy-${variant.name}`);
      await seedPro(uid);
      const id = newId();
      const sealed = variant.envelope === "missing"
        ? null
        : variant.envelope === "malformed"
          ? { wrappedDek: "not-an-envelope", iv: "bad", ciphertext: "bad", tag: "bad" }
          : crypto.encrypt(JSON.stringify(variant.plaintext), `mcp_servers:${id}`);
      await db.$client.unsafe(
        `INSERT INTO mcp_servers
          (id, user_id, name, transport, curated_id, provider_id, auth_state,
           health_state, secrets_sealed, agent_enabled, enabled,
           config_version, disconnect_generation)
         VALUES ($1, $2, $3, 'native', 'github', NULL, 'unknown',
           'never_checked', $4::jsonb, false, true, 1, 0)`,
        [id, uid, `Legacy health ${variant.name}`, sealed === null ? null : JSON.stringify(sealed)],
      );
      if (variant.name === "valid") {
        validId = id;
        validUid = uid;
      }

      const before = await getConnection(uid, id, healthApp);
      expect(before.statusCode, before.body).toBe(200);
      expect(before.json().authState).toBe(variant.expectedAuth);
      now = new Date(`2026-10-24T12:20:${String(index).padStart(2, "0")}.000Z`);
      const health = await postHealth(uid, id, healthApp);
      expect(health.statusCode, health.body).toBe(200);
      expect(health.json()).toMatchObject({
        connectionId: id,
        authState: variant.expectedAuth,
        healthState: variant.expectedHealth,
        lastCheckedAt: now.toISOString(),
        lastSuccessAt: variant.expectedHealth === "healthy" ? now.toISOString() : null,
      });
      expect(health.json().authState).toBe(before.json().authState);
      expect(probedUsers.includes(uid)).toBe(variant.name === "valid");
      expect(health.body).not.toContain(CREATE_SECRET);
      expect(JSON.stringify(warnings)).not.toContain(CREATE_SECRET);
    }

    const unavailable = await postHealth(validUid, validId, app);
    expect(unavailable.statusCode, unavailable.body).toBe(200);
    expect(unavailable.json()).toMatchObject({ authState: "configured", healthState: "unavailable" });
    expect((await patchConnection(validUid, validId, { enabled: false })).statusCode).toBe(200);
    const disabled = await postHealth(validUid, validId, app);
    expect(disabled.statusCode, disabled.body).toBe(200);
    expect(disabled.json()).toMatchObject({ authState: "configured", healthState: "disabled" });
  });

  it("fences completed probes by configVersion and disconnectGeneration", async () => {
    for (const mutation of ["secrets", "disconnect"] as const) {
      const uid = testUid(`parity-health-stale-${mutation}`);
      await seedPro(uid);
      const id = await createConfigured(uid);
      let release!: () => void;
      let markStarted!: () => void;
      const started = new Promise<void>((resolve) => { markStarted = resolve; });
      const gate = new Promise<void>((resolve) => { release = resolve; });
      const healthApp = appWithHealth(async () => {
        markStarted();
        await gate;
        return { state: "healthy" };
      });
      const pending = postHealth(uid, id, healthApp);
      const premature = await Promise.race([started.then(() => null), pending]);
      expect(premature).toBeNull();

      if (mutation === "secrets") {
        const changed = await patchConnection(uid, id, {
          secrets: { GITHUB_TOKEN: "replacement-secret-never-log-91b8" },
        });
        expect(changed.statusCode, changed.body).toBe(200);
        expect(changed.json().configVersion).toBe(2);
      } else {
        const disconnected = await app.inject({
          method: "DELETE",
          url: `/cloud/v1/mcp/connections/${id}`,
          headers: authHeaders(uid),
        });
        expect(disconnected.statusCode).toBe(204);
      }
      release();
      const completed = await pending;
      expect(completed.statusCode, completed.body).toBe(409);
      expect(completed.json().error.code).toBe("connection_changed");
      expect(completed.body).not.toContain(CREATE_SECRET);

      const current = await getConnection(uid, id);
      expect(current.statusCode).toBe(200);
      expect(current.json().healthState).not.toBe("healthy");
      expect(current.json().lastSuccessAt).toBeNull();
      if (mutation === "secrets") {
        expect(current.json()).toMatchObject({
          healthState: "never_checked",
          lastCheckedAt: null,
          configVersion: 2,
          disconnectGeneration: 0,
        });
      } else {
        expect(current.json()).toMatchObject({
          healthState: "revoked",
          configVersion: 1,
          disconnectGeneration: 1,
        });
      }
    }
  });
});
