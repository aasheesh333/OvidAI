import { OPEN_APP_SCRIPT, pageCsp } from "./headers.js";

/**
 * Public landing-page renderer, ported from `server/shares/api.py`.
 *
 * The same page is used for the read-only conversation viewer and the collab
 * invite landing: readable fallback + Android app intent + Play Store CTA.
 * All caller-supplied text is HTML-escaped; the only script is the constant
 * CSP-hashed OPEN_APP_SCRIPT.
 */

const PACKAGE_NAME_RE = /^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$/;

/** Python `html.escape(value, quote=True)`. */
export function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#x27;");
}

/**
 * Python `urllib.parse.quote`. encodeURIComponent agrees on the characters
 * that occur in our URLs; `safe` restores any deliberately-unencoded ones
 * (path keeps `/`).
 */
function quote(value: string, safe = ""): string {
  let encoded = encodeURIComponent(value);
  for (const char of safe) encoded = encoded.replaceAll(encodeURIComponent(char), char);
  return encoded;
}

/**
 * OVID_ANDROID_PACKAGE_NAME (default com.dhanuk.ovidai), validated as an
 * Android application id. Throws on an invalid configured value; the route's
 * catch-all maps that to 503, matching the Python wrapper.
 */
export function packageName(value = process.env.OVID_ANDROID_PACKAGE_NAME): string {
  const resolved = (value ?? "com.dhanuk.ovidai").trim();
  if (!PACKAGE_NAME_RE.test(resolved)) {
    throw new Error("OVID_ANDROID_PACKAGE_NAME is not a valid Android application id");
  }
  return resolved;
}

/** Play listing URL carrying the share token (+ invite) as install referrer. */
export function playStoreUrl(shareToken: string, invite?: string): string {
  const referrer =
    `share_token=${shareToken}` + (invite !== undefined ? `&invite=${invite}` : "");
  return (
    "https://play.google.com/store/apps/details?" +
    `id=${encodeURIComponent(packageName())}&referrer=${encodeURIComponent(referrer)}`
  );
}

export interface LandingPageOptions {
  title: string;
  heading: string;
  lead: string;
  body: string;
  /** Public host (netloc) from the configured base URL — never a Host header. */
  host: string;
  /** Public path (e.g. `/public/s/<token>`). */
  path: string;
  /** Play Store URL, already including the install referrer. */
  play: string;
  status?: number;
}

/** Renders the shared landing page; the caller sets the returned CSP header. */
export function landingPage(opts: LandingPageOptions): { html: string; csp: string } {
  const pkg = packageName();
  const intent =
    `intent://${opts.host}${quote(opts.path, "/")}#Intent;scheme=https;package=${pkg};` +
    `S.browser_fallback_url=${quote(opts.play)};end`;
  const esc = escapeHtml;
  const html =
    `<!doctype html><html lang="en" data-pkg="${esc(pkg)}" data-play="${esc(opts.play)}"><head>\n` +
    `<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\n` +
    `<meta name="robots" content="noindex,nofollow,noarchive"><title>${esc(opts.title)}</title>\n` +
    `<style>body{font:16px system-ui;max-width:760px;margin:40px auto;padding:0 20px;color:#202124}\n` +
    `section{border-top:1px solid #ddd;padding:16px 0}h2{font-size:15px}\n` +
    `pre{white-space:pre-wrap;overflow-wrap:anywhere;font:inherit;line-height:1.6}\n` +
    `.cta{display:flex;gap:12px;flex-wrap:wrap;margin:20px 0}\n` +
    `.cta a{padding:12px 18px;border-radius:999px;text-decoration:none;font-weight:600}\n` +
    `.primary{background:#1a73e8;color:#fff}.secondary{border:1px solid #1a73e8;color:#1a73e8}</style>\n` +
    `<script>${OPEN_APP_SCRIPT}</script></head><body><h1>${esc(opts.heading)}</h1><p>${esc(opts.lead)}</p>\n` +
    `<div class="cta"><a class="primary" rel="nofollow" href="${esc(intent)}">Open in the Ovid app</a>\n` +
    `<a class="secondary" rel="nofollow" href="${esc(opts.play)}">Get Ovid on Google Play</a></div>${opts.body}</body></html>`;
  return { html, csp: pageCsp() };
}
