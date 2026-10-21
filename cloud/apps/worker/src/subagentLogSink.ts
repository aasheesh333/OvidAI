/**
 * Sandbox-backed writer for the per-subagent append-only log (SI spec §9).
 *
 * agent-core's default `createSubagentLog` writes to the WORKER HOST at the
 * literal spec path `/workspace/.ovid/logs/...`. On the worker host that path
 * is not the sandbox workspace, so the default either fails or lands outside
 * the jail. The supervisor exposes `logFactory` exactly for this: the worker
 * supplies a writer that goes through its `SandboxPort`, whose file methods
 * resolve `/workspace/...` onto the session workspace that the jail mounts at
 * `/workspace`.
 *
 * Semantics kept from the agent-core contract:
 *  - one file per child id at `<dir>/subagent_{id}.log`, id validated by
 *    `subagentLogPath` (no `..`, no separators);
 *  - append-only: a cold resume of the same child id reads the existing file
 *    first, so a new header extends it instead of truncating it;
 *  - writes are serialized, and a write failure is recorded (`lastError`)
 *    rather than thrown — logging is fail-open for the child run.
 */

import {
  SUBAGENT_LOG_DIR,
  subagentLogPath,
  type CreateSubagentLogOptions,
  type SandboxPort,
  type SubagentLog,
  type SubagentLogEntry,
} from "@ovid/agent-core";

/** The SI spec §9 destination, as seen INSIDE the sandbox jail. */
export const SANDBOX_SUBAGENT_LOG_DIR = "/workspace/.ovid/logs";

function asError(err: unknown): Error {
  return err instanceof Error ? err : new Error(String(err));
}

/**
 * Build a `SubagentLog` factory bound to one run's user. Pass it to
 * `createSubagentSupervisor({ logDir, logFactory })`: `logDir` is the sandbox
 * path the supervisor forwards back as `options.dir`.
 */
export function createSandboxSubagentLogFactory(deps: {
  sandbox: SandboxPort;
  userId: string;
}): (options: CreateSubagentLogOptions) => Promise<SubagentLog> {
  return async (options) => {
    const path = subagentLogPath(options.sessionId, options.dir ?? SUBAGENT_LOG_DIR);
    const now = options.now ?? Date.now;

    // Cold-resume append: the spec says a second process for the same child id
    // appends a new header rather than erasing what the first one wrote.
    let content = "";
    if (await deps.sandbox.exists(deps.userId, path)) {
      content = await deps.sandbox.readFile(deps.userId, path);
    }

    let closed = false;
    let error: Error | null = null;
    let tail: Promise<void> = Promise.resolve();

    const write = (entry: SubagentLogEntry): Promise<void> => {
      if (closed) return tail;
      // Serialize synchronously so concurrent appends cannot interleave lines;
      // the write itself stays ordered through `tail`.
      content += `${JSON.stringify({ ts: now(), ...entry })}\n`;
      tail = tail
        .then(() => deps.sandbox.writeFile(deps.userId, path, content))
        .catch((err: unknown) => {
          error ??= asError(err);
        });
      return tail;
    };

    const log: SubagentLog = {
      path,
      append: write,
      async close() {
        closed = true;
        await tail;
      },
      lastError() {
        return error;
      },
    };

    await write({
      type: "subagent_log_started",
      sessionId: options.sessionId,
      ...(options.header ?? {}),
    });
    return log;
  };
}
