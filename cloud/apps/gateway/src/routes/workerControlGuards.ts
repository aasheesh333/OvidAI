import type { FastifyReply } from "fastify";
import type { Db } from "@ovid/db";

import { sendError } from "./http.js";

/** True for the initial run AND every current/follow-up turn of a durable child. */
export async function isDurableWorkerRun(db: Db, runId: string): Promise<boolean> {
  const rows = await db.$client<{ present: number }[]>`
    SELECT 1 AS present
      FROM runs r
      JOIN subagent_attempts a ON a.child_session_id = r.session_id
     WHERE r.id = ${runId}
     LIMIT 1`;
  return rows.length > 0;
}

/** True only for sessions owned by a durable logical worker, not its main parent. */
export async function isDurableWorkerSession(db: Db, sessionId: string): Promise<boolean> {
  const rows = await db.$client<{ present: number }[]>`
    SELECT 1 AS present FROM subagent_logical_workers WHERE child_session_id = ${sessionId} LIMIT 1`;
  return rows.length > 0;
}

/** Generic authenticated routes must never become public worker lifecycle controls. */
export function refusePublicWorkerControl(reply: FastifyReply): FastifyReply {
  return sendError(
    reply,
    403,
    "worker_control_main_only",
    "Worker lifecycle is controlled only by the main agent.",
  );
}
