import { describe, expect, it } from "vitest";
import {
  parseCreateShare,
  parseForkShare,
  PRIVATE_TEXT,
  ShareValidationError,
  type CreateShare,
} from "./snapshot.js";

// Port of server/shares/snapshot.py vectors. The Python regex is transcribed
// verbatim into JS; this matrix is the proof the transcription is faithful.

// The index signature is deliberate: several vectors pass extra fields
// (`thinking`, `attachments`) to prove the parser rejects them (extra=forbid).
function body(messages: Array<{ role: string; content: string; [extra: string]: unknown }>): unknown {
  return { session_id: "session-1", request_id: "request-1", messages };
}

describe("PRIVATE_TEXT", () => {
  // Every envelope class the Python pattern fails closed on.
  const rejected = [
    "<think>private</think>",
    "<thinking>private</thinking>",
    "<analysis>private</analysis>",
    "<reasoning>private</reasoning>",
    "<system-reminder>private</system-reminder>",
    "<internal>private</internal>",
    "<secret>private</secret>",
    "</think>",
    "[report from subagent sub-1]\nprivate",
    "[subagent sub-1] private",
    "[schedule nightly] private",
    "[plugin hook context] private",
    "[context window] private",
    "[system prompt] private",
    "[user attachments] private",
    "[previous phase result] private",
    "Background subagent sub-1 (private task) finished",
    "Authorization: Bearer secret-value",
    "authorization: basic xyz",
    "Bearer abc.def.ghi",
    "api_key=private",
    "api-key: private",
    "apikey = private",
    "password: hunter2",
    "password=hunter2",
    "secret: value",
    "secret=value",
    "access_token: value",
    "access-token=value",
    "-----BEGIN RSA PRIVATE KEY-----",
    "-----BEGIN PRIVATE KEY-----",
    "data:image/png;base64,AAAA",
    "sk-abcdefghijklmnop",
    "ghp_abcdefghijklmnop",
    "gho_abcdefghijklmnop",
    "see /data/user/0/private",
    "see /data/data/com.example/private",
    "see /root/.ssh/id_rsa",
    "see /home/alice/private",
    "file:///etc/passwd",
  ];

  it.each(rejected)("rejects %j", (content) => {
    expect(PRIVATE_TEXT.test(content)).toBe(true);
    expect(() => parseCreateShare(body([{ role: "user", content }]))).toThrow(
      ShareValidationError,
    );
  });

  const accepted = [
    "Hello",
    "<script>alert(1)</script> **hi**",
    "plain text about authorization flows",
    "a data URL is data:image/png;base64-ish",
    "the secret of a good story",
  ];
  it.each(accepted)("accepts %j", (content) => {
    expect(PRIVATE_TEXT.test(content)).toBe(false);
    expect(parseCreateShare(body([{ role: "user", content }]))).toEqual({
      session_id: "session-1",
      request_id: "request-1",
      messages: [{ role: "user", content }],
    });
  });
});

describe("parseCreateShare", () => {
  it("accepts user+assistant roles and preserves content byte-for-byte", () => {
    const parsed = parseCreateShare(
      body([
        { role: "user", content: "Hello" },
        { role: "assistant", content: "Hi there" },
      ]),
    ) as CreateShare;
    expect(parsed.messages).toEqual([
      { role: "user", content: "Hello" },
      { role: "assistant", content: "Hi there" },
    ]);
  });

  it("rejects unknown roles and extra fields (extra=forbid)", () => {
    expect(() => parseCreateShare(body([{ role: "tool", content: "secret" }]))).toThrow(
      ShareValidationError,
    );
    expect(() =>
      parseCreateShare(body([{ role: "assistant", content: "text", thinking: "secret" }])),
    ).toThrow(ShareValidationError);
    expect(() =>
      parseCreateShare(body([{ role: "user", content: "text", attachments: ["bytes"] }])),
    ).toThrow(ShareValidationError);
    expect(() =>
      parseCreateShare({
        session_id: "session-1",
        request_id: "request-1",
        messages: [{ role: "user", content: "ok" }],
        owner_uid: "bob",
      }),
    ).toThrow(ShareValidationError);
  });

  it("rejects blank content, bad ids, empty/oversized message lists", () => {
    expect(() => parseCreateShare(body([{ role: "user", content: "   " }]))).toThrow(
      ShareValidationError,
    );
    expect(() => parseCreateShare(body([{ role: "user", content: "" }]))).toThrow(
      ShareValidationError,
    );
    expect(() =>
      parseCreateShare({ session_id: "", request_id: "r", messages: [{ role: "user", content: "x" }] }),
    ).toThrow(ShareValidationError);
    expect(() =>
      parseCreateShare({
        session_id: "s".repeat(129),
        request_id: "r",
        messages: [{ role: "user", content: "x" }],
      }),
    ).toThrow(ShareValidationError);
    expect(() =>
      parseCreateShare({ session_id: "s", request_id: "bad id!", messages: [{ role: "user", content: "x" }] }),
    ).toThrow(ShareValidationError);
    expect(() => parseCreateShare(body([]))).toThrow(ShareValidationError);
    expect(() =>
      parseCreateShare(body(Array.from({ length: 501 }, () => ({ role: "user", content: "x" })))),
    ).toThrow(ShareValidationError);
  });

  it("counts content length in Unicode code points (Python semantics)", () => {
    // 20,000 emoji = 20,000 Python characters (40,000 UTF-16 units).
    const emoji = "\u{1F600}".repeat(20_000);
    expect(() => parseCreateShare(body([{ role: "user", content: emoji }]))).not.toThrow();
    expect(() =>
      parseCreateShare(body([{ role: "user", content: "\u{1F600}".repeat(20_001) }])),
    ).toThrow(ShareValidationError);
  });

  it("bounds the total snapshot at 200,000 UTF-8 bytes", () => {
    const tenChunks = Array.from({ length: 10 }, () => ({ role: "user", content: "a".repeat(20_000) }));
    expect(() => parseCreateShare(body(tenChunks))).not.toThrow(); // exactly 200,000
    expect(() =>
      parseCreateShare(body([...tenChunks, { role: "user", content: "a" }])),
    ).toThrow(ShareValidationError); // 200,001
  });
});

describe("parseForkShare", () => {
  it("accepts only a request_id and forbids extra fields", () => {
    expect(parseForkShare({ request_id: "fork-1" })).toEqual({ request_id: "fork-1" });
    expect(() => parseForkShare({ request_id: "fork-1", secret: "x" })).toThrow(
      ShareValidationError,
    );
    expect(() => parseForkShare({ request_id: "" })).toThrow(ShareValidationError);
  });
});
