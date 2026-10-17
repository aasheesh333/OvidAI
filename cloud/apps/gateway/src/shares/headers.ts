import { createHash } from "node:crypto";

/**
 * Header + inline-script constants ported VERBATIM from
 * `server/shares/api.py`.
 *
 * Every share response (success, 401, 404, 422, 413) carries SHARES_HEADERS;
 * HTML landing pages override Content-Security-Policy with `pageCsp()` so the
 * one constant inline script can run while everything else stays inert.
 */

export const SHARES_HEADERS: Record<string, string> = {
  "Cache-Control": "no-store, private, max-age=0",
  Pragma: "no-cache",
  "X-Robots-Tag": "noindex, nofollow, noarchive",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Content-Security-Policy":
    "default-src 'none'; style-src 'unsafe-inline'; " +
    "base-uri 'none'; form-action 'none'; frame-ancestors 'none'; sandbox",
};

/**
 * Constant inline script (CSP-hashed): on Android, hand the very same https
 * link to the Ovid app via an intent; Chrome falls back to the Play listing
 * (with the install referrer) when the app is not installed.
 */
export const OPEN_APP_SCRIPT =
  "(function(){var d=document.documentElement;" +
  "if(!/Android/i.test(navigator.userAgent))return;" +
  "var u='intent://'+location.host+location.pathname+'#Intent;scheme=https;package='" +
  "+d.getAttribute('data-pkg')+';S.browser_fallback_url='" +
  "+encodeURIComponent(d.getAttribute('data-play'))+';end';" +
  "location.replace(u);})();";

const OPEN_APP_SCRIPT_HASH = createHash("sha256")
  .update(OPEN_APP_SCRIPT, "utf8")
  .digest("base64");

/** Landing-page CSP with the computed sha256 of OPEN_APP_SCRIPT. */
export function pageCsp(): string {
  return (
    "default-src 'none'; style-src 'unsafe-inline'; img-src 'none'; " +
    `script-src 'sha256-${OPEN_APP_SCRIPT_HASH}'; base-uri 'none'; ` +
    "form-action 'none'; frame-ancestors 'none'"
  );
}
