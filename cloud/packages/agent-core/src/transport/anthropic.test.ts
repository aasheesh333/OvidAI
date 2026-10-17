import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, expect, it } from "vitest";
import type { AgentMessage, AgentRequest, ToolSpec } from "../types.js";
import type { EgressFetch } from "../ports.js";
import { markCacheBreakpoints } from "../promptCache.js";
import { TerminalModelError, TransientModelError } from "./errors.js";
import { convertMessagesToAnthropic, createAnthropicTransport } from "./anthropic.js";

// ---------------------------------------------------------------------------
// Mock Anthropic: a local http server speaking the Messages-API SSE dialect
// (named events: message_start / content_block_* / message_delta / message_stop
// / error) — same harness shape as openai.test.ts, per the brief's Step 1.
// No real network, no services — always runs.
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

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

async function startMock(
  handler: (req: IncomingMessage, res: ServerResponse) => void | Promise<void>,
): Promise<string> {
  server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      let body: unknown = text;
      try {
        body = JSON.parse(text);
      } catch {
        // keep raw text
      }
      lastRequest = { method: req.method ?? "", url: req.url ?? "", headers: req.headers, body };
      void handler(req, res);
    });
  });
  await new Promise<void>((resolve) => server!.listen(0, "127.0.0.1", resolve));
  const { port } = server.address() as AddressInfo;
  baseUrl = `http://127.0.0.1:${port}`;
  return baseUrl;
}

afterEach(async () => {
  if (server !== undefined) {
    const s = server;
    server = undefined;
    // undici keeps pooled sockets alive — force them closed so server.close()
    // (and vitest) never hangs on idle keep-alive connections.
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

/** One named Anthropic SSE event. */
function sse(res: ServerResponse, event: string, payload: unknown): void {
  res.write(`event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`);
}

const TOOLS: ToolSpec[] = [
  {
    name: "run_shell",
    description: "Run a shell command",
    parameters: { type: "object", properties: { cmd: { type: "string" } }, required: ["cmd"] },
  },
];

function agentReq(overrides?: Partial<AgentRequest>): AgentRequest {
  return {
    model: "claude-test-model",
    baseUrl,
    apiKey: "sk-ant-test",
    system: [{ role: "system", content: "sys" }],
    messages: [{ role: "user", content: "hi" }],
    tools: [],
    cacheMode: "none",
    ...overrides,
  };
}

// The BYOK egress seam: the transport takes an EgressFetch, never raw fetch.
const egress: EgressFetch = (url, init) => fetch(url, init);

function streamCall(
  overrides?: Partial<AgentRequest> & {
    onTextDelta?: (t: string) => void;
    onThinkingDelta?: (t: string) => void;
  },
) {
  const deltas: string[] = [];
  const thinking: string[] = [];
  const transport = createAnthropicTransport(egress);
  const controller = new AbortController();
  const promise = transport.stream(
    agentReq(overrides),
    {
      onTextDelta: overrides?.onTextDelta ?? ((t) => deltas.push(t)),
      onThinkingDelta: overrides?.onThinkingDelta ?? ((t) => thinking.push(t)),
    },
    controller.signal,
  );
  return { deltas, thinking, controller, promise };
}

/** A well-formed empty message: start → (blocks) → stop_reason → message_stop. */
function endTurn(res: ServerResponse, stopReason = "end_turn"): void {
  sse(res, "message_delta", { type: "message_delta", delta: { stop_reason: stopReason }, usage: { output_tokens: 7 } });
  sse(res, "message_stop", { type: "message_stop" });
}

function captureError(p: Promise<unknown>): Promise<unknown> {
  return p.then(
    () => null,
    (e: unknown) => e,
  );
}

// ---------------------------------------------------------------------------

it("is an anthropic-format AgentTransport", () => {
  expect(createAnthropicTransport(egress).apiFormat).toBe("anthropic");
});

// (a) text stream ------------------------------------------------------------

it("(a) streams text deltas, concatenates content, maps end_turn → finishReason stop, and normalizes usage", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    sse(res, "message_start", {
      type: "message_start",
      message: { usage: { input_tokens: 10, cache_read_input_tokens: 4, cache_creation_input_tokens: 1 } },
    });
    sse(res, "content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
    // one delta split mid-line across TCP chunks — the reader must buffer
    res.write('event: content_block_delta\ndata: {"type":"content_block_del');
    res.write('ta","index":0,"delta":{"type":"text_delta","text":"Hello"}}\n\n');
    sse(res, "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: " world" } });
    sse(res, "content_block_stop", { type: "content_block_stop", index: 0 });
    endTurn(res);
    res.end();
  });

  const { deltas, promise } = streamCall();
  const result = await promise;
  expect(deltas).toEqual(["Hello", " world"]);
  expect(result).toEqual({
    content: "Hello world",
    thinking: "",
    toolCalls: [],
    finishReason: "stop",
    usage: { inputTokens: 15, outputTokens: 7, cacheReadTokens: 4, cacheWriteTokens: 1 },
  });
});

it("(a) thinking blocks stream through onThinkingDelta and accumulate; signature deltas are ignored", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    sse(res, "message_start", { type: "message_start", message: { usage: { input_tokens: 5 } } });
    sse(res, "content_block_start", { type: "content_block_start", index: 0, content_block: { type: "thinking", thinking: "" } });
    sse(res, "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "pondering " } });
    sse(res, "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "signature_delta", signature: "EqMC..." } });
    sse(res, "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "thinking_delta", thinking: "hard" } });
    sse(res, "content_block_stop", { type: "content_block_stop", index: 0 });
    sse(res, "content_block_start", { type: "content_block_start", index: 1, content_block: { type: "text", text: "" } });
    sse(res, "content_block_delta", { type: "content_block_delta", index: 1, delta: { type: "text_delta", text: "answer" } });
    sse(res, "content_block_stop", { type: "content_block_stop", index: 1 });
    endTurn(res);
    res.end();
  });

  const { deltas, thinking, promise } = streamCall();
  const result = await promise;
  expect(thinking).toEqual(["pondering ", "hard"]);
  expect(deltas).toEqual(["answer"]);
  expect(result.thinking).toBe("pondering hard");
  expect(result.content).toBe("answer");
});

// (b) tool_use ---------------------------------------------------------------

it("(b) reassembles a tool call across input_json_delta fragments: exact id/name/args, finishReason tool_calls", async () => {
  await startMock(async (_req, res) => {
    sseHead(res);
    sse(res, "message_start", { type: "message_start", message: { usage: { input_tokens: 5 } } });
    sse(res, "content_block_start", { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_1", name: "run_shell", input: {} } });
    sse(res, "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"cmd"' } });
    await sleep(5);
    sse(res, "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: ':"ls"}' } });
    sse(res, "content_block_stop", { type: "content_block_stop", index: 0 });
    endTurn(res, "tool_use");
    res.end();
  });

  const { deltas, promise } = streamCall();
  const result = await promise;
  expect(deltas).toEqual([]);
  expect(result.content).toBe("");
  expect(result.toolCalls).toEqual([{ id: "toolu_1", name: "run_shell", args: { cmd: "ls" } }]);
  expect(result.finishReason).toBe("tool_calls");
});

it("(b) two parallel tool_use blocks finalize in index order; a block with no input_json_delta gets args {}", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    sse(res, "content_block_start", { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_a", name: "run_shell", input: {} } });
    sse(res, "content_block_start", { type: "content_block_start", index: 1, content_block: { type: "tool_use", id: "toolu_b", name: "get_time", input: {} } });
    sse(res, "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"cmd":"ls"}' } });
    sse(res, "content_block_stop", { type: "content_block_stop", index: 0 });
    sse(res, "content_block_stop", { type: "content_block_stop", index: 1 }); // no args fragments at all
    endTurn(res, "tool_use");
    res.end();
  });

  const { promise } = streamCall();
  const result = await promise;
  expect(result.toolCalls).toEqual([
    { id: "toolu_a", name: "run_shell", args: { cmd: "ls" } },
    { id: "toolu_b", name: "get_time", args: {} },
  ]);
});

it("(b) malformed accumulated tool-call JSON at content_block_stop → TerminalModelError naming the tool", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    sse(res, "content_block_start", { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: "toolu_x", name: "run_shell", input: {} } });
    sse(res, "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: '{"cmd": ' } });
    sse(res, "content_block_stop", { type: "content_block_stop", index: 0 });
    endTurn(res, "tool_use");
    res.end();
  });

  const err = await captureError(streamCall().promise);
  expect(err).toBeInstanceOf(TerminalModelError);
  expect(err).not.toBeInstanceOf(TransientModelError);
  expect((err as Error).message).toMatch(/run_shell/);
});

it("(b) maps max_tokens stop_reason → finishReason length", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    sse(res, "content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
    sse(res, "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "trunc" } });
    endTurn(res, "max_tokens");
    res.end();
  });
  const { promise } = streamCall();
  expect((await promise).finishReason).toBe("length");
});

// (c) request-shape pin --------------------------------------------------------

it("(c) POSTs the Anthropic streaming request shape (path, headers, max_tokens default 8192, system blocks, tools input_schema)", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    endTurn(res);
    res.end();
  });
  await streamCall({ tools: TOOLS, messages: [{ role: "user", content: "hi" }] }).promise;

  expect(lastRequest).toBeDefined();
  expect(lastRequest!.method).toBe("POST");
  expect(lastRequest!.url).toBe("/v1/messages");
  expect(lastRequest!.headers["x-api-key"]).toBe("sk-ant-test");
  expect(lastRequest!.headers["anthropic-version"]).toBe("2023-06-01");
  expect(lastRequest!.headers["content-type"]).toBe("application/json");
  expect(lastRequest!.headers.accept).toBe("text/event-stream");
  expect(lastRequest!.body).toEqual({
    model: "claude-test-model",
    max_tokens: 8192,
    stream: true,
    system: [{ type: "text", text: "sys" }],
    messages: [{ role: "user", content: "hi" }],
    tools: [{ name: "run_shell", description: "Run a shell command", input_schema: TOOLS[0].parameters }],
  });
});

it("(c) trims trailing slashes on baseUrl before appending /v1/messages", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    endTurn(res);
    res.end();
  });
  await streamCall({ baseUrl: `${baseUrl}//` }).promise;
  expect(lastRequest!.url).toBe("/v1/messages");
});

it("(c) passes maxTokens through and includes temperature when effort is not high", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    endTurn(res);
    res.end();
  });
  await streamCall({ maxTokens: 128, temperature: 0.3 }).promise;
  const body = lastRequest!.body as Record<string, unknown>;
  expect(body.max_tokens).toBe(128);
  expect(body.temperature).toBe(0.3);
});

it("(c) cacheMode anthropicNative: exactly the Task-3-marked blocks carry cache_control (≤4, never a volatile block)", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    endTurn(res);
    res.end();
  });
  const system: AgentMessage[] = [
    { role: "system", content: "base" },
    { role: "system", content: "rules" },
  ];
  const messages: AgentMessage[] = [
    { role: "user", content: "q1" },
    { role: "assistant", content: "a1" },
    { role: "user", content: "q2" },
    { role: "user", content: "now: 12:00", volatile: true },
  ];
  const marked = markCacheBreakpoints(system, messages, TOOLS);
  await streamCall({ cacheMode: "anthropicNative", system: marked.system, messages: marked.messages, tools: marked.tools }).promise;

  const body = lastRequest!.body as Record<string, unknown>;
  // Task 3 marked: last tool, last system row (merges with its neighbor into
  // one block), and the last two non-volatile messages — exactly 4 marks, and
  // the trailing volatile row carries none.
  expect(body.system).toEqual([{ type: "text", text: "base\n\nrules", cache_control: { type: "ephemeral" } }]);
  expect(body.messages).toEqual([
    { role: "user", content: "q1" },
    { role: "assistant", content: [{ type: "text", text: "a1", cache_control: { type: "ephemeral" } }] },
    { role: "user", content: [{ type: "text", text: "q2", cache_control: { type: "ephemeral" } }] },
    { role: "user", content: "now: 12:00" },
  ]);
  expect(body.tools).toEqual([
    { name: "run_shell", description: "Run a shell command", input_schema: TOOLS[0].parameters, cache_control: { type: "ephemeral" } },
  ]);
  expect(JSON.stringify(body).match(/"cache_control"/g)).toHaveLength(4);
});

it("(c) cacheMode none strips marks from the wire (Dart caps.marks gating)", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    endTurn(res);
    res.end();
  });
  const marked = markCacheBreakpoints([{ role: "system", content: "s" }], [{ role: "user", content: "q" }], TOOLS);
  await streamCall({ cacheMode: "none", system: marked.system, messages: marked.messages, tools: marked.tools }).promise;
  expect(JSON.stringify(lastRequest!.body).match(/"cache_control"/g)).toBeNull();
});

// (d) thinking budget ---------------------------------------------------------

it("(d) effort high → thinking budget 4096 and NO temperature even when provided", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    endTurn(res);
    res.end();
  });
  await streamCall({ effort: "high", temperature: 0.7 }).promise;
  const body = lastRequest!.body as Record<string, unknown>;
  expect(body.thinking).toEqual({ type: "enabled", budget_tokens: 4096 });
  expect("temperature" in body).toBe(false);
});

// (e) error taxonomy ----------------------------------------------------------

it("(e) HTTP 529 overloaded_error → TransientModelError carrying status and body excerpt", async () => {
  await startMock((_req, res) => {
    res.writeHead(529, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { type: "overloaded_error", message: "Overloaded" } }));
  });
  const err = await captureError(streamCall().promise);
  expect(err).toBeInstanceOf(TransientModelError);
  expect(err).not.toBeInstanceOf(TerminalModelError);
  expect((err as Error).message).toMatch(/529/);
  expect((err as Error).message).toMatch(/Overloaded/);
});

it("(e) HTTP 429 → TransientModelError; HTTP 400 → TerminalModelError", async () => {
  await startMock((_req, res) => {
    res.writeHead(429, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: "rate limit exceeded" } }));
  });
  const err429 = await captureError(streamCall().promise);
  expect(err429).toBeInstanceOf(TransientModelError);
  expect((err429 as Error).message).toMatch(/rate limit exceeded/);

  await startMock((_req, res) => {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: "unknown model" } }));
  });
  const err400 = await captureError(streamCall().promise);
  expect(err400).toBeInstanceOf(TerminalModelError);
  expect(err400).not.toBeInstanceOf(TransientModelError);
});

it("(e) HTTP 401 → TerminalModelError", async () => {
  await startMock((_req, res) => {
    res.writeHead(401, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { type: "authentication_error", message: "invalid x-api-key" } }));
  });
  const err = await captureError(streamCall().promise);
  expect(err).toBeInstanceOf(TerminalModelError);
  expect(err).not.toBeInstanceOf(TransientModelError);
});

it("(e) SSE event: error mid-stream (overloaded_error) → TransientModelError", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    sse(res, "content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
    sse(res, "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "par" } });
    sse(res, "error", { type: "error", error: { type: "overloaded_error", message: "Overloaded backend" } });
    res.end();
  });
  const err = await captureError(streamCall().promise);
  expect(err).toBeInstanceOf(TransientModelError);
  expect(err).not.toBeInstanceOf(TerminalModelError);
  expect((err as Error).message).toMatch(/Overloaded backend/);
});

it("(e) socket destroyed mid-stream → TransientModelError", async () => {
  await startMock((req, res) => {
    sseHead(res);
    sse(res, "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "par" } });
    setTimeout(() => {
      req.socket.destroy();
      res.destroy();
    }, 10);
  });
  await expect(streamCall().promise).rejects.toBeInstanceOf(TransientModelError);
});

it("(e) stream ends cleanly WITHOUT message_stop → TransientModelError (truncation parity with P1)", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    sse(res, "content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "half" } });
    res.end();
  });
  await expect(streamCall().promise).rejects.toBeInstanceOf(TransientModelError);
});

// (f) convertMessagesToAnthropic ----------------------------------------------

it("(f) tool rows → user message(s) with tool_result blocks; consecutive tool rows merge into ONE user turn", () => {
  const { system, messages } = convertMessagesToAnthropic([
    { role: "system", content: "You are Ovid." },
    { role: "system", content: "Be terse." },
    { role: "user", content: "hi" },
    { role: "assistant", content: "working", toolCalls: [{ id: "call_1", name: "run_shell", args: { cmd: "ls" } }] },
    { role: "tool", toolCallId: "call_1", content: "a.txt" },
    { role: "tool", toolCallId: "call_2", content: "b.txt" },
    { role: "user", content: "thanks" },
    { role: "system", content: "post-system" },
  ]);
  // consecutive system rows merge in order ("\n\n" join, Dart parity);
  // a later non-consecutive system row becomes its own block
  expect(system).toEqual([
    { type: "text", text: "You are Ovid.\n\nBe terse." },
    { type: "text", text: "post-system" },
  ]);
  expect(messages).toEqual([
    { role: "user", content: "hi" },
    // assistant text + tool_use blocks, text first (Dart parity)
    { role: "assistant", content: [{ type: "text", text: "working" }, { type: "tool_use", id: "call_1", name: "run_shell", input: { cmd: "ls" } }] },
    // consecutive tool rows share one user turn, one tool_result per call
    { role: "user", content: [
      { type: "tool_result", tool_use_id: "call_1", content: "a.txt" },
      { type: "tool_result", tool_use_id: "call_2", content: "b.txt" },
    ] },
    { role: "user", content: "thanks" },
  ]);
});

it("(f) volatile rows land LAST and are never cache-marked (volatile system rows ride the tail as user turns)", () => {
  const { system, messages } = convertMessagesToAnthropic([
    { role: "user", content: "q" },
    { role: "user", content: "volatile tail", volatile: true },
    { role: "system", content: "volatile sys", volatile: true },
    { role: "assistant", content: "a" },
    { role: "user", content: "marked but volatile", volatile: true, cacheControl: { type: "ephemeral" } },
  ]);
  expect(system).toEqual([]);
  expect(messages).toEqual([
    { role: "user", content: "q" },
    { role: "assistant", content: [{ type: "text", text: "a" }] },
    { role: "user", content: "volatile tail" },
    { role: "user", content: "volatile sys" },
    { role: "user", content: "marked but volatile" },
  ]);
});

it("(f) cacheControl marks serialize as wire cache_control on the marked block (ttl carried)", () => {
  const { system, messages } = convertMessagesToAnthropic([
    { role: "system", content: "s1", cacheControl: { type: "ephemeral" } },
    { role: "user", content: "q", cacheControl: { type: "ephemeral", ttl: "1h" } },
    { role: "assistant", content: "a", cacheControl: { type: "ephemeral" } },
  ]);
  expect(system).toEqual([{ type: "text", text: "s1", cache_control: { type: "ephemeral" } }]);
  expect(messages).toEqual([
    { role: "user", content: [{ type: "text", text: "q", cache_control: { type: "ephemeral", ttl: "1h" } }] },
    { role: "assistant", content: [{ type: "text", text: "a", cache_control: { type: "ephemeral" } }] },
  ]);
});

it("(f) cacheControl:false suppresses marks (the transport's cacheMode gating)", () => {
  const { system, messages } = convertMessagesToAnthropic(
    [
      { role: "system", content: "s1", cacheControl: { type: "ephemeral" } },
      { role: "user", content: "q", cacheControl: { type: "ephemeral" } },
    ],
    { cacheControl: false },
  );
  expect(system).toEqual([{ type: "text", text: "s1" }]);
  expect(messages).toEqual([{ role: "user", content: "q" }]);
});
