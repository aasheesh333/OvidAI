// The @ovid/mcp barrel. Cross-package consumers import ONLY from "." (the
// exports map exposes the package root alone) — deep-importing any module
// below fails with ERR_PACKAGE_PATH_NOT_EXPORTED, so every public surface
// must be re-exported here.
export * from "./jsonrpc.js";
export * from "./transport.js";
export * from "./client.js";
export * from "./backoff.js";
export * from "./ssrf.js";
export * from "./transports/http.js"; // incl. McpAuthRequiredError / McpSessionExpiredError
export * from "./transports/sse.js";
export * from "./transports/stdio.js";
export * from "./transports/native.js";
// Native in-process handlers (Task 5). WorkspaceFiles is re-exported
// explicitly (explicit beats star): transports/native.js still star-exports
// the permissive placeholder — R6: the worker seam (Task 16) adapts
// @ovid/sandbox to the real surface defined in workspace.ts.
export { WORKSPACE_ROOT, resolveWorkspacePath } from "./workspace.js";
export type { WorkspaceEntry, WorkspaceFiles } from "./workspace.js";
export * from "./native/github.js";
export * from "./native/filesystem.js";
export * from "./native/fetch.js";
export * from "./native/memory.js";
export * from "./configParse.js";
// P5 Task 8: P9-aligned envelope crypto shim (deleted once P9's @ovid/escrow
// lands and call sites swap imports — see crypto.ts header).
export * from "./crypto.js";
// P5 Task 9: MCP OAuth — RFC 9728/8414 discovery + DCR, server-side PKCE
// flow with the sealed token store (Task 15's gateway routes consume
// createOAuthFlow from this root; the exports map blocks deep imports).
export * from "./oauth/discovery.js";
export * from "./oauth/flow.js";
// P5 Task 10: worker-side system bus (the gateway hub's counterpart on the
// sys:{uid}:out / sys:{uid}:in channels; Task 15/16 consume it from this
// root — same barrel rule). UserSystemBus is declared ONCE, here (F9):
// Task 3's permissive forward-ref placeholder in transports/native.js is
// shadowed by this EXPLICIT re-export (explicit beats star — the same
// discipline as WorkspaceFiles above; the worker seam adapts the cast).
export {
  APPROVAL_TIMEOUT_MS,
  createRedisSystemBus,
  type SystemEventKind,
  type SystemResponse,
  type UserSystemBus,
} from "./systemBus.js";
// P5 Task 12: plugin source contract + resolver and two-pass archive
// validation. The contract module belongs in @ovid/shared once that package
// split lands; exports here keep cross-package consumers on the barrel (the
// exports map blocks deep imports).
export * from "./plugins/input.js";
export * from "./plugins/errors.js";
export {
  validateAndExtractArchive,
  type ArchiveValidationInput,
  type ArchiveValidationResult,
} from "./plugins/archive.js";
export {
  createSourceResolver,
  MAX_METADATA_BYTES,
  MAX_PASTE_BYTES,
  MAX_PAYLOAD_BYTES,
  type PluginProvenance,
  type ResolvedSource,
  type SourceResolver,
  type SourceResolverDeps,
} from "./plugins/sources.js";
// P5 Task 11: McpRouter (THE central P5 interface — curated singletons, the
// Free/Pro gate at every dispatch point, mcp__ naming with never-guess
// resolution, per-run stdio lifecycle). Tool 4's client-request handler is
// re-exported here too because RunContext's sampler carries its types; the
// explicit Sampling* re-exports shadow transports/native.js's permissive
// forward-ref placeholders (explicit beats star — same discipline as
// WorkspaceFiles/UserSystemBus above).
export * from "./clientRequests.js";
export type { SamplingRequest, SamplingResult } from "./clientRequests.js";
export * from "./toolNames.js";
export * from "./router.js";
// P5 Task 13: manifest normalization (CC/Codex/native adapters), capability
// inference + grants, and the contribution registry. The adapters
// (plugins/adapters/*) stay internal — adaptPlugin is the single entry
// point; Task 14's installer consumes the registry and grant math from this
// root (same barrel rule).
export {
  ManifestError,
  adaptPlugin,
  canonicalContributionId,
  pluginManifestDigest,
  type NormalizedPluginManifest,
  type PluginAgent,
  type PluginCapability,
  type PluginCommand,
  type PluginFormat,
  type PluginHook,
  type PluginMcpServerContribution,
  type PluginSkill,
} from "./plugins/manifest.js";
export { inferRequestedCapabilities } from "./plugins/capabilities.js";
export {
  CAPABILITY_EXPLANATIONS,
  capabilityDelta,
  grantCovers,
  type PluginGrantInput,
} from "./plugins/grants.js";
export {
  contributionsFromManifest,
  createContributionRegistry,
  type ContributionRecord,
  type ContributionRegistry,
} from "./plugins/registry.js";


// P5 Task 14: the atomic plugin install transaction (worker processor and
// the plugin-installs queue lane consume it from this root — same barrel
// rule; PluginInstallJob mirrors the @ovid/queue contract member-for-member,
// SandboxFiles/SandboxSpawner are @ovid/sandbox structural mirrors until the
// workspace dependency can be declared).
export {
  createPluginInstaller,
  pluginDir,
  pluginStagingDir,
  NPM_INSTALL_TIMEOUT_MS,
  MV_TIMEOUT_MS,
  type InstallPhase,
  type PluginInstallOutcome,
  type InstallerDeps,
  type PluginInstallJob,
  type SandboxFiles,
  type SandboxExecRequest,
  type SandboxExecResult,
} from "./plugins/install.js";
