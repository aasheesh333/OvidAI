import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { BrowserSessionRegistry, SessionBrowser } from "../sessions.js";
import { createBrowserTools } from "./definitions.js";
import type {
  BrowserArtifactVaultPort,
  BrowserToolContext,
  BrowserToolDef,
  BrowserToolsDeps,
} from "./types.js";

/**
 * Wave 6 W4 — the file bridge, without chromium. A stub page records
 * setInputFiles; a stub context exposes the download listener; the Artifact
 * Vault port is observed at both ends (fetch-to-workspace on upload,
 * register-from-workspace on download).
 */

const CTX: BrowserToolContext = { sessionId: "user-u1", userId: "u1", workspaceSessionId: "chat-1" };

interface Harness {
  tools: Map<string, BrowserToolDef>;
  uploaded: string[];
  vaultFetches: Array<Record<string, unknown>>;
  vaultRegisters: Array<Record<string, unknown>>;
  fireDownload(download: unknown): Promise<void>;
  network: SessionBrowser["network"];
  root: string;
}

async function harness(
  root: string,
  options: { registerFromWorkspace?: BrowserArtifactVaultPort["registerFromWorkspace"] } = {},
): Promise<Harness> {
  const uploaded: string[] = [];
  const vaultFetches: Array<Record<string, unknown>> = [];
  const vaultRegisters: Array<Record<string, unknown>> = [];
  let downloadListener: ((download: unknown) => void) | null = null;

  const page = {
    url: () => "https://example.test/",
    viewportSize: () => ({ width: 1280, height: 800 }),
    async setInputFiles(selector: string, path: string) {
      uploaded.push(`${selector}=${path}`);
    },
  };
  const context = {
    on(event: string, listener: (download: unknown) => void) {
      if (event === "download") downloadListener = listener;
    },
    async cookies() {
      return [];
    },
  };
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
  const registry = {
    get: () => session,
    touch: () => {},
    refuseReasonIfTakeover: () => null,
  } as unknown as BrowserSessionRegistry;

  const artifactVault: BrowserArtifactVaultPort = {
    async fetchToWorkspace({ artifactId, destDir }) {
      vaultFetches.push({ artifactId, destDir });
      await mkdir(join(root, destDir), { recursive: true });
      const path = `${destDir}/from-vault-${artifactId}.txt`;
      await writeFile(join(root, path), "vault bytes");
      return { path, mimeType: "text/plain", bytes: 11 };
    },
    async registerFromWorkspace(input) {
      vaultRegisters.push({ ...input });
      if (options.registerFromWorkspace !== undefined) {
        return options.registerFromWorkspace(input);
      }
      return { id: "artifact-1" };
    },
  };

  const deps: BrowserToolsDeps = {
    pool: {} as never,
    registry,
    persistence: null,
    cfg: {
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
      // The download URL is a literal loopback address; the test bypasses the
      // SSRF guard for it exactly like the chromium suites do.
      allowHosts: ["127.0.0.1"],
      ownPublicIp: null,
      blockHeavyResources: false,
      chromiumArgs: [],
    },
    workspaceDir: async () => root,
    artifactVault,
  };
  return {
    tools: new Map(createBrowserTools(deps).map((t) => [t.name, t])),
    uploaded,
    vaultFetches,
    vaultRegisters,
    async fireDownload(download: unknown) {
      if (downloadListener === null) throw new Error("download listener was not wired");
      downloadListener(download);
      // Let the async listener finish (it awaits path/stat/saveAs).
      await new Promise((r) => setTimeout(r, 20));
    },
    network: session.network,
    root,
  };
}

function exec(h: Harness, name: string, input: unknown) {
  const tool = h.tools.get(name);
  if (tool === undefined) throw new Error(`missing tool ${name}`);
  return tool.execute(input, CTX);
}

describe("browser file bridge (W4)", () => {
  let root: string;

  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), "ovid-browser-bridge-"));
  });

  afterEach(async () => {
    vi.unstubAllGlobals();
    await rm(root, { recursive: true, force: true });
  });

  it("uploads a workspace file into the page", async () => {
    await mkdir(join(root, "uploads"), { recursive: true });
    await writeFile(join(root, "uploads", "hello.txt"), "hello");
    const h = await harness(root);

    const result = await exec(h, "browser_upload", {
      selector: "input[type=file]",
      path: "uploads/hello.txt",
    });
    expect(result.content).toContain("uploaded uploads/hello.txt");
    expect(h.uploaded).toEqual([
      `input[type=file]=${join(root, "uploads", "hello.txt")}`,
    ]);
  });

  it("uploads an Artifact Vault artifact by fetching it into the workspace first", async () => {
    const h = await harness(root);
    const result = await exec(h, "browser_upload", {
      selector: "#file",
      artifactId: "art-9",
    });
    expect(h.vaultFetches).toEqual([{ artifactId: "art-9", destDir: "browser/uploads" }]);
    expect(h.uploaded).toEqual([`#file=${join(root, "browser/uploads/from-vault-art-9.txt")}`]);
    expect(result.content).toContain("from-vault-art-9.txt");
  });

  it("refuses a workspace-escaping upload path", async () => {
    const h = await harness(root);
    const result = await exec(h, "browser_upload", {
      selector: "#file",
      path: "../outside.txt",
    });
    expect(result.content).toContain("escapes the session workspace");
    expect(h.uploaded).toEqual([]);
  });

  it("downloads a URL into the workspace AND the Artifact Vault", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        const body = Buffer.from("downloaded bytes");
        return new Response(body, {
          status: 200,
          headers: { "content-type": "text/plain", "content-length": String(body.length) },
        });
      }),
    );
    const h = await harness(root);
    const result = await exec(h, "browser_download", {
      url: "http://127.0.0.1:1/report.txt",
      filename: "report.txt",
    });

    expect(await readFile(join(root, "browser/downloads/report.txt"), "utf8")).toBe("downloaded bytes");
    expect(h.vaultRegisters).toEqual([
      {
        userId: "u1",
        sessionId: "chat-1",
        path: "browser/downloads/report.txt",
        mimeType: "text/plain",
      },
    ]);
    expect(result.content).toContain("saved 16 bytes to browser/downloads/report.txt");
    expect(result.content).toContain("Artifact Vault");
    expect(result.artifacts?.[0]?.path).toBe("browser/downloads/report.txt");
  });

  // UNEXECUTED round-3: publication refusal is not an ordinary tool success.
  it("browser_download returns typed project refusal instead of artifact success", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("bytes", {
      status: 200,
      headers: { "content-type": "text/plain", "content-length": "5" },
    })));
    const h = await harness(root, {
      registerFromWorkspace: async () => {
        throw Object.assign(new Error("project full"), { code: "project_file_limit" });
      },
    });
    const result = await exec(h, "browser_download", {
      url: "http://127.0.0.1:1/report.txt",
      filename: "report.txt",
    });
    expect(result.content).toBe("error: project_file_limit: The project file allowance is exhausted.");
    expect(result.isError).toBe(true);
    expect(result.artifacts).toBeUndefined();
    expect(result.content).not.toContain("saved");
  });

  it("a page-initiated download records a typed publication failure, not a normal success", async () => {
    const h = await harness(root, {
      registerFromWorkspace: async () => {
        throw Object.assign(new Error("quota unavailable"), { code: "storage_quota_not_configured" });
      },
    });
    await exec(h, "browser_list_tabs", {});
    const temp = join(root, "tmp-refusal");
    await writeFile(temp, "page bytes");
    await h.fireDownload({
      url: () => "https://example.test/refusal.csv",
      suggestedFilename: () => "refusal.csv",
      path: async () => temp,
      saveAs: async (dest: string) => writeFile(dest, "page bytes"),
      delete: async () => {},
    });
    expect(h.network).toHaveLength(1);
    expect(h.network[0]!.failure).toContain("storage_quota_not_configured");
    expect(h.network[0]!.status).toBeNull();
  });

  it("a page-initiated download lands in the chat workspace and the vault", async () => {
    const h = await harness(root);
    await exec(h, "browser_list_tabs", {}); // wires the download listener
    const temp = join(root, "tmp-download");
    await writeFile(temp, "page bytes");

    await h.fireDownload({
      url: () => "https://example.test/data.csv",
      suggestedFilename: () => "data.csv",
      path: async () => temp,
      saveAs: async (dest: string) => writeFile(dest, "page bytes"),
      delete: async () => {},
    });

    expect(await readFile(join(root, "browser/downloads/data.csv"), "utf8")).toBe("page bytes");
    expect(h.vaultRegisters).toEqual([
      {
        userId: "u1",
        sessionId: "chat-1",
        path: "browser/downloads/data.csv",
        mimeType: "application/octet-stream",
      },
    ]);
  });
});
