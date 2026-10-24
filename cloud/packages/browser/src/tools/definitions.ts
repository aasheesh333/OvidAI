/**
 * Browser tool roster (P6 Task 12; Task 13 appends the interaction/transfer
 * half). The array is sorted by name so the prompt prefix is byte-stable
 * across calls (prompt-cache friendly, spec §6.1).
 */

import { inspectionTools } from "./inspection.js";
import { interactionTools } from "./interaction.js";
import { navigationTools } from "./navigation.js";
import { credentialTools } from "./credentials.js";
import { transferTools } from "./transfers.js";
import type { BrowserToolDef, BrowserToolsDeps } from "./types.js";

/** Production roster: legacy credential autofill is disabled and absent. Sorted by name. */
export const BROWSER_TOOL_NAMES: readonly string[] = Object.freeze([
  "browser_back",
  "browser_click",
  "browser_close_tab",
  "browser_console",
  "browser_cookies",
  "browser_dialog",
  "browser_double_click",
  "browser_download",
  "browser_drag",
  "browser_evaluate",
  "browser_fill",
  "browser_find",
  "browser_forward",
  "browser_hover",
  "browser_list_credentials",
  "browser_list_tabs",
  "browser_long_press",
  "browser_navigate",
  "browser_network",
  "browser_new_tab",
  "browser_open",
  "browser_outline",
  "browser_popups",
  "browser_press_key",
  "browser_read",
  "browser_reload",
  "browser_resize",
  "browser_screenshot",
  "browser_scroll",
  "browser_select",
  "browser_snapshot",
  "browser_swipe",
  "browser_switch_tab",
  "browser_tap_at",
  "browser_type",
  "browser_upload",
  "browser_wait_for",
]);

export function createBrowserTools(deps: BrowserToolsDeps): BrowserToolDef[] {
  return [
    ...navigationTools(deps),
    ...inspectionTools(deps),
    ...interactionTools(deps),
    ...transferTools(deps),
    ...credentialTools(deps),
  ].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
}
