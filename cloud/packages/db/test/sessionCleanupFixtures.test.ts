import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

// UNEXECUTED under HEAVY-COMMANDS-PAUSED.md. Source-level consumer regression,
// not runtime evidence or a replacement for the real-Postgres cleanup suites.
describe("sessionCleanupFixtures finalization fence", () => {
  it("passes the complete all-root snapshot IDs and canonical content fingerprint", async () => {
    const source = await readFile(
      new URL("./sessionCleanupFixtures.ts", import.meta.url),
      "utf8",
    );
    expect(source).toContain("snapshotRootFinalization");
    expect(source).toContain("fingerprintRootFinalizationReports");
    expect(source).toContain(
      "expectedReportAttemptIds: snapshot.reports.map((report) => report.attemptId)",
    );
    expect(source).toContain(
      "expectedReportFingerprint: fingerprintRootFinalizationReports(snapshot.reports)",
    );
    expect(source).toContain("activeAttemptIds: snapshot.activeAttemptIds");
    expect(source).toContain("executionEpoch: snapshot.executionEpoch");
    expect(source).not.toContain("expectedReportAttemptIds: []");
  });
});
