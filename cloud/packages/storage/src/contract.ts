/**
 * Shared StorageAdapter contract, run by the fs adapter's tests here and by
 * the R2 live tests in Task 2. Keeps the two adapters honest against the
 * same behavior set.
 *
 * The suite functions are INJECTED by the caller (storageContractSuite):
 * this module must not import vitest at runtime — it is re-exported from
 * src/index.ts, and a module-scope vitest import makes the compiled package
 * entry (dist/index.js) throw "Vitest failed to access its internal state"
 * under plain Node. Vitest appears here only as type-level
 * `typeof import("vitest")` references, which tsc erases entirely.
 */

import type { StorageAdapter } from "./adapter.js";

export type StorageContractMake = () => Promise<{
  adapter: StorageAdapter;
  cleanup: () => Promise<void>;
}>;

/** The vitest surface the contract needs — injected, never imported here. */
export interface ContractFramework {
  describe: typeof import("vitest").describe;
  it: typeof import("vitest").it;
  expect: typeof import("vitest").expect;
  beforeAll: typeof import("vitest").beforeAll;
  afterAll: typeof import("vitest").afterAll;
}

function runStorageContract(
  f: ContractFramework,
  name: string,
  make: StorageContractMake,
): void {
  f.describe(`StorageAdapter contract — ${name}`, () => {
    let adapter: StorageAdapter;
    let cleanup: () => Promise<void>;

    f.beforeAll(async () => {
      const fx = await make();
      adapter = fx.adapter;
      cleanup = fx.cleanup;
    });

    f.afterAll(async () => {
      await cleanup();
    });

    f.it("Buffer put + getBuffer round-trips", async () => {
      const body = Buffer.from("contract buffer body");
      const { key, bytes } = await adapter.put("contract/buffer.bin", body);
      f.expect(bytes).toBe(body.length);
      const back = await adapter.getBuffer(key);
      f.expect(back).not.toBeNull();
      f.expect(back!.equals(body)).toBe(true);
    });

    f.it("stream put + get round-trips", async () => {
      const { Readable } = await import("node:stream");
      const body = Readable.from(["a", "b", "c"]);
      const { key } = await adapter.put("contract/stream.bin", body);
      const stream = await adapter.get(key);
      f.expect(stream).not.toBeNull();
      const chunks: Buffer[] = [];
      for await (const c of stream!) chunks.push(c as Buffer);
      f.expect(Buffer.concat(chunks).toString()).toBe("abc");
    });

    f.it("presignGet/presignPut return non-empty strings", async () => {
      await adapter.put("contract/presign.bin", Buffer.from("v"));
      const g = await adapter.presignGet("contract/presign.bin", 60);
      const p = await adapter.presignPut({ key: "contract/presign.bin", ttlSeconds: 60 });
      f.expect(typeof g).toBe("string");
      f.expect(g.length).toBeGreaterThan(0);
      f.expect(typeof p).toBe("string");
      f.expect(p.length).toBeGreaterThan(0);
    });

    f.it("metadata round-trips via head", async () => {
      await adapter.put("contract/meta.bin", Buffer.from("v"), {
        contentType: "text/plain",
        metadata: { foo: "bar", n: "42" },
      });
      const head = await adapter.head("contract/meta.bin");
      f.expect(head).not.toBeNull();
      f.expect(head!.metadata).toEqual({ foo: "bar", n: "42" });
      f.expect(head!.contentType).toBe("text/plain");
    });

    f.it("delete-then-get is null", async () => {
      await adapter.put("contract/gone.bin", Buffer.from("v"));
      await adapter.delete("contract/gone.bin");
      f.expect(await adapter.getBuffer("contract/gone.bin")).toBeNull();
      f.expect(await adapter.head("contract/gone.bin")).toBeNull();
    });

    f.it("head of a missing key is null", async () => {
      f.expect(await adapter.head("contract/never-existed.bin")).toBeNull();
    });
  });
}

export type StorageContractSuite = {
  (name: string, make: StorageContractMake): void;
  /** Conditional skip — the R2 live suite (no credentials in CI → skipped). */
  skipIf(cond: boolean): (name: string, make: StorageContractMake) => void;
};

/**
 * Builds a StorageContractSuite bound to a concrete test framework. Callers
 * pass their own vitest functions:
 *
 *   const describeStorageContract = storageContractSuite({
 *     describe, it, expect, beforeAll, afterAll,
 *   });
 */
export function storageContractSuite(f: ContractFramework): StorageContractSuite {
  const run = (name: string, make: StorageContractMake): void => {
    runStorageContract(f, name, make);
  };
  return Object.assign(run, {
    skipIf(cond: boolean): (name: string, make: StorageContractMake) => void {
      return (name, make) => {
        if (cond) {
          f.describe.skip(
            `StorageAdapter contract — ${name} (skipped: no live credentials)`,
            () => {},
          );
          return;
        }
        run(name, make);
      };
    },
  });
}
