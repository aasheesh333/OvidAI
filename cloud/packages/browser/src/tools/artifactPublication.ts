/** Stable, provider-text-free artifact publication failure for browser tools. */
export function artifactPublicationFailure(error: unknown): string {
  const code = typeof (error as { code?: unknown } | null)?.code === "string"
    ? String((error as { code: string }).code)
    : "artifact_unavailable";
  const safeCode = /^[a-z][a-z0-9_]{2,64}$/.test(code) ? code : "artifact_unavailable";
  const message = safeCode === "project_file_limit"
    ? "The project file allowance is exhausted."
    : safeCode === "storage_quota_exceeded" || safeCode === "upload_limit_reached"
      ? "The storage allowance for this plan is exhausted."
      : "Artifact publication is temporarily unavailable.";
  return `error: ${safeCode}: ${message}`;
}
