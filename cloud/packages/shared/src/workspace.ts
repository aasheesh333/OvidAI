import { z } from "zod";

// ---------------------------------------------------------------------------
// P7 Task 3: workspace/artifact protocol (ADDITIVE).
//
// Consumed by the workspace state-hydrator (Tasks 4, 6), the browser package
// (Task 6/9) and the gateway routes (Tasks 11–13). Everything here is wire
// contract only — no storage or worker logic lives in @ovid/shared.
// ---------------------------------------------------------------------------

/**
 * Spec G7 "<5 KB": the UI manifest budget. This bounds the PRUNED tree the
 * client renders (spike §9.3/§9.4) — NOT the full workspace listing, which
 * can be arbitrarily large and is served through the live/explore routes.
 */
export const UI_MANIFEST_MAX_BYTES = 5120;

/** Files up to this size are answered inline (base64); larger get a redirect. */
export const DEFAULT_FILE_INLINE_MAX_BYTES = 1_048_576;

/** Presigned download/upload URL lifetime for workspace files and artifacts. */
export const DEFAULT_PRESIGN_TTL_SECONDS = 3600;

/**
 * How long a client that triggered hydration (or hit a "cold" workspace)
 * waits on the hydrate endpoint before falling back to polling the tree
 * (source: "manifest" with state "hydrating").
 */
export const DEFAULT_HYDRATE_WAIT_MS = 20_000;

export type FileNodeType = "dir" | "file" | "symlink";

export interface FileTreeNode {
  name: string;
  path: string;
  type: FileNodeType;
  sizeBytes?: number;
  /** ISO-8601, second precision (spike §9.1 — no millisecond component). */
  mtime?: string;
  /** Dirs only, present when within depth budget. */
  children?: FileTreeNode[];
  /** Dir rollups (present on pruned dirs). */
  files?: number;
  bytes?: number;
  dirs?: number;
  /** Siblings dropped from `children` to stay ≤ UI_MANIFEST_MAX_BYTES. */
  omitted?: number;
}

export interface UiManifest {
  version: 1;
  generatedAt: string;
  truncated: boolean;
  totals: { files: number; dirs: number; bytes: number };
  roots: FileTreeNode[];
}

export type WorkspaceState = "warm" | "hydrating" | "cold" | "hibernating";

/** GET /cloud/v1/sessions/:id/workspace/tree answer. */
export interface WorkspaceTreeResponse {
  sessionId: string;
  state: WorkspaceState;
  generation: number;
  source: "manifest" | "live";
  tree: UiManifest;
}

/** GET /cloud/v1/sessions/:id/workspace/file answer (inline variant). */
export interface WorkspaceFileResponse {
  path: string;
  sizeBytes: number;
  contentType: string;
  encoding: "utf8" | "base64";
  content: string;
}

/** GET /cloud/v1/sessions/:id/workspace/file answer (presigned redirect variant). */
export interface WorkspaceFileRedirect {
  path: string;
  sizeBytes: number;
  contentType: string;
  downloadUrl: string;
  expiresAt: string;
}

/** PUT /cloud/v1/sessions/:id/workspace/file body — exactly one content field. */
export interface PutWorkspaceFileBody {
  path: string;
  contentBase64?: string;
  contentUtf8?: string;
}

/** PUT /cloud/v1/sessions/:id/workspace/file answer. */
export interface WorkspaceFileWriteResponse {
  path: string;
  sizeBytes: number;
  sha256: string;
}

/** A stored artifact as it appears on the wire. */
export interface ArtifactDto {
  id: string;
  sessionId: string;
  name: string;
  sizeBytes: number;
  contentType: string;
  createdAt: string;
}

/** GET /cloud/v1/sessions/:id/artifacts/:artifactId/url answer. */
export interface ArtifactUrlResponse {
  url: string;
  expiresAt: string;
}

// ---------------------------------------------------------------------------
// Zod schemas
// ---------------------------------------------------------------------------

export const fileTreeNodeSchema: z.ZodType<FileTreeNode> = z.lazy(() =>
  z.object({
    name: z.string().min(1),
    path: z.string().min(1),
    type: z.enum(["dir", "file", "symlink"]),
    sizeBytes: z.number().int().nonnegative().optional(),
    mtime: z.string().min(1).optional(),
    children: z.array(fileTreeNodeSchema).optional(),
    files: z.number().int().nonnegative().optional(),
    bytes: z.number().int().nonnegative().optional(),
    dirs: z.number().int().nonnegative().optional(),
    omitted: z.number().int().nonnegative().optional(),
  }),
);

export const uiManifestSchema: z.ZodType<UiManifest> = z.object({
  version: z.literal(1),
  generatedAt: z.string().min(1),
  truncated: z.boolean(),
  totals: z.object({
    files: z.number().int().nonnegative(),
    dirs: z.number().int().nonnegative(),
    bytes: z.number().int().nonnegative(),
  }),
  roots: z.array(fileTreeNodeSchema),
});

export const workspaceTreeResponseSchema: z.ZodType<WorkspaceTreeResponse> = z.object({
  sessionId: z.string().min(1),
  state: z.enum(["warm", "hydrating", "cold", "hibernating"]),
  generation: z.number().int().nonnegative(),
  source: z.enum(["manifest", "live"]),
  tree: uiManifestSchema,
});

export const workspaceFileResponseSchema: z.ZodType<WorkspaceFileResponse> = z.object({
  path: z.string().min(1),
  sizeBytes: z.number().int().nonnegative(),
  contentType: z.string().min(1),
  encoding: z.enum(["utf8", "base64"]),
  content: z.string(),
});

export const workspaceFileRedirectSchema: z.ZodType<WorkspaceFileRedirect> = z.object({
  path: z.string().min(1),
  sizeBytes: z.number().int().nonnegative(),
  contentType: z.string().min(1),
  downloadUrl: z.string().min(1),
  expiresAt: z.string().min(1),
});

export const putWorkspaceFileBodySchema: z.ZodType<PutWorkspaceFileBody> = z
  .object({
    path: z.string().min(1),
    contentBase64: z.string().optional(),
    contentUtf8: z.string().optional(),
  })
  .strict()
  .refine(
    (body) =>
      (body.contentBase64 !== undefined ? 1 : 0) + (body.contentUtf8 !== undefined ? 1 : 0) === 1,
    { message: "Exactly one of 'contentBase64' or 'contentUtf8' is required." },
  );

export const workspaceFileWriteResponseSchema: z.ZodType<WorkspaceFileWriteResponse> = z.object({
  path: z.string().min(1),
  sizeBytes: z.number().int().nonnegative(),
  sha256: z.string().min(1),
});

export const artifactDtoSchema: z.ZodType<ArtifactDto> = z.object({
  id: z.string().min(1),
  sessionId: z.string().min(1),
  name: z.string().min(1),
  sizeBytes: z.number().int().nonnegative(),
  contentType: z.string().min(1),
  createdAt: z.string().min(1),
});

export const artifactUrlResponseSchema: z.ZodType<ArtifactUrlResponse> = z.object({
  url: z.string().min(1),
  expiresAt: z.string().min(1),
});

/**
 * `artifact_created` event payload (events.ts carries the envelope; the
 * payload schema lives here with the rest of the workspace protocol).
 */
export const artifactCreatedPayloadSchema = z
  .object({
    artifactId: z.string().min(1),
    name: z.string().min(1),
    sessionId: z.string().min(1),
    sizeBytes: z.number().int().nonnegative(),
    contentType: z.string().min(1),
    url: z.string().min(1),
    expiresAt: z.string().min(1),
  })
  .strict();

export type ArtifactCreatedPayload = z.infer<typeof artifactCreatedPayloadSchema>;

/**
 * `workspace_hibernated` / `workspace_hydrated` event payload.
 * `archiveBytes` (hibernated) and `ms` (hydrated) are set when the actor
 * knows them and omitted otherwise — clients must treat both as optional.
 */
export const workspaceStatePayloadSchema = z
  .object({
    generation: z.number().int().nonnegative(),
    archiveBytes: z.number().int().nonnegative().optional(),
    ms: z.number().int().nonnegative().optional(),
  })
  .strict();

export type WorkspaceStatePayload = z.infer<typeof workspaceStatePayloadSchema>;
