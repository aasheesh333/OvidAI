import type { FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";
import { browserCredentialsRepo, newId, users } from "@ovid/db";
import { browserCredentialRecordId } from "@ovid/shared";
import type { EnvelopeCrypto } from "@ovid/escrow";
import type { GatewayDeps } from "../app.js";
import { isUuid, sendError, zodBadRequest } from "./http.js";

/**
 * Wave 6 W4 — browser Credentials Vault routes.
 *
 *   GET    /credentials        metadata only (label/site/username/kind)
 *   POST   /credentials        seal password/token + optional notes
 *   PATCH  /credentials/:id    partial update; a new secret re-seals
 *   DELETE /credentials/:id    owner-scoped
 *
 * The plaintext secret is never echoed, logged or stored: it exists only in
 * the request body, the AES-256-GCM envelope (AAD `browser_credentials:{id}`)
 * and — at login time — the worker's memory. Every answer is `private,
 * no-store`; wrong owner and unknown id are the same 404.
 */

export const MAX_CREDENTIALS_PER_USER = 100;
const MAX_SECRET_CHARS = 16_384;
const MAX_NOTES_CHARS = 8_192;

function unavailable(reply: FastifyReply): FastifyReply {
  return sendError(reply, 503, "unavailable", "The credentials vault is not configured.");
}

function noStore(reply: FastifyReply): FastifyReply {
  return reply.header("cache-control", "private, no-store").header("pragma", "no-cache");
}

/** Postgres unique-violation code, across drizzle's error wrapping. */
function isUniqueViolation(err: unknown): boolean {
  let current: unknown = err;
  for (let depth = 0; depth < 4 && current !== null && current !== undefined; depth++) {
    if ((current as { code?: unknown }).code === "23505") return true;
    current = (current as { cause?: unknown }).cause;
  }
  return false;
}

/** Canonical HTTPS origin/path metadata; credentials never travel in `site`. */
function normalizeSite(raw: string): string | null {
  const site = raw.trim();
  if (site === "") return null;
  try {
    const url = new URL(site.includes("://") ? site : `https://${site}`);
    if (
      url.protocol !== "https:" ||
      url.hostname === "" ||
      url.username !== "" ||
      url.password !== "" ||
      url.search !== "" ||
      url.hash !== ""
    ) {
      return null;
    }
    return url.toString();
  } catch {
    return null;
  }
}

const createBody = z
  .object({
    label: z.string().trim().min(1).max(120),
    site: z.string().trim().min(1).max(2048),
    username: z.string().max(512).optional(),
    secret: z.string().min(1).max(MAX_SECRET_CHARS),
    secretKind: z.enum(["password", "token"]).optional(),
    notes: z.string().max(MAX_NOTES_CHARS).nullable().optional(),
  })
  .strict();

const patchBody = z
  .object({
    label: z.string().trim().min(1).max(120).optional(),
    site: z.string().trim().min(1).max(2048).optional(),
    username: z.string().max(512).optional(),
    secret: z.string().min(1).max(MAX_SECRET_CHARS).optional(),
    secretKind: z.enum(["password", "token"]).optional(),
    notes: z.string().max(MAX_NOTES_CHARS).nullable().optional(),
  })
  .strict();

function project(row: {
  id: string;
  label: string;
  site: string;
  username: string;
  secretKind: "password" | "token";
  hasNotes: boolean;
  createdAt: Date;
  updatedAt: Date;
}): Record<string, unknown> {
  return {
    id: row.id,
    label: row.label,
    site: row.site,
    username: row.username,
    secretKind: row.secretKind,
    hasNotes: row.hasNotes,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

export function registerCredentialRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/credentials", async (request, reply) => {
    const rows = await browserCredentialsRepo.list(deps.db, request.principal.uid);
    return noStore(reply).send({ items: rows.map(project) });
  });

  app.post("/credentials", async (request, reply) => {
    if (deps.crypto === undefined) return unavailable(reply);
    const parsed = createBody.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const body = parsed.data;
    const site = normalizeSite(body.site);
    if (site === null) {
      return sendError(reply, 400, "bad_request", "site must be an HTTPS URL without credentials, query or fragment.");
    }

    const { uid, email } = request.principal;
    await users.ensure(deps.db, uid, email);
    if ((await browserCredentialsRepo.count(deps.db, uid)) >= MAX_CREDENTIALS_PER_USER) {
      return sendError(
        reply,
        409,
        "limit_reached",
        `At most ${MAX_CREDENTIALS_PER_USER} credentials may be stored per account.`,
      );
    }

    const id = newId();
    const secretSealed = deps.crypto.encrypt(body.secret, browserCredentialRecordId(id));
    const notesSealed =
      body.notes === undefined || body.notes === null || body.notes === ""
        ? null
        : deps.crypto.encrypt(body.notes, browserCredentialRecordId(id));

    let row;
    try {
      row = await browserCredentialsRepo.create(deps.db, {
        id,
        userId: uid,
        label: body.label,
        site,
        username: body.username ?? "",
        secretKind: body.secretKind ?? "password",
        secretSealed,
        notesSealed,
      });
    } catch (err) {
      // UNIQUE(user_id, label). Postgres code 23505 — never echo the body.
      if (isUniqueViolation(err)) {
        return sendError(reply, 409, "label_taken", "A credential with that label already exists.");
      }
      throw err;
    }

    return noStore(reply).code(201).send(project(row));
  });

  app.patch("/credentials/:id", async (request, reply) => {
    if (deps.crypto === undefined) return unavailable(reply);
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return sendError(reply, 404, "not_found", "Credential not found.");
    const parsed = patchBody.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const body = parsed.data;
    const site = body.site === undefined ? undefined : normalizeSite(body.site);
    if (site === null) {
      return sendError(reply, 400, "bad_request", "site must be an HTTPS URL without credentials, query or fragment.");
    }
    if (Object.keys(body).length === 0) {
      return sendError(reply, 400, "bad_request", "Nothing to update.");
    }

    const uid = request.principal.uid;
    const existing = await browserCredentialsRepo.get(deps.db, uid, id);
    if (existing === null) return sendError(reply, 404, "not_found", "Credential not found.");

    let row;
    try {
      row = await browserCredentialsRepo.update(deps.db, uid, id, {
        ...(body.label !== undefined ? { label: body.label } : {}),
        ...(site !== undefined ? { site } : {}),
        ...(body.username !== undefined ? { username: body.username } : {}),
        ...(body.secretKind !== undefined ? { secretKind: body.secretKind } : {}),
        ...(body.secret !== undefined
          ? { secretSealed: deps.crypto.encrypt(body.secret, browserCredentialRecordId(id)) }
          : {}),
        ...(body.notes !== undefined
          ? {
              notesSealed:
                body.notes === null || body.notes === ""
                  ? null
                  : deps.crypto.encrypt(body.notes, browserCredentialRecordId(id)),
            }
          : {}),
      });
    } catch (err) {
      if (isUniqueViolation(err)) {
        return sendError(reply, 409, "label_taken", "A credential with that label already exists.");
      }
      throw err;
    }
    if (row === null) return sendError(reply, 404, "not_found", "Credential not found.");
    return noStore(reply).send(project(row));
  });

  app.delete("/credentials/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return sendError(reply, 404, "not_found", "Credential not found.");
    const removed = await browserCredentialsRepo.remove(deps.db, request.principal.uid, id);
    if (!removed) return sendError(reply, 404, "not_found", "Credential not found.");
    return reply.code(204).header("cache-control", "private, no-store").send();
  });
}
