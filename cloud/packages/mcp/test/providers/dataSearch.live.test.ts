import { describe, expect, it } from "vitest";
import {
  DATA_SEARCH_DESCRIPTORS,
  createDataSearchHandler,
} from "../../src/rest/descriptors/dataSearch.js";
import { createProviderEgress } from "../../src/egress/providerEgress.js";
import { createSecretRedactor } from "../../src/egress/redactor.js";
import type { McpCallContext } from "../../src/transports/native.js";
import type { RestServiceDescriptor } from "../../src/rest/engine.js";

interface LiveCase {
  id: string;
  operation: string;
  args: Record<string, unknown>;
  env: Record<string, string>;
  secretKeys: readonly string[];
}

const CASES: readonly LiveCase[] = [
  {
    id: "typeform",
    operation: "list_forms",
    args: { page: 1, page_size: 1 },
    env: { access_token: "OVID_LIVE_TYPEFORM_ACCESS_TOKEN" },
    secretKeys: ["access_token"],
  },
  {
    id: "calendly",
    operation: "get_current_user",
    args: {},
    env: { access_token: "OVID_LIVE_CALENDLY_ACCESS_TOKEN" },
    secretKeys: ["access_token"],
  },
  {
    id: "miro",
    operation: "list_boards",
    args: { limit: 1, offset: 0 },
    env: { access_token: "OVID_LIVE_MIRO_ACCESS_TOKEN" },
    secretKeys: ["access_token"],
  },
  {
    id: "canva",
    operation: "list_designs",
    args: { limit: 1 },
    env: { access_token: "OVID_LIVE_CANVA_ACCESS_TOKEN" },
    secretKeys: ["access_token"],
  },
  {
    id: "webflow",
    operation: "list_sites",
    args: {},
    env: { access_token: "OVID_LIVE_WEBFLOW_ACCESS_TOKEN" },
    secretKeys: ["access_token"],
  },
  {
    id: "pinecone",
    operation: "list_indexes",
    args: {},
    env: { api_key: "OVID_LIVE_PINECONE_API_KEY" },
    secretKeys: ["api_key"],
  },
  {
    id: "bigquery",
    operation: "list_datasets",
    args: { maxResults: 1 },
    env: {
      access_token: "OVID_LIVE_BIGQUERY_ACCESS_TOKEN",
      project_id: "OVID_LIVE_BIGQUERY_PROJECT_ID",
    },
    secretKeys: ["access_token"],
  },
  {
    id: "brave-search",
    operation: "web_search",
    args: { query: "Ovid Si", count: 1, offset: 0 },
    env: { api_key: "OVID_LIVE_BRAVE_SEARCH_API_KEY" },
    secretKeys: ["api_key"],
  },
  {
    id: "tavily",
    operation: "search",
    args: { query: "Ovid Si", max_results: 1 },
    env: { api_key: "OVID_LIVE_TAVILY_API_KEY" },
    secretKeys: ["api_key"],
  },
  {
    id: "google-maps",
    operation: "search_places",
    args: { query: "Eiffel Tower", pageSize: 1 },
    env: { api_key: "OVID_LIVE_GOOGLE_MAPS_API_KEY" },
    secretKeys: ["api_key"],
  },
  {
    id: "mixpanel",
    operation: "get_saved_insight",
    args: {},
    env: {
      username: "OVID_LIVE_MIXPANEL_USERNAME",
      secret: "OVID_LIVE_MIXPANEL_SECRET",
      project_id: "OVID_LIVE_MIXPANEL_PROJECT_ID",
      bookmark_id: "OVID_LIVE_MIXPANEL_BOOKMARK_ID",
    },
    secretKeys: ["username", "secret"],
  },
  {
    id: "amplitude",
    operation: "list_charts",
    args: { limit: 1 },
    env: {
      access_token: "OVID_LIVE_AMPLITUDE_ACCESS_TOKEN",
      project_id: "OVID_LIVE_AMPLITUDE_PROJECT_ID",
    },
    secretKeys: ["access_token"],
  },
  {
    id: "posthog",
    operation: "list_insights",
    args: { limit: 1, offset: 0 },
    env: {
      personal_api_key: "OVID_LIVE_POSTHOG_PERSONAL_API_KEY",
      project_id: "OVID_LIVE_POSTHOG_PROJECT_ID",
    },
    secretKeys: ["personal_api_key"],
  },
  {
    id: "segment",
    operation: "list_sources",
    args: { limit: 1 },
    env: { access_token: "OVID_LIVE_SEGMENT_ACCESS_TOKEN" },
    secretKeys: ["access_token"],
  },
  {
    id: "stripe",
    operation: "list_products",
    args: { limit: 1 },
    env: { restricted_key: "OVID_LIVE_STRIPE_RESTRICTED_KEY" },
    secretKeys: ["restricted_key"],
  },
];

function optInName(id: string): string {
  return `OVID_LIVE_PROVIDER_${id.toUpperCase().replace(/[^A-Z0-9]/g, "_")}`;
}

function descriptor(id: string): RestServiceDescriptor {
  const found = DATA_SEARCH_DESCRIPTORS.find((candidate) => candidate.curatedId === id);
  if (found === undefined) throw new Error(`Unsupported live provider: ${id}`);
  return found;
}

function credentials(fixture: LiveCase): Record<string, string> {
  const missing: string[] = [];
  const values: Record<string, string> = {};
  for (const [key, envName] of Object.entries(fixture.env)) {
    const value = process.env[envName]?.trim() ?? "";
    if (value === "") missing.push(envName);
    else values[key] = value;
  }
  if (missing.length > 0) {
    throw new Error(`credentials not provided for ${fixture.id}: ${missing.join(", ")}`);
  }
  return values;
}

// Ordinary CI does not claim live evidence. Setting the global gate deliberately
// enables every supported row; absent per-row opt-ins or credentials then FAIL.
describe.runIf(process.env.OVID_LIVE_PROVIDER_TESTS === "1")("data/search explicit live reads", () => {
  it.each(CASES)("$id performs one real read through pinned egress", { timeout: 60_000 }, async (fixture) => {
    const optIn = optInName(fixture.id);
    expect(process.env[optIn], `${fixture.id} is not explicitly opted in: set ${optIn}=1`).toBe("1");
    const secrets = credentials(fixture);
    const definition = descriptor(fixture.id);
    const egress = createProviderEgress({
      origins: { [fixture.id]: [new URL(definition.baseUrl)] },
      redactor: createSecretRedactor(),
      production: true,
    });
    try {
      const result = await createDataSearchHandler(definition, { providerEgress: egress }).callTool(
        fixture.operation,
        fixture.args,
        {
          uid: "live-fixture-user",
          secrets,
          workspace: {},
          fetchImpl: async () => { throw new Error("raw fetch is forbidden in live provider reads"); },
          sessionId: "live-session",
          runId: `live-${fixture.id}`,
          userId: "live-fixture-user",
          connectionId: `live-${fixture.id}`,
          providerId: fixture.id,
          mode: "auto",
          planMode: false,
          unattended: false,
          isSubagent: false,
          depth: 0,
          callKey: `live-${fixture.id}`,
          signal: new AbortController().signal,
        } as McpCallContext,
      );
      expect(result.isError, result.text).toBe(false);
      for (const key of fixture.secretKeys) {
        expect(result.text).not.toContain(secrets[key]);
      }
      const sanitizedResult = JSON.parse(result.text) as unknown;
      expect(typeof sanitizedResult).toBe("object");
      expect(sanitizedResult).not.toBeNull();
      console.info(JSON.stringify({
        providerId: fixture.id,
        operationId: fixture.operation,
        outcome: "passed",
        sanitizedResult,
      }));
    } finally {
      await egress.close();
    }
  });
});
