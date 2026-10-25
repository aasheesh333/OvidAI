/**
 * The curated REST descriptor set — the 16 declarative services of the
 * 20-server curated lineup (the other 4 are the Task 5 native handlers),
 * in the pinned order: dev (6), data (7), comms (3).
 */

import type { RestServiceDescriptor } from "../engine.js";
import { DEV_DESCRIPTORS } from "./dev.js";
import { DATA_DESCRIPTORS } from "./data.js";
import { COMMS_DESCRIPTORS } from "./comms.js";
import { DEV_WORK_DESCRIPTORS } from "./devWork.js";

export { DEV_DESCRIPTORS } from "./dev.js";
export {
  DATA_DESCRIPTORS,
  createS3Handler,
  createGoogleDriveHandler,
} from "./data.js";
export { COMMS_DESCRIPTORS } from "./comms.js";
export {
  FILES_SUITES_CANDIDATES,
  FILES_SUITES_CANDIDATE_IDS,
  FILES_SUITES_CONTRACT_DEFINITIONS,
  FILES_SUITES_DESCRIPTORS,
  FILES_SUITES_IDENTITY_PROFILES,
  FILES_SUITES_OAUTH_PROFILES,
  FILES_SUITES_READINESS_ROWS,
  FILES_SUITES_ORIGINS,
  FILES_SUITES_PROVIDERS,
  assertFilesSuitesLiveIdentity,
  createFilesSuitesHandler,
  createFilesSuitesLiveIdentityBinding,
  exchangeFilesSuitesOAuthCode,
  filesSuitesAndroidRegistrationBlocker,
  filesSuitesOAuthConfig,
  refreshFilesSuitesOAuthToken,
  revokeFilesSuitesOAuthToken,
} from "./filesSuites.js";
export type {
  FilesSuitesCandidate,
  FilesSuitesHandlerOptions,
  FilesSuitesIdentityProfile,
  FilesSuitesLiveIdentityBinding,
  FilesSuitesOAuthConfig,
  FilesSuitesOAuthProfile,
  FilesSuitesOAuthTokenSet,
  FilesSuitesProviderId,
} from "./filesSuites.js";
export { DEV_WORK_PROVIDERS, DEV_WORK_DESCRIPTORS } from "./devWork.js";
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
export {
  COMMERCE_INFRA_PROVIDERS,
  COMMERCE_INFRA_DESCRIPTORS,
  COMMERCE_INFRA_BLOCKED,
  COMMERCE_INFRA_SUPERSESSIONS,
  createCommerceInfraHandler,
} from "./commerceInfra.js";
export {
  DATA_SEARCH_BLOCKED,
  DATA_SEARCH_DESCRIPTORS,
  DATA_SEARCH_PROVIDERS,
  createDataSearchHandler,
  dataSearchProviderOperation,
} from "./dataSearch.js";
export type { DataSearchBlockedCandidate } from "./dataSearch.js";

// Data/search candidates stay separate until their explicit live-read gates pass.
export const CURATED_DESCRIPTORS: readonly RestServiceDescriptor[] = [
  ...DEV_DESCRIPTORS,
  ...DATA_DESCRIPTORS,
  ...COMMS_DESCRIPTORS,
  ...DEV_WORK_DESCRIPTORS,
];
