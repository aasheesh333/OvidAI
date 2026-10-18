/**
 * Model image-capability detection (owner directive 2026-10-18).
 *
 * The agent can now attach images to a prompt (browser screenshots, UI
 * snapshots, image attachments). A provider that cannot take them either
 * errors mid-run or silently drops the visual context, and the user sees a
 * confusing failure after paying for a partial run. So the WORKER asks this
 * module BEFORE the run starts, and refuses with a clear, actionable message
 * plus a push notification when the selected model cannot see.
 *
 * Resolution order (first decisive answer wins):
 *   1. LiteLLM `model_info.supports_vision` when the proxy publishes it —
 *      `true` accepts, `false` rejects. This is the operator's own catalog
 *      and outranks any list we ship.
 *   2. A static family list for the models this deployment actually routes
 *      (the same shape the Dart client used: family prefixes, conservative
 *      on anything unrecognised).
 *   3. Unknown ⇒ **false**. A model nobody has vouched for must not be handed
 *      an image: the failure mode of guessing "yes" is a broken run, the
 *      failure mode of guessing "no" is a clear error the user can act on.
 *
 * Deliberately NOT here: a network probe. The catalog is already in memory
 * (the mint's `modelInfo()` rows), and a per-run HTTP round-trip on the hot
 * path would add latency to every prompt to answer a question that changes
 * only when the operator edits the catalog.
 */

/** The subset of a LiteLLM `/model/info` row this module reads. */
export interface ModelCapabilityRow {
  model_name?: string;
  model_info?: Record<string, unknown>;
  [field: string]: unknown;
}

/**
 * Families known to accept image inputs. Matched as a lowercased SUBSTRING so
 * an aggregator prefix (`openai/gpt-4o`, `azure/gpt-4o-mini`, `anthropic/…`)
 * still matches. Keep this list to families whose vision support is a
 * documented property of the model, not a per-deployment option.
 */
const VISION_FAMILIES: readonly string[] = [
  // [OI]
  "gpt-4o",
  "gpt-4.1",
  "gpt-4-turbo",
  "gpt-4-vision",
  "gpt-5",
  "o3",
  "o4",
  // Anthropic
  "claude-3",
  "claude-4",
  "claude-5",
  "claude-sonnet",
  "claude-opus",
  "claude-haiku",
  // Google
  "gemini-1.5",
  "gemini-2",
  "gemini-3",
  // Others commonly routed here
  "glm-4v",
  "glm-4.5v",
  "glm-5v",
  "qwen-vl",
  "qwen2-vl",
  "qwen2.5-vl",
  "llava",
  "pixtral",
  "internvl",
  "minicpm-v",
  "grok-2-vision",
  "grok-4",
];

/**
 * Families that look like a vision family but are TEXT-ONLY. Checked first so
 * `gpt-4o-mini`-style substrings cannot be over-matched by a broader entry.
 */
const TEXT_ONLY_OVERRIDES: readonly string[] = [
  "deepseek-v4",
  "deepseek-chat",
  "deepseek-reasoner",
  "glm-5.3-flash",
  "glm-5.3",
];

export interface VisionDecision {
  supports: boolean;
  /** Why, for the run log and the push body. Never a secret. */
  basis: "catalog" | "family" | "unknown";
}

/**
 * Decide whether [model] can accept image input, given the LiteLLM catalog
 * rows (or null when the catalog could not be read).
 */
export function modelVisionSupport(
  model: string,
  catalog: readonly ModelCapabilityRow[] | null,
): VisionDecision {
  const name = model.trim().toLowerCase();
  if (name === "") return { supports: false, basis: "unknown" };

  // 1. The operator's own catalog is authoritative when it says anything.
  const row = catalog?.find(
    (r) => typeof r.model_name === "string" && r.model_name.toLowerCase() === name,
  );
  const flag = row?.model_info?.["supports_vision"];
  if (flag === true) return { supports: true, basis: "catalog" };
  if (flag === false) return { supports: false, basis: "catalog" };

  // 2. Text-only overrides beat the family list (a "gpt-4o"-shaped name that
  //    the operator knows is text-only must not be treated as multimodal).
  for (const family of TEXT_ONLY_OVERRIDES) {
    if (name.includes(family)) return { supports: false, basis: "family" };
  }

  // 3. Documented vision families.
  for (const family of VISION_FAMILIES) {
    if (name.includes(family)) return { supports: true, basis: "family" };
  }

  // 4. Unknown models are refused rather than guessed.
  return { supports: false, basis: "unknown" };
}

/** The exact user-facing copy (pinned; the push body and the run log share it). */
export function visionRefusalMessage(model: string): string {
  return (
    `Custom Model Error: Selected model '${model}' does not support vision/image inputs ` +
    `required for this action. Please switch to a vision-capable model (e.g. Gemini, ` +
    `GPT-4o, the model) or remove the image context.`
  );
}

/** Image MIME types the agent will forward to a model. */
const IMAGE_EXTENSIONS: Readonly<Record<string, string>> = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  webp: "image/webp",
  gif: "image/gif",
};

/**
 * The MIME type for an attachment NAME, or null when it is not an image.
 * Attachments carry no MIME column (P8 Task 3), so the extension is the only
 * signal — and an unknown extension is simply not an image, never a guess.
 */
export function imageMimeTypeFor(name: string): string | null {
  const dot = name.lastIndexOf(".");
  if (dot < 0) return null;
  const ext = name.slice(dot + 1).toLowerCase();
  return IMAGE_EXTENSIONS[ext] ?? null;
}

/**
 * A cached reader for LiteLLM's `/model/info`, used only when a run carries
 * images. The catalog changes when the operator edits it, not per prompt, so a
 * short TTL keeps the hot path free of an HTTP round-trip while still picking
 * up an operator's edit within a few minutes.
 *
 * Never throws: a catalog outage falls back to the static family list rather
 * than blocking every image run on the proxy being reachable.
 */
export interface ModelCatalogReader {
  (): Promise<readonly ModelCapabilityRow[] | null>;
}

export function createModelCatalogReader(opts: {
  baseUrl: string;
  masterKey: string;
  /** Default 5 minutes. */
  ttlMs?: number;
  fetchImpl?: typeof fetch;
  now?: () => number;
}): ModelCatalogReader {
  const ttl = opts.ttlMs ?? 300_000;
  const now = opts.now ?? Date.now;
  const doFetch = opts.fetchImpl ?? fetch;
  let cached: { at: number; rows: readonly ModelCapabilityRow[] } | null = null;
  let inFlight: Promise<readonly ModelCapabilityRow[] | null> | null = null;

  return async function read(): Promise<readonly ModelCapabilityRow[] | null> {
    if (cached !== null && now() - cached.at < ttl) return cached.rows;
    if (inFlight !== null) return inFlight;
    inFlight = (async () => {
      try {
        const res = await doFetch(`${opts.baseUrl.replace(/\/+$/, "")}/model/info`, {
          method: "GET",
          headers: { authorization: `Bearer ${opts.masterKey}` },
          signal: AbortSignal.timeout(5_000),
        });
        if (!res.ok) return null;
        const body = (await res.json()) as { data?: unknown } | null;
        const data = body?.data;
        if (!Array.isArray(data)) return null;
        const rows = data.filter(
          (r): r is ModelCapabilityRow => typeof r === "object" && r !== null,
        );
        cached = { at: now(), rows };
        return rows;
      } catch {
        return null;
      } finally {
        inFlight = null;
      }
    })();
    return inFlight;
  };
}
