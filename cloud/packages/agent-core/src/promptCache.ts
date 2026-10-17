// Prompt-cache-stable prefix (port of lib/core/prompt_cache.dart — pure part).
//
// Long agent sessions resend system prompt + tool schemas + history every
// turn. This module keeps that prefix byte-stable and places at most
// MAX_CACHE_BREAKPOINTS marks for providers that need explicit markers
// (Anthropic native; Claude behind LiteLLM/OpenRouter-style proxies).
// Providers that cache a stable prefix automatically (OpenAI, Gemini,
// DeepSeek...) get no markers, only the stable ordering.
//
// Pure functions only: no I/O. Mirrors the Dart structure — the request-body
// mutation halves of the Dart module (applyOpenAi/applyAnthropic) live in the
// transports (Task 5) / engine wiring (Task 15, ruling R3) instead; here the
// marks are typed domain state on AgentMessage.cacheControl (Task 1's home —
// no separate CacheMark interface).

import type { AgentMessage, PromptCacheMode, ToolSpec } from "./types.js";

/// Anthropic allows at most four breakpoints per request.
export const MAX_CACHE_BREAKPOINTS = 4;

// ── override parsing (Provider settings) ───────────────────────────────────

export type PromptCacheOverride = "auto" | "on" | "off";

/** Per-provider user override; unknown values fall back to "auto". */
export function parsePromptCacheOverride(
  raw: string | null | undefined,
): PromptCacheOverride {
  const v = (raw ?? "").trim().toLowerCase();
  return v === "on" || v === "off" ? v : "auto";
}

// ── capability gating ───────────────────────────────────────────────────────

/**
 * Which caching strategy a route uses (Dart `PromptCache.resolve` collapsed
 * onto the facts the cloud actually has — the gateway KNOWS its routes, so
 * model-name sniffing and host parsing become the single `isNativeAnthropic`
 * claude-route marker).
 *
 * Matrix (Dart-faithful; see prompt_cache.dart `resolve`):
 * - "off" → "none"                                  (Dart: override off / global off)
 * - apiFormat "anthropic" + on/auto → "anthropicNative"  (Dart: the FORMAT check
 *   alone decides — an anthropic-format endpoint speaks the Messages API,
 *   which defines cache_control; `isNativeAnthropic` carries no extra meaning
 *   for this branch)
 * - apiFormat "openai" + "on" → "openaiBlocks"      (Dart: explicit on forces
 *   blocks on ANY openai-format endpoint — "unknown / custom endpoints never
 *   receive markers unless the user turns them on for that provider")
 * - apiFormat "openai" + claude-route marker + "auto" → "openaiBlocks"
 *   (B3 RULING: Dart's auto branch returns openaiBlocks for a KNOWN Claude
 *   route — `claude && (isOvidCloud || openRouter)` — and the marker stands
 *   for exactly that "known Claude route behind an openai-format proxy" fact.
 *   Dart's logic therefore covers this case and dictates openaiBlocks, NOT
 *   implicit; pinned in promptCache.test.ts)
 * - else → "implicit"                               (stable ordering only)
 */
export function cacheModeFor(
  apiFormat: "openai" | "anthropic",
  isNativeAnthropic: boolean,
  override: PromptCacheOverride,
): PromptCacheMode {
  if (override === "off") return "none";
  if (apiFormat === "anthropic") return "anthropicNative";
  if (override === "on") return "openaiBlocks";
  if (isNativeAnthropic) return "openaiBlocks";
  return "implicit";
}

// ── stable serialisation ────────────────────────────────────────────────────

/** The typed mark — exactly AgentMessage["cacheControl"] (Task 1's home). */
export type CacheControlMark = NonNullable<AgentMessage["cacheControl"]>;

/**
 * A tool spec carrying a mark. Additive over `ToolSpec` (Task 1's frozen
 * contract has no cacheControl field on tools); the transports (Task 5)
 * serialize it as `cache_control` on the tool definition, mirroring Dart's
 * `{...tool, 'cache_control': cc}`.
 */
export interface MarkedToolSpec extends ToolSpec {
  cacheControl?: CacheControlMark;
}

/** Recursively key-sorted copy (object key order is not semantic JSON). */
function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value !== null && typeof value === "object") {
    const src = value as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(src).sort()) out[k] = canonicalize(src[k]);
    return out;
  }
  return value;
}

/**
 * THE canonical serializer: JSON.stringify over a recursively key-sorted
 * copy. Byte-identical for any two objects differing only in key order;
 * arrays keep their order (semantic). Task 14 reuses this for guard
 * canonArgs — it must stay a standalone, dependency-free function.
 */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(canonicalize(value));
}

/**
 * Tools sorted by name (byte-stable order; ties keep input order — Dart's
 * index tiebreak, which JS's stable sort provides) with canonical key order,
 * so the serialised roster is identical turn to turn regardless of plugin /
 * MCP load order. Inputs are not mutated.
 */
export function canonicalTools(tools: readonly ToolSpec[]): ToolSpec[] {
  return [...tools]
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
    .map((t) => canonicalize(t) as ToolSpec);
}

/**
 * The byte-stability contract for the tool roster: canonicalJson over the
 * canonical (name-sorted) tools. Identical to `canonicalJson(tools)` when the
 * roster is already canonical; load-order independent otherwise.
 */
export function canonicalToolJson(tools: readonly ToolSpec[]): string {
  return canonicalJson(canonicalTools(tools));
}

// ── breakpoint placement ────────────────────────────────────────────────────

const MARK: CacheControlMark = { type: "ephemeral" }; // no ttl → provider 5m default

/** Dart `_hasContent`: a row without content can't carry a breakpoint. */
function hasContent(m: AgentMessage): boolean {
  return typeof m.content === "string" && m.content.trim() !== "";
}

/** Copy with a mark (existing marks are kept verbatim → idempotent). */
function withMark<T extends { cacheControl?: CacheControlMark }>(m: T): T {
  return m.cacheControl ? m : { ...m, cacheControl: { ...MARK } };
}

/**
 * Places at most MAX_CACHE_BREAKPOINTS marks, last-first: the final tool,
 * the final non-volatile system block, then the last two non-volatile
 * content-bearing messages (the rolling tail — Dart's `messageMarks` picks
 * collapse to exactly these two under the volatile-rides-last invariant,
 * Task 7's ordering).
 *
 * Volatile rows (`volatile: true`) are NEVER marked — including a trailing
 * one. (Dart deviation, mandated by the plan: Dart's `messageMarks` can mark
 * a trailing volatile row because its eligibility check doesn't exclude them;
 * its tests only assert `marks.last`. The TS contract pins the intended
 * behavior instead.)
 *
 * Marks live on `AgentMessage.cacheControl` / `MarkedToolSpec.cacheControl`
 * and the transports serialize them (Task 5: anthropic `cache_control`
 * blocks; openai-format: the stable prefix rides LiteLLM's prompt cache via
 * the `prompt_cache_key` header — Task 15 wiring, ruling R3).
 *
 * Returns marked COPIES; inputs are not mutated. Idempotent: marking
 * already-marked input yields a deep-equal result. Callers apply `canonicalTools`
 * first (ruling R3's pipeline) — the tool mark lands on the last tool of the
 * roster as given.
 */
export function markCacheBreakpoints(
  system: readonly AgentMessage[],
  messages: readonly AgentMessage[],
  tools: readonly ToolSpec[],
): { system: AgentMessage[]; messages: AgentMessage[]; tools: MarkedToolSpec[] } {
  const outSystem: AgentMessage[] = [...system];
  const outMessages: AgentMessage[] = [...messages];
  const outTools: MarkedToolSpec[] = tools.map((t) => ({ ...t }));
  let used = 0;

  // 1. final tool
  if (outTools.length > 0) {
    const last = outTools[outTools.length - 1];
    outTools[outTools.length - 1] = withMark(last);
    used++;
  }

  // 2. final non-volatile, content-bearing system block
  if (used < MAX_CACHE_BREAKPOINTS) {
    for (let i = outSystem.length - 1; i >= 0; i--) {
      const m = outSystem[i];
      if (m.volatile || !hasContent(m)) continue;
      outSystem[i] = withMark(m);
      used++;
      break;
    }
  }

  // 3. last two non-volatile, content-bearing messages (budget-capped)
  const budget = Math.min(2, MAX_CACHE_BREAKPOINTS - used);
  let picked = 0;
  for (let i = outMessages.length - 1; i >= 0 && picked < budget; i--) {
    const m = outMessages[i];
    if (m.volatile || !hasContent(m)) continue;
    outMessages[i] = withMark(m);
    picked++;
  }

  return { system: outSystem, messages: outMessages, tools: outTools };
}
