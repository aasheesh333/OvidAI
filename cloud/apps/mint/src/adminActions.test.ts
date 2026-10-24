import { describe, expect, it } from "vitest";
import { schema, type Db } from "@ovid/db";
import {
  AdminActionError,
  createAdminActions,
  createAdminKeyRotator,
  createPostgresAdminAudit,
  type AdminAuditEntry,
  type AdminPlatform,
  type ProvisionedKeySnapshot,
} from "./adminActions.js";
import type { LiteLlmAdmin } from "./litellmAdmin.js";

const ADMIN = "Bearer separate-admin";
const OLD_KEY = "sk-live-canary-old";
const NEW_KEY = "sk-live-canary-new";
const OLD_KEY_ID = "hashed-old-canary";
const NEW_KEY_ID = "hashed-new-canary";
const INTERNAL_BASE_URL = "http://127.0.0.1:45999/private/litellm";
const NOW = new Date("2026-10-24T12:34:56.000Z");

interface Fixture {
  admin: ReturnType<typeof createAdminActions>;
  audits: AdminAuditEntry[];
  logs: string[];
  store: Map<AdminPlatform, ProvisionedKeySnapshot>;
  deleted: string[][];
  blocked: Array<{ uid: string; blocked: boolean }>;
  resets: string[];
  plans: Array<{ uid: string; plan: string }>;
}

function fixture(overrides: { deleteStatus?: number; rotationGeneration?: number; trustedIp?: string } = {}): Fixture {
  const audits: AdminAuditEntry[] = [];
  const logs: string[] = [];
  const deleted: string[][] = [];
  const blocked: Array<{ uid: string; blocked: boolean }> = [];
  const resets: string[] = [];
  const plans: Array<{ uid: string; plan: string }> = [];
  const store = new Map<AdminPlatform, ProvisionedKeySnapshot>([
    ["web", { keyId: OLD_KEY_ID, plaintext: OLD_KEY, generation: 1 }],
  ]);
  const litellm = {
    async keyGenerate(_body: Record<string, unknown>) {
      return { key: NEW_KEY, token: NEW_KEY_ID };
    },
    async keyDelete(keys: string[]) {
      deleted.push([...keys]);
      return overrides.deleteStatus ?? 200;
    },
  } as unknown as LiteLlmAdmin;
  const rotateKey = createAdminKeyRotator({
    litellm,
    store: {
      async read(_uid, platform) {
        const value = store.get(platform);
        return value === undefined ? null : { ...value };
      },
      async write(_uid, platform, value) {
        store.set(platform, { ...value });
      },
    },
    async creationBody() {
      // Deliberately hostile fixture data: neither this privileged endpoint nor
      // either key canary may cross the action result/audit/log boundary.
      return { user_id: "u1", api_base: INTERNAL_BASE_URL };
    },
  });
  const admin = createAdminActions({
    async authorize({ authorization }) {
      if (authorization === "") throw new AdminActionError(401, "missing admin authorization");
      if (authorization !== ADMIN) throw new AdminActionError(403, "not an administrator");
      return overrides.trustedIp === undefined
        ? "ops-admin"
        : { actor: "ops-admin", ip: overrides.trustedIp };
    },
    async appendAudit(entry) {
      audits.push(structuredClone(entry));
    },
    async setBlocked({ uid, blocked: value }) {
      blocked.push({ uid, blocked: value });
    },
    rotateKey: overrides.rotationGeneration === undefined
      ? rotateKey
      : async () => ({ generation: overrides.rotationGeneration! }),
    async resetAnomalyAndRate({ uid }) {
      resets.push(uid);
    },
    async adjustPlan({ uid, plan }) {
      plans.push({ uid, plan });
    },
    now: () => NOW,
    log(entry) {
      logs.push(JSON.stringify(entry));
    },
  });
  return { admin, audits, logs, store, deleted, blocked, resets, plans };
}

function publicText(value: unknown): string {
  return JSON.stringify(value);
}

function expectNoPrivilegedMaterial(text: string): void {
  expect(text).not.toContain(OLD_KEY);
  expect(text).not.toContain(NEW_KEY);
  expect(text).not.toContain(OLD_KEY_ID);
  expect(text).not.toContain(NEW_KEY_ID);
  expect(text).not.toContain(INTERNAL_BASE_URL);
  expect(text).not.toContain("litellm");
}

describe("createAdminActions", () => {
  it("rotates without revealing replacement material and revokes the old key", async () => {
    const f = fixture();
    const result = await f.admin.rotateKey({
      authorization: ADMIN,
      uid: "u1",
      platform: "web",
      reason: "incident-42",
    });

    expect(result).toEqual({ ok: true, platform: "web", generation: 2 });
    expect(f.deleted).toEqual([[OLD_KEY_ID]]);
    expect(f.store.get("web")).toEqual({
      keyId: NEW_KEY_ID,
      plaintext: NEW_KEY,
      generation: 2,
    });
    expect(f.audits).toEqual([
      {
        action: "rotate-key",
        actor: "ops-admin",
        target: { uid: "u1", platform: "web" },
        reason: "incident-42",
        time: "2026-10-24T12:34:56.000Z",
        outcome: { status: "succeeded", generation: 2 },
      },
    ]);
    const auditText = publicText(f.audits);
    expectNoPrivilegedMaterial(publicText({ result, auditText, logText: f.logs.join("\n") }));
  });

  it("does not claim success when old-key revocation fails and restores the prior reference", async () => {
    const f = fixture({ deleteStatus: 500 });
    let error: unknown;
    try {
      await f.admin.rotateKey({ authorization: ADMIN, uid: "u1", platform: "web", reason: "incident-43" });
    } catch (caught) {
      error = caught;
    }

    expect(error).toBeInstanceOf(AdminActionError);
    expect((error as AdminActionError).status).toBe(502);
    expect(f.store.get("web")).toEqual({ keyId: OLD_KEY_ID, plaintext: OLD_KEY, generation: 1 });
    expect(f.deleted).toEqual([[OLD_KEY_ID], [NEW_KEY_ID]]);
    expect(f.audits[0]?.outcome).toEqual({ status: "failed" });
    expectNoPrivilegedMaterial(publicText({ error: String(error), audits: f.audits, logs: f.logs }));
  });

  it("requires separate admin authorization for every action with no side effects", async () => {
    const f = fixture();
    const calls = [
      () => f.admin.block({ authorization: "", uid: "u1", reason: "abuse" }),
      () => f.admin.unblock({ authorization: "Bearer user-u1", uid: "u1", reason: "appeal" }),
      () => f.admin.rotateKey({ authorization: "Bearer user-u1", uid: "u1", platform: "web", reason: "rotate" }),
      () => f.admin.resetAnomalyAndRate({ authorization: "Bearer user-u1", uid: "u1", reason: "reset" }),
      () => f.admin.adjustPlan({ authorization: "Bearer user-u1", uid: "u1", plan: "pro", reason: "grant" }),
    ];
    for (const call of calls) {
      await expect(call()).rejects.toMatchObject({ status: expect.any(Number) });
    }
    expect(f.blocked).toEqual([]);
    expect(f.resets).toEqual([]);
    expect(f.plans).toEqual([]);
    expect(f.deleted).toEqual([]);
    expect(f.audits).toEqual([]);
  });

  it("audits block and unblock as append-only actor/target/reason/time/outcome records", async () => {
    const f = fixture();
    await expect(f.admin.block({ authorization: ADMIN, uid: "u1", reason: "confirmed abuse" })).resolves.toEqual({ ok: true });
    const first = structuredClone(f.audits[0]);
    await expect(f.admin.unblock({ authorization: ADMIN, uid: "u1", reason: "appeal accepted" })).resolves.toEqual({ ok: true });

    expect(f.blocked).toEqual([{ uid: "u1", blocked: true }, { uid: "u1", blocked: false }]);
    expect(f.audits).toHaveLength(2);
    expect(f.audits[0]).toEqual(first);
    expect(f.audits.map((entry) => [entry.action, entry.actor, entry.target, entry.reason, entry.time, entry.outcome])).toEqual([
      ["block", "ops-admin", { uid: "u1" }, "confirmed abuse", "2026-10-24T12:34:56.000Z", { status: "succeeded" }],
      ["unblock", "ops-admin", { uid: "u1" }, "appeal accepted", "2026-10-24T12:34:56.000Z", { status: "succeeded" }],
    ]);
  });

  it("uses only the authorization resolver's trusted IP metadata", async () => {
    const f = fixture({ trustedIp: "203.0.113.10" });
    await f.admin.block({
      authorization: ADMIN,
      uid: "u1",
      reason: "confirmed abuse",
      ip: "198.51.100.99",
    } as unknown as Parameters<typeof f.admin.block>[0]);
    expect(f.audits[0]?.ip).toBe("203.0.113.10");
    expect(f.audits[0]?.ip).not.toBe("198.51.100.99");
  });

  it("uses the same normalized target for the side effect and audit", async () => {
    const f = fixture();
    await f.admin.block({ authorization: ADMIN, uid: " u1 ", reason: "confirmed abuse" });
    expect(f.blocked).toEqual([{ uid: "u1", blocked: true }]);
    expect(f.audits[0]?.target).toEqual({ uid: "u1" });
  });

  it("refuses an impossible rotation generation instead of returning false success", async () => {
    const f = fixture({ rotationGeneration: 0 });
    await expect(
      f.admin.rotateKey({ authorization: ADMIN, uid: "u1", platform: "web", reason: "incident-44" }),
    ).rejects.toMatchObject({ status: 502 });
    expect(f.audits[0]?.outcome).toEqual({ status: "failed" });
  });

  it("resets anomaly and rate state without rotating or revealing a key", async () => {
    const f = fixture();
    const result = await f.admin.resetAnomalyAndRate({ authorization: ADMIN, uid: "u1", reason: "false positive" });
    expect(result).toEqual({ ok: true });
    expect(f.resets).toEqual(["u1"]);
    expect(f.deleted).toEqual([]);
    expect(f.audits[0]).toMatchObject({ action: "reset-anomaly-rate", outcome: { status: "succeeded" } });
    expectNoPrivilegedMaterial(publicText({ result, audits: f.audits, logs: f.logs }));
  });

  it("adjusts a plan through the bounded port and audits only the plan id", async () => {
    const f = fixture();
    const result = await f.admin.adjustPlan({ authorization: ADMIN, uid: "u1", plan: "pro", reason: "support grant" });
    expect(result).toEqual({ ok: true, plan: "pro" });
    expect(f.plans).toEqual([{ uid: "u1", plan: "pro" }]);
    expect(f.audits[0]).toMatchObject({ action: "adjust-plan", outcome: { status: "succeeded", plan: "pro" } });
    expectNoPrivilegedMaterial(publicText({ result, audits: f.audits, logs: f.logs }));
  });

  it.each([
    [401, "missing admin authorization"],
    [403, "not an administrator"],
  ])("maps authorizer %i to a fixed public message without secret canaries", async (status, message) => {
    const f = fixture();
    f.admin = createAdminActions({
      authorize: async () => {
        throw new AdminActionError(status, `denied ${OLD_KEY} ${INTERNAL_BASE_URL}`);
      },
      appendAudit: async (entry) => { f.audits.push(entry); },
      setBlocked: async ({ uid, blocked }) => { f.blocked.push({ uid, blocked }); },
      rotateKey: async () => ({ generation: 2 }),
      resetAnomalyAndRate: async () => {},
      adjustPlan: async () => {},
      now: () => NOW,
    });
    let error: unknown;
    try {
      await f.admin.block({ authorization: ADMIN, uid: "u1", reason: "incident" });
    } catch (caught) {
      error = caught;
    }
    expect(error).toBeInstanceOf(AdminActionError);
    expect((error as AdminActionError).status).toBe(status);
    expect((error as AdminActionError).message).toBe(message);
    expectNoPrivilegedMaterial(publicText({ error: String(error), audits: f.audits, logs: f.logs }));
    expect(f.blocked).toEqual([]);
    expect(f.audits).toEqual([]);
  });

  it("sanitizes failed dependencies and refuses sensitive-looking reasons", async () => {
    const f = fixture();
    f.admin = createAdminActions({
      authorize: async () => "ops-admin",
      appendAudit: async (entry) => { f.audits.push(entry); },
      setBlocked: async () => { throw new Error(`upstream ${OLD_KEY} ${INTERNAL_BASE_URL}`); },
      rotateKey: async () => ({ generation: 2 }),
      resetAnomalyAndRate: async () => {},
      adjustPlan: async () => {},
      now: () => NOW,
    });
    await expect(f.admin.block({ authorization: ADMIN, uid: "u1", reason: "incident" })).rejects.toThrow("admin action failed");
    expectNoPrivilegedMaterial(publicText({ audits: f.audits }));

    await expect(f.admin.block({ authorization: ADMIN, uid: "u1", reason: `leak ${NEW_KEY}` })).rejects.toMatchObject({ status: 400 });
    expect(f.audits).toHaveLength(1);
  });
});

describe("createAdminKeyRotator generation preflight", () => {
  it.each([
    ["zero", 0],
    ["negative", -1],
    ["fractional", 1.5],
    ["NaN", Number.NaN],
    ["infinite", Number.POSITIVE_INFINITY],
    ["string", "1"],
    ["next-generation overflow", Number.MAX_SAFE_INTEGER],
  ])("rejects malformed previous generation %s before any mutation or revoke", async (_label, generation) => {
    const previous = { keyId: OLD_KEY_ID, plaintext: OLD_KEY, generation };
    let generated = 0;
    let creationBodies = 0;
    const writes: ProvisionedKeySnapshot[] = [];
    const deleted: string[][] = [];
    const rotate = createAdminKeyRotator({
      litellm: {
        async keyGenerate() {
          generated += 1;
          return { key: NEW_KEY, token: NEW_KEY_ID };
        },
        async keyDelete(keys: string[]) {
          deleted.push([...keys]);
          return 200;
        },
      } as unknown as LiteLlmAdmin,
      store: {
        async read() {
          return previous as unknown as ProvisionedKeySnapshot;
        },
        async write(_uid, _platform, value) {
          writes.push({ ...value });
        },
      },
      async creationBody() {
        creationBodies += 1;
        return { user_id: "u1", api_base: INTERNAL_BASE_URL };
      },
    });

    await expect(rotate({ uid: "u1", platform: "web" })).rejects.toMatchObject({
      status: 502,
      message: "key rotation failed",
    });
    expect({ generated, creationBodies, writes, deleted }).toEqual({
      generated: 0,
      creationBodies: 0,
      writes: [],
      deleted: [],
    });
    expect(previous.generation).toBe(generation);
  });
});

describe("createPostgresAdminAudit", () => {
  it("uses the existing append-only mint_audit columns without a migration or secrets", async () => {
    const writes: Array<{ table: unknown; row: Record<string, unknown> }> = [];
    const db = {
      insert(table: unknown) {
        return {
          async values(row: Record<string, unknown>) {
            writes.push({ table, row });
          },
        };
      },
    } as unknown as Db;
    const append = createPostgresAdminAudit(db, () => "13131313-1313-7313-8313-131313131313");
    await append({
      action: "rotate-key",
      actor: "ops-admin",
      target: { uid: "u1", platform: "web" },
      reason: "incident-42",
      time: NOW.toISOString(),
      outcome: { status: "succeeded", generation: 2 },
    });

    expect(writes).toHaveLength(1);
    expect(writes[0]?.table).toBe(schema.mintAudit);
    expect(writes[0]?.row).toEqual({
      id: "13131313-1313-7313-8313-131313131313",
      at: NOW,
      actor: "ops-admin",
      action: "rotate-key",
      target: { uid: "u1", platform: "web" },
      before: { reason: "incident-42" },
      after: { status: "succeeded", generation: 2 },
      ip: null,
    });
  });
});
