// Named agent presets (port of lib/core/presets.dart — the built-in,
// non-device presets). IDs are stable (persisted on sessions as presetId).
//
// Composition semantics (Dart `PresetRegistry.allows`):
//   • allowedTools non-empty → ALLOWLIST: only these tools run, plus the
//     harness set (orchestration is the harness, not a capability);
//   • allowedTools empty + deniedTools non-empty → DENYLIST;
//   • both empty → standard (nothing denied).
//
// Dart's per-preset `planAllowedTools` (G5) is not part of the cloud
// surface: the cloud plan carries only the built-in plan policy (Task 8's
// PLAN_ALLOWED_TOOLS), and RosterContext.preset carries the composition.

import { HARNESS_TOOLS } from "./planMode.js";

export interface AgentPreset {
  id: string;
  label: string;
  description: string;
  /** Non-empty → this preset is an ALLOWLIST (harness always kept). */
  allowedTools: string[];
  /** Non-empty (and allowedTools empty) → this preset is a DENYLIST. */
  deniedTools: string[];
  /** Extra persona preamble injected above the base system prompt. */
  persona: string;
  /** G3: optional model pin (null = the session's model). */
  model: string | null;
  /** Provider that owns [model] (a pin records which route it was). */
  modelProviderId: string | null;
  /** G3: optional sampling temperature (null = provider default). */
  temperature: number | null;
}

/** Shared result-format guidance appended to every built-in persona (Dart
 * `PresetRegistry.resultFormatGuidance`). */
const RESULT_FORMAT_GUIDANCE =
  " Lead with the answer. Present results as a visible markdown block " +
  "(short bullets or code), never buried inside reasoning or tool " +
  "narration.";

const standard: AgentPreset = {
  id: "standard",
  label: "Standard",
  description: "Full tool roster — the default Ovid agent.",
  allowedTools: [],
  deniedTools: [],
  persona: "",
  model: null,
  modelProviderId: null,
  temperature: null,
};

/// Lean everyday agent: no browser, no image-gen, no orchestration fan-out.
/// File + search + memory + git stay.
const minimal: AgentPreset = {
  id: "minimal",
  label: "Minimal",
  description:
    "Chat + files + search + memory — no browser, images, or subagent fan-out.",
  allowedTools: [],
  deniedTools: [
    "browser_navigate", "browser_open", "browser_evaluate",
    "browser_snapshot", "browser_read", "browser_scroll",
    "browser_type", "browser_click", "browser_press_key",
    "browser_wait_for", "browser_resize", "browser_new_tab",
    "browser_switch_tab", "browser_list_tabs", "browser_close_tab",
    "browser_close", "browser_tabs",
    "generate_image", "edit_image", "edit_images", "resize_image", "crop_image", "workflow", "ralph",
  ],
  persona:
    "You are a lean agent: prefer direct answers and small file " +
    "edits. Do not open browsers or spawn subagents." +
    RESULT_FORMAT_GUIDANCE,
  model: null,
  modelProviderId: null,
  temperature: null,
};

/// Studio authoring preset: generation-heavy, wide access, persona tuned for
/// long-form deliverables in the workspace.
const studio: AgentPreset = {
  id: "studio",
  label: "Studio",
  description:
    "Authoring preset — images, web research, files, with a deliverables-first persona.",
  allowedTools: [],
  deniedTools: [],
  persona:
    "You are a studio author. Always end a turn by writing the " +
    "deliverable (report/image/code) into the shared workspace, then " +
    "summarize what changed and where it lives." +
    RESULT_FORMAT_GUIDANCE,
  model: null,
  modelProviderId: null,
  temperature: null,
};

/// Code preset: repo work only — shell, files, git; no browser or image
/// generation.
const code: AgentPreset = {
  id: "code",
  label: "Code",
  description: "Repo work — shell, file edits, git. No browser or image generation.",
  allowedTools: [],
  deniedTools: [
    "browser_navigate", "browser_open", "browser_evaluate",
    "browser_snapshot", "browser_read", "browser_scroll",
    "browser_type", "browser_click", "browser_press_key",
    "browser_wait_for", "browser_resize", "browser_new_tab",
    "browser_switch_tab", "browser_list_tabs", "browser_close_tab",
    "browser_close", "browser_tabs",
    "generate_image", "edit_image", "edit_images", "resize_image", "crop_image",
  ],
  persona:
    "You are a coding agent inside the user's repository. " +
    "Read before editing, keep changes minimal, and never touch " +
    "files outside the workspace." +
    RESULT_FORMAT_GUIDANCE,
  model: null,
  modelProviderId: null,
  temperature: null,
};

/// Plan preset: the research-first planning policy (opencode `plan` agent
/// parity). Selecting it couples plan mode on at the session level (the
/// engine/gateway wiring, not data here), which is why it carries no roster
/// narrowing of its own — the plan projection in roster.ts does the gating.
/// The optional cheap-model pin (G3) is unset on the built-in: a session may
/// pin a cheap fast model for its planning runs without changing the chat
/// model.
const plan: AgentPreset = {
  id: "plan",
  label: "Plan",
  description: "Read-only planning — research the workspace, then propose.",
  allowedTools: [],
  deniedTools: [],
  persona:
    "You are the plan agent, in the READ-ONLY planning phase. Research " +
    "the current directory thoroughly BEFORE proposing anything: read " +
    "files, glob and grep, inspect git history and diffs, and run " +
    "read-only shell commands (ls, cat, find, wc, tree, git log/diff/" +
    "status). You may NOT modify anything — no file writes, no edits, no " +
    "commits, no commands that change state. When you understand the " +
    "problem, write the plan out as a normal message in numbered steps, " +
    "then call exit_plan_mode to offer switching to the build agent." +
    RESULT_FORMAT_GUIDANCE,
  model: null,
  modelProviderId: null,
  temperature: null,
};

// The nested tool lists are frozen too (runtime immutability at every
// level), but the AgentPreset fields keep the brief's pinned `string[]`
// type — the freeze is a runtime property, not a type change, hence the
// casts (Object.freeze's Readonly<T> narrowing would otherwise bleed into
// every consumer).
export const BUILT_IN_PRESETS: readonly AgentPreset[] = Object.freeze(
  [standard, minimal, studio, code, plan].map((p) =>
    Object.freeze({
      ...p,
      allowedTools: Object.freeze(p.allowedTools) as string[],
      deniedTools: Object.freeze(p.deniedTools) as string[],
    }),
  ),
);

/**
 * Look up a built-in preset by id. Null for a null/unknown id — callers
 * treat null as standard (Dart's `PresetRegistry.byId` falls back to the
 * standard preset; the null return IS that fallback signal, so an unknown
 * persisted presetId can never break a session).
 */
export function presetById(id: string | null): AgentPreset | null {
  if (id == null) return null;
  return BUILT_IN_PRESETS.find((p) => p.id === id) ?? null;
}

/**
 * Roster decision under [preset] for [tool] — the Dart `PresetRegistry.
 * allows` port, with the harness set re-exported from planMode.ts (G7: one
 * definition). Not called by computeToolRoster directly (that inlines the
 * same rule through isToolPermitted), but exported so Task 15's gate and any
 * preset UI answer identically.
 */
export function presetAllows(preset: AgentPreset, tool: string): boolean {
  if (preset.allowedTools.length > 0) {
    return preset.allowedTools.includes(tool) || HARNESS_TOOLS.has(tool);
  }
  return !preset.deniedTools.includes(tool);
}
