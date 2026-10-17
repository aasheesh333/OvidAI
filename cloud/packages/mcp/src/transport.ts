import type { JsonRpcMessage } from "./jsonrpc.js";

/**
 * A MCP transport (stdio, streamable HTTP, ...). The client owns the
 * lifecycle; transports only carry bytes.
 *
 * close() semantics: an expected close fires onClose({expected: true}) and
 * NEVER triggers a reconnect — reconnection policy (if any) belongs to the
 * transport owner, not the client.
 */
export interface McpTransport {
  start(): Promise<void>;
  send(msg: JsonRpcMessage): Promise<void>;
  onMessage(cb: (msg: JsonRpcMessage) => void): void;
  onClose(cb: (info: { expected: boolean }) => void): void;
  close(): Promise<void>;
}
