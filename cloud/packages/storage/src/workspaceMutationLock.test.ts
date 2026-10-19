import { describe, expect, it } from "vitest";
import { WorkspaceMutationLocks } from "./workspaceMutationLock.js";

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

it("overlapping paths queue FIFO, but sibling files/users run independently", async () => {
  const locks = new WorkspaceMutationLocks();
  const gate = deferred();
  const entered = deferred();
  const order: string[] = [];
  const first = locks.run(["/root/u/workspace/src/a"], async () => {
    entered.resolve();
    await gate.promise;
    order.push("first");
  });
  await entered.promise;
  const folder = locks.run(["/root/u/workspace/src"], async () => { order.push("folder"); });
  const child = locks.run(["/root/u/workspace/src/a"], async () => { order.push("child"); });
  const independent = locks.run(["/root/u/workspace/other", "/root/v/workspace/src/a"], async () => {
    order.push("independent");
  });
  await independent;
  expect(order).toEqual(["independent"]);
  expect(locks).toHaveProperty("pending.size", 3);
  gate.resolve();
  await Promise.all([first, folder, child]);
  expect(order).toEqual(["independent", "first", "folder", "child"]);
  expect(locks).toHaveProperty("pending.size", 0);
});

describe("multi-path mutations", () => {
  it("opposite direction moves acquire both paths together without deadlock", async () => {
    const locks = new WorkspaceMutationLocks();
    const gate = deferred();
    const entered = deferred();
    const order: number[] = [];
    const first = locks.run(["/ws/a", "/ws/b"], async () => {
      entered.resolve();
      await gate.promise;
      order.push(1);
    });
    await entered.promise;
    const second = locks.run(["/ws/b", "/ws/a"], async () => { order.push(2); });
    const third = locks.run(["/ws/a/child"], async () => { order.push(3); });
    gate.resolve();
    await Promise.all([first, second, third]);
    expect(order).toEqual([1, 2, 3]);
    expect(locks).toHaveProperty("pending.size", 0);
  });

  it("throws release active entries and wake queued callers without poisoning the queue", async () => {
    const locks = new WorkspaceMutationLocks();
    const gate = deferred();
    const entered = deferred();
    const first = locks.run(["/ws/file"], async () => {
      entered.resolve();
      await gate.promise;
      throw new Error("failed write");
    });
    const refused = expect(first).rejects.toThrow("failed write");
    await entered.promise;
    const second = locks.run(["/ws/file"], async () => "ok");
    expect(locks).toHaveProperty("pending.size", 2);
    gate.resolve();
    await refused;
    expect(await second).toBe("ok");
    expect(locks).toHaveProperty("pending.size", 0);
    await Promise.all(Array.from({ length: 200 }, (_, i) => locks.run([`/ws/${i}`], async () => i)));
    expect(locks).toHaveProperty("pending.size", 0);
  });
});
