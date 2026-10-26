import { createHash } from "node:crypto";

/**
 * Task 11's pure central projection-redaction seam. Task 10 can pass this same
 * function into its bounded recall adapter; raw storage is never a dependency.
 * Both values and secret-bearing JSON property names are projected.
 */
export interface ProjectionRedactionPolicy {
  secretValues: readonly string[];
  providerBaseUrls: readonly string[];
}

export type ProjectionRedactor = (
  value: unknown,
  policy: ProjectionRedactionPolicy,
) => unknown;

export const EMPTY_REDACTION_POLICY: ProjectionRedactionPolicy = {
  secretValues: [],
  providerBaseUrls: [],
};

const SECRET_KEYS = new Set([
  "authorization", "proxyauthorization", "token", "accesstoken", "refreshtoken", "idtoken",
  "apikey", "xapikey", "secret", "secretkey", "clientsecret", "password", "cookie", "setcookie",
  "signature", "credential", "xamzsignature", "xamzcredential", "xamzsecuritytoken", "googsignature",
  "thought", "thoughts", "thinking", "reasoning", "privatethought", "privatethoughts",
]);

function normalizedKey(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/g, "");
}

export function sensitiveProjectionKey(key: string): boolean {
  const normalized = normalizedKey(key);
  return SECRET_KEYS.has(normalized) || normalized.endsWith("apitoken") ||
    normalized.endsWith("accesstoken") || normalized.endsWith("refreshtoken") ||
    normalized.endsWith("apikey") || normalized.endsWith("clientsecret") ||
    normalized.endsWith("privatekey") || normalized.endsWith("signature") ||
    normalized.endsWith("credential") || normalized.endsWith("token") ||
    normalized === "providerbaseurl" || normalized === "baseurl";
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function replaceSecretForms(text: string, secret: string): string {
  if (secret.length === 0) return text;
  let projected = text.replace(new RegExp(escapeRegExp(secret), "g"), "[redacted]");
  try {
    const encoded = encodeURIComponent(secret);
    if (encoded !== secret) {
      projected = projected.replace(new RegExp(escapeRegExp(encoded), "gi"), "[redacted]");
    }
  } catch {
    return "[redacted]";
  }
  const base64 = Buffer.from(secret, "utf8").toString("base64");
  if (base64.length > 0) {
    projected = projected.replace(new RegExp(escapeRegExp(base64), "g"), "[redacted]");
  }
  return projected;
}

const JSON_PROPERTY_PREFIX = /^\s*\{?\s*"([A-Za-z][A-Za-z0-9_-]*)"\s*:/;

/** Apply the same exact/suffix key semantics to a decodable JSON-string primitive. */
function sensitiveJsonPrimitiveText(value: string): boolean {
  const match = JSON_PROPERTY_PREFIX.exec(value);
  return match?.[1] !== undefined && sensitiveProjectionKey(match[1]);
}

/** Redact unavoidable text; JSON structure is handled by redactForProjection. */
export function redactProjectionText(
  input: string,
  policy: ProjectionRedactionPolicy = EMPTY_REDACTION_POLICY,
): string {
  // A JSON-string primitive such as "token":"…" is still structured data at
  // this boundary. Token-count fields (inputTokens) and prose are unaffected.
  if (sensitiveJsonPrimitiveText(input)) return "[redacted]";
  let text = input;
  for (const secret of [...policy.secretValues, ...policy.providerBaseUrls]) {
    text = replaceSecretForms(text, secret);
  }
  text = text
    .replace(/github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9]+|(?:sk|rk|pk)-[A-Za-z0-9_-]{4,}/g, "[redacted]")
    .replace(/\bBearer\s+[^\s,;]+/gi, "Bearer [redacted]")
    .replace(/\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\b/g, "[redacted]");

  // Encoded URLs are decoded only for projection and are never returned in
  // their original signed/provider form.
  text = text.replace(/https?%3A%2F%2F[^\s<>"']+/gi, (encoded) => {
    try {
      return encodeURIComponent(redactProjectionText(decodeURIComponent(encoded), policy));
    } catch {
      return "[redacted]";
    }
  });
  // Provider base URLs and signed URLs are deployment capabilities, not safe
  // display data. There is no hostname allowlist at this trust boundary.
  text = text.replace(/https?:\/\/[^\s<>"']+/gi, "[redacted]");
  text = text.replace(
    /(^|\r?\n)\s*([A-Za-z][A-Za-z0-9-]*)\s*:\s*[^\r\n]+/g,
    (header, prefix: string, key: string) =>
      sensitiveProjectionKey(key) ? `${prefix}${key}: [redacted]` : header,
  );
  return text.replace(
    /\b((?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|signature|sig|key)=)[^\s&]+/gi,
    "$1[redacted]",
  );
}

/**
 * Recursively redact a projection without retaining full secret-bearing keys.
 * A changed key is collision-safe and the original key is never serialized.
 */
export function redactForProjection(
  value: unknown,
  policy: ProjectionRedactionPolicy = EMPTY_REDACTION_POLICY,
): unknown {
  if (Array.isArray(value)) return value.map((entry) => redactForProjection(entry, policy));
  if (typeof value === "string") return redactProjectionText(value, policy);
  if (typeof value === "object" && value !== null) {
    const entries: Array<[string, unknown]> = [];
    const used = new Set<string>();
    for (const [originalKey, entry] of Object.entries(value as Record<string, unknown>)) {
      let key = redactProjectionText(originalKey, policy);
      if (used.has(key)) {
        const suffix = createHash("sha256").update(originalKey).digest("hex").slice(0, 12);
        key = `${key}-${suffix}`;
      }
      used.add(key);
      entries.push([
        key,
        sensitiveProjectionKey(originalKey) ? "[redacted]" : redactForProjection(entry, policy),
      ]);
    }
    return Object.fromEntries(entries);
  }
  return value;
}
