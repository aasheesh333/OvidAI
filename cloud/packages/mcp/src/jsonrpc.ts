/**
 * JSON-RPC 2.0 message shapes for the MCP wire protocol. A message is a
 * request (method + id), a response (id, no method) or a notification
 * (method, no id) — the narrow discriminators below mirror the Dart
 * `McpClient` dispatch exactly.
 */

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number | string;
  method: string;
  params?: Record<string, unknown>;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number | string;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

export interface JsonRpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: Record<string, unknown>;
}

export type JsonRpcMessage = JsonRpcRequest | JsonRpcResponse | JsonRpcNotification;

/**
 * True when the message is a REQUEST from the server to us (has both a
 * method and an id). Checked BEFORE response matching in the client's
 * dispatch: a server request carrying the same id as one of our pending
 * requests must never be mistaken for that request's response (Dart parity).
 */
export function isServerRequest(m: JsonRpcMessage): m is JsonRpcRequest {
  return "method" in m && "id" in m;
}

/** True when the message is a response to one of our requests (id, no method). */
export function isResponse(m: JsonRpcMessage): m is JsonRpcResponse {
  return "id" in m && !("method" in m);
}

/** True when the message is a notification (method, no id). */
export function isNotification(m: JsonRpcMessage): m is JsonRpcNotification {
  return "method" in m && !("id" in m);
}
