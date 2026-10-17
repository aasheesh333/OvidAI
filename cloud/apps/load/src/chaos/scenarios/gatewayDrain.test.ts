import { describe, expect, it, vi } from "vitest";
import {
  installShutdownHandlers,
  WS_RESTART_CLOSE_CODE,
  WS_RESTART_CLOSE_REASON,
} from "@ovid/gateway";
import {
  EXPECTED_CLOSE_CODE,
  EXPECTED_CLOSE_REASON,
} from "./gatewayRestart.js";

/**
 * P10 Task 2 drain contract, pinned at the unit level so the chaos suite fails
 * if the gateway's SIGTERM behaviour regresses — the gateway-restart scenario
 * asserts the same code/reason on a real staging restart.
 */

type FakeFastifyApp = Parameters<typeof installShutdownHandlers>[0];

interface FakeApp {
  app: FakeFastifyApp;
  closed: () => boolean;
}

function fakeApp(closeImpl?: () => Promise<void>): FakeApp {
  let closed = false;
  const app = {
    log: { warn: () => {} },
    close: async () => {
      closed = true;
      await closeImpl?.();
    },
  } as unknown as FakeFastifyApp;
  return { app, closed: () => closed };
}

describe("installShutdownHandlers (P10 Task 2 drain contract)", () => {
  it("closes live sockets with 1001 'server restarting', then closes the app and exits 0", async () => {
    const order: string[] = [];
    const { app } = fakeApp(async () => {
      order.push("app.close");
    });
    const closeWs = vi.fn(async (code: number, reason: string) => {
      order.push(`closeWs:${code}:${reason}`);
    });
    const exit = vi.fn((code: number) => {
      order.push(`exit:${code}`);
    });

    const shutdown = installShutdownHandlers(app, { closeWs, exit });
    await shutdown();

    expect(closeWs).toHaveBeenCalledTimes(1);
    expect(closeWs).toHaveBeenCalledWith(
      WS_RESTART_CLOSE_CODE,
      WS_RESTART_CLOSE_REASON,
    );
    expect(WS_RESTART_CLOSE_CODE).toBe(1001);
    expect(WS_RESTART_CLOSE_REASON).toBe("server restarting");
    expect(order).toEqual([
      "closeWs:1001:server restarting",
      "app.close",
      "exit:0",
    ]);
  });

  it("is idempotent: repeated signals run the drain once", async () => {
    const { app } = fakeApp();
    const closeWs = vi.fn(async () => {});
    const exit = vi.fn();
    const shutdown = installShutdownHandlers(app, { closeWs, exit });

    await Promise.all([shutdown(), shutdown()]);
    await shutdown();

    expect(closeWs).toHaveBeenCalledTimes(1);
    expect(exit).toHaveBeenCalledTimes(1);
  });

  it("hard-exits after drainMs when the drain wedges", async () => {
    const { app } = fakeApp(() => new Promise<void>(() => {}));
    const exit = vi.fn();
    const shutdown = installShutdownHandlers(app, {
      closeWs: async () => {},
      drainMs: 20,
      exit,
    });

    // Never resolves: app.close is wedged. The timer is the safety net.
    void shutdown();
    await new Promise((resolve) => setTimeout(resolve, 80));

    expect(exit).toHaveBeenCalledWith(1);
  });

  it("scenario constants are the gateway's real drain constants", () => {
    expect(EXPECTED_CLOSE_CODE).toBe(WS_RESTART_CLOSE_CODE);
    expect(EXPECTED_CLOSE_REASON).toBe(WS_RESTART_CLOSE_REASON);
  });
});
