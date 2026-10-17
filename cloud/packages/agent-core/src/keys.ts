// keys.ts — THE BYOK SEAM.
//
// P3 resolves LiteLLM virtual keys: `litellmKeyResolver` reads a user's
// provisioned key through the @ovid/shared `KeyProvider` (the mint service's
// Redis — P1 ledger ruling) and stamps the LiteLLM gateway base URL on it.
//
// P9 swaps in the escrow resolver (byok_keys table, envelope-decrypted) as
// JUST a new `KeyResolver` implementation — routing (routing.ts) and the
// transports (Task 5) are untouched. That is the entire point of this seam:
// the two `ResolvedKey` kinds below are the complete vocabulary routing knows
// about, and every route decision downstream keys off `kind` + the fields
// carried here, never off where the key came from.

import type { KeyProvider } from "@ovid/shared";

import { AUTO_ALIASES } from "./routing.js";

/**
 * A fully-resolved provider credential. `byok-anthropic` baseUrl defaults to
 * https://api.anthropic.com (set by the resolver that mints it — P9).
 */
export type ResolvedKey =
  | { kind: "litellm"; apiKey: string; baseUrl: string; model: string }
  | { kind: "byok-anthropic"; apiKey: string; baseUrl: string; model: string };

/**
 * Resolves the key a user's run rides on. null = the user has no usable key
 * (P1 contract: the run fails as run_failed key_not_minted — routing turns
 * a null key into a null route; it never invents a fallback credential).
 */
export interface KeyResolver {
  resolve(userId: string, requestedModel: string): Promise<ResolvedKey | null>;
}

/**
 * The P3 resolver: LiteLLM virtual keys. `requestedModel` in AUTO_ALIASES or
 * empty → defaultModel (the gateway's fleet default); kind is always
 * "litellm". A null key from the provider → null.
 */
export function litellmKeyResolver(deps: {
  keys: KeyProvider;
  baseUrl: string;
  defaultModel: string;
}): KeyResolver {
  return {
    async resolve(userId, requestedModel) {
      const apiKey = await deps.keys.getKeyForUser(userId);
      if (apiKey === null) return null;
      const requested = requestedModel.trim();
      const model =
        requested === "" || (AUTO_ALIASES as readonly string[]).includes(requested)
          ? deps.defaultModel
          : requested;
      return { kind: "litellm", apiKey, baseUrl: deps.baseUrl, model };
    },
  };
}
