import {
  ConnectionHealthError,
  ConnectionHealthInvocationError,
  type ConnectionHealthInvocations,
  type HealthConnection,
  type HealthTransition,
  type SelectedConnectionHealthRequest,
} from "@ovid/mcp";
import type { ProviderHealthState } from "@ovid/shared";

const MAX_HEALTH_RESPONSE_BYTES = 65_536;
const AUTH_STATES = new Set(["missing", "configured", "needs_auth", "authorized", "revoked"]);
const HEALTH_STATES = new Set<ProviderHealthState>([
  "never_checked", "checking", "healthy", "degraded", "needs_auth",
  "refreshing", "revoked", "unavailable", "disabled",
]);
const CONNECTION_KEYS = new Set([
  "connectionId", "userId", "providerId", "enabled", "agentEnabled", "authState",
  "healthState", "lastCheckedAt", "lastSuccessAt", "configVersion",
  "disconnectGeneration", "hasSecrets",
]);

export interface ConnectionHealthClientConfig {
  baseUrl: string;
  token: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function boundedString(value: unknown, nullable = false): boolean {
  return (nullable && value === null) || (typeof value === "string" && value.length <= 4_096);
}

function parseConnection(value: unknown): HealthConnection {
  const candidate = record(value);
  if (candidate === null || Object.keys(candidate).some((key) => !CONNECTION_KEYS.has(key)) ||
      !boundedString(candidate.connectionId) || !boundedString(candidate.userId) ||
      !boundedString(candidate.providerId) || typeof candidate.enabled !== "boolean" ||
      typeof candidate.agentEnabled !== "boolean" || typeof candidate.authState !== "string" ||
      !AUTH_STATES.has(candidate.authState) ||
      typeof candidate.healthState !== "string" || !HEALTH_STATES.has(candidate.healthState as ProviderHealthState) ||
      !boundedString(candidate.lastCheckedAt, true) || !boundedString(candidate.lastSuccessAt, true) ||
      typeof candidate.configVersion !== "number" || !Number.isInteger(candidate.configVersion) ||
      typeof candidate.disconnectGeneration !== "number" || !Number.isInteger(candidate.disconnectGeneration) ||
      (candidate.configVersion as number) < 0 || (candidate.disconnectGeneration as number) < 0 ||
      typeof candidate.hasSecrets !== "boolean") {
    throw new ConnectionHealthError("unavailable");
  }
  return candidate as unknown as HealthConnection;
}

function parseTransition(value: unknown): HealthTransition {
  const candidate = record(value);
  if (candidate === null || typeof candidate.from !== "string" || !HEALTH_STATES.has(candidate.from as ProviderHealthState) ||
      typeof candidate.to !== "string" || !HEALTH_STATES.has(candidate.to as ProviderHealthState) ||
      !boundedString(candidate.lastCheckedAt, true) || !boundedString(candidate.lastSuccessAt, true) ||
      typeof candidate.persisted !== "boolean" || !boundedString(candidate.code) ||
      (candidate.reason !== undefined && !boundedString(candidate.reason))) {
    throw new ConnectionHealthError("unavailable");
  }
  return {
    connection: parseConnection(candidate.connection),
    from: candidate.from as ProviderHealthState,
    to: candidate.to as ProviderHealthState,
    lastCheckedAt: candidate.lastCheckedAt as string | null,
    lastSuccessAt: candidate.lastSuccessAt as string | null,
    persisted: candidate.persisted,
    code: candidate.code as HealthTransition["code"],
    ...(candidate.reason === undefined ? {} : { reason: candidate.reason as HealthTransition["reason"] }),
  };
}

async function boundedJson(response: Response): Promise<unknown> {
  const declared = Number(response.headers.get("content-length") ?? "0");
  if (declared > MAX_HEALTH_RESPONSE_BYTES || response.body === null) {
    await response.body?.cancel().catch(() => {});
    throw new ConnectionHealthError("unavailable");
  }
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let bytes = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      bytes += next.value.byteLength;
      if (bytes > MAX_HEALTH_RESPONSE_BYTES) {
        await reader.cancel();
        throw new ConnectionHealthError("unavailable");
      }
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)));
  } catch {
    throw new ConnectionHealthError("unavailable");
  }
}

/** Typed gateway→worker lifecycle client; no local secret or runtime cache. */
export function createConnectionHealthClient(
  cfg: ConnectionHealthClientConfig,
): ConnectionHealthInvocations {
  const base = cfg.baseUrl.replace(/\/+$/, "");
  const fetchImpl = cfg.fetchImpl ?? globalThis.fetch;
  const timeoutMs = cfg.timeoutMs ?? 70_000;

  async function request<T>(
    method: "GET" | "POST" | "DELETE",
    uid: string,
    connectionId: string,
    operationId: string | undefined,
    parse: (value: unknown) => T,
  ): Promise<T> {
    let response: Response;
    try {
      response = await fetchImpl(`${base}/internal/mcp/connections/${encodeURIComponent(connectionId)}${
        method === "DELETE" ? "" : "/health"
      }`, {
        method,
        headers: {
          "x-ovid-internal-token": cfg.token,
          "x-ovid-user-id": uid,
          ...(operationId === undefined ? {} : { "content-type": "application/json" }),
        },
        ...(operationId === undefined ? {} : { body: JSON.stringify({ operationId }) }),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch {
      throw new ConnectionHealthError("unavailable");
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      if (response.status === 404) throw new ConnectionHealthError("not_found");
      if (response.status === 409) throw new ConnectionHealthError("connection_changed");
      throw new ConnectionHealthError("unavailable");
    }
    return parse(await boundedJson(response));
  }

  function assertAuthenticated(authenticated: boolean): void {
    if (!authenticated) throw new ConnectionHealthInvocationError("authentication_required");
  }

  return {
    checkAuthenticated(request) {
      assertAuthenticated(request.principal.authenticated);
      return request("POST", request.principal.uid, request.connectionId, request.operationId, parseTransition);
    },
    getAuthenticated(request) {
      assertAuthenticated(request.principal.authenticated);
      return request("GET", request.principal.uid, request.connectionId, undefined, parseConnection);
    },
    disconnectAuthenticated(request) {
      assertAuthenticated(request.principal.authenticated);
      return request("DELETE", request.principal.uid, request.connectionId, undefined, parseConnection);
    },
    async checkSelectedOperation(_request: SelectedConnectionHealthRequest): Promise<HealthTransition> {
      // Lazy snapshots are worker-local and never traverse this gateway client.
      throw new ConnectionHealthInvocationError("unavailable");
    },
  };
}
