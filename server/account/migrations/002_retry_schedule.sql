-- Explicit, additive migration for existing account databases. No row rewrite:
-- missing JSON fields mean attempts=0 / next_attempt=0 to the new reader.
-- Keep the old index for rollback. Runtime correctness does not require this
-- index, so the new code also works on the original four-column schema.
BEGIN;
CREATE INDEX IF NOT EXISTS account_deletions_retry_due
    ON account_deletions (
        COALESCE(CAST(record->>'next_attempt' AS double precision), 0),
        COALESCE(CAST(record->>'attempts' AS bigint), 0),
        delete_after, uid)
    WHERE state IN ('pending', 'fenced', 'deleting', 'cancelled');
COMMIT;
