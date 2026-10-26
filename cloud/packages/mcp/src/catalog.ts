/** Production catalog: only fully evidenced supported readiness rows may be materialized. */

import type { McpToolDef } from "./client.js";
import type { NativeMcpHandler } from "./transports/native.js";
import type { GuardedFetch } from "./ssrf.js";
import type { WorkspaceFiles } from "./workspace.js";
import type { ProviderEgress } from "./egress/responseLimits.js";
import {
  createRestHandler,
  type CredentialField,
  type RestHandlerOptions,
  type RestServiceDescriptor,
} from "./rest/engine.js";
import { withReadEnvelope } from "./rest/descriptors/readEnvelopes.js";
import {
  COMMERCE_INFRA_DESCRIPTORS,
  COMMERCE_INFRA_PROVIDERS,
  CURATED_DESCRIPTORS,
  DATA_SEARCH_DESCRIPTORS,
  DATA_SEARCH_PROVIDERS,
} from "./rest/descriptors/index.js";
import {
  createS3Handler,
  createGoogleDriveHandler,
  createSupabaseHandler,
} from "./rest/descriptors/data.js";
import { createLinearHandler } from "./rest/descriptors/dev.js";
import {
  createDiscordHandler,
  createSlackHandler,
  createTelegramHandler,
} from "./rest/descriptors/comms.js";
import { createFetchHandler } from "./native/fetch.js";
import { createFilesystemHandler } from "./native/filesystem.js";
import { createMemoryHandler } from "./native/memory.js";
import { createGitHubHandler } from "./native/github.js";
import {
  createProviderRegistry,
  type ProviderRegistry,
} from "./providers/registry.js";
import type { ProviderDefinition } from "./providers/types.js";
import { FILES_SUITES_PROVIDERS } from "./rest/descriptors/filesSuites.js";
import {
  createDevWorkHandler,
  DEV_WORK_CANDIDATE_IDS,
  DEV_WORK_CONTRACT_DEFINITIONS,
  DEV_WORK_CONTRACT_DESCRIPTORS,
} from "./rest/descriptors/devWork.js";
import {
  DATA_SEARCH_PROVIDERS as DATA_SEARCH_SPECIAL_HANDLERS,
  createDataSearchHandler,
} from "./rest/descriptors/dataSearch.js";
import {
  COMMERCE_INFRA_PROVIDERS as COMMERCE_INFRA_SPECIAL_HANDLERS,
  createCommerceInfraHandler,
} from "./rest/descriptors/commerceInfra.js";
import {
  KNOWN_PROVIDER_IDS,
  PRODUCTION_PROVIDER_REGISTRY,
  RESERVED_PROVIDER_NAMESPACES,
} from "./providerProduction.js";

export { KNOWN_PROVIDER_IDS, PRODUCTION_PROVIDER_REGISTRY, RESERVED_PROVIDER_NAMESPACES };

export interface CatalogManifestEntry {
  curatedId: string;
  displayName: string;
  description: string;
  credentialFields: CredentialField[];
  tools: McpToolDef[];
}

function credentialFieldsFor(definition: ProviderDefinition): CredentialField[] {
  if (definition.providerId === "github") {
    return [{ key: "GITHUB_TOKEN", label: "GitHub token", secret: true }];
  }
  if (["filesystem", "fetch", "memory", "mongodb"].includes(definition.providerId)) return [];
  const descriptor = CURATED_DESCRIPTORS.find((candidate) => candidate.curatedId === definition.providerId) ??
    DEV_WORK_CONTRACT_DESCRIPTORS.find((candidate) => candidate.curatedId === definition.providerId) ??
    DATA_SEARCH_DESCRIPTORS.find((candidate) => candidate.curatedId === definition.providerId) ??
    COMMERCE_INFRA_DESCRIPTORS.find((candidate) => candidate.curatedId === definition.providerId);
  if (descriptor === undefined) return [];
  const fields: CredentialField[] = descriptor.credentialKey === ""
    ? []
    : [{ key: descriptor.credentialKey, label: descriptor.credentialLabel, secret: true }];
  fields.push(...(descriptor.extraConfig ?? []));
  return fields;
}

function manifestEntry(definition: ProviderDefinition): CatalogManifestEntry {
  return {
    curatedId: definition.providerId,
    displayName: definition.displayName,
    description: definition.description,
    credentialFields: credentialFieldsFor(definition),
    tools: definition.operations.map((operation) => ({ ...operation, inputSchema: { ...operation.inputSchema } })),
  };
}

const SPECIAL_HANDLER_PROVIDER_IDS = new Set([
  "github",
  "filesystem",
  "fetch",
  "memory",
  "mongodb",
  "linear",
  "google-drive",
  "supabase",
  "s3",
  "slack",
  "discord",
  "telegram",
  ...DEV_WORK_CANDIDATE_IDS,
  ...DATA_SEARCH_SPECIAL_HANDLERS.map((definition) => definition.providerId),
  ...COMMERCE_INFRA_SPECIAL_HANDLERS.map((definition) => definition.providerId),
]);

function concreteOrigins(origins: readonly string[]): URL[] {
  const result = new Map<string, URL>();
  for (const value of origins) {
    if (!value.startsWith("https://") || /[{}*<>]/.test(value)) continue;
    try {
      const parsed = new URL(value);
      if (parsed.username === "" && parsed.password === "") result.set(parsed.origin, new URL(parsed.origin));
    } catch {
      // Native, dynamic-tenant, and malformed origins cannot enter a static pin map.
    }
  }
  return [...result.values()];
}

export interface CuratedCatalogProjection {
  definitions: readonly ProviderDefinition[];
  origins: Readonly<Record<string, readonly URL[]>>;
  /** Only descriptors whose default factory is genuinely generic REST. */
  genericDescriptors: readonly RestServiceDescriptor[];
}

/** One support projection for static metadata, worker catalog/origins, and activation. */
export function createCuratedCatalogProjection(
  registry: ProviderRegistry = PRODUCTION_PROVIDER_REGISTRY,
): CuratedCatalogProjection {
  const definitions: ProviderDefinition[] = [];
  const origins: Record<string, readonly URL[]> = {};
  const genericDescriptors = new Map<string, RestServiceDescriptor>();

  for (const definition of registry.catalogDefinitions()) {
    const registration = registry.get(definition.providerId);
    if (registration === undefined || registration.row.releaseState !== "supported") continue;
    const descriptor = CURATED_DESCRIPTORS.find((candidate) => candidate.curatedId === definition.providerId);
    const providerOrigins = concreteOrigins(registration.row.auth.tenantOrigins);
    // Dynamic generic REST tenants need per-connection composition. Exclude
    // them from BOTH metadata and activation until that composition exists.
    if (descriptor !== undefined && providerOrigins.length === 0) continue;
    if (providerOrigins.length > 0) origins[definition.providerId] = Object.freeze(providerOrigins);
    definitions.push(definition);
    if (descriptor !== undefined && !SPECIAL_HANDLER_PROVIDER_IDS.has(definition.providerId)) {
      genericDescriptors.set(definition.providerId, descriptor);
    }
  }

  return {
    definitions: Object.freeze(definitions),
    origins: Object.freeze(origins),
    genericDescriptors: Object.freeze([...genericDescriptors.values()]),
  };
}

export function createCuratedManifest(
  registry: ProviderRegistry = PRODUCTION_PROVIDER_REGISTRY,
): readonly CatalogManifestEntry[] {
  return createCuratedCatalogProjection(registry).definitions.map(manifestEntry);
}

function assertDefaultCatalogCallable(providerId: string): void {
  PRODUCTION_PROVIDER_REGISTRY.assertCatalogCallable(providerId);
}

const DEFAULT_CATALOG_PROJECTION = createCuratedCatalogProjection();
export const CURATED_IDS: readonly string[] = DEFAULT_CATALOG_PROJECTION.definitions.map(
  (definition) => definition.providerId,
);
export const CURATED_MANIFEST: readonly CatalogManifestEntry[] =
  DEFAULT_CATALOG_PROJECTION.definitions.map(manifestEntry);

/** Blocked files/suites candidates never become production manifest entries. */
export const FILES_SUITES_CATALOG_MANIFEST: readonly CatalogManifestEntry[] =
  FILES_SUITES_PROVIDERS.map(manifestEntry);

/** Internal Task 9 candidates only; never included in the production catalog projection. */
export const DATA_SEARCH_CANDIDATE_IDS: readonly string[] = DATA_SEARCH_PROVIDERS.map(
  (definition) => definition.providerId,
);
export const DATA_SEARCH_CANDIDATE_MANIFEST: readonly CatalogManifestEntry[] =
  DATA_SEARCH_CANDIDATE_IDS.map((providerId) => {
    const definition = DATA_SEARCH_PROVIDERS.find((candidate) => candidate.providerId === providerId);
    if (definition === undefined) throw new Error(`Missing data/search candidate: ${providerId}`);
    return manifestEntry(definition);
  });

/** Internal Task 10 candidates only; never included in the production catalog projection. */
export const COMMERCE_INFRA_PROVIDER_IDS: readonly string[] = COMMERCE_INFRA_PROVIDERS.map(
  (definition) => definition.providerId,
);
export const COMMERCE_INFRA_MANIFEST: readonly CatalogManifestEntry[] =
  COMMERCE_INFRA_PROVIDER_IDS.map((providerId) => {
    const definition = COMMERCE_INFRA_PROVIDERS.find((candidate) => candidate.providerId === providerId);
    if (definition === undefined) throw new Error(`Missing commerce/infrastructure candidate: ${providerId}`);
    return manifestEntry(definition);
  });

export interface CatalogEntry extends CatalogManifestEntry {
  handler: NativeMcpHandler;
}

export interface CuratedCatalog {
  entries(): readonly CatalogEntry[];
  get(curatedId: string): CatalogEntry | undefined;
}

export interface CuratedCatalogDeps {
  fetchImpl: GuardedFetch;
  workspace: WorkspaceFiles;
  githubApiBase?: string;
  providerEgress?: ProviderEgress;
  /** Defaults to the shared evidence-gated production registry; tests may supply isolated rows. */
  registry?: ProviderRegistry;
  handlerOverrides?: Partial<Record<string, () => NativeMcpHandler>>;
}

export function createCuratedCatalog(deps: CuratedCatalogDeps): CuratedCatalog {
  const cache = new Map<string, CatalogEntry>();
  const definitions = createCuratedCatalogProjection(deps.registry).definitions;
  const restOptions: RestHandlerOptions = deps.providerEgress === undefined
    ? {}
    : { providerEgress: deps.providerEgress };

  function defaultFactory(id: string): NativeMcpHandler {
    if (DEV_WORK_CONTRACT_DEFINITIONS.some((definition) => definition.providerId === id)) {
      return createDevWorkHandler(id, restOptions);
    }
    const dataSearchDescriptor = DATA_SEARCH_DESCRIPTORS.find((candidate) => candidate.curatedId === id);
    if (dataSearchDescriptor !== undefined) return createDataSearchHandler(dataSearchDescriptor, restOptions);
    if (COMMERCE_INFRA_SPECIAL_HANDLERS.some((definition) => definition.providerId === id)) {
      return createCommerceInfraHandler(id);
    }
    switch (id) {
      case "github":
        return createGitHubHandler({ apiBase: deps.githubApiBase, providerEgress: deps.providerEgress });
      case "filesystem":
        return createFilesystemHandler();
      case "fetch":
        return createFetchHandler();
      case "memory":
        return createMemoryHandler();
      case "s3":
        return createS3Handler(undefined, restOptions);
      case "google-drive":
        return createGoogleDriveHandler(undefined, restOptions);
      case "supabase":
        return createSupabaseHandler(restOptions);
      case "linear":
        return createLinearHandler(restOptions);
      case "slack":
        return createSlackHandler(restOptions);
      case "discord":
        return createDiscordHandler(restOptions);
      case "telegram":
        return createTelegramHandler(restOptions);
      default: {
        const descriptor = CURATED_DESCRIPTORS.find((candidate) => candidate.curatedId === id);
        if (descriptor === undefined) throw new Error(`unknown curated id: ${id}`);
        // Generic originals still get their documented read-shape check; the
        // wrapper delegates the actual request to the same engine handler.
        return withReadEnvelope(id, createRestHandler(descriptor, restOptions));
      }
    }
  }

  function entry(id: string): CatalogEntry {
    if (deps.registry !== undefined) deps.registry.assertCatalogCallable(id);
    else assertDefaultCatalogCallable(id);
    let cached = cache.get(id);
    if (cached === undefined) {
      const definition = definitions.find((candidate) => candidate.providerId === id);
      if (definition === undefined) throw new Error(`Supported provider is unavailable: ${id}`);
      const override = deps.handlerOverrides?.[id];
      const handler = override !== undefined ? override() : defaultFactory(id);
      cached = { ...manifestEntry(definition), handler };
      cache.set(id, cached);
    }
    return cached;
  }

  return {
    entries: () => definitions.map((definition) => entry(definition.providerId)),
    get(curatedId: string): CatalogEntry | undefined {
      return definitions.some((definition) => definition.providerId === curatedId) ? entry(curatedId) : undefined;
    },
  };
}

/** Isolated registry construction is useful to other contract tests without exposing candidates. */
export { createProviderRegistry, type ProviderRegistry };
