import type { Tool } from "@ovid/agent-core";
import type { BrowserToolDef } from "@ovid/browser";
import { userBrowserKey } from "@ovid/shared";

/**
 * Adapts the P6 browser tool suite onto the canonical `Tool` seam (ruling R2:
 * "artifacts is the optional additive channel for browser/file outputs —
 * P6 BrowserToolDef adapts onto this").
 *
 * Until 2026-10-18 these tools were exported but never dispatched: the
 * browser engine was composed in `main.ts`, yet `runProcessor` had no
 * reference to it, so the agent could not browse at all. This adapter is the
 * missing seam.
 *
 * Contract notes:
 * - `BrowserToolDef.execute` never throws (failures are content strings), so
 *   the adapter does not need to translate exceptions. It still maps
 *   `artifacts` through untouched: screenshots and downloads are what the
 *   client renders.
 * - `BrowserToolContext` needs only `{sessionId, userId}`; the canonical
 *   `ToolContext` carries both.
 * - The abort `signal` is NOT forwarded: `BrowserToolDef.execute` has no
 *   parameter for it. A cancelled run therefore lets the current browser
 *   action finish (bounded by its own Playwright timeout) and the run's
 *   `releaseSession` closes the context afterwards. Documented rather than
 *   silently ignored.
 */

/** Per-action ceiling. Navigation and screenshot capture are the slow ones. */
export const BROWSER_TOOL_TIMEOUT_MS = 60_000;

/**
 * Wave 5 (owner rule R2): ONE cloud browser per user, shared by all of that
 * user's sessions. A run ending must therefore not close a browser another
 * run of the same user is still driving, nor one the user is watching live.
 * The leases track which runs used the browser; the LAST one to end releases
 * it (flushing storageState), unless a viewer is attached — then the pool's
 * idle lease reaps it once they leave (the browser stays headless until).
 */
export interface UserBrowserLeases {
  /** Record that `runId` drove the user's browser. */
  note(userId: string, runId: string): void;
  /** The run ended: release the user's browser if it was the last user of it. */
  releaseRun(userId: string, runId: string): Promise<void>;
}

export function createUserBrowserLeases(engine: {
  releaseSession(key: string): Promise<void>;
  viewerCount(key: string): number;
}): UserBrowserLeases {
  const runsByUser = new Map<string, Set<string>>();
  return {
    note(userId, runId) {
      let runs = runsByUser.get(userId);
      if (runs === undefined) {
        runs = new Set();
        runsByUser.set(userId, runs);
      }
      runs.add(runId);
    },
    async releaseRun(userId, runId) {
      const runs = runsByUser.get(userId);
      if (runs === undefined || !runs.delete(runId)) return; // never browsed
      if (runs.size > 0) return; // another run of this user still drives it
      runsByUser.delete(userId);
      const key = userBrowserKey(userId);
      if (engine.viewerCount(key) > 0) return; // watched live: idle lease reaps later
      await engine.releaseSession(key);
    },
  };
}

export function adaptBrowserTools(defs: readonly BrowserToolDef[], leases?: UserBrowserLeases): Tool[] {
  return defs.map((def) => ({
    spec: {
      name: def.name,
      description: def.description,
      parameters: def.parameters,
    },
    timeoutMs: BROWSER_TOOL_TIMEOUT_MS,
    async execute(args, ctx) {
      leases?.note(ctx.userId, ctx.runId);
      const result = await def.execute(args, {
        // The browser key is the USER (R2); artifacts still land in the
        // run's own session workspace.
        sessionId: userBrowserKey(ctx.userId),
        userId: ctx.userId,
        workspaceSessionId: ctx.sessionId,
      });
      return {
        content: result.content,
        ...(result.artifacts !== undefined && result.artifacts.length > 0
          ? { artifacts: result.artifacts }
          : {}),
      };
    },
  }));
}
