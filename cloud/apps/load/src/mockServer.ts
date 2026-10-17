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
 */

export interface MockLlmScript {
  /** Content deltas streamed as choices[0].delta.content. */
  deltas?: string[];
  /** Wait this long before each delta (default 0). */
  chunkDelayMs?: number;
  /** After writing the Nth delta, hold the stream until release(). */
  gateAfterDeltas?: number | null;
  /** After writing the Nth delta, destroy the socket WITHOUT [DONE]. */
  closeSocketAfterDeltas?: number | null;
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
}

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
  };
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
  });
  let current = fallback;
  let gate = deferred();
  let chatRequests = 0;

  async function stream(
    res: ServerResponse,
    script: ResolvedScript,
    requestGate: Deferred,
  ): Promise<void> {
    res.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-store",
      connection: "keep-alive",
    });
    const writeData = (payload: string): void => {
      res.write(`data: ${payload}\n\n`);
    };
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
      if (script.gateAfterDeltas === written) {
        await requestGate.promise;
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
        await readBody(req);
        chatRequests += 1;
        // Snapshot per request: a later arm() never mutates an in-flight stream.
        const script = { ...current, deltas: [...current.deltas] };
        const requestGate = gate;
        await stream(res, script, requestGate);
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
