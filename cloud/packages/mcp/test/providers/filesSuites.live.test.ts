import { mkdir, writeFile } from "node:fs/promises";
import { afterAll, describe, expect, it } from "vitest";

import { createProviderEgress } from "../../src/egress/providerEgress.js";
import { createSecretRedactor } from "../../src/egress/redactor.js";
import {
  DEFAULT_EGRESS_LIMITS,
  readBoundedBody,
  type ProviderEgress,
} from "../../src/egress/responseLimits.js";
import { requestOAuth } from "../../src/oauth/discovery.js";
import {
  FILES_SUITES_CANDIDATES,
  FILES_SUITES_CANDIDATE_IDS,
  FILES_SUITES_IDENTITY_PROFILES,
  FILES_SUITES_OAUTH_PROFILES,
  FILES_SUITES_ORIGINS,
  assertFilesSuitesLiveOAuthEvidence,
  createFilesSuitesHandler,
  createFilesSuitesLiveIdentityBinding,
  type FilesSuitesLiveIdentityBinding,
  exchangeFilesSuitesOAuthCode,
  filesSuitesAndroidRegistrationBlocker,
  filesSuitesOAuthConfig,
  refreshFilesSuitesOAuthToken,
  revokeFilesSuitesOAuthToken,
  type FilesSuitesProviderId,
} from "../../src/rest/descriptors/filesSuites.js";

const ENABLED = process.env.OVID_LIVE_PROVIDER_TESTS === "1";
const EVIDENCE_DIR = process.env.OVID_LIVE_PROVIDER_EVIDENCE_DIR ??
  "/tmp/opencode/ovid-production-completion/connectors-task-8-files-suites";

const ENV_IDS: Record<FilesSuitesProviderId, string> = {
  dropbox: "DROPBOX",
  box: "BOX",
  onedrive: "ONEDRIVE",
  sharepoint: "SHAREPOINT",
  "google-docs": "GOOGLE_DOCS",
  "google-sheets": "GOOGLE_SHEETS",
  "google-calendar": "GOOGLE_CALENDAR",
  "google-tasks": "GOOGLE_TASKS",
  gmail: "GMAIL",
  outlook: "OUTLOOK",
};

const LIVE_OPERATION: Record<FilesSuitesProviderId, string> = {
  dropbox: "list_folder",
  box: "list_root_items",
  onedrive: "list_root_children",
  sharepoint: "get_site",
  "google-docs": "get_document",
  "google-sheets": "get_spreadsheet",
  "google-calendar": "list_upcoming_events",
  "google-tasks": "list_task_lists",
  gmail: "list_messages",
  outlook: "list_messages",
};

interface LiveOutcome {
  providerId: string;
  operationId: string;
  status: "not provided" | "failed" | "passed";
  runAt: string;
  checks: Record<string, "passed" | "failed" | "not provided" | "unsupported">;
  missingConfiguration?: string[];
  blocker?: string;
  readEvidence?: string;
}

const outcomes: LiveOutcome[] = [];

function summarizeRead(id: FilesSuitesProviderId, text: string): string {
  const body = JSON.parse(text) as Record<string, unknown>;
  if (typeof body !== "object" || body === null || Array.isArray(body)) throw new Error("read shape");
  const arrayCount = (key: string, optional = false): number => {
    const value = body[key];
    if (value === undefined && optional) return 0;
    if (!Array.isArray(value)) throw new Error("read shape");
    return value.length;
  };
  switch (id) {
    case "dropbox":
    case "box":
      return `entries=${arrayCount("entries")}`;
    case "onedrive":
    case "outlook":
      return `value=${arrayCount("value")}`;
    case "sharepoint":
      if (typeof body.id !== "string" || body.id === "") throw new Error("read shape");
      return "site id present";
    case "google-docs":
      if (typeof body.documentId !== "string" || body.documentId === "") throw new Error("read shape");
      return "document id present";
    case "google-sheets":
      if (typeof body.spreadsheetId !== "string" || body.spreadsheetId === "") throw new Error("read shape");
      return "spreadsheet id present";
    case "google-calendar":
    case "google-tasks":
      return `items=${arrayCount("items", true)}`;
    case "gmail": {
      if (typeof body.resultSizeEstimate !== "number") throw new Error("read shape");
      return `messages=${arrayCount("messages", true)};estimate present`;
    }
  }
}

async function verifyLiveIdentity(
  id: FilesSuitesProviderId,
  input: {
    network: { providerEgress: ProviderEgress; originKey: string };
    clientId: string;
    clientSecret?: string;
    expectedUserId: string;
    accessToken: string;
    binding: FilesSuitesLiveIdentityBinding;
  },
): Promise<void> {
  input.binding.clear();
  const profile = FILES_SUITES_IDENTITY_PROFILES[id];
  const headers: Record<string, string> = { accept: "application/json" };
  const secretValues = [input.accessToken, ...(input.clientSecret === undefined ? [] : [input.clientSecret])];
  let body: string | undefined;
  if (profile.kind === "dropbox_account") {
    headers.Authorization = `Bearer ${input.accessToken}`;
    headers["content-type"] = "application/json";
    body = "null";
  } else if (profile.kind === "box_tokeninfo") {
    if ((input.clientSecret ?? "") === "") throw new Error("OAuth identity client configuration is incomplete.");
    headers["content-type"] = "application/x-www-form-urlencoded";
    body = new URLSearchParams({
      client_id: input.clientId,
      client_secret: input.clientSecret!,
      token: input.accessToken,
    }).toString();
  } else {
    headers.Authorization = `Bearer ${input.accessToken}`;
  }
  try {
    const response = await requestOAuth(input.network, new URL(profile.url), {
      method: profile.method,
      headers,
      ...(body === undefined ? {} : { body }),
      secretValues,
    });
    if (response.status !== 200) {
      await response.body.cancel().catch(() => {});
      throw new Error("identity status");
    }
    const bytes = await readBoundedBody(response, DEFAULT_EGRESS_LIMITS);
    const metadata: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    input.binding.bind({
      providerId: id,
      clientId: input.clientId,
      expectedUserId: input.expectedUserId,
      accessToken: input.accessToken,
      metadata,
    });
  } catch {
    throw new Error("OAuth identity verification failed.");
  }
}

async function refreshRejectedWithoutSecrets(
  id: FilesSuitesProviderId,
  input: Parameters<typeof refreshFilesSuitesOAuthToken>[1],
): Promise<boolean> {
  // Resolve/reject values can contain access and refresh tokens. Discard both
  // before constructing any assertion or diagnostic.
  const settled = await refreshFilesSuitesOAuthToken(id, input).then(
    () => "resolved" as const,
    () => "rejected" as const,
  );
  return settled === "rejected";
}

function requiredEnvironment(id: FilesSuitesProviderId): string[] {
  const env = ENV_IDS[id];
  const row = FILES_SUITES_CANDIDATES.find((entry) => entry.providerId === id)!;
  const profile = FILES_SUITES_OAUTH_PROFILES[row.authProfileId];
  const required = [
    `OVID_LIVE_PROVIDER_${env}`,
    `OVID_LIVE_PROVIDER_${env}_CLIENT_ID`,
    `OVID_LIVE_PROVIDER_${env}_AUTHORIZATION_CODE`,
    `OVID_LIVE_PROVIDER_${env}_AUTHORIZE_URL`,
    `OVID_LIVE_PROVIDER_${env}_CODE_VERIFIER`,
    `OVID_LIVE_PROVIDER_${env}_EXPECTED_STATE`,
    `OVID_LIVE_PROVIDER_${env}_CALLBACK_STATE`,
    `OVID_LIVE_PROVIDER_${env}_WEB_REDIRECT_URI`,
    `OVID_LIVE_PROVIDER_${env}_OAUTH_TEST_USER`,
  ];
  if (profile.androidRedirectUri !== null) required.push(`OVID_LIVE_PROVIDER_${env}_ANDROID_REDIRECT_URI`);
  if (profile.clientSecretRequired) required.push(`OVID_LIVE_PROVIDER_${env}_CLIENT_SECRET`);
  if (id === "sharepoint") required.push(`OVID_LIVE_PROVIDER_${env}_SITE_ID`);
  if (id === "google-docs") required.push(`OVID_LIVE_PROVIDER_${env}_DOCUMENT_ID`);
  if (id === "google-sheets") required.push(`OVID_LIVE_PROVIDER_${env}_SPREADSHEET_ID`);
  return required;
}

function operationArgs(id: FilesSuitesProviderId): Record<string, unknown> {
  const env = ENV_IDS[id];
  if (id === "sharepoint") return { site_id: process.env[`OVID_LIVE_PROVIDER_${env}_SITE_ID`] };
  if (id === "google-docs") return { document_id: process.env[`OVID_LIVE_PROVIDER_${env}_DOCUMENT_ID`] };
  if (id === "google-sheets") return { spreadsheet_id: process.env[`OVID_LIVE_PROVIDER_${env}_SPREADSHEET_ID`] };
  if (id === "google-calendar") {
    return { time_min: process.env[`OVID_LIVE_PROVIDER_${env}_TIME_MIN`] ?? new Date().toISOString() };
  }
  return {};
}

function record(outcome: LiveOutcome): void {
  const index = outcomes.findIndex((entry) => entry.providerId === outcome.providerId);
  if (index < 0) outcomes.push(outcome);
  else outcomes[index] = outcome;
}

afterAll(async () => {
  if (!ENABLED) return;
  await mkdir(EVIDENCE_DIR, { recursive: true, mode: 0o700 });
  await writeFile(
    `${EVIDENCE_DIR}/live-outcomes.json`,
    JSON.stringify({ generatedAt: new Date().toISOString(), outcomes }, null, 2) + "\n",
    { mode: 0o600 },
  );
});

describe.skipIf(!ENABLED)("files/suites real OAuth reads", () => {
  it.each(FILES_SUITES_CANDIDATE_IDS)("%s: consent, read, refresh, revoke where supported, and disconnect evidence", { timeout: 120_000 }, async (id) => {
    const operationId = LIVE_OPERATION[id];
    const runAt = new Date().toISOString();
    const env = ENV_IDS[id];
    const row = FILES_SUITES_CANDIDATES.find((entry) => entry.providerId === id)!;
    const profile = FILES_SUITES_OAUTH_PROFILES[row.authProfileId];
    const androidBlocker = filesSuitesAndroidRegistrationBlocker(profile);
    if (androidBlocker !== null) {
      record({
        providerId: id, operationId, status: "not provided", runAt,
        checks: {
          appRegistration: "not provided",
          webAndroidRedirectPkce: "not provided",
          oauthTestUserConsent: "not provided",
          realRead: "not provided",
          refresh: "not provided",
          revoke: "not provided",
          disconnectGeneration: "not provided",
        },
        missingConfiguration: [androidBlocker],
        blocker: "No approved registered Android redirect profile exists. Environment-only values cannot unblock this provider.",
      });
      throw new Error(`${id}: not provided: approved registered Android redirect profile`);
    }
    const missing = requiredEnvironment(id).filter((key) => {
      const value = process.env[key];
      return value === undefined || value.trim() === "" || (key === `OVID_LIVE_PROVIDER_${env}` && value !== "1");
    });
    if (missing.length > 0) {
      record({
        providerId: id, operationId, status: "not provided", runAt,
        checks: {
          appRegistration: "not provided",
          webAndroidRedirectPkce: "not provided",
          oauthTestUserConsent: "not provided",
          realRead: "not provided",
          refresh: "not provided",
          revoke: "not provided",
          disconnectGeneration: "not provided",
        },
        missingConfiguration: missing,
        blocker: "Provider opt-in/app registration/test-user evidence is incomplete; this is not a skipped pass.",
      });
      throw new Error(`${id}: not provided: ${missing.join(", ")}`);
    }

    const clientId = process.env[`OVID_LIVE_PROVIDER_${env}_CLIENT_ID`]!;
    const clientSecret = process.env[`OVID_LIVE_PROVIDER_${env}_CLIENT_SECRET`];
    const expectedUserId = process.env[`OVID_LIVE_PROVIDER_${env}_OAUTH_TEST_USER`]!;
    const redirectUri = process.env[`OVID_LIVE_PROVIDER_${env}_WEB_REDIRECT_URI`]!;
    const codeVerifier = process.env[`OVID_LIVE_PROVIDER_${env}_CODE_VERIFIER`]!;
    const checks: LiveOutcome["checks"] = {
      appRegistration: "not provided",
      webAndroidRedirectPkce: "failed",
      oauthTestUserConsent: "failed",
      realRead: "failed",
      refresh: "failed",
      revoke: profile.revokeUrl === null ? "unsupported" : "failed",
      disconnectGeneration: "not provided",
    };
    let egress: ProviderEgress | undefined;
    let accessToken = "";
    const identityBinding = createFilesSuitesLiveIdentityBinding();
    let operations = 0;
    let readEvidence: string | undefined;
    try {
      // Both redirect profiles and the exact PKCE verifier must be supplied by
      // the external consent run. No Firebase/Google sign-in token is accepted.
      const config = filesSuitesOAuthConfig(id, clientId);
      const expectedState = process.env[`OVID_LIVE_PROVIDER_${env}_EXPECTED_STATE`]!;
      expect(config.scopes).toEqual(expect.arrayContaining([...row.operations[0]!.requiredScopes]));
      assertFilesSuitesLiveOAuthEvidence({
        profile,
        config,
        authorizeUrl: process.env[`OVID_LIVE_PROVIDER_${env}_AUTHORIZE_URL`]!,
        codeVerifier,
        expectedState,
        callbackState: process.env[`OVID_LIVE_PROVIDER_${env}_CALLBACK_STATE`]!,
        webRedirectUri: redirectUri,
        androidRedirectUri: process.env[`OVID_LIVE_PROVIDER_${env}_ANDROID_REDIRECT_URI`]!,
      });
      checks.webAndroidRedirectPkce = "passed";

      const oauthOrigins = [new URL(profile.tokenUrl), ...(profile.revokeUrl === null ? [] : [new URL(profile.revokeUrl)])];
      const rawEgress = createProviderEgress({
        origins: { ...FILES_SUITES_ORIGINS, [`${id}-oauth`]: oauthOrigins },
        redactor: createSecretRedactor(),
        production: true,
      });
      egress = rawEgress;
      const countingEgress: ProviderEgress = {
        request(request) { operations++; return rawEgress.request(request); },
        close: () => rawEgress.close(),
      };
      const network = { providerEgress: countingEgress, originKey: `${id}-oauth` };
      const authorization = await exchangeFilesSuitesOAuthCode(id, {
        network, clientId, clientSecret,
        code: process.env[`OVID_LIVE_PROVIDER_${env}_AUTHORIZATION_CODE`]!,
        codeVerifier,
        redirectUri,
      });
      accessToken = authorization.accessToken;
      expect(authorization.refreshToken).toBeTruthy();
      await verifyLiveIdentity(id, {
        network: { providerEgress: countingEgress, originKey: id },
        clientId,
        clientSecret,
        expectedUserId,
        accessToken,
        binding: identityBinding,
      });
      checks.appRegistration = "passed";
      checks.oauthTestUserConsent = "passed";

      const live = createFilesSuitesHandler(id, {
        providerEgress: countingEgress,
        redactor: createSecretRedactor(),
        // A synthetic MCP uid never substitutes for the verified tenant identity.
        resolveAccessToken: async () => identityBinding.token(),
      });
      const ctx = {
        uid: `live-${env.toLowerCase()}`,
        secrets: {},
        workspace: {},
        fetchImpl: async () => { throw new Error("raw fetch is forbidden"); },
      };
      const first = await live.callTool(operationId, operationArgs(id), ctx);
      expect(first.isError).toBe(false);
      expect(first.text.includes(accessToken)).toBe(false);
      const firstEvidence = summarizeRead(id, first.text);
      checks.realRead = "passed";

      const refreshed = await refreshFilesSuitesOAuthToken(id, {
        network, clientId, clientSecret, refreshToken: authorization.refreshToken!,
      });
      accessToken = refreshed.accessToken;
      await verifyLiveIdentity(id, {
        network: { providerEgress: countingEgress, originKey: id },
        clientId,
        clientSecret,
        expectedUserId,
        accessToken,
        binding: identityBinding,
      });
      const second = await live.callTool(operationId, operationArgs(id), ctx);
      expect(second.isError).toBe(false);
      expect(second.text.includes(accessToken)).toBe(false);
      const refreshedEvidence = summarizeRead(id, second.text);
      readEvidence = `sanitized-result: initial ${firstEvidence}; after-refresh ${refreshedEvidence}`;
      checks.refresh = "passed";

      if (profile.revokeUrl !== null) {
        await revokeFilesSuitesOAuthToken(id, {
          network, clientId, clientSecret,
          accessToken, refreshToken: refreshed.refreshToken,
        });
        expect(await refreshRejectedWithoutSecrets(id, {
          network, clientId, clientSecret, refreshToken: refreshed.refreshToken!,
        })).toBe(true);
        const afterRevoke = await live.callTool(operationId, operationArgs(id), ctx);
        expect(afterRevoke.isError).toBe(true);
        expect(afterRevoke.text.includes(accessToken)).toBe(false);
        checks.revoke = "passed";
      }

      // Local token removal must prevent another network call. This is not a
      // substitute for the still-required cross-instance disconnectGeneration
      // proof, so a configured run remains blocked below rather than passing.
      accessToken = "";
      identityBinding.clear();
      const beforeDisconnect = operations;
      const disconnected = await live.callTool(operationId, operationArgs(id), ctx);
      expect(disconnected.isError).toBe(true);
      expect(operations).toBe(beforeDisconnect);

      record({
        providerId: id, operationId, status: "failed", runAt, checks,
        ...(readEvidence === undefined ? {} : { readEvidence }),
        blocker: "Actual read/refresh/revoke outcomes recorded, but cross-instance disconnect-generation runtime evidence is not provided; row remains blocked.",
      });
      throw new Error(`${id}: disconnect-generation evidence not provided; live read does not make this row supported`);
    } catch {
      if (!outcomes.some((entry) => entry.providerId === id)) {
        record({
          providerId: id, operationId, status: "failed", runAt, checks,
          ...(readEvidence === undefined ? {} : { readEvidence }),
          blocker: "A configured OAuth/read/lifecycle check failed; raw provider output and credential values are intentionally omitted.",
        });
      }
      throw new Error(`${id}: configured live OAuth/read/lifecycle verification failed; see sanitized live-outcomes.json`);
    } finally {
      identityBinding.clear();
      await egress?.close();
    }
  });
});
