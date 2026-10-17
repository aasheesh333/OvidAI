import { z } from "zod";

/**
 * Wire schema port of `server/shares/snapshot.py`.
 *
 * "Never accept a serialized session or Message": the allowlist is explicit,
 * unknown fields are rejected, and every message is screened before storage.
 */

/**
 * Fail closed for known embedded reasoning/context/credential/byte envelopes.
 * Semantics copied VERBATIM from the Python `re` pattern; syntax transcribed
 * to a JS RegExp (the Python inline `re.IGNORECASE` becomes the `i` flag).
 * Defense in depth, not a promise to identify arbitrary prose secrets.
 */
export const PRIVATE_TEXT = new RegExp(
  String.raw`<\s*/?\s*(?:think|thinking|analysis|reasoning|system-reminder|internal|secret)\b` +
    String.raw`|\[(?:report from subagent|subagent |schedule |plugin hook context|` +
    String.raw`context |system |user attachments|previous phase result)` +
    String.raw`|\bBackground subagent\s` +
    String.raw`|\b(?:authorization\s*:|bearer\s+|api[_-]?key\s*[:=]|` +
    String.raw`password\s*[:=]|secret\s*[:=]|access[_-]?token\s*[:=])` +
    String.raw`|-----BEGIN [A-Z ]*PRIVATE KEY-----|data:[^\s,]*;base64,` +
    String.raw`|\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,})` +
    String.raw`|(?:/data/(?:user|data)/|/root/|/home/|file://)`,
  "i",
);

/** Any validation failure → 422 `{"detail":"invalid_snapshot"}` at the route. */
export class ShareValidationError extends Error {
  constructor() {
    super("invalid_snapshot");
    this.name = "ShareValidationError";
  }
}

export interface ShareMessage {
  role: "user" | "assistant";
  content: string;
}

/** Python `CreateShare` — snake_case on the wire. */
export interface CreateShare {
  session_id: string;
  request_id: string;
  messages: ShareMessage[];
}

/** Python `ForkShare`. */
export interface ForkShare {
  request_id: string;
}

const ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
const MAX_CONTENT_CHARS = 20_000;
const MAX_MESSAGES = 500;
const MAX_TOTAL_BYTES = 200_000;

/** Python `len(str)` counts Unicode code points, not UTF-16 code units. */
function codePoints(value: string): number {
  return Array.from(value).length;
}

const messageSchema = z
  .object({
    role: z.enum(["user", "assistant"]),
    content: z.string().superRefine((value, ctx) => {
      const length = codePoints(value);
      if (length < 1 || length > MAX_CONTENT_CHARS) {
        ctx.addIssue({ code: z.ZodIssueCode.custom, message: "invalid content length" });
        return;
      }
      if (value.trim() === "" || PRIVATE_TEXT.test(value)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: "Only visible public text may be shared",
        });
      }
    }),
  })
  .strict();

const createShareSchema = z
  .object({
    session_id: z.string().regex(ID_RE),
    request_id: z.string().regex(ID_RE),
    messages: z.array(messageSchema).min(1).max(MAX_MESSAGES),
  })
  .strict()
  .superRefine((value, ctx) => {
    const total = value.messages.reduce(
      (sum, message) => sum + Buffer.byteLength(message.content, "utf8"),
      0,
    );
    if (total > MAX_TOTAL_BYTES) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        path: ["messages"],
        message: "Snapshot is too large",
      });
    }
  });

const forkShareSchema = z
  .object({
    request_id: z.string().regex(ID_RE),
  })
  .strict();

/** Validates a create/update body. Throws ShareValidationError, never echoes input. */
export function parseCreateShare(body: unknown): CreateShare {
  const parsed = createShareSchema.safeParse(body);
  if (!parsed.success) throw new ShareValidationError();
  return parsed.data;
}

/** Validates a fork body. Throws ShareValidationError. */
export function parseForkShare(body: unknown): ForkShare {
  const parsed = forkShareSchema.safeParse(body);
  if (!parsed.success) throw new ShareValidationError();
  return parsed.data;
}
