// Postgres SessionStateStore (P3 Task 13) — the thin typed seam over @ovid/db's
// sessionState repo. The worker wires createDb() once and hands every session
// this store; T1's createMemoryStateStore stays the test/dev fake.
//
// SEMANTICS (defined here, pinned by @ovid/db's repos.search.test.ts):
//   get(sessionId)   → sessionState.get(db, sessionId): a PURE read — a
//                      missing row answers the Task-1 zero state WITHOUT
//                      materializing anything (the fake materializes-and-
//                      caches; Postgres never writes on read).
//   patch(sessionId) → sessionState.patch(db, sessionId, p): an atomic jsonb
//                      upsert; top-level keys replace wholesale (Object.assign
//                      semantics — arrays replace wholesale, siblings survive).
//                      Patching an unknown session raises the sessions FK
//                      violation — loud, never a silent zero row.

import { sessionState, type Db } from "@ovid/db";

import type { SessionAgentState, SessionStateStore } from "./ports.js";

/** The Postgres-backed store. One instance per process (Db is shared). */
export function createPostgresSessionStateStore(db: Db): SessionStateStore {
  return {
    async get(sessionId: string): Promise<SessionAgentState> {
      return sessionState.get(db, sessionId);
    },
    async patch(sessionId: string, p: Partial<SessionAgentState>): Promise<void> {
      await sessionState.patch(db, sessionId, p);
    },
  };
}
