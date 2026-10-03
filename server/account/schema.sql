-- Run explicitly in the account database before starting the service.
-- Do NOT put lifecycle records in the evicting gateway Redis cache.
CREATE TABLE IF NOT EXISTS account_deletions (
    uid text PRIMARY KEY,
    state text NOT NULL CHECK (state IN
        ('pending', 'fenced', 'deleting', 'deleted', 'cancelled')),
    delete_after double precision NOT NULL,
    record jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS account_deletions_due
    ON account_deletions (delete_after)
    WHERE state IN ('pending', 'fenced', 'deleting', 'cancelled');

-- Retry fields live in record for compatibility with the original schema.
-- Existing installations can apply migrations/002_retry_schedule.sql instead.
CREATE INDEX IF NOT EXISTS account_deletions_retry_due
    ON account_deletions (
        COALESCE(CAST(record->>'next_attempt' AS double precision), 0),
        COALESCE(CAST(record->>'attempts' AS bigint), 0),
        delete_after, uid)
    WHERE state IN ('pending', 'fenced', 'deleting', 'cancelled');
