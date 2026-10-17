import { spawn, type ChildProcess } from "node:child_process";
import { createServer } from "node:net";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import { afterEach, describe, expect, it } from "vitest";

/**
 * P10 Task 2: the SIGTERM drain path. Boots the REAL compiled gateway process
 * (dist/main.js) against the dev Postgres/Redis, connects one WS client, sends
 * SIGTERM, and asserts:
 *   - the live socket closes with code 1001 reason "server restarting";
 *   - the process exits 0 within the 10 s drain budget (well within the test's
 *     5 s assertion window when nothing is stuck).
 *
 * The child is spawned on an explicitly allocated free port rather than
 * PORT=0: loadGatewayEnv validates 1..65535 and the child cannot report a
 * kernel-assigned port back over stdout reliably.
 */

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const TEST_REDIS_URL = process.env.TEST_REDIS_URL;
const MAIN_JS = fileURLToPath(new URL("../dist/main.js", import.meta.url));

async function freePort(): Promise<number> {
  const server = createServer();
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  const port = typeof address === "object" && address !== null ? address.port : 0;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

async function waitForHealth(baseUrl: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  let lastError: unknown = null;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${baseUrl}/cloud/v1/health`);
      if (res.status === 200) return;
    } catch (err) {
      lastError = err;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(`gateway did not become healthy: ${String(lastError)}`);
}

interface Child {
  proc: ChildProcess;
  output: () => string;
  exited: Promise<{ code: number | null; signal: NodeJS.Signals | null }>;
}

function spawnGateway(port: number): Child {
  const storageRoot = mkdtempSync(join(tmpdir(), "ovid-gw-shutdown-"));
  const proc = spawn(process.execPath, [MAIN_JS], {
    env: {
      ...process.env,
      NODE_ENV: "test",
      OVID_AUTH_MODE: "test",
      HOST: "127.0.0.1",
      PORT: String(port),
      DATABASE_URL: TEST_DATABASE_URL,
      REDIS_Q_URL: TEST_REDIS_URL,
      REDIS_MINT_URL: TEST_REDIS_URL,
      MINT_BASE_URL: "http://127.0.0.1:1",
      OVID_FS_STORAGE_ROOT: storageRoot,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  proc.stdout?.on("data", (chunk: Buffer) => {
    output += chunk.toString("utf8");
  });
  proc.stderr?.on("data", (chunk: Buffer) => {
    output += chunk.toString("utf8");
  });
  const exited = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) => {
    proc.once("exit", (code, signal) => resolve({ code, signal }));
  });
  return { proc, output: () => output, exited };
}

describe.skipIf(!TEST_DATABASE_URL || !TEST_REDIS_URL)(
  "gateway SIGTERM drain (real process)",
  () => {
    let child: Child | undefined;
    let socket: WebSocket | undefined;

    afterEach(async () => {
      socket?.terminate();
      socket = undefined;
      if (child !== undefined && child.proc.exitCode === null) {
        child.proc.kill("SIGKILL");
        await child.exited.catch(() => {});
      }
      child = undefined;
    });

    it("SIGTERM closes the live WS with 1001 'server restarting' and the process exits 0", async () => {
      const port = await freePort();
      const baseUrl = `http://127.0.0.1:${port}`;
      child = spawnGateway(port);
      await waitForHealth(baseUrl, 15_000);

      // Real ticket → real WS handshake (single-use ticket in the query).
      const ticketRes = await fetch(`${baseUrl}/cloud/v1/auth/ticket`, {
        method: "POST",
        headers: { authorization: "Bearer test:shutdown-user" },
      });
      expect(ticketRes.status).toBe(200);
      const { ticket } = (await ticketRes.json()) as { ticket: string };

      socket = new WebSocket(`ws://127.0.0.1:${port}/cloud/ws?ticket=${encodeURIComponent(ticket)}`);
      const closed = new Promise<{ code: number; reason: string }>((resolve, reject) => {
        socket!.once("close", (code, reason) => resolve({ code, reason: reason.toString() }));
        socket!.once("error", reject);
      });
      await new Promise<void>((resolve, reject) => {
        socket!.once("open", () => resolve());
        socket!.once("error", reject);
      });

      child.proc.kill("SIGTERM");

      const [close, exit] = await Promise.all([
        Promise.race([
          closed,
          new Promise<never>((_, reject) =>
            setTimeout(() => reject(new Error("socket did not close within 5 s")), 5_000),
          ),
        ]),
        Promise.race([
          child.exited,
          new Promise<never>((_, reject) =>
            setTimeout(
              () => reject(new Error(`child did not exit within 5 s; output:\n${child!.output()}`)),
              5_000,
            ),
          ),
        ]),
      ]);

      expect(close.code).toBe(1001);
      expect(close.reason).toBe("server restarting");
      expect(exit.code).toBe(0);
    }, 30_000);
  },
);
