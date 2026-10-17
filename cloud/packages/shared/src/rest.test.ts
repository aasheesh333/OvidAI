import { describe, expect, it } from "vitest";
import {
  attachmentDtoSchema,
  attachmentUploadResponseSchema,
  importReportSchema,
  messageDtoSchema,
  pageSchema,
  runCancelResponseSchema,
  sanitizeAttachmentName,
  sessionDtoSchema,
  sessionPatchSchema,
} from "./rest.js";
import type { MessageDto, SessionDto } from "./rest.js";

const session: SessionDto = {
  id: "s1",
  title: null,
  mode: "auto",
  createdAt: "2026-10-15T12:00:00.000Z",
  updatedAt: "2026-10-15T12:00:00.000Z",
};

const message: MessageDto = {
  id: "m1",
  sessionId: "s1",
  role: "user",
  content: "hi",
  createdAt: "2026-10-15T12:00:00.000Z",
};

describe("rest schemas", () => {
  it("sessionDtoSchema parses a valid dto", () => {
    expect(sessionDtoSchema.parse(session)).toEqual(session);
    expect(sessionDtoSchema.parse({ ...session, title: "Hello" })).toEqual({
      ...session,
      title: "Hello",
    });
  });

  it("sessionDtoSchema rejects an invalid dto", () => {
    expect(() => sessionDtoSchema.parse({ ...session, id: 42 })).toThrow();
  });

  it("sessionDtoSchema requires mode and accepts every allowed value", () => {
    expect(sessionDtoSchema.parse(session)).toEqual(session);
    for (const mode of ["safe", "drive", "studio"] as const) {
      expect(sessionDtoSchema.parse({ ...session, mode })).toEqual({ ...session, mode });
    }
  });

  it("sessionDtoSchema rejects a missing mode and the retired 'control' value (spec D5)", () => {
    const { mode: _omitted, ...withoutMode } = session;
    expect(() => sessionDtoSchema.parse(withoutMode)).toThrow();
    expect(() => sessionDtoSchema.parse({ ...session, mode: "control" })).toThrow();
    expect(() => sessionDtoSchema.parse({ ...session, mode: 42 })).toThrow();
  });

  it("sessionPatchSchema parses title-only, mode-only, and both together", () => {
    expect(sessionPatchSchema.parse({ title: "renamed" })).toEqual({ title: "renamed" });
    expect(sessionPatchSchema.parse({ title: null })).toEqual({ title: null });
    expect(sessionPatchSchema.parse({ mode: "studio" })).toEqual({ mode: "studio" });
    expect(sessionPatchSchema.parse({ title: "t", mode: "safe" })).toEqual({
      title: "t",
      mode: "safe",
    });
  });

  it("sessionPatchSchema rejects an empty body, 'control', and unknown keys", () => {
    // At least one field required — PATCH {} must fail so the route 400s.
    expect(() => sessionPatchSchema.parse({})).toThrow();
    expect(() => sessionPatchSchema.parse({ mode: "control" })).toThrow();
    expect(() => sessionPatchSchema.parse({ mode: "auto", extra: "x" })).toThrow();
    expect(() => sessionPatchSchema.parse({ title: "t", nope: 1 })).toThrow();
    expect(() => sessionPatchSchema.parse({ title: 42 })).toThrow();
  });

  it("messageDtoSchema parses a valid dto", () => {
    expect(messageDtoSchema.parse(message)).toEqual(message);
  });

  it("messageDtoSchema rejects an unknown role", () => {
    expect(() => messageDtoSchema.parse({ ...message, role: "ghost" })).toThrow();
  });

  it("pageSchema(inner) parses a valid page", () => {
    const page = { items: [message], nextCursor: "cur" };
    expect(pageSchema(messageDtoSchema).parse(page)).toEqual(page);
    expect(pageSchema(messageDtoSchema).parse({ items: [], nextCursor: null })).toEqual({
      items: [],
      nextCursor: null,
    });
  });

  it("pageSchema rejects a page with non-array items", () => {
    expect(() => pageSchema(messageDtoSchema).parse({ items: "nope", nextCursor: null })).toThrow();
    expect(() => pageSchema(messageDtoSchema).parse({ items: {}, nextCursor: null })).toThrow();
  });

  it("runCancelResponseSchema parses both terminal answer statuses", () => {
    expect(runCancelResponseSchema.parse({ runId: "r1", status: "cancelled" })).toEqual({
      runId: "r1",
      status: "cancelled",
    });
    expect(runCancelResponseSchema.parse({ runId: "r1", status: "cancelling" })).toEqual({
      runId: "r1",
      status: "cancelling",
    });
  });

  it("runCancelResponseSchema rejects a non-status body", () => {
    expect(() => runCancelResponseSchema.parse({ runId: "r1", status: "done" })).toThrow();
    expect(() => runCancelResponseSchema.parse({ runId: "", status: "cancelled" })).toThrow();
  });

  it("attachmentUploadResponseSchema parses a valid answer (P8 Task 3 wire contract)", () => {
    const res = {
      attachmentId: "018f3e11-aaaa-7bbb-8ccc-2d2d2d2d2d2d",
      uploadUrl: "https://example.r2.cloudflarestorage.com/bucket/x?sig=abc",
      path: "uploads/report_final.pdf",
      expiresAt: "2026-10-17T12:15:00.000Z",
    };
    expect(attachmentUploadResponseSchema.parse(res)).toEqual(res);
  });

  it("attachmentUploadResponseSchema rejects a missing field, an empty string, and unknown keys", () => {
    const res = {
      attachmentId: "a1",
      uploadUrl: "https://r2.example/put",
      path: "uploads/a_b.txt",
      expiresAt: "2026-10-17T12:15:00.000Z",
    };
    const { path: _noPath, ...missingPath } = res;
    expect(() => attachmentUploadResponseSchema.parse(missingPath)).toThrow();
    expect(() => attachmentUploadResponseSchema.parse({ ...res, uploadUrl: "" })).toThrow();
    expect(() => attachmentUploadResponseSchema.parse({ ...res, extra: 1 })).toThrow();
  });

  it("attachmentDtoSchema parses a valid dto and rejects a non-positive size", () => {
    const dto = {
      id: "a1",
      sessionId: "s1",
      name: "photo 1.png",
      size: 1_024,
      createdAt: "2026-10-17T12:00:00.000Z",
    };
    expect(attachmentDtoSchema.parse(dto)).toEqual(dto);
    expect(() => attachmentDtoSchema.parse({ ...dto, size: 0 })).toThrow();
    expect(() => attachmentDtoSchema.parse({ ...dto, size: -1 })).toThrow();
    expect(() => attachmentDtoSchema.parse({ ...dto, size: 1.5 })).toThrow();
  });

  it("importReportSchema parses a valid report (P8 Task 4 import answer)", () => {
    const report = { sessionId: "018f3e11-0000-7000-8000-000000000000", imported: 3, skipped: 0 };
    expect(importReportSchema.parse(report)).toEqual(report);
    expect(importReportSchema.parse({ ...report, imported: 0, skipped: 3 })).toEqual({
      ...report,
      imported: 0,
      skipped: 3,
    });
  });

  it("importReportSchema rejects a missing field, negative/non-integer counts, and unknown keys", () => {
    const report = { sessionId: "s1", imported: 1, skipped: 0 };
    const { skipped: _noSkipped, ...missingSkipped } = report;
    expect(() => importReportSchema.parse(missingSkipped)).toThrow();
    expect(() => importReportSchema.parse({ ...report, imported: -1 })).toThrow();
    expect(() => importReportSchema.parse({ ...report, imported: 1.5 })).toThrow();
    expect(() => importReportSchema.parse({ ...report, extra: 1 })).toThrow();
    expect(() => importReportSchema.parse({ ...report, sessionId: "" })).toThrow();
  });

  describe("sanitizeAttachmentName", () => {
    it("keeps safe names untouched", () => {
      expect(sanitizeAttachmentName("report_final.pdf")).toBe("report_final.pdf");
      expect(sanitizeAttachmentName("a-b.c_d")).toBe("a-b.c_d");
    });

    it("replaces unsafe runs with a single underscore", () => {
      expect(sanitizeAttachmentName("photo 1.png")).toBe("photo_1.png");
      expect(sanitizeAttachmentName("a/b.txt")).toBe("a_b.txt");
      expect(sanitizeAttachmentName("héllo.txt")).toBe("h_llo.txt");
    });

    it("neutralizes traversal shapes: no leading dots, no dot-runs, never empty", () => {
      // ".." alone collapses to the fallback; leading dots are stripped;
      // interior ".." runs become "_" — the result is always a safe single
      // filename segment (the worker joins it under uploads/).
      expect(sanitizeAttachmentName("..")).toBe("attachment");
      expect(sanitizeAttachmentName(".hidden")).toBe("hidden");
      expect(sanitizeAttachmentName("my report ..pdf")).toBe("my_report__pdf");
      expect(sanitizeAttachmentName("a..b")).toBe("a_b");
      expect(sanitizeAttachmentName("...")).toBe("attachment");
    });

    it("caps the name at 80 characters", () => {
      expect(sanitizeAttachmentName("a".repeat(120))).toHaveLength(80);
    });
  });
});
