/**
 * Plugin install transaction (P5 Task 14) — the 8-step atomic install into
 * the sandbox + contribution registry, ported from Dart plugin_runtime.dart
 * and cloud-adapted per the brief.
 *
 * Gated on TEST_DATABASE_URL (real plugins/pluginGrants/users repos over the
 * shared dev Postgres; idempotent migrate only — parallel lanes share it).
 * Fakes: the source resolver (a fixture tree copied into a fresh mkdtemp
 * staging), SandboxFiles (an in-memory remote tree with recorded one-shot
 * exec, `mv` implemented as a real subtree move), the system bus
 * (auto-responding approvals) and the spawner (never reached — the
 * transaction's exec is the SandboxFiles one-shot). adaptPlugin, the digest,
 * capability inference, grants and the registry are Task 13's REAL
 * implementations.
 */

import { afterAll, beforeAll, describe, expect, it, vi } from "vitest";
import { cp, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

import { createDb, migrate } from "../../../db/src/client.js";
import { pluginGrants, plugins } from "../../../db/src/repos.js";
import { users } from "../../../db/src/schema.js";
import { createEnvelopeCrypto } from "../crypto.js";
import type { UserSystemBus } from "../systemBus.js";
import { adaptPlugin, pluginContentDigest, pluginManifestDigest } from "./manifest.js";
import { inferRequestedCapabilities } from "./capabilities.js";
import { createContributionRegistry } from "./registry.js";
import type { ContributionRegistry } from "./registry.js";
import { createSourceResolver, PASTE_PLUGIN_VERSION } from "./sources.js";
import {
  createPluginInstaller,
  pluginDir,
  type PluginInstallOutcome,
  type SandboxExecRequest,
  type SandboxFiles,
} from "./install.js";
import type { PluginSourceInput, ResolvedSource } from "./sources.js";

const TEST_DATABASE_URL = process.env.TEST_DATABASE_URL;
const MASTER_KEY_HEX = "ab7d31c4e59f60a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071829";

// ---------------------------------------------------------------------------
// Fixture trees (Claude-Code bundle shape — the adapter's documented input)
// ---------------------------------------------------------------------------

function ccManifest(over: Record<string, unknown> = {}): string {
  return JSON.stringify({
    name: "demo",
    version: "1.0.0",
    author: { name: "acme" },
    ...over,
  });
}

function mcpJson(env: Record<string, string>): string {
  return JSON.stringify({
    mcpServers: {
      bar: { command: "node", args: ["server.js"], env },
    },
  });
}

/** The base bundle: one command file + one stdio MCP server (env refs). */
const BASE_FILES: Record<string, string> = {
  ".claude-plugin/plugin.json": ccManifest(),
  "commands/foo.md": "# foo\n",
  ".mcp.json": mcpJson({
    API_KEY: "${user_config.api_key}",
    OTHER: "${user_config.missing_key}",
  }),
};

/** Digest-changing variant: same contributions, one more env reference. */
const EXTRA_ENV_FILES: Record<string, string> = {
  ...BASE_FILES,
  ".mcp.json": mcpJson({
    API_KEY: "${user_config.api_key}",
    OTHER: "${user_config.missing_key}",
    EXTRA: "${DEPLOY_ENV}",
  }),
};

/** Bundle with a package.json → the deps phase runs `npm install`. */
const WITH_PACKAGE_JSON_FILES: Record<string, string> = {
  ...BASE_FILES,
  "package.json": JSON.stringify({ name: "demo", version: "1.0.0", private: true }),
};

/**
 * Probe-failure setup: the base bundle uploaded MINUS one contribution file
 * (a partial upload is exactly what the probe defends against — the adapter
 * only discovers files that exist, so the drop is simulated at the seam).
 */

async function writeFixture(files: Record<string, string>): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "plugin-install-fixture-"));
  for (const [rel, content] of Object.entries(files)) {
    const target = join(dir, rel);
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, content);
  }
  return dir;
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

interface FakeExecCall {
  uid: string;
  command: string;
  args: string[];
  cwd?: string;
  env?: Record<string, string>;
  timeoutMs?: number;
}

type ExecResult = { exitCode: number | null; stdout: string; stderr: string };

/** In-memory remote tree + recorded one-shot exec (`mv` really moves). */
class FakeFiles implements SandboxFiles {
  readonly remote = new Map<string, { type: "file" | "dir"; content?: string; size: number; mtime: string }>();
  readonly execCalls: FakeExecCall[] = [];
  /** Per-call override; returning a result short-circuits the default. */
  execHandler: ((call: FakeExecCall) => ExecResult | undefined) | undefined;
  /** When set, uploadDir silently drops this workspace-relative file. */
  dropFile: string | undefined;
  /** When set, uploadDir throws (M4 failure injection). */
  uploadError: Error | undefined;
  /** When set and it returns an Error for a path, stat() throws (M4). */
  statHandler: ((path: string) => Error | undefined) | undefined;

  private touch(path: string, type: "file" | "dir", content?: string): void {
    this.remote.set(path, {
      type,
      content,
      size: content === undefined ? 0 : Buffer.byteLength(content),
      mtime: new Date().toISOString(),
    });
    // Materialize ancestor dir entries so list() works.
    const parent = dirname(path);
    if (parent !== "/" && parent !== "." && !this.remote.has(parent)) {
      this.touch(parent, "dir");
    }
  }

  async uploadDir(uid: string, localDir: string, remoteDir: string): Promise<void> {
    if (this.uploadError !== undefined) throw this.uploadError;
    const walk = async (abs: string, rel: string): Promise<void> => {
      for (const ent of await readdir(abs, { withFileTypes: true })) {
        const childRel = rel === "" ? ent.name : `${rel}/${ent.name}`;
        if (ent.isDirectory()) {
          this.touch(`${remoteDir}/${childRel}`, "dir");
          await walk(join(abs, ent.name), childRel);
        } else if (ent.isFile()) {
          if (childRel === this.dropFile) continue;
          const content = await readFile(join(abs, ent.name), "utf8");
          this.touch(`${remoteDir}/${childRel}`, "file", content);
        }
      }
    };
    this.touch(remoteDir, "dir");
    await walk(localDir, "");
  }

  async read(uid: string, path: string) {
    const e = this.remote.get(path);
    return e !== undefined && e.type === "file"
      ? { content: e.content ?? "", bytes: e.size }
      : null;
  }

  async write(uid: string, path: string, content: string): Promise<void> {
    this.touch(path, "file", content);
  }

  async list(uid: string, dir: string) {
    const prefix = dir.endsWith("/") ? dir : `${dir}/`;
    const out: { name: string; type: "file" | "dir"; size: number; mtime: string }[] = [];
    for (const [path, entry] of this.remote) {
      if (!path.startsWith(prefix)) continue;
      const rest = path.slice(prefix.length);
      if (rest.length === 0 || rest.includes("/")) continue;
      out.push({ name: rest, type: entry.type, size: entry.size, mtime: entry.mtime });
    }
    return out;
  }

  async stat(uid: string, path: string) {
    const thrown = this.statHandler?.(path);
    if (thrown !== undefined) throw thrown;
    const e = this.remote.get(path);
    return e === undefined ? null : { type: e.type, size: e.size, mtime: e.mtime };
  }

  async remove(uid: string, path: string): Promise<void> {
    for (const key of [...this.remote.keys()]) {
      if (key === path || key.startsWith(`${path}/`)) this.remote.delete(key);
    }
  }

  /** Moves a subtree (the fake's mv semantics — a real rename moves nodes). */
  private mv(from: string, to: string): void {
    for (const key of [...this.remote.keys()]) {
      if (key !== from && !key.startsWith(`${from}/`)) continue;
      const rel = key === from ? "" : key.slice(from.length + 1);
      const target = rel === "" ? to : `${to}/${rel}`;
      this.remote.set(target, this.remote.get(key)!);
      this.remote.delete(key);
    }
  }

  async exec(uid: string, req: SandboxExecRequest): Promise<ExecResult> {
    const call: FakeExecCall = { uid, ...req };
    this.execCalls.push(call);
    const override = this.execHandler?.(call);
    if (override !== undefined) return override;
    if (call.command === "mv" && call.args.length === 2) this.mv(call.args[0]!, call.args[1]!);
    return { exitCode: 0, stdout: "", stderr: "" };
  }

  /** Test helpers. */
  hasPrefix(prefix: string): boolean {
    for (const key of this.remote.keys()) {
      if (key === prefix || key.startsWith(`${prefix}/`)) return true;
    }
    return false;
  }

  paths(): string[] {
    return [...this.remote.keys()];
  }
}

interface BusEvent {
  uid: string;
  kind: string;
  requiresResponse: boolean;
  payload: Record<string, unknown>;
}

/** Auto-responding system bus: records everything, answers approvals. */
class FakeBus implements UserSystemBus {
  readonly published: BusEvent[] = [];
  readonly requests: { uid: string; kind: string; payload: Record<string, unknown>; opts?: { timeoutMs?: number } }[] = [];
  answer: (payload: Record<string, unknown>) => Record<string, unknown> | null = () => ({ approve: true });

  async publish(
    uid: string,
    event: { kind: string; requiresResponse?: boolean; payload: Record<string, unknown> },
  ): Promise<void> {
    this.published.push({
      uid,
      kind: event.kind,
      requiresResponse: event.requiresResponse ?? false,
      payload: event.payload,
    });
  }

  async request(
    uid: string,
    kind: string,
    payload: Record<string, unknown>,
    opts?: { timeoutMs?: number },
  ): Promise<{ id: string; payload: Record<string, unknown> } | null> {
    this.requests.push({ uid, kind, payload, opts });
    const a = this.answer(payload);
    return a === null ? null : { id: "fake-response", payload: a };
  }

  async close(): Promise<void> {}

  /** Every payload that ever crossed the bus (hygiene assertions). */
  allPayloads(): Record<string, unknown>[] {
    return [...this.published.map((p) => p.payload), ...this.requests.map((r) => r.payload)];
  }

  phases(): string[] {
    return this.published
      .filter((p) => p.kind === "plugin_install_progress")
      .map((p) => p.payload.phase as string);
  }
}

/** Serves fixture trees into fresh mkdtemp stagings; discard rm -rf's. */
function fakeResolver(
  serve: () => string,
  opts: { discardError?: Error } = {},
): {
  resolver: { resolve(input: PluginSourceInput, onProgress?: (bytes: number) => void): Promise<ResolvedSource> };
  stagings: string[];
} {
  const stagings: string[] = [];
  return {
    stagings,
    resolver: {
      async resolve(input: PluginSourceInput): Promise<ResolvedSource> {
        const staging = await mkdtemp(join(tmpdir(), "plugin-install-staging-"));
        await cp(serve(), staging, { recursive: true });
        stagings.push(staging);
        return {
          stagingDir: staging,
          bytes: 4096,
          provenance: { kind: input.kind },
          discard: async () => {
            await rm(staging, { recursive: true, force: true });
            if (opts.discardError !== undefined) throw opts.discardError;
          },
        };
      },
    },
  };
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

let db: ReturnType<typeof createDb>;
let crypto: ReturnType<typeof createEnvelopeCrypto>;

const installers: { uninstall(job: { installId: string; userId: string; pluginId: string; mode: "install" | "uninstall"; source?: PluginSourceInput }): Promise<void> }[] = [];

function testUid(prefix: string): string {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

async function seedUser(tier: "free" | "pro"): Promise<string> {
  const uid = testUid("plugininst");
  await db.insert(users).values({ uid, email: `u-${uid.slice(0, 16)}@test.local`, tier });
  return uid;
}

interface Harness {
  uid: string;
  files: FakeFiles;
  bus: FakeBus;
  registry: ReturnType<typeof createContributionRegistry>;
  job: (over?: Partial<PluginInstallJobLike>) => PluginInstallJobLike;
  install: (over?: Partial<PluginInstallJobLike>) => Promise<PluginInstallOutcome>;
  uninstall: (over?: Partial<PluginInstallJobLike>) => Promise<void>;
}

interface PluginInstallJobLike {
  installId: string;
  userId: string;
  pluginId: string;
  mode: "install" | "uninstall";
  source?: PluginSourceInput;
}

/**
 * Full world: seeded user + fixture-backed installer. `serve` picks the
 * fixture served to each resolve (single-fixture tests pass () => fixture).
 */
async function makeHarness(
  files: Record<string, string> | string,
  over: {
    tier?: "free" | "pro";
    busAnswer?: (payload: Record<string, unknown>) => Record<string, unknown> | null;
    execHandler?: FakeFiles["execHandler"];
    uploadError?: Error;
    statHandler?: FakeFiles["statHandler"];
    discardError?: Error;
    registry?: ContributionRegistry;
    registryWrapper?: (base: ContributionRegistry) => ContributionRegistry;
  } = {},
): Promise<Harness> {
  const fixture = typeof files === "string" ? files : await writeFixture(files);
  const uid = await seedUser(over.tier ?? "pro");
  return makeInstallerFor(uid, () => fixture, over);
}

/** Installer over an existing uid (multi-install tests). */
async function makeInstallerFor(
  uid: string,
  serve: () => string,
  over: {
    busAnswer?: (payload: Record<string, unknown>) => Record<string, unknown> | null;
    execHandler?: FakeFiles["execHandler"];
    uploadError?: Error;
    statHandler?: FakeFiles["statHandler"];
    discardError?: Error;
    registry?: ContributionRegistry;
    registryWrapper?: (base: ContributionRegistry) => ContributionRegistry;
  } = {},
): Promise<Harness> {
  const { resolver } = fakeResolver(serve, {
    ...(over.discardError !== undefined ? { discardError: over.discardError } : {}),
  });
  const files = new FakeFiles();
  if (over.execHandler !== undefined) files.execHandler = over.execHandler;
  if (over.uploadError !== undefined) files.uploadError = over.uploadError;
  if (over.statHandler !== undefined) files.statHandler = over.statHandler;
  const bus = new FakeBus();
  if (over.busAnswer !== undefined) bus.answer = over.busAnswer;
  const baseRegistry = over.registry ?? createContributionRegistry();
  const registry =
    over.registryWrapper !== undefined
      ? over.registryWrapper(baseRegistry)
      : baseRegistry;
  const installer = createPluginInstaller({
    db,
    crypto,
    systemBus: bus,
    resolver,
    sandbox: {
      files,
      spawner: {
        spawn: async () => {
          throw new Error("install transaction never spawns long-running processes");
        },
      },
    },
    registry,
    approvalTimeoutMs: 200,
  });
  installers.push(installer);
  const job = (jover: Partial<PluginInstallJobLike> = {}): PluginInstallJobLike => ({
    installId: `install-${testUid("id")}`,
    userId: uid,
    pluginId: "acme/demo",
    mode: "install",
    source: { kind: "paste", label: "fixture", config: "{}" },
    ...jover,
  });
  return {
    uid,
    files,
    bus,
    registry,
    job,
    install: (iover: Partial<PluginInstallJobLike> = {}) => installer.install(job(iover)),
    uninstall: (uover: Partial<PluginInstallJobLike> = {}) =>
      installer.uninstall({ ...job(uover), mode: "uninstall" }),
  };
}

/** Pre-seeds a covering grant for the fixture (skips the approval flow). */
async function seedCoveringGrant(uid: string, fixtureDir: string, allowDependencyScripts = false): Promise<void> {
  const manifest = await adaptPlugin(fixtureDir);
  await pluginGrants.put(db, {
    userId: uid,
    pluginId: manifest.pluginId,
    capabilities: [...inferRequestedCapabilities(manifest)],
    envNames: manifest.envNames,
    manifestDigest: pluginManifestDigest(manifest, await pluginContentDigest(manifest)),
    allowDependencyScripts,
  });
}

/** Stages a previous-install row carrying a sealed user config. */
async function seedSealedConfig(uid: string, config: Record<string, string>): Promise<string> {
  const first = await plugins.upsert(db, {
    userId: uid,
    pluginId: "acme/demo",
    version: "0.9.0",
    source: { kind: "seed" },
    status: "active",
  });
  // Re-seal under the row's real id (recordId convention plugins:{id}).
  await plugins.upsert(db, {
    userId: uid,
    pluginId: "acme/demo",
    version: "0.9.0",
    source: { kind: "seed" },
    status: "active",
    configSealed: crypto.encrypt(JSON.stringify(config), `plugins:${first.id}`),
  });
  return first.id;
}

describe.skipIf(!TEST_DATABASE_URL)("plugin installer (atomic transaction)", () => {
  beforeAll(async () => {
    const url = TEST_DATABASE_URL!;
    await migrate(url);
    db = createDb(url);
    crypto = createEnvelopeCrypto(MASTER_KEY_HEX);
  }, 60_000);

  afterAll(async () => {
    await db?.$client.end({ timeout: 5 });
  });

  // -------------------------------------------------------------------------

  it("happy path: phases in order, row active, registry populated, content at pluginDir", async () => {
    const w = await makeHarness(BASE_FILES);
    // Covering grant against the same fixture the resolver serves.
    const fixtureCopy = await writeFixture(BASE_FILES);
    await seedCoveringGrant(w.uid, fixtureCopy);

    const out = await w.install();

    expect(out.status).toBe("active");
    expect(out.pluginId).toBe("acme/demo");
    expect(out.version).toBe("1.0.0");
    expect(out.probeFailures).toEqual([]);

    // Phases in order (no grant phase — the stored grant covers).
    expect(w.bus.phases()).toEqual(["resolved", "normalized", "deps", "probe", "activate", "committed"]);

    // Row active with the committed content dir.
    const row = await plugins.getByPluginId(db, w.uid, "acme/demo");
    expect(row).not.toBeNull();
    expect(row!.status).toBe("active");
    expect(row!.contentDir).toBe(pluginDir("acme/demo", "1.0.0"));
    expect((row!.manifest as { rootPath?: string }).rootPath).toBe(pluginDir("acme/demo", "1.0.0"));

    // Registry populated with the canonical ids.
    const ids = w.registry.list({ pluginId: "acme/demo" }).map((r) => r.canonicalId).sort();
    expect(ids).toContain("plugin:acme/demo/command:foo");
    expect(ids).toContain("plugin:acme/demo/mcp:bar");

    // Content committed at pluginDir; no staging path survived the rename.
    expect(w.files.hasPrefix(pluginDir("acme/demo", "1.0.0"))).toBe(true);
    const content = await w.files.read(w.uid, `${pluginDir("acme/demo", "1.0.0")}/commands/foo.md`);
    expect(content?.content).toBe("# foo\n");
    for (const key of w.files.paths()) {
      expect(key.includes(".staging-")).toBe(false);
    }
  });

  it("no stored grant → pending_grant + approval payload carries explanations, never a secret; approve → grant row persisted", async () => {
    const w = await makeHarness(BASE_FILES);
    const out = await w.install({ installId: "inst-approval-1" });

    expect(out.status).toBe("active");
    expect(w.bus.phases()).toEqual(
      ["resolved", "normalized", "pending_grant", "deps", "probe", "activate", "committed"],
    );

    // The approval request: install/plugin ids, capability sheet with
    // explanations, env NAMES, and the dependency-scripts switch OFF.
    expect(w.bus.requests.length).toBe(1);
    const req = w.bus.requests[0]!;
    expect(req.kind).toBe("plugin_grant_approval");
    expect(req.payload.pluginId).toBe("acme/demo");
    expect(req.payload.version).toBe("1.0.0");
    expect(req.payload.installId).toBe("inst-approval-1");
    expect(req.payload.allowDependencyScripts).toBe(false);
    const capabilities = req.payload.capabilities as { name: string; explanation: string }[];
    expect(capabilities.length).toBeGreaterThan(0);
    for (const cap of capabilities) {
      expect(cap.name).toBeTruthy();
      expect(cap.explanation.length).toBeGreaterThan(0);
    }
    expect(Array.isArray(req.payload.envNames)).toBe(true);

    // Grant row persisted with the manifest digest (sha256 hex).
    const grant = await pluginGrants.get(db, w.uid, "acme/demo");
    expect(grant).not.toBeNull();
    expect(grant!.manifestDigest).toMatch(/^sha256:[0-9a-f]{64}$/);
    expect(grant!.allowDependencyScripts).toBe(false);
  });

  it("approval timeout (bus returns null) → rolled_back, outcome failed grant_denied, no dir, no registry entries, no grant row", async () => {
    const w = await makeHarness(BASE_FILES, { busAnswer: () => null });
    const out = await w.install();

    expect(out.status).toBe("failed");
    expect(out.reason).toBe("grant_denied");

    const row = await plugins.getByPluginId(db, w.uid, "acme/demo");
    expect(row!.status).toBe("rolled_back");

    expect(w.files.remote.size).toBe(0);
    expect(w.registry.list({ pluginId: "acme/demo" })).toEqual([]);
    expect(await pluginGrants.get(db, w.uid, "acme/demo")).toBeNull();
    expect(w.bus.phases()).toContain("rolled_back");
  });

  it("deny response → same as timeout", async () => {
    const w = await makeHarness(BASE_FILES, { busAnswer: () => ({ approve: false }) });
    const out = await w.install();

    expect(out.status).toBe("failed");
    expect(out.reason).toBe("grant_denied");
    const row = await plugins.getByPluginId(db, w.uid, "acme/demo");
    expect(row!.status).toBe("rolled_back");
    expect(w.files.remote.size).toBe(0);
    expect(w.registry.list({ pluginId: "acme/demo" })).toEqual([]);
    expect(await pluginGrants.get(db, w.uid, "acme/demo")).toBeNull();
  });

  it("digest change on reinstall forces re-approval; commit + idempotent re-register (count unchanged)", async () => {
    const first = await writeFixture(BASE_FILES);
    const second = await writeFixture(EXTRA_ENV_FILES);
    const uid = await seedUser("pro");
    let resolveCount = 0;
    const w = await makeInstallerFor(uid, () => (resolveCount += 1) > 1 ? second : first);

    // First install: approval requested and granted.
    const out1 = await w.install();
    expect(out1.status).toBe("active");
    expect(w.bus.requests.length).toBe(1);
    const countAfterFirst = w.registry.list().length;
    expect(countAfterFirst).toBeGreaterThan(0);

    // Second install (changed manifest → new digest): re-approval.
    const out2 = await w.install();
    expect(out2.status).toBe("active");
    expect(w.bus.requests.length).toBe(2);
    expect(w.bus.requests[1]!.payload.pluginId).toBe("acme/demo");

    // The same canonicalIds re-register idempotently — no throw, count unchanged.
    expect(w.registry.list().length).toBe(countAfterFirst);
    const row = await plugins.getByPluginId(db, uid, "acme/demo");
    expect(row!.status).toBe("active");

    // The grant now carries the NEW digest.
    const m2 = await adaptPlugin(second);
    const grant = await pluginGrants.get(db, uid, "acme/demo");
    expect(grant!.manifestDigest).toBe(
      pluginManifestDigest(m2, await pluginContentDigest(m2)),
    );
  });

  it("deps: npm install --ignore-scripts by default; without the flag on an allowDependencyScripts approval; failure → rolled_back, staging gone, prior row untouched", async () => {
    // (a) default: --ignore-scripts present, install commits.
    const wa = await makeHarness(WITH_PACKAGE_JSON_FILES, {
      busAnswer: () => ({ approve: true, allowDependencyScripts: false }),
    });
    const outa = await wa.install();
    expect(outa.status).toBe("active");
    const npm = wa.files.execCalls.find((c) => c.command === "npm");
    expect(npm).toBeDefined();
    expect(npm!.args).toContain("install");
    expect(npm!.args).toContain("--ignore-scripts");
    expect(npm!.args).toContain("--prefix");
    expect(npm!.cwd).toBeDefined();

    // (b) approved scripts: no --ignore-scripts.
    const wb = await makeHarness(WITH_PACKAGE_JSON_FILES, {
      busAnswer: () => ({ approve: true, allowDependencyScripts: true }),
    });
    const outb = await wb.install();
    expect(outb.status).toBe("active");
    const npm2 = wb.files.execCalls.find((c) => c.command === "npm");
    expect(npm2).toBeDefined();
    expect(npm2!.args).not.toContain("--ignore-scripts");
    // The approval's choice is persisted on the grant row.
    const grantB = await pluginGrants.get(db, wb.uid, "acme/demo");
    expect(grantB!.allowDependencyScripts).toBe(true);

    // (c) npm exits non-zero: the transaction rolls back, the prior active
    // version's row is untouched (still v1, active).
    const fixtureV1 = await writeFixture(BASE_FILES);
    const fixtureV2 = await writeFixture({
      ...WITH_PACKAGE_JSON_FILES,
      ".claude-plugin/plugin.json": ccManifest({ version: "2.0.0" }),
    });
    const uid = await seedUser("pro");
    let resolveCount = 0;
    const wc = await makeInstallerFor(uid, () => (resolveCount += 1) > 1 ? fixtureV2 : fixtureV1, {
      execHandler: (call) =>
        call.command === "npm" ? { exitCode: 1, stdout: "", stderr: "EPERM" } : undefined,
    });

    const outA = await wc.install();
    expect(outA.status).toBe("active");
    const rowA = await plugins.getByPluginId(db, uid, "acme/demo");
    expect(rowA!.version).toBe("1.0.0");
    expect(rowA!.status).toBe("active");

    const outB = await wc.install();
    expect(outB.status).toBe("failed");
    // Staging gone (remote)…
    for (const key of wc.files.paths()) {
      expect(key.includes(".staging-")).toBe(false);
    }
    // …prior version row untouched: still v1, active, at its content dir.
    const rowB = await plugins.getByPluginId(db, uid, "acme/demo");
    expect(rowB!.version).toBe("1.0.0");
    expect(rowB!.status).toBe("active");
    expect(rowB!.contentDir).toBe(pluginDir("acme/demo", "1.0.0"));
    expect(wc.files.hasPrefix(pluginDir("acme/demo", "1.0.0"))).toBe(true);
    expect(wc.files.hasPrefix(pluginDir("acme/demo", "2.0.0"))).toBe(false);
  });

  it("probe: missing contribution file → degraded + probeFailures lists it (commit still happens)", async () => {
    const fixture = await writeFixture(BASE_FILES);
    const uid = await seedUser("pro");
    await seedCoveringGrant(uid, fixture);
    const w = await makeInstallerFor(uid, () => fixture);
    // The upload drops one contribution file: the probe must catch it and
    // degrade the install WITHOUT failing the commit.
    w.files.dropFile = "commands/foo.md";

    const out = await w.install();
    expect(out.status).toBe("degraded");
    expect(out.probeFailures.length).toBe(1);
    expect(out.probeFailures[0]!).toContain("commands/foo.md");

    // Commit still happened.
    expect(w.bus.phases()).toContain("committed");
    expect(w.files.hasPrefix(pluginDir("acme/demo", "1.0.0"))).toBe(true);
    const row = await plugins.getByPluginId(db, uid, "acme/demo");
    expect(row!.status).toBe("degraded");
    expect(row!.probeFailures).not.toBeNull();
    expect(row!.probeFailures!.length).toBe(1);
  });

  it("rename failure → registry restored to prior version, row failed, prior active version still present and registered", async () => {
    const fixtureV1 = await writeFixture(BASE_FILES);
    const fixtureV2 = await writeFixture({
      ...BASE_FILES,
      ".claude-plugin/plugin.json": ccManifest({ version: "2.0.0" }),
    });
    const uid = await seedUser("pro");
    let resolveCount = 0;
    let commitMvCount = 0;
    const w = await makeInstallerFor(uid, () => (resolveCount += 1) > 1 ? fixtureV2 : fixtureV1, {
      // Fail exactly the SECOND transaction's COMMIT mv (staging → active);
      // the first install and any backup-restore mv still succeed.
      execHandler: (call) => {
        if (call.command !== "mv" || !call.args[0]!.includes(".staging-")) return undefined;
        commitMvCount += 1;
        return commitMvCount > 1 ? { exitCode: 1, stdout: "", stderr: "rename failed" } : undefined;
      },
    });

    const outA = await w.install();
    expect(outA.status).toBe("active");
    const v1Records = w.registry.list({ pluginId: "acme/demo" });
    expect(v1Records.length).toBeGreaterThan(0);
    for (const r of v1Records) expect(r.rootPath).toBe(pluginDir("acme/demo", "1.0.0"));

    const outB = await w.install();
    expect(outB.status).toBe("failed");
    expect(outB.reason).toBe("rename_failed");

    // Prior active version still present (dir)…
    expect(w.files.hasPrefix(pluginDir("acme/demo", "1.0.0"))).toBe(true);
    expect(w.files.hasPrefix(pluginDir("acme/demo", "2.0.0"))).toBe(false);
    // …still registered (records restored to the v1 rootPath)…
    const restored = w.registry.list({ pluginId: "acme/demo" });
    expect(restored.length).toBe(v1Records.length);
    for (const r of restored) expect(r.rootPath).toBe(pluginDir("acme/demo", "1.0.0"));
    // …row restored to the prior version verbatim (I4): the DB now matches
    // what is live on disk instead of claiming a failed 2.0.0 install whose
    // contentDir does not exist.
    const row = await plugins.getByPluginId(db, uid, "acme/demo");
    expect(row!.version).toBe("1.0.0");
    expect(row!.status).toBe("active");
    expect(row!.contentDir).toBe(pluginDir("acme/demo", "1.0.0"));
    for (const key of w.files.paths()) {
      expect(key.includes(".staging-")).toBe(false);
      expect(key.includes(".backup-")).toBe(false);
    }
  });

  it("rename failure on a FRESH install → row failed (nothing prior to restore)", async () => {
    const w = await makeHarness(BASE_FILES, {
      execHandler: (call) =>
        call.command === "mv" && call.args[0]!.includes(".staging-")
          ? { exitCode: 1, stdout: "", stderr: "rename failed" }
          : undefined,
    });

    const out = await w.install();
    expect(out.status).toBe("failed");
    expect(out.reason).toBe("rename_failed");
    const row = await plugins.getByPluginId(db, w.uid, "acme/demo");
    expect(row!.status).toBe("failed");
    expect(w.registry.list({ pluginId: "acme/demo" })).toEqual([]);
    expect(w.files.hasPrefix(pluginDir("acme/demo", "1.0.0"))).toBe(false);
  });

  it("uninstall removes dir, rows, registry entries", async () => {
    const w = await makeHarness(BASE_FILES);
    const out = await w.install();
    expect(out.status).toBe("active");
    expect(w.registry.list({ pluginId: "acme/demo" }).length).toBeGreaterThan(0);

    await w.uninstall();

    expect(w.files.hasPrefix("/workspace/.ovid/plugins/acme/demo")).toBe(false);
    expect(await plugins.getByPluginId(db, w.uid, "acme/demo")).toBeNull();
    expect(await pluginGrants.get(db, w.uid, "acme/demo")).toBeNull();
    expect(w.registry.list({ pluginId: "acme/demo" })).toEqual([]);
  });

  it("I3: a foreign/no-row uninstall is a no-op; registry entries are user-scoped", async () => {
    const fixture = await writeFixture(BASE_FILES);
    const registry = createContributionRegistry();
    const uidA = await seedUser("pro");
    const uidB = await seedUser("pro");
    const a = await makeInstallerFor(uidA, () => fixture, { registry });
    const b = await makeInstallerFor(uidB, () => fixture, { registry });

    expect((await a.install()).status).toBe("active");
    const aRecords = registry.list({ pluginId: "acme/demo", userId: uidA });
    expect(aRecords.length).toBeGreaterThan(0);

    // B never installed: the uninstall must not touch A's row, content or
    // registration (the pre-fix code unregistered the shared pluginId first).
    await b.uninstall();
    expect(registry.list({ pluginId: "acme/demo", userId: uidA })).toEqual(aRecords);
    expect(await plugins.getByPluginId(db, uidA, "acme/demo")).not.toBeNull();
    expect(a.files.hasPrefix(pluginDir("acme/demo", "1.0.0"))).toBe(true);

    // Both users install the same plugin: records coexist under per-user keys.
    expect((await b.install()).status).toBe("active");
    expect(registry.list({ pluginId: "acme/demo" }).length).toBe(aRecords.length * 2);

    // B's real uninstall removes ONLY B's records/row.
    await b.uninstall();
    expect(registry.list({ pluginId: "acme/demo", userId: uidA })).toEqual(aRecords);
    expect(registry.list({ pluginId: "acme/demo", userId: uidB })).toEqual([]);
    expect(await plugins.getByPluginId(db, uidA, "acme/demo")).not.toBeNull();
    expect(await plugins.getByPluginId(db, uidB, "acme/demo")).toBeNull();
  });

  it("M4: uploadDir throws → fresh row failed, no registry entries, staging discarded", async () => {
    const w = await makeHarness(BASE_FILES, { uploadError: new Error("upload boom") });

    await expect(w.install()).rejects.toThrow("upload boom");

    const row = await plugins.getByPluginId(db, w.uid, "acme/demo");
    expect(row!.status).toBe("failed");
    expect(w.registry.list({ pluginId: "acme/demo" })).toEqual([]);
    expect(w.files.remote.size).toBe(0);
  });

  it("I2: a post-commit resolved.discard() failure never rolls the committed install back", async () => {
    const w = await makeHarness(BASE_FILES, { discardError: new Error("discard boom") });
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const out = await w.install();

      // The install committed despite the cleanup failure.
      expect(out.status).toBe("active");
      const row = await plugins.getByPluginId(db, w.uid, "acme/demo");
      expect(row!.status).toBe("active");
      expect(row!.contentDir).toBe(pluginDir("acme/demo", "1.0.0"));
      expect(w.files.hasPrefix(pluginDir("acme/demo", "1.0.0"))).toBe(true);
      expect(w.registry.list({ pluginId: "acme/demo", userId: w.uid }).length).toBeGreaterThan(0);
      // …and the cleanup failure was logged, not silently swallowed.
      expect(
        errors.mock.calls.some((c) => String(c[0]).includes("discarding local staging")),
      ).toBe(true);
    } finally {
      errors.mockRestore();
    }
  });

  it("I4: registry.register throws after step ⑦'s upsert on an upgrade → prior row + records restored", async () => {
    const fixtureV1 = await writeFixture(BASE_FILES);
    const fixtureV2 = await writeFixture({
      ...BASE_FILES,
      ".claude-plugin/plugin.json": ccManifest({ version: "2.0.0" }),
    });
    const uid = await seedUser("pro");
    let resolveCount = 0;
    const w = await makeInstallerFor(uid, () => (resolveCount += 1) > 1 ? fixtureV2 : fixtureV1, {
      registryWrapper: (inner) => ({
        register(recs) {
          if (recs.some((r) => r.rootPath.includes("/2.0.0"))) {
            throw new Error("register boom");
          }
          inner.register(recs);
        },
        unregisterPlugin: (pluginId, userId) => inner.unregisterPlugin(pluginId, userId),
        list: (filter) => inner.list(filter),
        get: (canonicalId, userId) => inner.get(canonicalId, userId),
      }),
    });

    expect((await w.install()).status).toBe("active");
    const v1Records = w.registry.list({ pluginId: "acme/demo", userId: uid });

    await expect(w.install()).rejects.toThrow("register boom");

    // Prior row restored verbatim; the failed 2.0.0 row does not survive.
    const row = await plugins.getByPluginId(db, uid, "acme/demo");
    expect(row!.version).toBe("1.0.0");
    expect(row!.status).toBe("active");
    expect(row!.contentDir).toBe(pluginDir("acme/demo", "1.0.0"));
    expect(w.registry.list({ pluginId: "acme/demo", userId: uid })).toEqual(v1Records);
    expect(w.files.hasPrefix(pluginDir("acme/demo", "1.0.0"))).toBe(true);
    expect(w.files.hasPrefix(pluginDir("acme/demo", "2.0.0"))).toBe(false);
    for (const key of w.files.paths()) expect(key.includes(".staging-")).toBe(false);
  });

  it("I4: files.stat throws after step ⑦'s upsert on an upgrade → prior row + records restored", async () => {
    const fixtureV1 = await writeFixture(BASE_FILES);
    const fixtureV2 = await writeFixture({
      ...BASE_FILES,
      ".claude-plugin/plugin.json": ccManifest({ version: "2.0.0" }),
    });
    const uid = await seedUser("pro");
    let resolveCount = 0;
    const w = await makeInstallerFor(uid, () => (resolveCount += 1) > 1 ? fixtureV2 : fixtureV1, {
      statHandler: (path) =>
        path === pluginDir("acme/demo", "2.0.0") ? new Error("stat boom") : undefined,
    });

    expect((await w.install()).status).toBe("active");
    const v1Records = w.registry.list({ pluginId: "acme/demo", userId: uid });

    await expect(w.install()).rejects.toThrow("stat boom");

    const row = await plugins.getByPluginId(db, uid, "acme/demo");
    expect(row!.version).toBe("1.0.0");
    expect(row!.status).toBe("active");
    expect(w.registry.list({ pluginId: "acme/demo", userId: uid })).toEqual(v1Records);
    expect(w.files.hasPrefix(pluginDir("acme/demo", "1.0.0"))).toBe(true);
    expect(w.files.hasPrefix(pluginDir("acme/demo", "2.0.0"))).toBe(false);
  });

  it("I4/M4: the aside mv failing on a same-version reinstall restores the prior row + registry", async () => {
    const fixtureV1 = await writeFixture(BASE_FILES);
    const fixtureV2 = await writeFixture(EXTRA_ENV_FILES); // same 1.0.0, new digest
    const uid = await seedUser("pro");
    let resolveCount = 0;
    const w = await makeInstallerFor(uid, () => (resolveCount += 1) > 1 ? fixtureV2 : fixtureV1, {
      execHandler: (call) =>
        call.command === "mv" && call.args[1]!.includes(".backup-")
          ? { exitCode: 1, stdout: "", stderr: "aside failed" }
          : undefined,
    });

    expect((await w.install()).status).toBe("active");
    const v1Records = w.registry.list({ pluginId: "acme/demo", userId: uid });

    const out = await w.install();
    expect(out.status).toBe("failed");
    expect(out.reason).toBe("rename_failed");

    const row = await plugins.getByPluginId(db, uid, "acme/demo");
    expect(row!.version).toBe("1.0.0");
    expect(row!.status).toBe("active");
    expect(row!.contentDir).toBe(pluginDir("acme/demo", "1.0.0"));
    expect(w.registry.list({ pluginId: "acme/demo", userId: uid })).toEqual(v1Records);
    // The aside failed, so the prior content never moved.
    expect(w.files.hasPrefix(pluginDir("acme/demo", "1.0.0"))).toBe(true);
    for (const key of w.files.paths()) expect(key.includes(".staging-")).toBe(false);
  });

  it("M3: a double failure (commit mv + backup restore) is logged loudly, not swallowed", async () => {
    const fixtureV1 = await writeFixture(BASE_FILES);
    const fixtureV2 = await writeFixture(EXTRA_ENV_FILES); // same 1.0.0
    const uid = await seedUser("pro");
    let resolveCount = 0;
    let commitCount = 0;
    const w = await makeInstallerFor(uid, () => (resolveCount += 1) > 1 ? fixtureV2 : fixtureV1, {
      execHandler: (call) => {
        if (call.command !== "mv") return undefined;
        // Fail the SECOND transaction's commit rename AND its backup
        // restore (the first install must commit normally).
        if (call.args[0]!.includes(".staging-")) {
          commitCount += 1;
          return commitCount > 1
            ? { exitCode: 1, stdout: "", stderr: "mv failed" }
            : undefined;
        }
        if (call.args[0]!.includes(".backup-")) {
          return { exitCode: 1, stdout: "", stderr: "mv failed" };
        }
        return undefined;
      },
    });

    expect((await w.install()).status).toBe("active");
    const errors = vi.spyOn(console, "error").mockImplementation(() => {});
    try {
      const out = await w.install({ installId: "inst-double-fail" });
      expect(out.reason).toBe("rename_failed");
      expect(
        errors.mock.calls.some((c) => String(c[0]).includes("CRITICAL: backup restore failed")),
      ).toBe(true);
    } finally {
      errors.mockRestore();
    }

    // DB still describes the prior install (what the operator expects live);
    // the prior content is stranded at the backup dir — the logged CRITICAL.
    const row = await plugins.getByPluginId(db, uid, "acme/demo");
    expect(row!.version).toBe("1.0.0");
    expect(row!.status).toBe("active");
    const backupDir = `${pluginDir("acme/demo", "1.0.0")}.backup-inst-double-fail`;
    expect(w.files.hasPrefix(backupDir)).toBe(true);
    expect(w.files.hasPrefix(pluginDir("acme/demo", "1.0.0"))).toBe(false);
  });

  it("M5: an over-long installId is rejected before the transaction", async () => {
    const w = await makeHarness(BASE_FILES);
    const out = await w.install({ installId: "i".repeat(101) });
    expect(out.status).toBe("failed");
    expect(out.reason).toBe("invalid_install_id");
    expect(await plugins.getByPluginId(db, w.uid, "acme/demo")).toBeNull();
    expect(w.files.remote.size).toBe(0);
  });

  it("M5: an over-long manifest version is rejected before any remote write", async () => {
    const w = await makeHarness({
      ...BASE_FILES,
      ".claude-plugin/plugin.json": ccManifest({ version: "1".repeat(101) }),
    });
    const out = await w.install();
    expect(out.status).toBe("failed");
    expect(out.reason).toBe("invalid_plugin");
    expect(await plugins.getByPluginId(db, w.uid, "acme/demo")).toBeNull();
    expect(w.files.remote.size).toBe(0);
    expect(w.registry.list({ pluginId: "acme/demo" })).toEqual([]);
  });

  it("user_config substitution is SEALED: refs persisted in the row, values only in the runtime view (env + headers)", async () => {
    // A stdio server (env ref) + an HTTP server (header ref — M2 ruling).
    const fixture = await writeFixture({
      ".claude-plugin/plugin.json": ccManifest(),
      "commands/foo.md": "# foo\n",
      ".mcp.json": JSON.stringify({
        mcpServers: {
          bar: {
            command: "node",
            args: ["server.js"],
            env: {
              API_KEY: "${user_config.api_key}",
              OTHER: "${user_config.missing_key}",
            },
          },
          web: {
            url: "https://example.com/mcp",
            headers: {
              Authorization: "Bearer ${user_config.api_key}",
              "X-Static": "literal",
            },
          },
        },
      }),
    });
    const uid = await seedUser("pro");
    await seedSealedConfig(uid, { api_key: "sk-live-test-123" });
    await seedCoveringGrant(uid, fixture);
    const w = await makeInstallerFor(uid, () => fixture);

    const out = await w.install();
    expect(out.status).toBe("active");

    // C1: the DB row keeps the REFS — no resolved secret anywhere in the
    // row's JSON serialization (the negative probe).
    const row = await plugins.getByPluginId(db, uid, "acme/demo");
    const servers = (row!.manifest as {
      mcpServers: {
        name: string;
        imported: {
          env?: Record<string, string>;
          headers?: Record<string, string>;
        };
      }[];
    }).mcpServers;
    const bar = servers.find((s) => s.name === "bar")!;
    expect(bar.imported.env!.API_KEY).toBe("${user_config.api_key}");
    expect(bar.imported.env!.OTHER).toBe("${user_config.missing_key}");
    const web = servers.find((s) => s.name === "web")!;
    expect(web.imported.headers!.Authorization).toBe("Bearer ${user_config.api_key}");
    expect(web.imported.headers!["X-Static"]).toBe("literal");
    expect(JSON.stringify(row)).not.toContain("sk-live-test-123");

    // The runtime view (registry) IS substituted — env and headers.
    const mcpRecord = w.registry.get("plugin:acme/demo/mcp:bar", uid);
    expect(mcpRecord).toBeDefined();
    const data = mcpRecord!.data as { imported?: { env?: Record<string, string> } };
    expect(data.imported?.env?.API_KEY).toBe("sk-live-test-123");
    expect(data.imported?.env?.OTHER).toBe("${user_config.missing_key}");
    const webRecord = w.registry.get("plugin:acme/demo/mcp:web", uid);
    const webData = webRecord!.data as { imported?: { headers?: Record<string, string> } };
    expect(webData.imported?.headers?.Authorization).toBe("Bearer sk-live-test-123");
    expect(webData.imported?.headers?.["X-Static"]).toBe("literal");

    // The sealed config survived the reinstall (carried over).
    expect(row!.configSealed).not.toBeNull();
  });

  it("tier re-check: user flipped to free before job start → outcome failed pro_required", async () => {
    const w = await makeHarness(BASE_FILES, { tier: "pro" });
    await db.$client.unsafe("UPDATE users SET tier = $1 WHERE uid = $2", ["free", w.uid]);

    const out = await w.install();

    expect(out.status).toBe("failed");
    expect(out.reason).toBe("pro_required");
    // Nothing happened: no row, no remote dir, no registry entries.
    expect(await plugins.getByPluginId(db, w.uid, "acme/demo")).toBeNull();
    expect(w.files.remote.size).toBe(0);
    expect(w.registry.list({ pluginId: "acme/demo" })).toEqual([]);
  });

  it("secret hygiene: no bus payload ever contains a fixture or sealed-config secret", async () => {
    const fixture = await writeFixture({
      ...BASE_FILES,
      ".mcp.json": mcpJson({
        API_KEY: "${user_config.api_key}",
        STATIC_TOKEN: "FIXTURE-SECRET-abc123",
      }),
    });
    const uid = await seedUser("pro");
    await seedSealedConfig(uid, { api_key: "sk-hygiene-999" });
    const w = await makeInstallerFor(uid, () => fixture);

    const out = await w.install();
    expect(out.status).toBe("active");

    for (const payload of w.bus.allPayloads()) {
      const json = JSON.stringify(payload);
      expect(json.includes("FIXTURE-SECRET-abc123")).toBe(false);
      expect(json.includes("sk-hygiene-999")).toBe(false);
    }
    // C1 negative probe: the sealed config value is nowhere in the DB row
    // (the manifest keeps `${user_config.api_key}`; config_sealed is opaque).
    const row = await plugins.getByPluginId(db, uid, "acme/demo");
    expect(JSON.stringify(row)).not.toContain("sk-hygiene-999");
    // The approval sheet carried explanations for every requested capability.
    const req = w.bus.requests[0]!;
    const capabilities = req.payload.capabilities as { name: string; explanation: string }[];
    for (const cap of capabilities) expect(cap.explanation.length).toBeGreaterThan(0);
  });

  // -------------------------------------------------------------------------
  // HIGH-1 / MEDIUM-2 / MEDIUM-3 — cross-task regressions
  // -------------------------------------------------------------------------

  it("HIGH-1: the REAL paste resolver → real adapter → real installer installs (version emitted)", async () => {
    // No fake resolver and no fake manifest: a regression that drops the
    // version back to "" fails here with `invalid_plugin`.
    const uid = await seedUser("pro");
    const files = new FakeFiles();
    const bus = new FakeBus();
    const registry = createContributionRegistry();
    const installer = createPluginInstaller({
      db,
      crypto,
      systemBus: bus,
      resolver: createSourceResolver(),
      sandbox: {
        files,
        spawner: {
          spawn: async () => {
            throw new Error("install transaction never spawns long-running processes");
          },
        },
      },
      registry,
      approvalTimeoutMs: 200,
    });
    installers.push(installer);

    const out = await installer.install({
      installId: `install-${testUid("paste")}`,
      userId: uid,
      pluginId: "mcp/pasted-demo",
      mode: "install",
      source: {
        kind: "paste",
        label: "Pasted Demo",
        config: JSON.stringify({
          mcpServers: { demo: { command: "npx", args: ["demo-mcp"] } },
        }),
      },
    });

    expect(out.status).toBe("active");
    expect(out.reason).toBeUndefined();
    expect(out.version).toBe(PASTE_PLUGIN_VERSION);
    const row = await plugins.getByPluginId(db, uid, "mcp/pasted-demo");
    expect(row!.status).toBe("active");
    expect(row!.version).toBe(PASTE_PLUGIN_VERSION);
  });

  it("MEDIUM-3: editing a contribution file body after approval forces re-approval", async () => {
    const fixture = await writeFixture(BASE_FILES);
    const uid = await seedUser("pro");
    const w = await makeInstallerFor(uid, () => fixture);

    const out1 = await w.install();
    expect(out1.status).toBe("active");
    expect(w.bus.requests.length).toBe(1);

    // Same metadata/paths, changed prompt bytes: the content digest must
    // differ so the stored grant no longer covers the plugin.
    await writeFile(join(fixture, "commands/foo.md"), "# foo CHANGED\n");

    const out2 = await w.install();
    expect(out2.status).toBe("active");
    expect(w.bus.requests.length).toBe(2);
  });

  it("MEDIUM-2: rehydrate rebuilds the contribution registry from active rows", async () => {
    const w = await makeHarness(BASE_FILES);
    const out = await w.install();
    expect(out.status).toBe("active");
    const expected = w.registry.list({ userId: w.uid }).length;
    expect(expected).toBeGreaterThan(0);

    // A fresh process: empty registry, same DB/disk.
    const registry2 = createContributionRegistry();
    const { resolver } = fakeResolver(() => "");
    const installer2 = createPluginInstaller({
      db,
      crypto,
      systemBus: new FakeBus(),
      resolver,
      sandbox: {
        files: new FakeFiles(),
        spawner: {
          spawn: async () => {
            throw new Error("rehydrate never spawns");
          },
        },
      },
      registry: registry2,
      approvalTimeoutMs: 200,
    });
    installers.push(installer2);

    const rehydrated = await installer2.rehydrate();
    expect(rehydrated).toBeGreaterThanOrEqual(1);
    expect(registry2.list({ userId: w.uid })).toHaveLength(expected);
  });
});
