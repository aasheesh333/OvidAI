// The plugin-source wire contract.
//
// The P5 plan homes this module in `@ovid/shared` (`src/plugins.ts`) because
// the REST body, the plugin-installs queue job and @ovid/plugins all consume
// it. This task's dispatch confines writes to `@ovid/mcp/src`, so the
// contract lives here for now; it is dependency-free and can move to
// @ovid/shared verbatim (the package split is a mechanical re-export).

import { z } from "zod";

export type PluginSourceInput =
  | { kind: "github"; owner: string; repo: string; ref?: string }
  | { kind: "npm"; package: string; version?: string }
  | { kind: "zip"; url: string }
  | { kind: "paste"; label: string; config: string };

/**
 * Discriminated union on `kind`. The schema only enforces shape/lengths;
 * semantic validation (npm name rules, ref safety, SSRF, caps) happens in
 * the resolver so every entry point shares one set of checks.
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
      config: z.string().min(1),
    }),
  ]) as z.ZodType<PluginSourceInput>;
