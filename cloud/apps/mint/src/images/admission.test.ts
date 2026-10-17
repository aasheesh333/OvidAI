import { describe, expect, it } from "vitest";
import { money } from "@ovid/money";
import { createAdmission, type AdmissionDeps } from "./admission.js";
import { ImageError } from "./types.js";

/**
 * Port of the admission half of server/images/deploy/images_gateway.py and
 * test_gateway_admission.py: tier budget minus the live key spend, the free
 * monthly cap, and the `${uid}:${duration}` window id.
 */

const identity = { uid: "alice", keyId: "key-id", tier: "pro" };

function deps(overrides: Partial<AdmissionDeps> = {}): AdmissionDeps {
  return {
    effectiveTier: async () => "pro",
    tierBudget: async () => ({ budget: 10, duration: "24h" }),
    freeCapRemaining: async () => 10,
    keySpend: async () => 0,
    ...overrides,
  };
}

async function imageError(promise: Promise<unknown>): Promise<ImageError> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(ImageError);
    return error as ImageError;
  }
  throw new Error("expected ImageError");
}

describe("images admission", () => {
  it("yields the window id and the tier budget minus key spend", async () => {
    const seen: { window: string; budget: string }[] = [];
    const admission = createAdmission(
      deps({
        tierBudget: async (uid, tier) => {
          expect(uid).toBe("alice");
          expect(tier).toBe("pro");
          return { budget: 10, duration: "24h" };
        },
        keySpend: async (keyId) => {
          expect(keyId).toBe("key-id");
          return 9.25;
        },
      }),
    );
    const result = await admission(identity, async (ctx) => {
      seen.push({ window: ctx.window, budget: ctx.budget.toString() });
      return { ok: true };
    });
    expect(result).toEqual({ ok: true });
    expect(seen).toEqual([{ window: "alice:24h", budget: "0.75" }]);
  });

  it("treats an unreadable key spend as zero", async () => {
    const admission = createAdmission(deps({ keySpend: async () => null }));
    let budget = "";
    await admission(identity, async (ctx) => {
      budget = ctx.budget.toString();
      return {};
    });
    expect(money(budget).equals(money("10"))).toBe(true);
  });

  it("rejects a free account whose monthly cap is exhausted", async () => {
    const admission = createAdmission(
      deps({
        effectiveTier: async () => "free",
        freeCapRemaining: async () => 0,
      }),
    );
    const error = await imageError(
      admission({ ...identity, tier: "free" }, async () => ({})),
    );
    expect(error.status).toBe(402);
    expect(error.code).toBe("image_limit_reached");
  });

  it("rejects a non-positive remaining budget", async () => {
    for (const spend of [10, 10.5, 99]) {
      const admission = createAdmission(deps({ keySpend: async () => spend }));
      const error = await imageError(admission(identity, async () => ({})));
      expect(error.status).toBe(402);
      expect(error.code).toBe("image_limit_reached");
    }
  });

  it("re-reads the effective tier at admission time, not the auth-time tier", async () => {
    const admission = createAdmission(
      deps({
        // The plan changed after auth: admission must use the live tier.
        effectiveTier: async () => "free",
        tierBudget: async (_uid, tier) => ({ budget: tier === "pro" ? 10 : 1, duration: "24h" }),
      }),
    );
    let budget = "";
    await admission(identity, async (ctx) => {
      budget = ctx.budget.toString();
      return {};
    });
    expect(money(budget).equals(money("1"))).toBe(true);
  });

  it("resolves the tier budget before the free-cap gate (Python order)", async () => {
    const calls: string[] = [];
    const admission = createAdmission(
      deps({
        effectiveTier: async () => {
          calls.push("tier");
          return "free";
        },
        tierBudget: async () => {
          calls.push("budget");
          return { budget: 10, duration: "24h" };
        },
        freeCapRemaining: async () => {
          calls.push("cap");
          return 0;
        },
        keySpend: async () => {
          calls.push("spend");
          return 0;
        },
      }),
    );
    const error = await imageError(admission(identity, async () => ({})));
    expect(error.status).toBe(402);
    expect(error.code).toBe("image_limit_reached");
    expect(calls).toEqual(["tier", "budget", "cap"]);
  });

  it("treats a key/info failure as zero spend", async () => {
    const admission = createAdmission(
      deps({
        keySpend: async () => {
          throw new Error("key/info down");
        },
      }),
    );
    let budget = "";
    await admission(identity, async (ctx) => {
      budget = ctx.budget.toString();
      return {};
    });
    expect(money(budget).equals(money("10"))).toBe(true);
  });
});
