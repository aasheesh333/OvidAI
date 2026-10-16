import { access, constants, readFile, realpath } from "node:fs/promises";
import { join } from "node:path";
import { z } from "zod";

/**
 * Manifest shipped inside every built rootfs tarball (written by
 * cloud/deploy/rootfs/build.sh; see versions.env for the pins). The build
 * pipeline adds extra fields (e.g. a dpkg -l snapshot) which the schema
 * ignores.
 */
export interface RootfsManifest {
  name: string;
  baseImage: string;
  baseImageDigest: string;
  nodeVersion: string;
  pnpmVersion: string;
  uvVersion: string;
  aptPackages: string[];
  buildDate: string;
  builderCommit: string;
}

const rootfsManifestSchema = z.object({
  name: z.string().min(1),
  baseImage: z.string().min(1),
  baseImageDigest: z.string().regex(/^sha256:[0-9a-f]{64}$/),
  nodeVersion: z.string().min(1),
  pnpmVersion: z.string().min(1),
  uvVersion: z.string().min(1),
  aptPackages: z.array(z.string()),
  buildDate: z.string().min(1),
  builderCommit: z.string().min(1),
});

/**
 * Parses and validates a rootfs manifest. Throws (zod) on missing or
 * ill-typed fields.
 */
export function parseRootfsManifest(json: unknown): RootfsManifest {
  return rootfsManifestSchema.parse(json);
}

/** A rootfs tree that passed validation and is ready to be bound into jails. */
export interface ResolvedRootfs {
  /** Real path of the revision directory (`current` symlink already followed). */
  path: string;
  manifest: RootfsManifest;
}

/** The rootfs is missing, incomplete or corrupt — unusable for jailing. */
export class RootfsUnavailable extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RootfsUnavailable";
  }
}

// Every piece the sandbox launcher needs inside the tree; a missing one means
// the extraction or the build itself was broken, and no jail may start.
const REQUIRED_FILES = [
  "usr/bin/env",
  "usr/local/bin/node",
  "usr/local/bin/pnpm",
  "usr/local/bin/uv",
  "usr/bin/git",
  "usr/bin/python3",
  "usr/local/bin/ovid",
] as const;

/**
 * Validates a rootfs tree at `rootfsPath` (which may be the `/opt/ovid-rootfs`
 * `current` symlink — it is resolved to the real revision directory). Reads
 * and parses `manifest.json`, then checks that every required binary exists.
 * Throws {@link RootfsUnavailable} (message naming the missing piece) when the
 * tree cannot be used.
 */
export async function resolveRootfs(rootfsPath: string): Promise<ResolvedRootfs> {
  let resolved: string;
  try {
    resolved = await realpath(rootfsPath);
  } catch {
    throw new RootfsUnavailable(`rootfs path not found: ${rootfsPath}`);
  }

  let raw: string;
  try {
    raw = await readFile(join(resolved, "manifest.json"), "utf8");
  } catch {
    throw new RootfsUnavailable(`rootfs at ${rootfsPath} has no manifest.json`);
  }

  let manifest: RootfsManifest;
  try {
    manifest = parseRootfsManifest(JSON.parse(raw));
  } catch (err) {
    throw new RootfsUnavailable(
      `rootfs at ${rootfsPath} has an invalid manifest.json: ${String(err)}`,
    );
  }

  for (const rel of REQUIRED_FILES) {
    try {
      await access(join(resolved, rel), constants.F_OK);
    } catch {
      throw new RootfsUnavailable(
        `rootfs ${manifest.name} at ${rootfsPath} is missing ${rel}`,
      );
    }
  }

  return { path: resolved, manifest };
}
