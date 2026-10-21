import { describe, expect, it, vi } from "vitest";

import { StorageError } from "./errors.js";
import {
  BYTES_PER_GB,
  PLAN_STORAGE_BYTES,
  PLAN_STORAGE_GB,
  STORAGE_QUOTA_EXCEEDED_CODE,
  StorageQuotaExceededError,
  assertStorageQuota,
  checkStorageQuota,
  createMemoryStorageQuotaLedger,
  readStorageUsage,
  reserveStorageForUpload,
  resolveStoragePlan,
  storageAttribution,
  storageLimitBytes,
  withStorageQuota,
  type StorageQuotaLedger,
} from "./quota.js";

const MB = 1024 * 1024;
const GB = BYTES_PER_GB;

function ledgerWith(uid: string, bytes: number): StorageQuotaLedger {
  return createMemoryStorageQuotaLedger([[uid, bytes]]);
}

function personal(bytes: number, plan = "free", uploaderUid = "owner") {
  return { uploaderUid, plan, bytes };
}

async function expectQuotaError(promise: Promise<unknown>): Promise<StorageQuotaExceededError> {
  try {
    await promise;
  } catch (err) {
    expect(err).toBeInstanceOf(StorageQuotaExceededError);
    const quota = err as StorageQuotaExceededError;
    expect(quota.code).toBe(STORAGE_QUOTA_EXCEEDED_CODE);
    return quota;
  }
  throw new Error("expected StorageQuotaExceededError, but the promise resolved");
}

describe("plan storage table", () => {
  it("pins 3 / 5 / 15 / 75 GB in bytes", () => {
    expect(PLAN_STORAGE_GB).toEqual({ free: 3, go: 5, plus: 15, pro: 75 });
    expect(PLAN_STORAGE_BYTES).toEqual({
      free: 3 * GB,
      go: 5 * GB,
      plus: 15 * GB,
      pro: 75 * GB,
    });
    expect(storageLimitBytes("free")).toBe(3 * GB);
    expect(storageLimitBytes("go")).toBe(5 * GB);
    expect(storageLimitBytes("plus")).toBe(15 * GB);
    expect(storageLimitBytes("pro")).toBe(75 * GB);
  });

  it("resolves canonical ids, display names and the mint's legacy tier ids", () => {
    for (const id of ["free", "FREE", " free plan "]) {
      expect(resolveStoragePlan(id)).toBe("free");
    }
    for (const id of ["go", "Ovid Go", "3x", "starter"]) {
      expect(resolveStoragePlan(id)).toBe("go");
    }
    for (const id of ["plus", "Ovid Plus", "7x"]) {
      expect(resolveStoragePlan(id)).toBe("plus");
    }
    for (const id of ["pro", "Ovid Pro", "15x", "max"]) {
      expect(resolveStoragePlan(id)).toBe("pro");
    }
  });

  it("fails closed to Free for unknown or missing plans", () => {
    expect(resolveStoragePlan(undefined)).toBe("free");
    expect(resolveStoragePlan(null)).toBe("free");
    expect(resolveStoragePlan("")).toBe("free");
    expect(resolveStoragePlan("enterprise-unlimited")).toBe("free");
  });
});

describe("quota cap (under / at / over)", () => {
  it("allows an upload that stays under the plan limit", async () => {
    const ledger = ledgerWith("owner", 1 * GB);
    const snapshot = await checkStorageQuota(ledger, personal(1 * GB));

    expect(snapshot.plan).toBe("free");
    expect(snapshot.limitBytes).toBe(3 * GB);
    expect(snapshot.usedBytes).toBe(1 * GB);
    expect(snapshot.availableBytes).toBe(2 * GB);
    // Read-only pre-flight never reserves.
    await expect(ledger.usedBytes("owner")).resolves.toBe(1 * GB);
  });

  it("allows the upload that lands exactly on the limit (inclusive cap)", async () => {
    const ledger = ledgerWith("owner", 2 * GB);
    const snapshot = await checkStorageQuota(ledger, personal(1 * GB));

    expect(snapshot.usedBytes + 1 * GB).toBe(snapshot.limitBytes);
    expect(snapshot.availableBytes).toBe(1 * GB);
  });

  it("allows a first upload exactly equal to the whole allowance", async () => {
    const ledger = ledgerWith("owner", 0);
    const reservation = await reserveStorageForUpload(ledger, personal(3 * GB));

    expect(reservation.usedBytes).toBe(3 * GB);
    expect(reservation.availableBytes).toBe(0);
    await expect(ledger.usedBytes("owner")).resolves.toBe(3 * GB);
  });

  it("refuses one byte over the limit without reserving anything", async () => {
    const ledger = ledgerWith("owner", 2 * GB);
    const error = await expectQuotaError(
      reserveStorageForUpload(ledger, personal(1 * GB + 1)),
    );

    expect(error.ownerUid).toBe("owner");
    expect(error.uploaderUid).toBe("owner");
    expect(error.plan).toBe("free");
    expect(error.limitBytes).toBe(3 * GB);
    expect(error.usedBytes).toBe(2 * GB);
    expect(error.requestedBytes).toBe(1 * GB + 1);
    expect(error.availableBytes).toBe(1 * GB);
    await expect(ledger.usedBytes("owner")).resolves.toBe(2 * GB);
  });

  it("refuses any positive upload when a downgrade left usage above the cap", async () => {
    const ledger = ledgerWith("owner", 4 * GB); // e.g. Pro → Free downgrade
    const error = await expectQuotaError(reserveStorageForUpload(ledger, personal(1)));

    expect(error.usedBytes).toBe(4 * GB);
    expect(error.availableBytes).toBe(0);
    await expect(ledger.usedBytes("owner")).resolves.toBe(4 * GB);
  });

  it("always allows a zero-byte upload, even at or above the cap", async () => {
    const ledger = ledgerWith("owner", 3 * GB);
    const atCap = await reserveStorageForUpload(ledger, personal(0));
    expect(atCap.bytes).toBe(0);
    expect(atCap.usedBytes).toBe(3 * GB);
    await expect(ledger.usedBytes("owner")).resolves.toBe(3 * GB);

    const over = ledgerWith("owner", 4 * GB);
    await expect(reserveStorageForUpload(over, personal(0))).resolves.toMatchObject({
      bytes: 0,
      usedBytes: 4 * GB,
      availableBytes: 0,
    });
  });

  it("honours paid-plan limits per plan", async () => {
    const go = ledgerWith("owner", 4 * GB);
    await expect(checkStorageQuota(go, personal(1 * GB, "go"))).resolves.toMatchObject({
      plan: "go",
      limitBytes: 5 * GB,
    });
    await expect(
      reserveStorageForUpload(go, personal(1 * GB + 1, "go")),
    ).rejects.toBeInstanceOf(StorageQuotaExceededError);

    const plus = ledgerWith("owner", 15 * GB);
    await expect(
      reserveStorageForUpload(plus, personal(1, "plus")),
    ).rejects.toBeInstanceOf(StorageQuotaExceededError);

    const pro = ledgerWith("owner", 74 * GB);
    await expect(
      reserveStorageForUpload(pro, personal(1 * GB, "pro")),
    ).resolves.toMatchObject({ plan: "pro", usedBytes: 75 * GB, availableBytes: 0 });
  });

  it("refuses an unknown plan as Free rather than granting paid storage", async () => {
    const ledger = ledgerWith("owner", 3 * GB);
    await expect(
      reserveStorageForUpload(ledger, personal(1, "mystery-tier")),
    ).rejects.toBeInstanceOf(StorageQuotaExceededError);
  });

  it("assertStorageQuota is the same pure decision", () => {
    const snapshot = {
      ownerUid: "owner",
      uploaderUid: "owner",
      isCreator: true,
      plan: "free" as const,
      limitBytes: 3 * GB,
      usedBytes: 2 * GB,
      availableBytes: 1 * GB,
    };
    expect(() => assertStorageQuota(snapshot, 1 * GB)).not.toThrow();
    expect(() => assertStorageQuota(snapshot, 1 * GB + 1)).toThrowError(
      StorageQuotaExceededError,
    );
    expect(() => assertStorageQuota(snapshot, 0)).not.toThrow();
  });
});

describe("Collab attribution — the creator pays", () => {
  it("charges a personal upload to the uploader", async () => {
    const ledger = createMemoryStorageQuotaLedger();
    const reservation = await reserveStorageForUpload(ledger, {
      uploaderUid: "alice",
      plan: "plus",
      bytes: 100 * MB,
    });

    expect(reservation.ownerUid).toBe("alice");
    expect(reservation.uploaderUid).toBe("alice");
    expect(reservation.isCreator).toBe(true);
    await expect(ledger.usedBytes("alice")).resolves.toBe(100 * MB);
  });

  it("charges a member's upload to the session creator, not the member", async () => {
    const ledger = createMemoryStorageQuotaLedger();
    const reservation = await reserveStorageForUpload(ledger, {
      uploaderUid: "guest",
      sessionOwnerUid: "creator",
      plan: "free",
      bytes: 100 * MB,
    });

    expect(reservation.ownerUid).toBe("creator");
    expect(reservation.uploaderUid).toBe("guest");
    expect(reservation.isCreator).toBe(false);
    await expect(ledger.usedBytes("creator")).resolves.toBe(100 * MB);
    await expect(ledger.usedBytes("guest")).resolves.toBe(0);
  });

  it("keeps one usage total across creator and member uploads", async () => {
    const ledger = createMemoryStorageQuotaLedger();
    await reserveStorageForUpload(ledger, {
      uploaderUid: "creator",
      plan: "free",
      bytes: 50 * MB,
    });
    await reserveStorageForUpload(ledger, {
      uploaderUid: "guest-a",
      sessionOwnerUid: "creator",
      plan: "free",
      bytes: 25 * MB,
    });
    const last = await reserveStorageForUpload(ledger, {
      uploaderUid: "guest-b",
      sessionOwnerUid: "creator",
      plan: "free",
      bytes: 25 * MB,
    });

    expect(last.usedBytes).toBe(100 * MB);
    await expect(ledger.usedBytes("creator")).resolves.toBe(100 * MB);
    await expect(ledger.usedBytes("guest-a")).resolves.toBe(0);
    await expect(ledger.usedBytes("guest-b")).resolves.toBe(0);
  });

  it("enforces the creator's plan against a member and leaves both rows unchanged", async () => {
    const ledger = ledgerWith("creator", 3 * GB - 1);
    const error = await expectQuotaError(
      reserveStorageForUpload(ledger, {
        uploaderUid: "guest",
        sessionOwnerUid: "creator",
        plan: "free",
        bytes: 2,
      }),
    );

    expect(error.ownerUid).toBe("creator");
    expect(error.uploaderUid).toBe("guest");
    expect(error.plan).toBe("free");
    expect(error.availableBytes).toBe(1);
    await expect(ledger.usedBytes("creator")).resolves.toBe(3 * GB - 1);
    await expect(ledger.usedBytes("guest")).resolves.toBe(0);
  });

  it("collapses a personal session onto the uploader and rejects blank ids", () => {
    expect(
      storageAttribution({ uploaderUid: "alice", sessionOwnerUid: null }),
    ).toEqual({ ownerUid: "alice", uploaderUid: "alice", isCreator: true });
    expect(
      storageAttribution({ uploaderUid: "guest", sessionOwnerUid: "creator" }),
    ).toEqual({ ownerUid: "creator", uploaderUid: "guest", isCreator: false });
    expect(() => storageAttribution({ uploaderUid: "" })).toThrowError(StorageError);
    expect(() =>
      storageAttribution({ uploaderUid: "guest", sessionOwnerUid: "  " }),
    ).toThrowError(StorageError);
  });
});

describe("concurrent uploads", () => {
  it("serializes reservations: only the uploads that fit succeed", async () => {
    const ledger = createMemoryStorageQuotaLedger();
    const chunk = 512 * MB; // six chunks fill a 3 GB Free plan exactly
    const uploads = Array.from({ length: 10 }, () =>
      reserveStorageForUpload(ledger, personal(chunk)),
    );
    const results = await Promise.allSettled(uploads);

    const fulfilled = results.filter((r) => r.status === "fulfilled");
    const rejected = results.filter((r) => r.status === "rejected");
    expect(fulfilled).toHaveLength(6);
    expect(rejected).toHaveLength(4);
    for (const failure of rejected) {
      expect((failure as PromiseRejectedResult).reason).toBeInstanceOf(
        StorageQuotaExceededError,
      );
      expect((failure as PromiseRejectedResult).reason.code).toBe(
        STORAGE_QUOTA_EXCEEDED_CODE,
      );
    }
    await expect(ledger.usedBytes("owner")).resolves.toBe(3 * GB);
  });

  it("never overshoots when concurrent sizes differ", async () => {
    const ledger = createMemoryStorageQuotaLedger();
    const sizes = [1 * GB, 1 * GB, 1 * GB, 1, 2 * GB, 1 * GB];
    const results = await Promise.allSettled(
      sizes.map((bytes) => reserveStorageForUpload(ledger, personal(bytes))),
    );

    const succeeded = results.filter((r) => r.status === "fulfilled").length;
    const used = await ledger.usedBytes("owner");
    expect(used).toBeLessThanOrEqual(3 * GB);
    expect(succeeded).toBe(3); // three 1 GB uploads; the rest never fit
    expect(used).toBe(3 * GB);
  });

  it("does not mix two creators' concurrent uploads", async () => {
    const ledger = createMemoryStorageQuotaLedger();
    const alice = Array.from({ length: 5 }, () =>
      reserveStorageForUpload(ledger, {
        uploaderUid: "alice",
        plan: "free",
        bytes: 1 * GB,
      }),
    );
    const bob = Array.from({ length: 5 }, () =>
      reserveStorageForUpload(ledger, {
        uploaderUid: "bob",
        sessionOwnerUid: "bob",
        plan: "go",
        bytes: 1 * GB,
      }),
    );
    await Promise.allSettled([...alice, ...bob]);

    await expect(ledger.usedBytes("alice")).resolves.toBe(3 * GB);
    await expect(ledger.usedBytes("bob")).resolves.toBe(5 * GB);
  });
});

describe("upload wrapper + reservation release", () => {
  it("keeps the reservation when the upload succeeds", async () => {
    const ledger = createMemoryStorageQuotaLedger();
    const upload = vi.fn(async () => "stored");

    await expect(
      withStorageQuota(ledger, personal(2 * GB), upload),
    ).resolves.toBe("stored");
    expect(upload).toHaveBeenCalledTimes(1);
    await expect(ledger.usedBytes("owner")).resolves.toBe(2 * GB);
  });

  it("releases the reservation when the upload fails", async () => {
    const ledger = createMemoryStorageQuotaLedger();
    const failure = new Error("put failed");

    await expect(
      withStorageQuota(ledger, personal(2 * GB), async () => {
        throw failure;
      }),
    ).rejects.toBe(failure);
    await expect(ledger.usedBytes("owner")).resolves.toBe(0);
  });

  it("never runs the upload when already over quota", async () => {
    const ledger = ledgerWith("owner", 3 * GB);
    const upload = vi.fn(async () => "stored");

    await expect(
      withStorageQuota(ledger, personal(1), upload),
    ).rejects.toBeInstanceOf(StorageQuotaExceededError);
    expect(upload).not.toHaveBeenCalled();
    await expect(ledger.usedBytes("owner")).resolves.toBe(3 * GB);
  });

  it("makes release idempotent and clamps at zero", async () => {
    const ledger = createMemoryStorageQuotaLedger();
    const reservation = await reserveStorageForUpload(ledger, personal(1 * GB));
    await reservation.release();
    await reservation.release();

    await expect(ledger.usedBytes("owner")).resolves.toBe(0);
    await ledger.release("owner", 5);
    await expect(ledger.usedBytes("owner")).resolves.toBe(0);
  });
});

describe("usage reads + input validation", () => {
  it("reads usage without throwing when over quota", async () => {
    const ledger = ledgerWith("owner", 5 * GB);
    await expect(
      readStorageUsage(ledger, { uploaderUid: "owner", plan: "free" }),
    ).resolves.toMatchObject({
      usedBytes: 5 * GB,
      limitBytes: 3 * GB,
      availableBytes: 0,
    });
  });

  it("rejects negative, fractional and non-finite byte counts", async () => {
    const ledger = createMemoryStorageQuotaLedger();
    for (const bytes of [-1, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
      await expect(
        reserveStorageForUpload(ledger, personal(bytes)),
      ).rejects.toMatchObject({ code: "invalid_arg" });
      await expect(checkStorageQuota(ledger, personal(bytes))).rejects.toMatchObject({
        code: "invalid_arg",
      });
    }
    await expect(ledger.usedBytes("owner")).resolves.toBe(0);
  });

  it("rejects a missing uploader instead of attributing to nobody", async () => {
    const ledger = createMemoryStorageQuotaLedger();
    await expect(
      reserveStorageForUpload(ledger, {
        uploaderUid: "",
        plan: "free",
        bytes: 1,
      }),
    ).rejects.toMatchObject({ code: "invalid_arg" });
  });
});
