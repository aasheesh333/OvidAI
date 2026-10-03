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
