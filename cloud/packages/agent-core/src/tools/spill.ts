/**
 * Output spill (ported from spillToolOutput/_toolOutputCapFor in
 * lib/core/agent_service.dart) and THE dispatch timeout helper — single
 * definition, single arity; Task 15's dispatch imports this exact shape.
 *
 * The timeout CONTRACT lives here: on timeout the dispatcher calls
 * sandbox.killCall(userId, callKey) and the tool result is
 * TOOL_TIMEOUT_MESSAGE(name, budget) — the timed-out call's late output never
 * reaches the model.
 */

import type { SandboxPort } from "../ports.js";
import type { ToolResult } from "../types.js";

export const SPILL_DEFAULT_CAP = 6000;

/**
 * Per-tool cap for the spill-to-disk path. 6000 for everything — device_read's
 * 24000 died with decision D5 (the full-processor path's business is Task 16).
 * fetch_url uses 8000 at its own call site (Task 10).
 */
export function toolOutputCapFor(name: string): number {
  void name;
  return SPILL_DEFAULT_CAP;
}

/** How to read the middle back — picked by tool shape (spill policy locators). */
function locatorFor(toolName: string, relPath: string): string {
  if (toolName === "run_shell") {
    return (
      `run_shell: \`sed -n "L,LP" ${relPath}\` for a line range, ` +
      `\`grep -n "<pattern>" ${relPath}\` to find lines`
    );
  }
  if (toolName === "fs_grep" || toolName === "fs_glob") {
    return (
      "re-run with a narrower `pattern` or an `include` glob; the full " +
      `output is saved at ${relPath} (fs_edit view can page it)`
    );
  }
  return `the full output is saved at ${relPath} — read it with fs_edit view (path ${relPath}) in chunks`;
}

/**
 * Returns `text` verbatim when it fits the cap. Over the cap: writes the FULL
 * text to `.spill/<epochMs>.txt` under the session workspace (via
 * sandbox.writeFile) and returns head(cap/2) + the exact omission notice with a
 * per-tool locator + tail(cap/2).
 */
export async function spillToolOutput(
  deps: { sandbox: SandboxPort; userId: string; workspaceRelDir: string },
  toolName: string,
  text: string,
  cap: number = SPILL_DEFAULT_CAP,
): Promise<string> {
  if (text.length <= cap) return text;
  const id = `${Date.now()}`;
  const writePath = deps.workspaceRelDir
    ? `${deps.workspaceRelDir}/.spill/${id}.txt`
    : `.spill/${id}.txt`;
  const relPath = `.spill/${id}.txt`;
  await deps.sandbox.writeFile(deps.userId, writePath, text);

  const headLen = Math.floor(cap / 2);
  const tailLen = Math.floor(cap / 2);
  const head = text.slice(0, headLen);
  const tail = text.slice(text.length - tailLen);
  const omitted = text.length - headLen - tailLen;
  const locator = locatorFor(toolName, relPath);
  return (
    `${head}\n\n` +
    `[…${omitted} characters omitted — full output saved to ${relPath}. ${locator}…]` +
    `\n\n${tail}`
  );
}

/** The pinned timeout result message (exact Dart copy). */
export const TOOL_TIMEOUT_MESSAGE = (name: string, secs: number): string =>
  `Error: tool "${name}" timed out after ${secs}s and its processes were KILLED. ` +
  "It may have partially completed — check the current state " +
  "(read the file, `git status`) before doing anything else, and do NOT re-run it blindly.";

/**
 * Resolves with `promise`, or — after `timeoutMs` — awaits `o.onKill()` (the
 * dispatcher binds it to sandbox.killCall(userId, o.callKey)) and resolves the
 * pinned KILLED message as an isError result. A late resolution of the wrapped
 * promise is discarded; a REJECTION before the timeout propagates (infrastructure
 * errors stay loud, the P2 convention).
 */
export function withToolTimeout(
  promise: Promise<ToolResult>,
  o: { timeoutMs: number; callKey: string; toolName: string; onKill: () => Promise<void> },
): Promise<ToolResult> {
  return new Promise<ToolResult>((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      void (async () => {
        // Kill failures must not mask the timeout result — the KILLED message
        // is what the model needs to see either way.
        try {
          await o.onKill();
        } catch {
          /* swallowed deliberately */
        }
        resolve({
          content: TOOL_TIMEOUT_MESSAGE(o.toolName, Math.floor(o.timeoutMs / 1000)),
          isError: true,
        });
      })();
    }, o.timeoutMs);

    promise.then(
      (res) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(res);
      },
      (err) => {
        if (settled) return; // the timeout already answered; swallow
        settled = true;
        clearTimeout(timer);
        reject(err);
      },
    );
  });
}
