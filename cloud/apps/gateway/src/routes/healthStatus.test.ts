import { describe, expect, it } from "vitest";
import type { Db } from "@ovid/db";
import type { QueueServices } from "@ovid/queue";
import { buildGateway } from "../app.js";
import { noopEvents, stubKeys, stubMint, stubSystemBus, stubTickets, stubVerifier } from "../test/stubs.js";

// Wave 4 (SE-014): GET /cloud/v1/health/status — public, coarse service
// status for the app's Service status screen.

const okDb = { $client: { unsafe: async () => [{ ok: 1 }] } } as unknown as Db;
const failDb = {
  $client: {
    unsafe: async () => {
      throw new Error("connection refused at 10.0.0.5:5432");
    },
  },
} as unknown as Db;

function queues(workers: number | Error | "absent"): QueueServices {
  return {
    agentRuns: {
      client: Promise.resolve({ ping: async () => "PONG" }),
      ...(workers === "absent"
        ? {}
        : {
            getWorkersCount: async () => {
              if (workers instanceof Error) throw workers;
              return workers;
            },
          }),
    },
  } as unknown as QueueServices;
}

async function status(
  db: Db,
  q: QueueServices,
  modelCatalog?: () => Promise<readonly string[] | null>,
) {
  const app = buildGateway({
    system: stubSystemBus(),
    db,
    queues: q,
    verifier: stubVerifier(),
    tickets: stubTickets(),
    keys: stubKeys(),
    mint: stubMint(),
    events: noopEvents,
    ...(modelCatalog !== undefined ? { modelCatalog } : {}),
  });
  try {
    // No auth headers: the status view is public.
    return await app.inject({ method: "GET", url: "/cloud/v1/health/status" });
  } finally {
    await app.close();
  }
}

describe("GET /cloud/v1/health/status", () => {
  it("everything healthy → ok, without auth", async () => {
    const res = await status(okDb, queues(2), async () => ["auto", "glm-5.3"]);
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.status).toBe("ok");
    expect(body.checks).toEqual({ api: "ok", storage: "ok", queue: "ok", agents: "ok", models: "ok" });
    expect(typeof body.checkedAt).toBe("string");
  });

  it("no queue consumer → agents down, overall down (runs would hang)", async () => {
    const res = await status(okDb, queues(0), async () => ["auto"]);
    expect(res.json().status).toBe("down");
    expect(res.json().checks.agents).toBe("down");
  });

  it("empty model catalog → models degraded, overall degraded", async () => {
    const res = await status(okDb, queues(1), async () => null);
    expect(res.json().status).toBe("degraded");
    expect(res.json().checks.models).toBe("degraded");
  });

  it("unknowable consumer count → agents unknown (never guessed)", async () => {
    expect((await status(okDb, queues(new Error("ERR unknown command"))))
      .json().checks.agents).toBe("unknown");
    expect((await status(okDb, queues("absent"))).json().checks.agents).toBe("unknown");
  });

  it("database down → storage down; the body never leaks internals", async () => {
    const res = await status(failDb, queues(1), async () => ["auto"]);
    expect(res.statusCode).toBe(200);
    expect(res.json().checks.storage).toBe("down");
    expect(res.json().status).toBe("down");
    expect(res.body).not.toContain("10.0.0.5");
    expect(res.body).not.toContain("refused");
  });
});
