/** Read-first official comms providers. Provider envelopes are checked even on HTTP 200. */

import {
  createRestHandler,
  createSecretRedactor,
  type RestHandlerOptions,
  type RestServiceDescriptor,
} from "../engine.js";
import { trimToolResult, type McpToolCallResult } from "../../client.js";
import type { NativeMcpHandler } from "../../transports/native.js";
import { withReadEnvelope } from "./readEnvelopes.js";

export const SLACK_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "slack",
  displayName: "Slack MCP",
  description: "Read Slack conversations with an OAuth user token and the Web API response envelope.",
  baseUrl: "https://slack.com/api",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "user_token",
  credentialLabel: "Slack OAuth user token",
  tools: [
    {
      name: "list_channels",
      description: "List public channels through conversations.list with bounded cursor pagination.",
      method: "GET",
      path: "/conversations.list",
      effect: "read",
      queryArgMap: { cursor: "cursor" },
      fixedQuery: { types: "public_channel", limit: "100" },
      outputPolicy: { kind: "redacted_json", maxBytes: 65_536 },
      inputSchema: {
        type: "object",
        properties: { cursor: { type: "string", maxLength: 8_192 } },
      },
    },
    {
      name: "history",
      description: "Read recent public-channel messages through conversations.history.",
      method: "GET",
      path: "/conversations.history",
      effect: "read",
      queryArgs: ["channel"],
      queryArgMap: { limit: "limit:100", oldest: "oldest" },
      outputPolicy: { kind: "redacted_json", maxBytes: 65_536 },
      inputSchema: {
        type: "object",
        properties: {
          channel: { type: "string", minLength: 1, maxLength: 128 },
          limit: { type: "integer", minimum: 1, maximum: 200, default: 100 },
          oldest: { type: "string", maxLength: 64 },
        },
        required: ["channel"],
      },
      required: ["channel"],
    },
  ],
};

function boundedResult(text: string, isError: boolean): McpToolCallResult {
  const bounded = trimToolResult(text);
  return { text: bounded, isError, content: [{ type: "text", text: bounded }] };
}

/** Slack's top-level ok boolean is authoritative independently of HTTP status. */
export function createSlackHandler(options: RestHandlerOptions = {}): NativeMcpHandler {
  const rest = createRestHandler(SLACK_DESCRIPTOR, options);
  const redactor = options.redactor ?? createSecretRedactor();
  return {
    initialize: (params) => rest.initialize(params),
    listTools: () => rest.listTools(),
    async callTool(name, args, ctx) {
      const token = (ctx.secrets.user_token ?? "").trim();
      if (!token.startsWith("xoxp-")) {
        return boundedResult("Configure a Slack OAuth user token (xoxp) first; bot tokens are not accepted.", true);
      }
      const result = await rest.callTool(name, args, ctx);
      if (result.isError) return result;
      const secrets = Object.values(ctx.secrets ?? {});
      try {
        const envelope = JSON.parse(result.text) as { ok?: unknown; error?: unknown };
        if (envelope.ok === true) return result;
        const code = typeof envelope.error === "string" && /^[a-z0-9_:-]{1,128}$/.test(envelope.error)
          ? envelope.error
          : "unknown_error";
        return boundedResult(redactor.text(`Slack API error: ${code}`, secrets), true);
      } catch {
        return boundedResult("Provider returned an invalid Slack response.", true);
      }
    },
  };
}

export const DISCORD_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "discord",
  displayName: "Discord MCP",
  description: "Read OAuth-user identity and guilds through Discord API v10; bot authority is a separate model.",
  baseUrl: "https://discord.com/api/v10",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "access_token",
  credentialLabel: "Discord OAuth user access token",
  staticHeaders: { "User-Agent": "DiscordBot (https://ovidsi.com, 1.0)" },
  tools: [
    {
      name: "get_current_user",
      description: "Read the current OAuth user through /users/@me (identify scope).",
      method: "GET",
      path: "/users/@me",
      effect: "read",
      outputPolicy: { kind: "redacted_json", maxBytes: 65_536 },
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "list_guilds",
      description: "List guilds visible to the current OAuth user (guilds scope), not bot guilds.",
      method: "GET",
      path: "/users/@me/guilds",
      effect: "read",
      queryArgMap: { after: "after", limit: "limit:100" },
      outputPolicy: { kind: "redacted_json", maxBytes: 65_536 },
      inputSchema: {
        type: "object",
        properties: {
          after: { type: "string", maxLength: 64 },
          limit: { type: "integer", minimum: 1, maximum: 200, default: 100 },
        },
      },
    },
  ],
};

export function createDiscordHandler(options: RestHandlerOptions = {}): NativeMcpHandler {
  return withReadEnvelope("discord", createRestHandler(DISCORD_DESCRIPTOR, options));
}

export const TELEGRAM_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "telegram",
  displayName: "Telegram MCP",
  description: "Read bot-scoped identity/chat/webhook metadata; arbitrary user history and update acknowledgement are unavailable.",
  baseUrl: "https://api.telegram.org",
  auth: "none",
  credentialKey: "bot_token",
  credentialLabel: "Telegram bot token",
  extraConfig: [{ key: "allowed_chat_ids", label: "Allowed Telegram chat IDs (comma-separated)", secret: false }],
  tools: [
    {
      name: "get_me",
      description: "Read the bot identity with getMe; this does not grant end-user account access.",
      method: "POST",
      path: "/bot{bot_token}/getMe",
      effect: "read",
      bodyTemplate: {},
      outputPolicy: { kind: "redacted_json", maxBytes: 65_536 },
      inputSchema: { type: "object", properties: {} },
    },
    {
      name: "get_chat",
      description: "Read metadata for an explicitly allowed chat through getChat.",
      method: "POST",
      path: "/bot{bot_token}/getChat",
      effect: "read",
      bodyTemplate: { chat_id: "arg:chat_id" },
      outputPolicy: { kind: "redacted_json", maxBytes: 65_536 },
      inputSchema: {
        type: "object",
        properties: { chat_id: { type: "string", minLength: 1, maxLength: 128 } },
        required: ["chat_id"],
      },
      required: ["chat_id"],
    },
    {
      name: "get_webhook_info",
      description: "Read bot webhook state without acknowledging or discarding updates.",
      method: "POST",
      path: "/bot{bot_token}/getWebhookInfo",
      effect: "read",
      bodyTemplate: {},
      outputPolicy: { kind: "redacted_json", maxBytes: 65_536 },
      inputSchema: { type: "object", properties: {} },
    },
  ],
};

/** Redacts the complete token-bearing URL path, including percent-encoded forms. */
export function createTelegramHandler(options: RestHandlerOptions = {}): NativeMcpHandler {
  const rest = createRestHandler(TELEGRAM_DESCRIPTOR, options);
  const redactor = options.redactor ?? createSecretRedactor();
  return {
    initialize: (params) => rest.initialize(params),
    listTools: () => rest.listTools(),
    async callTool(name, args, ctx) {
      if (name === "get_chat") {
        const allowed = (ctx.secrets.allowed_chat_ids ?? "").split(",").map((entry) => entry.trim());
        if (typeof args.chat_id !== "string" || !allowed.includes(args.chat_id)) {
          return boundedResult("Telegram chat is not allowlisted for this connection.", true);
        }
      }
      const result = await rest.callTool(name, args, ctx);
      const secrets = Object.values(ctx.secrets ?? {});
      if (result.isError) {
        // Never echo engine/upstream text that could contain bot<token> in its path.
        return boundedResult(redactor.text("Telegram API request failed.", secrets), true);
      }
      try {
        const envelope = JSON.parse(result.text) as { ok?: unknown; result?: unknown };
        if (envelope.ok !== true) return boundedResult("Telegram API request failed.", true);
        const sanitized = redactor.json(envelope, secrets);
        return boundedResult(redactor.text(JSON.stringify(sanitized), secrets), false);
      } catch {
        return boundedResult(redactor.text("Provider returned an invalid Telegram response.", secrets), true);
      }
    },
  };
}

export const COMMS_DESCRIPTORS: readonly RestServiceDescriptor[] = [
  SLACK_DESCRIPTOR,
  DISCORD_DESCRIPTOR,
  TELEGRAM_DESCRIPTOR,
];
