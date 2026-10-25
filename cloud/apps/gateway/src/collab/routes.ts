import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { CollabError, type CollabErrorCode } from "@ovid/db";
import { authHook, type Verifier } from "../auth.js";
import { longPoll, type CollabLongPollOptions } from "./longPoll.js";
import type { CollabMembership } from "./membership.js";
import { CollabProjection, CollabProjectionError } from "./projection.js";

export interface CollabRouteDeps {
  membership: CollabMembership;
  projection: CollabProjection;
  verifier: Verifier;
  longPoll?: CollabLongPollOptions;
}

const MESSAGES: Record<CollabErrorCode, string> = {
  invalid_request: "Invalid request",
  not_member: "Not a session member",
  invite_invalid: "Invitation is invalid",
  invite_not_found: "Invitation not found",
  member_not_found: "Member not found",
  session_closed: "Session is closed",
  session_full: "Session is full",
  owner_not_removable: "Owner cannot be removed",
  request_already_used: "Request was already used",
  temporarily_unavailable: "The collaboration service is temporarily unavailable",
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function strictBody(request: FastifyRequest, allowed: readonly string[]): Record<string, unknown> {
  if (!isRecord(request.body)) throw new CollabError("invalid_request");
  const body = request.body;
  if (body.schemaVersion !== 1 || Object.keys(body).some((key) => !allowed.includes(key))) {
    throw new CollabError("invalid_request");
  }
  if (allowed.includes("idempotencyKey")) {
    if (typeof body.idempotencyKey !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(body.idempotencyKey)) {
      throw new CollabError("invalid_request");
    }
  }
  return body;
}

function requestId(body: Record<string, unknown>): string {
  if (typeof body.requestId !== "string" || body.requestId !== body.idempotencyKey) {
    throw new CollabError("invalid_request");
  }
  return body.requestId;
}

function stringField(body: Record<string, unknown>, key: string): string {
  if (typeof body[key] !== "string" || body[key] === "") throw new CollabError("invalid_request");
  return body[key];
}

function integerField(body: Record<string, unknown>, key: string, fallback: number): number {
  const value = body[key] ?? fallback;
  if (!Number.isInteger(value)) throw new CollabError("invalid_request");
  return value as number;
}

function token(request: FastifyRequest): string {
  const value = (request.params as { token?: unknown }).token;
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(value)) {
    throw new CollabError("not_member");
  }
  return value;
}

function refusal(reply: FastifyReply, error: unknown): FastifyReply {
  if (error instanceof CollabProjectionError) {
    const code = error.code as "not_member" | "session_closed" | "cursor_reset";
    const status = code === "session_closed" ? 409 : code === "cursor_reset" ? 410 : 403;
    return reply.code(status).send({
      schemaVersion: 1, code, message: code === "cursor_reset" ? "Replay cursor must be reset" : MESSAGES[code],
    });
  }
  if (error instanceof CollabError) {
    return reply.code(error.status).send({
      schemaVersion: 1,
      code: error.code,
      message: MESSAGES[error.code],
    });
  }
  throw error;
}

function disconnectSignal(request: FastifyRequest): AbortSignal {
  const supplied = (request.raw as typeof request.raw & { signal?: AbortSignal }).signal;
  if (supplied instanceof AbortSignal) return supplied;
  const controller = new AbortController();
  request.raw.once("aborted", () => {
    controller.abort(new DOMException("The operation was aborted.", "AbortError"));
  });
  return controller.signal;
}

function queryNumber(value: unknown, fallback: number, min: number, max: number): number {
  if (value === undefined) return fallback;
  if (typeof value !== "string" || !/^\d+$/.test(value)) throw new CollabError("invalid_request");
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) throw new CollabError("invalid_request");
  return parsed;
}

export function registerCollabRoutes(app: FastifyInstance, deps: CollabRouteDeps): void {
  app.addHook("onRequest", authHook(deps.verifier));
  app.addHook("onSend", async (_request, reply) => {
    reply.header("Cache-Control", "private, no-store");
  });

  app.post("/chat", async (request, reply) => {
    try {
      const body = strictBody(request, ["schemaVersion", "requestId", "idempotencyKey", "sessionId"]);
      const key = requestId(body);
      let sessionId: string | undefined;
      if (body.sessionId !== undefined) {
        if (typeof body.sessionId !== "string" || !/^[0-9a-f]{8}-[0-9a-f-]{27}$/i.test(body.sessionId)) {
          throw new CollabError("invalid_request");
        }
        sessionId = body.sessionId;
      }
      const result = await deps.membership.createRoom({ principal: request.principal, requestId: key, sessionId });
      return reply.send({
        schemaVersion: 1,
        sessionToken: result.sessionToken,
        session: result.session,
        member: result.member,
        cursor: result.cursor,
      });
    } catch (error) { return refusal(reply, error); }
  });

  app.get("/chat/:token", async (request, reply) => {
    try {
      const opaque = token(request);
      const auth = await deps.membership.authorize({ principal: request.principal, token: opaque });
      const result = await deps.projection.state({ roomId: auth.roomId, viewerUid: request.principal.uid });
      return reply.send(result);
    } catch (error) { return refusal(reply, error); }
  });

  app.post("/chat/:token/members", async (request, reply) => {
    try {
      const opaque = token(request);
      if (!isRecord(request.body)) throw new CollabError("invalid_request");
      if (Object.hasOwn(request.body, "invitationCode")) {
        const body = strictBody(request, ["schemaVersion", "idempotencyKey", "invitationCode"]);
        const result = await deps.membership.join({
          principal: request.principal,
          token: opaque,
          inviteCode: stringField(body, "invitationCode"),
          idempotencyKey: body.idempotencyKey as string,
        });
        return reply.send({ schemaVersion: 1, ...result });
      }
      const body = strictBody(request, ["schemaVersion", "idempotencyKey", "maxUses", "ttlSeconds"]);
      const result = await deps.membership.createInvite({
        principal: request.principal,
        token: opaque,
        idempotencyKey: body.idempotencyKey as string,
        maxUses: integerField(body, "maxUses", 1),
        ttlSeconds: integerField(body, "ttlSeconds", 86_400),
      });
      return reply.send({
        schemaVersion: 1,
        inviteId: result.inviteId,
        inviteCode: result.inviteCode,
        expiresAt: result.expiresAt,
        maxUses: result.maxUses,
      });
    } catch (error) { return refusal(reply, error); }
  });

  app.delete("/chat/:token/invites/:inviteId", async (request, reply) => {
    try {
      const opaque = token(request);
      const inviteId = (request.params as { inviteId?: unknown }).inviteId;
      if (typeof inviteId !== "string") throw new CollabError("invite_not_found");
      await deps.membership.revokeInvite({ principal: request.principal, token: opaque, inviteId });
      return reply.send({ schemaVersion: 1, inviteId, revoked: true });
    } catch (error) { return refusal(reply, error); }
  });

  app.delete("/chat/:token/members/me", async (request, reply) => {
    try {
      const result = await deps.membership.leave({ principal: request.principal, token: token(request) });
      return reply.send({ schemaVersion: 1, member: result.member });
    } catch (error) { return refusal(reply, error); }
  });

  app.delete("/chat/:token/members/:participantId", async (request, reply) => {
    try {
      const participantId = (request.params as { participantId?: unknown }).participantId;
      if (typeof participantId !== "string" || participantId === "me") throw new CollabError("member_not_found");
      const result = await deps.membership.remove({
        principal: request.principal, token: token(request), participantId,
      });
      return reply.send({ schemaVersion: 1, member: result.member });
    } catch (error) { return refusal(reply, error); }
  });

  app.get("/chat/:token/events", async (request, reply) => {
    try {
      const opaque = token(request);
      const query = request.query as Record<string, unknown>;
      const auth = await deps.membership.authorize({ principal: request.principal, token: opaque });
      if (Object.keys(query).some((key) => !["cursor", "limit", "wait"].includes(key))) {
        throw new CollabError("invalid_request");
      }
      const cursor = query.cursor ?? null;
      if (cursor !== null && (typeof cursor !== "string" || cursor.length > 4096)) {
        throw new CollabError("invalid_request");
      }
      const result = await longPoll(deps.projection, {
        roomId: auth.roomId,
        viewerUid: request.principal.uid,
        cursor: cursor as string | null,
        limit: queryNumber(query.limit, 100, 1, 100),
        waitSeconds: queryNumber(query.wait, 0, 0, 25),
        signal: disconnectSignal(request),
      }, deps.longPoll);
      return reply.send(result);
    } catch (error) { return refusal(reply, error); }
  });

  app.post("/chat/:token/close", async (request, reply) => {
    try {
      const body = strictBody(request, ["schemaVersion", "idempotencyKey"]);
      const result = await deps.membership.close({
        principal: request.principal,
        token: token(request),
        idempotencyKey: body.idempotencyKey as string,
      });
      return reply.send({ schemaVersion: 1, ...result });
    } catch (error) { return refusal(reply, error); }
  });

  // Task 4 owns actual admission. Never offer a partial arbitrary-event writer.
  app.post("/chat/:token/turns", async (request, reply) => {
    try {
      const body = strictBody(request, ["schemaVersion", "idempotencyKey", "text", "model", "attachmentIds"]);
      stringField(body, "text");
      if (body.model !== undefined && (typeof body.model !== "string" || body.model === "")) {
        throw new CollabError("invalid_request");
      }
      if (body.attachmentIds !== undefined && (
        !Array.isArray(body.attachmentIds) ||
        body.attachmentIds.some((id) => typeof id !== "string" || id === "")
      )) {
        throw new CollabError("invalid_request");
      }
      await deps.membership.authorize({ principal: request.principal, token: token(request) });
      throw new CollabError("temporarily_unavailable");
    } catch (error) { return refusal(reply, error); }
  });
}
