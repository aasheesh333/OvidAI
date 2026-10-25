import { randomUUID } from "node:crypto";

import type { ProviderConnectionState } from "@ovid/shared";

import {
  assertClosedProviderSchema,
  type ProviderDefinition,
  type ProviderOperation,
  type RunPolicy,
} from "./providers/types.js";
import { canonicalToolId, toolNameFor } from "./toolNames.js";
import type { SecretRedactor } from "./egress/redactor.js";
import type { ProviderEgress } from "./egress/providerEgress.js";
import { createCuratedCatalogProjection, type CuratedCatalogDeps } from "./catalog.js";
import { createRestHandler } from "./rest/engine.js";
import type { NativeMcpHandler } from "./transports/native.js";
import { PRODUCTION_PROVIDER_REGISTRY } from "./providerProduction.js";
import type { ProviderRegistry } from "./providers/registry.js";

/** The exact non-secret operation record carried by a root or child run. */
export interface ActivatedOperation {
  connectionId: string;
  providerId: string;
  operationId: string;
  modelName: string;
  definition: ProviderOperation;
  configVersion: number;
  disconnectGeneration: number;
}

/** A generation-fenced, per-run roster. It never contains connection config or secrets. */
export interface RunMcpSnapshot {
  generation: string;
  operations: readonly ActivatedOperation[];
}

export interface SnapshotForRunInput extends RunPolicy {
  userId: string;
  runId: string;
  sessionId: string;
  isSubagent: boolean;
  parent?: RunMcpSnapshot;
  allow: readonly string[];
  deny: readonly string[];
}

export type ActivationRevalidation = "current" | "stale" | "denied";

export interface ActivationService {
  snapshotForRun(input: SnapshotForRunInput): Promise<RunMcpSnapshot>;
  revalidate(
    snapshot: RunMcpSnapshot,
    call: { connectionId: string; operationId: string },
  ): Promise<ActivationRevalidation>;
  closeRun(runId: string): Promise<void>;
}

/** Task 1's current connection facts; secret/config columns deliberately have no place here. */
export interface ActivationConnection {
  connectionId: string;
  userId: string;
  providerId: string;
  enabled: boolean;
  agentEnabled: boolean;
  authState: ProviderConnectionState["authState"];
  configVersion: number;
  disconnectGeneration: number;
}

export type ActivationProvider = Pick<
  ProviderDefinition,
  "providerId" | "operations" | "readiness"
>;

export interface ActivationServiceDeps {
  /** The supported registry. Candidate/blocked/deprecated rows are not accepted. */
  readonly definitions: readonly ActivationProvider[];
  /** Must query only the supplied user's rows. Returned rows contain no plaintext secrets. */
  listConnections(userId: string): Promise<readonly ActivationConnection[]>;
  /** Task 1's conditional current-row/version/activation fence. */
  revalidateConnection(call: {
    connectionId: string;
    userId: string;
    configVersion: number;
    disconnectGeneration: number;
  }): Promise<ActivationRevalidation>;
  /** Releases resources owned by this run, never process-wide provider singletons. */
  closeRun?(runId: string): Promise<void>;
}

interface SnapshotOwner {
  userId: string;
  runId: string;
  closed: boolean;
}

function matches(entry: string, operation: ActivatedOperation): boolean {
  if (entry === "*") return true;
  const canonical = canonicalToolId(operation.connectionId, operation.operationId);
  const candidates = [operation.modelName, canonical];
  if (entry.endsWith("*") && entry.length > 1) {
    const prefix = entry.slice(0, -1);
    return candidates.some((candidate) => candidate.startsWith(prefix));
  }
  return candidates.includes(entry);
}

function policyAdmits(
  operation: ActivatedOperation,
  input: Pick<SnapshotForRunInput, "allow" | "deny">,
): boolean {
  if (input.deny.some((entry) => matches(entry, operation))) return false;
  return input.allow.length === 0 || input.allow.some((entry) => matches(entry, operation));
}

function runPolicyAdmits(operation: ProviderOperation, policy: RunPolicy): boolean {
  const highRisk = operation.effect === "external_communication" ||
    operation.effect === "financial" || operation.effect === "deployment" ||
    operation.effect === "destructive";
  if (operation.custom === true && (policy.planMode || policy.unattended)) return false;
  if (highRisk && (policy.planMode || policy.unattended)) return false;
  if (policy.planMode && operation.effect !== "read") return false;
  if (policy.unattended &&
      (operation.approval !== "mode" || operation.effect === "credential_use")) return false;
  return true;
}

function authReady(row: ActivationConnection): boolean {
  return row.enabled && row.agentEnabled &&
    (row.authState === "configured" || row.authState === "authorized");
}

function freezeSnapshot(
  generation: string,
  operations: readonly ActivatedOperation[],
): RunMcpSnapshot {
  return Object.freeze({
    generation,
    operations: Object.freeze(operations.map((operation) => Object.freeze(operation))),
  });
}

export function createActivationService(deps: ActivationServiceDeps): ActivationService {
  const definitions = new Map<string, ActivationProvider>();
  for (const definition of deps.definitions) {
    if (definition.providerId.trim() === "" || definition.readiness !== "supported" ||
        definition.operations.length === 0) {
      throw new Error("invalid_supported_provider");
    }
    if (definitions.has(definition.providerId)) {
      throw new Error(`duplicate_provider:${definition.providerId}`);
    }
    const operationNames = new Set<string>();
    for (const operation of definition.operations) {
      if (operation.name.trim() === "" || operationNames.has(operation.name)) {
        throw new Error(`duplicate_operation:${definition.providerId}/${operation.name}`);
      }
      assertClosedProviderSchema(operation.inputSchema);
      operationNames.add(operation.name);
    }
    definitions.set(definition.providerId, definition);
  }

  // Weak object identity prevents generation-string forgery. The run map is
  // only for close iteration; parent objects stay weakly reachable for an
  // in-flight supervisor's later child turns without a global retention leak.
  const owners = new WeakMap<RunMcpSnapshot, SnapshotOwner>();
  const runSnapshots = new Map<string, Set<RunMcpSnapshot>>();

  function register(snapshot: RunMcpSnapshot, input: SnapshotForRunInput): RunMcpSnapshot {
    owners.set(snapshot, { userId: input.userId, runId: input.runId, closed: false });
    const owned = runSnapshots.get(input.runId) ?? new Set<RunMcpSnapshot>();
    owned.add(snapshot);
    runSnapshots.set(input.runId, owned);
    return snapshot;
  }

  function assertNoCollision(
    modelNames: Map<string, string>,
    operation: ActivatedOperation,
  ): void {
    const existing = modelNames.get(operation.modelName);
    const pair = `${operation.connectionId}/${operation.operationId}`;
    if (existing !== undefined && existing !== pair) {
      throw new Error(`model_name_collision:${operation.modelName}`);
    }
    modelNames.set(operation.modelName, pair);
  }

  async function revalidateOwned(
    snapshot: RunMcpSnapshot,
    owner: SnapshotOwner,
    operation: ActivatedOperation,
  ): Promise<ActivationRevalidation> {
    const definition = definitions.get(operation.providerId);
    if (definition === undefined || !definition.operations.some(
      (candidate) => candidate.name === operation.operationId,
    )) return "denied";
    return deps.revalidateConnection({
      connectionId: operation.connectionId,
      userId: owner.userId,
      configVersion: operation.configVersion,
      disconnectGeneration: operation.disconnectGeneration,
    });
  }

  return {
    async snapshotForRun(input) {
      const modelNames = new Map<string, string>();

      if (input.isSubagent) {
        const parent = input.parent;
        const parentOwner = parent === undefined ? undefined : owners.get(parent);
        if (parent === undefined || parentOwner === undefined || parentOwner.userId !== input.userId) {
          return register(freezeSnapshot(randomUUID(), []), input);
        }
        const operations: ActivatedOperation[] = [];
        for (const operation of parent.operations) {
          if (!runPolicyAdmits(operation.definition, input) || !policyAdmits(operation, input)) {
            continue;
          }
          // A child inherits only the parent's exact pair and non-secret definition.
          // It never lists or resolves a connection, and current-row revocation applies now.
          if (await revalidateOwned(parent, parentOwner, operation) !== "current") continue;
          assertNoCollision(modelNames, operation);
          operations.push(operation);
        }
        return register(freezeSnapshot(randomUUID(), operations), input);
      }

      const rows = await deps.listConnections(input.userId);
      const operations: ActivatedOperation[] = [];
      for (const row of rows) {
        if (row.userId !== input.userId || !authReady(row)) continue;
        const definition = definitions.get(row.providerId);
        if (definition === undefined) continue;
        for (const definitionOperation of definition.operations) {
          if (!runPolicyAdmits(definitionOperation, input)) continue;
          const operation: ActivatedOperation = {
            connectionId: row.connectionId,
            providerId: row.providerId,
            operationId: definitionOperation.name,
            modelName: toolNameFor(row.providerId, definitionOperation.name),
            definition: definitionOperation,
            configVersion: row.configVersion,
            disconnectGeneration: row.disconnectGeneration,
          };
          if (!policyAdmits(operation, input)) continue;
          assertNoCollision(modelNames, operation);
          operations.push(operation);
        }
      }
      return register(freezeSnapshot(randomUUID(), operations), input);
    },

    async revalidate(snapshot, call) {
      const owner = owners.get(snapshot);
      if (owner === undefined || owner.closed) return "denied";
      const operation = snapshot.operations.find(
        (candidate) => candidate.connectionId === call.connectionId &&
          candidate.operationId === call.operationId,
      );
      if (operation === undefined) return "denied";
      return revalidateOwned(snapshot, owner, operation);
    },

    async closeRun(runId) {
      const snapshots = runSnapshots.get(runId);
      if (snapshots !== undefined) {
        for (const snapshot of snapshots) {
          const owner = owners.get(snapshot);
          if (owner !== undefined) owner.closed = true;
        }
        runSnapshots.delete(runId);
      }
      await deps.closeRun?.(runId);
    },
  };
}

/** Runtime support is projected exclusively from validated readiness rows. */
export interface CuratedProviderSupport {
  registry: ProviderRegistry;
  definitions: readonly ActivationProvider[];
  origins: Readonly<Record<string, readonly URL[]>>;
  handlerOverrides(
    egress: ProviderEgress,
    redactor?: SecretRedactor,
  ): CuratedCatalogDeps["handlerOverrides"];
}

export function createCuratedProviderSupport(
  registry: ProviderRegistry = PRODUCTION_PROVIDER_REGISTRY,
): CuratedProviderSupport {
  const projection = createCuratedCatalogProjection(registry);
  return {
    registry,
    definitions: projection.definitions,
    origins: projection.origins,
    handlerOverrides(egress, redactor) {
      return Object.fromEntries(projection.genericDescriptors.map((descriptor) => [
        descriptor.curatedId,
        (): NativeMcpHandler => createRestHandler(descriptor, {
          providerEgress: egress,
          ...(redactor !== undefined ? { redactor } : {}),
        }),
      ]));
    },
  };
}
