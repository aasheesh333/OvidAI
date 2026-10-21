-- PostgreSQL authority for the IP-hop guard.
--
-- PostgresIpHopStore applies this DDL automatically when ensure_schema is
-- enabled (the default).  The file is idempotent and can also be applied by an
-- operator before the application starts:
--
--   psql "$IP_HOP_DATABASE_URL" -f server/security/schema_postgres.sql
--
-- Timestamps and distances are DOUBLE PRECISION Unix seconds / kilometres,
-- matching the SQLite schema.  ``active`` is a BOOLEAN here (SQLite uses 0/1).

CREATE TABLE IF NOT EXISTS ip_hop_observations (
    id BIGSERIAL PRIMARY KEY,
    uid TEXT NOT NULL,
    session_id TEXT NOT NULL,
    ip_prefix TEXT NOT NULL,
    country TEXT,
    asn TEXT,
    city TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    seen_at DOUBLE PRECISION NOT NULL
);
CREATE INDEX IF NOT EXISTS ip_hop_observations_uid_seen
    ON ip_hop_observations (uid, seen_at);
CREATE INDEX IF NOT EXISTS ip_hop_observations_seen
    ON ip_hop_observations (seen_at);

CREATE TABLE IF NOT EXISTS ip_hop_blocks (
    uid TEXT NOT NULL,
    session_id TEXT NOT NULL,
    reason TEXT NOT NULL,
    event_id TEXT NOT NULL,
    blocked_at DOUBLE PRECISION NOT NULL,
    blocked_until DOUBLE PRECISION NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (uid, session_id)
);
CREATE INDEX IF NOT EXISTS ip_hop_blocks_uid_active
    ON ip_hop_blocks (uid, active, blocked_until);

CREATE TABLE IF NOT EXISTS ip_hop_overrides (
    uid TEXT NOT NULL,
    session_id TEXT NOT NULL,
    until_at DOUBLE PRECISION NOT NULL,
    actor TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at DOUBLE PRECISION NOT NULL,
    PRIMARY KEY (uid, session_id)
);

CREATE TABLE IF NOT EXISTS ip_hop_audit (
    id BIGSERIAL PRIMARY KEY,
    event_id TEXT NOT NULL,
    uid TEXT NOT NULL,
    action TEXT NOT NULL,
    reason TEXT NOT NULL,
    actor TEXT,
    session_id TEXT,
    older_session_id TEXT,
    ip_prefix TEXT,
    older_ip_prefix TEXT,
    country TEXT,
    older_country TEXT,
    asn TEXT,
    older_asn TEXT,
    created_at DOUBLE PRECISION NOT NULL
);
CREATE INDEX IF NOT EXISTS ip_hop_audit_uid_created
    ON ip_hop_audit (uid, created_at);

CREATE TABLE IF NOT EXISTS ip_hop_alerts (
    event_key TEXT PRIMARY KEY,
    uid TEXT NOT NULL,
    created_at DOUBLE PRECISION NOT NULL,
    status TEXT NOT NULL
);
