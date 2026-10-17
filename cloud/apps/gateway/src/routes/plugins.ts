import type { FastifyInstance, FastifyReply } from "fastify";
import { z } from "zod";
import { newId, plugins as pluginsRepo, users, type PluginRow } from "@ovid/db";
import {
  adaptPlugin,
  createSourceResolver,
  PRO_REQUIRED_MESSAGE,
  type SourceResolver,
} from "@ovid/mcp";
import {
  PLUGIN_INSTALL_JOB_NAME,
  type PluginInstallJob,
} from "@ovid/queue";
import {
  pluginSourceInputSchema,
  type PluginDto,
  type PluginInstallResponse,
  type PluginSourceInput,
} from "@ovid/shared";
import type { GatewayDeps } from "../app.js";
import { isUuid, notFound, sendError, zodBadRequest } from "./http.js";

/**
 * Plugin routes (P5 Task 15).
 *
 *  - Install/uninstall are Pro features, re-read at REQUEST time (a downgrade
 *    takes effect on the next call).
 *  - POST /install computes the canonical `publisher/name` at enqueue: the
 *    Task-14 installer re-derives it from the manifest and refuses a mismatch
 *    (`plugin_id_mismatch`), so the row and the job carry the same id.
 *  - The row is created `queued` here; the worker processor claims it
 *    (`installing`) and owns every later transition, including `rolled_back`.
 *  - PATCH /config seals values under `plugins:{id}`. Neither the manifest
 *    nor any config value is ever projected in a DTO.
 *  - DELETE verifies row ownership BEFORE enqueueing (a foreign id is a 404,
 *    never a job).
 */

const installBodySchema = z
  .object({
    source: pluginSourceInputSchema,
  })
  .strict();

const configBodySchema = z
  .object({
    config: z.record(z.string(), z.string()),
  })
  .strict();

const PLUGIN_NOT_FOUND = "Plugin not found.";

/**
 * Resolver used to stage a source ONCE at enqueue so the row/job carry the
 * same canonical `publisher/name` the Task-14 installer re-derives from the
 * manifest. A source heuristic (owner/repo, package slug, `paste/<label>`)
 * produced ids the installer refuses with `plugin_id_mismatch`.
 *
 * Lazily constructed so importing this module stays side-effect free; the
 * resolver reads GITHUB_API_TOKEN from the environment on first use.
 */
let sourceResolver: Pick<SourceResolver, "resolve"> | undefined;

function pluginSourceResolver(): Pick<SourceResolver, "resolve"> {
  sourceResolver ??= createSourceResolver();
  return sourceResolver;
}

/**
 * Derive the canonical plugin id the SAME way the installer will: stage the
 * source with the runtime resolver and adapt its manifest. Mirrors the
 * worker's catalog-tool enqueue path (mcpTools.ts `canonicalPluginId`).
 *
 * The staging tree is discarded immediately — this call only reads identity;
 * the install transaction resolves the source again.
 */
async function canonicalPluginId(
  resolver: Pick<SourceResolver, "resolve">,
  source: PluginSourceInput,
): Promise<string> {
  const resolved = await resolver.resolve(source);
  try {
    return (await adaptPlugin(resolved.stagingDir)).pluginId;
  } finally {
    await resolved.discard().catch(() => {
      // discard is idempotent/best-effort; identity was already read.
    });
  }
}

/** Non-secret source projection stored on the row and served in DTOs. */
function sourceLabel(source: PluginSourceInput): string {
  switch (source.kind) {
    case "github":
      return `${source.owner}/${source.repo}`;
    case "npm":
      return source.package;
    case "zip":
      return source.url;
    case "paste":
      return source.label;
  }
}

function pluginNotFound(reply: FastifyReply): FastifyReply {
  return notFound(reply, PLUGIN_NOT_FOUND);
}

function probeFailureText(entry: unknown): string {
  if (typeof entry === "string") return entry;
  if (entry !== null && typeof entry === "object") {
    const record = entry as Record<string, unknown>;
    for (const key of ["file", "name", "path", "kind"]) {
      if (typeof record[key] === "string" && record[key] !== "") return record[key];
    }
  }
  try {
    return JSON.stringify(entry);
  } catch {
    return "unknown";
  }
}

/** Masked wire projection: no manifest, no config values, no content dir. */
function toDto(row: PluginRow): PluginDto {
  const source = (row.source ?? {}) as Record<string, unknown>;
  const kind = typeof source.kind === "string" && source.kind !== "" ? source.kind : "unknown";
  const label =
    typeof source.label === "string" && source.label !== ""
      ? source.label
      : typeof source.githubRepo === "string" && source.githubRepo !== ""
        ? source.githubRepo
        : typeof source.npmPackage === "string" && source.npmPackage !== ""
          ? source.npmPackage
          : typeof source.url === "string" && source.url !== ""
            ? source.url
            : row.pluginId;

  const manifest = (row.manifest ?? {}) as Record<string, unknown>;
  const capabilities = Array.isArray(manifest.capabilities)
    ? manifest.capabilities.filter((c): c is string => typeof c === "string")
    : [];
  const probeFailures = Array.isArray(row.probeFailures)
    ? row.probeFailures.map(probeFailureText)
    : [];

  return {
    id: row.id,
    pluginId: row.pluginId,
    version: row.version !== "" ? row.version : "pending",
    status: row.status,
    source: { kind, label },
    capabilities,
    probeFailures,
    installedAt: row.installedAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}

export function registerPluginRoutes(app: FastifyInstance, deps: GatewayDeps): void {
  app.get("/plugins", async (request) => {
    const rows = await pluginsRepo.list(deps.db, request.principal.uid);
    return rows.map(toDto);
  });

  app.get("/plugins/:id", async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return pluginNotFound(reply);
    const row = await pluginsRepo.get(deps.db, id, request.principal.uid);
    if (row === null) return pluginNotFound(reply);
    return toDto(row);
  });

  app.post("/plugins/install", async (request, reply) => {
    const { uid } = request.principal;

    const parsed = installBodySchema.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);

    // Tier gate FIRST: cheaper than the queue lookup and it never reveals
    // the composition's queue state to a Free caller.
    const tier = await users.getTier(deps.db, uid);
    if (tier === "free") {
      return sendError(reply, 402, "pro_required", PRO_REQUIRED_MESSAGE);
    }

    const queue = deps.queues.pluginInstalls;
    if (queue === undefined) {
      return sendError(reply, 503, "unavailable", "Plugin installs are not configured.");
    }

    const source = parsed.data.source;

    // Canonical id from the MANIFEST (never a source heuristic): the
    // installer re-derives identity from the same manifest and refuses a
    // mismatch (`plugin_id_mismatch`). An unresolvable/adapt-failing source
    // is a 400 and enqueues NOTHING — no row, no job.
    let pluginId: string;
    try {
      pluginId = await canonicalPluginId(pluginSourceResolver(), source);
    } catch (err) {
      const reason = err instanceof Error ? err.message : String(err);
      return sendError(
        reply,
        400,
        "invalid_source",
        `The plugin source could not be resolved: ${reason}`,
      );
    }
    if (pluginId === "" || pluginId === "/" || pluginId.split("/").some((s) => s === "")) {
      return sendError(reply, 400, "invalid_source", "The plugin source has no usable identity.");
    }

    // Carry 3: the row exists (status queued) BEFORE the job is enqueued.
    const row = await pluginsRepo.upsert(deps.db, {
      userId: uid,
      pluginId,
      version: "pending",
      source: { kind: source.kind, label: sourceLabel(source) },
      status: "queued",
    });

    const job: PluginInstallJob = {
      installId: row.id,
      userId: uid,
      pluginId,
      mode: "install",
      source,
    };
    await queue.add(PLUGIN_INSTALL_JOB_NAME, job, {
      jobId: row.id,
      priority: tier === "free" ? 2 : 1,
    });

    const body: PluginInstallResponse = { installId: row.id, status: "queued" };
    return reply.code(202).send(body);
  });

  app.patch("/plugins/:id/config", async (request, reply) => {
    const { uid } = request.principal;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return pluginNotFound(reply);

    const row = await pluginsRepo.get(deps.db, id, uid);
    if (row === null) return pluginNotFound(reply);
    if (deps.crypto === undefined) {
      return sendError(reply, 503, "unavailable", "Plugin config sealing is not configured.");
    }

    const parsed = configBodySchema.safeParse(request.body);
    if (!parsed.success) return zodBadRequest(reply, parsed.error);

    // Seal, never persist plaintext and never echo the values.
    const sealed = deps.crypto.encrypt(
      JSON.stringify(parsed.data.config),
      `plugins:${row.id}`,
    );
    // Re-read the CURRENT status immediately before the write: the worker
    // owns status transitions, so writing the status read above could clobber
    // one (e.g. queued → installing) that landed while we sealed.
    const current = await pluginsRepo.get(deps.db, row.id, uid);
    if (current === null) return pluginNotFound(reply);
    await pluginsRepo.setStatus(deps.db, row.id, uid, current.status, { configSealed: sealed });

    const updated = await pluginsRepo.get(deps.db, row.id, uid);
    return toDto(updated ?? current);
  });

  app.delete("/plugins/:id", async (request, reply) => {
    const { uid } = request.principal;
    const { id } = request.params as { id: string };
    if (!isUuid(id)) return pluginNotFound(reply);

    // Carry 6: ownership FIRST — a foreign/unknown id is a 404 and must never
    // enqueue an uninstall job.
    const row = await pluginsRepo.get(deps.db, id, uid);
    if (row === null) return pluginNotFound(reply);

    const queue = deps.queues.pluginInstalls;
    if (queue === undefined) {
      return sendError(reply, 503, "unavailable", "Plugin installs are not configured.");
    }

    // Tier is re-read at request time (a downgraded user gets Free priority).
    const tier = await users.getTier(deps.db, uid);
    const installId = newId();

    await pluginsRepo.setStatus(deps.db, row.id, uid, "uninstalling");

    const job: PluginInstallJob = {
      installId,
      userId: uid,
      pluginId: row.pluginId,
      mode: "uninstall",
    };
    await queue.add(PLUGIN_INSTALL_JOB_NAME, job, {
      jobId: installId,
      priority: tier === "free" ? 2 : 1,
    });

    const body: PluginInstallResponse = { installId, status: "queued" };
    return reply.code(202).send(body);
  });
}
