/**
 * Browser tool roster (P6 Task 12; Task 13 appends the interaction/transfer
 * half). The array is sorted by name so the prompt prefix is byte-stable
 * across calls (prompt-cache friendly, spec §6.1).
 */

import { inspectionTools } from "./inspection.js";
import { navigationTools } from "./navigation.js";
import type { BrowserToolDef, BrowserToolsDeps } from "./types.js";

/** Task-12 roster (Task 13 grows this to the final 36). Sorted by name. */
export const BROWSER_TOOL_NAMES: readonly string[] = Object.freeze([
  "browser_back",
  "browser_close_tab",
  "browser_evaluate",
  "browser_find",
  "browser_forward",
  "browser_list_tabs",
  "browser_navigate",
  "browser_new_tab",
  "browser_open",
  "browser_outline",
  "browser_read",
  "browser_reload",
  "browser_resize",
  "browser_screenshot",
  "browser_snapshot",
  "browser_switch_tab",
  "browser_wait_for",
]);

export function createBrowserTools(deps: BrowserToolsDeps): BrowserToolDef[] {
  return [...navigationTools(deps), ...inspectionTools(deps)].sort((a, b) =>
    a.name < b.name ? -1 : a.name > b.name ? 1 : 0,
  );
}
