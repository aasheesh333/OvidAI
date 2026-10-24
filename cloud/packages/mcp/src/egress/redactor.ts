export interface SecretRedactor {
  text(value: string, secrets?: readonly string[]): string;
  error(error: unknown, secrets?: readonly string[]): Error;
  json<T>(value: T, secrets?: readonly string[]): T;
}

const MARKER = "[REDACTED]";
const SECRET_NAMES = [
  "authorization",
  "proxy-authorization",
  "cookie",
  "set-cookie",
  "x-api-key",
  "api-key",
  "apikey",
  "api_key",
  "private-token",
  "x-figma-token",
  "access_token",
  "refresh_token",
  "client_secret",
  "code_verifier",
  "password",
  "secret",
  "token",
  "x-amz-security-token",
  "x-amz-credential",
  "x-amz-signature",
  "signature",
  "sig",
] as const;
const SECRET_NAME_PATTERN = SECRET_NAMES.join("|");
const SENSITIVE_KEYS = new Set<string>(SECRET_NAMES);

function variants(secrets: readonly string[]): string[] {
  const values = new Set<string>();
  for (const secret of secrets) {
    if (secret === "") continue;
    values.add(secret);
    values.add(encodeURIComponent(secret));
    values.add(new URLSearchParams({ value: secret }).toString().slice("value=".length));
    values.add(JSON.stringify(secret).slice(1, -1));
    values.add(Buffer.from(secret, "utf8").toString("base64"));
  }
  values.delete("");
  return [...values].sort((a, b) => b.length - a.length);
}

function redactSignedUrls(value: string): string {
  return value.replace(/\bhttps?:\/\/[^\s<>"']+/gi, (url) => {
    return /[?&](?:x-amz-signature|signature|sig)=/i.test(url) ? MARKER : url;
  });
}

function redactNamedValues(value: string): string {
  let output = value;
  // Header-shaped lines: the entire value is sensitive, including every
  // cookie pair rather than just the first one.
  output = output.replace(
    new RegExp(
      `^(\\s*(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key|api-key|apikey|private-token|x-figma-token|x-amz-security-token)\\s*:\\s*)[^\\r\\n]*`,
      "gim",
    ),
    (_match, prefix: string) => prefix + MARKER,
  );
  // JSON or header-like text embedded in an upstream error. Preserve a quote
  // when one was present so already-JSON text remains parseable.
  output = output.replace(
    new RegExp(
      `((?:"|')?(?:${SECRET_NAME_PATTERN})(?:"|')?\\s*:\\s*)(["']?)([^"'\\r\\n,}]+)\\2`,
      "gi",
    ),
    (_match, prefix: string, quote: string) => prefix + quote + MARKER + quote,
  );
  // Query strings and URL-encoded forms. This deliberately includes both
  // snake_case and common signed-AWS parameter names.
  output = output.replace(
    new RegExp(`([?&]|^)(${SECRET_NAME_PATTERN})=([^&#\\s}"']+)`, "gim"),
    (_match, prefix: string, key: string) => `${prefix}${key}=${MARKER}`,
  );
  return output;
}

function text(value: string, secrets: readonly string[] = []): string {
  let output = value;
  for (const secret of variants(secrets)) output = output.split(secret).join(MARKER);
  output = redactSignedUrls(output);
  return redactNamedValues(output);
}

function sensitiveKey(key: string): boolean {
  const lower = key.toLowerCase();
  return SENSITIVE_KEYS.has(lower) || SENSITIVE_KEYS.has(lower.replace(/-/g, "_"));
}

function project(value: unknown, secrets: readonly string[]): unknown {
  const seen = new WeakSet<object>();
  let visited = 0;

  const walk = (current: unknown, depth: number): unknown => {
    if (typeof current === "string") return text(current, secrets);
    if (current === null || typeof current !== "object") return current;
    if (depth > 32 || visited > 10_000 || seen.has(current)) return MARKER;
    seen.add(current);
    visited++;
    if (Array.isArray(current)) return current.map((entry) => walk(entry, depth + 1));
    const output: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(current)) {
      const safeKey = text(key, secrets);
      output[safeKey] = sensitiveKey(key) ? MARKER : walk(entry, depth + 1);
    }
    return output;
  };

  return walk(value, 0);
}

export function createSecretRedactor(): SecretRedactor {
  return {
    text: (value, secrets = []) => text(value, secrets),
    error: (error, secrets = []) => {
      const message = error instanceof Error ? error.message : String(error);
      // A provider's stack is diagnostic input, never a user-facing trace.
      const withoutStack = message
        .split(/\r?\n/)
        .filter((line) => !/^\s*at\s+\S/.test(line))
        .join("\n");
      const projected = new Error(text(withoutStack, secrets));
      projected.name = "Error";
      projected.stack = undefined;
      return projected;
    },
    json: <T>(value: T, secrets: readonly string[] = []): T => project(value, secrets) as T,
  };
}
