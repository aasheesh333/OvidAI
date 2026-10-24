import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { drizzle } from "drizzle-orm/postgres-js";
import { migrate as drizzleMigrate } from "drizzle-orm/postgres-js/migrator";
import postgres from "postgres";

const MIGRATIONS_FOLDER = fileURLToPath(new URL("../drizzle", import.meta.url));

/** Split one generated migration exactly as drizzle's statement breakpoints do. */
export function migrationStatements(source: string): string[] {
  return source
    .split("--> statement-breakpoint")
    .map((statement) => statement.trim())
    .filter((statement) => statement.length > 0);
}

/** Manually replay a migration, independently of drizzle's applied-journal check. */
export async function applyMigrationFile(client: postgres.Sql, path: string): Promise<void> {
  const source = await readFile(path, "utf8");
  for (const statement of migrationStatements(source)) {
    await client.unsafe(statement);
  }
}

interface MigrationJournal {
  entries: Array<{ idx: number; tag: string }>;
  [key: string]: unknown;
}

/** Apply the real generated migrations only through [throughIdx], in an isolated temp folder. */
export async function migrateThrough(databaseUrl: string, throughIdx: number): Promise<void> {
  if (!Number.isInteger(throughIdx) || throughIdx < 0) {
    throw new Error(`invalid migration index: ${throughIdx}`);
  }
  const journal = JSON.parse(
    await readFile(join(MIGRATIONS_FOLDER, "meta", "_journal.json"), "utf8"),
  ) as MigrationJournal;
  const entries = journal.entries.filter((entry) => entry.idx <= throughIdx);
  const folder = await mkdtemp(join(tmpdir(), "ovid-migrations-through-"));
  const client = postgres(databaseUrl, { max: 1, onnotice: () => {} });
  try {
    await mkdir(join(folder, "meta"), { recursive: true });
    await writeFile(
      join(folder, "meta", "_journal.json"),
      `${JSON.stringify({ ...journal, entries }, null, 2)}\n`,
      "utf8",
    );
    for (const entry of entries) {
      await copyFile(
        join(MIGRATIONS_FOLDER, `${entry.tag}.sql`),
        join(folder, `${entry.tag}.sql`),
      );
    }
    await drizzleMigrate(drizzle(client), { migrationsFolder: folder });
  } finally {
    await client.end({ timeout: 5 });
    await rm(folder, { recursive: true, force: true });
  }
}

export interface MigrationScratch {
  name: string;
  url: string;
  client: postgres.Sql;
  close(): Promise<void>;
}

/** Create an isolated real database and always provide a forced-cleanup hook. */
export async function createMigrationScratch(
  baseUrl: string,
  prefix: string,
): Promise<MigrationScratch> {
  const safePrefix = prefix.toLowerCase().replace(/[^a-z0-9_]/g, "_").slice(0, 24);
  const name = `${safePrefix}_${process.pid}_${randomUUID().replaceAll("-", "").slice(0, 12)}`;
  const url = baseUrl.replace(/\/[^/]*$/, `/${name}`);
  const admin = postgres(baseUrl, { max: 1, onnotice: () => {} });
  let client: postgres.Sql | undefined;
  let closed = false;
  try {
    await admin.unsafe(`CREATE DATABASE "${name}"`);
    client = postgres(url, { max: 4, onnotice: () => {} });
  } catch (error) {
    await admin.unsafe(`DROP DATABASE IF EXISTS "${name}" WITH (FORCE)`).catch(() => {});
    await admin.end({ timeout: 5 });
    throw error;
  }
  return {
    name,
    url,
    client,
    async close() {
      if (closed) return;
      closed = true;
      try {
        await client!.end({ timeout: 5 });
      } finally {
        try {
          await admin.unsafe(`DROP DATABASE IF EXISTS "${name}" WITH (FORCE)`);
        } finally {
          await admin.end({ timeout: 5 });
        }
      }
    },
  };
}
