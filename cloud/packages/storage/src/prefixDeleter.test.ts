import { describe, expect, it, vi } from "vitest";
import { DeleteObjectsCommand, ListObjectsV2Command } from "@aws-sdk/client-s3";
import {
  createR2PrefixDeleter,
  createR2PrefixDeleterFromEnv,
  type PrefixDeleteClient,
} from "./prefixDeleter.js";

/**
 * P9 final review H2: the deleter must actually list and delete every object
 * under the user prefix — not complete as a no-op while private files remain.
 */

const cfg = {
  accountId: "acct",
  accessKeyId: "key",
  secretAccessKey: "secret",
  bucket: "bucket",
};

type ListPage = {
  Contents?: Array<{ Key?: string }>;
  IsTruncated?: boolean;
  NextContinuationToken?: string;
};

function fakeClient(pages: ListPage[]): {
  client: PrefixDeleteClient;
  lists: ListObjectsV2Command[];
  deletes: DeleteObjectsCommand[];
} {
  const lists: ListObjectsV2Command[] = [];
  const deletes: DeleteObjectsCommand[] = [];
  let index = 0;
  const client: PrefixDeleteClient = {
    async send(command: unknown) {
      if (command instanceof ListObjectsV2Command) {
        lists.push(command);
        return pages[index++] ?? { Contents: [] };
      }
      if (command instanceof DeleteObjectsCommand) {
        deletes.push(command);
        return {};
      }
      throw new Error("unexpected command");
    },
  };
  return { client, lists, deletes };
}

describe("createR2PrefixDeleter (H2)", () => {
  it("lists every page and deletes every object under the prefix", async () => {
    const { client, lists, deletes } = fakeClient([
      {
        Contents: [{ Key: "users/u1/a" }, { Key: "users/u1/b" }],
        IsTruncated: true,
        NextContinuationToken: "page-2",
      },
      { Contents: [{ Key: "users/u1/c" }], IsTruncated: false },
    ]);
    await createR2PrefixDeleter(cfg, client).deletePrefix("users/u1/");

    expect(lists).toHaveLength(2);
    expect(lists[0]!.input).toMatchObject({ Bucket: "bucket", Prefix: "users/u1/" });
    expect(lists[0]!.input.ContinuationToken).toBeUndefined();
    expect(lists[1]!.input.ContinuationToken).toBe("page-2");

    expect(deletes).toHaveLength(2);
    expect(deletes.map((d) => d.input.Delete?.Objects)).toEqual([
      [{ Key: "users/u1/a" }, { Key: "users/u1/b" }],
      [{ Key: "users/u1/c" }],
    ]);
    expect(deletes[0]!.input.Delete?.Quiet).toBe(true);
  });

  it("splits a >1000-key page into DeleteObjects batches", async () => {
    const keys = Array.from({ length: 1001 }, (_, i) => ({ Key: `users/u1/${i}` }));
    const { client, deletes } = fakeClient([{ Contents: keys, IsTruncated: false }]);
    await createR2PrefixDeleter(cfg, client).deletePrefix("users/u1/");
    expect(deletes).toHaveLength(2);
    expect(deletes[0]!.input.Delete?.Objects).toHaveLength(1000);
    expect(deletes[1]!.input.Delete?.Objects).toHaveLength(1);
  });

  it("is a no-op for an empty prefix (idempotent replay)", async () => {
    const { client, deletes } = fakeClient([{ Contents: [], IsTruncated: false }]);
    await expect(
      createR2PrefixDeleter(cfg, client).deletePrefix("users/gone/"),
    ).resolves.toBeUndefined();
    expect(deletes).toHaveLength(0);
  });

  it("fails loudly on a truncated page without a continuation token", async () => {
    const { client } = fakeClient([{ Contents: [{ Key: "users/u1/a" }], IsTruncated: true }]);
    await expect(
      createR2PrefixDeleter(cfg, client).deletePrefix("users/u1/"),
    ).rejects.toThrow(/continuation token/);
  });

  it("builds from env only when all four R2 vars are present", () => {
    expect(createR2PrefixDeleterFromEnv({})).toBeNull();
    expect(
      createR2PrefixDeleterFromEnv({
        OVID_R2_ACCOUNT_ID: "a",
        OVID_R2_ACCESS_KEY_ID: "b",
        OVID_R2_SECRET_ACCESS_KEY: "c",
      }),
    ).toBeNull();
    const built = createR2PrefixDeleterFromEnv({
      OVID_R2_ACCOUNT_ID: "a",
      OVID_R2_ACCESS_KEY_ID: "b",
      OVID_R2_SECRET_ACCESS_KEY: "c",
      OVID_R2_BUCKET: "bucket",
    });
    expect(built).not.toBeNull();
    expect(typeof built!.deletePrefix).toBe("function");
  });
});
