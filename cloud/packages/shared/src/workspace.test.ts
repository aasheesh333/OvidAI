import { describe, expect, it } from "vitest";
import {
  DEFAULT_FILE_INLINE_MAX_BYTES,
  DEFAULT_HYDRATE_WAIT_MS,
  DEFAULT_PRESIGN_TTL_SECONDS,
  UI_MANIFEST_MAX_BYTES,
  artifactCreatedPayloadSchema,
  artifactDtoSchema,
  artifactUrlResponseSchema,
  makeWorkspaceDirBodySchema,
  moveWorkspacePathBodySchema,
  putWorkspaceFileBodySchema,
  uiManifestSchema,
  workspaceDeleteResponseSchema,
  workspaceMkdirResponseSchema,
  workspaceMoveResponseSchema,
  workspaceFileRedirectSchema,
  workspaceFileResponseSchema,
  workspaceFileWriteResponseSchema,
  workspaceStatePayloadSchema,
  workspaceTreeResponseSchema,
} from "./workspace.js";
import type { FileTreeNode, UiManifest } from "./workspace.js";
// Additive check: the pre-existing spine schemas must keep parsing untouched.
import { sessionDtoSchema } from "./rest.js";
import type { SessionDto } from "./rest.js";

const fileNode: FileTreeNode = {
  name: "main.py",
  path: "src/main.py",
  type: "file",
  sizeBytes: 1_234,
  mtime: "2026-10-16T10:00:00Z", // second precision, no millis (spike §9.1)
};

const prunedDir: FileTreeNode = {
  name: "src",
  path: "src",
  type: "dir",
  mtime: "2026-10-16T10:00:05Z",
  children: [fileNode],
  files: 4,
  bytes: 9_999,
  dirs: 1,
  omitted: 12, // siblings dropped to stay ≤ UI_MANIFEST_MAX_BYTES
};

const manifest: UiManifest = {
  version: 1,
  generatedAt: "2026-10-16T10:00:06Z",
  truncated: true,
  totals: { files: 57, dirs: 9, bytes: 123_456 },
  roots: [prunedDir, { name: "README.md", path: "README.md", type: "file", sizeBytes: 42 }],
};

describe("workspace constants (spec G7 / spike defaults)", () => {
  it("pins the protocol tuning knobs", () => {
    expect(UI_MANIFEST_MAX_BYTES).toBe(5_120);
    expect(DEFAULT_FILE_INLINE_MAX_BYTES).toBe(1_048_576);
    expect(DEFAULT_PRESIGN_TTL_SECONDS).toBe(3_600);
    expect(DEFAULT_HYDRATE_WAIT_MS).toBe(20_000);
  });
});

describe("uiManifestSchema", () => {
  it("round-trips a valid pruned tree (recursive nodes)", () => {
    expect(uiManifestSchema.parse(manifest)).toEqual(manifest);
  });

  it("round-trips a minimal manifest with empty roots and no rollups", () => {
    const minimal: UiManifest = {
      version: 1,
      generatedAt: "2026-10-16T10:00:00Z",
      truncated: false,
      totals: { files: 0, dirs: 0, bytes: 0 },
      roots: [],
    };
    expect(uiManifestSchema.parse(minimal)).toEqual(minimal);
  });

  it("round-trips symlink nodes", () => {
    const link: FileTreeNode = { name: "current", path: "current", type: "symlink" };
    const m: UiManifest = {
      version: 1,
      generatedAt: "2026-10-16T10:00:00Z",
      truncated: false,
      totals: { files: 0, dirs: 0, bytes: 0 },
      roots: [link],
    };
    expect(uiManifestSchema.parse(m)).toEqual(m);
  });

  it("rejects a wrong version, an unknown node type, and a non-integer rollup", () => {
    expect(() => uiManifestSchema.parse({ ...manifest, version: 2 })).toThrow();
    expect(() =>
      uiManifestSchema.parse({
        ...manifest,
        roots: [{ name: "x", path: "x", type: "socket" }],
      }),
    ).toThrow();
    expect(() =>
      uiManifestSchema.parse({ ...manifest, totals: { files: 1.5, dirs: 0, bytes: 0 } }),
    ).toThrow();
  });
});

describe("workspaceTreeResponseSchema", () => {
  const treeResponse = {
    sessionId: "01990b7a-2f6c-7d1e-8a3b-4c5d6e7f8090",
    state: "warm" as const,
    generation: 7,
    source: "manifest" as const,
    tree: manifest,
  };

  it("round-trips a valid response", () => {
    expect(workspaceTreeResponseSchema.parse(treeResponse)).toEqual(treeResponse);
  });

  it("accepts every workspace state and both sources", () => {
    for (const state of ["hydrating", "cold", "hibernating"] as const) {
      expect(workspaceTreeResponseSchema.parse({ ...treeResponse, state })).toEqual({
        ...treeResponse,
        state,
      });
    }
    expect(
      workspaceTreeResponseSchema.parse({ ...treeResponse, source: "live" }),
    ).toEqual({ ...treeResponse, source: "live" });
  });

  it("rejects an unknown state and a negative generation", () => {
    expect(() =>
      workspaceTreeResponseSchema.parse({ ...treeResponse, state: "frozen" }),
    ).toThrow();
    expect(() => workspaceTreeResponseSchema.parse({ ...treeResponse, generation: -1 })).toThrow();
  });
});

describe("workspaceFileResponseSchema", () => {
  it("round-trips utf8 and base64 bodies", () => {
    const utf8 = {
      path: "notes/todo.txt",
      sizeBytes: 11,
      contentType: "text/plain",
      encoding: "utf8" as const,
      content: "hello\nworld",
    };
    expect(workspaceFileResponseSchema.parse(utf8)).toEqual(utf8);

    const b64 = {
      path: "bin/app",
      sizeBytes: 4,
      contentType: "application/octet-stream",
      encoding: "base64" as const,
      content: "QUJD",
    };
    expect(workspaceFileResponseSchema.parse(b64)).toEqual(b64);
  });

  it("rejects an unknown encoding and a non-integer size", () => {
    const utf8 = {
      path: "a.txt",
      sizeBytes: 1,
      contentType: "text/plain",
      encoding: "utf8" as const,
      content: "x",
    };
    expect(() => workspaceFileResponseSchema.parse({ ...utf8, encoding: "hex" })).toThrow();
    expect(() => workspaceFileResponseSchema.parse({ ...utf8, sizeBytes: 1.5 })).toThrow();
  });
});

describe("workspaceFileRedirectSchema", () => {
  it("round-trips a presigned redirect", () => {
    const redirect = {
      path: "data/big.parquet",
      sizeBytes: 50_000_000,
      contentType: "application/octet-stream",
      downloadUrl: "https://example.r2.cloudflarestorage.com/bucket/o?sig=abc",
      expiresAt: "2026-10-16T11:00:00Z",
    };
    expect(workspaceFileRedirectSchema.parse(redirect)).toEqual(redirect);
  });

  it("rejects a missing downloadUrl", () => {
    const { downloadUrl: _noUrl, ...missing } = {
      path: "p",
      sizeBytes: 1,
      contentType: "application/octet-stream",
      downloadUrl: "u",
      expiresAt: "2026-10-16T11:00:00Z",
    };
    expect(() => workspaceFileRedirectSchema.parse(missing)).toThrow();
  });
});

describe("putWorkspaceFileBodySchema", () => {
  it("accepts each single-content form", () => {
    expect(putWorkspaceFileBodySchema.parse({ path: "a.txt", contentUtf8: "hi" })).toEqual({
      path: "a.txt",
      contentUtf8: "hi",
    });
    expect(putWorkspaceFileBodySchema.parse({ path: "a.bin", contentBase64: "aGk=" })).toEqual({
      path: "a.bin",
      contentBase64: "aGk=",
    });
  });

  it("rejects a body with no content field", () => {
    expect(() => putWorkspaceFileBodySchema.parse({ path: "a" })).toThrow();
  });

  it("rejects a body with both content fields", () => {
    expect(() =>
      putWorkspaceFileBodySchema.parse({ path: "a", contentBase64: "x", contentUtf8: "y" }),
    ).toThrow();
  });

  it("rejects an empty path and unknown keys (strict request body)", () => {
    expect(() => putWorkspaceFileBodySchema.parse({ path: "", contentUtf8: "y" })).toThrow();
    expect(() =>
      putWorkspaceFileBodySchema.parse({ path: "a", contentUtf8: "y", extra: 1 }),
    ).toThrow();
  });

  // Wave 2 (ST-005/ST-007): server-side write preconditions.
  it("accepts an ifMatchSha256 precondition (lowercase sha256 hex only)", () => {
    const sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    expect(
      putWorkspaceFileBodySchema.parse({ path: "a", contentUtf8: "y", ifMatchSha256: sha }),
    ).toEqual({ path: "a", contentUtf8: "y", ifMatchSha256: sha });
    expect(() =>
      putWorkspaceFileBodySchema.parse({ path: "a", contentUtf8: "y", ifMatchSha256: "abc" }),
    ).toThrow();
    expect(() =>
      putWorkspaceFileBodySchema.parse({
        path: "a",
        contentUtf8: "y",
        ifMatchSha256: sha.toUpperCase(),
      }),
    ).toThrow();
  });

  it("accepts ifNoneMatch:'*' (create-only) but never together with ifMatchSha256", () => {
    expect(
      putWorkspaceFileBodySchema.parse({ path: "a", contentUtf8: "", ifNoneMatch: "*" }),
    ).toEqual({ path: "a", contentUtf8: "", ifNoneMatch: "*" });
    expect(() =>
      putWorkspaceFileBodySchema.parse({ path: "a", contentUtf8: "", ifNoneMatch: "yes" }),
    ).toThrow();
    expect(() =>
      putWorkspaceFileBodySchema.parse({
        path: "a",
        contentUtf8: "",
        ifNoneMatch: "*",
        ifMatchSha256: "0".repeat(64),
      }),
    ).toThrow();
  });
});

describe("Studio file-management schemas (ST-008)", () => {
  it("move body is strict {from,to}", () => {
    expect(moveWorkspacePathBodySchema.parse({ from: "a", to: "b" })).toEqual({
      from: "a",
      to: "b",
    });
    expect(() => moveWorkspacePathBodySchema.parse({ from: "a" })).toThrow();
    expect(() => moveWorkspacePathBodySchema.parse({ from: "a", to: "b", x: 1 })).toThrow();
    expect(() => moveWorkspacePathBodySchema.parse({ from: "", to: "b" })).toThrow();
  });

  it("mkdir body is strict {path}", () => {
    expect(makeWorkspaceDirBodySchema.parse({ path: "src/new" })).toEqual({ path: "src/new" });
    expect(() => makeWorkspaceDirBodySchema.parse({ path: "" })).toThrow();
    expect(() => makeWorkspaceDirBodySchema.parse({ path: "a", recursive: true })).toThrow();
  });

  it("responses round-trip", () => {
    expect(workspaceDeleteResponseSchema.parse({ path: "a", type: "dir" })).toEqual({
      path: "a",
      type: "dir",
    });
    expect(() => workspaceDeleteResponseSchema.parse({ path: "a", type: "pipe" })).toThrow();
    expect(workspaceMoveResponseSchema.parse({ from: "a", to: "b" })).toEqual({
      from: "a",
      to: "b",
    });
    expect(workspaceMkdirResponseSchema.parse({ path: "a", created: false })).toEqual({
      path: "a",
      created: false,
    });
  });
});

describe("workspaceFileWriteResponseSchema", () => {
  it("round-trips a write receipt", () => {
    const receipt = {
      path: "uploads/report_final.pdf",
      sizeBytes: 2_048,
      sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    };
    expect(workspaceFileWriteResponseSchema.parse(receipt)).toEqual(receipt);
  });

  it("rejects a missing sha256", () => {
    expect(() =>
      workspaceFileWriteResponseSchema.parse({ path: "a", sizeBytes: 1 }),
    ).toThrow();
  });
});

describe("artifactDtoSchema / artifactUrlResponseSchema", () => {
  it("round-trips a valid artifact dto", () => {
    const dto = {
      id: "018f3e11-aaaa-7bbb-8ccc-2d2d2d2d2d2d",
      sessionId: "01990b7a-2f6c-7d1e-8a3b-4c5d6e7f8090",
      name: "figure_1.png",
      sizeBytes: 88_888,
      contentType: "image/png",
      createdAt: "2026-10-16T10:30:00Z",
    };
    expect(artifactDtoSchema.parse(dto)).toEqual(dto);
  });

  it("round-trips a presigned artifact url answer", () => {
    const res = {
      url: "https://example.r2.cloudflarestorage.com/bucket/a?sig=xyz",
      expiresAt: "2026-10-16T11:30:00Z",
    };
    expect(artifactUrlResponseSchema.parse(res)).toEqual(res);
  });

  it("rejects a negative sizeBytes on the dto", () => {
    expect(() =>
      artifactDtoSchema.parse({
        id: "a1",
        sessionId: "s1",
        name: "n",
        sizeBytes: -1,
        contentType: "image/png",
        createdAt: "2026-10-16T10:30:00Z",
      }),
    ).toThrow();
  });
});

describe("artifactCreatedPayloadSchema", () => {
  const payload = {
    artifactId: "018f3e11-aaaa-7bbb-8ccc-2d2d2d2d2d2d",
    name: "figure_1.png",
    sessionId: "01990b7a-2f6c-7d1e-8a3b-4c5d6e7f8090",
    sizeBytes: 88_888,
    contentType: "image/png",
    url: "https://example.r2.cloudflarestorage.com/bucket/a?sig=xyz",
    expiresAt: "2026-10-16T11:30:00Z",
  };

  it("round-trips a valid payload", () => {
    expect(artifactCreatedPayloadSchema.parse(payload)).toEqual(payload);
  });

  it("rejects a fractional sizeBytes (.int())", () => {
    expect(() => artifactCreatedPayloadSchema.parse({ ...payload, sizeBytes: 1.5 })).toThrow();
  });

  it("rejects a missing field and unknown keys (strict)", () => {
    const { url: _noUrl, ...missing } = payload;
    expect(() => artifactCreatedPayloadSchema.parse(missing)).toThrow();
    expect(() => artifactCreatedPayloadSchema.parse({ ...payload, extra: 1 })).toThrow();
  });
});

describe("workspaceStatePayloadSchema", () => {
  it("round-trips generation-only and full hydration payloads", () => {
    expect(workspaceStatePayloadSchema.parse({ generation: 3 })).toEqual({ generation: 3 });
    expect(
      workspaceStatePayloadSchema.parse({ generation: 4, archiveBytes: 12_345, ms: 850 }),
    ).toEqual({ generation: 4, archiveBytes: 12_345, ms: 850 });
  });

  it("rejects a negative generation, fractional ms, and unknown keys (strict)", () => {
    expect(() => workspaceStatePayloadSchema.parse({ generation: -1 })).toThrow();
    expect(() => workspaceStatePayloadSchema.parse({ generation: 0, ms: 1.5 })).toThrow();
    expect(() => workspaceStatePayloadSchema.parse({ generation: 0, extra: 1 })).toThrow();
  });
});

describe("spine additivity (rest.ts untouched)", () => {
  it("still parses a valid session dto", () => {
    const session: SessionDto = {
      id: "s1",
      title: null,
      mode: "auto",
      createdAt: "2026-10-15T12:00:00.000Z",
      updatedAt: "2026-10-15T12:00:00.000Z",
    };
    expect(sessionDtoSchema.parse(session)).toEqual(session);
  });
});
