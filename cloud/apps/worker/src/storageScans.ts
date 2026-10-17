/**
 * Worker-local SQL scans the storage engines cannot own themselves.
 *
 * Both `@ovid/storage` engines take these as injected structural mirrors
 * (the same forcing-function pattern as `awaitWarm`'s `$client.unsafe`):
 * `@ovid/db` has no `listStuck*` query, and adding one would force a package
 * edge/lockfile change this parallel wave forbids. Keeping the SQL here means
 * the worker is the only place that knows how to find crash-stranded rows.
 *
 *  - hibernating: T8's `reconcileStuckHibernations` (boot + sweeper);
 *  - hydrating:   T10's `reconcileWarmRegistry` (T9-review I1 — a hard crash
 *                 mid-extract otherwise strands the row forever).
 */

import type {
  DbLike,
  FileManifestRowView,
  StuckHibernationScan,
} from "@ovid/storage";
import type { StuckHydrationScan, WarmRowView } from "@ovid/storage";

interface UnsafeClient {
  unsafe(query: string, params?: unknown[]): Promise<unknown>;
}

function clientOf(db: DbLike): UnsafeClient {
  const client = (db as { $client?: UnsafeClient }).$client;
  if (client === undefined || typeof client.unsafe !== "function") {
    throw new Error(
      "storage scans need a db handle exposing $client.unsafe (the drizzle/postgres.js handle)",
    );
  }
  return client;
}

interface RawHibernatingRow {
  session_id: string;
  user_id: string;
  generation: number | string;
  state: string;
  archive_key: string | null;
  workspace_bytes: number | string | null;
  updated_at: Date | string;
}

interface RawHydratingRow {
  session_id: string;
  user_id: string;
  generation: number | string;
  workspace_bytes: number | string | null;
  updated_at: Date | string;
}

function asDate(value: Date | string): Date {
  return value instanceof Date ? value : new Date(value);
}

function asNumberOrNull(value: number | string | null): number | null {
  return value === null ? null : Number(value);
}

export function createStuckHibernationScan(): StuckHibernationScan {
  return {
    async listStuck(db: DbLike, olderThan: Date): Promise<FileManifestRowView[]> {
      const rows = (await clientOf(db).unsafe(
        `SELECT session_id, user_id, generation, state, archive_key, workspace_bytes, updated_at
           FROM file_manifests
          WHERE state = 'hibernating' AND updated_at < $1
          ORDER BY updated_at ASC`,
        [olderThan],
      )) as RawHibernatingRow[];
      return rows.map((r) => ({
        sessionId: r.session_id,
        userId: r.user_id,
        generation: Number(r.generation),
        state: r.state as FileManifestRowView["state"],
        archiveKey: r.archive_key,
        workspaceBytes: asNumberOrNull(r.workspace_bytes),
        updatedAt: asDate(r.updated_at),
      }));
    },
  };
}

export function createStuckHydrationScan(): StuckHydrationScan {
  return {
    async listStuckHydrating(db: DbLike, olderThan: Date): Promise<WarmRowView[]> {
      const rows = (await clientOf(db).unsafe(
        `SELECT session_id, user_id, generation, workspace_bytes, updated_at
           FROM file_manifests
          WHERE state = 'hydrating' AND updated_at < $1
          ORDER BY updated_at ASC`,
        [olderThan],
      )) as RawHydratingRow[];
      return rows.map((r) => ({
        sessionId: r.session_id,
        userId: r.user_id,
        generation: Number(r.generation),
        workspaceBytes: asNumberOrNull(r.workspace_bytes),
        updatedAt: asDate(r.updated_at),
      }));
    },
  };
}
