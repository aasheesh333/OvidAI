import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import type { FastifyInstance } from "fastify";
import { users, type Db } from "@ovid/db";
import { CURATED_IDS, createEnvelopeCrypto } from "@ovid/mcp";
import { catalogServerDtoSchema } from "@ovid/shared";
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

// Explicit test-only support: no production readiness row is promoted to make
// this route's configured-flag and DTO projection fixtures executable.
vi.mock("@ovid/mcp", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@ovid/mcp")>();
  return {
    ...actual,
    CURATED_IDS: ["github", "fetch"],
    COMMERCE_INFRA_MANIFEST: [
      {
        curatedId: "blocked-commerce",
        displayName: "Blocked commerce candidate",
        description: "Must not cross the supported-only catalog boundary",
        credentialFields: [],
        tools: [{
          name: "charge_customer",
          description: "Unsupported operation",
          effect: "financial",
          approval: "per_action",
          requiredScopes: ["payments:write"],
        }],
      },
    ],
    CURATED_MANIFEST: [
      {
        curatedId: "github",
        displayName: "GitHub",
        description: "Supported test GitHub entry",
        credentialFields: [{ key: "GITHUB_TOKEN", label: "GitHub token", secret: true }],
        tools: [{
          name: "list_issues",
          description: "List issues",
          effect: "read",
          approval: "mode",
          requiredScopes: ["repo:read", "issues:read"],
          inputSchema: {
            type: "object",
            properties: { token: { type: "string", default: "fixture-input-secret" } },
          },
          request: {
            originKey: "github",
            method: "GET",
            pathTemplate: "https://raw.internal.example/issues?token=fixture-request-secret",
          },
          config: { apiToken: "fixture-config-secret" },
          authToken: "fixture-auth-token",
          handler: () => "fixture-handler-result",
        }],
      },
      {
        curatedId: "fetch",
        displayName: "Fetch",
        description: "Supported test Fetch entry",
        credentialFields: [],
        tools: [{ name: "fetch", description: "Fetch a public page" }],
      },
    ],
  };
});

// Curated catalog route (P5 Task 15): CURATED_MANIFEST served as pure data
// with the caller's configured flags. No crypto dep needed — the catalog is
// public-shape data; only the credential VALUES (never projected) are sealed.

const TEST_DATABASE_URL_ = TEST_DATABASE_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";

describe.skipIf(!TEST_DATABASE_URL_)("gateway mcp catalog route (real postgres)", () => {
  let db: Db;
  let app: FastifyInstance;

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
      // The configured-flag test writes a curated credential row, which is
      // sealed — the route refuses loudly without crypto (P5 secret invariant).
      crypto: createEnvelopeCrypto(MASTER_KEY_HEX),
    });
  }, 60_000);

  afterAll(async () => {
    await app?.close();
    await closeDb(db);
  });

  it("GET /mcp/catalog preserves the legacy envelope and adds only validated operation metadata", async () => {
    const uid = testUid("cat-bare");
    const res = await app.inject({
      method: "GET",
      url: "/cloud/v1/mcp/catalog",
      headers: authHeaders(uid),
    });
    expect(res.statusCode).toBe(200);
    const body = res.json() as { items: unknown[] };
    // Existing consumers can still parse every legacy DTO field unchanged.
    expect(body.items.map((item) => catalogServerDtoSchema.parse(item).curatedId)).toEqual([
      ...CURATED_IDS,
    ]);
    // Exact raw response: additive operation fields only, no internal config,
    // credentials, request URLs, handlers, or unsupported candidate entries.
    expect(body).toEqual({
      items: [
        {
          curatedId: "github",
          displayName: "GitHub",
          description: "Supported test GitHub entry",
          credentialFields: [{ key: "GITHUB_TOKEN", label: "GitHub token", secret: true }],
          tools: [{
            name: "list_issues",
            description: "List issues",
            effect: "read",
            approval: "mode",
            requiredScopes: ["repo:read", "issues:read"],
          }],
          configured: false,
        },
        {
          curatedId: "fetch",
          displayName: "Fetch",
          description: "Supported test Fetch entry",
          credentialFields: [],
          // Unknown legacy operation metadata stays absent, never defaulted.
          tools: [{ name: "fetch", description: "Fetch a public page" }],
          configured: false,
        },
      ],
    });
    for (const forbidden of [
      "blocked-commerce",
      "fixture-input-secret",
      "fixture-request-secret",
      "fixture-config-secret",
      "fixture-auth-token",
      "fixture-handler-result",
      "raw.internal.example",
    ]) {
      expect(res.body).not.toContain(forbidden);
    }
  });

  it("configured flags reflect the caller's credential rows only", async () => {
    const uid = testUid("cat-cfg");
    await users.ensure(db, uid, `${uid}@stub.test`);
    const created = await app.inject({
      method: "POST",
      url: "/cloud/v1/mcp/servers",
      headers: authHeaders(uid),
      payload: { curatedId: "github", secrets: { GITHUB_TOKEN: "ghp-cat-31" } },
    });
    expect(created.statusCode).toBe(201);

    const mine = await app.inject({
      method: "GET",
      url: "/cloud/v1/mcp/catalog",
      headers: authHeaders(uid),
    });
    const mineItems = (
      mine.json() as { items: ReturnType<typeof catalogServerDtoSchema.parse>[] }
    ).items.map((i) => catalogServerDtoSchema.parse(i));
    const byId = new Map(mineItems.map((i) => [i.curatedId, i]));
    expect(byId.get("github")!.configured).toBe(true);
    expect(mineItems.filter((i) => i.configured).length).toBe(1);
    // The credential VALUE never rides the catalog response.
    expect(JSON.stringify(mine.body)).not.toContain("ghp-cat-31");

    // A different user sees github unconfigured.
    const other = await app.inject({
      method: "GET",
      url: "/cloud/v1/mcp/catalog",
      headers: authHeaders(testUid("cat-other")),
    });
    const otherItems = (other.json() as { items: unknown[] }).items.map((i) =>
      catalogServerDtoSchema.parse(i),
    );
    expect(otherItems.find((i) => i.curatedId === "github")!.configured).toBe(false);
    expect(otherItems.filter((i) => i.configured).length).toBe(0);
  });
});
