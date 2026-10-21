import { describe, expect, it } from "vitest";

import { ensureSession } from "./sessionOps.js";
import type { SessionBrowser } from "./sessions.js";
import type { SessionOps } from "./sessionOps.js";

function opsFor(session: SessionBrowser): SessionOps {
  return {
    pool: {
      acquireLive: async () => {
        throw new Error("pool must not be touched for an existing session");
      },
    } as never,
    registry: {
      get: () => session,
      touch: () => {},
    } as never,
    persistence: null,
    cfg: {} as never,
  };
}

const session = {
  sessionId: "shared-browser-key",
  userId: "owner",
  handle: { page: { url: () => "https://example.test/" }, context: {}, touch() {} },
  tabs: [],
  activeIndex: 0,
  takeover: false,
  takeoverViewerId: null,
  lastActivityAt: 0,
  console: [],
  network: [],
  dialogs: [],
  popups: [],
} as unknown as SessionBrowser;

describe("ensureSession ownership", () => {
  it("returns the session to its owner", async () => {
    await expect(
      ensureSession(opsFor(session), { sessionId: "shared-browser-key", userId: "owner" }),
    ).resolves.toBe(session);
  });

  it("refuses a same-key lookup by a different user", async () => {
    await expect(
      ensureSession(opsFor(session), { sessionId: "shared-browser-key", userId: "attacker" }),
    ).rejects.toThrow(/belongs to a different user/);
  });
});
