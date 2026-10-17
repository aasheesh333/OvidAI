/**
 * Process-env → storage backend selection (the seam the gateway/worker boot
 * through: `createStorage(loadStorageEnv(process.env))`).
 *
 * Selection:
 * - OVID_STORAGE_BACKEND explicit: "fs" or "r2" (anything else fails loud).
 * - unset: "r2" iff ALL FOUR OVID_R2_* vars are present, else "fs".
 * - backend "fs" requires a non-empty OVID_FS_STORAGE_ROOT.
 * - NODE_ENV === "production" with backend "fs" → throw: fs is a dev/test
 *   backend, production must run on R2 (same fail-loud mindset as the
 *   gateway's test-auth-in-production gate).
 */

import type { StorageAdapter } from "./adapter.js";
import { createFsStorage } from "./fsAdapter.js";
import { createR2Storage, loadR2Config, type R2Config } from "./r2Adapter.js";

export type StorageBackend = "fs" | "r2";

export interface StorageEnv {
  backend: StorageBackend;
  /** Present iff backend is "r2". */
  r2?: R2Config;
  /** Present iff backend is "fs". */
  fsRoot?: string;
}

const R2_REQUIRED_VARS = [
  "OVID_R2_ACCOUNT_ID",
  "OVID_R2_ACCESS_KEY_ID",
  "OVID_R2_SECRET_ACCESS_KEY",
  "OVID_R2_BUCKET",
] as const;

function hasAllR2Vars(env: NodeJS.ProcessEnv): boolean {
  return R2_REQUIRED_VARS.every((name) => (env[name] ?? "") !== "");
}

function requireFsRoot(env: NodeJS.ProcessEnv): string {
  const root = env.OVID_FS_STORAGE_ROOT;
  if (root === undefined || root === "") {
    throw new Error(
      'missing required storage environment variable: OVID_FS_STORAGE_ROOT (required when OVID_STORAGE_BACKEND is unset or "fs")',
    );
  }
  return root;
}

function forbidFsInProduction(env: NodeJS.ProcessEnv): void {
  if (env.NODE_ENV === "production") {
    throw new Error(
      "fs storage backend is not allowed in production (NODE_ENV=production): configure R2 (OVID_R2_ACCOUNT_ID, OVID_R2_ACCESS_KEY_ID, OVID_R2_SECRET_ACCESS_KEY, OVID_R2_BUCKET) or set OVID_STORAGE_BACKEND=r2",
    );
  }
}

export function loadStorageEnv(env: NodeJS.ProcessEnv): StorageEnv {
  const explicit = env.OVID_STORAGE_BACKEND;
  if (explicit !== undefined) {
    if (explicit !== "fs" && explicit !== "r2") {
      throw new Error(
        `OVID_STORAGE_BACKEND must be "fs" or "r2" (got ${JSON.stringify(explicit)})`,
      );
    }
    if (explicit === "r2") {
      return { backend: "r2", r2: loadR2Config(env) };
    }
    const fsRoot = requireFsRoot(env);
    forbidFsInProduction(env);
    return { backend: "fs", fsRoot };
  }
  if (hasAllR2Vars(env)) {
    return { backend: "r2", r2: loadR2Config(env) };
  }
  const fsRoot = requireFsRoot(env);
  forbidFsInProduction(env);
  return { backend: "fs", fsRoot };
}

export function createStorage(env: StorageEnv): StorageAdapter {
  if (env.backend === "fs") {
    if (env.fsRoot === undefined || env.fsRoot === "") {
      throw new Error('createStorage: backend "fs" requires a non-empty fsRoot');
    }
    return createFsStorage(env.fsRoot);
  }
  if (env.r2 === undefined) {
    throw new Error('createStorage: backend "r2" requires an R2Config (env.r2)');
  }
  return createR2Storage(env.r2);
}
