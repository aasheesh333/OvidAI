import { z } from "zod";

// ---------------------------------------------------------------------------
// Wave 4 (Settings truthfulness) — wire contracts for the account-level
// settings the server now owns: push notifications, the BYOK key runs use,
// custom agent presets, memory files and the public service-status view.
// Every value here is enforced server-side (owner rule R4: a setting either
// works end to end against the cloud or it is not shown).
// ---------------------------------------------------------------------------

/** Model ids: printable, no control characters. */
// eslint-disable-next-line no-control-regex
const MODEL_ID_RE = /^[^\u0000-\u001f\u007f]+$/;

/** The escrowed key (and the provider model) every run of the user uses. */
export interface ByokDefault {
  keyId: string;
  model: string;
}

/**
 * GET/PATCH /cloud/v1/settings.
 *  - notificationsEnabled=false: the worker sends no push to any of the
 *    user's devices (run finished / failed / needs approval).
 *  - byokDefault: when set, every run (chat and scheduled) is routed to the
 *    user's own provider key with this model instead of Ovid's models, so it
 *    is not metered against the Ovid allowance. null = Ovid models.
 */
export interface AccountSettings {
  notificationsEnabled: boolean;
  byokDefault: ByokDefault | null;
}

export const DEFAULT_ACCOUNT_SETTINGS: AccountSettings = Object.freeze({
  notificationsEnabled: true,
  byokDefault: null,
}) as AccountSettings;

export const byokDefaultSchema = z
  .object({
    keyId: z.string().uuid(),
    model: z.string().trim().min(1).max(160).regex(MODEL_ID_RE),
  })
  .strict();

export const accountSettingsPatchSchema = z
  .object({
    notificationsEnabled: z.boolean().optional(),
    byokDefault: byokDefaultSchema.nullable().optional(),
  })
  .strict()
  .refine((b) => b.notificationsEnabled !== undefined || b.byokDefault !== undefined, {
    message: "At least one of 'notificationsEnabled' or 'byokDefault' is required.",
  });

export type AccountSettingsPatch = z.infer<typeof accountSettingsPatchSchema>;

// ---------------------------------------------------------------------------
// Custom agent presets (SE-007)
// ---------------------------------------------------------------------------

/**
 * The tool families a custom preset may switch off, in user words. Each group
 * names every server tool id of that family (the cloud roster has a few
 * aliases per family — the legacy v0 file tools and the sandbox tools), so a
 * denied group can never be reached through a sibling name.
 */
export const PRESET_TOOL_GROUPS = Object.freeze([
  {
    id: "shell",
    label: "Run commands and code",
    tools: ["run_shell", "run_code", "job_start", "job_kill"],
  },
  {
    id: "file_edits",
    label: "Create and edit files",
    tools: ["write_file", "edit_file", "file_write", "fs_edit", "multi_edit", "str_replace", "notebook_edit"],
  },
  { id: "web", label: "Web search and fetch", tools: ["web_search", "fetch_url"] },
  {
    id: "browser",
    label: "Cloud browser",
    tools: [
      "browser_navigate", "browser_open", "browser_evaluate", "browser_snapshot", "browser_read",
      "browser_scroll", "browser_type", "browser_click", "browser_press_key", "browser_wait_for",
      "browser_resize", "browser_new_tab", "browser_switch_tab", "browser_list_tabs",
      "browser_close_tab", "browser_close", "browser_tabs",
    ],
  },
  {
    id: "images",
    label: "Image generation and editing",
    tools: ["generate_image", "edit_image", "edit_images", "resize_image", "crop_image"],
  },
  { id: "git", label: "Git (clone, pull, push)", tools: ["git_clone", "git_pull", "git_push"] },
  { id: "subagents", label: "Background subagents", tools: ["dispatch_agent", "workflow", "ralph"] },
  {
    id: "schedules",
    label: "Create or change schedules",
    tools: ["schedule_create", "schedule_update", "schedule_delete"],
  },
  { id: "memory_save", label: "Save memories", tools: ["memory_save"] },
] as const);

export type PresetToolGroupId = (typeof PRESET_TOOL_GROUPS)[number]["id"];

/** Every tool id a custom preset may deny. */
export const GATEABLE_TOOL_NAMES: ReadonlySet<string> = new Set(
  PRESET_TOOL_GROUPS.flatMap((g) => [...g.tools]),
);

export const CUSTOM_PRESET_ID_RE = /^custom-[a-z0-9][a-z0-9-]{0,39}$/;
export const MAX_CUSTOM_PRESETS = 20;

export interface CustomPreset {
  id: string;
  label: string;
  description: string;
  /** Server tool ids this preset removes from the roster (and refuses). */
  deniedTools: string[];
  /** Ovid Cloud model pin for this preset's runs (null = the chat's model). */
  model: string | null;
  /** Sampling temperature 0..2 (null = the provider default). */
  temperature: number | null;
}

/** PUT /presets/:id body (the id rides the path). */
export const customPresetBodySchema = z
  .object({
    label: z.string().trim().min(1).max(60),
    description: z.string().trim().max(200).default(""),
    deniedTools: z
      .array(z.string().refine((t) => GATEABLE_TOOL_NAMES.has(t), { message: "Unknown tool." }))
      .max(64)
      .default([]),
    model: z.string().trim().min(1).max(160).regex(MODEL_ID_RE).nullable().default(null),
    temperature: z.number().min(0).max(2).nullable().default(null),
  })
  .strict();

export type CustomPresetBody = z.infer<typeof customPresetBodySchema>;

/** PUT /sessions/:id/preset body — a built-in id or one of the user's custom ids. */
export const sessionPresetBodySchema = z.object({ presetId: z.string().min(1).max(64) }).strict();

// ---------------------------------------------------------------------------
// Memory files (SE-006)
// ---------------------------------------------------------------------------

/** Shared memory is opt-in; existing files here are never imported into isolated chats. */
export const MEMORY_DIR = ".ovid/memory";

/** Session ids are trusted internal ids here; REST additionally requires an owned UUID. */
export function memoryDirectoryFor(sessionId: string, shareSessionMemory = false): string {
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(sessionId)) throw new Error("A valid chat is required for memory.");
  return shareSessionMemory ? MEMORY_DIR : `.ovid/session-memory/${sessionId}`;
}

/**
 * A memory file name: a plain .md filename, at most 80 characters, no paths
 * (the same rule as agent-core's validateMemoryName). MEMORY.md is the
 * entrypoint; a case-variant of it is rejected.
 */
export function isValidMemoryName(name: string): boolean {
  return (
    name.length <= 80 &&
    /^[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)*\.md$/.test(name) &&
    !(name.toLowerCase() === "memory.md" && name !== "MEMORY.md")
  );
}

export interface MemoryFileSummary {
  name: string;
  sizeBytes: number;
}

export interface MemoryFileDto {
  name: string;
  content: string;
  /** sha256 of the content — send back as ifRevision to avoid lost updates. */
  revision: string;
}

export const memoryPutBodySchema = z
  .object({
    content: z.string().max(32 * 1024),
    ifRevision: z.string().regex(/^[0-9a-f]{64}$/).optional(),
  })
  .strict();

// ---------------------------------------------------------------------------
// Public service status (SE-014)
// ---------------------------------------------------------------------------

export type ServiceCheckState = "ok" | "degraded" | "down" | "unknown";

/**
 * GET /cloud/v1/health/status — unauthenticated and coarse on purpose: one
 * state per user-visible capability, never hostnames, versions, counts or
 * error text.
 */
export interface ServiceStatusDto {
  status: "ok" | "degraded" | "down";
  checks: {
    /** The API answered (always "ok" when this body arrives). */
    api: ServiceCheckState;
    /** Chats and history storage. */
    storage: ServiceCheckState;
    /** The run queue accepts work. */
    queue: ServiceCheckState;
    /** At least one agent worker is consuming the queue. */
    agents: ServiceCheckState;
    /** The model route has a usable model catalog. */
    models: ServiceCheckState;
  };
  checkedAt: string;
}
