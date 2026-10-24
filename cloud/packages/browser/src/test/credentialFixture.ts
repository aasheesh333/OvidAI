/** Real-Chromium credential broker fixture. Test-only; no production trust changes. */

import type { Browser, BrowserContext, Page } from "playwright-core";

import { BrowserOperationCoordinator } from "../browserOperations.js";
import { instrumentPage, type SessionBrowser } from "../sessions.js";
import type {
  BrowserCredentialSecret,
  BrowserCredentialsPort,
  BrowserToolContext,
  BrowserToolsDeps,
} from "../tools/types.js";
import type { CredentialHttpsFixture } from "./httpsFixture.js";

export const CREDENTIAL_SENTINEL = "OVID-T9-SENTINEL-7f3a9c2e /+?&=%DoNotLog";
export const REDACTION_SENTINEL = "OVID-T9-REDACTION-MARKER";

export interface CredentialTestContext extends BrowserToolContext {
  runId: string;
  signal: AbortSignal;
}

export interface CredentialFixture {
  context: BrowserContext;
  page: Page;
  session: SessionBrowser;
  deps: BrowserToolsDeps;
  credentials: BrowserCredentialsPort;
  credential: BrowserCredentialSecret;
  operations: BrowserOperationCoordinator;
  ctx: CredentialTestContext;
  controller: AbortController;
  approvals: Array<Record<string, unknown>>;
  resolutions: Array<{ userId: string; id: string }>;
  logs: unknown[][];
  close(): Promise<void>;
}

export async function createCredentialFixture(opts: {
  browser: Browser;
  https: CredentialHttpsFixture;
  path?: string;
  site?: string;
  secret?: string;
}): Promise<CredentialFixture> {
  const secret = opts.secret ?? CREDENTIAL_SENTINEL;
  const credential: BrowserCredentialSecret = {
    id: "cred-1",
    label: "Fixture login",
    site: opts.site ?? opts.https.origin,
    username: "person@example.test",
    secretKind: "password",
    hasNotes: false,
    secret,
    notes: null,
  };
  const context = await opts.browser.newContext({ ignoreHTTPSErrors: true });
  const page = await context.newPage();
  await page.goto(opts.https.url(opts.path ?? "/login"));
  const session = {
    sessionId: "user-u1",
    userId: "u1",
    handle: { page, context, touch() {} },
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
  instrumentPage(session, page);
  const logs: unknown[][] = [];
  const resolutions: Array<{ userId: string; id: string }> = [];
  const cfg = {
    maxLiveBrowsers: 1,
    tier1FallbackContexts: 0,
    idleEvictMs: 180_000,
    maxTier1Processes: 1,
    tier1TimeoutMs: 1_000,
    maxActiveScreencasts: 1,
    screencastLoadMax: 6,
    screencastDetachGraceMs: 0,
    screencast: { width: 1280, height: 800, quality: 60, everyNthFrame: 2, maxFramesInFlight: 1 },
    stateDir: null,
    lightpandaBin: null,
    allowHosts: ["127.0.0.1"],
    ownPublicIp: null,
    blockHeavyResources: false,
    chromiumArgs: [],
    credentialBrokerEnabled: true,
  } as BrowserToolsDeps["cfg"];
  const registry = {
    get: (key: string) => (key === session.sessionId ? session : null),
    touch() {},
    refuseReasonIfTakeover: () => null,
  };
  const deps: BrowserToolsDeps = {
    pool: {} as never,
    registry: registry as never,
    persistence: null,
    cfg,
    workspaceDir: async () => "/tmp/opencode/credential-fixture-unused",
    log: (...args: unknown[]) => logs.push(args),
  };
  const credentials: BrowserCredentialsPort = {
    async list(userId) {
      if (userId !== "u1") return [];
      const { secret: _secret, notes: _notes, ...metadata } = credential;
      return [metadata];
    },
    async resolve(userId, id) {
      resolutions.push({ userId, id });
      return userId === "u1" && id === credential.id ? credential : null;
    },
  };
  const controller = new AbortController();
  return {
    context,
    page,
    session,
    deps,
    credentials,
    credential,
    operations: new BrowserOperationCoordinator(),
    ctx: {
      sessionId: "user-u1",
      userId: "u1",
      workspaceSessionId: "chat-1",
      runId: "run-1",
      signal: controller.signal,
    },
    controller,
    approvals: [],
    resolutions,
    logs,
    async close() {
      await context.close();
    },
  };
}
