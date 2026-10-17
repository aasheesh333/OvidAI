/**
 * Shared runtime for the Task-18 migration scripts.
 *
 * The scripts live outside the pnpm workspace packages (`cloud/scripts/`),
 * so bare `@ovid/*` / `ioredis` specifiers do not resolve from this directory.
 * `createRequire` anchored at `apps/mint/package.json` resolves them exactly
 * as the mint process does — no duplicated dependency tree, no NODE_PATH
 * hacks, and the same versions the runtime uses.
 *
 * The scripts are plain TypeScript executed by Node 22's built-in type
 * stripping (`node --experimental-strip-types …`; on Node ≥22.18 the flag is
 * optional). They are NOT compiled by any tsconfig and never ship in an
 * image. `node:sqlite` is built in.
 */

import { createRequire } from "node:module";

const requireFromMint = createRequire(new URL("../../apps/mint/package.json", import.meta.url));

/** The slice of @ovid/db the migration scripts use. */
export interface DbHandle {
  /** postgres.js tagged template (drizzle `$client`). */
  $client: ((
    strings: TemplateStringsArray,
    ...values: unknown[]
  ) => Promise<Array<Record<string, unknown>>>) & {
    end(opts?: { timeout?: number }): Promise<void>;
  };
}

export type DbLike = DbHandle;

export interface RedisLike {
  get(key: string): Promise<string | null>;
  hgetall(key: string): Promise<Record<string, string>>;
  smembers(key: string): Promise<string[]>;
  set(key: string, value: string): Promise<unknown>;
  del(...keys: string[]): Promise<number>;
  disconnect(): void;
}

export interface OvidDbModule {
  createDb(url: string): DbHandle;
  imageJobsRepo: {
    insertRaw(db: DbLike, row: Record<string, unknown>): Promise<void>;
    listRaw(
      db: DbLike,
      opts?: { states?: string[]; limit?: number },
    ): Promise<Array<Record<string, unknown>>>;
    countByState(db: DbLike): Promise<Record<string, number>>;
    insertDeletedAccountRaw(db: DbLike, account: string, deletedAt: number): Promise<void>;
  };
  plansRepo: {
    list(db: DbLike): Promise<Array<Record<string, unknown>>>;
    getSettings(db: DbLike): Promise<Record<string, unknown> | null>;
    allUids(db: DbLike): Promise<string[]>;
    mintUids(db: DbLike): Promise<string[]>;
  };
  migrate(url: string): Promise<void>;
}

export const ovidDb = requireFromMint("@ovid/db") as OvidDbModule;
export const IORedis = requireFromMint("ioredis").Redis as new (url: string) => RedisLike;

// ── CLI helpers ─────────────────────────────────────────────────────────────

export function argValue(argv: string[], name: string): string | undefined {
  const index = argv.indexOf(name);
  if (index === -1) return undefined;
  const value = argv[index + 1];
  if (value === undefined || value.startsWith("--")) {
    throw new Error(`${name} requires a value`);
  }
  return value;
}

export function hasFlag(argv: string[], name: string): boolean {
  return argv.includes(name);
}

/** Required setting: flag → env → throw naming both. */
export function requiredSetting(
  argv: string[],
  flag: string,
  envName: string,
): string {
  const value = argValue(argv, flag) ?? process.env[envName]?.trim();
  if (value === undefined || value === "") {
    throw new Error(`missing ${flag} (or ${envName})`);
  }
  return value;
}

export function isMain(metaUrl: string): boolean {
  const entry = process.argv[1];
  if (entry === undefined) return false;
  try {
    return metaUrl === new URL(`file://${entry}`).href || metaUrl.endsWith(entry);
  } catch {
    return false;
  }
}

export function openDb(url: string): DbHandle {
  return ovidDb.createDb(url);
}

export function openRedis(url: string): RedisLike {
  return new IORedis(url);
}

export async function closeDb(db: ReturnType<typeof openDb>): Promise<void> {
  await db.$client.end({ timeout: 5 });
}

/** Pretty, deterministic report lines (scripts are read by a human owner). */
export function line(label: string, value: unknown): string {
  return `  ${label.padEnd(42)} ${String(value)}`;
}

export function ok(message: string): void {
  console.log(`OK   ${message}`);
}

export function warn(message: string): void {
  console.warn(`WARN ${message}`);
}

export function fail(message: string): never {
  throw new Error(message);
}
