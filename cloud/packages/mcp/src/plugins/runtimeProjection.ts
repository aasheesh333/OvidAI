// Pure runtime metadata projection for reviewed, active plugin contributions.
//
// This module performs no source resolution, file reads, secret resolution,
// process execution, MCP connection, or registry mutation. Callers must supply
// a fresh, authoritative per-user read. The result is a full replacement, not
// an incremental merge. Secret invalidations are cache-key directives only;
// they are not evidence that a process, transport, or credential cache closed.

import type { ApprovedSource } from "./admission.js";
import { PLUGIN_CAPABILITIES } from "./capabilities.js";
import {
  projectApprovedContribution,
  type ApprovedContribution,
  type PersistedContribution,
} from "./contributions.js";
import { WORKSPACE_ROOT } from "../workspace.js";
import { grantCovers, type PluginGrantInput } from "./grants.js";
import {
  canonicalContributionId,
  canonicalHookEvent,
  isCloudHookEvent,
  type PluginCapability,
} from "./manifest.js";

export const APPROVED_RUNTIME_LIMITS = Object.freeze({
  maxInstallations: 64,
  maxContributions: 256,
  maxPerKind: 64,
  maxIdLength: 200,
  maxPluginIdLength: 200,
  maxDigestLength: 512,
  maxRootPathLength: 4096,
  maxFileLength: 1024,
  maxDescriptionLength: 4096,
  maxHookCommandLength: 16_384,
  maxMcpArguments: 64,
  maxMcpArgumentLength: 4096,
  maxCredentialNames: 128,
  maxCredentialNameLength: 200,
  maxUrlLength: 2048,
  maxOauthScopes: 32,
  maxMimeTypeLength: 128,
  maxResourceUriLength: 4096,
});

/** One installed manifest's approval binding; no raw install job is accepted. */
export interface ApprovedRuntimeInstallation {
  installationId: string;
  pluginId: string;
  /** Canonical realpath of this installation's owned content directory. */
  contentRoot: string;
  generation: number;
  approvedSource: ApprovedSource;
  grant: PluginGrantInput;
}

export interface ApprovedRuntimeProjectionInput {
  userId: string;
  /** Durable per-user configuration generation for this complete read. */
  configGeneration: number;
  /** The generation the caller requires; a mismatch denies the whole snapshot. */
  expectedConfigGeneration: number;
  installations: readonly ApprovedRuntimeInstallation[];
  contributions: readonly PersistedContribution[];
}

export type ApprovedRuntimeKind =
  | "hook"
  | "skill"
  | "command"
  | "resource"
  | "agent"
  | "mcp";

export interface ApprovedRuntimeContributionMetadata {
  contributionId: string;
  kind: ApprovedRuntimeKind;
  pluginId: string;
  name: string;
  rootPath: string;
  installationId: string;
  approvedSourceId: string;
  digest: string;
  generation: number;
}

export interface ApprovedRuntimeHook extends ApprovedRuntimeContributionMetadata {
  kind: "hook";
  event: string;
  type: "command";
  command: string;
  canBlock: boolean;
  ordinal: number;
}

export interface ApprovedRuntimeFileContribution
  extends ApprovedRuntimeContributionMetadata {
  file: string;
  description?: string;
}

export interface ApprovedRuntimeSkill extends ApprovedRuntimeFileContribution {
  kind: "skill";
}

export interface ApprovedRuntimeCommand extends ApprovedRuntimeFileContribution {
  kind: "command";
}

export interface ApprovedRuntimeAgent extends ApprovedRuntimeFileContribution {
  kind: "agent";
}

export interface ApprovedRuntimeResource extends ApprovedRuntimeContributionMetadata {
  kind: "resource";
  uri: string;
  file: string;
  mimeType?: string;
}

export interface ApprovedRuntimeOauthMetadata {
  authorizationUrl?: string;
  tokenUrl?: string;
  clientId?: string;
  redirectUri?: string;
  scopes?: readonly string[];
}

/** Connection metadata only: env/header values and resolved secrets are absent. */
export interface ApprovedRuntimeMcp extends ApprovedRuntimeContributionMetadata {
  kind: "mcp";
  transport: "stdio" | "http" | "sse";
  command?: string;
  args?: readonly string[];
  cwd?: string;
  url?: string;
  oauth?: ApprovedRuntimeOauthMetadata;
  envNames: readonly string[];
  headerNames: readonly string[];
}

export type ApprovedRuntimeContribution =
  | ApprovedRuntimeHook
  | ApprovedRuntimeSkill
  | ApprovedRuntimeCommand
  | ApprovedRuntimeResource
  | ApprovedRuntimeAgent
  | ApprovedRuntimeMcp;

/** A secret-cache namespace, never a secret or decrypted value. */
export interface ApprovedRuntimeSecretScope {
  userId: string;
  configGeneration: number;
  installationId: string;
  pluginId: string;
  approvedSourceId: string;
  digest: string;
  generation: number;
}

export interface ApprovedRuntimeProjection {
  userId: string;
  configGeneration: number;
  hooks: readonly ApprovedRuntimeHook[];
  skills: readonly ApprovedRuntimeSkill[];
  commands: readonly ApprovedRuntimeCommand[];
  resources: readonly ApprovedRuntimeResource[];
  agents: readonly ApprovedRuntimeAgent[];
  mcp: readonly ApprovedRuntimeMcp[];
  /** Current cache namespaces; changes make prior namespaces unusable. */
  secretScopes: readonly ApprovedRuntimeSecretScope[];
}

export interface ApprovedRuntimeReplacement {
  projection: ApprovedRuntimeProjection;
  /** Old namespaces the composition layer MUST evict before using the snapshot. */
  requiredSecretInvalidations: readonly ApprovedRuntimeSecretScope[];
}

export type ApprovedRuntimeProjectionErrorCode =
  | "invalid_input"
  | "unreviewed"
  | "approval_required"
  | "owner_mismatch"
  | "stale_generation"
  | "source_mismatch"
  | "digest_mismatch"
  | "capability_mismatch"
  | "secret_mismatch"
  | "unsupported_contribution"
  | "invalid_contribution"
  | "duplicate_contribution"
  | "forbidden_workspace_authority"
  | "unapproved_field"
  | "limit_exceeded";

/** Static, value-free denial: persisted values and secrets are never echoed. */
export class ApprovedPluginRuntimeProjectionError extends Error {
  constructor(readonly code: ApprovedRuntimeProjectionErrorCode) {
    super(code);
    this.name = "ApprovedPluginRuntimeProjectionError";
  }
}

const INPUT_KEYS = [
  "userId",
  "configGeneration",
  "expectedConfigGeneration",
  "installations",
  "contributions",
] as const;
const INSTALLATION_KEYS = [
  "installationId",
  "pluginId",
  "contentRoot",
  "generation",
  "approvedSource",
  "grant",
] as const;
const SOURCE_KEYS = [
  "approvedSourceId",
  "userId",
  "canonicalSource",
  "resolvedRevision",
  "digest",
  "provenance",
  "validationState",
  "approvalState",
  "approvedCapabilities",
] as const;
const GRANT_KEYS = [
  "capabilities",
  "envNames",
  "manifestDigest",
  "allowDependencyScripts",
] as const;
const CONTRIBUTION_KEYS = [
  "canonicalId",
  "kind",
  "pluginId",
  "name",
  "rootPath",
  "data",
  "userId",
  "installationId",
  "approvedSourceId",
  "digest",
  "generation",
  "active",
] as const;
const FILE_DATA_KEYS = ["file", "description"] as const;
const HOOK_DATA_KEYS = ["type", "command", "canBlock", "ordinal"] as const;
const RESOURCE_DATA_KEYS = ["file", "mimeType"] as const;
const MCP_DATA_KEYS = ["imported", "envNames", "headerNames"] as const;
const MCP_IMPORT_KEYS = [
  "name",
  "transport",
  "command",
  "args",
  "cwd",
  "url",
  "env",
  "headers",
  "oauth",
] as const;
const OAUTH_KEYS = [
  "authorizationUrl",
  "tokenUrl",
  "clientId",
  "redirectUri",
  "scopes",
] as const;
const PROVENANCE_KEYS = new Set([
  "kind",
  "githubRepo",
  "resolvedRef",
  "revision",
  "npmPackage",
  "npmVersion",
  "integrity",
  "url",
]);
const KNOWN_CAPABILITIES: ReadonlySet<string> = new Set(PLUGIN_CAPABILITIES);
const SAFE_PLUGIN_ID = /^[a-z0-9][a-z0-9-_.]*\/[a-z0-9][a-z0-9-_.]*$/;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;
const DSH_IN_COMMAND = /(?:^|[^A-Za-z0-9_.-])\.dsh(?:$|[^A-Za-z0-9_.-])/i;
const USER_CONFIG_REFERENCE = /\$\{user_config\.([A-Za-z0-9_.-]+)\}/g;
const GENERIC_MCP_REFERENCE = /\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-(?:[^}]*))?\}/g;
const HEADER_NAME = /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/;
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const WINDOWS_ABSOLUTE_PATH = /^[A-Za-z]:/;
const SAFE_CONTRIBUTION_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const SHELL_WRAPPER = /^(?:ba|z|k|da|a)?sh$/i;
const INLINE_SHELL_SCRIPT_OPTION = /^-[0-9A-Za-z]*c[0-9A-Za-z]*$/;
const ENV_ASSIGNMENT = /=/;

function deny(code: ApprovedRuntimeProjectionErrorCode): never {
  throw new ApprovedPluginRuntimeProjectionError(code);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actual = Object.keys(value);
  return actual.length === keys.length && keys.every((key) =>
    Object.prototype.hasOwnProperty.call(value, key),
  );
}

function hasOnlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  return Object.keys(value).every((key) => keys.includes(key));
}

function boundedText(value: unknown, maximum: number): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= maximum &&
    !value.includes("\u0000")
  );
}

function metadataId(value: unknown): value is string {
  return boundedText(value, APPROVED_RUNTIME_LIMITS.maxIdLength) &&
    !CONTROL_CHARACTERS.test(value as string);
}

function generation(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0;
}

function pluginId(value: unknown): value is string {
  return (
    boundedText(value, APPROVED_RUNTIME_LIMITS.maxPluginIdLength) &&
    SAFE_PLUGIN_ID.test(value as string)
  );
}

function uniqueStrings(value: unknown, maximum: number): value is string[] {
  return (
    Array.isArray(value) &&
    value.length <= maximum &&
    value.every((entry) =>
      boundedText(entry, APPROVED_RUNTIME_LIMITS.maxCredentialNameLength) &&
      !CONTROL_CHARACTERS.test(entry),
    ) &&
    new Set(value).size === value.length
  );
}

function capabilities(value: unknown): value is PluginCapability[] {
  return (
    uniqueStrings(value, PLUGIN_CAPABILITIES.length) &&
    value.every((entry) => KNOWN_CAPABILITIES.has(entry))
  );
}

function provenance(value: unknown): value is Record<string, unknown> {
  return (
    isRecord(value) &&
    boundedText(value.kind, APPROVED_RUNTIME_LIMITS.maxIdLength) &&
    Object.entries(value).every(
      ([key, entry]) =>
        PROVENANCE_KEYS.has(key) &&
        boundedText(entry, APPROVED_RUNTIME_LIMITS.maxUrlLength) &&
        !CONTROL_CHARACTERS.test(entry),
    )
  );
}

function decodePathText(value: string): string | null {
  let decoded = value;
  // Percent and HTML entities are both decoded to a fixed point so nested
  // wrappers cannot conceal a path segment from this lexical authority gate.
  for (let pass = 0; pass < 8; pass += 1) {
    let next = decoded;
    try {
      next = decodeURIComponent(next);
    } catch {
      // A malformed percent escape is a literal filename, not decoded traversal.
      next = decoded;
    }
    next = next.replace(/&(?:#46|#x2e|#x2f|#x5c|#47|#92|sol|bsol);/gi, (entity) => {
      switch (entity.toLowerCase()) {
        case "&sol;":
        case "&#47;":
        case "&#x2f;":
          return "/";
        case "&bsol;":
        case "&#92;":
        case "&#x5c;":
          return "\\";
        default:
          return ".";
      }
    });
    if (next === decoded) return decoded;
    decoded = next;
  }
  return null;
}

function pathSegments(path: string): string[] | null {
  const decoded = decodePathText(path);
  if (decoded === null) return null;
  return decoded
    .replaceAll("\u2024", ".")
    .replaceAll("\u3002", ".")
    .replaceAll("\uff0e", ".")
    .replaceAll("\uff61", ".")
    .replaceAll("\u2216", "\\")
    .replaceAll("\u29f5", "\\")
    .replaceAll("\u2044", "/")
    .replaceAll("\u2215", "/")
    .replaceAll("\uff0f", "/")
    .replaceAll("\uff3c", "\\")
    .replaceAll("\\", "/")
    .split("/");
}

function hasDshSegment(path: string): boolean {
  return pathSegments(path)?.some((segment) => segment.toLowerCase() === ".dsh") ?? true;
}

function containsDshAuthority(value: string): boolean {
  const decoded = decodePathText(value);
  return decoded === null || hasDshSegment(decoded) || DSH_IN_COMMAND.test(decoded);
}

function executableBasename(value: string): string | null {
  const decoded = decodePathText(value);
  if (decoded === null || /[\s'"\\]/.test(decoded)) return null;
  return decoded.slice(decoded.lastIndexOf("/") + 1);
}

function isShellExecutable(value: string): boolean {
  const basename = executableBasename(value);
  return basename !== null && SHELL_WRAPPER.test(basename);
}

function isEnvExecutable(value: string): boolean {
  return executableBasename(value) === "env";
}

function hasInlineShellScriptOption(
  selectedShell: string,
  args: readonly string[],
  start: number,
): boolean {
  const basename = executableBasename(selectedShell);
  const zsh = basename === "zsh";
  for (let index = start; index < args.length; index += 1) {
    const arg = args[index]!;
    if (arg === "--") break;
    if (!arg.startsWith("-") && !arg.startsWith("+")) break;
    if (arg === "-" || arg === "+") return true;
    if (INLINE_SHELL_SCRIPT_OPTION.test(arg)) return true;

    // Bash accepts -o/+o option names and -O/+O shopt operands. Zsh also
    // consumes an option-name operand for -o/+o (including stacked forms
    // ending in o) and a mode for --emulate.
    const bashOptionOperand = !zsh && ["-o", "+o", "-O", "+O"].includes(arg);
    const zshOptionOperand = zsh && /^[-+][0-9A-Za-z]*o$/.test(arg);
    const bashFileOperand = !zsh &&
      (arg === "--init-file" || arg === "--rcfile" || arg === "--startup-file");
    if (
      bashOptionOperand ||
      zshOptionOperand ||
      bashFileOperand ||
      (zsh && arg === "--emulate")
    ) {
      if (index + 1 >= args.length) return true;
      index += 1;
      continue;
    }

    const bashNoOperandOption = !zsh && (
      /^[-+][alxefhkmnptuvxBCEHPT]+$/.test(arg) ||
      arg === "--noediting" ||
      arg === "--noprofile" ||
      arg === "--norc" ||
      arg === "--posix" ||
      arg === "--restricted" ||
      arg === "--verbose" ||
      arg === "--debugger"
    );
    const zshNoOperandOption = zsh && /^[-+][0-9A-Za-z]+$/.test(arg);
    if (bashNoOperandOption || zshNoOperandOption) continue;

    // Unknown pre-script shell options fail closed: their operand arity must
    // not be guessed. Arguments after a real script filename never reach here.
    return true;
  }
  return false;
}

const ENV_FLAG_OPTIONS = new Set([
  "-",
  "-i",
  "--ignore-environment",
  "-0",
  "--null",
  "-v",
  "--verbose",
  "--debug",
]);
const ENV_OPERAND_OPTIONS = new Set([
  "-u",
  "--unset",
  "-C",
  "--chdir",
  "-a",
  "--argv0",
]);
const ENV_ATTACHED_OPERAND = /^(?:--unset|--chdir|--argv0)=.+$/;
const ENV_ATTACHED_SHORT_OPERAND = /^-(?:u|C|a).+$/;
const ENV_SPLIT_STRING = /^(?:-S(?:.*)?|--split-string(?:=.*)?)$/;

/**
 * Recognize Coreutils env command selection without treating ordinary argv as
 * shell text. Split-string and unknown options are conservatively denied as
 * ambiguous inline execution; assignments and known non-shell commands remain.
 */
function envSelectsInlineShell(args: readonly string[]): boolean {
  let index = 0;
  while (index < args.length) {
    const arg = args[index]!;
    if (ENV_SPLIT_STRING.test(arg)) return true;
    if (arg === "--") {
      index += 1;
      break;
    }
    if (ENV_ASSIGNMENT.test(arg)) {
      index += 1;
      continue;
    }
    if (ENV_FLAG_OPTIONS.has(arg)) {
      index += 1;
      continue;
    }
    if (ENV_OPERAND_OPTIONS.has(arg)) {
      if (index + 1 >= args.length) return true;
      index += 2;
      continue;
    }
    if (ENV_ATTACHED_OPERAND.test(arg) || ENV_ATTACHED_SHORT_OPERAND.test(arg)) {
      index += 1;
      continue;
    }
    if (arg.startsWith("-")) return true; // unknown/ambiguous env invocation
    break;
  }
  const selected = args[index];
  if (selected !== undefined && isEnvExecutable(selected)) return true;
  return (
    selected !== undefined &&
    isShellExecutable(selected) &&
    hasInlineShellScriptOption(selected, args, index + 1)
  );
}

/** Reject actual inline shell wrappers; direct argv/cwd remains opaque data. */
function unsafeStdioSyntax(command: string, args: readonly string[]): boolean {
  const decodedCommand = decodePathText(command);
  if (decodedCommand === null || /[\s'"\\;&|<>`()]/.test(decodedCommand)) {
    return true;
  }
  return (
    isShellExecutable(decodedCommand) ||
    (isEnvExecutable(decodedCommand) && envSelectsInlineShell(args))
  );
}

function canonicalAbsolutePath(value: unknown): value is string {
  if (
    !boundedText(value, APPROVED_RUNTIME_LIMITS.maxRootPathLength) ||
    typeof value !== "string" ||
    !value.startsWith("/") ||
    value.includes("\\") ||
    value.includes("\u0000") ||
    CONTROL_CHARACTERS.test(value)
  ) {
    return false;
  }
  const segments = value.split("/");
  const decodedSegments = pathSegments(value);
  // No empty, dot, or parent segments: the trusted realpath and persisted row
  // must use the exact same canonical spelling, not merely normalize equal.
  return (
    decodedSegments !== null &&
    segments[0] === "" &&
    segments.slice(1).every(
      (segment) => segment !== "" && segment !== "." && segment !== "..",
    ) &&
    decodedSegments.every(
      (segment, index) => index === 0 || segment === segments[index],
    )
  );
}

function canonicalContentRoot(value: unknown): value is string {
  return canonicalAbsolutePath(value) && value !== WORKSPACE_ROOT;
}

function relativePath(value: unknown): value is string {
  if (
    !boundedText(value, APPROVED_RUNTIME_LIMITS.maxFileLength) ||
    (value as string).includes("\\") ||
    (value as string).startsWith("/") ||
    (value as string).includes("${") ||
    CONTROL_CHARACTERS.test(value as string) ||
    WINDOWS_ABSOLUTE_PATH.test(value as string)
  ) {
    return false;
  }
  const segments = pathSegments(value as string);
  return (
    segments !== null &&
    segments.length > 0 &&
    segments.every(
      (segment) => segment !== "" && segment !== "." && segment !== "..",
    )
  );
}

function endpoint(value: unknown): value is string {
  if (!boundedText(value, APPROVED_RUNTIME_LIMITS.maxUrlLength)) return false;
  try {
    const parsed = new URL(
      (value as string)
        .replace(USER_CONFIG_REFERENCE, "credential")
        .replace(GENERIC_MCP_REFERENCE, "credential"),
    );
    return (
      (parsed.protocol === "https:" || parsed.protocol === "http:") &&
      parsed.username === "" &&
      parsed.password === "" &&
      parsed.search === "" &&
      parsed.hash === ""
    );
  } catch {
    return false;
  }
}

function userConfigReferences(value: string): string[] {
  return [...value.matchAll(USER_CONFIG_REFERENCE)].map((match) => match[1]!);
}

function validateApprovedSource(
  candidate: unknown,
  userId: string,
): asserts candidate is ApprovedSource {
  if (!isRecord(candidate) || !hasExactKeys(candidate, SOURCE_KEYS)) {
    deny("unreviewed");
  }
  if (
    candidate.validationState !== "validated" ||
    candidate.approvalState !== "approved"
  ) {
    deny("approval_required");
  }
  if (candidate.userId !== userId) deny("owner_mismatch");
  if (
    !metadataId(candidate.approvedSourceId) ||
    !boundedText(candidate.canonicalSource, APPROVED_RUNTIME_LIMITS.maxUrlLength) ||
    CONTROL_CHARACTERS.test(candidate.canonicalSource as string) ||
    !metadataId(candidate.resolvedRevision) ||
    !boundedText(candidate.digest, APPROVED_RUNTIME_LIMITS.maxDigestLength) ||
    !provenance(candidate.provenance) ||
    !capabilities(candidate.approvedCapabilities)
  ) {
    deny("unreviewed");
  }
}

function validateGrant(candidate: unknown): asserts candidate is PluginGrantInput {
  if (!isRecord(candidate) || !hasExactKeys(candidate, GRANT_KEYS)) {
    deny("unreviewed");
  }
  if (
    !capabilities(candidate.capabilities) ||
    !uniqueStrings(
      candidate.envNames,
      APPROVED_RUNTIME_LIMITS.maxCredentialNames,
    ) ||
    !boundedText(
      candidate.manifestDigest,
      APPROVED_RUNTIME_LIMITS.maxDigestLength,
    ) ||
    typeof candidate.allowDependencyScripts !== "boolean"
  ) {
    deny("unreviewed");
  }
}

function installationMap(
  candidates: readonly ApprovedRuntimeInstallation[],
  userId: string,
): ReadonlyMap<string, ApprovedRuntimeInstallation> {
  if (candidates.length > APPROVED_RUNTIME_LIMITS.maxInstallations) {
    deny("limit_exceeded");
  }
  const installations = new Map<string, ApprovedRuntimeInstallation>();
  for (const candidate of candidates) {
    if (!isRecord(candidate) || !hasExactKeys(candidate, INSTALLATION_KEYS)) {
      deny("invalid_input");
    }
    if (
      typeof candidate.contentRoot === "string" &&
      hasDshSegment(candidate.contentRoot)
    ) {
      deny("forbidden_workspace_authority");
    }
    if (
      !metadataId(candidate.installationId) ||
      !pluginId(candidate.pluginId) ||
      !canonicalContentRoot(candidate.contentRoot) ||
      !generation(candidate.generation)
    ) {
      deny("invalid_input");
    }
    if (installations.has(candidate.installationId)) deny("invalid_input");
    validateApprovedSource(candidate.approvedSource, userId);
    validateGrant(candidate.grant);
    if (candidate.grant.manifestDigest !== candidate.approvedSource.digest) {
      deny("digest_mismatch");
    }
    installations.set(candidate.installationId, candidate);
  }
  return installations;
}

function metadata(
  row: ApprovedContribution,
  kind: ApprovedRuntimeKind,
  installation: ApprovedRuntimeInstallation,
): ApprovedRuntimeContributionMetadata {
  if (row.rootPath !== installation.contentRoot) deny("source_mismatch");
  if (
    !boundedText(row.canonicalId, 1024) ||
    !boundedText(row.name, APPROVED_RUNTIME_LIMITS.maxIdLength) ||
    (kind !== "hook" && !SAFE_CONTRIBUTION_NAME.test(row.name)) ||
    !pluginId(row.pluginId) ||
    !canonicalContentRoot(row.rootPath) ||
    !metadataId(row.installationId) ||
    !metadataId(row.approvedSourceId) ||
    !boundedText(row.digest, APPROVED_RUNTIME_LIMITS.maxDigestLength)
  ) {
    deny("invalid_contribution");
  }
  if (hasDshSegment(row.rootPath)) deny("forbidden_workspace_authority");
  return {
    contributionId: row.canonicalId,
    kind,
    pluginId: row.pluginId,
    name: row.name,
    rootPath: row.rootPath,
    installationId: row.installationId,
    approvedSourceId: row.approvedSourceId,
    digest: row.digest,
    generation: row.generation,
  };
}

function requireCanonicalId(
  row: ApprovedContribution,
  expected: string,
): void {
  if (row.canonicalId !== expected) deny("invalid_contribution");
}

interface ParsedContribution {
  value: ApprovedRuntimeContribution;
  capabilities: ReadonlySet<PluginCapability>;
  secretNames: readonly string[];
}

function parseFileContribution(
  row: ApprovedContribution,
  data: Record<string, unknown>,
  kind: "command" | "skill" | "agent",
  installation: ApprovedRuntimeInstallation,
): ParsedContribution {
  if (!hasOnlyKeys(data, FILE_DATA_KEYS)) deny("unapproved_field");
  if (
    typeof data.file === "string" &&
    data.file.length > APPROVED_RUNTIME_LIMITS.maxFileLength
  ) {
    deny("limit_exceeded");
  }
  if (!relativePath(data.file)) deny("invalid_contribution");
  if (hasDshSegment(data.file)) deny("forbidden_workspace_authority");
  const directory = kind === "command" ? "commands/" : kind === "skill" ? "skills/" : "agents/";
  const validFile = kind === "skill"
    ? data.file.startsWith(directory) && data.file.endsWith("/SKILL.md")
    : data.file.startsWith(directory) && data.file.endsWith(".md");
  if (!validFile) deny("invalid_contribution");
  if (
    data.description !== undefined &&
    !boundedText(data.description, APPROVED_RUNTIME_LIMITS.maxDescriptionLength)
  ) {
    deny(
      typeof data.description === "string" &&
        data.description.length > APPROVED_RUNTIME_LIMITS.maxDescriptionLength
        ? "limit_exceeded"
        : "invalid_contribution",
    );
  }
  requireCanonicalId(
    row,
    canonicalContributionId(row.pluginId, kind, row.name),
  );
  const value = {
    ...metadata(row, kind, installation),
    kind,
    file: data.file,
    ...(typeof data.description === "string"
      ? { description: data.description }
      : {}),
  } as ApprovedRuntimeCommand | ApprovedRuntimeSkill | ApprovedRuntimeAgent;
  return { value, capabilities: new Set<PluginCapability>(["workspaceRead"]), secretNames: [] };
}

function parseHook(
  row: ApprovedContribution,
  data: Record<string, unknown>,
  installation: ApprovedRuntimeInstallation,
): ParsedContribution {
  if (!hasOnlyKeys(data, HOOK_DATA_KEYS)) deny("unapproved_field");
  if (
    data.type !== "command" ||
    !boundedText(data.command, APPROVED_RUNTIME_LIMITS.maxHookCommandLength) ||
    typeof data.canBlock !== "boolean" ||
    typeof data.ordinal !== "number" ||
    !Number.isSafeInteger(data.ordinal) ||
    data.ordinal < 0 ||
    data.ordinal >= APPROVED_RUNTIME_LIMITS.maxPerKind
  ) {
    deny(
      typeof data.command === "string" &&
        data.command.length > APPROVED_RUNTIME_LIMITS.maxHookCommandLength
        ? "limit_exceeded"
        : "invalid_contribution",
    );
  }
  if (containsDshAuthority(data.command)) deny("forbidden_workspace_authority");
  const event = canonicalHookEvent(row.name);
  if (
    event === null ||
    event !== row.name ||
    !isCloudHookEvent(event) ||
    data.canBlock !== (event === "pre_tool")
  ) {
    deny("unsupported_contribution");
  }
  requireCanonicalId(
    row,
    canonicalContributionId(row.pluginId, "hook", event, data.ordinal),
  );
  const required = new Set<PluginCapability>(["hooksObserve", "shellExecute"]);
  if (data.canBlock) required.add("hooksBlock");
  const secretNames = userConfigReferences(data.command);
  if (secretNames.length > 0) required.add("environmentRead");
  return {
    value: {
      ...metadata(row, "hook", installation),
      kind: "hook",
      event,
      type: "command",
      command: data.command,
      canBlock: data.canBlock,
      ordinal: data.ordinal,
    },
    capabilities: required,
    secretNames,
  };
}

function encodePath(path: string): string {
  return path.split("/").map(encodeURIComponent).join("/");
}

function parseResource(
  row: ApprovedContribution,
  data: Record<string, unknown>,
  installation: ApprovedRuntimeInstallation,
): ParsedContribution {
  if (!hasOnlyKeys(data, RESOURCE_DATA_KEYS)) deny("unapproved_field");
  if (!relativePath(data.file)) deny("invalid_contribution");
  if (hasDshSegment(data.file)) deny("forbidden_workspace_authority");
  if (
    data.mimeType !== undefined &&
    (!boundedText(data.mimeType, APPROVED_RUNTIME_LIMITS.maxMimeTypeLength) ||
      CONTROL_CHARACTERS.test(data.mimeType as string) ||
      !(data.mimeType as string).includes("/"))
  ) {
    deny("invalid_contribution");
  }
  if (!SAFE_CONTRIBUTION_NAME.test(row.name)) deny("invalid_contribution");
  const expectedId = `plugin:${row.pluginId}/resource:${row.name}`;
  requireCanonicalId(row, expectedId);
  const contributionPath = expectedId
    .split("/")
    .map((segment) => encodeURIComponent(segment).replace(/%3A/gi, ":"))
    .join("/");
  const uri = `plugin://${encodeURIComponent(row.installationId)}/${contributionPath}/${encodePath(data.file)}`;
  if (uri.length > APPROVED_RUNTIME_LIMITS.maxResourceUriLength) {
    deny("limit_exceeded");
  }
  return {
    value: {
      ...metadata(row, "resource", installation),
      kind: "resource",
      uri,
      file: data.file,
      ...(typeof data.mimeType === "string" ? { mimeType: data.mimeType } : {}),
    },
    capabilities: new Set<PluginCapability>(["workspaceRead"]),
    secretNames: [],
  };
}

function credentialReferences(value: string): string[] {
  const generic = [...value.matchAll(GENERIC_MCP_REFERENCE)].map(
    (match) => match[1]!,
  );
  return [...userConfigReferences(value), ...generic];
}

function credentialNames(
  data: Record<string, unknown>,
  imported: Record<string, unknown>,
): { envNames: string[]; headerNames: string[]; references: string[] } {
  for (const names of [data.envNames, data.headerNames]) {
    if (
      names !== undefined &&
      !uniqueStrings(names, APPROVED_RUNTIME_LIMITS.maxCredentialNames)
    ) {
      deny(
        Array.isArray(names) &&
          names.length > APPROVED_RUNTIME_LIMITS.maxCredentialNames
          ? "limit_exceeded"
          : "invalid_contribution",
      );
    }
  }
  if (
    (imported.env !== undefined && !isRecord(imported.env)) ||
    (imported.headers !== undefined && !isRecord(imported.headers)) ||
    (isRecord(imported.env) &&
      Object.keys(imported.env).length > APPROVED_RUNTIME_LIMITS.maxCredentialNames) ||
    (isRecord(imported.headers) &&
      Object.keys(imported.headers).length > APPROVED_RUNTIME_LIMITS.maxCredentialNames)
  ) {
    deny("invalid_contribution");
  }
  const envNames = new Set<string>([
    ...(Array.isArray(data.envNames) ? data.envNames as string[] : []),
    ...(isRecord(imported.env) ? Object.keys(imported.env) : []),
  ]);
  const headerNames = new Set<string>([
    ...(Array.isArray(data.headerNames) ? data.headerNames as string[] : []),
    ...(isRecord(imported.headers) ? Object.keys(imported.headers) : []),
  ]);
  if (
    envNames.size > APPROVED_RUNTIME_LIMITS.maxCredentialNames ||
    headerNames.size > APPROVED_RUNTIME_LIMITS.maxCredentialNames
  ) {
    deny("limit_exceeded");
  }
  if (
    [...envNames].some((name) => !ENV_NAME.test(name)) ||
    [...headerNames].some(
      (name) =>
        name.length > APPROVED_RUNTIME_LIMITS.maxCredentialNameLength ||
        !HEADER_NAME.test(name),
    )
  ) {
    deny("invalid_contribution");
  }
  const references: string[] = [];
  // Inspect values BEFORE dropping them. The reference names are authority;
  // literal values are neither copied into the projection nor returned in errors.
  for (const values of [imported.env, imported.headers]) {
    if (!isRecord(values)) continue;
    for (const value of Object.values(values)) {
      if (
        typeof value !== "string" ||
        value.length > APPROVED_RUNTIME_LIMITS.maxMcpArgumentLength
      ) {
        deny("invalid_contribution");
      }
      references.push(...credentialReferences(value));
    }
  }
  return {
    envNames: [...envNames].sort(),
    headerNames: [...headerNames].sort(),
    references,
  };
}

function parseOauth(value: unknown): ApprovedRuntimeOauthMetadata | undefined {
  if (value === undefined) return undefined;
  if (!isRecord(value) || !hasOnlyKeys(value, OAUTH_KEYS)) deny("unapproved_field");
  for (const key of ["authorizationUrl", "tokenUrl", "redirectUri"] as const) {
    if (value[key] !== undefined && !endpoint(value[key])) deny("invalid_contribution");
  }
  if (
    value.clientId !== undefined &&
    !boundedText(value.clientId, APPROVED_RUNTIME_LIMITS.maxCredentialNameLength)
  ) {
    deny("invalid_contribution");
  }
  if (
    value.scopes !== undefined &&
    !uniqueStrings(value.scopes, APPROVED_RUNTIME_LIMITS.maxOauthScopes)
  ) {
    deny("invalid_contribution");
  }
  return {
    ...(typeof value.authorizationUrl === "string"
      ? { authorizationUrl: value.authorizationUrl }
      : {}),
    ...(typeof value.tokenUrl === "string" ? { tokenUrl: value.tokenUrl } : {}),
    ...(typeof value.clientId === "string" ? { clientId: value.clientId } : {}),
    ...(typeof value.redirectUri === "string" ? { redirectUri: value.redirectUri } : {}),
    ...(Array.isArray(value.scopes) ? { scopes: [...value.scopes] as string[] } : {}),
  };
}

function oauthCredentialReferences(value: unknown): string[] {
  if (!isRecord(value)) return [];
  return Object.values(value).flatMap((entry) => {
    if (typeof entry === "string") return credentialReferences(entry);
    if (Array.isArray(entry)) {
      return entry.flatMap((scope) =>
        typeof scope === "string" ? credentialReferences(scope) : [],
      );
    }
    return [];
  });
}

function parseMcp(
  row: ApprovedContribution,
  data: Record<string, unknown>,
  installation: ApprovedRuntimeInstallation,
): ParsedContribution {
  if (!hasOnlyKeys(data, MCP_DATA_KEYS)) deny("unapproved_field");
  if (!isRecord(data.imported) || !hasOnlyKeys(data.imported, MCP_IMPORT_KEYS)) {
    deny("unapproved_field");
  }
  const imported = data.imported;
  const transport = imported.transport;
  if (
    imported.name !== row.name ||
    (transport !== "stdio" && transport !== "http" && transport !== "sse")
  ) {
    deny("invalid_contribution");
  }
  if (
    imported.command !== undefined &&
    !boundedText(imported.command, APPROVED_RUNTIME_LIMITS.maxHookCommandLength)
  ) {
    deny("invalid_contribution");
  }
  if (imported.args !== undefined) {
    if (
      !Array.isArray(imported.args) ||
      imported.args.length > APPROVED_RUNTIME_LIMITS.maxMcpArguments ||
      !imported.args.every((argument) =>
        boundedText(argument, APPROVED_RUNTIME_LIMITS.maxMcpArgumentLength),
      )
    ) {
      deny(
        Array.isArray(imported.args) &&
          imported.args.length > APPROVED_RUNTIME_LIMITS.maxMcpArguments
          ? "limit_exceeded"
          : "invalid_contribution",
      );
    }
  }
  if (imported.cwd !== undefined && !relativePath(imported.cwd)) {
    deny("invalid_contribution");
  }
  if (transport === "stdio") {
    if (!boundedText(imported.command, APPROVED_RUNTIME_LIMITS.maxHookCommandLength) ||
      imported.url !== undefined || imported.oauth !== undefined) {
      deny("invalid_contribution");
    }
    const command = imported.command;
    if (!boundedText(command, APPROVED_RUNTIME_LIMITS.maxHookCommandLength)) {
      deny("invalid_contribution");
    }
    const stdioArgs = Array.isArray(imported.args)
      ? imported.args as string[]
      : [];
    const stdioValues: string[] = [
      ...stdioArgs,
      ...(typeof imported.cwd === "string" ? [imported.cwd] : []),
    ];
    if (unsafeStdioSyntax(command, stdioArgs)) {
      deny("forbidden_workspace_authority");
    }
    const stdioPaths = [imported.command, ...stdioValues];
    if (stdioPaths.some(
      (value) => typeof value === "string" && containsDshAuthority(value),
    )) {
      deny("forbidden_workspace_authority");
    }
  } else {
    if (!endpoint(imported.url) || imported.command !== undefined ||
      imported.args !== undefined || imported.cwd !== undefined) {
      deny("invalid_contribution");
    }
  }

  const names = credentialNames(data, imported);
  const oauth = parseOauth(imported.oauth);
  const required = new Set<PluginCapability>(["mcpRegister"]);
  if (transport === "stdio") required.add("processSpawn");
  else required.add("networkConnect");
  if (names.envNames.length + names.headerNames.length > 0) {
    required.add("environmentRead");
  }
  const retainedStrings = [
    ...(typeof imported.command === "string" ? [imported.command] : []),
    ...(Array.isArray(imported.args) ? imported.args as string[] : []),
    ...(typeof imported.cwd === "string" ? [imported.cwd] : []),
    ...(typeof imported.url === "string" ? [imported.url] : []),
  ];
  const references = [
    ...retainedStrings.flatMap(credentialReferences),
    ...names.references,
    ...oauthCredentialReferences(imported.oauth),
  ];
  if (new Set(references).size > APPROVED_RUNTIME_LIMITS.maxCredentialNames) {
    deny("limit_exceeded");
  }
  if (references.length > 0) required.add("environmentRead");
  requireCanonicalId(row, canonicalContributionId(row.pluginId, "mcp", row.name));
  return {
    value: {
      ...metadata(row, "mcp", installation),
      kind: "mcp",
      transport,
      ...(typeof imported.command === "string" ? { command: imported.command } : {}),
      ...(Array.isArray(imported.args) ? { args: [...imported.args] as string[] } : {}),
      ...(typeof imported.cwd === "string" ? { cwd: imported.cwd } : {}),
      ...(typeof imported.url === "string" ? { url: imported.url } : {}),
      ...(oauth !== undefined ? { oauth } : {}),
      envNames: names.envNames,
      headerNames: names.headerNames,
    },
    capabilities: required,
    secretNames: [...names.envNames, ...names.headerNames, ...references],
  };
}

function parseContribution(
  row: ApprovedContribution,
  data: Record<string, unknown>,
  installation: ApprovedRuntimeInstallation,
): ParsedContribution {
  switch (row.kind) {
    case "command":
    case "skill":
    case "agent":
      return parseFileContribution(row, data, row.kind, installation);
    case "hook":
      return parseHook(row, data, installation);
    case "resource":
      return parseResource(row, data, installation);
    case "mcp":
      return parseMcp(row, data, installation);
    default:
      return deny("unsupported_contribution");
  }
}

function validateBinding(
  row: ApprovedContribution,
  installation: ApprovedRuntimeInstallation,
  userId: string,
): void {
  if (row.userId !== userId || installation.approvedSource.userId !== userId) {
    deny("owner_mismatch");
  }
  if (row.generation !== installation.generation) deny("stale_generation");
  if (
    row.approvedSourceId !== installation.approvedSource.approvedSourceId ||
    row.pluginId !== installation.pluginId
  ) {
    deny("source_mismatch");
  }
  if (
    row.digest !== installation.approvedSource.digest ||
    row.digest !== installation.grant.manifestDigest
  ) {
    deny("digest_mismatch");
  }
}

function validateGrants(
  parsed: ParsedContribution,
  installation: ApprovedRuntimeInstallation,
): void {
  if (!grantCovers(parsed.capabilities, installation.grant)) {
    deny("capability_mismatch");
  }
  const approved = new Set(installation.approvedSource.approvedCapabilities);
  for (const capability of parsed.capabilities) {
    if (!approved.has(capability)) deny("capability_mismatch");
  }
  const declaredSecrets = new Set(installation.grant.envNames);
  for (const name of new Set(parsed.secretNames)) {
    if (!declaredSecrets.has(name)) deny("secret_mismatch");
  }
}

function secretScope(
  row: ApprovedContribution,
  userId: string,
  configGeneration: number,
): ApprovedRuntimeSecretScope {
  return {
    userId,
    configGeneration,
    installationId: row.installationId,
    pluginId: row.pluginId,
    approvedSourceId: row.approvedSourceId,
    digest: row.digest,
    generation: row.generation,
  };
}

/**
 * Project a complete fresh per-user read. Any active invalid row denies the
 * whole snapshot; inactive rows are retained only as removal evidence.
 */
export function projectApprovedPluginRuntime(
  input: ApprovedRuntimeProjectionInput,
): ApprovedRuntimeProjection {
  if (!isRecord(input) || !hasExactKeys(input, INPUT_KEYS)) deny("invalid_input");
  if (
    !metadataId(input.userId) ||
    !generation(input.configGeneration) ||
    !generation(input.expectedConfigGeneration) ||
    !Array.isArray(input.installations) ||
    !Array.isArray(input.contributions)
  ) {
    deny("invalid_input");
  }
  if (input.configGeneration !== input.expectedConfigGeneration) {
    deny("stale_generation");
  }
  if (input.contributions.length > APPROVED_RUNTIME_LIMITS.maxContributions) {
    deny("limit_exceeded");
  }
  const installations = installationMap(input.installations, input.userId);
  const hooks: ApprovedRuntimeHook[] = [];
  const skills: ApprovedRuntimeSkill[] = [];
  const commands: ApprovedRuntimeCommand[] = [];
  const resources: ApprovedRuntimeResource[] = [];
  const agents: ApprovedRuntimeAgent[] = [];
  const mcp: ApprovedRuntimeMcp[] = [];
  const seen = new Set<string>();
  const counts = new Map<string, number>();
  const scopes = new Map<string, ApprovedRuntimeSecretScope>();

  for (const candidate of input.contributions) {
    if (!isRecord(candidate)) deny("invalid_contribution");
    if (candidate.userId !== input.userId) deny("owner_mismatch");
    if (candidate.active === false) continue;
    if (!hasOnlyKeys(candidate, CONTRIBUTION_KEYS)) deny("unapproved_field");
    const row = projectApprovedContribution(candidate);
    if (row === null) deny("unreviewed");
    if (!row.active) continue;
    const installation = installations.get(row.installationId);
    if (installation === undefined) deny("unreviewed");
    validateBinding(row, installation, input.userId);
    if (seen.has(row.canonicalId)) deny("duplicate_contribution");
    seen.add(row.canonicalId);
    const count = (counts.get(row.kind) ?? 0) + 1;
    if (count > APPROVED_RUNTIME_LIMITS.maxPerKind) deny("limit_exceeded");
    counts.set(row.kind, count);

    const parsed = parseContribution(row, candidate.data, installation);
    validateGrants(parsed, installation);
    const value = parsed.value;
    switch (value.kind) {
      case "hook":
        hooks.push(value);
        break;
      case "skill":
        skills.push(value);
        break;
      case "command":
        commands.push(value);
        break;
      case "resource":
        resources.push(value);
        break;
      case "agent":
        agents.push(value);
        break;
      case "mcp":
        mcp.push(value);
        break;
    }
    scopes.set(
      row.installationId,
      secretScope(row, input.userId, input.configGeneration),
    );
  }

  const byId = (
    left: ApprovedRuntimeContribution,
    right: ApprovedRuntimeContribution,
  ): number => left.contributionId.localeCompare(right.contributionId);
  hooks.sort(byId);
  skills.sort(byId);
  commands.sort(byId);
  resources.sort(byId);
  agents.sort(byId);
  mcp.sort(byId);
  return {
    userId: input.userId,
    configGeneration: input.configGeneration,
    hooks,
    skills,
    commands,
    resources,
    agents,
    mcp,
    secretScopes: [...scopes.values()].sort((left, right) =>
      left.installationId.localeCompare(right.installationId),
    ),
  };
}

function scopeKey(scope: ApprovedRuntimeSecretScope): string {
  return JSON.stringify([
    scope.userId,
    scope.configGeneration,
    scope.installationId,
    scope.pluginId,
    scope.approvedSourceId,
    scope.digest,
    scope.generation,
  ]);
}

/**
 * Full replacement/uninstall projection. A newer per-user configGeneration is
 * mandatory, and every prior secret namespace absent from the new snapshot is
 * returned for mandatory eviction. No cache or process is touched here.
 */
export function replaceApprovedPluginRuntimeProjection(
  previous: ApprovedRuntimeProjection | null,
  input: ApprovedRuntimeProjectionInput,
): ApprovedRuntimeReplacement {
  const projection = projectApprovedPluginRuntime(input);
  if (previous === null) return { projection, requiredSecretInvalidations: [] };
  if (previous.userId !== input.userId) deny("owner_mismatch");
  if (input.configGeneration <= previous.configGeneration) deny("stale_generation");
  const current = new Set(projection.secretScopes.map(scopeKey));
  return {
    projection,
    requiredSecretInvalidations: previous.secretScopes.filter(
      (scope) => !current.has(scopeKey(scope)),
    ),
  };
}
