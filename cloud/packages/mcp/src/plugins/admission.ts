// Pure approved-source admission. This module performs no resolution, I/O, or
// installation: callers must load `registered` from the authoritative per-user
// approved-source store and invoke this gate BEFORE giving work to a resolver.
// The returned value contains only the admitted reference and reviewed source
// metadata; raw source/config/model/prompt/shell job fields are never accepted.

import { PLUGIN_CAPABILITIES } from "./capabilities.js";

/** The complete persisted approved-source shape (Task 12 contract). */
export interface ApprovedSource {
  approvedSourceId: string;
  userId: string;
  canonicalSource: string;
  resolvedRevision: string;
  digest: string;
  provenance: Record<string, unknown>;
  validationState: "validated";
  approvalState: "approved";
  approvedCapabilities: string[];
}

/** The only install/uninstall job fields this admission boundary accepts. */
export interface ApprovedSourceJob {
  approvedSourceId: string;
  expectedDigest: string;
  installationId: string;
  userId: string;
  mode: "install" | "uninstall";
}

/** Inspected facts which must exactly match the user's registered approval. */
export interface ApprovedSourceInspection {
  canonicalSource: string;
  resolvedRevision: string;
  digest: string;
  capabilities: string[];
}

export interface ApprovedSourceAdmissionRecord {
  job: ApprovedSourceJob;
  /** Null means there is no registered approval for this per-user reference. */
  registered: ApprovedSource | null;
  inspected: ApprovedSourceInspection;
}

/** Admitted for a later staging operation; no bytes have been staged here. */
export interface StagedApprovedSource {
  installationId: string;
  mode: ApprovedSourceJob["mode"];
  approvedSource: ApprovedSource;
}

export type ApprovedSourceAdmissionErrorCode =
  | "invalid_job"
  | "invalid_registered_source"
  | "unregistered_source"
  | "approval_required"
  | "owner_mismatch"
  | "source_mismatch"
  | "digest_mismatch"
  | "capability_mismatch";

/** Value-free denial: source text, pasted config, and secrets are not echoed. */
export class ApprovedSourceAdmissionError extends Error {
  constructor(readonly code: ApprovedSourceAdmissionErrorCode) {
    super(code);
    this.name = "ApprovedSourceAdmissionError";
  }
}

const JOB_KEYS = [
  "approvedSourceId",
  "expectedDigest",
  "installationId",
  "userId",
  "mode",
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
const INSPECTION_KEYS = [
  "canonicalSource",
  "resolvedRevision",
  "digest",
  "capabilities",
] as const;
const KNOWN_CAPABILITIES: ReadonlySet<string> = new Set(PLUGIN_CAPABILITIES);
const PROVENANCE_KEYS: ReadonlySet<string> = new Set([
  "kind",
  "githubRepo",
  "resolvedRef",
  "revision",
  "npmPackage",
  "npmVersion",
  "integrity",
  "url",
]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const actual = Object.keys(value);
  return actual.length === keys.length && keys.every((key) =>
    Object.prototype.hasOwnProperty.call(value, key),
  );
}

function nonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function validCapabilities(value: unknown): value is string[] {
  return (
    Array.isArray(value) &&
    value.every((capability) =>
      nonEmptyString(capability) && KNOWN_CAPABILITIES.has(capability),
    ) &&
    new Set(value).size === value.length
  );
}

function validProvenance(value: unknown): value is Record<string, unknown> {
  return (
    isRecord(value) &&
    nonEmptyString(value.kind) &&
    Object.entries(value).every(
      ([key, entry]) => PROVENANCE_KEYS.has(key) && nonEmptyString(entry),
    )
  );
}

function sameCapabilities(left: readonly string[], right: readonly string[]): boolean {
  const sortedLeft = [...left].sort();
  const sortedRight = [...right].sort();
  return (
    sortedLeft.length === sortedRight.length &&
    sortedLeft.every((capability, index) => capability === sortedRight[index])
  );
}

function deny(code: ApprovedSourceAdmissionErrorCode): never {
  throw new ApprovedSourceAdmissionError(code);
}

/**
 * Validate the exact approved binding. Resolution is deliberately outside this
 * pure primitive, so every denial necessarily happens before a resolver can be
 * invoked by a correctly composed caller. Any canonical-source, revision,
 * digest, or capability change requires a newly registered approval.
 */
export async function admitApprovedSource(
  record: ApprovedSourceAdmissionRecord,
): Promise<StagedApprovedSource> {
  if (!isRecord(record) || !isRecord(record.job) || !hasExactKeys(record.job, JOB_KEYS)) {
    return deny("invalid_job");
  }
  const job = record.job;
  if (
    !nonEmptyString(job.approvedSourceId) ||
    !nonEmptyString(job.expectedDigest) ||
    !nonEmptyString(job.installationId) ||
    !nonEmptyString(job.userId) ||
    (job.mode !== "install" && job.mode !== "uninstall")
  ) {
    return deny("invalid_job");
  }

  if (record.registered === null) return deny("unregistered_source");
  if (!isRecord(record.registered) || !hasExactKeys(record.registered, SOURCE_KEYS)) {
    return deny("invalid_registered_source");
  }
  const registered = record.registered;
  if (
    registered.validationState !== "validated" ||
    registered.approvalState !== "approved"
  ) {
    return deny("approval_required");
  }
  if (
    !nonEmptyString(registered.approvedSourceId) ||
    !nonEmptyString(registered.userId) ||
    !nonEmptyString(registered.canonicalSource) ||
    !nonEmptyString(registered.resolvedRevision) ||
    !nonEmptyString(registered.digest) ||
    !validProvenance(registered.provenance) ||
    !validCapabilities(registered.approvedCapabilities)
  ) {
    return deny("invalid_registered_source");
  }

  if (job.userId !== registered.userId) return deny("owner_mismatch");
  if (job.approvedSourceId !== registered.approvedSourceId) {
    return deny("source_mismatch");
  }
  if (job.expectedDigest !== registered.digest) return deny("digest_mismatch");

  if (
    !isRecord(record.inspected) ||
    !hasExactKeys(record.inspected, INSPECTION_KEYS) ||
    !nonEmptyString(record.inspected.canonicalSource) ||
    !nonEmptyString(record.inspected.resolvedRevision) ||
    !nonEmptyString(record.inspected.digest)
  ) {
    return deny("source_mismatch");
  }
  const inspected = record.inspected;
  if (
    inspected.canonicalSource !== registered.canonicalSource ||
    inspected.resolvedRevision !== registered.resolvedRevision
  ) {
    return deny("source_mismatch");
  }
  if (inspected.digest !== registered.digest) return deny("digest_mismatch");
  if (
    !validCapabilities(inspected.capabilities) ||
    !sameCapabilities(inspected.capabilities, registered.approvedCapabilities)
  ) {
    return deny("capability_mismatch");
  }

  return {
    installationId: job.installationId,
    mode: job.mode,
    approvedSource: {
      approvedSourceId: registered.approvedSourceId,
      userId: registered.userId,
      canonicalSource: registered.canonicalSource,
      resolvedRevision: registered.resolvedRevision,
      digest: registered.digest,
      provenance: { ...registered.provenance },
      validationState: "validated",
      approvalState: "approved",
      approvedCapabilities: [...registered.approvedCapabilities],
    },
  };
}
