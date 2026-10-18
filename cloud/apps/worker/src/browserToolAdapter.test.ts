import { describe, expect, it, vi } from "vitest";
import type { BrowserToolDef, BrowserToolContext, BrowserToolResult } from "@ovid/browser";
import { adaptBrowserTools, BROWSER_TOOL_TIMEOUT_MS } from "./browserToolAdapter.js";
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

  it("passes the run's sessionId and userId to the browser context", async () => {
    const seen: BrowserToolContext[] = [];
    const [tool] = adaptBrowserTools([
      def("browser_open", { content: "ok" }, (_input, c) => seen.push({ ...c })),
    ]);

    await tool!.execute({ url: "https://example.com" }, ctx({ sessionId: "s-9", userId: "u-9" }));

    expect(seen).toEqual([{ sessionId: "s-9", userId: "u-9" }]);
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

  it("does not forward the abort signal (documented limitation, not silence)", () => {
    // BrowserToolDef.execute takes no signal. Pinning the absence means a
    // future signature change is a deliberate act, not an accident.
    const spy = vi.fn((_input: unknown, c: BrowserToolContext) => {
      expect(Object.keys(c).sort()).toEqual(["sessionId", "userId"]);
      return Promise.resolve({ content: "ok" });
    });
    const [tool] = adaptBrowserTools([{ ...def("browser_wait_for", { content: "ok" }), execute: spy }]);
    return tool!.execute({}, ctx()).then(() => {
      expect(spy).toHaveBeenCalledTimes(1);
    });
  });
});
