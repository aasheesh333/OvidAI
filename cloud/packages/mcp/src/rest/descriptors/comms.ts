/**
 * Comms REST descriptors — a data port of the Dart
 * `rest_descriptors_comms.dart` for the three curated comms services:
 * Slack, Discord, Telegram (Cal.com, Twilio, WhatsApp and the Discord bot
 * builder were cut by the Task 6 lineup decision). All three are fully
 * declarative — no Dart routing capability was needed:
 *  - Slack `send_message` and Telegram `send_message` keep pure scalars
 *    because both APIs honestly accept the parameters as URL query
 *    arguments on the send call.
 *  - Telegram carries its secret in the path (`/bot{bot_token}/…`) with
 *    `auth: none`; the engine fills the placeholder from stored config and
 *    the configure-first gate still applies.
 */

import type { RestServiceDescriptor } from "../engine.js";

export const SLACK_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "slack",
  displayName: "Slack Notify",
  description: "Post messages and read channels over the Slack Web API.",
  baseUrl: "https://slack.com/api",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "bot_token",
  credentialLabel: "Slack bot token",
  tools: [
    {
      name: "send_message",
      description:
        "Post a message to a Slack channel (channel + text travel as request parameters, which Slack accepts on this method).",
      method: "POST",
      path: "/chat.postMessage",
      inputSchema: {
        type: "object",
        properties: {
          channel: { type: "string" },
          text: { type: "string" },
        },
        required: ["channel", "text"],
      },
      queryArgs: ["channel", "text"],
      required: ["channel", "text"],
    },
    {
      name: "list_channels",
      description: "List the workspace channels (conversations.list).",
      method: "GET",
      path: "/conversations.list",
      inputSchema: { type: "object" },
    },
    {
      name: "history",
      description: "Read recent messages from a channel.",
      method: "GET",
      path: "/conversations.history",
      inputSchema: {
        type: "object",
        properties: {
          channel: { type: "string" },
          limit: { type: "number" },
        },
        required: ["channel"],
      },
      queryArgs: ["channel", "limit"],
      required: ["channel"],
    },
  ],
};

export const DISCORD_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "discord",
  displayName: "Discord MCP",
  description: "Send messages and list guilds/channels over the Discord bot API.",
  baseUrl: "https://discord.com/api/v10",
  auth: "bearer",
  authPrefix: "Bot ",
  credentialKey: "bot_token",
  credentialLabel: "Discord bot token",
  tools: [
    {
      name: "send_message",
      description: 'Send a message to a Discord channel. body is the Discord message JSON, e.g. {"content": "hello"}.',
      method: "POST",
      path: "/channels/{channel_id}/messages",
      inputSchema: {
        type: "object",
        properties: {
          channel_id: { type: "string" },
          body: { type: "object" },
        },
        required: ["channel_id", "body"],
      },
      jsonBodyArg: "body",
      required: ["channel_id", "body"],
    },
    {
      name: "list_guilds",
      description: "List the servers (guilds) the bot belongs to.",
      method: "GET",
      path: "/users/@me/guilds",
      inputSchema: { type: "object" },
    },
    {
      name: "list_channels",
      description: "List the channels of a guild (server).",
      method: "GET",
      path: "/guilds/{guild_id}/channels",
      inputSchema: {
        type: "object",
        properties: {
          guild_id: { type: "string" },
        },
        required: ["guild_id"],
      },
      required: ["guild_id"],
    },
  ],
};

export const TELEGRAM_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "telegram",
  displayName: "Telegram MCP",
  description: "Send messages and poll updates over the Telegram Bot API.",
  baseUrl: "https://api.telegram.org",
  auth: "none",
  credentialKey: "bot_token",
  credentialLabel: "Telegram bot token",
  tools: [
    {
      name: "send_message",
      description:
        "Send a message via the Telegram Bot API (chat_id + text travel as request parameters, which Telegram accepts).",
      method: "GET",
      path: "/bot{bot_token}/sendMessage",
      inputSchema: {
        type: "object",
        properties: {
          chat_id: { type: "string" },
          text: { type: "string" },
        },
        required: ["chat_id", "text"],
      },
      queryArgs: ["chat_id", "text"],
      required: ["chat_id", "text"],
    },
    {
      name: "get_updates",
      description: "Poll pending updates for the bot (getUpdates).",
      method: "GET",
      path: "/bot{bot_token}/getUpdates",
      inputSchema: { type: "object" },
    },
    {
      name: "get_me",
      description: "Return the bot identity (getMe).",
      method: "GET",
      path: "/bot{bot_token}/getMe",
      inputSchema: { type: "object" },
    },
  ],
};

export const COMMS_DESCRIPTORS: readonly RestServiceDescriptor[] = [
  SLACK_DESCRIPTOR,
  DISCORD_DESCRIPTOR,
  TELEGRAM_DESCRIPTOR,
];
