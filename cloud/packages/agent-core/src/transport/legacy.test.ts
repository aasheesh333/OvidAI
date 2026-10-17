import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, expect, it } from "vitest";
import type { AgentRequest, ToolSpec } from "../types.js";
import {
  adaptLegacyTransport,
  createLegacyOpenAiTransport,
  type LegacyChatMessage,
  type LegacyModelTransport,
} from "./legacy.js";

// ---------------------------------------------------------------------------
// legacy.ts: the P2 ChatMessage/ModelTransport shapes (raw `arguments`
// strings, tools in the request, toolCalls in the result) adapted onto the
// P3 AgentTransport seam — plus the P1/P2 createOpenAiTransport rebuilt over
// the agent transport.
// ---------------------------------------------------------------------------

interface CapturedRequest {
  method: string;
  url: string;
  headers: IncomingMessage["headers"];
  body: unknown;
}

let server: Server | undefined;
let baseUrl = "";
let lastRequest: CapturedRequest | undefined;

afterEach(async () => {
  if (server !== undefined) {
    const s = server;
    server = undefined;
    s.closeAllConnections();
    await new Promise<void>((resolve) => s.close(() => resolve()));
  }
  lastRequest = undefined;
});

function sseHead(res: ServerResponse): void {
  res.writeHead(200, {
    "content-type": "text/event-stream",
    "cache-control": "no-cache",
  });
}

const TOOLS: ToolSpec[] = [
  {
    name: "run_shell",
    description: "Run a shell command",
    parameters: { type: "object", properties: { cmd: { type: "string" } }, required: ["cmd"] },
  },
];

const WIRE_TOOLS = [
  { type: "function", function: TOOLS[0]! },
];

function agentReq(overrides?: Partial<AgentRequest>): AgentRequest {
  return {
    model: "ovid-test-model",
    baseUrl: "http://legacy.example",
    apiKey: "sk-test",
    system: [{ role: "system", content: "sys" }],
    messages: [
      { role: "user", content: "hi" },
      { role: "assistant", content: "", toolCalls: [{ id: "c1", name: "run_shell", args: { cmd: "ls" } }] },
      { role: "tool", toolCallId: "c1", content: "a.txt" },
    ],
    tools: TOOLS,
    cacheMode: "none",
    ...overrides,
  };
}

// ---------------------------------------------------------------------------

it("adaptLegacyTransport maps system+messages into the legacy request (system row first), passes tools through, fires onDelta, and returns the transport's toolCalls as parsed args", async () => {
  let captured: Parameters<LegacyModelTransport["stream"]>[0] | undefined;
  const legacy: LegacyModelTransport = {
    async stream(req, h, _signal) {
      captured = req;
      h.onDelta("a");
      h.onDelta("b");
      return {
        finishReason: "tool_calls",
        toolCalls: [{ id: "c1", name: "run_shell", arguments: '{"cmd":"ls"}' }],
      };
    },
  };

  const transport = adaptLegacyTransport(legacy);
  expect(transport.apiFormat).toBe("openai");

  const deltas: string[] = [];
  const result = await transport.stream(
    agentReq(),
    { onTextDelta: (t) => deltas.push(t) },
    new AbortController().signal,
  );

  expect(captured).toBeDefined();
  expect(captured!.baseUrl).toBe("http://legacy.example");
  expect(captured!.apiKey).toBe("sk-test");
  expect(captured!.model).toBe("ovid-test-model");
  expect(captured!.messages).toEqual([
    { role: "system", content: "sys" },
    { role: "user", content: "hi" },
    { role: "assistant", content: "", toolCalls: [{ id: "c1", name: "run_shell", arguments: '{"cmd":"ls"}' }] },
    { role: "tool", content: "a.txt", toolCallId: "c1" },
  ]);
  expect(captured!.tools).toEqual(WIRE_TOOLS);
  expect(deltas).toEqual(["a", "b"]);
  expect(result).toEqual({
    content: "ab",
    thinking: "",
    toolCalls: [{ id: "c1", name: "run_shell", args: { cmd: "ls" } }],
    finishReason: "tool_calls",
    usage: null,
  });
});

it("adaptLegacyTransport omits the legacy tools key when the agent request carries no tools (v0 body shape)", async () => {
  let captured: Parameters<LegacyModelTransport["stream"]>[0] | undefined;
  const legacy: LegacyModelTransport = {
    async stream(req, _h, _signal) {
      captured = req;
      return { finishReason: "stop", toolCalls: [] };
    },
  };
  const transport = adaptLegacyTransport(legacy);
  await transport.stream(agentReq({ tools: [] }), { onTextDelta: () => {} }, new AbortController().signal);
  expect(captured!.tools).toBeUndefined();
});

it("createLegacyOpenAiTransport satisfies the exact P2 ModelTransport signature (tools in the request, raw-arguments toolCalls in the result) against the SSE mock", async () => {
  server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      lastRequest = {
        method: req.method ?? "",
        url: req.url ?? "",
        headers: req.headers,
        body: JSON.parse(Buffer.concat(chunks).toString("utf8")),
      };
      sseHead(res);
      res.write('data: {"choices":[{"delta":{"content":"think"},"finish_reason":null}]}\n\n');
      res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"run_shell","arguments":"{\\"cm"}}]},"finish_reason":null}]}\n\n');
      res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"d\\":\\"ls\\"}"}}]},"finish_reason":null}]}\n\n');
      res.write('data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n');
      res.end("data: [DONE]\n\n");
    });
  });
  await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

  const transport = createLegacyOpenAiTransport();
  const messages: LegacyChatMessage[] = [
    { role: "system", content: "sys" },
    { role: "user", content: "list files" },
    { role: "assistant", content: "", toolCalls: [{ id: "c1", name: "run_shell", arguments: '{"cmd":"ls"}' }] },
    { role: "tool", toolCallId: "c1", content: "a.txt" },
  ];
  const deltas: string[] = [];
  const result = await transport.stream(
    {
      baseUrl,
      apiKey: "sk-test",
      model: "ovid-test-model",
      messages,
      tools: WIRE_TOOLS,
    },
    { onDelta: (t) => deltas.push(t) },
    new AbortController().signal,
  );

  expect(lastRequest!.method).toBe("POST");
  expect(lastRequest!.url).toBe("/chat/completions");
  expect(lastRequest!.headers.authorization).toBe("Bearer sk-test");
  expect(lastRequest!.body).toEqual({
    model: "ovid-test-model",
    messages: [
      { role: "system", content: "sys" },
      { role: "user", content: "list files" },
      { role: "assistant", content: "", tool_calls: [{ id: "c1", type: "function", function: { name: "run_shell", arguments: '{"cmd":"ls"}' } }] },
      { role: "tool", content: "a.txt", tool_call_id: "c1" },
    ],
    tools: WIRE_TOOLS,
    stream: true,
    stream_options: { include_usage: true },
  });
  expect(deltas).toEqual(["think"]);
  expect(result).toEqual({
    finishReason: "tool_calls",
    toolCalls: [{ id: "call_1", name: "run_shell", arguments: '{"cmd":"ls"}' }],
  });
});

it("createLegacyOpenAiTransport rethrows the model error taxonomy unwrapped (429 → TransientModelError)", async () => {
  server = createServer((_req, res) => {
    res.writeHead(429, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: "rate limit exceeded" } }));
  });
  await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
  baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;

  const transport = createLegacyOpenAiTransport();
  await expect(
    transport.stream(
      { baseUrl, apiKey: "sk-test", model: "m", messages: [{ role: "user", content: "hi" }] },
      { onDelta: () => {} },
      new AbortController().signal,
    ),
  ).rejects.toMatchObject({ name: "TransientModelError" });
});
