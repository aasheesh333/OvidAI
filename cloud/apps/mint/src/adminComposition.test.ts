import { describe, expect, it, vi } from "vitest";
import { schema, type Db } from "@ovid/db";
import type { Redis } from "ioredis";
import { AdminActionError } from "./adminActions.js";
import {
  createAdminComposition,
  toAdminHttpError,
  type AdminCompositionPorts,
} from "./adminComposition.js";
import { buildMintApps, type MintDeps } from "./app.js";
import type { LiteLlmAdmin } from "./litellmAdmin.js";
import { withBillingAccountWrite } from "./windows.js";

/**
 * UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
 * Round-1/round-2/round-3/round-4/round-5 regressions are source-only until the user explicitly lifts that pause.
 * No RED/GREEN or runtime result is claimed.
 */

const ADMIN = "Bearer owner-only-test-key";
const OLD_KEY = "sk-live-composition-old";
const NEW_KEY = "sk-live-composition-new";
const OLD_KEY_ID = "hashed-composition-old";
const NEW_KEY_ID = "hashed-composition-new";
const INTERNAL_URL = "http://127.0.0.1:45999/private/litellm";
const NOW = new Date("2026-10-25T01:02:03.000Z");
const NOW_SECONDS = Math.floor(NOW.getTime() / 1000);

type Row = Record<string, unknown>;

class FakeRedis {
  readonly values = new Map<string, string>();
  readonly hashes = new Map<string, Map<string, string>>();
  readonly sets = new Map<string, Set<string>>();
  storeWrites = 0;

  constructor(private readonly failStoreWrites: number[] = []) {}

  async get(key: string): Promise<string | null> {
    return this.values.get(key) ?? null;
  }

  async set(key: string, value: string, ...args: unknown[]): Promise<"OK" | null> {
    if (args.includes("NX") && this.values.has(key)) return null;
    this.values.set(key, value);
    return "OK";
  }

  async del(...keys: string[]): Promise<number> {
    let deleted = 0;
    for (const key of keys) if (this.values.delete(key)) deleted += 1;
    return deleted;
  }

  async incr(key: string): Promise<number> {
    const next = Number(this.values.get(key) ?? "0") + 1;
    this.values.set(key, String(next));
    return next;
  }

  async expire(): Promise<number> {
    return 1;
  }

  async sadd(key: string, ...members: string[]): Promise<number> {
    const set = this.sets.get(key) ?? new Set<string>();
    this.sets.set(key, set);
    const before = set.size;
    for (const member of members) set.add(member);
    return set.size - before;
  }

  async sismember(key: string, member: string): Promise<number> {
    return this.sets.get(key)?.has(member) === true ? 1 : 0;
  }

  async hget(key: string, field: string): Promise<string | null> {
    return this.hashes.get(key)?.get(field) ?? null;
  }

  async hset(key: string, ...args: unknown[]): Promise<number> {
    const hash = this.hashes.get(key) ?? new Map<string, string>();
    this.hashes.set(key, hash);
    if (args.length === 1 && typeof args[0] === "object" && args[0] !== null) {
      for (const [field, value] of Object.entries(args[0] as Row)) hash.set(field, String(value));
      return 0;
    }
    hash.set(String(args[0]), String(args[1]));
    return 1;
  }

  async hgetall(key: string): Promise<Record<string, string>> {
    return Object.fromEntries(this.hashes.get(key) ?? []);
  }

  async eval(script: string, numKeys: number, ...args: Array<string | number>): Promise<number> {
    const keys = args.slice(0, numKeys).map(String);
    const values = args.slice(numKeys).map(String);
    if (script.includes("SADD") && keys.length === 4) {
      if (this.values.get(keys[0]!) !== values[0]) return 0;
      this.values.set(keys[1]!, values[1]!);
      this.values.set(keys[2]!, values[2]!);
      const set = this.sets.get(keys[3]!) ?? new Set<string>();
      this.sets.set(keys[3]!, set);
      set.add(values[3]!);
      return 1;
    }
    if (script.includes("KEYS[4]") && keys.length === 4) {
      if (this.values.get(keys[0]!) !== values[0]) return 0;
      this.storeWrites += 1;
      if (this.failStoreWrites.includes(this.storeWrites)) {
        throw new Error(`store write failed ${OLD_KEY} ${INTERNAL_URL}`);
      }
      this.values.set(keys[1]!, values[1]!);
      this.values.set(keys[2]!, values[2]!);
      this.values.set(keys[3]!, values[3]!);
      return 1;
    }
    if (keys.length === 2 && script.includes("current and current ~= '1'")) {
      if (this.values.get(keys[0]!) !== values[0]) return 0;
      const current = this.values.get(keys[1]!);
      if (current !== undefined && current !== "1") return 0;
      if (current === undefined) this.values.set(keys[1]!, "1");
      return this.values.get(keys[1]!) === "1" ? 1 : 0;
    }
    if (script.includes("KEYS[3]") && keys.length === 3) {
      this.storeWrites += 1;
      if (this.failStoreWrites.includes(this.storeWrites)) {
        throw new Error(`store write failed ${OLD_KEY} ${INTERNAL_URL}`);
      }
      for (let index = 0; index < 3; index += 1) {
        this.values.set(keys[index]!, values[index]!);
      }
      return 1;
    }
    if (keys.length === 1 && script.includes("tonumber(ARGV[1])")) {
      const current = Number(this.values.get(keys[0]!) ?? "0");
      const requested = Number(values[0]);
      if (requested < current) return 0;
      this.values.set(keys[0]!, String(requested));
      return 1;
    }
    if (keys.length === 1 && script.includes("if redis.call('GET'")) {
      if (this.values.get(keys[0]!) === values[0]) this.values.delete(keys[0]!);
      return 1;
    }
    throw new Error("unexpected Redis script in composition fixture");
  }
}

interface AuditWrite {
  table: unknown;
  row: Row;
}

interface FixtureOptions {
  ports?: AdminCompositionPorts;
  deleteStatus?: (keyId: string) => number;
  blockStatus?: (keyId: string, blocked: boolean) => number;
  keyInfoResult?: (keyId: string) => { status: number; info: Row | null };
  beforeGenerate?: (call: number) => Promise<void>;
  beforeKeyInfo?: (keyId: string) => Promise<void>;
  auditError?: Error;
  failStoreWrites?: number[];
}

interface Fixture {
  deps: MintDeps;
  redis: FakeRedis;
  audits: AuditWrite[];
  durableUsers: Row[];
  users: Map<string, Row>;
  purchases: Map<string, Row>;
  durableBanned: Set<string>;
  provisioned: Set<string>;
  sql: Array<{ text: string; values: unknown[] }>;
  deletes: string[][];
  blockedKeys: Array<{ key: string; blocked: boolean }>;
  blockedState: Map<string, boolean>;
  keyInfoState: Map<string, Row>;
  generatedBodies: Row[];
  userUpdates: Row[];
  deleteRemoteKey: (keyId: string) => void;
  ports: AdminCompositionPorts;
}

type Predicate = (row: Row) => boolean;

function isChunk(value: unknown, field: "value" | "name" | "queryChunks"): boolean {
  return typeof value === "object" && value !== null && field in value;
}

function chunkText(value: unknown): string | null {
  if (!isChunk(value, "value")) return null;
  const raw = (value as { value: unknown }).value;
  return Array.isArray(raw) ? raw.join("") : typeof raw === "string" ? raw : null;
}

function literal(value: unknown): unknown {
  return isChunk(value, "value") && "encoder" in (value as Row)
    ? (value as { value: unknown }).value
    : value;
}

/** Compile the actual Drizzle condition tree, including remote-outbox OR/LIKE. */
function predicate(condition: unknown): Predicate {
  if (condition === undefined) return () => true;
  if (!isChunk(condition, "queryChunks")) {
    throw new Error("unsupported non-SQL condition in composition fixture");
  }
  let chunks = [...((condition as { queryChunks: unknown[] }).queryChunks)];
  // Drizzle wraps sql.join in another SQL, then wraps that SQL in parentheses.
  // Recursively unwrap BOTH shapes before inspecting separators; compound
  // groups recurse here again, so nested OR/AND trees never stay opaque.
  for (;;) {
    if (chunks.length === 0) return () => true;
    if (chunks.length === 1 && isChunk(chunks[0], "queryChunks")) {
      chunks = [...((chunks[0] as { queryChunks: unknown[] }).queryChunks)];
      continue;
    }
    if (chunkText(chunks[0]) === "(" && chunkText(chunks.at(-1)) === ")") {
      chunks = chunks.slice(1, -1);
      continue;
    }
    break;
  }

  for (const [separator, combine] of [[" or ", "or"], [" and ", "and"]] as const) {
    const groups: unknown[][] = [[]];
    for (const chunk of chunks) {
      if (chunkText(chunk) === separator) {
        groups.push([]);
      } else {
        groups.at(-1)!.push(chunk);
      }
    }
    if (groups.length > 1) {
      const compiled = groups.map((group) => predicate({ queryChunks: group }));
      return combine === "or"
        ? (row) => compiled.some((test) => test(row))
        : (row) => compiled.every((test) => test(row));
    }
  }

  if (chunks.length === 3 && isChunk(chunks[0], "name")) {
    const column = (chunks[0] as { name: string }).name;
    const operator = chunkText(chunks[1])?.trim().toLowerCase() ?? "";
    const right = literal(chunks[2]);
    if (operator === "=") return (row) => row[column] === right;
    if (operator === "like" && typeof right === "string") {
      const pattern = new RegExp(`^${right.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replaceAll("%", ".*").replaceAll("_", ".")}$`);
      return (row) => typeof row[column] === "string" && pattern.test(row[column] as string);
    }
    if (operator === "in" && Array.isArray(right)) {
      const values = right.map(literal);
      return (row) => values.includes(row[column]);
    }
  }
  throw new Error(`unsupported SQL condition in composition fixture: ${JSON.stringify(condition)}`);
}

/**
 * Real query-builder/transaction semantics needed by billingUsers.beginRefresh,
 * withBillingAccountWrite and the unversioned createTierSink path. This is not
 * the old insert-only fake that could never reach the canonical tier write.
 */
function fixtureDb(f: {
  users: Map<string, Row>;
  purchases: Map<string, Row>;
  settings: Map<number, Row>;
  plans: Map<string, Row>;
  overrides: Map<string, Row>;
  audits: AuditWrite[];
  durableUsers: Row[];
  sql: Array<{ text: string; values: unknown[] }>;
  durableBanned: Set<string>;
  provisioned: Set<string>;
}, auditError?: Error): Db {
  const tables = new Map<unknown, () => Row[]>([
    [schema.users, () => [...f.users.values()]],
    [schema.billingPurchases, () => [...f.purchases.values()]],
    [schema.mintSettings, () => [...f.settings.values()]],
    [schema.plans, () => [...f.plans.values()]],
    [schema.userPlanOverrides, () => [...f.overrides.values()]],
  ]);

  function filtered(table: unknown, projection: Row | undefined, condition: unknown, limit: number): Row[] {
    const source = tables.get(table);
    if (source === undefined) throw new Error("unexpected select table in composition fixture");
    const matches = predicate(condition);
    let rows = source().filter(matches);
    if (limit >= 0) rows = rows.slice(0, limit);
    return rows.map((row) => {
      const source = structuredClone(row);
      if (projection === undefined) return source;
      return Object.fromEntries(Object.keys(projection).map((key) => [key, source[key]]));
    });
  }

  function select(projection?: Row): unknown {
    let table: unknown;
    let condition: unknown;
    let limit = -1;
    const query = {
      from(value: unknown) { table = value; return query; },
      where(value: unknown) { condition = value; return query; },
      orderBy() { return query; },
      limit(value: number) { limit = value; return query; },
      for() { return query; },
      then(onfulfilled: (rows: Row[]) => unknown, onrejected?: (error: unknown) => unknown) {
        return Promise.resolve(filtered(table, projection, condition, limit)).then(onfulfilled, onrejected);
      },
    };
    return query;
  }

  function keyFor(table: unknown, row: Row): string | number {
    if (table === schema.users) return String(row.uid);
    if (table === schema.billingPurchases) return String(row.token);
    if (table === schema.mintSettings) return Number(row.id ?? 1);
    if (table === schema.plans) return String(row.id);
    if (table === schema.userPlanOverrides) return String(row.uid);
    throw new Error("unexpected insert table in composition fixture");
  }

  function store(table: unknown, row: Row, conflict?: { set: Row }): void {
    if (table === schema.mintAudit) {
      if (auditError !== undefined) throw auditError;
      f.audits.push({ table, row: structuredClone(row) });
      return;
    }
    const key = keyFor(table, row);
    if (table === schema.users) {
      f.durableUsers.push(structuredClone(row));
      if (row.mintProvisioned === true) f.provisioned.add(String(key));
      const previous = f.users.get(String(key)) ?? {};
      f.users.set(String(key), { ...previous, ...structuredClone(row), ...(conflict?.set ?? {}) });
    } else if (table === schema.billingPurchases) {
      const previous = f.purchases.get(String(key)) ?? {};
      f.purchases.set(String(key), { ...previous, ...structuredClone(row), ...(conflict?.set ?? {}) });
    } else if (table === schema.mintSettings) {
      f.settings.set(Number(key), { ...structuredClone(row), ...(conflict?.set ?? {}) });
    } else if (table === schema.plans) {
      f.plans.set(String(key), { ...structuredClone(row), ...(conflict?.set ?? {}) });
    } else if (table === schema.userPlanOverrides) {
      f.overrides.set(String(key), { ...structuredClone(row), ...(conflict?.set ?? {}) });
    }
  }

  function runSql(text: string, values: unknown[]): Row[] {
    f.sql.push({ text, values });
    const uid = typeof values[0] === "string" ? values[0] : "";
    if (text.startsWith("SELECT banned_at IS NOT NULL")) {
      return [{ banned: f.durableBanned.has(uid) }];
    }
    if (text.startsWith("INSERT INTO users (uid, banned_at")) {
      f.durableBanned.add(uid);
      return [];
    }
    if (text.startsWith("UPDATE users SET banned_at = NULL")) {
      f.durableBanned.delete(uid);
      return [];
    }
    if (text.startsWith("INSERT INTO users (uid, mint_provisioned)")) {
      f.provisioned.add(uid);
      return [];
    }
    if (text.startsWith("SELECT pg_advisory_xact_lock")) return [];
    throw new Error(`unexpected raw SQL in composition fixture: ${text}`);
  }

  function executeSql(query: unknown): Row[] {
    const values: unknown[] = [];
    function render(value: unknown): string {
      const text = chunkText(value);
      if (text !== null && !("encoder" in (value as Row))) return text;
      if (isChunk(value, "queryChunks")) {
        return ((value as { queryChunks: unknown[] }).queryChunks).map(render).join("");
      }
      if (isChunk(value, "name")) return String((value as { name: unknown }).name);
      if (Array.isArray(value)) return value.map(render).join(", ");
      values.push(literal(value));
      return "?";
    }
    return runSql(render(query).replace(/\s+/g, " ").trim(), values);
  }

  const db: any = {
    $client(strings: TemplateStringsArray, ...values: unknown[]) {
      return Promise.resolve(runSql(strings.join("?").replace(/\s+/g, " ").trim(), values));
    },
    select,
    insert(table: unknown) {
      return {
        values(row: Row) {
          const mutation = {
            async onConflictDoUpdate(options: { set: Row }) {
              store(table, row, options);
            },
            then(onfulfilled: (value: undefined) => unknown, onrejected?: (error: unknown) => unknown) {
              return Promise.resolve().then(() => { store(table, row); }).then(() => undefined).then(onfulfilled, onrejected);
            },
          };
          return mutation;
        },
      };
    },
    update(table: unknown) {
      let changes: Row = {};
      let condition: unknown;
      const mutation = {
        set(value: Row) { changes = value; return mutation; },
        where(value: unknown) { condition = value; return mutation; },
        then(onfulfilled: (value: undefined) => unknown, onrejected?: (error: unknown) => unknown) {
          return Promise.resolve().then(() => {
            const source = tables.get(table);
            if (source === undefined) throw new Error("unexpected update table in composition fixture");
            const matches = predicate(condition);
            for (const row of source()) {
              if (matches(row)) Object.assign(row, structuredClone(changes));
            }
          }).then(() => undefined).then(onfulfilled, onrejected);
        },
      };
      return mutation;
    },
    async execute(query: unknown) {
      executeSql(query);
    },
    async transaction<T>(operation: (tx: unknown) => Promise<T>): Promise<T> {
      return operation(db);
    },
  };
  return db as unknown as Db;
}

function fixture(options: FixtureOptions = {}): Fixture {
  const redis = new FakeRedis(options.failStoreWrites);
  const audits: AuditWrite[] = [];
  const durableUsers: Row[] = [];
  const users = new Map<string, Row>();
  const purchases = new Map<string, Row>();
  const durableBanned = new Set<string>();
  const provisioned = new Set<string>();
  const sql: Array<{ text: string; values: unknown[] }> = [];
  const deletes: string[][] = [];
  const blockedKeys: Array<{ key: string; blocked: boolean }> = [];
  const blockedState = new Map<string, boolean>();
  const generatedBodies: Row[] = [];
  const userUpdates: Row[] = [];
  const deletedKeyIds = new Set<string>();
  const keyInfoState = new Map<string, Row>();
  const userBudgets = new Map<string, Row>();
  let generateCalls = 0;

  const db = fixtureDb({
    users,
    purchases,
    settings: new Map(),
    plans: new Map(),
    overrides: new Map(),
    audits,
    durableUsers,
    sql,
    durableBanned,
    provisioned,
  }, options.auditError);

  function deleteRemoteKey(key: string): void {
    // External deletion must not masquerade as adapter cleanup in `deletes`.
    deletedKeyIds.add(key);
    keyInfoState.delete(key);
    blockedState.delete(key);
  }

  async function readKeyInfo(key: string): Promise<{ status: number; info: Row | null }> {
    await options.beforeKeyInfo?.(key);
    if (options.keyInfoResult !== undefined) return options.keyInfoResult(key);
    if (deletedKeyIds.has(key) || !keyInfoState.has(key)) return { status: 404, info: null };
    return { status: 200, info: structuredClone(keyInfoState.get(key)!) };
  }

  const litellm = {
    async keyGenerate(body: Row) {
      generateCalls += 1;
      await options.beforeGenerate?.(generateCalls);
      generatedBodies.push(structuredClone(body));
      const key = generateCalls === 1 ? NEW_KEY : `${NEW_KEY}-${generateCalls}`;
      const token = generateCalls === 1 ? NEW_KEY_ID : `${NEW_KEY_ID}-${generateCalls}`;
      const blocked = body.blocked === true;
      blockedState.set(token, blocked);
      keyInfoState.set(token, {
        ...structuredClone(body),
        token,
        key_id: token,
        blocked,
        budget_duration: body.budget_duration ?? "24h",
      });
      return { key, token };
    },
    async keyDelete(keys: string[]) {
      deletes.push([...keys]);
      const status = options.deleteStatus?.(keys[0]!) ?? 200;
      if ((status >= 200 && status < 300) || status === 404) {
        for (const key of keys) deletedKeyIds.add(key);
      }
      return status;
    },
    async keyInfoStatus(key: string) {
      return readKeyInfo(key);
    },
    async keyUpdateStatus(body: Row) {
      const key = String(body.key ?? "");
      const info = keyInfoState.get(key);
      if (deletedKeyIds.has(key) || info === undefined) return 404;
      Object.assign(info, structuredClone(body));
      return 200;
    },
    async keyBlock(key: string) {
      blockedKeys.push({ key, blocked: true });
      const status = options.blockStatus?.(key, true) ?? 200;
      if (status >= 200 && status < 300) {
        blockedState.set(key, true);
        const info = keyInfoState.get(key);
        if (info !== undefined) info.blocked = true;
      }
      return status;
    },
    async keyUnblock(key: string) {
      blockedKeys.push({ key, blocked: false });
      const status = options.blockStatus?.(key, false) ?? 200;
      if (status >= 200 && status < 300) {
        blockedState.set(key, false);
        const info = keyInfoState.get(key);
        if (info !== undefined) info.blocked = false;
      }
      return status;
    },
    async modelInfo() {
      return [{ model_name: "auto", model_info: {}, litellm_params: { model: "auto" } }];
    },
    async userInfoStatus() {
      return { status: 404, info: null };
    },
    async userUpdate(body: Row) {
      userUpdates.push(structuredClone(body));
      userBudgets.set(String(body.user_id), structuredClone(body));
      return 200;
    },
  } as unknown as LiteLlmAdmin;

  // A real per-UID async serializer for composition tests. The canonical plan
  // test separately exercises the actual billing protocol through fixtureDb.
  const accountTails = new Map<string, Promise<void>>();
  const accountWrite: NonNullable<AdminCompositionPorts["accountWrite"]> = async (uid, operation) => {
    const previous = accountTails.get(uid) ?? Promise.resolve();
    let release!: () => void;
    const current = new Promise<void>((resolve) => { release = resolve; });
    const tail = previous.then(() => current);
    accountTails.set(uid, tail);
    await previous;
    try {
      // Keep the real AsyncLocalStorage generation/lock protocol while the
      // fixture supplies deterministic per-UID serialization for race cases.
      return await withBillingAccountWrite(deps, uid, operation);
    } finally {
      release();
      if (accountTails.get(uid) === tail) accountTails.delete(uid);
    }
  };

  const ports: AdminCompositionPorts = {
    projection: {
      async publishUserState(uid, options) {
        if (options?.clearBan === true) {
          await redis.del(`user:${uid}:banned`);
        } else if (durableBanned.has(uid)) {
          await redis.set(`user:${uid}:banned`, "admin");
        }
      },
      async publishUserTier() {},
    },
    accountWrite,
    reapplyUser: async () => ({ keys: 0, errors: 0 }),
    creationBody: async ({ uid, platform }) => ({
      user_id: uid,
      max_budget: 1,
      budget_duration: "24h",
      metadata: { tier: "pro", ovid_uid: uid, platform },
      rpm_limit: 10,
      tpm_limit: 100,
      max_parallel_requests: 2,
      models: ["auto", "ovid-image"],
      api_base: INTERNAL_URL,
    }),
    resetAnomalyAndRate: async () => {},
    ...options.ports,
  };

  const deps = {
    db,
    redis: redis as unknown as Redis,
    litellm,
    env: {
      adminMasterKey: "owner-only-test-key",
      litellmBaseUrl: INTERNAL_URL,
      litellmMasterKey: "litellm-master-fixture",
      webTeamDailyUsd: 25,
      abuse: {
        newkeyWindowS: 3600,
        globalNewkeysPerWindow: 500,
      },
    },
    alerter: async () => {},
    verifyIdentity: async () => {
      throw new Error("Firebase identity must not be used by owner admin composition");
    },
    fetchImpl: async (url: string | URL) => {
      const parsed = new URL(url);
      if (parsed.pathname.endsWith("/user/info")) {
        const info = userBudgets.get(parsed.searchParams.get("user_id") ?? "") ?? {};
        return new Response(JSON.stringify({ user_info: info }), { status: 200 });
      }
      if (parsed.pathname.endsWith("/key/info")) {
        const current = await readKeyInfo(parsed.searchParams.get("key") ?? "");
        return new Response(JSON.stringify({ info: current.info }), { status: current.status });
      }
      if (parsed.pathname.endsWith("/key/list")) {
        const uid = parsed.searchParams.get("user_id");
        const keys = [...keyInfoState.entries()]
          .filter(([key, info]) => !deletedKeyIds.has(key) && (uid === null || info.user_id === uid))
          .map(([, info]) => structuredClone(info));
        return new Response(JSON.stringify({ keys, total_pages: 1 }), { status: 200 });
      }
      return new Response("not found", { status: 404 });
    },
    clock: () => NOW,
    mintLock: { pollMs: 0, polls: 0 },
  } as unknown as MintDeps;
  return {
    deps,
    redis,
    audits,
    durableUsers,
    users,
    purchases,
    durableBanned,
    provisioned,
    sql,
    deletes,
    blockedKeys,
    blockedState,
    keyInfoState,
    generatedBodies,
    userUpdates,
    deleteRemoteKey,
    ports,
  };
}

function actions(f: Fixture, ports: AdminCompositionPorts = f.ports) {
  return createAdminComposition(f.deps, ports).forRequest({
    trustedRequestIp: "203.0.113.10",
  });
}

function seedAndroidKey(f: Fixture, generation = "1", blocked = false): void {
  f.redis.values.set("user:u1:keyid", OLD_KEY_ID);
  f.redis.values.set("user:u1:key", OLD_KEY);
  f.redis.values.set("user:u1:key_generation", generation);
  f.blockedState.set(OLD_KEY_ID, blocked);
  f.keyInfoState.set(OLD_KEY_ID, {
    token: OLD_KEY_ID,
    user_id: "u1",
    blocked,
    budget_duration: "24h",
  });
}

function publicText(value: unknown): string {
  return JSON.stringify(value);
}

function expectSafe(text: string): void {
  expect(text).not.toContain(OLD_KEY);
  expect(text).not.toContain(NEW_KEY);
  expect(text).not.toContain(OLD_KEY_ID);
  expect(text).not.toContain(NEW_KEY_ID);
  expect(text).not.toContain(INTERNAL_URL);
  expect(text).not.toContain("Firebase identity");
}

describe("owner authorization and audit composition", () => {
  it("uses requireAdmin rather than Firebase and records only the trusted request IP", async () => {
    const f = fixture();
    seedAndroidKey(f);
    const result = await actions(f).block({
      authorization: ADMIN,
      uid: "u1",
      reason: "confirmed-abuse",
      ip: "198.51.100.99",
    } as unknown as Parameters<ReturnType<typeof actions>["block"]>[0]);

    expect(result).toEqual({ ok: true });
    expect(f.blockedKeys).toEqual([{ key: OLD_KEY_ID, blocked: true }]);
    const banWrite = f.sql.find(({ text }) => text.startsWith("INSERT INTO users (uid, banned_at"));
    expect(banWrite?.text).toContain("INSERT INTO users");
    expect(banWrite?.values).toEqual(["u1", "2026-10-25T01:02:03Z", "admin"]);
    expect(f.audits).toHaveLength(1);
    expect(f.audits[0]?.table).toBe(schema.mintAudit);
    expect(f.audits[0]?.row).toMatchObject({
      actor: "master-key",
      action: "block",
      target: { uid: "u1" },
      before: { reason: "confirmed-abuse" },
      after: { status: "succeeded" },
      ip: "203.0.113.10",
    });
    expect(publicText(f.audits)).not.toContain("198.51.100.99");
    expectSafe(publicText(f.audits));
  });

  it("denies every non-owner action before validation, configuration, effects or audit", async () => {
    const f = fixture();
    seedAndroidKey(f);
    const admin = createAdminComposition(f.deps, {
      ...f.ports,
      resetAnomalyAndRate: undefined,
    }).forRequest({ trustedRequestIp: "203.0.113.10" });
    const calls = [
      () => admin.block({ authorization: "Bearer firebase-user", uid: "u1", reason: "block" }),
      () => admin.unblock({ authorization: "Bearer firebase-user", uid: "u1", reason: "appeal" }),
      () => admin.rotateKey({ authorization: "Bearer firebase-user", uid: "u1", platform: "invalid", reason: "incident-64" } as never),
      () => admin.resetAnomalyAndRate({ authorization: "Bearer firebase-user", uid: "u1", reason: "reset" }),
      () => admin.adjustPlan({ authorization: "Bearer firebase-user", uid: "u1", plan: "7x", reason: "grant" }),
    ];
    for (const call of calls) {
      await expect(call()).rejects.toMatchObject({ status: 403, message: "not an administrator" });
    }
    await expect(admin.resetAnomalyAndRate({
      authorization: "",
      uid: "u1",
      reason: "reset",
    })).rejects.toMatchObject({ status: 401, message: "missing admin authorization" });
    await expect(admin.adjustPlan({
      authorization: "",
      uid: "u1",
      plan: "7x",
      reason: "grant",
    })).rejects.toMatchObject({ status: 401, message: "missing admin authorization" });
    expect(f.sql).toEqual([]);
    expect(f.audits).toEqual([]);
    expect(f.deletes).toEqual([]);
    expect(f.blockedKeys).toEqual([]);
    expect(f.durableUsers).toEqual([]);
  });

  it("preserves the existing ban projection then live-key ordering on unban", async () => {
    const f = fixture();
    const order: string[] = [];
    f.ports.projection = {
      async publishUserState(_uid, options) {
        order.push(`projection:${options?.clearBan === true}`);
      },
      async publishUserTier() {},
    };
    seedAndroidKey(f, "1", true);
    f.durableBanned.add("u1");
    f.redis.values.set("user:u1:banned", "admin");
    const litellm = f.deps.litellm;
    const original = litellm.keyUnblock.bind(litellm);
    vi.spyOn(litellm, "keyUnblock").mockImplementation(async (key) => {
      order.push("live-key");
      return original(key);
    });

    await expect(actions(f).unblock({
      authorization: ADMIN,
      uid: "u1",
      reason: "appeal-accepted",
    })).resolves.toEqual({ ok: true });
    expect(order).toEqual(["projection:true", "live-key"]);
    expect(f.sql.some(({ text }) => text.startsWith("UPDATE users SET banned_at = NULL"))).toBe(true);
    expect(f.sql.some(({ text }) => text.startsWith("INSERT INTO users (uid, banned_at"))).toBe(false);
  });

  it("runs the live ban effect and records failure after a degraded projection", async () => {
    const f = fixture();
    f.ports.projection = {
      async publishUserState() {
        throw new Error(`projection failed ${OLD_KEY} ${INTERNAL_URL}`);
      },
      async publishUserTier() {},
    };
    seedAndroidKey(f);
    await expect(actions(f).block({
      authorization: ADMIN,
      uid: "u1",
      reason: "confirmed-abuse",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(f.blockedKeys).toEqual([{ key: OLD_KEY_ID, blocked: true }]);
    expect(f.audits[0]?.row.after).toEqual({ status: "failed" });
  });

  it("restores durable ban and re-blocks after an unblock remote failure", async () => {
    const f = fixture({
      blockStatus: (_key, blocked) => blocked ? 200 : 500,
    });
    seedAndroidKey(f, "1", true);
    f.durableBanned.add("u1");
    f.redis.values.set("user:u1:banned", "admin");
    await expect(actions(f).unblock({
      authorization: ADMIN,
      uid: "u1",
      reason: "appeal-accepted",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(f.durableBanned.has("u1")).toBe(true);
    expect(f.redis.values.get("user:u1:banned")).toBe("admin");
    expect(f.blockedState.get(OLD_KEY_ID)).toBe(true);
    expect(f.blockedKeys[0]).toEqual({ key: OLD_KEY_ID, blocked: false });
    expect(f.blockedState.get(OLD_KEY_ID)).toBe(true);
    expect(f.audits.at(-1)?.row.after).toEqual({ status: "failed" });
  });

  it("restores blocked state after an unblock projection failure", async () => {
    const f = fixture();
    f.ports.projection = {
      async publishUserState() {
        throw new Error(`projection failed ${OLD_KEY} ${INTERNAL_URL}`);
      },
      async publishUserTier() {},
    };
    seedAndroidKey(f, "1", true);
    f.durableBanned.add("u1");
    f.redis.values.set("user:u1:banned", "admin");
    await expect(actions(f).unblock({
      authorization: ADMIN,
      uid: "u1",
      reason: "appeal-accepted",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(f.durableBanned.has("u1")).toBe(true);
    expect(f.blockedState.get(OLD_KEY_ID)).toBe(true);
    expect(f.blockedKeys).toEqual([
      { key: OLD_KEY_ID, blocked: false },
      { key: OLD_KEY_ID, blocked: true },
    ]);
    expect(f.audits.at(-1)?.row.after).toEqual({ status: "failed" });
  });

  it("keeps failed bans unresolved and proves blocked state on the retry", async () => {
    let calls = 0;
    const f = fixture({
      blockStatus: () => {
        calls += 1;
        return calls === 1 ? 500 : 200;
      },
    });
    seedAndroidKey(f);
    const admin = actions(f);
    await expect(admin.block({
      authorization: ADMIN,
      uid: "u1",
      reason: "confirmed-abuse",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(f.durableBanned.has("u1")).toBe(true);
    expect(f.audits.at(-1)?.row.after).toEqual({ status: "failed" });
    await expect(admin.block({
      authorization: ADMIN,
      uid: "u1",
      reason: "confirmed-abuse",
    })).resolves.toEqual({ ok: true });
    expect(f.blockedState.get(OLD_KEY_ID)).toBe(true);
    expect(f.audits.at(-1)?.row.after).toEqual({ status: "succeeded" });
  });

  it.each([
    "redis://internal:6379/2",
    "postgres://internal/db",
    "file:///etc/passwd",
    "mailto:ops@example.internal",
    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1MSJ9.c2lnbmF0dXJl",
    "ghp_1234567890abcdefghijklmnop",
    "AKIAIOSFODNN7EXAMPLE",
    "-----BEGIN PRIVATE KEY-----",
    "aWdub3JlLXRoaXMtYmFzZTY0LXNlY3JldC12YWx1ZQ==",
    "http:/localhost/admin",
    "//localhost/admin",
    "https:%2f%2finternal/admin",
    "http://[::1]:4000/admin",
    "redis+ssl://user:pass@internal:6379/2",
    "auth_token=abc123",
    "refresh_token=abc123",
    "id_token:abc123",
    "client-key=abc123",
    "Basic YWxhZGRpbjpvcGVuc2VzYW1l",
    "x-api-key:abc123",
    "postgres://internal/db?sslmode=require",
  ])("rejects URL or secret reason %s before any effect, audit or sensitive public text", async (reason) => {
    const f = fixture();
    seedAndroidKey(f);
    let error: unknown;
    try {
      await actions(f).block({ authorization: ADMIN, uid: "u1", reason });
    } catch (caught) {
      error = caught;
    }
    expect(error).toMatchObject({ status: 400, message: "reason is invalid or contains sensitive content" });
    expect(String(error)).not.toContain(reason);
    const http = toAdminHttpError(error);
    expect(publicText({ status: http.status, detail: http.detail })).not.toContain(reason);
    expect(f.sql).toEqual([]);
    expect(f.audits).toEqual([]);
    expect(f.blockedKeys).toEqual([]);
  });
});

describe("server-side key rotation composition", () => {
  it("uses Android mappings, revokes the old id and returns only generation metadata", async () => {
    const f = fixture();
    seedAndroidKey(f);
    const result = await actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-51",
    });

    expect(result).toEqual({ ok: true, platform: "android", generation: 2 });
    expect(f.deletes).toEqual([[OLD_KEY_ID]]);
    expect(f.redis.values.get("user:u1:keyid")).toBe(NEW_KEY_ID);
    expect(f.redis.values.get("user:u1:key")).toBe(NEW_KEY);
    expect(f.redis.values.get("user:u1:key_generation")).toBe("2");
    expect(f.redis.values.has("mintlock:u1")).toBe(false);
    expect(f.generatedBodies[0]?.metadata).toEqual({ tier: "pro", ovid_uid: "u1", platform: "android" });
    expect(f.audits[0]?.row).toMatchObject({
      action: "rotate-key",
      target: { uid: "u1", platform: "android" },
      after: { status: "succeeded", generation: 2 },
      ip: "203.0.113.10",
    });
    expectSafe(publicText({ result, audits: f.audits }));
  });

  it("uses the Web namespace and an independent generation", async () => {
    const f = fixture();
    f.redis.values.set("user:u1:web:keyid", OLD_KEY_ID);
    f.redis.values.set("user:u1:web:key", OLD_KEY);
    f.blockedState.set(OLD_KEY_ID, false);
    f.keyInfoState.set(OLD_KEY_ID, { token: OLD_KEY_ID, user_id: "u1", blocked: false, budget_duration: "24h" });
    const result = await actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "web",
      reason: "incident-52",
    });
    expect(result).toEqual({ ok: true, platform: "web", generation: 2 });
    expect(f.redis.values.get("user:u1:web:key_generation")).toBe("2");
    expect(f.redis.values.has("user:u1:key_generation")).toBe(false);
  });

  it("preserves a durable ban and an old LiteLLM blocked state on the replacement", async () => {
    const f = fixture();
    seedAndroidKey(f, "1", true);
    f.durableBanned.add("u1");
    f.redis.values.set("user:u1:banned", "admin");
    const result = await actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-55",
    });
    expect(result).toEqual({ ok: true, platform: "android", generation: 2 });
    expect(f.generatedBodies[0]?.blocked).toBe(true);
    expect(f.blockedState.get(OLD_KEY_ID)).toBe(true);
    expect(f.blockedState.get(NEW_KEY_ID)).toBe(true);
    expect(f.blockedKeys.some(({ blocked }) => !blocked)).toBe(false);
  });

  it("preserves provider-only blocked state without requiring a durable ban", async () => {
    const f = fixture();
    seedAndroidKey(f, "1", true);
    expect(f.durableBanned.has("u1")).toBe(false);
    expect(f.redis.values.has("user:u1:banned")).toBe(false);
    await expect(actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-66",
    })).resolves.toEqual({ ok: true, platform: "android", generation: 2 });
    expect(f.generatedBodies[0]?.blocked).toBe(true);
    expect(f.blockedState.get(OLD_KEY_ID)).toBe(true);
    expect(f.blockedState.get(NEW_KEY_ID)).toBe(true);
  });

  it.each([0, 401, 403, 500])(
    "fails closed on provider key-info status %s instead of assuming unblocked",
    async (status) => {
      const f = fixture({
        keyInfoResult: () => ({ status, info: status === 200 ? { blocked: true } : null }),
      });
      seedAndroidKey(f, "1", true);
      await expect(actions(f).rotateKey({
        authorization: ADMIN,
        uid: "u1",
        platform: "android",
        reason: "incident-67",
      })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
      expect(f.generatedBodies).toEqual([]);
      expect(f.deletes).toEqual([]);
      expect(f.redis.values.get("user:u1:keyid")).toBe(OLD_KEY_ID);
      expect(f.blockedState.get(OLD_KEY_ID)).toBe(true);
    },
  );

  it("fails closed when a 200 key-info response omits blocked state", async () => {
    const f = fixture({
      keyInfoResult: () => ({ status: 200, info: { budget_duration: "24h" } }),
    });
    seedAndroidKey(f, "1", true);
    await expect(actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-68",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(f.generatedBodies).toEqual([]);
    expect(f.deletes).toEqual([]);
    expect(f.redis.values.get("user:u1:keyid")).toBe(OLD_KEY_ID);
    expect(f.blockedState.get(OLD_KEY_ID)).toBe(true);
  });

  it("never reports replacement success when remote blocking is unresolved or deleted", async () => {
    // Generate readback is alias-based (/key/list), not /key/info. The FIRST
    // direct new-key read is the generic block pre-read: make it live/unblocked
    // so the real keyBlock is sent and its configured 500 drives cleanup.
    let failedBlock!: Fixture;
    let failedBlockReads = 0;
    failedBlock = fixture({
      beforeKeyInfo: async (key) => {
        if (key === NEW_KEY_ID && ++failedBlockReads === 1) {
          failedBlock.blockedState.set(key, false);
          const info = failedBlock.keyInfoState.get(key);
          if (info !== undefined) info.blocked = false;
        }
      },
      blockStatus: (key, blocked) => key === NEW_KEY_ID && blocked ? 500 : 200,
    });
    seedAndroidKey(failedBlock, "1", true);
    await expect(actions(failedBlock).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-69",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(failedBlock.blockedKeys).toContainEqual({ key: NEW_KEY_ID, blocked: true });
    expect(failedBlock.deletes).toEqual([[NEW_KEY_ID]]);
    expect(failedBlock.deletes).not.toContainEqual([OLD_KEY_ID]);
    expect(failedBlock.redis.values.get("user:u1:keyid")).toBe(OLD_KEY_ID);
    expect(failedBlock.blockedState.get(OLD_KEY_ID)).toBe(true);
    expect(failedBlock.audits.at(-1)?.row.after).toEqual({ status: "failed" });

    // Delete externally on that same FIRST direct read. This drives the generic
    // block's terminalAbsent/terminal-404 branch without logging a fake adapter
    // deletion. The mandatory final guard must still fail. Cleanup is proven
    // by its durable delete operation, not by an already-absent provider send;
    // the old key must never be revoked.
    let deleted!: Fixture;
    let deletedReads = 0;
    deleted = fixture({
      beforeKeyInfo: async (key) => {
        if (key === NEW_KEY_ID && ++deletedReads === 1) deleted.deleteRemoteKey(key);
      },
    });
    seedAndroidKey(deleted, "1", true);
    await expect(actions(deleted).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-69",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(deleted.blockedKeys).toEqual([]);
    // An already-deleted target is terminalAbsent for cleanup too, so the
    // generic protocol correctly sends no provider keyDelete. Prove cleanup
    // through its durable delete operation instead of transport-call counts.
    expect(deleted.deletes).toEqual([]);
    const replacementRemoteRows = [...deleted.purchases.values()].filter((row) =>
      typeof row.accountHash === "string" &&
      row.accountHash.includes(`"target":"${NEW_KEY_ID}"`),
    );
    expect(replacementRemoteRows.some((row) =>
      (row.accountHash as string).includes('"blocked":true') &&
      (row.accountHash as string).includes('"resolution":"terminal-404"'),
    )).toBe(true);
    expect(replacementRemoteRows.some((row) =>
      (row.accountHash as string).includes('"effect":"delete"') &&
      (row.accountHash as string).includes('"resolution":"terminal-404"'),
    )).toBe(true);
    expect(deleted.deletes).not.toContainEqual([OLD_KEY_ID]);
    expect(deleted.redis.values.get("user:u1:keyid")).toBe(OLD_KEY_ID);
    expect(deleted.redis.values.get("user:u1:key_generation")).toBe("1");
    expect(deleted.blockedState.get(OLD_KEY_ID)).toBe(true);
    expect(deleted.audits.at(-1)?.row.after).toEqual({ status: "failed" });
    expect(deleted.audits.at(-1)?.row.after).not.toEqual({ status: "succeeded" });

    // The second direct read is the adapter's final guard when the generic
    // block was already applied. A non-200/unknown result there must also fail
    // closed rather than install or revoke (distinct from terminal absence).
    let unknown!: Fixture;
    let unknownReads = 0;
    unknown = fixture({
      keyInfoResult: (key) => {
        if (key === NEW_KEY_ID && ++unknownReads === 2) return { status: 503, info: null };
        const info = unknown.keyInfoState.get(key);
        return info === undefined
          ? { status: 404, info: null }
          : { status: 200, info: structuredClone(info) };
      },
    });
    seedAndroidKey(unknown, "1", true);
    await expect(actions(unknown).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-69",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(unknown.generatedBodies).toHaveLength(1);
    expect(unknown.redis.values.get("user:u1:keyid")).toBe(OLD_KEY_ID);
    expect(unknown.redis.values.get("user:u1:key_generation")).toBe("1");
    expect(unknown.deletes).not.toContainEqual([OLD_KEY_ID]);
    expect(unknown.audits.at(-1)?.row.after).toEqual({ status: "failed" });
  });

  it("serializes ban and rotation through the same per-UID writer", async () => {
    let releaseFirst!: () => void;
    let generateStarted!: () => void;
    const firstWaiting = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const started = new Promise<void>((resolve) => { generateStarted = resolve; });
    const f = fixture({
      beforeGenerate: async (call) => {
        if (call === 1) {
          generateStarted();
          await firstWaiting;
        }
      },
    });
    seedAndroidKey(f);
    const admin = actions(f);
    const rotation = admin.rotateKey({ authorization: ADMIN, uid: "u1", platform: "android", reason: "incident-64" });
    await started;
    const ban = admin.block({ authorization: ADMIN, uid: "u1", reason: "confirmed-abuse" });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(f.sql.some(({ text }) => text.startsWith("INSERT INTO users (uid, banned_at"))).toBe(false);
    expect(f.blockedKeys).toEqual([]);
    releaseFirst();
    await expect(rotation).resolves.toEqual({ ok: true, platform: "android", generation: 2 });
    await expect(ban).resolves.toEqual({ ok: true });
    expect(f.blockedKeys).toContainEqual({ key: NEW_KEY_ID, blocked: true });
    expect(f.blockedState.get(NEW_KEY_ID)).toBe(true);
  });

  it("uses canonical first-key registration, breaker and user-budget provisioning", async () => {
    const f = fixture();
    const result = await actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "first-key-recovery",
    });
    expect(result).toEqual({ ok: true, platform: "android", generation: 1 });
    expect(f.generatedBodies).toHaveLength(1);
    expect(f.redis.values.get(`newkeys:${Math.floor(NOW_SECONDS / 3600)}`)).toBe("1");
    expect(f.redis.sets.get("ovid:uids")?.has("u1")).toBe(true);
    expect(f.provisioned.has("u1")).toBe(true);
    expect(f.userUpdates).toEqual([
      { user_id: "u1", max_budget: 10, budget_duration: "30d" },
    ]);
    expect(f.purchases.get("revenuecat:remote:u1")?.status).toBe("replaced");
    expect(f.purchases.get("revenuecat:remote:u1")?.productId).toBe("litellm_remote_v2");
    expect([...f.purchases.keys()].filter((token) => token.startsWith("revenuecat:remote:u1:"))).not.toEqual([]);
    expect(f.purchases.get("revenuecat:refresh:u1")?.productId).toBe("revenuecat_refresh");
    expect(f.redis.values.get("user:u1:key_generation")).toBe("1");
    expect(f.deletes).toEqual([]);
    expectSafe(publicText({ result, audits: f.audits }));
  });

  it("keeps a banned first key blocked through the canonical mint path", async () => {
    const f = fixture();
    f.durableBanned.add("u1");
    f.redis.values.set("user:u1:banned", "auto");
    await expect(actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-56",
    })).resolves.toEqual({ ok: true, platform: "android", generation: 1 });
    expect(f.generatedBodies[0]?.blocked).toBe(true);
    expect(f.blockedState.get(NEW_KEY_ID)).toBe(true);
    expect(f.provisioned.has("u1")).toBe(true);
  });

  it("does not install or report a banned first key when blocking fails", async () => {
    const f = fixture({
      blockStatus: (key, blocked) => key === NEW_KEY_ID && blocked ? 500 : 200,
    });
    f.durableBanned.add("u1");
    f.redis.values.set("user:u1:banned", "auto");
    await expect(actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-70",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(f.redis.values.has("user:u1:keyid")).toBe(false);
    expect(f.redis.values.has("user:u1:key_generation")).toBe(false);
    expect(f.deletes).toEqual([[NEW_KEY_ID]]);
    expect(f.durableBanned.has("u1")).toBe(true);
    expect(f.audits.at(-1)?.row.after).toEqual({ status: "failed" });
  });

  it("builds the default creation body from tier, limits and public model scope", async () => {
    const f = fixture({ ports: { creationBody: undefined } });
    seedAndroidKey(f);
    await expect(actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-57",
    })).resolves.toEqual({ ok: true, platform: "android", generation: 2 });
    expect(f.generatedBodies[0]).toMatchObject({
      user_id: "u1",
      max_budget: 0.15,
      budget_duration: "24h",
      metadata: { tier: "free", ovid_uid: "u1", platform: "android" },
      rpm_limit: 240,
      tpm_limit: 4_000_000,
      max_parallel_requests: 16,
      models: ["auto", "ovid-image"],
    });
    expect(f.generatedBodies[0]).not.toHaveProperty("api_base");
    expect(f.generatedBodies[0]).not.toHaveProperty("base_url");
  });

  it("does not steal another writer's mint lock or churn keys when it is held", async () => {
    const f = fixture();
    seedAndroidKey(f);
    f.redis.values.set("mintlock:u1", "another-writer");
    await expect(actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-58",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(f.generatedBodies).toEqual([]);
    expect(f.deletes).toEqual([]);
    expect(f.redis.values.get("mintlock:u1")).toBe("another-writer");
    expect(f.redis.values.get("user:u1:key")).toBe(OLD_KEY);
  });

  it("serializes the whole lifecycle per uid and platform", async () => {
    let releaseFirst!: () => void;
    const firstWaiting = new Promise<void>((resolve) => { releaseFirst = resolve; });
    const f = fixture({
      beforeGenerate: async (call) => {
        if (call === 1) await firstWaiting;
      },
    });
    seedAndroidKey(f);
    const admin = actions(f);
    const first = admin.rotateKey({ authorization: ADMIN, uid: "u1", platform: "android", reason: "incident-62" });
    const second = admin.rotateKey({ authorization: ADMIN, uid: "u1", platform: "android", reason: "incident-63" });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(f.generatedBodies).toHaveLength(0);
    releaseFirst();
    await expect(first).resolves.toEqual({ ok: true, platform: "android", generation: 2 });
    await expect(second).resolves.toEqual({ ok: true, platform: "android", generation: 3 });
    expect(f.deletes).toEqual([[OLD_KEY_ID], [NEW_KEY_ID]]);
    expect(f.redis.values.get("user:u1:key_generation")).toBe("3");
  });

  it("restores a still-blocked old reference and removes the replacement after revoke failure", async () => {
    const f = fixture({ deleteStatus: (keyId) => keyId === OLD_KEY_ID ? 500 : 200 });
    seedAndroidKey(f, "1", true);
    f.durableBanned.add("u1");
    await expect(actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-53",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(f.redis.values.get("user:u1:keyid")).toBe(OLD_KEY_ID);
    expect(f.redis.values.get("user:u1:key")).toBe(OLD_KEY);
    expect(f.redis.values.get("user:u1:key_generation")).toBe("1");
    expect(f.deletes).toEqual([[OLD_KEY_ID], [NEW_KEY_ID]]);
    expect(f.blockedState.get(OLD_KEY_ID)).toBe(true);
    expect(f.audits[0]?.row.after).toEqual({ status: "failed" });
  });

  it("keeps a blocked reachable replacement when old-reference restoration fails", async () => {
    const f = fixture({
      deleteStatus: (keyId) => keyId === OLD_KEY_ID ? 500 : 200,
      failStoreWrites: [2],
    });
    seedAndroidKey(f, "1", true);
    f.durableBanned.add("u1");
    await expect(actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-59",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(f.redis.values.get("user:u1:keyid")).toBe(NEW_KEY_ID);
    expect(f.redis.values.get("user:u1:key")).toBe(NEW_KEY);
    expect(f.blockedState.get(NEW_KEY_ID)).toBe(true);
    expect(f.deletes).toEqual([[OLD_KEY_ID]]);
    expect(f.audits[0]?.row.after).toEqual({ status: "failed" });
  });

  it("does not disguise replacement-cleanup failure as rotation success", async () => {
    const f = fixture({ deleteStatus: () => 500 });
    seedAndroidKey(f, "1", true);
    f.durableBanned.add("u1");
    await expect(actions(f).rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "android",
      reason: "incident-60",
    })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
    expect(f.redis.values.get("user:u1:keyid")).toBe(OLD_KEY_ID);
    expect(f.deletes).toEqual([[OLD_KEY_ID], [NEW_KEY_ID]]);
    expect(f.blockedState.get(OLD_KEY_ID)).toBe(true);
    expect(f.blockedState.get(NEW_KEY_ID)).toBe(true);
    expect(f.audits[0]?.row.after).toEqual({ status: "failed" });
  });

  it("does not report rotation success or log secrets when durable audit fails", async () => {
    const f = fixture({ auditError: new Error(`audit unavailable ${NEW_KEY} ${INTERNAL_URL}`) });
    seedAndroidKey(f);
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    try {
      await expect(actions(f).rotateKey({
        authorization: ADMIN,
        uid: "u1",
        platform: "android",
        reason: "incident-54",
      })).rejects.toMatchObject({ status: 502, message: "admin audit failed" });
      expect(f.redis.values.get("user:u1:key")).toBe(NEW_KEY);
      expect(f.deletes).toEqual([[OLD_KEY_ID]]);
      expect(log).not.toHaveBeenCalled();
      expectSafe(publicText(log.mock.calls));
    } finally {
      log.mockRestore();
    }
  });

  it.each(["0", "-1", "1.5", "not-a-number", String(Number.MAX_SAFE_INTEGER)])(
    "rejects malformed stored generation %s before key generation",
    async (generation) => {
      const f = fixture();
      seedAndroidKey(f, generation);
      await expect(actions(f).rotateKey({
        authorization: ADMIN,
        uid: "u1",
        platform: "android",
        reason: "incident-65",
      })).rejects.toMatchObject({ status: 502, message: "admin action failed" });
      expect(f.generatedBodies).toEqual([]);
      expect(f.deletes).toEqual([]);
      expect(f.redis.values.get("user:u1:keyid")).toBe(OLD_KEY_ID);
    },
  );
});

describe("reset, canonical plan and configuration boundaries", () => {
  it("returns missing reset configuration only after owner authorization", async () => {
    const f = fixture();
    const admin = createAdminComposition(f.deps, {
      ...f.ports,
      resetAnomalyAndRate: undefined,
    }).forRequest({ trustedRequestIp: "203.0.113.10" });
    await expect(admin.resetAnomalyAndRate({
      authorization: ADMIN,
      uid: "u1",
      reason: "false-positive",
    })).rejects.toMatchObject({
      status: 503,
      message: "admin anomaly/rate reset is not configured",
    });
    expect(f.audits).toEqual([]);
  });

  it("resets the owner port and mint strikes without clearing bans, keys or spend", async () => {
    const f = fixture();
    const resets: string[] = [];
    f.ports.resetAnomalyAndRate = async ({ uid }) => { resets.push(uid); };
    f.redis.values.set("abuse:uid:u1", "20");
    f.redis.values.set("user:u1:banned", "auto");
    f.redis.values.set("user:u1:key", OLD_KEY);
    f.redis.values.set("pool:u1:spend", "12.5");
    const result = await actions(f).resetAnomalyAndRate({
      authorization: ADMIN,
      uid: "u1",
      reason: "false-positive",
    });
    expect(result).toEqual({ ok: true });
    expect(resets).toEqual(["u1"]);
    expect(f.redis.values.has("abuse:uid:u1")).toBe(false);
    expect(f.redis.values.get("user:u1:banned")).toBe("auto");
    expect(f.redis.values.get("user:u1:key")).toBe(OLD_KEY);
    expect(f.redis.values.get("pool:u1:spend")).toBe("12.5");
    expect(f.deletes).toEqual([]);
    expect(f.blockedKeys).toEqual([]);
  });

  it("executes the real transaction-backed tier sink with no second SQL entitlement writer", async () => {
    const f = fixture();
    f.redis.values.set("usagecache:u1", "cached");
    const result = await actions(f).adjustPlan({
      authorization: ADMIN,
      uid: "u1",
      plan: "pro",
      reason: "support-grant",
    });
    expect(result).toEqual({ ok: true, plan: "pro" });
    expect(f.durableUsers).toEqual([
      { uid: "u1", tier: "pro", tierExpiresAt: null, mintProvisioned: true },
    ]);
    expect(f.users.get("u1")).toMatchObject({ uid: "u1", tier: "pro", tierExpiresAt: null });
    expect(f.purchases.get("revenuecat:refresh:u1")?.accountHash).toBe("1");
    expect(f.redis.values.get("user:u1:billing_refresh_generation")).toBe("1");
    expect(f.redis.values.has("usagecache:u1")).toBe(false);
    expect(f.sql.filter(({ text }) => !text.startsWith("SELECT pg_advisory_xact_lock"))).toEqual([]);
    expect(f.audits[0]?.row.after).toEqual({ status: "succeeded", plan: "pro" });
  });

  it("refuses a legacy alias only after owner authorization", async () => {
    const f = fixture();
    await expect(actions(f).adjustPlan({
      authorization: ADMIN,
      uid: "u1",
      plan: "7x",
      reason: "support-grant",
    })).rejects.toMatchObject({ status: 400, message: "plan is invalid" });
    expect(f.durableUsers).toEqual([]);
    expect(f.audits).toEqual([]);
  });

  it("maps only exact fixed public errors and never arbitrary AdminActionError text", () => {
    const configured = toAdminHttpError(new AdminActionError(503, "admin anomaly/rate reset is not configured"));
    expect(configured).toMatchObject({ status: 503, detail: "admin anomaly/rate reset is not configured" });
    const auth = toAdminHttpError(new AdminActionError(403, "not an administrator"));
    expect(auth).toMatchObject({ status: 403, detail: "not an administrator" });
    const forged = toAdminHttpError(new AdminActionError(503, `driver failed ${OLD_KEY} ${INTERNAL_URL}`));
    expect(forged).toMatchObject({ status: 500, detail: "admin action failed" });
    const raw = toAdminHttpError(new Error(`driver failed ${OLD_KEY} ${INTERNAL_URL}`));
    expect(raw).toMatchObject({ status: 500, detail: "admin action failed" });
    expectSafe(publicText([
      { status: forged.status, detail: forged.detail },
      { status: raw.status, detail: raw.detail },
    ]));
  });
});

describe("route-level secrecy and trusted-IP binding (UNEXECUTED)", () => {
  it("returns a fixed failure without request-log errors or secret console output", async () => {
    const f = fixture({ deleteStatus: () => 500 });
    seedAndroidKey(f);
    const composition = createAdminComposition(f.deps, f.ports);
    const { adminApp, publicApp } = buildMintApps(f.deps);
    const requestLogCalls: unknown[][] = [];
    adminApp.post("/test/admin/rotate", async (request, reply) => {
      request.log.error = ((...args: unknown[]) => {
        requestLogCalls.push(args);
      }) as typeof request.log.error;
      const forwarded = request.headers["x-forwarded-for"];
      const header = Array.isArray(forwarded) ? forwarded[0] : forwarded;
      const trustedRequestIp = typeof header === "string" && header !== ""
        ? header.split(",")[0]!.trim()
        : request.ip || "unknown";
      try {
        const result = await composition.forRequest({ trustedRequestIp }).rotateKey({
          authorization: request.headers.authorization ?? "",
          uid: "u1",
          platform: "android",
          reason: "incident-61",
          ip: "198.51.100.99",
        } as never);
        return reply.send(result);
      } catch (error) {
        throw toAdminHttpError(error);
      }
    });
    const consoleLog = vi.spyOn(console, "log").mockImplementation(() => {});
    const consoleWarn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const response = await adminApp.inject({
        method: "POST",
        url: "/test/admin/rotate",
        headers: { authorization: ADMIN, "x-forwarded-for": "203.0.113.10, 127.0.0.1" },
        payload: { ip: "198.51.100.99" },
      });
      expect(response.statusCode).toBe(502);
      expect(response.json()).toEqual({ detail: "admin action failed" });
      expect(f.audits[0]?.row.ip).toBe("203.0.113.10");
      expect(publicText(f.audits)).not.toContain("198.51.100.99");
      expect(requestLogCalls).toEqual([]);
      expectSafe(publicText(consoleLog.mock.calls));
      expect(consoleWarn).not.toHaveBeenCalled();
      expect(consoleError).not.toHaveBeenCalled();
      expectSafe(publicText({
        body: response.body,
        requestLogs: requestLogCalls,
        consoleLogs: consoleLog.mock.calls,
        warnings: consoleWarn.mock.calls,
        errors: consoleError.mock.calls,
      }));
    } finally {
      consoleLog.mockRestore();
      consoleWarn.mockRestore();
      consoleError.mockRestore();
      await adminApp.close();
      await publicApp.close();
    }
  });
});
