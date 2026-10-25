import { describe, expect, it } from "vitest";
import { createCuratedCatalog } from "../../src/catalog.js";
import type { McpToolCallResult } from "../../src/client.js";
import { createFetchHandler } from "../../src/native/fetch.js";
import type { GuardedFetch } from "../../src/ssrf.js";
import type { McpCallContext } from "../../src/transports/native.js";
import { FETCH_SANITIZED_FIXTURE } from "./fetch.sanitized.fixture.js";
import { createLinearHandler, JIRA_DESCRIPTOR } from "../../src/rest/descriptors/dev.js";
import {
  createGoogleDriveHandler,
  createS3Handler,
  createSupabaseHandler,
  FIREBASE_DESCRIPTOR,
  GOOGLE_DRIVE_UPLOAD_ORIGIN,
  MONGODB_DESCRIPTOR,
  NOTION_DESCRIPTOR,
} from "../../src/rest/descriptors/data.js";
import {
  createDiscordHandler,
  createSlackHandler,
  createTelegramHandler,
} from "../../src/rest/descriptors/comms.js";
import { CURATED_DESCRIPTORS } from "../../src/rest/descriptors/index.js";
import { createRestHandler, restToolDefs } from "../../src/rest/engine.js";
import { ORIGINAL_READINESS_ROWS } from "../../src/providerEvidence.js";

interface RecordedCall { url: string; init?: RequestInit }

function fakeFetch(status = 200, body: string | Uint8Array<ArrayBuffer> = "{}"): { calls: RecordedCall[]; impl: GuardedFetch } {
  const calls: RecordedCall[] = [];
  return {
    calls,
    impl: async (url, init) => {
      calls.push({ url, init });
      return new Response(status === 204 || status === 304 ? null : body, {
        status,
        headers: status === 302 ? { location: "https://evil.example/redirect" } : undefined,
      });
    },
  };
}

function ctx(secrets: Record<string, string>, fetchImpl: GuardedFetch): McpCallContext {
  return {
    uid: "user-1",
    secrets,
    workspace: {},
    fetchImpl,
    mode: "auto",
    planMode: false,
    unattended: false,
  } as McpCallContext;
}

function headers(call: RecordedCall): Record<string, string> {
  return (call.init?.headers ?? {}) as Record<string, string>;
}

function userJwt(role = "authenticated"): string {
  const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${encode({ alg: "HS256", typ: "JWT" })}.${encode({ role, sub: "user-1" })}.signature`;
}

const supabaseConfig = {
  publishable_key: "sb_publishable_test",
  user_jwt: userJwt(),
  base_url: "https://project.supabase.co",
  allowed_tables: "tasks,notes",
  allowed_columns: "id,title",
};

describe("original provider official contracts", () => {
  // The readiness row cites this exact native-handler fixture anchor.
  it("fetch-sanitized-fixture", async () => {
    const fixture = FETCH_SANITIZED_FIXTURE;
    const handler = createFetchHandler();
    const tools = await handler.listTools();
    expect(tools.map((tool) => tool.name)).toEqual(["fetch"]);
    expect(tools[0]).toMatchObject({
      effect: "read",
      request: { originKey: "public-web", method: "GET" },
      outputPolicy: { kind: "redacted_text" },
    });
    const schema = tools[0]?.inputSchema as { properties?: Record<string, unknown> } | undefined;
    expect(Object.keys(schema?.properties ?? {})).toEqual(["url", "max_length", "raw"]);

    const network = fakeFetch(200, fixture.successBody);
    const result: McpToolCallResult = await handler.callTool(
      "fetch",
      fixture.request,
      ctx({}, network.impl),
    );
    const expected = {
      text: fixture.expectedText,
      isError: false,
      content: [{ type: "text", text: fixture.expectedText }],
    } satisfies McpToolCallResult;
    expect(result).toEqual(expected);
    expect(JSON.stringify(result)).not.toContain(fixture.canary);
    expect(network.calls).toHaveLength(1);
    expect(network.calls[0].url).toBe(fixture.request.url);
    expect(network.calls[0].init?.method).toBe("GET");
    expect(network.calls[0].init?.body).toBeUndefined();
    expect(network.calls[0].init?.redirect).toBe("manual");
    expect(headers(network.calls[0])).toEqual({
      "User-Agent": "Mozilla/5.0 (compatible; OvidAI/1.0)",
    });

    for (const args of [
      { url: fixture.request.url, method: "POST", body: "fixture write" },
      { url: fixture.request.url, headers: { authorization: `Bearer ${fixture.canary}` } },
      { url: fixture.request.url, access_token: fixture.canary },
    ]) {
      const rejected = await handler.callTool("fetch", args, ctx({}, network.impl));
      expect(rejected).toEqual({
        text: "Invalid operation arguments.",
        isError: true,
        content: [{ type: "text", text: "Invalid operation arguments." }],
      });
      expect(JSON.stringify(rejected)).not.toContain(fixture.canary);
    }
    expect(network.calls).toHaveLength(1);

    const failedNetwork = fakeFetch(fixture.failureStatus, fixture.failureBody);
    const failureResult = await handler.callTool(
      "fetch",
      { url: fixture.request.url },
      ctx({}, failedNetwork.impl),
    );
    const failureText = `HTTP error ${fixture.failureStatus}`;
    expect(failureResult).toEqual({
      text: failureText,
      isError: true,
      content: [{ type: "text", text: failureText }],
    });
    expect(JSON.stringify(failureResult)).not.toContain(fixture.canary);
  });

  it("uses Linear personal keys directly, OAuth as Bearer, fixed documents, and GraphQL envelope checks", async () => {
    const personal = fakeFetch(200, '{"data":{"viewer":{"id":"u1"}}}');
    const handler = createLinearHandler();
    const result = await handler.callTool("get_viewer", {}, ctx({ personal_api_key: "lin_personal" }, personal.impl));
    expect(result.isError).toBe(false);
    expect(headers(personal.calls[0]).Authorization).toBe("lin_personal");
    const document = JSON.parse(String(personal.calls[0].init?.body)) as { query: string };
    expect(document.query).toContain("viewer");
    expect(document.query).not.toContain("mutation");

    const oauth = fakeFetch(200, '{"data":{"viewer":{"id":"u1"}}}');
    await createLinearHandler().callTool("get_viewer", {}, ctx({ oauth_access_token: "lin_oauth" }, oauth.impl));
    expect(headers(oauth.calls[0]).Authorization).toBe("Bearer lin_oauth");

    const failed = fakeFetch(200, '{"errors":[{"message":"secret upstream detail"}]}');
    const rejected = await createLinearHandler().callTool("get_viewer", {}, ctx({ personal_api_key: "lin_personal" }, failed.impl));
    expect(rejected.isError).toBe(true);
    expect(rejected.text).not.toContain("secret upstream detail");
  });

  it("separates Drive blob download from bounded native export and reserves a distinct upload origin", async () => {
    const download = fakeFetch(200, new Uint8Array([1, 2, 3]));
    await createGoogleDriveHandler().callTool("download_file", { id: "blob-1" }, ctx({ access_token: "drive-token" }, download.impl));
    const downloadUrl = new URL(download.calls[0].url);
    expect(downloadUrl.pathname).toBe("/drive/v3/files/blob-1");
    expect(downloadUrl.searchParams.get("alt")).toBe("media");
    expect(downloadUrl.searchParams.has("mimeType")).toBe(false);

    const exported = fakeFetch(200, new Uint8Array([1, 2, 3]));
    await createGoogleDriveHandler().callTool(
      "export_native",
      { id: "doc-1", mime_type: "application/pdf" },
      ctx({ access_token: "drive-token" }, exported.impl),
    );
    const exportUrl = new URL(exported.calls[0].url);
    expect(exportUrl.pathname).toBe("/drive/v3/files/doc-1/export");
    expect(exportUrl.searchParams.get("mimeType")).toBe("application/pdf");
    expect(exportUrl.searchParams.has("alt")).toBe(false);

    const denied = fakeFetch();
    const invalid = await createGoogleDriveHandler().callTool(
      "export_native",
      { id: "doc-1", mime_type: "application/x-arbitrary" },
      ctx({ access_token: "drive-token" }, denied.impl),
    );
    expect(invalid.isError).toBe(true);
    expect(denied.calls).toHaveLength(0);
    expect(GOOGLE_DRIVE_UPLOAD_ORIGIN).toBe("https://www.googleapis.com/upload/drive/v3");
    expect((await createGoogleDriveHandler().listTools()).some((tool) => tool.name === "upload_text")).toBe(false);
  });

  it("uses Firestore OAuth Bearer auth and never treats a web API key as document authorization", async () => {
    const handler = createRestHandler(FIREBASE_DESCRIPTOR);
    const oauth = fakeFetch(200, '{"documents":[]}');
    await handler.callTool(
      "list_documents",
      { collection: "users" },
      ctx({ access_token: "firebase-oauth", project_id: "project-1" }, oauth.impl),
    );
    const url = new URL(oauth.calls[0].url);
    expect(url.searchParams.has("key")).toBe(false);
    expect(headers(oauth.calls[0]).Authorization).toBe("Bearer firebase-oauth");

    const webKey = fakeFetch();
    const denied = await handler.callTool(
      "list_documents",
      { collection: "users" },
      ctx({ api_key: "firebase-web-key", project_id: "project-1" }, webKey.impl),
    );
    expect(denied.isError).toBe(true);
    expect(webKey.calls).toHaveLength(0);
  });

  it("retires MongoDB Atlas Data API without a callable legacy fallback", async () => {
    const row = ORIGINAL_READINESS_ROWS.find((candidate) => candidate.providerId === "mongodb");
    expect(row?.releaseState).toBe("deprecated");
    expect(MONGODB_DESCRIPTOR.tools).toEqual([]);
    expect(restToolDefs(MONGODB_DESCRIPTOR)).toEqual([]);
    const network = fakeFetch();
    const legacy = await createRestHandler(MONGODB_DESCRIPTOR).callTool("find", {}, ctx({}, network.impl));
    expect(legacy.isError).toBe(true);
    expect(network.calls).toHaveLength(0);
    const catalog = createCuratedCatalog({ fetchImpl: network.impl, workspace: {} as never });
    expect(catalog.get("mongodb")).toBeUndefined();
  });

  it("does not follow S3 redirects or expose upstream redirect bodies", async () => {
    const network = fakeFetch(302, "do-not-follow-or-return");
    const result = await createS3Handler().callTool("list_objects", {}, ctx({
      secret_access_key: "aws-secret",
      access_key_id: "AKIDEXAMPLE",
      region: "us-east-1",
      bucket: "bucket-1",
      session_token: "sts-session-token",
    }, network.impl));
    expect(result.isError).toBe(true);
    expect(result.text).not.toContain("do-not-follow-or-return");
    expect(network.calls).toHaveLength(1);
    expect(network.calls[0].init?.redirect).toBe("manual");
  });

  it("uses Slack user-token reads and treats HTTP-200 ok:false envelopes as failures", async () => {
    const network = fakeFetch(200, '{"ok":false,"error":"invalid_auth","echo":"secret-upstream"}');
    const result = await createSlackHandler().callTool("list_channels", {}, ctx({ user_token: "xoxp-user" }, network.impl));
    expect(result.isError).toBe(true);
    expect(result.text).toContain("invalid_auth");
    expect(result.text).not.toContain("secret-upstream");
    expect(headers(network.calls[0]).Authorization).toBe("Bearer xoxp-user");
    const bot = fakeFetch();
    const denied = await createSlackHandler().callTool(
      "list_channels",
      {},
      ctx({ user_token: "xoxb-bot-not-user" }, bot.impl),
    );
    expect(denied.isError).toBe(true);
    expect(bot.calls).toHaveLength(0);
    expect((await createSlackHandler().listTools()).some((tool) => tool.name === "send_message")).toBe(false);
  });

  it("pins Discord v10 OAuth-user reads without conflating bot authority", async () => {
    const network = fakeFetch(200, '{"id":"user-1"}');
    const result = await createDiscordHandler().callTool("get_current_user", {}, ctx({ access_token: "discord-user" }, network.impl));
    expect(result.isError).toBe(false);
    expect(network.calls[0].url).toBe("https://discord.com/api/v10/users/@me");
    expect(headers(network.calls[0]).Authorization).toBe("Bearer discord-user");
    expect(headers(network.calls[0])["User-Agent"]).toBe("DiscordBot (https://ovidsi.com, 1.0)");
    expect((await createDiscordHandler().listTools()).map((tool) => tool.name)).not.toContain("send_message");

    const bot = fakeFetch();
    const denied = await createDiscordHandler().callTool("get_current_user", {}, ctx({ bot_token: "discord-bot" }, bot.impl));
    expect(denied.isError).toBe(true);
    expect(bot.calls).toHaveLength(0);
  });

  it("checks Telegram envelopes and redacts the credential-bearing URL path", async () => {
    const token = "123456:secret-token";
    const failure = fakeFetch(200, '{"ok":false,"description":"Unauthorized","error_code":401}');
    const rejected = await createTelegramHandler().callTool("get_me", {}, ctx({ bot_token: token }, failure.impl));
    expect(rejected.isError).toBe(true);
    expect(rejected.text).not.toContain(token);
    expect(rejected.text).not.toContain("Unauthorized");

    const echoed = fakeFetch(200, JSON.stringify({ ok: true, result: { url: `https://api.telegram.org/bot${token}/getMe` } }));
    const result = await createTelegramHandler().callTool("get_me", {}, ctx({ bot_token: token }, echoed.impl));
    expect(result.text).not.toContain(token);
    expect(result.text).not.toContain(encodeURIComponent(token));
    expect(result.text).toContain("[REDACTED]");
    expect((await createTelegramHandler().listTools()).map((tool) => tool.name)).not.toContain("get_updates");
    expect((await createTelegramHandler().listTools()).map((tool) => tool.name)).not.toContain("send_message");
  });

  it("restricts Telegram getChat to connection-approved chat IDs", async () => {
    const network = fakeFetch(200, '{"ok":true,"result":{"id":42}}');
    const config = { bot_token: "123456:secret-token", allowed_chat_ids: "42,99" };
    const handler = createTelegramHandler();
    const allowed = await handler.callTool("get_chat", { chat_id: "42" }, ctx(config, network.impl));
    expect(allowed.isError).toBe(false);
    expect(network.calls).toHaveLength(1);
    const denied = await handler.callTool("get_chat", { chat_id: "100" }, ctx(config, network.impl));
    expect(denied.isError).toBe(true);
    expect(network.calls).toHaveLength(1);
  });

  it("uses Supabase publishable+user-JWT auth and enforces table allowlists with no mutations", async () => {
    const network = fakeFetch(200, "[]");
    const result = await createSupabaseHandler().callTool(
      "select",
      { table: "tasks", columns: "id,title", limit: 20 },
      ctx(supabaseConfig, network.impl),
    );
    expect(result.isError).toBe(false);
    expect(headers(network.calls[0]).apikey).toBe("sb_publishable_test");
    expect(headers(network.calls[0]).Authorization).toBe(`Bearer ${supabaseConfig.user_jwt}`);
    const url = new URL(network.calls[0].url);
    expect(url.searchParams.get("select")).toBe("id,title");
    expect(url.searchParams.get("limit")).toBe("20");

    for (const [name, args, secrets] of [
      ["select", { table: "private", columns: "id" }, supabaseConfig],
      ["select", { table: "tasks", columns: "id,private_secret" }, supabaseConfig],
      ["select", { table: "tasks", columns: "*" }, supabaseConfig],
      ["select", { table: "tasks", columns: "id" }, { ...supabaseConfig, user_jwt: userJwt("service_role") }],
      ["select", { table: "tasks", columns: "id" }, { ...supabaseConfig, publishable_key: "sb_secret_test" }],
      ["update", { table: "tasks", patch_json: { done: true } }, supabaseConfig],
      ["delete", { table: "tasks" }, supabaseConfig],
    ] as const) {
      const denied = fakeFetch();
      const attempt = await createSupabaseHandler().callTool(name, args, ctx(secrets, denied.impl));
      expect(attempt.isError, name).toBe(true);
      expect(denied.calls, name).toHaveLength(0);
    }
  });

  it("pins Notion 2026-03-11 data sources and Jira enhanced JQL", async () => {
    const notion = fakeFetch(200, '{"results":[]}');
    await createRestHandler(NOTION_DESCRIPTOR).callTool(
      "query_data_source",
      { data_source_id: "ds-1", page_size: 10 },
      ctx({ api_key: "notion-token" }, notion.impl),
    );
    expect(new URL(notion.calls[0].url).pathname).toBe("/v1/data_sources/ds-1/query");
    expect(headers(notion.calls[0])["Notion-Version"]).toBe("2026-03-11");
    expect(JSON.parse(String(notion.calls[0].init?.body))).toEqual({ page_size: 10 });

    const jira = fakeFetch(200, '{"issues":[]}');
    await createRestHandler(JIRA_DESCRIPTOR).callTool(
      "search",
      { jql: "project = PROJ", maxResults: 10 },
      ctx({ host: "acme.atlassian.net", email: "a@b.co", api_token: "jira-token" }, jira.impl),
    );
    expect(new URL(jira.calls[0].url).pathname).toBe("/rest/api/3/search/jql");
    expect(JSON.parse(String(jira.calls[0].init?.body))).toMatchObject({ jql: "project = PROJ", maxResults: 10 });
    expect(JSON.parse(String(jira.calls[0].init?.body))).not.toHaveProperty("startAt");
  });

  it("publishes only read operations for original external descriptors", () => {
    for (const descriptor of CURATED_DESCRIPTORS) {
      const tools = restToolDefs(descriptor);
      expect(tools.every((tool) => tool.effect === "read"), descriptor.curatedId).toBe(true);
      expect(tools.some((tool) => /(?:^|_)(?:create|insert|update|delete|send|upload|put|patch)(?:_|$)/.test(tool.name)), descriptor.curatedId).toBe(false);
    }
  });
});
