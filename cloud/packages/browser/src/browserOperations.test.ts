import { describe, expect, it } from "vitest";

import { BrowserOperationCoordinator } from "./browserOperations.js";
import { releaseSession } from "./sessionOps.js";

function deferred<T = void>(): {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(error: unknown): void;
} {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

const shared = (operationId: string, signal?: AbortSignal) => ({
  kind: "shared" as const,
  operationId,
  ...(signal === undefined ? {} : { signal }),
});
const credential = (operationId: string, signal?: AbortSignal) => ({
  kind: "credential" as const,
  operationId,
  ...(signal === undefined ? {} : { signal }),
});

describe("BrowserOperationCoordinator", () => {
  it("runs independent shared operations concurrently and isolates per-user keys", async () => {
    const coordinator = new BrowserOperationCoordinator();
    const first = deferred();
    const second = deferred();
    let releaseFirst!: () => void;
    let releaseSecond!: () => void;
    const one = coordinator.withOperation("user-u1", shared("one"), async () => {
      releaseFirst = first.resolve;
      await first.promise;
      return "one";
    });
    const two = coordinator.withOperation("user-u1", shared("two"), async () => {
      releaseSecond = second.resolve;
      await second.promise;
      return "two";
    });
    const otherUser = coordinator.withOperation("user-u2", shared("three"), async () => "other");
    await Promise.resolve();
    releaseSecond();
    expect(await two).toBe("two");
    expect(await otherUser).toBe("other");
    releaseFirst();
    expect(await one).toBe("one");
  });

  it("exclusive entry drains current shared work and refuses new shared work instead of queueing a read-back", async () => {
    const coordinator = new BrowserOperationCoordinator();
    const release = deferred();
    const order: string[] = [];
    const ordinary = coordinator.withOperation("user-u1", shared("read"), async () => {
      order.push("shared:start");
      await release.promise;
      order.push("shared:end");
    });
    const exclusive = coordinator.withOperation("user-u1", credential("login"), async () => {
      order.push("credential");
      expect(coordinator.isCredentialOperationActive("user-u1")).toBe(true);
    });
    expect(coordinator.isCredentialOperationActive("user-u1")).toBe(true);
    await expect(
      coordinator.withOperation("user-u1", shared("late-read"), async () => {
        order.push("late-read");
      }),
    ).rejects.toMatchObject({ code: "credential_operation_in_progress" });
    release.resolve();
    await Promise.all([ordinary, exclusive]);
    expect(order).toEqual(["shared:start", "shared:end", "credential"]);
    expect(coordinator.isCredentialOperationActive("user-u1")).toBe(false);
    await coordinator.withOperation("user-u1", shared("after"), async () => order.push("after"));
    expect(order.at(-1)).toBe("after");
  });

  it("serializes credential operations per user without blocking another user", async () => {
    const coordinator = new BrowserOperationCoordinator();
    const release = deferred();
    const order: string[] = [];
    const first = coordinator.withOperation("user-u1", credential("first"), async () => {
      order.push("first:start");
      await release.promise;
      order.push("first:end");
    });
    const second = coordinator.withOperation("user-u1", credential("second"), async () => {
      order.push("second");
    });
    const other = coordinator.withOperation("user-u2", credential("other"), async () => {
      order.push("other");
    });
    await other;
    expect(order).toEqual(["first:start", "other"]);
    release.resolve();
    await Promise.all([first, second]);
    expect(order).toEqual(["first:start", "other", "first:end", "second"]);
  });

  it("is reentrant for nested broker withSession work carrying the same credential operation id", async () => {
    const coordinator = new BrowserOperationCoordinator();
    const result = await coordinator.withOperation("user-u1", credential("login-run"), async () =>
      coordinator.withOperation("user-u1", credential("login-run"), async () =>
        coordinator.withOperation("user-u1", shared("login-run"), async () => {
          expect(coordinator.isCredentialOperationActive("user-u1")).toBe(true);
          return "nested-ok";
        }),
      ),
    );
    expect(result).toEqual("nested-ok");
    expect(coordinator.isCredentialOperationActive("user-u1")).toBe(false);
  });

  it("allows distinct shared tool and pool operations nested inside one ordinary tool", async () => {
    const coordinator = new BrowserOperationCoordinator();
    const result = await coordinator.withOperation("user-u1", shared("tool-open"), async () =>
      coordinator.withOperation("user-u1", shared("pool-acquire"), async () => "ordinary"),
    );
    expect(result).toBe("ordinary");
    expect(coordinator.isCredentialOperationActive("user-u1")).toBe(false);
  });

  it("does not run a queued credential operation after its signal aborts", async () => {
    const coordinator = new BrowserOperationCoordinator();
    const release = deferred();
    const controller = new AbortController();
    let ran = false;
    const ordinary = coordinator.withOperation("user-u1", shared("read"), () => release.promise);
    const waiting = coordinator.withOperation("user-u1", credential("login", controller.signal), async () => {
      ran = true;
    });
    controller.abort();
    await expect(waiting).rejects.toMatchObject({ code: "operation_aborted" });
    release.resolve();
    await ordinary;
    expect(ran).toBe(false);
    expect(coordinator.isCredentialOperationActive("user-u1")).toBe(false);
  });

  it("checks abort before accepting same-operation reentrancy", async () => {
    const coordinator = new BrowserOperationCoordinator();
    const controller = new AbortController();
    let nestedRuns = 0;
    await coordinator.withOperation("user-u1", credential("owner"), async () => {
      controller.abort();
      await expect(
        coordinator.withOperation("user-u1", credential("owner", controller.signal), async () => {
          nestedRuns += 1;
        }),
      ).rejects.toMatchObject({ code: "operation_aborted" });
    });
    expect(nestedRuns).toBe(0);
  });

  it("denies a detached old operation id while another exclusive operation owns the key", async () => {
    const coordinator = new BrowserOperationCoordinator();
    let releaseDetached!: () => void;
    let detached!: Promise<string>;
    let detachedRuns = 0;
    await coordinator.withOperation("user-u1", credential("old-owner"), async () => {
      detached = new Promise<void>((resolve) => {
        releaseDetached = resolve;
      }).then(() =>
        coordinator.withOperation("user-u1", credential("old-owner"), async () => {
          detachedRuns += 1;
          return "escaped";
        }),
      );
    });
    // This continuation was created under the old owner but runs after it ended.
    await coordinator.withOperation("user-u1", credential("new-owner"), async () => {
      releaseDetached();
      await expect(detached).rejects.toMatchObject({ code: "credential_operation_in_progress" });
    });
    expect(detachedRuns).toBe(0);
  });

  it("distinguishes the active credential owner from outside direct registry consumers and reports lock transitions", async () => {
    const coordinator = new BrowserOperationCoordinator();
    const transitions: Array<{ key: string; active: boolean }> = [];
    const remove = coordinator.addCredentialOperationListener((key, active) => {
      transitions.push({ key, active });
    });
    const release = deferred();
    const pending = coordinator.withOperation("user-u1", credential("owner"), async () => {
      expect(coordinator.isCredentialOperationOwner("user-u1")).toBe(true);
      await release.promise;
    });
    expect(coordinator.isCredentialOperationOwner("user-u1")).toBe(false);
    expect(coordinator.isCredentialOperationActive("user-u1")).toBe(true);
    release.resolve();
    await pending;
    expect(coordinator.isCredentialOperationActive("user-u1")).toBe(false);
    expect(transitions).toEqual([
      { key: "user-u1", active: true },
      { key: "user-u1", active: false },
    ]);
    remove();
  });

  it("UNEXECUTED review C2/I2: credential epochs remain monotonic across unlock/prune and are isolated per key", async () => {
    const coordinator = new BrowserOperationCoordinator();
    const initial = coordinator.credentialEpoch("user-u1");
    const release = deferred();
    const pending = coordinator.withOperation("user-u1", credential("login"), async () => {
      expect(coordinator.credentialEpoch("user-u1")).toBe(initial + 1);
      expect(coordinator.credentialEpoch("user-u2")).toBe(0);
      await release.promise;
    });
    expect(coordinator.credentialEpoch("user-u1")).toBe(initial + 1);
    release.resolve();
    await pending;
    expect(coordinator.credentialEpoch("user-u1")).toBe(initial + 1);
    await coordinator.withOperation("user-u1", shared("ordinary"), async () => {
      expect(coordinator.credentialEpoch("user-u1")).toBe(initial + 1);
    });
    expect(coordinator.credentialEpoch("user-u1")).toBe(initial + 1);
  });

  it("close aborts credential work, awaits its cleanup, and refuses every later operation", async () => {
    const coordinator = new BrowserOperationCoordinator();
    const controller = new AbortController();
    const started = deferred();
    const cleanupStarted = deferred();
    const cleanupRelease = deferred();
    let cleaned = false;
    const pending = coordinator.withOperation(
      "user-u1",
      { ...credential("owner", controller.signal), abortController: controller },
      async () => {
        started.resolve();
        try {
          await new Promise<void>((resolve) => {
            controller.signal.addEventListener("abort", () => resolve(), { once: true });
          });
          return "aborted";
        } finally {
          cleanupStarted.resolve();
          await cleanupRelease.promise;
          cleaned = true;
        }
      },
    );
    await started.promise;
    const closing = coordinator.close();
    let closeSettled = false;
    void closing.then(() => {
      closeSettled = true;
    });
    await cleanupStarted.promise;
    expect(closeSettled).toBe(false);
    cleanupRelease.resolve();
    expect(await pending).toBe("aborted");
    await closing;
    expect(cleaned).toBe(true);
    await expect(coordinator.withOperation("user-u1", shared("late"), async () => "late")).rejects.toMatchObject({
      code: "operation_aborted",
    });
  });

  it("drains an already-running persistence release before exclusive work instead of capturing during credentials", async () => {
    const coordinator = new BrowserOperationCoordinator();
    const captureStarted = deferred();
    const captureRelease = deferred();
    let credentialStarted = false;
    const session = {
      userId: "u1",
      handle: {
        context: {
          storageState: async () => {
            captureStarted.resolve();
            await captureRelease.promise;
            return { cookies: [], origins: [] };
          },
        },
      },
    };
    const releasing = releaseSession(
      {
        browserOperations: coordinator,
        registry: {
          get: () => session,
          close: () => session,
        },
        pool: { releaseLive: async () => {} },
        persistence: null,
        cfg: {},
      } as never,
      "user-u1",
    );
    await captureStarted.promise;
    const exclusive = coordinator.withOperation("user-u1", credential("login"), async () => {
      credentialStarted = true;
    });
    try {
      await new Promise((resolve) => setTimeout(resolve, 0));
      expect(credentialStarted).toBe(false);
    } finally {
      captureRelease.resolve();
      await Promise.all([releasing, exclusive]);
    }
    expect(credentialStarted).toBe(true);
  });

  it("refuses already-aborted shared and credential entry before running the callback", async () => {
    const coordinator = new BrowserOperationCoordinator();
    const controller = new AbortController();
    controller.abort();
    let runs = 0;
    for (const options of [shared("shared", controller.signal), credential("credential", controller.signal)]) {
      await expect(
        coordinator.withOperation("user-u1", options, async () => {
          runs += 1;
        }),
      ).rejects.toMatchObject({ code: "operation_aborted" });
    }
    expect(runs).toBe(0);
  });
});
