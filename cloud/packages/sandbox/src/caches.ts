import { BASE_JAIL_ENV } from "./invocation.js";

/**
 * Per-user package caches + the `ovid install` fast path (P2 Task 10).
 *
 * Design notes (research §5):
 * - PER-USER stores, not a shared read-only one. A shared RO store is
 *   unworkable three ways: hardlinks out of a store written by another uid
 *   hit `protected_hardlinks` (EPERM) once the jail's root euid maps to an
 *   unprivileged host uid; pnpm needs a writable store to fetch into at all;
 *   uv refuses a read-only cache dir outright. Every sandbox uid therefore
 *   gets its own /root/.cache/{pnpm-store,uv} — host side {uid}/.home/.cache/…,
 *   inside the same `.cache` project-quota subtree (Task 8) and on the same
 *   filesystem as /workspace, which is the hardlink precondition.
 * - Hardlinks are the proven install mechanism: an installed file shows
 *   `stat %h` ≥ 2 and the same inode inside the store (host-gated proof,
 *   research §5 reproduced per-user). After the first per-user fetch, an
 *   install is link + metadata, not network + decompress — that is the
 *   `ovid install` fast path pinned by the timing gate.
 * - `UV_LINK_MODE=hardlink` is PINNED via BASE_JAIL_ENV: the stores live on
 *   the workspace XFS volume, the same filesystem as the venvs, so hardlinks
 *   always succeed. If the stores ever move cross-device, uv warns and flips
 *   to copy on its own — flip this pin to `copy` at that point (cost: full
 *   file copies into every venv).
 * - XFS reflink SEED stores (deduping every user's first fetch against a
 *   pre-populated store image) are a FUTURE owner decision: they need the
 *   XFS volume from Task 16 (reflink is an mkfs-time XFS option). v1 ships
 *   no seeding — the first install per user pays the network cost, and every
 *   subsequent install hits the per-user store.
 */

/**
 * Jail-side store roots — the exact paths BASE_JAIL_ENV (Task 5) points
 * `NPM_CONFIG_STORE_DIR` / `UV_CACHE_DIR` at. Host side they map onto
 * `{uid}/.home/.cache/…` (the manager's homeDir bind at jail /root).
 */
export const STORE_PATHS: Readonly<{ pnpmStore: string; uvCache: string }> = Object.freeze({
  pnpmStore: "/root/.cache/pnpm-store",
  uvCache: "/root/.cache/uv",
});

/** The `ovid` dispatcher baked into the rootfs (Task 3, /usr/local/bin/ovid). */
const OVID_BIN = "/usr/local/bin/ovid";

/**
 * Payload argv for an install through the dispatcher — package resolution
 * (package.json → pnpm, pyproject.toml → uv) stays the shim's job, so this
 * stays a flat passthrough.
 */
export function ovidInstallArgv(packages: string[]): string[] {
  return [OVID_BIN, "install", ...packages];
}

/**
 * Payload argv for the P7 hibernate path: reclaim per-user store bytes via
 * `pnpm store prune` + `uv cache prune` (both invoked by the shim).
 */
export function cachePruneArgv(): string[] {
  return [OVID_BIN, "cache-prune"];
}

/** The env keys that make an install hit the per-user stores. */
const INSTALL_ENV_KEYS = ["NPM_CONFIG_STORE_DIR", "UV_CACHE_DIR", "UV_LINK_MODE"] as const;

/**
 * The exact env subset installs run with, re-exported from BASE_JAIL_ENV so
 * tool-side assertions (e.g. a worker building an install job) and the jail
 * itself can never drift apart. Frozen per call; callers may merge freely.
 */
export function installEnv(): Readonly<Record<string, string>> {
  const env: Record<string, string> = {};
  for (const key of INSTALL_ENV_KEYS) {
    const value = BASE_JAIL_ENV[key];
    if (value === undefined) {
      // Load-time tripwire, not a silent fallback: the Task 5 wiring is a
      // contract, and losing a store var would quietly degrade installs to
      // the default (non-per-user, non-hardlink) locations.
      throw new Error(`installEnv: BASE_JAIL_ENV lost ${key} — jail env wiring regressed`);
    }
    env[key] = value;
  }
  return Object.freeze(env);
}

// Module-load consistency guard: the constants above and the Task 5 env
// allowlist must describe the SAME stores. A mismatch here is a wiring bug
// (someone moved a store without updating both), so it fails fast on import
// rather than at the first install.
if (
  BASE_JAIL_ENV.NPM_CONFIG_STORE_DIR !== STORE_PATHS.pnpmStore ||
  BASE_JAIL_ENV.UV_CACHE_DIR !== STORE_PATHS.uvCache
) {
  throw new Error(
    "caches.ts: STORE_PATHS and BASE_JAIL_ENV disagree on store paths — " +
      `${JSON.stringify(STORE_PATHS)} vs NPM_CONFIG_STORE_DIR=${BASE_JAIL_ENV.NPM_CONFIG_STORE_DIR} UV_CACHE_DIR=${BASE_JAIL_ENV.UV_CACHE_DIR}`,
  );
}
