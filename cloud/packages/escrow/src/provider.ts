/**
 * Worker-side BYOK decryption provider (P9 Task 11).
 *
 * Implements the Task-9 `ByokKeyProvider` contract (the interface is pinned
 * here until @ovid/shared carries it): resolve an owned, active BYOK row and
 * decrypt its API key. Every failure — unknown id, wrong owner, inactive row,
 * envelope auth failure, DB error — resolves to `null` (logged, never thrown
 * into runs): a bad BYOK key must degrade to the normal key path, not kill a
 * run with an infrastructure error.
 */

import { byokKeysRepo, type Db } from "@ovid/db";
import { EnvelopeAuthError, type EnvelopeCrypto } from "./envelope.js";

export interface ByokKeyProvider {
  getDecrypted(
    byokKeyId: string,
    uid: string,
  ): Promise<{ providerId: string; endpoint: string; apiKey: string } | null>;
}

/** The ONE recordId convention for BYOK envelopes (AAD binding). */
export function byokRecordId(id: string): string {
  return `byok_keys:${id}`;
}

export interface ByokKeyProviderOptions {
  /** Sink for sanitized diagnostics; defaults to console.warn. */
  log?: (message: string, detail?: unknown) => void;
}

export function createByokKeyProvider(
  db: Db,
  crypto: EnvelopeCrypto,
  opts: ByokKeyProviderOptions = {},
): ByokKeyProvider {
  const log =
    opts.log ??
    ((message: string, detail?: unknown) => {
      console.warn(`[escrow] ${message}`, detail ?? "");
    });

  return {
    async getDecrypted(byokKeyId: string, uid: string) {
      try {
        const row = await byokKeysRepo.get(db, byokKeyId, uid);
        if (row === null) return null; // unknown id OR wrong owner — same answer
        if (row.status === "inactive") return null;

        try {
          const apiKey = crypto.decrypt(
            {
              wrappedDek: row.wrappedDek,
              iv: row.iv,
              ciphertext: row.ciphertext,
              tag: row.tag,
            },
            byokRecordId(row.id),
          );
          return { providerId: row.providerId, endpoint: row.endpoint, apiKey };
        } catch (err) {
          if (err instanceof EnvelopeAuthError) {
            // Tampered/rotated-key row: never surface the envelope or key.
            log("byok envelope failed authentication", { id: row.id, uid });
            return null;
          }
          throw err;
        }
      } catch (err) {
        log("byok key lookup failed", {
          id: byokKeyId,
          uid,
          error: err instanceof Error ? err.message : "unknown",
        });
        return null;
      }
    },
  };
}
