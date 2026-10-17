/**
 * Key-provisioning contracts shared by the gateway, the worker and the mint
 * service (implementations live in `apps/gateway/src/keys.ts`,
 * `apps/gateway/src/internalMint.ts`, `apps/worker/src/keyResolver.ts` and
 * `apps/mint/src/internalRoutes.ts`).
 *
 * Controller ruling: the INTERFACES live here in @ovid/shared so the worker
 * never imports from an app package; implementations stay in the apps. This
 * module is NOT types-only: `MintInternalError` is a runtime class (the
 * gateway relays its `status`/`body` to the caller), and the P9 Task 9
 * HMAC helpers live beside it in `internalAuth.ts`.
 */

/**
 * Reads a user's provisioned model key from the mint service's Redis
 * (mint db2 — the connection URL carries the db selector, so implementations
 * do a plain `GET user:{uid}:key`). null = the user has no key yet.
 *
 * P9 Task 9 note: the worker's production path now resolves through
 * `KeyResolver` (below); this narrow read-only contract remains for the
 * P3 `litellmKeyResolver` seam and pre-P9 compositions.
 */
export interface KeyProvider {
  getKeyForUser(uid: string): Promise<string | null>;
}

/**
 * LEGACY (pre-P9 Task 9): forwarding the caller's Firebase identity to the
 * public mint service. The gateway no longer uses this contract — it calls
 * `InternalMintProvisioner` with its OWN verified principal instead. Kept so
 * the P0/P1 e2e compositions that still stub it keep compiling.
 */
export interface MintProvisioner {
  ensureKey(idToken: string, appCheck: string | null): Promise<{ key: string }>;
}

/**
 * A fully-resolved credential for one run (P9 Task 9).
 *
 * - `litellm`: a LiteLLM virtual key read from mint's db2 projection, or one
 *   minted through the signed internal endpoint. `baseUrl` is the LiteLLM
 *   origin (never a user-supplied URL).
 * - `byok`: a decrypted BYOK record. `endpoint` is the escrow-canonicalized
 *   provider endpoint — the worker re-validates it at USE time (SSRF) and
 *   NEVER adds it to the trusted provider-origin allowlist.
 */
export type ResolvedKey =
  | { kind: "litellm"; key: string; baseUrl: string }
  | {
      kind: "byok";
      byokKeyId: string;
      providerId: string;
      endpoint: string;
      apiKey: string;
    };

/**
 * The worker's per-run key resolution seam.
 *
 * `ctx.unattended` gates the internal mint call: an attended run with no
 * provisioned key keeps P4's `key_not_minted` contract (the client can mint
 * through the gateway), while an unattended run (scheduler) may mint
 * server-to-server. A referenced `byokKeyId` that cannot be decrypted
 * resolves to null — never a silent fallback to Ovid's LiteLLM key.
 */
export interface KeyResolver {
  resolveForRun(
    uid: string,
    ctx: { unattended: boolean; byokKeyId?: string | null },
  ): Promise<ResolvedKey | null>;
}

/**
 * The gateway → mint server-to-server provisioning contract (P9 Task 9).
 * The caller is authenticated by a per-request HMAC (see internalAuth.ts);
 * `uid` is the gateway's OWN verified principal — no client token crosses
 * this boundary.
 */
export interface InternalMintProvisioner {
  ensureKeyForUid(
    uid: string,
    opts?: { platform?: "android" | "web" },
  ): Promise<{ key: string; tier: string; baseUrl: string }>;
}

/**
 * A non-2xx response from the internal mint endpoint, carrying the status
 * and parsed body so the gateway can relay billing/rate-limit envelopes
 * (402/429) to the caller verbatim.
 */
export class MintInternalError extends Error {
  readonly status: number;
  readonly body: unknown;

  constructor(status: number, body: unknown) {
    super(`internal mint responded with HTTP ${status}`);
    this.name = "MintInternalError";
    this.status = status;
    this.body = body;
  }
}

/**
 * Decrypted BYOK credential lookup (implemented by P9 Task 11's
 * `@ovid/escrow` provider). Every failure resolves to null; the caller
 * decides what a missing record means (the worker fails the run).
 */
export interface ByokKeyProvider {
  getDecrypted(
    byokKeyId: string,
    uid: string,
  ): Promise<{ providerId: string; endpoint: string; apiKey: string } | null>;
}
