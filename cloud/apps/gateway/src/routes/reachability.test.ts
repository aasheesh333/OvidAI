import { afterAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildGateway } from "../app.js";
import {
  authHeaders,
  noopDb,
  noopEvents,
  stubKeys,
  stubMint,
  stubQueues,
  stubSystemBus,
  stubTickets,
  stubVerifier,
} from "../test/stubs.js";

/**
 * Registration wiring, not route behaviour.
 *
 * The P2 modules (`search`, `accountHealth`, `dataControl`) have their own
 * contract tests. What none of those can prove is the one thing that makes
 * them reachable in production: that `buildGateway` actually calls their
 * register function inside the authenticated `/cloud/v1` scope. A missing
 * import or a forgotten `register*Routes(scope, deps)` line leaves every
 * module test green while the deployed route answers 404.
 *
 * So each request below is chosen to answer WITHOUT touching the database
 * (`noopDb` is `{}`), and the assertion is deliberately about status class:
 * a 400 from input validation or a 200 from an empty query is proof the
 * handler ran; `not_found` is proof it did not. The final case pins the
 * control: an unregistered path really does 404 through the same app.
 */
describe("P2 route registration in buildGateway", () => {
  let app: FastifyInstance | undefined;

  function gateway(): FastifyInstance {
    app ??= buildGateway({
      system: stubSystemBus(),
      db: noopDb,
      queues: stubQueues().queues,
      verifier: stubVerifier(),
      tickets: stubTickets(),
      keys: stubKeys(),
      mint: stubMint(),
      events: noopEvents,
    });
    return app;
  }

  afterAll(async () => {
    await app?.close();
  });

  /** Every response must be a real handler answer, never the 404 envelope. */
  function expectReachable(status: number, body: { error?: { code?: string } }): void {
    expect(status).not.toBe(404);
    expect(body.error?.code).not.toBe("not_found");
  }

  it("GET /cloud/v1/search/messages is registered (blank q answers an empty page)", async () => {
    const res = await gateway().inject({
      method: "GET",
      url: "/cloud/v1/search/messages?q=",
      headers: authHeaders("u1"),
    });

    expectReachable(res.statusCode, res.json());
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ items: [], total: 0 });
  });

  it("GET /cloud/v1/account/health is registered (bad offset is a 400, not a 404)", async () => {
    const res = await gateway().inject({
      method: "GET",
      url: "/cloud/v1/account/health?utcOffsetMinutes=999",
      headers: authHeaders("u1"),
    });

    expectReachable(res.statusCode, res.json());
    expect(res.statusCode).toBe(400);
  });

  it("POST /cloud/v1/data/delete-all is registered (missing confirmation is a 400, not a 404)", async () => {
    const res = await gateway().inject({
      method: "POST",
      url: "/cloud/v1/data/delete-all",
      headers: authHeaders("u1"),
      payload: {},
    });

    expectReachable(res.statusCode, res.json());
    expect(res.statusCode).toBe(400);
  });

  it("POST /cloud/v1/memory/reset is registered (missing confirmation is a 400, not a 404)", async () => {
    const res = await gateway().inject({
      method: "POST",
      url: "/cloud/v1/memory/reset",
      headers: authHeaders("u1"),
      payload: {},
    });

    expectReachable(res.statusCode, res.json());
    expect(res.statusCode).toBe(400);
  });

  it("control: an unregistered /cloud/v1 path still answers 404 not_found", async () => {
    const res = await gateway().inject({
      method: "GET",
      url: "/cloud/v1/p2-not-a-route",
      headers: authHeaders("u1"),
    });

    expect(res.statusCode).toBe(404);
    expect(res.json().error.code).toBe("not_found");
  });
});
