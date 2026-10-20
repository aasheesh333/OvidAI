/**
 * Wave 6 W4 — Credentials Vault tools.
 *
 * The vault stores an entry per login: URL/site, username, password-or-token
 * (AES-256-GCM sealed server-side) and optional notes. The AGENT may list
 * entries and use one to fill a login form, but it never receives the secret
 * in tool output: [BrowserCredentialsPort.resolve] hands the plaintext
 * directly to the Playwright fill calls in this module. Nothing here logs,
 * returns, or embeds the secret, and every failure message is value-free.
 *
 * Safety pins:
 *  - Host binding: the credential's `site` must match the live page's host
 *    (exact or a dot-boundary suffix). A model that navigated to a phishing
 *    page cannot make the browser type the secret there.
 *  - The tools require an explicit credential id; there is no "guess the
 *    credential for this page" path.
 *  - Missing vault wiring is a loud content error, never a silent no-op.
 */

import { z } from "zod";

import { withSession } from "../sessionOps.js";
import {
  TOOL_ERROR_PREFIX,
  defineBrowserTool,
  type BrowserCredentialSecret,
  type BrowserToolDef,
  type BrowserToolSpec,
  type BrowserToolsDeps,
} from "./types.js";

const NO_VAULT = `${TOOL_ERROR_PREFIX}the credentials vault is not configured on this deployment`;

/** Lower-cased host from a credential site ("https://x.test/login" or "x.test"). */
export function credentialHost(site: string): string | null {
  const raw = site.trim();
  if (raw === "") return null;
  try {
    const url = new URL(raw.includes("://") ? raw : `https://${raw}`);
    return url.hostname.toLowerCase() || null;
  } catch {
    return null;
  }
}

/**
 * True when `pageHost` is exactly `siteHost` (or the conventional `www.`
 * alias of it). Deliberately NOT a general subdomain match: an
 * attacker-controlled subdomain must not receive a credential stored for the
 * parent domain. Users who sign in on `accounts.example.test` should store
 * that host.
 */
export function hostMatches(pageHost: string, siteHost: string): boolean {
  const page = pageHost.toLowerCase();
  const site = siteHost.toLowerCase();
  return page === site || page === `www.${site}` || site === `www.${page}`;
}

/**
 * Host of the live page. `page.url()` is authoritative; a blank/about: page
 * has no host and therefore cannot match a vault entry.
 */
function pageHost(url: string): string | null {
  try {
    const parsed = new URL(url);
    return parsed.hostname.toLowerCase() || null;
  } catch {
    return null;
  }
}

/** Default username field: the first visible credential-ish text input. */
const DEFAULT_USERNAME_SELECTOR =
  'input[type="email"], input[autocomplete="username"], input[name*="user" i], input[name*="email" i], input[type="text"]';
/** Default secret field. */
const DEFAULT_PASSWORD_SELECTOR = 'input[type="password"]';
const DEFAULT_TOKEN_SELECTOR =
  'input[type="password"], input[name*="token" i], input[name*="key" i], input[type="text"]';

function describe(entry: BrowserCredentialSecret): string {
  const kind = entry.secretKind === "token" ? "token" : "password";
  return `${entry.label} (${entry.site}, ${entry.username}, ${kind})`;
}

function specs(deps: BrowserToolsDeps): BrowserToolSpec[] {
  const list: BrowserToolSpec = {
    name: "browser_list_credentials",
    description:
      "List the user's saved browser credentials (label, site, username, kind). Secrets are never returned. Use browser_login_with_credential to sign in.",
    parameters: { type: "object", properties: {} },
    inputSchema: z.object({}).strict(),
    async execute(_input, ctx) {
      if (deps.credentials === undefined) return { content: NO_VAULT };
      const entries = await deps.credentials.list(ctx.userId);
      if (entries.length === 0) return { content: "No saved credentials." };
      return {
        content: entries
          .map(
            (e) =>
              `- ${e.id}: ${e.label} (${e.site}, ${e.username}, ${
                e.secretKind === "token" ? "token" : "password"
              })`,
          )
          .join("\n"),
      };
    },
  };

  const login: BrowserToolSpec = {
    name: "browser_login_with_credential",
    description:
      "Fill a login form from the user's credentials vault. The secret is injected server-side and is NEVER shown to you. Only works on the credential's own site. Optionally submits the form.",
    parameters: {
      type: "object",
      properties: {
        credentialId: { type: "string", description: "Id from browser_list_credentials." },
        usernameSelector: {
          type: "string",
          description: "CSS selector for the username/e-mail field (auto-detected when omitted).",
        },
        secretSelector: {
          type: "string",
          description: "CSS selector for the password/token field (auto-detected when omitted).",
        },
        submit: {
          type: "boolean",
          description: "Submit the form after filling (default false).",
        },
        submitSelector: {
          type: "string",
          description: "CSS selector for the submit control (defaults to pressing Enter).",
        },
      },
      required: ["credentialId"],
    },
    inputSchema: z
      .object({
        credentialId: z.string().min(1),
        usernameSelector: z.string().min(1).optional(),
        secretSelector: z.string().min(1).optional(),
        submit: z.boolean().optional(),
        submitSelector: z.string().min(1).optional(),
      })
      .strict(),
    async execute(input, ctx) {
      if (deps.credentials === undefined) return { content: NO_VAULT };
      const entry = await deps.credentials.resolve(ctx.userId, input.credentialId);
      if (entry === null) {
        return { content: `${TOOL_ERROR_PREFIX}credential not found` };
      }

      const siteHost = credentialHost(entry.site);
      return withSession(deps, ctx, async (_session, page) => {
        const currentHost = pageHost(page.url());
        if (siteHost === null || currentHost === null || !hostMatches(currentHost, siteHost)) {
          // Deliberately value-free and precise about the refusal.
          return {
            content: `${TOOL_ERROR_PREFIX}this credential is for ${entry.site}; the live page is ${
              currentHost ?? "not a web page"
            }`,
          };
        }

        const secretSelector =
          input.secretSelector ??
          (entry.secretKind === "token" ? DEFAULT_TOKEN_SELECTOR : DEFAULT_PASSWORD_SELECTOR);
        const usernameSelector = input.usernameSelector ?? DEFAULT_USERNAME_SELECTOR;

        // Username is optional: token-only forms have no user field. A fill
        // failure on the username selector is tolerated; the secret fill is
        // required (it is the whole point of the call).
        if (entry.username !== "") {
          try {
            await page.fill(usernameSelector, entry.username);
          } catch {
            // No matching username field — continue with the secret.
          }
        }
        try {
          await page.fill(secretSelector, entry.secret);
        } catch {
          return {
            content: `${TOOL_ERROR_PREFIX}could not find the secret field (${secretSelector})`,
          };
        }

        if (input.submit === true) {
          try {
            if (input.submitSelector !== undefined) {
              await page.click(input.submitSelector);
            } else {
              await page.keyboard.press("Enter");
            }
          } catch {
            return { content: `${TOOL_ERROR_PREFIX}credentials filled but submit failed` };
          }
        }

        return {
          content: `filled credentials for ${describe(entry)}${
            input.submit === true ? " and submitted the form" : ""
          }`,
        };
      });
    },
  };

  return [list, login];
}

export function credentialTools(deps: BrowserToolsDeps): BrowserToolDef[] {
  return specs(deps).map((spec) => defineBrowserTool(deps, spec));
}
