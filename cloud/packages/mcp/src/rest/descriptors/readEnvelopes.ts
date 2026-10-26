/**
 * Documented read-envelope validation for the curated originals whose requests
 * still run through the generic REST engine (GitLab, Jira, Figma, Sentry, Exa,
 * Notion, Airtable, Firestore, Discord).
 *
 * The generic engine proves "HTTP 2xx + parseable JSON" and nothing more. For
 * these providers a 2xx body can still be a soft failure — an Atlassian
 * `{"message": ...}`, a Figma `{"err": ...}`, a bare `{}` from a misrouted
 * tenant, or a paginated envelope with no result list. The specialised
 * handlers (Linear, Slack, Telegram, Google Drive, Supabase) and the
 * data-search/commerce batches already check a named shape; these nine did
 * not, so a wrong-tenant or soft-error response was reported to the model as
 * a successful read.
 *
 * This module adds exactly that check, keyed on the operation the descriptor
 * publishes. It never builds a second request and never re-derives a URL: the
 * wrapped handler still delegates to the engine, and the check inspects the
 * already-redacted model-facing document.
 *
 * Failure output is one fixed string. Provider payloads, upstream error text,
 * and credentials are never echoed, so a rejected envelope cannot leak an
 * upstream secret through an error path.
 */

import type { McpToolCallResult } from "../../client.js";
import type { NativeMcpHandler } from "../../transports/native.js";

const SHAPE_MESSAGE = "Provider returned an unexpected read response.";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function text(value: unknown): boolean {
  return typeof value === "string" && value.trim() !== "";
}

function hasText(payload: unknown, ...keys: string[]): boolean {
  return isRecord(payload) && keys.some((key) => text(payload[key]));
}

/**
 * Null when `payload` is the documented shape of the named read, otherwise a
 * short stable reason. Only operations the descriptors actually publish are
 * listed; anything else is rejected rather than silently accepted.
 */
export function readShapeError(providerId: string, operationId: string, payload: unknown): string | null {
  switch (providerId) {
    case "gitlab":
      // Both published reads are bare arrays from the GitLab REST API.
      if (operationId === "list_projects" || operationId === "list_merge_requests") {
        return Array.isArray(payload) ? null : "expected an array";
      }
      return "unknown operation";
    case "jira":
      if (operationId === "search") {
        return isRecord(payload) && Array.isArray(payload.issues) ? null : "expected an issues list";
      }
      if (operationId === "get_issue") return hasText(payload, "key", "id") ? null : "expected an issue";
      return "unknown operation";
    case "figma":
      if (operationId === "get_file") {
        return isRecord(payload) && isRecord(payload.document) ? null : "expected a file document";
      }
      if (operationId === "get_comments") {
        return isRecord(payload) && Array.isArray(payload.comments) ? null : "expected a comments list";
      }
      return "unknown operation";
    case "sentry":
      if (operationId === "list_issues") return Array.isArray(payload) ? null : "expected an issues array";
      if (operationId === "get_issue") return hasText(payload, "id") ? null : "expected an issue";
      if (operationId === "latest_event") return hasText(payload, "eventID", "id") ? null : "expected an event";
      return "unknown operation";
    case "exa":
      if (operationId === "search" || operationId === "contents") {
        return isRecord(payload) && Array.isArray(payload.results) ? null : "expected a results list";
      }
      return "unknown operation";
    case "notion":
      if (operationId === "search" || operationId === "query_data_source") {
        return isRecord(payload) && payload.object === "list" && Array.isArray(payload.results)
          ? null
          : "expected a list envelope";
      }
      if (operationId === "get_page") {
        return isRecord(payload) && payload.object === "page" && hasText(payload, "id")
          ? null
          : "expected a page";
      }
      return "unknown operation";
    case "airtable":
      if (operationId === "list_records") {
        return isRecord(payload) && Array.isArray(payload.records) ? null : "expected a records list";
      }
      return "unknown operation";
    case "firebase":
      if (operationId === "get_document") return hasText(payload, "name") ? null : "expected a document";
      if (operationId === "list_documents") {
        // Firestore omits `documents` entirely for an empty collection, but an
        // error object is never a successful listing.
        return isRecord(payload) && payload.error === undefined &&
          (payload.documents === undefined || Array.isArray(payload.documents))
          ? null
          : "expected a documents list";
      }
      return "unknown operation";
    case "discord":
      if (operationId === "get_current_user") return hasText(payload, "id") ? null : "expected a user";
      if (operationId === "list_guilds") return Array.isArray(payload) ? null : "expected a guilds array";
      return "unknown operation";
    default:
      return "provider has no documented read envelope";
  }
}

/** Every provider this module validates; used to keep the wrapper honest. */
export const READ_ENVELOPE_PROVIDER_IDS: readonly string[] = Object.freeze([
  "gitlab",
  "jira",
  "figma",
  "sentry",
  "exa",
  "notion",
  "airtable",
  "firebase",
  "discord",
]);

function failure(): McpToolCallResult {
  return { text: SHAPE_MESSAGE, isError: true, content: [{ type: "text", text: SHAPE_MESSAGE }] };
}

/**
 * Wrap a handler with the documented-shape check for its provider. Providers
 * without a documented envelope are returned untouched, so this can never
 * narrow a read it does not understand.
 */
export function withReadEnvelope(providerId: string, handler: NativeMcpHandler): NativeMcpHandler {
  if (!READ_ENVELOPE_PROVIDER_IDS.includes(providerId)) return handler;
  return {
    initialize: (params) => handler.initialize(params),
    listTools: () => handler.listTools(),
    async callTool(name, args, ctx) {
      const result = await handler.callTool(name, args, ctx);
      if (result.isError) return result;
      let payload: unknown;
      try {
        payload = JSON.parse(result.text) as unknown;
      } catch {
        return failure();
      }
      return readShapeError(providerId, name, payload) === null ? result : failure();
    },
    ...(handler.dispose === undefined ? {} : { dispose: () => handler.dispose!() }),
  };
}
