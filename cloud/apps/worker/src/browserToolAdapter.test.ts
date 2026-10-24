import { describe, expect, it, vi } from "vitest";
import type { BrowserToolDef, BrowserToolContext, BrowserToolResult } from "@ovid/browser";
import { adaptBrowserTools, BROWSER_TOOL_TIMEOUT_MS, createUserBrowserLeases } from "./browserToolAdapter.js";
import type { ToolContext } from "@ovid/agent-core";

/**
 * The browser tool suite was exported by P6 but never dispatched — the agent
 * could not browse. These tests pin the adapter that closes that gap, and the
 * contract the rest of the system relies on:
 *   - the model sees the tool's own name/description/schema;
 *   - the browser context gets the RUN's sessionId and userId;
 *   - artifacts (screenshots/downloads) reach the tool result untouched;
 *   - an empty artifact list is omitted rather than sent as [].
 */

function ctx(overrides: Partial<ToolContext> = {}): ToolContext {
  return {
    sessionId: "sess-1",
    runId: "run-1",
    userId: "u-1",
    mode: "auto",
    planMode: false,
    isSubagent: false,
    depth: 0,
    unattended: false,
    callKey: "call-1",
    signal: new AbortController().signal,
    ...overrides,
  };
}

function def(
  name: string,
  result: BrowserToolResult,
  onExecute?: (input: unknown, ctx: BrowserToolContext) => void,
): BrowserToolDef {
  return {
    name,
    description: `${name} description`,
    parameters: { type: "object", properties: { selector: { type: "string" } } },
    inputSchema: { _def: {} } as never,
    async execute(input, browserCtx) {
      onExecute?.(input, browserCtx);
      return result;
    },
  };
}

describe("adaptBrowserTools", () => {
  it("maps the tool's own identity onto the canonical spec", () => {
    const [tool] = adaptBrowserTools([def("browser_click", { content: "clicked" })]);
    expect(tool!.spec).toEqual({
      name: "browser_click",
      description: "browser_click description",
      parameters: { type: "object", properties: { selector: { type: "string" } } },
    });
    expect(tool!.timeoutMs).toBe(BROWSER_TOOL_TIMEOUT_MS);
  });

  it("keys the browser by USER (one per user, Wave 5 R2) and sends artifacts to the run's session", async () => {
    const seen: BrowserToolContext[] = [];
    const [tool] = adaptBrowserTools([
      def("browser_open", { content: "ok" }, (_input, c) => seen.push({ ...c })),
    ]);

    const first = ctx({ sessionId: "s-9", userId: "u-9", runId: "r-9" });
    const second = ctx({ sessionId: "s-10", userId: "u-9", runId: "r-10" });
    await tool!.execute({ url: "https://example.com" }, first);
    await tool!.execute({ url: "https://example.com" }, second);

    expect(seen).toEqual([
      { sessionId: "user-u-9", userId: "u-9", workspaceSessionId: "s-9", runId: "r-9", signal: first.signal },
      { sessionId: "user-u-9", userId: "u-9", workspaceSessionId: "s-10", runId: "r-10", signal: second.signal },
    ]);
  });

  it("forwards the model's arguments unchanged", async () => {
    const seen: unknown[] = [];
    const [tool] = adaptBrowserTools([
      def("browser_fill", { content: "filled" }, (input) => seen.push(input)),
    ]);
    const args = { selector: "#q", text: "hello" };

    await tool!.execute(args, ctx());

    expect(seen).toEqual([args]);
  });

  it("carries artifacts through to the tool result", async () => {
    const artifacts = [
      { kind: "screenshot" as const, path: "browser/screenshots/x.jpg", mimeType: "image/jpeg", bytes: 1234 },
    ];
    const [tool] = adaptBrowserTools([def("browser_screenshot", { content: "took it", artifacts })]);

    const result = await tool!.execute({}, ctx());

    expect(result.content).toBe("took it");
    expect(result.artifacts).toEqual(artifacts);
  });

  it("omits the artifacts key when the tool produced none", async () => {
    const [withNone] = adaptBrowserTools([def("browser_read", { content: "text" })]);
    const [withEmpty] = adaptBrowserTools([def("browser_read", { content: "text", artifacts: [] })]);

    expect(await withNone!.execute({}, ctx())).toEqual({ content: "text" });
    expect(await withEmpty!.execute({}, ctx())).toEqual({ content: "text" });
  });

  it("never throws: a browser failure is a content string (the tool contract)", async () => {
    const [tool] = adaptBrowserTools([
      {
        ...def("browser_open", { content: "" }),
        async execute() {
          // BrowserToolDef promises this; the adapter must not add a wrapper
          // that turns it into an exception.
          return { content: "Browser refused: blocked host", isError: true } as never;
        },
      },
    ]);

    const result = await tool!.execute({ url: "http://169.254.169.254/" }, ctx());

    expect(result.content).toContain("blocked host");
  });

  it("adapts the whole suite (every definition keeps its name)", () => {
    const names = ["browser_open", "browser_click", "browser_drag", "browser_screenshot"];
    const tools = adaptBrowserTools(names.map((n) => def(n, { content: n })));
    expect(tools.map((t) => t.spec.name)).toEqual(names);
  });

  it("forwards the run id and abort signal needed by per-use credential approval and cleanup", async () => {
    const run = ctx({ runId: "run-credential", sessionId: "chat-credential" });
    const spy = vi.fn((_input: unknown, c: BrowserToolContext) => {
      expect(Object.keys(c).sort()).toEqual(["runId", "sessionId", "signal", "userId", "workspaceSessionId"]);
      expect(c).toMatchObject({
        sessionId: "user-u-1",
        workspaceSessionId: "chat-credential",
        runId: "run-credential",
        signal: run.signal,
      });
      return Promise.resolve({ content: "ok" });
    });
    const [tool] = adaptBrowserTools([{ ...def("browser_wait_for", { content: "ok" }), execute: spy }]);
    await tool!.execute({}, run);
    expect(spy).toHaveBeenCalledTimes(1);
  });
});

describe("createUserBrowserLeases (Wave 5 R2: a run's end never kills another run's or a viewer's browser)", () => {
  function engine(viewers = 0) {
    return { releaseSession: vi.fn(async (_key: string) => {}), viewerCount: vi.fn((_key: string) => viewers) };
  }

  it("the last browsing run of a user releases the user's browser", async () => {
    const e = engine();
    const leases = createUserBrowserLeases(e);
    const [tool] = adaptBrowserTools([def("browser_open", { content: "ok" })], leases);
    await tool!.execute({}, ctx({ runId: "r1", userId: "u1" }));
    await leases.releaseRun("u1", "r1");
    expect(e.releaseSession).toHaveBeenCalledWith("user-u1");
  });

  it("two concurrent runs of one user: the first to end leaves the browser to the other", async () => {
    const e = engine();
    const leases = createUserBrowserLeases(e);
    const [tool] = adaptBrowserTools([def("browser_open", { content: "ok" })], leases);
    await tool!.execute({}, ctx({ runId: "r1", sessionId: "a", userId: "u1" }));
    await tool!.execute({}, ctx({ runId: "r2", sessionId: "b", userId: "u1" }));
    await leases.releaseRun("u1", "r1");
    expect(e.releaseSession).not.toHaveBeenCalled();
    await leases.releaseRun("u1", "r2");
    expect(e.releaseSession).toHaveBeenCalledTimes(1);
  });

  it("someone watching the live view keeps the browser (the pool's idle lease reaps it after they leave)", async () => {
    const e = engine(1);
    const leases = createUserBrowserLeases(e);
    leases.note("u1", "r1");
    await leases.releaseRun("u1", "r1");
    expect(e.releaseSession).not.toHaveBeenCalled();
  });

  it("a run that never browsed releases nothing", async () => {
    const e = engine();
    const leases = createUserBrowserLeases(e);
    await leases.releaseRun("u1", "r-none");
    expect(e.releaseSession).not.toHaveBeenCalled();
  });

  it("users are independent", async () => {
    const e = engine();
    const leases = createUserBrowserLeases(e);
    leases.note("u1", "r1");
    leases.note("u2", "r2");
    await leases.releaseRun("u1", "r1");
    expect(e.releaseSession.mock.calls).toEqual([["user-u1"]]);
  });
});
