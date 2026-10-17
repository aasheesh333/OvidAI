import { beforeEach, describe, expect, it } from "vitest";
import {
  AccountError,
  GRACE_SECONDS,
  FENCE_SETTLE_SECONDS,
  IDENTITY_PROVIDERS,
  RECENT_AUTH_SECONDS,
  RETRY_SECONDS,
  MAX_RETRY_SECONDS,
  authTime,
  createLifecycle,
  identity,
  type AdminAdapter,
  type Claims,
  type CleanupContext,
  type CleanupStep,
  type DataAdapter,
  type DeletionRow,
  type DeletionSession,
  type DeletionStore,
  type Lifecycle,
} from "./domain.js";

// ---------------------------------------------------------------------------
// Port of server/account/tests/test_lifecycle.py (+ the fractional/parallel
// cases from parallel_account_cleanup_test.py). Fake Admin/Data adapters and a
// deep-cloning MemoryStore stand in for Firebase and the cloud cleanup.
// ---------------------------------------------------------------------------

type Mutable<T> = { -readonly [K in keyof T]: T[K] };

class MemoryStore implements DeletionStore {
  rows = new Map<string, DeletionRow>();
  private tail: Promise<unknown> = Promise.resolve();

  locked<T>(uid: string, fn: (s: DeletionSession) => Promise<T>): Promise<T> {
    // A single global mutex (stronger than per-uid) — the lifecycle's
    // correctness must not depend on the store's concurrency primitive.
    const run = this.tail.then(async () => {
      const session: DeletionSession = {
        get: async (id) => {
          const row = this.rows.get(id);
          return row === undefined ? null : structuredClone(row);
        },
        save: async (row) => {
          this.rows.set(row.uid, structuredClone(row));
        },
      };
      return fn(session);
    });
    this.tail = run.catch(() => undefined);
    return run;
  }

  async due(now: number): Promise<string[]> {
    const rows = [...this.rows.values()]
      .filter(
        (r) =>
          (r.next_attempt ?? 0) <= now &&
          ((["pending", "fenced", "deleting"].includes(r.state) && r.delete_after <= now) ||
            (r.state === "cancelled" && r.fence_owned)),
      )
      .sort(
        (a, b) =>
          (a.next_attempt ?? 0) - (b.next_attempt ?? 0) ||
          (a.attempts ?? 0) - (b.attempts ?? 0) ||
          a.delete_after - b.delete_after ||
          a.uid.localeCompare(b.uid),
      );
    return rows.slice(0, 100).map((r) => r.uid);
  }
}

class Admin implements AdminAdapter {
  users: Record<string, { disabled: boolean; last_login_ms: number }> = {
    alice: { disabled: false, last_login_ms: 900_000 },
  };
  onDisable: (() => void) | null = null;
  disableCalls: string[] = [];
  enableCalls: string[] = [];
  deleteCalls: string[] = [];

  async user(uid: string) {
    const u = this.users[uid];
    return u === undefined ? null : structuredClone(u);
  }
  async disable(uid: string) {
    this.disableCalls.push(uid);
    this.users[uid]!.disabled = true;
    this.onDisable?.();
  }
  async enable(uid: string) {
    this.enableCalls.push(uid);
    this.users[uid]!.disabled = false;
  }
  async delete(uid: string) {
    this.deleteCalls.push(uid);
    delete this.users[uid];
  }
}

class Data implements DataAdapter {
  keys: Record<string, string[]> = { alice: ["key-a"], bob: ["key-b"] };
  profiles: Record<string, { tier: string }> = { alice: { tier: "free" }, bob: { tier: "7x" } };
  fail = false;
  slowMs = 0;
  /** Number of named data steps (the Python fake had one aggregate call). */
  stepCount = 1;
  failStep: string | null = null;
  revokeCalls = 0;
  stepNames: string[] = [];
  events: string[] = [];

  async prepare(_uid: string): Promise<CleanupContext> {
    return {};
  }
  async revokeKeys(uid: string, _ctx: CleanupContext): Promise<void> {
    this.revokeCalls += 1;
    this.events.push("keys");
    delete this.keys[uid];
  }
  deletionSteps(): CleanupStep[] {
    const names = ["one", "two", "three"].slice(0, this.stepCount);
    return names.map((name) => ({
      name,
      run: async (uid: string) => {
        if (this.slowMs > 0) {
          // The lifecycle's clock is advanced by the test through nowMs.
          nowMs += this.slowMs;
        }
        this.events.push(`data:${name}`);
        this.stepNames.push(name);
        if (this.fail || this.failStep === name) throw new Error("storage unavailable");
        if (name === names[names.length - 1]) delete this.profiles[uid];
      },
    }));
  }
}

let nowMs = 1000;

beforeEach(() => {
  nowMs = 1000;
});

function service(
  store: DeletionStore,
  admin: AdminAdapter,
  data: DataAdapter,
  clock: () => number = () => nowMs,
): Lifecycle {
  return createLifecycle({ store, admin, data, clock });
}

function claims(over: Partial<Claims> = {}): Claims {
  return {
    uid: "alice",
    auth_time: 1000,
    firebase: { sign_in_provider: "google.com" },
    ...over,
  };
}

async function expectAccountError(p: Promise<unknown>, code: string, status?: number) {
  await expect(p).rejects.toBeInstanceOf(AccountError);
  try {
    await p;
  } catch (err) {
    const e = err as AccountError;
    expect(e.code).toBe(code);
    if (status !== undefined) expect(e.status).toBe(status);
  }
}

describe("domain constants (verbatim)", () => {
  it("matches server/account/domain.py", () => {
    expect(GRACE_SECONDS).toBe(86_400);
    expect(RECENT_AUTH_SECONDS).toBe(300);
    expect(FENCE_SETTLE_SECONDS).toBe(60);
    expect(RETRY_SECONDS).toBe(60);
    expect(MAX_RETRY_SECONDS).toBe(3600);
    expect([...IDENTITY_PROVIDERS].sort()).toEqual(
      [
        "google.com",
        "github.com",
        "apple.com",
        "microsoft.com",
        "facebook.com",
        "twitter.com",
        "yahoo.com",
        "phone",
      ].sort(),
    );
  });
});

describe("identity / authTime", () => {
  it("accepts uid or sub and the provider allowlist", () => {
    expect(identity(claims())).toBe("alice");
    expect(identity({ sub: "bob", firebase: { sign_in_provider: "phone" } })).toBe("bob");
    for (const provider of IDENTITY_PROVIDERS) {
      expect(identity(claims({ firebase: { sign_in_provider: provider } }))).toBe("alice");
    }
  });

  it("rejects malformed uids and unsupported providers", () => {
    for (const uid of ["", "has space", "a".repeat(129), "semi;colon", 7, null]) {
      expect(() => identity(claims({ uid }))).toThrowError(
        expect.objectContaining({ code: "invalid_identity", status: 401 }),
      );
    }
    for (const firebase of [
      { sign_in_provider: "anonymous" },
      { sign_in_provider: "custom" },
      { sign_in_provider: "oidc.example" },
      { sign_in_provider: ["google.com"] },
      null,
    ]) {
      expect(() => identity(claims({ firebase }))).toThrowError(
        expect.objectContaining({ code: "unsupported_identity", status: 403 }),
      );
    }
    // Password only via the legacy flag.
    expect(() => identity(claims({ firebase: { sign_in_provider: "password" } }))).toThrowError(
      expect.objectContaining({ code: "unsupported_identity" }),
    );
    expect(
      identity(claims({ firebase: { sign_in_provider: "password" } }), {
        allowLegacyPassword: true,
      }),
    ).toBe("alice");
  });

  it("requires a finite numeric auth_time (booleans rejected)", () => {
    expect(authTime(claims({ auth_time: 12.5 }))).toBe(12.5);
    for (const value of [undefined, null, true, false, "12", Infinity, -Infinity, NaN]) {
      expect(() => authTime(claims({ auth_time: value }))).toThrowError(
        expect.objectContaining({ code: "reauthentication_required", status: 401 }),
      );
    }
  });
});

describe("Lifecycle request/status/login/cancel", () => {
  it("is durable and a duplicate request id does not extend the grace", async () => {
    const store = new MemoryStore();
    const svc = service(store, new Admin(), new Data());
    const first = await svc.request(claims(), "request-0001");
    expect(first).toEqual({ state: "pending", delete_after: 87_400, request_id: "request-0001" });
    nowMs += 100;
    const second = await svc.request(claims(), "request-0001");
    expect(second).toEqual(first);
    expect(store.rows.get("alice")!.state).toBe("pending");
  });

  it("requires recent auth and a non-anonymous identity, with no row written", async () => {
    const store = new MemoryStore();
    const svc = service(store, new Admin(), new Data());
    const bad: Array<Partial<Claims>> = [
      { auth_time: 600 },
      { auth_time: 2000 },
      { firebase: { sign_in_provider: "anonymous" } },
      { firebase: { sign_in_provider: "custom" } },
      { firebase: { sign_in_provider: "oidc.example" } },
      { firebase: { sign_in_provider: ["google.com"] } },
      { firebase: null },
      { uid: "" },
    ];
    for (const update of bad) {
      await expect(svc.request(claims(update), "request-0001")).rejects.toBeInstanceOf(AccountError);
    }
    expect(store.rows.size).toBe(0);
  });

  it("login is observational and a duplicate request cannot resurrect a cancelled deletion", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const data = new Data();
    const svc = service(store, admin, data);
    await svc.request(claims(), "request-0001");
    nowMs = 2000;
    const fresh = claims({ auth_time: 2000 });
    expect(await svc.login(fresh)).toEqual({ state: "pending", delete_after: 87_400, request_id: "request-0001" });
    expect(store.rows.get("alice")!.state).toBe("pending");
    expect(await svc.request(fresh, "request-0001")).toMatchObject({ state: "pending" });
    expect(await svc.cancel(fresh)).toMatchObject({ state: "cancelled" });
    nowMs = 87_400;
    await svc.finalize("alice");
    nowMs += 61;
    expect(await svc.finalize("alice")).toMatchObject({ state: "cancelled" });
    expect(admin.users.alice).toBeDefined();
    expect(data.keys.alice).toEqual(["key-a"]);
    expect(admin.enableCalls).toEqual([]);
  });

  it("cancel after the grace deadline is rejected as deletion_in_progress", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const svc = service(store, admin, new Data());
    await svc.request(claims(), "request-0001");
    nowMs = 87_401;
    await expectAccountError(
      svc.cancel(claims({ auth_time: 87_401 })),
      "deletion_in_progress",
      409,
    );
    expect(store.rows.get("alice")!.state).toBe("pending");
    expect(admin.users.alice).toBeDefined();
  });

  it("an old session does not cancel a pending deletion", async () => {
    const store = new MemoryStore();
    const svc = service(store, new Admin(), new Data());
    await svc.request(claims(), "request-0001");
    nowMs = 2000;
    expect(await svc.login(claims({ auth_time: 900 }))).toMatchObject({ state: "pending" });
    expect(store.rows.get("alice")!.state).toBe("pending");
  });

  it("the requesting session in the same second does not cancel", async () => {
    const store = new MemoryStore();
    const svc = service(store, new Admin(), new Data());
    await svc.request(claims(), "request-0001");
    expect(await svc.login(claims())).toMatchObject({ state: "pending" });
    expect(store.rows.get("alice")!.state).toBe("pending");
  });

  it("cancel wins at the exact deadline before the worker claims", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const svc = service(store, admin, new Data());
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    const atDeadline = claims({ auth_time: 87_400 });
    expect(await svc.cancel(atDeadline)).toMatchObject({ state: "cancelled" });
    await svc.finalize("alice");
    expect(admin.users.alice).toBeDefined();
  });

  it("cancel uses ONE server timestamp at the accepted deadline", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    await store.locked("alice", async () => undefined);
    const svc = service(store, admin, new Data());
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    let calls = 0;
    const ticks = [87_400, 87_401];
    const timed = createLifecycle({
      store,
      admin,
      data: new Data(),
      clock: () => ticks[calls++] ?? 87_401,
    });
    expect(await timed.cancel(claims({ auth_time: 87_400 }))).toMatchObject({ state: "cancelled" });
    expect(admin.users.alice).toBeDefined();
  });

  it("a Firebase login during the fence does not cancel", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    admin.onDisable = () => {
      admin.users.alice!.last_login_ms = 87_399_999;
    };
    const svc = service(store, admin, new Data());
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    await svc.finalize("alice");
    nowMs += 61;
    expect(await svc.finalize("alice")).toMatchObject({ state: "deleted" });
    expect(admin.users.alice).toBeUndefined();
  });

  it("a late explicit cancel can restore a fenced request", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const data = new Data();
    const svc = service(store, admin, data);
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    await svc.finalize("alice");
    nowMs += 10;
    expect(await svc.cancel(claims({ auth_time: 87_410 }))).toMatchObject({ state: "cancelled" });
    expect(admin.users.alice!.disabled).toBe(false);
    expect(data.profiles.alice).toBeDefined();
  });

  it("an expired login cannot cancel", async () => {
    const store = new MemoryStore();
    const svc = service(store, new Admin(), new Data());
    await svc.request(claims(), "request-0001");
    nowMs = 87_401;
    expect(await svc.login(claims({ auth_time: 87_401 }))).toMatchObject({ state: "pending" });
  });

  it("cleanup retries after a restart and deletes only the bound uid", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const data = new Data();
    const svc = service(store, admin, data);
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    await svc.finalize("alice");
    nowMs += 61;
    data.fail = true;
    await expect(svc.finalize("alice")).rejects.toThrow("storage unavailable");
    expect(store.rows.get("alice")!.state).toBe("deleting");
    expect(admin.users.alice).toBeDefined();
    expect(data.keys.alice).toBeUndefined();
    data.fail = false;
    const restarted = service(store, admin, data);
    expect(await restarted.finalize("alice")).toMatchObject({ state: "deleted" });
    expect(admin.users.alice).toBeUndefined();
    expect(data.profiles.alice).toBeUndefined();
    expect(data.keys.bob).toEqual(["key-b"]);
    expect(await restarted.finalize("alice")).toMatchObject({ state: "deleted" });
    // Tombstone semantics: the row survives completion, without cleanup data.
    expect(store.rows.get("alice")!.state).toBe("deleted");
    expect(store.rows.get("alice")!.cleanup_context).toBeUndefined();
    // Keys are blocked before any data stage runs.
    expect(data.events[0]).toBe("keys");
  });

  it("resumes at the failed checkpoint without re-running completed stages", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const data = new Data();
    data.stepCount = 2;
    const svc = service(store, admin, data);
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    await svc.finalize("alice"); // pending → fenced
    nowMs = 87_460;
    data.failStep = "two";
    await expect(svc.finalize("alice", { scheduled: true })).rejects.toThrow("storage unavailable");
    const afterFailure = store.rows.get("alice")!;
    expect(afterFailure.state).toBe("deleting");
    expect(afterFailure.completed).toEqual(["keys", "data:one"]);
    expect(afterFailure.cleanup_context).toBeDefined();
    expect(data.revokeCalls).toBe(1);
    expect(data.stepNames).toEqual(["one", "two"]);

    // Restart: step one is checkpointed and MUST NOT run again.
    data.failStep = null;
    nowMs = afterFailure.next_attempt;
    const restarted = service(store, admin, data);
    expect(await restarted.finalize("alice", { scheduled: true })).toMatchObject({
      state: "deleted",
    });
    expect(data.revokeCalls).toBe(1);
    expect(data.stepNames).toEqual(["one", "two", "two"]);
    expect(store.rows.get("alice")!.cleanup_context).toBeUndefined();
  });

  it("the worker waits for grace and fence settlement", async () => {
    const store = new MemoryStore();
    const data = new Data();
    const svc = service(store, new Admin(), data);
    await svc.request(claims(), "request-0001");
    nowMs = 87_399;
    expect(await svc.finalize("alice")).toMatchObject({ state: "pending" });
    nowMs += 1;
    expect(await svc.finalize("alice")).toMatchObject({ state: "fenced" });
    expect(data.profiles.alice).toBeDefined();
  });

  it("a crash before disable does not skip fence settlement on retry", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const data = new Data();
    const svc = service(store, admin, data);
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    const disable = admin.disable.bind(admin);
    admin.disable = async () => {
      throw new Error("offline");
    };
    await expect(svc.finalize("alice")).rejects.toThrow("offline");
    nowMs += 120;
    admin.disable = disable;
    expect(await svc.finalize("alice")).toMatchObject({ state: "fenced" });
    expect(data.keys.alice).toEqual(["key-a"]);
  });

  it("request ids stay idempotent after a newer request", async () => {
    const store = new MemoryStore();
    const svc = service(store, new Admin(), new Data());
    await svc.request(claims(), "request-0001");
    nowMs = 2000;
    const fresh = claims({ auth_time: 2000 });
    await svc.cancel(fresh);
    const second = await svc.request(fresh, "request-0002");
    await expectAccountError(svc.request(fresh, "request-0001"), "request_already_completed");
    expect(store.rows.get("alice")!.request_id).toBe(second.request_id);
  });

  it("a coalesced request B cannot resurrect cancelled A after restart", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const data = new Data();
    let svc = service(store, admin, data);
    const first = await svc.request(claims(), "request-aaaa");
    expect(await svc.request(claims(), "request-bbbb")).toEqual(first);
    nowMs = 1001;
    const fresh = claims({ auth_time: 1001 });
    await svc.cancel(fresh);
    svc = service(store, admin, data);
    expect(await svc.request(fresh, "request-bbbb")).toMatchObject({ state: "cancelled" });
    await svc.request(fresh, "request-cccc");
    await expectAccountError(svc.request(fresh, "request-bbbb"), "request_already_completed");
    expect(store.rows.get("alice")!.request_id).toBe("request-cccc");
  });

  it("rechecks recent auth after the lock wait", async () => {
    const store = new MemoryStore();
    const original = store.locked.bind(store);
    store.locked = async (uid, fn) => {
      nowMs = 1301;
      return original(uid, fn);
    };
    const svc = service(store, new Admin(), new Data());
    await expectAccountError(svc.request(claims(), "request-0001"), "reauthentication_required", 401);
    expect(store.rows.size).toBe(0);
  });

  it("rechecks recent auth after the admin lookup", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const user = admin.user.bind(admin);
    admin.user = async (uid) => {
      nowMs = 1301;
      return user(uid);
    };
    const svc = service(store, admin, new Data());
    await expectAccountError(svc.request(claims(), "request-0001"), "reauthentication_required", 401);
    expect(store.rows.size).toBe(0);
  });

  it("uses acceptance time for the deadline after lock and admin waits", async () => {
    const store = new MemoryStore();
    const originalLock = store.locked.bind(store);
    store.locked = async (uid, fn) => {
      nowMs += 20;
      return originalLock(uid, fn);
    };
    const admin = new Admin();
    const user = admin.user.bind(admin);
    admin.user = async (uid) => {
      nowMs += 30;
      return user(uid);
    };
    const svc = service(store, admin, new Data());
    const state = await svc.request(claims(), "request-0001");
    expect(state.delete_after).toBe(87_450);
    expect(store.rows.get("alice")!.requested_at).toBe(1050);
  });

  it("supports every social and phone provider", async () => {
    const store = new MemoryStore();
    const svc = service(store, new Admin(), new Data());
    for (const provider of IDENTITY_PROVIDERS) {
      store.rows.clear();
      expect(
        await svc.request(claims({ firebase: { sign_in_provider: provider } }), "request-social"),
      ).toMatchObject({ state: "pending" });
    }
  });

  it("password cannot start a request or gain normal access", async () => {
    const store = new MemoryStore();
    const svc = service(store, new Admin(), new Data());
    const password = claims({ firebase: { sign_in_provider: "password" } });
    await expectAccountError(svc.request(password, "request-password"), "unsupported_identity", 403);
    await expectAccountError(svc.login(password), "unsupported_identity", 403);
    await expectAccountError(svc.status(password), "unsupported_identity", 403);
    await expect(
      svc.access(password, async () => "never"),
    ).rejects.toMatchObject({ code: "unsupported_identity" });
  });

  it("legacy password keeps existing deletion and fence recovery", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const svc = service(store, admin, new Data());
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    await svc.finalize("alice");
    const legacy = claims({
      auth_time: 87_399,
      _account_disabled: true,
      firebase: { sign_in_provider: "password" },
    });
    const enable = admin.enable.bind(admin);
    admin.enable = async () => {
      throw new Error("offline");
    };
    await expect(svc.cancel(legacy)).rejects.toThrow("offline");
    admin.enable = enable;
    expect(await svc.cancel(legacy)).toMatchObject({ state: "cancelled" });
    expect(admin.users.alice!.disabled).toBe(false);
    expect(await svc.status(legacy)).toMatchObject({ state: "cancelled" });
    expect(await svc.request(legacy, "request-0001")).toMatchObject({ state: "cancelled" });
    await expectAccountError(svc.request(legacy, "request-newpassword"), "unsupported_identity");
  });

  it("fence settlement uses the clock after the admin wait", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const svc = service(store, admin, new Data());
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    await svc.finalize("alice");
    nowMs = 87_459;
    const user = admin.user.bind(admin);
    admin.user = async (uid) => {
      nowMs += 2;
      return user(uid);
    };
    expect(await svc.finalize("alice")).toMatchObject({ state: "deleted" });
  });

  it("scheduled retries recheck the due time under the lock", async () => {
    const store = new MemoryStore();
    const svc = service(store, new Admin(), new Data());
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    expect(await svc.finalize("alice", { scheduled: true })).toMatchObject({ state: "fenced" });
    expect(store.rows.get("alice")!.attempts).toBe(1);
    nowMs = 87_459;
    expect(await svc.finalize("alice", { scheduled: true })).toMatchObject({ state: "fenced" });
    expect(store.rows.get("alice")!.attempts).toBe(1);
    nowMs = 87_460;
    expect(await svc.finalize("alice", { scheduled: true })).toMatchObject({ state: "deleted" });
  });

  it("backs off from the end of a slow failure, capped at one hour", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const data = new Data();
    const svc = service(store, admin, data);
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    await svc.finalize("alice");
    nowMs = 87_461;
    data.slowMs = 500;
    data.fail = true;
    for (const delay of [120, 240, 480, 960, 1920, 3600, 3600]) {
      await expect(svc.finalize("alice", { scheduled: true })).rejects.toThrow("storage unavailable");
      const row = store.rows.get("alice")!;
      expect(row.next_attempt).toBe(nowMs + delay);
      expect(row.completed).toEqual(["keys"]);
      nowMs = row.next_attempt;
    }
  });

  it("saves retry intent before the external effect", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const svc = service(store, admin, new Data());
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    admin.disable = async () => {
      throw new Error("simulated process crash");
    };
    await expect(svc.finalize("alice", { scheduled: true })).rejects.toThrow("simulated process crash");
    const row = store.rows.get("alice")!;
    expect(row.attempts).toBe(1);
    expect(row.next_attempt).toBe(87_460);
    expect(row.state).toBe("fenced");
    expect(row.fence_at).toBeNull();
  });

  it("a disabled account without a worker-owned fence cannot log in", async () => {
    const svc = service(new MemoryStore(), new Admin(), new Data());
    await expectAccountError(
      svc.login(claims({ _account_disabled: true })),
      "account_unavailable",
      403,
    );
  });

  it("cancel intent survives an enable failure and is retried by the worker", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const data = new Data();
    const svc = service(store, admin, data);
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    await svc.finalize("alice");
    const enable = admin.enable.bind(admin);
    admin.enable = async () => {
      throw new Error("offline");
    };
    await expect(svc.cancel(claims({ auth_time: 87_399 }))).rejects.toThrow("offline");
    expect(store.rows.get("alice")!.state).toBe("cancelled");
    admin.enable = enable;
    nowMs += 120;
    await svc.finalize("alice");
    expect(admin.users.alice!.disabled).toBe(false);
    expect(data.keys.alice).toEqual(["key-a"]);
  });

  it("two workers finalize the same uid without duplicate effects", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const svc = service(store, admin, new Data());
    await svc.request(claims(), "request-0001");
    nowMs = 87_400;
    await svc.finalize("alice");
    nowMs += 61;
    await Promise.all([svc.finalize("alice"), svc.finalize("alice")]);
    expect(admin.deleteCalls).toEqual(["alice"]);
  });

  it("access blocks stale sessions and deleted uids, and holds the lock across fn", async () => {
    const store = new MemoryStore();
    const svc = service(store, new Admin(), new Data());
    await svc.request(claims(), "request-0001");
    await expect(
      svc.access(claims(), async () => "never"),
    ).rejects.toMatchObject({ code: "account_deletion_pending", status: 403 });
    nowMs = 87_400;
    await svc.finalize("alice");
    nowMs += 61;
    await svc.finalize("alice");
    await expect(
      svc.access(claims(), async () => "never"),
    ).rejects.toMatchObject({ code: "account_deletion_pending", status: 403 });
  });

  it("keeps fractional deadlines exact across restart", async () => {
    const store = new MemoryStore();
    const admin = new Admin();
    const data = new Data();
    nowMs = 1000.25;
    let svc = service(store, admin, data);
    const receipt = await svc.request(
      claims({ auth_time: 1000, firebase: { sign_in_provider: "phone" } }),
      "request-original",
    );
    expect(receipt.delete_after).toBe(87_400.25);
    nowMs = 1300;
    expect(await svc.request(claims({ auth_time: 1000 }), "request-alias")).toEqual(receipt);
    nowMs = 1300.001;
    await expectAccountError(
      svc.request(claims({ auth_time: 1000 }), "request-expired"),
      "reauthentication_required",
    );
    expect(store.rows.get("alice")!.request_aliases).toEqual(["request-alias"]);
    svc = service(store, admin, data);
    nowMs = 87_400.249;
    expect(await svc.finalize("alice", { scheduled: true })).toEqual(receipt);
    expect(admin.users.alice!.disabled).toBe(false);
    nowMs = 87_400.25;
    expect(await svc.finalize("alice", { scheduled: true })).toMatchObject({ state: "fenced" });
    nowMs = 87_460.249;
    expect(await svc.finalize("alice", { scheduled: true })).toMatchObject({ state: "fenced" });
    nowMs = 87_460.25;
    expect(await svc.finalize("alice", { scheduled: true })).toMatchObject({ state: "deleted" });
  });
});
