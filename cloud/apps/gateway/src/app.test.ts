import { afterEach, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildGateway } from "./app.js";
import { stubSystemBus, authHeaders, noopDb, noopEvents, stubKeys, stubMint, stubQueues, stubTickets, stubVerifier, type TicketStub } from "./test/stubs.js";

/**
 * buildGateway-level behavior: the ticket route (registered in app.ts) and the
 * global error envelopes. Never touches the database (noopDb).
 */
describe("buildGateway", () => {
  const built: FastifyInstance[] = [];

  afterEach(async () => {
    while (built.length > 0) await built.pop()!.close();
  });

  function makeApp(tickets: TicketStub = stubTickets()): { app: FastifyInstance; tickets: TicketStub } {
    const { queues } = stubQueues();
    const app = buildGateway({
      system: stubSystemBus(),
      db: noopDb,
      queues,
      verifier: stubVerifier(),
      tickets,
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
    });
    built.push(app);
    return { app, tickets };
  }

  it("POST /cloud/v1/auth/ticket → 200 {ticket} minted for the principal uid", async () => {
    const { app, tickets } = makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/auth/ticket",
      headers: authHeaders("ws-user-1"),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ticket: "ticket-ws-user-1-0" });
    expect(tickets.minted).toEqual([{ uid: "ws-user-1", ticket: "ticket-ws-user-1-0" }]);
  });

  it("POST /cloud/v1/auth/ticket unauthenticated → 401 envelope, ticket store untouched", async () => {
    const { app, tickets } = makeApp();
    const res = await app.inject({ method: "POST", url: "/cloud/v1/auth/ticket" });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toMatchObject({ error: { code: "unauthenticated" } });
    expect(tickets.minted).toEqual([]);
  });

  it("unexpected route throw → 500 {code:'internal'} without leaking the internal message", async () => {
    const failing = stubTickets({ failMint: true });
    const { app } = makeApp(failing);
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/auth/ticket",
      headers: authHeaders("ws-user-2"),
    });
    expect(res.statusCode).toBe(500);
    expect(res.json()).toEqual({
      error: { code: "internal", message: "Internal server error." },
    });
    expect(res.body).not.toContain("ticket redis boom");
  });

  it("unknown route → 404 {code:'not_found'} envelope (consistent shape)", async () => {
    const { app } = makeApp();
    const res = await app.inject({
      method: "GET",
      url: "/cloud/v1/nope",
      headers: authHeaders("ws-user-3"),
    });
    expect(res.statusCode).toBe(404);
    expect(res.json().error.code).toBe("not_found");
  });
});
