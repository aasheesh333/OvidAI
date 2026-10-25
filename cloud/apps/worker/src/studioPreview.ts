import { randomUUID } from "node:crypto";
import { constants as FS_CONSTANTS } from "node:fs";
import {
  lstat,
  mkdir,
  open,
  realpath,
  stat,
  type FileHandle,
} from "node:fs/promises";
import { get as httpGet } from "node:http";
import { createServer } from "node:net";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { StringDecoder } from "node:string_decoder";
import {
  buildBwrapArgs,
  type CgroupManager,
  type JailLauncher,
  type SandboxConfig,
  type SandboxManager,
} from "@ovid/sandbox";
import {
  StudioRunBindingError,
  type StudioRunBindingPort,
} from "./studioRunBinding.js";

export type StudioPreviewKind = "static" | "dev_server";
export type StudioPreviewStatus =
  | "starting"
  | "running"
  | "stopping"
  | "stopped"
  | "failed"
  | "expired";
export type StudioPreviewScript = "dev" | "start" | "preview";

/**
 * Durable registration shape. Runtime/terminal unknowns are null, never zero
 * or an invented value. There are deliberately no command/URL/grant/secret
 * fields: package-manager argv and log paths are reconstructed from identity.
 */
export interface StudioPreviewRecord {
  id: string;
  sessionId: string;
  userId: string;
  generation: number;
  kind: StudioPreviewKind;
  workspacePath: string;
  projectDir: string | null;
  startScript: StudioPreviewScript | null;
  processId: number | null;
  processGroupId: string | null;
  workerEpoch: string | null;
  bindHost: string | null;
  port: number | null;
  status: StudioPreviewStatus;
  createdAt: string;
  lastAccessAt: string | null;
  expiresAt: string;
  endedAt: string | null;
  exitCode: number | null;
  failureCode: string | null;
  logBytes: number | null;
}

export type StudioPreviewStorePatch = Partial<Pick<StudioPreviewRecord,
  | "status"
  | "processId"
  | "processGroupId"
  | "workerEpoch"
  | "bindHost"
  | "port"
  | "expiresAt"
  | "endedAt"
  | "exitCode"
  | "failureCode"
  | "logBytes"
>>;

/** The DB adapter MUST serialize start+cap counting in one transaction/advisory lock. */
export interface StudioPreviewStore {
  start(
    record: StudioPreviewRecord,
    caps: { perUser: number; global: number },
  ): Promise<StudioPreviewRecord>;
  getForUser(
    userId: string,
    sessionId: string,
    id?: string,
  ): Promise<StudioPreviewRecord[]>;
  getLive(): Promise<StudioPreviewRecord[]>;
  update(
    id: string,
    generation: number,
    patch: StudioPreviewStorePatch,
  ): Promise<StudioPreviewRecord | null>;
  /**
   * Matches the DB contract exactly. True means an actual lastAccessAt write;
   * false means stale, denied, missing, OR ordinarily throttled. The manager
   * always performs an authoritative re-read before returning Record | null.
   */
  touch(input: {
    id: string;
    generation: number;
    now: string;
  }): Promise<boolean>;
  sweepExpired(now: string, limit: number): Promise<StudioPreviewRecord[]>;
}

export interface StudioPreviewLimits {
  perUser: number;
  global: number;
  startupMs: number;
  idleMs: number;
  absoluteMs: number;
  logCapBytes: number;
  portMin: number;
  portMax: number;
  bindHost: string;
}

export const STUDIO_PREVIEW_DEFAULT_LIMITS: Readonly<StudioPreviewLimits> = Object.freeze({
  perUser: 2,
  global: 32,
  startupMs: 30_000,
  idleMs: 15 * 60_000,
  absoluteMs: 60 * 60_000,
  logCapBytes: 256 * 1024,
  portMin: 20_000,
  portMax: 29_999,
  bindHost: "127.0.0.1",
});

export type StudioPreviewErrorCode =
  | "invalid_request"
  | "invalid_path"
  | "invalid_script"
  | "invalid_bind"
  | "per_user_capacity"
  | "global_capacity"
  | "startup_timeout"
  | "startup_failed"
  | "output_limit"
  | "process_exited"
  | "idle_expired"
  | "absolute_expired"
  | "stale_process"
  | "deleted"
  | "hibernated"
  | "shutdown"
  | "preview_closed"
  | "not_found"
  | "not_running"
  | "no_repo"
  | "cleanup_unproven"
  | "lifecycle_conflict"
  | "log_unavailable";

export class StudioPreviewError extends Error {
  readonly name = "StudioPreviewError";
  readonly processGroupId: string | null;
  constructor(
    readonly code: StudioPreviewErrorCode,
    message: string,
    options?: { cause?: unknown; processGroupId?: string },
  ) {
    super(message, options);
    this.processGroupId = options?.processGroupId ?? null;
  }
}

export interface StudioPreviewStartStatic {
  userId: string;
  sessionId: string;
  kind: "static";
  workspacePath: string;
}

export interface StudioPreviewStartDev {
  userId: string;
  sessionId: string;
  kind: "dev_server";
  projectDir: string;
  script: StudioPreviewScript;
}

export type StudioPreviewStartRequest = StudioPreviewStartStatic | StudioPreviewStartDev;

export interface StudioPreviewOwner {
  userId: string;
  sessionId: string;
}

export interface StudioPreviewRef extends StudioPreviewOwner {
  id: string;
}

export interface StudioPreviewTouchRequest extends StudioPreviewRef {
  generation: number;
  /** Optional expected kind; omitted still requires the authoritative kind to stay unchanged. */
  kind?: StudioPreviewKind;
  /** Gateway server time for its adapter; tests/worker calls default to the manager clock. */
  now?: Date;
}

export interface StudioPreviewLogs {
  text: string;
  truncated: boolean;
}

export interface StudioPreviewManager {
  start(request: StudioPreviewStartRequest): Promise<StudioPreviewRecord>;
  stop(request: StudioPreviewRef): Promise<StudioPreviewRecord | null>;
  get(request: StudioPreviewOwner): Promise<StudioPreviewRecord[]>;
  get(request: StudioPreviewRef): Promise<StudioPreviewRecord | null>;
  /** Explicit authorized content/HMR access; ordinary management reads never touch. */
  touch(request: StudioPreviewTouchRequest): Promise<StudioPreviewRecord | null>;
  logs(request: StudioPreviewRef): Promise<StudioPreviewLogs | null>;
  sweep(limit?: number): Promise<number>;
  stopSession(request: StudioPreviewOwner & {
    reason: "delete" | "hibernate";
  }): Promise<number>;
  close(): Promise<void>;
}

export interface StudioPreviewProcess {
  readonly processId: number;
  /** Absolute cgroup leaf identity. A PID alone is never a cleanup identity. */
  readonly processGroupId: string;
  onExit(callback: (exitCode: number | null) => void): void;
  kill(): Promise<void>;
}

export interface StudioPreviewSpawnRequest {
  previewId: string;
  userId: string;
  argv: string[];
  cwd: string;
  env: Record<string, string>;
  port: number;
  projectDir: string;
}

export interface StudioPreviewProcessRunner {
  spawn(
    request: StudioPreviewSpawnRequest,
    onOutput: (chunk: Buffer) => void,
  ): Promise<StudioPreviewProcess>;
  /** Must refuse a missing/mismatched cgroup identity; never fall back to kill(pid). */
  killStale(record: StudioPreviewRecord): Promise<void>;
}

export interface StudioPreviewManagerConfig {
  store: StudioPreviewStore;
  manager: Pick<SandboxManager, "attach" | "workspaceDir">;
  /** Canonical uid+sid studio_repos read; dev paths are confined below this binding. */
  binding: Pick<StudioRunBindingPort, "get">;
  redact: (text: string) => string;
  /** Stable worker-host identity, NOT a random per-process value. */
  workerEpoch: string;
  now?: () => number;
  limits?: Partial<StudioPreviewLimits>;
  processes?: StudioPreviewProcessRunner;
  /** Test seam for readiness; production performs an actual private HTTP probe. */
  probe?: (host: string, port: number) => Promise<boolean>;
  sleep?: (ms: number) => Promise<void>;
  allocatePort?: (reserved: ReadonlySet<number>) => Promise<number>;
}

interface Attempt {
  process: StudioPreviewProcess;
  exited: boolean;
  exitCode: number | null;
  outputTail: string;
}

interface Runtime {
  record: StudioPreviewRecord;
  attempt: Attempt | null;
  spawnAttempted: boolean;
  logHandle: FileHandle | null;
  logBytes: number;
  receivedBytes: number;
  pendingOutput: string;
  decoder: StringDecoder;
  outputFailure: "output_limit" | null;
  terminal: boolean;
  tail: Promise<void>;
}

const STARTUP_ATTEMPTS = 3;
const LIFECYCLE_ATTEMPTS = 4;
const SWEEP_LIMIT = 100;
const STATIC_MAX_BYTES = 16 * 1024 * 1024;
const LIVE_STATUSES = new Set<StudioPreviewStatus>(["starting", "running", "stopping"]);
const SCRIPTS = new Set<StudioPreviewScript>(["dev", "start", "preview"]);
const sleepDefault = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

function isLive(record: StudioPreviewRecord): boolean {
  return LIVE_STATUSES.has(record.status);
}

function isErrno(err: unknown, ...codes: string[]): boolean {
  return err instanceof Error && "code" in err &&
    codes.includes((err as NodeJS.ErrnoException).code ?? "");
}

function invalidPath(): never {
  throw new StudioPreviewError("invalid_path", "That path is outside the workspace.");
}

function inside(root: string, candidate: string): boolean {
  const rel = relative(root, candidate);
  return rel === "" || (!rel.startsWith(`..${sep}`) && rel !== ".." && !isAbsolute(rel));
}

function assertRelativePath(raw: unknown): string {
  if (
    typeof raw !== "string" || raw.length === 0 || raw.length > 4096 ||
    raw.includes("\0") || raw.includes("\\") || raw.startsWith("/")
  ) invalidPath();
  const parts = raw.split("/");
  if (parts.some((part) => part === "" || part === "." || part === "..")) {
    if (raw !== ".") invalidPath();
  }
  return raw;
}

/** Reject every symlink component, including an in-workspace symlinked project dir. */
async function confinedDirectory(workspaceReal: string, raw: unknown): Promise<string> {
  const rel = assertRelativePath(raw);
  let current = workspaceReal;
  if (rel !== ".") {
    for (const part of rel.split("/")) {
      current = resolve(current, part);
      let info;
      try {
        info = await lstat(current);
      } catch (err) {
        if (isErrno(err, "ENOENT", "ENOTDIR", "ELOOP")) invalidPath();
        throw err;
      }
      if (info.isSymbolicLink() || !info.isDirectory()) invalidPath();
    }
  }
  const resolved = await realpath(current).catch(() => invalidPath());
  if (!inside(workspaceReal, resolved)) invalidPath();
  return resolved;
}

async function readPackageDefinition(projectDir: string, script: StudioPreviewScript): Promise<{
  packageManager: "npm" | "pnpm";
}> {
  const manifestPath = resolve(projectDir, "package.json");
  const manifestHandle = await open(
    manifestPath,
    FS_CONSTANTS.O_RDONLY | FS_CONSTANTS.O_NOFOLLOW,
  ).catch(() => invalidPath());
  let manifestText: string;
  try {
    const info = await manifestHandle.stat();
    if (!info.isFile() || info.size > 1024 * 1024) invalidPath();
    manifestText = await manifestHandle.readFile("utf8");
  } finally {
    await manifestHandle.close();
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(manifestText);
  } catch {
    throw new StudioPreviewError("invalid_script", "The project has no readable package manifest.");
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) invalidPath();
  const manifest = parsed as { scripts?: unknown; packageManager?: unknown };
  const scripts = manifest.scripts;
  if (scripts === null || typeof scripts !== "object" || Array.isArray(scripts)) {
    throw new StudioPreviewError("invalid_script", `The project does not declare "${script}".`);
  }
  const declared = (scripts as Record<string, unknown>)[script];
  if (typeof declared !== "string" || declared.trim() === "") {
    throw new StudioPreviewError("invalid_script", `The project does not declare "${script}".`);
  }
  let packageManager: "npm" | "pnpm" = "npm";
  if (manifest.packageManager !== undefined) {
    if (typeof manifest.packageManager !== "string" ||
        !/^(?:npm|pnpm)@\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$/.test(manifest.packageManager)) {
      throw new StudioPreviewError("invalid_script", "The project package manager is not supported.");
    }
    packageManager = manifest.packageManager.startsWith("pnpm@") ? "pnpm" : "npm";
  } else {
    const pnpmLock = await lstat(resolve(projectDir, "pnpm-lock.yaml"))
      .then((entry) => entry.isFile() && !entry.isSymbolicLink())
      .catch(() => false);
    if (pnpmLock) packageManager = "pnpm";
  }
  return { packageManager };
}

function packageArgv(
  packageManager: "npm" | "pnpm",
  script: StudioPreviewScript,
  host: string,
  port: number,
): string[] {
  const args = ["--host", host, "--port", String(port), "--strictPort"];
  return packageManager === "pnpm"
    ? ["pnpm", "run", script, ...args]
    : ["npm", "run", script, "--", ...args];
}

async function defaultProbe(host: string, port: number): Promise<boolean> {
  return new Promise((resolveProbe) => {
    const request = httpGet({
      host,
      port,
      path: "/",
      method: "GET",
      timeout: 1_000,
      headers: { connection: "close", host: `${host}:${port}` },
    }, (response) => {
      response.resume();
      resolveProbe(true);
    });
    request.on("timeout", () => request.destroy());
    request.on("error", () => resolveProbe(false));
  });
}

async function portIsFree(host: string, port: number): Promise<boolean> {
  return new Promise((resolvePort) => {
    const server = createServer();
    server.unref();
    server.once("error", () => resolvePort(false));
    server.listen({ host, port, exclusive: true }, () => {
      server.close((err) => resolvePort(err === undefined));
    });
  });
}

async function defaultAllocatePort(
  reserved: ReadonlySet<number>,
  limits: StudioPreviewLimits,
): Promise<number> {
  for (let port = limits.portMin; port <= limits.portMax; port++) {
    if (!reserved.has(port) && await portIsFree(limits.bindHost, port)) return port;
  }
  throw new StudioPreviewError("global_capacity", "No private preview port is available.");
}

function logPathParts(sessionDir: string, id: string): { dir: string; path: string } {
  const dir = resolve(sessionDir, ".ovid", "previews");
  return { dir, path: resolve(dir, `${id}.log`) };
}

async function createLog(sessionDir: string, id: string): Promise<{
  handle: FileHandle;
  bytes: number;
}> {
  const { dir, path } = logPathParts(sessionDir, id);
  await mkdir(dirname(dir), { recursive: true, mode: 0o700 });
  await mkdir(dir, { recursive: true, mode: 0o700 });
  for (const directory of [dirname(dir), dir]) {
    const directoryHandle = await open(
      directory,
      FS_CONSTANTS.O_RDONLY | FS_CONSTANTS.O_DIRECTORY | FS_CONSTANTS.O_NOFOLLOW,
    ).catch(() => invalidPath());
    try {
      await directoryHandle.chmod(0o700);
    } finally {
      await directoryHandle.close();
    }
  }
  const handle = await open(
    path,
    FS_CONSTANTS.O_WRONLY | FS_CONSTANTS.O_CREAT | FS_CONSTANTS.O_EXCL | FS_CONSTANTS.O_NOFOLLOW,
    0o600,
  );
  await handle.chmod(0o600);
  return { handle, bytes: 0 };
}

function enqueue(runtime: Runtime, operation: () => Promise<void>): void {
  runtime.tail = runtime.tail.then(operation, operation);
}

async function updateRuntime(
  store: StudioPreviewStore,
  runtime: Runtime,
  patch: StudioPreviewStorePatch,
): Promise<StudioPreviewRecord | null> {
  const updated = await store.update(runtime.record.id, runtime.record.generation, patch);
  if (updated !== null) runtime.record = updated;
  return updated;
}

export function createStudioPreviewManager(config: StudioPreviewManagerConfig): StudioPreviewManager {
  const limits: StudioPreviewLimits = {
    ...STUDIO_PREVIEW_DEFAULT_LIMITS,
    ...config.limits,
  };
  if (limits.bindHost !== "127.0.0.1" && limits.bindHost !== "::1") {
    throw new StudioPreviewError("invalid_bind", "Previews must bind a private loopback address.");
  }
  for (const value of [
    limits.perUser, limits.global, limits.startupMs, limits.idleMs,
    limits.absoluteMs, limits.logCapBytes, limits.portMin, limits.portMax,
  ]) {
    if (!Number.isInteger(value) || value <= 0) {
      throw new StudioPreviewError("invalid_request", "Preview limits must be positive integers.");
    }
  }
  if (limits.portMin < 20_000 || limits.portMax > 29_999 || limits.portMin > limits.portMax) {
    throw new StudioPreviewError("invalid_request", "Preview ports must stay within 20000–29999.");
  }
  if (config.workerEpoch.trim() === "") {
    throw new StudioPreviewError("invalid_request", "A stable worker epoch is required.");
  }
  const now = config.now ?? Date.now;
  const probe = config.probe ?? defaultProbe;
  const sleep = config.sleep ?? sleepDefault;
  const allocatePort = config.allocatePort ?? ((reserved: ReadonlySet<number>) =>
    defaultAllocatePort(reserved, limits));
  if (config.processes === undefined) {
    throw new StudioPreviewError("invalid_request", "A jailed preview process runner is required.");
  }
  const processes = config.processes;
  const runtimes = new Map<string, Runtime>();
  let closed = false;

  async function owned(userId: string, sessionId: string, id: string): Promise<StudioPreviewRecord | null> {
    return (await config.store.getForUser(userId, sessionId, id))[0] ?? null;
  }

  function accessExpiresAt(record: StudioPreviewRecord): string {
    const created = Date.parse(record.createdAt);
    const accessed = Date.parse(record.lastAccessAt ?? record.createdAt);
    return new Date(Math.min(accessed + limits.idleMs, created + limits.absoluteMs)).toISOString();
  }

  function withAccessExpiry(record: StudioPreviewRecord): StudioPreviewRecord {
    return { ...record, expiresAt: accessExpiresAt(record) };
  }

  function cleanupUnproven(message: string, cause?: unknown, processGroupId?: string): StudioPreviewError {
    return new StudioPreviewError("cleanup_unproven", message, {
      ...(cause !== undefined ? { cause } : {}),
      ...(processGroupId !== undefined ? { processGroupId } : {}),
    });
  }

  function lifecycleConflict(): StudioPreviewError {
    return new StudioPreviewError(
      "lifecycle_conflict",
      "Preview lifecycle is still changing. Retry the operation.",
    );
  }

  function isTerminal(record: StudioPreviewRecord): boolean {
    return !isLive(record);
  }

  async function touch(
    request: StudioPreviewTouchRequest,
    record: StudioPreviewRecord,
  ): Promise<StudioPreviewRecord | null> {
    const at = request.now?.getTime() ?? now();
    const expectedKind = request.kind ?? record.kind;
    if (
      !Number.isFinite(at) ||
      record.generation !== request.generation ||
      record.kind !== expectedKind ||
      record.status !== "running" ||
      Date.parse(accessExpiresAt(record)) <= at
    ) return null;

    // This is the DB-boolean → Record|null composition boundary. Always call
    // the atomic operation, even when the persisted row is inside its throttle
    // window; false is never cast to a record or assumed to mean denial.
    await config.store.touch({
      id: record.id,
      generation: request.generation,
      now: new Date(at).toISOString(),
    });

    // A throttle no-op and a real write both require a fresh authoritative
    // registration. Content/lifecycle changes after the pre-touch read deny.
    const authoritative = await owned(request.userId, request.sessionId, request.id);
    if (
      authoritative === null ||
      authoritative.generation !== request.generation ||
      authoritative.kind !== expectedKind ||
      authoritative.status !== "running" ||
      Date.parse(accessExpiresAt(authoritative)) <= at
    ) return null;
    const result = withAccessExpiry(authoritative);
    const runtime = runtimes.get(record.id);
    if (runtime !== undefined && runtime.record.generation === result.generation) {
      runtime.record = result;
    }
    return result;
  }

  async function closeLog(runtime: Runtime): Promise<void> {
    const handle = runtime.logHandle;
    runtime.logHandle = null;
    if (handle !== null) await handle.close().catch(() => {});
  }

  async function flushOutput(runtime: Runtime, flushAll: boolean): Promise<void> {
    if (runtime.pendingOutput === "") return;
    let text: string;
    if (flushAll) {
      text = runtime.pendingOutput + runtime.decoder.end();
      runtime.pendingOutput = "";
    } else {
      const newline = runtime.pendingOutput.lastIndexOf("\n");
      if (newline < 0) return;
      text = runtime.pendingOutput.slice(0, newline + 1);
      runtime.pendingOutput = runtime.pendingOutput.slice(newline + 1);
    }
    if (text === "") return;
    const safe = config.redact(text);
    const remaining = limits.logCapBytes - runtime.logBytes;
    const bytes = Buffer.from(safe, "utf8").subarray(0, Math.max(0, remaining));
    if (bytes.length > 0 && runtime.logHandle !== null) {
      await runtime.logHandle.write(bytes);
      runtime.logBytes += bytes.length;
      await updateRuntime(config.store, runtime, { logBytes: runtime.logBytes });
    }
  }

  function onOutput(runtime: Runtime, attempt: Attempt, chunk: Buffer): void {
    if (runtime.terminal || runtime.attempt !== attempt || runtime.outputFailure !== null) return;
    const previous = runtime.receivedBytes;
    runtime.receivedBytes += chunk.length;
    const accepted = chunk.subarray(0, Math.max(0, limits.logCapBytes + 1 - previous));
    runtime.pendingOutput += runtime.decoder.write(accepted);
    // A compact per-attempt diagnostic is enough to recognize a real bind race;
    // it is never returned to clients or written without the shared redactor.
    attempt.outputTail = (attempt.outputTail + chunk.toString("utf8")).slice(-64 * 1024);
    if (runtime.receivedBytes > limits.logCapBytes) runtime.outputFailure = "output_limit";
    enqueue(runtime, async () => {
      if (runtime.terminal) return;
      await flushOutput(runtime, runtime.outputFailure !== null);
      if (runtime.outputFailure !== null) {
        await terminateRuntime(runtime, "failed", "output_limit");
      }
    });
  }

  async function failRuntimeCleanup(
    runtime: Runtime,
    claimed: StudioPreviewRecord,
    cause?: unknown,
  ): Promise<never> {
    const marked = await config.store.update(claimed.id, claimed.generation, {
      status: "stopping",
      failureCode: "cleanup_unproven",
    }).catch(() => null);
    if (marked !== null) runtime.record = marked;
    throw cleanupUnproven(
      "Preview cleanup is unproven; the registration remains live for recovery.",
      cause,
      claimed.processGroupId ?? undefined,
    );
  }

  async function transitionStatic(
    record: StudioPreviewRecord,
    status: "stopped" | "failed" | "expired",
    failureCode: string | null,
  ): Promise<StudioPreviewRecord | null> {
    for (let attempt = 0; attempt < LIFECYCLE_ATTEMPTS; attempt++) {
      const current = await owned(record.userId, record.sessionId, record.id);
      if (current === null || isTerminal(current)) return current;
      const updated = await config.store.update(current.id, current.generation, {
        status,
        failureCode,
        endedAt: new Date(now()).toISOString(),
      });
      if (updated !== null) return updated;
    }
    throw lifecycleConflict();
  }

  /** Caller holds runtime.tail. Every success has durable terminal confirmation. */
  async function terminateRuntime(
    runtime: Runtime,
    status: "stopped" | "failed" | "expired",
    failureCode: string | null,
    exitCode: number | null = null,
  ): Promise<StudioPreviewRecord | null> {
    if (runtime.terminal && isTerminal(runtime.record)) return runtime.record;
    const expectedGroup = runtime.attempt?.process.processGroupId ?? runtime.record.processGroupId;
    for (let transition = 0; transition < LIFECYCLE_ATTEMPTS; transition++) {
      const current = await owned(runtime.record.userId, runtime.record.sessionId, runtime.record.id);
      if (current === null) {
        try {
          if (runtime.attempt !== null) await runtime.attempt.process.kill();
          else if (expectedGroup !== null) {
            await processes.killStale({ ...runtime.record, processGroupId: expectedGroup });
          }
        } catch (err) {
          throw cleanupUnproven("Preview row is missing and process cleanup is unproven.", err, expectedGroup ?? undefined);
        }
        runtime.terminal = true;
        await closeLog(runtime);
        return null;
      }
      if (isTerminal(current)) {
        runtime.record = current;
        runtime.terminal = true;
        await closeLog(runtime);
        return current;
      }
      const claimed = await config.store.update(current.id, current.generation, {
        status: "stopping",
        failureCode,
      });
      if (claimed === null) continue;
      runtime.record = claimed;
      const noSpawnEverAttempted = !runtime.spawnAttempted && claimed.processGroupId === null;
      if (!noSpawnEverAttempted && (
        expectedGroup === null ||
        claimed.processGroupId === null ||
        claimed.processGroupId !== expectedGroup
      )) {
        await failRuntimeCleanup(runtime, claimed);
      }
      try {
        if (noSpawnEverAttempted) {
          // Durable pre-spawn admission plus this runtime proves no leaf existed.
        } else if (runtime.attempt !== null) await runtime.attempt.process.kill();
        else await processes.killStale(claimed);
      } catch (err) {
        await failRuntimeCleanup(runtime, claimed, err);
      }
      try {
        await flushOutput(runtime, true);
      } catch (err) {
        await failRuntimeCleanup(runtime, claimed, err);
      }
      const terminal = await config.store.update(claimed.id, claimed.generation, {
        status,
        endedAt: new Date(now()).toISOString(),
        exitCode,
        failureCode,
      });
      if (terminal === null) continue;
      runtime.record = terminal;
      runtime.terminal = true;
      await closeLog(runtime);
      return terminal;
    }
    throw lifecycleConflict();
  }

  function onExit(runtime: Runtime, attempt: Attempt, exitCode: number | null): void {
    if (runtime.terminal || runtime.attempt !== attempt) return;
    attempt.exited = true;
    attempt.exitCode = exitCode;
    enqueue(runtime, async () => {
      if (runtime.terminal || runtime.attempt !== attempt) return;
      const current = await owned(runtime.record.userId, runtime.record.sessionId, runtime.record.id);
      if (current === null || current.status !== "running") return;
      runtime.record = current;
      await terminateRuntime(runtime, "failed", "process_exited", exitCode)
        .catch(() => closeLog(runtime));
    });
  }

  async function markRunning(runtime: Runtime, attempt: Attempt): Promise<StudioPreviewRecord> {
    for (let transition = 0; transition < LIFECYCLE_ATTEMPTS; transition++) {
      const current = await owned(runtime.record.userId, runtime.record.sessionId, runtime.record.id);
      if (current === null) throw new StudioPreviewError("preview_closed", "Preview registration disappeared.");
      if (current.processGroupId !== attempt.process.processGroupId) throw lifecycleConflict();
      if (current.status === "running") {
        runtime.record = current;
        return current;
      }
      if (isTerminal(current)) {
        runtime.record = current;
        runtime.terminal = true;
        await closeLog(runtime);
        return current;
      }
      if (current.status !== "starting") throw lifecycleConflict();
      const updated = await config.store.update(current.id, current.generation, {
        status: "running",
      });
      if (updated !== null) {
        runtime.record = updated;
        return updated;
      }
    }
    throw lifecycleConflict();
  }

  async function spawnAttempt(runtime: Runtime, port: number): Promise<Attempt> {
    const record = runtime.record;
    if (record.projectDir === null || record.startScript === null) invalidPath();
    const definition = await readPackageDefinition(record.projectDir, record.startScript);
    const rel = relative(record.workspacePath, record.projectDir).split(sep).join("/");
    const attempt = {} as Attempt;
    const earlyOutput: Buffer[] = [];
    let acceptingOutput = false;
    runtime.spawnAttempted = true;
    let process: StudioPreviewProcess;
    try {
      process = await processes.spawn({
        previewId: record.id,
        userId: record.userId,
        argv: packageArgv(definition.packageManager, record.startScript, limits.bindHost, port),
        cwd: rel === "" ? "/workspace" : `/workspace/${rel}`,
        env: {
          HOST: limits.bindHost,
          HOSTNAME: limits.bindHost,
          PORT: String(port),
          NODE_ENV: "development",
        },
        port,
        projectDir: record.projectDir,
      }, (chunk) => {
        if (acceptingOutput) onOutput(runtime, attempt, chunk);
        else earlyOutput.push(chunk);
      });
    } catch (err) {
      if (err instanceof StudioPreviewError &&
          err.code === "startup_failed" &&
          err.processGroupId === null) {
        // The runner proves its pre-Attempt cleanup succeeded in this one case.
        runtime.spawnAttempted = false;
      }
      throw err;
    }
    if (!Number.isInteger(process.processId) || process.processId <= 0 || process.processGroupId === "") {
      try {
        await process.kill();
      } catch (err) {
        throw cleanupUnproven(
          "Preview process identity is invalid and cleanup is unproven.",
          err,
          process.processGroupId || undefined,
        );
      }
      throw new StudioPreviewError("startup_failed", "The preview process has no cgroup identity.");
    }
    attempt.process = process;
    attempt.exited = false;
    attempt.exitCode = null;
    attempt.outputTail = "";
    runtime.attempt = attempt;
    acceptingOutput = true;
    for (const chunk of earlyOutput) onOutput(runtime, attempt, chunk);
    process.onExit((code) => onExit(runtime, attempt, code));
    const current = await owned(record.userId, record.sessionId, record.id);
    if (current === null || current.status !== "starting") {
      await process.kill();
      throw new StudioPreviewError("preview_closed", "Preview is no longer starting.");
    }
    runtime.record = current;
    const updated = await updateRuntime(config.store, runtime, {
      processId: process.processId,
      processGroupId: process.processGroupId,
      port,
      bindHost: limits.bindHost,
      status: "starting",
      exitCode: null,
      failureCode: null,
    });
    if (updated === null) {
      await process.kill();
      throw new StudioPreviewError("preview_closed", "The preview registration changed during startup.");
    }
    return attempt;
  }

  async function startDev(record: StudioPreviewRecord, initialPort: number): Promise<StudioPreviewRecord> {
    let log: Awaited<ReturnType<typeof createLog>>;
    try {
      const sessionDir = await config.manager.workspaceDir(record.userId, record.sessionId);
      const sessionReal = await realpath(sessionDir).catch(() => invalidPath());
      log = await createLog(sessionReal, record.id);
    } catch (err) {
      await config.store.update(record.id, record.generation, {
        status: "failed",
        failureCode: "startup_failed",
        endedAt: new Date(now()).toISOString(),
      }).catch(() => {});
      throw new StudioPreviewError("startup_failed", "Preview could not start.", { cause: err });
    }
    const runtime: Runtime = {
      record,
      attempt: null,
      spawnAttempted: false,
      logHandle: log.handle,
      logBytes: 0,
      receivedBytes: 0,
      pendingOutput: "",
      decoder: new StringDecoder("utf8"),
      outputFailure: null,
      terminal: false,
      tail: Promise.resolve(),
    };
    runtimes.set(record.id, runtime);
    enqueue(runtime, async () => {
      const reserved = new Set<number>([initialPort]);
      const deadline = Date.parse(record.createdAt) + limits.startupMs;
      let failure: "startup_timeout" | "startup_failed" = "startup_timeout";
      try {
        for (let startupAttempt = 0; startupAttempt < STARTUP_ATTEMPTS; startupAttempt++) {
          if (closed) {
            await terminateRuntime(runtime, "stopped", "shutdown");
            return;
          }
          const port = startupAttempt === 0
            ? initialPort
            : await allocatePort(new Set(reserved));
          reserved.add(port);
          const attempt = await spawnAttempt(runtime, port);
          while (now() < deadline && !runtime.terminal) {
            if (runtime.outputFailure !== null) {
              await terminateRuntime(runtime, "failed", "output_limit");
              return;
            }
            if (attempt.exited) {
              if (/\bEADDRINUSE\b/.test(attempt.outputTail) && startupAttempt + 1 < STARTUP_ATTEMPTS) {
                await attempt.process.kill();
                runtime.attempt = null;
                const retry = await updateRuntime(config.store, runtime, {
                  processId: null,
                  port: null,
                  exitCode: null,
                });
                if (retry === null) throw lifecycleConflict();
                break;
              }
              failure = "startup_failed";
              await terminateRuntime(runtime, "failed", failure, attempt.exitCode);
              return;
            }
            if (await probe(limits.bindHost, port)) {
              await markRunning(runtime, attempt);
              return;
            }
            await sleep(Math.min(100, Math.max(1, deadline - now())));
          }
          if (runtime.terminal) return;
          if (runtime.attempt === attempt && !attempt.exited) {
            await terminateRuntime(runtime, "failed", "startup_timeout");
            return;
          }
        }
        if (!runtime.terminal) await terminateRuntime(runtime, "failed", failure);
      } catch (err) {
        const preserveUnproven = async (cleanupErr: StudioPreviewError): Promise<void> => {
          const current = await owned(record.userId, record.sessionId, record.id).catch(() => null);
          if (current !== null && !isTerminal(current)) {
            const marked = await config.store.update(current.id, current.generation, {
              status: "stopping",
              failureCode: "cleanup_unproven",
              ...(cleanupErr.processGroupId !== null
                ? { processGroupId: cleanupErr.processGroupId }
                : {}),
            }).catch(() => null);
            if (marked !== null) runtime.record = marked;
          }
          if (runtime.attempt === null) runtimes.delete(record.id);
          await closeLog(runtime);
        };
        const resolveLifecycleConflict = async (): Promise<void> => {
          try {
            const resolved = await terminateRuntime(runtime, "failed", "startup_failed");
            if (resolved === null) {
              throw new StudioPreviewError("preview_closed", "Preview registration disappeared.");
            }
            if (isLive(resolved)) {
              throw cleanupUnproven(
                "Preview startup conflict did not establish terminal ownership.",
                undefined,
                runtime.attempt?.process.processGroupId,
              );
            }
            runtime.record = resolved;
          } catch (conflictErr) {
            if (conflictErr instanceof StudioPreviewError &&
                conflictErr.code === "cleanup_unproven") {
              await preserveUnproven(conflictErr);
              throw conflictErr;
            }
            if (conflictErr instanceof StudioPreviewError &&
                conflictErr.code === "lifecycle_conflict") {
              const unproven = cleanupUnproven(
                "Preview startup conflict remains recoverable for the next lifecycle sweep.",
                conflictErr,
                runtime.attempt?.process.processGroupId,
              );
              await preserveUnproven(unproven);
              throw unproven;
            }
            throw conflictErr;
          }
        };
        if (err instanceof StudioPreviewError && err.code === "cleanup_unproven") {
          await preserveUnproven(err);
          throw err;
        }
        if (err instanceof StudioPreviewError && err.code === "lifecycle_conflict") {
          await resolveLifecycleConflict();
          return;
        }
        let terminal: StudioPreviewRecord | null;
        try {
          terminal = await terminateRuntime(runtime, "failed", "startup_failed");
        } catch (cleanupErr) {
          if (cleanupErr instanceof StudioPreviewError && cleanupErr.code === "cleanup_unproven") {
            await preserveUnproven(cleanupErr);
            throw cleanupErr;
          }
          if (cleanupErr instanceof StudioPreviewError && cleanupErr.code === "lifecycle_conflict") {
            await resolveLifecycleConflict();
            return;
          }
          try {
            if (runtime.attempt !== null) await runtime.attempt.process.kill();
          } catch (killErr) {
            const unproven = cleanupUnproven(
              "Preview startup and process cleanup both failed.",
              killErr,
              runtime.attempt?.process.processGroupId,
            );
            await preserveUnproven(unproven);
            throw unproven;
          }
          const unproven = cleanupUnproven(
            "Preview startup failed before terminal registration could be confirmed.",
            cleanupErr,
            runtime.attempt?.process.processGroupId,
          );
          await preserveUnproven(unproven);
          throw new StudioPreviewError("startup_failed", "Preview could not start.", { cause: cleanupErr });
        }
        if (err instanceof StudioPreviewError && err.code === "preview_closed") throw err;
        if (terminal === null || isLive(terminal)) {
          throw new StudioPreviewError("startup_failed", "Preview could not start.", { cause: err });
        }
      }
    });
    await runtime.tail;
    return withAccessExpiry(runtime.record);
  }

  async function start(request: StudioPreviewStartRequest): Promise<StudioPreviewRecord> {
    if (closed) throw new StudioPreviewError("preview_closed", "Preview management is closed.");
    if (request === null || typeof request !== "object") {
      throw new StudioPreviewError("invalid_request", "Invalid preview definition.");
    }
    const keys = new Set(Object.keys(request));
    const allowed = request.kind === "static"
      ? new Set(["userId", "sessionId", "kind", "workspacePath"])
      : new Set(["userId", "sessionId", "kind", "projectDir", "script"]);
    if ([...keys].some((key) => !allowed.has(key)) || keys.size !== allowed.size) {
      throw new StudioPreviewError("invalid_request", "Invalid preview definition.");
    }
    if (typeof request.userId !== "string" || request.userId.trim() === "" ||
        typeof request.sessionId !== "string" || request.sessionId.trim() === "") {
      throw new StudioPreviewError("invalid_request", "Invalid preview owner.");
    }
    const attached = await config.manager.attach(request.userId);
    const workspaceReal = await realpath(attached.workspaceDir).catch(() => invalidPath());
    const attachedInfo = await stat(attached.workspaceDir).catch(() => invalidPath());
    if (!attachedInfo.isDirectory()) invalidPath();
    const at = now();
    const common = {
      id: randomUUID(),
      sessionId: request.sessionId,
      userId: request.userId,
      generation: 1,
      createdAt: new Date(at).toISOString(),
      lastAccessAt: null,
      // Durable absolute deadline. Idle expiry is derived from lastAccessAt;
      // dedicated touch must never rewrite this content/lifecycle field.
      expiresAt: new Date(at + limits.absoluteMs).toISOString(),
      endedAt: null,
      exitCode: null,
      failureCode: null,
    };
    if (request.kind === "static") {
      const staticDir = await confinedDirectory(workspaceReal, request.workspacePath);
      const created = await config.store.start({
        ...common,
        kind: "static",
        workspacePath: staticDir,
        projectDir: null,
        startScript: null,
        processId: null,
        processGroupId: null,
        workerEpoch: null,
        bindHost: null,
        port: null,
        status: "running",
        logBytes: null,
      }, { perUser: limits.perUser, global: limits.global });
      return withAccessExpiry(created);
    }
    if (request.kind !== "dev_server" || !SCRIPTS.has(request.script)) {
      throw new StudioPreviewError("invalid_script", "Choose dev, start, or preview.");
    }
    let binding: Awaited<ReturnType<StudioRunBindingPort["get"]>>;
    try {
      binding = await config.binding.get({
        userId: request.userId,
        sessionId: request.sessionId,
      });
    } catch (err) {
      if (err instanceof StudioRunBindingError) {
        throw new StudioPreviewError("no_repo", "No repository is bound to this session.");
      }
      throw err;
    }
    if (binding === null) {
      throw new StudioPreviewError("no_repo", "No repository is bound to this session.");
    }
    const boundRepo = await confinedDirectory(workspaceReal, binding.repoDir);
    const projectDir = await confinedDirectory(workspaceReal, request.projectDir);
    if (!inside(boundRepo, projectDir)) invalidPath();
    await readPackageDefinition(projectDir, request.script);
    const port = await allocatePort(new Set());
    const record = await config.store.start({
      ...common,
      kind: "dev_server",
      workspacePath: workspaceReal,
      projectDir,
      startScript: request.script,
      processId: null,
      processGroupId: null,
      workerEpoch: config.workerEpoch,
      bindHost: limits.bindHost,
      port,
      status: "starting",
      logBytes: 0,
    }, { perUser: limits.perUser, global: limits.global });
    return startDev(record, port);
  }

  async function stop(request: StudioPreviewRef): Promise<StudioPreviewRecord | null> {
    const record = await owned(request.userId, request.sessionId, request.id);
    if (record === null) return null;
    if (!isLive(record)) return record;
    const runtime = runtimes.get(record.id);
    if (runtime === undefined) {
      if (record.kind === "static") return transitionStatic(record, "stopped", null);
      if (record.workerEpoch !== config.workerEpoch) throw lifecycleConflict();
      return terminateStale(record, "stopped", null);
    }
    enqueue(runtime, async () => {
      await terminateRuntime(runtime, "stopped", null);
    });
    await runtime.tail;
    const result = await owned(request.userId, request.sessionId, request.id);
    if (result !== null && isLive(result)) throw lifecycleConflict();
    return result;
  }

  async function get(request: StudioPreviewOwner): Promise<StudioPreviewRecord[]>;
  async function get(request: StudioPreviewRef): Promise<StudioPreviewRecord | null>;
  async function get(request: StudioPreviewOwner | StudioPreviewRef): Promise<StudioPreviewRecord[] | StudioPreviewRecord | null> {
    if ("id" in request) {
      const record = await owned(request.userId, request.sessionId, request.id);
      return record === null ? null : withAccessExpiry(record);
    }
    return (await config.store.getForUser(request.userId, request.sessionId)).map(withAccessExpiry);
  }

  async function touchAuthorized(
    request: StudioPreviewTouchRequest,
  ): Promise<StudioPreviewRecord | null> {
    if (closed) return null;
    const record = await owned(request.userId, request.sessionId, request.id);
    if (record === null) return null;
    return touch(request, record);
  }

  async function logs(request: StudioPreviewRef): Promise<StudioPreviewLogs | null> {
    const record = await owned(request.userId, request.sessionId, request.id);
    if (record === null) return null;
    if (record.kind !== "dev_server" || record.logBytes === null) {
      throw new StudioPreviewError("log_unavailable", "No preview log is available.");
    }
    const sessionDir = await config.manager.workspaceDir(request.userId, request.sessionId);
    const sessionReal = await realpath(sessionDir).catch(() => invalidPath());
    const { dir } = logPathParts(sessionReal, request.id);
    const parent = await open(
      dir,
      FS_CONSTANTS.O_RDONLY | FS_CONSTANTS.O_DIRECTORY | FS_CONSTANTS.O_NOFOLLOW,
    ).catch(() => {
      throw new StudioPreviewError("log_unavailable", "No preview log is available.");
    });
    let handle: FileHandle;
    try {
      handle = await open(
        `/proc/self/fd/${parent.fd}/${request.id}.log`,
        FS_CONSTANTS.O_RDONLY | FS_CONSTANTS.O_NOFOLLOW,
      ).catch(() => {
        throw new StudioPreviewError("log_unavailable", "No preview log is available.");
      });
    } finally {
      await parent.close();
    }
    try {
      const info = await handle.stat();
      if (!info.isFile() || info.size > limits.logCapBytes) {
        throw new StudioPreviewError("log_unavailable", "No preview log is available.");
      }
      const bytes = await handle.readFile();
      return {
        text: config.redact(bytes.toString("utf8")),
        truncated: record.failureCode === "output_limit" || (record.logBytes ?? 0) >= limits.logCapBytes,
      };
    } finally {
      await handle.close();
    }
  }

  async function failStaleCleanup(
    claimed: StudioPreviewRecord,
    cause?: unknown,
  ): Promise<never> {
    await config.store.update(claimed.id, claimed.generation, {
      status: "stopping",
      failureCode: "cleanup_unproven",
    }).catch(() => {});
    throw cleanupUnproven(
      "Preview cleanup is unproven; the registration remains live for recovery.",
      cause,
      claimed.processGroupId ?? undefined,
    );
  }

  async function terminateStale(
    record: StudioPreviewRecord,
    status: "stopped" | "failed" | "expired",
    failureCode: string | null,
  ): Promise<StudioPreviewRecord | null> {
    const expectedGroup = record.processGroupId;
    for (let transition = 0; transition < LIFECYCLE_ATTEMPTS; transition++) {
      const current = await owned(record.userId, record.sessionId, record.id);
      if (current === null || isTerminal(current)) return current;
      const claimed = await config.store.update(current.id, current.generation, {
        status: "stopping",
        failureCode,
      });
      if (claimed === null) continue;
      if (
        expectedGroup === null ||
        claimed.processGroupId === null ||
        claimed.processGroupId !== expectedGroup
      ) {
        await failStaleCleanup(claimed);
      }
      try {
        await processes.killStale(claimed);
      } catch (err) {
        await failStaleCleanup(claimed, err);
      }
      const terminal = await config.store.update(claimed.id, claimed.generation, {
        status,
        failureCode,
        endedAt: new Date(now()).toISOString(),
        exitCode: null,
      });
      if (terminal !== null) return terminal;
    }
    throw lifecycleConflict();
  }

  async function sweep(limit = SWEEP_LIMIT): Promise<number> {
    if (!Number.isInteger(limit) || limit < 1 || limit > 500) {
      throw new StudioPreviewError("invalid_request", "Preview sweep limit must be between 1 and 500.");
    }
    if (closed) return 0;
    const at = now();
    const candidates = new Map<string, StudioPreviewRecord>();
    for (const record of await config.store.sweepExpired(new Date(at).toISOString(), limit)) {
      candidates.set(record.id, record);
    }
    for (const record of await config.store.getLive()) {
      const derivedExpiry = Date.parse(accessExpiresAt(record)) <= at;
      const recoverable = record.workerEpoch === config.workerEpoch &&
        (!runtimes.has(record.id) || record.failureCode === "cleanup_unproven");
      const starting = record.workerEpoch === config.workerEpoch && record.status === "starting";
      // Selection includes every owned starting row; the filter below keeps
      // the ordinary startup grace but can no longer overlook conflicts.
      if (derivedExpiry || recoverable || starting) candidates.set(record.id, record);
    }
    let completed = 0;
    for (const record of candidates.values()) {
      if (record.kind === "dev_server" && record.workerEpoch !== config.workerEpoch) continue;
      const age = at - Date.parse(record.createdAt);
      const expired = Date.parse(accessExpiresAt(record)) <= at;
      const runtime = runtimes.get(record.id);
      const recoverable = record.failureCode === "cleanup_unproven" ||
        (record.kind === "dev_server" && runtime === undefined && record.status !== "starting");
      const startupTimedOut = record.status === "starting" && age >= limits.startupMs;
      if (!expired && !recoverable && !startupTimedOut) continue;
      const failureCode = expired
        ? age >= limits.absoluteMs ? "absolute_expired" : "idle_expired"
        : startupTimedOut ? "startup_timeout" : "stale_process";
      const status = expired ? "expired" : "failed";
      let result: StudioPreviewRecord | null;
      if (runtime !== undefined) {
        enqueue(runtime, async () => {
          await terminateRuntime(runtime, status, failureCode);
        });
        await runtime.tail;
        result = await owned(record.userId, record.sessionId, record.id);
      } else if (record.kind === "static") {
        result = await transitionStatic(record, status, failureCode);
      } else {
        result = await terminateStale(record, status, failureCode);
      }
      if (result !== null && result.status === status && result.failureCode === failureCode) {
        completed++;
      }
    }
    return completed;
  }

  async function stopSession(request: StudioPreviewOwner & {
    reason: "delete" | "hibernate";
  }): Promise<number> {
    const records = await config.store.getForUser(request.userId, request.sessionId);
    const failureCode = request.reason === "delete" ? "deleted" : "hibernated";
    let stopped = 0;
    for (const record of records) {
      if (!isLive(record)) continue;
      const runtime = runtimes.get(record.id);
      let result: StudioPreviewRecord | null;
      if (runtime !== undefined) {
        enqueue(runtime, async () => {
          await terminateRuntime(runtime, "stopped", failureCode);
        });
        await runtime.tail;
        result = await owned(record.userId, record.sessionId, record.id);
      } else if (record.kind === "dev_server") {
        if (record.workerEpoch !== config.workerEpoch) throw lifecycleConflict();
        result = await terminateStale(record, "stopped", failureCode);
      } else {
        result = await transitionStatic(record, "stopped", failureCode);
      }
      if (result !== null && result.status === "stopped" && result.failureCode === failureCode) {
        stopped++;
      }
    }
    return stopped;
  }

  async function close(): Promise<void> {
    if (closed) return;
    closed = true;
    const records = await config.store.getLive();
    const failures: unknown[] = [];
    for (const record of records) {
      if (record.kind === "static") {
        try {
          const result = await transitionStatic(record, "stopped", "shutdown");
          if (result !== null && isLive(result)) failures.push(lifecycleConflict());
        } catch (err) {
          failures.push(err);
        }
        continue;
      }
      if (record.workerEpoch !== config.workerEpoch) continue;
      try {
        const runtime = runtimes.get(record.id);
        if (runtime !== undefined) {
          enqueue(runtime, async () => {
            await terminateRuntime(runtime, "stopped", "shutdown");
          });
          await runtime.tail;
          const result = await owned(record.userId, record.sessionId, record.id);
          if (result !== null && isLive(result)) failures.push(lifecycleConflict());
        } else {
          const result = await terminateStale(record, "stopped", "shutdown");
          if (result !== null && isLive(result)) failures.push(lifecycleConflict());
        }
      } catch (err) {
        failures.push(err);
      }
    }
    await Promise.allSettled([...runtimes.values()].map((runtime) => runtime.tail));
    if (failures.length > 0) {
      throw new StudioPreviewError("cleanup_unproven", "Some preview processes did not stop cleanly.", { cause: failures[0] });
    }
  }

  return { start, stop, get, touch: touchAuthorized, logs, sweep, stopSession, close };
}

// ---------------------------------------------------------------------------
// Static bytes: descriptor-pinned, no-follow traversal below a registered root.
// ---------------------------------------------------------------------------

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".wasm": "application/wasm",
};

function extension(path: string): string {
  const name = path.slice(path.lastIndexOf("/") + 1);
  const dot = name.lastIndexOf(".");
  return dot < 0 ? "" : name.slice(dot).toLowerCase();
}

export async function readStudioPreviewStatic(
  record: StudioPreviewRecord,
  rawPath: string,
): Promise<{ bytes: Buffer; contentType: string; sizeBytes: number }> {
  if (record.kind !== "static" || record.status !== "running") {
    throw new StudioPreviewError("not_running", "Preview is not running.");
  }
  if (rawPath.includes("\0") || rawPath.includes("\\") || rawPath.split("/").some((part) => part === "..")) {
    invalidPath();
  }
  const parts = rawPath.split("/").filter((part) => part !== "" && part !== ".");
  if (parts.some((part) => part.startsWith("."))) invalidPath();
  const handles: FileHandle[] = [];
  try {
    const root = await open(
      record.workspacePath,
      FS_CONSTANTS.O_RDONLY | FS_CONSTANTS.O_DIRECTORY | FS_CONSTANTS.O_NOFOLLOW,
    ).catch(() => invalidPath());
    handles.push(root);
    let current = root;
    if (parts.length === 0) parts.push("index.html");
    for (let i = 0; i < parts.length - 1; i++) {
      const next = await open(
        `/proc/self/fd/${current.fd}/${parts[i]}`,
        FS_CONSTANTS.O_RDONLY | FS_CONSTANTS.O_DIRECTORY | FS_CONSTANTS.O_NOFOLLOW,
      ).catch(() => invalidPath());
      handles.push(next);
      current = next;
    }
    const file = await open(
      `/proc/self/fd/${current.fd}/${parts.at(-1)}`,
      FS_CONSTANTS.O_RDONLY | FS_CONSTANTS.O_NOFOLLOW,
    ).catch((err) => {
      if (isErrno(err, "ENOENT")) {
        throw new StudioPreviewError("not_found", "Preview file not found.");
      }
      invalidPath();
    });
    handles.push(file);
    const info = await file.stat();
    if (!info.isFile()) invalidPath();
    if (info.size > STATIC_MAX_BYTES) {
      throw new StudioPreviewError("invalid_request", "Preview file is too large.");
    }
    const bytes = await file.readFile();
    return {
      bytes,
      contentType: MIME[extension(parts.at(-1)!)] ?? "application/octet-stream",
      sizeBytes: bytes.length,
    };
  } finally {
    for (const handle of handles.reverse()) await handle.close().catch(() => {});
  }
}

// ---------------------------------------------------------------------------
// Real jailed runner: lower-level launcher + cgroup leaves expose live stderr
// and durable cgroup identity, unlike SpawnedProcess's stdio-only MCP surface.
// ---------------------------------------------------------------------------

export interface JailedStudioPreviewProcessRunnerConfig {
  manager: Pick<SandboxManager, "attach">;
  cgroups: CgroupManager;
  launcher: JailLauncher;
  config: SandboxConfig;
  rootfs: string;
}

function leafName(previewId: string): string {
  if (!/^[a-f0-9-]{36}$/.test(previewId)) {
    throw new StudioPreviewError("invalid_request", "Invalid preview process identity.");
  }
  return `preview-${previewId}`;
}

export function createJailedStudioPreviewProcessRunner(
  deps: JailedStudioPreviewProcessRunnerConfig,
): StudioPreviewProcessRunner {
  async function expectedLeaf(record: StudioPreviewRecord): Promise<string> {
    const handle = await deps.manager.attach(record.userId);
    return deps.cgroups.leafPath(handle.uid, leafName(record.id));
  }

  async function killLeaf(path: string): Promise<void> {
    try {
      await deps.cgroups.kill(path);
    } catch (err) {
      if (!isErrno(err, "ENOENT")) throw err;
    }
  }

  return {
    async spawn(request, onOutput) {
      const handle = await deps.manager.attach(request.userId);
      const leaf = deps.cgroups.leafPath(handle.uid, leafName(request.previewId));
      await deps.cgroups.createLeaf(handle.uid, leafName(request.previewId));
      const spec = {
        rootfs: deps.rootfs,
        workspaceDir: handle.workspaceDir,
        homeDir: handle.homeDir,
        etcDir: resolve(handle.workspaceDir, "..", "etc"),
        cwd: request.cwd,
        env: request.env,
        argv: request.argv,
      };
      let child;
      try {
        child = deps.launcher.spawn(buildBwrapArgs(spec, deps.config), {
          uid: handle.uid,
          gid: handle.uid,
          cgroupProcsFile: deps.cgroups.procsFile(leaf),
          cwd: handle.workspaceDir,
        });
      } catch (err) {
        try {
          await killLeaf(leaf);
        } catch (cleanupErr) {
          throw new StudioPreviewError(
            "cleanup_unproven",
            "Preview launch failed and cgroup leaf cleanup is unproven.",
            { cause: cleanupErr, processGroupId: leaf },
          );
        }
        throw new StudioPreviewError("startup_failed", "Preview launch failed.", { cause: err });
      }
      child.stdin?.on("error", () => {});
      child.stdout?.on("data", (chunk: Buffer) => onOutput(chunk));
      child.stderr?.on("data", (chunk: Buffer) => onOutput(chunk));
      let finished = false;
      let exitCode: number | null = null;
      let killPromise: Promise<void> | undefined;
      const callbacks: Array<(code: number | null) => void> = [];
      let resolveExit!: () => void;
      const exited = new Promise<void>((resolve) => { resolveExit = resolve; });
      const finish = (code: number | null): void => {
        if (finished) return;
        finished = true;
        exitCode = code;
        // The lifecycle owner CAS-claims cleanup on this notification. Doing
        // an untracked kill here would erase the durable cgroup before the
        // owner can prove cleanup succeeded or report a cleanup failure.
        for (const callback of callbacks.splice(0)) callback(code);
        resolveExit();
      };
      child.once("exit", (code) => finish(code));
      child.once("error", () => finish(null));
      const result: StudioPreviewProcess = {
        processId: child.pid,
        processGroupId: leaf,
        onExit(callback) {
          if (finished) callback(exitCode);
          else callbacks.push(callback);
        },
        kill() {
          if (killPromise !== undefined) return killPromise;
          const pending = (async () => {
            try { child.stdin?.end(); } catch { /* already gone */ }
            await killLeaf(leaf);
            if (!finished) {
              // No PID fallback: a functioning cgroup is the only kill authority.
              await exited;
            }
          })();
          killPromise = pending;
          // Concurrent callers share one cgroup operation, but a settled call
          // (especially a rejection) must never poison later lifecycle retry.
          void pending.then(
            () => { if (killPromise === pending) killPromise = undefined; },
            () => { if (killPromise === pending) killPromise = undefined; },
          );
          return pending;
        },
      };
      return result;
    },

    async killStale(record) {
      if (record.processGroupId === null) {
        throw new StudioPreviewError("cleanup_unproven", "Preview has no cgroup identity.");
      }
      const expected = await expectedLeaf(record);
      if (resolve(record.processGroupId) !== resolve(expected)) {
        throw new StudioPreviewError("cleanup_unproven", "Preview cgroup identity does not match.");
      }
      await killLeaf(expected);
    },
  };
}
