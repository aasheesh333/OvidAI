/**
 * Shared, low-cardinality observability contracts.
 *
 * Only operational identifiers and closed metric names cross this boundary.
 * Arbitrary log fields are deliberately not accepted: prompts, credentials and
 * signed URLs must never become a new "just this once" label.
 */

export const CORRELATION_KEYS = [
  "requestId",
  "runId",
  "parentRunId",
  "childRunId",
  "connectionId",
  "providerOperationId",
  "studioId",
  "previewId",
  "collabTurnId",
] as const;

export type CorrelationKey = (typeof CORRELATION_KEYS)[number];
export type CorrelationIds = Partial<Record<CorrelationKey, string>>;

function correlationId(value: unknown): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > 128 ||
    !/^[A-Za-z0-9][A-Za-z0-9_.:@-]*$/.test(value) ||
    /(?:https?:|bearer\s|\bsk-|\beyJ|\b(?:token|secret|api[_-]?key|signature)=)/i.test(value)
  ) {
    // Never include the rejected value in the error: it may be the secret.
    throw new TypeError("invalid correlation id");
  }
  return value;
}

/** Copies only known correlation labels and validates every retained value. */
export function correlationIds(input: object): CorrelationIds {
  const record = input as Record<string, unknown>;
  const out: CorrelationIds = {};
  for (const key of CORRELATION_KEYS) {
    const value = record[key];
    if (value !== undefined) out[key] = correlationId(value);
  }
  return out;
}

/** A child keeps the request lineage and points parentRunId at its parent. */
export function childCorrelation(parent: CorrelationIds, childRunId: string): CorrelationIds {
  const input: Record<string, unknown> = { ...parent };
  delete input.childRunId;
  input.parentRunId = parent.runId ?? parent.parentRunId;
  input.runId = childRunId;
  return correlationIds(input);
}

export const METRIC_NAMES = [
  "admission.accepted",
  "admission.rejected",
  "admission.degraded",
  "queue.waiting",
  "queue.oldest_age_seconds",
  "settlement.completed",
  "settlement.failed",
  "events.lost",
  "events.duplicates",
  "sockets.active",
  "sockets.reconnects",
  "approval.age_seconds",
  "connectors.health",
  "connectors.refresh_failures",
  "connectors.egress_refusals",
  "connectors.cap_hits",
  "plugins.lifecycle",
  "subagents.slots",
  "subagents.wake_duplicates",
  "subagents.cleanup",
  "preview.processes",
  "collab.leases",
  "collab.outbox",
  "collab.members",
  "storage.reservations",
  "notifications.registrations",
  "notifications.deliveries",
  "notifications.pruned",
] as const;

export type MetricName = (typeof METRIC_NAMES)[number];
export type MetricUnit = "count" | "seconds" | "milliseconds" | "bytes" | "gauge";

export interface MetricSample {
  name: string;
  value: number;
  unit: MetricUnit;
  correlation?: CorrelationIds;
}

const METRIC_NAME_SET: ReadonlySet<string> = new Set(METRIC_NAMES);
const METRIC_UNITS: ReadonlySet<string> = new Set([
  "count",
  "seconds",
  "milliseconds",
  "bytes",
  "gauge",
]);

export interface MetricRegistry {
  record(sample: MetricSample): void;
  snapshot(): MetricSample[];
}

/** In-memory transport seam; exporters receive the same validated samples. */
export function createMetricRegistry(): MetricRegistry {
  const samples: MetricSample[] = [];
  const copy = (sample: MetricSample): MetricSample => ({
    name: sample.name,
    value: sample.value,
    unit: sample.unit,
    ...(sample.correlation === undefined
      ? {}
      : { correlation: { ...sample.correlation } }),
  });
  return {
    record(sample) {
      if (!METRIC_NAME_SET.has(sample.name)) throw new TypeError("unknown metric");
      if (!Number.isFinite(sample.value)) throw new TypeError("invalid metric value");
      if (!METRIC_UNITS.has(sample.unit)) throw new TypeError("invalid metric unit");
      const correlation = sample.correlation === undefined
        ? undefined
        : correlationIds(sample.correlation);
      samples.push(copy({ ...sample, ...(correlation === undefined ? {} : { correlation }) }));
    },
    snapshot() {
      return samples.map(copy);
    },
  };
}

export interface SafeLogRecord {
  event: string;
  correlation?: CorrelationIds;
  outcome?: string;
  reason?: string;
}

function operationalCode(value: unknown, label: string): string {
  if (typeof value !== "string" || !/^[A-Za-z][A-Za-z0-9_.:-]{0,79}$/.test(value)) {
    throw new TypeError(`invalid ${label}`);
  }
  return value;
}

/**
 * Builds a log record from a closed field set. Unknown input keys are dropped,
 * not recursively serialized. `event`, `outcome` and `reason` are codes, not
 * free-form provider/user messages.
 */
export function safeLogRecord(input: Record<string, unknown>): SafeLogRecord {
  const out: SafeLogRecord = {
    event: operationalCode(input.event, "log event"),
  };
  if (input.correlation !== undefined) {
    if (typeof input.correlation !== "object" || input.correlation === null || Array.isArray(input.correlation)) {
      throw new TypeError("invalid correlation");
    }
    out.correlation = correlationIds(input.correlation as Record<string, unknown>);
  }
  if (input.outcome !== undefined) out.outcome = operationalCode(input.outcome, "log outcome");
  if (input.reason !== undefined) out.reason = operationalCode(input.reason, "log reason");
  return out;
}

/** Last-resort redaction for unavoidable legacy text; structured logs use safeLogRecord. */
export function redactSensitiveText(text: string): string {
  return text
    .replace(/https?:\/\/[^\s<>"']+/gi, "[redacted]")
    .replace(/\bBearer\s+[A-Za-z0-9._~+\/-]+/gi, "Bearer [redacted]")
    .replace(/\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b/g, "[redacted]")
    .replace(/\b((?:api[_-]?key|access[_-]?token|token|secret|signature|sig|key)=)[^\s&]+/gi, "$1[redacted]")
    .replace(/\b(?:sk|rk|pk)-[A-Za-z0-9_-]{4,}/g, "[redacted]");
}
