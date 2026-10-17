import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { createHash } from "node:crypto";
import { access, mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gzipSync } from "node:zlib";
import { parseMcpConfig } from "../configParse.js";
import { createGuardedFetch, type GuardedFetch } from "../ssrf.js";
import { buildTar, buildZip } from "./__fixtures__/builders.js";
import {
  MAX_METADATA_BYTES,
  MAX_PASTE_BYTES,
  MAX_PAYLOAD_BYTES,
  PluginSourceError,
  createSourceResolver,
} from "./sources.js";

type RouteHandler = (url: string, init?: RequestInit) => Response | Promise<Response>;

function fakeFetch(routes: Array<[RegExp | string, RouteHandler]>): {
  fetchImpl: GuardedFetch;
  calls: string[];
} {
  const calls: string[] = [];
  const fetchImpl: GuardedFetch = async (url, init) => {
    calls.push(url);
    for (const [matcher, handler] of routes) {
      const matches = typeof matcher === "string" ? url.includes(matcher) : matcher.test(url);
      if (matches) return handler(url, init);
    }
    throw new Error(`unexpected fetch: ${url}`);
  };
  return { fetchImpl, calls };
}

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

function sha512Sri(bytes: Uint8Array): string {
  return "sha512-" + createHash("sha512").update(bytes).digest("base64");
}

async function listTree(dir: string): Promise<string[]> {
  const out: string[] = [];
  async function walk(current: string, prefix: string): Promise<void> {
    for (const entry of await readdir(current, { withFileTypes: true })) {
      const rel = prefix === "" ? entry.name : `${prefix}/${entry.name}`;
      if (entry.isDirectory()) await walk(join(current, entry.name), rel);
      else out.push(rel);
    }
  }
  await walk(dir, "");
  return out.sort();
}

let stagingRoot: string;

beforeEach(async () => {
  stagingRoot = await mkdtemp(join(tmpdir(), "ovid-plugin-staging-test-"));
});

afterEach(async () => {
  await rm(stagingRoot, { recursive: true, force: true });
});

describe("createSourceResolver — github", () => {
  it("walks the trees API, downloads blobs into staging and pins provenance", async () => {
    const pluginJson = Buffer.from('{"name":"demo"}');
    const readme = Buffer.from("# demo\n");
    const { fetchImpl, calls } = fakeFetch([
      [
        /\/repos\/acme\/plugin\/git\/trees\/main\?recursive=1$/,
        () =>
          json({
            sha: "tree-sha-123",
            tree: [
              { path: "plugin.json", type: "blob", mode: "100644", sha: "blob1" },
              { path: "lib", type: "tree", mode: "040000", sha: "tree1" },
              { path: "lib/readme.md", type: "blob", mode: "100644", sha: "blob2" },
            ],
          }),
      ],
      [
        "/repos/acme/plugin/git/blobs/blob1",
        () => json({ content: pluginJson.toString("base64"), encoding: "base64" }),
      ],
      [
        "/repos/acme/plugin/git/blobs/blob2",
        () => json({ content: readme.toString("base64"), encoding: "base64" }),
      ],
    ]);

    const resolver = createSourceResolver({ fetchImpl, stagingRoot });
    const resolved = await resolver.resolve({
      kind: "github",
      owner: "acme",
      repo: "plugin",
      ref: "main",
    });

    expect(resolved.provenance).toEqual({
      kind: "github",
      githubRepo: "acme/plugin",
      resolvedRef: "main",
      revision: "tree-sha-123",
    });
    expect(resolved.bytes).toBe(pluginJson.length + readme.length);
    expect(await readFile(join(resolved.stagingDir, "plugin.json"), "utf8")).toBe(
      '{"name":"demo"}',
    );
    expect(await readFile(join(resolved.stagingDir, "lib/readme.md"), "utf8")).toBe(
      "# demo\n",
    );
    expect(calls.some((u) => u.includes("trees/main?recursive=1"))).toBe(true);
    await resolved.discard();
  });

  it("skips contained symlinks and validates escaping symlinks", async () => {
    const safe = fakeFetch([
      [
        /\/git\/trees\/HEAD\?recursive=1$/,
        () =>
          json({
            sha: "s",
            tree: [
              { path: "plugin.json", type: "blob", mode: "100644", sha: "b1" },
              { path: "link", type: "blob", mode: "120000", sha: "b2" },
            ],
          }),
      ],
      ["/git/blobs/b1", () => json({ content: Buffer.from("{}").toString("base64"), encoding: "base64" })],
      [
        "/git/blobs/b2",
        () => json({ content: Buffer.from("plugin.json").toString("base64"), encoding: "base64" }),
      ],
    ]);
    const resolved = await createSourceResolver(safe).resolve({
      kind: "github",
      owner: "acme",
      repo: "plugin",
    });
    expect(await listTree(resolved.stagingDir)).toEqual(["plugin.json"]);
    await resolved.discard();

    const unsafe = fakeFetch([
      [
        /\/git\/trees\/HEAD\?recursive=1$/,
        () =>
          json({
            sha: "s",
            tree: [{ path: "link", type: "blob", mode: "120000", sha: "b2" }],
          }),
      ],
      [
        "/git/blobs/b2",
        () =>
          json({
            content: Buffer.from("../../etc/passwd").toString("base64"),
            encoding: "base64",
          }),
      ],
    ]);
    await expect(
      createSourceResolver(unsafe).resolve({ kind: "github", owner: "acme", repo: "plugin" }),
    ).rejects.toBeInstanceOf(PluginSourceError);
    expect(await readdir(stagingRoot)).toEqual([]);
  });

  it("rejects tree metadata over 4 MiB and discards staging", async () => {
    const { fetchImpl } = fakeFetch([
      [
        /\/git\/trees\/main\?recursive=1$/,
        () => new Response("x".repeat(MAX_METADATA_BYTES + 1), { status: 200 }),
      ],
    ]);

    await expect(
      createSourceResolver({ fetchImpl, stagingRoot }).resolve({
        kind: "github",
        owner: "acme",
        repo: "plugin",
        ref: "main",
      }),
    ).rejects.toBeInstanceOf(PluginSourceError);
    expect(await readdir(stagingRoot)).toEqual([]);
  });

  it("rejects path traversal in repository coordinates", async () => {
    const { fetchImpl, calls } = fakeFetch([]);
    const resolver = createSourceResolver({ fetchImpl, stagingRoot });
    await expect(
      resolver.resolve({ kind: "github", owner: "..", repo: "plugin" }),
    ).rejects.toBeInstanceOf(PluginSourceError);
    await expect(
      resolver.resolve({ kind: "github", owner: "acme", repo: "../../evil" }),
    ).rejects.toBeInstanceOf(PluginSourceError);
    expect(calls).toEqual([]);
  });
});

describe("createSourceResolver — npm", () => {
  function npmFixture(version = "1.2.3") {
    const tarball = gzipSync(
      buildTar([
        { name: "package/", type: "5" },
        { name: "package/plugin.json", data: Buffer.from('{"name":"demo"}') },
        { name: "package/lib/a.js", data: Buffer.from("export {};\n") },
      ]),
    );
    const integrity = sha512Sri(tarball);
    const tarballUrl = `https://registry.npmjs.org/acme-plugin/-/acme-plugin-${version}.tgz`;
    return { tarball, integrity, tarballUrl, version };
  }

  it("resolves the registry doc, verifies dist.integrity and extracts the tarball", async () => {
    const fixture = npmFixture();
    const { fetchImpl, calls } = fakeFetch([
      [
        /^https:\/\/registry\.npmjs\.org\/acme-plugin$/,
        () =>
          json({
            "dist-tags": { latest: fixture.version },
            versions: {
              [fixture.version]: {
                dist: { tarball: fixture.tarballUrl, integrity: fixture.integrity },
              },
            },
          }),
      ],
      [fixture.tarballUrl, () => new Response(fixture.tarball)],
    ]);

    const progress: number[] = [];
    const resolved = await createSourceResolver({ fetchImpl, stagingRoot }).resolve(
      { kind: "npm", package: "acme-plugin", version: "latest" },
      (n) => progress.push(n),
    );

    expect(resolved.provenance).toEqual({
      kind: "npm",
      npmPackage: "acme-plugin",
      npmVersion: fixture.version,
      integrity: fixture.integrity,
    });
    expect(resolved.bytes).toBe(fixture.tarball.length);
    expect(await readFile(join(resolved.stagingDir, "package/plugin.json"), "utf8")).toBe(
      '{"name":"demo"}',
    );
    expect(calls[0]).toBe("https://registry.npmjs.org/acme-plugin");
    expect(progress.at(-1)).toBe(fixture.tarball.length);
    await resolved.discard();
  });

  it("rejects an integrity mismatch and discards staging", async () => {
    const fixture = npmFixture();
    const wrongIntegrity = sha512Sri(Buffer.from("something else"));
    const { fetchImpl } = fakeFetch([
      [
        /^https:\/\/registry\.npmjs\.org\/acme-plugin$/,
        () =>
          json({
            versions: {
              [fixture.version]: {
                dist: { tarball: fixture.tarballUrl, integrity: wrongIntegrity },
              },
            },
          }),
      ],
      [fixture.tarballUrl, () => new Response(fixture.tarball)],
    ]);

    await expect(
      createSourceResolver({ fetchImpl, stagingRoot }).resolve({
        kind: "npm",
        package: "acme-plugin",
        version: fixture.version,
      }),
    ).rejects.toBeInstanceOf(PluginSourceError);
    expect(await readdir(stagingRoot)).toEqual([]);
  });

  it("rejects unsafe package names before fetching", async () => {
    const { fetchImpl, calls } = fakeFetch([]);
    const resolver = createSourceResolver({ fetchImpl, stagingRoot });
    for (const name of ["../evil", "Foo Bar", "@scope/../x", "a/b", "-bad", "a%2fb"]) {
      await expect(resolver.resolve({ kind: "npm", package: name })).rejects.toBeInstanceOf(
        PluginSourceError,
      );
    }
    expect(calls).toEqual([]);
    expect(await readdir(stagingRoot)).toEqual([]);
  });
});

describe("createSourceResolver — zip", () => {
  it("routes the download through the SSRF guard (non-public literal rejected)", async () => {
    const resolver = createSourceResolver({
      fetchImpl: createGuardedFetch(),
      stagingRoot,
    });

    await expect(
      resolver.resolve({ kind: "zip", url: "http://10.0.0.1/x.zip" }),
    ).rejects.toBeInstanceOf(PluginSourceError);
    expect(await readdir(stagingRoot)).toEqual([]);
  });

  it("downloads and extracts a zip into staging", async () => {
    const archive = buildZip([
      { name: "plugin.json", data: Buffer.from('{"name":"demo"}') },
      { name: "lib/a.js", data: Buffer.from("export {};\n"), method: 8 },
    ]);
    const { fetchImpl } = fakeFetch([
      ["https://example.test/plugin.zip", () => new Response(archive)],
    ]);

    const progress: number[] = [];
    const resolved = await createSourceResolver({ fetchImpl, stagingRoot }).resolve(
      { kind: "zip", url: "https://example.test/plugin.zip" },
      (n) => progress.push(n),
    );

    expect(resolved.provenance).toEqual({
      kind: "zip",
      url: "https://example.test/plugin.zip",
    });
    expect(resolved.bytes).toBe(archive.length);
    expect(await readFile(join(resolved.stagingDir, "lib/a.js"), "utf8")).toBe("export {};\n");
    expect(progress.length).toBeGreaterThan(0);
    expect(progress.at(-1)).toBe(archive.length);
    await resolved.discard();
  });

  it("aborts a download that exceeds the payload cap", async () => {
    const chunk = new Uint8Array(1024 * 1024);
    let sent = 0;
    const stream = new ReadableStream<Uint8Array>({
      pull(controller) {
        if (sent < 65) {
          sent += 1;
          controller.enqueue(chunk);
        } else {
          controller.close();
        }
      },
    });
    const { fetchImpl } = fakeFetch([
      ["https://example.test/huge.zip", () => new Response(stream)],
    ]);

    await expect(
      createSourceResolver({ fetchImpl, stagingRoot }).resolve({
        kind: "zip",
        url: "https://example.test/huge.zip",
      }),
    ).rejects.toBeInstanceOf(PluginSourceError);
    expect(sent).toBeLessThanOrEqual(65);
    expect(await readdir(stagingRoot)).toEqual([]);
  });

  it("rejects non-http(s) URLs before fetching", async () => {
    const { fetchImpl, calls } = fakeFetch([]);
    await expect(
      createSourceResolver({ fetchImpl, stagingRoot }).resolve({
        kind: "zip",
        url: "file:///etc/passwd",
      }),
    ).rejects.toBeInstanceOf(PluginSourceError);
    expect(calls).toEqual([]);
  });
});

describe("createSourceResolver — paste", () => {
  it("writes .mcp.json and plugin.json for a valid pasted config", async () => {
    const config = JSON.stringify({
      mcpServers: { fetch: { command: "npx", args: ["fetch-mcp"] } },
    });

    const resolved = await createSourceResolver({ stagingRoot }).resolve({
      kind: "paste",
      label: "demo",
      config,
    });

    const mcpJson = await readFile(join(resolved.stagingDir, ".mcp.json"), "utf8");
    const pluginJson = JSON.parse(
      await readFile(join(resolved.stagingDir, "plugin.json"), "utf8"),
    ) as Record<string, unknown>;
    expect(parseMcpConfig(mcpJson)).toHaveLength(1);
    expect(pluginJson.name).toBe("demo");
    expect(resolved.provenance).toEqual({ kind: "paste" });
    expect(resolved.bytes).toBe(Buffer.byteLength(config, "utf8"));
    await resolved.discard();
  });

  it("accepts Codex TOML paste input", async () => {
    const config = '[mcp_servers.demo]\ncommand = "npx"\nargs = ["demo-mcp"]\n';
    const resolved = await createSourceResolver({ stagingRoot }).resolve({
      kind: "paste",
      label: "codex",
      config,
    });
    const parsed = parseMcpConfig(
      await readFile(join(resolved.stagingDir, ".mcp.json"), "utf8"),
    );
    expect(parsed[0]?.name).toBe("demo");
    await resolved.discard();
  });

  it("keeps ${VAR} placeholders literal instead of leaking process env values", async () => {
    process.env.OVID_PLUGIN_TEST_SECRET = "super-secret-value";
    try {
      const config = JSON.stringify({
        mcpServers: {
          demo: {
            command: "npx",
            env: { TOKEN: "${OVID_PLUGIN_TEST_SECRET}" },
          },
        },
      });
      const resolved = await createSourceResolver({ stagingRoot }).resolve({
        kind: "paste",
        label: "secret",
        config,
      });
      const written = await readFile(join(resolved.stagingDir, ".mcp.json"), "utf8");
      expect(written).toContain("${OVID_PLUGIN_TEST_SECRET}");
      expect(written).not.toContain("super-secret-value");
      await resolved.discard();
    } finally {
      delete process.env.OVID_PLUGIN_TEST_SECRET;
    }
  });

  it("rejects a paste over 1 MiB and discards staging", async () => {
    await expect(
      createSourceResolver({ stagingRoot }).resolve({
        kind: "paste",
        label: "huge",
        config: "x".repeat(MAX_PASTE_BYTES + 1),
      }),
    ).rejects.toBeInstanceOf(PluginSourceError);
    expect(await readdir(stagingRoot)).toEqual([]);
  });

  it("rejects invalid pasted config", async () => {
    await expect(
      createSourceResolver({ stagingRoot }).resolve({
        kind: "paste",
        label: "bad",
        config: "{not json",
      }),
    ).rejects.toBeInstanceOf(PluginSourceError);
    expect(await readdir(stagingRoot)).toEqual([]);
  });
});

describe("createSourceResolver — lifecycle", () => {
  it("discard() removes the staging directory and is idempotent", async () => {
    const resolved = await createSourceResolver({ stagingRoot }).resolve({
      kind: "paste",
      label: "demo",
      config: JSON.stringify({ mcpServers: { x: { command: "npx" } } }),
    });
    await access(resolved.stagingDir);
    await resolved.discard();
    await expect(access(resolved.stagingDir)).rejects.toMatchObject({ code: "ENOENT" });
    await resolved.discard();
  });

  it("exports the documented caps", () => {
    expect(MAX_PAYLOAD_BYTES).toBe(64 * 1024 * 1024);
    expect(MAX_METADATA_BYTES).toBe(4 * 1024 * 1024);
    expect(MAX_PASTE_BYTES).toBe(1024 * 1024);
  });
});
