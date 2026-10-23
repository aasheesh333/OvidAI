import { describe, expect, it } from "vitest";

import {
  UPLOAD_WINDOWS,
  UploadWindowExceededError,
  assertUploadWindow,
} from "./uploadWindow.js";

/**
 * The plan's file window is a product promise:
 *   Free 50 files / 24 h, Go·Plus·Pro 80 files / 3 h.
 * Only the per-project cap and the storage quota were enforced before this;
 * the window counter did not exist, so the number on the plans screen was
 * decoration.
 */

const now = new Date("2026-10-23T12:00:00.000Z");

function counting(n: number) {
  const seen: Date[] = [];
  return {
    seen,
    countSince: async (since: Date) => {
      seen.push(since);
      return n;
    },
  };
}

describe("upload window", () => {
  it("publishes the plan table the product states", () => {
    expect(UPLOAD_WINDOWS.free).toEqual({ limit: 50, hours: 24 });
    expect(UPLOAD_WINDOWS.go).toEqual({ limit: 80, hours: 3 });
    expect(UPLOAD_WINDOWS.plus).toEqual({ limit: 80, hours: 3 });
    expect(UPLOAD_WINDOWS.pro).toEqual({ limit: 80, hours: 3 });
  });

  it("allows an upload below the Free window and looks back exactly 24 h", async () => {
    const c = counting(49);
    await expect(
      assertUploadWindow({ tier: "free", now, countSince: c.countSince }),
    ).resolves.toBeUndefined();
    expect(c.seen[0]).toEqual(new Date("2026-10-22T12:00:00.000Z"));
  });

  it("refuses the 51st Free upload in the window with a retry instant", async () => {
    const c = counting(50);
    await expect(
      assertUploadWindow({ tier: "free", now, countSince: c.countSince }),
    ).rejects.toBeInstanceOf(UploadWindowExceededError);
  });

  it("refuses the 81st Go upload and looks back exactly 3 h", async () => {
    const c = counting(80);
    await expect(
      assertUploadWindow({ tier: "go", now, countSince: c.countSince }),
    ).rejects.toMatchObject({ code: "upload_limit_reached", status: 429 });
    expect(c.seen[0]).toEqual(new Date("2026-10-23T09:00:00.000Z"));
  });

  it("Plus and Pro share the 80 / 3 h window", async () => {
    for (const tier of ["plus", "pro"] as const) {
      const c = counting(80);
      await expect(
        assertUploadWindow({ tier, now, countSince: c.countSince }),
      ).rejects.toBeInstanceOf(UploadWindowExceededError);
    }
  });

  it("an unknown or missing tier fails closed to the Free window", async () => {
    for (const tier of [undefined, null, "", "mystery"]) {
      const c = counting(50);
      await expect(
        assertUploadWindow({ tier, now, countSince: c.countSince }),
      ).rejects.toBeInstanceOf(UploadWindowExceededError);
    }
  });

  it("the refusal carries the plan's numbers, not a raw status", async () => {
    const err = await assertUploadWindow({
      tier: "go",
      now,
      countSince: counting(80).countSince,
    }).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(UploadWindowExceededError);
    const e = err as UploadWindowExceededError;
    expect(e.limit).toBe(80);
    expect(e.hours).toBe(3);
    expect(e.message).toContain("80");
    expect(e.message).toContain("3 hours");
  });
});
