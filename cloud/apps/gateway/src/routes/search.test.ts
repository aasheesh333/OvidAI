import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Db } from "@ovid/db";

/**
 * Global message search — the gateway half of `searchMessages`.
 *
 * The SQL (tsvector match, ranking, snippets, ownership join, query/limit/
 * offset clamps) already lives in `@ovid/db` and is pinned against real
 * Postgres in `packages/db/src/repos.search.test.ts`. This file pins the only
 * things the route adds:
 *
 *   - the caller's own uid is the search scope, always (never a body/query
 *     supplied user id);
 *   - pagination is clamped, never a 400 for a big number;
 *   - the wire is camelCase.
 *
 * The repo is mocked so a failure here means the ROUTE is wrong, not the SQL.
 */
const searchMessagesMock = vi.hoisted(() => vi.fn());

vi.mock("@ovid/db", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@ovid/db")>();
  return { ...actual, searchMessages: searchMessagesMock };
});

import { buildGateway } from "../app.js";
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

const SEARCH_URL = "/cloud/v1/search/messages";

function buildApp() {
  return buildGateway({
    system: stubSystemBus(),
    // searchMessages is mocked; no other route in this file touches the db.
    db: {} as Db,
    queues: stubQueues().queues,
    verifier: stubVerifier(),
    tickets: stubTickets(),
    keys: stubKeys(),
    mint: stubMint(),
    events: noopEvents,
  });
}

async function get(url: string, uid = "u1") {
  const response = await buildApp().inject({
    method: "GET",
    url,
    headers: authHeaders(uid),
  });
  return { status: response.statusCode, body: response.json() };
}

const ROW = {
  messageId: "11111111-1111-4111-8111-111111111111",
  sessionId: "22222222-2222-4222-8222-222222222222",
  role: "user",
  rank: 0.5,
  snippet: "a →needle← here",
};

beforeEach(() => {
  searchMessagesMock.mockReset();
  searchMessagesMock.mockResolvedValue({ rows: [ROW], total: 1 });
});

describe("GET /cloud/v1/search/messages", () => {
  it("scopes the search to the authenticated caller, never to a query-supplied user", async () => {
    const { status, body } = await get(`${SEARCH_URL}?q=needle&userId=someone-else`, "alice");

    expect(status).toBe(200);
    expect(searchMessagesMock).toHaveBeenCalledTimes(1);
    // Argument 2 is the scope. `userId` in the query is not part of the
    // contract and must not reach the repo.
    expect(searchMessagesMock.mock.calls[0]![1]).toBe("alice");
    expect(searchMessagesMock.mock.calls[0]![2]).toBe("needle");
    expect(body.items).toEqual([ROW]);
    expect(body.total).toBe(1);
  });

  it("answers with camelCase wire fields", async () => {
    const { body } = await get(`${SEARCH_URL}?q=needle`);

    expect(body).toEqual({
      items: [
        {
          messageId: ROW.messageId,
          sessionId: ROW.sessionId,
          role: "user",
          rank: 0.5,
          snippet: ROW.snippet,
        },
      ],
      total: 1,
      limit: 30,
      offset: 0,
    });
  });

  it("clamps a huge limit to 100 instead of rejecting it", async () => {
    const { status, body } = await get(`${SEARCH_URL}?q=needle&limit=100000`);

    expect(status).toBe(200);
    expect(body.limit).toBe(100);
    expect(searchMessagesMock.mock.calls[0]![3]).toMatchObject({ limit: 100 });
  });

  it("clamps a negative or past-the-end offset, never a 400", async () => {
    const negative = await get(`${SEARCH_URL}?q=needle&offset=-4`);
    expect(negative.status).toBe(200);
    expect(negative.body.offset).toBe(0);
    expect(searchMessagesMock.mock.calls[0]![3]).toMatchObject({ offset: 0 });

    searchMessagesMock.mockClear();
    const huge = await get(`${SEARCH_URL}?q=needle&offset=999999999`);
    expect(huge.status).toBe(200);
    expect(huge.body.offset).toBe(100_000);
    expect(searchMessagesMock.mock.calls[0]![3]).toMatchObject({ offset: 100_000 });
  });

  it("passes an optional sessionId through as a scope, not as a second owner", async () => {
    const { status } = await get(`${SEARCH_URL}?q=needle&sessionId=${ROW.sessionId}`);

    expect(status).toBe(200);
    expect(searchMessagesMock.mock.calls[0]![1]).toBe("u1");
    expect(searchMessagesMock.mock.calls[0]![3]).toMatchObject({ sessionId: ROW.sessionId });
  });

  it("rejects a malformed sessionId before it can reach a uuid column", async () => {
    const { status, body } = await get(`${SEARCH_URL}?q=needle&sessionId=not-a-uuid`);

    expect(status).toBe(400);
    expect(body.error.code).toBe("bad_request");
    expect(searchMessagesMock).not.toHaveBeenCalled();
  });

  it("treats a blank query as an empty page, not an error", async () => {
    const { status, body } = await get(`${SEARCH_URL}?q=%20%20`);

    expect(status).toBe(200);
    expect(body).toEqual({ items: [], total: 0, limit: 30, offset: 0 });
    expect(searchMessagesMock).not.toHaveBeenCalled();
  });
});
