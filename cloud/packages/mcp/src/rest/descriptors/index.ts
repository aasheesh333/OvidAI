/**
 * The curated REST descriptor set: the 16 declarative services of the original
 * 20-server lineup (the other 4 are the Task 5 native handlers) followed by
 * the 80-service expansion — 96 declarative + 4 native = 100 total.
 *
 * Order is pinned: dev (6), data (7), comms (3), then the expansion.
 */

import type { RestServiceDescriptor } from "../engine.js";
import { DEV_DESCRIPTORS } from "./dev.js";
import { DATA_DESCRIPTORS } from "./data.js";
import { COMMS_DESCRIPTORS } from "./comms.js";
import { EXPANDED_DESCRIPTORS } from "./expanded.js";

export { DEV_DESCRIPTORS } from "./dev.js";
export {
  DATA_DESCRIPTORS,
  createS3Handler,
  createGoogleDriveHandler,
} from "./data.js";
export { COMMS_DESCRIPTORS } from "./comms.js";
export { EXPANDED_DESCRIPTORS, EXPANDED_IDS } from "./expanded.js";
export {
  GITLAB_DESCRIPTOR,
  JIRA_DESCRIPTOR,
  LINEAR_DESCRIPTOR,
  FIGMA_DESCRIPTOR,
  SENTRY_DESCRIPTOR,
  EXA_DESCRIPTOR,
} from "./dev.js";
export {
  NOTION_DESCRIPTOR,
  GOOGLE_DRIVE_DESCRIPTOR,
  AIRTABLE_DESCRIPTOR,
  SUPABASE_DESCRIPTOR,
  FIREBASE_DESCRIPTOR,
  MONGODB_DESCRIPTOR,
  S3_DESCRIPTOR,
} from "./data.js";
export { SLACK_DESCRIPTOR, DISCORD_DESCRIPTOR, TELEGRAM_DESCRIPTOR } from "./comms.js";

export const CURATED_DESCRIPTORS: readonly RestServiceDescriptor[] = [
  ...DEV_DESCRIPTORS,
  ...DATA_DESCRIPTORS,
  ...COMMS_DESCRIPTORS,
  // The 80-service expansion (owner directive 2026-10-23): 20 -> 100.
  ...EXPANDED_DESCRIPTORS,
];
