/**
 * The curated REST descriptor set — the 16 declarative services of the
 * 20-server curated lineup (the other 4 are the Task 5 native handlers),
 * in the pinned order: dev (6), data (7), comms (3).
 */

import type { RestServiceDescriptor } from "../engine.js";
import { DEV_DESCRIPTORS } from "./dev.js";
import { DATA_DESCRIPTORS } from "./data.js";
import { COMMS_DESCRIPTORS } from "./comms.js";

export { DEV_DESCRIPTORS } from "./dev.js";
export {
  DATA_DESCRIPTORS,
  createS3Handler,
  createGoogleDriveHandler,
} from "./data.js";
export { COMMS_DESCRIPTORS } from "./comms.js";
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
];
