import { beforeEach, describe, expect, it, vi } from "vitest";
import type { FileServiceDeps } from "./fileService.js";
import type { FullRunDeps } from "./runProcessor.js";
import type { StudioGitServiceConfig } from "./studioGitRoutes.js";

const h = vi.hoisted(() => {
  const marker = { studio: "real-service-from-factory" };
  const manager = { recover: vi.fn(async () => undefined) };
  const queue = () => ({ add: vi.fn(), close: vi.fn(async () => undefined) });
  return {
    marker,
    manager,
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
  dbPoolOptionsFromEnv: vi.fn(() => ({})),
  byokKeysRepo: {},
  eventMirror: {},
  fileManifests: {},
  imagesRepo: {},
  mcpOauthFlows: {},
  mcpServers: { list: h.mcpList },
  messages: {},
  runs: {},
  sharesRepo: {},
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
  hibernateJobSchema: {},
  hydrateJobSchema: {},
}));
vi.mock("@ovid/storage", () => ({
  awaitWarm: vi.fn(),
  createActivityTracker: vi.fn(() => ({})),
  createR2PrefixDeleterFromEnv: vi.fn(() => null),
  createSandboxManagerEviction: vi.fn(() => ({})),
  createStorage: vi.fn(() => ({})),
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
  createCgroupManager: vi.fn(() => ({ init: vi.fn(async () => undefined) })),
  createRootmapLauncher: vi.fn(() => ({})),
  createSandboxManager: vi.fn(() => h.manager),
  createSetuidLauncher: vi.fn(() => ({})),
  loadSandboxConfig: vi.fn(() => ({
    rootfsPath: "/test/rootfs",
    workspacesRoot: "/test/workspaces",
    launch: "setuid",
  })),
  resolveRootfs: vi.fn(async () => "/test/rootfs"),
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
vi.mock("./fileService.js", () => ({ buildFileService: h.buildFileService }));
vi.mock("./mcpRuntime.js", () => ({ createMcpRuntime: h.createMcpRuntime }));
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

beforeEach(() => {
  vi.clearAllMocks();
  h.createStudioGitService.mockReturnValue(h.marker);
  h.parseStudioGitAllowedHosts.mockReturnValue(["github.com"]);
  h.buildFileService.mockReturnValue({ listen: vi.fn(async () => undefined) });
  h.createFullAgentRunProcessor.mockReturnValue({});
});

describe("worker Studio production composition", () => {
  it("requires the master key before opening DB or Redis resources", async () => {
    h.createDb.mockImplementation(() => {
      throw new Error("db-opened-before-studio-key-validation");
    });
    const { main } = await import("./main.js");
    await expect(main(baseEnv())).rejects.toThrow("OVID_MASTER_KEY is required for Studio git");
    expect(h.createDb).not.toHaveBeenCalled();
    expect(h.redisConstructor).not.toHaveBeenCalled();
    expect(h.createStudioGitService).not.toHaveBeenCalled();
  });

  it("passes the real Studio service and preserves the existing MCP composition", async () => {
    const mcpRuntime = {
      activation: { activate: vi.fn() },
      router: { releaseRun: vi.fn(() => "released") },
      installer: { rehydrate: vi.fn(async () => 0) },
      resolver: {},
    };
    h.createMcpRuntime.mockReturnValue(mcpRuntime);
    const db = { $client: {} };
    h.createDb.mockReturnValue(db);
    const { main } = await import("./main.js");

    await expect(main(baseEnv({
      OVID_MASTER_KEY: MASTER_KEY,
      OVID_GIT_ALLOWED_HOSTS: " github.com, git.corp.example ",
    }))).rejects.toThrow("composition-stop-after-processor");

    expect(h.parseStudioGitAllowedHosts).toHaveBeenCalledWith(" github.com, git.corp.example ");
    expect(h.createStudioGitService).toHaveBeenCalledTimes(1);
    const config = h.createStudioGitService.mock.calls[0]![0];
    expect(config).toMatchObject({ manager: h.manager, masterKey: MASTER_KEY, allowedHosts: ["github.com"] });
    expect(config).not.toHaveProperty("allowLocalUrls");
    expect(config).not.toHaveProperty("githubToken");
    await config.listServers("verified-user");
    expect(h.mcpList).toHaveBeenCalledWith(db, "verified-user");

    expect(h.buildFileService).toHaveBeenCalledTimes(1);
    expect(h.createStudioGitService.mock.invocationCallOrder[0]).toBeLessThan(
      h.buildFileService.mock.invocationCallOrder[0]!,
    );
    const deps = h.buildFileService.mock.calls[0]![0];
    expect(deps.studioGit).toBe(h.marker);

    const processor = h.createFullAgentRunProcessor.mock.calls[0]![0];
    expect(processor.mcp).toEqual({
      activation: mcpRuntime.activation,
      router: mcpRuntime.router,
    });
    expect(processor.mcpReleaseRun!("verified-user", { sessionId: "session", runId: "run" }))
      .toBe("released");
    expect(mcpRuntime.router.releaseRun).toHaveBeenCalledWith("verified-user", {
      sessionId: "session",
      runId: "run",
    });
  });
});
