-- Explicit, idempotent PostgreSQL live-collaboration migration. Apply in the
-- same schema as account_deletions. Equivalent to schema_collaboration.sql.
CREATE TABLE IF NOT EXISTS collab_accounts (uid text PRIMARY KEY);
CREATE TABLE IF NOT EXISTS collab_sessions (
    session_id text PRIMARY KEY, token_hash text NOT NULL UNIQUE,
    owner_uid text NOT NULL, request_id text NOT NULL,
    lifecycle text NOT NULL CHECK (lifecycle IN ('active','closing','closed')),
    generation bigint NOT NULL CHECK (generation > 0),
    next_sequence bigint NOT NULL CHECK (next_sequence > 0),
    created_at double precision NOT NULL, closed_at double precision,
    UNIQUE(owner_uid, request_id)
);
CREATE TABLE IF NOT EXISTS collab_memberships (
    session_id text NOT NULL, uid text NOT NULL, participant_id text NOT NULL,
    role text NOT NULL CHECK (role IN ('owner','participant')),
    status text NOT NULL CHECK (status IN ('active','left','revoked')),
    generation bigint NOT NULL, revoked_generation bigint,
    joined_order bigint NOT NULL, created_at double precision NOT NULL,
    updated_at double precision NOT NULL, revoked_at double precision,
    cursor_epoch bigint NOT NULL DEFAULT 1 CHECK (cursor_epoch > 0),
    PRIMARY KEY(session_id, uid), UNIQUE(session_id, participant_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS collab_one_owner ON collab_memberships(session_id) WHERE role='owner';
CREATE INDEX IF NOT EXISTS collab_memberships_uid ON collab_memberships(uid);
CREATE TABLE IF NOT EXISTS collab_invites (
    invite_id text PRIMARY KEY, session_id text NOT NULL,
    code_hash text NOT NULL UNIQUE, issued_generation bigint NOT NULL,
    max_uses integer NOT NULL CHECK (max_uses BETWEEN 1 AND 9),
    uses integer NOT NULL DEFAULT 0 CHECK (uses >= 0 AND uses <= max_uses),
    revoked integer NOT NULL DEFAULT 0 CHECK (revoked IN (0,1)),
    created_at double precision NOT NULL, expires_at double precision NOT NULL
);
CREATE INDEX IF NOT EXISTS collab_invites_session ON collab_invites(session_id);
CREATE TABLE IF NOT EXISTS collab_invite_requests (
    session_id text NOT NULL, owner_uid text NOT NULL, request_id text NOT NULL,
    invite_id text NOT NULL UNIQUE, PRIMARY KEY(session_id, owner_uid, request_id)
);
CREATE TABLE IF NOT EXISTS collab_events (
    session_id text NOT NULL, sequence bigint NOT NULL CHECK (sequence > 0),
    event_id text NOT NULL, sender_participant_id text NOT NULL, kind text NOT NULL,
    envelope text NOT NULL, fingerprint text NOT NULL, size bigint NOT NULL,
    created_at double precision NOT NULL,
    PRIMARY KEY(session_id, sequence), UNIQUE(session_id, event_id)
);
CREATE INDEX IF NOT EXISTS collab_events_window ON collab_events(session_id, created_at);
CREATE TABLE IF NOT EXISTS collab_requests (
    session_id text NOT NULL, uid text NOT NULL, operation text NOT NULL,
    request_id text NOT NULL, fingerprint text NOT NULL,
    membership_epoch bigint NOT NULL, result text NOT NULL,
    PRIMARY KEY(session_id, uid, operation, request_id)
);
CREATE INDEX IF NOT EXISTS collab_requests_uid ON collab_requests(uid);
CREATE INDEX IF NOT EXISTS collab_invite_requests_uid ON collab_invite_requests(owner_uid);
CREATE TABLE IF NOT EXISTS collab_rates (
    session_id text NOT NULL, operation text NOT NULL, created_at double precision NOT NULL
);
CREATE INDEX IF NOT EXISTS collab_rates_window ON collab_rates(session_id, operation, created_at);
CREATE INDEX IF NOT EXISTS collab_rates_expiry ON collab_rates(created_at);
CREATE TABLE IF NOT EXISTS deleted_accounts (uid text PRIMARY KEY);
CREATE TABLE IF NOT EXISTS deleted_sessions (
    session_id text PRIMARY KEY, token_hash text NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS collab_secrets (name text PRIMARY KEY, secret text NOT NULL);
INSERT INTO collab_secrets VALUES ('cursor',
    replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
    ON CONFLICT DO NOTHING;
INSERT INTO collab_secrets VALUES ('authority', 'collaboration:postgres:' || gen_random_uuid()::text)
    ON CONFLICT DO NOTHING;
