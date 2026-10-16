import type { Db } from "@ovid/db";
import type { EventLog } from "@ovid/events";
import type { AgentRunJob, QueueServices } from "@ovid/queue";
import type { KeyProvider, MintProvisioner } from "@ovid/shared";
import type { Verifier } from "../auth.js";
import type { TicketStore } from "../tickets.js";

/**
 * Stub deps for buildGateway() route tests (Fastify inject — no listening,
 * no real Redis/queue; Postgres IS real, see src/test/db.ts).
 */

/**
 * Verifier stub accepting Task 6's `test:<uid>` token shape, but WITH an
 * email (`<uid>@stub.test`) so users.ensure(principal) is assertable.
 */
export function stubVerifier(): Verifier {
  return async (idToken) => {
    const match = /^test:(\S+)$/.exec(idToken);
    if (match === null) throw new Error(`stub verifier rejected token: ${idToken}`);
    const uid = match[1]!;
    return { uid, email: `${uid}@stub.test`, authTime: 1_700_000_000 };
  };
}

export function authHeaders(uid: string, appCheck: string | null = "app-check-stub"): Record<string, string> {
  const headers: Record<string, string> = { authorization: `Bearer test:${uid}` };
  if (appCheck !== null) headers["x-firebase-appcheck"] = appCheck;
  return headers;
}

export interface QueueAdd {
  name: string;
  data: AgentRunJob;
  opts: { jobId?: string; priority?: number } & Record<string, unknown>;
}

/**
 * QueueServices stub capturing every add(name, data, opts). `failAdd` makes
 * add() reject (503 path); the `client`/ping surface satisfies the health
 * route's redisQ probe.
 */
export function stubQueues(behavior: { failAdd?: boolean } = {}): {
  queues: QueueServices;
  adds: QueueAdd[];
} {
  const adds: QueueAdd[] = [];
  const queues = {
    agentRuns: {
      add: async (name: string, data: AgentRunJob, opts?: Record<string, unknown>) => {
        if (behavior.failAdd) throw new Error("queue redis unreachable");
        adds.push({ name, data, opts: (opts ?? {}) as QueueAdd["opts"] });
        return { id: String(opts?.jobId ?? ""), name, data };
      },
      client: Promise.resolve({ ping: async () => "PONG" }),
    },
  } as unknown as QueueServices;
  return { queues, adds };
}

export interface MintStub extends MintProvisioner {
  calls: Array<{ idToken: string; appCheck: string | null }>;
}

/** MintProvisioner stub; `throws` (any value) makes ensureKey reject with it. */
export function stubMint(behavior: { throws?: unknown } = {}): MintStub {
  const calls: MintStub["calls"] = [];
  return {
    calls,
    async ensureKey(idToken, appCheck) {
      calls.push({ idToken, appCheck });
      if (behavior.throws !== undefined) throw behavior.throws;
      return { key: "sk-stub" };
    },
  };
}

export function stubKeys(value: string | null = "sk-stub"): KeyProvider {
  return { getKeyForUser: async () => value };
}

export interface TicketStub extends TicketStore {
  minted: Array<{ uid: string; ticket: string }>;
}

export function stubTickets(behavior: { failMint?: boolean } = {}): TicketStub {
  const minted: TicketStub["minted"] = [];
  return {
    minted,
    async mint(uid) {
      if (behavior.failMint) throw new Error("ticket redis boom");
      const ticket = `ticket-${uid}-${minted.length}`;
      minted.push({ uid, ticket });
      return ticket;
    },
    async verify(ticket) {
      const hit = minted.find((m) => m.ticket === ticket);
      return hit ? { uid: hit.uid } : null;
    },
  };
}

/** Minimal non-db-touching Db stand-in for tests that never hit the database. */
export const noopDb = {} as unknown as Db;

/**
 * EventLog stand-in for REST-only tests: buildGateway registers the WS route
 * unconditionally, but inject() tests never upgrade a socket, so the log is
 * never touched.
 */
export const noopEvents = {} as unknown as EventLog;
