import { timingSafeEqual } from "node:crypto";
import type {
  FastifyError,
  FastifyInstance,
  FastifyReply,
  FastifyRequest,
} from "fastify";
import type { MintEnv } from "../env.js";
import type { CardManager } from "./cardManager.js";

/**
 * Port of server/images/admin.py — owner-only card admin routes.
 *
 * Mounted on the ADMIN listener (8092) only and protected by the LiteLLM
 * master key (the same credential the mint admin routes use). Responses
 * contain internal model names and probe results and must never be exposed to
 * app users. The Python contract answers 403 `{"error":{"code":"forbidden"}}`
 * for a missing or wrong key (not the mint admin ladder's 401/403 split).
 */

export interface ImagesAdminDeps {
  env: MintEnv;
}

export interface ImagesAdminOptions {
  wake?: () => void;
  refreshPrices?: () => Promise<void>;
}

function headerValue(value: string | string[] | undefined): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value[0] ?? "";
  return "";
}

function authorized(deps: ImagesAdminDeps, authorization: string): boolean {
  const master = deps.env.adminMasterKey ?? "";
  if (master === "") return false;
  if (!authorization.toLowerCase().startsWith("bearer ")) return false;
  const token = authorization.slice(authorization.indexOf(" ") + 1);
  const expected = Buffer.from(master, "utf8");
  const got = Buffer.from(token, "utf8");
  return got.length === expected.length && timingSafeEqual(got, expected);
}

function forbidden(reply: FastifyReply): FastifyReply {
  return reply.code(403).send({ error: { code: "forbidden" } });
}

function round6(value: number): number {
  return Math.round(value * 1_000_000) / 1_000_000;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function registerImagesAdminRoutes(
  adminApp: FastifyInstance,
  deps: ImagesAdminDeps,
  manager: CardManager,
  opts: ImagesAdminOptions = {},
): void {
  adminApp.register(async (scope) => {
    // onRequest fires BEFORE body parsing, matching Python's authorize-first
    // order even for a malformed body.
    scope.addHook("onRequest", async (request: FastifyRequest, reply: FastifyReply) => {
      if (!authorized(deps, headerValue(request.headers.authorization))) {
        return forbidden(reply);
      }
    });

    // admin.py reads the reprobe body with request.json(), so a malformed or
    // non-JSON body is always 400 {"error":{"code":"invalid_request"}}. Fastify
    // raises 400/415 during body parsing, before the route handler runs; map
    // those parse errors to the Python contract. Everything else keeps the
    // default Fastify serialization.
    scope.setErrorHandler((error: FastifyError, request, reply) => {
      const statusCode = error.statusCode ?? 500;
      if (
        request.method === "POST" &&
        request.url.split("?", 1)[0] === "/images/admin/reprobe" &&
        (statusCode === 400 || statusCode === 415)
      ) {
        return reply.code(400).send({ error: { code: "invalid_request" } });
      }
      return reply.send(error);
    });

    scope.get("/images/admin/cards", async (_request, reply) => {
      const cards = manager.cards();
      const out = [];
      for (const card of cards) {
        out.push({
          ...card,
          history: await manager.store.history(card.model),
          probe_state: await manager.store.probeState(card.model),
        });
      }
      const spent = await manager.store.spentSince(Date.now() / 1000 - 86_400);
      const runner = manager.runner;
      const daily = runner === null ? null : Number(runner.dailyCapUsd.toString());
      const perCall = runner === null ? null : Number(runner.perProbeCapUsd.toString());
      const spentUsd = round6(Number(spent.toString()));
      const budget = {
        probes_enabled: runner !== null,
        probe_spend_24h_usd: spentUsd,
        probe_daily_cap_usd: daily,
        probe_daily_left_usd:
          daily === null ? null : round6(Math.max(0, daily - Number(spent.toString()))),
        probe_per_call_cap_usd: perCall,
      };
      return reply.headers({ "Cache-Control": "no-store" }).send({
        schema: 1,
        cards: out,
        probe_spend_24h_usd: spentUsd,
        probe_budget: budget,
      });
    });

    scope.post("/images/admin/refresh-prices", async (_request, reply) => {
      // Re-read LiteLLM prices/discovery now (otherwise they refresh on TTL).
      if (opts.refreshPrices !== undefined) await opts.refreshPrices();
      return reply.headers({ "Cache-Control": "no-store" }).send({
        refreshed: opts.refreshPrices !== undefined,
        priced: Object.fromEntries(manager.cards().map((card) => [card.model, card.priced])),
      });
    });

    scope.post("/images/admin/reprobe", async (request, reply) => {
      const body = request.body;
      if (!isPlainObject(body) || typeof body.model !== "string") {
        return reply.code(400).send({ error: { code: "invalid_request" } });
      }
      const wanted = body.model;
      const name = manager
        .cards()
        .find((card) => card.model === wanted || card.slug === wanted)?.model;
      if (name === undefined || !manager.reprobe(name)) {
        return reply.code(404).send({ error: { code: "unknown_model" } });
      }
      opts.wake?.();
      return reply.code(202).send({ queued: name });
    });
  });
}
