-- SQLite authority for the IP-hop guard. SqliteIpHopStore applies this DDL
-- automatically; the file is the operator-reviewed schema for provisioning.
-- PostgreSQL deployments use schema_postgres.sql and PostgresIpHopStore.

CREATE TABLE IF NOT EXISTS ip_hop_observations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    uid TEXT NOT NULL,
    session_id TEXT NOT NULL,
    ip_prefix TEXT NOT NULL,
    country TEXT,
    asn TEXT,
    city TEXT,
    latitude REAL,
    longitude REAL,
    seen_at REAL NOT NULL
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
    blocked_at REAL NOT NULL,
    blocked_until REAL NOT NULL,
    active INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (uid, session_id)
);
CREATE INDEX IF NOT EXISTS ip_hop_blocks_uid_active
    ON ip_hop_blocks (uid, active, blocked_until);

CREATE TABLE IF NOT EXISTS ip_hop_overrides (
    uid TEXT NOT NULL,
    session_id TEXT NOT NULL,
    until_at REAL NOT NULL,
    actor TEXT NOT NULL,
    reason TEXT NOT NULL,
    created_at REAL NOT NULL,
    PRIMARY KEY (uid, session_id)
);

CREATE TABLE IF NOT EXISTS ip_hop_audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
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
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS ip_hop_audit_uid_created
    ON ip_hop_audit (uid, created_at);

CREATE TABLE IF NOT EXISTS ip_hop_alerts (
    event_key TEXT PRIMARY KEY,
    uid TEXT NOT NULL,
    created_at REAL NOT NULL,
    status TEXT NOT NULL
);
