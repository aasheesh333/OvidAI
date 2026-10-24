/**
 * Wave 6 W4 — Credentials Vault metadata tool.
 *
 * The vault stores an entry per login: URL/site, username, password-or-token
 * (AES-256-GCM sealed server-side) and optional notes. The agent may list
 * non-secret metadata only. Legacy browser credential autofill is disabled:
 * it is absent from every roster and its direct execution boundary refuses
 * before resolving a secret or touching a page.
 */

import { z } from "zod";

import {
  TOOL_ERROR_PREFIX,
  defineBrowserTool,
  type BrowserToolDef,
  type BrowserToolSpec,
  type BrowserToolsDeps,
} from "./types.js";

const NO_VAULT = `${TOOL_ERROR_PREFIX}the credentials vault is not configured on this deployment`;
const LEGACY_AUTOFILL_REFUSAL = `${TOOL_ERROR_PREFIX}credential_autofill_disabled`;

function listSpec(deps: BrowserToolsDeps): BrowserToolSpec {
  return {
    name: "browser_list_credentials",
    description:
      "List the user's saved browser credentials (label, site, username, kind). Secrets are never returned.",
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
}

/**
 * Internal, non-roster boundary for stale direct callers of the legacy tool.
 * No autofill implementation is retained here; a future broker must be a
 * separate implementation and cannot re-enable this path by calling it.
 */
export function legacyCredentialAutofillTool(deps: BrowserToolsDeps): BrowserToolDef {
  return defineBrowserTool(deps, {
    name: "browser_login_with_credential",
    description: "Legacy browser credential autofill is disabled.",
    parameters: {
      type: "object",
      properties: {
        credentialId: { type: "string", description: "Id from browser_list_credentials." },
        usernameSelector: {
          type: "string",
          description: "CSS selector for the username/e-mail field.",
        },
        secretSelector: {
          type: "string",
          description: "CSS selector for the password/token field.",
        },
        submit: {
          type: "boolean",
          description: "Submit the form after filling.",
        },
        submitSelector: {
          type: "string",
          description: "CSS selector for the submit control.",
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
    async execute() {
      return { content: LEGACY_AUTOFILL_REFUSAL };
    },
  });
}

export function credentialTools(deps: BrowserToolsDeps): BrowserToolDef[] {
  return [defineBrowserTool(deps, listSpec(deps))];
}
