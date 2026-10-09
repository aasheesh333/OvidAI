-- Explicit, additive migration for private account sync.
-- Spec: docs/superpowers/specs/2026-10-08-private-account-sync-design.md
--       docs/superpowers/specs/2026-10-08-device-activity-feed-design.md
-- Plan: docs/superpowers/plans/2026-10-08-private-account-sync.md (Task S2)
--
-- Only creates objects; never rewrites or removes existing account rows.
-- Re-applying is a no-op. Requires PostgreSQL 11+ (sha256(), EXECUTE FUNCTION).
-- Run explicitly; the service never performs startup DDL.
--
-- Conventions (match account_deletions):
--   * account_id is the verified account UID (text), never client-submitted.
--   * *_at columns are epoch seconds (double precision) from the injected clock.
--   * Opaque IDs are ASCII, 1..128 bytes (octet_length = char_length on UTF-8).
--   * No credential, token, cookie, authorization, grant, or local-path column
--     exists in any sync table. Transcript content lives only in canonical bytes.
--   * Every table's primary key starts with account_id so account cleanup and
--     per-account locking are index-driven.
BEGIN;

-- §Deletion, cache invalidation, and tombstones; §API contract (fences).
-- One row per account that has used sync. state='deleted' is the permanent
-- account tombstone that rejects late requests after cleanup; it is never
-- updated or removed (guarded by trigger below).
CREATE TABLE IF NOT EXISTS sync_accounts (
    account_id text PRIMARY KEY
        CHECK (octet_length(account_id) BETWEEN 1 AND 128
               AND octet_length(account_id) = char_length(account_id)),
    state text NOT NULL CHECK (state IN ('active', 'fenced', 'deleted')),
    created_at double precision NOT NULL,
    fenced_at double precision,
    deleted_at double precision,
    CONSTRAINT sync_accounts_fence_consistent CHECK (
        (state = 'active' AND deleted_at IS NULL)
        OR (state = 'fenced' AND fenced_at IS NOT NULL AND deleted_at IS NULL)
        OR (state = 'deleted' AND fenced_at IS NOT NULL AND deleted_at IS NOT NULL))
);

CREATE OR REPLACE FUNCTION sync_accounts_tombstone_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.state = 'deleted' THEN
        RAISE EXCEPTION 'sync account tombstone is permanent'
            USING ERRCODE = 'check_violation';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'sync_accounts_tombstone_guard'
          AND tgrelid = 'sync_accounts'::regclass
    ) THEN
        CREATE TRIGGER sync_accounts_tombstone_guard
            BEFORE UPDATE OR DELETE ON sync_accounts
            FOR EACH ROW EXECUTE FUNCTION sync_accounts_tombstone_guard();
    END IF;
END
$$;

-- §Ordering, conflict handling, and delivery (server change sequence).
-- Per-account allocator: UPDATE ... SET last_change_sequence = last + 1
-- RETURNING under the row lock serializes sequence assignment per account.
CREATE TABLE IF NOT EXISTS sync_sequence_allocators (
    account_id text PRIMARY KEY REFERENCES sync_accounts (account_id),
    last_change_sequence bigint NOT NULL DEFAULT 0
        CHECK (last_change_sequence >= 0)
);

-- §Enrollment, authorization, and revocation.
-- Server-issued opaque device IDs, globally unique and never reused: revoked
-- rows are kept until account cleanup, and the permanent account tombstone
-- prevents the same account from re-enrolling. The 10-active-device limit is
-- enforced by the repository under the account lock; sync_devices_active
-- supports that count.
CREATE TABLE IF NOT EXISTS sync_devices (
    account_id text NOT NULL REFERENCES sync_accounts (account_id),
    device_id text NOT NULL
        CHECK (octet_length(device_id) BETWEEN 1 AND 128
               AND octet_length(device_id) = char_length(device_id)),
    device_label text NOT NULL CHECK (char_length(device_label) BETWEEN 1 AND 128),
    consent_version integer NOT NULL CHECK (consent_version >= 1),
    consented_at double precision NOT NULL,
    created_at double precision NOT NULL,
    revoked_at double precision,
    revocation_kind text CHECK (revocation_kind IN
        ('device', 'lost_device', 'account_security', 'account_deletion')),
    PRIMARY KEY (account_id, device_id),
    CONSTRAINT sync_devices_device_id_unique UNIQUE (device_id),
    CONSTRAINT sync_devices_revocation_consistent CHECK (
        (revoked_at IS NULL) = (revocation_kind IS NULL)),
    CONSTRAINT sync_devices_revoked_after_created CHECK (
        revoked_at IS NULL OR revoked_at >= created_at)
);
CREATE INDEX IF NOT EXISTS sync_devices_active
    ON sync_devices (account_id, created_at)
    WHERE revoked_at IS NULL;

-- §Normative v1 wire contract; §Ordering, conflict handling; §Exact quotas.
-- Current state per (account_id, record_id). canonical_bytes is the RFC 8785
-- UTF-8 DTO exactly as replayed (never re-serialized through JSONB). A
-- tombstoned target keeps identity and revision (so stale uploads cannot
-- recreate it) but may drop its content bytes. Tombstone records carry
-- target_record_id and always keep their bytes until purge_after.
CREATE TABLE IF NOT EXISTS sync_records (
    account_id text NOT NULL REFERENCES sync_accounts (account_id),
    record_id text NOT NULL
        CHECK (octet_length(record_id) BETWEEN 1 AND 128
               AND octet_length(record_id) = char_length(record_id)),
    record_type text NOT NULL CHECK (record_type IN
        ('transcript', 'providerMetadata', 'usage', 'activity', 'tombstone')),
    schema_version smallint NOT NULL CHECK (schema_version = 1),
    source_device_id text NOT NULL,
    revision bigint NOT NULL CHECK (revision BETWEEN 1 AND 2147483647),
    change_sequence bigint NOT NULL CHECK (change_sequence >= 1),
    conversation_id text
        CHECK (conversation_id IS NULL
               OR (octet_length(conversation_id) BETWEEN 1 AND 128
                   AND octet_length(conversation_id) = char_length(conversation_id))),
    logical_request_id text
        CHECK (logical_request_id IS NULL
               OR (octet_length(logical_request_id) BETWEEN 1 AND 128
                   AND octet_length(logical_request_id) = char_length(logical_request_id))),
    target_record_id text
        CHECK (target_record_id IS NULL
               OR (octet_length(target_record_id) BETWEEN 1 AND 128
                   AND octet_length(target_record_id) = char_length(target_record_id))),
    tombstoned boolean NOT NULL DEFAULT false,
    canonical_bytes bytea,
    canonical_sha256 bytea,
    canonical_length integer,
    accepted_at double precision NOT NULL,
    updated_at double precision NOT NULL,
    purge_after double precision,
    PRIMARY KEY (account_id, record_id),
    CONSTRAINT sync_records_change_sequence_unique UNIQUE (account_id, change_sequence),
    CONSTRAINT sync_records_source_device_fk FOREIGN KEY (account_id, source_device_id)
        REFERENCES sync_devices (account_id, device_id),
    CONSTRAINT sync_records_bytes_present CHECK (tombstoned OR canonical_bytes IS NOT NULL),
    CONSTRAINT sync_records_bytes_consistent CHECK (
        (canonical_bytes IS NULL AND canonical_sha256 IS NULL AND canonical_length IS NULL)
        OR (canonical_bytes IS NOT NULL
            AND canonical_length = octet_length(canonical_bytes)
            AND canonical_length BETWEEN 1 AND 262144
            AND canonical_sha256 = sha256(canonical_bytes))),
    CONSTRAINT sync_records_tombstone_target CHECK (
        (record_type = 'tombstone') = (target_record_id IS NOT NULL)),
    CONSTRAINT sync_records_tombstone_not_tombstoned CHECK (
        NOT (record_type = 'tombstone' AND tombstoned)),
    CONSTRAINT sync_records_logical_request_typed CHECK (
        logical_request_id IS NULL OR record_type IN ('usage', 'activity')),
    CONSTRAINT sync_records_usage_logical_request CHECK (
        record_type <> 'usage' OR logical_request_id IS NOT NULL),
    CONSTRAINT sync_records_purge_scope CHECK (
        purge_after IS NULL OR record_type = 'tombstone' OR tombstoned)
);
CREATE INDEX IF NOT EXISTS sync_records_conversation
    ON sync_records (account_id, conversation_id, change_sequence)
    WHERE conversation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS sync_records_logical_request
    ON sync_records (account_id, logical_request_id, change_sequence)
    WHERE logical_request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS sync_records_tombstone_target
    ON sync_records (account_id, target_record_id)
    WHERE target_record_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS sync_records_purge_due
    ON sync_records (purge_after, account_id)
    WHERE purge_after IS NOT NULL;
CREATE INDEX IF NOT EXISTS sync_records_activity_compaction
    ON sync_records (account_id, updated_at)
    WHERE record_type = 'activity' AND NOT tombstoned;

-- §Ordering, conflict handling, and delivery; feed §Identity, ordering.
-- Append-only account-scoped log; replay order is change_sequence. Entries
-- reference record/marker state instead of duplicating canonical bytes, so the
-- retained-bytes ledger counts content once. Replay emits a record only at its
-- current sync_records.change_sequence; superseded entries are skipped.
CREATE TABLE IF NOT EXISTS sync_changes (
    account_id text NOT NULL REFERENCES sync_accounts (account_id),
    change_sequence bigint NOT NULL CHECK (change_sequence >= 1),
    change_kind text NOT NULL CHECK (change_kind IN ('record', 'tombstone', 'marker')),
    record_id text,
    revision bigint CHECK (revision IS NULL OR revision BETWEEN 1 AND 2147483647),
    marker_id bigint,
    committed_at double precision NOT NULL,
    PRIMARY KEY (account_id, change_sequence),
    CONSTRAINT sync_changes_subject CHECK (
        (change_kind = 'marker' AND marker_id IS NOT NULL
            AND record_id IS NULL AND revision IS NULL)
        OR (change_kind <> 'marker' AND marker_id IS NULL
            AND record_id IS NOT NULL AND revision IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS sync_changes_record
    ON sync_changes (account_id, record_id, change_sequence)
    WHERE record_id IS NOT NULL;

-- §Ordering, conflict handling ("All mutations require an idempotency key").
-- Keys are account-scoped so enrollment (no device yet) shares the mechanism.
-- request_sha256 detects key reuse with a different request; result_bytes is
-- the canonical per-record result envelope (IDs, revisions, outcome codes; no
-- DTO payloads or transcript text).
CREATE TABLE IF NOT EXISTS sync_idempotency (
    account_id text NOT NULL REFERENCES sync_accounts (account_id),
    idempotency_key text NOT NULL
        CHECK (octet_length(idempotency_key) BETWEEN 1 AND 128
               AND octet_length(idempotency_key) = char_length(idempotency_key)),
    operation text NOT NULL CHECK (operation IN ('upload', 'enroll', 'revoke')),
    device_id text,
    request_sha256 bytea NOT NULL CHECK (octet_length(request_sha256) = 32),
    state text NOT NULL CHECK (state IN ('in_progress', 'completed')),
    result_bytes bytea CHECK (result_bytes IS NULL OR octet_length(result_bytes) <= 1048576),
    created_at double precision NOT NULL,
    expires_at double precision NOT NULL,
    PRIMARY KEY (account_id, idempotency_key),
    CONSTRAINT sync_idempotency_result_state CHECK (
        (state = 'completed') = (result_bytes IS NOT NULL)),
    CONSTRAINT sync_idempotency_expiry CHECK (expires_at > created_at)
);
CREATE INDEX IF NOT EXISTS sync_idempotency_expiry
    ON sync_idempotency (expires_at, account_id);

-- §Exact quotas and codec (10,000 accepted records per rolling 24 hours).
-- One row per accepted record revision; duplicates hit the unique constraint
-- and are not charged twice. The oldest admitted_at in the window gives the
-- quota_exhausted retry time. Rows older than 24 hours are pruned.
CREATE TABLE IF NOT EXISTS sync_ingest_admissions (
    account_id text NOT NULL REFERENCES sync_accounts (account_id),
    change_sequence bigint NOT NULL CHECK (change_sequence >= 1),
    record_id text NOT NULL,
    revision bigint NOT NULL CHECK (revision BETWEEN 1 AND 2147483647),
    canonical_length integer NOT NULL CHECK (canonical_length BETWEEN 1 AND 262144),
    quota_exempt boolean NOT NULL DEFAULT false,
    admitted_at double precision NOT NULL,
    PRIMARY KEY (account_id, change_sequence),
    CONSTRAINT sync_ingest_admissions_revision_unique UNIQUE (account_id, record_id, revision)
);
CREATE INDEX IF NOT EXISTS sync_ingest_admissions_window
    ON sync_ingest_admissions (account_id, admitted_at);

-- §Exact quotas and codec (100 MiB retained canonical bytes per account).
-- Updated in the same transaction as record writes, tombstone purge, and
-- compaction. No upper CHECK: deletion/conflict tombstones stay admissible
-- after exhaustion, so the 104857600-byte limit is an admission rule only.
CREATE TABLE IF NOT EXISTS sync_retained_bytes (
    account_id text PRIMARY KEY REFERENCES sync_accounts (account_id),
    retained_bytes bigint NOT NULL DEFAULT 0 CHECK (retained_bytes >= 0),
    retained_records bigint NOT NULL DEFAULT 0 CHECK (retained_records >= 0),
    updated_at double precision NOT NULL
);

-- §Ordering ("opaque cursor and bounded page"); §Deletion (tombstone horizon).
-- Cursors are positions, not credentials. expires_at is the cursor lease; the
-- tombstone horizon is 30 days after the last cursor whose position precedes
-- the tombstone expires. snapshot_sequence pins a paginated bootstrap.
CREATE TABLE IF NOT EXISTS sync_cursors (
    account_id text NOT NULL REFERENCES sync_accounts (account_id),
    cursor_id text NOT NULL
        CHECK (octet_length(cursor_id) BETWEEN 1 AND 128
               AND octet_length(cursor_id) = char_length(cursor_id)),
    device_id text NOT NULL,
    position bigint NOT NULL CHECK (position >= 0),
    snapshot_sequence bigint CHECK (snapshot_sequence IS NULL OR snapshot_sequence >= 0),
    issued_at double precision NOT NULL,
    last_used_at double precision NOT NULL,
    expires_at double precision NOT NULL,
    PRIMARY KEY (account_id, cursor_id),
    CONSTRAINT sync_cursors_device_fk FOREIGN KEY (account_id, device_id)
        REFERENCES sync_devices (account_id, device_id),
    CONSTRAINT sync_cursors_expiry CHECK (expires_at > issued_at),
    CONSTRAINT sync_cursors_snapshot_order CHECK (
        snapshot_sequence IS NULL OR position <= snapshot_sequence)
);
CREATE INDEX IF NOT EXISTS sync_cursors_horizon
    ON sync_cursors (account_id, position, expires_at);
CREATE INDEX IF NOT EXISTS sync_cursors_expiry
    ON sync_cursors (expires_at, account_id);
CREATE INDEX IF NOT EXISTS sync_cursors_device
    ON sync_cursors (account_id, device_id);

-- Feed §Primary delivery: foreground polling; §SSE optimization;
-- account §Deployment limits (2 streams/account, 1 stream/device).
-- Shared cross-instance leases; revocation and deletion fences invalidate
-- them. Streams close after 15 minutes or 1 MiB total event data.
CREATE TABLE IF NOT EXISTS sync_leases (
    account_id text NOT NULL REFERENCES sync_accounts (account_id),
    lease_id text NOT NULL
        CHECK (octet_length(lease_id) BETWEEN 1 AND 128
               AND octet_length(lease_id) = char_length(lease_id)),
    device_id text NOT NULL,
    lease_kind text NOT NULL CHECK (lease_kind IN ('stream', 'poll')),
    acquired_at double precision NOT NULL,
    renewed_at double precision NOT NULL,
    expires_at double precision NOT NULL,
    event_bytes bigint NOT NULL DEFAULT 0 CHECK (event_bytes >= 0),
    ended_at double precision,
    end_reason text CHECK (end_reason IN
        ('closed', 'expired', 'revoked', 'fenced', 'byte_limit', 'time_limit')),
    PRIMARY KEY (account_id, lease_id),
    CONSTRAINT sync_leases_device_fk FOREIGN KEY (account_id, device_id)
        REFERENCES sync_devices (account_id, device_id),
    CONSTRAINT sync_leases_end_consistent CHECK ((ended_at IS NULL) = (end_reason IS NULL)),
    CONSTRAINT sync_leases_timeline CHECK (
        renewed_at >= acquired_at AND expires_at > acquired_at),
    CONSTRAINT sync_leases_stream_bounds CHECK (
        lease_kind <> 'stream'
        OR (expires_at <= acquired_at + 900 AND event_bytes <= 1048576))
);
CREATE INDEX IF NOT EXISTS sync_leases_open_account
    ON sync_leases (account_id, lease_kind)
    WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS sync_leases_open_device
    ON sync_leases (account_id, device_id, lease_kind)
    WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS sync_leases_expiry
    ON sync_leases (expires_at, account_id)
    WHERE ended_at IS NULL;

-- Account §Deployment: 60 upload/min and 120 replay/min per account;
-- 30 upload/min per device. Fixed 60-second windows shared across instances.
-- device_id is '' for account-scoped windows to keep the key non-null.
CREATE TABLE IF NOT EXISTS sync_rate_windows (
    account_id text NOT NULL REFERENCES sync_accounts (account_id),
    scope text NOT NULL CHECK (scope IN ('account', 'device')),
    device_id text NOT NULL DEFAULT '',
    route_class text NOT NULL CHECK (route_class IN ('upload', 'replay')),
    window_start double precision NOT NULL,
    window_seconds integer NOT NULL DEFAULT 60 CHECK (window_seconds = 60),
    request_count integer NOT NULL DEFAULT 0 CHECK (request_count >= 0),
    PRIMARY KEY (account_id, scope, device_id, route_class, window_start),
    CONSTRAINT sync_rate_windows_scope_device CHECK (
        (scope = 'account' AND device_id = '')
        OR (scope = 'device' AND octet_length(device_id) BETWEEN 1 AND 128
            AND octet_length(device_id) = char_length(device_id))),
    CONSTRAINT sync_rate_windows_limits CHECK (
        (scope = 'account' AND route_class = 'upload' AND request_count <= 60)
        OR (scope = 'account' AND route_class = 'replay' AND request_count <= 120)
        OR (scope = 'device' AND route_class = 'upload' AND request_count <= 30))
);
CREATE INDEX IF NOT EXISTS sync_rate_windows_expiry
    ON sync_rate_windows (window_start, account_id);

-- §Ordering, conflict handling ("hard integrity conflict ... retained for
-- audit/error handling without choosing a winner"). Stores identities,
-- revisions, and digests only; never the conflicting payload or text.
CREATE TABLE IF NOT EXISTS sync_conflicts (
    account_id text NOT NULL REFERENCES sync_accounts (account_id),
    conflict_id bigint GENERATED ALWAYS AS IDENTITY,
    record_id text NOT NULL,
    record_type text NOT NULL CHECK (record_type IN
        ('transcript', 'providerMetadata', 'usage', 'activity', 'tombstone')),
    source_device_id text NOT NULL,
    canonical_revision bigint NOT NULL CHECK (canonical_revision BETWEEN 1 AND 2147483647),
    canonical_sha256 bytea CHECK (canonical_sha256 IS NULL OR octet_length(canonical_sha256) = 32),
    submitted_revision bigint NOT NULL CHECK (submitted_revision BETWEEN 1 AND 2147483647),
    submitted_sha256 bytea NOT NULL CHECK (octet_length(submitted_sha256) = 32),
    submitted_length integer NOT NULL CHECK (submitted_length BETWEEN 1 AND 262144),
    detected_at double precision NOT NULL,
    resolution text NOT NULL DEFAULT 'open' CHECK (resolution IN
        ('open', 'kept_canonical', 'kept_local', 'dismissed')),
    resolved_at double precision,
    PRIMARY KEY (account_id, conflict_id),
    CONSTRAINT sync_conflicts_submission_unique
        UNIQUE (account_id, record_id, submitted_revision, submitted_sha256),
    CONSTRAINT sync_conflicts_resolution_consistent CHECK (
        (resolution = 'open') = (resolved_at IS NULL))
);
CREATE INDEX IF NOT EXISTS sync_conflicts_open
    ON sync_conflicts (account_id, detected_at)
    WHERE resolution = 'open';

-- §Deletion, cache invalidation, and tombstones (compaction and retention
-- actions emit replayable markers, transactional with quota accounting).
-- Each marker is published at its own change_sequence (sync_changes kind
-- 'marker'). activity_compaction rows name the summarized logical request.
CREATE TABLE IF NOT EXISTS sync_retention_markers (
    account_id text NOT NULL REFERENCES sync_accounts (account_id),
    marker_id bigint GENERATED ALWAYS AS IDENTITY,
    marker_kind text NOT NULL CHECK (marker_kind IN
        ('activity_compaction', 'retention_action', 'tombstone_expiry')),
    change_sequence bigint NOT NULL CHECK (change_sequence >= 1),
    through_change_sequence bigint NOT NULL CHECK (through_change_sequence >= 0),
    logical_request_id text
        CHECK (logical_request_id IS NULL
               OR (octet_length(logical_request_id) BETWEEN 1 AND 128
                   AND octet_length(logical_request_id) = char_length(logical_request_id))),
    freed_bytes bigint NOT NULL DEFAULT 0 CHECK (freed_bytes >= 0),
    freed_records integer NOT NULL DEFAULT 0 CHECK (freed_records >= 0),
    canonical_bytes bytea NOT NULL,
    canonical_sha256 bytea NOT NULL,
    canonical_length integer NOT NULL,
    created_at double precision NOT NULL,
    PRIMARY KEY (account_id, marker_id),
    CONSTRAINT sync_retention_markers_change_unique UNIQUE (account_id, change_sequence),
    CONSTRAINT sync_retention_markers_bytes_consistent CHECK (
        canonical_length = octet_length(canonical_bytes)
        AND canonical_length BETWEEN 1 AND 262144
        AND canonical_sha256 = sha256(canonical_bytes)),
    CONSTRAINT sync_retention_markers_through_order CHECK (
        through_change_sequence < change_sequence),
    CONSTRAINT sync_retention_markers_compaction_request CHECK (
        (marker_kind = 'activity_compaction') = (logical_request_id IS NOT NULL))
);

COMMENT ON TABLE sync_accounts IS
    'Private sync spec: Deletion/tombstones + API contract fences. Permanent account tombstone when state=deleted.';
COMMENT ON TABLE sync_sequence_allocators IS
    'Private sync spec: Ordering. Per-account monotonic change_sequence allocator.';
COMMENT ON TABLE sync_devices IS
    'Private sync spec: Enrollment, authorization, and revocation. Max 10 active (repository-enforced).';
COMMENT ON TABLE sync_records IS
    'Private sync spec: Normative v1 wire contract + Ordering. Canonical RFC 8785 bytes per (account_id, record_id).';
COMMENT ON TABLE sync_changes IS
    'Private sync spec: Ordering; activity feed spec: Identity, ordering. Account-scoped replay log.';
COMMENT ON TABLE sync_idempotency IS
    'Private sync spec: Ordering (mutations require an idempotency key).';
COMMENT ON TABLE sync_ingest_admissions IS
    'Private sync spec: Exact quotas (10,000 accepted records per rolling 24 hours).';
COMMENT ON TABLE sync_retained_bytes IS
    'Private sync spec: Exact quotas (100 MiB retained canonical bytes per account).';
COMMENT ON TABLE sync_cursors IS
    'Private sync spec: Ordering (opaque cursors) + Deletion (tombstone horizon).';
COMMENT ON TABLE sync_leases IS
    'Activity feed spec: Primary delivery + SSE optimization; private sync spec: Deployment stream limits.';
COMMENT ON TABLE sync_rate_windows IS
    'Private sync spec: Deployment (per-account/per-device request rate limits).';
COMMENT ON TABLE sync_conflicts IS
    'Private sync spec: Ordering, conflict handling (immutable-content integrity conflicts, digests only).';
COMMENT ON TABLE sync_retention_markers IS
    'Private sync spec: Deletion, cache invalidation, and tombstones (compaction/retention markers).';
COMMIT;
