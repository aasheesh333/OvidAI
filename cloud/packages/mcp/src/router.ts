/**
 * McpRouter (P5 Task 11) — THE central P5 interface: curated shared-singleton
 * MCPs for every tier, Pro-only custom servers (stdio-in-jail / Streamable
 * HTTP / legacy SSE), model-facing `mcp__` tool naming with never-guess
 * resolution, and per-run connection lifecycle.
 *
 * Tier gate (spec G9): every gate point re-reads `users.getTier` — addServer,
 * connectForRun, listTools, resolveTool candidates and callTool. Nothing is
 * cached, so a downgrade takes effect at the next dispatch: custom connections
 * are torn down and `ProRequiredError` (`code: "pro_required"`) is thrown.
 * Curated servers keep working for Free users.
 *
 * Curated entries are provably shared singletons: the catalog owns exactly one
 * handler per curated server per process; the router adds a thin per-uid
 * McpClient over `createNativeTransport(handler, () => ctx)`, and the
 * per-call context (decrypted credentials, workspace, guarded fetch, bus,
 * sampler) is rebuilt for every request. The handler object identity never
 * changes, and per-uid clients never dispose it (the native transport's
 * close() calls handler.dispose — a shared handler must outlive any one uid).
 *
 * Sealed secrets use the Task-8 recordId convention
 * `mcp_servers:{row.id}`. Curated rows seal a flat credential map
 * (`GITHUB_TOKEN`, …); custom rows seal `{env?, headers?, oauth?}`. Plaintext
 * secrets never appear in a summary, a bus payload or an error message.
 *
 * @ovid/db is loaded through the same lazy computed dynamic import as
 * oauth/flow.ts (the workspace dependency cannot be declared in this wave);
 * the wave merger converts it to a real import.
 */

import { AsyncLocalStorage } from "node:async_hooks";
import { McpClient } from "./client.js";
import type { McpClientHooks, McpToolCallResult, McpToolDef } from "./client.js";
import type { CatalogEntry, CuratedCatalog } from "./catalog.js";
import { CURATED_IDS } from "./catalog.js";
import type { ImportedMcp } from "./configParse.js";
import { createClientRequestHandler } from "./clientRequests.js";
import type { SamplingRequest, SamplingResult } from "./clientRequests.js";
import type { EncryptedEnvelope, EnvelopeCrypto } from "./crypto.js";
import { McpReconnector } from "./backoff.js";
import type { OAuthFlow } from "./oauth/flow.js";
import type { GuardedFetch } from "./ssrf.js";
import type { UserSystemBus } from "./systemBus.js";
import type { McpTransport } from "./transport.js";
import { McpAuthRequiredError, createHttpTransport } from "./transports/http.js";
import { createNativeTransport } from "./transports/native.js";
import type { McpCallContext, NativeMcpHandler } from "./transports/native.js";
import { createSseTransport } from "./transports/sse.js";
import { createStdioTransport } from "./transports/stdio.js";
import type { SandboxSpawner } from "./transports/stdio.js";
import type { WorkspaceFiles } from "./workspace.js";
import { canonicalToolId, safeServerName, toolNameFor } from "./toolNames.js";

// ---------------------------------------------------------------------------
// Public surface
// ---------------------------------------------------------------------------

export class ProRequiredError extends Error {
  readonly code = "pro_required";

  constructor() {
    super(PRO_REQUIRED_MESSAGE);
    this.name = "ProRequiredError";
  }
}

export const PRO_REQUIRED_MESSAGE =
  "Custom MCP servers and third-party plugins are a Pro feature. Upgrade to Pro to connect your own servers and install plugins.";

/** A curated server is never tier-gated (custom servers are). */
export function isCurated(server: { curatedId: string | null }): boolean {
  return server.curatedId !== null;
}

/** Per-run context: identity plus the run's model sampler (Task 4 wiring). */
export interface RunContext {
  sessionId: string;
  runId: string;
  sampler?: (req: SamplingRequest) => Promise<SamplingResult | null>;
}

export interface McpServerSummary {
  id: string;
  name: string;
  transport: string;
  curatedId: string | null;
  enabled: boolean;
  hasSecrets: boolean;
  status: "connected" | "disconnected" | "needs_auth";
}

export interface McpToolListing {
  /** Published, model-facing name: `mcp__<safe server>__<tool>`. */
  name: string;
  /** Provider-independent id: `mcp:<serverId>/<tool>`. */
  canonicalId: string;
  serverId: string;
  curatedId: string | null;
  description?: string;
  inputSchema?: Record<string, unknown>;
}

export interface ResolvedTool {
  listing: McpToolListing;
  server: McpServerSummary;
}

export type AddServerInput = { imported: ImportedMcp } | { curatedId: string; name?: string };

/**
 * Opaque @ovid/db handle. Structural on purpose: the dependency cannot be
 * declared in this wave (same ruling as oauth/flow.ts).
 */
type Db = object;

export interface McpRouterDeps {
  db: Db;
  crypto: EnvelopeCrypto;
  catalog: CuratedCatalog;
  systemBus: UserSystemBus;
  spawner: SandboxSpawner;
  workspace: WorkspaceFiles;
  fetchImpl: GuardedFetch;
  oauth: Pick<OAuthFlow, "getAccessToken" | "start">;
  /** Default 64 simultaneous custom connections per uid (LRU-evicted). */
  maxCustomConnections?: number;
  /** Default 600_000 ms idle TTL for cached http/sse clients. */
  idleTtlMs?: number;
  now?: () => Date;
}

export interface McpRouter {
  listServers(uid: string): Promise<McpServerSummary[]>;
  addServer(uid: string, input: AddServerInput): Promise<McpServerSummary>;
  updateServer(
    uid: string,
    serverId: string,
    patch: { enabled?: boolean; secrets?: Record<string, unknown> },
  ): Promise<McpServerSummary>;
  removeServer(uid: string, serverId: string): Promise<void>;
  listTools(uid: string, runCtx?: RunContext): Promise<McpToolListing[]>;
  /**
   * The optional `runCtx` is ADDITIVE (T16 threads the active run): with it,
   * custom stdio servers are enumerated over the run's live process instead
   * of a transient spawn-and-kill.
   */
  resolveTool(uid: string, name: string, runCtx?: RunContext): Promise<ResolvedTool | null>;
  callTool(
    uid: string,
    name: string,
    args: Record<string, unknown>,
    runCtx: RunContext,
  ): Promise<McpToolCallResult>;
  connectForRun(uid: string, runCtx: RunContext): Promise<void>;
  releaseRun(uid: string, runCtx: RunContext): Promise<void>;
  shutdown(): Promise<void>;
}

// ---------------------------------------------------------------------------
// @ovid/db structural surface + lazy loader (wave-merger carry)
// ---------------------------------------------------------------------------

interface DbServerRow {
  id: string;
  userId: string;
  name: string;
  transport: string;
  curatedId: string | null;
  config: Record<string, unknown> | null;
  secretsSealed: EncryptedEnvelope | null;
  enabled: boolean;
}

interface RouterDbRepos {
  mcpServers: {
    list(db: Db, uid: string): Promise<DbServerRow[]>;
    get(db: Db, id: string, uid: string): Promise<DbServerRow | null>;
    create(
      db: Db,
      input: {
        userId: string;
        name: string;
        transport: string;
        curatedId?: string | null;
        config?: Record<string, unknown> | null;
        secretsSealed?: EncryptedEnvelope | null;
        enabled?: boolean;
      },
    ): Promise<DbServerRow>;
    update(
      db: Db,
      id: string,
      uid: string,
      patch: {
        name?: string;
        transport?: string;
        curatedId?: string | null;
        config?: Record<string, unknown> | null;
        secretsSealed?: EncryptedEnvelope | null;
        enabled?: boolean;
      },
    ): Promise<DbServerRow | null>;
    remove(db: Db, id: string, uid: string): Promise<boolean>;
    findByName(db: Db, uid: string, name: string): Promise<DbServerRow | null>;
  };
  users: { getTier(db: Db, uid: string): Promise<string> };
}

// From src/router.ts: `../..` is cloud/packages, then db/src.
const DB_MODULE_CANDIDATES = ["../../db/src/index.js", "../../db/dist/index.js"];

let reposPromise: Promise<RouterDbRepos> | undefined;

async function loadDbRepos(): Promise<RouterDbRepos> {
  for (const spec of DB_MODULE_CANDIDATES) {
    try {
      const mod = (await import(spec)) as unknown as RouterDbRepos;
      if (
        typeof mod.mcpServers?.list === "function" &&
        typeof mod.mcpServers?.create === "function" &&
        typeof mod.users?.getTier === "function"
      ) {
        return mod;
      }
    } catch {
      // try the next candidate
    }
  }
  throw new Error(
    "@ovid/db (Task 8 repos) could not be loaded — build @ovid/db, or convert the " +
      "computed dynamic import in router.ts to a declared workspace dependency " +
      "(wave-merger carry; see the file header)",
  );
}

function dbRepos(): Promise<RouterDbRepos> {
  if (reposPromise === undefined) {
    reposPromise = loadDbRepos().catch((e: unknown) => {
      reposPromise = undefined; // never cache a rejected load
      throw e;
    });
  }
  return reposPromise;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function stringMap(v: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (!isRecord(v)) return out;
  for (const [key, value] of Object.entries(v)) {
    if (typeof value === "string") out[key] = value;
  }
  return out;
}

function isUniqueViolation(err: unknown): boolean {
  let e: unknown = err;
  for (let depth = 0; depth < 5 && e instanceof Error; depth++) {
    if (/duplicate key|unique/i.test(e.message)) return true;
    e = (e as { cause?: unknown }).cause;
  }
  return false;
}

function isAuthRequired(err: unknown): boolean {
  if (err instanceof McpAuthRequiredError) return true;
  // The legacy SSE start() surfaces a plain Error for a 401.
  return err instanceof Error && /HTTP 401/.test(err.message);
}

function serverExists(): Error {
  return new Error("server_exists");
}

function notFound(): Error {
  return new Error("not_found");
}

// ---------------------------------------------------------------------------
// Internal server refs + live entries
// ---------------------------------------------------------------------------

interface ServerRef {
  uid: string;
  curated: CatalogEntry | null;
  curatedId: string | null;
  row: DbServerRow | null;
  /** Summary id / canonical-id namespace. */
  serverId: string;
  /** Name used for the published `mcp__<safe>__<tool>` prefix. */
  publishedName: string;
  transport: string;
  enabled: boolean;
}

interface LiveEntry {
  /** Run-scoped map key: `<row id>#run:<runId>` for per-run transports. */
  key: string;
  /** Run-independent identity of the server (row id / curated key). */
  baseKey: string;
  uid: string;
  kind: "curated" | "custom";
  ref: ServerRef;
  client: McpClient;
  transport: McpTransport;
  transportKind: "native" | "http" | "sse" | "stdio";
  reconnector: McpReconnector | null;
  lastUsed: number;
  /**
   * Per-run stdio/legacy-SSE connections belong to the run that spawned
   * them. Server→client requests on these transports are attributed from
   * THIS captured context, never from AsyncLocalStorage: the transport's
   * read loop is an async resource created at spawn time, so its callbacks
   * carry the spawn-time store and can never observe a later run's store.
   */
  ownerRun: RunContext | undefined;
  /** The owner run's id (release/eviction key); null for shared entries. */
  ownerRunId: string | null;
  /** The most recent run using a SHARED connection (http/native) — the
   *  fallback context for server-initiated pushes that arrive outside any
   *  call. In-call requests on those transports use the AsyncLocalStorage
   *  slot, which is exact because they are dispatched inside the call's own
   *  async chain. Documented fallback: last writer wins. */
  activeRun: RunContext | undefined;
  toolDefs: McpToolDef[] | null;
  closing: boolean;
}

interface ResolvedInternal {
  ref: ServerRef;
  def: McpToolDef;
}

const DEFAULT_MAX_CUSTOM_CONNECTIONS = 64;
const DEFAULT_IDLE_TTL_MS = 600_000;

// ---------------------------------------------------------------------------
// The router
// ---------------------------------------------------------------------------

export function createMcpRouter(deps: McpRouterDeps): McpRouter {
  const entries = new Map<string, LiveEntry>();
  const needsAuth = new Set<string>();
  /**
   * The run context of the CALL currently executing on this async chain. The
   * worker runs up to 8 jobs concurrently (per-session serialization only), so
   * a single per-uid slot would let one session's sampling request borrow
   * another session's sampler/model/API key. AsyncLocalStorage propagates
   * through the await chains that dispatch a call, including server→client
   * requests delivered while an HTTP/native response is being read.
   *
   * It is NOT sufficient across a transport read loop: stdio's stdout and
   * legacy SSE's GET stream are async resources created when the connection
   * was spawned/opened, so their callbacks carry the SPAWN-time store, not the
   * store of the run whose call is currently in flight. Per-run stdio/SSE
   * entries therefore attribute requests from their captured `ownerRun`
   * (connection ownership). Shared HTTP/native entries use this slot, with the
   * entry's `activeRun` as the documented last-writer-wins fallback for
   * out-of-band pushes.
   */
  const runStorage = new AsyncLocalStorage<RunContext>();
  let closed = false;

  /** Run `fn` with `runCtx` as the ambient context (no-op when undefined). */
  function withRun<T>(runCtx: RunContext | undefined, fn: () => Promise<T>): Promise<T> {
    return runCtx === undefined ? fn() : runStorage.run(runCtx, fn);
  }

  const maxCustom = deps.maxCustomConnections ?? DEFAULT_MAX_CUSTOM_CONNECTIONS;
  const idleTtl = deps.idleTtlMs ?? DEFAULT_IDLE_TTL_MS;

  function nowMs(): number {
    return deps.now?.()?.getTime() ?? Date.now();
  }

  /** Route a custom server's egress through the injected guarded fetch. */
  function customTransportFetch(): typeof fetch {
    return (input, init) => {
      const target =
        typeof input === "string"
          ? input
          : input instanceof URL
            ? input.toString()
            : input.url;
      return deps.fetchImpl(target, init);
    };
  }

  async function repos(): Promise<RouterDbRepos> {
    return dbRepos();
  }

  async function listRows(uid: string): Promise<DbServerRow[]> {
    return (await repos()).mcpServers.list(deps.db, uid);
  }

  async function getTier(uid: string): Promise<string> {
    // NEVER cached (G9: every gate point re-reads).
    return (await repos()).users.getTier(deps.db, uid);
  }

  function curatedKey(curatedId: string, uid: string): string {
    return `curated:${curatedId}:${uid}`;
  }

  /** Transports whose connection belongs to ONE run (see LiveEntry.ownerRun). */
  function isPerRunTransport(transport: string): boolean {
    return transport === "stdio" || transport === "sse";
  }

  function isPerRunEntry(entry: LiveEntry): boolean {
    return (
      entry.kind === "custom" &&
      (entry.transportKind === "stdio" || entry.transportKind === "sse")
    );
  }

  /** Run-independent key: curated singleton or custom row id. */
  function baseEntryKey(ref: ServerRef): string {
    return ref.curated !== null ? curatedKey(ref.curated.curatedId, ref.uid) : ref.row!.id;
  }

  /**
   * Run-scoped key. stdio and legacy SSE connections are keyed by
   * `(uid, runId)` — a run's tool call must never attach to a connection
   * spawned by a different run (the sampler/model/API key leak). Streamable
   * HTTP stays per-uid and shared: its requests are request-scoped.
   */
  function entryKeyFor(ref: ServerRef, runCtx: RunContext | undefined): string {
    const base = baseEntryKey(ref);
    if (ref.curated !== null || !isPerRunTransport(ref.transport)) return base;
    return runCtx === undefined ? base : `${base}#run:${runCtx.runId}`;
  }

  function rowEntryKey(row: DbServerRow, uid: string): string {
    return row.curatedId !== null ? curatedKey(row.curatedId, uid) : row.id;
  }

  /**
   * The live entry for `ref`. With a run, per-run transports resolve to that
   * run's incarnation exactly. Without a run (tool enumeration), the most
   * recently used connected incarnation is reused so listing does not
   * double-spawn; a run's calls never take this path.
   */
  function findLiveEntry(ref: ServerRef, runCtx: RunContext | undefined): LiveEntry | undefined {
    if (ref.curated !== null) return entries.get(baseEntryKey(ref));
    if (isPerRunTransport(ref.transport)) {
      if (runCtx !== undefined) return entries.get(entryKeyFor(ref, runCtx));
      const base = baseEntryKey(ref);
      let best: LiveEntry | undefined;
      for (const entry of entries.values()) {
        if (entry.baseKey !== base || !entry.client.connected) continue;
        if (best === undefined || entry.lastUsed > best.lastUsed) best = entry;
      }
      return best;
    }
    return entries.get(baseEntryKey(ref));
  }

  /** Drop every incarnation of one server (all runs) — update/remove. */
  async function disposeEntriesForBase(uid: string, base: string): Promise<void> {
    const doomed = [...entries.values()].filter(
      (entry) => entry.uid === uid && entry.baseKey === base,
    );
    for (const entry of doomed) await disposeEntry(entry);
  }

  // -- refs ----------------------------------------------------------------

  function curatedRef(uid: string, entry: CatalogEntry, row: DbServerRow | null): ServerRef {
    return {
      uid,
      curated: entry,
      curatedId: entry.curatedId,
      row,
      serverId: row?.id ?? `curated:${entry.curatedId}`,
      publishedName: entry.curatedId,
      transport: row?.transport ?? "native",
      enabled: row?.enabled ?? true,
    };
  }

  function customRef(uid: string, row: DbServerRow): ServerRef {
    return {
      uid,
      curated: null,
      curatedId: null,
      row,
      serverId: row.id,
      publishedName: row.name,
      transport: row.transport,
      enabled: row.enabled,
    };
  }

  /** A credential row whose curated id is no longer in the catalog: list it
   *  (so the user can delete it) but never connect or resolve it. */
  function staleCuratedRef(uid: string, row: DbServerRow): ServerRef {
    return {
      uid,
      curated: null,
      curatedId: row.curatedId,
      row,
      serverId: row.id,
      publishedName: row.name,
      transport: row.transport,
      enabled: row.enabled,
    };
  }

  /** Curated refs (catalog order) + custom rows (insertion order). */
  function buildRefs(uid: string, rows: DbServerRow[]): ServerRef[] {
    const catalog = deps.catalog.entries();
    const known = new Set(catalog.map((e) => e.curatedId));
    const refs: ServerRef[] = [];
    for (const entry of catalog) {
      const row = rows.find((r) => r.curatedId === entry.curatedId) ?? null;
      refs.push(curatedRef(uid, entry, row));
    }
    for (const row of rows) {
      if (row.curatedId === null) refs.push(customRef(uid, row));
      else if (!known.has(row.curatedId)) refs.push(staleCuratedRef(uid, row));
    }
    return refs;
  }

  function candidateRefs(uid: string, rows: DbServerRow[], tier: string): ServerRef[] {
    return buildRefs(uid, rows).filter(
      (ref) =>
        ref.enabled &&
        (ref.curated !== null || (ref.curatedId === null && tier !== "free")),
    );
  }

  function statusFor(ref: ServerRef): McpServerSummary["status"] {
    const live = findLiveEntry(ref, undefined);
    if (live !== undefined && live.client.connected) return "connected";
    const base = baseEntryKey(ref);
    if (needsAuth.has(base)) return "needs_auth";
    return "disconnected";
  }

  function summaryFor(ref: ServerRef): McpServerSummary {
    return {
      id: ref.serverId,
      name: ref.row?.name ?? ref.curatedId ?? ref.serverId,
      transport: ref.transport,
      curatedId: ref.curatedId,
      enabled: ref.enabled,
      hasSecrets: ref.row?.secretsSealed != null,
      status: statusFor(ref),
    };
  }

  // -- sealed secrets ------------------------------------------------------

  function unseal(row: DbServerRow | null): unknown {
    if (row === null || row.secretsSealed == null) return null;
    try {
      return JSON.parse(deps.crypto.decrypt(row.secretsSealed, `mcp_servers:${row.id}`)) as unknown;
    } catch {
      return null;
    }
  }

  /** Curated rows seal a flat credential map (ctx.secrets). */
  function curatedSecrets(row: DbServerRow | null): Record<string, string> {
    return stringMap(unseal(row));
  }

  /** Custom rows seal `{env?, headers?}`; a flat all-string blob is treated
   *  as env (the liberal shape an older/route-written row may carry). */
  function customSecrets(row: DbServerRow): {
    env: Record<string, string>;
    headers: Record<string, string>;
  } {
    const parsed = unseal(row);
    if (!isRecord(parsed)) return { env: {}, headers: {} };
    if (parsed.env === undefined && parsed.headers === undefined) {
      return { env: stringMap(parsed), headers: {} };
    }
    return { env: stringMap(parsed.env), headers: stringMap(parsed.headers) };
  }

  function seal(value: unknown, rowId: string): EncryptedEnvelope {
    return deps.crypto.encrypt(JSON.stringify(value), `mcp_servers:${rowId}`);
  }

  // -- per-call context + client-request wiring ---------------------------

  function callContext(ref: ServerRef, entry: LiveEntry | undefined): McpCallContext {
    const runCtx = runStorage.getStore() ?? entry?.activeRun;
    // McpCallContext still carries Task 3's permissive forward-ref
    // placeholders for the Task 4/5/10 surfaces; the real objects are what the
    // handlers consume at runtime, so adapt through the placeholder (the same
    // seam cast the worker's Task 16 adapter uses — see index.ts).
    return {
      uid: ref.uid,
      secrets: curatedSecrets(ref.row),
      workspace: deps.workspace as unknown as McpCallContext["workspace"],
      fetchImpl: deps.fetchImpl,
      systemBus: deps.systemBus as unknown as McpCallContext["systemBus"],
      sampler: runCtx?.sampler as unknown as McpCallContext["sampler"],
    };
  }

  function clientHooks(
    ref: ServerRef,
    live: () => LiveEntry | undefined,
  ): McpClientHooks {
    /**
     * Attribution of server→client requests. Per-run stdio/SSE connections
     * use their captured owner: the read loop was created at spawn time, so
     * AsyncLocalStorage there is the spawn-time (or stale) store, never the
     * calling run's. Shared HTTP/native connections are request-scoped and
     * use this call's run, falling back to the last user for out-of-band
     * pushes (documented last-writer-wins).
     */
    const runCtx = (): RunContext | undefined => {
      const entry = live();
      if (entry !== undefined && isPerRunEntry(entry)) return entry.ownerRun;
      return runStorage.getStore() ?? entry?.activeRun;
    };
    const handler = createClientRequestHandler({
      rootsProvider: () => [{ uri: "file:///workspace", name: "workspace" }],
      samplingApprover: async (req: SamplingRequest): Promise<boolean> => {
        const res = await deps.systemBus.request(ref.uid, "mcp_sampling_approval", {
          serverId: ref.serverId,
          server: ref.publishedName,
          preview: req.preview,
          maxTokens: req.maxTokens,
          modelHints: req.modelHints,
        });
        if (res === null) return false; // timeout = default-deny (§6.2)
        return res.payload.approved === true || res.payload.action === "accept";
      },
      sampler: async (req: SamplingRequest): Promise<SamplingResult | null> => {
        const sampler = runCtx()?.sampler;
        if (sampler === undefined) return null;
        return sampler(req);
      },
      elicitor: async (req) => {
        const res = await deps.systemBus.request(ref.uid, "mcp_elicitation", {
          serverId: ref.serverId,
          server: ref.publishedName,
          message: req.message,
          fields: req.fields,
          required: req.required,
        });
        if (res === null) return { action: "cancel" };
        const action = res.payload.action;
        if (action === "accept") {
          const content = res.payload.content;
          return { action: "accept", content: isRecord(content) ? content : {} };
        }
        return { action: action === "decline" ? "decline" : "cancel" };
      },
    });
    return {
      // The client calls this with the raw JSON-RPC request; bind the server
      // label so sampling/elicitation payloads identify their origin.
      onServerRequest: (req) => handler(ref.publishedName, req),
      onUnexpectedDisconnect: () => {
        live()?.reconnector?.scheduleUnexpected();
      },
    };
  }

  // -- lifecycle -----------------------------------------------------------

  async function disposeEntry(entry: LiveEntry): Promise<void> {
    entry.reconnector?.cancel();
    entry.closing = true;
    if (entries.get(entry.key) === entry) entries.delete(entry.key);
    needsAuth.delete(entry.baseKey);
    if (entry.kind === "curated") {
      // The native transport's close() disposes the SHARED handler. A per-uid
      // client must never tear down the singleton; dropping the reference is
      // enough (the in-process transport owns no OS resources).
      return;
    }
    await entry.client.close().catch(() => {});
  }

  async function teardownCustom(uid: string): Promise<void> {
    const doomed = [...entries.values()].filter((e) => e.kind === "custom" && e.uid === uid);
    for (const entry of doomed) await disposeEntry(entry);
  }

  async function sweepIdle(): Promise<void> {
    const now = nowMs();
    for (const entry of [...entries.values()]) {
      if (entry.kind !== "custom") continue;
      // Per-run stdio/SSE entries are normally released when their run ends
      // (releaseRun, wired by the worker). The idle TTL is the backstop for a
      // consumer that never calls releaseRun: no process lives until shutdown.
      if (now - entry.lastUsed > idleTtl) await disposeEntry(entry);
    }
  }

  async function enforceCustomCap(
    uid: string,
    keepKey: string,
    ownerRunId: string | null,
  ): Promise<void> {
    const custom = [...entries.values()].filter(
      (e) =>
        e.kind === "custom" &&
        e.uid === uid &&
        e.key !== keepKey &&
        // Never evict another live run's per-run connection: it is in use by
        // a concurrent call, and per-run ownership forbids cross-run reuse.
        !(isPerRunEntry(e) && e.ownerRunId !== ownerRunId),
    );
    const over = custom.length - maxCustom + 1;
    if (over <= 0) return;
    custom.sort((a, b) => a.lastUsed - b.lastUsed);
    for (let i = 0; i < over; i++) {
      const victim = custom[i];
      if (victim !== undefined) await disposeEntry(victim);
    }
  }

  function makeReconnector(entry: LiveEntry): McpReconnector {
    return new McpReconnector({
      connect: async (): Promise<boolean> => {
        if (entry.closing || closed) return false;
        // Still the live incarnation for this key? A removeServer/replacement
        // since scheduling means this attempt must do nothing.
        if (entries.get(entry.key) !== entry) return false;
        // A downgrade must not be resurrected by a crash/drop: re-read the
        // tier at the reconnect gate too (G9 — no cached tier), and tear the
        // whole custom set down if it now reads Free.
        if ((await getTier(entry.uid)) === "free") {
          await teardownCustom(entry.uid);
          return false;
        }
        // A per-run connection must be respawned under its ORIGINAL owner —
        // never under whatever run happens to trigger the retry.
        if (isPerRunEntry(entry) && entry.ownerRun === undefined) return false;
        await entry.client.close().catch(() => {});
        let fresh: LiveEntry;
        try {
          fresh = await createCustomEntry(entry.ref, entry.ownerRun);
        } catch {
          return false;
        }
        // The world may have moved while we were connecting: a concurrent
        // removeServer (or shutdown) must win — never resurrect the entry.
        if (closed || entries.get(entry.key) !== entry) {
          await disposeEntry(fresh);
          return false;
        }
        entries.set(entry.key, fresh);
        return true;
      },
    });
  }

  function buildNativeEntry(ref: ServerRef): LiveEntry {
    const catalogEntry = ref.curated!;
    const handler: NativeMcpHandler = catalogEntry.handler;
    const transport = createNativeTransport(handler, () => callContext(ref, live));
    let live: LiveEntry | undefined;
    const hooks = clientHooks(ref, () => live);
    const client = new McpClient(transport, { hooks });
    live = {
      key: entryKeyFor(ref, undefined),
      baseKey: baseEntryKey(ref),
      uid: ref.uid,
      kind: "curated",
      ref,
      client,
      transport,
      transportKind: "native",
      reconnector: null,
      lastUsed: nowMs(),
      ownerRun: undefined,
      ownerRunId: null,
      activeRun: undefined,
      toolDefs: null,
      closing: false,
    };
    return live;
  }

  async function createCustomEntry(
    ref: ServerRef,
    runCtx: RunContext | undefined,
  ): Promise<LiveEntry> {
    const row = ref.row!;
    const config = row.config ?? {};
    const secrets = customSecrets(row);
    const perRun = isPerRunTransport(row.transport);
    const key = entryKeyFor(ref, runCtx);
    const ownerRunId = perRun ? runCtx?.runId ?? null : null;

    let transport: McpTransport;
    let transportKind: LiveEntry["transportKind"];

    switch (row.transport) {
      case "http": {
        const url = requireUrl(config.url);
        transport = createHttpTransport({
          url,
          headers: secrets.headers,
          fetchImpl: customTransportFetch(),
          accessToken: () => deps.oauth.getAccessToken(ref.uid, row.id),
        });
        transportKind = "http";
        break;
      }
      case "sse": {
        const url = requireUrl(config.url);
        transport = createSseTransport({
          url,
          headers: secrets.headers,
          fetchImpl: customTransportFetch(),
          accessToken: () => deps.oauth.getAccessToken(ref.uid, row.id),
        });
        transportKind = "sse";
        break;
      }
      case "stdio": {
        const command = requireString(config.command, "command");
        const args = Array.isArray(config.args)
          ? config.args.filter((a): a is string => typeof a === "string")
          : [];
        const cwd = typeof config.cwd === "string" ? config.cwd : undefined;
        transport = createStdioTransport(deps.spawner, ref.uid, {
          command,
          args,
          env: secrets.env,
          cwd,
        });
        transportKind = "stdio";
        break;
      }
      default:
        throw new Error(`unsupported MCP transport "${row.transport}"`);
    }

    await enforceCustomCap(ref.uid, key, ownerRunId);

    let live: LiveEntry | undefined;
    const hooks = clientHooks(ref, () => live);
    const client = new McpClient(transport, { hooks });
    live = {
      key,
      baseKey: baseEntryKey(ref),
      uid: ref.uid,
      kind: "custom",
      ref,
      client,
      transport,
      transportKind,
      reconnector: null,
      lastUsed: nowMs(),
      ownerRun: perRun ? runCtx : undefined,
      ownerRunId,
      activeRun: runCtx,
      toolDefs: null,
      closing: false,
    };
    live.reconnector = makeReconnector(live);

    try {
      await transport.start();
      await client.initialize();
      if ("setProtocolVersion" in transport && typeof transport.setProtocolVersion === "function") {
        const version = client.protocolVersion;
        if (version !== null) transport.setProtocolVersion(version);
      }
      needsAuth.delete(live.baseKey);
    } catch (err) {
      if (isAuthRequired(err)) needsAuth.add(live.baseKey);
      await client.close().catch(() => {});
      throw err;
    }
    live.lastUsed = nowMs();
    return live;
  }

  async function ensureLive(ref: ServerRef, runCtx: RunContext | undefined): Promise<LiveEntry> {
    const key = entryKeyFor(ref, runCtx);
    const existing = entries.get(key);
    if (existing !== undefined) {
      if (existing.kind === "custom" && !isPerRunEntry(existing)) {
        // Shared http: cache with an idle TTL across runs.
        if (nowMs() - existing.lastUsed > idleTtl) {
          await disposeEntry(existing);
        } else if (existing.client.connected) {
          existing.lastUsed = nowMs();
          if (runCtx !== undefined) existing.activeRun = runCtx;
          return existing;
        } else {
          await disposeEntry(existing);
        }
      } else if (existing.client.connected) {
        // Per-run (the key already scopes the run) or curated. Ownership is
        // fixed at creation — never reassign it to another run — but the same
        // run may refresh its sampler for later server→client requests.
        if (runCtx !== undefined && isPerRunEntry(existing)) {
          existing.ownerRun = runCtx;
          existing.activeRun = runCtx;
        }
        existing.lastUsed = nowMs();
        return existing;
      } else {
        await disposeEntry(existing);
      }
    }

    const entry =
      ref.curated !== null
        ? buildNativeEntry(ref)
        : await createCustomEntry(ref, runCtx);

    if (ref.curated !== null) {
      await entry.transport.start();
      await entry.client.initialize();
    }
    if (runCtx !== undefined) entry.activeRun = runCtx;
    entries.set(entry.key, entry);
    return entry;
  }

  // -- tool defs / listings ------------------------------------------------

  async function listDefs(entry: LiveEntry, refresh: boolean): Promise<McpToolDef[]> {
    if (refresh || entry.toolDefs === null) {
      entry.toolDefs = await entry.client.listTools();
    }
    return entry.toolDefs;
  }

  /**
   * A custom stdio/legacy-SSE server without a run: open a throwaway
   * connection just to enumerate. Both transports are per-run, so with no run
   * there is no connection a listing may legitimately attach to.
   */
  async function transientCustomDefs(ref: ServerRef): Promise<McpToolDef[]> {
    const row = ref.row!;
    const config = row.config ?? {};
    const secrets = customSecrets(row);
    let transport: McpTransport;
    switch (row.transport) {
      case "stdio": {
        transport = createStdioTransport(deps.spawner, ref.uid, {
          command: requireString(config.command, "command"),
          args: Array.isArray(config.args)
            ? config.args.filter((a): a is string => typeof a === "string")
            : [],
          env: secrets.env,
          cwd: typeof config.cwd === "string" ? config.cwd : undefined,
        });
        break;
      }
      case "sse": {
        transport = createSseTransport({
          url: requireUrl(config.url),
          headers: secrets.headers,
          fetchImpl: customTransportFetch(),
          accessToken: () => deps.oauth.getAccessToken(ref.uid, row.id),
        });
        break;
      }
      default:
        throw new Error(`unsupported MCP transport "${row.transport}"`);
    }
    const client = new McpClient(transport, {
      hooks: clientHooks(ref, () => undefined),
    });
    try {
      await transport.start();
      await client.initialize();
      return await client.listTools();
    } finally {
      await client.close().catch(() => {});
    }
  }

  async function refToolDefs(
    ref: ServerRef,
    runCtx: RunContext | undefined,
    refresh = false,
  ): Promise<McpToolDef[]> {
    // Prefer an ALREADY-LIVE connection (this run's stdio/SSE incarnation, a
    // cached http client, or — for run-less enumeration — any live per-run
    // incarnation). Without this, every resolveTool call would transient-spawn
    // a second jailed process and T16's resolveTool → callTool flow would
    // spawn twice per tool call.
    const live = findLiveEntry(ref, runCtx);
    const reusable = live !== undefined && live.client.connected;
    const perRunCustom = ref.curated === null && isPerRunTransport(ref.transport);
    if (perRunCustom && runCtx === undefined && !reusable) {
      return transientCustomDefs(ref);
    }
    const entry = reusable ? live! : await ensureLive(ref, runCtx);
    if (reusable && runCtx !== undefined) {
      if (isPerRunEntry(entry)) entry.ownerRun = runCtx;
      else entry.activeRun = runCtx;
    }
    return listDefs(entry, refresh);
  }

  function listingFor(ref: ServerRef, def: McpToolDef): McpToolListing {
    return {
      name: toolNameFor(ref.publishedName, def.name),
      canonicalId: canonicalToolId(ref.serverId, def.name),
      serverId: ref.serverId,
      curatedId: ref.curatedId,
      ...(def.description !== undefined ? { description: def.description } : {}),
      ...(def.inputSchema !== undefined ? { inputSchema: def.inputSchema } : {}),
    };
  }

  // -- resolution ----------------------------------------------------------

  function publishedPrefix(ref: ServerRef): string {
    return `mcp__${safeServerName(ref.publishedName)}__`;
  }

  function canonicalPrefix(ref: ServerRef): string {
    return `mcp:${ref.serverId}/`;
  }

  async function resolveAmong(
    refs: ServerRef[],
    name: string,
    runCtx: RunContext | undefined,
  ): Promise<ResolvedInternal | null> {
    // 1. Exact published name.
    const published = refs.filter((ref) => name.startsWith(publishedPrefix(ref)));
    if (published.length > 1) return null; // ambiguous — never guess
    if (published.length === 1) {
      const ref = published[0]!;
      const raw = name.slice(publishedPrefix(ref).length);
      const defs = await refToolDefs(ref, runCtx).catch(() => [] as McpToolDef[]);
      const def = defs.find((d) => d.name === raw);
      return def === undefined ? null : { ref, def };
    }

    // 2. Exact canonical id.
    const canonical = refs.filter((ref) => name.startsWith(canonicalPrefix(ref)));
    if (canonical.length > 1) return null;
    if (canonical.length === 1) {
      const ref = canonical[0]!;
      const raw = name.slice(canonicalPrefix(ref).length);
      const defs = await refToolDefs(ref, runCtx).catch(() => [] as McpToolDef[]);
      const def = defs.find((d) => d.name === raw);
      return def === undefined ? null : { ref, def };
    }

    // 3. UNIQUE bare alias across the candidate servers.
    let match: ResolvedInternal | null = null;
    let count = 0;
    for (const ref of refs) {
      const defs = await refToolDefs(ref, runCtx).catch(() => [] as McpToolDef[]);
      const def = defs.find((d) => d.name === name);
      if (def !== undefined) {
        count++;
        match = { ref, def };
        if (count > 1) return null;
      }
    }
    return count === 1 ? match : null;
  }

  /** Which custom server (if any) does this name belong to? Prefix/canonical
   *  attribution needs no connection; bare aliases only consult LIVE custom
   *  clients (a Free user's server is never dialed just to reject a call). */
  async function attributeCustom(
    uid: string,
    rows: DbServerRow[],
    name: string,
  ): Promise<DbServerRow | null> {
    for (const row of rows) {
      if (row.curatedId !== null) continue;
      if (name.startsWith(`mcp__${safeServerName(row.name)}__`)) return row;
      if (name.startsWith(`mcp:${row.id}/`)) return row;
    }
    for (const entry of entries.values()) {
      if (entry.kind !== "custom" || entry.uid !== uid) continue;
      let defs = entry.toolDefs;
      if (defs === null && entry.client.connected) {
        defs = await entry.client.listTools().catch(() => null);
      }
      if (defs?.some((d) => d.name === name)) return entry.ref.row;
    }
    return null;
  }

  // -- server lookup -------------------------------------------------------

  /**
   * True when a custom row named `name` would publish a prefix that collides
   * with a curated server or with another custom row. Comparison is on the
   * SANITIZED form (what the model actually sees), so "Fetch", "fetch!" and
   * "fetch" are all the same namespace. Curated credential rows are skipped:
   * they always publish their catalog curatedId, never their row name.
   */
  function namespaceTaken(rows: DbServerRow[], name: string): boolean {
    const safe = safeServerName(name);
    if (safe === "") return true; // unpublishable name
    // CURATED_IDS is pure data — no handler is instantiated by this check.
    if (CURATED_IDS.some((id) => safeServerName(id) === safe)) return true;
    return rows.some(
      (r) => r.curatedId === null && safeServerName(r.name) === safe,
    );
  }

  function findRow(rows: DbServerRow[], serverId: string): DbServerRow | null {
    if (serverId.startsWith("curated:")) {
      const curatedId = serverId.slice("curated:".length);
      return rows.find((r) => r.curatedId === curatedId) ?? null;
    }
    return rows.find((r) => r.id === serverId) ?? null;
  }

  // -- public API ----------------------------------------------------------

  return {
    async listServers(uid: string): Promise<McpServerSummary[]> {
      const rows = await listRows(uid);
      return buildRefs(uid, rows).map(summaryFor);
    },

    async addServer(uid: string, input: AddServerInput): Promise<McpServerSummary> {
      const rows = await listRows(uid);

      if ("curatedId" in input) {
        const entry = deps.catalog.get(input.curatedId);
        if (entry === undefined) throw new Error("unknown_curated_id");
        if (rows.some((r) => r.curatedId === input.curatedId)) throw serverExists();
        const name = input.name?.trim() || input.curatedId;
        if (rows.some((r) => r.name === name)) throw serverExists();
        let row: DbServerRow;
        try {
          row = await (await repos()).mcpServers.create(deps.db, {
            userId: uid,
            name,
            transport: "native",
            curatedId: input.curatedId,
            config: null,
            secretsSealed: null,
          });
        } catch (err) {
          if (isUniqueViolation(err)) throw serverExists();
          throw err;
        }
        return summaryFor(curatedRef(uid, entry, row));
      }

      // Custom servers are Pro-only (no caching: tier read per gate point).
      if ((await getTier(uid)) === "free") throw new ProRequiredError();

      const imported = input.imported;
      validateImported(imported);
      if (rows.some((r) => r.name === imported.name)) throw serverExists();
      // Reserve the published namespace, not just the exact row name: the
      // model-facing id is mcp__<safe name>__, so a custom "fetch" would
      // shadow the curated fetch (and two rows can sanitize to one prefix).
      // Reject rather than silently namespace: never guess which one wins.
      if (namespaceTaken(rows, imported.name)) throw serverExists();

      const config: Record<string, unknown> = { type: imported.transport };
      if (imported.url !== undefined) config.url = imported.url;
      if (imported.command !== undefined) config.command = imported.command;
      if (imported.args !== undefined) config.args = [...imported.args];
      if (imported.cwd !== undefined) config.cwd = imported.cwd;

      const secrets: Record<string, unknown> = {};
      if (imported.env !== undefined && Object.keys(imported.env).length > 0) {
        secrets.env = imported.env;
      }
      if (imported.headers !== undefined && Object.keys(imported.headers).length > 0) {
        secrets.headers = imported.headers;
      }
      if (imported.oauth !== undefined) secrets.oauth = imported.oauth;
      const hasSecrets = Object.keys(secrets).length > 0;

      let row: DbServerRow;
      try {
        row = await (await repos()).mcpServers.create(deps.db, {
          userId: uid,
          name: imported.name,
          transport: imported.transport,
          curatedId: null,
          config,
          // The recordId needs the generated row id: create, then seal.
          secretsSealed: null,
        });
      } catch (err) {
        if (isUniqueViolation(err)) throw serverExists();
        throw err;
      }
      if (hasSecrets) {
        const updated = await (await repos()).mcpServers.update(deps.db, row.id, uid, {
          secretsSealed: seal(secrets, row.id),
        });
        if (updated !== null) row = updated;
      }
      return summaryFor(customRef(uid, row));
    },

    async updateServer(
      uid: string,
      serverId: string,
      patch: { enabled?: boolean; secrets?: Record<string, unknown> },
    ): Promise<McpServerSummary> {
      const rows = await listRows(uid);
      let row = findRow(rows, serverId);

      // PATCH on a curated synthetic id (no credential row yet): materialize
      // the credential row rather than 404-ing the unconfigured catalog entry.
      if (row === null && serverId.startsWith("curated:")) {
        const curatedId = serverId.slice("curated:".length);
        const entry = deps.catalog.get(curatedId);
        if (entry === undefined) throw notFound();
        try {
          row = await (await repos()).mcpServers.create(deps.db, {
            userId: uid,
            name: curatedId,
            transport: "native",
            curatedId,
            config: null,
            secretsSealed: null,
          });
        } catch (err) {
          if (isUniqueViolation(err)) throw serverExists();
          throw err;
        }
      }
      if (row === null) throw notFound();

      const fields: {
        enabled?: boolean;
        secretsSealed?: EncryptedEnvelope;
      } = {};
      if (patch.enabled !== undefined) fields.enabled = patch.enabled;
      if (patch.secrets !== undefined) {
        fields.secretsSealed = seal(patch.secrets, row.id);
      }

      const updated =
        Object.keys(fields).length === 0
          ? row
          : await (await repos()).mcpServers.update(deps.db, row.id, uid, fields);
      if (updated === null) throw notFound();

      const base = rowEntryKey(updated, uid);
      const liveEntries = [...entries.values()].filter(
        (entry) => entry.uid === uid && entry.baseKey === base,
      );
      if (updated.curatedId !== null) {
        // The native ctx provider reads entry.ref.row on every call, so a
        // credential refresh needs no reconnect (and must not dispose the
        // shared handler).
        for (const live of liveEntries) live.ref.row = updated;
      } else if (patch.enabled === false || patch.secrets !== undefined) {
        // Transport env/headers changed: reconnect on next use. Drop every
        // per-run incarnation, not just whichever key was looked up.
        await disposeEntriesForBase(uid, base);
      }

      if (updated.curatedId !== null) {
        const entry = deps.catalog.get(updated.curatedId);
        if (entry !== undefined) return summaryFor(curatedRef(uid, entry, updated));
      }
      return summaryFor(customRef(uid, updated));
    },

    async removeServer(uid: string, serverId: string): Promise<void> {
      const rows = await listRows(uid);
      const row = findRow(rows, serverId);
      const key = row !== null ? rowEntryKey(row, uid) : serverId.startsWith("curated:")
        ? curatedKey(serverId.slice("curated:".length), uid)
        : serverId;

      // A custom stdio/SSE server may have one live incarnation per run.
      await disposeEntriesForBase(uid, key);

      if (row === null) throw notFound();
      // Curated: this deletes only the user's credential row; the catalog
      // entry itself is process-wide and stays available.
      await (await repos()).mcpServers.remove(deps.db, row.id, uid);
    },

    async listTools(uid: string, runCtx?: RunContext): Promise<McpToolListing[]> {
      return withRun(runCtx, async () => {
        await sweepIdle();
        const tier = await getTier(uid);
        // A downgrade takes effect immediately: no custom connection may
        // survive (and none may be dialed) once the user is Free.
        if (tier === "free") await teardownCustom(uid);
        const rows = await listRows(uid);
        const listings: McpToolListing[] = [];
        for (const ref of candidateRefs(uid, rows, tier)) {
          try {
            const defs = await refToolDefs(ref, runCtx, true);
            for (const def of defs) listings.push(listingFor(ref, def));
          } catch {
            // One unreachable server must not hide every other server's tools.
          }
        }
        return listings;
      });
    },

    async resolveTool(
      uid: string,
      name: string,
      runCtx?: RunContext,
    ): Promise<ResolvedTool | null> {
      return withRun(runCtx, async () => {
        await sweepIdle();
        const tier = await getTier(uid);
        if (tier === "free") await teardownCustom(uid);
        const rows = await listRows(uid);
        const refs = candidateRefs(uid, rows, tier);
        const resolved = await resolveAmong(refs, name, runCtx);
        if (resolved === null) return null;
        return {
          listing: listingFor(resolved.ref, resolved.def),
          server: summaryFor(resolved.ref),
        };
      });
    },

    async callTool(
      uid: string,
      name: string,
      args: Record<string, unknown>,
      runCtx: RunContext,
    ): Promise<McpToolCallResult> {
      return withRun(runCtx, async () => {
        await sweepIdle();
        const tier = await getTier(uid);
        const rows = await listRows(uid);

        // Gate BEFORE any custom connection is attempted: a Free user (or a
        // downgraded one) never dials a custom server just to be refused.
        // Teardown FIRST, so attributeCustom's live-client scan has nothing to
        // dial (prefix/canonical attribution needs no connection).
        if (tier === "free") {
          await teardownCustom(uid);
          if ((await attributeCustom(uid, rows, name)) !== null) {
            throw new ProRequiredError();
          }
        }

        const refs = candidateRefs(uid, rows, tier);
        const resolved = await resolveAmong(refs, name, runCtx);
        if (resolved === null) throw new Error(`unknown MCP tool: ${name}`);

        if (resolved.ref.curated === null) {
          // Re-read the tier immediately before dispatch: a downgrade that
          // landed during resolution still refuses this call.
          if ((await getTier(uid)) === "free") {
            await teardownCustom(uid);
            throw new ProRequiredError();
          }
        }

        const entry = await ensureLive(resolved.ref, runCtx);
        entry.lastUsed = nowMs();
        return entry.client.callTool(resolved.def.name, args);
      });
    },

    async connectForRun(uid: string, runCtx: RunContext): Promise<void> {
      return withRun(runCtx, async () => {
        await sweepIdle();
        const tier = await getTier(uid);
        const rows = await listRows(uid);

        // A downgrade takes effect immediately: no Pro connection survives.
        if (tier === "free") await teardownCustom(uid);

        for (const ref of candidateRefs(uid, rows, tier)) {
          try {
            await ensureLive(ref, runCtx);
          } catch {
            // Per-server failure (needs_auth, unreachable, bad config) must
            // not fail the whole run; statusFor reports it.
          }
        }
      });
    },

    async releaseRun(uid: string, runCtx: RunContext): Promise<void> {
      for (const entry of [...entries.values()]) {
        if (entry.uid !== uid) continue;
        if (isPerRunEntry(entry) && entry.ownerRunId === runCtx.runId) {
          // This run's stdio process / legacy-SSE stream: kill it now. The
          // next run spawns a fresh connection under its own key.
          await disposeEntry(entry);
        } else if (entry.activeRun?.runId === runCtx.runId) {
          // Drop the run's sampler closure (it may capture the model
          // transport and API key) as soon as the run is over. Cached
          // http/native connections stay, but no longer carry this run.
          entry.activeRun = undefined;
        }
      }
    },

    async shutdown(): Promise<void> {
      if (closed) return;
      closed = true;
      const disposedHandlers = new Set<NativeMcpHandler>();
      for (const entry of [...entries.values()]) {
        entry.reconnector?.cancel();
        entry.closing = true;
        if (entry.kind === "custom") {
          await entry.client.close().catch(() => {});
        } else {
          // Close one per-uid client per shared handler at most: close()
          // calls handler.dispose(), and a singleton disposes once.
          const handler = entry.ref.curated?.handler;
          if (handler !== undefined && !disposedHandlers.has(handler)) {
            disposedHandlers.add(handler);
            await entry.client.close().catch(() => {});
          }
        }
      }
      entries.clear();
      needsAuth.clear();
    },
  };
}

// ---------------------------------------------------------------------------
// addServer validation
// ---------------------------------------------------------------------------

function requireString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`invalid_config: missing ${field}`);
  }
  return value;
}

function requireUrl(value: unknown): string {
  const url = requireString(value, "url");
  try {
    new URL(url);
  } catch {
    throw new Error("invalid_config: invalid url");
  }
  return url;
}

function validateImported(imported: ImportedMcp): void {
  if (typeof imported.name !== "string" || imported.name.trim() === "") {
    throw new Error("invalid_config: missing name");
  }
  if (imported.transport === "stdio") {
    requireString(imported.command, "command");
    return;
  }
  if (imported.transport === "http" || imported.transport === "sse") {
    requireUrl(imported.url);
    return;
  }
  throw new Error(`invalid_config: unsupported transport "${String(imported.transport)}"`);
}
