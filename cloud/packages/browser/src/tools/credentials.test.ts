import { describe, expect, it } from "vitest";

import type { BrowserSessionRegistry, SessionBrowser } from "../sessions.js";
import * as credentialModule from "./credentials.js";
import { BROWSER_TOOL_NAMES, createBrowserTools } from "./definitions.js";
import type {
  BrowserCredentialSecret,
  BrowserCredentialSummary,
  BrowserCredentialsPort,
  BrowserToolContext,
  BrowserToolDef,
  BrowserToolsDeps,
} from "./types.js";

/** No chromium: the vault and page seams record every prohibited side effect. */
const SECRET = "correct-horse-battery-staple";
const CTX: BrowserToolContext = { sessionId: "user-u1", userId: "u1", workspaceSessionId: "chat-1" };
const AUTOFILL_REFUSAL = "error: credential_autofill_disabled";

interface Harness {
  deps: BrowserToolsDeps;
  tools: Map<string, BrowserToolDef>;
  resolutions: Array<{ userId: string; id: string }>;
  fills: Array<{ selector: string; value: string }>;
  clicks: string[];
  keys: string[];
  logs: unknown[][];
}

function harness(opts: {
  credential?: BrowserCredentialSecret | null;
  list?: BrowserCredentialSummary[];
  vault?: boolean;
} = {}): Harness {
  const fills: Array<{ selector: string; value: string }> = [];
  const clicks: string[] = [];
  const keys: string[] = [];
  const logs: unknown[][] = [];
  const resolutions: Array<{ userId: string; id: string }> = [];

  const page = {
    url: () => "https://example.test/login",
    viewportSize: () => ({ width: 1280, height: 800 }),
    async fill(selector: string, value: string) {
      fills.push({ selector, value });
    },
    async click(selector: string) {
      clicks.push(selector);
    },
    keyboard: {
      async press(key: string) {
        keys.push(key);
      },
    },
  };
  const session = {
    sessionId: "user-u1",
    userId: "u1",
    handle: { page, context: { on() {} }, touch() {} },
    tabs: [page],
    activeIndex: 0,
    takeover: false,
    takeoverViewerId: null,
    lastActivityAt: 0,
    console: [],
    network: [],
    dialogs: [],
    popups: [],
  } as unknown as SessionBrowser;

  const registry = {
    get: () => session,
    touch: () => {},
    refuseReasonIfTakeover: () => null,
  } as unknown as BrowserSessionRegistry;

  const secret = opts.credential === undefined
    ? {
        id: "cred-1",
        label: "Example",
        site: "example.test",
        username: "me@example.test",
        secretKind: "password" as const,
        hasNotes: false,
        secret: SECRET,
        notes: null,
      }
    : opts.credential;
  const summaries: BrowserCredentialSummary[] = opts.list ?? [
    {
      id: "cred-1",
      label: "Example",
      site: "example.test",
      username: "me@example.test",
      secretKind: "password",
      hasNotes: false,
    },
  ];
  const credentials: BrowserCredentialsPort = {
    list: async () => summaries,
    resolve: async (userId, id) => {
      resolutions.push({ userId, id });
      return secret;
    },
  };

  const cfg = {
    maxLiveBrowsers: 1,
    tier1FallbackContexts: 0,
    idleEvictMs: 180_000,
    maxTier1Processes: 1,
    tier1TimeoutMs: 1000,
    maxActiveScreencasts: 1,
    screencastLoadMax: 6,
    screencastDetachGraceMs: 0,
    screencast: { width: 1280, height: 800, quality: 60, everyNthFrame: 2, maxFramesInFlight: 1 },
    stateDir: null,
    lightpandaBin: null,
    allowHosts: [],
    ownPublicIp: null,
    blockHeavyResources: false,
    chromiumArgs: [],
  };

  const deps: BrowserToolsDeps = {
    pool: {} as never,
    registry,
    persistence: null,
    cfg,
    workspaceDir: async () => "/tmp/does-not-matter",
    log: (...args: unknown[]) => logs.push(args),
    ...(opts.vault === false ? {} : { credentials }),
  };
  const tools = new Map(createBrowserTools(deps).map((t) => [t.name, t]));
  return { deps, tools, resolutions, fills, clicks, keys, logs };
}

function exec(h: Harness, name: string, input: unknown) {
  const tool = h.tools.get(name);
  if (tool === undefined) throw new Error(`missing tool ${name}`);
  return tool.execute(input, CTX);
}

function execLegacy(h: Harness, input: unknown) {
  return credentialModule.legacyCredentialAutofillTool(h.deps).execute(input, CTX);
}

describe("credentials vault tools", () => {
  it("lists metadata and never the secret", async () => {
    const h = harness();
    const result = await exec(h, "browser_list_credentials", {});
    expect(result.content).toContain("cred-1");
    expect(result.content).toContain("Example");
    expect(result.content).toContain("example.test");
    expect(result.content).not.toContain(SECRET);
  });

  it("omits legacy autofill from credential tool discovery", () => {
    const h = harness();
    expect(credentialModule.credentialTools(h.deps).map((tool) => tool.name)).toEqual([
      "browser_list_credentials",
    ]);
  });

  it("omits legacy autofill from both production browser roster views", () => {
    const h = harness();
    expect([...h.tools.keys()]).not.toContain("browser_login_with_credential");
    expect(BROWSER_TOOL_NAMES).not.toContain("browser_login_with_credential");
  });

  it("refuses direct legacy autofill before resolving a secret or touching the page", async () => {
    const h = harness();
    const result = await execLegacy(h, {
      credentialId: "cred-1",
      submit: true,
      submitSelector: "#sign-in",
    });

    expect(result).toEqual({ content: AUTOFILL_REFUSAL });
    expect(h.resolutions).toEqual([]);
    expect(h.fills).toEqual([]);
    expect(h.clicks).toEqual([]);
    expect(h.keys).toEqual([]);
    expect(JSON.stringify(h.logs)).not.toContain(SECRET);
  });

  it("returns the same sanitized refusal when the vault is not configured", async () => {
    const h = harness({ vault: false });
    const listed = await exec(h, "browser_list_credentials", {});
    const login = await execLegacy(h, { credentialId: "cred-1" });

    expect(listed.content).toContain("not configured");
    expect(login).toEqual({ content: AUTOFILL_REFUSAL });
    expect(h.resolutions).toEqual([]);
    expect(h.fills).toEqual([]);
    expect(h.clicks).toEqual([]);
    expect(h.keys).toEqual([]);
  });
});
