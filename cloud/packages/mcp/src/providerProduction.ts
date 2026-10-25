/** Production support and non-publishing provider inventory projections. */

import { ORIGINAL_PROVIDER_REGISTRY } from "./providerEvidence.js";
import { createProviderRegistry, type ProviderReadinessRow } from "./providers/registry.js";
import type { ProviderDefinition, ProviderOperation } from "./providers/types.js";
import {
  DEV_WORK_CONTRACT_DEFINITIONS,
  DEV_WORK_READINESS_ROWS,
} from "./rest/descriptors/devWork.js";
import {
  FILES_SUITES_CONTRACT_DEFINITIONS,
  FILES_SUITES_READINESS_ROWS,
} from "./rest/descriptors/filesSuites.js";
import {
  DATA_SEARCH_BLOCKED,
  DATA_SEARCH_DESCRIPTORS,
  DATA_SEARCH_PROVIDERS,
} from "./rest/descriptors/dataSearch.js";
import {
  COMMERCE_INFRA_BLOCKED,
  COMMERCE_INFRA_DESCRIPTORS,
  COMMERCE_INFRA_PROVIDERS,
  COMMERCE_INFRA_SUPERSESSIONS,
} from "./rest/descriptors/commerceInfra.js";
import type { RestServiceDescriptor } from "./rest/engine.js";
import { safeServerName } from "./toolNames.js";

const NON_SUPPORTED_API_VERSION = "not asserted for this non-supported candidate";
const NON_SUPPORTED_REVIEWER = "not independently reviewed; current descriptor export";

function effectsFor(operations: readonly ProviderOperation[]): ProviderReadinessRow["effects"] {
  return Object.fromEntries(operations.map((operation) => [operation.name, {
    effect: operation.effect,
    approval: operation.approval,
  }]));
}

function tenantOrigin(descriptor: RestServiceDescriptor): string {
  const withScheme = descriptor.baseUrl.startsWith("https://")
    ? descriptor.baseUrl
    : `https://${descriptor.baseUrl}`;
  const authority = withScheme.slice("https://".length).split("/")[0];
  if (authority === undefined || authority === "") {
    throw new Error(`Provider origin is unavailable: ${descriptor.curatedId}`);
  }
  return `https://${authority}`;
}

/** Formal candidate facts only. Contract descriptors are not live evidence. */
function candidateRows(
  definitions: readonly ProviderDefinition[],
  descriptors: readonly RestServiceDescriptor[],
  catalogOwner: string,
  contractTest: string,
  supersessions: Readonly<Record<string, string>> = {},
): ProviderReadinessRow[] {
  return definitions.map((definition): ProviderReadinessRow => {
    const descriptor = descriptors.find((candidate) => candidate.curatedId === definition.providerId);
    if (descriptor === undefined) throw new Error(`Provider descriptor missing: ${definition.providerId}`);
    const superseded = supersessions[definition.providerId];
    return {
      providerId: definition.providerId,
      ...(superseded === undefined ? {} : { supersedes: superseded }),
      catalogOwner,
      officialDocs: definition.officialDocs.map((doc) => ({
        ...doc,
        apiVersion: NON_SUPPORTED_API_VERSION,
        reviewer: NON_SUPPORTED_REVIEWER,
      })),
      operations: definition.operations.map((operation) => ({ ...operation })),
      auth: {
        profileId: definition.authProfileId,
        tokenType: "Candidate auth profile; no production credential approval",
        authorizationPrefix: descriptor.authPrefix ?? "",
        minimumScopes: [...new Set(definition.operations.flatMap((operation) => operation.requiredScopes))],
        tenantOrigins: [tenantOrigin(descriptor)],
        refreshBehavior: "Candidate lifecycle evidence is absent; promotion requires a real review.",
        revokeBehavior: "Candidate revoke evidence is absent; no remote revocation claim is made.",
        disconnectBehavior: "Candidate generation fencing evidence is absent; production admission remains closed.",
      },
      effects: effectsFor(definition.operations),
      isolationEvidence: [],
      fixtures: [],
      automatedEvidence: { test: contractTest, result: "not_run", runAt: null },
      liveReadEvidence: null,
      liveWriteEvidence: [],
      credentials: "not provided",
      releaseState: "candidate",
    };
  });
}

interface BlockedIdentity {
  providerId: string;
  reason: string;
  officialDocs: ProviderDefinition["officialDocs"];
}

function emptyConnectionSchema(): Record<string, unknown> {
  return {
    type: "object",
    properties: {},
    required: [],
    additionalProperties: false,
    maxProperties: 0,
  };
}

/** Descriptor-absent IDs get metadata/readiness rows, never a callable operation. */
function blockedRegistration(identity: BlockedIdentity, deprecated: boolean): {
  definition: ProviderDefinition;
  row: ProviderReadinessRow;
} {
  const authProfileId = `${identity.providerId}-non-supported`;
  const definition: ProviderDefinition = {
    providerId: identity.providerId,
    catalogVersion: "2026-10-24.non-supported",
    displayName: `${identity.providerId} (unavailable)`,
    description: identity.reason,
    officialDocs: identity.officialDocs.map((doc) => ({ ...doc })),
    authProfileId,
    connectionSchema: emptyConnectionSchema(),
    operations: [],
    // ProviderDefinition's legacy type uses this literal for its operation shape;
    // the readiness row is the release authority and is deliberately non-supported.
    readiness: "supported",
  };
  const row: ProviderReadinessRow = {
    providerId: identity.providerId,
    catalogOwner: "catalog-integration-blocked-inventory",
    officialDocs: identity.officialDocs.map((doc) => ({
      ...doc,
      apiVersion: NON_SUPPORTED_API_VERSION,
      reviewer: NON_SUPPORTED_REVIEWER,
    })),
    operations: [],
    auth: {
      profileId: authProfileId,
      tokenType: "No admitted credential profile",
      authorizationPrefix: "",
      minimumScopes: [],
      tenantOrigins: ["native://unavailable"],
      refreshBehavior: "No refresh lifecycle is available for this blocked identity.",
      revokeBehavior: "No remote revoke behavior is claimed for this blocked identity.",
      disconnectBehavior: "No connection can be activated for this blocked identity.",
    },
    effects: {},
    isolationEvidence: [],
    fixtures: [],
    automatedEvidence: { test: "non-supported inventory has no callable operation", result: "not_run", runAt: null },
    liveReadEvidence: null,
    liveWriteEvidence: [],
    credentials: "not provided",
    releaseState: deprecated ? "deprecated" : "blocked",
  };
  return { definition, row };
}

const productionRegistry = createProviderRegistry();
const originalRegistrations = ORIGINAL_PROVIDER_REGISTRY.definitions().map((definition) => ({
  definition,
  row: ORIGINAL_PROVIDER_REGISTRY.get(definition.providerId)!.row,
}));
const devWorkRegistrations = DEV_WORK_CONTRACT_DEFINITIONS.map((definition) => ({
  definition,
  row: DEV_WORK_READINESS_ROWS.find((row) => row.providerId === definition.providerId)!,
}));
const filesSuitesRegistrations = FILES_SUITES_CONTRACT_DEFINITIONS.map((definition) => ({
  definition,
  row: FILES_SUITES_READINESS_ROWS.find((row) => row.providerId === definition.providerId)!,
}));
const dataSearchRows = candidateRows(
  DATA_SEARCH_PROVIDERS,
  DATA_SEARCH_DESCRIPTORS,
  "data-search",
  "test/providers/dataSearch.contract.test.ts",
);
const dataSearchRegistrations = DATA_SEARCH_PROVIDERS.map((definition, index) => ({
  definition,
  row: dataSearchRows[index]!,
}));
const commerceRows = candidateRows(
  COMMERCE_INFRA_PROVIDERS,
  COMMERCE_INFRA_DESCRIPTORS,
  "commerce-infrastructure",
  "test/providers/commerceInfra.contract.test.ts",
  COMMERCE_INFRA_SUPERSESSIONS,
);
const commerceRegistrations = COMMERCE_INFRA_PROVIDERS.map((definition, index) => ({
  definition,
  row: commerceRows[index]!,
}));
const blockedRegistrations = [
  ...DATA_SEARCH_BLOCKED.map((identity) => blockedRegistration(identity, false)),
  ...COMMERCE_INFRA_BLOCKED.map((identity) => blockedRegistration(identity, identity.providerId === "opsgenie")),
];
const readinessBatches = [
  originalRegistrations,
  devWorkRegistrations,
  filesSuitesRegistrations,
  dataSearchRegistrations,
  commerceRegistrations,
  blockedRegistrations,
];

for (const batch of readinessBatches) {
  for (const { definition, row } of batch) {
    if (row.providerId !== definition.providerId) {
      throw new Error(`Production readiness ID mismatch: ${definition.providerId}`);
    }
    productionRegistry.registerProvider(definition, row);
  }
}

/**
 * The single complete evidence-gated production registry used by metadata,
 * catalog, origins, and activation. Every current batch has a formal row;
 * candidate/blocked/deprecated registrations cannot enter the supported view.
 */
export const PRODUCTION_PROVIDER_REGISTRY = productionRegistry;

const inventoriedIds = productionRegistry.definitions().map((definition) => definition.providerId);
if (new Set(inventoriedIds).size !== inventoriedIds.length) {
  throw new Error("Provider inventory contains a duplicate provider ID.");
}
const supersededIds = productionRegistry.rows().flatMap((row) =>
  row.supersedes === undefined ? [] : [row.supersedes]
);

/**
 * Non-publishing admission/namespace inventory. Known unsupported IDs must
 * never fall through to custom connection creation, and historical IDs remain
 * reserved after supersession. This is intentionally separate from CURATED_IDS.
 */
export const KNOWN_PROVIDER_IDS: readonly string[] = Object.freeze([
  ...new Set([...inventoriedIds, ...supersededIds]),
]);

/** Exact model-facing namespaces reserved by the complete known inventory. */
export const RESERVED_PROVIDER_NAMESPACES: ReadonlySet<string> = new Set(
  KNOWN_PROVIDER_IDS.map((providerId) => safeServerName(providerId)),
);
