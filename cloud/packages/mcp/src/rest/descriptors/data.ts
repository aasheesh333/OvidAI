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
  sha256Hex,
  sigV4Encode,
  restToolDefs,
  createSecretRedactor,
  type RestHandlerOptions,
  type RestServiceDescriptor,
} from "../engine.js";
import {
  assertBoundedHeadersOrCancel,
  egressResponseFromDecodedFetch,
  readBoundedBody,
  type EgressLimits,
  type ProviderEgress,
} from "../../egress/responseLimits.js";
import {
  authorizeProviderOperation,
  snapshotProviderArgs,
  validateProviderArgs,
  type ToolContext,
} from "../../providers/types.js";
import { trimToolResult, type McpToolCallResult } from "../../client.js";
import type { McpCallContext, NativeMcpHandler } from "../../transports/native.js";

// ---------------------------------------------------------------------------
// Descriptors
// ---------------------------------------------------------------------------

export const NOTION_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "notion",
  displayName: "Notion Sync",
  description: "Search Notion and query pages/data sources through the current read API.",
  baseUrl: "https://api.notion.com/v1",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "api_key",
  credentialLabel: "Notion API key",
  staticHeaders: { "Notion-Version": "2026-03-11" },
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
      name: "query_data_source",
      description: "Query a Notion data source with bounded cursor pagination.",
      method: "POST",
      path: "/data_sources/{data_source_id}/query",
      effect: "read",
      required: ["data_source_id"],
      bodyTemplate: {
        start_cursor: "arg:start_cursor",
        page_size: "int:page_size:50",
      },
      inputSchema: {
        type: "object",
        properties: {
          data_source_id: { type: "string", minLength: 1, maxLength: 128 },
          start_cursor: { type: "string", maxLength: 8_192 },
          page_size: { type: "integer", minimum: 1, maximum: 100, default: 50 },
        },
        required: ["data_source_id"],
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
  description: "Search metadata and read Drive blobs or native-document exports with bounded responses.",
  baseUrl: "https://www.googleapis.com/drive/v3",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "access_token",
  credentialLabel: "Google OAuth access token",
  tools: [
    {
      name: "search",
      description: "Search Google Drive files with an explicit bounded field projection.",
      method: "GET",
      path: "/files",
      effect: "read",
      queryArgMap: { query: "q", limit: "pageSize:20" },
      fixedQuery: {
        fields: "nextPageToken,files(id,name,mimeType,parents,capabilities.canDownload)",
        supportsAllDrives: "true",
      },
      inputSchema: {
        type: "object",
        properties: {
          query: { type: "string", maxLength: 2_048 },
          limit: { type: "integer", minimum: 1, maximum: 100, default: 20 },
        },
      },
    },
    {
      name: "get_file",
      description: "Get bounded Drive file metadata and download capability by id.",
      method: "GET",
      path: "/files/{id}",
      effect: "read",
      required: ["id"],
      fixedQuery: {
        fields: "id,name,mimeType,capabilities.canDownload",
        supportsAllDrives: "true",
      },
      inputSchema: {
        type: "object",
        properties: { id: { type: "string", minLength: 1, maxLength: 256 } },
        required: ["id"],
      },
    },
    {
      name: "download_file",
      description: "Download blob content with alt=media; native Google documents use export_native instead.",
      method: "GET",
      path: "/files/{id}",
      effect: "read",
      required: ["id"],
      fixedQuery: { alt: "media", supportsAllDrives: "true" },
      outputPolicy: { kind: "binary_metadata", maxBytes: 65_536 },
      inputSchema: {
        type: "object",
        properties: { id: { type: "string", minLength: 1, maxLength: 256 } },
        required: ["id"],
      },
    },
    {
      name: "export_native",
      description: "Export a native Google Workspace document through files.export using an allowed MIME type.",
      method: "GET",
      path: "/files/{id}/export",
      effect: "read",
      required: ["id", "mime_type"],
      queryArgMap: { mime_type: "mimeType" },
      fixedQuery: { supportsAllDrives: "true" },
      outputPolicy: { kind: "binary_metadata", maxBytes: 65_536 },
      inputSchema: {
        type: "object",
        properties: {
          id: { type: "string", minLength: 1, maxLength: 256 },
          mime_type: {
            type: "string",
            enum: [
              "text/plain",
              "text/csv",
              "text/html",
              "application/pdf",
              "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
              "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
              "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            ],
          },
        },
        required: ["id", "mime_type"],
      },
    },
  ],
};

export const AIRTABLE_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "airtable",
  displayName: "Airtable MCP",
  description: "Read Airtable records through scoped PAT/OAuth access.",
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
  ],
};

export const SUPABASE_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "supabase",
  displayName: "Supabase MCP",
  description: "Read allowlisted Supabase tables with a publishable key, user JWT, grants, and RLS.",
  baseUrl: "{base_url}",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "user_jwt",
  credentialLabel: "Supabase Auth user JWT",
  extraConfig: [
    { key: "publishable_key", label: "Supabase publishable key", secret: false },
    {
      key: "base_url",
      label: "Supabase project URL",
      secret: false,
      hint: "The project origin, e.g. https://xyzcompany.supabase.co.",
    },
    { key: "allowed_tables", label: "Allowed tables (comma-separated)", secret: false },
    { key: "allowed_columns", label: "Allowed projection columns (comma-separated)", secret: false },
  ],
  tools: [
    {
      name: "select",
      description: "Select bounded columns and rows from an allowlisted table using the end user's RLS identity.",
      method: "GET",
      path: "/rest/v1/{table}",
      effect: "read",
      queryArgMap: { columns: "select:id", limit: "limit:20" },
      outputPolicy: { kind: "redacted_json", maxBytes: 65_536 },
      inputSchema: {
        type: "object",
        properties: {
          table: { type: "string", minLength: 1, maxLength: 63 },
          columns: { type: "string", minLength: 1, maxLength: 512 },
          limit: { type: "integer", minimum: 1, maximum: 100, default: 20 },
        },
        required: ["table"],
      },
      required: ["table"],
    },
  ],
};

function validSupabaseUserJwt(token: string): boolean {
  const parts = token.split(".");
  if (parts.length !== 3 || parts.some((part) => part === "")) return false;
  try {
    const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8")) as { role?: unknown };
    return payload.role === "authenticated";
  } catch {
    return false;
  }
}

/** Adds the publishable application key separately from the end-user Bearer identity. */
export function createSupabaseHandler(
  options: Omit<RestHandlerOptions, "resolveConnectionConfig"> = {},
): NativeMcpHandler {
  const definitions = createRestHandler(SUPABASE_DESCRIPTOR, options);
  return {
    initialize: (params) => definitions.initialize(params),
    listTools: () => definitions.listTools(),
    async callTool(name, args, ctx) {
      const stored = ctx.secrets ?? {};
      const publishable = (stored.publishable_key ?? "").trim();
      const jwt = (stored.user_jwt ?? "").trim();
      const table = typeof args.table === "string" ? args.table : "";
      const allowedTables = (stored.allowed_tables ?? "").split(",").map((entry) => entry.trim()).filter((entry) => entry !== "");
      const allowedColumns = new Set(
        (stored.allowed_columns ?? "").split(",").map((entry) => entry.trim()).filter((entry) => entry !== ""),
      );
      let base: URL | undefined;
      try { base = new URL((stored.base_url ?? "").trim()); } catch { base = undefined; }
      const validBase = base !== undefined && base.protocol === "https:" && base.username === "" && base.password === "" &&
        base.search === "" && base.hash === "" && /^[a-z0-9-]+\.supabase\.co$/.test(base.hostname) &&
        (base.pathname === "/" || base.pathname === "");
      const columns = typeof args.columns === "string" ? args.columns : "id";
      const requestedColumns = columns.split(",").map((column) => column.trim());
      const validColumns = requestedColumns.length > 0 && requestedColumns.every((column) =>
        /^[A-Za-z_][A-Za-z0-9_]*$/.test(column) && allowedColumns.has(column)
      );
      if (!publishable.startsWith("sb_publishable_") || !validSupabaseUserJwt(jwt) || !validBase ||
          !/^[A-Za-z_][A-Za-z0-9_]*$/.test(table) || !allowedTables.includes(table) || !validColumns) {
        return toolResult("Invalid Supabase connection configuration or table policy.", true);
      }
      const descriptor: RestServiceDescriptor = {
        ...SUPABASE_DESCRIPTOR,
        staticHeaders: { apikey: publishable },
      };
      return createRestHandler(descriptor, options).callTool(name, args, ctx);
    },
  };
}

export const FIREBASE_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "firebase",
  displayName: "Firebase MCP",
  description: "Firestore documents and collections over the REST API (Firestore only).",
  baseUrl: "https://firestore.googleapis.com/v1",
  auth: "bearer",
  authPrefix: "Bearer ",
  credentialKey: "access_token",
  credentialLabel: "Firebase ID token or Google OAuth access token",
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
  ],
};

export const MONGODB_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "mongodb",
  displayName: "MongoDB Atlas Data API (retired)",
  description: "Deprecated: Atlas Data API and Custom HTTPS Endpoints were removed on 2025-09-30; no document calls are available.",
  baseUrl: "https://www.mongodb.com",
  auth: "none",
  credentialKey: "",
  credentialLabel: "Retired MongoDB Atlas Data API credential",
  tools: [],
};

export const S3_DESCRIPTOR: RestServiceDescriptor = {
  curatedId: "s3",
  displayName: "S3 MCP",
  description: "Read S3 objects through short-lived SigV4 credentials with bounded responses and no redirects.",
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
    { key: "session_token", label: "AWS STS session token", secret: true },
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
        "Fetch an object key (SigV4-signed). Small UTF-8 text is returned inline; other content is metadata only.",
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
    method: "GET" | "PUT" | "DELETE";
    key: string;
    query?: Record<string, string>;
    bodyBytes?: Uint8Array;
    contentType?: string;
    accessKeyId: string;
    secretAccessKey: string;
    region: string;
    bucket: string;
    timeoutSeconds: number;
    sessionToken?: string;
    providerEgress?: ProviderEgress;
    secretValues?: readonly string[];
  },
): Promise<S3SendResult> {
  const host = `${opts.bucket}.s3.${opts.region}.amazonaws.com`;
  const rawPath = opts.key === "" ? "/" : `/${opts.key}`;
  const encodedPath = opts.key === "" ? "/" : `/${opts.key.split("/").map(sigV4Encode).join("/")}`;
  const now = new Date();
  const amzDate = amzDateStr(now);
  const payloadHash = sha256Hex(opts.bodyBytes ?? Buffer.alloc(0));
  const signedHeaders: Record<string, string> = {
    host,
    "x-amz-date": amzDate,
    "x-amz-content-sha256": payloadHash,
    ...(opts.sessionToken === undefined || opts.sessionToken === "" ? {} : { "x-amz-security-token": opts.sessionToken }),
  };
  const authorization = s3Authorization({
    accessKeyId: opts.accessKeyId,
    secretAccessKey: opts.secretAccessKey,
    region: opts.region,
    method: opts.method,
    canonicalUri: rawPath,
    queryParameters: opts.query ?? {},
    headers: signedHeaders,
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
    "x-amz-content-sha256": payloadHash,
    Authorization: authorization,
    ...(opts.sessionToken === undefined || opts.sessionToken === "" ? {} : { "x-amz-security-token": opts.sessionToken }),
  };
  if (opts.contentType !== undefined) headers["content-type"] = opts.contentType;

  const totalMs = opts.timeoutSeconds * 1_000;
  const limits: EgressLimits = {
    connectMs: totalMs,
    headersMs: totalMs,
    idleMs: totalMs,
    totalMs,
    maxRedirects: 0,
    headerBytes: 8_192,
    responseBytes: 65_536,
    decompressedBytes: 262_144,
  };
  try {
    const url = new URL(urlStr);
    const response = opts.providerEgress !== undefined
      ? await opts.providerEgress.request({
          originKey: "s3",
          url,
          method: opts.method,
          headers,
          ...(opts.bodyBytes === undefined ? {} : { body: opts.bodyBytes }),
          secretValues: opts.secretValues ?? [opts.secretAccessKey],
          privileged: true,
          redirect: "deny",
          limits,
          signal: AbortSignal.timeout(totalMs),
        })
      : await (async () => {
          const legacy = await ctx.fetchImpl(url.toString(), {
            method: opts.method,
            headers,
            body: opts.bodyBytes as BodyInit | undefined,
            redirect: "manual",
            signal: AbortSignal.timeout(totalMs),
          });
          return egressResponseFromDecodedFetch(legacy, url);
        })();
    await assertBoundedHeadersOrCancel(response, limits);
    const body = Buffer.from(await readBoundedBody(response, limits));
    return { status: response.status, body, contentType: response.headers.get("content-type") ?? "unknown" };
  } catch {
    throw new Error("Provider request failed or exceeded its safety limits.");
  }
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
function nativeAuthorizationContext(ctx: McpCallContext, providerId: string): ToolContext {
  const candidate = ctx as unknown as Partial<ToolContext>;
  return {
    ...candidate,
    sessionId: candidate.sessionId ?? "",
    runId: candidate.runId ?? "",
    userId: candidate.userId ?? ctx.uid,
    connectionId: candidate.connectionId ?? "",
    providerId,
    mode: candidate.mode ?? "safe",
    planMode: candidate.planMode ?? false,
    unattended: candidate.unattended ?? true,
    isSubagent: candidate.isSubagent ?? false,
    depth: candidate.depth ?? 0,
    callKey: candidate.callKey ?? "",
    signal: candidate.signal ?? new AbortController().signal,
  } as ToolContext;
}

export function createS3Handler(
  descriptor: RestServiceDescriptor = S3_DESCRIPTOR,
  options: RestHandlerOptions = {},
): NativeMcpHandler {
  const published = restToolDefs(descriptor).map((operation) => ({
    ...operation,
    description: operation.description ?? `Read ${operation.name} through the official provider operation.`,
    inputSchema: operation.inputSchema ?? {
      type: "object",
      properties: {},
      required: [],
      additionalProperties: false,
      maxProperties: 0,
    },
  }));
  const redactor = options.redactor ?? createSecretRedactor();
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
      const operation = published.find((candidate) => candidate.name === name);
      if (operation === undefined) {
        return toolResult("Unknown provider operation.", true);
      }
      try {
        args = snapshotProviderArgs(args);
      } catch {
        return toolResult("Invalid operation arguments.", true);
      }
      if (!validateProviderArgs(operation.inputSchema, args).ok) {
        return toolResult("Invalid operation arguments.", true);
      }
      const authorization = await authorizeProviderOperation(nativeAuthorizationContext(ctx, descriptor.curatedId), operation, args);
      if (authorization.kind === "deny") return toolResult(`Operation denied (${authorization.code}).`, true);
      const stored = ctx.secrets ?? {};
      const redactionValues = [
        stored[descriptor.credentialKey],
        stored.access_key_id,
        stored.session_token,
      ].filter((value): value is string => typeof value === "string" && value !== "");
      const finish = (text: string, isError = false): McpToolCallResult =>
        toolResult(redactor.text(text, redactionValues), isError);
      try {
        // Configure-first gates, Dart order: secret → key id → region → bucket.
        const gates: [string, string][] = [
          [descriptor.credentialKey, descriptor.credentialLabel],
          ["access_key_id", "AWS access key ID"],
          ["region", "AWS region"],
          ["session_token", "AWS STS session token"],
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
        if (!/^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/.test(bucket) || !/^[a-z0-9-]+$/.test(region)) {
          return finish("Invalid S3 connection configuration.", true);
        }
        const transport = {
          sessionToken: (stored.session_token ?? "").trim(),
          providerEgress: options.providerEgress,
          secretValues: Object.values(stored).filter((value) => value !== ""),
        };

        const timeoutSeconds = resolveTimeoutSeconds(args);

        if (name === "list_objects") {
          const query: Record<string, string> = { "list-type": "2", "max-keys": "100" };
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
            ...transport,
          });
          if (response.status < 200 || response.status >= 300) {
            return finish(`Provider request failed (HTTP ${response.status}).`, true);
          }
          return finish(response.body.toString("utf8"));
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
            ...transport,
          });
          if (response.status < 200 || response.status >= 300) {
            return finish(`Provider request failed (HTTP ${response.status}).`, true);
          }
          let text: string | null = null;
          try {
            text = new TextDecoder("utf-8", { fatal: true }).decode(response.body);
          } catch {
            text = null;
          }
          if (text !== null && response.body.length <= 6000) return finish(text);
          return finish(
            `S3 object "${bucket}/${key}": ${response.body.length} bytes, ` +
              `content-type: ${response.contentType}. Content is binary or exceeds 6000 bytes and is not inlined.`,
          );
        }

        return toolResult(`Unknown tool: ${name} for plugin "${descriptor.displayName}".`, true);
      } catch (err) {
        return finish(messageOf(err), true);
      }
    },
  };
}

// ---------------------------------------------------------------------------
// Google Drive wrapper (port of the Dart GoogleDriveCapability — only the
// multipart upload_text; everything else delegates to the engine handler)
// ---------------------------------------------------------------------------

/** Reserved for a separately evidenced future write; no upload operation is published. */
export const GOOGLE_DRIVE_UPLOAD_ORIGIN = "https://www.googleapis.com/upload/drive/v3";

export function createGoogleDriveHandler(
  descriptor: RestServiceDescriptor = GOOGLE_DRIVE_DESCRIPTOR,
  options: RestHandlerOptions = {},
): NativeMcpHandler {
  return createRestHandler(descriptor, options);
}
