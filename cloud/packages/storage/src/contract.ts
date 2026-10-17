/**
 * Shared StorageAdapter contract, run by the fs adapter's tests here and by
 * the R2 live tests in Task 2. Keeps the two adapters honest against the
 * same behavior set.
 */

import { afterAll, beforeAll, describe, expect, it } from "vitest";

import type { StorageAdapter } from "./adapter.js";

export function describeStorageContract(
  name: string,
  make: () => Promise<{ adapter: StorageAdapter; cleanup: () => Promise<void> }>,
): void {
  describe(`StorageAdapter contract — ${name}`, () => {
    let adapter: StorageAdapter;
    let cleanup: () => Promise<void>;

    beforeAll(async () => {
      const fx = await make();
      adapter = fx.adapter;
      cleanup = fx.cleanup;
    });

    afterAll(async () => {
      await cleanup();
    });

    it("Buffer put + getBuffer round-trips", async () => {
      const body = Buffer.from("contract buffer body");
      const { key, bytes } = await adapter.put("contract/buffer.bin", body);
      expect(bytes).toBe(body.length);
      const back = await adapter.getBuffer(key);
      expect(back).not.toBeNull();
      expect(back!.equals(body)).toBe(true);
    });

    it("stream put + get round-trips", async () => {
      const { Readable } = await import("node:stream");
      const body = Readable.from(["a", "b", "c"]);
      const { key } = await adapter.put("contract/stream.bin", body);
      const stream = await adapter.get(key);
      expect(stream).not.toBeNull();
      const chunks: Buffer[] = [];
      for await (const c of stream!) chunks.push(c as Buffer);
      expect(Buffer.concat(chunks).toString()).toBe("abc");
    });

    it("presignGet/presignPut return non-empty strings", async () => {
      await adapter.put("contract/presign.bin", Buffer.from("v"));
      const g = await adapter.presignGet("contract/presign.bin", 60);
      const p = await adapter.presignPut("contract/presign.bin", 60);
      expect(typeof g).toBe("string");
      expect(g.length).toBeGreaterThan(0);
      expect(typeof p).toBe("string");
      expect(p.length).toBeGreaterThan(0);
    });

    it("metadata round-trips via head", async () => {
      await adapter.put("contract/meta.bin", Buffer.from("v"), {
        contentType: "text/plain",
        metadata: { foo: "bar", n: "42" },
      });
      const head = await adapter.head("contract/meta.bin");
      expect(head).not.toBeNull();
      expect(head!.metadata).toEqual({ foo: "bar", n: "42" });
    });

    it("delete-then-get is null", async () => {
      await adapter.put("contract/gone.bin", Buffer.from("v"));
      await adapter.delete("contract/gone.bin");
      expect(await adapter.getBuffer("contract/gone.bin")).toBeNull();
      expect(await adapter.head("contract/gone.bin")).toBeNull();
    });

    it("head of a missing key is null", async () => {
      expect(await adapter.head("contract/never-existed.bin")).toBeNull();
    });
  });
}
