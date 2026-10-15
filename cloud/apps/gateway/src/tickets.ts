import { randomBytes } from "node:crypto";
import type { Redis } from "ioredis";

export interface TicketStore {
  /** Mint a single-use ticket bound to `uid`, valid for TICKET_TTL_SECONDS. */
  mint(uid: string): Promise<string>;
  /** Consume a ticket: returns its uid exactly once, null afterwards. */
  verify(ticket: string): Promise<{ uid: string } | null>;
}

export const TICKET_TTL_SECONDS = 60;

// 32 bytes = 256 bits of entropy, rendered as 43-char base64url (unguessable
// tickets; the charset is URL-safe so ?ticket= needs no escaping).
const TICKET_BYTES = 32;

const ticketKey = (ticket: string): string => `ws:ticket:${ticket}`;

// Atomic get-and-delete in one Lua script: two racing verifies of the same
// ticket are serialized by redis, so exactly one sees the value and the key
// is gone before the other runs — a ticket can never be double-spent.
// (Same semantics as GETDEL, which needs redis ≥ 6.2.)
const CONSUME_TICKET_LUA = `
local uid = redis.call('GET', KEYS[1])
if uid then
  redis.call('DEL', KEYS[1])
end
return uid
`;

export function createTicketStore(redis: Redis): TicketStore {
  return {
    async mint(uid) {
      const ticket = randomBytes(TICKET_BYTES).toString("base64url");
      await redis.set(ticketKey(ticket), uid, "EX", TICKET_TTL_SECONDS);
      return ticket;
    },
    async verify(ticket) {
      const uid = (await redis.eval(
        CONSUME_TICKET_LUA,
        1,
        ticketKey(ticket),
      )) as string | null;
      return uid === null ? null : { uid };
    },
  };
}
