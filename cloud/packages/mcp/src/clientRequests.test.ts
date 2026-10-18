import { describe, expect, it } from "vitest";
import {
  createClientRequestHandler,
  createNotificationHandler,
  JSONRPC_INTERNAL_ERROR,
  JSONRPC_INVALID_PARAMS,
  JSONRPC_METHOD_NOT_FOUND,
  JSONRPC_USER_REJECTED,
  MAX_SERVER_LOGS,
  parseElicitationRequest,
  parseSamplingRequest,
  SAMPLING_PREVIEW_MAX_CHARS,
  validateElicitationResponse,
  type ClientRequestHandlers,
  type ElicitationRequest,
  type ElicitationResponse,
  type McpRoot,
  type NotificationSink,
} from "./clientRequests.js";
import type { JsonRpcRequest } from "./jsonrpc.js";

function req(method: string, params?: Record<string, unknown>, id: number | string = 1): JsonRpcRequest {
  return { jsonrpc: "2.0", id, method, params };
}

function textMessage(role: "user" | "assistant", text: string) {
  return { role, content: { type: "text", text } };
}

describe("ping", () => {
  it("answers {}", async () => {
    const handle = createClientRequestHandler({});
    const res = await handle("srv", req("ping"));
    expect(res).toEqual({ jsonrpc: "2.0", id: 1, result: {} });
  });
});

describe("roots/list", () => {
  it("returns provider roots as {uri,name}", async () => {
    const roots: McpRoot[] = [
      { uri: "file:///a", name: "a" },
      { uri: "file:///b" },
    ];
    const h: ClientRequestHandlers = { rootsProvider: () => roots };
    const res = await createClientRequestHandler(h)("srv", req("roots/list"));
    expect(res.result).toEqual({
      roots: [{ uri: "file:///a", name: "a" }, { uri: "file:///b" }],
    });
  });

  it("returns [] when no provider", async () => {
    const res = await createClientRequestHandler({})("srv", req("roots/list"));
    expect(res.result).toEqual({ roots: [] });
  });
});

describe("sampling/createMessage", () => {
  const params = { messages: [textMessage("user", "hi")], maxTokens: 10 };

  it("without approver or sampler → error -1 'User rejected sampling request'", async () => {
    const res = await createClientRequestHandler({})("srv", req("sampling/createMessage", params));
    expect(res.error?.code).toBe(JSONRPC_USER_REJECTED);
    expect(res.error?.message).toBe("User rejected sampling request");
  });

  it("denied by approver → -1", async () => {
    const h: ClientRequestHandlers = {
      samplingApprover: async () => false,
      sampler: async () => ({ role: "assistant", content: { type: "text", text: "x" } }),
    };
    const res = await createClientRequestHandler(h)("srv", req("sampling/createMessage", params));
    expect(res.error?.code).toBe(JSONRPC_USER_REJECTED);
  });

  it("approved → sampler result passed through", async () => {
    const result = { role: "assistant" as const, content: { type: "text" as const, text: "answer" }, model: "m1", stopReason: "endTurn" };
    const seen: unknown[] = [];
    const h: ClientRequestHandlers = {
      samplingApprover: async (r) => {
        seen.push(r);
        return true;
      },
      sampler: async () => result,
    };
    const res = await createClientRequestHandler(h)("srv", req("sampling/createMessage", params));
    expect(res.result).toEqual(result);
    expect(seen).toHaveLength(1);
    expect((seen[0] as { server: string }).server).toBe("srv");
  });

  it("sampler null → -32603 'sampling failed'", async () => {
    const h: ClientRequestHandlers = {
      samplingApprover: async () => true,
      sampler: async () => null,
    };
    const res = await createClientRequestHandler(h)("srv", req("sampling/createMessage", params));
    expect(res.error?.code).toBe(JSONRPC_INTERNAL_ERROR);
    expect(res.error?.message).toBe("sampling failed");
  });
});

describe("parseSamplingRequest", () => {
  it("non-text content summarized as '[<type> content omitted]'", () => {
    const p = parseSamplingRequest("srv", {
      messages: [{ role: "user", content: { type: "image", data: "..." } }],
      maxTokens: 5,
    });
    expect(p?.messages).toEqual([{ role: "user", text: "[image content omitted]" }]);
  });

  it("array content joins text parts and summarizes others", () => {
    const p = parseSamplingRequest("srv", {
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: "a" },
            { type: "image" },
            { type: "text", text: "b" },
          ],
        },
      ],
    });
    expect(p?.messages).toEqual([{ role: "user", text: "a\n[image content omitted]\nb" }]);
  });

  it("maxTokens default 1024", () => {
    const p = parseSamplingRequest("srv", { messages: [textMessage("user", "x")] });
    expect(p?.maxTokens).toBe(1024);
  });

  it("modelHints from modelPreferences.hints[].name", () => {
    const p = parseSamplingRequest("srv", {
      messages: [textMessage("user", "x")],
      modelPreferences: { hints: [{ name: "claude-3" }, { noName: true }, 7, { name: "gpt-4o" }] },
    });
    expect(p?.modelHints).toEqual(["claude-3", "gpt-4o"]);
  });

  it("rejects bad messages (missing, non-map, bad role, non-map/non-list content)", () => {
    expect(parseSamplingRequest("srv", {})).toBeNull();
    expect(parseSamplingRequest("srv", { messages: [] })).toBeNull();
    expect(parseSamplingRequest("srv", { messages: ["nope"] })).toBeNull();
    expect(parseSamplingRequest("srv", { messages: [{ role: "tool", content: { type: "text", text: "t" } }] })).toBeNull();
    expect(parseSamplingRequest("srv", { messages: [{ role: "user", content: "plain" }] })).toBeNull();
  });

  it("preview truncated at 1500 + '…'", () => {
    const long = "a".repeat(3000);
    const p = parseSamplingRequest("srv", {
      systemPrompt: "sys",
      messages: [textMessage("user", long)],
    });
    const preview = p?.preview ?? "";
    expect(preview.length).toBe(SAMPLING_PREVIEW_MAX_CHARS + 1);
    expect(preview.endsWith("…")).toBe(true);
    expect(preview.startsWith("System: sys")).toBe(true);
    expect(preview).toContain("user: ");
  });

  it("preview under limit is trimmed and untruncated", () => {
    const p = parseSamplingRequest("srv", { messages: [textMessage("user", "hello")] });
    expect(p?.preview).toBe("user: hello");
  });

  it("temperature and systemPrompt carried through", () => {
    const p = parseSamplingRequest("srv", {
      messages: [textMessage("user", "x")],
      systemPrompt: "sp",
      temperature: 0.5,
    });
    expect(p?.systemPrompt).toBe("sp");
    expect(p?.temperature).toBe(0.5);
  });
});

describe("elicitation/create", () => {
  const schema = {
    type: "object",
    properties: {
      name: { type: "string", title: "Name", description: "Your name" },
    },
    required: ["name"],
  };
  const params = { message: "Who?", requestedSchema: schema };

  it("without elicitor → {action:'cancel'}", async () => {
    const res = await createClientRequestHandler({})("srv", req("elicitation/create", params));
    expect(res.result).toEqual({ action: "cancel" });
  });

  it("parse rejects non-flat schemas (property type 'object' → null → -32602)", async () => {
    const bad = {
      message: "Who?",
      requestedSchema: {
        type: "object",
        properties: { nested: { type: "object", properties: {} } },
      },
    };
    expect(parseElicitationRequest("srv", bad)).toBeNull();
    const res = await createClientRequestHandler({
      elicitor: async () => ({ action: "accept", content: {} }),
    })("srv", req("elicitation/create", bad));
    expect(res.error?.code).toBe(JSONRPC_INVALID_PARAMS);
    expect(res.error?.message).toBe("elicitation/create: invalid params");
  });

  it("elicitor response validated and passed through", async () => {
    const h: ClientRequestHandlers = {
      elicitor: async (r) => ({ action: "accept", content: { name: "Ada" } }),
    };
    const res = await createClientRequestHandler(h)("srv", req("elicitation/create", params));
    expect(res.result).toEqual({ action: "accept", content: { name: "Ada" } });
  });

  it("parse carries fields, enum values, defaults and required", () => {
    const p = parseElicitationRequest("srv", {
      message: "m",
      requestedSchema: {
        type: "object",
        properties: {
          size: { type: "string", enum: ["small", "large"], default: "small" },
          count: { type: "integer" },
        },
        required: ["size"],
      },
    });
    expect(p?.message).toBe("m");
    expect(p?.fields).toEqual([
      { name: "size", type: "string", enumValues: ["small", "large"], defaultValue: "small" },
      { name: "count", type: "integer", enumValues: [] },
    ]);
    expect(p?.required).toEqual(["size"]);
  });

  it("parse rejects non-string message or non-map schema", () => {
    expect(parseElicitationRequest("srv", { requestedSchema: schema })).toBeNull();
    expect(parseElicitationRequest("srv", { message: "m" })).toBeNull();
    expect(
      parseElicitationRequest("srv", { message: "m", requestedSchema: { type: "array" } }),
    ).toBeNull();
  });
});

describe("validateElicitationResponse", () => {
  const mkReq = (props: Record<string, unknown>, required: string[]): ElicitationRequest => ({
    server: "srv",
    message: "m",
    fields: Object.entries(props).map(([name, v]) => {
      const spec = v as { type: string; enum?: unknown[] };
      return {
        name,
        type: spec.type as "string" | "number" | "integer" | "boolean",
        enumValues: Array.isArray(spec.enum) ? spec.enum.map(String) : [],
      };
    }),
    required,
  });

  it("coerces '42'→42 for integer", () => {
    const req = mkReq({ n: { type: "integer" } }, ["n"]);
    const res = validateElicitationResponse(req, { action: "accept", content: { n: "42" } });
    expect(res).toEqual({ action: "accept", content: { n: 42 } });
  });

  it("coerces '1.5'→1.5 for number and 'true'→true for boolean", () => {
    const req = mkReq({ n: { type: "number" }, b: { type: "boolean" } }, ["n", "b"]);
    const res = validateElicitationResponse(req, { action: "accept", content: { n: "1.5", b: "true" } });
    expect(res).toEqual({ action: "accept", content: { n: 1.5, b: true } });
  });

  it("rejects enum violation → cancel", () => {
    const req = mkReq({ size: { type: "string", enum: ["small", "large"] } }, ["size"]);
    const res = validateElicitationResponse(req, { action: "accept", content: { size: "huge" } });
    expect(res).toEqual({ action: "cancel" });
  });

  it("missing required → cancel", () => {
    const req = mkReq({ name: { type: "string" } }, ["name"]);
    const res = validateElicitationResponse(req, { action: "accept", content: {} });
    expect(res).toEqual({ action: "cancel" });
  });

  it("missing optional is skipped, unparseable optional skipped", () => {
    const req = mkReq({ n: { type: "integer" }, s: { type: "string" } }, []);
    const res = validateElicitationResponse(req, { action: "accept", content: { s: "ok", n: "zzz" } });
    expect(res).toEqual({ action: "accept", content: { s: "ok" } });
  });

  it("decline and cancel pass through unchanged", () => {
    const req = mkReq({ name: { type: "string" } }, ["name"]);
    const decline: ElicitationResponse = { action: "decline" };
    const cancel: ElicitationResponse = { action: "cancel" };
    expect(validateElicitationResponse(req, decline)).toEqual(decline);
    expect(validateElicitationResponse(req, cancel)).toEqual(cancel);
  });
});

describe("unknown method", () => {
  it("→ -32601 'Method not found: <m>'", async () => {
    const res = await createClientRequestHandler({})("srv", req("tools/unknown"));
    expect(res.error?.code).toBe(JSONRPC_METHOD_NOT_FOUND);
    expect(res.error?.message).toBe("Method not found: tools/unknown");
  });
});

describe("handler never throws", () => {
  it("throwing elicitor → -32603", async () => {
    const h: ClientRequestHandlers = {
      elicitor: async () => {
        throw new Error("boom");
      },
    };
    const res = await createClientRequestHandler(h)(
      "srv",
      req("elicitation/create", { message: "m", requestedSchema: { type: "object", properties: {} } }),
    );
    expect(res.error?.code).toBe(JSONRPC_INTERNAL_ERROR);
    expect(res.error?.message).toBe("client error handling elicitation/create");
  });

  it("throwing roots provider → -32603, never rejects", async () => {
    const h: ClientRequestHandlers = {
      rootsProvider: () => {
        throw new Error("boom");
      },
    };
    const res = await createClientRequestHandler(h)("srv", req("roots/list"));
    expect(res.error?.code).toBe(JSONRPC_INTERNAL_ERROR);
  });
});

describe("createNotificationHandler", () => {
  function sink(): { sink: NotificationSink; logs: Parameters<NotificationSink["log"]>[0][]; progress: { server: string; token: string }[] } {
    const logs: Parameters<NotificationSink["log"]>[0][] = [];
    const progress: { server: string; token: string }[] = [];
    const s: NotificationSink = {
      log: (e) => logs.push(e),
      progress: (p) => progress.push(p),
    };
    return { sink: s, logs, progress };
  }

  it("notifications/message recorded per server capped at 200", () => {
    const { sink: s, logs } = sink();
    const handle = createNotificationHandler(s);
    for (let i = 0; i < MAX_SERVER_LOGS + 5; i++) {
      expect(handle("srv", { jsonrpc: "2.0", method: "notifications/message", params: { level: "info", data: i } })).toBe(true);
    }
    // The sink streams every entry; the handler's own ring is what stays bounded.
    expect(logs.length).toBe(MAX_SERVER_LOGS + 5);
    expect(handle.logsFor("srv")).toHaveLength(MAX_SERVER_LOGS);
    // The cap is per server: another server's entries are unaffected.
    handle("other", { jsonrpc: "2.0", method: "notifications/message", params: { level: "error" } });
    expect(handle.logsFor("other")).toHaveLength(1);
    expect(handle.logsFor("srv")).toHaveLength(MAX_SERVER_LOGS);
  });

  it("log entry carries level, logger, data, timestamp; level defaults to info", () => {
    const { sink: s, logs } = sink();
    const handle = createNotificationHandler(s);
    handle("srv", { jsonrpc: "2.0", method: "notifications/message", params: { level: "warning", logger: "app", data: { x: 1 } } });
    handle("srv", { jsonrpc: "2.0", method: "notifications/message", params: {} });
    expect(logs[0]).toMatchObject({ server: "srv", level: "warning", logger: "app", data: { x: 1 } });
    expect(typeof logs[0]!.at).toBe("string");
    expect(logs[1]).toMatchObject({ server: "srv", level: "info", logger: undefined });
    expect(logs[1]!.data).toBeUndefined();
  });

  it("notifications/progress routed with token/progress/total", () => {
    const { sink: s, progress } = sink();
    const handle = createNotificationHandler(s);
    expect(
      handle("srv", {
        jsonrpc: "2.0",
        method: "notifications/progress",
        params: { progressToken: "tok-1", progress: 3, total: 10, message: "working" },
      }),
    ).toBe(true);
    expect(progress).toEqual([{ server: "srv", token: "tok-1", progress: 3, total: 10, message: "working" }]);
  });

  it("progress with missing token or non-numeric progress is still handled (consumed)", () => {
    const { sink: s, progress } = sink();
    const handle = createNotificationHandler(s);
    expect(handle("srv", { jsonrpc: "2.0", method: "notifications/progress", params: { progress: 1 } })).toBe(true);
    expect(handle("srv", { jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: "t" } })).toBe(true);
    expect(progress).toEqual([]);
  });

  it("unhandled notification returns false", () => {
    const { sink: s } = sink();
    const handle = createNotificationHandler(s);
    expect(handle("srv", { jsonrpc: "2.0", method: "notifications/initialized" })).toBe(false);
    expect(handle("srv", { jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 1 } })).toBe(false);
  });
});
