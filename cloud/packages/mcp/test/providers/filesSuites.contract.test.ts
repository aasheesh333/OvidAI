import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";

import type { EgressRequest, EgressResponse, ProviderEgress } from "../../src/egress/responseLimits.js";
import { buildAuthorizeUrl } from "../../src/oauth/flow.js";
import { createSecretRedactor } from "../../src/egress/redactor.js";
import type { McpCallContext } from "../../src/transports/native.js";
import {
  FILES_SUITES_CANDIDATES,
  FILES_SUITES_CANDIDATE_IDS,
  FILES_SUITES_DESCRIPTORS,
  FILES_SUITES_IDENTITY_PROFILES,
  FILES_SUITES_OAUTH_PROFILES,
  FILES_SUITES_ORIGINS,
  assertFilesSuitesLiveIdentity,
  assertFilesSuitesLiveOAuthEvidence,
  createFilesSuitesHandler,
  exchangeFilesSuitesOAuthCode,
  filesSuitesOAuthConfig,
  refreshFilesSuitesOAuthToken,
  revokeFilesSuitesOAuthToken,
  type FilesSuitesProviderId,
} from "../../src/rest/descriptors/filesSuites.js";
import { restToolDefs } from "../../src/rest/engine.js";

const TOKEN_A = "fixture-user-a-oauth-token";
const TOKEN_B = "fixture-user-b-oauth-token";
const PKCE_VERIFIER = "pkce-verifier-fixture-12345678901234567890123456789012";

function response(body: string, status = 200, contentType = "application/json"): EgressResponse {
  const res = new Response(body, { status, headers: { "content-type": contentType } });
  return {
    status,
    headers: res.headers,
    body: res.body!,
    origin: new URL("https://fixture.invalid/"),
    remoteAddress: "192.0.2.10",
  };
}

function recordingEgress(
  calls: EgressRequest[],
  responder: (request: EgressRequest, index: number) => EgressResponse,
): ProviderEgress {
  return {
    async request(request) {
      calls.push(request);
      return responder(request, calls.length - 1);
    },
    async close() {},
  };
}

function context(uid: string): McpCallContext {
  return {
    uid,
    // Decoys prove these unrelated sign-in/deployment values are never reused.
    secrets: {
      firebase_id_token: `firebase-sign-in-${uid}`,
      google_sign_in_token: `google-sign-in-${uid}`,
      access_token: `pasted-token-${uid}`,
    },
    workspace: {},
    fetchImpl: async () => { throw new Error("legacy fetch fallback is forbidden"); },
  };
}

function handler(id: FilesSuitesProviderId, egress: ProviderEgress) {
  return createFilesSuitesHandler(id, {
    providerEgress: egress,
    redactor: createSecretRedactor(),
    resolveAccessToken: async (ctx) => ctx.uid === "user-a" ? TOKEN_A : TOKEN_B,
  });
}

const FIRST_ARGS: Record<FilesSuitesProviderId, Record<string, unknown>> = {
  dropbox: {},
  box: {},
  onedrive: {},
  sharepoint: { site_id: "site-fixture" },
  "google-docs": { document_id: "document-fixture" },
  "google-sheets": { spreadsheet_id: "sheet-fixture" },
  "google-calendar": { time_min: "2026-01-01T00:00:00Z" },
  "google-tasks": {},
  gmail: {},
  outlook: {},
};

const EXPECTED_REQUESTS: Record<FilesSuitesProviderId, {
  operation: string;
  method: string;
  origin: string;
  path: string;
  query?: Record<string, string>;
}> = {
  dropbox: { operation: "list_folder", method: "POST", origin: "https://api.dropboxapi.com", path: "/2/files/list_folder" },
  box: {
    operation: "list_root_items", method: "GET", origin: "https://api.box.com", path: "/2.0/folders/0/items",
    query: { usemarker: "true", limit: "20", fields: "id,type,name,size,modified_at" },
  },
  onedrive: {
    operation: "list_root_children", method: "GET", origin: "https://graph.microsoft.com", path: "/v1.0/me/drive/root/children",
    query: { $top: "20", $select: "id,name,size,file,folder" },
  },
  sharepoint: {
    operation: "get_site", method: "GET", origin: "https://graph.microsoft.com", path: "/v1.0/sites/site-fixture",
    query: { $select: "id,displayName,webUrl" },
  },
  "google-docs": {
    operation: "get_document", method: "GET", origin: "https://docs.googleapis.com", path: "/v1/documents/document-fixture",
    query: { includeTabsContent: "true", fields: "documentId,title,revisionId,tabs" },
  },
  "google-sheets": {
    operation: "get_spreadsheet", method: "GET", origin: "https://sheets.googleapis.com", path: "/v4/spreadsheets/sheet-fixture",
    query: { fields: "spreadsheetId,properties.title,sheets.properties" },
  },
  "google-calendar": {
    operation: "list_upcoming_events", method: "GET", origin: "https://www.googleapis.com", path: "/calendar/v3/calendars/primary/events",
    query: {
      singleEvents: "true", orderBy: "startTime", maxResults: "20",
      fields: "items(id,summary,start,end,updated),nextPageToken,nextSyncToken",
      timeMin: "2026-01-01T00:00:00Z",
    },
  },
  "google-tasks": {
    operation: "list_task_lists", method: "GET", origin: "https://tasks.googleapis.com", path: "/tasks/v1/users/@me/lists",
    query: { maxResults: "20", fields: "items(id,title,updated),nextPageToken" },
  },
  gmail: {
    operation: "list_messages", method: "GET", origin: "https://gmail.googleapis.com", path: "/gmail/v1/users/me/messages",
    query: { maxResults: "20", fields: "messages(id,threadId),nextPageToken,resultSizeEstimate" },
  },
  outlook: {
    operation: "list_messages", method: "GET", origin: "https://graph.microsoft.com", path: "/v1.0/me/messages",
    query: { $top: "20", $select: "id,subject,from,receivedDateTime,isRead" },
  },
};

function candidate(id: FilesSuitesProviderId) {
  return FILES_SUITES_CANDIDATES.find((row) => row.providerId === id)!;
}

describe.each(FILES_SUITES_CANDIDATE_IDS)("%s executable read contract", (id) => {
  it("executes only the official typed read with a per-user OAuth token and bounded sanitized output", async () => {
    const expected = EXPECTED_REQUESTS[id];
    const calls: EgressRequest[] = [];
    const egress = recordingEgress(calls, (request) => response(JSON.stringify({
      fixture: `${id}-redacted-fixture`,
      access_token: request.headers.Authorization,
      echoed_token: request.headers.Authorization?.replace("Bearer ", ""),
    })));
    const result = await handler(id, egress).callTool(expected.operation, FIRST_ARGS[id], context("user-a"));

    expect(result.isError, result.text).toBe(false);
    expect(calls).toHaveLength(1);
    const request = calls[0]!;
    expect(request.originKey).toBe(id);
    expect(request.method).toBe(expected.method);
    expect(request.url.origin).toBe(expected.origin);
    expect(request.url.pathname).toBe(expected.path);
    for (const [key, value] of Object.entries(expected.query ?? {})) {
      expect(request.url.searchParams.get(key)).toBe(value);
    }
    expect(request.headers.Authorization).toBe(`Bearer ${TOKEN_A}`);
    expect(request.headers.Authorization).not.toContain(TOKEN_B);
    expect(request.privileged).toBe(true);
    expect(request.redirect).toBe("deny");
    expect(request.limits.responseBytes).toBeLessThanOrEqual(65_536);
    expect(request.signal?.aborted).toBe(false);
    if (id === "dropbox") {
      expect(new TextDecoder().decode(request.body)).toBe('{"path":"","recursive":false,"limit":20}');
    } else {
      expect(request.body).toBeUndefined();
    }
    expect(result.text).toContain(`${id}-redacted-fixture`);
    expect(result.text).not.toContain(TOKEN_A);
    expect(result.text).not.toContain(TOKEN_B);
    expect(result.text).not.toContain(`firebase-sign-in-user-a`);
    expect(result.text).not.toContain(`pasted-token-user-a`);
  });

  it("fails closed when no provider-owned OAuth lifecycle resolver exists", async () => {
    const calls: EgressRequest[] = [];
    const egress = recordingEgress(calls, () => response("{}"));
    const definition = FILES_SUITES_DESCRIPTORS.find((entry) => entry.curatedId === id)!;
    const operation = restToolDefs(definition)[0]!;
    const unresolved = createFilesSuitesHandler(id, { providerEgress: egress });
    const result = await unresolved.callTool(operation.name, FIRST_ARGS[id], context("user-a"));
    expect(result.isError).toBe(true);
    expect(result.text).toBe("Provider OAuth lifecycle is unavailable.");
    expect(calls).toHaveLength(0);
  });

  it("projects distinct tenant canaries without cross-user token or response material", async () => {
    const calls: EgressRequest[] = [];
    const egress = recordingEgress(calls, (request) => {
      const tenantA = request.headers.Authorization === `Bearer ${TOKEN_A}`;
      return response(JSON.stringify({
        tenant_marker: tenantA ? "tenant-a-response-canary" : "tenant-b-response-canary",
        tenant_secret: tenantA ? TOKEN_A : TOKEN_B,
        access_token: tenantA ? TOKEN_A : TOKEN_B,
        projection: "valid",
      }));
    });
    const live = handler(id, egress);
    const first = await live.callTool(EXPECTED_REQUESTS[id].operation, FIRST_ARGS[id], context("user-a"));
    const second = await live.callTool(EXPECTED_REQUESTS[id].operation, FIRST_ARGS[id], context("user-b"));
    expect(first.isError, first.text).toBe(false);
    expect(second.isError, second.text).toBe(false);
    const projectedA = JSON.parse(first.text) as Record<string, unknown>;
    const projectedB = JSON.parse(second.text) as Record<string, unknown>;
    expect(projectedA).toMatchObject({
      tenant_marker: "tenant-a-response-canary",
      tenant_secret: "[REDACTED]",
      access_token: "[REDACTED]",
      projection: "valid",
    });
    expect(projectedB).toMatchObject({
      tenant_marker: "tenant-b-response-canary",
      tenant_secret: "[REDACTED]",
      access_token: "[REDACTED]",
      projection: "valid",
    });
    expect(first.text).not.toContain("tenant-b-response-canary");
    expect(first.text).not.toContain(TOKEN_B);
    expect(second.text).not.toContain("tenant-a-response-canary");
    expect(second.text).not.toContain(TOKEN_A);
    expect(calls.map((call) => call.headers.Authorization)).toEqual([
      `Bearer ${TOKEN_A}`,
      `Bearer ${TOKEN_B}`,
    ]);
    for (const call of calls) {
      expect(call.url.toString()).not.toContain(TOKEN_A);
      expect(call.url.toString()).not.toContain(TOKEN_B);
      expect(new TextDecoder().decode(call.body)).not.toContain(TOKEN_A);
      expect(new TextDecoder().decode(call.body)).not.toContain(TOKEN_B);
    }
  });
});

describe("files/suites argument snapshots across awaits", () => {
  it("keeps the Docs export ID stable when caller args mutate during OAuth resolution", async () => {
    const args = { document_id: "document-original" };
    const calls: EgressRequest[] = [];
    const egress = recordingEgress(calls, () => response("document text", 200, "text/plain"));
    const live = createFilesSuitesHandler("google-docs", {
      providerEgress: egress,
      resolveAccessToken: async () => {
        args.document_id = "document-mutated";
        return TOKEN_A;
      },
    });
    const result = await live.callTool("export_text", args, context("user-a"));
    expect(result.isError, result.text).toBe(false);
    expect(calls).toHaveLength(1);
    expect(calls[0]?.url.pathname).toBe("/drive/v3/files/document-original/export");
  });

  it("keeps the Dropbox preflight path stable when caller args mutate during OAuth resolution", async () => {
    const args = { path: "/original.txt" };
    const calls: EgressRequest[] = [];
    const egress = recordingEgress(calls, (request) => {
      if (request.url.hostname === "api.dropboxapi.com") {
        return response('{"id":"id:fixture","name":"original.txt","size":12,".tag":"file"}');
      }
      return response("fixture text", 200, "application/octet-stream");
    });
    const live = createFilesSuitesHandler("dropbox", {
      providerEgress: egress,
      resolveAccessToken: async () => {
        args.path = "/mutated.txt";
        return TOKEN_A;
      },
    });
    const result = await live.callTool("download_text", args, context("user-a"));
    expect(result.isError, result.text).toBe(false);
    expect(calls).toHaveLength(2);
    expect(new TextDecoder().decode(calls[0]?.body)).toBe('{"path":"/original.txt","include_media_info":false,"include_deleted":false,"include_has_explicit_shared_members":false}');
    expect(calls[1]?.headers["Dropbox-API-Arg"]).toBe('{"path":"/original.txt"}');
  });

  it("keeps the Dropbox download path identical to preflight when caller args mutate during metadata await", async () => {
    const args = { path: "/original.txt" };
    const calls: EgressRequest[] = [];
    const egress = recordingEgress(calls, (request, index) => {
      if (index === 0) {
        const metadata = response('{"id":"id:fixture","name":"original.txt","size":12,".tag":"file"}');
        args.path = "/mutated.txt";
        return metadata;
      }
      return response("fixture text", 200, "application/octet-stream");
    });
    const live = createFilesSuitesHandler("dropbox", {
      providerEgress: egress,
      resolveAccessToken: async () => TOKEN_A,
    });
    const result = await live.callTool("download_text", args, context("user-a"));
    expect(result.isError, result.text).toBe(false);
    expect(calls).toHaveLength(2);
    expect(new TextDecoder().decode(calls[0]?.body)).toContain('"path":"/original.txt"');
    expect(calls[1]?.headers["Dropbox-API-Arg"]).toBe('{"path":"/original.txt"}');
  });
});

describe("files/suites input and tenant boundaries", () => {
  const hostileIds: [FilesSuitesProviderId, string, Record<string, unknown>][] = [
    ["dropbox", "get_metadata", { path: "/café.txt" }],
    ["sharepoint", "get_site", { site_id: "https://evil.example" }],
    ["google-docs", "get_document", { document_id: "../admin" }],
    ["google-sheets", "get_spreadsheet", { spreadsheet_id: "sheet/other" }],
    ["google-calendar", "get_event", { event_id: "../cancel" }],
    ["google-tasks", "get_task", { tasklist_id: "list", task_id: "../delete" }],
    ["gmail", "get_message_metadata", { message_id: "../send" }],
    ["outlook", "get_message", { message_id: "../sendMail" }],
    ["box", "get_file", { file_id: "../content" }],
    ["onedrive", "get_item", { item_id: "../content" }],
  ];

  it.each(hostileIds)("%s rejects path/tenant escape in %s before egress", async (id, operation, args) => {
    const calls: EgressRequest[] = [];
    const egress = recordingEgress(calls, () => response("{}"));
    const result = await handler(id, egress).callTool(operation, args, context("user-a"));
    expect(result.isError).toBe(true);
    expect(result.text).toBe("Invalid operation arguments.");
    expect(calls).toHaveLength(0);
  });

  it("rejects unknown/base/body arguments before OAuth resolution or egress", async () => {
    for (const id of FILES_SUITES_CANDIDATE_IDS) {
      let resolutions = 0;
      const calls: EgressRequest[] = [];
      const egress = recordingEgress(calls, () => response("{}"));
      const live = createFilesSuitesHandler(id, {
        providerEgress: egress,
        resolveAccessToken: async () => { resolutions++; return TOKEN_A; },
      });
      const result = await live.callTool(EXPECTED_REQUESTS[id].operation, {
        ...FIRST_ARGS[id], base_url: "https://evil.example", body: { arbitrary: true },
      }, context("user-a"));
      expect(result.isError).toBe(true);
      expect(resolutions).toBe(0);
      expect(calls).toHaveLength(0);
    }
  });

  it("accepts only bounded rectangular Sheets A1 ranges", async () => {
    for (const range of ["Sheet1!A1:B20", "A1:Z100"]) {
      const calls: EgressRequest[] = [];
      const egress = recordingEgress(calls, () => response('{"range":"Sheet1!A1:B20","majorDimension":"ROWS","values":[]}'));
      const result = await handler("google-sheets", egress).callTool("get_values", {
        spreadsheet_id: "sheet-fixture", range,
      }, context("user-a"));
      expect(result.isError, result.text).toBe(false);
      expect(calls[0]?.url.searchParams.get("majorDimension")).toBe("ROWS");
      expect(calls[0]?.url.searchParams.get("fields")).toBe("range,majorDimension,values");
    }
    for (const range of ["A1", "A1:Z101", "A1:AA20", "B20:A1", "Sheet!A1:B20/delete", "https://evil.example"]) {
      const calls: EgressRequest[] = [];
      const egress = recordingEgress(calls, () => response("{}"));
      const result = await handler("google-sheets", egress).callTool("get_values", {
        spreadsheet_id: "sheet-fixture", range,
      }, context("user-a"));
      expect(result.isError, range).toBe(true);
      expect(calls, range).toHaveLength(0);
    }
  });

  it("does not accept Gmail metadata search, raw MIME or arbitrary Graph operations", async () => {
    for (const [id, operation, args] of [
      ["gmail", "list_messages", { q: "from:someone" }],
      ["gmail", "get_message_metadata", { message_id: "fixture", format: "raw" }],
      ["outlook", "list_messages", { $filter: "contains(subject,'secret')" }],
      ["onedrive", "list_root_children", { path: "/me/messages" }],
    ] as const) {
      const calls: EgressRequest[] = [];
      const egress = recordingEgress(calls, () => response("{}"));
      const result = await handler(id, egress).callTool(operation, args, context("user-a"));
      expect(result.isError).toBe(true);
      expect(calls).toHaveLength(0);
      expect(candidate(id).operations.some((entry) => /send|raw|upload|download_all/.test(entry.name))).toBe(false);
    }
  });
});

describe("bounded file download and native export", () => {
  it("preflights Dropbox metadata then downloads bounded UTF-8 text from the fixed content origin", async () => {
    const calls: EgressRequest[] = [];
    const egress = recordingEgress(calls, (request) => {
      if (request.url.hostname === "api.dropboxapi.com") {
        return response('{"id":"id:fixture","name":"notes.txt","path_lower":"/notes.txt","size":12,".tag":"file"}');
      }
      return response("fixture text", 200, "application/octet-stream");
    });
    const result = await handler("dropbox", egress).callTool("download_text", { path: "/notes.txt" }, context("user-a"));
    expect(result.isError, result.text).toBe(false);
    expect(result.text).toBe("fixture text");
    expect(calls.map((call) => call.url.origin + call.url.pathname)).toEqual([
      "https://api.dropboxapi.com/2/files/get_metadata",
      "https://content.dropboxapi.com/2/files/download",
    ]);
    expect(calls[1]?.headers["Dropbox-API-Arg"]).toBe('{"path":"/notes.txt"}');
    expect(calls[1]?.headers.Authorization).toBe(`Bearer ${TOKEN_A}`);
  });

  it.each([
    ["size", '{"id":"id:fixture","name":"notes.txt","size":8193,".tag":"file"}'],
    ["extension", '{"id":"id:fixture","name":"notes.pdf","size":12,".tag":"file"}'],
    ["folder", '{"id":"id:fixture","name":"notes.txt","size":12,".tag":"folder"}'],
  ])("blocks Dropbox content after failed %s preflight", async (_kind, metadata) => {
    const calls: EgressRequest[] = [];
    const egress = recordingEgress(calls, () => response(metadata));
    const result = await handler("dropbox", egress).callTool("download_text", { path: "/notes.txt" }, context("user-a"));
    expect(result.isError).toBe(true);
    expect(calls).toHaveLength(1);
    expect(calls[0]?.url.pathname).toBe("/2/files/get_metadata");
  });

  it("exports Google-native Docs as explicit bounded plain text, never Drive alt=media", async () => {
    const calls: EgressRequest[] = [];
    const egress = recordingEgress(calls, () => response("native document text", 200, "text/plain; charset=utf-8"));
    const result = await handler("google-docs", egress).callTool("export_text", { document_id: "document-fixture" }, context("user-a"));
    expect(result.isError, result.text).toBe(false);
    expect(result.text).toBe("native document text");
    expect(calls[0]?.url.toString()).toBe("https://www.googleapis.com/drive/v3/files/document-fixture/export?mimeType=text%2Fplain");
    expect(calls[0]?.url.searchParams.has("alt")).toBe(false);
  });

  it("rejects an unexpected native-export MIME and caps response bytes", async () => {
    for (const fixture of [
      { body: "not plain text", contentType: "application/pdf" },
      { body: "x".repeat(8_193), contentType: "text/plain" },
    ]) {
      const calls: EgressRequest[] = [];
      const egress = recordingEgress(calls, () => response(fixture.body, 200, fixture.contentType));
      const result = await handler("google-docs", egress).callTool("export_text", { document_id: "document-fixture" }, context("user-a"));
      expect(result.isError).toBe(true);
      expect(result.text).not.toContain(fixture.body);
    }
  });
});

describe("OAuth code exchange, refresh and revocation", () => {
  function tokenNetwork(calls: EgressRequest[], body: Record<string, unknown> | null = null): ProviderEgress {
    return recordingEgress(calls, (request) => {
      if (request.url.pathname === "/revoke" || request.url.pathname === "/oauth2/revoke" || request.url.pathname === "/2/auth/token/revoke") {
        return response("");
      }
      return response(JSON.stringify(body ?? {
        access_token: "new-access-fixture",
        refresh_token: "new-refresh-fixture",
        token_type: "Bearer",
        expires_in: 3600,
      }));
    });
  }

  it.each(FILES_SUITES_CANDIDATE_IDS)("%s exchanges a provider authorization code with PKCE, never a sign-in token", async (id) => {
    const row = candidate(id);
    const profile = FILES_SUITES_OAUTH_PROFILES[row.authProfileId];
    const config = filesSuitesOAuthConfig(id, "client-fixture");
    const calls: EgressRequest[] = [];
    const egress = recordingEgress(calls, () => response(JSON.stringify({
      access_token: "new-access-fixture",
      refresh_token: "new-refresh-fixture",
      token_type: "Bearer",
      expires_in: 3600,
      scope: config.scopes.join(" "),
    })));
    const exchanging = exchangeFilesSuitesOAuthCode(id, {
      network: { providerEgress: egress, originKey: `${id}-oauth` },
      clientId: "client-fixture",
      clientSecret: profile.clientSecretRequired ? "client-secret-fixture" : undefined,
      code: "authorization-code-fixture",
      codeVerifier: PKCE_VERIFIER,
      redirectUri: "https://ovidsi.com/oauth/callback",
    });
    if (id === "box") {
      await expect(exchanging).rejects.toThrow("OAuth PKCE is unsupported for this profile.");
      expect(calls).toHaveLength(0);
      return;
    }
    const tokens = await exchanging;
    expect(tokens.accessToken).toBe("new-access-fixture");
    expect(tokens.refreshToken).toBe("new-refresh-fixture");
    expect(calls).toHaveLength(1);
    expect(calls[0]?.url.toString()).toBe(profile.tokenUrl);
    const body = new URLSearchParams(new TextDecoder().decode(calls[0]?.body));
    expect(body.get("grant_type")).toBe("authorization_code");
    expect(body.get("code")).toBe("authorization-code-fixture");
    expect(body.get("code_verifier")).toBe(PKCE_VERIFIER);
    expect(body.get("client_id")).toBe("client-fixture");
    expect(body.get("redirect_uri")).toBe("https://ovidsi.com/oauth/callback");
    expect(body.has("id_token")).toBe(false);
    expect(body.has("firebase_id_token")).toBe(false);
    if (profile.clientSecretRequired) expect(body.get("client_secret")).toBe("client-secret-fixture");
  });

  it("encodes the exact Dropbox public client_id and never falls back to a client secret", async () => {
    const calls: EgressRequest[] = [];
    const config = filesSuitesOAuthConfig("dropbox", "dropbox-public-client-123");
    const egress = recordingEgress(calls, () => response(JSON.stringify({
      access_token: "new-access-fixture",
      refresh_token: "new-refresh-fixture",
      token_type: "Bearer",
      expires_in: 3600,
      scope: config.scopes.join(" "),
    })));
    await exchangeFilesSuitesOAuthCode("dropbox", {
      network: { providerEgress: egress, originKey: "dropbox-oauth" },
      clientId: "dropbox-public-client-123",
      clientSecret: "must-not-be-used-as-public-client-fallback",
      code: "authorization-code-fixture",
      codeVerifier: PKCE_VERIFIER,
      redirectUri: "https://ovidsi.com/oauth/callback",
    });
    expect(calls).toHaveLength(1);
    const encoded = new TextDecoder().decode(calls[0]?.body);
    expect(encoded).toContain("client_id=dropbox-public-client-123");
    expect(encoded).not.toContain("client_secret");
    expect(encoded).not.toContain("must-not-be-used-as-public-client-fallback");
    const body = new URLSearchParams(encoded);
    expect(body.get("client_id")).toBe("dropbox-public-client-123");
    expect(body.get("code_verifier")).toBe(PKCE_VERIFIER);
    expect(body.get("client_secret")).toBeNull();
  });

  it("refreshes with rotation and retains an omitted old refresh token", async () => {
    for (const id of FILES_SUITES_CANDIDATE_IDS) {
      const row = candidate(id);
      const profile = FILES_SUITES_OAUTH_PROFILES[row.authProfileId];
      for (const rotated of [true, false]) {
        const calls: EgressRequest[] = [];
        const egress = tokenNetwork(calls, {
          access_token: "refreshed-access-fixture",
          ...(rotated ? { refresh_token: "rotated-refresh-fixture" } : {}),
          token_type: "Bearer",
          expires_in: 3600,
        });
        const refreshing = refreshFilesSuitesOAuthToken(id, {
          network: { providerEgress: egress, originKey: `${id}-oauth` },
          clientId: "client-fixture",
          clientSecret: profile.clientSecretRequired ? "client-secret-fixture" : undefined,
          refreshToken: "old-refresh-fixture",
        });
        if (id === "box" && !rotated) {
          await expect(refreshing).rejects.toThrow("OAuth refresh-token rotation was not returned.");
          continue;
        }
        const tokens = await refreshing;
        expect(tokens.accessToken).toBe("refreshed-access-fixture");
        expect(tokens.refreshToken).toBe(rotated ? "rotated-refresh-fixture" : "old-refresh-fixture");
        const body = new URLSearchParams(new TextDecoder().decode(calls[0]?.body));
        expect(calls[0]?.url.toString()).toBe(profile.tokenUrl);
        expect(body.get("grant_type")).toBe("refresh_token");
        expect(body.get("refresh_token")).toBe("old-refresh-fixture");
        expect(body.get("code")).toBeNull();
      }
    }
  });

  it("rejects broader grants instead of silently retaining excess provider privilege", async () => {
    for (const [id, excess] of [
      ["google-docs", "https://www.googleapis.com/auth/drive"],
      ["box", "root_readwrite"],
      ["outlook", "Mail.ReadWrite"],
    ] as const) {
      const row = candidate(id);
      const profile = FILES_SUITES_OAUTH_PROFILES[row.authProfileId];
      const config = filesSuitesOAuthConfig(id, "client-fixture");
      const calls: EgressRequest[] = [];
      const egress = recordingEgress(calls, () => response(JSON.stringify({
        access_token: "excess-access-fixture",
        refresh_token: "refresh-fixture",
        token_type: "Bearer",
        expires_in: 3600,
        scope: [...config.scopes, excess].join(" "),
      })));
      const exchanging = exchangeFilesSuitesOAuthCode(id, {
        network: { providerEgress: egress, originKey: `${id}-oauth` },
        clientId: "client-fixture",
        clientSecret: profile.clientSecretRequired ? "client-secret-fixture" : undefined,
        code: "authorization-code-fixture",
        codeVerifier: PKCE_VERIFIER,
        redirectUri: "https://ovidsi.com/oauth/callback",
      });
      if (id === "box") {
        await expect(exchanging).rejects.toThrow("OAuth PKCE is unsupported for this profile.");
      } else {
        await expect(exchanging).rejects.toThrow("OAuth granted scopes exceed the provider operations.");
      }
    }
  });

  it("uses only documented revoke endpoints; Microsoft fails without a fabricated revoke call", async () => {
    for (const id of FILES_SUITES_CANDIDATE_IDS) {
      const row = candidate(id);
      const profile = FILES_SUITES_OAUTH_PROFILES[row.authProfileId];
      const calls: EgressRequest[] = [];
      const egress = tokenNetwork(calls);
      const input = {
        network: { providerEgress: egress, originKey: `${id}-oauth` },
        clientId: "client-fixture",
        clientSecret: profile.clientSecretRequired ? "client-secret-fixture" : undefined,
        accessToken: "access-revoke-fixture",
        refreshToken: "refresh-revoke-fixture",
      };
      if (profile.revokeUrl === null) {
        await expect(revokeFilesSuitesOAuthToken(id, input)).rejects.toThrow("OAuth remote revocation is unsupported for this profile.");
        expect(calls).toHaveLength(0);
        continue;
      }
      await revokeFilesSuitesOAuthToken(id, input);
      expect(calls).toHaveLength(1);
      expect(calls[0]?.method).toBe("POST");
      expect(calls[0]?.url.toString()).toBe(
        id === "dropbox" || id === "box" ? profile.revokeUrl : `${profile.revokeUrl}?token=refresh-revoke-fixture`,
      );
      if (id === "dropbox") expect(calls[0]?.headers.Authorization).toBe("Bearer access-revoke-fixture");
      if (id === "box") {
        const body = new URLSearchParams(new TextDecoder().decode(calls[0]?.body));
        expect(body.get("token")).toBe("access-revoke-fixture");
        expect(body.get("client_secret")).toBe("client-secret-fixture");
      }
    }
  });
});

// UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25).
describe("provider-owned identity metadata fixtures", () => {
  it("requires the identity-only scope in the provider-owned grant", () => {
    for (const id of FILES_SUITES_CANDIDATE_IDS) {
      const identity = FILES_SUITES_IDENTITY_PROFILES[id];
      expect(FILES_SUITES_ORIGINS[id].map((origin) => origin.origin)).toContain(new URL(identity.url).origin);
      if (identity.requiredScope !== null) {
        expect(filesSuitesOAuthConfig(id, "client-fixture").scopes).toContain(identity.requiredScope);
      }
    }
  });

  it("requires an active Box token for the exact client and intended user", () => {
    for (const metadata of [
      { active: false, client_id: "client-fixture", user: { id: "tenant-user" } },
      { active: true, client_id: "other-client", user: { id: "tenant-user" } },
      { active: true, client_id: "client-fixture", user: { id: "other-user" } },
    ]) {
      expect(() => assertFilesSuitesLiveIdentity({
        providerId: "box",
        clientId: "client-fixture",
        expectedUserId: "tenant-user",
        metadata,
      })).toThrow("OAuth token identity does not match the intended test user.");
    }
  });
});

describe("live OAuth redirect and PKCE evidence (offline)", () => {
  const profile = {
    ...FILES_SUITES_OAUTH_PROFILES["google-workspace-oauth"],
    androidRedirectUri: "ovidsi://oauth/callback",
  };
  const config = filesSuitesOAuthConfig("google-docs", "client-fixture");
  const codeVerifier = PKCE_VERIFIER;
  const expectedState = "registered-state-1234567890";
  const codeChallenge = createHash("sha256").update(codeVerifier, "ascii").digest("base64url");
  const webRedirectUri = profile.webRedirectUri;
  const androidRedirectUri = profile.androidRedirectUri;
  const authorizeUrl = buildAuthorizeUrl(config, {
    state: expectedState,
    codeChallenge,
    redirectUri: webRedirectUri,
  });

  function evidence(overrides: Partial<Parameters<typeof assertFilesSuitesLiveOAuthEvidence>[0]> = {}) {
    return {
      profile,
      config,
      authorizeUrl,
      codeVerifier,
      expectedState,
      callbackState: expectedState,
      webRedirectUri,
      androidRedirectUri,
      ...overrides,
    };
  }

  it("accepts exact registered Web/Android redirects and PKCE evidence", () => {
    expect(() => assertFilesSuitesLiveOAuthEvidence(evidence())).not.toThrow();
  });

  it("rejects a Web redirect that is HTTPS but not the registered profile URI", () => {
    const unregistered = "https://evil.example/oauth/callback";
    expect(() => assertFilesSuitesLiveOAuthEvidence(evidence({
      webRedirectUri: unregistered,
      authorizeUrl: buildAuthorizeUrl(config, {
        state: expectedState,
        codeChallenge,
        redirectUri: unregistered,
      }),
    }))).toThrow("Web redirect does not match the registered profile");
  });

  it("rejects an Android redirect that is parseable but not the registered profile URI", () => {
    expect(() => assertFilesSuitesLiveOAuthEvidence(evidence({
      androidRedirectUri: "https://evil.example/android/callback",
    }))).toThrow("Android redirect does not match the registered profile");
  });

  it("rejects authorize parameters outside the provider-owned profile", () => {
    const url = new URL(authorizeUrl);
    url.searchParams.set("login_hint", "attacker@example.invalid");
    expect(() => assertFilesSuitesLiveOAuthEvidence(evidence({ authorizeUrl: url.toString() })))
      .toThrow("authorize URL parameters do not match the provider profile");
  });

  it("rejects a PKCE challenge that was not derived from the supplied verifier", () => {
    const url = new URL(authorizeUrl);
    url.searchParams.set("code_challenge", "a".repeat(43));
    expect(() => assertFilesSuitesLiveOAuthEvidence(evidence({ authorizeUrl: url.toString() })))
      .toThrow("authorize URL parameters do not match the provider profile");
  });
});

describe("production catalog gate", () => {
  it("does not leak documentation-only or lifecycle-blocked candidates into either catalog", async () => {
    const { CURATED_IDS, CURATED_MANIFEST, FILES_SUITES_CATALOG_MANIFEST, createCuratedCatalog } = await import("../../src/catalog.js");
    const { CURATED_DESCRIPTORS } = await import("../../src/rest/descriptors/index.js");
    const catalog = createCuratedCatalog({
      fetchImpl: async () => new Response("unexpected", { status: 500 }),
      workspace: {
        read: async () => null,
        write: async () => {},
        list: async () => [],
        stat: async () => null,
        remove: async () => {},
      },
    });
    expect(FILES_SUITES_CATALOG_MANIFEST).toEqual([]);
    for (const id of FILES_SUITES_CANDIDATE_IDS) {
      expect(CURATED_IDS).not.toContain(id);
      expect(CURATED_MANIFEST.some((entry) => entry.curatedId === id)).toBe(false);
      expect(CURATED_DESCRIPTORS.some((entry) => entry.curatedId === id)).toBe(false);
      expect(catalog.get(id)).toBeUndefined();
      expect(candidate(id).releaseState).toBe("blocked");
    }
    expect(FILES_SUITES_ORIGINS["dropbox"].map((url) => url.origin)).toEqual([
      "https://api.dropboxapi.com",
      "https://content.dropboxapi.com",
    ]);
  });
});
