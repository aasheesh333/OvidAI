import {
  correlationIds,
  createMetricRegistry,
  safeLogRecord,
  type MetricSample,
  type SafeLogRecord,
} from "../../../packages/shared/dist/observability.js";
import { createGatewayObservability } from "./observability.js";

/**
 * Task 11 composition only: one shared registry/sanitizer and the injected real
 * exporter. The shared package barrel is outside this adapter's scope, so this
 * imports its built module directly (the gateway/shared dist layouts align).
 * No routes, application instrumentation, or exporter implementation lives here.
 */

export interface GatewayObservabilityExporter {
  metric(sample: MetricSample): void;
  log(record: SafeLogRecord): void;
}

const OPERATIONAL_HEALTH_FACTS = [
  "anomaly",
  "mail",
  "reservation",
  "notification",
] as const;

export type GatewayOperationalHealthFact = (typeof OPERATIONAL_HEALTH_FACTS)[number];

/** Only these four fields may be merged into the existing health `checks` object. */
export type GatewayOperationalHealthChecks = Partial<
  Record<GatewayOperationalHealthFact, boolean>
>;

/** A missing/malformed/throwing probe produces an omitted (unknown) fact. */
export type GatewayOperationalHealthProbes = Partial<
  Record<GatewayOperationalHealthFact, () => unknown>
>;

export interface GatewayObservabilityCompositionDeps {
  exporter: GatewayObservabilityExporter;
  health?: GatewayOperationalHealthProbes;
}

function createHealthChecksProducer(probes: GatewayOperationalHealthProbes) {
  return async (): Promise<GatewayOperationalHealthChecks> => {
    // Resolve independently: one failed probe must not erase the other facts.
    // Await inside the try so synchronous throws and rejected promises are equal.
    const values = await Promise.all(
      OPERATIONAL_HEALTH_FACTS.map(async (fact): Promise<unknown> => {
        try {
          const probe = probes[fact];
          if (typeof probe !== "function") return undefined;
          return await probe();
        } catch {
          return undefined;
        }
      }),
    );

    const checks: GatewayOperationalHealthChecks = {};
    OPERATIONAL_HEALTH_FACTS.forEach((fact, index) => {
      const value = values[index];
      // Never coerce truthiness, numbers, strings, or Boolean objects. Omission
      // is intentional: Watch treats a missing fact as failing `unknown`.
      if (value === true || value === false) checks[fact] = value;
    });
    return checks;
  };
}

export function createGatewayObservabilityComposition(
  deps: GatewayObservabilityCompositionDeps,
) {
  const registry = createMetricRegistry();
  const observability = createGatewayObservability({
    recordMetric(sample) {
      const correlation = sample.correlation === undefined
        ? undefined
        : correlationIds(sample.correlation);
      const validated = {
        name: sample.name,
        value: sample.value,
        unit: sample.unit,
        ...(correlation === undefined ? {} : { correlation }),
      };

      // The shared registry is the sole authority for closed names, units, and
      // finite values. Nothing reaches the actual exporter if validation fails.
      registry.record(validated);
      // `validated` is already a fresh closed-field object. The registry keeps
      // its own defensive copies, so exporter mutation cannot alter snapshots.
      try {
        deps.exporter.metric(validated);
      } catch {
        // Degrade: a broken sink must never break a request. The registry
        // already holds the validated sample; the caller gets no error.
      }
    },
    sanitizeLog: safeLogRecord,
    emitLog(record) {
      // createGatewayObservability calls safeLogRecord before this sink. Its
      // result is a fresh closed-field object, including copied correlation IDs.
      try {
        deps.exporter.log(record);
      } catch {
        // Degrade: a broken log sink must never break a request.
      }
    },
  });

  return {
    ...observability,
    // Expose only the shared registry's defensive read side, not a bypass around
    // the composed validation/export path.
    metrics: { snapshot: () => registry.snapshot() },
    healthChecks: createHealthChecksProducer(deps.health ?? {}),
  };
}
