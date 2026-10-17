// The plugin-source wire contract — shared by REST bodies, the
// plugin-installs queue job and @ovid/plugins (the P5 plan's "contracts live
// in shared" ruling). Dependency-free beyond zod; semantic validation (npm
// name rules, ref safety, SSRF, byte caps) lives in the resolver so every
// entry point shares one set of checks.

import { z } from "zod";

export type PluginSourceInput =
  | { kind: "github"; owner: string; repo: string; ref?: string }
  | { kind: "npm"; package: string; version?: string }
  | { kind: "zip"; url: string }
  | { kind: "paste"; label: string; config: string };

/** Mirrors @ovid/mcp's MAX_PASTE_BYTES (1 MiB) for shape-level rejection. */
const MAX_PASTE_CONFIG_CHARS = 1024 * 1024;

/**
 * Discriminated union on `kind`. The schema enforces shape/lengths only;
 * the resolver re-checks semantics and the byte caps.
 */
export const pluginSourceInputSchema: z.ZodType<PluginSourceInput> =
  z.discriminatedUnion("kind", [
    z.object({
      kind: z.literal("github"),
      owner: z.string().min(1).max(100),
      repo: z.string().min(1).max(200),
      ref: z.string().min(1).max(500).optional(),
    }),
    z.object({
      kind: z.literal("npm"),
      package: z.string().min(1).max(214),
      version: z.string().min(1).max(100).optional(),
    }),
    z.object({
      kind: z.literal("zip"),
      url: z.string().min(1).max(4096),
    }),
    z.object({
      kind: z.literal("paste"),
      label: z.string().min(1).max(200),
      config: z.string().min(1).max(MAX_PASTE_CONFIG_CHARS),
    }),
  ]) as z.ZodType<PluginSourceInput>;
