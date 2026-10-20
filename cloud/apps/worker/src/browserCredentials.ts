import { mkdir, writeFile } from "node:fs/promises";
import { basename, join } from "node:path";

import type { BrowserArtifactVaultPort, BrowserCredentialsPort } from "@ovid/browser";
import { artifactVault, browserCredentialsRepo, type Db } from "@ovid/db";
import type { EnvelopeCrypto } from "@ovid/escrow";
import { browserCredentialRecordId } from "@ovid/shared";
import { registerArtifact, type ArtifactEventMirror, type ArtifactWorkspaceObjectsRepo, type HydrateEventLog, type StorageAdapter } from "@ovid/storage";

/**
 * Wave 6 W4 production seams for the browser package:
 *
 *  - [createBrowserCredentialsPort] lists metadata and decrypts ONE entry on
 *    demand for the login tool. Decryption failures are logged without the
 *    secret (and without the ciphertext); the caller sees "not found".
 *  - [createBrowserArtifactVaultPort] materializes a vault artifact into the
 *    session workspace for `browser_upload`, and registers a downloaded
 *    workspace file back into the vault.
 */

/** Minimal event-log seam (the worker's Redis event log satisfies it). */
export interface BrowserArtifactEventLog extends HydrateEventLog {}

export interface BrowserArtifactMirror extends ArtifactEventMirror {}

export function createBrowserCredentialsPort(opts: {
  db: Db;
  crypto: EnvelopeCrypto | null;
  log?: (msg: string, err?: unknown) => void;
}): BrowserCredentialsPort {
  const log = opts.log ?? ((msg, err) => console.warn(`[browser-credentials] ${msg}`, err ?? ""));
  return {
    async list(userId) {
      const rows = await browserCredentialsRepo.list(opts.db, userId);
      return rows.map((r) => ({
        id: r.id,
        label: r.label,
        site: r.site,
        username: r.username,
        secretKind: r.secretKind,
        hasNotes: r.hasNotes,
      }));
    },
    async resolve(userId, id) {
      if (opts.crypto === null) {
        log("credentials vault resolve refused: OVID_MASTER_KEY is not set");
        return null;
      }
      const row = await browserCredentialsRepo.get(opts.db, userId, id);
      if (row === null) return null;
      try {
        const secret = opts.crypto.decrypt(row.secretSealed, browserCredentialRecordId(row.id));
        const notes =
          row.notesSealed === null
            ? null
            : opts.crypto.decrypt(row.notesSealed, browserCredentialRecordId(row.id));
        return {
          id: row.id,
          label: row.label,
          site: row.site,
          username: row.username,
          secretKind: row.secretKind,
          hasNotes: row.hasNotes,
          secret,
          notes,
        };
      } catch {
        // Fixed, value-free diagnostic: no ciphertext, no plaintext.
        log(`credential ${row.id} failed to decrypt (wrong key or tampered envelope)`);
        return null;
      }
    },
  };
}

/** A single-component filename; server names cannot escape destDir. */
function safeName(raw: string): string {
  const base = basename(raw).replace(/[\\/:*?"<>|\0]/g, "_").trim();
  return base === "" || base === "." || base === ".." ? "artifact" : base;
}

export function createBrowserArtifactVaultPort(opts: {
  db: Db;
  storage: StorageAdapter;
  events: BrowserArtifactEventLog;
  workspaceObjects: ArtifactWorkspaceObjectsRepo;
  eventMirror: BrowserArtifactMirror;
  workspaceDir(userId: string, sessionId: string): Promise<string>;
  log?: (msg: string, err?: unknown) => void;
}): BrowserArtifactVaultPort {
  const log = opts.log ?? ((msg, err) => console.warn(`[browser-artifacts] ${msg}`, err ?? ""));
  return {
    async fetchToWorkspace({ userId, sessionId, artifactId, destDir }) {
      // The tool does not carry an origin; try the generated table first,
      // then user uploads. Both lookups are owner-scoped.
      const row =
        (await artifactVault.get(opts.db, userId, artifactId, "generated")) ??
        (await artifactVault.get(opts.db, userId, artifactId, "uploaded"));
      if (row === null) return null;
      const body = await opts.storage.getBuffer(row.r2Key);
      if (body === null) return null;

      const root = await opts.workspaceDir(userId, sessionId);
      const dir = join(root, destDir);
      await mkdir(dir, { recursive: true });
      const name = safeName(row.name);
      await writeFile(join(dir, name), body);
      return {
        path: `${destDir}/${name}`,
        mimeType: row.contentType,
        bytes: body.length,
      };
    },

    async registerFromWorkspace({ userId, sessionId, path, mimeType }) {
      try {
        const root = await opts.workspaceDir(userId, sessionId);
        const rec = await registerArtifact(
          {
            db: opts.db,
            events: opts.events,
            storage: opts.storage,
            workspaceObjects: opts.workspaceObjects,
            eventMirror: opts.eventMirror,
          },
          {
            userId,
            sessionId,
            name: path,
            contentType: mimeType,
            sourcePath: join(root, path),
          },
        );
        return { id: rec.id };
      } catch (err) {
        log(`artifact vault registration failed for ${path}`, err);
        return null;
      }
    },
  };
}
