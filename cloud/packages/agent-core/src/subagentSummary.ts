// Subagent result contract (SI spec §9 / plan Task 8.10).
//
// A subagent NEVER returns its transcript to the parent. Its dispatch result
// is exactly one strict JSON object with these five keys:
//
//   {status, files_modified, artifacts_created, key_findings, error_if_any}
//
// and the serialized object is held to a HARD 300-token budget. Truncation is
// deterministic (same input → byte-identical output) and always leaves the
// marker `…[truncated]` behind, so a reader can tell a shortened finding from
// a complete one.
//
// TOKEN COUNT: agent-core must not depend on a provider tokenizer (dependency
// direction + lockfile rule), so the budget uses the standard deterministic
// approximation ceil(chars / 4) over the serialized JSON. It is an upper-bound
// estimate for English/JSON text and is stable across processes.

export const SUBAGENT_SUMMARY_KEYS = [
  "status",
  "files_modified",
  "artifacts_created",
  "key_findings",
  "error_if_any",
] as const;

export type SubagentSummaryKey = (typeof SUBAGENT_SUMMARY_KEYS)[number];

/** Terminal states a subagent can report. `running` is not a valid result. */
export type SubagentSummaryStatus = "completed" | "failed" | "cancelled" | "timeout";

export interface SubagentSummary {
  status: SubagentSummaryStatus;
  files_modified: string[];
  artifacts_created: string[];
  key_findings: string[];
  error_if_any: string | null;
}

export const SUBAGENT_SUMMARY_TOKEN_BUDGET = 300;

/**
 * The budget for a child that did NOT complete. A failed, stopped or
 * timed-out child never produced the five-key contract, and its final message
 * is never persisted — so without its partial output the parent receives an
 * empty `key_findings` and learns nothing about work already done. The failure
 * summary therefore carries the TAIL of what the child streamed, under a
 * larger budget (1,000 tokens) because there is no other record of it.
 */
export const SUBAGENT_FAILURE_TOKEN_BUDGET = 1000;

/**
 * Marks a failure excerpt. It is explicitly "unverified": the text is the
 * child's own stream, not a validated finding, and the parent must treat it as
 * data.
 */
export const SUBAGENT_PARTIAL_OUTPUT_LABEL =
  "partial output before it stopped (unverified, last tokens):";

export const SUBAGENT_TRUNCATION_MARKER = "…[truncated]";

/**
 * The rejection message used when a child's final text is not the five-key
 * contract JSON. SECURITY: non-contract text is untrusted prose — it may
 * contain instructions aimed at the parent — so it is REJECTED as a finding
 * rather than embedded verbatim. The runtime status always survives.
 */
export const SUBAGENT_NON_CONTRACT_ERROR =
  "subagent output rejected: the final answer is not the required five-key " +
  "JSON summary (status, files_modified, artifacts_created, key_findings, " +
  "error_if_any).";

const SUMMARY_STATUSES: ReadonlySet<string> = new Set<SubagentSummaryStatus>([
  "completed",
  "failed",
  "cancelled",
  "timeout",
]);

/** Deterministic token estimate: ceil(chars / 4). */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

/** Serialize with a stable key order (the contract's exact five keys). */
export function serializeSubagentSummary(summary: SubagentSummary): string {
  return JSON.stringify({
    status: summary.status,
    files_modified: [...summary.files_modified],
    artifacts_created: [...summary.artifacts_created],
    key_findings: [...summary.key_findings],
    error_if_any: summary.error_if_any,
  });
}

export function summaryTokens(summary: SubagentSummary): number {
  return estimateTokens(serializeSubagentSummary(summary));
}

export type SubagentSummaryValidation =
  | { ok: true; summary: SubagentSummary }
  | { ok: false; error: string };

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
}

/**
 * Strict schema validation: EXACTLY the five contract keys — an extra or a
 * missing key is a rejection, never a silent coercion. Used both to validate
 * a child's self-reported JSON and by callers/tests.
 */
export function validateSubagentSummary(value: unknown): SubagentSummaryValidation {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, error: "summary must be a JSON object" };
  }
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).sort();
  const expected = [...SUBAGENT_SUMMARY_KEYS].sort();
  if (keys.length !== expected.length || keys.some((key, i) => key !== expected[i])) {
    const missing = expected.filter((key) => !keys.includes(key));
    const extra = keys.filter((key) => !(expected as string[]).includes(key));
    return {
      ok: false,
      error:
        `summary must have exactly ${expected.join(", ")}` +
        (missing.length > 0 ? `; missing: ${missing.join(", ")}` : "") +
        (extra.length > 0 ? `; unexpected: ${extra.join(", ")}` : ""),
    };
  }
  if (typeof record["status"] !== "string" || !SUMMARY_STATUSES.has(record["status"])) {
    return {
      ok: false,
      error: `status must be one of ${[...SUMMARY_STATUSES].join(", ")}`,
    };
  }
  if (!isStringArray(record["files_modified"])) {
    return { ok: false, error: "files_modified must be an array of strings" };
  }
  if (!isStringArray(record["artifacts_created"])) {
    return { ok: false, error: "artifacts_created must be an array of strings" };
  }
  if (!isStringArray(record["key_findings"])) {
    return { ok: false, error: "key_findings must be an array of strings" };
  }
  const error = record["error_if_any"];
  if (error !== null && typeof error !== "string") {
    return { ok: false, error: "error_if_any must be a string or null" };
  }
  return {
    ok: true,
    summary: {
      status: record["status"] as SubagentSummaryStatus,
      files_modified: [...(record["files_modified"] as string[])],
      artifacts_created: [...(record["artifacts_created"] as string[])],
      key_findings: [...(record["key_findings"] as string[])],
      error_if_any: error as string | null,
    },
  };
}

/** Parse a serialized summary; anything but exact-contract JSON is invalid. */
export function parseSubagentSummary(text: string): SubagentSummaryValidation {
  let parsed: unknown;
  try {
    parsed = JSON.parse(text) as unknown;
  } catch {
    return { ok: false, error: "summary is not valid JSON" };
  }
  return validateSubagentSummary(parsed);
}

// ── deterministic budget enforcement ───────────────────────────────────────

function cloneSummary(summary: SubagentSummary): SubagentSummary {
  return {
    status: summary.status,
    files_modified: [...summary.files_modified],
    artifacts_created: [...summary.artifacts_created],
    key_findings: [...summary.key_findings],
    error_if_any: summary.error_if_any,
  };
}

/** Truncate one string to [maxChars], keeping the marker when shortened. */
function truncateText(value: string, maxChars: number): string {
  if (value.length <= maxChars) return value;
  if (maxChars <= SUBAGENT_TRUNCATION_MARKER.length) return SUBAGENT_TRUNCATION_MARKER;
  return value.slice(0, maxChars - SUBAGENT_TRUNCATION_MARKER.length) +
    SUBAGENT_TRUNCATION_MARKER;
}

/**
 * Shrink a string list until `measure(candidate)` fits the budget.
 *
 * Deterministic order of operations:
 *  1. keep every entry, binary-search a common per-entry character cap;
 *  2. otherwise binary-search the largest prefix that fits with marker-only
 *     entries, then binary-search how much of its last entry survives;
 *  3. otherwise keep marker-only entries (or the empty list).
 */
function shrinkStringList(
  list: readonly string[],
  measure: (candidate: string[]) => number,
  budget: number,
): string[] {
  if (list.length === 0) return [];
  if (measure([...list]) <= budget) return [...list];

  const maxLen = list.reduce((max, value) => Math.max(max, value.length), 0);
  let lo = 0;
  let hi = maxLen;
  let bestCap = -1;
  while (lo <= hi) {
    const mid = Math.floor((lo + hi) / 2);
    const candidate = list.map((value) => truncateText(value, mid));
    if (measure(candidate) <= budget) {
      bestCap = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (bestCap >= 0) return list.map((value) => truncateText(value, bestCap));

  // Even marker-only entries do not all fit: keep the longest prefix that does.
  let keepLo = 0;
  let keepHi = list.length;
  let keepBest = 0;
  while (keepLo <= keepHi) {
    const mid = Math.floor((keepLo + keepHi) / 2);
    const candidate = Array.from({ length: mid }, () => SUBAGENT_TRUNCATION_MARKER);
    if (measure(candidate) <= budget) {
      keepBest = mid;
      keepLo = mid + 1;
    } else {
      keepHi = mid - 1;
    }
  }
  if (keepBest === 0) return [];
  const head = list.slice(0, keepBest - 1);
  const last = list[keepBest - 1]!;
  let lastLo = 0;
  let lastHi = last.length;
  let lastBest = -1;
  while (lastLo <= lastHi) {
    const mid = Math.floor((lastLo + lastHi) / 2);
    const candidate = [...head, truncateText(last, mid)];
    if (measure(candidate) <= budget) {
      lastBest = mid;
      lastLo = mid + 1;
    } else {
      lastHi = mid - 1;
    }
  }
  if (lastBest >= 0) return [...head, truncateText(last, lastBest)];
  // Marker-only prefix is guaranteed to fit by construction.
  return Array.from({ length: keepBest }, () => SUBAGENT_TRUNCATION_MARKER);
}

/**
 * Apply the hard token budget. The returned object ALWAYS has the five
 * contract keys and is deterministic for the same input.
 */
export function enforceSubagentTokenBudget(
  summary: SubagentSummary,
  budget: number = SUBAGENT_SUMMARY_TOKEN_BUDGET,
): SubagentSummary {
  const out = cloneSummary(summary);
  const original = serializeSubagentSummary(summary);
  if (summaryTokens(out) <= budget) return out;

  // Priority: findings first (the useful payload), then the file/artifact
  // lists, then the error string. `status` is never truncated.
  out.key_findings = shrinkStringList(
    out.key_findings,
    (candidate) => summaryTokens({ ...out, key_findings: candidate }),
    budget,
  );
  // Findings are the primary payload: if the list was emptied only because
  // the other fields were still large, keep a marker here — the later steps
  // shrink those fields and the marker then fits.
  if (out.key_findings.length === 0 && summary.key_findings.length > 0) {
    out.key_findings = [SUBAGENT_TRUNCATION_MARKER];
  }
  if (summaryTokens(out) > budget) {
    out.files_modified = shrinkStringList(
      out.files_modified,
      (candidate) => summaryTokens({ ...out, files_modified: candidate }),
      budget,
    );
  }
  if (summaryTokens(out) > budget) {
    out.artifacts_created = shrinkStringList(
      out.artifacts_created,
      (candidate) => summaryTokens({ ...out, artifacts_created: candidate }),
      budget,
    );
  }
  if (summaryTokens(out) > budget && out.error_if_any !== null) {
    const error = out.error_if_any;
    let lo = 0;
    let hi = error.length;
    let best = -1;
    while (lo <= hi) {
      const mid = Math.floor((lo + hi) / 2);
      const candidate = truncateText(error, mid);
      if (summaryTokens({ ...out, error_if_any: candidate }) <= budget) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    out.error_if_any = best >= 0 ? truncateText(error, best) : null;
  }

  // Absolute backstop: the five-key skeleton always fits 300 tokens, but a
  // caller could pass an absurd budget. Never return an over-budget object.
  if (summaryTokens(out) > budget) {
    out.files_modified = [];
    out.artifacts_created = [];
    out.error_if_any = null;
    if (summaryTokens(out) > budget) {
      out.key_findings = [SUBAGENT_TRUNCATION_MARKER];
    }
    if (summaryTokens(out) > budget) {
      out.key_findings = [];
    }
  }

  // A shortened result must SAY it was shortened. If every field was emptied
  // (no surviving marker), add the marker as the one finding when it fits.
  if (
    serializeSubagentSummary(out) !== original &&
    !serializeSubagentSummary(out).includes(SUBAGENT_TRUNCATION_MARKER)
  ) {
    const marked: SubagentSummary = {
      ...out,
      key_findings: [...out.key_findings, SUBAGENT_TRUNCATION_MARKER],
    };
    if (summaryTokens(marked) <= budget) return marked;
  }
  return out;
}

/**
 * The largest TAIL of [text] that fits [budget] once [base] is serialized.
 *
 * Tail, not head: on a failure the end of the stream is where the child was
 * when it died, which is the only part the parent cannot infer.
 */
function tailFinding(
  text: string,
  base: SubagentSummary,
  budget: number,
): string[] {
  const body = text.trim();
  if (body === "") return [];
  const build = (slice: string): string[] => [
    `${SUBAGENT_PARTIAL_OUTPUT_LABEL}\n${slice}`,
  ];
  const fits = (slice: string): boolean =>
    summaryTokens({ ...base, key_findings: build(slice) }) <= budget;

  let lo = 0;
  let hi = body.length;
  let best = -1;
  while (lo <= hi) {
    const mid = Math.floor((lo + hi) / 2);
    const slice = mid === body.length ? body : `…${body.slice(body.length - mid)}`;
    if (fits(slice)) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (best <= 0) return [SUBAGENT_PARTIAL_OUTPUT_LABEL];
  const slice =
    best === body.length ? body : `…${body.slice(body.length - best)}`;
  return build(slice);
}

/**
 * Build the canonical summary from a child's final text.
 *
 * If the text is already a strict-contract JSON object it is adopted (the
 * runtime's terminal status always wins, because the runtime — not the model —
 * knows whether the run was cancelled/timed out). Otherwise the text is
 * REJECTED: non-contract prose is never copied into `key_findings`, because a
 * child's transcript is untrusted data and must not smuggle instructions to
 * the parent. The rejection is reported in `error_if_any` instead. Either way
 * the 300-token budget is applied.
 */
export function buildSubagentSummary(input: {
  status: SubagentSummaryStatus;
  text?: string | null;
  error?: string | null;
  filesModified?: readonly string[];
  artifactsCreated?: readonly string[];
  keyFindings?: readonly string[];
  /**
   * What the child streamed before it stopped. Only consulted when the child
   * did NOT complete and produced no contract JSON — the parent has no other
   * record of that work.
   */
  partialOutput?: string | null;
}): SubagentSummary {
  const budget =
    input.status === "completed"
      ? SUBAGENT_SUMMARY_TOKEN_BUDGET
      : SUBAGENT_FAILURE_TOKEN_BUDGET;
  const text = (input.text ?? "").trim();
  let base: SubagentSummary = {
    status: input.status,
    files_modified: [...(input.filesModified ?? [])],
    artifacts_created: [...(input.artifactsCreated ?? [])],
    key_findings: [...(input.keyFindings ?? [])],
    error_if_any: input.error ?? null,
  };

  if (text !== "") {
    const parsed = text.startsWith("{") ? parseSubagentSummary(text) : { ok: false as const, error: "" };
    if (parsed.ok) {
      base = {
        status: input.status,
        files_modified: parsed.summary.files_modified,
        artifacts_created: parsed.summary.artifacts_created,
        key_findings: parsed.summary.key_findings,
        error_if_any: input.error ?? parsed.summary.error_if_any,
      };
    } else {
      // Reject, never embed. Explicit findings passed by the caller are kept;
      // the offending text itself is discarded.
      base.key_findings = [...(input.keyFindings ?? [])];
      base.error_if_any = input.error ?? SUBAGENT_NON_CONTRACT_ERROR;
    }
  }

  // A child that stopped early never wrote a contract. Give the parent the
  // tail of what it actually streamed, clearly labelled as unverified — an
  // empty summary would hide work that was already done.
  if (input.status !== "completed" && base.key_findings.length === 0) {
    const partial = (input.partialOutput ?? "").trim();
    if (partial !== "") {
      base.key_findings = tailFinding(partial, base, budget);
    }
  }

  if (input.filesModified !== undefined) base.files_modified = [...input.filesModified];
  if (input.artifactsCreated !== undefined) {
    base.artifacts_created = [...input.artifactsCreated];
  }
  // A runtime error (timeout/cancel/failed) wins over the child's own text;
  // `null` means "no runtime error" and must not erase a rejection message.
  if (input.error !== undefined && input.error !== null) {
    base.error_if_any = input.error;
  }

  return enforceSubagentTokenBudget(base, budget);
}
