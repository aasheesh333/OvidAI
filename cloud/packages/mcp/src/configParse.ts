// ── MCP config parsing (cloud port of lib/core/mcp_config_parse.dart) ────
// Pure, dependency-free parsing of the MCP server config shapes Ovid accepts:
// Claude-Code `.mcp.json` (JSON) and Codex `config.toml` `[mcp_servers.<name>]`
// sections (hand-rolled TOML subset — Dart parity: sections, dotted env.X /
// headers.X subkeys, quoted strings, arrays of strings).
//
// SECRETS: interpolated `${VAR}` values are credentials. They are never
// logged and never embedded in error messages — every ConfigParseError below
// carries a static, value-free message.

export class ConfigParseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigParseError";
  }
}

export interface McpOAuthConfigInput {
  authorizationUrl?: string;
  tokenUrl?: string;
  clientId?: string;
  scopes?: string[];
  redirectUri?: string;
}

export interface ImportedMcp {
  name: string;
  transport: "stdio" | "http" | "sse";
  command?: string;
  args?: string[];
  cwd?: string;
  env?: Record<string, string>;
  url?: string;
  headers?: Record<string, string>;
  oauth?: McpOAuthConfigInput;
}

const MCP_VAR_PATTERN = /\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}/g;

/**
 * Expand `${VAR}` / `${VAR:-default}` references in an MCP config value
 * against `env`. A variable with a non-empty value is replaced by that
 * value; otherwise the `:-default` is used when present. A reference with
 * neither a resolved value nor a default is left intact as the literal
 * `${VAR}` so the credential gate can still detect the required name
 * (Dart parity).
 */
export function interpolateMcpValue(
  value: string,
  env: Record<string, string>,
): string {
  if (!value.includes("${")) return value;
  return value.replace(MCP_VAR_PATTERN, (match, name, _def, fallback) => {
    const resolved = env[name];
    if (typeof resolved === "string" && resolved.length > 0) return resolved;
    if (_def !== undefined) return fallback ?? "";
    return match;
  });
}

// Canonical transport name for a declared MCP server (Dart parity:
// Codex spells the remote transport `streamable-http` in several ways).
function normalizeMcpTransport(raw: string): string {
  switch (raw.trim().toLowerCase()) {
    case "streamable-http":
    case "streamablehttp":
    case "streamable_http":
    case "http-streamable":
    case "http_streamable":
      return "http";
    case "server-sent-events":
    case "server_sent_events":
    case "serversentevents":
      return "sse";
    default:
      return raw.trim().toLowerCase();
  }
}

/**
 * Parse a pasted MCP config. Accepts JSON (Claude-Code `.mcp.json`) or TOML
 * (Codex `config.toml` `[mcp_servers.<name>]` sections). The top-level
 * server map must use exactly one of the `mcpServers` | `mcp_servers` |
 * `servers` keys (JSON); a map with none of them — or with several — is a
 * ConfigParseError, as is any entry that declares neither a command nor a
 * url. Parsing is atomic: a ConfigParseError means nothing was imported.
 *
 * `opts.env` supplies `${VAR}` / `${VAR:-default}` values; it defaults to
 * the process environment.
 */
export function parseMcpConfig(
  raw: string,
  opts?: { env?: Record<string, string> },
): ImportedMcp[] {
  const env = opts?.env ?? defaultEnv();
  const trimmed = raw.trim();
  if (trimmed === "") return [];
  if (trimmed.startsWith("{")) return parseJsonConfig(trimmed, env);
  if (trimmed.startsWith("[")) {
    // Ambiguous: a JSON array OR a TOML `[mcp_servers.foo]` block. A TOML
    // section never decodes as JSON, so JSON wins when it parses.
    try {
      JSON.parse(trimmed);
    } catch {
      return parseTomlConfig(trimmed, env);
    }
    return parseJsonConfig(trimmed, env);
  }
  return parseTomlConfig(trimmed, env);
}

function defaultEnv(): Record<string, string> {
  return typeof process !== "undefined" && process.env
    ? (process.env as Record<string, string>)
    : {};
}

// ── JSON path ─────────────────────────────────────────────────────────────

const WRAPPER_KEYS = ["mcpServers", "mcp_servers", "servers"] as const;

function parseJsonConfig(raw: string, env: Record<string, string>): ImportedMcp[] {
  let decoded: unknown;
  try {
    decoded = JSON.parse(raw);
  } catch {
    throw new ConfigParseError("Input is not valid JSON");
  }
  rejectDuplicateJsonKeys(raw);

  if (Array.isArray(decoded)) {
    const out: ImportedMcp[] = [];
    for (const e of decoded) {
      if (isRecord(e)) {
        const name = typeof e.name === "string" ? e.name.trim() : "";
        if (name !== "") out.push(importedFromJson(name, e, env));
      }
    }
    return rejectDuplicateNames(out);
  }
  if (!isRecord(decoded)) {
    throw new ConfigParseError("Input is not an MCP config object");
  }
  const j: Record<string, unknown> = decoded;
  const present = WRAPPER_KEYS.filter((k) => k in j);
  if (present.length > 1) {
    throw new ConfigParseError("Ambiguous MCP server wrappers");
  }
  if (present.length === 0) {
    if (Object.keys(j).length === 0) return [];
    throw new ConfigParseError("Missing MCP server map key");
  }
  const servers = j[present[0]];
  if (servers === null || typeof servers !== "object") {
    throw new ConfigParseError("MCP server map must be an object");
  }
  const out: ImportedMcp[] = [];
  if (Array.isArray(servers)) {
    for (const v of servers) {
      if (isRecord(v)) {
        const name = typeof v.name === "string" ? v.name.trim() : "";
        if (name !== "") out.push(importedFromJson(name, v, env));
      }
    }
  } else {
    for (const [name, v] of Object.entries(servers)) {
      if (isRecord(v)) out.push(importedFromJson(name, v, env));
    }
  }
  return rejectDuplicateNames(out);
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

// jsonDecode discards duplicate keys. Scan the already-validated JSON before
// consuming its map, comparing decoded keys (including Unicode escapes).
function rejectDuplicateJsonKeys(raw: string): void {
  const objects: (Set<string> | null)[] = [];
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i];
    if (c === "{") objects.push(new Set());
    else if (c === "[") objects.push(null);
    else if (c === "}" || c === "]") objects.pop();
    else if (c === '"') {
      const start = i;
      i++;
      while (i < raw.length) {
        if (raw[i] === "\\") i += 2;
        else if (raw[i] === '"') break;
        else i++;
      }
      let next = i + 1;
      while (next < raw.length && /\s/.test(raw[next])) next++;
      if (raw[next] === ":") {
        const top = objects[objects.length - 1];
        if (top) {
          const key = JSON.parse(raw.slice(start, i + 1)) as string;
          if (top.has(key)) throw new ConfigParseError("Duplicate JSON key");
          top.add(key);
        }
      }
    }
  }
}

function rejectDuplicateNames(entries: ImportedMcp[]): ImportedMcp[] {
  const names = new Set<string>();
  for (const e of entries) {
    const key = e.name.trim();
    if (key === "") throw new ConfigParseError("Empty MCP server name");
    if (names.has(key)) {
      throw new ConfigParseError("Duplicate MCP server name");
    }
    names.add(key);
  }
  return entries;
}

function importedFromJson(
  name: string,
  v: Record<string, unknown>,
  env: Record<string, string>,
): ImportedMcp {
  if (
    typeof v.command === "string" &&
    typeof v.cmd === "string" &&
    v.command !== v.cmd
  ) {
    throw new ConfigParseError("Conflicting MCP command aliases");
  }
  if (
    typeof v.transport === "string" &&
    typeof v.type === "string" &&
    normalizeMcpTransport(v.transport) !== normalizeMcpTransport(v.type)
  ) {
    throw new ConfigParseError("Conflicting MCP transport aliases");
  }
  const rawCommand =
    typeof v.command === "string"
      ? v.command
      : typeof v.cmd === "string"
        ? v.cmd
        : undefined;
  const command =
    rawCommand !== undefined && rawCommand.trim() !== ""
      ? interpolateMcpValue(rawCommand, env)
      : undefined;

  const rawUrl = typeof v.url === "string" ? v.url.trim() : "";
  const url = rawUrl !== "" ? interpolateMcpValue(rawUrl, env) : undefined;

  const rawExplicit =
    typeof v.transport === "string"
      ? v.transport
      : typeof v.type === "string"
        ? v.type
        : undefined;
  const explicit =
    rawExplicit !== undefined && rawExplicit.trim() !== ""
      ? normalizeMcpTransport(rawExplicit)
      : undefined;

  // Transport inference: command → stdio; url + type "sse" → sse;
  // url → http; neither → error.
  let transport: "stdio" | "http" | "sse";
  if (command !== undefined) {
    transport = "stdio";
  } else if (url !== undefined) {
    transport = explicit === "sse" ? "sse" : "http";
  } else {
    throw new ConfigParseError("MCP entry declares neither command nor url");
  }

  const argsRaw = v.args;
  let args: string[] | undefined;
  if (Array.isArray(argsRaw)) {
    args = argsRaw.filter((a): a is string => typeof a === "string");
  } else if (typeof argsRaw === "string") {
    args = shellSplitArgs(argsRaw);
  }

  const rawCwd = typeof v.cwd === "string" ? v.cwd.trim() : undefined;

  return {
    name,
    transport,
    command,
    args: args?.map((a) => interpolateMcpValue(a, env)),
    cwd: rawCwd !== undefined && rawCwd !== "" ? interpolateMcpValue(rawCwd, env) : undefined,
    env: mcpStringMap(v.env, env),
    url,
    headers: mcpStringMap(v.headers, env),
    oauth: parseMcpOAuthConfig(v.oauth, env),
  };
}

function mcpStringMap(
  m: unknown,
  env: Record<string, string>,
): Record<string, string> | undefined {
  if (!isRecord(m)) return undefined;
  const out: Record<string, string> = {};
  for (const [k, val] of Object.entries(m)) {
    out[k] = interpolateMcpValue(String(val), env);
  }
  return out;
}

function parseMcpOAuthConfig(
  raw: unknown,
  env: Record<string, string>,
): McpOAuthConfigInput | undefined {
  if (!isRecord(raw)) return undefined;
  const m = raw;
  const str = (key: string): string | undefined => {
    const val = m[key];
    if (typeof val !== "string" || val.trim() === "") return undefined;
    return interpolateMcpValue(val.trim(), env);
  };
  const authorizationUrl = str("authorization_url");
  const authorizeAlias = str("authorize_url");
  if (authorizationUrl !== undefined && authorizeAlias !== undefined && authorizationUrl !== authorizeAlias) {
    throw new ConfigParseError("Conflicting OAuth authorization aliases");
  }
  const scopesRaw = m.scopes;
  let scopes: string[] | undefined;
  if (Array.isArray(scopesRaw)) {
    scopes = scopesRaw.map((s) => String(s));
  } else if (typeof scopesRaw === "string" && scopesRaw.trim() !== "") {
    scopes = scopesRaw.split(/[\s,]+/).filter((s) => s !== "");
  }
  const tokenUrl = str("token_url");
  const clientId = str("client_id");
  const redirectUri = str("redirect_uri");
  // An empty `oauth: {}` declares nothing.
  if (
    authorizationUrl === undefined &&
    authorizeAlias === undefined &&
    tokenUrl === undefined &&
    clientId === undefined &&
    scopes === undefined &&
    redirectUri === undefined
  ) {
    return undefined;
  }
  const out: McpOAuthConfigInput = {};
  if (authorizationUrl ?? authorizeAlias) {
    out.authorizationUrl = authorizationUrl ?? authorizeAlias;
  }
  if (tokenUrl !== undefined) out.tokenUrl = tokenUrl;
  if (clientId !== undefined) out.clientId = clientId;
  if (scopes !== undefined) out.scopes = scopes;
  if (redirectUri !== undefined) out.redirectUri = redirectUri;
  return out;
}

// ── Shell-style splitter (port of shellSplitArgs from state.dart) ─────────

function shellSplitArgs(input: string): string[] {
  const out: string[] = [];
  let buf = "";
  let quote: string | null = null;
  let escaped = false;
  let hasToken = false;
  const flush = () => {
    if (hasToken) {
      out.push(buf);
      buf = "";
      hasToken = false;
    }
  };
  for (const c of input) {
    if (escaped) {
      buf += c;
      escaped = false;
      continue;
    }
    if (c === "\\" && quote !== "'") {
      escaped = true;
      continue;
    }
    if (quote !== null) {
      if (c === quote) quote = null;
      else buf += c;
      hasToken = true;
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      hasToken = true;
      continue;
    }
    if (c === " " || c === "\t" || c === "\n" || c === "\r") {
      flush();
      continue;
    }
    buf += c;
    hasToken = true;
  }
  flush();
  return out;
}

// ── TOML subset (hand-rolled, Codex config.toml — Dart parity) ────────────

interface TomlServerAgg {
  name: string;
  command?: string;
  args?: string[];
  url?: string;
  cwd?: string;
  type?: string;
  env: Record<string, string>;
  headers: Record<string, string>;
}

function parseTomlConfig(raw: string, env: Record<string, string>): ImportedMcp[] {
  const servers = new Map<string, TomlServerAgg>();
  const tables = new Set<string>();
  const assignments = new Set<string>();
  const serverFor = (name: string): TomlServerAgg => {
    let agg = servers.get(name);
    if (!agg) {
      agg = { name, env: {}, headers: {} };
      servers.set(name, agg);
    }
    return agg;
  };

  let current: TomlServerAgg | null = null;
  let currentSub: string | null = null; // null | 'env' | 'headers'
  const lines = raw.split("\n");
  let i = 0;
  while (i < lines.length) {
    const line = lines[i].trim();
    if (line === "" || line.startsWith("#")) {
      i++;
      continue;
    }
    const sec = tomlSection(line);
    if (sec) {
      const tableKey = `${sec.name}\u0000${sec.sub ?? ""}`;
      if (tables.has(tableKey)) {
        throw new ConfigParseError("Duplicate MCP TOML table");
      }
      tables.add(tableKey);
      current = serverFor(sec.name);
      currentSub = sec.sub;
      i++;
      continue;
    }
    // A non-MCP TOML table (for example `[environment]`) ends the current
    // MCP server context.
    if (line.startsWith("[") && line.endsWith("]")) {
      current = null;
      currentSub = null;
      i++;
      continue;
    }
    const eq = indexOfAssignment(line);
    if (eq < 0) {
      throw new ConfigParseError("Unparseable line in MCP TOML");
    }
    const key = line.slice(0, eq).trim();
    const valueRaw = line.slice(eq + 1).trim();
    if (current !== null) {
      const field = currentSub === null ? key : `${currentSub}.${unquoteToml(key)}`;
      const assignKey = `${current.name}\u0000${field}`;
      if (assignments.has(assignKey)) {
        throw new ConfigParseError("Duplicate MCP TOML key");
      }
      assignments.add(assignKey);
    }

    if (currentSub === "env") {
      if (current) current.env[unquoteToml(key)] = unquoteToml(valueRaw);
      i++;
      continue;
    }
    if (currentSub === "headers") {
      if (current) current.headers[key] = unquoteToml(valueRaw);
      i++;
      continue;
    }
    if (current === null) {
      i++;
      continue;
    }

    const lower = key.toLowerCase();
    if (lower === "command") {
      current.command = unquoteToml(valueRaw);
    } else if (lower === "url") {
      current.url = unquoteToml(valueRaw);
    } else if (lower === "cwd") {
      current.cwd = unquoteToml(valueRaw);
    } else if (lower === "type" || lower === "transport") {
      const next = unquoteToml(valueRaw).toLowerCase();
      if (
        current.type !== undefined &&
        normalizeMcpTransport(current.type) !== normalizeMcpTransport(next)
      ) {
        throw new ConfigParseError("Conflicting MCP transport aliases");
      }
      current.type = next;
    } else if (lower === "args") {
      let buf = valueRaw;
      if (buf.includes("[") || buf.includes("]")) {
        let open = countChar(buf, "[") - countChar(buf, "]");
        while (open > 0 && i + 1 < lines.length) {
          i++;
          buf += " " + lines[i].trim();
          open = countChar(buf, "[") - countChar(buf, "]");
        }
        current.args = parseArgsArray(buf);
      } else {
        current.args = shellSplitArgs(unquoteToml(buf));
      }
    } else if (key.startsWith("env.")) {
      current.env[key.slice(4)] = unquoteToml(valueRaw);
    } else if (lower.startsWith("headers.")) {
      current.headers[key.slice(8)] = unquoteToml(valueRaw);
    }
    // Unknown keys are skipped (Dart surfaces them as ignored fields; the
    // cloud interface deliberately omits them).
    i++;
  }

  const out: ImportedMcp[] = [];
  for (const agg of servers.values()) {
    out.push(importedFromToml(agg, env));
  }
  return rejectDuplicateNames(out);
}

function importedFromToml(
  a: TomlServerAgg,
  env: Record<string, string>,
): ImportedMcp {
  const rawUrl = a.url;
  const url = rawUrl !== undefined && rawUrl !== "" ? interpolateMcpValue(rawUrl, env) : undefined;
  const command =
    a.command !== undefined && a.command.trim() !== ""
      ? interpolateMcpValue(a.command, env)
      : undefined;
  const explicit = a.type !== undefined && a.type !== "" ? normalizeMcpTransport(a.type) : undefined;
  let transport: "stdio" | "http" | "sse";
  if (command !== undefined) {
    transport = "stdio";
  } else if (url !== undefined) {
    transport = explicit === "sse" ? "sse" : "http";
  } else {
    throw new ConfigParseError("MCP entry declares neither command nor url");
  }
  const envMap: Record<string, string> = {};
  for (const [k, val] of Object.entries(a.env)) {
    envMap[k] = interpolateMcpValue(val, env);
  }
  const headers: Record<string, string> = {};
  for (const [k, val] of Object.entries(a.headers)) {
    headers[k] = interpolateMcpValue(val, env);
  }
  return {
    name: a.name,
    transport,
    command,
    args: a.args?.map((arg) => interpolateMcpValue(arg, env)),
    env: envMap,
    url,
    headers,
    cwd: a.cwd !== undefined && a.cwd !== "" ? interpolateMcpValue(a.cwd, env) : undefined,
  };
}

// Parse a TOML section header `[a.b.c]` into its name + optional sub-table
// kind (env / headers). Handles the quoted-key form. Returns null for
// non-MCP sections.
function tomlSection(t: string): { name: string; sub: string | null } | null {
  if (!t.startsWith("[") || !t.endsWith("]")) return null;
  let inner = t.slice(1, -1).trim();
  if (inner.length >= 2 && inner.startsWith('"') && inner.endsWith('"')) {
    inner = inner.slice(1, -1);
  }
  const parts = inner.split(".");
  if (parts.length < 2) return null;
  const root = parts[0].toLowerCase();
  if (root !== "mcp_servers" && root !== "mcpservers" && root !== "servers") {
    return null;
  }
  const name = parts[1];
  const sub = parts.length >= 3 ? parts.slice(2).join(".").toLowerCase() : null;
  return { name, sub };
}

function indexOfAssignment(s: string): number {
  let inS = false;
  let inD = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === "'" && !inD) inS = !inS;
    else if (c === '"' && !inS) inD = !inD;
    else if (c === "=" && !inS && !inD) return i;
  }
  return -1;
}

// Strip surrounding TOML quotes from a scalar value.
function unquoteToml(v: string): string {
  let s = v.trim();
  if (s.length >= 2) {
    const f = s[0];
    const l = s[s.length - 1];
    if ((f === '"' && l === '"') || (f === "'" && l === "'")) {
      s = s.slice(1, -1);
    } else if (f === '"' || f === "'") {
      s = s.slice(1);
    }
  }
  return s;
}

function countChar(s: string, ch: string): number {
  let n = 0;
  for (const c of s) if (c === ch) n++;
  return n;
}

function parseArgsArray(s: string): string[] {
  const start = s.indexOf("[");
  const end = s.lastIndexOf("]");
  if (start < 0) return shellSplitArgs(unquoteToml(s));
  const inner = s.slice(start + 1, end < 0 ? s.length : end);
  const out: string[] = [];
  const re = /'([^']*)'|"([^"]*)"/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(inner)) !== null) {
    out.push(m[1] ?? m[2] ?? "");
  }
  return out;
}
