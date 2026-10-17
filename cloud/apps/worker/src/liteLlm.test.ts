import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, expect, it } from "vitest";
import type { ModelToolSpec } from "./tools/types.js";
import {
  createOpenAiTransport,
  TerminalModelError,
  TransientModelError,
  type ChatMessage,
  type ToolCall,
} from "./liteLlm.js";

// ---------------------------------------------------------------------------
// Mock LiteLLM: a local http server speaking the OpenAI SSE dialect. No real
// network, no services — these tests always run.
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

/** Starts a one-off server; resolves to its base URL. Captures the last request. */
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

const MESSAGES: ChatMessage[] = [{ role: "user", content: "hi" }];

const TOOL_SPECS: ModelToolSpec[] = [
  {
    type: "function",
    function: {
      name: "run_shell",
      description: "Run a shell command",
      parameters: { type: "object", properties: { command: { type: "string" } }, required: ["command"] },
    },
  },
];

function streamCall(
  overrides?: {
    baseUrl?: string;
    onDelta?: (t: string) => void;
    tools?: ModelToolSpec[];
    messages?: ChatMessage[];
  },
) {
  const deltas: string[] = [];
  const transport = createOpenAiTransport();
  const controller = new AbortController();
  const promise = transport.stream(
    {
      baseUrl: overrides?.baseUrl ?? baseUrl,
      apiKey: "sk-test",
      model: "ovid-test-model",
      messages: overrides?.messages ?? MESSAGES,
      tools: overrides?.tools,
    },
    { onDelta: overrides?.onDelta ?? ((t) => deltas.push(t)) },
    controller.signal,
  );
  return { deltas, controller, promise };
}

// ---------------------------------------------------------------------------

it("POSTs the OpenAI streaming request shape (path, auth header, stream_options)", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.end("data: [DONE]\n\n");
  });
  await streamCall().promise;

  expect(lastRequest).toBeDefined();
  expect(lastRequest!.method).toBe("POST");
  expect(lastRequest!.url).toBe("/chat/completions");
  expect(lastRequest!.headers.authorization).toBe("Bearer sk-test");
  expect(lastRequest!.headers["content-type"]).toBe("application/json");
  expect(lastRequest!.body).toEqual({
    model: "ovid-test-model",
    messages: MESSAGES,
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

it("concatenates deltas exactly when the SSE arrives in awkward chunks", async () => {
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
    // 3. empty-string delta must NOT reach onDelta
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
    // 6. the include_usage trailer chunk has NO choices — must not crash the parser
    res.write('data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":5,"total_tokens":8}}\n\n');
    // 7. finish_reason on a delta-less final chunk, then [DONE]
    res.write('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n');
    await sleep(5);
    res.write("data: [DONE]\n\n");
    res.end();
  });

  const { deltas, promise } = streamCall();
  const result = await promise;
  expect(deltas).toEqual(["Hello", " world", "🌊 wave"]);
  expect(result).toEqual({ finishReason: "stop", toolCalls: [] });
});

it("accepts `data:[DONE]` without a space and without a trailing blank line", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.write('data:{"choices":[{"delta":{"content":"x"},"finish_reason":"length"}]}\n');
    res.end("data:[DONE]"); // no trailing newline: the end-of-stream flush must handle it
  });
  const { deltas, promise } = streamCall();
  const result = await promise;
  expect(deltas).toEqual(["x"]);
  expect(result).toEqual({ finishReason: "length", toolCalls: [] });
});

it("returns finishReason null when the stream never carries one", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.write('data: {"choices":[{"delta":{"content":"a"},"finish_reason":null}]}\n\n');
    res.end("data: [DONE]\n\n");
  });
  const result = await streamCall().promise;
  expect(result).toEqual({ finishReason: null, toolCalls: [] });
});

it("429 → TransientModelError carrying the status", async () => {
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
  expect((err as Error).message).toMatch(/rate limit exceeded/); // body excerpt preserved
});

it("500 → TransientModelError", async () => {
  await startMock((_req, res) => {
    res.writeHead(500, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: { message: "upstream exploded" } }));
  });
  await expect(streamCall().promise).rejects.toBeInstanceOf(TransientModelError);
});

it("503 → TransientModelError", async () => {
  await startMock((_req, res) => {
    res.writeHead(503);
    res.end();
  });
  await expect(streamCall().promise).rejects.toBeInstanceOf(TransientModelError);
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
  expect((err as Error).message).toMatch(/400/);
  expect((err as Error).message).toMatch(/unknown model/); // body excerpt preserved
});

it("401 → TerminalModelError", async () => {
  await startMock((_req, res) => {
    res.writeHead(401);
    res.end("bad key");
  });
  await expect(streamCall().promise).rejects.toBeInstanceOf(TerminalModelError);
});

it("server closes the socket mid-stream → TransientModelError", async () => {
  await startMock((req, res) => {
    sseHead(res);
    res.write('data: {"choices":[{"delta":{"content":"par"},"finish_reason":null}]}\n\n');
    // Hard reset mid-response (no [DONE], no clean end).
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
    res.end(); // clean FIN, but the terminal [DONE] never arrived
  });
  await expect(streamCall().promise).rejects.toBeInstanceOf(TransientModelError);
});

it("connection refused (nothing listening) → TransientModelError", async () => {
  // Grab a port, free it, then connect: nothing is listening there.
  const probe = createServer();
  await new Promise<void>((r) => probe.listen(0, "127.0.0.1", r));
  const dead = `http://127.0.0.1:${(probe.address() as AddressInfo).port}`;
  await new Promise<void>((r) => probe.close(() => r()));

  await expect(streamCall({ baseUrl: dead }).promise).rejects.toBeInstanceOf(TransientModelError);
});

it("AbortSignal mid-stream → rejects with the abort error (not a model error)", async () => {
  await startMock(async (_req, res) => {
    sseHead(res);
    res.write('data: {"choices":[{"delta":{"content":"first"},"finish_reason":null}]}\n\n');
    // Stall forever with keep-alives until the client aborts; res "close" ends it.
    const keepAlive = setInterval(() => {
      if (!res.writableEnded) res.write(": ping\n\n");
    }, 20);
    res.on("close", () => clearInterval(keepAlive));
  });

  const { controller, promise } = streamCall({
    onDelta: () => {
      controller.abort(); // abort as soon as the first delta lands
    },
  });
  const err = await promise.then(
    () => null,
    (e: unknown) => e,
  );
  expect(err).not.toBeNull();
  expect((err as Error).name).toBe("AbortError");
  expect(err).not.toBeInstanceOf(TransientModelError);
  expect(err).not.toBeInstanceOf(TerminalModelError);
});

it("AbortSignal already aborted → rejects immediately with AbortError", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.end("data: [DONE]\n\n");
  });
  const { controller, promise } = streamCall();
  controller.abort();
  await expect(promise).rejects.toMatchObject({ name: "AbortError" });
});

// ---------------------------------------------------------------------------
// Tool-call streaming (P2 Task 12): delta.tool_calls[] merged by index —
// id/name set once, arguments concatenated in arrival order — and the wire
// mapping for assistant tool_calls / role:"tool" messages and the tools param.
// ---------------------------------------------------------------------------

it("aggregates tool-call deltas split mid-JSON across frames into the exact ToolCall[] (two parallel calls, byte-identical arguments)", async () => {
  await startMock(async (_req, res) => {
    sseHead(res);
    // call A: id+name first, arguments split MID-JSON across TCP chunks
    res.write(
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","fun',
    );
    await sleep(5);
    res.write(
      'ction":{"name":"run_shell","arguments":""}}]},"finish_reason":null}]}\n\n',
    );
    res.write(
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"command\\":\\"e"}}]},"finish_reason":null}]}\n\n',
    );
    await sleep(5);
    // call B interleaved between call A's argument fragments (index-merged)
    res.write(
      'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"read_file","arguments":"{\\"path\\":\\"a.ts\\"}"}}]},"finish_reason":null}]}\n\n',
    );
    res.write(
      'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"cho hi\\"}"}}]},"finish_reason":null}]}\n\n',
    );
    await sleep(5);
    res.write('data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n');
    res.end("data: [DONE]\n\n");
  });

  const { promise } = streamCall();
  const result = await promise;
  const expected: ToolCall[] = [
    { id: "call_a", name: "run_shell", arguments: '{"command":"echo hi"}' },
    { id: "call_b", name: "read_file", arguments: '{"path":"a.ts"}' },
  ];
  expect(result.toolCalls).toEqual(expected); // index order: 0 before 1
  expect(result.finishReason).toBe("tool_calls");
});

it("a text-only stream yields toolCalls: [] (v0-compatible result)", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.write('data: {"choices":[{"delta":{"content":"plain text"},"finish_reason":null}]}\n\n');
    res.write('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n');
    res.end("data: [DONE]\n\n");
  });
  const { promise } = streamCall();
  const result = await promise;
  expect(result).toEqual({ finishReason: "stop", toolCalls: [] });
});

it("maps the request wire shape: tools passed through, assistant tool_calls and role:tool messages", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.end("data: [DONE]\n\n");
  });
  const messages: ChatMessage[] = [
    { role: "system", content: "sys" },
    { role: "user", content: "list the files" },
    {
      role: "assistant",
      content: "",
      toolCalls: [{ id: "call_1", name: "run_shell", arguments: '{"command":"ls"}' }],
    },
    { role: "tool", toolCallId: "call_1", content: "a.txt\nb.txt" },
  ];
  const { promise } = streamCall({ tools: TOOL_SPECS, messages });
  await promise;

  const body = lastRequest!.body as {
    tools: ModelToolSpec[];
    messages: Array<{
      role: string;
      content: string;
      tool_calls?: Array<{ id: string; type: string; function: { name: string; arguments: string } }>;
      tool_call_id?: string;
    }>;
  };
  expect(body.tools).toEqual(TOOL_SPECS);
  expect(body.messages).toEqual([
    { role: "system", content: "sys" },
    { role: "user", content: "list the files" },
    {
      role: "assistant",
      content: "",
      tool_calls: [
        { id: "call_1", type: "function", function: { name: "run_shell", arguments: '{"command":"ls"}' } },
      ],
    },
    { role: "tool", content: "a.txt\nb.txt", tool_call_id: "call_1" },
  ]);
});

it("omits the tools key entirely when no tools are passed (v0 body shape unchanged)", async () => {
  await startMock((_req, res) => {
    sseHead(res);
    res.end("data: [DONE]\n\n");
  });
  await streamCall().promise;
  expect(lastRequest!.body).toEqual({
    model: "ovid-test-model",
    messages: MESSAGES,
    stream: true,
    stream_options: { include_usage: true },
  });
});
