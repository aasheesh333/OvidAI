import type { ActivationRevalidation, RunMcpSnapshot } from "./activation.js";
import { ConnectionHealthError } from "./health.js";
import type {
  ConnectionHealthLifecycle,
  HealthConnection,
  HealthTransition,
} from "./health.js";

/** Constructed only from the framework's already-authenticated request principal. */
export interface VerifiedConnectionHealthPrincipal {
  uid: string;
  authenticated: boolean;
}

export interface AuthenticatedConnectionHealthRequest {
  principal: VerifiedConnectionHealthPrincipal;
  connectionId: string;
  operationId: string;
}

export interface AuthenticatedConnectionDisconnectRequest {
  principal: VerifiedConnectionHealthPrincipal;
  connectionId: string;
}

export interface SelectedConnectionHealthRequest {
  snapshot: RunMcpSnapshot;
  uid: string;
  connectionId: string;
  operationId: string;
}

export type ConnectionHealthInvocationErrorCode =
  | "authentication_required"
  | "operation_not_selected"
  | "connection_changed"
  | "unavailable";

export class ConnectionHealthInvocationError extends Error {
  constructor(readonly code: ConnectionHealthInvocationErrorCode) {
    super(code);
    this.name = "ConnectionHealthInvocationError";
  }
}

export interface ConnectionHealthInvocations {
  /** Explicit user action; the route supplies its verified principal, never a model uid. */
  checkAuthenticated(request: AuthenticatedConnectionHealthRequest): Promise<HealthTransition>;
  /** Live persisted + in-process transient projection for an authenticated DTO read. */
  getAuthenticated(request: AuthenticatedConnectionDisconnectRequest): Promise<HealthConnection>;
  /** Authenticated generation bump, refresh abort, and owned transport cleanup. */
  disconnectAuthenticated(request: AuthenticatedConnectionDisconnectRequest): Promise<HealthConnection>;
  /** Lazy need for one exact operation selected in the current root/child snapshot. */
  checkSelectedOperation(request: SelectedConnectionHealthRequest): Promise<HealthTransition>;
}

export interface ConnectionHealthInvocationDeps {
  lifecycle: Pick<ConnectionHealthLifecycle, "checkConnectionHealth"> &
    Partial<Pick<ConnectionHealthLifecycle, "getConnectionHealth" | "disconnectConnection">>;
  revalidate(
    snapshot: RunMcpSnapshot,
    call: { connectionId: string; operationId: string },
  ): Promise<ActivationRevalidation>;
}

function validId(value: string): boolean {
  return value.trim() !== "" && value.length <= 256;
}

function assertPrincipal(request: AuthenticatedConnectionDisconnectRequest): void {
  if (!request.principal.authenticated || !validId(request.principal.uid) ||
      !validId(request.connectionId)) {
    throw new ConnectionHealthInvocationError("authentication_required");
  }
}

/**
 * Narrow composition surface for the authenticated route and selected lazy
 * operation adapter. No roster/discovery function accepts or calls this object.
 */
export function createConnectionHealthInvocations(
  deps: ConnectionHealthInvocationDeps,
): ConnectionHealthInvocations {
  return {
    async checkAuthenticated(request) {
      assertPrincipal(request);
      if (!validId(request.operationId)) {
        throw new ConnectionHealthInvocationError("authentication_required");
      }
      return deps.lifecycle.checkConnectionHealth(
        request.connectionId,
        request.principal.uid,
        request.operationId,
      );
    },

    async getAuthenticated(request) {
      assertPrincipal(request);
      if (deps.lifecycle.getConnectionHealth === undefined) {
        throw new ConnectionHealthInvocationError("unavailable");
      }
      return deps.lifecycle.getConnectionHealth(request.connectionId, request.principal.uid);
    },

    async disconnectAuthenticated(request) {
      assertPrincipal(request);
      if (deps.lifecycle.disconnectConnection === undefined) {
        throw new ConnectionHealthInvocationError("unavailable");
      }
      return deps.lifecycle.disconnectConnection(request.connectionId, request.principal.uid);
    },

    async checkSelectedOperation(request) {
      const selected = request.snapshot.operations.some((operation) =>
        operation.connectionId === request.connectionId &&
        operation.operationId === request.operationId
      );
      if (!selected || !validId(request.uid)) {
        throw new ConnectionHealthInvocationError("operation_not_selected");
      }
      try {
        const verdict = await deps.revalidate(request.snapshot, {
          connectionId: request.connectionId,
          operationId: request.operationId,
        });
        if (verdict === "stale") throw new ConnectionHealthInvocationError("connection_changed");
        if (verdict !== "current") throw new ConnectionHealthInvocationError("operation_not_selected");
        return await deps.lifecycle.checkConnectionHealth(
          request.connectionId,
          request.uid,
          request.operationId,
        );
      } catch (error) {
        if (error instanceof ConnectionHealthInvocationError || error instanceof ConnectionHealthError) {
          throw error;
        }
        throw new ConnectionHealthInvocationError("unavailable");
      }
    },
  };
}
