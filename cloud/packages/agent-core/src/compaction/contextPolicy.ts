/**
 * Pure per-model context policy for automatic compaction.
 *
 * This module deliberately has no runtime, database, checkpoint, or fold
 * dependencies. Callers supply the actual selected model and the complete
 * JSON-ready provider request; later composition owns persistence and wiring.
 */

export interface ModelContextProfile {
  model: string;
  contextLimit: number;
  outputReserveTokens: number;
  providerReserveTokens: number;
}

export interface ContextUsage {
  usageSource: "measured" | "deterministic_fallback";
  beforeTokens: number;
}

export interface CompactionActor {
  sessionId: string;
  rootTaskRunId: string;
  logicalWorkerId: string | null;
  attemptId: string | null;
  kind: "main" | "worker";
}

/** The LiteLLM /model/info fields shared by the worker and mint catalog rows. */
export interface ModelContextCatalogRow {
  model_name?: string;
  model_info?: Record<string, unknown>;
  litellm_params?: Record<string, unknown>;
  [field: string]: unknown;
}

export type ConfiguredModelContextFallback = Omit<ModelContextProfile, "model">;

export interface ResolveModelContextProfileInput {
  /** Actual resolved route/deployment id, not an unresolved auto alias. */
  model: string;
  catalog: readonly ModelContextCatalogRow[] | null;
  /** Operator-supplied conservative values used only where metadata is unknown. */
  fallback: ConfiguredModelContextFallback;
  /** AgentRequest.maxTokens, when the run configured one. */
  requestMaxOutputTokens?: number;
}

export interface CompactionBoundary {
  /** True only at the pre-model-request checkpoint, never inside a response. */
  beforeModelRequest: boolean;
  /** Every issued call has a terminal result (success, error, or cancellation). */
  toolCallsTerminal: boolean;
  /** Every requested approval has a terminal decision or terminal cancellation. */
  approvalsTerminal: boolean;
}

export interface CompactionDecisionInput {
  profile: ModelContextProfile;
  usage: ContextUsage;
  boundary: CompactionBoundary;
}

export interface DeterministicFallbackOptions {
  /**
   * Configured per-image upper bound for the selected provider/model. Image
   * tokenization cannot be inferred from base64 length. Without this bound, an
   * image-bearing fallback is saturated and the next-request budget fails closed.
   */
  imageTokenUpperBound?: number;
}

export interface NextRequestBudgetInput {
  profile: ModelContextProfile;
  usage: ContextUsage;
}

function positiveInteger(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0
    ? value
    : null;
}

function nonNegativeInteger(value: unknown): number | null {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0
    ? value
    : null;
}

function normalizedModel(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  return normalized === "" ? null : normalized;
}

/**
 * Resolve only exact public-model or underlying-deployment metadata. Multiple
 * matches are ambiguous (notably an unresolved auto group), so the configured
 * fallback wins rather than arbitrarily crediting one deployment's capacity.
 */
export function resolveModelContextProfile(
  input: ResolveModelContextProfileInput,
): ModelContextProfile {
  const selected = normalizedModel(input.model);
  const matches = (input.catalog ?? []).filter((row) => {
    const publicName = normalizedModel(row.model_name);
    const underlying = normalizedModel(row.litellm_params?.model);
    return selected !== null && (publicName === selected || underlying === selected);
  });
  const row = matches.length === 1 ? matches[0] : undefined;
  const info = row?.model_info;

  const contextLimit =
    positiveInteger(info?.max_input_tokens) ??
    positiveInteger(info?.max_tokens) ??
    input.fallback.contextLimit;
  const modelOutputReserve = positiveInteger(info?.max_output_tokens);
  const requestOutputReserve = positiveInteger(input.requestMaxOutputTokens);
  const outputReserveTokens =
    requestOutputReserve === null
      ? (modelOutputReserve ?? input.fallback.outputReserveTokens)
      : modelOutputReserve === null
        ? requestOutputReserve
        : Math.min(requestOutputReserve, modelOutputReserve);

  return {
    model: input.model,
    contextLimit,
    outputReserveTokens,
    providerReserveTokens:
      nonNegativeInteger(info?.provider_reserve_tokens) ??
      input.fallback.providerReserveTokens,
  };
}

function serializedMessageCount(request: unknown): number {
  if (typeof request !== "object" || request === null) return 0;
  const body = request as { system?: unknown; messages?: unknown };
  const system = Array.isArray(body.system)
    ? body.system.length
    : body.system === undefined || body.system === null
      ? 0
      : 1;
  const messages = Array.isArray(body.messages) ? body.messages.length : 0;
  return system + messages;
}

/** Count internal and common provider image parts without double-counting wrappers. */
function serializedImageCount(value: unknown, field?: string): number {
  if (Array.isArray(value)) {
    if (field === "images") return value.length;
    return value.reduce((count, item) => count + serializedImageCount(item), 0);
  }
  if (typeof value !== "object" || value === null) return 0;

  const row = value as Record<string, unknown>;
  if (row.type === "image" || row.type === "image_url" || row.type === "input_image") {
    return 1;
  }
  if ((field === "inline_data" || field === "inlineData") && typeof row.data === "string") {
    return 1;
  }
  return Object.entries(row).reduce(
    (count, [key, child]) => count + serializedImageCount(child, key),
    0,
  );
}

const UNKNOWN_CONTEXT_TOKENS = Number.MAX_SAFE_INTEGER;
const MAX_SAFE_BIGINT = BigInt(UNKNOWN_CONTEXT_TOKENS);

function clampToSafeInteger(value: bigint): number {
  return value >= MAX_SAFE_BIGINT ? UNKNOWN_CONTEXT_TOKENS : Number(value);
}

/**
 * Use exact provider prompt usage when supplied. Otherwise charge one token per
 * serialized UTF-8 byte plus request/message framing. That byte-fallback policy
 * bound covers adversarial dense text without assuming four bytes per token; it
 * is deliberately not a provider-tokenizer or provider-exact claim.
 *
 * Image token cost is model-specific and cannot be inferred from base64 bytes.
 * The caller must supply a configured per-image upper bound. Unknown image cost
 * saturates the fallback, and nextRequestWithinLimit refuses that request.
 */
export function contextUsageFor(
  request: unknown,
  measuredInputTokens?: number | null,
  fallback: DeterministicFallbackOptions = {},
): ContextUsage {
  const measured = nonNegativeInteger(measuredInputTokens);
  if (measured !== null) {
    return { usageSource: "measured", beforeTokens: measured };
  }

  const serialized = JSON.stringify(request);
  if (serialized === undefined) {
    throw new TypeError("context request must be JSON-serializable");
  }
  const imageCount = serializedImageCount(request);
  const imageTokenUpperBound = nonNegativeInteger(fallback.imageTokenUpperBound);
  if (imageCount > 0 && imageTokenUpperBound === null) {
    return {
      usageSource: "deterministic_fallback",
      beforeTokens: UNKNOWN_CONTEXT_TOKENS,
    };
  }

  const contentBound = BigInt(Buffer.byteLength(serialized, "utf8"));
  const framingBound = 4n + 4n * BigInt(serializedMessageCount(request));
  const imageBound = BigInt(imageCount) * BigInt(imageTokenUpperBound ?? 0);
  return {
    usageSource: "deterministic_fallback",
    beforeTokens: clampToSafeInteger(contentBound + framingBound + imageBound),
  };
}

/**
 * Fail-closed budget predicate for the exact next request. Recompute usage after
 * any fold, then include output and provider reserves before sending. `true` is
 * a configured conservative-budget result, never a provider-exact usage claim.
 */
export function nextRequestWithinLimit(input: NextRequestBudgetInput): boolean {
  const contextLimit = positiveInteger(input.profile.contextLimit);
  const beforeTokens = nonNegativeInteger(input.usage.beforeTokens);
  const outputReserve = nonNegativeInteger(input.profile.outputReserveTokens);
  const providerReserve = nonNegativeInteger(input.profile.providerReserveTokens);
  if (
    contextLimit === null ||
    beforeTokens === null ||
    outputReserve === null ||
    providerReserve === null ||
    (input.usage.usageSource === "deterministic_fallback" &&
      beforeTokens === UNKNOWN_CONTEXT_TOKENS)
  ) {
    return false;
  }
  return (
    BigInt(beforeTokens) + BigInt(outputReserve) + BigInt(providerReserve) <=
    BigInt(contextLimit)
  );
}

export function isSafeCompactionBoundary(boundary: CompactionBoundary): boolean {
  return (
    boundary.beforeModelRequest &&
    boundary.toolCallsTerminal &&
    boundary.approvalsTerminal
  );
}

/**
 * Integer-only 80% trigger. Reserves stay in the profile for downstream request
 * budgeting; the Task 9 pressure contract compares beforeTokens with the raw
 * per-model contextLimit and never applies the legacy universal 100,000 cap.
 */
export function shouldCompact(input: CompactionDecisionInput): boolean {
  return (
    isSafeCompactionBoundary(input.boundary) &&
    BigInt(input.usage.beforeTokens) * 100n >= BigInt(input.profile.contextLimit) * 80n
  );
}
