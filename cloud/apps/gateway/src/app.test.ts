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

  function makeApp(
    tickets: TicketStub = stubTickets(),
    limits: { requestTimeout?: number; connectionTimeout?: number; bodyLimit?: number } = {},
  ): { app: FastifyInstance; tickets: TicketStub } {
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
    }, limits);
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

  it("hardens the transport: explicit requestTimeout, connectionTimeout and bodyLimit", async () => {
    // Fastify's own config type omits requestTimeout (it is forwarded to the
    // http server), though the value is present on initialConfig at runtime.
    type Config = FastifyInstance["initialConfig"] & { requestTimeout?: number };
    const { app } = makeApp();
    const config = app.initialConfig as Config;
    expect(config.requestTimeout).toBe(60_000);
    expect(config.connectionTimeout).toBe(10_000);
    expect(config.bodyLimit).toBe(10 * 1024 * 1024);
    expect(app.server.requestTimeout).toBe(60_000);

    // Every knob is overridable by the composition root / tests.
    const custom = makeApp(stubTickets(), {
      requestTimeout: 5_000,
      connectionTimeout: 2_000,
      bodyLimit: 1_024,
    });
    const customConfig = custom.app.initialConfig as Config;
    expect(customConfig.requestTimeout).toBe(5_000);
    expect(customConfig.connectionTimeout).toBe(2_000);
    expect(customConfig.bodyLimit).toBe(1_024);

    // The explicit cap is enforced: an over-limit body is a stable 413, not
    // a connection that stays open until the client gives up.
    const tooBig = await custom.app.inject({
      method: "POST",
      url: "/cloud/v1/auth/ticket",
      headers: { ...authHeaders("ws-user-big"), "content-type": "application/json" },
      payload: JSON.stringify({ pad: "x".repeat(2_048) }),
    });
    expect(tooBig.statusCode).toBe(413);
    expect(tooBig.json()).toEqual({
      error: { code: "payload_too_large", message: "Request body too large." },
    });
  });

  it("a 4xx never echoes Fastify's raw error message (stable code + server-side log)", async () => {
    const { app } = makeApp();
    const res = await app.inject({
      method: "POST",
      url: "/cloud/v1/auth/ticket",
      headers: { ...authHeaders("ws-user-json"), "content-type": "application/json" },
      payload: "{not valid json",
    });
    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ error: { code: "bad_request", message: "Invalid request." } });
    // No parser internals, token snippets or byte offsets reach the client.
    expect(res.body).not.toContain("JSON");
    expect(res.body).not.toContain("Unexpected");
    expect(res.body).not.toContain("position");
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
