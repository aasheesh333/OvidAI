// Plugin source resolver: GitHub / npm (SRI-verified) / ZIP URL / pasted
// MCP config. Every egress call goes through the injected GuardedFetch
// (default: @ovid/mcp's SSRF guard). Each source is staged under
// `<stagingRoot>/<uuidv7>` and only validated archives are extracted.
//
// Caps: MAX_PAYLOAD_BYTES on downloaded + decoded bytes, MAX_METADATA_BYTES
// on registry/tree JSON, MAX_PASTE_BYTES on pasted configs.

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve as resolvePath, sep } from "node:path";
import { gunzipSync } from "node:zlib";
import { ConfigParseError, parseMcpConfig } from "../configParse.js";
import {
  TooManyRedirectsError,
  followGuardedRedirects,
} from "../native/fetch.js";
import {
  SsrfBlockedError,
  createGuardedFetch,
  type GuardedFetch,
} from "../ssrf.js";
import {
  assertSafeLinkTarget,
  normalizeArchivePath,
  validateAndExtractArchive,
} from "./archive.js";
import {
  MAX_METADATA_BYTES,
  MAX_PASTE_BYTES,
  MAX_PAYLOAD_BYTES,
} from "./constants.js";
import { ArchiveUnsafeError, PluginSourceError } from "./errors.js";
import type { PluginSourceInput } from "./input.js";

// Re-exported here so callers that import the resolver get the contract and
// failure families from one module (the brief's @ovid/plugins sources.ts
// surface). The contract itself lives in ./input.ts pending the package split.
export type { PluginSourceInput } from "./input.js";
export { ArchiveUnsafeError, PluginSourceError } from "./errors.js";
export { MAX_METADATA_BYTES, MAX_PASTE_BYTES, MAX_PAYLOAD_BYTES } from "./constants.js";

export interface PluginProvenance {
  kind: string;
  githubRepo?: string;
  resolvedRef?: string;
  revision?: string;
  npmPackage?: string;
  npmVersion?: string;
  integrity?: string;
  url?: string;
}

export interface ResolvedSource {
  stagingDir: string;
  bytes: number;
  provenance: PluginProvenance;
  discard(): Promise<void>;
}

export interface SourceResolverDeps {
  fetchImpl?: GuardedFetch;
  githubApiBase?: string;
  npmRegistryBase?: string;
  stagingRoot?: string;
  /**
   * GitHub API token. Defaults to GITHUB_API_TOKEN (the worker's existing
   * variable). Without it the unauthenticated API allows only ~60 requests
   * per hour, which the per-file blob downloads exhaust almost immediately.
   */
  githubToken?: string;
}

export interface SourceResolver {
  resolve(
    input: PluginSourceInput,
    onProgress?: (bytes: number) => void,
  ): Promise<ResolvedSource>;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function uuidv7(): string {
  const buf = Buffer.alloc(16);
  buf.writeUIntBE(Date.now(), 0, 6);
  const rnd = randomBytes(10);
  buf[6] = 0x70 | (rnd[0]! & 0x0f);
  buf[7] = rnd[1]!;
  buf[8] = 0x80 | (rnd[2]! & 0x3f);
  rnd.copy(buf, 9, 3, 10);
  const hex = buf.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function concatChunks(chunks: Uint8Array[], total: number): Uint8Array {
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function decodeJson(bytes: Uint8Array, what: string): unknown {
  try {
    return JSON.parse(Buffer.from(bytes).toString("utf8"));
  } catch {
    throw new PluginSourceError(`${what} is not valid JSON`);
  }
}

function safeStagingPath(stagingDir: string, normalized: string): string {
  const root = resolvePath(stagingDir);
  const absolute = resolvePath(root, normalized);
  if (absolute !== root && !absolute.startsWith(root + sep)) {
    throw new PluginSourceError(`source path escapes staging: ${normalized}`);
  }
  return absolute;
}

/**
 * Read a response body, refusing to exceed `cap` bytes. Checks
 * Content-Length first, then aborts the stream mid-flight as soon as the
 * running total crosses the cap.
 */
async function readBodyCapped(
  response: Response,
  cap: number,
  label: string,
  onProgress?: (bytes: number) => void,
): Promise<Uint8Array> {
  const contentLength = response.headers.get("content-length");
  if (contentLength !== null) {
    const declared = Number(contentLength);
    if (Number.isFinite(declared) && declared > cap) {
      try {
        await response.body?.cancel();
      } catch {
        // body already closed
      }
      throw new PluginSourceError(`${label} exceeds ${cap} bytes`);
    }
  }

  if (response.body === null) {
    onProgress?.(0);
    return new Uint8Array(0);
  }

  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value === undefined) continue;
    total += value.byteLength;
    if (total > cap) {
      try {
        await reader.cancel();
      } catch {
        // body already closed
      }
      throw new PluginSourceError(`${label} exceeds ${cap} bytes`);
    }
    chunks.push(value);
    onProgress?.(total);
  }
  return concatChunks(chunks, total);
}

function validateGithubCoordinate(value: string, label: string): void {
  if (
    value.length === 0 ||
    value.length > 200 ||
    !/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(value) ||
    value.includes("..")
  ) {
    throw new PluginSourceError(`invalid GitHub ${label}`);
  }
}

function validateGitRef(ref: string): void {
  if (ref.length === 0 || ref.length > 500 || !/^[A-Za-z0-9._/-]+$/.test(ref)) {
    throw new PluginSourceError("invalid GitHub ref");
  }
  for (const segment of ref.split("/")) {
    if (segment === "" || segment === "." || segment === "..") {
      throw new PluginSourceError("invalid GitHub ref");
    }
  }
}

function encodeGitRef(ref: string): string {
  return ref
    .split("/")
    .map((segment) => encodeURIComponent(segment))
    .join("/");
}

const NPM_NAME = /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/;

function validateNpmPackage(name: string): void {
  if (name.length === 0 || name.length > 214 || !NPM_NAME.test(name) || name.includes("..")) {
    throw new PluginSourceError("invalid npm package name");
  }
}

function validateNpmVersion(version: string): void {
  if (
    version.length === 0 ||
    version.length > 100 ||
    version.includes("..") ||
    !/^[A-Za-z0-9][A-Za-z0-9.+_-]*$/.test(version)
  ) {
    throw new PluginSourceError("invalid npm version");
  }
}

function encodeNpmName(name: string): string {
  // Scoped packages use the registry's `@scope%2Fname` spelling; the @ stays
  // literal. Unscoped names are URL-safe already (validated above).
  return name.startsWith("@") ? name.replace("/", "%2F") : name;
}

function verifySri(bytes: Uint8Array, integrity: string): void {
  const sha512 = integrity
    .trim()
    .split(/\s+/)
    .find((token) => token.startsWith("sha512-"));
  if (sha512 === undefined) {
    throw new PluginSourceError("npm tarball has no sha512 integrity value");
  }
  const expected = Buffer.from(sha512.slice("sha512-".length), "base64");
  const actual = createHash("sha512").update(bytes).digest();
  if (
    expected.length !== actual.length ||
    !timingSafeEqual(expected, actual)
  ) {
    throw new PluginSourceError("npm tarball integrity mismatch");
  }
}

// ---------------------------------------------------------------------------
// Resolver
// ---------------------------------------------------------------------------

export function createSourceResolver(deps: SourceResolverDeps = {}): SourceResolver {
  const fetchImpl = deps.fetchImpl ?? createGuardedFetch();
  const githubApiBase = (deps.githubApiBase ?? "https://api.github.com").replace(/\/+$/, "");
  const npmRegistryBase = (deps.npmRegistryBase ?? "https://registry.npmjs.org").replace(
    /\/+$/,
    "",
  );
  const stagingRoot = deps.stagingRoot ?? join(tmpdir(), "ovid-plugin-staging");
  const githubToken = deps.githubToken ?? process.env.GITHUB_API_TOKEN;

  /**
   * Every resolver request goes through followGuardedRedirects: the stack is
   * told redirect:"manual" and each Location is re-entered through the
   * injected guard, so a public 302 to 169.254.169.254 (or any internal
   * host) is classified and refused before the hop is followed.
   */
  async function guardedFetch(url: string, init?: RequestInit): Promise<Response> {
    try {
      return await followGuardedRedirects(fetchImpl, url, init);
    } catch (error) {
      if (
        error instanceof SsrfBlockedError ||
        (error instanceof Error && error.name === "SsrfBlockedError")
      ) {
        throw new PluginSourceError(
          `source URL was blocked by the egress guard: ${error.message}`,
        );
      }
      if (error instanceof TooManyRedirectsError) {
        throw new PluginSourceError("source URL redirected too many times");
      }
      throw error;
    }
  }

  function githubHeaders(): Record<string, string> {
    const headers: Record<string, string> = {
      accept: "application/vnd.github+json",
      "user-agent": "ovid-plugin-resolver",
    };
    if (githubToken !== undefined && githubToken !== "") {
      headers.authorization = `Bearer ${githubToken}`;
    }
    return headers;
  }

  async function createStagingDir(): Promise<string> {
    await mkdir(stagingRoot, { recursive: true, mode: 0o700 });
    const dir = join(stagingRoot, uuidv7());
    // 0700: staged configs may contain literal credentials (pasted input).
    await mkdir(dir, { recursive: false, mode: 0o700 });
    return dir;
  }

  async function resolveGithub(
    input: Extract<PluginSourceInput, { kind: "github" }>,
    stagingDir: string,
    onProgress?: (bytes: number) => void,
  ): Promise<{ bytes: number; provenance: PluginProvenance }> {
    validateGithubCoordinate(input.owner, "owner");
    validateGithubCoordinate(input.repo, "repository");
    const ref = input.ref ?? "HEAD";
    validateGitRef(ref);

    const treeUrl =
      `${githubApiBase}/repos/${encodeURIComponent(input.owner)}/` +
      `${encodeURIComponent(input.repo)}/git/trees/${encodeGitRef(ref)}?recursive=1`;
    const treeResponse = await guardedFetch(treeUrl, { headers: githubHeaders() });
    if (!treeResponse.ok) {
      throw new PluginSourceError(`GitHub tree request failed (${treeResponse.status})`);
    }
    const treeBytes = await readBodyCapped(
      treeResponse,
      MAX_METADATA_BYTES,
      "GitHub tree metadata",
    );
    const tree = decodeJson(treeBytes, "GitHub tree metadata");
    if (!isRecord(tree) || !Array.isArray(tree.tree)) {
      throw new PluginSourceError("GitHub tree response has an unexpected shape");
    }
    if (tree.truncated === true) {
      // A partial tree would silently install an incomplete plugin.
      throw new PluginSourceError("GitHub tree is truncated (too many entries)");
    }

    let total = 0;
    for (const raw of tree.tree) {
      if (!isRecord(raw)) continue;
      const path = typeof raw.path === "string" ? raw.path : "";
      const type = typeof raw.type === "string" ? raw.type : "";
      const mode = typeof raw.mode === "string" ? raw.mode : "";
      if (type !== "blob") continue; // trees, submodule commits
      if (mode === "160000") continue; // submodule
      if (path === "" || typeof raw.sha !== "string") {
        throw new PluginSourceError("GitHub tree entry is missing path/sha");
      }
      let normalized: string;
      try {
        normalized = normalizeArchivePath(path);
      } catch (error) {
        // One failure family for every GitHub validation rejection.
        if (error instanceof ArchiveUnsafeError) {
          throw new PluginSourceError(error.message);
        }
        throw error;
      }
      if (normalized === "") {
        throw new PluginSourceError("GitHub tree entry resolves to the repository root");
      }

      const blobUrl =
        `${githubApiBase}/repos/${encodeURIComponent(input.owner)}/` +
        `${encodeURIComponent(input.repo)}/git/blobs/${encodeURIComponent(raw.sha)}`;
      const blobResponse = await guardedFetch(blobUrl, { headers: githubHeaders() });
      if (!blobResponse.ok) {
        throw new PluginSourceError(`GitHub blob request failed (${blobResponse.status})`);
      }
      const blobBytes = await readBodyCapped(
        blobResponse,
        Math.ceil((MAX_PAYLOAD_BYTES * 4) / 3) + 4096,
        "GitHub blob response",
      );
      const blob = decodeJson(blobBytes, "GitHub blob response");
      if (!isRecord(blob) || typeof blob.content !== "string") {
        throw new PluginSourceError("GitHub blob response has an unexpected shape");
      }
      const data =
        blob.encoding === "base64"
          ? Buffer.from(blob.content, "base64")
          : Buffer.from(blob.content, "utf8");

      // Count every downloaded blob toward the aggregate BEFORE branching:
      // a symlink blob is still bytes the worker downloaded and decoded.
      total += data.length;
      if (total > MAX_PAYLOAD_BYTES) {
        throw new PluginSourceError(
          `GitHub source exceeds ${MAX_PAYLOAD_BYTES} bytes`,
        );
      }

      if (mode === "120000") {
        // Symlink blob: validate the target, then never materialise the link.
        // Same 4096-byte target cap as ZIP symlink entries.
        if (data.length > 4096) {
          throw new PluginSourceError("GitHub symlink target is unreasonably large");
        }
        const target = data.toString("utf8");
        try {
          assertSafeLinkTarget(normalized, target, "symlink");
        } catch (error) {
          if (error instanceof ArchiveUnsafeError) {
            throw new PluginSourceError(error.message);
          }
          throw error;
        }
        continue;
      }

      const absolute = safeStagingPath(stagingDir, normalized);
      await mkdir(dirname(absolute), { recursive: true });
      await writeFile(absolute, data);
      onProgress?.(total);
    }

    return {
      bytes: total,
      provenance: {
        kind: "github",
        githubRepo: `${input.owner}/${input.repo}`,
        resolvedRef: ref,
        revision: typeof tree.sha === "string" ? tree.sha : ref,
      },
    };
  }

  async function resolveNpm(
    input: Extract<PluginSourceInput, { kind: "npm" }>,
    stagingDir: string,
    onProgress?: (bytes: number) => void,
  ): Promise<{ bytes: number; provenance: PluginProvenance }> {
    validateNpmPackage(input.package);
    const requested = input.version ?? "latest";
    validateNpmVersion(requested);

    const metadataUrl = `${npmRegistryBase}/${encodeNpmName(input.package)}`;
    const metadataResponse = await guardedFetch(metadataUrl, {
      headers: { accept: "application/json", "user-agent": "ovid-plugin-resolver" },
    });
    if (!metadataResponse.ok) {
      throw new PluginSourceError(`npm registry request failed (${metadataResponse.status})`);
    }
    const metadata = decodeJson(
      await readBodyCapped(metadataResponse, MAX_METADATA_BYTES, "npm metadata"),
      "npm metadata",
    );
    if (!isRecord(metadata)) {
      throw new PluginSourceError("npm metadata has an unexpected shape");
    }
    const versions = isRecord(metadata.versions) ? metadata.versions : {};
    const distTags = isRecord(metadata["dist-tags"]) ? metadata["dist-tags"] : {};

    let version = requested;
    if (!isRecord(versions[version])) {
      const tagged = distTags[version];
      if (typeof tagged === "string" && isRecord(versions[tagged])) {
        version = tagged;
      } else {
        throw new PluginSourceError(`npm version "${requested}" was not found`);
      }
    }
    const manifest = versions[version];
    if (!isRecord(manifest) || !isRecord(manifest.dist)) {
      throw new PluginSourceError("npm version metadata has no dist object");
    }
    const tarball = manifest.dist.tarball;
    const integrity = manifest.dist.integrity;
    if (typeof tarball !== "string" || typeof integrity !== "string") {
      throw new PluginSourceError("npm dist metadata lacks tarball/integrity");
    }

    const tarballResponse = await guardedFetch(tarball, {
      headers: { "user-agent": "ovid-plugin-resolver" },
    });
    if (!tarballResponse.ok) {
      throw new PluginSourceError(`npm tarball request failed (${tarballResponse.status})`);
    }
    const archive = await readBodyCapped(
      tarballResponse,
      MAX_PAYLOAD_BYTES,
      "npm tarball",
      onProgress,
    );
    verifySri(archive, integrity);

    let tarBytes: Uint8Array;
    try {
      tarBytes = gunzipSync(Buffer.from(archive), {
        maxOutputLength: MAX_PAYLOAD_BYTES + 1,
      });
    } catch {
      throw new PluginSourceError("npm tarball could not be decompressed");
    }
    await validateAndExtractArchive({ bytes: tarBytes, format: "tar" }, stagingDir);

    return {
      bytes: archive.byteLength,
      provenance: {
        kind: "npm",
        npmPackage: input.package,
        npmVersion: version,
        integrity,
      },
    };
  }

  async function resolveZip(
    input: Extract<PluginSourceInput, { kind: "zip" }>,
    stagingDir: string,
    onProgress?: (bytes: number) => void,
  ): Promise<{ bytes: number; provenance: PluginProvenance }> {
    let url: URL;
    try {
      url = new URL(input.url);
    } catch {
      throw new PluginSourceError("invalid zip URL");
    }
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      throw new PluginSourceError("zip URL must use http or https");
    }

    const response = await guardedFetch(url.toString(), {
      headers: { "user-agent": "ovid-plugin-resolver" },
    });
    if (!response.ok) {
      throw new PluginSourceError(`zip download failed (${response.status})`);
    }
    const bytes = await readBodyCapped(response, MAX_PAYLOAD_BYTES, "zip payload", onProgress);
    await validateAndExtractArchive({ bytes, format: "zip" }, stagingDir);

    return {
      bytes: bytes.byteLength,
      provenance: { kind: "zip", url: input.url },
    };
  }

  async function resolvePaste(
    input: Extract<PluginSourceInput, { kind: "paste" }>,
    stagingDir: string,
    onProgress?: (bytes: number) => void,
  ): Promise<{ bytes: number; provenance: PluginProvenance }> {
    const bytes = Buffer.byteLength(input.config, "utf8");
    if (bytes > MAX_PASTE_BYTES) {
      throw new PluginSourceError(`pasted config exceeds ${MAX_PASTE_BYTES} bytes`);
    }
    if (input.config.trim() === "") {
      throw new PluginSourceError("pasted config is empty");
    }

    let imported;
    try {
      // An EMPTY env on purpose: pasted configs may carry `${SECRET}`
      // placeholders. Interpolating against the worker's process environment
      // would copy live credentials into the staged config, so unresolved
      // references stay literal for the install-time credential gate.
      imported = parseMcpConfig(input.config, { env: {} });
    } catch (error) {
      if (error instanceof ConfigParseError) {
        throw new PluginSourceError(`invalid pasted config: ${error.message}`);
      }
      throw error;
    }
    if (imported.length === 0) {
      throw new PluginSourceError("pasted config declares no MCP servers");
    }

    // Null prototype: a server literally named "__proto__" must survive
    // rather than hit the prototype setter.
    const servers: Record<string, unknown> = Object.create(null);
    for (const entry of imported) {
      const { name, ...rest } = entry;
      servers[name] = rest;
    }
    const mcpJson = JSON.stringify({ mcpServers: servers }, null, 2);
    const pluginJson = JSON.stringify(
      { name: input.label, mcpServers: servers },
      null,
      2,
    );
    await writeFile(join(stagingDir, ".mcp.json"), mcpJson, "utf8");
    await writeFile(join(stagingDir, "plugin.json"), pluginJson, "utf8");
    onProgress?.(bytes);

    return { bytes, provenance: { kind: "paste" } };
  }

  return {
    async resolve(input, onProgress) {
      const stagingDir = await createStagingDir();
      try {
        let resolved: { bytes: number; provenance: PluginProvenance };
        switch (input.kind) {
          case "github":
            resolved = await resolveGithub(input, stagingDir, onProgress);
            break;
          case "npm":
            resolved = await resolveNpm(input, stagingDir, onProgress);
            break;
          case "zip":
            resolved = await resolveZip(input, stagingDir, onProgress);
            break;
          case "paste":
            resolved = await resolvePaste(input, stagingDir, onProgress);
            break;
          default: {
            const unreachable: never = input;
            throw new PluginSourceError(
              `unsupported source kind: ${String((unreachable as { kind?: unknown }).kind)}`,
            );
          }
        }
        return {
          stagingDir,
          bytes: resolved.bytes,
          provenance: resolved.provenance,
          discard: async () => {
            await rm(stagingDir, { recursive: true, force: true });
          },
        };
      } catch (error) {
        await rm(stagingDir, { recursive: true, force: true });
        throw error;
      }
    },
  };
}
