import {
  assertClosedProviderSchema,
  snapshotProviderArgs,
  validateProviderDefinition,
  type ApprovalPolicy,
  type Effect,
  type ProviderDefinition,
  type ProviderOperation,
} from "./types.js";

export type CredentialState = "not provided" | "configured" | "passed" | "failed";

/** Internal auth/readiness facts. This is never a credential-bearing DTO. */
export interface AuthProfile {
  profileId: string;
  tokenType: string;
  authorizationPrefix: string;
  minimumScopes: readonly string[];
  tenantOrigins: readonly string[];
  refreshBehavior: string;
  revokeBehavior: string;
  disconnectBehavior: string;
}

/** `evidence` is either an HTTPS sanitized evidence link or `sanitized-result:` text. */
export interface LiveEvidence {
  command: string;
  operationId: string;
  runAt: string;
  evidence: string;
}

export interface ProviderReadinessRow {
  providerId: string;
  supersedes?: string;
  catalogOwner: string;
  officialDocs: { url: string; apiVersion: string; verifiedAt: string; reviewer: string }[];
  operations: ProviderOperation[];
  auth: AuthProfile;
  effects: Record<string, { effect: Effect; approval: ApprovalPolicy }>;
  isolationEvidence: string[];
  fixtures: string[];
  automatedEvidence: { test: string; result: "not_run" | "passed" | "failed"; runAt: string | null };
  liveReadEvidence: LiveEvidence | null;
  liveWriteEvidence: LiveEvidence[];
  credentials: CredentialState;
  releaseState: "candidate" | "blocked" | "supported" | "deprecated";
}

export interface ProviderRegistration {
  definition: ProviderDefinition;
  row: ProviderReadinessRow;
}

export interface ProviderRegistry {
  registerProvider(definition: ProviderDefinition, row: ProviderReadinessRow): ProviderRegistration;
  get(providerId: string): ProviderRegistration | undefined;
  rows(): readonly ProviderReadinessRow[];
  definitions(): readonly ProviderDefinition[];
  /** Only fully evidenced supported definitions may enter a production catalog. */
  catalogDefinitions(): readonly ProviderDefinition[];
  assertCatalogCallable(providerId: string): ProviderDefinition;
}

const CREDENTIAL_STATES = new Set<CredentialState>(["not provided", "configured", "passed", "failed"]);
const RELEASE_STATES = new Set<ProviderReadinessRow["releaseState"]>(["candidate", "blocked", "supported", "deprecated"]);
const PLACEHOLDER = /(?:\bTODO\b|\bTBD\b|placeholder|not[ _-](?:run|executed)|fake(?: evidence)?|dummy|example\.com)/i;
const SECRET_LIKE = /(?:Bearer\s+\S+|api[_-]?key\s*[=:]\s*\S+|[?&](?:token|key|api_key)=|bot\d+:[A-Za-z0-9_-]+|sb_secret_[A-Za-z0-9_-]+)/i;
const READ_METHODS = new Set(["GET", "HEAD"]);
const GENERIC_ORIGINS = new Set([
  "fetch", "publicweb", "generic", "genericfetch", "generichttp", "http", "https",
  "httpclient", "webrequest", "url", "uri", "target", "endpoint",
]);
const GENERIC_OPERATIONS = new Set([
  "fetch", "request", "httprequest", "genericrequest", "genericfetch",
  "callapi", "apirequest", "apifetch", "webrequest",
]);
const GENERIC_ARGUMENTS = new Set([
  "url", "uri", "target", "endpoint", "requesturl", "targeturl", "endpointurl",
  "baseurl", "proxy", "method", "httpmethod", "headers", "request", "requestoptions",
  "fetchoptions",
]);

function normalizedAlias(value: string): string {
  return value.toLowerCase().replaceAll("_", "").replaceAll("-", "");
}

function fail(message: string): never {
  throw new Error(`Provider readiness rejected: ${message}`);
}

function text(value: unknown, field: string, max = 2_048): string {
  if (typeof value !== "string" || value.trim() === "" || value.length > max || PLACEHOLDER.test(value)) {
    fail(`${field} is incomplete or a placeholder.`);
  }
  return value;
}

function validCalendarDate(value: unknown, now: Date): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString().slice(0, 10) === value && parsed.valueOf() <= now.valueOf();
}

function validInstant(value: unknown, now: Date): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)) return false;
  const parsed = new Date(value);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString() === value && parsed.valueOf() <= now.valueOf();
}

function safeEvidenceText(value: unknown, field: string): string {
  const result = text(value, field, 16_384);
  if (SECRET_LIKE.test(result)) fail(`${field} contains credential-like material.`);
  if (result.startsWith("https://")) {
    let url: URL;
    try { url = new URL(result); } catch { return fail(`${field} has an invalid evidence link.`); }
    if (url.username !== "" || url.password !== "" || url.hash !== "" || SECRET_LIKE.test(url.search)) {
      fail(`${field} has an unsafe evidence link.`);
    }
  } else if (!result.startsWith("sanitized-result:")) {
    fail(`${field} must be a sanitized HTTPS link or sanitized-result text.`);
  }
  return result;
}

function validateAuth(auth: AuthProfile, profileId: string): void {
  if (auth === null || typeof auth !== "object") fail("auth profile is missing.");
  if (text(auth.profileId, "auth.profileId", 128) !== profileId) fail("auth profile ID mismatch.");
  text(auth.tokenType, "auth.tokenType");
  if (typeof auth.authorizationPrefix !== "string" || auth.authorizationPrefix.length > 64 || SECRET_LIKE.test(auth.authorizationPrefix)) {
    fail("auth.authorizationPrefix is invalid.");
  }
  if (!Array.isArray(auth.minimumScopes) || auth.minimumScopes.some((scope) => text(scope, "auth scope", 256) === "")) {
    fail("auth minimum scopes are invalid.");
  }
  if (!Array.isArray(auth.tenantOrigins) || auth.tenantOrigins.length === 0) fail("auth tenant origins are missing.");
  for (const origin of auth.tenantOrigins) {
    text(origin, "auth tenant origin", 512);
    if (!/^(?:https:\/\/|native:\/\/|public-web:\/\/)/.test(origin) || /[\s?#]/.test(origin) || origin.includes("@")) {
      fail("auth tenant origin is unsafe.");
    }
  }
  text(auth.refreshBehavior, "auth.refreshBehavior");
  text(auth.revokeBehavior, "auth.revokeBehavior");
  text(auth.disconnectBehavior, "auth.disconnectBehavior");
}

function assertRealOperation(operation: ProviderOperation, providerId: string): void {
  if (/^(?:ping|health|health_check|noop|test)$/i.test(operation.name) || /\/(?:ping|health|health_check|noop)\/?$/i.test(operation.request.pathTemplate)) {
    fail(`${providerId} uses a fake ping instead of a real typed operation.`);
  }
  const nativeFetch = providerId === "fetch" && operation.name === "fetch" &&
    operation.request.originKey === "public-web";
  const schemaProperties = operation.inputSchema.properties;
  const genericArgument = schemaProperties !== undefined && schemaProperties !== null && typeof schemaProperties === "object" &&
    Object.keys(schemaProperties).some((name) => GENERIC_ARGUMENTS.has(normalizedAlias(name)));
  const genericPath = [...operation.request.pathTemplate.matchAll(/\{([^{}]+)\}/g)]
    .some((match) => GENERIC_ARGUMENTS.has(normalizedAlias(match[1] ?? "")));
  if (!nativeFetch && (
    GENERIC_ORIGINS.has(normalizedAlias(operation.request.originKey)) ||
    GENERIC_OPERATIONS.has(normalizedAlias(operation.name)) ||
    genericArgument || genericPath
  )) {
    fail(`${providerId} uses a generic fetch implementation, model-controlled URL, or arbitrary request operation.`);
  }
  if (operation.effect === "read" && !READ_METHODS.has(operation.request.method)) {
    // POST is valid for documented read RPCs, but arbitrary mutations are not.
    if (!["POST"].includes(operation.request.method)) fail(`${providerId}/${operation.name} is not a real read.`);
  }
}

export function assertValidLiveEvidence(
  evidence: LiveEvidence,
  operations: readonly ProviderOperation[],
  write: boolean,
  providerId: string,
  now = new Date(),
): void {
  text(evidence.command, "live evidence command", 4_096);
  if (!evidence.command.includes("OVID_LIVE_PROVIDER_TESTS=1")) fail("live evidence lacks the explicit global opt-in command.");
  const optInEnv = `OVID_LIVE_PROVIDER_${providerId.toUpperCase().replaceAll("-", "_")}`;
  if (!evidence.command.includes(`${optInEnv}=1`)) fail(`live evidence lacks ${optInEnv}=1.`);
  if (write && !evidence.command.includes("OVID_LIVE_PROVIDER_WRITE_TESTS=1")) fail("write evidence lacks the separate write opt-in command.");
  if (write && !evidence.command.includes(`${optInEnv}_DISPOSABLE_RESOURCE`)) fail("write evidence lacks a disposable-resource declaration.");
  if (write && !/cleanup verified/i.test(evidence.evidence)) fail("write evidence lacks verified cleanup.");
  text(evidence.operationId, "live evidence operationId", 128);
  const operation = operations.find((candidate) => candidate.name === evidence.operationId);
  if (operation === undefined || (write ? operation.effect === "read" : operation.effect !== "read")) {
    fail(`live evidence operation ${evidence.operationId} is not an advertised ${write ? "write" : "read"}.`);
  }
  if (!validInstant(evidence.runAt, now)) fail("live evidence runAt must be an actual non-future ISO instant.");
  safeEvidenceText(evidence.evidence, "live evidence result/link");
}

function safeReference(value: unknown, field: string): void {
  const reference = text(value, field, 2_048);
  if (SECRET_LIKE.test(reference)) fail(`${field} contains credential-like material.`);
}

function sameJson(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b);
}

function validateRow(definition: ProviderDefinition, row: ProviderReadinessRow, now: Date): void {
  if (row === null || typeof row !== "object" || row.providerId !== definition.providerId) fail("provider ID mismatch.");
  if (row.supersedes !== undefined && (text(row.supersedes, "supersedes", 128) === row.providerId)) fail("provider cannot supersede itself.");
  text(row.catalogOwner, "catalogOwner", 256);
  if (!CREDENTIAL_STATES.has(row.credentials)) fail("credential state is invalid.");
  if (!RELEASE_STATES.has(row.releaseState)) fail("release state is invalid.");
  validateAuth(row.auth, definition.authProfileId);

  if (!Array.isArray(row.officialDocs) || row.officialDocs.length === 0) fail("official docs are missing.");
  const seenDocs = new Set<string>();
  for (const doc of row.officialDocs) {
    let url: URL;
    try { url = new URL(doc.url); } catch { return fail("official docs URL is invalid."); }
    if (url.protocol !== "https:" || url.username !== "" || url.password !== "") fail("official docs URL must be credential-free HTTPS.");
    text(doc.apiVersion, "official API version", 128);
    text(doc.reviewer, "official docs reviewer", 256);
    if (!validCalendarDate(doc.verifiedAt, now)) fail("official docs verification date is missing, impossible, or future.");
    if (!definition.officialDocs.some((candidate) => candidate.url === doc.url && candidate.verifiedAt === doc.verifiedAt)) {
      fail("official docs differ between definition and readiness row.");
    }
    if (seenDocs.has(doc.url)) fail("official docs contain duplicates.");
    seenDocs.add(doc.url);
  }
  if (definition.officialDocs.length !== row.officialDocs.length) fail("official docs coverage mismatch.");

  if (!Array.isArray(row.operations) || row.operations.length !== definition.operations.length) fail("operation count mismatch.");
  for (const operation of definition.operations) {
    assertRealOperation(operation, definition.providerId);
    const reflected = row.operations.find((candidate) => candidate.name === operation.name);
    if (reflected === undefined || !sameJson(reflected, operation)) fail(`operation mismatch for ${operation.name}.`);
    const effect = row.effects?.[operation.name];
    if (effect === undefined || effect.effect !== operation.effect || effect.approval !== operation.approval) {
      fail(`effect/approval mismatch for ${operation.name}.`);
    }
  }
  const effectNames = Object.keys(row.effects ?? {});
  if (effectNames.length !== definition.operations.length || effectNames.some((name) => !definition.operations.some((operation) => operation.name === name))) {
    fail("effects contain unknown or missing operations.");
  }

  if (!Array.isArray(row.isolationEvidence) || !Array.isArray(row.fixtures)) fail("isolation evidence or fixtures are missing.");
  if (!row.automatedEvidence || typeof row.automatedEvidence.test !== "string") fail("automated evidence is missing.");
  text(row.automatedEvidence.test, "automated evidence test", 1_024);
  if (!["not_run", "passed", "failed"].includes(row.automatedEvidence.result)) fail("automated evidence result is invalid.");
  if (row.automatedEvidence.result === "not_run") {
    if (row.automatedEvidence.runAt !== null) fail("not_run automated evidence cannot have a run date.");
  } else if (!validInstant(row.automatedEvidence.runAt, now)) {
    fail("executed automated evidence requires a non-future ISO run date.");
  }
  if (!Array.isArray(row.liveWriteEvidence)) fail("liveWriteEvidence must be an array.");
  if (row.liveReadEvidence !== null) assertValidLiveEvidence(row.liveReadEvidence, row.operations, false, row.providerId, now);
  for (const evidence of row.liveWriteEvidence) assertValidLiveEvidence(evidence, row.operations, true, row.providerId, now);

  if (row.releaseState !== "supported") return;
  if (!definition.operations.some((operation) => operation.effect === "read")) fail("supported provider lacks a real typed read.");
  if (row.isolationEvidence.length === 0 || row.fixtures.length === 0) fail("supported provider lacks isolation evidence or sanitized fixtures.");
  row.isolationEvidence.forEach((entry) => safeReference(entry, "isolation evidence"));
  row.fixtures.forEach((entry) => safeReference(entry, "fixture evidence"));
  if (row.automatedEvidence.result !== "passed") fail("supported provider lacks passing contract evidence.");
  if (row.credentials !== "passed" || row.liveReadEvidence === null) fail("supported provider lacks passed credentials and live-read evidence.");
  for (const operation of row.operations.filter((candidate) => candidate.effect !== "read")) {
    if (!row.liveWriteEvidence.some((evidence) => evidence.operationId === operation.name)) {
      fail(`supported provider lacks write evidence for ${operation.name}.`);
    }
  }
}

function deepSnapshot<T>(value: T): T {
  // snapshotProviderArgs recursively clones/freezes plain JSON data and rejects
  // accessors, cycles, sparse arrays, non-JSON values, and excessive depth/size.
  return snapshotProviderArgs(value as unknown as Record<string, unknown>) as unknown as T;
}

function validatedRegistration(
  definitionInput: ProviderDefinition,
  rowInput: ProviderReadinessRow,
  now: Date,
): ProviderRegistration {
  if (Number.isNaN(now.valueOf())) fail("registry clock is invalid.");
  const definition = deepSnapshot(definitionInput);
  const row = deepSnapshot(rowInput);
  if (row.releaseState !== "supported" && definition.operations.length === 0) {
    assertClosedProviderSchema(definition.connectionSchema);
    if (definition.providerId.trim() === "" || definition.catalogVersion.trim() === "" ||
        definition.displayName.trim() === "" || definition.description.trim() === "" ||
        definition.authProfileId.trim() === "") {
      fail("non-supported provider metadata is incomplete.");
    }
  } else {
    validateProviderDefinition(definition);
  }
  validateRow(definition, row, now);
  return Object.freeze({ definition, row });
}

export function createProviderRegistry(options: { now?: () => Date } = {}): ProviderRegistry {
  const registrations = new Map<string, ProviderRegistration>();
  const now = () => options.now?.() ?? new Date();

  function readRegistration(entry: ProviderRegistration): ProviderRegistration {
    // Revalidate on every read and return a fresh defensive frozen graph so
    // neither the original caller nor another reader can mutate registry state.
    return validatedRegistration(entry.definition, entry.row, now());
  }

  function registerProvider(definition: ProviderDefinition, row: ProviderReadinessRow): ProviderRegistration {
    const registration = validatedRegistration(definition, row, now());
    if (registrations.has(registration.definition.providerId)) {
      fail(`provider ID collides: ${registration.definition.providerId}.`);
    }
    registrations.set(registration.definition.providerId, registration);
    return readRegistration(registration);
  }

  return {
    registerProvider,
    get: (providerId) => {
      const entry = registrations.get(providerId);
      return entry === undefined ? undefined : readRegistration(entry);
    },
    rows: () => [...registrations.values()].map(readRegistration).map((entry) => entry.row),
    definitions: () => [...registrations.values()].map(readRegistration).map((entry) => entry.definition),
    catalogDefinitions: () => [...registrations.values()]
      .map(readRegistration)
      .filter((entry) => entry.row.releaseState === "supported")
      .map((entry) => entry.definition),
    assertCatalogCallable(providerId) {
      const entry = registrations.get(providerId);
      if (entry === undefined) throw new Error(`Provider ${providerId} is not supported and is unavailable for catalog calls.`);
      const registration = readRegistration(entry);
      if (registration.row.releaseState !== "supported") {
        throw new Error(`Provider ${providerId} is not supported and is unavailable for catalog calls.`);
      }
      return registration.definition;
    },
  };
}
