/**
 * Client-side MCP requests (port of the Dart `McpClientRequests`).
 *
 * MCP is bidirectional: besides answering our requests, a server may send
 * requests TO the client and notifications about long-running work. This
 * module owns the client side of the protocol, transport-agnostic:
 *
 *  - `createClientRequestHandler` — one server→client request in, one
 *    JSON-RPC response out (`ping`, `roots/list`, `sampling/createMessage`,
 *    `elicitation/create`);
 *  - `createNotificationHandler` — `notifications/progress` and
 *    `notifications/message` (server logging) routed into a sink.
 *
 * The host-facing parts are injected: `samplingApprover` asks the user before
 * any server may use their model, `sampler` runs the approved completion,
 * `elicitor` shows the elicitation UI, `rootsProvider` lists workspace roots.
 * Each one missing degrades to the spec's refusal shape, never a hang, and
 * the handler itself never throws.
 */

import type { JsonRpcNotification, JsonRpcRequest, JsonRpcResponse } from "./jsonrpc.js";

// ── Shapes ────────────────────────────────────────────────────────────────

/** One `roots/list` entry. */
export interface McpRoot {
  uri: string;
  name?: string;
}

/** A parsed `sampling/createMessage` request (text content only). */
export interface SamplingRequest {
  server: string;
  /** `[{role, text}]` — non-text parts are summarised. */
  messages: { role: "user" | "assistant"; text: string }[];
  maxTokens: number;
  systemPrompt?: string;
  temperature?: number;
  modelHints: string[];
  /** What the approval prompt shows the user. */
  preview: string;
}

export interface SamplingResult {
  role: "assistant";
  content: { type: "text"; text: string };
  model?: string;
  stopReason?: string;
}

/** A flat primitive elicitation field per the MCP spec. */
export interface ElicitationField {
  name: string;
  type: "string" | "number" | "integer" | "boolean";
  title?: string;
  description?: string;
  enumValues: string[];
  defaultValue?: unknown;
}

/** A parsed `elicitation/create` request (flat primitive schema per spec). */
export interface ElicitationRequest {
  server: string;
  message: string;
  fields: ElicitationField[];
  required: string[];
}

/** The user's answer to an elicitation: `accept` (with content), `decline` or `cancel`. */
export type ElicitationResponse =
  | { action: "accept"; content: Record<string, unknown> }
  | { action: "decline" }
  | { action: "cancel" };

/** Host-injected handlers; each one missing degrades to the spec's refusal shape. */
export interface ClientRequestHandlers {
  rootsProvider?(server: string): McpRoot[];
  samplingApprover?(req: SamplingRequest): Promise<boolean>;
  sampler?(req: SamplingRequest): Promise<SamplingResult | null>;
  elicitor?(req: ElicitationRequest): Promise<ElicitationResponse>;
}

export interface NotificationSink {
  log(entry: { server: string; level: string; logger?: string; data?: unknown; at: string }): void;
  progress(p: { server: string; token: string; progress: number; total?: number; message?: string }): void;
}

// ── Constants ─────────────────────────────────────────────────────────────

export const JSONRPC_METHOD_NOT_FOUND = -32601;
export const JSONRPC_INVALID_PARAMS = -32602;
export const JSONRPC_INTERNAL_ERROR = -32603;
/** MCP spec: "User rejected sampling request". */
export const JSONRPC_USER_REJECTED = -1;
export const SAMPLING_PREVIEW_MAX_CHARS = 1500;
/** `notifications/message` ring per server. */
export const MAX_SERVER_LOGS = 200;

const FIELD_TYPES = new Set(["string", "number", "integer", "boolean"]);

// ── Sampling ──────────────────────────────────────────────────────────────

/** Parse `sampling/createMessage` params; null when the message list is unusable. */
export function parseSamplingRequest(server: string, p: Record<string, unknown>): SamplingRequest | null {
  const raw = p.messages;
  if (!Array.isArray(raw) || raw.length === 0) return null;
  const messages: { role: "user" | "assistant"; text: string }[] = [];
  for (const m of raw) {
    if (typeof m !== "object" || m === null) return null;
    const role = (m as Record<string, unknown>).role;
    if (role !== "user" && role !== "assistant") return null;
    const content = (m as Record<string, unknown>).content;
    let text: string;
    if (typeof content === "object" && content !== null && !Array.isArray(content)) {
      const c = content as Record<string, unknown>;
      if (c.type === "text") {
        text = `${c.text ?? ""}`;
      } else {
        text = `[${c.type ?? "unknown"} content omitted]`;
      }
    } else if (Array.isArray(content)) {
      text = content
        .filter((c): c is Record<string, unknown> => typeof c === "object" && c !== null)
        .map((c) => (c.type === "text" ? `${c.text ?? ""}` : `[${c.type} content omitted]`))
        .join("\n");
    } else {
      return null;
    }
    messages.push({ role, text });
  }
  const maxTokens = p.maxTokens;
  const prefs = p.modelPreferences;
  const hints =
    typeof prefs === "object" && prefs !== null && Array.isArray((prefs as Record<string, unknown>).hints)
      ? ((prefs as Record<string, unknown>).hints as unknown[])
          .filter(
            (h): h is Record<string, unknown> => typeof h === "object" && h !== null && typeof (h as Record<string, unknown>).name === "string",
          )
          .map((h) => h.name as string)
      : [];
  const temperature = typeof p.temperature === "number" ? p.temperature : undefined;
  const systemPrompt = typeof p.systemPrompt === "string" ? p.systemPrompt : undefined;
  const request: SamplingRequest = {
    server,
    messages,
    maxTokens: typeof maxTokens === "number" ? Math.trunc(maxTokens) : 1024,
    systemPrompt,
    temperature,
    modelHints: hints,
    preview: "",
  };
  request.preview = samplingPreview(request);
  return request;
}

/** What the approval prompt shows the user (Dart `preview` getter). */
function samplingPreview(req: Pick<SamplingRequest, "systemPrompt" | "messages">): string {
  let b = "";
  if (req.systemPrompt && req.systemPrompt.length > 0) b += `System: ${req.systemPrompt}\n`;
  for (const m of req.messages) b += `${m.role}: ${m.text}\n`;
  const s = b.trim();
  return s.length > SAMPLING_PREVIEW_MAX_CHARS ? `${s.slice(0, SAMPLING_PREVIEW_MAX_CHARS)}…` : s;
}

// ── Elicitation ───────────────────────────────────────────────────────────

/** Parse `elicitation/create` params; null when the schema is not a flat primitive object. */
export function parseElicitationRequest(server: string, p: Record<string, unknown>): ElicitationRequest | null {
  const message = p.message;
  const schema = p.requestedSchema;
  if (typeof message !== "string" || typeof schema !== "object" || schema === null) return null;
  const s = schema as Record<string, unknown>;
  if (s.type !== undefined && s.type !== null && s.type !== "object") return null;
  const props = s.properties;
  const fields: ElicitationField[] = [];
  if (typeof props === "object" && props !== null) {
    for (const [key, v] of Object.entries(props as Record<string, unknown>)) {
      if (typeof v !== "object" || v === null) return null;
      const spec = v as Record<string, unknown>;
      // The spec restricts elicitation to flat primitive properties.
      if (!FIELD_TYPES.has(spec.type as string)) return null;
      const enumValues = Array.isArray(spec.enum) ? spec.enum.map((x) => `${x}`) : [];
      fields.push({
        name: `${key}`,
        type: spec.type as ElicitationField["type"],
        title: typeof spec.title === "string" ? spec.title : undefined,
        description: typeof spec.description === "string" ? spec.description : undefined,
        enumValues,
        defaultValue: spec.default,
      });
    }
  }
  const req = s.required;
  return {
    server,
    message,
    fields,
    required: Array.isArray(req) ? req.map((r) => `${r}`) : [],
  };
}

/**
 * Coerce the accepted content to the requested types; an accept missing a
 * required field (or violating an enum) degrades to `cancel` rather than
 * sending the server bad data (Dart `validated`).
 */
export function validateElicitationResponse(req: ElicitationRequest, res: ElicitationResponse): ElicitationResponse {
  if (res.action !== "accept") return res;
  const out: Record<string, unknown> = {};
  for (const f of req.fields) {
    const v = res.content[f.name];
    if (v === undefined || v === null || (typeof v === "string" && v.length === 0 && f.type !== "string")) {
      if (req.required.includes(f.name)) return { action: "cancel" };
      continue;
    }
    let coerced: unknown;
    switch (f.type) {
      case "number":
        coerced = typeof v === "number" ? v : numOrNull(`${v}`);
        break;
      case "integer":
        coerced = typeof v === "number" && Number.isInteger(v) ? v : intOrNull(`${v}`);
        break;
      case "boolean":
        coerced = typeof v === "boolean" ? v : `${v}` === "true";
        break;
      default:
        coerced = `${v}`;
        break;
    }
    if (coerced === null || coerced === undefined) {
      if (req.required.includes(f.name)) return { action: "cancel" };
      continue;
    }
    if (f.enumValues.length > 0 && !f.enumValues.includes(`${coerced}`)) {
      return { action: "cancel" };
    }
    out[f.name] = coerced;
  }
  return { action: "accept", content: out };
}

function numOrNull(s: string): number | null {
  const n = Number(s);
  return s.trim() !== "" && Number.isFinite(n) ? n : null;
}

function intOrNull(s: string): number | null {
  const n = numOrNull(s);
  return n !== null && Number.isInteger(n) ? n : null;
}

// ── Request handler ───────────────────────────────────────────────────────

/**
 * Answer one server→client request. The returned promise always resolves to a
 * complete JSON-RPC response (`result` or `error`) — it never rejects, and a
 * throwing injected handler becomes `-32603`.
 */
export function createClientRequestHandler(
  h: ClientRequestHandlers,
): (server: string, req: JsonRpcRequest) => Promise<JsonRpcResponse> {
  return async (server, request): Promise<JsonRpcResponse> => {
    const id = request.id;
    const method = request.method;
    const params: Record<string, unknown> =
      typeof request.params === "object" && request.params !== null ? request.params : {};
    const ok = (result: unknown): JsonRpcResponse => ({ jsonrpc: "2.0", id, result });
    const err = (code: number, message: string): JsonRpcResponse => ({
      jsonrpc: "2.0",
      id,
      error: { code, message },
    });
    try {
      switch (method) {
        case "ping":
          return ok({});
        case "roots/list": {
          const roots = h.rootsProvider?.(server) ?? [];
          return ok({
            roots: roots.map((r) => (r.name !== undefined ? { uri: r.uri, name: r.name } : { uri: r.uri })),
          });
        }
        case "sampling/createMessage": {
          const sreq = parseSamplingRequest(server, params);
          if (sreq === null) {
            return err(JSONRPC_INVALID_PARAMS, "sampling/createMessage: invalid params");
          }
          const approve = h.samplingApprover;
          const run = h.sampler;
          if (approve === undefined || run === undefined) {
            return err(JSONRPC_USER_REJECTED, "User rejected sampling request");
          }
          if (!(await approve(sreq))) {
            return err(JSONRPC_USER_REJECTED, "User rejected sampling request");
          }
          const result = await run(sreq);
          if (result === null) {
            return err(JSONRPC_INTERNAL_ERROR, "sampling failed");
          }
          return ok(result);
        }
        case "elicitation/create": {
          const ereq = parseElicitationRequest(server, params);
          if (ereq === null) {
            return err(JSONRPC_INVALID_PARAMS, "elicitation/create: invalid params");
          }
          const ask = h.elicitor;
          if (ask === undefined) return ok({ action: "cancel" });
          const response = await ask(ereq);
          const validated = validateElicitationResponse(ereq, response);
          return ok(
            validated.action === "accept"
              ? { action: "accept", content: validated.content ?? {} }
              : { action: validated.action },
          );
        }
        default:
          return err(JSONRPC_METHOD_NOT_FOUND, `Method not found: ${method}`);
      }
    } catch {
      return err(JSONRPC_INTERNAL_ERROR, `client error handling ${method}`);
    }
  };
}

// ── Notification handler ──────────────────────────────────────────────────

export type ClientNotificationHandler = ((server: string, n: JsonRpcNotification) => boolean) & {
  /** Server log lines (oldest first, bounded at MAX_SERVER_LOGS per server). */
  logsFor(server: string): { server: string; level: string; logger?: string; data?: unknown; at: string }[];
};

/**
 * Record a `notifications/progress` or `notifications/message`. True when the
 * notification was one of those (i.e. consumed by us). Every log entry is
 * streamed to the sink as it arrives; the handler additionally keeps its own
 * per-server ring (oldest first, `MAX_SERVER_LOGS`) inspectable via
 * `logsFor`, mirroring the Dart `logsFor`.
 */
export function createNotificationHandler(sink: NotificationSink): ClientNotificationHandler {
  const logs = new Map<string, { server: string; level: string; logger?: string; data?: unknown; at: string }[]>();
  const handle = (server: string, n: JsonRpcNotification): boolean => {
    const params: Record<string, unknown> =
      typeof n.params === "object" && n.params !== null ? n.params : {};
    switch (n.method) {
      case "notifications/progress": {
        const token = params.progressToken;
        const progress = params.progress;
        if (token === undefined || token === null || typeof progress !== "number") return true;
        const total = typeof params.total === "number" ? params.total : undefined;
        const message = typeof params.message === "string" ? params.message : undefined;
        sink.progress({ server, token: `${token}`, progress, total, message });
        return true;
      }
      case "notifications/message": {
        const list = logs.get(server) ?? [];
        logs.set(server, list);
        list.push({
          server,
          level: params.level !== undefined && params.level !== null ? `${params.level}` : "info",
          logger: params.logger !== undefined && params.logger !== null ? `${params.logger}` : undefined,
          data: params.data,
          at: new Date().toISOString(),
        });
        if (list.length > MAX_SERVER_LOGS) {
          list.splice(0, list.length - MAX_SERVER_LOGS);
        }
        sink.log(list[list.length - 1]!);
        return true;
      }
    }
    return false;
  };
  handle.logsFor = (server: string) => [...(logs.get(server) ?? [])];
  return handle;
}
