import type { FastifyReply, FastifyRequest } from "fastify";

/**
 * The one authentication fence shared by every internal file-service route.
 * The gateway has already verified the user and session ownership; a PAT is
 * neither accepted nor required on this hop.
 */
export function createInternalServiceAuth(internalToken: string) {
  return async function internalServicePreHandler(
    req: FastifyRequest,
    reply: FastifyReply,
  ): Promise<FastifyReply | undefined> {
    const token = req.headers["x-ovid-internal-token"];
    if (typeof token !== "string" || token !== internalToken) {
      return reply.code(401).send({
        error: { code: "unauthenticated", message: "Missing or invalid internal token." },
      });
    }
    const userId = req.headers["x-ovid-user-id"];
    if (typeof userId !== "string" || userId.trim() === "") {
      return reply.code(401).send({
        error: { code: "unauthenticated", message: "Missing x-ovid-user-id." },
      });
    }
    return undefined;
  };
}
