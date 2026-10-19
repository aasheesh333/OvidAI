import { describe, expect, it } from "vitest";
import {
  branchSessionBodySchema,
  messageDtoSchema,
  MAX_OUTPUT_TOKENS_CAP,
  regenerateBodySchema,
} from "./rest.js";

describe("Wave 1b wire additions", () => {
  it("MessageDto accepts optional attachments and stays backward compatible", () => {
    const base = {
      id: "m",
      sessionId: "s",
      role: "user" as const,
      content: "hi",
      createdAt: "2026-10-19T00:00:00.000Z",
    };
    expect(messageDtoSchema.parse(base)).toEqual(base);
    const rich = { ...base, attachments: [{ id: "a", name: "a.png", sizeBytes: 3 }] };
    expect(messageDtoSchema.parse(rich)).toEqual(rich);
    expect(() => messageDtoSchema.parse({ ...base, attachments: [{ id: "a", name: "x", sizeBytes: -1 }] })).toThrow();
  });

  it("regenerate body is strict and caps maxOutputTokens like the send body", () => {
    expect(regenerateBodySchema.parse({})).toEqual({});
    expect(regenerateBodySchema.parse({ maxOutputTokens: MAX_OUTPUT_TOKENS_CAP })).toEqual({
      maxOutputTokens: MAX_OUTPUT_TOKENS_CAP,
    });
    expect(regenerateBodySchema.safeParse({ maxOutputTokens: MAX_OUTPUT_TOKENS_CAP + 1 }).success).toBe(false);
    expect(regenerateBodySchema.safeParse({ content: "x" }).success).toBe(false);
  });

  it("branch body needs a uuid messageId", () => {
    const id = "01990b7a-2f6c-7d1e-8a3b-4c5d6e7f8090";
    expect(branchSessionBodySchema.parse({ messageId: id })).toEqual({ messageId: id });
    expect(branchSessionBodySchema.safeParse({ messageId: "nope" }).success).toBe(false);
    expect(branchSessionBodySchema.safeParse({ messageId: id, extra: 1 }).success).toBe(false);
  });
});
