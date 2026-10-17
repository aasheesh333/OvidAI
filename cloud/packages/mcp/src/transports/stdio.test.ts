import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import type { JsonRpcMessage } from "../jsonrpc.js";
import {
  createStdioTransport,
  LAUNCHER_ONLY_COMMANDS,
  McpConfigError,
  type SandboxedProcess,
  type SandboxSpawner,
} from "./stdio.js";

// ---------------------------------------------------------------------------
// stdio-in-sandbox transport: the adapter's whole job is the EXPLICIT
// MAPPING onto the P2 primitive — send → one JSON line on stdin, each
// stdout line → onMessage, close → kill + expected close, any other exit →
// unexpected close. All tests run against a FakeSpawner; no real jailed
// process (and no direct process spawning) is involved anywhere.
// ---------------------------------------------------------------------------

interface SpawnCall {
  uid: string;
  req: { command: string; args: string[]; env?: Record<string, string>; cwd?: string };
}

class FakeProcess implements SandboxedProcess {
  readonly id = "proc-1";
  readonly pid = 4242;
  readonly writtenLines: string[] = [];
  killed = false;
  private lineCb: ((line: string) => void) | undefined;
  private exitCb: ((code: number | null) => void) | undefined;

  writeLine(line: string): void {
    this.writtenLines.push(line);
  }
  onStdoutLine(cb: (line: string) => void): void {
    this.lineCb = cb;
  }
  onExit(cb: (code: number | null) => void): void {
    this.exitCb = cb;
  }
  async kill(): Promise<void> {
    if (this.killed) return;
    this.killed = true;
    // mirrors the real primitive: killing ends the process (exit fires)
    this.exitCb?.(null);
  }
  emitLine(line: string): void {
    this.lineCb?.(line);
  }
  exit(code: number | null): void {
    this.exitCb?.(code);
  }
}

function makeSpawner(): { proc: FakeProcess; calls: SpawnCall[]; spawner: SandboxSpawner } {
  const proc = new FakeProcess();
  const calls: SpawnCall[] = [];
  const spawner: SandboxSpawner = {
    async spawn(uid, req) {
      calls.push({ uid, req: { command: req.command, args: req.args, env: req.env, cwd: req.cwd } });
      return proc;
    },
  };
  return { proc, calls, spawner };
}

const initRequest = { jsonrpc: "2.0" as const, id: 1, method: "initialize", params: {} };

describe("createStdioTransport", () => {
  it("JSON-RPC lines flow over stdin/stdout: one send → ONE line, each stdout line → onMessage", async () => {
    const { proc, calls, spawner } = makeSpawner();
    const t = createStdioTransport(spawner, "u-1", {
      command: "/usr/local/bin/mcp-server-x",
      args: ["--stdio"],
      env: { LANG: "C" },
      cwd: "/srv",
    });
    await t.start();
    expect(calls).toEqual([
      {
        uid: "u-1",
        req: {
          command: "/usr/local/bin/mcp-server-x",
          args: ["--stdio"],
          env: { LANG: "C" },
          cwd: "/srv",
        },
      },
    ]);

    const seen: JsonRpcMessage[] = [];
    t.onMessage((m) => seen.push(m));

    await t.send(initRequest);
    expect(proc.writtenLines).toEqual([JSON.stringify(initRequest)]); // exactly ONE line

    const response = { jsonrpc: "2.0" as const, id: 1, result: { serverInfo: { name: "x" } } };
    proc.emitLine(JSON.stringify(response));
    expect(seen).toEqual([response]);

    await t.send({ jsonrpc: "2.0", id: 2, method: "ping" });
    expect(proc.writtenLines.length).toBe(2);

    // non-JSON stdout lines (banners, log noise) are dropped, never emitted
    proc.emitLine("not json at all");
    expect(seen.length).toBe(1);
  });

  it("unrunnable launcher rejected: npx with no package target throws McpConfigError before any spawn", () => {
    const { calls, spawner } = makeSpawner();
    expect([...LAUNCHER_ONLY_COMMANDS]).toEqual(["npx", "uvx", "bunx", "pnpm", "yarn"]);
    expect(() =>
      createStdioTransport(spawner, "u-1", { command: "npx", args: ["--yes"] }),
    ).toThrow(McpConfigError);
    // launcher by absolute path is still recognized (basename check)
    expect(() =>
      createStdioTransport(spawner, "u-1", { command: "/usr/bin/npx", args: [] }),
    ).toThrow(McpConfigError);
    expect(() =>
      createStdioTransport(spawner, "u-1", { command: "uvx", args: ["-q"] }),
    ).toThrow(McpConfigError);
    expect(calls.length).toBe(0); // NO spawn call recorded
  });

  it("a launcher with a package target spawns it", async () => {
    const { proc, calls, spawner } = makeSpawner();
    const t = createStdioTransport(spawner, "u-1", {
      command: "npx",
      args: ["-y", "mcp-server-x"],
    });
    await t.start();
    expect(calls).toEqual([
      { uid: "u-1", req: { command: "npx", args: ["-y", "mcp-server-x"], env: undefined, cwd: undefined } },
    ]);
    await t.close();
    expect(proc.killed).toBe(true);
  });

  it("process exit fires onClose unexpected", async () => {
    const { proc, spawner } = makeSpawner();
    const t = createStdioTransport(spawner, "u-1", { command: "node", args: ["server.js"] });
    await t.start();
    const closes: Array<{ expected: boolean }> = [];
    t.onClose((info) => closes.push(info));
    proc.exit(1);
    expect(closes).toEqual([{ expected: false }]);
  });

  it("close() kills the process and fires expected close (exactly once)", async () => {
    const { proc, spawner } = makeSpawner();
    const t = createStdioTransport(spawner, "u-1", { command: "node", args: ["server.js"] });
    await t.start();
    const closes: Array<{ expected: boolean }> = [];
    t.onClose((info) => closes.push(info));
    await t.close();
    expect(proc.killed).toBe(true);
    expect(closes).toEqual([{ expected: true }]); // kill()'s own exit does NOT double-fire
    await t.close(); // idempotent
    expect(closes.length).toBe(1);
    await expect(t.send(initRequest)).rejects.toThrow();
  });

  it("spawn is only ever called through the injected SandboxSpawner (no direct process spawning)", () => {
    // grep -c "child_process" src/transports/stdio.ts === 0 — the seam is
    // pure: the module cannot spawn anything except via the injected spawner.
    const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "stdio.ts"), "utf8");
    const occurrences = src.split("child_process").length - 1;
    expect(occurrences).toBe(0);
  });
});
