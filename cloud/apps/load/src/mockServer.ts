import { randomBytes } from "node:crypto";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

/**
 * Mock LiteLLM: [OI]-dialect SSE chat streaming plus the LiteLLM admin stubs
 * the REAL P9 mint uses to provision staging keys.
 *
 * Staging topology (Task 1): this process binds 0.0.0.0:14000 on the host so
 * the staging gateway container can reach it across the docker bridge
 * (`http://172.17.0.1:14000`). The host firewall keeps 14000 closed to the
 * outside. In-process tests use the default loopback bind.
 *
 * Determinism: `arm()` installs the script the NEXT request streams and
 * returns a deferred gate — no timing guesses. Each request snapshots the
 * script at arrival, so a later `arm()` never mutates an in-flight stream.
 *
 * Out-of-process control (the load scenario against the standalone staging
 * mock) uses a documented HTTP surface — the same arm/release mechanics:
 *
 *   POST /_control/arm      body: MockLlmScript → {gateId}
 *   POST /_control/release  body: {gateId?}     → {released, heldRequests}
 *   GET  /_control/status                       → {armed, gateId, requestsSeen,
 *                                                   heldRequests, totalHeldRequests}
 *
 * `/_control/arm` installs the next-request script exactly like `arm()` and
 * returns the id of its deferred gate; `/_control/release` resolves it. The
 * staging mock binds 0.0.0.0:14000 on the host behind the firewall (see the
 * staging topology note above); these routes are mock-only and never proxy.
 */

/**
 * A provider tool call the mock can stream. `arguments` is the raw JSON
 * string, exactly as an OpenAI-compatible provider streams it; the worker's
 * [OI] transport aggregates it and JSON-parses it into tool-call args.
 */
export interface MockLlmToolCall {
  id: string;
  name: string;
  /** Raw JSON argument string (e.g. `{"command":"echo load-ok"}`). */
  arguments: string;
}

export interface MockLlmScript {
  /** Content deltas streamed as choices[0].delta.content. */
  deltas?: string[];
  /** Wait this long before each delta (default 0). */
  chunkDelayMs?: number;
  /** After writing the Nth delta, hold the stream until release(). */
  gateAfterDeltas?: number | null;
  /** After writing the Nth delta, destroy the socket WITHOUT [DONE]. */
  closeSocketAfterDeltas?: number | null;
  /**
   * Emit a provider `tool_calls` delta instead of content on the FIRST
   * provider call of a run. `undefined` keeps the server default; `null`
   * disables tool calls.
   */
  toolCall?: MockLlmToolCall | null;
  /**
   * Only emit `toolCall` when the last user message starts with this marker.
   * `null` = emit for every run. Default: `"[sandbox]"` — the marker the
   * scenario already prefixes onto `sandboxDutyCycle` runs.
   */
  toolCallMarker?: string | null;
  /**
   * Only honour `gateAfterDeltas` when the last user message starts with this
   * marker. `null` = gate every request (the `arm()` default). The scenario
   * arms `"[spike]"` so only the spike burst is held; steady-state runs keep
   * streaming while the spike is parked.
   */
  gateMarker?: string | null;
}

export interface MockLlmServer {
  /** Host-side base URL (never 0.0.0.0 — use 127.0.0.1 when bound wildcard). */
  baseUrl: string;
  /** Chat completion requests observed (admin stubs are not counted). */
  requestsSeen(): number;
  arm(script: MockLlmScript): { release(): void };
  close(): Promise<void>;
}

export interface StartMockLlmOptions extends MockLlmScript {
  port?: number;
  bindHost?: string;
}

interface ResolvedScript {
  deltas: string[];
  chunkDelayMs: number;
  gateAfterDeltas: number | null;
  closeSocketAfterDeltas: number | null;
  toolCall: MockLlmToolCall | null;
  toolCallMarker: string | null;
  gateMarker: string | null;
}

/**
 * The default sandbox-trigger call. `run_shell` is in the worker's real P2
 * roster; `echo load-ok` passes the command policy, is read-only (so it is
 * allowed even in plan/read-only mode), is deterministic and exits at once.
 * The worker executes it in the attached sandbox and emits the normal
 * `tool_started` / `tool_completed` events.
 */
const DEFAULT_SANDBOX_TOOL_CALL: MockLlmToolCall = {
  id: "call_load_sandbox",
  name: "run_shell",
  arguments: JSON.stringify({ command: "echo load-ok" }),
};

interface Deferred {
  promise: Promise<void>;
  resolve(): void;
}

function deferred(): Deferred {
  let resolve!: () => void;
  const promise = new Promise<void>((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function resolveScript(script: MockLlmScript, fallback: ResolvedScript): ResolvedScript {
  return {
    deltas: script.deltas ?? fallback.deltas,
    chunkDelayMs: script.chunkDelayMs ?? fallback.chunkDelayMs,
    gateAfterDeltas:
      script.gateAfterDeltas === undefined ? fallback.gateAfterDeltas : script.gateAfterDeltas,
    closeSocketAfterDeltas:
      script.closeSocketAfterDeltas === undefined
        ? fallback.closeSocketAfterDeltas
        : script.closeSocketAfterDeltas,
    // `null` is meaningful (disable), so only `undefined` falls back.
    toolCall: script.toolCall === undefined ? fallback.toolCall : script.toolCall,
    toolCallMarker:
      script.toolCallMarker === undefined ? fallback.toolCallMarker : script.toolCallMarker,
    gateMarker: script.gateMarker === undefined ? fallback.gateMarker : script.gateMarker,
  };
}

interface ChatRequestMessage {
  role?: unknown;
  content?: unknown;
  tool_calls?: unknown;
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) =>
        part !== null && typeof part === "object" && "text" in part
          ? String((part as { text?: unknown }).text ?? "")
          : "",
      )
      .join("");
  }
  return "";
}

function parseMessages(rawBody: string): ChatRequestMessage[] {
  try {
    const body = JSON.parse(rawBody) as { messages?: unknown };
    return Array.isArray(body.messages) ? (body.messages as ChatRequestMessage[]) : [];
  } catch {
    return [];
  }
}

function lastUserMessage(messages: ChatRequestMessage[]): ChatRequestMessage | undefined {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index]?.role === "user") return messages[index];
  }
  return undefined;
}

/**
 * True when this is the first provider call for the run's latest user
 * message. The engine's continuation rounds append an assistant message with
 * `tool_calls` and a `role:"tool"` result AFTER that user message, so their
 * presence marks a continuation. History from earlier runs sits BEFORE the
 * last user message and does not confuse the check.
 */
function isFirstProviderCall(messages: ChatRequestMessage[]): boolean {
  let lastUser = -1;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    if (messages[index]?.role === "user") {
      lastUser = index;
      break;
    }
  }
  if (lastUser === -1) return true;
  for (let index = lastUser + 1; index < messages.length; index += 1) {
    const message = messages[index];
    if (message?.role === "tool") return false;
    if (
      message?.role === "assistant" &&
      Array.isArray(message.tool_calls) &&
      message.tool_calls.length > 0
    ) {
      return false;
    }
  }
  return true;
}

function shouldEmitToolCall(script: ResolvedScript, rawBody: string): boolean {
  if (script.toolCall === null) return false;
  const messages = parseMessages(rawBody);
  if (!isFirstProviderCall(messages)) return false;
  if (script.toolCallMarker !== null) {
    const lastUser = lastUserMessage(messages);
    const text = lastUser === undefined ? "" : contentText(lastUser.content);
    if (!text.startsWith(script.toolCallMarker)) return false;
  }
  return true;
}

/**
 * Whether this request's stream should honour `gateAfterDeltas`. With no
 * marker every request is eligible (the historical `arm()` semantics); with a
 * marker only requests whose latest user message starts with it are held.
 */
function shouldGate(script: ResolvedScript, rawBody: string): boolean {
  if (script.gateAfterDeltas === null) return false;
  if (script.gateMarker === null) return true;
  const lastUser = lastUserMessage(parseMessages(rawBody));
  const text = lastUser === undefined ? "" : contentText(lastUser.content);
  return text.startsWith(script.gateMarker);
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

async function readBody(req: IncomingMessage): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks).toString("utf8");
}

/** UUIDv7 (time-ordered) — staging key ids look like real LiteLLM keys. */
function uuidv7(): string {
  const bytes = randomBytes(16);
  const ts = BigInt(Date.now());
  bytes[0] = Number((ts >> 40n) & 0xffn);
  bytes[1] = Number((ts >> 32n) & 0xffn);
  bytes[2] = Number((ts >> 24n) & 0xffn);
  bytes[3] = Number((ts >> 16n) & 0xffn);
  bytes[4] = Number((ts >> 8n) & 0xffn);
  bytes[5] = Number(ts & 0xffn);
  bytes[6] = (bytes[6]! & 0x0f) | 0x70; // version 7
  bytes[8] = (bytes[8]! & 0x3f) | 0x80; // RFC 4122 variant
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(
    16,
    20,
  )}-${hex.slice(20)}`;
}

export async function startMockLlmServer(
  opts: StartMockLlmOptions = {},
): Promise<MockLlmServer> {
  const bindHost = opts.bindHost ?? "127.0.0.1";
  const fallback: ResolvedScript = resolveScript(opts, {
    deltas: ["mock"],
    chunkDelayMs: 0,
    gateAfterDeltas: null,
    closeSocketAfterDeltas: null,
    toolCall: DEFAULT_SANDBOX_TOOL_CALL,
    toolCallMarker: "[sandbox]",
    gateMarker: null,
  });
  let current = fallback;
  let gate = deferred();
  let chatRequests = 0;
  let activeStreams = 0;
  let peakActiveStreams = 0;
  let completedStreams = 0;
  /** HTTP control gates by id; in-process `arm()` gates stay outside this map. */
  const remoteGates = new Map<string, Deferred>();
  let gateSeq = 0;
  let activeGateId: string | null = null;
  /** Requests currently parked on a deferred gate (and the running total). */
  let heldRequests = 0;
  let totalHeldRequests = 0;

  async function stream(
    res: ServerResponse,
    script: ResolvedScript,
    requestGate: Deferred,
    emitToolCall: boolean,
    gateAfterDeltas: number | null,
  ): Promise<void> {
    res.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-store",
      connection: "keep-alive",
    });
    const writeData = (payload: string): void => {
      res.write(`data: ${payload}\n\n`);
    };

    if (emitToolCall && script.toolCall !== null) {
      if (script.chunkDelayMs > 0) await sleep(script.chunkDelayMs);
      if (res.destroyed || res.writableEnded) return;
      // Real provider tool-call wire shape: one fragment with index/id/name/
      // arguments, then a finish_reason:"tool_calls" chunk. The worker's [OI]
      // transport aggregates this and dispatches the real tool.
      writeData(
        JSON.stringify({
          choices: [
            {
              delta: {
                tool_calls: [
                  {
                    index: 0,
                    id: script.toolCall.id,
                    type: "function",
                    function: {
                      name: script.toolCall.name,
                      arguments: script.toolCall.arguments,
                    },
                  },
                ],
              },
              finish_reason: null,
            },
          ],
        }),
      );
      writeData(JSON.stringify({ choices: [{ delta: {}, finish_reason: "tool_calls" }] }));
      res.end("data: [DONE]\n\n");
      return;
    }

    for (let i = 0; i < script.deltas.length; i += 1) {
      if (script.chunkDelayMs > 0) await sleep(script.chunkDelayMs);
      if (res.destroyed || res.writableEnded) return;
      writeData(
        JSON.stringify({
          choices: [{ delta: { content: script.deltas[i] }, finish_reason: null }],
        }),
      );
      const written = i + 1;
      if (script.closeSocketAfterDeltas === written) {
        res.socket?.destroy();
        return;
      }
      if (gateAfterDeltas === written) {
        heldRequests += 1;
        totalHeldRequests += 1;
        try {
          await requestGate.promise;
        } finally {
          heldRequests -= 1;
        }
        if (res.destroyed || res.writableEnded) return;
      }
    }
    writeData(JSON.stringify({ choices: [{ delta: {}, finish_reason: "stop" }] }));
    res.end("data: [DONE]\n\n");
  }

  const server: Server = createServer((req, res) => {
    void (async () => {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      const path = url.pathname;

      // Chat completions — the worker transport appends /chat/completions to
      // its base URL (agent-core/openai.ts), so match the suffix.
      if (req.method === "POST" && path.endsWith("/chat/completions")) {
        const body = await readBody(req);
        chatRequests += 1;
        // Snapshot per request: a later arm() never mutates an in-flight stream.
        const script = { ...current, deltas: [...current.deltas] };
        const requestGate = gate;
        activeStreams += 1;
        peakActiveStreams = Math.max(peakActiveStreams, activeStreams);
        try {
          await stream(
            res,
            script,
            requestGate,
            shouldEmitToolCall(script, body),
            shouldGate(script, body) ? script.gateAfterDeltas : null,
          );
          if (res.writableEnded) completedStreams += 1;
        } finally { activeStreams -= 1; }
        return;
      }

      // ---- Out-of-process control surface (the spike hold) ----------------
      if (req.method === "POST" && path === "/_control/arm") {
        let script: MockLlmScript;
        try {
          script = JSON.parse(await readBody(req)) as MockLlmScript;
        } catch {
          sendJson(res, 400, { error: { message: "control arm: body must be JSON" } });
          return;
        }
        gateSeq += 1;
        const gateId = `gate-${gateSeq}`;
        current = resolveScript(script, fallback);
        gate = deferred();
        remoteGates.set(gateId, gate);
        activeGateId = gateId;
        sendJson(res, 200, { gateId });
        return;
      }

      if (req.method === "POST" && path === "/_control/release") {
        let gateId: string | null = null;
        try {
          const body = JSON.parse(await readBody(req)) as { gateId?: unknown };
          gateId = typeof body.gateId === "string" ? body.gateId : null;
        } catch {
          sendJson(res, 400, { error: { message: "control release: body must be JSON" } });
          return;
        }
        const targetId = gateId ?? activeGateId;
        const target = targetId === null ? undefined : remoteGates.get(targetId);
        if (target !== undefined && targetId !== null) {
          remoteGates.delete(targetId);
          if (activeGateId === targetId) activeGateId = null;
          target.resolve();
        }
        sendJson(res, 200, { released: target !== undefined, heldRequests });
        return;
      }

      if (req.method === "GET" && path === "/_control/status") {
        sendJson(res, 200, {
          armed: activeGateId !== null,
          gateId: activeGateId,
          gateAfterDeltas: current.gateAfterDeltas,
          gateMarker: current.gateMarker,
          requestsSeen: chatRequests,
          activeStreams,
          peakActiveStreams,
          completedStreams,
          heldRequests,
          totalHeldRequests,
        });
        return;
      }

      if (req.method === "POST" && path === "/key/generate") {
        await readBody(req);
        sendJson(res, 200, { key: `sk-mock-${uuidv7()}`, token: "mock" });
        return;
      }

      if (
        req.method === "POST" &&
        (path === "/key/update" ||
          path === "/key/delete" ||
          path === "/key/block" ||
          path === "/key/unblock")
      ) {
        await readBody(req);
        sendJson(res, 200, {});
        return;
      }

      if (req.method === "GET" && path === "/key/info") {
        const key = url.searchParams.get("key") ?? "";
        // Shape matches mint's `data.info ?? data` unwrap.
        sendJson(res, 200, {
          key,
          info: { key, blocked: false, spend: 0, key_alias: null },
        });
        return;
      }

      if (req.method === "GET" && path === "/user/info") {
        sendJson(res, 200, { spend: 0, budget_duration: null });
        return;
      }

      if (req.method === "GET" && (path === "/spend/logs" || path === "/model/info")) {
        sendJson(res, 200, []);
        return;
      }

      if (req.method === "GET" && path === "/health") {
        sendJson(res, 200, { status: "ok" });
        return;
      }

      sendJson(res, 404, { error: { message: `mock LiteLLM: no route ${req.method} ${path}` } });
    })().catch((err: unknown) => {
      if (!res.headersSent) {
        sendJson(res, 500, {
          error: { message: err instanceof Error ? err.message : String(err) },
        });
      } else {
        res.destroy();
      }
    });
  });

  await new Promise<void>((resolveListen) => server.listen(opts.port ?? 0, bindHost, resolveListen));
  const port = (server.address() as AddressInfo).port;
  const hostForUrl = bindHost === "0.0.0.0" || bindHost === "::" ? "127.0.0.1" : bindHost;

  return {
    baseUrl: `http://${hostForUrl}:${port}`,
    requestsSeen: () => chatRequests,
    arm(next) {
      current = resolveScript(next, fallback);
      gate = deferred();
      const requestGate = gate;
      return { release: () => requestGate.resolve() };
    },
    async close() {
      server.closeAllConnections();
      await new Promise<void>((resolveClose) => server.close(() => resolveClose()));
    },
  };
}

/**
 * CLI entry (`node dist/mockServer.js --port 14000 --bind 0.0.0.0`), used by
 * `staging.sh mock-start`. Runs until SIGINT/SIGTERM.
 */
async function main(): Promise<void> {
  const args = process.argv.slice(2);
  let port = 14000;
  let bindHost = "127.0.0.1";
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === "--port" && args[i + 1] !== undefined) {
      port = Number(args[i + 1]);
      i += 1;
    } else if (args[i] === "--bind" && args[i + 1] !== undefined) {
      bindHost = args[i + 1]!;
      i += 1;
    }
  }
  const server = await startMockLlmServer({ port, bindHost });
  console.log(`mock-litellm listening on http://${bindHost}:${port}`);
  const shutdown = (): void => {
    void server.close().finally(() => process.exit(0));
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

const invokedDirectly =
  process.argv[1] !== undefined &&
  fileURLToPath(import.meta.url) === resolve(process.argv[1]);
if (invokedDirectly) {
  void main();
}
