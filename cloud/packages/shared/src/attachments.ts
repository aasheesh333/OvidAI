const ATTACHMENT_CONTENT_TYPE_MAX_BYTES = 255;
// RFC 7230 token characters on both sides of exactly one slash. Wildcards,
// parameters, whitespace, controls and non-ASCII separators are not tokens.
const ATTACHMENT_CONTENT_TYPE_RE = /^[A-Za-z0-9!#$%&'*+\-.^_`|~]+\/[A-Za-z0-9!#$%&'*+\-.^_`|~]+$/;
const utf8 = new TextEncoder();

/** Canonical declared attachment MIME, or octet-stream only when it is absent. */
export function normalizeAttachmentContentType(value?: string): string {
  if (value === undefined) return "application/octet-stream";
  const [type, subtype] = value.split("/");
  if (
    utf8.encode(value).byteLength > ATTACHMENT_CONTENT_TYPE_MAX_BYTES ||
    !ATTACHMENT_CONTENT_TYPE_RE.test(value) ||
    type === "*" ||
    subtype === "*"
  ) {
    throw new Error("Invalid attachment contentType");
  }
  return value.toLowerCase();
}
