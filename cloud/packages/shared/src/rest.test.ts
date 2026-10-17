import { describe, expect, it } from "vitest";
import { messageDtoSchema, pageSchema, runCancelResponseSchema, sessionDtoSchema } from "./rest.js";
import type { MessageDto, SessionDto } from "./rest.js";

const session: SessionDto = {
  id: "s1",
  title: null,
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
});
