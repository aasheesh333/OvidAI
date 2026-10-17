/**
 * Data/backend REST descriptors — a data port of the Dart
 * `rest_descriptors_backend.dart` (Firebase, Supabase, Airtable, MongoDB,
 * S3) and `rest_descriptors_aimedia.dart` (Notion, Google Drive) for the
 * seven curated data services. Tool names, paths, schemas and credential
 * labels are copied verbatim from the Dart source; the routing/synthesis
 * the Dart file did in capability subclasses is expressed declaratively
 * through the engine's documented supersets:
 *  - Supabase: `{base_url}` whole-base routing, the `apikey` static header
 *    (the Dart `_HeaderClient`), `query`-map expansion, and the
 *    unfiltered-write refusal (`requireQueryArgs`).
 *  - Firebase/Airtable: the `{"fields": …}` wrap via `bodyTemplate`; the
 *    slash-preserving path encoder replaces the Dart per-segment path
 *    rewrite.
 *  - MongoDB: the Data-API envelopes via `bodyTemplate` (dataSource from
 *    config, `json:`/`int:` refs for the scalar args).
 *  - Notion: the version header via `staticHeaders`; `create_page`'s nested
 *    payload via `bodyTemplate` dot-paths.
 *  - Google Drive: arg→param renames via `queryArgMap` (`query`→`q`,
 *    `limit`→`pageSize=20`) and constants via `fixedQuery` (`fields=*`,
 *    `alt=media`). The multipart `upload_text` cannot be expressed
 *    declaratively, so `createGoogleDriveHandler` wraps the engine handler
 *    and executes just that tool itself — the Dart architecture's "special
 *    engine beside the declarative one", inverted only in that everything
 *    else delegates to the engine.
 *  - S3: SigV4 execution over the engine's ported `s3Authorization`
 *    (`createS3Handler`) — the Dart engine had no signing hook either, and
 *    `presign_get` stays pure signing (no network).
 */

import { Buffer } from "node:buffer";
import {
  configureFirstMessage,
  createRestHandler,
  resolveTimeoutSeconds,
  s3Authorization,
  s3PresignedGetUrl,
  sha256Hex,
  sigV4Encode,
  restToolDefs,
  type RestServiceDescriptor,
} from "../engine.js";
import { trimToolResult, type McpToolCallResult } from "../../client.js";
import type { McpCallContext, NativeMcpHandler } from "../../transports/native.js";
import { followGuardedRedirects } from "../../native/fetch.js";

// ---------------------------------------------------------------------------
// Descriptors
// ---------------------------------------------------------------------------

export const NOTION_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "notion",
  displayName: "Notion Sync",
  description: "Search, query and create Notion pages and databases.",
  baseUrl: "https://api.notion.com/v1",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "api_key",
  credentialLabel: "Notion API key",
  staticHeaders: { "Notion-Version": "2022-06-28" },
  tools: [
    {
      name: "search",
      description: "Search Notion pages and databases.",
      method: "POST",
      path: "/search",
      bodyTemplate: { query: "arg:query" },
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string" },
        },
      },
    },
    {
      name: "query_database",
      description: "Query a Notion database.",
      method: "POST",
      path: "/databases/{db_id}/query",
      required: ["db_id"],
      jsonBodyArg: "filter_json",
      inputSchema: {
        type: "object",
        properties: {
          db_id: { type: "string" },
          filter_json: { type: "string" },
        },
        required: ["db_id"],
      },
    },
    {
      name: "create_page",
      description: "Create a new Notion page.",
      method: "POST",
      path: "/pages",
      required: ["parent_id", "title"],
      bodyTemplate: {
        "parent.database_id": "arg:parent_id",
        "properties.title.title.0.text.content": "arg:title",
        "children.0.object": 'when:text:const:"block"',
        "children.0.type": 'when:text:const:"paragraph"',
        "children.0.paragraph.rich_text.0.type": 'when:text:const:"text"',
        "children.0.paragraph.rich_text.0.text.content": "arg:text",
      },
      inputSchema: {
        type: "object",
        properties: {
          parent_id: { type: "string" },
          title: { type: "string" },
          text: { type: "string" },
        },
        required: ["parent_id", "title"],
      },
    },
    {
      name: "get_page",
      description: "Get a Notion page by id.",
      method: "GET",
      path: "/pages/{id}",
      required: ["id"],
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string" },
        },
        required: ["id"],
      },
    },
  ],
};

export const GOOGLE_DRIVE_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "google-drive",
  displayName: "Google Drive MCP",
  description: "Search, read and upload Google Drive files (text-oriented).",
  baseUrl: "https://www.googleapis.com/drive/v3",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "access_token",
  credentialLabel: "Google OAuth access token",
  tools: [
    {
      name: "search",
      description: "Search Google Drive files.",
      method: "GET",
      path: "/files",
      queryArgMap: { query: "q", limit: "pageSize:20" },
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string" },
          limit: { type: "integer", default: 20 },
        },
      },
    },
    {
      name: "get_file",
      description: "Get Google Drive file metadata by id.",
      method: "GET",
      path: "/files/{id}",
      required: ["id"],
      fixedQuery: { fields: "*" },
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string" },
        },
        required: ["id"],
      },
    },
    {
      name: "download_text",
      description: "Download text content of a Google Drive file (or export Google Docs to plain text).",
      method: "GET",
      path: "/files/{id}",
      required: ["id"],
      fixedQuery: { alt: "media" },
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string" },
        },
        required: ["id"],
      },
    },
    {
      name: "upload_text",
      description: "Upload a text file to Google Drive (multipart upload).",
      method: "POST",
      path: "/files",
      required: ["name", "text"],
      inputSchema: {
        type: "object",
        properties: {
          name: { type: "string" },
          text: { type: "string" },
          folder_id: { type: "string" },
        },
        required: ["name", "text"],
      },
    },
  ],
};

export const AIRTABLE_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "airtable",
  displayName: "Airtable MCP",
  description: "Airtable records over the REST API (list, create, update, delete).",
  baseUrl: "https://api.airtable.com/v0",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "token",
  credentialLabel: "Airtable personal access token",
  tools: [
    {
      name: "list_records",
      description: "List the records of a table in a base.",
      method: "GET",
      path: "/{base_id}/{table}",
      inputSchema: {
        type: "object",
        properties: {
          base_id: { type: "string" },
          table: { type: "string" },
        },
        required: ["base_id", "table"],
      },
      required: ["base_id", "table"],
    },
    {
      name: "create_record",
      description: 'Create a record. fields_json is the fields object, e.g. {"Name": "Write report"}.',
      method: "POST",
      path: "/{base_id}/{table}",
      inputSchema: {
        type: "object",
        properties: {
          base_id: { type: "string" },
          table: { type: "string" },
          fields_json: { type: "object" },
        },
        required: ["base_id", "table", "fields_json"],
      },
      bodyTemplate: { fields: "json:fields_json" },
      required: ["base_id", "table", "fields_json"],
    },
    {
      name: "update_record",
      description: "Update a record. fields_json is the fields object.",
      method: "PATCH",
      path: "/{base_id}/{table}/{record_id}",
      inputSchema: {
        type: "object",
        properties: {
          base_id: { type: "string" },
          table: { type: "string" },
          record_id: { type: "string" },
          fields_json: { type: "object" },
        },
        required: ["base_id", "table", "record_id", "fields_json"],
      },
      bodyTemplate: { fields: "json:fields_json" },
      required: ["base_id", "table", "record_id", "fields_json"],
    },
    {
      name: "delete_record",
      description: "Delete a record from a table.",
      method: "DELETE",
      path: "/{base_id}/{table}/{record_id}",
      inputSchema: {
        type: "object",
        properties: {
          base_id: { type: "string" },
          table: { type: "string" },
          record_id: { type: "string" },
        },
        required: ["base_id", "table", "record_id"],
      },
      required: ["base_id", "table", "record_id"],
    },
  ],
};

export const SUPABASE_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "supabase",
  displayName: "Supabase MCP",
  description: "Supabase tables over the PostgREST API (select, insert, update, delete).",
  baseUrl: "{base_url}",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "service_key",
  credentialLabel: "Supabase service role key",
  staticHeaders: { apikey: "{secret}" },
  extraConfig: [
    {
      key: "base_url",
      label: "Supabase project URL",
      secret: false,
      hint: "The project REST URL, e.g. https://xyzcompany.supabase.co.",
    },
  ],
  tools: [
    {
      name: "select",
      description:
        'Select rows from a table. query is the PostgREST filter map passed through as URL params, e.g. {"select": "*", "status": "eq.done"}.',
      method: "GET",
      path: "/rest/v1/{table}",
      queryArgs: ["query"],
      inputSchema: {
        type: "object",
        properties: {
          table: { type: "string" },
          query: { type: "object" },
        },
        required: ["table"],
      },
      required: ["table"],
    },
    {
      name: "insert",
      description: 'Insert a row. row_json is the row object, e.g. {"task": "write tests"}.',
      method: "POST",
      path: "/rest/v1/{table}",
      jsonBodyArg: "row_json",
      inputSchema: {
        type: "object",
        properties: {
          table: { type: "string" },
          row_json: { type: "object" },
        },
        required: ["table", "row_json"],
      },
      required: ["table", "row_json"],
    },
    {
      name: "update",
      description:
        "Update rows matching the query filter map. patch_json is the patch object. A non-empty query filter is required — unfiltered writes are refused.",
      method: "PATCH",
      path: "/rest/v1/{table}",
      jsonBodyArg: "patch_json",
      queryArgs: ["query"],
      requireQueryArgs: ["query"],
      inputSchema: {
        type: "object",
        properties: {
          table: { type: "string" },
          query: { type: "object" },
          patch_json: { type: "object" },
        },
        required: ["table", "query", "patch_json"],
      },
      required: ["table", "query", "patch_json"],
    },
    {
      name: "delete",
      description:
        "Delete rows matching the query filter map. A non-empty query filter is required — unfiltered deletes are refused.",
      method: "DELETE",
      path: "/rest/v1/{table}",
      queryArgs: ["query"],
      requireQueryArgs: ["query"],
      inputSchema: {
        type: "object",
        properties: {
          table: { type: "string" },
          query: { type: "object" },
        },
        required: ["table", "query"],
      },
      required: ["table", "query"],
    },
  ],
};

export const FIREBASE_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "firebase",
  displayName: "Firebase MCP",
  description: "Firestore documents and collections over the REST API (Firestore only).",
  baseUrl: "https://firestore.googleapis.com/v1",
  auth: "queryKey",
  authParam: "key",
  credentialKey: "api_key",
  credentialLabel: "Firebase API key",
  extraConfig: [
    {
      key: "project_id",
      label: "Firebase project ID",
      secret: false,
      hint: "The GCP project id owning the Firestore database.",
    },
  ],
  tools: [
    {
      name: "get_document",
      description: "Fetch one Firestore document by path, e.g. users/abc123 (Firestore only — Auth/Storage are out of scope).",
      method: "GET",
      path: "/projects/{project_id}/databases/(default)/documents/{path}",
      inputSchema: {
        type: "object",
        properties: {
          path: { type: "string" },
        },
        required: ["path"],
      },
      required: ["path"],
    },
    {
      name: "list_documents",
      description: "List the documents of a Firestore collection (Firestore only).",
      method: "GET",
      path: "/projects/{project_id}/databases/(default)/documents/{collection}",
      inputSchema: {
        type: "object",
        properties: {
          collection: { type: "string" },
        },
        required: ["collection"],
      },
      required: ["collection"],
    },
    {
      name: "create_document",
      description:
        'Create a document in a collection. fields_json is the Firestore fields map, e.g. {"name": {"stringValue": "Ada"}} (Firestore only).',
      method: "POST",
      path: "/projects/{project_id}/databases/(default)/documents/{collection}",
      inputSchema: {
        type: "object",
        properties: {
          collection: { type: "string" },
          fields_json: { type: "object" },
        },
        required: ["collection", "fields_json"],
      },
      bodyTemplate: { fields: "json:fields_json" },
      required: ["collection", "fields_json"],
    },
    {
      name: "patch_document",
      description: "Update a Firestore document by path. fields_json is the Firestore fields map (Firestore only).",
      method: "PATCH",
      path: "/projects/{project_id}/databases/(default)/documents/{path}",
      inputSchema: {
        type: "object",
        properties: {
          path: { type: "string" },
          fields_json: { type: "object" },
        },
        required: ["path", "fields_json"],
      },
      bodyTemplate: { fields: "json:fields_json" },
      required: ["path", "fields_json"],
    },
    {
      name: "delete_document",
      description: "Delete a Firestore document by path (Firestore only).",
      method: "DELETE",
      path: "/projects/{project_id}/databases/(default)/documents/{path}",
      inputSchema: {
        type: "object",
        properties: {
          path: { type: "string" },
        },
        required: ["path"],
      },
      required: ["path"],
    },
  ],
};

export const MONGODB_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "mongodb",
  displayName: "MongoDB MCP",
  description: "MongoDB documents over the Atlas Data API (the self-hosted wire protocol is unsupported).",
  baseUrl: "{data_api_base}",
  auth: "apiKeyHeader",
  authHeader: "api-key",
  credentialKey: "api_key",
  credentialLabel: "MongoDB Data API key",
  extraConfig: [
    {
      key: "data_api_base",
      label: "MongoDB Data API base URL",
      secret: false,
      hint: "The Atlas Data API base, e.g. https://data.mongodb-api.com/app/…/endpoint/data/v1.",
    },
    {
      key: "data_source",
      label: "MongoDB data source",
      secret: false,
      hint: "The Atlas cluster name, e.g. Cluster0.",
    },
  ],
  tools: [
    {
      name: "find",
      description:
        "Find documents (Atlas Data API only — the self-hosted wire protocol is unsupported). filter_json is optional; limit defaults to 20.",
      method: "POST",
      path: "/action/find",
      inputSchema: {
        type: "object",
        properties: {
          db: { type: "string" },
          coll: { type: "string" },
          filter_json: { type: "object" },
          limit: { type: "number" },
        },
        required: ["db", "coll"],
      },
      bodyTemplate: {
        dataSource: "config:data_source",
        database: "arg:db",
        collection: "arg:coll",
        filter: "json:filter_json",
        limit: "int:limit:20",
      },
      required: ["db", "coll"],
    },
    {
      name: "find_one",
      description:
        "Find a single document (Atlas Data API only — the self-hosted wire protocol is unsupported).",
      method: "POST",
      path: "/action/findOne",
      inputSchema: {
        type: "object",
        properties: {
          db: { type: "string" },
          coll: { type: "string" },
          filter_json: { type: "object" },
        },
        required: ["db", "coll"],
      },
      bodyTemplate: {
        dataSource: "config:data_source",
        database: "arg:db",
        collection: "arg:coll",
        filter: "json:filter_json",
      },
      required: ["db", "coll"],
    },
    {
      name: "insert_one",
      description:
        "Insert a document. doc_json is the document (Atlas Data API only — the self-hosted wire protocol is unsupported).",
      method: "POST",
      path: "/action/insertOne",
      inputSchema: {
        type: "object",
        properties: {
          db: { type: "string" },
          coll: { type: "string" },
          doc_json: { type: "object" },
        },
        required: ["db", "coll", "doc_json"],
      },
      bodyTemplate: {
        dataSource: "config:data_source",
        database: "arg:db",
        collection: "arg:coll",
        document: "json:doc_json",
      },
      required: ["db", "coll", "doc_json"],
    },
  ],
};

export const S3_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "s3",
  displayName: "S3 MCP",
  description: "S3 objects over SigV4-signed virtual-hosted requests (list, get, put, delete, presign).",
  baseUrl: "https://s3.{region}.amazonaws.com",
  auth: "none",
  credentialKey: "secret_access_key",
  credentialLabel: "AWS secret access key",
  extraConfig: [
    {
      key: "access_key_id",
      label: "AWS access key ID",
      secret: false,
      hint: "The public access key id (not a secret).",
    },
    {
      key: "region",
      label: "AWS region",
      secret: false,
      hint: "The bucket region, e.g. us-east-1.",
    },
    {
      key: "bucket",
      label: "S3 bucket",
      secret: false,
      hint: "The bucket name (virtual-hosted style requests).",
    },
  ],
  tools: [
    {
      name: "list_objects",
      description: "List objects in the bucket (SigV4-signed). prefix is optional.",
      method: "GET",
      path: "/",
      inputSchema: {
        type: "object",
        properties: {
          prefix: { type: "string" },
          timeout_seconds: { type: "number" },
        },
      },
    },
    {
      name: "get_object",
      description:
        "Fetch an object key (SigV4-signed). UTF-8 text under 6000 bytes is returned inline, otherwise metadata plus a presign_get hint.",
      method: "GET",
      path: "/{key}",
      inputSchema: {
        type: "object",
        properties: {
          key: { type: "string" },
          timeout_seconds: { type: "number" },
        },
        required: ["key"],
      },
      required: ["key"],
    },
    {
      name: "put_object",
      description: "Write text to an object key (SigV4-signed).",
      method: "PUT",
      path: "/{key}",
      inputSchema: {
        type: "object",
        properties: {
          key: { type: "string" },
          text: { type: "string" },
          timeout_seconds: { type: "number" },
        },
        required: ["key", "text"],
      },
      required: ["key", "text"],
    },
    {
      name: "delete_object",
      description: "Delete an object key (SigV4-signed).",
      method: "DELETE",
      path: "/{key}",
      inputSchema: {
        type: "object",
        properties: {
          key: { type: "string" },
          timeout_seconds: { type: "number" },
        },
        required: ["key"],
      },
      required: ["key"],
    },
    {
      name: "presign_get",
      description: "Build a presigned GET URL for a key (pure SigV4 signing, no network). expires is seconds, default 3600 (max 604800).",
      method: "GET",
      path: "/{key}",
      inputSchema: {
        type: "object",
        properties: {
          key: { type: "string" },
          expires: { type: "number" },
        },
        required: ["key"],
      },
      required: ["key"],
    },
  ],
};

export const DATA_DESCRIPTORS: readonly RestServiceDescriptor[] = [
  NOTION_DESCRIPTOR,
  GOOGLE_DRIVE_DESCRIPTOR,
  AIRTABLE_DESCRIPTOR,
  SUPABASE_DESCRIPTOR,
  FIREBASE_DESCRIPTOR,
  MONGODB_DESCRIPTOR,
  S3_DESCRIPTOR,
];

// ---------------------------------------------------------------------------
// S3 special engine (port of the Dart S3Capability)
// ---------------------------------------------------------------------------

function toolResult(text: string, isError = false): McpToolCallResult {
  const trimmed = trimToolResult(text);
  return { text: trimmed, isError, content: [{ type: "text", text: trimmed }] };
}

function messageOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function amzDateStr(date: Date): string {
  const two = (n: number): string => String(n).padStart(2, "0");
  const dateStamp = `${date.getUTCFullYear()}${two(date.getUTCMonth() + 1)}${two(date.getUTCDate())}`;
  return `${dateStamp}T${two(date.getUTCHours())}${two(date.getUTCMinutes())}${two(date.getUTCSeconds())}Z`;
}

function asInt(raw: unknown, key: string, fallback: number): number {
  if (raw === undefined || raw === null) return fallback;
  if (typeof raw === "number") return Math.round(raw);
  const text = String(raw).trim();
  if (text === "") return fallback;
  const parsed = Number(text);
  if (Number.isNaN(parsed)) {
    throw new Error(`Invalid ${key} "${String(raw)}": expected a number.`);
  }
  return Math.round(parsed);
}

interface S3SendResult {
  status: number;
  body: Buffer;
  contentType: string;
}

/**
 * Sends one SigV4-signed S3 request. Unlike the generic engine, redirects
 * are NOT followed: a SigV4 Authorization is bound to the signed host, so a
 * hop would both break the signature and replay the credentials to the
 * Location target — a 3xx surfaces verbatim as a non-2xx result instead.
 */
async function s3Send(
  ctx: McpCallContext,
  opts: {
    method: string;
    key: string;
    query?: Record<string, string>;
    bodyBytes?: Uint8Array;
    contentType?: string;
    accessKeyId: string;
    secretAccessKey: string;
    region: string;
    bucket: string;
    timeoutSeconds: number;
  },
): Promise<S3SendResult> {
  const host = `${opts.bucket}.s3.${opts.region}.amazonaws.com`;
  const rawPath = opts.key === "" ? "/" : `/${opts.key}`;
  const encodedPath = opts.key === "" ? "/" : `/${opts.key.split("/").map(sigV4Encode).join("/")}`;
  const now = new Date();
  const amzDate = amzDateStr(now);
  const payloadHash = sha256Hex(opts.bodyBytes ?? Buffer.alloc(0));
  const authorization = s3Authorization({
    accessKeyId: opts.accessKeyId,
    secretAccessKey: opts.secretAccessKey,
    region: opts.region,
    method: opts.method,
    canonicalUri: rawPath,
    queryParameters: opts.query ?? {},
    headers: { host, "x-amz-date": amzDate },
    payloadHash,
    amzDate: now,
  });
  const sortedQuery = Object.entries(opts.query ?? {})
    .map(([k, v]) => [sigV4Encode(k), sigV4Encode(v)] as const)
    .sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  const queryString = sortedQuery.map(([k, v]) => `${k}=${v}`).join("&");
  const urlStr = `https://${host}${encodedPath}${queryString === "" ? "" : `?${queryString}`}`;

  const headers: Record<string, string> = {
    "x-amz-date": amzDate,
    Authorization: authorization,
  };
  if (opts.contentType !== undefined) headers["content-type"] = opts.contentType;

  let res: Response;
  try {
    res = await ctx.fetchImpl(urlStr, {
      method: opts.method,
      headers,
      body:
        opts.bodyBytes !== undefined && opts.bodyBytes.length > 0
          ? (opts.bodyBytes as unknown as BodyInit)
          : undefined,
      redirect: "manual",
      signal: AbortSignal.timeout(opts.timeoutSeconds * 1000),
    });
  } catch (err) {
    if (err instanceof Error && (err.name === "TimeoutError" || err.name === "AbortError")) {
      throw new Error(`Request to ${urlStr} timed out after ${opts.timeoutSeconds} seconds.`);
    }
    throw new Error(`HTTP request failed: ${messageOf(err)}`);
  }
  const body = Buffer.from(await res.arrayBuffer());
  return { status: res.status, body, contentType: res.headers.get("content-type") ?? "unknown" };
}

function requireStringArg(args: Record<string, unknown>, key: string): string {
  const value = args[key];
  if (value === undefined || value === null || String(value).trim() === "") {
    throw new Error(`Missing required argument: ${key}`);
  }
  return String(value);
}

/**
 * S3 handler: custom SigV4 execution (the engine has no signing hook —
 * same reason the Dart S3Capability existed), with the engine's exact
 * timeout/verbatim/trim conventions. One process-wide instance is safe:
 * credentials come from ctx.secrets per call.
 */
export function createS3Handler(
  descriptor: RestServiceDescriptor = S3_DESCRIPTOR,
): NativeMcpHandler {
  return {
    async initialize(): Promise<Record<string, unknown>> {
      return {
        protocolVersion: "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: descriptor.curatedId, version: "1.0.0" },
      };
    },

    async listTools() {
      return restToolDefs(descriptor).map((t) => ({ ...t, inputSchema: { ...t.inputSchema } }));
    },

    async callTool(
      name: string,
      args: Record<string, unknown>,
      ctx: McpCallContext,
    ): Promise<McpToolCallResult> {
      const def = descriptor.tools.find((t) => t.name === name);
      if (def === undefined) {
        return toolResult(`Unknown tool: ${name} for plugin "${descriptor.displayName}".`, true);
      }
      const stored = ctx.secrets ?? {};
      try {
        // Configure-first gates, Dart order: secret → key id → region → bucket.
        const gates: [string, string][] = [
          [descriptor.credentialKey, descriptor.credentialLabel],
          ["access_key_id", "AWS access key ID"],
          ["region", "AWS region"],
          ["bucket", "S3 bucket"],
        ];
        for (const [key, label] of gates) {
          if ((stored[key] ?? "").trim() === "") {
            return toolResult(configureFirstMessage(descriptor.displayName, label), true);
          }
        }
        const secretAccessKey = (stored[descriptor.credentialKey] ?? "").trim();
        const accessKeyId = (stored.access_key_id ?? "").trim();
        const region = (stored.region ?? "").trim();
        const bucket = (stored.bucket ?? "").trim();

        if (name === "presign_get") {
          const key = requireStringArg(args, "key");
          const expires = Math.min(604800, Math.max(1, asInt(args.expires, "expires", 3600)));
          return toolResult(
            s3PresignedGetUrl({
              accessKeyId,
              secretAccessKey,
              region,
              bucket,
              key,
              expiresSeconds: expires,
              amzDate: new Date(),
            }),
          );
        }

        const timeoutSeconds = resolveTimeoutSeconds(args);

        if (name === "list_objects") {
          const query: Record<string, string> = { "list-type": "2" };
          const prefix = args.prefix === undefined || args.prefix === null ? "" : String(args.prefix);
          if (prefix !== "") query.prefix = prefix;
          const response = await s3Send(ctx, {
            method: "GET",
            key: "",
            query,
            accessKeyId,
            secretAccessKey,
            region,
            bucket,
            timeoutSeconds,
          });
          if (response.status < 200 || response.status >= 300) {
            return toolResult(`HTTP ${response.status}\n${response.body.toString("utf8")}`, true);
          }
          return toolResult(response.body.toString("utf8"));
        }

        if (name === "get_object") {
          const key = requireStringArg(args, "key");
          const response = await s3Send(ctx, {
            method: "GET",
            key,
            accessKeyId,
            secretAccessKey,
            region,
            bucket,
            timeoutSeconds,
          });
          if (response.status < 200 || response.status >= 300) {
            return toolResult(`HTTP ${response.status}\n${response.body.toString("utf8")}`, true);
          }
          let text: string | null = null;
          try {
            text = new TextDecoder("utf-8", { fatal: true }).decode(response.body);
          } catch {
            text = null;
          }
          if (text !== null && response.body.length <= 6000) return toolResult(text);
          return toolResult(
            `S3 object "${bucket}/${key}": ${response.body.length} bytes, ` +
              `content-type: ${response.contentType}. (Content is binary or exceeds 6000 ` +
              `bytes and is not inlined — call presign_get for a download URL.)`,
          );
        }

        if (name === "put_object") {
          const key = requireStringArg(args, "key");
          const text = requireStringArg(args, "text");
          const bodyBytes = Buffer.from(text, "utf8");
          const response = await s3Send(ctx, {
            method: "PUT",
            key,
            bodyBytes,
            contentType: "text/plain; charset=utf-8",
            accessKeyId,
            secretAccessKey,
            region,
            bucket,
            timeoutSeconds,
          });
          if (response.status < 200 || response.status >= 300) {
            return toolResult(`HTTP ${response.status}\n${response.body.toString("utf8")}`, true);
          }
          return toolResult(`Put ${bodyBytes.length} bytes to "${key}" in bucket "${bucket}".`);
        }

        if (name === "delete_object") {
          const key = requireStringArg(args, "key");
          const response = await s3Send(ctx, {
            method: "DELETE",
            key,
            accessKeyId,
            secretAccessKey,
            region,
            bucket,
            timeoutSeconds,
          });
          if (response.status < 200 || response.status >= 300) {
            return toolResult(`HTTP ${response.status}\n${response.body.toString("utf8")}`, true);
          }
          return toolResult(`Deleted "${key}" from bucket "${bucket}".`);
        }

        return toolResult(`Unknown tool: ${name} for plugin "${descriptor.displayName}".`, true);
      } catch (err) {
        return toolResult(messageOf(err), true);
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Google Drive wrapper (port of the Dart GoogleDriveCapability — only the
// multipart upload_text; everything else delegates to the engine handler)
// ---------------------------------------------------------------------------

const GDRIVE_UPLOAD_URL = "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart";
const GDRIVE_BOUNDARY = "-------314159265358979323846";

export function createGoogleDriveHandler(
  descriptor: RestServiceDescriptor = GOOGLE_DRIVE_DESCRIPTOR,
): NativeMcpHandler {
  const rest = createRestHandler(descriptor);

  async function uploadText(
    args: Record<string, unknown>,
    ctx: McpCallContext,
    token: string,
  ): Promise<McpToolCallResult> {
    const name = requireStringArg(args, "name");
    const text = typeof args.text === "string" ? args.text : "";
    const folderId = typeof args.folder_id === "string" ? args.folder_id.trim() : "";
    let timeoutSeconds: number;
    try {
      timeoutSeconds = resolveTimeoutSeconds(args);
    } catch (err) {
      return toolResult(messageOf(err), true);
    }

    const metadata: Record<string, unknown> = {
      name,
      mimeType: "text/plain",
      ...(folderId !== "" ? { parents: [folderId] } : {}),
    };
    const body =
      `--${GDRIVE_BOUNDARY}\r\n` +
      `Content-Type: application/json; charset=UTF-8\r\n\r\n` +
      `${JSON.stringify(metadata)}\r\n` +
      `--${GDRIVE_BOUNDARY}\r\n` +
      `Content-Type: text/plain\r\n\r\n` +
      `${text}\r\n` +
      `--${GDRIVE_BOUNDARY}--\r\n`;

    let res: Response;
    try {
      res = await followGuardedRedirects(ctx.fetchImpl, GDRIVE_UPLOAD_URL, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "content-type": `multipart/related; boundary=${GDRIVE_BOUNDARY}`,
        },
        body,
        signal: AbortSignal.timeout(timeoutSeconds * 1000),
      });
    } catch (err) {
      if (err instanceof Error && (err.name === "TimeoutError" || err.name === "AbortError")) {
        return toolResult(`Request to ${GDRIVE_UPLOAD_URL} timed out after ${timeoutSeconds} seconds.`, true);
      }
      return toolResult(`HTTP request failed: ${messageOf(err)}`, true);
    }
    const text2 = await res.text();
    if (res.status >= 200 && res.status < 300) return toolResult(text2);
    return toolResult(`HTTP ${res.status}\n${text2}`, true);
  }

  return {
    async initialize(params) {
      return rest.initialize(params);
    },

    async listTools() {
      return rest.listTools();
    },

    async callTool(
      name: string,
      args: Record<string, unknown>,
      ctx: McpCallContext,
    ): Promise<McpToolCallResult> {
      if (name !== "upload_text") return rest.callTool(name, args, ctx);
      const stored = ctx.secrets ?? {};
      const token = (stored[descriptor.credentialKey] ?? "").trim();
      if (token === "") {
        return toolResult(
          configureFirstMessage(descriptor.displayName, descriptor.credentialLabel),
          true,
        );
      }
      try {
        return await uploadText(args ?? {}, ctx, token);
      } catch (err) {
        return toolResult(messageOf(err), true);
      }
    },
  };
}
