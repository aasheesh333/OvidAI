import { createProviderRegistry, type ProviderReadinessRow, type ProviderRegistry } from "../providers/registry.js";
import type { ProviderDefinition } from "../providers/types.js";
import { ORIGINAL_PROVIDER_DEFINITIONS, ORIGINAL_READINESS_ROWS } from "../providerEvidence.js";
import {
  DEV_WORK_CONTRACT_DEFINITIONS,
  DEV_WORK_READINESS_ROWS,
} from "../rest/descriptors/devWork.js";
import {
  FILES_SUITES_CONTRACT_DEFINITIONS,
  FILES_SUITES_READINESS_ROWS,
} from "../rest/descriptors/filesSuites.js";

export interface TestProviderRegistryOptions {
  /** Synthetic supported fixtures only; never mutate production readiness rows. */
  supported?: readonly string[];
  /** Real candidate/blocked/deprecated rows to exercise mixed composition. */
  internal?: readonly string[];
  /** Test-only concrete origins for tenant-template readiness rows. */
  concreteOrigins?: Readonly<Record<string, readonly string[]>>;
}

function sourceFor(providerId: string): { definition: ProviderDefinition; row: ProviderReadinessRow } {
  const batches = [
    { definitions: ORIGINAL_PROVIDER_DEFINITIONS, rows: ORIGINAL_READINESS_ROWS },
    { definitions: DEV_WORK_CONTRACT_DEFINITIONS, rows: DEV_WORK_READINESS_ROWS },
    { definitions: FILES_SUITES_CONTRACT_DEFINITIONS, rows: FILES_SUITES_READINESS_ROWS },
  ];
  for (const batch of batches) {
    const definition = batch.definitions.find((candidate) => candidate.providerId === providerId);
    const row = batch.rows.find((candidate) => candidate.providerId === providerId);
    if (definition !== undefined && row !== undefined) return { definition, row };
  }
  throw new Error(`No original/devWork/filesSuites test readiness fixture for ${providerId}`);
}

function supportedRow(
  definition: ProviderDefinition,
  original: ProviderReadinessRow,
  concreteOrigins: readonly string[] | undefined,
): ProviderReadinessRow {
  const read = definition.operations.find((operation) => operation.effect === "read");
  if (read === undefined) throw new Error(`No typed read in supported test fixture for ${definition.providerId}`);
  const suffix = definition.providerId.toUpperCase().replaceAll("-", "_");
  return {
    ...original,
    auth: concreteOrigins === undefined ? original.auth : { ...original.auth, tenantOrigins: concreteOrigins },
    operations: definition.operations.map((operation) => ({ ...operation })),
    effects: Object.fromEntries(definition.operations.map((operation) => [operation.name, {
      effect: operation.effect,
      approval: operation.approval,
    }])),
    automatedEvidence: {
      test: "src/__fixtures__/providerRegistry.ts",
      result: "passed",
      runAt: "2026-10-24T20:00:00.000Z",
    },
    liveReadEvidence: {
      command: `OVID_LIVE_PROVIDER_TESTS=1 OVID_LIVE_PROVIDER_${suffix}=1 test-only-registry-fixture`,
      operationId: read.name,
      runAt: "2026-10-24T20:01:00.000Z",
      evidence: "sanitized-result: isolated test registry fixture only; not live provider evidence",
    },
    liveWriteEvidence: definition.operations.filter((operation) => operation.effect !== "read").map((operation) => ({
      command: `OVID_LIVE_PROVIDER_TESTS=1 OVID_LIVE_PROVIDER_WRITE_TESTS=1 OVID_LIVE_PROVIDER_${suffix}=1 OVID_LIVE_PROVIDER_${suffix}_DISPOSABLE_RESOURCE=declared test-only-registry-fixture`,
      operationId: operation.name,
      runAt: "2026-10-24T20:02:00.000Z",
      evidence: "sanitized-result: isolated disposable test fixture; cleanup verified",
    })),
    credentials: "passed",
    releaseState: "supported",
  };
}

/** Build an isolated mixed registry without promoting any production readiness row. */
export function createTestProviderRegistry(options: TestProviderRegistryOptions = {}): ProviderRegistry {
  const registry = createProviderRegistry({ now: () => new Date("2026-10-24T23:00:00.000Z") });
  const supported = new Set(options.supported ?? []);
  const internal = new Set(options.internal ?? []);
  for (const providerId of [...supported, ...internal]) {
    if (supported.has(providerId) && internal.has(providerId)) {
      throw new Error(`Test provider cannot be both supported and internal: ${providerId}`);
    }
    const { definition, row } = sourceFor(providerId);
    registry.registerProvider(
      definition,
      supported.has(providerId)
        ? supportedRow(definition, row, options.concreteOrigins?.[providerId])
        : row,
    );
  }
  return registry;
}
