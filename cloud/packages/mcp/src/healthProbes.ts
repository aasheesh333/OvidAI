import { validateProviderArgs, type ProviderOperation } from "./providers/types.js";

/**
 * Reviewed, bounded health-probe inputs by provider family. This is an
 * allowlist, not a provider-wide readiness claim: absent operations remain
 * unavailable instead of receiving fabricated resource coordinates or a
 * generic ping. Static-token/OAuth status is never used as probe evidence.
 */
const SAFE_PROBE_ARGS: Readonly<Record<string, Readonly<Record<string, Readonly<Record<string, unknown>>>>>> = Object.freeze({
  github: Object.freeze({
    // GET /user requires no tenant/repository coordinates.
    get_user: Object.freeze({}),
  }),
  cloudflare: Object.freeze({
    // One bounded first page through the actual Zone Read operation.
    list_zones: Object.freeze({ page: 1, per_page: 5 }),
  }),
  vercel: Object.freeze({
    // One project through the actual v10 list operation; no deployment action.
    list_projects: Object.freeze({ limit: 1 }),
  }),
  "google-drive": Object.freeze({
    // Bounded metadata search through the real Drive read operation.
    search: Object.freeze({}),
  }),
});

const DEFAULT_OPERATION: Readonly<Record<string, string>> = Object.freeze({
  fetch: "fetch",
  github: "get_user",
  cloudflare: "list_zones",
  vercel: "list_projects",
  "google-drive": "search",
});

export interface HealthProbeInput {
  providerId: string;
  operation: ProviderOperation;
  /** Non-secret connection config only; never decrypted secrets. */
  config: Record<string, unknown> | null;
}

export function defaultHealthOperationId(providerId: string): string | null {
  return DEFAULT_OPERATION[providerId] ?? null;
}

export function healthProbeArgs(input: HealthProbeInput): Record<string, unknown> | null {
  if (input.providerId === "fetch" && input.operation.name === "fetch") {
    const url = input.config?.url;
    if (typeof url !== "string" || url === "" || url.length > 2_048) return null;
    try {
      const parsed = new URL(url);
      if (parsed.protocol !== "https:" || parsed.username !== "" || parsed.password !== "" ||
          (parsed.port !== "" && parsed.port !== "443")) return null;
      return { url, max_length: 1_000 };
    } catch {
      return null;
    }
  }

  const candidate = SAFE_PROBE_ARGS[input.providerId]?.[input.operation.name];
  if (candidate === undefined) return null;
  const args = structuredClone(candidate);
  return validateProviderArgs(input.operation.inputSchema, args).ok ? args : null;
}
