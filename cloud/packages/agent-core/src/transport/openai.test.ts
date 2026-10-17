import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, expect, it } from "vitest";
import type { AgentRequest, ToolSpec } from "../types.js";
import { TerminalModelError, TransientModelError } from "./errors.js";
import { createOpenAiAgentTransport } from "./openai.js";

// ---------------------------------------------------------------------------
// Mock LiteLLM: a local http server speaking the [OI] SSE dialect — same
// harness shape as P1's worker liteLlm.test.ts, re-pinned at the transport's
// new home in agent-core. No real network, no services — always runs.
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

const TOOLS: ToolSpec[] = [
  {
    name: "run_shell",
    description: "Run a shell command",
    parameters: { type: "object", properties: { cmd: { type: "string" } }, required: ["cmd"] },
  },
];

function agentReq(overrides?: Partial<AgentRequest>): AgentRequest {
  return {
    model: "ovid-test-model",
    baseUrl,
    apiKey: "sk-test",
    system: [{ role: "system", content: "sys" }],
    messages: [{ role: "user", content: "hi" }],
    tools: [],
    cacheMode: "none",
    ...overrides,
  };
}

function streamCall(
  overrides?: Partial<AgentRequest> & {
    onTextDelta?: (t: string) => void;
    onThinkingDelta?: (t: string) => void;
  },
) {
  const deltas: string[] = [];
  const thinking: string[] = [];
  const transport = createOpenAiAgentTransport(fetch);
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

// ---------------------------------------------------------------------------

it("is an openai-format AgentTransport", () => {
  expect(createOpenAiAgentTransport(fetch).apiFormat).toBe("openai");
});

it("POSTs the agent streaming request shape (path, auth, system rows first, tools wire shape, temperature/max_tokens)", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.end("data: [DONE]\n\n");
  });
  await streamCall({
    messages: [{ role: "user", content: "hi" }, { role: "assistant", content: "", toolCalls: [{ id: "c1", name: "run_shell", args: { cmd: "ls" } }] }, { role: "tool", toolCallId: "c1", content: "a.txt" }],
    tools: TOOLS,
    temperature: 0.2,
    maxTokens: 128,
  }).promise;

  expect(lastRequest).toBeDefined();
  expect(lastRequest!.method).toBe("POST");
  expect(lastRequest!.url).toBe("/chat/completions");
  expect(lastRequest!.headers.authorization).toBe("Bearer sk-test");
  expect(lastRequest!.headers["content-type"]).toBe("application/json");
  expect(lastRequest!.body).toEqual({
    model: "ovid-test-model",
    messages: [
      { role: "system", content: "sys" },
      { role: "user", content: "hi" },
      { role: "assistant", content: "", tool_calls: [{ id: "c1", type: "function", function: { name: "run_shell", arguments: '{"cmd":"ls"}' } }] },
      { role: "tool", content: "a.txt", tool_call_id: "c1" },
    ],
    tools: [{ type: "function", function: TOOLS[0]! }],
    stream: true,
    stream_options: { include_usage: true },
    temperature: 0.2,
    max_tokens: 128,
  });
});

it("omits the tools/temperature/max_tokens keys entirely when unset (v0 body shape)", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.end("data: [DONE]\n\n");
  });
  await streamCall().promise;
  expect(lastRequest!.body).toEqual({
    model: "ovid-test-model",
    messages: [{ role: "system", content: "sys" }, { role: "user", content: "hi" }],
    stream: true,
    stream_options: { include_usage: true },
  });
});

it("trims trailing slashes on baseUrl before appending /chat/completions", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.end("data: [DONE]\n\n");
  });
  await streamCall({ baseUrl: `${baseUrl}//` }).promise;
  expect(lastRequest!.url).toBe("/chat/completions");
});

it("sends the prompt_cache_key header when the request carries one (ruling R3)", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.end("data: [DONE]\n\n");
  });
  await streamCall({ promptCacheKey: "sess-123" }).promise;
  expect(lastRequest!.headers["prompt_cache_key"]).toBe("sess-123");
});

it("omits the prompt_cache_key header when the request has no cache key", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.end("data: [DONE]\n\n");
  });
  await streamCall().promise;
  expect(lastRequest!.headers["prompt_cache_key"]).toBeUndefined();
});

it("concatenates text deltas exactly when the SSE arrives in awkward chunks; empty deltas never fire", async () => {
  await startMock(async (_req, res) => {
    sseHead(res);
    // 1. split MID-`data:` line AND mid-JSON (buffering across chunks)
    res.write('data: {"choices":[{"delta":{"con');
    await sleep(5);
    res.write('tent":"Hello"},"finish_reason":null}]}\n\n');
    // 2. keep-alive comment + a blank line (both must be skipped)
    res.write(": keep-alive\n\n");
    await sleep(5);
    res.write("\n");
    // 3. empty-string delta must NOT reach onTextDelta
    res.write('data: {"choices":[{"delta":{"content":""},"finish_reason":null}]}\n\n');
    // 4. a single SSE event split across TCP chunks mid-line, CRLF terminated
    res.write('data: {"choices":[{"delta":{"content":" wor');
    await sleep(5);
    res.write('ld"},"finish_reason":null}]}\r\n\r\n');
    // 5. a multi-byte character split across TCP segments (streaming decode)
    const emoji = Buffer.from(
      'data: {"choices":[{"delta":{"content":"🌊 wave"},"finish_reason":null}]}\n\n',
      "utf8",
    );
    res.write(emoji.subarray(0, 41)); // cuts the 4-byte emoji in half
    await sleep(5);
    res.write(emoji.subarray(41));
    // 6. garbage (unparseable) line: skipped, streaming continues
    res.write('data: {broken-json\n\n');
    // 7. finish_reason on a delta-less final chunk, then [DONE]
    res.write('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n');
    await sleep(5);
    res.write("data: [DONE]\n\n");
    res.end();
  });

  const { deltas, promise } = streamCall();
  const result = await promise;
  expect(deltas).toEqual(["Hello", " world", "🌊 wave"]);
  expect(result).toEqual({
    content: "Hello world🌊 wave",
    thinking: "",
    toolCalls: [],
    finishReason: "stop",
    usage: null,
  });
});

it("maps delta.reasoning_content to onThinkingDelta and accumulates thinking", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.write('data: {"choices":[{"delta":{"content":"answer","reasoning_content":"thinking "},"finish_reason":null}]}\n\n');
    res.write('data: {"choices":[{"delta":{"reasoning_content":"hard"},"finish_reason":null}]}\n\n');
    res.write('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n');
    res.end("data: [DONE]\n\n");
  });
  const { deltas, thinking, promise } = streamCall();
  const result = await promise;
  expect(deltas).toEqual(["answer"]);
  expect(thinking).toEqual(["thinking ", "hard"]);
  expect(result.content).toBe("answer");
  expect(result.thinking).toBe("thinking hard");
});

it("reassembles a tool call split across chunks: parsed args, empty content, finish_reason tool_calls", async () => {
  await startMock(async (_req, res) => {
    sseHead(res);
    res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"run_shell","arguments":"{\\"cm"}}]},"finish_reason":null}]}\n\n');
    await sleep(5);
    res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"d\\":\\"ls\\"}"}}]},"finish_reason":null}]}\n\n');
    res.write('data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n');
    res.end("data: [DONE]\n\n");
  });
  const { deltas, promise } = streamCall();
  const result = await promise;
  expect(deltas).toEqual([]);
  expect(result.content).toBe("");
  expect(result.toolCalls).toEqual([{ id: "call_1", name: "run_shell", args: { cmd: "ls" } }]);
  expect(result.finishReason).toBe("tool_calls");
});

it("reassembles two parallel tool calls with interleaved indexes in index order", async () => {
  await startMock(async (_req, res) => {
    sseHead(res);
    // call A: id+name first, arguments split MID-JSON across TCP chunks
    res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","fun');
    await sleep(5);
    res.write('ction":{"name":"run_shell","arguments":""}}]},"finish_reason":null}]}\n\n');
    res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"cmd\\":\\"e"}}]},"finish_reason":null}]}\n\n');
    await sleep(5);
    // call B interleaved between call A's argument fragments (index-merged)
    res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"read_file","arguments":"{\\"path\\":\\"a.ts\\"}"}}]},"finish_reason":null}]}\n\n');
    res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"cho hi\\"}"}}]},"finish_reason":null}]}\n\n');
    await sleep(5);
    res.write('data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n');
    res.end("data: [DONE]\n\n");
  });
  const { promise } = streamCall();
  const result = await promise;
  expect(result.toolCalls).toEqual([
    { id: "call_a", name: "run_shell", args: { cmd: "echo hi" } },
    { id: "call_b", name: "read_file", args: { path: "a.ts" } },
  ]);
  expect(result.finishReason).toBe("tool_calls");
});

it("malformed tool-call arguments JSON → TerminalModelError naming the tool call", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.write('data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_x","function":{"name":"run_shell","arguments":"{\\"cmd\\": "}}]},"finish_reason":null}]}\n\n');
    res.write('data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n');
    res.end("data: [DONE]\n\n");
  });
  const err = await streamCall().promise.then(
    () => null,
    (e: unknown) => e,
  );
  expect(err).toBeInstanceOf(TerminalModelError);
  expect(err).not.toBeInstanceOf(TransientModelError);
  expect((err as Error).message).toMatch(/run_shell/);
});

it("usage trailer maps to AgentResponse.usage including cacheReadTokens from prompt_tokens_details.cached_tokens", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.write('data: {"choices":[{"delta":{"content":"hi"},"finish_reason":"stop"}]}\n\n');
    res.write('data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30,"prompt_tokens_details":{"cached_tokens":7}}}\n\n');
    res.end("data: [DONE]\n\n");
  });
  const { promise } = streamCall();
  const result = await promise;
  expect(result.usage).toEqual({ inputTokens: 10, outputTokens: 20, cacheReadTokens: 7 });
});

it("usage without prompt_tokens_details has no cacheReadTokens", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.write('data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":5,"total_tokens":8}}\n\n');
    res.end("data: [DONE]\n\n");
  });
  const { promise } = streamCall();
  const result = await promise;
  expect(result.usage).toEqual({ inputTokens: 3, outputTokens: 5 });
});

// The four P1 taxonomy cases, re-pinned at the new home.

it("429 → TransientModelError carrying the status and body excerpt", async () => {
  await startMock((_req, res) => {
    res.writeHead(429, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: "rate limit exceeded" } }));
  });
  const err = await streamCall().promise.then(
    () => null,
    (e: unknown) => e,
  );
  expect(err).toBeInstanceOf(TransientModelError);
  expect(err).not.toBeInstanceOf(TerminalModelError);
  expect((err as Error).message).toMatch(/429/);
  expect((err as Error).message).toMatch(/rate limit exceeded/);
});

it("400 → TerminalModelError", async () => {
  await startMock((_req, res) => {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: "unknown model" } }));
  });
  const err = await streamCall().promise.then(
    () => null,
    (e: unknown) => e,
  );
  expect(err).toBeInstanceOf(TerminalModelError);
  expect(err).not.toBeInstanceOf(TransientModelError);
});

it("server destroys the socket mid-stream → TransientModelError", async () => {
  await startMock((req, res) => {
    sseHead(res);
    res.write('data: {"choices":[{"delta":{"content":"par"},"finish_reason":null}]}\n\n');
    setTimeout(() => {
      req.socket.destroy();
      res.destroy();
    }, 10);
  });
  await expect(streamCall().promise).rejects.toBeInstanceOf(TransientModelError);
});

it("stream ends cleanly WITHOUT [DONE] → TransientModelError (truncated response)", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.write('data: {"choices":[{"delta":{"content":"half"},"finish_reason":null}]}\n\n');
    res.end();
  });
  await expect(streamCall().promise).rejects.toBeInstanceOf(TransientModelError);
});
