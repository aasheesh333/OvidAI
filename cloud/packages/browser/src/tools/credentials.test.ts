import { describe, expect, it, vi } from "vitest";

import type { BrowserSessionRegistry, SessionBrowser } from "../sessions.js";
import { credentialHost, hostMatches } from "./credentials.js";
import { createBrowserTools } from "./definitions.js";
import type {
  BrowserCredentialSecret,
  BrowserCredentialSummary,
  BrowserCredentialsPort,
  BrowserToolContext,
  BrowserToolDef,
  BrowserToolsDeps,
} from "./types.js";

/**
 * Wave 6 W4 — credentials vault tools. No chromium: a stub page records the
 * fill calls, so the assertions are about the SECURITY contract — the secret
 * reaches the page, never the tool output or the log.
 */

const SECRET = "correct-horse-battery-staple";
const CTX: BrowserToolContext = { sessionId: "user-u1", userId: "u1", workspaceSessionId: "chat-1" };

interface Harness {
  tools: Map<string, BrowserToolDef>;
  fills: Array<{ selector: string; value: string }>;
  clicks: string[];
  keys: string[];
  logs: unknown[][];
  setUrl(url: string): void;
}

function harness(opts: {
  credential?: BrowserCredentialSecret | null;
  list?: BrowserCredentialSummary[];
  vault?: boolean;
} = {}): Harness {
  let url = "https://example.test/login";
  const fills: Array<{ selector: string; value: string }> = [];
  const clicks: string[] = [];
  const keys: string[] = [];
  const logs: unknown[][] = [];

  const page = {
    url: () => url,
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
    resolve: async () => secret,
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
  return {
    tools,
    fills,
    clicks,
    keys,
    logs,
    setUrl: (next: string) => {
      url = next;
    },
  };
}

function exec(h: Harness, name: string, input: unknown) {
  const tool = h.tools.get(name);
  if (tool === undefined) throw new Error(`missing tool ${name}`);
  return tool.execute(input, CTX);
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

  it("fills the login form server-side; the secret never appears in output or logs", async () => {
    const h = harness();
    const result = await exec(h, "browser_login_with_credential", { credentialId: "cred-1" });

    expect(h.fills).toEqual([
      { selector: expect.stringContaining("input"), value: "me@example.test" },
      { selector: 'input[type="password"]', value: SECRET },
    ]);
    expect(result.content).toContain("filled credentials for Example");
    expect(result.content).not.toContain(SECRET);
    expect(JSON.stringify(h.logs)).not.toContain(SECRET);
  });

  it("refuses to inject on a different host (phishing guard)", async () => {
    const h = harness();
    h.setUrl("https://evil.test/login");
    const result = await exec(h, "browser_login_with_credential", { credentialId: "cred-1" });
    expect(result.content).toContain("this credential is for example.test");
    expect(h.fills).toEqual([]);
    expect(result.content).not.toContain(SECRET);
  });

  it("the conventional www alias is allowed, but arbitrary subdomains are not", async () => {
    const h = harness();
    h.setUrl("https://www.example.test/signin");
    await exec(h, "browser_login_with_credential", { credentialId: "cred-1" });
    expect(h.fills).toHaveLength(2);

    // accounts.example.test is a DIFFERENT site: store it explicitly rather
    // than letting any attacker-controlled subdomain receive the credential.
    const sub = harness();
    sub.setUrl("https://accounts.example.test/signin");
    const refused = await exec(sub, "browser_login_with_credential", { credentialId: "cred-1" });
    expect(refused.content).toContain("this credential is for example.test");
    expect(sub.fills).toEqual([]);
  });

  it("token entries use the token selector and can submit with Enter", async () => {
    const h = harness({
      credential: {
        id: "cred-t",
        label: "API",
        site: "api.example.test",
        username: "",
        secretKind: "token",
        hasNotes: false,
        secret: SECRET,
        notes: null,
      },
    });
    h.setUrl("https://api.example.test/login");
    const result = await exec(h, "browser_login_with_credential", {
      credentialId: "cred-t",
      submit: true,
    });
    expect(h.fills).toHaveLength(1);
    expect(h.fills[0].value).toBe(SECRET);
    expect(h.keys).toEqual(["Enter"]);
    expect(result.content).not.toContain(SECRET);
  });

  it("an unknown credential is a value-free error", async () => {
    const h = harness({ credential: null });
    const result = await exec(h, "browser_login_with_credential", { credentialId: "nope" });
    expect(result.content).toContain("credential not found");
    expect(h.fills).toEqual([]);
  });

  it("missing vault wiring is a loud refusal, never a silent no-op", async () => {
    const h = harness({ vault: false });
    const listed = await exec(h, "browser_list_credentials", {});
    const login = await exec(h, "browser_login_with_credential", { credentialId: "cred-1" });
    expect(listed.content).toContain("not configured");
    expect(login.content).toContain("not configured");
    expect(h.fills).toEqual([]);
  });

  it("host matching is exact or the www alias only", () => {
    expect(hostMatches("example.test", "example.test")).toBe(true);
    expect(hostMatches("www.example.test", "example.test")).toBe(true);
    expect(hostMatches("example.test", "www.example.test")).toBe(true);
    expect(hostMatches("accounts.example.test", "example.test")).toBe(false);
    expect(hostMatches("evilexample.test", "example.test")).toBe(false);
    expect(credentialHost("https://Example.test/login")).toBe("example.test");
    expect(credentialHost("example.test")).toBe("example.test");
    expect(credentialHost("")).toBeNull();
  });
});
