// Re-export of the canonical plugin-source contract. The contract lives in
// @ovid/shared because the REST body, the plugin-installs queue job and the
// resolver all consume it (T14/T15 import it from @ovid/shared directly).
// This module keeps the @ovid/mcp barrel's surface stable for existing
// consumers.
export type { PluginSourceInput } from "@ovid/shared";
export { pluginSourceInputSchema } from "@ovid/shared";
