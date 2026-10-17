/**
 * Real R2 prefix deletion — the S3 `ListObjectsV2` + `DeleteObjects` primitive
 * P7's StorageAdapter never exposed (it has only single-key delete).
 *
 * P9 final review H2: account deletion wired `createNoopR2Deleter()`, so the
 * `workspaces`/`browser` cleanup stages "completed" while private objects
 * under `users/{uid}/` survived. This is the real deleter the composition
 * roots use when R2 is configured.
 *
 * Semantics:
 * - Lists every page under `prefix` (including a nested/continuation token)
 *   and deletes in ≤1000-key batches (the S3 DeleteObjects cap).
 * - `Quiet: true` keeps responses small; any failed key surfaces in the
 *   command error and fails the cleanup stage (retried by the lifecycle).
 * - A prefix with no objects is a no-op (idempotent replay after a crash).
 * - No key is logged; the caller passes a user-scoped prefix.
 */

import {
  DeleteObjectsCommand,
  ListObjectsV2Command,
  S3Client,
} from "@aws-sdk/client-s3";
import { r2Endpoint, type R2Config } from "./r2Adapter.js";

/** Structural seam for tests: the two SDK commands this module issues. */
export interface PrefixDeleteClient {
  send(command: unknown): Promise<{
    Contents?: Array<{ Key?: string }>;
    IsTruncated?: boolean;
    NextContinuationToken?: string;
  }>;
}

export interface R2PrefixDeleter {
  deletePrefix(prefix: string): Promise<void>;
}

/** S3 DeleteObjects accepts at most 1000 keys per request. */
const DELETE_BATCH = 1000;

export function createR2PrefixDeleter(
  cfg: R2Config,
  client?: PrefixDeleteClient,
): R2PrefixDeleter {
  const s3: PrefixDeleteClient =
    client ??
    new S3Client({
      region: "auto",
      endpoint: cfg.endpoint ?? r2Endpoint(cfg.accountId),
      credentials: {
        accessKeyId: cfg.accessKeyId,
        secretAccessKey: cfg.secretAccessKey,
      },
      maxAttempts: 4,
    });

  return {
    async deletePrefix(prefix: string): Promise<void> {
      let continuationToken: string | undefined;
      do {
        const listed = await s3.send(
          new ListObjectsV2Command({
            Bucket: cfg.bucket,
            Prefix: prefix,
            ContinuationToken: continuationToken,
          }),
        );
        const keys = (listed.Contents ?? [])
          .map((object) => object.Key)
          .filter((key): key is string => typeof key === "string" && key !== "")
          .map((key) => ({ Key: key }));
        for (let start = 0; start < keys.length; start += DELETE_BATCH) {
          await s3.send(
            new DeleteObjectsCommand({
              Bucket: cfg.bucket,
              Delete: { Objects: keys.slice(start, start + DELETE_BATCH), Quiet: true },
            }),
          );
        }
        continuationToken = listed.IsTruncated === true ? listed.NextContinuationToken : undefined;
        if (listed.IsTruncated === true && continuationToken === undefined) {
          throw new Error("R2 list returned a truncated page without a continuation token");
        }
      } while (continuationToken !== undefined);
    },
  };
}

/**
 * Build the deleter from the environment when all four R2 vars are present.
 * Returns null when R2 is not configured (the caller decides whether that is
 * acceptable — account deletion must not run without it in production).
 */
export function createR2PrefixDeleterFromEnv(
  env: NodeJS.ProcessEnv,
): R2PrefixDeleter | null {
  const required = [
    "OVID_R2_ACCOUNT_ID",
    "OVID_R2_ACCESS_KEY_ID",
    "OVID_R2_SECRET_ACCESS_KEY",
    "OVID_R2_BUCKET",
  ] as const;
  if (required.some((name) => (env[name] ?? "") === "")) return null;
  const endpoint = env.OVID_R2_ENDPOINT;
  return createR2PrefixDeleter({
    accountId: env.OVID_R2_ACCOUNT_ID!,
    accessKeyId: env.OVID_R2_ACCESS_KEY_ID!,
    secretAccessKey: env.OVID_R2_SECRET_ACCESS_KEY!,
    bucket: env.OVID_R2_BUCKET!,
    ...(endpoint !== undefined && endpoint !== "" ? { endpoint } : {}),
  });
}
