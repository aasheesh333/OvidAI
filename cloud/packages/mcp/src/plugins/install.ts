/**
 * Atomic plugin install transaction (P5 Task 14) — the cloud port of Dart
 * plugin_runtime.dart's 8-step transaction:
 *
 *   ① resolve the source into worker staging          (phase `resolved`)
 *   ② adaptPlugin + digest                            (`normalized`)
 *   ③ grant gate: stored grant covers the requested
 *      capabilities AND matches the digest, else ask the user over the
 *      system bus (120 s default, timeout = deny)     (`pending_grant`)
 *   ④ upload the staged tree into the jail            (`deps`)
 *   ⑤ npm install inside the staging dir (--ignore-scripts unless the
 *      grant allows dependency scripts)               (`deps`)
 *   ⑥ probe every contribution file (missing → degraded, never failed)
 *   ⑦ plugins.upsert + registry.register (idempotent upsert — reinstalls
 *      re-register the same version-independent canonicalIds)   (`activate`)
 *   ⑧ COMMIT: the atomic rename staging → active (backup-dance: the prior
 *      active version is moved aside and restored if the rename fails)
 *                                                      (`committed`)
 *
 * Nothing survives a refused or failed transaction: local staging is
 * discarded (ResolvedSource.discard, idempotent), the remote staging tree is
 * removed, registry entries added by this transaction are unregistered (the
 * prior version's records restored verbatim), and the row ends
 * `rolled_back`/`failed` — or is restored to the prior version's exact state
 * when a prior install exists.
 *
 * SECRETS (P5 plan invariant, "Secrets NEVER in … plaintext columns"):
 * `plugins.manifest` persists the manifest with `${user_config.x}` REFS
 * INTACT; the resolved values are substituted only into the in-memory
 * runtime view handed to `registry.register` (and, at spawn time, the
 * sandbox env). User values live at rest only in `config_sealed`.
 *
 * STATUS VOCABULARY (plugins.status): `queued` (gateway-created, awaiting a
 * worker), `installing` (processor claim), `pending_grant`, `active`,
 * `degraded`, `failed`, `rolled_back`, `uninstalling`. Terminal states are
 * `active`, `degraded`, `failed`, `rolled_back` — a replayed job whose row is
 * already terminal must no-op (see apps/worker/src/pluginInstallProcessor.ts).
 *
 * Structural declarations (wave-merger carries, frozen lockfile):
 * - `Db` + the plugins/pluginGrants/users repo surface mirror @ovid/db
 *   member-for-member (same pattern as router.ts / oauth/flow.ts).
 * - `SandboxFiles` mirrors @ovid/sandbox's P2-revision type (R6): the
 *   WorkspaceFiles surface + uploadDir + the one-shot exec. Convert to a
 *   real `import type` when the workspace dependency can be declared.
 * - `SandboxSpawner` is the stdio transport's declared mirror.
 * - `PluginInstallJob` mirrors the plugin-installs queue contract (the
 *   @ovid/queue lane pins its zod schema member-for-member).
 */

import { randomUUID } from "node:crypto";
import { join } from "node:path";

import type { EncryptedEnvelope, EnvelopeCrypto } from "../crypto.js";
import { APPROVAL_TIMEOUT_MS, type UserSystemBus } from "../systemBus.js";
import type { SandboxSpawner } from "../transports/stdio.js";
import { WORKSPACE_ROOT, type WorkspaceFiles } from "../workspace.js";
import { adaptPlugin, pluginManifestDigest, ManifestError, type NormalizedPluginManifest, type PluginCapability } from "./manifest.js";
import { inferRequestedCapabilities } from "./capabilities.js";
import { CAPABILITY_EXPLANATIONS, grantCovers, type PluginGrantInput } from "./grants.js";
import {
  contributionsFromManifest,
  type ContributionRecord,
  type ContributionRegistry,
} from "./registry.js";
import type { PluginSourceInput, ResolvedSource } from "./sources.js";

// ---------------------------------------------------------------------------
// Job + outcome contracts
// ---------------------------------------------------------------------------

/**
 * One plugin-installs queue job. Mirrors the @ovid/queue contract (the queue
 * lane's zod schema and this interface are pinned member-for-member;
 * PluginSourceInput itself is @ovid/shared's).
 */
export interface PluginInstallJob {
  installId: string;
  userId: string;
  pluginId: string;
  mode: "install" | "uninstall";
  source?: PluginSourceInput;
}

/**
 * The transaction phases, published as `plugin_install_progress` events.
 * `pending_grant` matches the plugins.status column vocabulary — there is no
 * second name for the same state.
 */
export type InstallPhase =
  | "resolved"
  | "normalized"
  | "pending_grant"
  | "deps"
  | "probe"
  | "activate"
  | "committed"
  | "rolled_back"
  | "failed";

export interface PluginInstallOutcome {
  status: "active" | "degraded" | "failed";
  pluginId: string;
  version?: string;
  probeFailures: string[];
  reason?: string;
}

// ---------------------------------------------------------------------------
// Sandbox seam (R6 — structural mirrors; see the file header)
// ---------------------------------------------------------------------------

/** One-shot jailed exec — the transaction's npm/mv surface. */
export interface SandboxExecRequest {
  command: string;
  args: string[];
  cwd?: string;
  env?: Record<string, string>;
  timeoutMs?: number;
}

export interface SandboxExecResult {
  /** null when the one-shot was killed (timeout) — callers read that as failure. */
  exitCode: number | null;
  stdout: string;
  stderr: string;
}

/** @ovid/sandbox's P2-revision SandboxFiles: WorkspaceFiles + upload + exec. */
export interface SandboxFiles extends WorkspaceFiles {
  uploadDir(uid: string, localDir: string, remoteDir: string): Promise<void>;
  exec(uid: string, req: SandboxExecRequest): Promise<SandboxExecResult>;
}

// ---------------------------------------------------------------------------
// Paths + timeouts
// ---------------------------------------------------------------------------

/** Jail-internal active content dir for one plugin version. */
export function pluginDir(pluginId: string, version: string): string {
  return `${WORKSPACE_ROOT}/.ovid/plugins/${pluginId}/${version}`;
}

/**
 * Jail-internal staging dir for one install transaction
 * (`${pluginDir}.staging-${installId}`). The brief's template references the
 * install id, so the signature carries it.
 */
export function pluginStagingDir(pluginId: string, version: string, installId: string): string {
  return `${pluginDir(pluginId, version)}.staging-${installId}`;
}

/** Jail-internal backup dir used by the commit's rename dance. */
function pluginBackupDir(pluginId: string, version: string, installId: string): string {
  return `${pluginDir(pluginId, version)}.backup-${installId}`;
}

/** Jail-internal root of every version of one plugin (uninstall removes it). */
function pluginRootDir(pluginId: string): string {
  return `${WORKSPACE_ROOT}/.ovid/plugins/${pluginId}`;
}

/** npm install inside the jail — generous: cold registries are slow. */
export const NPM_INSTALL_TIMEOUT_MS = 300_000;

/** The commit rename + the backup dance — same-filesystem renames are fast. */
export const MV_TIMEOUT_MS = 30_000;

/**
 * Path-safety: pluginId/version/installId become jail path segments. The
 * canonical manifest identity is lowercase `[a-z0-9-_.]` segments (Task 13)
 * and versions/install ids come from manifests/uuids, but the transaction
 * refuses anything that could climb out of `.ovid/plugins` rather than
 * trusting every producer.
 */
const SAFE_PLUGIN_ID = /^[a-z0-9][a-z0-9-_.]*\/[a-z0-9][a-z0-9-_.]*$/;
const SAFE_VERSION = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const SAFE_INSTALL_ID = /^[A-Za-z0-9][A-Za-z0-9-]*$/;

/**
 * Length bounds for values that become jail path segments or row keys (M5).
 * The regexes above are unbounded, so a multi-KB id would otherwise only
 * fail deep in the seam (ENAMETOOLONG) — or create absurd paths. These are
 * the same caps @ovid/queue's pluginInstallJobSchema enforces.
 */
const MAX_PLUGIN_ID_LENGTH = 200;
const MAX_VERSION_LENGTH = 100;
const MAX_INSTALL_ID_LENGTH = 100;

// ---------------------------------------------------------------------------
// ${user_config.x} substitution (Dart plugin_user_config.dart parity)
// ---------------------------------------------------------------------------

const USER_CONFIG_REF = /\$\{user_config\.([A-Za-z0-9_.\-]+)\}/g;

/** Replaces `${user_config.<key>}` with the saved value; unknown keys stay literal. */
function substituteUserConfigValue(value: string, config: Record<string, string>): string {
  return value.replace(USER_CONFIG_REF, (match, key: string) => config[key] ?? match);
}

/**
 * Returns a manifest whose MCP server env values, MCP server header values
 * and hook commands have `${user_config.x}` resolved from the user's sealed
 * config. Unresolved references stay literal so the credential gate can
 * still detect them.
 *
 * This is the RUNTIME view only. The manifest persisted in
 * `plugins.manifest` keeps the refs intact (P5 secret invariant, C1); an
 * HTTP MCP server commonly carries its key in a header, so headers are
 * substituted here with the same refs-in-DB rule (M2 ruling).
 */
function substituteUserConfig(
  manifest: NormalizedPluginManifest,
  config: Record<string, string>,
): NormalizedPluginManifest {
  const needsIt = (v: string): boolean => v.includes("${user_config.");
  const resolveMap = (values: Record<string, string>): Record<string, string> => {
    const next: Record<string, string> = {};
    for (const [key, value] of Object.entries(values)) {
      next[key] = needsIt(value) ? substituteUserConfigValue(value, config) : value;
    }
    return next;
  };
  const mcpServers = manifest.mcpServers.map((server) => {
    const env = server.imported.env;
    const headers = server.imported.headers;
    const envNeeds = env !== undefined && Object.values(env).some(needsIt);
    const headersNeed = headers !== undefined && Object.values(headers).some(needsIt);
    if (!envNeeds && !headersNeed) return server;
    const imported = { ...server.imported };
    if (envNeeds) imported.env = resolveMap(env);
    if (headersNeed) imported.headers = resolveMap(headers);
    return { ...server, imported };
  });
  const hooks = manifest.hooks.map((hook) =>
    needsIt(hook.command)
      ? { ...hook, command: substituteUserConfigValue(hook.command, config) }
      : hook,
  );
  return { ...manifest, mcpServers, hooks };
}

// ---------------------------------------------------------------------------
// @ovid/db structural surface + lazy loader (router.ts pattern)
// ---------------------------------------------------------------------------

/** Opaque @ovid/db handle (the dependency cannot be declared this wave). */
type Db = object;

interface PluginDbRow {
  id: string;
  userId: string;
  pluginId: string;
  version: string;
  source: Record<string, unknown>;
  status: string;
  contentDir: string | null;
  manifest: Record<string, unknown> | null;
  probeFailures: Record<string, unknown>[] | null;
  configSealed: EncryptedEnvelope | null;
}

interface PluginGrantDbRow {
  userId: string;
  pluginId: string;
  capabilities: string[];
  envNames: string[];
  manifestDigest: string;
  allowDependencyScripts: boolean;
}

/** Member-for-member mirror of @ovid/db's plugins/pluginGrants/users repos. */
interface InstallerDbRepos {
  plugins: {
    upsert(db: Db, input: {
      userId: string;
      pluginId: string;
      version: string;
      source: Record<string, unknown>;
      status?: string;
      contentDir?: string | null;
      manifest?: Record<string, unknown> | null;
      probeFailures?: Record<string, unknown>[] | null;
      configSealed?: EncryptedEnvelope | null;
    }): Promise<PluginDbRow>;
    get(db: Db, id: string, uid: string): Promise<PluginDbRow | null>;
    getByPluginId(db: Db, uid: string, pluginId: string): Promise<PluginDbRow | null>;
    setStatus(
      db: Db,
      id: string,
      uid: string,
      status: string,
      extra?: {
        contentDir?: string | null;
        manifest?: Record<string, unknown> | null;
        probeFailures?: Record<string, unknown>[] | null;
        configSealed?: EncryptedEnvelope | null;
      },
    ): Promise<void>;
    remove(db: Db, id: string, uid: string): Promise<boolean>;
  };
  pluginGrants: {
    put(db: Db, input: {
      userId: string;
      pluginId: string;
      capabilities: string[];
      envNames: string[];
      manifestDigest: string;
      allowDependencyScripts?: boolean;
    }): Promise<void>;
    get(db: Db, uid: string, pluginId: string): Promise<PluginGrantDbRow | null>;
    remove(db: Db, uid: string, pluginId: string): Promise<void>;
  };
  users: { getTier(db: Db, uid: string): Promise<string> };
}

// From src/plugins/install.ts: `../../..` is cloud/packages, then db/src.
const DB_MODULE_CANDIDATES = ["../../../db/src/index.js", "../../../db/dist/index.js"];

let reposPromise: Promise<InstallerDbRepos> | undefined;

async function loadDbRepos(): Promise<InstallerDbRepos> {
  for (const spec of DB_MODULE_CANDIDATES) {
    try {
      const mod = (await import(spec)) as unknown as InstallerDbRepos;
      if (
        typeof mod.plugins?.upsert === "function" &&
        typeof mod.plugins?.setStatus === "function" &&
        typeof mod.pluginGrants?.put === "function" &&
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
      "computed dynamic import in plugins/install.ts to a declared workspace dependency " +
      "(wave-merger carry; see the file header)",
  );
}

function dbRepos(): Promise<InstallerDbRepos> {
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

function noop(): void {}

async function swallow(p: Promise<unknown>): Promise<void> {
  try {
    await p;
  } catch {
    // best-effort by design (progress events, stale-dir cleanup)
  }
}

/**
 * Best-effort cleanup that is NOT allowed to fail the caller, but must not
 * disappear silently either. Used after the commit point (I2): once the
 * content is live, a cleanup failure is logged and swallowed — it must never
 * roll a committed install back.
 */
async function swallowLogged(context: string, p: Promise<unknown>): Promise<void> {
  try {
    await p;
  } catch (err) {
    console.error(`[plugin-install] ${context} failed after commit; continuing:`, err);
  }
}

/** Exit code helper: null (killed) reads as failure. */
function failed(res: SandboxExecResult): boolean {
  return (res.exitCode ?? -1) !== 0;
}

// ---------------------------------------------------------------------------
// Installer
// ---------------------------------------------------------------------------

export interface InstallerDeps {
  db: Db;
  crypto: EnvelopeCrypto;
  systemBus: UserSystemBus;
  resolver: { resolve(input: PluginSourceInput, onProgress?: (bytes: number) => void): Promise<ResolvedSource> };
  /** Both from @ovid/sandbox (P2's revision) — see the SandboxFiles mirror. */
  sandbox: { files: SandboxFiles; spawner: SandboxSpawner };
  registry: ContributionRegistry;
  /** Grant-approval timeout; default APPROVAL_TIMEOUT_MS (120 s). */
  approvalTimeoutMs?: number;
}

export function createPluginInstaller(deps: InstallerDeps): {
  install(job: PluginInstallJob): Promise<PluginInstallOutcome>;
  uninstall(job: PluginInstallJob): Promise<void>;
} {
  const { db, crypto, systemBus, resolver, registry } = deps;
  const files = deps.sandbox.files;
  const approvalTimeoutMs = deps.approvalTimeoutMs ?? APPROVAL_TIMEOUT_MS;

  /** Fire-and-forget progress — a bus blip must never kill an install. */
  function progress(
    uid: string,
    installId: string,
    pluginId: string,
    phase: InstallPhase,
    message?: string,
  ): Promise<void> {
    const payload: Record<string, unknown> = { installId, pluginId, phase };
    if (message !== undefined) payload.message = message;
    return swallow(
      systemBus.publish(uid, {
        id: randomUUID(),
        kind: "plugin_install_progress",
        requiresResponse: false,
        payload,
      }),
    );
  }

  /** The prior row's sealed user config, decrypted (auth failure → empty). */
  async function sealedUserConfig(row: PluginDbRow | null): Promise<Record<string, string>> {
    if (row?.configSealed === null || row?.configSealed === undefined) return {};
    try {
      const parsed: unknown = JSON.parse(crypto.decrypt(row.configSealed, `plugins:${row.id}`));
      if (!isRecord(parsed)) return {};
      const out: Record<string, string> = {};
      for (const [key, value] of Object.entries(parsed)) {
        if (typeof value === "string") out[key] = value;
      }
      return out;
    } catch {
      return {}; // wrong key / tampered envelope → unresolved (literal) refs
    }
  }

  /** Every roster contribution that declares a file (the probe set). */
  function fileContributions(m: NormalizedPluginManifest): { kind: string; name: string; file: string }[] {
    const out: { kind: string; name: string; file: string }[] = [];
    for (const c of m.commands) out.push({ kind: "command", name: c.name, file: c.file });
    for (const s of m.skills) out.push({ kind: "skill", name: s.name, file: s.file });
    for (const a of m.agents) out.push({ kind: "agent", name: a.name, file: a.file });
    return out;
  }

  async function install(job: PluginInstallJob): Promise<PluginInstallOutcome> {
    const uid = job.userId;
    const r = await dbRepos();

    // ⓪ Tier gate (Review Focus 3): re-read at job START — the tier at
    // enqueue time is stale the moment a downgrade lands. Free users never
    // reach the transaction: no staging, no row writes, no events.
    const tier = await r.users.getTier(db, uid);
    if (tier === "free") {
      return { status: "failed", pluginId: job.pluginId, probeFailures: [], reason: "pro_required" };
    }
    if (job.mode !== "install") {
      return { status: "failed", pluginId: job.pluginId, probeFailures: [], reason: "missing_source" };
    }
    if (job.source === undefined) {
      return { status: "failed", pluginId: job.pluginId, probeFailures: [], reason: "missing_source" };
    }
    if (
      !SAFE_INSTALL_ID.test(job.installId) ||
      job.installId.length > MAX_INSTALL_ID_LENGTH
    ) {
      return { status: "failed", pluginId: job.pluginId, probeFailures: [], reason: "invalid_install_id" };
    }

    let resolved: ResolvedSource | undefined;
    let pluginId = job.pluginId;
    let version = "";
    let remoteStaging = "";
    let rowId: string | undefined; // set once this transaction writes the row
    let prevRow: PluginDbRow | null = null;
    let prevRecords: ContributionRecord[] = []; // registry snapshot before ⑦
    let registered = false; // this transaction's ⑦ register happened

    /**
     * Restore the row to the prior install's exact state when there was one;
     * otherwise terminalize this transaction's row. This is the ONE restore
     * path used by every failure — including failures AFTER step ⑦'s upsert
     * (I4), so the DB always describes what is live on disk (an upgrade that
     * dies in the activate/commit window leaves the prior version running,
     * so its row comes back verbatim rather than being clobbered to `failed`
     * pointing at a version dir that does not exist).
     */
    const restoreRow = async (rowStatus: "rolled_back" | "failed"): Promise<void> => {
      if (rowId === undefined) return;
      if (prevRow !== null) {
        // Prior active install survives: restore its row exactly.
        await r.plugins.upsert(db, {
          userId: uid,
          pluginId: prevRow.pluginId,
          version: prevRow.version,
          source: prevRow.source,
          status: prevRow.status,
          contentDir: prevRow.contentDir,
          manifest: prevRow.manifest,
          probeFailures: prevRow.probeFailures,
          configSealed: prevRow.configSealed,
        });
      } else {
        await r.plugins.setStatus(db, rowId, uid, rowStatus);
      }
    };

    /**
     * Failure cleanup for everything before the commit rename: local staging
     * discarded, remote staging removed, this transaction's registry entries
     * reverted (prior records restored verbatim), and the row restored to
     * the prior version's exact state — or marked rolled_back/failed when
     * there was nothing to restore.
     */
    const rollback = async (reason: string, rowStatus: "rolled_back" | "failed"): Promise<PluginInstallOutcome> => {
      if (registered) {
        registry.unregisterPlugin(pluginId, uid);
        if (prevRecords.length > 0) registry.register(prevRecords);
        registered = false;
      }
      if (resolved !== undefined) await swallow(resolved.discard());
      if (remoteStaging !== "") await swallow(files.remove(uid, remoteStaging));
      await restoreRow(rowStatus);
      await progress(uid, job.installId, pluginId, rowStatus, reason);
      return { status: "failed", pluginId, version: version || undefined, probeFailures: [], reason };
    };

    try {
      // ① Resolve the source into worker staging.
      resolved = await resolver.resolve(job.source);
      await progress(uid, job.installId, pluginId, "resolved", "source staged");

      // ② Adapt + digest.
      const manifest = await adaptPlugin(resolved.stagingDir);
      pluginId = manifest.pluginId;
      version = manifest.version;
      if (manifest.pluginId !== job.pluginId) {
        await swallow(resolved.discard());
        await progress(uid, job.installId, pluginId, "failed", "plugin_id_mismatch");
        return { status: "failed", pluginId, version, probeFailures: [], reason: "plugin_id_mismatch" };
      }
      if (
        !SAFE_PLUGIN_ID.test(pluginId) ||
        !SAFE_VERSION.test(version) ||
        pluginId.length > MAX_PLUGIN_ID_LENGTH ||
        version.length > MAX_VERSION_LENGTH
      ) {
        await swallow(resolved.discard());
        await progress(uid, job.installId, pluginId, "failed", "invalid_plugin");
        return { status: "failed", pluginId, version, probeFailures: [], reason: "invalid_plugin" };
      }
      const digest = pluginManifestDigest(manifest);
      await progress(uid, job.installId, pluginId, "normalized", "manifest adapted");

      const activeDir = pluginDir(pluginId, version);
      remoteStaging = pluginStagingDir(pluginId, version, job.installId);
      const backupDir = pluginBackupDir(pluginId, version, job.installId);

      // Snapshot the prior install (row + this user's registration) before
      // touching it. The registry is worker-global; the userId scope keeps
      // another user's records out of this transaction's snapshot/restore.
      prevRow = await r.plugins.getByPluginId(db, uid, pluginId);
      prevRecords = registry.list({ pluginId, userId: uid });

      // ③ Grant gate — NEVER auto-approved (Dart plugin_permissions parity).
      const requested = inferRequestedCapabilities(manifest);
      const stored = await r.pluginGrants.get(db, uid, pluginId);
      const storedGrant: PluginGrantInput | null = stored === null ? null : {
        capabilities: stored.capabilities as PluginCapability[],
        envNames: stored.envNames,
        manifestDigest: stored.manifestDigest,
        allowDependencyScripts: stored.allowDependencyScripts,
      };
      let allowDependencyScripts = storedGrant?.allowDependencyScripts ?? false;
      const covered =
        storedGrant !== null && grantCovers(requested, storedGrant) && storedGrant.manifestDigest === digest;
      if (!covered) {
        const row = await r.plugins.upsert(db, {
          userId: uid,
          pluginId,
          version,
          source: { ...resolved.provenance } as Record<string, unknown>,
          status: "pending_grant",
        });
        rowId = row.id;
        await progress(uid, job.installId, pluginId, "pending_grant", "approval requested");
        const response = await systemBus.request(
          uid,
          "plugin_grant_approval",
          {
            installId: job.installId,
            pluginId,
            version,
            capabilities: [...requested].sort().map((name) => ({
              name,
              explanation: CAPABILITY_EXPLANATIONS[name],
            })),
            envNames: manifest.envNames,
            allowDependencyScripts: false,
          },
          { timeoutMs: approvalTimeoutMs },
        );
        // null (timeout) and an explicit deny are the same refusal (§6.2).
        const approved = response !== null && response.payload.approve === true;
        if (!approved) {
          return await rollback("grant_denied", "rolled_back");
        }
        allowDependencyScripts = response.payload.allowDependencyScripts === true;
        await r.pluginGrants.put(db, {
          userId: uid,
          pluginId,
          capabilities: [...requested],
          envNames: manifest.envNames,
          manifestDigest: digest,
          allowDependencyScripts,
        });
      }

      // ④ Upload the staged tree into the jail.
      await files.uploadDir(uid, resolved.stagingDir, remoteStaging);

      // ⑤ Dependencies: npm install inside the jail-side staging dir.
      await progress(uid, job.installId, pluginId, "deps", "dependencies");
      const hasPackageJson = await files.stat(uid, join(remoteStaging, "package.json"));
      if (hasPackageJson !== null) {
        const res = await files.exec(uid, {
          command: "npm",
          args: [
            "install",
            "--prefix",
            remoteStaging,
            ...(allowDependencyScripts ? [] : ["--ignore-scripts"]),
          ],
          cwd: remoteStaging,
          timeoutMs: NPM_INSTALL_TIMEOUT_MS,
        });
        if (failed(res)) {
          return await rollback("deps_failed", "failed");
        }
      }

      // ⑥ Probe: every contribution file must exist in the staged tree.
      await progress(uid, job.installId, pluginId, "probe", "probing contributions");
      const probeFailures: string[] = [];
      const probeRecords: Record<string, unknown>[] = [];
      for (const contribution of fileContributions(manifest)) {
        const st = await files.stat(uid, join(remoteStaging, contribution.file));
        if (st === null) {
          probeFailures.push(contribution.file);
          probeRecords.push({ file: contribution.file, kind: contribution.kind, name: contribution.name });
        }
      }

      // ⑦ Activate: row upsert (REFS intact) + registry register (resolved
      // runtime view).
      const config = await sealedUserConfig(prevRow);
      // C1 (P5 secret invariant): persist the manifest with `${user_config.x}`
      // REFS INTACT — the resolved values never touch a plaintext column.
      // Substitution happens only in this process's runtime view, which is
      // what the registry (and later the sandbox env at spawn time) sees.
      const persistedManifest: NormalizedPluginManifest = { ...manifest, rootPath: activeDir };
      const runtimeManifest = substituteUserConfig(persistedManifest, config);
      const row = await r.plugins.upsert(db, {
        userId: uid,
        pluginId,
        version,
        source: { ...resolved.provenance } as Record<string, unknown>,
        status: probeFailures.length > 0 ? "degraded" : "active",
        contentDir: activeDir,
        manifest: persistedManifest as unknown as Record<string, unknown>,
        probeFailures: probeRecords,
        // Sealed user config carries over from the previous install (an
        // absent key leaves the stored envelope untouched — repos contract).
        configSealed: prevRow?.configSealed,
      });
      rowId = row.id;
      // IDEMPOTENT UPSERT (Task 13): reinstalling/upgrade re-registers the
      // same version-independent canonicalIds and never throws. Records are
      // user-scoped (I3) so two users installing the same plugin coexist.
      registry.register(contributionsFromManifest(runtimeManifest, uid));
      registered = true;
      await progress(uid, job.installId, pluginId, "activate", "activated");

      // ⑧ COMMIT — the atomic rename (backup dance: the prior active version
      // moves aside first and is restored if the staging rename fails, so a
      // failed upgrade never destroys the working install).
      const activeExists = await files.stat(uid, activeDir);
      if (activeExists !== null) {
        await swallow(files.remove(uid, backupDir)); // stale backup from a crashed run
        const aside = await files.exec(uid, {
          command: "mv",
          args: [activeDir, backupDir],
          timeoutMs: MV_TIMEOUT_MS,
        });
        if (failed(aside)) {
          return await rollback("rename_failed", "failed");
        }
      }
      const commit = await files.exec(uid, {
        command: "mv",
        args: [remoteStaging, activeDir],
        timeoutMs: MV_TIMEOUT_MS,
      });
      if (failed(commit)) {
        // RULING / DEVIATION (M6): the brief's test line says "registry
        // emptied" on a rename failure. That is only correct for a FRESH
        // install. On an upgrade the prior active version is untouched (and
        // was restored above when the backup dance moved it aside), so
        // emptying the registry would take a working install offline. We
        // therefore restore this user's prior records verbatim — the
        // "prior active version untouched" guarantee from the brief's step
        // ⑧ wins over its test-line shorthand. The fresh-install case does
        // end with no records (there is nothing to restore).
        if (activeExists !== null) {
          // Restore the prior active version, then clean this transaction.
          // M3: a double failure (rename AND restore) must never disappear
          // silently — the prior version is then stranded at backupDir while
          // the row/registry describe activeDir, so shout about it.
          try {
            const restored = await files.exec(uid, {
              command: "mv",
              args: [backupDir, activeDir],
              timeoutMs: MV_TIMEOUT_MS,
            });
            if (failed(restored)) {
              console.error(
                `[plugin-install] CRITICAL: backup restore failed for ${pluginId} ` +
                  `(${backupDir} -> ${activeDir}); prior version is stranded at the backup dir`,
              );
            }
          } catch (err) {
            console.error(
              `[plugin-install] CRITICAL: backup restore threw for ${pluginId} ` +
                `(${backupDir} -> ${activeDir}); prior version is stranded at the backup dir`,
              err,
            );
          }
        }
        registry.unregisterPlugin(pluginId, uid);
        if (prevRecords.length > 0) registry.register(prevRecords);
        registered = false;
        await swallow(files.remove(uid, remoteStaging));
        await swallow(resolved.discard());
        // I4: the rename failed BEFORE the commit, so what is live on disk is
        // the prior version (restored above) — restore its row verbatim
        // rather than leaving a `failed` row pointing at a dir that does not
        // exist. A fresh install (no prior row) terminalizes as `failed`.
        await restoreRow("failed");
        await progress(uid, job.installId, pluginId, "failed", "rename_failed");
        return { status: "failed", pluginId, version, probeFailures, reason: "rename_failed" };
      }

      // Success: drop the backup, drop superseded version dirs, discard the
      // local staging tree. The install is COMMITTED — a cleanup failure here
      // is logged and swallowed (I2); it must never enter the rollback path.
      if (activeExists !== null) {
        await swallowLogged(`removing backup ${backupDir}`, files.remove(uid, backupDir));
      }
      if (prevRow !== null && prevRow.version !== version) {
        await swallowLogged(
          `removing previous version ${pluginDir(pluginId, prevRow.version)}`,
          files.remove(uid, pluginDir(pluginId, prevRow.version)),
        );
      }
      await swallowLogged("discarding local staging", resolved.discard());
      await progress(uid, job.installId, pluginId, "committed", "committed");
      return {
        status: probeFailures.length > 0 ? "degraded" : "active",
        pluginId,
        version,
        probeFailures,
      };
    } catch (err) {
      // Run-level failures (bad source, unusable manifest) surface as a
      // failed outcome; infra failures rethrow after the same cleanup (the
      // processor lets infra propagate per the attempts:1 ruling).
      const runLevel =
        err instanceof ManifestError ||
        (err instanceof Error && /^(PluginSource|ArchiveUnsafe)/.test(err.name));
      await rollback(
        runLevel ? "invalid_plugin" : "install_failed",
        "failed",
      );
      if (runLevel) {
        return { status: "failed", pluginId, version: version || undefined, probeFailures: [], reason: "invalid_plugin" };
      }
      throw err;
    }
  }

  async function uninstall(job: PluginInstallJob): Promise<void> {
    const uid = job.userId;
    const r = await dbRepos();
    const pluginId = job.pluginId;
    if (!SAFE_PLUGIN_ID.test(pluginId)) return; // nothing can exist at an unsafe path

    // I3: verify ownership/row existence FIRST. A foreign or replayed
    // uninstall (no row for THIS user) must be a no-op — it must never
    // unregister another user's live contribution records. Registry entries
    // are also user-scoped, so even a row-owning uninstall only removes this
    // user's records.
    const row = await r.plugins.getByPluginId(db, uid, pluginId);
    if (row === null) return;

    // Every step below is idempotent, so a retry is safe.
    registry.unregisterPlugin(pluginId, uid);
    await files.remove(uid, pluginRootDir(pluginId));
    await r.plugins.remove(db, row.id, uid);
    await r.pluginGrants.remove(db, uid, pluginId);
  }

  return { install, uninstall };
}
