ALTER TABLE "users" ADD COLUMN "sandbox_uid" integer;--> statement-breakpoint
ALTER TABLE "users" ADD CONSTRAINT "users_sandbox_uid_unique" UNIQUE("sandbox_uid");--> statement-breakpoint
-- Per-user sandbox uid pool. drizzle-kit does not emit sequences, so this is
-- hand-added (see repos.ts users.allocateSandboxUid). The block is PINNED TO
-- PRODUCTION (spec §11: 200000–209999): staging (P10) instead sets
-- OVID_SANDBOX_UID_BASE=220000 and hash-allocates its sandbox uids — it never
-- touches this sequence, which is why it is not OWNED BY users.sandbox_uid
-- and why the config-level uid range is base-relative so staging validates.
CREATE SEQUENCE users_sandbox_uid_seq START WITH 200000 MINVALUE 200000 MAXVALUE 209999;
