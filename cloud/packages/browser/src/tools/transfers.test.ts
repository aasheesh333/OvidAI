import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
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
  root: string;
  /** Mutable seams (downloadMaxBytes / uploadMaxBytes) after construction. */
  deps: BrowserToolsDeps;
}

async function harness(root: string): Promise<Harness> {
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
    getOwned: (_sessionId: string, userId: string) => (userId === session.userId ? session : null),
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
    root,
    deps,
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

  it("a page-initiated download lands in the chat workspace and the vault", async () => {
    const h = await harness(root);
    await exec(h, "browser_list_tabs", {}); // wires the download listener
    const temp = join(root, "tmp-download");
    await writeFile(temp, "page bytes");

    await h.fireDownload({
      url: () => "https://example.test/data.csv",
      suggestedFilename: () => "data.csv",
      page: () => (h.deps.registry.get("x") as SessionBrowser).tabs[0],
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
        mimeType: "text/csv",
      },
    ]);
  });

  it("refuses an oversized upload before touching the page", async () => {
    await mkdir(join(root, "uploads"), { recursive: true });
    await writeFile(join(root, "uploads", "big.txt"), "0123456789");
    const h = await harness(root);
    h.deps.uploadMaxBytes = 4;

    const result = await exec(h, "browser_upload", {
      selector: "#file",
      path: "uploads/big.txt",
    });
    expect(result.content).toBe("Upload refused: file exceeds the 50 MB limit.");
    expect(h.uploaded).toEqual([]);
  });

  it("refuses an upload type outside the allowlist", async () => {
    await mkdir(join(root, "uploads"), { recursive: true });
    await writeFile(join(root, "uploads", "run.sh"), "rm -rf /");
    const h = await harness(root);

    const result = await exec(h, "browser_upload", {
      selector: "#file",
      path: "uploads/run.sh",
    });
    expect(result.content).toBe("Upload refused: file type not allowed (.sh).");
    expect(h.uploaded).toEqual([]);
  });

  it("refuses a symlink that escapes the workspace on upload", async () => {
    const outside = await mkdtemp(join(tmpdir(), "ovid-browser-outside-"));
    try {
      await writeFile(join(outside, "secret.txt"), "not yours");
      await symlink(outside, join(root, "linked"), "dir");
      const h = await harness(root);

      const result = await exec(h, "browser_upload", {
        selector: "#file",
        path: "linked/secret.txt",
      });
      expect(result.content).toBe("Upload refused: path escapes the session workspace.");
      expect(h.uploaded).toEqual([]);
    } finally {
      await rm(outside, { recursive: true, force: true });
    }
  });

  it("downloads normalize an allowed content type and keep the vault type", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        const body = Buffer.from("plain body");
        return new Response(body, {
          status: 200,
          headers: { "content-type": "text/plain; charset=utf-8", "content-length": String(body.length) },
        });
      }),
    );
    const h = await harness(root);
    const result = await exec(h, "browser_download", {
      url: "http://127.0.0.1:1/notes.txt",
      filename: "notes.txt",
    });

    expect(result.artifacts?.[0]?.mimeType).toBe("text/plain");
    expect(h.vaultRegisters[0]?.mimeType).toBe("text/plain");
    expect(await readFile(join(root, "browser/downloads/notes.txt"), "utf8")).toBe("plain body");
  });

  it("refuses a download with an active content type without writing", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        const body = Buffer.from("<script>alert(1)</script>");
        return new Response(body, {
          status: 200,
          headers: { "content-type": "text/html; charset=utf-8", "content-length": String(body.length) },
        });
      }),
    );
    const h = await harness(root);
    const result = await exec(h, "browser_download", {
      url: "http://127.0.0.1:1/page.html",
      filename: "page.html",
    });

    expect(result.content).toBe("Download refused: content type text/html is not allowed.");
    expect(existsSync(join(root, "browser", "downloads", "page.html"))).toBe(false);
    expect(h.vaultRegisters).toEqual([]);
  });

  it("refuses an oversized download without writing", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        const body = Buffer.from("too large");
        return new Response(body, {
          status: 200,
          headers: { "content-type": "text/plain", "content-length": String(body.length) },
        });
      }),
    );
    const h = await harness(root);
    h.deps.downloadMaxBytes = 4;

    const result = await exec(h, "browser_download", {
      url: "http://127.0.0.1:1/big.txt",
      filename: "big.txt",
    });
    expect(result.content).toBe("Download refused: file exceeds the 50 MB limit.");
    expect(existsSync(join(root, "browser", "downloads", "big.txt"))).toBe(false);
    expect(h.vaultRegisters).toEqual([]);
  });

  it("refuses a download destination that is a symlink outside the workspace", async () => {
    const outside = await mkdtemp(join(tmpdir(), "ovid-browser-outside-"));
    try {
      await symlink(outside, join(root, "browser"), "dir");
      vi.stubGlobal(
        "fetch",
        vi.fn(async () => {
          const body = Buffer.from("bytes");
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

      expect(result.content).toBe("Download refused: destination escapes the session workspace.");
      // Not even the directory may be created through the symlink.
      expect(existsSync(join(outside, "downloads"))).toBe(false);
      expect(h.vaultRegisters).toEqual([]);
    } finally {
      await rm(outside, { recursive: true, force: true });
    }
  });

  it("refuses a redirect to a private address — only the vetted hop is fetched", async () => {
    const fetchMock = vi.fn(
      async () =>
        new Response(null, {
          status: 302,
          headers: { location: "http://169.254.169.254/latest/meta-data/iam/security-credentials/" },
        }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const h = await harness(root);

    const result = await exec(h, "browser_download", {
      url: "http://127.0.0.1:1/start",
      filename: "meta.txt",
    });

    expect(result.content).toContain("Download refused");
    expect(result.content).toContain("non-public");
    // The 302 target was never requested.
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(existsSync(join(root, "browser", "downloads", "meta.txt"))).toBe(false);
    expect(h.vaultRegisters).toEqual([]);
  });

  it("follows an allowed redirect manually, re-gating each hop", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = String(input);
      if (url === "http://127.0.0.1:1/start") {
        return new Response(null, {
          status: 302,
          headers: { location: "http://127.0.0.1:1/final.txt" },
        });
      }
      const body = Buffer.from("redirected bytes");
      return new Response(body, {
        status: 200,
        headers: { "content-type": "text/plain", "content-length": String(body.length) },
      });
    });
    vi.stubGlobal("fetch", fetchMock);
    const h = await harness(root);

    const result = await exec(h, "browser_download", {
      url: "http://127.0.0.1:1/start",
      filename: "final.txt",
    });

    expect(result.content).toContain("saved 16 bytes to browser/downloads/final.txt");
    expect(fetchMock).toHaveBeenCalledTimes(2);
    expect(await readFile(join(root, "browser/downloads/final.txt"), "utf8")).toBe("redirected bytes");
  });
});

// The agent must be able to modify what it downloaded. The worker writes as
// root; the jail runs as the sandbox uid, so without an ownership hand-off a
// download is readable but not writable/movable/deletable by the agent.
describe("workspace ownership hand-off", () => {
  it("owns a browser_download's file AND its directory", async () => {
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
    const root = await mkdtemp(join(tmpdir(), "ovid-own-dl-"));
    const h = await harness(root);
    const owned: string[] = [];
    h.deps.ownPath = async (_userId, hostPath) => {
      owned.push(hostPath);
    };

    await exec(h, "browser_download", { url: "http://127.0.0.1:1/file.txt", filename: "file.txt" });

    const file = join(root, "browser/downloads/file.txt");
    expect(owned).toContain(file);
    // The directory too: deleting a file needs write on its parent.
    expect(owned).toContain(join(root, "browser/downloads"));
    await rm(root, { recursive: true, force: true });
  });

  it("owns the page-download copy the listener writes", async () => {
    const root = await mkdtemp(join(tmpdir(), "ovid-own-page-"));
    const h = await harness(root);
    await exec(h, "browser_list_tabs", {}); // wires the download listener
    const owned: string[] = [];
    h.deps.ownPath = async (_userId, hostPath) => {
      owned.push(hostPath);
    };
    // The listener stats the browser's own copy before saving it.
    const source = join(root, "tmp-source.pdf");
    await writeFile(source, "pdf bytes");

    await h.fireDownload({
      url: () => "https://example.test/report.pdf",
      suggestedFilename: () => "report.pdf",
      page: () => (h.deps.registry.get("x") as SessionBrowser).tabs[0],
      async path() {
        return source;
      },
      async saveAs(dest: string) {
        await writeFile(dest, "pdf bytes");
      },
      async delete() {},
    });

    expect(owned).toContain(join(root, "browser/downloads/report.pdf"));
    await rm(root, { recursive: true, force: true });
  });

  it("does not own anything when no seam is wired (dev/test)", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(Buffer.from("x"), { status: 200 })),
    );
    const root = await mkdtemp(join(tmpdir(), "ovid-own-none-"));
    const h = await harness(root);
    await expect(
      exec(h, "browser_download", { url: "http://127.0.0.1:1/file.txt", filename: "f.txt" }),
    ).resolves.toBeDefined();
    await rm(root, { recursive: true, force: true });
  });
});
