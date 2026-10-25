import { describe, expect, it } from "vitest";

import { restToolDefs } from "../engine.js";
import { buildAuthorizeUrl } from "../../oauth/flow.js";
import type { EgressResponse, ProviderEgress } from "../../egress/responseLimits.js";
import { validateProviderArgs, validateProviderDefinition } from "../../providers/types.js";
import { createProviderRegistry } from "../../providers/registry.js";
import {
  FILES_SUITES_CANDIDATES,
  FILES_SUITES_CANDIDATE_IDS,
  FILES_SUITES_DESCRIPTORS,
  FILES_SUITES_IDENTITY_PROFILES,
  FILES_SUITES_OAUTH_PROFILES,
  FILES_SUITES_ORIGINS,
  FILES_SUITES_PROVIDERS,
  FILES_SUITES_CONTRACT_DEFINITIONS,
  FILES_SUITES_READINESS_ROWS,
  assertFilesSuitesLiveIdentity,
  createFilesSuitesLiveIdentityBinding,
  exchangeFilesSuitesOAuthCode,
  filesSuitesAndroidRegistrationBlocker,
  filesSuitesOAuthConfig,
  refreshFilesSuitesOAuthToken,
  revokeFilesSuitesOAuthToken,
  type FilesSuitesProviderId,
} from "./filesSuites.js";

function candidate(id: FilesSuitesProviderId) {
  const row = FILES_SUITES_CANDIDATES.find((entry) => entry.providerId === id);
  expect(row).toBeDefined();
  return row!;
}

function descriptor(id: FilesSuitesProviderId) {
  const row = FILES_SUITES_DESCRIPTORS.find((entry) => entry.curatedId === id);
  expect(row).toBeDefined();
  return row!;
}

const FIRST_READS = {
  dropbox: { name: "list_folder", method: "POST", path: "/2/files/list_folder", scope: "files.metadata.read" },
  box: { name: "list_root_items", method: "GET", path: "/2.0/folders/0/items", scope: "root_readonly" },
  onedrive: { name: "list_root_children", method: "GET", path: "/v1.0/me/drive/root/children", scope: "Files.Read" },
  sharepoint: { name: "get_site", method: "GET", path: "/v1.0/sites/{site_id}", scope: "Sites.Read.All" },
  "google-docs": { name: "get_document", method: "GET", path: "/v1/documents/{document_id}", scope: "https://www.googleapis.com/auth/drive.file" },
  "google-sheets": { name: "get_spreadsheet", method: "GET", path: "/v4/spreadsheets/{spreadsheet_id}", scope: "https://www.googleapis.com/auth/drive.file" },
  "google-calendar": { name: "list_upcoming_events", method: "GET", path: "/calendar/v3/calendars/primary/events", scope: "https://www.googleapis.com/auth/calendar.events.readonly" },
  "google-tasks": { name: "list_task_lists", method: "GET", path: "/tasks/v1/users/@me/lists", scope: "https://www.googleapis.com/auth/tasks.readonly" },
  gmail: { name: "list_messages", method: "GET", path: "/gmail/v1/users/me/messages", scope: "https://www.googleapis.com/auth/gmail.metadata" },
  outlook: { name: "list_messages", method: "GET", path: "/v1.0/me/messages", scope: "Mail.ReadBasic" },
} as const;

describe("files/suites candidate definitions", () => {
  it("keeps the exact candidate inventory while unsupported rows stay out of production", () => {
    expect(FILES_SUITES_CANDIDATE_IDS).toEqual([
      "dropbox",
      "box",
      "onedrive",
      "sharepoint",
      "google-docs",
      "google-sheets",
      "google-calendar",
      "google-tasks",
      "gmail",
      "outlook",
    ]);
    expect(FILES_SUITES_CANDIDATES.map((row) => row.providerId)).toEqual(FILES_SUITES_CANDIDATE_IDS);
    expect(FILES_SUITES_PROVIDERS).toEqual([]);
    for (const row of FILES_SUITES_CANDIDATES) {
      expect(row.releaseState).toBe("blocked");
      expect(row.blockers).toContain("live OAuth read/refresh/revoke/disconnect-generation evidence not provided");
      expect(row.connectionSchema).toEqual({
        type: "object",
        properties: {},
        required: [],
        additionalProperties: false,
        maxProperties: 0,
      });
    }
  });

  it.each(FILES_SUITES_CANDIDATE_IDS)("%s has a valid typed official read, fixed origins and closed schemas", (id) => {
    const row = candidate(id);
    const expected = FIRST_READS[id];
    expect(row.operations[0]).toMatchObject({
      name: expected.name,
      effect: "read",
      approval: "mode",
      requiredScopes: [expected.scope],
      request: { method: expected.method, pathTemplate: expected.path },
    });
    expect(row.officialDocs.length).toBeGreaterThan(0);
    expect(row.officialDocs.every((doc) => doc.verifiedAt === "2026-10-24" && doc.url.startsWith("https://"))).toBe(true);
    expect(FILES_SUITES_ORIGINS[id].length).toBeGreaterThan(0);
    expect(FILES_SUITES_ORIGINS[id].every((origin) => origin.protocol === "https:" && origin.username === "" && origin.password === "")).toBe(true);
    expect(row.operations.every((operation) => FILES_SUITES_ORIGINS[id].some(
      (origin) => origin.origin === new URL(operation.request.pathTemplate, origin).origin,
    ))).toBe(true);

    // Validation only: the candidate itself remains blocked, never a production definition.
    validateProviderDefinition({ ...row, readiness: "supported" });
    for (const operation of row.operations) {
      expect(operation.effect).toBe("read");
      expect(operation.approval).toBe("mode");
      expect(operation.limits.responseBytes).toBeLessThanOrEqual(65_536);
      expect(operation.limits.pageBytes).toBeLessThanOrEqual(65_536);
      expect(operation.outputPolicy.maxBytes).toBeLessThanOrEqual(8_192);
      expect(operation.request.pathTemplate).not.toContain("alt=media");
      expect(operation.request.pathTemplate).not.toContain("{base");
      expect(operation.request.pathTemplate).not.toContain("{url");
      for (const hostile of ["baseUrl", "base_url", "url", "headers", "proxy", "body", "query"]) {
        expect(validateProviderArgs(operation.inputSchema, { [hostile]: "https://evil.example" }).ok).toBe(false);
      }
    }

    const published = restToolDefs(descriptor(id));
    expect(published.map((operation) => operation.name)).toEqual(row.operations.map((operation) => operation.name));
    expect(published.every((operation) => operation.effect === "read")).toBe(true);
  });

  it("does not advertise mail, calendar, file or suite writes", () => {
    const forbidden = /(?:^|_)(?:send|create|insert|update|patch|delete|upload|append|clear|share|publish)(?:_|$)/;
    for (const row of FILES_SUITES_CANDIDATES) {
      for (const operation of row.operations) {
        expect(operation.name, `${row.providerId}/${operation.name}`).not.toMatch(forbidden);
        expect(operation.request.pathTemplate).not.toMatch(/sendMail|messages\/send|batchUpdate|values:append/);
        expect(["POST", "PUT", "PATCH", "DELETE"].includes(operation.request.method) && row.providerId !== "dropbox").toBe(false);
      }
    }
  });

  it("distinguishes bounded file download from Google-native export without alt=media", () => {
    const dropbox = candidate("dropbox");
    const download = dropbox.operations.find((operation) => operation.name === "download_text");
    expect(download).toMatchObject({
      effect: "read",
      requiredScopes: ["files.content.read"],
      request: { method: "POST", pathTemplate: "/2/files/download" },
      outputPolicy: { kind: "redacted_text", maxBytes: 8_192 },
    });
    expect(download?.description).toContain("metadata size/extension preflight");

    const docs = candidate("google-docs");
    const nativeExport = docs.operations.find((operation) => operation.name === "export_text");
    expect(nativeExport).toMatchObject({
      effect: "read",
      requiredScopes: ["https://www.googleapis.com/auth/drive.file"],
      request: { method: "GET", pathTemplate: "/drive/v3/files/{document_id}/export?mimeType=text/plain" },
      outputPolicy: { kind: "redacted_text", maxBytes: 8_192 },
    });
    expect(docs.operations.some((operation) => operation.request.pathTemplate.includes("alt=media"))).toBe(false);
    for (const id of ["box", "onedrive", "sharepoint"] as const) {
      expect(candidate(id).operations.some((operation) => /download|content/.test(operation.name))).toBe(false);
    }
  });

  it("keeps Gmail snippets/body content out of the metadata projection", () => {
    const get = descriptor("gmail").tools.find((operation) => operation.name === "get_message_metadata")!;
    expect(get.path).toContain("format=metadata");
    expect(get.path).toContain("metadataHeaders=From&metadataHeaders=Subject");
    expect(get.path).not.toContain("snippet");
    expect(get.path).not.toContain("format=raw");
    expect(get.path).not.toContain("format=full");
  });

  it("uses bounded metadata fields and one-page caps", () => {
    expect(descriptor("dropbox").tools[0]?.bodyTemplate).toMatchObject({ limit: "const:20" });
    expect(descriptor("box").tools[0]?.fixedQuery).toMatchObject({ limit: "20", fields: "id,type,name,size,modified_at" });
    expect(descriptor("onedrive").tools[0]?.fixedQuery).toMatchObject({ $top: "20", $select: "id,name,size,file,folder" });
    expect(descriptor("google-calendar").tools[0]?.fixedQuery).toMatchObject({ maxResults: "20", singleEvents: "true", orderBy: "startTime" });
    expect(descriptor("google-tasks").tools[0]?.fixedQuery).toMatchObject({ maxResults: "20" });
    expect(descriptor("gmail").tools[0]?.fixedQuery).toMatchObject({ maxResults: "20" });
    expect(descriptor("gmail").tools[0]?.fixedQuery).not.toHaveProperty("q");
    expect(descriptor("outlook").tools[0]?.fixedQuery).toMatchObject({ $top: "20", $select: "id,subject,from,receivedDateTime,isRead" });
  });
});

// UNEXECUTED under HEAVY-COMMANDS-PAUSED.md (2026-10-25).
describe("files/suites live identity binding and evidence metadata", () => {
  const expectedUserId = "tenant-user-fixture";
  const metadataFor = (id: FilesSuitesProviderId): unknown => {
    if (id === "dropbox") return { account_id: expectedUserId };
    if (id === "box") return { active: true, client_id: "client-fixture", user: { id: expectedUserId } };
    if (id.startsWith("google-") || id === "gmail") return { sub: expectedUserId };
    return { id: expectedUserId };
  };

  it.each(FILES_SUITES_CANDIDATE_IDS)("%s binds only its official metadata identity and expected tenant user", (id) => {
    const profile = FILES_SUITES_IDENTITY_PROFILES[id];
    expect(FILES_SUITES_ORIGINS[id].map((origin) => origin.origin)).toContain(new URL(profile.url).origin);
    const config = filesSuitesOAuthConfig(id, "client-fixture");
    if (profile.requiredScope !== null) expect(config.scopes).toContain(profile.requiredScope);
    expect(() => assertFilesSuitesLiveIdentity({
      providerId: id,
      clientId: "client-fixture",
      expectedUserId,
      metadata: metadataFor(id),
    })).not.toThrow();
    expect(() => assertFilesSuitesLiveIdentity({
      providerId: id,
      clientId: "client-fixture",
      expectedUserId: "different-tenant-user",
      metadata: metadataFor(id),
    })).toThrow("OAuth token identity does not match the intended test user.");
  });

  it("does not let a synthetic UID or failed revalidation release a token", () => {
    const binding = createFilesSuitesLiveIdentityBinding();
    expect(binding.token()).toBe("");
    expect(() => binding.bind({
      providerId: "dropbox",
      clientId: "client-fixture",
      expectedUserId,
      accessToken: "oauth-token-fixture",
      metadata: { account_id: "someone-else" },
    })).toThrow("OAuth token identity does not match the intended test user.");
    expect(binding.token()).toBe("");
    expect(binding.bind({
      providerId: "dropbox",
      clientId: "client-fixture",
      expectedUserId,
      accessToken: "oauth-token-fixture",
      metadata: { account_id: expectedUserId },
    })).toBe("oauth-token-fixture");
    expect(binding.token()).toBe("oauth-token-fixture");
    expect(() => binding.bind({
      providerId: "dropbox",
      clientId: "client-fixture",
      expectedUserId,
      accessToken: "replacement-token-fixture",
      metadata: { account_id: "someone-else" },
    })).toThrow("OAuth token identity does not match the intended test user.");
    expect(binding.token()).toBe("");
    binding.clear();
    expect(binding.token()).toBe("");
  });

  it("rejects inactive or wrong-client Box token metadata", () => {
    for (const metadata of [
      { active: false, client_id: "client-fixture", user: { id: expectedUserId } },
      { active: true, client_id: "other-client", user: { id: expectedUserId } },
    ]) {
      expect(() => assertFilesSuitesLiveIdentity({
        providerId: "box",
        clientId: "client-fixture",
        expectedUserId,
        metadata,
      })).toThrow("OAuth token identity does not match the intended test user.");
    }
  });

  it.each(FILES_SUITES_CANDIDATE_IDS)("%s keeps Android and current automated evidence honestly blocked", (id) => {
    const row = FILES_SUITES_READINESS_ROWS.find((entry) => entry.providerId === id)!;
    expect(row.auth.refreshBehavior).not.toMatch(/^Single-flight/);
    expect(row.automatedEvidence).toMatchObject({ result: "not_run", runAt: null });
    expect(row.automatedEvidence.test).toContain("UNEXECUTED after 2026-10-25 review fixes");
    expect(row.automatedEvidence.test).toContain("historical 103/103 at 2026-10-24T17:53:00.000Z");
    const profile = FILES_SUITES_OAUTH_PROFILES[candidate(id).authProfileId];
    expect(filesSuitesAndroidRegistrationBlocker(profile)).toBe(`${profile.profileId}.androidRedirectUri`);
    expect(filesSuitesAndroidRegistrationBlocker({
      ...profile,
      androidRedirectUri: "ovidsi://oauth/callback",
    })).toBeNull();
    expect(candidate(id).blockers).toContain("approved Android redirect registration not provided; environment-only configuration cannot unblock");
  });
});

describe("files/suites Task 6 readiness rows", () => {
  it.each(FILES_SUITES_CANDIDATE_IDS)("%s registers as blocked and yields no production definition", (id) => {
    const registry = createProviderRegistry({ now: () => new Date("2026-10-24T16:00:00.000Z") });
    const definition = FILES_SUITES_CONTRACT_DEFINITIONS.find((entry) => entry.providerId === id)!;
    const row = FILES_SUITES_READINESS_ROWS.find((entry) => entry.providerId === id)!;
    expect(definition).toBeDefined();
    expect(row).toBeDefined();
    expect(row.releaseState).toBe("blocked");
    expect(row.credentials).toBe("not provided");
    expect(row.liveReadEvidence).toBeNull();
    expect(row.liveWriteEvidence).toEqual([]);
    expect(row.automatedEvidence.result).toBe("not_run");
    expect(row.auth.profileId).toBe(definition.authProfileId);
    expect(row.auth.minimumScopes).toEqual(expect.arrayContaining([...definition.operations[0]!.requiredScopes]));
    expect(row.auth.tenantOrigins).toEqual([...FILES_SUITES_ORIGINS[id].map((origin): string => origin.origin)]);
    expect(() => registry.registerProvider(definition, row)).not.toThrow();
    expect(registry.rows()).toEqual([{ ...row }]);
    expect(registry.catalogDefinitions()).toEqual([]);
    expect(() => registry.assertCatalogCallable(id)).toThrow("not supported");
  });
});

describe("files/suites OAuth profiles", () => {
  it("uses provider-owned scopes, PKCE and offline authorization without sign-in token reuse", () => {
    for (const id of FILES_SUITES_CANDIDATE_IDS) {
      const row = candidate(id);
      const profile = FILES_SUITES_OAUTH_PROFILES[row.authProfileId];
      expect(profile).toBeDefined();
      expect(profile.tokenSource).toBe("provider_authorization_code");
      expect(profile.webRedirectUri).toBe("https://ovidsi.com/oauth/callback");
      expect(profile.androidRedirectUri).toBeNull();
      expect(profile.stateRequired).toBe(true);
      expect(profile.refreshSkewMs).toBe(30_000);
      expect(profile.disconnectGenerationRequired).toBe(true);
      const config = filesSuitesOAuthConfig(id, "fixture-client-id");
      expect(config.scopes).toEqual(expect.arrayContaining([FIRST_READS[id].scope]));
      expect(config.authorizationUrl).toBe(profile.authorizationUrl);
      expect(config.tokenUrl).toBe(profile.tokenUrl);
      expect(config.clientId).toBe("fixture-client-id");
      expect(config.pkce).toBe(profile.pkce);
      expect(config).not.toHaveProperty("firebaseIdToken");
      expect(config).not.toHaveProperty("googleSignInToken");
      if (id === "box") {
        expect(profile.pkce).toBe("unsupported");
        expect(row.blockers).toContain("Box PKCE support is not documented on the official authorize endpoint; Web/Android PKCE evidence is unavailable");
        continue;
      }
      expect(profile.pkce).toBe("S256");
      const authorize = new URL(buildAuthorizeUrl(config, {
        state: "fixture-state",
        codeChallenge: "fixture-challenge",
        redirectUri: "https://ovidsi.com/oauth/callback",
      }));
      expect(authorize.searchParams.get("code_challenge_method")).toBe("S256");
      expect(authorize.searchParams.get("redirect_uri")).toBe("https://ovidsi.com/oauth/callback");
      if (profile.offlineParameter !== undefined) {
        const [key, value] = profile.offlineParameter;
        expect(authorize.searchParams.get(key)).toBe(value);
      }
    }
  });

  it("refuses OAuth token exchange without the pinned provider egress", async () => {
    let legacyCalls = 0;
    await expect(exchangeFilesSuitesOAuthCode("google-docs", {
      network: {
        fetchImpl: async () => {
          legacyCalls++;
          return new Response(JSON.stringify({
            access_token: "access-fixture",
            refresh_token: "refresh-fixture",
            token_type: "Bearer",
            scope: "https://www.googleapis.com/auth/drive.file",
          }), { status: 200 });
        },
      },
      clientId: "client-fixture",
      clientSecret: "client-secret-fixture",
      code: "authorization-code-fixture",
      codeVerifier: "pkce-verifier-fixture-12345678901234567890123456789012",
      redirectUri: "https://ovidsi.com/oauth/callback",
    })).rejects.toThrow("ProviderEgress is required for OAuth provider requests.");
    expect(legacyCalls).toBe(0);
  });

  it("refuses OAuth revocation without the pinned provider egress", async () => {
    let legacyCalls = 0;
    await expect(revokeFilesSuitesOAuthToken("dropbox", {
      network: {
        fetchImpl: async () => {
          legacyCalls++;
          return new Response(null, { status: 200 });
        },
      },
      clientId: "client-fixture",
      accessToken: "access-fixture",
      refreshToken: "refresh-fixture",
    })).rejects.toThrow("ProviderEgress is required for OAuth provider requests.");
    expect(legacyCalls).toBe(0);
  });

  it("requires Box's documented one-use refresh-token rotation", async () => {
    const requests: unknown[] = [];
    const providerEgress: ProviderEgress = {
      async request(request) {
        requests.push(request);
        const wire = new Response(JSON.stringify({
          access_token: "access-fixture",
          token_type: "Bearer",
          expires_in: 3600,
        }), { status: 200, headers: { "content-type": "application/json" } });
        return {
          status: wire.status,
          headers: wire.headers,
          body: wire.body!,
          origin: request.url,
          remoteAddress: "192.0.2.20",
        } satisfies EgressResponse;
      },
      async close() {},
    };
    await expect(refreshFilesSuitesOAuthToken("box", {
      network: { providerEgress, originKey: "box-oauth" },
      clientId: "client-fixture",
      clientSecret: "client-secret-fixture",
      refreshToken: "spent-refresh-fixture",
    })).rejects.toThrow("OAuth refresh-token rotation was not returned.");
  });

  it("rejects grants broader than the requested provider operations", async () => {
    const providerEgress: ProviderEgress = {
      async request(request) {
        const config = filesSuitesOAuthConfig("google-docs", "client-fixture");
        const wire = new Response(JSON.stringify({
          access_token: "access-fixture",
          refresh_token: "refresh-fixture",
          token_type: "Bearer",
          expires_in: 3600,
          scope: [...config.scopes, "https://www.googleapis.com/auth/drive"].join(" "),
        }), { status: 200, headers: { "content-type": "application/json" } });
        return {
          status: wire.status,
          headers: wire.headers,
          body: wire.body!,
          origin: request.url,
          remoteAddress: "192.0.2.20",
        } satisfies EgressResponse;
      },
      async close() {},
    };
    await expect(exchangeFilesSuitesOAuthCode("google-docs", {
      network: { providerEgress, originKey: "google-docs-oauth" },
      clientId: "client-fixture",
      clientSecret: "client-secret-fixture",
      code: "authorization-code-fixture",
      codeVerifier: "pkce-verifier-fixture-12345678901234567890123456789012",
      redirectUri: "https://ovidsi.com/oauth/callback",
    })).rejects.toThrow("OAuth granted scopes exceed the provider operations.");
  });

  it("pins Dropbox/Box/Google revocation and honestly marks Microsoft remote revocation unsupported", () => {
    expect(FILES_SUITES_OAUTH_PROFILES["dropbox-user-oauth"].revokeUrl).toBe("https://api.dropboxapi.com/2/auth/token/revoke");
    expect(FILES_SUITES_OAUTH_PROFILES["box-user-oauth"].revokeUrl).toBe("https://api.box.com/oauth2/revoke");
    expect(FILES_SUITES_OAUTH_PROFILES["google-workspace-oauth"].revokeUrl).toBe("https://oauth2.googleapis.com/revoke");
    expect(FILES_SUITES_OAUTH_PROFILES["microsoft-graph-common-oauth"].revokeUrl).toBeNull();
    expect(FILES_SUITES_OAUTH_PROFILES["microsoft-graph-organizations-oauth"].revokeUrl).toBeNull();
    expect(candidate("outlook").blockers).toContain("Microsoft delegated remote token revocation is not supported by this profile; local disconnect still requires generation proof");
  });
});
