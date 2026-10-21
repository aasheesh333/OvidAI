-- Explicit, additive migration for the collaboration contract: single-sender
-- turn locks, creator-paid storage accounting, session foreign keys and the
-- 50-member invite capacity. Apply in the same schema as account_deletions.
--
-- Equivalent to server/collaboration/schema_extensions.sql; keep both in sync.
-- Re-applying is a no-op. Run explicitly; services never perform startup DDL.
BEGIN;

CREATE TABLE IF NOT EXISTS collab_turns (
    session_id text PRIMARY KEY,
    uid text NOT NULL,
    participant_id text NOT NULL,
    generation bigint NOT NULL CHECK (generation > 0),
    acquired_at double precision NOT NULL,
    expires_at double precision NOT NULL
);
-- Account cleanup and participant revocation delete turns by uid.
CREATE INDEX IF NOT EXISTS collab_turns_uid ON collab_turns(uid);

CREATE TABLE IF NOT EXISTS collab_storage_files (
    file_id text PRIMARY KEY,
    session_id text NOT NULL,
    uploader_uid text NOT NULL,
    owner_uid text NOT NULL,
    size bigint NOT NULL CHECK (size >= 0),
    created_at double precision NOT NULL
);
CREATE INDEX IF NOT EXISTS collab_storage_files_owner ON collab_storage_files(owner_uid);
-- Session deletion and tombstone cleanup scan by session.
CREATE INDEX IF NOT EXISTS collab_storage_files_session ON collab_storage_files(session_id);

-- Exactly one quota row per creator. A member upload updates this row; it never
-- creates a row of its own.
CREATE TABLE IF NOT EXISTS collab_storage_usage (
    owner_uid text PRIMARY KEY,
    bytes bigint NOT NULL CHECK (bytes >= 0),
    files bigint NOT NULL CHECK (files >= 0),
    updated_at double precision NOT NULL
);

-- Child rows must belong to a real session. Constraints are added separately
-- from CREATE TABLE so an existing deployment adopts them without rebuilding
-- tables. Both names are stable so re-running this file is a no-op.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'collab_turns_session_fk'
          AND conrelid = 'collab_turns'::regclass
    ) THEN
        ALTER TABLE collab_turns
            ADD CONSTRAINT collab_turns_session_fk
            FOREIGN KEY (session_id) REFERENCES collab_sessions(session_id)
            ON DELETE CASCADE;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'collab_storage_files_session_fk'
          AND conrelid = 'collab_storage_files'::regclass
    ) THEN
        ALTER TABLE collab_storage_files
            ADD CONSTRAINT collab_storage_files_session_fk
            FOREIGN KEY (session_id) REFERENCES collab_sessions(session_id)
            ON DELETE CASCADE;
    END IF;
END
$$;

-- The 50-member cap needs a link invite that can admit the whole session. The
-- historical account bootstrap declared 1..9; replace it on every deployment.
ALTER TABLE collab_invites DROP CONSTRAINT IF EXISTS collab_invites_max_uses_check;
ALTER TABLE collab_invites ADD CONSTRAINT collab_invites_max_uses_check
    CHECK (max_uses BETWEEN 1 AND 50);

COMMIT;
