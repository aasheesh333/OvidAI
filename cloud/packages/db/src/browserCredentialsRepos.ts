import { and, asc, eq, sql } from "drizzle-orm";

import type { Db } from "./client.js";
import {
  browserCredentials as browserCredentialsTable,
  type SealedEnvelope,
} from "./schema.js";

/**
 * Wave 6 W4 — owner-scoped browser Credentials Vault repository.
 *
 * Two projections:
 *  - metadata (list/get) NEVER selects the sealed columns: the gateway and
 *    the agent's list tool can only ever see label/site/username/kind.
 *  - resolve selects the envelopes for the worker's server-side login fill;
 *    decryption happens there under the row's AAD (`browser_credentials:{id}`).
 *
 * Every read/write filters by userId. Wrong owner and unknown id are
 * indistinguishable (both null / false).
 */

export interface BrowserCredentialMetadata {
  id: string;
  label: string;
  site: string;
  username: string;
  secretKind: "password" | "token";
  hasNotes: boolean;
  createdAt: Date;
  updatedAt: Date;
}

export interface BrowserCredentialRow extends BrowserCredentialMetadata {
  userId: string;
  secretSealed: SealedEnvelope;
  notesSealed: SealedEnvelope | null;
}

export interface BrowserCredentialInsert {
  id: string;
  userId: string;
  label: string;
  site: string;
  username: string;
  secretKind: "password" | "token";
  secretSealed: SealedEnvelope;
  notesSealed?: SealedEnvelope | null;
}

export interface BrowserCredentialPatch {
  label?: string;
  site?: string;
  username?: string;
  secretKind?: "password" | "token";
  secretSealed?: SealedEnvelope;
  notesSealed?: SealedEnvelope | null;
}

function metadata(row: {
  id: string;
  label: string;
  site: string;
  username: string;
  secretKind: string;
  notesSealed: SealedEnvelope | null;
  createdAt: Date;
  updatedAt: Date;
}): BrowserCredentialMetadata {
  return {
    id: row.id,
    label: row.label,
    site: row.site,
    username: row.username,
    secretKind: row.secretKind === "token" ? "token" : "password",
    hasNotes: row.notesSealed !== null && row.notesSealed !== undefined,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  };
}

export const browserCredentialsRepo = {
  /** Metadata only, newest first. Never selects a sealed column. */
  async list(db: Db, userId: string): Promise<BrowserCredentialMetadata[]> {
    const rows = await db
      .select({
        id: browserCredentialsTable.id,
        label: browserCredentialsTable.label,
        site: browserCredentialsTable.site,
        username: browserCredentialsTable.username,
        secretKind: browserCredentialsTable.secretKind,
        notesSealed: browserCredentialsTable.notesSealed,
        createdAt: browserCredentialsTable.createdAt,
        updatedAt: browserCredentialsTable.updatedAt,
      })
      .from(browserCredentialsTable)
      .where(eq(browserCredentialsTable.userId, userId))
      .orderBy(asc(browserCredentialsTable.label));
    return rows.map(metadata);
  },

  async count(db: Db, userId: string): Promise<number> {
    const [row] = await db
      .select({ n: sql<number>`count(*)::int` })
      .from(browserCredentialsTable)
      .where(eq(browserCredentialsTable.userId, userId));
    return row?.n ?? 0;
  },

  async get(db: Db, userId: string, id: string): Promise<BrowserCredentialRow | null> {
    const [row] = await db
      .select()
      .from(browserCredentialsTable)
      .where(and(eq(browserCredentialsTable.userId, userId), eq(browserCredentialsTable.id, id)));
    if (row === undefined) return null;
    return {
      ...metadata(row),
      userId: row.userId,
      secretSealed: row.secretSealed,
      notesSealed: row.notesSealed ?? null,
    };
  },

  async create(db: Db, input: BrowserCredentialInsert): Promise<BrowserCredentialRow> {
    const [row] = await db
      .insert(browserCredentialsTable)
      .values({
        id: input.id,
        userId: input.userId,
        label: input.label,
        site: input.site,
        username: input.username,
        secretKind: input.secretKind,
        secretSealed: input.secretSealed,
        notesSealed: input.notesSealed ?? null,
      })
      .returning();
    if (row === undefined) throw new Error("browser credential insert returned no row");
    return {
      ...metadata(row),
      userId: row.userId,
      secretSealed: row.secretSealed,
      notesSealed: row.notesSealed ?? null,
    };
  },

  async update(
    db: Db,
    userId: string,
    id: string,
    patch: BrowserCredentialPatch,
  ): Promise<BrowserCredentialRow | null> {
    const values: Record<string, unknown> = { updatedAt: new Date() };
    if (patch.label !== undefined) values.label = patch.label;
    if (patch.site !== undefined) values.site = patch.site;
    if (patch.username !== undefined) values.username = patch.username;
    if (patch.secretKind !== undefined) values.secretKind = patch.secretKind;
    if (patch.secretSealed !== undefined) values.secretSealed = patch.secretSealed;
    if (patch.notesSealed !== undefined) values.notesSealed = patch.notesSealed;

    const [row] = await db
      .update(browserCredentialsTable)
      .set(values)
      .where(and(eq(browserCredentialsTable.userId, userId), eq(browserCredentialsTable.id, id)))
      .returning();
    if (row === undefined) return null;
    return {
      ...metadata(row),
      userId: row.userId,
      secretSealed: row.secretSealed,
      notesSealed: row.notesSealed ?? null,
    };
  },

  async remove(db: Db, userId: string, id: string): Promise<boolean> {
    const rows = await db
      .delete(browserCredentialsTable)
      .where(and(eq(browserCredentialsTable.userId, userId), eq(browserCredentialsTable.id, id)))
      .returning({ id: browserCredentialsTable.id });
    return rows.length > 0;
  },
};
