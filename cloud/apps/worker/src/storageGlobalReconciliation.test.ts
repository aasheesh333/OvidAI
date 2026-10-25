import { createHash } from "node:crypto";

import { describe, expect, it, vi } from "vitest";

import {
  canonicalStorageGlobalJson,
  createGlobalStorageDryRunReport,
  decodeGlobalStorageCursor,
  encodeGlobalStorageCursor,
  inspectGlobalStoragePage,
  parseExactDryRunOptions,
  type ExactDryRunOptions,
  type GlobalStorageCursor,
  type GlobalStorageDryRunPage,
  type GlobalStoragePageOutcome,
  type GlobalStorageReadPageRequest,
} from "./storageGlobalReconciliation.js";

// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
// No test runner, typecheck, build, Postgres, R2, timer, or deploy was used.

const OBSERVED_AT = "2026-10-25T12:00:00.000Z";

function exactOptions(overrides: Partial<ExactDryRunOptions> = {}): ExactDryRunOptions {
  return {
    schemaVersion: 1,
    reportFormatVersion: 1,
    cycleId: "cycle-test",
    stream: "attachment",
    highWaterId: "row-zz",
    afterId: null,
    legacyEvidencePolicy: null,
    olderThanMs: 900_000,
    scanLimit: 2,
    ioLimit: 0,
    maxOwners: 2,
    perOwnerIoLimit: 2,
    reportLimit: 2,
    deadlineMs: 1_000,
    ...overrides,
  };
}

function cursor(overrides: Partial<GlobalStorageCursor> = {}): GlobalStorageCursor {
  return {
    schemaVersion: 1,
    cycleId: "cycle-test",
    stream: "attachment",
    highWaterId: "row-zz",
    afterId: null,
    ...overrides,
  };
}

function emptyPage(overrides: Partial<GlobalStorageDryRunPage> = {}): GlobalStorageDryRunPage {
  return {
    outcomes: [],
    examinedRawRows: 0,
    scanComplete: true,
    reportCompleteForApproval: true,
    nextCursor: null,
    stopReason: null,
    ownersTouched: 0,
    ...overrides,
  };
}

function outcome(rawId = "row-1"): GlobalStoragePageOutcome {
  return {
    version: 1,
    stream: "attachment",
    rawId,
    identity: `attachment:${rawId}`,
    fingerprint: `sha256:${"a".repeat(64)}`,
    classification: {
      disposition: "ordinary_candidate",
      reason: "active_source_reconciliation",
      dryRunOnly: false,
    },
    generation: {
      version: 1,
      stream: "attachment",
      raw: { id: rawId },
      attachments: [],
      workspaceObjects: [],
      reservations: [],
      reservationSetComplete: true,
      dependentShares: [],
      dependentShareSetComplete: true,
      authority: {
        session: [],
        ownerAccount: [],
        actorAccount: [],
        collabRooms: [],
      },
      factsComplete: true,
    },
    history: {
      actorProvenance: "existing_reservation",
      originalFinalizedAt: null,
      originalFinalizedAtUnknown: false,
      reservedAtProvenance: "existing_reservation",
    },
  };
}

describe("versioned canonical cursor and semantic options (UNEXECUTED)", () => {
  it("round-trips exact canonical cursor JSON", () => {
    expect(encodeGlobalStorageCursor(cursor())).toBe(
      '{"afterId":null,"cycleId":"cycle-test","highWaterId":"row-zz","schemaVersion":1,"stream":"attachment"}',
    );
    expect(decodeGlobalStorageCursor(encodeGlobalStorageCursor(cursor()))).toEqual(cursor());
    expect(decodeGlobalStorageCursor(new TextEncoder().encode(encodeGlobalStorageCursor(cursor())))).toEqual(cursor());
  });

  it("rejects a UTF-8 BOM even when the decoded cursor JSON is otherwise canonical", () => {
    const canonical = new TextEncoder().encode(encodeGlobalStorageCursor(cursor()));
    const withBom = new Uint8Array([0xef, 0xbb, 0xbf, ...canonical]);
    expect(() => decodeGlobalStorageCursor(withBom)).toThrow(/UTF-8|canonical|byte/i);
  });

  it.each([
    '{"afterId":null,"cycleId":"cycle-test","highWaterId":"row-zz","schemaVersion":2,"stream":"attachment"}',
    '{"afterId":null,"cycleId":"cycle-test","highWaterId":"row-zz","schemaVersion":1,"stream":"unknownHistory"}',
    '{"afterId":null,"cycleId":"cycle-test","highWaterId":"row-zz","schemaVersion":1,"stream":"attachment","extra":true}',
    '{ "afterId":null,"cycleId":"cycle-test","highWaterId":"row-zz","schemaVersion":1,"stream":"attachment"}',
  ])("rejects noncanonical, unknown, or version-mismatched cursor data: %s", (encoded) => {
    expect(() => decodeGlobalStorageCursor(encoded)).toThrow();
  });

  it("canonicalizes semantic options without serializing runtime handles", () => {
    const withHandles = {
      ...exactOptions(),
      db: { unsafe: vi.fn() },
      storage: { head: vi.fn(), delete: vi.fn() },
      shareCleanupIo: { beginDeleteAndReadback: vi.fn() },
      signal: new AbortController().signal,
      now: () => new Date(),
    };
    expect(() => parseExactDryRunOptions(withHandles)).toThrow(/unrecognized/i);

    const policy = {
      policyId: "legacy-policy-1",
      pre0038Boundary: "2026-10-20T00:00:00.000Z",
      allowedHostKinds: ["artifact", "attachment"],
      creationAdmissionRule: "host_created_at_before_boundary",
      actorEvidenceRule: "owner_is_actor",
      reconstructReservedAtFromHostCreatedAt: true,
      rollingHistoryPolicyId: "rolling-policy-1",
      rollingHistoryMeaning: "Approved reconstruction basis only; not observed completion history.",
    };
    const parsed = parseExactDryRunOptions({ ...exactOptions(), legacyEvidencePolicy: policy });
    expect(parsed.legacyEvidencePolicy?.allowedHostKinds).toEqual(["artifact", "attachment"]);
    expect(canonicalStorageGlobalJson(parsed)).not.toContain("shareCleanupIo");
    expect(canonicalStorageGlobalJson(parsed)).not.toContain("signal");
    expect(canonicalStorageGlobalJson(parsed)).not.toContain("storage");
    const reversed = parseExactDryRunOptions({
      ...parsed,
      legacyEvidencePolicy: { ...policy, allowedHostKinds: ["attachment", "artifact"] },
    });
    expect(canonicalStorageGlobalJson(reversed)).not.toBe(canonicalStorageGlobalJson(parsed));
  });

  it("rejects sparse and undefined legacy policy host-kind entries", () => {
    const policy = {
      policyId: "legacy-policy-1",
      pre0038Boundary: "2026-10-20T00:00:00.000Z",
      allowedHostKinds: ["attachment"],
      creationAdmissionRule: "host_created_at_before_boundary",
      actorEvidenceRule: "owner_is_actor",
      reconstructReservedAtFromHostCreatedAt: false,
      rollingHistoryPolicyId: "rolling-policy-1",
      rollingHistoryMeaning: "No observed completion recovery.",
    } as NonNullable<ExactDryRunOptions["legacyEvidencePolicy"]>;
    const sparse = new Array(1) as Array<"attachment" | "artifact">;
    const explicitUndefined = [undefined] as unknown as Array<"attachment" | "artifact">;
    for (const allowedHostKinds of [sparse, explicitUndefined]) {
      expect(() => parseExactDryRunOptions({
        ...exactOptions(),
        legacyEvidencePolicy: { ...policy, allowedHostKinds },
      })).toThrow(/dense|sparse|undefined|index/i);
    }
  });

  it("requires zero storage I/O and enforces every structural bound", () => {
    expect(() => parseExactDryRunOptions(exactOptions({ olderThanMs: 899_999 }))).toThrow();
    expect(() => parseExactDryRunOptions(exactOptions({ scanLimit: 0 }))).toThrow();
    expect(() => parseExactDryRunOptions(exactOptions({ ioLimit: 1 as 0 }))).toThrow(/ioLimit/i);
    expect(() => parseExactDryRunOptions(exactOptions({ maxOwners: 17 }))).toThrow();
    expect(() => parseExactDryRunOptions(exactOptions({ perOwnerIoLimit: 0 }))).toThrow();
    expect(() => parseExactDryRunOptions(exactOptions({ perOwnerIoLimit: 9 }))).toThrow();
    expect(() => parseExactDryRunOptions(exactOptions({ reportLimit: 0 }))).toThrow();
    expect(() => parseExactDryRunOptions(exactOptions({ deadlineMs: 0 }))).toThrow();
  });

  it("rejects nonfinite, unsafe, noncanonical timestamp, and secret-bearing values", () => {
    expect(() => parseExactDryRunOptions(exactOptions({ deadlineMs: Number.POSITIVE_INFINITY }))).toThrow();
    expect(() => parseExactDryRunOptions(exactOptions({ deadlineMs: Number.MAX_SAFE_INTEGER + 1 }))).toThrow();
    const policy = {
      policyId: "legacy-policy-1",
      pre0038Boundary: "2026-10-20T00:00:00.000Z",
      allowedHostKinds: ["attachment"],
      creationAdmissionRule: "host_created_at_before_boundary",
      actorEvidenceRule: "owner_is_actor",
      reconstructReservedAtFromHostCreatedAt: false,
      rollingHistoryPolicyId: "rolling-policy-1",
      rollingHistoryMeaning: "No observed completion recovery.",
    } as NonNullable<ExactDryRunOptions["legacyEvidencePolicy"]>;
    expect(() => parseExactDryRunOptions(exactOptions({
      legacyEvidencePolicy: { ...policy, pre0038Boundary: "2026-10-20T00:00:00+00:00" },
    }))).toThrow(/RFC|UTC|canonical/i);
    expect(() => parseExactDryRunOptions(exactOptions({
      legacyEvidencePolicy: { ...policy, credential: "do-not-serialize" } as ExactDryRunOptions["legacyEvidencePolicy"],
    }))).toThrow(/unrecognized/i);
  });
});

describe("exact page-local dry-run report bytes (UNEXECUTED)", () => {
  it("pins canonical empty-report UTF-8 bytes and lowercase SHA-256", () => {
    const report = createGlobalStorageDryRunReport({
      options: exactOptions(),
      page: emptyPage(),
      observedAt: OBSERVED_AT,
    });
    const expected = '{"byteEvidenceComplete":false,"cycle":{"cycleId":"cycle-test","endingAfterId":null,"highWaterId":"row-zz","startingAfterId":null,"stream":"attachment"},"dbDiscoverableCoverageOnly":true,"nextCursor":null,"options":{"afterId":null,"cycleId":"cycle-test","deadlineMs":1000,"highWaterId":"row-zz","ioLimit":0,"legacyEvidencePolicy":null,"maxOwners":2,"olderThanMs":900000,"perOwnerIoLimit":2,"reportFormatVersion":1,"reportLimit":2,"scanLimit":2,"schemaVersion":1,"stream":"attachment"},"outcomes":[],"page":{"examinedRawRows":0,"ownersTouched":0,"stopReason":null},"projectedUsedBytes":null,"reportCompleteForApproval":true,"reportFormatVersion":1,"rollingHistoryComplete":false,"scanComplete":true,"usedBytes":null}';
    expect(new TextDecoder().decode(report.bytes)).toBe(expected);
    expect(report.sha256).toBe(createHash("sha256").update(report.bytes).digest("hex"));
    expect(report.sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(report.view).toEqual(JSON.parse(expected));
  });

  it("keeps object key order semantic and report bytes deterministic across restart-shaped input", () => {
    const options = exactOptions();
    const reordered = JSON.parse(JSON.stringify({
      deadlineMs: options.deadlineMs,
      reportLimit: options.reportLimit,
      perOwnerIoLimit: options.perOwnerIoLimit,
      schemaVersion: options.schemaVersion,
      olderThanMs: options.olderThanMs,
      maxOwners: options.maxOwners,
      legacyEvidencePolicy: options.legacyEvidencePolicy,
      ioLimit: options.ioLimit,
      stream: options.stream,
      highWaterId: options.highWaterId,
      cycleId: options.cycleId,
      afterId: options.afterId,
      scanLimit: options.scanLimit,
      reportFormatVersion: options.reportFormatVersion,
    })) as ExactDryRunOptions;
    const first = createGlobalStorageDryRunReport({ options, page: emptyPage(), observedAt: OBSERVED_AT });
    const second = createGlobalStorageDryRunReport({ options: reordered, page: emptyPage(), observedAt: OBSERVED_AT });
    expect(second.bytes).toEqual(first.bytes);
    expect(second.sha256).toBe(first.sha256);
  });

  it("reports HEAD not_requested, null measured evidence, and review-only page-local outcomes", () => {
    const page = emptyPage({
      outcomes: [outcome()],
      examinedRawRows: 1,
      scanComplete: false,
      nextCursor: cursor({ afterId: "row-1" }),
      stopReason: "scan_limit",
      ownersTouched: 1,
    });
    const report = createGlobalStorageDryRunReport({ options: exactOptions(), page, observedAt: OBSERVED_AT });
    expect(report.view.outcomes[0]).toMatchObject({
      head: "not_requested",
      measuredBytes: null,
      measuredContentType: null,
      observedAt: OBSERVED_AT,
      proposedAction: "ordinary_review",
      proposedActionReason: "active_source_reconciliation",
      accountingOutcome: "notAttempted",
      physicalOutcome: "notAttempted",
      readbackOutcome: "notAttempted",
      completeness: { scanComplete: false, reportCompleteForApproval: true },
    });
    expect(report.view).toMatchObject({
      scanComplete: false,
      reportCompleteForApproval: true,
      byteEvidenceComplete: false,
      rollingHistoryComplete: false,
      usedBytes: null,
      projectedUsedBytes: null,
      dbDiscoverableCoverageOnly: true,
    });
  });

  it("never promotes raw scan completion, including history-stream completion, to fleet claims", () => {
    for (const stream of ["attachment", "history"] as const) {
      const report = createGlobalStorageDryRunReport({
        options: exactOptions({ stream }),
        page: emptyPage({ scanComplete: true, reportCompleteForApproval: true }),
        observedAt: OBSERVED_AT,
      });
      expect(report.view.scanComplete).toBe(true);
      expect(report.view.reportCompleteForApproval).toBe(true);
      expect(report.view.byteEvidenceComplete).toBe(false);
      expect(report.view.rollingHistoryComplete).toBe(false);
      expect(report.view.usedBytes).toBeNull();
      expect(report.view.projectedUsedBytes).toBeNull();
    }
  });

  it("rejects sparse outcomes, nested generation arrays, and undefined canonical entries", () => {
    const pageWith = (outcomes: GlobalStoragePageOutcome[]) => emptyPage({
      outcomes,
      examinedRawRows: 1,
      scanComplete: false,
      nextCursor: cursor({ afterId: "row-1" }),
      stopReason: "scan_limit",
      ownersTouched: 1,
      reportCompleteForApproval: true,
    });
    const sparse = new Array(1) as GlobalStoragePageOutcome[];
    expect(() => canonicalStorageGlobalJson(sparse)).toThrow(/dense|sparse|undefined|index/i);
    expect(() => createGlobalStorageDryRunReport({
      options: exactOptions(),
      page: pageWith(sparse),
      observedAt: OBSERVED_AT,
    })).toThrow(/dense|sparse|undefined|index/i);

    const nested = outcome();
    nested.generation.workspaceObjects = new Array(1);
    expect(() => createGlobalStorageDryRunReport({
      options: exactOptions(),
      page: pageWith([nested]),
      observedAt: OBSERVED_AT,
    })).toThrow(/dense|sparse|undefined|index/i);

    const explicitUndefined = [undefined] as unknown as GlobalStoragePageOutcome[];
    expect(() => canonicalStorageGlobalJson(explicitUndefined)).toThrow(/dense|sparse|undefined|index/i);
    const nullOutcome = [null] as unknown as GlobalStoragePageOutcome[];
    expect(() => createGlobalStorageDryRunReport({
      options: exactOptions(),
      page: pageWith(nullOutcome),
      observedAt: OBSERVED_AT,
    })).toThrow(/outcome|fingerprint/i);
  });

  it("preserves conservative incomplete reporting for deadline, truncation, or omitted fingerprints", () => {
    for (const stopReason of ["deadline", "report_limit"] as const) {
      const report = createGlobalStorageDryRunReport({
        options: exactOptions(),
        page: emptyPage({
          scanComplete: false,
          reportCompleteForApproval: false,
          nextCursor: cursor(),
          stopReason,
        }),
        observedAt: OBSERVED_AT,
      });
      expect(report.view.reportCompleteForApproval).toBe(false);
      expect(report.view.byteEvidenceComplete).toBe(false);
      expect(report.view.rollingHistoryComplete).toBe(false);
    }

    const omittedFingerprint: Partial<GlobalStoragePageOutcome> = outcome();
    delete omittedFingerprint.fingerprint;
    expect(() => createGlobalStorageDryRunReport({
      options: exactOptions(),
      page: emptyPage({
        outcomes: [omittedFingerprint as GlobalStoragePageOutcome],
        examinedRawRows: 1,
        scanComplete: false,
        nextCursor: cursor({ afterId: "row-1" }),
        stopReason: "scan_limit",
        ownersTouched: 1,
        reportCompleteForApproval: true,
      }),
      observedAt: OBSERVED_AT,
    })).toThrow(/fingerprint/i);
  });

  it("forces raw/current identity mismatches report-incomplete without erasing raw scan evidence", () => {
    const mismatch = outcome();
    mismatch.classification = {
      disposition: "unresolved",
      reason: "raw_current_identity_mismatch",
      dryRunOnly: true,
    };
    const report = createGlobalStorageDryRunReport({
      options: exactOptions(),
      page: emptyPage({
        outcomes: [mismatch],
        examinedRawRows: 1,
        scanComplete: true,
        reportCompleteForApproval: true,
        nextCursor: null,
        stopReason: null,
        ownersTouched: 1,
      }),
      observedAt: OBSERVED_AT,
    });
    expect(mismatch.generation.factsComplete).toBe(true);
    expect(report.view.reportCompleteForApproval).toBe(false);
    expect(report.view.outcomes[0]).toMatchObject({
      rawId: "row-1",
      fingerprint: mismatch.fingerprint,
      head: "not_requested",
      measuredBytes: null,
      measuredContentType: null,
      completeness: { scanComplete: true, reportCompleteForApproval: false },
    });
    expect(report.view.page.examinedRawRows).toBe(1);
    expect(report.view.cycle.endingAfterId).toBe("row-1");
    expect(report.view.scanComplete).toBe(true);
    expect(report.view.nextCursor).toBeNull();
    expect(report.view.byteEvidenceComplete).toBe(false);
    expect(report.view.rollingHistoryComplete).toBe(false);
  });

  it("binds exact options and rejects an altered continuation scope", () => {
    const first = createGlobalStorageDryRunReport({ options: exactOptions(), page: emptyPage(), observedAt: OBSERVED_AT });
    const changed = createGlobalStorageDryRunReport({
      options: exactOptions({ cycleId: "cycle-other" }),
      page: emptyPage(),
      observedAt: OBSERVED_AT,
    });
    expect(changed.bytes).not.toEqual(first.bytes);
    expect(changed.sha256).not.toBe(first.sha256);

    expect(() => createGlobalStorageDryRunReport({
      options: exactOptions(),
      page: emptyPage({
        outcomes: [outcome()],
        examinedRawRows: 1,
        scanComplete: false,
        nextCursor: cursor({ cycleId: "cycle-other", afterId: "row-1" }),
        stopReason: "scan_limit",
        ownersTouched: 1,
      }),
      observedAt: OBSERVED_AT,
    })).toThrow(/scope/i);
  });

  it("changes exact bytes and digest when any proposed review action changes", () => {
    const page = emptyPage({
      outcomes: [outcome()],
      examinedRawRows: 1,
      scanComplete: false,
      nextCursor: cursor({ afterId: "row-1" }),
      stopReason: "scan_limit",
      ownersTouched: 1,
    });
    const first = createGlobalStorageDryRunReport({ options: exactOptions(), page, observedAt: OBSERVED_AT });
    const changedOutcome = outcome();
    changedOutcome.classification = {
      disposition: "unresolved",
      reason: "live_accounting_inconsistent",
      dryRunOnly: true,
    };
    const second = createGlobalStorageDryRunReport({
      options: exactOptions(),
      page: { ...page, outcomes: [changedOutcome] },
      observedAt: OBSERVED_AT,
    });
    expect(second.view.outcomes[0]!.proposedAction).toBe("unresolved_review");
    expect(second.bytes).not.toEqual(first.bytes);
    expect(second.sha256).not.toBe(first.sha256);
  });

  it("rejects a reader that advances past an unexamined or malformed next item", () => {
    expect(() => createGlobalStorageDryRunReport({
      options: exactOptions(),
      page: emptyPage({
        outcomes: [outcome("row-1")],
        examinedRawRows: 1,
        scanComplete: false,
        nextCursor: cursor({ afterId: "row-99" }),
        stopReason: "scan_limit",
        ownersTouched: 1,
      }),
      observedAt: OBSERVED_AT,
    })).toThrow("Next cursor skips an unexamined or malformed item");
  });
});

describe("unwired bounded page executor (UNEXECUTED)", () => {
  it("passes clock/deadline/signal only through execution and calls only the read port", async () => {
    const storage = { head: vi.fn(), delete: vi.fn(), put: vi.fn() };
    const mutations = {
      reconcileStorageUsage: vi.fn(),
      storageUsage: vi.fn(),
      reserve: vi.fn(),
      finalize: vi.fn(),
      release: vi.fn(),
      remove: vi.fn(),
      cleanup: vi.fn(),
    };
    const readPage = vi.fn(async (_request: GlobalStorageReadPageRequest) => emptyPage());
    const controller = new AbortController();
    const execution = {
      readPage,
      now: () => new Date(OBSERVED_AT),
      signal: controller.signal,
      // Structural poison: the unwired executor has no storage or mutation port.
      storage,
      mutations,
    };
    const report = await inspectGlobalStoragePage(execution, exactOptions());

    expect(readPage).toHaveBeenCalledTimes(1);
    const request = readPage.mock.calls[0]![0];
    expect(request.options).toEqual(exactOptions());
    expect(request.observedAt).toBe(OBSERVED_AT);
    expect(request.deadlineExceeded()).toBe(false);
    expect(request.options).not.toHaveProperty("storage");
    expect(request.options).not.toHaveProperty("signal");
    expect(report.view.byteEvidenceComplete).toBe(false);
    for (const spy of [storage.head, storage.delete, storage.put, ...Object.values(mutations)]) {
      expect(spy).not.toHaveBeenCalled();
    }
  });

  it("fails closed before I/O when the caller is already aborted", async () => {
    const readPage = vi.fn(async (_request: GlobalStorageReadPageRequest) => emptyPage());
    const controller = new AbortController();
    controller.abort();
    const report = await inspectGlobalStoragePage({ readPage, now: () => new Date(OBSERVED_AT), signal: controller.signal }, exactOptions());
    expect(readPage).not.toHaveBeenCalled();
    expect(report.view.scanComplete).toBe(false);
    expect(report.view.reportCompleteForApproval).toBe(false);
    expect(report.view.byteEvidenceComplete).toBe(false);
  });
});
