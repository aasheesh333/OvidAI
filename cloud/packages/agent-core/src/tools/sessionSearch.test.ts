import { beforeEach, describe, expect, it, vi } from "vitest";

import type { Db } from "@ovid/db";
import { searchMessages } from "@ovid/db";
import type { ToolContext } from "../types.js";
import { createSessionSearchTool, SESSION_SEARCH_MAX_QUERY_UTF16 } from "./sessionSearch.js";

/**
 * P3 Task 13 — the session_search tool over a STUBBED db (the repo itself is
 * tested against real Postgres in @ovid/db's repos.search.test.ts). Pins the
 * rendered line shape, the zero-row copy, and the Dart input clamps.
 */

vi.mock("@ovid/db", () => ({
  searchMessages: vi.fn(),
}));

const mockedSearch = vi.mocked(searchMessages);

const stubDb = {} as Db;

function ctx(userId = "u1"): ToolContext {
  return {
    sessionId: "s1",
    runId: "r1",
    userId,
    mode: "auto",
    planMode: false,
    isSubagent: false,
    depth: 0,
    unattended: false,
    callKey: "k1",
    signal: new AbortController().signal,
  };
}

describe("session_search tool", () => {
  beforeEach(() => {
    mockedSearch.mockReset();
  });

  it("renders one 'sessionId messageId: snippet' line per row, in rank order", async () => {
    mockedSearch.mockResolvedValue({
      rows: [
        { messageId: "m1", sessionId: "sA", role: "user", rank: 0.9, snippet: "→needle← in A" },
        { messageId: "m2", sessionId: "sB", role: "assistant", rank: 0.5, snippet: "a →needle← too" },
      ],
      total: 2,
    });
    const tool = createSessionSearchTool({ db: stubDb });
    const res = await tool.execute({ query: "needle" }, ctx());
    expect(res.isError).toBeFalsy();
    expect(res.content).toBe("sA m1: →needle← in A\nsB m2: a →needle← too");
    // The repo call is scoped to the CALLER's user id (ownership lives there).
    expect(mockedSearch).toHaveBeenCalledWith(stubDb, "u1", "needle", {
      limit: undefined,
      offset: undefined,
      sessionId: undefined,
    });
  });

  it("passes sessionId and limit through to the repo", async () => {
    mockedSearch.mockResolvedValue({ rows: [], total: 0 });
    const tool = createSessionSearchTool({ db: stubDb });
    await tool.execute({ query: "x", sessionId: "s9", limit: 5 }, ctx());
    expect(mockedSearch).toHaveBeenCalledWith(stubDb, "u1", "x", {
      limit: 5,
      offset: undefined,
      sessionId: "s9",
    });
  });

  it("zero rows → 'No matches.'", async () => {
    mockedSearch.mockResolvedValue({ rows: [], total: 0 });
    const tool = createSessionSearchTool({ db: stubDb });
    const res = await tool.execute({ query: "nothing" }, ctx());
    expect(res.content).toBe("No matches.");
    expect(res.isError).toBeFalsy();
  });

  it("over-long query → the Dart error copy (max 4096 UTF-16 units)", async () => {
    const tool = createSessionSearchTool({ db: stubDb });
    const res = await tool.execute({ query: "x".repeat(SESSION_SEARCH_MAX_QUERY_UTF16 + 1) }, ctx());
    expect(res.isError).toBe(true);
    expect(res.content).toBe(
      `Error: query must be text of at most ${SESSION_SEARCH_MAX_QUERY_UTF16} characters.`,
    );
    expect(mockedSearch).not.toHaveBeenCalled();
  });

  it("empty / whitespace-only query → 'query is required' (Dart copy)", async () => {
    const tool = createSessionSearchTool({ db: stubDb });
    for (const q of ["", "   \t "]) {
      const res = await tool.execute({ query: q }, ctx());
      expect(res.isError).toBe(true);
      expect(res.content).toBe("query is required");
      expect(mockedSearch).not.toHaveBeenCalled();
    }
  });

  it("non-string or out-of-range limit → input error, repo not called", async () => {
    const tool = createSessionSearchTool({ db: stubDb });
    const bad = await tool.execute({ query: "x", limit: 101 }, ctx());
    expect(bad.isError).toBe(true);
    expect(bad.content).toContain("0–100");
    const negative = await tool.execute({ query: "x", limit: -1 }, ctx());
    expect(negative.isError).toBe(true);
    const notString = await tool.execute({ query: 42 }, ctx());
    expect(notString.isError).toBe(true);
    expect(mockedSearch).not.toHaveBeenCalled();
  });

  it("repo failures surface as isError results (infrastructure stays loud)", async () => {
    mockedSearch.mockRejectedValue(new Error("connection refused"));
    const tool = createSessionSearchTool({ db: stubDb });
    const res = await tool.execute({ query: "x" }, ctx());
    expect(res.isError).toBe(true);
    expect(res.content).toContain("connection refused");
  });

  it("spec: name 'session_search', query required, optional sessionId/limit", () => {
    const tool = createSessionSearchTool({ db: stubDb });
    expect(tool.spec.name).toBe("session_search");
    expect(tool.spec.parameters).toMatchObject({
      type: "object",
      required: ["query"],
    });
    expect(Object.keys(tool.spec.parameters.properties ?? {})).toEqual(
      expect.arrayContaining(["query", "sessionId", "limit"]),
    );
    expect(tool.timeoutMs).toBeGreaterThan(0);
  });
});
