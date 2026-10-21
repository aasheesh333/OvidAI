/**
 * Cookie safety rules for `browser_cookies`.
 *
 * Cookies are credentials: the model must be able to confirm a cookie exists
 * without ever seeing (and echoing into a transcript, log or tool argument)
 * its value. Sets are bound to the ACTIVE page's origin so the tool cannot be
 * used for cross-site cookie tossing (writing `domain=.other.test` from
 * `bank.test`).
 */

/** Model-facing rendering of a cookie: name only, value always redacted. */
export function formatCookieForModel(name: string, value: string): string {
  return `${name}=<redacted> (${value.length} chars)`;
}

/** Bare, lowercase hostname from an http(s) origin/URL; null otherwise. */
export function hostOfOrigin(origin: string): string | null {
  try {
    const parsed = new URL(origin);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
    return parsed.hostname.toLowerCase().replace(/\.$/, "");
  } catch {
    return null;
  }
}

/**
 * True when a `domain=` attribute may be applied from the active origin.
 * A leading dot is ignored (RFC 6265), and only the exact host is accepted:
 * a parent/sibling domain is a cookie-tossing attempt from this context.
 */
export function cookieDomainMatchesOrigin(origin: string, domain: string): boolean {
  const originHost = hostOfOrigin(origin);
  if (originHost === null) return false;
  const requested = domain.trim().toLowerCase().replace(/^\.+/, "").replace(/\.$/, "");
  return requested === originHost;
}
