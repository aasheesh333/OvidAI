import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { mkdir, mkdtemp, readdir, rm } from "node:fs/promises";
import { join } from "node:path";

import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import type { Redis } from "ioredis";
import { chromium, type Browser, type Page } from "playwright-core";
import {
  browserCtlChannel,
  browserInputChannel,
  userBrowserKey,
  type BrowserStateDto,
} from "@ovid/shared";

import { BrowserOperationCoordinator } from "./browserOperations.js";
import type { BrowserEngineConfig } from "./config.js";
import { createBrowserEngine, type BrowserEngine } from "./engine.js";
import {
  BrowserCredentialBroker,
  type BrokerToolContext,
  type CredentialUseApproval,
  type CredentialUseApprover,
} from "./credentialBroker.js";
import { captureScreenshot, startScreencast } from "./screencast.js";
import { releaseSession } from "./sessionOps.js";
import { BROWSER_TOOL_NAMES, createBrowserTools } from "./tools/definitions.js";
import type { BrowserCredentialsPort, BrowserToolDef, BrowserToolResult } from "./tools/types.js";
import {
  createCredentialFixture,
  type CredentialFixture,
} from "./test/credentialFixture.js";
import { startCredentialHttpsFixture, type CredentialHttpsFixture } from "./test/httpsFixture.js";

const REFUSAL = "error: credential_operation_in_progress";
const TEST_TMP = "/tmp/opencode/ovid-production-completion/credential-observation-gate/chromium";

function deferred(): { promise: Promise<void>; resolve(): void } {
  let resolve!: () => void;
  const promise = new Promise<void>((res) => {
    resolve = res;
  });
  return { promise, resolve };
}

async function sleep(ms: number): Promise<void> {
  await new Promise((resolve) => setTimeout(resolve, ms));
}

async function eventually(predicate: () => Promise<boolean> | boolean, timeoutMs = 5_000): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (await predicate()) return true;
    if (Date.now() >= deadline) return false;
    await sleep(10);
  }
}

function secretStatus(value: unknown, secret: string): { leaked: boolean; encodedLeak: boolean } {
  const serialized = JSON.stringify(value) ?? "";
  return { leaked: serialized.includes(secret), encodedLeak: serialized.includes(encodeURIComponent(secret)) };
}

function refusalStatus(result: BrowserToolResult, secret: string): { refused: boolean; leaked: boolean } {
  return { refused: result.content === REFUSAL, leaked: secretStatus(result, secret).leaked };
}

function makeApprover(
  fixture: CredentialFixture,
  onApproval?: (input: CredentialUseApproval) => Promise<void>,
): CredentialUseApprover {
  return {
    async approve(input) {
      fixture.approvals.push(input as unknown as Record<string, unknown>);
      await onApproval?.(input);
      return "allow";
    },
  };
}

function makeBroker(fixture: CredentialFixture, submitTimeoutMs = 5_000): BrowserCredentialBroker {
  return new BrowserCredentialBroker({
    ...fixture.deps,
    browserOperations: fixture.operations,
    credentials: fixture.credentials,
    operations: fixture.operations,
    submitTimeoutMs,
  });
}

function login(
  fixture: CredentialFixture,
  approver: CredentialUseApprover,
  submitTimeoutMs = 5_000,
) {
  return makeBroker(fixture, submitTimeoutMs).login({
    ctx: fixture.ctx,
    credentialId: fixture.credential.id,
    approver,
    signal: fixture.controller.signal,
  });
}

function toolsFor(fixture: CredentialFixture, broker?: BrowserCredentialBroker): Map<string, BrowserToolDef> {
  return new Map(
    createBrowserTools({
      ...fixture.deps,
      browserOperations: fixture.operations,
      credentials: fixture.credentials,
      ...(broker === undefined
        ? {}
        : {
            credentialBroker: broker,
            credentialApprover: makeApprover(fixture),
          }),
    }).map((tool) => [tool.name, tool]),
  );
}

async function execute(
  tools: Map<string, BrowserToolDef>,
  name: string,
  input: unknown,
  fixture: CredentialFixture,
): Promise<BrowserToolResult> {
  const tool = tools.get(name);
  if (tool === undefined) throw new Error(`missing roster tool ${name}`);
  return await tool.execute(input, fixture.ctx);
}

async function pauseSubmission(fixture: { page: Page }): Promise<{ release(): Promise<void>; paused: Promise<void> }> {
  const intercepted = deferred();
  const release = deferred();
  await fixture.page.route("**/session", async (route) => {
    intercepted.resolve();
    await release.promise;
    await route.continue();
  });
  return {
    paused: intercepted.promise,
    async release() {
      release.resolve();
    },
  };
}

function ordinaryInput(name: string, https: CredentialHttpsFixture): unknown {
  const inputs: Record<string, unknown> = {
    browser_click: { selector: "#username" },
    browser_close_tab: { index: 0 },
    browser_console: { action: "read" },
    browser_cookies: { get: "session" },
    browser_dialog: { action: "read" },
    browser_double_click: { selector: "#username" },
    browser_download: { url: https.url("/after"), filename: "ordinary.txt" },
    browser_drag: { from: "#username", to: "#password" },
    browser_evaluate: { expression: 'document.querySelector("#password").value' },
    browser_fill: { fields: { "#username": "other@example.test" } },
    browser_find: { text: "User" },
    browser_hover: { selector: "#username" },
    browser_long_press: { selector: "#username" },
    browser_navigate: { url: https.otherUrl("/after") },
    browser_network: { action: "list" },
    browser_new_tab: { url: https.otherUrl("/after") },
    browser_open: { url: https.otherUrl("/after") },
    browser_popups: { action: "list" },
    browser_press_key: { key: "Shift" },
    browser_resize: { width: 800, height: 600 },
    browser_screenshot: { type: "png" },
    browser_scroll: { direction: "down", amount: 1 },
    browser_select: { selector: "#username", value: "x" },
    browser_swipe: { fromX: 0, fromY: 0, toX: 1, toY: 1 },
    browser_switch_tab: { index: 0 },
    browser_tap_at: { x: 1, y: 1 },
    browser_type: { selector: "#username", text: "other" },
    browser_upload: { selector: "#username", path: "ordinary.txt" },
    browser_wait_for: { text: "not-present", timeoutMs: 1 },
  };
  return inputs[name] ?? {};
}

class MemoryRedis extends EventEmitter {
  readonly channels = new Set<string>();
  quitCalled = false;

  constructor(private readonly bus: MemoryBrowserBus) {
    super();
    bus.connections.add(this);
  }

  async subscribe(...channels: string[]): Promise<number> {
    for (const channel of channels) this.channels.add(channel);
    return channels.length;
  }

  async unsubscribe(...channels: string[]): Promise<number> {
    if (channels.length === 0) this.channels.clear();
    else for (const channel of channels) this.channels.delete(channel);
    return channels.length;
  }

  async quit(): Promise<string> {
    this.quitCalled = true;
    this.channels.clear();
    this.bus.connections.delete(this);
    return "OK";
  }

  async publish(channel: string, payload: Buffer | string): Promise<number> {
    return await this.bus.publish(channel, payload);
  }
}

class MemoryBrowserBus {
  readonly connections = new Set<MemoryRedis>();
  readonly states: Array<BrowserStateDto & { credentialLock?: boolean }> = [];
  readonly frames: Buffer[] = [];
  readonly records: Array<{ channel: string; payload: Buffer | string }> = [];

  connection(): Redis {
    return new MemoryRedis(this) as unknown as Redis;
  }

  async publish(channel: string, payload: Buffer | string): Promise<number> {
    this.records.push({ channel, payload });
    if (channel.endsWith(":state")) {
      this.states.push(JSON.parse(payload.toString()) as BrowserStateDto & { credentialLock?: boolean });
    } else if (channel.endsWith(":frames")) {
      this.frames.push(Buffer.isBuffer(payload) ? payload : Buffer.from(payload));
    }
    for (const connection of this.connections) {
      if (connection.channels.has(channel)) {
        connection.emit(
          "messageBuffer",
          Buffer.from(channel),
          Buffer.isBuffer(payload) ? payload : Buffer.from(payload),
        );
      }
    }
    return 1;
  }

  async close(): Promise<void> {
    for (const connection of [...this.connections]) await connection.quit();
  }
}

interface EngineFixture {
  engine: BrowserEngine;
  operations: BrowserOperationCoordinator;
  bus: MemoryBrowserBus;
  ctx: BrokerToolContext;
  key: string;
  page: Page | null;
  logs: unknown[][];
  flushes: unknown[];
  approvals: CredentialUseApproval[];
  fieldsClearAtFlush: boolean | null;
}

describe("Task 10 credential observation boundary (real Chromium + two HTTPS origins)", () => {
  let browser: Browser;
  let https: CredentialHttpsFixture;
  const fixtures: CredentialFixture[] = [];
  const engineFixtures: EngineFixture[] = [];
  const roots: string[] = [];

  beforeAll(async () => {
    await mkdir(TEST_TMP, { recursive: true });
    https = await startCredentialHttpsFixture();
    browser = await chromium.launch({
      headless: true,
      args: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu"],
    });
  }, 30_000);

  afterAll(async () => {
    await browser.close();
    await https.close();
  });

  afterEach(async () => {
    for (const fixture of engineFixtures.splice(0)) {
      await fixture.engine.close();
      await fixture.bus.close();
    }
    for (const fixture of fixtures.splice(0)) await fixture.close();
    for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true });
    https.posts.length = 0;
    https.otherPosts.length = 0;
  });

  async function fixture(path = "/login"): Promise<{ value: CredentialFixture; secret: string; root: string }> {
    const secret = `OVID-T10-${randomUUID()}-/+?&=%DoNotLog`;
    const root = await mkdtemp(join(TEST_TMP, "run-"));
    roots.push(root);
    const value = await createCredentialFixture({ browser, https, path, secret });
    value.deps.browserOperations = value.operations;
    value.deps.workspaceDir = async () => root;
    fixtures.push(value);
    return { value, secret, root };
  }

  async function engineFixture(secret: string): Promise<EngineFixture> {
    const root = await mkdtemp(join(TEST_TMP, "engine-"));
    roots.push(root);
    const key = userBrowserKey("u1");
    const operations = new BrowserOperationCoordinator();
    const bus = new MemoryBrowserBus();
    const controller = new AbortController();
    const ctx: BrokerToolContext = {
      sessionId: key,
      userId: "u1",
      workspaceSessionId: "chat-engine",
      runId: "run-engine",
      signal: controller.signal,
    };
    const credentials: BrowserCredentialsPort = {
      async list() {
        return [{
          id: "cred-engine",
          label: "Engine fixture",
          site: https.origin,
          username: "person@example.test",
          secretKind: "password",
          hasNotes: false,
        }];
      },
      async resolve() {
        return {
          id: "cred-engine",
          label: "Engine fixture",
          site: https.origin,
          username: "person@example.test",
          secretKind: "password",
          hasNotes: false,
          secret,
          notes: null,
        };
      },
    };
    const cfg: BrowserEngineConfig = {
      maxLiveBrowsers: 1,
      tier1FallbackContexts: 0,
      idleEvictMs: 1,
      maxTier1Processes: 1,
      tier1TimeoutMs: 1_000,
      maxActiveScreencasts: 1,
      screencastLoadMax: 6,
      screencastDetachGraceMs: 0,
      screencast: { width: 1280, height: 800, quality: 60, everyNthFrame: 2, maxFramesInFlight: 1 },
      stateDir: null,
      lightpandaBin: null,
      allowHosts: ["127.0.0.1", "localhost"],
      ownPublicIp: null,
      blockHeavyResources: false,
      // Test-only trust for the disposable fixture certificate. The pool's
      // production ignoreHTTPSErrors:false context setting is untouched.
      chromiumArgs: ["--no-sandbox", "--disable-dev-shm-usage", "--disable-gpu", "--ignore-certificate-errors"],
      credentialBrokerEnabled: true,
    };
    const logs: unknown[][] = [];
    const flushes: unknown[] = [];
    const approvals: CredentialUseApproval[] = [];
    let fixture!: EngineFixture;
    const engine = await createBrowserEngine({
      cfg,
      browserOperations: operations,
      credentials,
      credentialApprover: {
        approve: async (input) => {
          approvals.push(input);
          return "allow";
        },
      },
      redisFactory: () => bus.connection(),
      persistence: {
        restore: async () => null,
        flush: async (_userId, state) => {
          flushes.push(state);
          if (fixture.page !== null && !fixture.page.isClosed()) {
            fixture.fieldsClearAtFlush = (await fixture.page.locator("#password").inputValue()) === "";
          }
        },
      },
      workspaceDir: async () => root,
      prepareUidDrop: async () => null,
      log: (...args: unknown[]) => logs.push(args),
    });
    fixture = {
      engine,
      operations,
      bus,
      ctx,
      key,
      page: null,
      logs,
      flushes,
      approvals,
      fieldsClearAtFlush: null,
    };
    engineFixtures.push(fixture);
    return fixture;
  }

  function engineTool(fixture: EngineFixture, name: string): BrowserToolDef {
    const tool = fixture.engine.tools.find((candidate) => candidate.name === name);
    if (tool === undefined) throw new Error(`missing engine tool ${name}`);
    return tool;
  }

  async function openEngineLogin(fixture: EngineFixture): Promise<void> {
    const opened = await engineTool(fixture, "browser_open").execute({ url: https.url("/login") }, fixture.ctx);
    expect(opened.content).toContain(https.origin);
    fixture.page = fixture.engine.registry.activePage(fixture.key);
    expect(fixture.page !== null).toBe(true);
  }

  it("refuses direct and concurrent browser_evaluate read-back before any secret observation", async () => {
    const { value: f, secret } = await fixture();
    const tools = toolsFor(f);
    const paused = await pauseSubmission(f);
    const pending = login(f, makeApprover(f));
    let outcome;
    try {
      await paused.paused;
      const direct = await execute(tools, "browser_evaluate", ordinaryInput("browser_evaluate", https), f);
      const concurrent = await Promise.all([
        execute(tools, "browser_evaluate", ordinaryInput("browser_evaluate", https), f),
        execute(tools, "browser_evaluate", ordinaryInput("browser_evaluate", https), f),
      ]);
      const observed = [direct, ...concurrent].map((result) => refusalStatus(result, secret));
      expect(observed).toEqual([
        { refused: true, leaked: false },
        { refused: true, leaked: false },
        { refused: true, leaked: false },
      ]);
    } finally {
      await paused.release();
      outcome = await pending;
    }
    expect(outcome.status).toBe("submitted");
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expect(f.operations.isCredentialOperationActive(f.ctx.sessionId)).toBe(false);
    expect(secretStatus([outcome, f.logs, f.session.console, f.session.network], secret)).toEqual({
      leaked: false,
      encodedLeak: false,
    });
  });

  it("refuses every ordinary roster tool concurrently instead of queueing it until clear", async () => {
    const { value: f, secret } = await fixture();
    const broker = makeBroker(f);
    const tools = toolsFor(f, broker);
    const paused = await pauseSubmission(f);
    const pending = login(f, makeApprover(f));
    let outcome;
    try {
      await paused.paused;
      const results = await Promise.all(
        BROWSER_TOOL_NAMES.map(async (name) => ({
          name,
          result: refusalStatus(await execute(tools, name, ordinaryInput(name, https), f), secret),
        })),
      );
      expect(results.map(({ name, result }) => ({ name, ...result }))).toEqual(
        BROWSER_TOOL_NAMES.map((name) => ({ name, refused: true, leaked: false })),
      );
    } finally {
      await paused.release();
      outcome = await pending;
    }
    expect(outcome.status).toBe("submitted");
    expect(https.otherPosts).toEqual([]);
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expect(f.operations.isCredentialOperationActive(f.ctx.sessionId)).toBe(false);
  });

  it("drops screencast frames and refuses direct screenshots during the credential period without replay", async () => {
    const { value: f, secret } = await fixture();
    const frames: Buffer[] = [];
    const active = () => f.operations.isCredentialOperationActive(f.ctx.sessionId);
    const cast = await startScreencast(f.page, f.deps.cfg.screencast, (frame) => frames.push(frame.data), {
      isCredentialOperationActive: active,
    } as never);
    const paused = await pauseSubmission(f);
    await cast.refresh();
    const before = frames.length;
    const pending = login(f, makeApprover(f));
    let outcome;
    let screenshotResult: unknown;
    try {
      await paused.paused;
      await f.page.evaluate((value) => {
        const visual = globalThis.document.createElement("div");
        visual.id = "credential-visual";
        visual.textContent = value;
        globalThis.document.body.append(visual);
      }, secret);
      await cast.refresh();
      try {
        screenshotResult = await captureScreenshot(f.page, {
          type: "png",
          isCredentialOperationActive: active,
        } as never);
      } catch (error) {
        screenshotResult = { code: (error as { code?: string }).code };
      }
      await sleep(250);
      expect({
        newFrames: frames.length - before,
        screenshotRefused:
          typeof screenshotResult === "object" &&
          screenshotResult !== null &&
          (screenshotResult as { code?: string }).code === "credential_operation_in_progress",
        rawSecretBytes: frames.some((frame) => frame.includes(secret)),
      }).toEqual({ newFrames: 0, screenshotRefused: true, rawSecretBytes: false });
    } finally {
      await paused.release();
      outcome = await pending;
      await cast.stop();
    }
    expect(outcome.status).toBe("submitted");
    expect(secretStatus([outcome, f.logs, f.session.console, f.session.network], secret)).toEqual({
      leaked: false,
      encodedLeak: false,
    });
  });

  it("keeps the exclusive lock through paused field cleanup and releases only after empty fields", async () => {
    const { value: f, secret } = await fixture();
    const tools = toolsFor(f);
    const cleanupStarted = deferred();
    const cleanupRelease = deferred();
    const originalEvaluate = f.page.evaluate.bind(f.page);
    f.page.evaluate = (async (pageFunction: unknown, arg: unknown) => {
      if (String(pageFunction).includes("readLiveValue")) {
        cleanupStarted.resolve();
        await cleanupRelease.promise;
      }
      return await originalEvaluate(pageFunction as never, arg as never);
    }) as typeof f.page.evaluate;

    const pending = login(f, makeApprover(f));
    let outcome;
    let activeAtCleanup = false;
    let readback: BrowserToolResult | null = null;
    try {
      await cleanupStarted.promise;
      activeAtCleanup = f.operations.isCredentialOperationActive(f.ctx.sessionId);
      readback = await execute(tools, "browser_evaluate", ordinaryInput("browser_evaluate", https), f);
      expect({
        activeAtCleanup,
        readback: refusalStatus(readback, secret),
      }).toEqual({ activeAtCleanup: true, readback: { refused: true, leaked: false } });
    } finally {
      cleanupRelease.resolve();
      outcome = await pending;
      f.page.evaluate = originalEvaluate;
    }
    expect(outcome.status).toBe("submitted");
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expect(f.operations.isCredentialOperationActive(f.ctx.sessionId)).toBe(false);
  });

  it("serializes another run/chat login on the same per-user key only after first cleanup", async () => {
    const { value: f, secret } = await fixture();
    const paused = await pauseSubmission(f);
    const first = login(f, makeApprover(f));
    await paused.paused;
    let secondFieldsClear: boolean | null = null;
    const secondCtx = { ...f.ctx, workspaceSessionId: "chat-2", runId: "run-2" };
    const second = makeBroker(f).login({
      ctx: secondCtx,
      credentialId: f.credential.id,
      approver: makeApprover(f, async () => {
        secondFieldsClear = (await f.page.locator("#password").inputValue()) === "";
      }),
      signal: f.controller.signal,
    });
    let secondSettled = false;
    void second.then(() => {
      secondSettled = true;
    });
    await sleep(50);
    const beforeRelease = { secondSettled, resolutions: f.resolutions.length };
    await paused.release();
    const [firstOutcome, secondOutcome] = await Promise.all([first, second]);
    expect(beforeRelease).toEqual({ secondSettled: false, resolutions: 1 });
    expect({ secondFieldsClear, posts: https.posts.length }).toEqual({ secondFieldsClear: true, posts: 2 });
    expect([firstOutcome.status, secondOutcome.status]).toEqual(["submitted", "submitted"]);
    expect(await f.page.locator("#password").inputValue()).toBe("");
    expect(f.operations.isCredentialOperationActive(f.ctx.sessionId)).toBe(false);
    expect(secretStatus([firstOutcome, secondOutcome, f.logs], secret)).toEqual({ leaked: false, encodedLeak: false });
  });

  it("drops page downloads and refuses persistence/pool release during credential work", async () => {
    const { value: f, secret, root } = await fixture();
    const tools = toolsFor(f);
    await execute(tools, "browser_list_tabs", {}, f); // production download-wiring entry point
    const flushes: unknown[] = [];
    let poolReleases = 0;
    f.deps.persistence = {
      restore: async () => null,
      flush: async (_userId, state) => {
        flushes.push(state);
      },
    };
    f.deps.pool = {
      releaseLive: async () => {
        poolReleases += 1;
      },
    } as never;
    const paused = await pauseSubmission(f);
    const pending = login(f, makeApprover(f));
    let outcome;
    let releaseResult: unknown;
    try {
      await paused.paused;
      const downloaded = f.page.waitForEvent("download");
      await f.page.evaluate(() => {
        const anchor = globalThis.document.createElement("a");
        anchor.href = "/after";
        anchor.download = "credential-period.txt";
        globalThis.document.body.append(anchor);
        anchor.click();
      });
      await downloaded;
      const downloadSaved = await eventually(async () => (await readdir(join(root, "browser", "downloads")).catch(() => [])).length > 0, 500);
      try {
        await releaseSession(f.deps, f.ctx.sessionId);
        releaseResult = { code: "released" };
      } catch (error) {
        releaseResult = { code: (error as { code?: string }).code };
      }
      expect({
        downloadSaved,
        releaseCode: (releaseResult as { code?: string }).code,
        flushes: flushes.length,
        poolReleases,
        secretHygiene: secretStatus([releaseResult, flushes, f.session.network], secret).leaked,
      }).toEqual({
        downloadSaved: false,
        releaseCode: "credential_operation_in_progress",
        flushes: 0,
        poolReleases: 0,
        secretHygiene: false,
      });
    } finally {
      await paused.release();
      outcome = await pending;
    }
    await sleep(250);
    expect(await readdir(join(root, "browser", "downloads")).catch(() => [])).toEqual([]);
    expect(outcome.status).toBe("submitted");
    expect(f.operations.isCredentialOperationActive(f.ctx.sessionId)).toBe(false);
  });

  it("drops credential-period console and network records instead of redacting and replaying them", async () => {
    const { value: f, secret } = await fixture();
    Object.assign(f.session, { browserOperations: f.operations });
    await f.page.evaluate(() => {
      globalThis.document.querySelector("#password")?.addEventListener("input", (event) => {
        const value = (event.currentTarget as HTMLInputElement).value;
        globalThis.console.log(`credential-period console ${value}`);
        void globalThis.fetch(`/after?credential=${encodeURIComponent(value)}`).catch(() => {});
      }, { once: true });
    });
    const paused = await pauseSubmission(f);
    const pending = login(f, makeApprover(f));
    let outcome;
    try {
      await paused.paused;
      await sleep(50);
      expect({ console: f.session.console.length, network: f.session.network.length }).toEqual({ console: 0, network: 0 });
    } finally {
      await paused.release();
      outcome = await pending;
    }
    expect(outcome.status).toBe("submitted");
    expect({ console: f.session.console.length, network: f.session.network.length }).toEqual({ console: 0, network: 0 });
    expect(secretStatus([outcome, f.logs, f.session.console, f.session.network], secret)).toEqual({
      leaked: false,
      encodedLeak: false,
    });
  });

  it("UNEXECUTED review C1: broker-first acquisition uses the production engine pool coordinator", async () => {
    const secret = `OVID-T10-${randomUUID()}-/+?&=%DoNotLog`;
    const f = await engineFixture(secret);
    const acquireLive = f.engine.pool.acquireLive.bind(f.engine.pool);
    f.engine.pool.acquireLive = async (sessionId, acquireOpts) => {
      // Test-only navigation seam: the production broker deliberately does not
      // navigate on its own. Put the newly acquired blank page on the valid
      // exact-origin form before its proof, after acquisition has exercised
      // the production coordinator/owner path under test.
      expect(f.operations.isCredentialOperationActive(sessionId)).toBe(true);
      const handle = await acquireLive(sessionId, acquireOpts);
      await handle.page.goto(https.url("/login"));
      return handle;
    };
    expect(f.engine.registry.get(f.key)).toBeNull();

    const outcome = await engineTool(f, "browser_login_with_credential").execute(
      { credentialId: "cred-engine" },
      f.ctx,
    );

    expect(outcome.content.startsWith("submitted: submitted_unverified:")).toBe(true);
    const page = f.engine.registry.activePage(f.key);
    expect(page).not.toBeNull();
    f.page = page;
    expect(await page!.locator("#password").inputValue()).toBe("");
    expect(f.approvals).toHaveLength(1);
    expect(f.operations.isCredentialOperationActive(f.key)).toBe(false);
  });

  it("UNEXECUTED review C1: production engine drains pre-lock idle capture before broker approval", async () => {
    const secret = `OVID-T10-${randomUUID()}-/+?&=%DoNotLog`;
    const f = await engineFixture(secret);
    await openEngineLogin(f);
    const page = f.page!;
    const context = page.context();
    const captureStarted = deferred();
    const captureRelease = deferred();
    const originalStorageState = context.storageState.bind(context);
    context.storageState = (async () => {
      captureStarted.resolve();
      await captureRelease.promise;
      return await originalStorageState();
    }) as typeof context.storageState;

    await sleep(5);
    const eviction = f.engine.pool.evictIdle();
    await captureStarted.promise;
    const pending = engineTool(f, "browser_login_with_credential").execute(
      { credentialId: "cred-engine" },
      f.ctx,
    );
    let outcome;
    try {
      await sleep(25);
      // The reviewer-covered defect lets approval/fill begin while the old
      // context is still capturing and about to close.
      expect(f.approvals).toEqual([]);
    } finally {
      captureRelease.resolve();
      [outcome] = await Promise.all([pending, eviction]);
    }
    expect(outcome.status).toBe("manual_login_required");
    expect(f.approvals).toEqual([]); // blank post-eviction page: no secret resolution
    expect(f.operations.isCredentialOperationActive(f.key)).toBe(false);
  });

  it("UNEXECUTED review C1: direct production pool close aborts then awaits field cleanup before context close", async () => {
    const secret = `OVID-T10-${randomUUID()}-/+?&=%DoNotLog`;
    const f = await engineFixture(secret);
    await openEngineLogin(f);
    const page = f.page!;
    const context = page.context();
    let fieldsClearAtContextClose: boolean | null = null;
    const originalContextClose = context.close.bind(context);
    context.close = (async () => {
      fieldsClearAtContextClose = (await page.locator("#password").inputValue()) === "";
      await originalContextClose();
    }) as typeof context.close;

    const paused = await pauseSubmission({ page });
    const pending = engineTool(f, "browser_login_with_credential").execute(
      { credentialId: "cred-engine" },
      f.ctx,
    );
    await paused.paused;
    const cleanupStarted = deferred();
    const cleanupRelease = deferred();
    const originalEvaluate = page.evaluate.bind(page);
    page.evaluate = (async (pageFunction: unknown, arg: unknown) => {
      if (String(pageFunction).includes("readLiveValue")) {
        cleanupStarted.resolve();
        await cleanupRelease.promise;
      }
      return await originalEvaluate(pageFunction as never, arg as never);
    }) as typeof page.evaluate;

    let closeSettled = false;
    const closing = f.engine.pool.close().then(
      () => ({ ok: true as const }),
      (error: unknown) => ({ ok: false as const, code: (error as { code?: string }).code }),
    );
    void closing.finally(() => {
      closeSettled = true;
    });
    try {
      await paused.release();
      await cleanupStarted.promise;
      expect({ closeSettled, fieldsClearAtContextClose }).toEqual({
        closeSettled: false,
        fieldsClearAtContextClose: null,
      });
    } finally {
      cleanupRelease.resolve();
      await Promise.all([pending, closing]);
      page.evaluate = originalEvaluate;
    }
    expect(await closing).toEqual({ ok: true });
    expect(fieldsClearAtContextClose).toBe(true);
  });

  it.each(["long_press", "swipe"] as const)(
    "UNEXECUTED review I1: production engine drains an admitted viewer %s before credential approval",
    async (kind) => {
      const secret = `OVID-T10-${randomUUID()}-/+?&=%DoNotLog`;
      const f = await engineFixture(secret);
      await openEngineLogin(f);
      const page = f.page!;
      await f.bus.publish(browserCtlChannel(f.key), JSON.stringify({ type: "viewer_join", viewerId: "viewer-input" }));
      await f.bus.publish(browserCtlChannel(f.key), JSON.stringify({ type: "takeover", enabled: true, viewerId: "viewer-input" }));
      expect(await eventually(() => f.engine.registry.get(f.key)?.takeover === true)).toBe(true);
      // Complete the viewer/cast preamble before admitting input; the one-time
      // WebP probe must also have restored the exact-origin form.
      expect(await eventually(async () =>
        f.engine.screencastCount() === 1 && f.bus.frames.length > 0 && page.url() === https.url("/login"),
      )).toBe(true);

      const mouseDown = deferred();
      const inputRelease = deferred();
      let mouseUp = false;
      const originalDown = page.mouse.down.bind(page.mouse);
      const originalUp = page.mouse.up.bind(page.mouse);
      page.mouse.down = (async () => {
        await originalDown();
        mouseDown.resolve();
      }) as typeof page.mouse.down;
      page.mouse.up = (async () => {
        await inputRelease.promise;
        mouseUp = true;
        await originalUp();
      }) as typeof page.mouse.up;
      const input = kind === "long_press"
        ? { type: "long_press", x: 5, y: 5, durationMs: 1_000 }
        : { type: "swipe", fromX: 5, fromY: 5, toX: 50, toY: 50, steps: 8 };
      await f.bus.publish(browserInputChannel(f.key), JSON.stringify(input));
      await mouseDown.promise;
      // Input is now admitted and paused inside its full shared dispatch.
      // Release takeover so the broker's ordinary preamble can run; releasing
      // must not cancel the already-admitted mouse operation being drained.
      await f.bus.publish(browserCtlChannel(f.key), JSON.stringify({ type: "takeover", enabled: false, viewerId: "viewer-input" }));
      expect(await eventually(() => f.engine.registry.get(f.key)?.takeover === false)).toBe(true);

      const pending = engineTool(f, "browser_login_with_credential").execute(
        { credentialId: "cred-engine" },
        f.ctx,
      );
      let outcome;
      try {
        await sleep(25);
        expect({ approvals: f.approvals.length, mouseUp }).toEqual({ approvals: 0, mouseUp: false });
      } finally {
        inputRelease.resolve();
        outcome = await pending;
        page.mouse.down = originalDown;
        page.mouse.up = originalUp;
      }
      expect(outcome.content.startsWith("submitted: submitted_unverified:")).toBe(true);
      expect(mouseUp).toBe(true);
      expect(f.approvals).toHaveLength(1);
    },
  );

  it("drops real-engine viewer input/takeover/tab state and frames while pinning the live pool", async () => {
    const secret = `OVID-T10-${randomUUID()}-/+?&=%DoNotLog`;
    const f = await engineFixture(secret);
    await openEngineLogin(f);
    const page = f.page!;
    await f.bus.publish(browserCtlChannel(f.key), JSON.stringify({ type: "viewer_join", viewerId: "viewer-1" }));
    expect(await eventually(async () => f.engine.screencastCount() === 1 && f.bus.frames.length > 0 && page.url() === https.url("/login"), 10_000)).toBe(true);
    // Install AFTER the one-time WebP probe has restored the login page; the
    // probe's navigation creates a fresh JS realm and would erase this marker.
    await page.evaluate(() => {
      const g = globalThis as any;
      g.__viewerInputApplied = false;
      g.document.addEventListener("click", () => {
        g.__viewerInputApplied = true;
      });
    });

    const paused = await pauseSubmission({ page });
    const pending = engineTool(f, "browser_login_with_credential").execute({ credentialId: "cred-engine" }, f.ctx);
    let outcome;
    try {
      await paused.paused;
      expect(await eventually(() => f.operations.isCredentialOperationActive(f.key) && f.engine.screencastCount() === 0)).toBe(true);
      const framesBefore = f.bus.frames.length;
      await page.evaluate((value) => {
        const visual = globalThis.document.createElement("div");
        visual.textContent = value;
        globalThis.document.body.append(visual);
      }, secret);
      await f.bus.publish(browserCtlChannel(f.key), JSON.stringify({ type: "takeover", enabled: true, viewerId: "viewer-1" }));
      await f.bus.publish(browserCtlChannel(f.key), JSON.stringify({ type: "switch_tab", index: 0, viewerId: "viewer-1" }));
      await f.bus.publish(browserInputChannel(f.key), JSON.stringify({ type: "tap", x: 5, y: 5 }));
      const evaluation = await engineTool(f, "browser_evaluate").execute(ordinaryInput("browser_evaluate", https), f.ctx);
      const evicted = await f.engine.pool.evictIdle();
      await sleep(150);
      const latestLocked = f.bus.states.at(-1)?.credentialLock === true;
      expect({
        latestLocked,
        newFrames: f.bus.frames.length - framesBefore,
        viewerInputApplied: await page.evaluate(() => (globalThis as any).__viewerInputApplied),
        evaluation: refusalStatus(evaluation, secret),
        evicted,
      }).toEqual({
        latestLocked: true,
        newFrames: 0,
        viewerInputApplied: false,
        evaluation: { refused: true, leaked: false },
        evicted: [],
      });
    } finally {
      await paused.release();
      outcome = await pending;
    }
    expect(outcome.content.startsWith("submitted: submitted_unverified:")).toBe(true);
    const session = f.engine.registry.get(f.key);
    expect({
      takeover: session?.takeover,
      activeIndex: session?.activeIndex,
      empty: await page.locator("#password").inputValue() === "",
      active: f.operations.isCredentialOperationActive(f.key),
      secretHygiene: secretStatus([outcome, f.bus.states, f.bus.records, f.logs], secret),
    }).toEqual({
      takeover: false,
      activeIndex: 0,
      empty: true,
      active: false,
      secretHygiene: { leaked: false, encodedLeak: false },
    });
  });

  it("engine close aborts a real submission then awaits empty-field cleanup before persistence and pool close", async () => {
    const secret = `OVID-T10-${randomUUID()}-/+?&=%DoNotLog`;
    const f = await engineFixture(secret);
    await openEngineLogin(f);
    const page = f.page!;
    const paused = await pauseSubmission({ page });
    const pending = engineTool(f, "browser_login_with_credential").execute({ credentialId: "cred-engine" }, f.ctx);
    await paused.paused;

    const cleanupStarted = deferred();
    const cleanupRelease = deferred();
    const originalEvaluate = page.evaluate.bind(page);
    page.evaluate = (async (pageFunction: unknown, arg: unknown) => {
      if (String(pageFunction).includes("readLiveValue")) {
        cleanupStarted.resolve();
        await cleanupRelease.promise;
      }
      return await originalEvaluate(pageFunction as never, arg as never);
    }) as typeof page.evaluate;

    let closeSettled = false;
    const closing = f.engine.close();
    void closing.then(() => {
      closeSettled = true;
    });
    try {
      await paused.release();
      await cleanupStarted.promise;
      expect({
        closeSettled,
        active: f.operations.isCredentialOperationActive(f.key),
        registryGone: f.engine.registry.get(f.key) === null,
        poolLive: f.engine.pool.liveCount(),
      }).toEqual({ closeSettled: false, active: true, registryGone: true, poolLive: 1 });
    } finally {
      cleanupRelease.resolve();
      await Promise.all([pending, closing]);
      page.evaluate = originalEvaluate;
    }
    expect({
      fieldsClearAtFlush: f.fieldsClearAtFlush,
      flushes: f.flushes.length,
      active: f.operations.isCredentialOperationActive(f.key),
      registryGone: f.engine.registry.get(f.key) === null,
      browserAlive: f.engine.pool.stats().browserAlive,
      secretHygiene: secretStatus([f.flushes, f.bus.states, f.bus.records, f.logs], secret),
    }).toEqual({
      fieldsClearAtFlush: true,
      flushes: 1,
      active: false,
      registryGone: true,
      browserAlive: false,
      secretHygiene: { leaked: false, encodedLeak: false },
    });
  });

  it("drops console/network observations and releases the lock on MFA, cross-origin, timeout, abort, redirect and cleanup-failure paths", async () => {
    const cases: Array<{
      path: string;
      action?: "timeout" | "abort" | "cleanup" | "navigation" | "new-tab";
      code: string;
    }> = [
      { path: "/login-mfa", code: "manual_login_required" },
      { path: "/login-iframe", code: "unsupported_login_context" },
      { path: `/login?action=${encodeURIComponent(https.otherUrl("/steal"))}`, code: "form_action_origin_mismatch" },
      { path: "/login?action=/redirect-session", code: "submission_outcome_unknown" },
      { path: "/login?action=/slow-session", action: "timeout", code: "submission_timeout" },
      { path: "/login?action=/slow-session", action: "abort", code: "submission_aborted" },
      { path: "/login", action: "navigation", code: "credential_navigation_refused" },
      { path: "/login", action: "new-tab", code: "unsupported_login_context" },
      { path: "/login", action: "cleanup", code: "submitted_unverified" },
    ];
    for (const testCase of cases) {
      const postBaseline = https.posts.length;
      const { value: f, secret } = await fixture(testCase.path);
      if (testCase.action === "cleanup") {
        await f.page.evaluate(() => {
          const password = globalThis.document.querySelector("#password") as HTMLInputElement;
          password.addEventListener("input", () => {
            Object.defineProperty(password, "value", {
              configurable: true,
              get: () => "retained",
              set: () => {
                throw new Error("test-only cleanup failure");
              },
            });
          }, { once: true });
        });
      }
      if (testCase.action === "navigation" || testCase.action === "new-tab") {
        await f.page.evaluate((action) => {
          globalThis.document.querySelector("#password")?.addEventListener("input", () => {
            if (action === "navigation") globalThis.location.assign("/navigated");
            else globalThis.open("/after", "_blank");
          }, { once: true });
        }, testCase.action);
      }
      const pending = login(f, makeApprover(f), testCase.action === "timeout" ? 30 : 5_000);
      if (testCase.action === "abort") {
        expect(await eventually(() => https.posts.length > postBaseline)).toBe(true);
        f.controller.abort();
      }
      const outcome = await pending;
      expect({ path: testCase.path, code: outcome.code }).toEqual({ path: testCase.path, code: testCase.code });
      expect(f.operations.isCredentialOperationActive(f.ctx.sessionId)).toBe(false);
      expect(secretStatus([outcome, f.logs, f.session.console, f.session.network, f.session.dialogs, f.session.popups], secret)).toEqual({
        leaked: false,
        encodedLeak: false,
      });
      if (testCase.action === "cleanup" || testCase.action === "navigation") {
        expect(f.page.isClosed()).toBe(true);
      }
      if (testCase.action === "new-tab") {
        expect(f.context.pages()).toEqual([f.page]);
        expect(await f.page.locator("#password").inputValue()).toBe("");
      }
      if (!f.page.isClosed() && testCase.path === "/login-mfa") {
        expect(await f.page.locator("#password").inputValue()).toBe("");
      }
    }
  });
});
