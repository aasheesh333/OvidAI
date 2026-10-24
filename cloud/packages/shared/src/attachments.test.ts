import { describe, expect, it } from "vitest";

import { normalizeAttachmentContentType } from "./attachments.js";
import { attachmentUploadResponseSchema } from "./rest.js";

describe("normalizeAttachmentContentType", () => {
  it("uses octet-stream only when the declared type is absent", () => {
    expect(normalizeAttachmentContentType()).toBe("application/octet-stream");
    expect(normalizeAttachmentContentType(undefined)).toBe("application/octet-stream");
  });

  it.each([
    ["text/plain", "text/plain"],
    ["Application/PDF", "application/pdf"],
    ["X-Custom/ABC.def+GZIP", "x-custom/abc.def+gzip"],
    ["application/x-ovid-unknown", "application/x-ovid-unknown"],
    ["vnd.example/resource_v1~draft", "vnd.example/resource_v1~draft"],
  ])("normalizes the valid MIME %s without requiring a known registry entry", (input, expected) => {
    expect(normalizeAttachmentContentType(input)).toBe(expected);
  });

  it("accepts exactly 255 UTF-8 bytes", () => {
    const value = `${"a".repeat(128)}/${"b".repeat(126)}`;
    expect(Buffer.byteLength(value, "utf8")).toBe(255);
    expect(normalizeAttachmentContentType(value)).toBe(value);
  });

  it.each([
    ["empty", ""],
    ["whitespace", "   "],
    ["over 255 bytes", `${"a".repeat(128)}/${"b".repeat(127)}`],
    ["parameter", "text/plain; charset=utf-8"],
    ["wildcard subtype", "image/*"],
    ["wildcard type", "*/plain"],
    ["CRLF", "text/plain\r\nX-Injected: yes"],
    ["unicode line separator", "text/\u2028plain"],
    ["unicode paragraph separator", "text/\u2029plain"],
    ["NUL", "text/plain\u0000"],
    ["non-ASCII token", "text/pläin"],
    ["missing type", "/plain"],
    ["missing subtype", "text/"],
    ["extra slash", "text/plain/extra"],
    ["whitespace around slash", "text / plain"],
    ["surrounding whitespace", " text/plain "],
  ])("rejects %s instead of repairing or truncating it", (_name, value) => {
    expect(() => normalizeAttachmentContentType(value)).toThrow(/contentType/i);
  });
});

describe("attachment upload response compatibility", () => {
  const legacy = {
    attachmentId: "attachment-legacy",
    uploadUrl: "https://uploads.example.invalid/legacy?signature=fixture",
    path: "uploads/notes.txt",
    expiresAt: "2026-10-24T12:15:00.000Z",
  };

  it("continues to parse old response fixtures with no additive fields", () => {
    expect(attachmentUploadResponseSchema.parse(legacy)).toEqual(legacy);
  });

  it("parses normalized content type and exact upload headers additively", () => {
    const typed = {
      ...legacy,
      contentType: "application/pdf",
      uploadHeaders: { "Content-Type": "application/pdf" },
    };
    expect(attachmentUploadResponseSchema.parse(typed)).toEqual(typed);
    expect(attachmentUploadResponseSchema.parse({ ...legacy, uploadHeaders: {} })).toEqual({
      ...legacy,
      uploadHeaders: {},
    });
  });

  it("remains closed to unknown response fields", () => {
    expect(() => attachmentUploadResponseSchema.parse({ ...legacy, signedUrl: "unexpected" })).toThrow();
  });
});
