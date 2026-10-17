// routing.ts — provider routing for the `auto` alias (port of the route
// resolution half of lib/core/agent_service.dart `_requestRoute` +
// `ApiFormat.parse`, collapsed onto the cloud's KeyResolver seam).
//
// Pure resolution: given the run's requested model and the session preset's
// G3 pins (presets.dart), pick the winning model, strip its effort suffix,
// resolve the user's key through the KeyResolver seam (keys.ts — THE BYOK
// SEAM), and shape the result into the transport-facing ResolvedRoute the
// engine (Task 15 wiring) hands to the Task-5 transports. Null key → null
// route → run_failed key_not_minted (P1 contract); no synthetic fallbacks.

import type { KeyResolver } from "./keys.js";
import { cacheModeFor, type PromptCacheOverride } from "./promptCache.js";
import type { PromptCacheMode } from "./types.js";

/** The picker's Auto entries — bare and fully-qualified (state.dart seeds 'auto'). */
export const AUTO_ALIASES = ["auto", "ovid-cloud/auto"] as const;

const EFFORT_SUFFIX = /·\s*(low|medium|high)$/i; // Dart: RegExp(r'·\s*(low|medium|high)$', caseSensitive: false)

/**
 * Strips the effort suffix (e.g. "gpt-5.2 · High") into the real model id +
 * lowercased effort (agent_service.dart ~13938). No suffix → effort null,
 * model unchanged. The suffix is parsed off whichever model WINS the
 * precedence chain below — never off the loser.
 */
export function parseModelEffort(raw: string): {
  model: string;
  effort: "low" | "medium" | "high" | null;
} {
  const m = EFFORT_SUFFIX.exec(raw);
  if (m === null) return { model: raw, effort: null };
  return {
    model: raw.slice(0, m.index).trim(),
    effort: m[1].toLowerCase() as "low" | "medium" | "high",
  };
}

export interface RouteRequest {
  userId: string;
  requestedModel: string | null;
  /** presets.dart G3: the preset's optional model pin and temperature. */
  preset?: { model?: string | null; temperature?: number | null } | null;
}

export interface ResolvedRoute {
  transportKind: "openai" | "anthropic";
  baseUrl: string;
  apiKey: string;
  model: string;
  effort: "low" | "medium" | "high" | null;
  temperature?: number; // present ONLY when the preset pinned one (G3 — never a synthetic default)
  cacheMode: PromptCacheMode;
}

/**
 * Precedence: preset.model pin (non-null, non-empty) > requestedModel >
 * AUTO alias / absent → defaultModel (the resolver applies the alias map).
 * The effort suffix is parsed off the winner; preset.temperature is carried
 * ONLY when non-null. byok-anthropic → anthropic transport +
 * cacheModeFor("anthropic", true, override); litellm → openai transport +
 * cacheModeFor("openai", false, override). Null key → null route.
 */
export async function resolveRoute(
  req: RouteRequest,
  deps: {
    keys: KeyResolver;
    litellmBaseUrl: string;
    defaultModel: string;
    cacheOverride?: PromptCacheOverride;
  },
): Promise<ResolvedRoute | null> {
  const pin = req.preset?.model;
  const winnerRaw =
    pin != null && pin.trim() !== "" ? pin : (req.requestedModel ?? "");
  const { model, effort } = parseModelEffort(winnerRaw);

  const key = await deps.keys.resolve(req.userId, model);
  if (key === null) return null;

  const override: PromptCacheOverride = deps.cacheOverride ?? "auto";
  const temperature = req.preset?.temperature ?? null;
  const shared = {
    baseUrl: key.kind === "litellm" ? key.baseUrl || deps.litellmBaseUrl : key.baseUrl,
    apiKey: key.apiKey,
    model: key.model,
    effort,
    ...(temperature !== null ? { temperature } : {}),
  };

  if (key.kind === "byok-anthropic") {
    return {
      transportKind: "anthropic",
      ...shared,
      cacheMode: cacheModeFor("anthropic", true, override),
    };
  }
  return {
    transportKind: "openai",
    ...shared,
    cacheMode: cacheModeFor("openai", false, override),
  };
}
