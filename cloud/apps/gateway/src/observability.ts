/**
 * Gateway boundary for the shared observability contracts.
 *
 * The composition root supplies the shared metric registry, safeLogRecord and
 * its exporter. Keeping those operations injectable avoids a second metric or
 * redaction implementation in the gateway.
 */

export interface GatewayCorrelationIds {
  requestId?: string;
  runId?: string;
  parentRunId?: string;
  childRunId?: string;
  connectionId?: string;
  providerOperationId?: string;
  studioId?: string;
  previewId?: string;
  collabTurnId?: string;
}

export type GatewayMetricUnit = "count" | "seconds" | "milliseconds" | "bytes" | "gauge";

export interface GatewayMetricSample {
  name: string;
  value: number;
  unit: GatewayMetricUnit;
  correlation?: GatewayCorrelationIds;
}

export interface GatewayLogInput extends Record<string, unknown> {
  event: string;
  correlation?: GatewayCorrelationIds;
  outcome?: string;
  reason?: string;
}

export interface GatewayLogRecord {
  event: string;
  correlation?: GatewayCorrelationIds;
  outcome?: string;
  reason?: string;
}

export interface GatewayObservabilityDeps {
  recordMetric(sample: GatewayMetricSample): void;
  sanitizeLog(record: GatewayLogInput): GatewayLogRecord;
  emitLog(record: GatewayLogRecord): void;
}

export function createGatewayObservability(deps: GatewayObservabilityDeps) {
  return {
    metric(
      name: string,
      value: number,
      unit: GatewayMetricUnit,
      correlation?: GatewayCorrelationIds,
    ): void {
      deps.recordMetric({
        name,
        value,
        unit,
        ...(correlation === undefined ? {} : { correlation }),
      });
    },

    log(record: GatewayLogInput): void {
      // Sanitization is before the sink, never an exporter-only convention.
      deps.emitLog(deps.sanitizeLog(record));
    },
  };
}
