import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { lockPushSubscriptions, pushSubscriptionsRepo, users, type Db } from "@ovid/db";
import type { GatewayDeps } from "../app.js";
import { sendError, zodBadRequest } from "./http.js";

const STANDARD_PUSH_HOSTS = new Set([
  "fcm.googleapis.com",
  "updates.push.services.mozilla.com",
  "web.push.apple.com",
]);
const MAX_BROWSER_SUBSCRIPTIONS = 10;

function allowedEndpoint(raw: string): boolean {
  try {
    const url = new URL(raw);
    const extra = (process.env.WEB_PUSH_ALLOWED_HOSTS ?? "")
      .split(",").map((host) => host.trim().toLowerCase()).filter((host) => host !== "");
    return (
      url.protocol === "https:" &&
      url.username === "" &&
      url.password === "" &&
      (STANDARD_PUSH_HOSTS.has(url.hostname.toLowerCase()) || extra.includes(url.hostname.toLowerCase()))
    );
  } catch {
    return false;
  }
}

const subscribeBody = z.object({
  endpoint: z.string().url().max(4096).refine(allowedEndpoint),
  p256dh: z.string().min(1).max(512),
  auth: z.string().min(1).max(512),
}).strict();
const unsubscribeBody = subscribeBody.pick({ endpoint: true }).strict();

export function registerWebPushRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/push/subscription", async (request, reply) => {
    const query = (request.query ?? {}) as Record<string, unknown>;
    if (!allowedEndpoint(typeof query.endpoint === "string" ? query.endpoint : "")) {
      return reply.header("cache-control", "private, no-store").send({ registered: false });
    }
    const rows = await pushSubscriptionsRepo.listForUser(deps.db, request.principal.uid);
    return reply.header("cache-control", "private, no-store").send({
      registered: rows.some((row) => row.endpoint === query.endpoint),
    });
  });

  app.get("/push/config", async (_request, reply) => {
    const key = deps.webPushPublicKey?.trim();
    if (!key) {
      return sendError(
        reply,
        503,
        "web_push_unconfigured",
        "Web push is not configured on this deployment.",
      );
    }
    return reply.header("cache-control", "private, no-store").send({ vapidPublicKey: key });
  });

  app.post("/push/subscriptions", async (request, reply) => {
    const parsed = subscribeBody.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    const { uid, email } = request.principal;
    await users.ensure(deps.db, uid, email);
    const accepted = await deps.db.transaction(async (tx) => {
      const db = tx as unknown as Db;
      await lockPushSubscriptions(db, uid);
      const existing = await pushSubscriptionsRepo.listForUser(db, uid);
      const isRefresh = existing.some((row) => row.endpoint === parsed.data.endpoint);
      if (!isRefresh && existing.length >= MAX_BROWSER_SUBSCRIPTIONS) return false;
      await pushSubscriptionsRepo.upsert(db, {
        userId: uid,
        ...parsed.data,
      });
      return true;
    });
    if (!accepted) {
      return sendError(reply, 409, "push_subscription_limit", "Disconnect an older browser before adding another.");
    }
    return reply.header("cache-control", "private, no-store").code(201).send({ registered: true });
  });

  app.delete("/push/subscriptions", async (request, reply) => {
    const parsed = unsubscribeBody.safeParse(request.body ?? {});
    if (!parsed.success) return zodBadRequest(reply, parsed.error);
    await pushSubscriptionsRepo.remove(deps.db, request.principal.uid, parsed.data.endpoint);
    return reply.code(204).send();
  });
}
