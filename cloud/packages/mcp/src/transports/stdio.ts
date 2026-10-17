/**
 * stdio MCP transport inside the P2 sandbox. This adapter's whole job is the
 * EXPLICIT MAPPING onto the sandbox's long-lived jailed process primitive
 * (WRITABLE STDIN, LINE-STREAMED STDOUT, KILL):
 *
 *   McpTransport.send(msg)          → ONE `JSON.stringify(msg)` line written
 *                                      to the process's stdin
 *   each complete stdout line       → parsed as a JsonRpcMessage →
 *                                      onMessage (partial lines are buffered
 *                                      by the sandbox layer and never
 *                                      surface here; non-JSON lines are
 *                                      dropped, never fatal)
 *   McpTransport.close()            → process kill() →
 *                                      onClose({ expected: true })
 *   process exit not from close()    → onClose({ expected: false }) —
 *                                      reconnector territory (backoff.ts)
 *
 * The process is spawned ONLY through the injected spawner; this module
 * never launches anything on its own (a source-purity test pins that).
 */

import type { JsonRpcMessage } from "../jsonrpc.js";
import type { McpTransport } from "../transport.js";

/**
 * Structural mirror of @ovid/sandbox's index-exported `SpawnedProcess`
 * (long-lived jailed process with pipes). Declared locally per the plan
 * ruling — P5 adapts member names only and never re-declares the sandbox
 * interface; `spawnLongRunning` stays the sole implementation.
 */
export interface SandboxedProcess {
  readonly id: string;
  readonly pid: number;
  /** UTF-8 + "\n" (appended when absent) → process stdin; never throws. */
  writeLine(line: string): void;
  /** Complete stdout lines only (partial lines stay buffered below). */
  onStdoutLine(cb: (line: string) => void): void;
  onExit(cb: (code: number | null) => void): void;
  /** End stdin, kill the process tree, clean up; idempotent. */
  kill(): Promise<void>;
}

/**
 * Spawns a jailed long-lived process under the caller's uid — the P2 seam
 * the worker's sandbox adapter implements around `spawnLongRunning`.
 */
export interface SandboxSpawner {
  spawn(
    uid: string,
    req: {
      command: string;
      args: string[];
      env?: Record<string, string>;
      cwd?: string;
    },
  ): Promise<SandboxedProcess>;
}

/**
 * Package launchers may not be configured bare — `npx --yes` with no package
 * to run would download and execute nothing useful (and stalls the jail).
 * A launcher command MUST carry a non-flag argument (the package target).
 */
export const LAUNCHER_ONLY_COMMANDS = ["npx", "uvx", "bunx", "pnpm", "yarn"] as const;

/** The stdio server spec is unusable (bare launcher, bad argv). */
export class McpConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "McpConfigError";
  }
}

function basename(command: string): string {
  return command.split("/").pop() ?? command;
}

export function createStdioTransport(
  spawner: SandboxSpawner,
  uid: string,
  spec: { command: string; args: string[]; env?: Record<string, string>; cwd?: string },
): McpTransport {
  // eager config check — an unrunnable launcher is rejected before ANY spawn
  const launcher = basename(spec.command);
  if ((LAUNCHER_ONLY_COMMANDS as readonly string[]).includes(launcher)) {
    const hasPackageTarget = spec.args.some((a) => !a.startsWith("-"));
    if (!hasPackageTarget) {
      throw new McpConfigError(
        `command "${spec.command}" is a package launcher (${launcher}) but no package to run was given — e.g. ["-y", "<package>"]`,
      );
    }
  }

  let proc: SandboxedProcess | undefined;
  let msgCb: ((m: JsonRpcMessage) => void) | undefined;
  let closeCb: ((info: { expected: boolean }) => void) | undefined;
  let started = false;
  let closing = false;
  let closeFired = false;

  function fireClose(expected: boolean): void {
    if (closeFired) return;
    closeFired = true;
    closeCb?.({ expected });
  }

  const transport: McpTransport = {
    async start(): Promise<void> {
      if (started) throw new Error("MCP stdio transport already started");
      started = true;
      proc = await spawner.spawn(uid, {
        command: spec.command,
        args: spec.args,
        env: spec.env,
        cwd: spec.cwd,
      });
      // EXPLICIT MAPPING: each complete stdout line is one JSON-RPC frame.
      proc.onStdoutLine((line) => {
        let parsed: unknown;
        try {
          parsed = JSON.parse(line);
        } catch {
          return; // banner / log noise — dropped, never fatal
        }
        if (typeof parsed !== "object" || parsed === null) return;
        msgCb?.(parsed as JsonRpcMessage);
      });
      // EXPLICIT MAPPING: an exit we did not ask for is an unexpected close.
      proc.onExit(() => {
        if (closing) return; // close() owns the expected-close notification
        fireClose(false);
      });
    },

    async send(msg: JsonRpcMessage): Promise<void> {
      if (proc === undefined || !started) throw new Error("MCP stdio transport is not started");
      if (closing) throw new Error("MCP stdio transport is closed");
      proc.writeLine(JSON.stringify(msg)); // ONE line per message
    },

    onMessage(cb: (m: JsonRpcMessage) => void): void {
      msgCb = cb;
    },

    onClose(cb: (info: { expected: boolean }) => void): void {
      closeCb = cb;
    },

    async close(): Promise<void> {
      if (closing) return; // idempotent
      closing = true;
      if (proc !== undefined) await proc.kill();
      fireClose(true);
    },
  };
  return transport;
}
