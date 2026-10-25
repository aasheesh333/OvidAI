import { describe, expect, it, vi } from "vitest";

import type { Db } from "./client.js";
import {
  GLOBAL_STORAGE_STREAMS,
  classifyGlobalStorageGeneration,
  readGlobalStorageHighWater,
  readGlobalStoragePage,
  type GlobalStorageCurrentFacts,
  type GlobalStorageCursor,
  type GlobalStorageStream,
  type LegacyEvidencePolicy,
} from "./storageGlobalReconciliation.js";

// UNEXECUTED under /tmp/opencode/ovid-production-completion/HEAVY-COMMANDS-PAUSED.md.
// These are source regressions only; this suite has not been run.

const OBSERVED_AT = "2026-10-25T12:00:00.000Z";

function cursor(stream: GlobalStorageStream, afterId: string | null = null): GlobalStorageCursor {
  return {
    schemaVersion: 1,
    cycleId: "cycle-test",
    stream,
    highWaterId: "row-zz",
    afterId,
  };
}

function attachment(id: string | null, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id,
    session_id: "session-1",
    user_id: "owner-1",
    project_id: null,
    name: "note.txt",
    size: 12,
    r2_key: `users/owner-1/sessions/session-1/uploads/${id}`,
    content_type: "text/plain",
    content_type_declared: true,
    upload_status: "ready",
    actual_bytes: 12,
    actual_content_type: "text/plain",
    finalized_at: "2026-10-25T10:00:00.000Z",
    message_id: null,
    created_at: "2026-10-25T09:00:00.000Z",
    ...overrides,
  };
}

function workspace(id: string, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id,
    user_id: "owner-1",
    session_id: "session-1",
    project_id: null,
    kind: "artifact",
    r2_key: `users/owner-1/artifacts/session-1/${id}-result.txt`,
    bytes: 12,
    sha256: "a".repeat(64),
    content_type: "text/plain",
    generation: null,
    status: "active",
    meta: { name: "result.txt" },
    created_at: "2026-10-25T09:00:00.000Z",
    ...overrides,
  };
}

function reservation(id: string, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id,
    actor_user_id: "owner-1",
    owner_user_id: "owner-1",
    session_id: "session-1",
    object_id: id,
    state: "finalized",
    declared_bytes: 12,
    actual_bytes: 12,
    actual_content_type: "text/plain",
    etag: "etag-1",
    reserved_at: "2026-10-25T09:00:00.000Z",
    finalized_at: "2026-10-25T10:00:00.000Z",
    released_at: null,
    created_at: "2026-10-25T09:00:00.000Z",
    updated_at: "2026-10-25T10:00:00.000Z",
    ...overrides,
  };
}

function facts(overrides: Partial<GlobalStorageCurrentFacts> = {}): GlobalStorageCurrentFacts {
  return {
    attachments: [],
    workspaceObjects: [],
    reservations: [],
    dependentShares: [],
    session: [{
      id: "session-1",
      user_id: "owner-1",
      deleted_at: null,
      updated_at: "2026-10-25T10:00:00.000Z",
    }],
    ownerAccount: [{ uid: "owner-1", state: null, updated_at: null }],
    actorAccount: [{ uid: "owner-1", state: null, updated_at: null }],
    collabRooms: [],
    ...overrides,
  };
}

function classify(
  stream: GlobalStorageStream,
  raw: Record<string, unknown>,
  current: GlobalStorageCurrentFacts,
) {
  return classifyGlobalStorageGeneration(
    { stream, raw, facts: current },
    { observedAt: OBSERVED_AT, olderThanMs: 900_000, legacyEvidencePolicy: null },
  );
}

interface RecordedStatement {
  text: string;
  params: unknown[] | undefined;
}

function fakeDb(responses: unknown[][]) {
  const statements: RecordedStatement[] = [];
  const remaining = [...responses];
  const unsafe = vi.fn(async (text: string, params?: unknown[]) => {
    statements.push({ text: text.replace(/\s+/g, " ").trim(), params });
    if (remaining.length === 0) throw new Error("unexpected read");
    return remaining.shift()!;
  });
  return {
    db: { $client: { unsafe } } as unknown as Db,
    statements,
    unsafe,
  };
}

function runtime(deadlineExceeded: () => boolean = () => false) {
  return {
    now: () => new Date(OBSERVED_AT),
    deadlineExceeded,
  };
}

const bounds = {
  scanLimit: 2,
  ioLimit: 0,
  maxOwners: 4,
  perOwnerIoLimit: 8,
  reportLimit: 10,
};

describe("global storage raw keyset readers (UNEXECUTED)", () => {
  it("advances only examined rows and resumes at the immutable high-water keyset", async () => {
    const first = fakeDb([
      [attachment("row-1"), attachment("row-2"), attachment("row-3")],
      [facts()],
      [facts()],
      [attachment("row-3")],
      [facts()],
    ]);
    const options = {
      cursor: cursor("attachment"),
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    };

    const page1 = await readGlobalStoragePage(first.db, options, runtime());
    expect(page1.examinedRawRows).toBe(2);
    expect(page1.nextCursor).toMatchObject({ afterId: "row-2", highWaterId: "row-zz" });
    expect(page1.scanComplete).toBe(false);
    expect(page1.reportCompleteForApproval).toBe(true);
    expect(first.statements[0]!.text).toContain("id > $1");
    expect(first.statements[0]!.text).toContain("id <= $2");
    expect(first.statements[0]!.text).toContain("ORDER BY id");
    expect(first.statements[0]!.text).toContain("LIMIT $3");
    expect(first.statements[0]!.params).toEqual([null, "row-zz", 3]);

    const page2 = await readGlobalStoragePage(first.db, {
      ...options,
      cursor: page1.nextCursor!,
    }, runtime());
    expect(page2.examinedRawRows).toBe(1);
    expect(page2.nextCursor).toBeNull();
    expect(page2.scanComplete).toBe(true);
    expect(first.statements[3]!.params).toEqual(["row-2", "row-zz", 3]);
  });

  it("uses stream-specific high-water filters, including the formerly missing history reader", async () => {
    expect(GLOBAL_STORAGE_STREAMS).toEqual([
      "attachment",
      "workspace",
      "reservation",
      "share",
      "history",
    ]);
    for (const stream of GLOBAL_STORAGE_STREAMS) {
      const h = fakeDb([[{ high_water_id: stream === "attachment" ? null : "row-9" }]]);
      const highWater = await readGlobalStorageHighWater(h.db, stream);
      expect(highWater).toBe(stream === "attachment" ? "" : "row-9");
      const text = h.statements[0]!.text;
      expect(text).toContain("MAX(id)");
      if (stream === "reservation") {
        expect(text).toContain("upload-complete:");
        expect(text).toContain("artifact-share:");
        expect(text).toContain("charge:%");
        expect(text).toContain("artifact-shares");
      }
      if (stream === "share") {
        expect(text).toContain("artifact-share:");
        expect(text).toContain("charge:%");
        expect(text).toContain("artifact-shares");
        expect(text).toContain("upload-complete:");
      }
      if (stream === "history") {
        expect(text).toContain("FROM storage_reservations");
        expect(text).toContain("id LIKE");
        expect(text).toContain("object_id LIKE");
        expect(text).toContain("upload-complete:");
      }
    }
  });

  it("advances a malformed row with a valid immutable id but refuses a poison cursor id", async () => {
    const malformed = attachment("row-1", { user_id: null, upload_status: "surprising" });
    const h = fakeDb([[malformed], [facts()]]);
    const page = await readGlobalStoragePage(h.db, {
      cursor: cursor("attachment"),
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime());
    expect(page.outcomes[0]).toMatchObject({
      rawId: "row-1",
      classification: { disposition: "unresolved" },
    });
    expect(page.nextCursor).toBeNull();
    expect(page.scanComplete).toBe(true);

    const poison = fakeDb([[attachment(null)]]);
    await expect(readGlobalStoragePage(poison.db, {
      cursor: cursor("attachment"),
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime())).rejects.toMatchObject({ code: "malformed_cursor_identity" });
    expect(poison.unsafe).toHaveBeenCalledTimes(1);
  });

  it.each([
    [{ ...bounds, maxOwners: 1 }, "owner_limit", "row-1"],
    [{ ...bounds, reportLimit: 1 }, "report_limit", "row-1"],
  ])("stops before an over-budget next item without skipping it: %o", async (limited, reason, afterId) => {
    const rows = [
      attachment("row-1"),
      attachment("row-2", limited.maxOwners === 1 ? { user_id: "owner-2" } : {}),
      attachment("row-3"),
    ];
    const h = fakeDb([rows, [facts()], [facts()]]);
    const page = await readGlobalStoragePage(h.db, {
      cursor: cursor("attachment"),
      bounds: limited,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime());
    expect(page.stopReason).toBe(reason);
    expect(page.nextCursor).toMatchObject({ afterId });
    expect(page.outcomes).toHaveLength(1);
    expect(page.reportCompleteForApproval).toBe(true);
  });

  it("advances after one bounded per-candidate fact error without calling the page report complete", async () => {
    const h = fakeDb([
      [attachment("row-1"), attachment("row-2")],
      [{ malformed_fact_payload: true }],
      [facts()],
    ]);
    const page = await readGlobalStoragePage(h.db, {
      cursor: cursor("attachment"),
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime());
    expect(page.outcomes).toHaveLength(2);
    expect(page.outcomes[0]).toMatchObject({
      rawId: "row-1",
      classification: { disposition: "unresolved", reason: "current_facts_unavailable" },
      generation: { factsComplete: false },
    });
    expect(page.outcomes[1]!.rawId).toBe("row-2");
    expect(page.scanComplete).toBe(true);
    expect(page.reportCompleteForApproval).toBe(false);
    expect(h.unsafe).toHaveBeenCalledTimes(3);
  });

  it("enforces the cooperative deadline between bounded reads and keeps the next row", async () => {
    let checks = 0;
    const h = fakeDb([
      [attachment("row-1"), attachment("row-2")],
      [facts()],
    ]);
    const page = await readGlobalStoragePage(h.db, {
      cursor: cursor("attachment"),
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime(() => ++checks > 3));
    expect(page.stopReason).toBe("deadline");
    expect(page.nextCursor).toMatchObject({ afterId: "row-1" });
    expect(page.reportCompleteForApproval).toBe(false);
  });

  it("examines and advances upload-complete history instead of excluding it from every reader", async () => {
    const history = reservation("upload-complete:artifact-1", {
      object_id: "upload-complete:artifact-1",
      declared_bytes: 0,
      actual_bytes: 0,
    });
    const original = reservation("artifact-1", {
      state: "released",
      actual_bytes: null,
      finalized_at: null,
      released_at: "2026-10-25T11:00:00.000Z",
    });
    const h = fakeDb([[history], [facts({ reservations: [original, history] })]]);
    const page = await readGlobalStoragePage(h.db, {
      cursor: { ...cursor("history"), highWaterId: "zzz" },
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime());
    expect(page.outcomes).toHaveLength(1);
    expect(page.outcomes[0]).toMatchObject({
      rawId: "upload-complete:artifact-1",
      classification: { disposition: "history_candidate" },
    });
    expect(page.scanComplete).toBe(true);
    expect(h.statements[0]!.text).toContain("upload-complete:");
  });

  it("binds every current-fact SQL parameter contiguously with no unreferenced holes", async () => {
    const raw = reservation("reservation-1", {
      state: "reserved",
      actual_bytes: null,
      finalized_at: null,
    });
    const h = fakeDb([[raw], [facts({ reservations: [raw] })]]);
    await readGlobalStoragePage(h.db, {
      cursor: cursor("reservation"),
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime());

    const statement = h.statements[1]!;
    const references = [...statement.text.matchAll(/\$([1-9][0-9]*)/g)].map((match) => Number(match[1]));
    const positions = [...new Set(references)].sort((left, right) => left - right);
    expect(positions).toEqual(Array.from({ length: 10 }, (_, index) => index + 1));
    expect(statement.params).toHaveLength(positions.length);
    for (const position of positions) expect(references).toContain(position);
    expect(h.unsafe).toHaveBeenCalledTimes(2);
  });

  it("issues reads only: no counter, reservation, host, tombstone, or object writes", async () => {
    const h = fakeDb([[attachment("row-1")], [facts()]]);
    await readGlobalStoragePage(h.db, {
      cursor: cursor("attachment"),
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime());
    expect(h.statements.length).toBeGreaterThan(0);
    for (const statement of h.statements) {
      expect(statement.text).toMatch(/^(SELECT|WITH)\b/);
      expect(statement.text).not.toMatch(/\b(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|ALTER|DROP|CREATE|CALL|SET)\b/);
    }
  });
});

describe("one shared current-generation classifier (UNEXECUTED)", () => {
  it.each(["workspace", "reservation"] as const)(
    "gives active host generation precedence over a released reservation from %s",
    (stream) => {
      const host = workspace("artifact-1");
      const released = reservation("artifact-1", {
        state: "released",
        actual_bytes: null,
        finalized_at: null,
        released_at: "2026-10-25T11:00:00.000Z",
      });
      const raw = stream === "workspace" ? host : released;
      const current = facts({ workspaceObjects: [host], reservations: [released] });
      const result = classify(stream, raw, current);
      expect(result.classification).toMatchObject({
        disposition: "unresolved",
        reason: "live_accounting_inconsistent",
      });
      expect(result.fingerprint).toMatch(/^sha256:[0-9a-f]{64}$/);
    },
  );

  it.each(["ready", "pending"] as const)("never makes %s + released a terminal-delete candidate", (status) => {
    const host = attachment("attachment-1", { upload_status: status });
    const released = reservation("attachment-1", {
      state: "released",
      actual_bytes: null,
      finalized_at: null,
      released_at: "2026-10-25T11:00:00.000Z",
    });
    const result = classify("reservation", released, facts({
      attachments: [host],
      reservations: [released],
    }));
    expect(result.classification).toMatchObject({
      disposition: "unresolved",
      reason: "live_host_reservation_inconsistent",
    });
  });

  it.each(["attachment", "reservation"] as const)(
    "resolves every same-key host conflict from %s discovery with bounded expansion",
    async (stream) => {
      const key = "users/owner-1/sessions/session-1/uploads/shared-key";
      const failed = attachment("attachment-a", {
        upload_status: "failed",
        actual_bytes: null,
        finalized_at: null,
        r2_key: key,
      });
      const ready = attachment("attachment-b", { r2_key: key });
      const released = reservation("reservation-a", {
        object_id: "attachment-a",
        state: "released",
        actual_bytes: null,
        finalized_at: null,
        released_at: "2026-10-25T11:00:00.000Z",
      });
      const current = facts({ attachments: [failed, ready], reservations: [released] });
      const raw = stream === "attachment" ? failed : released;
      const h = fakeDb([[raw], [current]]);
      const page = await readGlobalStoragePage(h.db, {
        cursor: cursor(stream),
        bounds,
        olderThanMs: 900_000,
        legacyEvidencePolicy: null,
      }, runtime());

      expect(page.outcomes[0]).toMatchObject({
        classification: { disposition: "unresolved", reason: "host_identity_ambiguous" },
      });
      expect(page.outcomes[0]!.generation.attachments.map((row) => row.id)).toEqual([
        "attachment-a",
        "attachment-b",
      ]);
      const sql = h.statements[1]!.text;
      expect(sql).toContain("host_keys");
      expect(sql).toContain("a.r2_key = k.r2_key");
      expect(sql).toContain("w.r2_key = k.r2_key");
      expect(sql.match(/FROM host_keys/g)?.length).toBe(2);
      expect(h.unsafe).toHaveBeenCalledTimes(2);
    },
  );

  it.each([
    ["reservation", "attachment-a", "attachment-b"],
    ["reservation", "attachment-b", "attachment-a"],
    ["history", "artifact-a", "artifact-b"],
    ["history", "artifact-b", "artifact-a"],
  ] as const)(
    "uses current object identity from %s discovery for raw %s versus current %s",
    async (stream, rawObjectId, currentObjectId) => {
      const liveHost = currentObjectId.startsWith("attachment-")
        ? attachment(currentObjectId)
        : workspace(currentObjectId);
      const original = reservation("reservation-1", {
        object_id: currentObjectId,
        state: "released",
        actual_bytes: null,
        finalized_at: null,
        released_at: "2026-10-25T11:00:00.000Z",
      });
      const raw = stream === "history"
        ? reservation("upload-complete:reservation-1", {
          object_id: `upload-complete:${rawObjectId}`,
          declared_bytes: 0,
          actual_bytes: 0,
        })
        : reservation("reservation-1", {
          object_id: rawObjectId,
          state: "reserved",
          actual_bytes: null,
          finalized_at: null,
        });
      const currentReservation = stream === "history"
        ? { ...raw, object_id: `upload-complete:${currentObjectId}` }
        : { ...raw, object_id: currentObjectId };
      const current = facts({
        attachments: currentObjectId.startsWith("attachment-") ? [liveHost] : [],
        workspaceObjects: currentObjectId.startsWith("artifact-") ? [liveHost] : [],
        reservations: stream === "history" ? [original, currentReservation] : [currentReservation],
      });
      const h = fakeDb([[raw], [current]]);
      const page = await readGlobalStoragePage(h.db, {
        cursor: { ...cursor(stream), highWaterId: "zzz" },
        bounds,
        olderThanMs: 900_000,
        legacyEvidencePolicy: null,
      }, runtime());

      expect(page.outcomes[0]).toMatchObject({
        classification: {
          disposition: "unresolved",
          reason: "raw_current_identity_mismatch",
          dryRunOnly: true,
        },
        generation: { factsComplete: true },
      });
      expect(page.reportCompleteForApproval).toBe(false);
      expect(page.examinedRawRows).toBe(1);
      expect(page.scanComplete).toBe(true);
      expect(page.nextCursor).toBeNull();
      const generation = page.outcomes[0]!.generation;
      expect(generation.raw.object_id).toBe(stream === "history"
        ? `upload-complete:${rawObjectId}`
        : rawObjectId);
      const currentRaw = generation.reservations.find((row) => row.id === raw.id);
      expect(currentRaw?.object_id).toBe(stream === "history"
        ? `upload-complete:${currentObjectId}`
        : currentObjectId);
      expect(currentObjectId.startsWith("attachment-")
        ? generation.attachments.map((row) => row.id)
        : generation.workspaceObjects.map((row) => row.id)).toEqual([currentObjectId]);
      expect(h.statements[1]!.text).toContain("current_object_identity");
      expect(h.statements[1]!.text).toContain("seed_current_reservation");
      expect(h.statements[1]!.text).toContain("seed_original_reservation");
      expect(h.statements[1]!.text).toContain("$10");
      expect(h.statements[1]!.text).toContain("a.id = c.object_id OR a.r2_key = c.object_id");
      expect(h.statements[1]!.text).toContain("w.id = c.object_id OR w.r2_key = c.object_id");
      expect(h.statements[1]!.text).not.toContain("a.id = $3 OR a.r2_key = $3");
      expect(h.unsafe).toHaveBeenCalledTimes(2);
    },
  );

  it("fails closed on current/raw cross-kind, missing, and overflow identity evidence", async () => {
    const raw = reservation("reservation-1", {
      object_id: "artifact-a",
      state: "reserved",
      actual_bytes: null,
      finalized_at: null,
    });
    const current = { ...raw, object_id: "artifact-b" };
    const crossKind = await readGlobalStoragePage(fakeDb([
      [raw],
      [facts({
        attachments: [attachment("artifact-b")],
        workspaceObjects: [workspace("artifact-b")],
        reservations: [current],
      })],
    ]).db, {
      cursor: cursor("reservation"),
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime());
    expect(crossKind.outcomes[0]).toMatchObject({
      classification: { disposition: "unresolved", reason: "host_identity_ambiguous" },
      generation: { factsComplete: true },
    });
    expect(crossKind.outcomes[0]!.generation.attachments).toHaveLength(1);
    expect(crossKind.outcomes[0]!.generation.workspaceObjects).toHaveLength(1);

    const missingHost = await readGlobalStoragePage(fakeDb([
      [raw],
      [facts({ reservations: [current] })],
    ]).db, {
      cursor: cursor("reservation"),
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime());
    expect(missingHost.outcomes[0]!.classification).toMatchObject({
      disposition: "unresolved",
      reason: "raw_current_identity_mismatch",
    });

    const missingCurrent = await readGlobalStoragePage(fakeDb([
      [raw],
      [facts()],
    ]).db, {
      cursor: cursor("reservation"),
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime());
    expect(missingCurrent.outcomes[0]!.classification).toMatchObject({
      disposition: "unresolved",
      reason: "reservation_changed",
    });

    const overflow = await readGlobalStoragePage(fakeDb([
      [raw],
      [facts({
        attachments: [attachment("artifact-b"), attachment("attachment-c"), attachment("attachment-d")],
        reservations: [current],
      })],
    ]).db, {
      cursor: cursor("reservation"),
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime());
    expect(overflow.outcomes[0]).toMatchObject({
      classification: { disposition: "unresolved", reason: "current_facts_unavailable" },
      generation: { factsComplete: false },
    });
    expect(overflow.reportCompleteForApproval).toBe(false);
  });

  it.each(["reservations", "dependentShares"] as const)(
    "marks %s overflow incomplete in facts and page approval evidence",
    async (field) => {
      const raw = field === "reservations"
        ? attachment("attachment-1")
        : workspace("artifact-1", { status: "deleted" });
      const overflow = Array.from({ length: 17 }, (_, index) =>
        reservation(`overflow-${index}`, { object_id: `overflow-object-${index}` }));
      const current = field === "reservations"
        ? facts({ attachments: [raw], reservations: overflow })
        : facts({ workspaceObjects: [raw], dependentShares: overflow });
      const stream = field === "reservations" ? "attachment" : "workspace";
      const h = fakeDb([[raw], [current]]);
      const page = await readGlobalStoragePage(h.db, {
        cursor: cursor(stream),
        bounds,
        olderThanMs: 900_000,
        legacyEvidencePolicy: null,
      }, runtime());

      expect(page.outcomes[0]).toMatchObject({
        classification: { disposition: "unresolved", reason: "current_facts_unavailable" },
        generation: { factsComplete: false },
      });
      expect(page.outcomes[0]!.generation.reservationSetComplete).toBe(field !== "reservations");
      expect(page.outcomes[0]!.generation.dependentShareSetComplete).toBe(field !== "dependentShares");
      expect(page.reportCompleteForApproval).toBe(false);
      expect(page.examinedRawRows).toBe(1);
      expect(page.scanComplete).toBe(true);
      expect(page.nextCursor).toBeNull();
      expect(h.unsafe).toHaveBeenCalledTimes(2);
    },
  );

  it("fails closed on cross-kind same-ID conflicts and bounded host overflow", async () => {
    const failed = attachment("shared-id", {
      upload_status: "failed",
      actual_bytes: null,
      finalized_at: null,
    });
    const workspaceConflict = workspace("shared-id");
    const released = reservation("reservation-a", {
      object_id: "shared-id",
      state: "released",
      actual_bytes: null,
      finalized_at: null,
      released_at: "2026-10-25T11:00:00.000Z",
    });
    const conflict = classify("attachment", failed, facts({
      attachments: [failed],
      workspaceObjects: [workspaceConflict],
      reservations: [released],
    }));
    expect(conflict.classification).toMatchObject({
      disposition: "unresolved",
      reason: "host_identity_ambiguous",
    });
    expect(conflict.generation.attachments).toHaveLength(1);
    expect(conflict.generation.workspaceObjects).toHaveLength(1);

    const overflowHosts = [failed, attachment("attachment-b"), attachment("attachment-c")];
    const h = fakeDb([[failed], [facts({ attachments: overflowHosts, reservations: [released] })]]);
    const page = await readGlobalStoragePage(h.db, {
      cursor: cursor("attachment"),
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime());
    expect(page.outcomes[0]!.classification.disposition).toBe("unresolved");
    expect(page.outcomes[0]!.generation.factsComplete).toBe(false);
    expect(page.reportCompleteForApproval).toBe(false);
    expect(h.statements[1]!.text).toContain("LIMIT 3");
    expect(h.unsafe).toHaveBeenCalledTimes(2);
  });

  it("quarantines pending workspace generations and detects Collab only from canonical rooms", () => {
    const pending = workspace("artifact-1", { status: "pending" });
    const publicReservation = reservation("artifact-1", { state: "reserved", actual_bytes: null, finalized_at: null });
    const unresolved = classify("reservation", publicReservation, facts({
      workspaceObjects: [pending],
      reservations: [publicReservation],
    }));
    expect(unresolved.classification).toMatchObject({
      disposition: "unresolved",
      reason: "workspace_generation_unresolved",
    });

    const room = {
      id: "room-1",
      session_id: "session-1",
      owner_user_id: "owner-1",
      request_id: "request-1",
      lifecycle: "closed",
      generation: 4,
      close_request_id: "close-1",
      created_at: "2026-10-25T08:00:00.000Z",
      updated_at: "2026-10-25T11:00:00.000Z",
    };
    const collab = classify("reservation", publicReservation, facts({
      workspaceObjects: [{ ...pending, status: "active" }],
      reservations: [publicReservation],
      collabRooms: [room],
    }));
    expect(collab.classification).toMatchObject({
      disposition: "collab_lifecycle_owned",
      dryRunOnly: true,
    });
  });

  it("keeps an attempt-shaped reservation unresolved without a room, never ordinary by ID shape", () => {
    const attempt = reservation("artifact-1:collab-attempt:1", {
      object_id: "users/owner-1/artifacts/session-1/artifact-1-attempt.txt",
      state: "released",
      actual_bytes: null,
      finalized_at: null,
      released_at: "2026-10-25T11:00:00.000Z",
    });
    const result = classify("reservation", attempt, facts({ reservations: [attempt] }));
    expect(result.classification.disposition).toBe("unresolved");
    expect(result.classification.reason).toBe("collab_mapping_unresolved");
  });

  it("separates foreign identity, owner lifecycle, and actor lifecycle", () => {
    const host = attachment("attachment-1");
    const currentReservation = reservation("attachment-1");
    const foreign = classify("attachment", host, facts({
      attachments: [host],
      reservations: [currentReservation],
      session: [{ id: "session-1", user_id: "somebody-else", deleted_at: null, updated_at: null }],
    }));
    expect(foreign.classification.disposition).toBe("foreign_identity");

    const wrongKeyId = workspace("attachment-1", {
      r2_key: "users/owner-1/artifacts/session-1/another-object-result.txt",
    });
    const wrongId = classify("workspace", wrongKeyId, facts({
      workspaceObjects: [wrongKeyId],
      reservations: [currentReservation],
    }));
    expect(wrongId.classification).toMatchObject({
      disposition: "foreign_identity",
      reason: "host_key_identity_mismatch",
    });

    const deleting = classify("attachment", host, facts({
      attachments: [host],
      reservations: [currentReservation],
      ownerAccount: [{ uid: "owner-1", state: "deleting", updated_at: "2026-10-25T11:00:00.000Z" }],
    }));
    expect(deleting.classification.disposition).toBe("account_lifecycle_owned");

    const actorDeleting = classify("reservation", currentReservation, facts({
      attachments: [host],
      reservations: [{ ...currentReservation, actor_user_id: "actor-1" }],
      actorAccount: [{ uid: "actor-1", state: "deleting", updated_at: "2026-10-25T11:00:00.000Z" }],
    }));
    expect(actorDeleting.classification.disposition).not.toBe("account_lifecycle_owned");
    expect(actorDeleting.history.actorProvenance).toBe("existing_reservation");
  });

  it("fingerprints complete generation fields instead of trusting the discovering raw row", () => {
    const host = workspace("artifact-1");
    const currentReservation = reservation("artifact-1");
    const current = facts({ workspaceObjects: [host], reservations: [currentReservation] });
    const first = classify("workspace", host, current);
    const changed = classify("workspace", host, facts({
      workspaceObjects: [{ ...host, meta: { name: "result.txt", attemptNumber: 2 } }],
      reservations: [currentReservation],
    }));
    expect(changed.fingerprint).not.toBe(first.fingerprint);
    expect(changed.generation.workspaceObjects[0]).toHaveProperty("meta");
    expect(changed.generation.authority.session[0]).toHaveProperty("updated_at");
  });

  it("classifies share grants/charges independently of ID shape and preserves a live grant", async () => {
    const artifactId = "11111111-1111-4111-8111-111111111111";
    const version = "b".repeat(64);
    const key = `users/owner-1/artifact-shares/${artifactId}/sha256-${version}/object`;
    const source = workspace(artifactId, { sha256: version, status: "deleted" });
    const charge = reservation(`artifact-share:${artifactId}:${version}`, {
      object_id: `charge:${key}`,
    });
    const grant = reservation("grant-1", {
      object_id: key,
      declared_bytes: 0,
      actual_bytes: 0,
      etag: version,
    });
    const current = facts({
      workspaceObjects: [source],
      reservations: [charge, grant],
      dependentShares: [charge, grant],
    });
    const fromCharge = classify("share", charge, current);
    const fromGrant = classify("share", grant, current);
    expect(fromCharge.classification).toMatchObject({
      disposition: "share_candidate",
      reason: "live_grant_preserves_copy",
      dryRunOnly: true,
    });
    expect(fromGrant.classification.reason).toBe("live_grant_preserves_copy");
    expect(fromCharge.identity).toBe(fromGrant.identity);

    const fromDeletedSource = classify("workspace", source, current);
    expect(fromDeletedSource.classification.reason).toBe("deleted_source_shares_pending");

    const h = fakeDb([[charge], [current]]);
    const page = await readGlobalStoragePage(h.db, {
      cursor: { ...cursor("share"), highWaterId: "zzz" },
      bounds,
      olderThanMs: 900_000,
      legacyEvidencePolicy: null,
    }, runtime());
    expect(page.outcomes[0]!.classification.reason).toBe("live_grant_preserves_copy");
    expect(h.statements[1]!.text).toContain("substring(object_id from 8)");
    expect(h.statements[1]!.text).toContain("substring(split_part(share_key, '/', 5) from 8)");
  });

  it.each(["charge-id-grant-object", "grant-id-charge-object"] as const)(
    "rejects crossed charge/grant identity evidence: %s",
    (shape) => {
      const artifactId = "11111111-1111-4111-8111-111111111111";
      const version = "b".repeat(64);
      const key = `users/owner-1/artifact-shares/${artifactId}/sha256-${version}/object`;
      const chargeId = `artifact-share:${artifactId}:${version}`;
      const source = workspace(artifactId, { sha256: version });
      const crossed = shape === "charge-id-grant-object"
        ? reservation(chargeId, {
          object_id: key,
          declared_bytes: 0,
          actual_bytes: 0,
          etag: version,
        })
        : reservation("grant-1", { object_id: `charge:${key}` });
      const result = classify("share", crossed, facts({
        workspaceObjects: [source],
        reservations: [crossed],
        dependentShares: [crossed],
      }));
      expect(result.classification).toMatchObject({
        disposition: "foreign_identity",
        reason: "share_identity_mismatch",
      });
    },
  );

  it("marks a well-formed share key under another owner foreign", () => {
    const artifactId = "11111111-1111-4111-8111-111111111111";
    const version = "b".repeat(64);
    const foreignKey = `users/other-owner/artifact-shares/${artifactId}/sha256-${version}/object`;
    const grant = reservation("grant-1", {
      object_id: foreignKey,
      declared_bytes: 0,
      actual_bytes: 0,
      etag: version,
    });
    const result = classify("share", grant, facts({
      workspaceObjects: [workspace(artifactId, { sha256: version })],
      reservations: [grant],
      dependentShares: [grant],
    }));
    expect(result.classification).toMatchObject({
      disposition: "foreign_identity",
      reason: "share_identity_mismatch",
    });

    const ownerKey = foreignKey.replace("users/other-owner/", "users/owner-1/");
    const ownerBoundGrant = { ...grant, object_id: ownerKey };
    const wrongKind = classify("share", ownerBoundGrant, facts({
      workspaceObjects: [workspace(artifactId, { kind: "workspace_archive", sha256: version })],
      reservations: [ownerBoundGrant],
      dependentShares: [ownerBoundGrant],
    }));
    expect(wrongKind.classification).toMatchObject({
      disposition: "foreign_identity",
      reason: "share_identity_mismatch",
    });
  });

  it("rejects sparse legacy policy host kinds and fails closed on sparse current-fact arrays", () => {
    const host = attachment("attachment-1", { created_at: "2026-10-19T00:00:00.000Z" });
    const policy: LegacyEvidencePolicy = {
      policyId: "legacy-policy-1",
      pre0038Boundary: "2026-10-20T00:00:00.000Z",
      allowedHostKinds: new Array(1) as Array<"attachment" | "artifact">,
      creationAdmissionRule: "host_created_at_before_boundary",
      actorEvidenceRule: "owner_is_actor",
      reconstructReservedAtFromHostCreatedAt: false,
      rollingHistoryPolicyId: "rolling-policy-1",
      rollingHistoryMeaning: "No observed completion recovery.",
    };
    expect(() => classifyGlobalStorageGeneration({
      stream: "attachment",
      raw: host,
      facts: facts({ attachments: [host] }),
    }, { observedAt: OBSERVED_AT, olderThanMs: 900_000, legacyEvidencePolicy: policy }))
      .toThrow(/dense|sparse|host-kind|index/i);

    const sparseFacts = facts();
    sparseFacts.attachments = new Array(1);
    const result = classify("attachment", host, sparseFacts);
    expect(result.classification).toMatchObject({
      disposition: "unresolved",
      reason: "current_facts_unavailable",
    });
    expect(result.generation.factsComplete).toBe(false);
  });

  it("uses only explicit legacy actor/admission evidence and never fabricates unknown history", () => {
    const legacyEvidencePolicy: LegacyEvidencePolicy = {
      policyId: "legacy-policy-1",
      pre0038Boundary: "2026-10-20T00:00:00.000Z",
      allowedHostKinds: ["attachment"],
      creationAdmissionRule: "host_created_at_before_boundary",
      actorEvidenceRule: "owner_is_actor",
      reconstructReservedAtFromHostCreatedAt: true,
      rollingHistoryPolicyId: "rolling-policy-1",
      rollingHistoryMeaning: "Reconstruction basis only, not observed upload completion.",
    };
    const host = attachment("attachment-1", {
      created_at: "2026-10-19T00:00:00.000Z",
      finalized_at: null,
    });
    const eligible = classifyGlobalStorageGeneration({
      stream: "attachment",
      raw: host,
      facts: facts({ attachments: [host] }),
    }, { observedAt: OBSERVED_AT, olderThanMs: 900_000, legacyEvidencePolicy });
    expect(eligible.classification).toMatchObject({
      disposition: "ordinary_candidate",
      reason: "legacy_evidence_candidate",
    });
    expect(eligible.history).toMatchObject({
      actorProvenance: "owner_actor_policy",
      originalFinalizedAt: null,
      originalFinalizedAtUnknown: true,
      reservedAtProvenance: "approved_reconstruction",
    });

    const postBoundary = { ...host, created_at: "2026-10-21T00:00:00.000Z" };
    const unresolved = classifyGlobalStorageGeneration({
      stream: "attachment",
      raw: postBoundary,
      facts: facts({ attachments: [postBoundary] }),
    }, { observedAt: OBSERVED_AT, olderThanMs: 900_000, legacyEvidencePolicy });
    expect(unresolved.classification).toMatchObject({
      disposition: "unresolved",
      reason: "legacy_evidence_unresolved",
    });
    expect(unresolved.history.actorProvenance).toBe("unresolved");
    expect(unresolved.history.originalFinalizedAt).toBeNull();

    const collab = classifyGlobalStorageGeneration({
      stream: "attachment",
      raw: host,
      facts: facts({
        attachments: [host],
        collabRooms: [{
          id: "room-1",
          session_id: "session-1",
          owner_user_id: "owner-1",
          request_id: "request-1",
          lifecycle: "active",
          generation: 1,
          close_request_id: null,
          created_at: "2026-10-25T08:00:00.000Z",
          updated_at: "2026-10-25T10:00:00.000Z",
        }],
      }),
    }, { observedAt: OBSERVED_AT, olderThanMs: 900_000, legacyEvidencePolicy });
    expect(collab.classification.disposition).toBe("collab_lifecycle_owned");
    expect(collab.history.actorProvenance).not.toBe("owner_actor_policy");
  });

  it.each(["object", "owner", "actor", "session"] as const)(
    "rejects original/history %s identity disagreement",
    (field) => {
      const original = reservation("artifact-1", {
        state: "released",
        actual_bytes: null,
        finalized_at: null,
        released_at: "2026-10-25T11:00:00.000Z",
      });
      const history = reservation("upload-complete:artifact-1", {
        object_id: "upload-complete:artifact-1",
        declared_bytes: 0,
        actual_bytes: 0,
      });
      const authority: Partial<GlobalStorageCurrentFacts> = {};
      if (field === "object") history.object_id = "upload-complete:different-object";
      if (field === "owner") {
        history.owner_user_id = "owner-2";
        history.actor_user_id = "owner-2";
        authority.ownerAccount = [{ uid: "owner-2", state: null, updated_at: null }];
        authority.actorAccount = [{ uid: "owner-2", state: null, updated_at: null }];
        authority.session = [{
          id: "session-1",
          user_id: "owner-2",
          deleted_at: null,
          updated_at: "2026-10-25T10:00:00.000Z",
        }];
      }
      if (field === "actor") {
        history.actor_user_id = "actor-2";
        authority.actorAccount = [{ uid: "actor-2", state: null, updated_at: null }];
      }
      if (field === "session") {
        history.session_id = "session-2";
        authority.session = [{
          id: "session-2",
          user_id: "owner-1",
          deleted_at: null,
          updated_at: "2026-10-25T10:00:00.000Z",
        }];
      }
      const result = classify("history", history, facts({
        ...authority,
        reservations: [original, history],
      }));
      expect(result.classification).toMatchObject({
        disposition: "foreign_identity",
        reason: "history_identity_mismatch",
      });
    },
  );

  it.each([
    ["artifact-a", "artifact-b"],
    ["artifact-b", "artifact-a"],
  ] as const)(
    "rejects original-only history identity change %s to %s with unchanged history evidence",
    async (rawObjectId, currentObjectId) => {
      const history = reservation("upload-complete:reservation-1", {
        object_id: `upload-complete:${rawObjectId}`,
        declared_bytes: 0,
        actual_bytes: 0,
      });
      const original = reservation("reservation-1", { object_id: currentObjectId });
      const liveHost = workspace(currentObjectId);
      const h = fakeDb([
        [history],
        [facts({
          workspaceObjects: [liveHost],
          reservations: [original, history],
        })],
      ]);
      const page = await readGlobalStoragePage(h.db, {
        cursor: { ...cursor("history"), highWaterId: "zzz" },
        bounds,
        olderThanMs: 900_000,
        legacyEvidencePolicy: null,
      }, runtime());

      expect(page.outcomes[0]).toMatchObject({
        classification: {
          disposition: "unresolved",
          reason: "raw_current_identity_mismatch",
          dryRunOnly: true,
        },
        generation: { factsComplete: true },
      });
      expect(page.outcomes[0]!.generation.raw.object_id).toBe(`upload-complete:${rawObjectId}`);
      const currentHistory = page.outcomes[0]!.generation.reservations.find((row) => row.id === history.id);
      expect(currentHistory?.object_id).toBe(`upload-complete:${rawObjectId}`);
      const currentOriginal = page.outcomes[0]!.generation.reservations.find((row) => row.id === original.id);
      expect(currentOriginal).toMatchObject({ object_id: currentObjectId, state: "finalized" });
      expect(page.outcomes[0]!.generation.workspaceObjects.map((row) => row.id)).toEqual([currentObjectId]);
      expect(page.examinedRawRows).toBe(1);
      expect(page.scanComplete).toBe(true);
      expect(page.nextCursor).toBeNull();
      expect(page.reportCompleteForApproval).toBe(false);
      expect(h.unsafe).toHaveBeenCalledTimes(2);
    },
  );

  it("binds history null-object fallback and refuses an unbound missing original", () => {
    const original = reservation("artifact-1", {
      object_id: null,
      state: "released",
      actual_bytes: null,
      finalized_at: null,
      released_at: "2026-10-25T11:00:00.000Z",
    });
    const history = reservation("upload-complete:artifact-1", {
      object_id: "upload-complete:artifact-1",
      declared_bytes: 0,
      actual_bytes: 0,
    });
    const valid = classify("history", history, facts({ reservations: [original, history] }));
    expect(valid.classification).toMatchObject({
      disposition: "history_candidate",
      reason: "successful_upload_history",
    });

    const missing = classify("history", history, facts({ reservations: [history] }));
    expect(missing.classification).toMatchObject({
      disposition: "unresolved",
      reason: "history_original_unresolved",
    });
  });

  it("keeps valid history explicit and flags unrecognized history shapes", () => {
    const original = reservation("artifact-1", {
      state: "released",
      actual_bytes: null,
      finalized_at: null,
      released_at: "2026-10-25T11:00:00.000Z",
    });
    const history = reservation("upload-complete:artifact-1", {
      object_id: "upload-complete:artifact-1",
      declared_bytes: 0,
      actual_bytes: 0,
    });
    const valid = classify("history", history, facts({ reservations: [original, history] }));
    expect(valid.classification).toMatchObject({
      disposition: "history_candidate",
      reason: "successful_upload_history",
      dryRunOnly: true,
    });
    expect(valid.history).toMatchObject({
      actorProvenance: "existing_history",
      originalFinalizedAt: "2026-10-25T10:00:00.000Z",
      originalFinalizedAtUnknown: false,
      reservedAtProvenance: "existing_history",
    });

    const malformed = classify("history", { ...history, actual_bytes: 1 }, facts({
      reservations: [original, { ...history, actual_bytes: 1 }],
    }));
    expect(malformed.classification).toMatchObject({
      disposition: "unresolved",
      reason: "unrecognized_history_shape",
    });

    const unknownActor = classify("history", { ...history, actor_user_id: null }, facts({
      reservations: [original, { ...history, actor_user_id: null }],
    }));
    expect(unknownActor.classification.disposition).toBe("unresolved");
    expect(unknownActor.history.actorProvenance).toBe("unresolved");

    const futureHistory = reservation("future-history-1", {
      object_id: "future-history-object",
      declared_bytes: 0,
      actual_bytes: 0,
    });
    const unknownShape = classify("reservation", futureHistory, facts({ reservations: [futureHistory] }));
    expect(unknownShape.classification).toMatchObject({
      disposition: "unresolved",
      reason: "unrecognized_history_shape",
    });

    const live = workspace("artifact-1");
    const throughHistory = classify("history", history, facts({
      workspaceObjects: [live],
      reservations: [original, history],
    }));
    expect(throughHistory.classification).toMatchObject({
      disposition: "unresolved",
      reason: "live_accounting_inconsistent",
    });
  });

  it("does not confuse a soft-deleted session with a deleted object generation", () => {
    const host = attachment("attachment-1", { upload_status: "failed", actual_bytes: null, finalized_at: null });
    const released = reservation("attachment-1", {
      state: "released",
      actual_bytes: null,
      finalized_at: null,
      released_at: "2026-10-25T11:00:00.000Z",
    });
    const deletedSession = [{
      id: "session-1",
      user_id: "owner-1",
      deleted_at: "2026-10-25T11:30:00.000Z",
      updated_at: "2026-10-25T11:30:00.000Z",
    }];
    const result = classify("attachment", host, facts({
      attachments: [host],
      reservations: [released],
      session: deletedSession,
    }));
    expect(result.classification).toMatchObject({
      disposition: "unresolved",
      reason: "soft_deleted_session_retains_files",
    });

    const deletedSource = workspace("attachment-1", { status: "deleted" });
    const sourceResult = classify("workspace", deletedSource, facts({
      workspaceObjects: [deletedSource],
      reservations: [released],
      session: deletedSession,
    }));
    expect(sourceResult.classification).toMatchObject({
      disposition: "unresolved",
      reason: "soft_deleted_session_retains_files",
    });
  });
});
