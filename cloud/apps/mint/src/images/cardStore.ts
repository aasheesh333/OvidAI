import { randomBytes } from "node:crypto";
import { exactSum, money, type Money } from "@ovid/money";
import type { Db } from "@ovid/db";
import type { Card } from "./capabilities.js";

/**
 * Postgres port of server/images/cardstore.py.
 *
 * Same semantics as the SQLite store: the full card JSON is the durable
 * truth, every put appends history, probe accounting is exact decimal text
 * (never a SQL float SUM), and probe backoff state is one row per model.
 *
 * Queries go through the postgres.js handle (`db.$client.unsafe`) because
 * @ovid/mint does not depend on drizzle-orm directly; the schema itself is
 * owned by @ovid/db (`image_cards*` tables).
 */

export interface ProbeState {
  attempts: number;
  nextAttemptAt: number;
  lastError: string | null;
}

export interface CardStore {
  get(model: string): Promise<Card | null>;
  all(): Promise<Card[]>;
  put(card: Card): Promise<void>;
  history(model: string, limit?: number): Promise<{ fingerprint: string; state: string; at: number }[]>;
  logProbe(
    model: string,
    probe: string,
    ok: boolean,
    errorClass: string | null,
    latencyMs: number | null,
    costUsd: Money,
  ): Promise<void>;
  spentSince(epoch: number): Promise<Money>;
  probeState(model: string): Promise<ProbeState>;
  setProbeState(
    model: string,
    attempts: number,
    nextAttemptAt: number,
    lastError?: string | null,
  ): Promise<void>;
}

/** UUIDv7 (time-ordered) for image_card_history/image_probe_log ids. */
function uuidv7(now: Date): string {
  const ts = BigInt(now.getTime());
  const bytes = randomBytes(16);
  bytes[0] = Number((ts >> 40n) & 0xffn);
  bytes[1] = Number((ts >> 32n) & 0xffn);
  bytes[2] = Number((ts >> 24n) & 0xffn);
  bytes[3] = Number((ts >> 16n) & 0xffn);
  bytes[4] = Number((ts >> 8n) & 0xffn);
  bytes[5] = Number(ts & 0xffn);
  bytes[6] = (bytes[6]! & 0x0f) | 0x70; // version 7
  bytes[8] = (bytes[8]! & 0x3f) | 0x80; // RFC 4122 variant
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(
    16,
    20,
  )}-${hex.slice(20)}`;
}

interface CardRow {
  card: Card;
}

export function createCardStore(
  db: Db,
  clock: () => number = () => Date.now() / 1000,
): CardStore {
  const sql = db.$client;

  return {
    async get(model: string): Promise<Card | null> {
      const rows = await sql.unsafe<CardRow[]>(
        "SELECT card FROM image_cards WHERE model = $1",
        [model],
      );
      return rows.length > 0 ? rows[0]!.card : null;
    },

    async all(): Promise<Card[]> {
      const rows = await sql.unsafe<CardRow[]>(
        "SELECT card FROM image_cards ORDER BY model",
      );
      return rows.map((row) => row.card);
    },

    async put(card: Card): Promise<void> {
      const now = Math.trunc(clock());
      const blob = JSON.stringify(card);
      const historyId = uuidv7(new Date(now * 1000));
      await sql.begin(async (tx) => {
        await tx.unsafe(
          `INSERT INTO image_cards(model,fingerprint,state,card,priced,edit_transport,updated_at,probed_at)
           VALUES($1,$2,$3,$4::jsonb,$5,$6,$7,$8)
           ON CONFLICT(model) DO UPDATE SET fingerprint=excluded.fingerprint,
             state=excluded.state, card=excluded.card, priced=excluded.priced,
             edit_transport=excluded.edit_transport, updated_at=excluded.updated_at,
             probed_at=excluded.probed_at`,
          [
            card.model,
            card.fingerprint,
            card.state,
            blob,
            card.priced ?? null,
            card.edit_transport ?? null,
            now,
            card.probed_at ?? null,
          ],
        );
        await tx.unsafe(
          `INSERT INTO image_card_history(id,model,fingerprint,state,card,at)
           VALUES($1,$2,$3,$4,$5::jsonb,$6)`,
          [historyId, card.model, card.fingerprint, card.state, blob, now],
        );
      });
    },

    async history(model: string, limit = 20) {
      const rows = await sql.unsafe<
        { fingerprint: string; state: string; at: number }[]
      >(
        `SELECT fingerprint,state,at FROM image_card_history
         WHERE model = $1 ORDER BY id DESC LIMIT $2`,
        [model, limit],
      );
      return rows.map((row) => ({
        fingerprint: row.fingerprint,
        state: row.state,
        at: Number(row.at),
      }));
    },

    async logProbe(
      model: string,
      probe: string,
      ok: boolean,
      errorClass: string | null,
      latencyMs: number | null,
      costUsd: Money,
    ): Promise<void> {
      const id = uuidv7(new Date(Math.trunc(clock()) * 1000));
      await sql.unsafe(
        `INSERT INTO image_probe_log(id,model,probe,ok,error_class,latency_ms,cost_usd,at)
         VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,
        [
          id,
          model,
          probe,
          ok,
          errorClass,
          latencyMs,
          costUsd.toString(),
          Math.trunc(clock()),
        ],
      );
    },

    async spentSince(epoch: number): Promise<Money> {
      const rows = await sql.unsafe<{ cost_usd: string }[]>(
        "SELECT cost_usd FROM image_probe_log WHERE at >= $1",
        [Math.trunc(epoch)],
      );
      // Exact decimal sum over the text column — never SQL SUM(float).
      return exactSum(rows.map((row) => money(String(row.cost_usd))));
    },

    async probeState(model: string): Promise<ProbeState> {
      const rows = await sql.unsafe<
        { attempts: number; next_attempt_at: number; last_error: string | null }[]
      >(
        "SELECT attempts,next_attempt_at,last_error FROM image_probe_state WHERE model = $1",
        [model],
      );
      if (rows.length === 0) {
        return { attempts: 0, nextAttemptAt: 0, lastError: null };
      }
      return {
        attempts: Number(rows[0]!.attempts),
        nextAttemptAt: Number(rows[0]!.next_attempt_at),
        lastError: rows[0]!.last_error ?? null,
      };
    },

    async setProbeState(
      model: string,
      attempts: number,
      nextAttemptAt: number,
      lastError: string | null = null,
    ): Promise<void> {
      await sql.unsafe(
        `INSERT INTO image_probe_state(model,attempts,next_attempt_at,last_error)
         VALUES($1,$2,$3,$4)
         ON CONFLICT(model) DO UPDATE SET attempts=excluded.attempts,
           next_attempt_at=excluded.next_attempt_at, last_error=excluded.last_error`,
        [model, attempts, Math.trunc(nextAttemptAt), lastError],
      );
    },
  };
}
