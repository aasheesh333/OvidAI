import { describe, expect, it } from "vitest";
import { projectAccountHealth } from "./accountHealthProjection.js";

// UNEXECUTED while /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md
// is active. These tests define the pure adapter contract; no RED/GREEN claim
// is made until the user permits test execution.

const CHECKED_AT = "2026-10-24T10:00:00.000Z";
const GIB = 1024 ** 3;

function completeFacts() {
  return {
    plan: {
      tier: "7x",
      id: "plus",
      name: "Ovid Plus",
      expiresAt: "2026-11-20T00:00:00.000Z",
      limits: {
        storageBytes: 15 * GIB,
        customConnectors: 20,
        projectFiles: 150,
        manualModels: true,
        autoMultiplier: 5,
        uploads: { count: 80, windowHours: 3 },
      },
    },
    storage: {
      usedBytes: GIB,
      quotaBytes: 15 * GIB,
      remainingBytes: 14 * GIB,
    },
    usage: {
      today: {
        since: "2026-10-24T00:00:00.000Z",
        until: "2026-10-24T12:00:00.000Z",
        used: {
          runs: 2,
          modelCalls: 3,
          inputTokens: 1000,
          outputTokens: 200,
          cacheReadTokens: 0,
          cacheWriteTokens: 0,
          costUsd: null,
        },
        remainingUsd: null,
        tokensUsed: 1200,
        tokenCap: 250_000_000,
        tokensRemaining: 249_998_800,
      },
      month: {
        since: "2026-10-01T00:00:00.000Z",
        until: "2026-10-24T12:00:00.000Z",
        used: {
          runs: 9,
          modelCalls: 12,
          inputTokens: 8000,
          outputTokens: 900,
          cacheReadTokens: 0,
          cacheWriteTokens: 0,
          costUsd: null,
        },
        remainingUsd: null,
        tokensUsed: 8900,
        tokenCap: 7_500_000_000,
        tokensRemaining: 7_499_991_100,
      },
    },
    standing: {
      banned: false,
      bannedAt: null,
      bannedReason: null,
      multiIpFlags: null,
      deletion: null,
    },
    devices: { total: 2, active: 1, currentRegistered: true },
    security: { status: "ok", multiIpFlags: 0, lastCheckedAt: CHECKED_AT },
  };
}

function facts(overrides: Record<string, unknown> = {}) {
  return { ...completeFacts(), ...overrides };
}

function planWithUploads(uploads: Record<string, unknown> | null) {
  const plan = completeFacts().plan;
  return {
    ...plan,
    limits: uploads === null ? null : { ...plan.limits, uploads },
  };
}

describe("projectAccountHealth", () => {
  it("preserves the existing gateway DTO and projects Flutter-complete facts", () => {
    const input = completeFacts();
    const projected = projectAccountHealth(input);

    expect(projected.plan).toEqual(input.plan);
    expect(projected.storage).toEqual(input.storage);
    expect(projected.usage).toEqual(input.usage);
    expect(projected.standing).toEqual(input.standing);
    expect(projected.devices).toEqual({
      total: 2,
      active: 1,
      currentRegistration: true,
      currentRegistered: true,
    });
    expect(projected.security).toEqual({
      status: "ok",
      flags: 0,
      checkedAt: CHECKED_AT,
      multiIpFlags: 0,
      lastCheckedAt: CHECKED_AT,
    });
    expect(projected.plan).toMatchObject({
      limits: { uploads: { count: 80, windowHours: 3 } },
    });
    expect(projected).not.toHaveProperty("uploads");
    expect(projected).not.toHaveProperty("uploadWindow");
    expect(projected.complete).toBe(true);
    expect(projected.known).toBe(true);
    expect(projected.statusLabel).toBe("Healthy");
  });

  it("keeps measured zero as a fact and reports explicit no-activity facts", () => {
    const projected = projectAccountHealth(facts({
      devices: { total: 0, active: 0, currentRegistered: false },
      plan: planWithUploads({ count: 0, windowHours: 24 }),
    }));

    expect(projected.devices).toMatchObject({
      total: 0,
      active: 0,
      currentRegistration: false,
    });
    expect(projected.plan).toMatchObject({
      limits: { uploads: { count: 0, windowHours: 24 } },
    });
    expect(projected.complete).toBe(true);
    expect(projected.known).toBe(true);
    expect(projected.statusLabel).toBe("Healthy");
  });

  it("makes every supplemental field unknown when no supplemental source exists", () => {
    const projected = projectAccountHealth({
      plan: completeFacts().plan,
      storage: completeFacts().storage,
      usage: completeFacts().usage,
      standing: completeFacts().standing,
    });

    expect(projected.devices).toEqual({
      total: null,
      active: null,
      currentRegistration: null,
      currentRegistered: null,
    });
    expect(projected.security).toEqual({
      status: null,
      flags: null,
      checkedAt: null,
      multiIpFlags: null,
      lastCheckedAt: null,
    });
    expect(projected.plan).toMatchObject({
      limits: { uploads: { count: 80, windowHours: 3 } },
    });
    expect(projected.complete).toBe(false);
    expect(projected.known).toBe(false);
    expect(projected.statusLabel).toBe("Attention needed · Status unknown");
  });

  it.each([false, true])(
    "keeps devices null unknown when currentRegistration is %s",
    (currentRegistration) => {
      const projected = projectAccountHealth(facts({
        devices: null,
        currentRegistration,
        security: { status: "healthy", multiIpFlags: 0, lastCheckedAt: CHECKED_AT },
        uploadWindow: { used: 0, remaining: 80, windowHours: 3 },
      }));

      expect(projected.devices).toEqual({
        total: null,
        active: null,
        currentRegistration,
        currentRegistered: currentRegistration,
      });
      expect(projected.plan).toMatchObject({
        limits: { uploads: { count: 80, windowHours: 3 } },
      });
      expect(projected).not.toHaveProperty("uploadWindow");
      expect(projected.security.flags).toBe(0);
      expect(projected.complete).toBe(false);
      expect(projected.known).toBe(false);
      expect(projected.statusLabel).toBe("Attention needed · Status unknown");
    },
  );

  it.each([
    ["device total", { devices: { active: 1, currentRegistered: true } }],
    ["device active", { devices: { total: 2, currentRegistered: true } }],
    ["current registration", { devices: { total: 2, active: 1 } }],
    ["security status", { security: { multiIpFlags: 0, lastCheckedAt: CHECKED_AT } }],
    ["security flags", { security: { status: "ok", lastCheckedAt: CHECKED_AT } }],
    ["security checked time", { security: { status: "ok", multiIpFlags: 0 } }],
    ["upload count", { plan: planWithUploads({ windowHours: 3 }) }],
    ["upload window", { plan: planWithUploads({ count: 80 }) }],
  ])("does not call partial %s facts complete or healthy", (_name, supplemental) => {
    const projected = projectAccountHealth(facts(supplemental));

    expect(projected.complete).toBe(false);
    expect(projected.known).toBe(false);
    expect(projected.statusLabel).toBe("Attention needed · Status unknown");
  });

  it("preserves the readable fields in a partial projection without filling gaps", () => {
    const projected = projectAccountHealth(facts({
      devices: { total: 2, active: 0 },
      security: { status: "ok", multiIpFlags: null, lastCheckedAt: CHECKED_AT },
      plan: planWithUploads({ count: 80 }),
    }));

    expect(projected.devices).toMatchObject({ total: 2, active: 0, currentRegistration: null });
    expect(projected.security).toMatchObject({ status: "ok", flags: null, checkedAt: CHECKED_AT });
    expect(projected.plan).toMatchObject({
      limits: { uploads: { count: 80, windowHours: null } },
    });
    expect(projected.complete).toBe(false);
    expect(projected.known).toBe(false);
    expect(projected.statusLabel).not.toBe("Healthy");
  });

  it("rejects malformed counters, booleans, statuses, and timestamps as unknown", () => {
    const projected = projectAccountHealth(facts({
      devices: { total: 2.5, active: -1, currentRegistered: "yes" },
      security: { status: "everything_is_fine", multiIpFlags: Number.NaN, lastCheckedAt: "not-a-date" },
      plan: planWithUploads({ count: -1, windowHours: Number.POSITIVE_INFINITY }),
    }));

    expect(projected.devices).toEqual({
      total: null,
      active: null,
      currentRegistration: null,
      currentRegistered: null,
    });
    expect(projected.security).toMatchObject({ status: null, flags: null, checkedAt: null });
    expect(projected.plan).toMatchObject({
      limits: { uploads: { count: null, windowHours: null } },
    });
    expect(projected.complete).toBe(false);
    expect(projected.known).toBe(false);
    expect(projected.statusLabel).toBe("Attention needed · Status unknown");
  });

  it("requires a complete security verdict before surfacing an attention state", () => {
    const projected = projectAccountHealth(facts({
      security: { status: "attention", multiIpFlags: 0 },
    }));

    expect(projected.security).toMatchObject({ status: "attention", checkedAt: null });
    expect(projected.statusLabel).toBe("Attention needed · Status unknown");
    expect(projected.statusLabel).not.toContain("Security");
  });

  it.each(["attention", "degraded"])("complete %s security facts force review", (status) => {
    const projected = projectAccountHealth(facts({
      security: { status, multiIpFlags: 0, lastCheckedAt: CHECKED_AT },
    }));

    expect(projected.complete).toBe(true);
    expect(projected.known).toBe(true);
    expect(projected.statusLabel).toBe(
      status === "degraded"
        ? "Attention needed · Security degraded"
        : "Attention needed · Security review",
    );
    expect(projected.statusLabel).not.toBe("Healthy");
  });

  it("a complete nonzero security flag count forces review even with an ok status", () => {
    const projected = projectAccountHealth(facts({
      security: { status: "ok", multiIpFlags: 2, lastCheckedAt: CHECKED_AT },
    }));

    expect(projected.security.flags).toBe(2);
    expect(projected.complete).toBe(true);
    expect(projected.statusLabel).toBe("Attention needed · Security review");
  });

  it("does not infer anomaly evidence from standing or device fields", () => {
    const projected = projectAccountHealth(facts({
      standing: { ...completeFacts().standing, multiIpFlags: 7 },
      devices: { total: 9, active: 9, currentRegistered: true },
      security: null,
    }));

    expect(projected.security).toMatchObject({ status: null, flags: null, checkedAt: null });
    expect(projected.complete).toBe(false);
    expect(projected.statusLabel).toBe("Attention needed · Status unknown");
  });

  it("normalizes only the Flutter-recognized status vocabulary", () => {
    const projected = projectAccountHealth(facts({
      security: { status: "  HeAlThY  ", multiIpFlags: 0, lastCheckedAt: CHECKED_AT },
    }));

    expect(projected.security.status).toBe("healthy");
    expect(projected.complete).toBe(true);
    expect(projected.statusLabel).toBe("Healthy");
  });

  it("retains storage warning priority over unknown supplemental facts", () => {
    const projected = projectAccountHealth(facts({
      storage: { usedBytes: 14 * GIB, quotaBytes: 15 * GIB, remainingBytes: GIB },
      devices: null,
      security: null,
    }));

    expect(projected.statusLabel).toBe("Attention needed · Storage almost full");
  });

  it("retains daily quota warning priority over unknown supplemental facts", () => {
    const projected = projectAccountHealth(facts({
      usage: {
        ...completeFacts().usage,
        today: {
          ...completeFacts().usage.today,
          tokensUsed: 250_000_000,
          tokensRemaining: 0,
        },
      },
      devices: null,
      security: null,
    }));

    expect(projected.statusLabel).toBe("Attention needed · Daily limit reached");
  });

  it("retains storage warning priority over security attention", () => {
    const projected = projectAccountHealth(facts({
      storage: { usedBytes: 15 * GIB, quotaBytes: 15 * GIB, remainingBytes: 0 },
      security: { status: "degraded", multiIpFlags: 4, lastCheckedAt: CHECKED_AT },
    }));

    expect(projected.statusLabel).toBe("Attention needed · Storage almost full");
  });

  it("preserves banned and deletion-standing priority over all other facts", () => {
    const banned = projectAccountHealth(facts({
      standing: { ...completeFacts().standing, banned: true, bannedReason: "auto" },
      storage: { usedBytes: 15 * GIB, quotaBytes: 15 * GIB, remainingBytes: 0 },
    }));
    const deleting = projectAccountHealth(facts({
      standing: {
        ...completeFacts().standing,
        deletion: { state: "pending", pending: true, deleteAfter: "2026-11-20T00:00:00.000Z" },
      },
      security: { status: "degraded", multiIpFlags: 1, lastCheckedAt: CHECKED_AT },
    }));

    expect(banned.statusLabel).toBe("Banned");
    expect(deleting.statusLabel).toBe("Attention needed · Deletion scheduled");
  });

  it("uses the current Flutter 90 percent storage and exhausted daily-cap boundaries", () => {
    const belowStorage = projectAccountHealth(facts({
      storage: { usedBytes: 899, quotaBytes: 1000, remainingBytes: 101 },
    }));
    const atStorage = projectAccountHealth(facts({
      storage: { usedBytes: 900, quotaBytes: 1000, remainingBytes: 100 },
    }));
    const belowDaily = projectAccountHealth(facts({
      usage: {
        ...completeFacts().usage,
        today: { ...completeFacts().usage.today, tokensUsed: 999, tokenCap: 1000, tokensRemaining: 1 },
      },
    }));
    const atDaily = projectAccountHealth(facts({
      usage: {
        ...completeFacts().usage,
        today: { ...completeFacts().usage.today, tokensUsed: 1000, tokenCap: 1000, tokensRemaining: 0 },
      },
    }));

    expect(belowStorage.statusLabel).toBe("Healthy");
    expect(atStorage.statusLabel).toBe("Attention needed · Storage almost full");
    expect(belowDaily.statusLabel).toBe("Healthy");
    expect(atDaily.statusLabel).toBe("Attention needed · Daily limit reached");
  });

  it("ignores alternate upload and verdict sources when the canonical plan is complete", () => {
    const projected = projectAccountHealth(facts({
      uploads: { count: 0, window: 0 },
      uploadWindow: { used: 12, cap: 0, remaining: 0, windowHours: 0 },
      complete: false,
      known: false,
      statusLabel: "Attention needed · Status unknown",
    }));

    expect(projected.plan).toMatchObject({
      limits: { uploads: { count: 80, windowHours: 3 } },
    });
    expect(projected).not.toHaveProperty("uploads");
    expect(projected).not.toHaveProperty("uploadWindow");
    expect(projected.complete).toBe(true);
    expect(projected.known).toBe(true);
    expect(projected.statusLabel).toBe("Healthy");
  });

  it("does not complete partial canonical uploads from top-level sources or verdicts", () => {
    const projected = projectAccountHealth(facts({
      plan: planWithUploads({ count: 80 }),
      uploads: { count: 80, window: 3 },
      uploadWindow: { used: 0, cap: 80, remaining: 80, windowHours: 3 },
      complete: true,
      known: true,
      statusLabel: "Healthy",
    }));

    expect(projected.plan).toMatchObject({
      limits: { uploads: { count: 80, windowHours: null } },
    });
    expect(projected).not.toHaveProperty("uploads");
    expect(projected).not.toHaveProperty("uploadWindow");
    expect(projected.complete).toBe(false);
    expect(projected.known).toBe(false);
    expect(projected.statusLabel).toBe("Attention needed · Status unknown");
  });

  it("ignores unknown top-level counter usage instead of converting it to zero", () => {
    const projected = projectAccountHealth(facts({
      uploadWindow: { used: null, cap: 0, remaining: null, windowHours: 0 },
    }));

    expect(projected.plan).toMatchObject({
      limits: { uploads: { count: 80, windowHours: 3 } },
    });
    expect(projected).not.toHaveProperty("uploadWindow");
    expect(projected.complete).toBe(true);
    expect(projected.statusLabel).toBe("Healthy");
  });

  it("requires the committed windowHours spelling in canonical plan uploads", () => {
    const projected = projectAccountHealth(facts({
      plan: planWithUploads({ count: 80, window: 3 }),
      uploadWindow: { used: 0, cap: 80, remaining: 80, windowHours: 3 },
    }));

    expect(projected.plan).toMatchObject({
      limits: { uploads: { count: 80, window: 3, windowHours: null } },
    });
    expect(projected).not.toHaveProperty("uploadWindow");
    expect(projected.complete).toBe(false);
    expect(projected.known).toBe(false);
    expect(projected.statusLabel).toBe("Attention needed · Status unknown");
  });

  it("accepts registered-device rows as a source only with explicit activity and registration facts", () => {
    const projected = projectAccountHealth(facts({
      devices: {
        rows: [
          { deviceId: "masked-a", active: true, currentRegistration: true },
          { deviceId: "masked-b", active: false, currentRegistration: false },
        ],
      },
      security: { status: "ok", multiIpFlags: 0, lastCheckedAt: CHECKED_AT },
    }));

    expect(projected.devices).toMatchObject({ total: 2, active: 1, currentRegistration: true });
    expect(projected.complete).toBe(true);
  });

  it("does not equate a device row's presence with current registration or activity", () => {
    const projected = projectAccountHealth(facts({
      devices: [{ deviceId: "masked-a", platform: "android" }],
    }));

    expect(projected.devices).toMatchObject({ total: 1, active: null, currentRegistration: null });
    expect(projected.complete).toBe(false);
    expect(projected.statusLabel).toBe("Attention needed · Status unknown");
  });

  it("never turns absent device arrays, null security, or null counters into a complete verdict", () => {
    const projected = projectAccountHealth(facts({
      devices: [],
      security: null,
      uploadWindow: null,
      uploads: null,
      plan: planWithUploads(null),
    }));

    expect(projected.devices).toMatchObject({ total: 0, active: null, currentRegistration: null });
    expect(projected.security.status).toBeNull();
    expect(projected.plan).toMatchObject({ limits: null });
    expect(projected).not.toHaveProperty("uploads");
    expect(projected).not.toHaveProperty("uploadWindow");
    expect(projected.complete).toBe(false);
    expect(projected.known).toBe(false);
  });
});
