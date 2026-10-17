/**
 * Provider endpoint validation and canonicalization.
 *
 * Verbatim wire-contract port of `server/sync/endpoints.py` (P9 D3): an
 * endpoint value is portable metadata, not an arbitrary URL. `validateEndpoint`
 * returns a canonical credential-free identity or throws
 * `EndpointRejectedError` — and it NEVER echoes the input.
 *
 * The validator is deliberately hand-written over a printable-ASCII grammar
 * rather than delegating to the WHATWG URL parser, whose lenient parsing
 * (backslashes, missing slashes, whitespace stripping) is a known source of
 * parser confusion. Every rule below mirrors the Python service exactly.
 */

export const MAX_ENDPOINT_LENGTH = 2048;

export type EndpointScheme = "https" | "http";

export interface EndpointPolicy {
  /** May only widen https to http; no other scheme is an endpoint identity. */
  allowedSchemes: ReadonlySet<EndpointScheme>;
  /** Lower-case, percent-decoded query names the provider proves are not secret. */
  nonSecretQueryKeys: ReadonlySet<string>;
}

/** HTTPS-only default (the Python DEFAULT_POLICY). */
export const DEFAULT_ENDPOINT_POLICY: EndpointPolicy = {
  allowedSchemes: new Set<EndpointScheme>(["https"]),
  nonSecretQueryKeys: new Set<string>(),
};

/** Fixed message, identical to SyncError("endpoint_rejected"). */
const REJECTED_MESSAGE = "The provider endpoint is not an allowed endpoint identity.";

/**
 * Typed rejection. The message is fixed and the constructor takes NO input, so
 * request bodies, endpoints and credentials can never be echoed.
 */
export class EndpointRejectedError extends Error {
  readonly code = "endpoint_rejected" as const;

  constructor() {
    super(REJECTED_MESSAGE);
    this.name = "EndpointRejectedError";
  }
}

/** Internal sentinel: every rejection path funnels through it. */
class Reject extends Error {}

const SUPPORTED_SCHEMES: Readonly<Record<EndpointScheme, number>> = {
  https: 443,
  http: 80,
};

// Printable ASCII minus characters that are never valid unescaped in a URL or
// that enable parser confusion. '#' is excluded so any fragment is rejected.
const FORBIDDEN = new Set(['\\', '<', '>', '"', '{', '}', '|', '^', '`', '#']);

const URL_RE = /^([A-Za-z][A-Za-z0-9+.\-]*):\/\/([^/?]*)([^?]*)(?:\?(.*))?$/s;
const PORT_RE = /^[0-9]{1,5}$/;
const LABEL_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;
const PCT_RE = /%([0-9A-Fa-f]{2})/g;
const BAD_PCT_RE = /%(?![0-9A-Fa-f]{2})/;
const HEX_GROUP_RE = /^[0-9A-Fa-f]{1,4}$/;
const DIGITS_RE = /^[0-9]+$/;

const UNRESERVED = new Set(
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~",
);

// Matched against the percent-decoded, lower-cased name with every
// non-alphanumeric character removed ("API%5FKey" -> "apikey").
const SENSITIVE_NAME_PARTS = [
  "key",
  "token",
  "secret",
  "passw",
  "pwd",
  "auth",
  "sig",
  "credential",
  "bearer",
  "jwt",
  "session",
  "cookie",
] as const;
const SENSITIVE_EXACT = new Set(["pass", "otp"]);

// Well-known credential value shapes, checked in decoded path and query text.
// `bearer\s` is case-insensitive in the Python source (the rest is not), so it
// is a separate test below rather than a global `i` flag.
const SECRET_VALUES_RE =
  /sk-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{30,}|xox[abprs]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/;
const BEARER_RE = /bearer\s/i;

const AZURE_PROVIDERS = new Set(["azure", "azureopenai"]);

/**
 * Return the canonical credential-free identity for `value`.
 *
 * `opts.policy` (explicit) wins over `opts.policies[providerId]`; otherwise
 * the HTTPS-only default applies.
 */
export function validateEndpoint(
  value: unknown,
  providerId: string,
  opts: {
    policy?: EndpointPolicy;
    policies?: Record<string, EndpointPolicy>;
  } = {},
): string {
  const policy =
    opts.policy ?? opts.policies?.[providerId] ?? DEFAULT_ENDPOINT_POLICY;
  try {
    return canonicalize(value, policy, providerId);
  } catch {
    throw new EndpointRejectedError();
  }
}

function canonicalize(
  value: unknown,
  policy: EndpointPolicy,
  providerId: string,
): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > MAX_ENDPOINT_LENGTH
  ) {
    throw new Reject();
  }
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code < 0x21 || code > 0x7e || FORBIDDEN.has(value[i]!)) {
      throw new Reject();
    }
  }

  const match = URL_RE.exec(value);
  if (match === null) throw new Reject();
  const scheme = match[1]!.toLowerCase();
  const authorityRaw = match[2]!;
  const pathRaw = match[3]!;
  const queryRaw = match[4];

  if (scheme !== "https" && scheme !== "http") throw new Reject();
  if (!policy.allowedSchemes.has(scheme)) throw new Reject();
  const typedScheme = scheme as EndpointScheme;

  const { host, port } = parseAuthority(authorityRaw, SUPPORTED_SCHEMES[typedScheme]);
  const path = canonicalPath(pathRaw);
  const query = canonicalQuery(queryRaw, policy, providerId);
  const result = `${scheme}://${host}${port}${path}${query}`;
  if (result.length > MAX_ENDPOINT_LENGTH) throw new Reject();
  return result;
}

function parseAuthority(
  authority: string,
  defaultPort: number,
): { host: string; port: string } {
  if (authority === "" || authority.includes("@") || authority.includes("%")) {
    throw new Reject();
  }

  let host: string;
  let rest: string;
  if (authority.startsWith("[")) {
    const close = authority.indexOf("]");
    if (close < 0) throw new Reject();
    host = `[${parseIpv6(authority.slice(1, close))}]`;
    rest = authority.slice(close + 1);
  } else {
    if (authority.includes("[") || authority.includes("]")) throw new Reject();
    const colon = authority.indexOf(":");
    const hostText = colon < 0 ? authority : authority.slice(0, colon);
    const portText = colon < 0 ? "" : authority.slice(colon + 1);
    host = parseRegName(hostText);
    rest = colon < 0 ? "" : `:${portText}`;
  }

  if (rest === "") return { host, port: "" };
  if (!rest.startsWith(":")) throw new Reject();
  const portText = rest.slice(1);
  if (!PORT_RE.test(portText)) throw new Reject();
  const port = Number(portText);
  if (port < 1 || port > 65535) throw new Reject();
  return { host, port: port === defaultPort ? "" : `:${port}` };
}

/** Lower-case reg-name; all-digit hosts must be strict dotted-quad IPv4. */
function parseRegName(text: string): string {
  const host = text.toLowerCase();
  if (host.length < 1 || host.length > 253) throw new Reject();
  const labels = host.split(".");
  for (const label of labels) {
    if (!LABEL_RE.test(label)) throw new Reject();
  }
  if (DIGITS_RE.test(labels[labels.length - 1]!)) {
    // Only strict dotted-quad IPv4; refuse octal/hex/short/integer forms.
    if (labels.length !== 4) throw new Reject();
    for (const label of labels) {
      if (!DIGITS_RE.test(label)) throw new Reject();
      if (label.length > 1 && label.startsWith("0")) throw new Reject();
      if (Number(label) > 255) throw new Reject();
    }
  }
  return host;
}

/** Strict IPv6 parse + RFC 5952-style compression (matches Python `.compressed`). */
function parseIpv6(text: string): string {
  if (text === "") throw new Reject();

  const compressionCount = text.split("::").length - 1;
  if (compressionCount > 1) throw new Reject();
  const compressed = compressionCount === 1;

  let left: string[];
  let right: string[];
  if (compressed) {
    const idx = text.indexOf("::");
    const leftText = text.slice(0, idx);
    const rightText = text.slice(idx + 2);
    left = leftText === "" ? [] : leftText.split(":");
    right = rightText === "" ? [] : rightText.split(":");
  } else {
    left = text.split(":");
    right = [];
  }

  // An embedded dotted-quad is only valid as the FINAL group.
  const expandIpv4Tail = (groups: string[]): string[] => {
    if (groups.length === 0) return groups;
    const last = groups[groups.length - 1]!;
    if (!last.includes(".")) return groups;
    const quad = parseDottedQuad(last);
    const hi = ((quad[0]! << 8) | quad[1]!).toString(16);
    const lo = ((quad[2]! << 8) | quad[3]!).toString(16);
    return [...groups.slice(0, -1), hi, lo];
  };

  if (right.length > 0) {
    right = expandIpv4Tail(right);
  } else if (!compressed) {
    left = expandIpv4Tail(left);
  } else {
    left = expandIpv4Tail(left);
  }

  const groups: number[] = [];
  for (const group of left) groups.push(parseHexGroup(group));
  const tail: number[] = [];
  for (const group of right) tail.push(parseHexGroup(group));

  const total = groups.length + tail.length;
  if (compressed) {
    if (total > 7) throw new Reject();
    while (groups.length + tail.length < 8) groups.push(0);
  } else if (total !== 8) {
    throw new Reject();
  }
  groups.push(...tail);
  if (groups.length !== 8) throw new Reject();

  return compressIpv6(groups);
}

function parseHexGroup(text: string): number {
  if (!HEX_GROUP_RE.test(text)) throw new Reject();
  return parseInt(text, 16);
}

function parseDottedQuad(text: string): [number, number, number, number] {
  const parts = text.split(".");
  if (parts.length !== 4) throw new Reject();
  const out: number[] = [];
  for (const part of parts) {
    if (!DIGITS_RE.test(part)) throw new Reject();
    if (part.length > 1 && part.startsWith("0")) throw new Reject();
    const value = Number(part);
    if (value > 255) throw new Reject();
    out.push(value);
  }
  return [out[0]!, out[1]!, out[2]!, out[3]!];
}

function compressIpv6(groups: number[]): string {
  let bestStart = -1;
  let bestLen = 0;
  for (let i = 0; i < groups.length; ) {
    if (groups[i] !== 0) {
      i++;
      continue;
    }
    let j = i;
    while (j < groups.length && groups[j] === 0) j++;
    const len = j - i;
    if (len > bestLen) {
      bestLen = len;
      bestStart = i;
    }
    i = j;
  }

  const hex = groups.map((group) => group.toString(16));
  if (bestLen < 2) return hex.join(":");
  const head = hex.slice(0, bestStart).join(":");
  const tail = hex.slice(bestStart + bestLen).join(":");
  return `${head}::${tail}`;
}

/** Decode percent-encoded unreserved octets and upper-case remaining escapes. */
function normalizePct(text: string): string {
  if (BAD_PCT_RE.test(text)) throw new Reject();
  return text.replace(PCT_RE, (_whole, hex: string) => {
    const char = String.fromCharCode(parseInt(hex, 16));
    return UNRESERVED.has(char) ? char : `%${hex.toUpperCase()}`;
  });
}

/** Repeatedly percent-decode (and '+' -> space) to defeat layered encodings. */
function fullyDecode(text: string): string {
  for (let round = 0; round < 8; round++) {
    const decoded = text
      .replace(/\+/g, " ")
      .replace(PCT_RE, (_whole, hex: string) => String.fromCharCode(parseInt(hex, 16)));
    for (let i = 0; i < decoded.length; i++) {
      const code = decoded.charCodeAt(i);
      if (code < 0x20 || code >= 0x7f) throw new Reject();
    }
    if (decoded === text) return decoded;
    text = decoded;
  }
  throw new Reject();
}

function sensitiveName(name: string, policy: EndpointPolicy): boolean {
  const decoded = fullyDecode(name).toLowerCase();
  if (policy.nonSecretQueryKeys.has(decoded)) return false;
  const collapsed = decoded.replace(/[^a-z0-9]/g, "");
  if (SENSITIVE_EXACT.has(collapsed)) return true;
  return SENSITIVE_NAME_PARTS.some((part) => collapsed.includes(part));
}

function checkSecretValue(text: string): void {
  const decoded = fullyDecode(text);
  if (SECRET_VALUES_RE.test(decoded) || BEARER_RE.test(decoded)) {
    throw new Reject();
  }
}

function canonicalPath(path: string): string {
  if (path.includes("[") || path.includes("]")) throw new Reject();
  const normalized = normalizePct(path === "" ? "/" : path);
  checkSecretValue(normalized);
  for (const segment of fullyDecode(normalized).split("/")) {
    const params = segment.split(";");
    for (let i = 1; i < params.length; i++) {
      // Python pins DEFAULT_POLICY here (not the caller's policy) — ported
      // verbatim so a provider-wide exemption can never un-hide a path param.
      const name = params[i]!.split("=")[0]!;
      if (sensitiveName(name, DEFAULT_ENDPOINT_POLICY)) throw new Reject();
    }
  }
  return removeDotSegments(normalized);
}

/** RFC 3986 section 5.2.4 for an absolute path. */
function removeDotSegments(path: string): string {
  const output: string[] = [];
  const segments = path.split("/").slice(1);
  segments.forEach((segment, index) => {
    const last = index === segments.length - 1;
    if (segment === ".") {
      if (last) output.push("");
    } else if (segment === "..") {
      if (output.length > 0) output.pop();
      if (last) output.push("");
    } else {
      output.push(segment);
    }
  });
  return "/" + output.join("/");
}

function canonicalQuery(
  query: string | undefined,
  policy: EndpointPolicy,
  providerId: string,
): string {
  if (query === undefined) return "";
  if (query.includes("[") || query.includes("]")) throw new Reject();

  const provider = providerId.toLowerCase().replace(/[^a-z0-9]/g, "");
  const pairs: string[] = [];
  for (const piece of query.split("&")) {
    if (piece === "") continue;
    const eq = piece.indexOf("=");
    const name = eq < 0 ? piece : piece.slice(0, eq);
    const sep = eq < 0 ? "" : "=";
    const item = eq < 0 ? "" : piece.slice(eq + 1);

    if (sensitiveName(name, policy)) throw new Reject();
    const decodedName = fullyDecode(name).toLowerCase();
    if (
      AZURE_PROVIDERS.has(provider) &&
      decodedName.replace(/[^a-z0-9]/g, "") === "code" &&
      !policy.nonSecretQueryKeys.has(decodedName)
    ) {
      throw new Reject();
    }
    checkSecretValue(name);
    checkSecretValue(item);
    pairs.push(normalizePct(name) + sep + normalizePct(item));
  }
  return pairs.length > 0 ? "?" + pairs.join("&") : "";
}
