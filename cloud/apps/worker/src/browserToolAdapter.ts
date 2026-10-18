import type { Tool } from "@ovid/agent-core";
import type { BrowserToolDef } from "@ovid/browser";

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

export function adaptBrowserTools(defs: readonly BrowserToolDef[]): Tool[] {
  return defs.map((def) => ({
    spec: {
      name: def.name,
      description: def.description,
      parameters: def.parameters,
    },
    timeoutMs: BROWSER_TOOL_TIMEOUT_MS,
    async execute(args, ctx) {
      const result = await def.execute(args, {
        sessionId: ctx.sessionId,
        userId: ctx.userId,
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
