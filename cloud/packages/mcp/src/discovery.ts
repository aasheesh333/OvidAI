import type { ActivatedOperation, RunMcpSnapshot } from "./activation.js";

/** Deterministic model-context limits for one run-local schema ledger. */
export interface SchemaBudget {
  discoveryResults: number;
  operationsPerProvider: number;
  operationsPerRun: number;
  schemaBytes: number;
  schemaTokens: number;
}

export const ROOT_SCHEMA_BUDGET: SchemaBudget = Object.freeze({
  discoveryResults: 8,
  operationsPerProvider: 4,
  operationsPerRun: 12,
  schemaBytes: 24_576,
  schemaTokens: 8_192,
});

export const CHILD_SCHEMA_BUDGET: SchemaBudget = Object.freeze({
  discoveryResults: 4,
  operationsPerProvider: 2,
  operationsPerRun: 6,
  schemaBytes: 8_192,
  schemaTokens: 2_730,
});

export function schemaBudgetFor(isSubagent: boolean): SchemaBudget {
  return isSubagent ? CHILD_SCHEMA_BUDGET : ROOT_SCHEMA_BUDGET;
}

export interface DiscoveryQuery {
  query?: string;
  providerId?: string;
}

export interface IntegrationSummary {
  providerId: string;
  connectionId: string;
  operationId: string;
  description: string;
}

export interface DiscoveryResult {
  code: "ok";
  results: IntegrationSummary[];
  hasMore: boolean;
}

export interface IntegrationSchemaRequest {
  connectionId: string;
  operationIds: readonly string[];
}

export interface LoadedIntegrationSchema {
  providerId: string;
  connectionId: string;
  operationId: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export interface SchemaResult {
  code: "ok" | "denied" | "narrow_query";
  loaded: LoadedIntegrationSchema[];
}

interface CachedSchema {
  serialized: string;
}

interface SchemaUsage {
  loaded: Map<string, CachedSchema>;
  runOperations: Set<string>;
  providerOperations: Map<string, Set<string>>;
  schemaBytes: number;
  schemaTokens: number;
}

interface PreparedSchema {
  key: string;
  operation: ActivatedOperation;
  cached: CachedSchema;
  bytes: number;
  tokens: number;
  cacheHit: boolean;
}

// Usage is local to the exact snapshot and canonical budget VALUES. Equivalent
// cloned budgets share a ledger; root/child semantics and distinct snapshots do
// not. The outer WeakMap cannot retain a closed run or leak usage across runs.
// Entries contain only non-secret IDs and complete JSON schemas. Run-local
// connectionId/configVersion/disconnectGeneration metadata remains in the
// immutable snapshot; uid stays with activation. No config/secret value,
// resolver result, transport state or health inference is stored here.
const runUsage = new WeakMap<RunMcpSnapshot, Map<string, SchemaUsage>>();

function compareText(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function compareOperations(a: ActivatedOperation, b: ActivatedOperation): number {
  return compareText(a.providerId, b.providerId) ||
    compareText(a.connectionId, b.connectionId) ||
    compareText(a.operationId, b.operationId);
}

function operationKey(operation: ActivatedOperation): string {
  return JSON.stringify([operation.providerId, operation.connectionId, operation.operationId]);
}

function orderedOperations(snapshot: RunMcpSnapshot): ActivatedOperation[] {
  // Every operation here is already activation- and run-policy-gated. Effects
  // and approvals belong to the execution boundary; discovery only describes
  // the exact roster and never executes an operation or changes activation.
  return [...snapshot.operations].sort(compareOperations);
}

function budgetKey(budget: SchemaBudget): string {
  return JSON.stringify([
    budget.discoveryResults,
    budget.operationsPerProvider,
    budget.operationsPerRun,
    budget.schemaBytes,
    budget.schemaTokens,
  ]);
}

function usageFor(snapshot: RunMcpSnapshot, budget: SchemaBudget): SchemaUsage {
  let budgets = runUsage.get(snapshot);
  if (budgets === undefined) {
    budgets = new Map<string, SchemaUsage>();
    runUsage.set(snapshot, budgets);
  }
  const key = budgetKey(budget);
  let usage = budgets.get(key);
  if (usage === undefined) {
    usage = {
      loaded: new Map<string, CachedSchema>(),
      runOperations: new Set<string>(),
      providerOperations: new Map<string, Set<string>>(),
      schemaBytes: 0,
      schemaTokens: 0,
    };
    budgets.set(key, usage);
  }
  return usage;
}

function serializedSchema(operation: ActivatedOperation): CachedSchema {
  // Provider schemas are closed JSON data. Serializing the WHOLE schema before
  // measuring makes invalid values and byte/token accounting deterministic.
  const serialized = JSON.stringify(operation.definition.inputSchema);
  if (serialized === undefined) throw new Error("invalid_provider_schema");
  return { serialized };
}

/**
 * Conservative planning estimate, not a provider-tokenizer measurement:
 * ceil(UTF-8 byte length / 3), including JSON punctuation and schema metadata.
 */
export function estimateSchemaTokens(serializedSchema: string): number {
  return Math.ceil(Buffer.byteLength(serializedSchema, "utf8") / 3);
}

/** Return read-only summaries in stable provider/connection/operation order. */
export function discoverIntegrations(
  snapshot: RunMcpSnapshot,
  query: DiscoveryQuery,
  budget: SchemaBudget,
): DiscoveryResult {
  const providerId = query.providerId?.trim();
  const terms = (query.query ?? "")
    .toLowerCase()
    .split(/\s+/u)
    .map((term) => term.trim())
    .filter((term) => term !== "");
  const matches = orderedOperations(snapshot).filter((operation) => {
    if (providerId !== undefined && providerId !== "" && operation.providerId !== providerId) {
      return false;
    }
    if (terms.length === 0) return true;
    const summary = `${operation.providerId} ${operation.connectionId} ${operation.operationId} ${operation.definition.description}`
      .toLowerCase();
    return terms.every((term) => summary.includes(term));
  });
  const results = matches.slice(0, budget.discoveryResults).map((operation) => ({
    providerId: operation.providerId,
    connectionId: operation.connectionId,
    operationId: operation.operationId,
    description: operation.definition.description,
  }));
  return { code: "ok", results, hasMore: matches.length > results.length };
}

function projectedSchema(prepared: PreparedSchema): LoadedIntegrationSchema {
  return {
    providerId: prepared.operation.providerId,
    connectionId: prepared.operation.connectionId,
    operationId: prepared.operation.operationId,
    description: prepared.operation.definition.description,
    inputSchema: JSON.parse(prepared.cached.serialized) as Record<string, unknown>,
  };
}

/**
 * Load only requested schemas from the exact activated run snapshot. Every
 * denial/overflow is atomic: no partial selection is committed or returned,
 * and no schema is cut to fit. Repeating a cached selection is not re-charged.
 * This metadata operation never invokes the operation being described.
 */
export function loadIntegrationSchema(
  snapshot: RunMcpSnapshot,
  request: IntegrationSchemaRequest,
  budget: SchemaBudget,
): SchemaResult {
  const requestedIds = new Set(request.operationIds);
  const selected = orderedOperations(snapshot).filter((operation) =>
    operation.connectionId === request.connectionId && requestedIds.has(operation.operationId)
  );
  // Unknown, unrostered, and cross-connection IDs are indistinguishable
  // denials. In particular, a request cannot mix an allowed ID with a denied one.
  if (selected.length !== requestedIds.size) return { code: "denied", loaded: [] };

  const usage = usageFor(snapshot, budget);
  const prepared: PreparedSchema[] = [];
  const newRunKeys = new Set<string>();
  const newProviderKeys = new Map<string, Set<string>>();
  let addedBytes = 0;
  let addedTokens = 0;

  for (const operation of selected) {
    const key = operationKey(operation);
    const existing = usage.loaded.get(key);
    const cacheHit = existing !== undefined;
    const cached = existing ?? serializedSchema(operation);
    const bytes = cacheHit ? 0 : Buffer.byteLength(cached.serialized, "utf8");
    const tokens = cacheHit ? 0 : estimateSchemaTokens(cached.serialized);
    if (!usage.runOperations.has(key)) newRunKeys.add(key);
    if (!usage.providerOperations.get(operation.providerId)?.has(key)) {
      const pending = newProviderKeys.get(operation.providerId) ?? new Set<string>();
      pending.add(key);
      newProviderKeys.set(operation.providerId, pending);
    }
    addedBytes += bytes;
    addedTokens += tokens;
    prepared.push({ key, operation, cached, bytes, tokens, cacheHit });
  }

  const providerOverflow = [...newProviderKeys].some(([providerId, pending]) =>
    (usage.providerOperations.get(providerId)?.size ?? 0) + pending.size > budget.operationsPerProvider
  );
  if (usage.runOperations.size + newRunKeys.size > budget.operationsPerRun ||
      providerOverflow ||
      usage.schemaBytes + addedBytes > budget.schemaBytes ||
      usage.schemaTokens + addedTokens > budget.schemaTokens) {
    return { code: "narrow_query", loaded: [] };
  }

  for (const entry of prepared) {
    if (entry.cacheHit) continue;
    usage.loaded.set(entry.key, entry.cached);
    usage.runOperations.add(entry.key);
    const providerOperations = usage.providerOperations.get(entry.operation.providerId) ?? new Set<string>();
    providerOperations.add(entry.key);
    usage.providerOperations.set(entry.operation.providerId, providerOperations);
    usage.schemaBytes += entry.bytes;
    usage.schemaTokens += entry.tokens;
  }

  return { code: "ok", loaded: prepared.map(projectedSchema) };
}
