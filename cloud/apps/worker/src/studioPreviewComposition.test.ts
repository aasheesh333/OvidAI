import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { FileServiceDeps } from "./fileService.js";
import type { FullRunDeps } from "./runProcessor.js";
import type { StudioGitServiceConfig } from "./studioGitRoutes.js";
import { hibernateWorkspace } from "@ovid/storage";
import { createHibernateWorker } from "@ovid/queue";
import type { Db } from "@ovid/db";
import type {
  JailedStudioPreviewProcessRunnerConfig,
  StudioPreviewManagerConfig,
} from "./studioPreview.js";

const h = vi.hoisted(() => {
  const marker = { studio: "real-service-from-factory" };
  const manager = {
    recover: vi.fn(async () => undefined),
    close: vi.fn(async () => undefined),
  };
  const cgroups = { init: vi.fn(async () => undefined) };
  const launcher = { setuid: true };
  const previewPort = { durable: "postgres-port" };
  const previewStore = { durable: "lifecycle-store" };
  const previewRunner = { jailed: true };
  const previews = {
    sweep: vi.fn(async () => 0),
    stopSession: vi.fn(async () => 0),
    close: vi.fn(async () => undefined),
  };
  const redact = vi.fn((text: string) => text);
  const queue = () => ({ add: vi.fn(), close: vi.fn(async () => undefined) });
  return {
    marker,
    manager,
    cgroups,
    launcher,
    previewPort,
    previewStore,
    previewRunner,
    previews,
    redact,
    createStudioPreviewPostgresStore: vi.fn((_db: unknown) => previewPort),
    createStudioPreviewStore: vi.fn((_port: unknown) => previewStore),
    createStudioPreviewManager: vi.fn((_config: StudioPreviewManagerConfig) => previews),
    createJailedStudioPreviewProcessRunner: vi.fn(
      (_config: JailedStudioPreviewProcessRunnerConfig) => previewRunner,
    ),
    createSecretRedactor: vi.fn(() => ({ text: redact })),
    createDb: vi.fn(),
    redisConstructor: vi.fn(),
    createStudioGitService: vi.fn((_config: StudioGitServiceConfig) => marker),
    parseStudioGitAllowedHosts: vi.fn(() => ["github.com"]),
    buildFileService: vi.fn((_deps: FileServiceDeps) => ({
      listen: vi.fn(async () => undefined),
    })),
    mcpList: vi.fn(async () => []),
    createMcpRuntime: vi.fn(),
    createFullAgentRunProcessor: vi.fn((_deps: FullRunDeps, _storage: unknown) => ({})),
    queues: {
      agentRuns: queue(),
      hibernate: queue(),
      schedules: queue(),
      pluginInstalls: queue(),
    },
  };
});

vi.mock("@ovid/db", () => ({
  createDb: h.createDb,
  createStorageQuotaRepos: vi.fn(() => ({})),
  RunQuotaService: class {
    constructor(_db: unknown) {}
  },
  createStudioPreviewPostgresStore: h.createStudioPreviewPostgresStore,
  createStudioPreviewStore: h.createStudioPreviewStore,
  assertSessionFileCapacity: vi.fn(),
  dbPoolOptionsFromEnv: vi.fn(() => ({})),
  byokKeysRepo: {},
  eventMirror: {},
  fileManifests: {},
  imagesRepo: {},
  mcpOauthFlows: {},
  mcpServers: { list: h.mcpList },
  messages: {},
  runs: {},
  sessions: {},
  sharesRepo: {},
  studioRepos: {},
  users: {},
  workspaceObjects: {},
}));
vi.mock("ioredis", () => ({
  Redis: class {
    constructor(...args: unknown[]) { h.redisConstructor(...args); }
    defineCommand(): void {}
    disconnect(): void {}
  },
}));
vi.mock("@ovid/account", () => ({
  createCloudCleanup: vi.fn(),
  createFirebaseAdmin: vi.fn(),
  createHttpKeyAdmin: vi.fn(),
  createLifecycle: vi.fn(),
  createNoopR2Deleter: vi.fn(),
  createPostgresDeletionStore: vi.fn(),
}));
vi.mock("@ovid/events", () => ({
  createRedisEventLog: vi.fn(() => ({})),
  createRedisSystemBus: vi.fn(() => ({})),
}));
vi.mock("@ovid/browser", () => ({
  createBrowserEngine: vi.fn(async () => ({ tools: [], close: vi.fn() })),
  createLocalDiskBrowserStateStore: vi.fn(),
  createStorageStatePersistence: vi.fn(),
  loadBrowserEngineConfig: vi.fn(() => ({})),
}));
vi.mock("@ovid/queue", () => ({
  AGENT_RUN_JOB_NAME: "agent-run",
  createAgentRunsWorker: vi.fn(),
  createHibernateWorker: vi.fn(() => ({ on: vi.fn() })),
  createHydrateWorker: vi.fn(() => ({ on: vi.fn() })),
  createPluginInstallsWorker: vi.fn(() => ({ on: vi.fn() })),
  createQueues: vi.fn(() => h.queues),
  createScheduleFireWorker: vi.fn(),
  hibernateJobSchema: { parse: (value: unknown) => value },
  hydrateJobSchema: {},
}));
vi.mock("@ovid/mcp", () => ({
  createSecretRedactor: h.createSecretRedactor,
}));
vi.mock("@ovid/storage", () => ({
  awaitWarm: vi.fn(),
  createActivityTracker: vi.fn(() => ({})),
  createR2PrefixDeleterFromEnv: vi.fn(() => null),
  createSandboxManagerEviction: vi.fn(() => ({})),
  createStorage: vi.fn(() => ({})),
  createHttpArtifactGrantFactory: vi.fn(),
  diskAlertFractionFromEnv: vi.fn(() => 0.8),
  hibernateWorkspace: vi.fn(),
  hydrateWorkspace: vi.fn(),
  loadStorageEnv: vi.fn(() => ({})),
  loadCdnConfig: vi.fn(() => null),
  maxWarmBytesFromEnv: vi.fn(() => 1024),
  reconcileStuckHibernations: vi.fn(),
  registerArtifact: vi.fn(),
  STUCK_STATE_MS: 1000,
  SWEEP_INTERVAL_MS: 1000,
  sweepWorkspaces: vi.fn(),
}));
vi.mock("@ovid/sandbox", () => ({
  createCgroupManager: vi.fn(() => h.cgroups),
  createRootmapLauncher: vi.fn(() => h.launcher),
  createSandboxManager: vi.fn(() => h.manager),
  createSetuidLauncher: vi.fn(() => h.launcher),
  loadSandboxConfig: vi.fn(() => ({
    rootfsPath: "/test/rootfs",
    workspacesRoot: "/test/workspaces",
    launch: "setuid",
  })),
  resolveRootfs: vi.fn(async () => ({ path: "/test/rootfs", manifest: {} })),
  selectQuotaBackend: vi.fn(async () => ({})),
}));
vi.mock("@ovid/agent-core", () => ({
  createGuardedEgressFetch: vi.fn(() => vi.fn()),
  createSsrfGuard: vi.fn(() => ({})),
}));
vi.mock("@ovid/escrow", () => ({
  createByokKeyProvider: vi.fn(() => ({})),
  createEnvelopeCrypto: vi.fn(() => ({})),
}));
vi.mock("./studioGitRoutes.js", () => ({
  createStudioGitService: h.createStudioGitService,
  parseStudioGitAllowedHosts: h.parseStudioGitAllowedHosts,
}));
vi.mock("./studioPreview.js", () => ({
  createStudioPreviewManager: h.createStudioPreviewManager,
  createJailedStudioPreviewProcessRunner: h.createJailedStudioPreviewProcessRunner,
}));
vi.mock("./fileService.js", () => ({ buildFileService: h.buildFileService }));
vi.mock("./mcpRuntime.js", () => ({ createMcpRuntime: h.createMcpRuntime }));
vi.mock("./fetchEgressPolicy.js", () => ({
  createFetchEgressPolicy: vi.fn(() => vi.fn()),
}));
vi.mock("./runProcessor.js", () => ({
  createFullAgentRunProcessor: h.createFullAgentRunProcessor,
}));
vi.mock("./keyResolver.js", () => ({ createServerKeyResolver: vi.fn(() => ({})) }));
vi.mock("./notify.js", () => ({
  createNotifier: vi.fn(() => ({})),
  createFcmPushSender: vi.fn(() => ({})),
}));
vi.mock("./webPush.js", () => ({ createWebPushSender: vi.fn(() => ({})) }));
vi.mock("./pluginInstallProcessor.js", () => ({
  createPluginInstallProcessor: vi.fn(() => vi.fn()),
}));
vi.mock("./ptyBridge.js", () => ({ startWorkerPtyBridge: vi.fn(async () => vi.fn()) }));
vi.mock("./sandboxAdapter.js", () => ({
  createSandboxPort: vi.fn(() => ({})),
  createStepLimiter: vi.fn(() => ({})),
}));
vi.mock("./browserToolAdapter.js", () => ({
  adaptBrowserTools: vi.fn(() => []),
  createUserBrowserLeases: vi.fn(() => ({ releaseRun: vi.fn() })),
}));
vi.mock("./browserCredentials.js", () => ({
  createBrowserArtifactVaultPort: vi.fn(() => ({})),
  createBrowserCredentialsPort: vi.fn(() => ({})),
}));
vi.mock("./modelCapabilities.js", () => ({ createModelCatalogReader: vi.fn(() => ({})) }));
vi.mock("./sandboxSeam.js", () => ({ createSandboxSeam: vi.fn(() => ({})) }));
vi.mock("./schedulerMirror.js", () => ({
  createScheduleFireProcessor: vi.fn(() => ({})),
  resyncScheduleMirror: vi.fn(async () => {
    throw new Error("composition-stop-after-processor");
  }),
}));
vi.mock("./scheduleTools.js", () => ({
  createScheduleTools: vi.fn(() => ({})),
  toCoreTools: vi.fn(() => []),
}));
vi.mock("./tools/imageTools.js", () => ({
  createImageTools: vi.fn(() => ({})),
  createInternalImageClient: vi.fn(() => ({})),
  fetchImageCapabilities: vi.fn(),
}));
vi.mock("./schedulerTick.js", () => ({ startSchedulerLoop: vi.fn() }));
vi.mock("./staleRuns.js", () => ({ sweepStaleRuns: vi.fn() }));
vi.mock("./storageScans.js", () => ({
  createColdRowScan: vi.fn(() => ({})),
  createStuckHibernationScan: vi.fn(() => ({})),
  createStuckHydrationScan: vi.fn(() => ({})),
}));
vi.mock("./unattended.js", () => ({ createUnattendedApprovalHook: vi.fn(() => ({})) }));
vi.mock("./accountSweep.js", () => ({ startAccountDeletionSweeper: vi.fn() }));

const MASTER_KEY = "ab".repeat(32);
const baseEnv = (overrides: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv => ({
  DATABASE_URL: "postgres://postgres:ovid@127.0.0.1:5433/postgres",
  REDIS_Q_URL: "redis://127.0.0.1:6390",
  REDIS_MINT_URL: "redis://127.0.0.1:6390",
  OVID_INTERNAL_MINT_URL: "http://127.0.0.1:18092",
  OVID_INTERNAL_API_SECRET: "test-internal-secret-0123456789abcdef",
  OVID_LITELLM_BASE: "http://litellm.invalid",
  OVID_DEFAULT_MODEL: "ovid-default-model",
  OVID_INTERNAL_TOKEN: "shared-secret",
  ...overrides,
});

function mainDb(studioPreviewTablePresent = false): Db {
  const query = vi.fn(async (strings: TemplateStringsArray, ..._values: unknown[]) => {
    const text = strings.join("$").replace(/\s+/g, " ").trim();
    if (text.includes("to_regclass('studio_previews')")) {
      return [{ table_name: studioPreviewTablePresent ? "studio_previews" : null }];
    }
    return [];
  });
  const client = Object.assign(query, { end: vi.fn(async () => undefined) });
  return { $client: client } as unknown as Db;
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.clearAllMocks();
  h.createStudioGitService.mockReturnValue(h.marker);
  h.parseStudioGitAllowedHosts.mockReturnValue(["github.com"]);
  h.createStudioPreviewPostgresStore.mockReturnValue(h.previewPort);
  h.createStudioPreviewStore.mockReturnValue(h.previewStore);
  h.createStudioPreviewManager.mockReturnValue(h.previews);
  h.createJailedStudioPreviewProcessRunner.mockReturnValue(h.previewRunner);
  h.createSecretRedactor.mockReturnValue({ text: h.redact });
  h.previews.sweep.mockResolvedValue(0);
  h.previews.stopSession.mockResolvedValue(0);
  h.previews.close.mockResolvedValue(undefined);
  h.buildFileService.mockReturnValue({ listen: vi.fn(async () => undefined) });
  h.createFullAgentRunProcessor.mockReturnValue({});
});

afterEach(() => {
  vi.useRealTimers();
});

interface AccountPreviewRow {
  id: string;
  status: string;
}

function accountCleanupDb(options: {
  tablePresent?: boolean;
  sessions?: string[];
  rows?: AccountPreviewRow[];
  afterPurge?: AccountPreviewRow[];
  events?: string[];
} = {}) {
  const events = options.events ?? [];
  const statements: string[] = [];
  let rows = [...(options.rows ?? [])];
  const terminal = new Set(["stopped", "failed", "expired"]);
  const query = vi.fn(async (strings: TemplateStringsArray, ..._values: unknown[]) => {
    const text = strings.join("$").replace(/\s+/g, " ").trim();
    statements.push(text);
    if (text.includes("to_regclass('studio_previews')")) {
      events.push("table");
      return [{ table_name: options.tablePresent === false ? null : "studio_previews" }];
    }
    if (text.startsWith("SELECT id FROM sessions WHERE user_id =")) {
      events.push("sessions");
      return (options.sessions ?? []).map((id) => ({ id }));
    }
    if (text.startsWith("SELECT id, status FROM studio_previews") && text.endsWith("FOR UPDATE")) {
      events.push("lock-rows");
      return rows.map((row) => ({ ...row }));
    }
    if (text.startsWith("DELETE FROM studio_previews WHERE user_id =")) {
      events.push("purge");
      rows = options.afterPurge === undefined
        ? rows.filter((row) => !terminal.has(row.status))
        : [...options.afterPurge];
      return [];
    }
    if (text.startsWith("SELECT id, status FROM studio_previews")) {
      events.push("confirm");
      return rows.map((row) => ({ ...row }));
    }
    throw new Error(`unexpected account preview query: ${text}`);
  });
  const begin = vi.fn(async (operation: (tx: typeof query) => Promise<void>) => {
    events.push("begin");
    return operation(query);
  });
  const client = Object.assign(query, { begin });
  return {
    db: { $client: client } as unknown as Db,
    events,
    statements,
    begin,
  };
}

describe("UNEXECUTED Studio preview worker composition regressions", () => {
  it("disables constructors, routes, and the boot sweep when studio_previews is absent", async () => {
    h.createDb.mockReturnValue(mainDb(false));
    h.createMcpRuntime.mockReturnValue(null);
    const { main } = await import("./main.js");

    await expect(main(baseEnv({ OVID_MASTER_KEY: MASTER_KEY })))
      .rejects.toThrow("composition-stop-after-processor");

    expect(h.createStudioPreviewPostgresStore).not.toHaveBeenCalled();
    expect(h.createStudioPreviewStore).not.toHaveBeenCalled();
    expect(h.createStudioPreviewManager).not.toHaveBeenCalled();
    expect(h.previews.sweep).not.toHaveBeenCalled();
    expect(h.buildFileService).toHaveBeenCalledTimes(1);
    expect(h.buildFileService.mock.calls[0]![0]).not.toHaveProperty("studioPreviews");
  });

  it("uses the real Postgres store, binding, jailed runner, redactor, stable epoch, and route dependency", async () => {
    const db = mainDb(true);
    h.createDb.mockReturnValue(db);
    h.createMcpRuntime.mockReturnValue(null);
    const { main } = await import("./main.js");

    await expect(main(baseEnv({
      OVID_MASTER_KEY: MASTER_KEY,
      OVID_WORKER_EPOCH: "worker-host-stable-a",
    }))).rejects.toThrow("composition-stop-after-processor");

    expect(h.createStudioPreviewPostgresStore).toHaveBeenCalledWith(db);
    expect(h.createStudioPreviewStore).toHaveBeenCalledWith(h.previewPort);
    expect(h.createJailedStudioPreviewProcessRunner).toHaveBeenCalledTimes(1);
    const runner = h.createJailedStudioPreviewProcessRunner.mock.calls[0]![0];
    expect(runner).toMatchObject({
      manager: h.manager,
      cgroups: h.cgroups,
      launcher: h.launcher,
      rootfs: "/test/rootfs",
    });
    expect(runner.config).toMatchObject({
      rootfsPath: "/test/rootfs",
      workspacesRoot: "/test/workspaces",
      launch: "setuid",
    });

    expect(h.createSecretRedactor).toHaveBeenCalledTimes(1);
    expect(h.createStudioPreviewManager).toHaveBeenCalledTimes(1);
    const config = h.createStudioPreviewManager.mock.calls[0]![0] as StudioPreviewManagerConfig;
    expect(config.store).toBe(h.previewStore);
    expect(config.manager).toBe(h.manager);
    expect(config.processes).toBe(h.previewRunner);
    expect(config.redact).toBe(h.redact);
    expect(config.workerEpoch).toBe("worker-host-stable-a");
    expect(config.binding).toHaveProperty("db", db);
    expect(config.binding?.constructor.name).toBe("StudioRunBinding");

    expect(h.previews.sweep).toHaveBeenCalledTimes(1);
    expect(h.buildFileService.mock.calls[0]![0].studioPreviews).toBe(h.previews);
  });

  it("stops session previews before hibernation eviction", async () => {
    h.createDb.mockReturnValue(mainDb(true));
    h.createMcpRuntime.mockReturnValue(null);
    const { main } = await import("./main.js");
    await expect(main(baseEnv({ OVID_MASTER_KEY: MASTER_KEY })))
      .rejects.toThrow("composition-stop-after-processor");
    const consumer = vi.mocked(createHibernateWorker).mock.calls[0]![1] as unknown as (
      job: { data: unknown },
    ) => Promise<void>;

    await consumer({
      data: { userId: "user-h", sessionId: "session-h", generation: 1, reason: "idle" },
    });

    expect(h.previews.stopSession).toHaveBeenCalledWith({
      userId: "user-h",
      sessionId: "session-h",
      reason: "hibernate",
    });
    expect(hibernateWorkspace).toHaveBeenCalledTimes(1);
    expect(h.previews.stopSession.mock.invocationCallOrder[0]).toBeLessThan(
      vi.mocked(hibernateWorkspace).mock.invocationCallOrder[0]!,
    );
  });

  it("rejects hibernation for retry when preview stopping fails, without eviction", async () => {
    h.createDb.mockReturnValue(mainDb(true));
    h.createMcpRuntime.mockReturnValue(null);
    const { main } = await import("./main.js");
    await expect(main(baseEnv({ OVID_MASTER_KEY: MASTER_KEY })))
      .rejects.toThrow("composition-stop-after-processor");
    const consumer = vi.mocked(createHibernateWorker).mock.calls[0]![1] as unknown as (
      job: { data: unknown },
    ) => Promise<void>;
    h.previews.stopSession.mockRejectedValueOnce(new Error("preview stop failed"));

    await expect(consumer({
      data: { userId: "user-h", sessionId: "session-h", generation: 1, reason: "idle" },
    })).rejects.toThrow("preview stop failed");
    expect(hibernateWorkspace).not.toHaveBeenCalled();
  });

  it("keeps boot and 30-second sweeps single-flight and stops later ticks", async () => {
    vi.useFakeTimers();
    try {
      const { startStudioPreviewSweeper } = await import("./main.js");
      let releaseBoot!: (swept: number) => void;
      const sweep = vi.fn()
        .mockImplementationOnce(() => new Promise<number>((resolve) => {
          releaseBoot = resolve;
        }))
        .mockResolvedValue(0);
      const sweeper = startStudioPreviewSweeper({ sweep });

      expect(sweep).toHaveBeenCalledTimes(1);
      vi.advanceTimersByTime(30_000);
      expect(sweep).toHaveBeenCalledTimes(1);

      releaseBoot(0);
      await sweeper.boot;
      await vi.advanceTimersByTimeAsync(30_000);
      expect(sweep).toHaveBeenCalledTimes(2);

      await sweeper.stop();
      await vi.advanceTimersByTimeAsync(60_000);
      expect(sweep).toHaveBeenCalledTimes(2);
    } finally {
      vi.useRealTimers();
    }
  });

  it("drains the active sweep, closes internal requests once, confirms previews, then closes the manager", async () => {
    const { closeStudioPreviewResources } = await import("./main.js");
    const events: string[] = [];
    let releaseSweep!: () => void;
    const previewSweepStopped = new Promise<void>((resolve) => {
      releaseSweep = resolve;
    });
    const fileService = {
      close: vi.fn(async () => {
        events.push("file-service");
      }),
    };
    const previews = {
      close: vi.fn(async () => {
        events.push("previews");
      }),
    };
    const closeManager = vi.fn(async () => {
      events.push("manager");
    });

    const closing = closeStudioPreviewResources({
      previewSweepStopped,
      fileService,
      previews,
      closeManager,
    });
    await Promise.resolve();
    expect(fileService.close).not.toHaveBeenCalled();
    expect(previews.close).not.toHaveBeenCalled();
    expect(closeManager).not.toHaveBeenCalled();

    releaseSweep();
    await closing;

    expect(events).toEqual(["file-service", "previews", "manager"]);
    expect(fileService.close).toHaveBeenCalledTimes(1);
  });

  it("stops every current session and purges only confirmed terminal evidence on every retry", async () => {
    const fixture = accountCleanupDb({
      sessions: ["session-a", "session-b"],
      rows: [
        { id: "preview-a", status: "stopped" },
        { id: "preview-b", status: "expired" },
      ],
    });
    const stopSession = vi.fn(async ({ sessionId }: { sessionId: string }) => {
      fixture.events.push(`stop:${sessionId}`);
      return 1;
    });
    const { createStudioPreviewAccountCleanup } = await import("./main.js");
    const cleanup = createStudioPreviewAccountCleanup({
      db: fixture.db,
      previews: { stopSession },
    });

    await cleanup.deleteAccount("user-a");
    await cleanup.deleteAccount("user-a");

    expect(stopSession).toHaveBeenCalledTimes(4);
    expect(stopSession).toHaveBeenNthCalledWith(1, {
      userId: "user-a",
      sessionId: "session-a",
      reason: "delete",
    });
    expect(fixture.events.slice(0, 8)).toEqual([
      "table",
      "sessions",
      "stop:session-a",
      "stop:session-b",
      "begin",
      "lock-rows",
      "purge",
      "confirm",
    ]);
    const deletes = fixture.statements.filter((text) =>
      text.startsWith("DELETE FROM studio_previews")
    );
    expect(deletes).toHaveLength(2);
    for (const text of deletes) {
      expect(text).toContain("status IN ('stopped', 'failed', 'expired')");
    }
  });

  it.each(["starting", "running", "stopping", "unknown-future-state"])(
    "aborts account deletion without a purge for live or unknown preview state %s",
    async (status) => {
      const fixture = accountCleanupDb({
        sessions: ["session-a"],
        rows: [{ id: "preview-a", status }],
      });
      const stopSession = vi.fn(async () => 0);
      const { createStudioPreviewAccountCleanup } = await import("./main.js");
      const cleanup = createStudioPreviewAccountCleanup({
        db: fixture.db,
        previews: { stopSession },
      });

      await expect(cleanup.deleteAccount("user-a")).rejects.toThrow(/terminal/i);
      expect(stopSession).toHaveBeenCalledTimes(1);
      expect(fixture.events).not.toContain("purge");
      expect(fixture.statements.some((text) => text.startsWith("DELETE FROM sessions"))).toBe(false);
    },
  );

  it("aborts before evidence purge when stopSession cleanup fails", async () => {
    const fixture = accountCleanupDb({ sessions: ["session-a"] });
    const stopSession = vi.fn(async () => {
      throw new Error("cleanup unproven");
    });
    const { createStudioPreviewAccountCleanup } = await import("./main.js");
    const cleanup = createStudioPreviewAccountCleanup({
      db: fixture.db,
      previews: { stopSession },
    });

    await expect(cleanup.deleteAccount("user-a")).rejects.toThrow("cleanup unproven");
    expect(fixture.begin).not.toHaveBeenCalled();
    expect(fixture.events).not.toContain("purge");
  });

  it("keeps pre-0041 account deletion normal without a manager or preview queries", async () => {
    const fixture = accountCleanupDb({ tablePresent: false });
    const { createStudioPreviewAccountCleanup } = await import("./main.js");
    const cleanup = createStudioPreviewAccountCleanup({ db: fixture.db, previews: null });

    await expect(cleanup.deleteAccount("user-a")).resolves.toBeUndefined();
    expect(fixture.events).toEqual(["table"]);
    expect(fixture.begin).not.toHaveBeenCalled();
    expect(fixture.statements.some((text) => text.startsWith("SELECT id FROM sessions"))).toBe(false);
  });
});
