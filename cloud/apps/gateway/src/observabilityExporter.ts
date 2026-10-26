import type { MetricSample, SafeLogRecord } from "@ovid/shared";
import type { GatewayObservabilityExporter } from "./observabilityComposition.js";

/**
 * Production exporter: structured JSON lines to stdout.
 *
 * No external dependency is introduced. The composition feeds this sink only
 * after the shared registry/sanitizer has validated and redacted the record, so
 * the sink never sees free-form text, credentials, or arbitrary labels.
 */
export function createStdoutObservabilityExporter(): GatewayObservabilityExporter {
  return {
    metric(sample: MetricSample): void {
      console.log(JSON.stringify({ type: "metric", sample }));
    },
    log(record: SafeLogRecord): void {
      console.log(JSON.stringify({ type: "log", record }));
    },
  };
}
