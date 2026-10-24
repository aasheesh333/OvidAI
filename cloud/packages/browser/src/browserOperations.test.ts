import { describe, expect, it } from "vitest";

import { BrowserOperationCoordinator } from "./browserOperations.js";

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
