"""Durable PostgreSQL checkpoints with session-scoped per-UID advisory locks."""

from contextlib import contextmanager

import psycopg
from psycopg.types.json import Jsonb


class Session:
    def __init__(self, connection):
        self.connection = connection

    def get(self, uid):
        row = self.connection.execute(
            'SELECT record FROM account_deletions WHERE uid = %s', (uid,)
        ).fetchone()
        return row[0] if row else None

    def save(self, row):
        self.connection.execute('''
            INSERT INTO account_deletions (uid, state, delete_after, record)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (uid) DO UPDATE SET state = EXCLUDED.state,
                delete_after = EXCLUDED.delete_after, record = EXCLUDED.record
        ''', (row['uid'], row['state'], row['delete_after'], Jsonb(row)))


class PostgresStore:
    def __init__(self, dsn):
        self.dsn = dsn

    @contextmanager
    def locked(self, uid):
        # A dedicated connection is essential: returning a still-locked
        # connection to a pool could let unrelated requests share ownership.
        with psycopg.connect(self.dsn, autocommit=True) as connection:
            connection.execute("SET lock_timeout = '30s'")
            connection.execute(
                "SELECT pg_advisory_lock(hashtextextended(%s, 714031))", (uid,))
            try:
                yield Session(connection)
            finally:
                connection.execute(
                    "SELECT pg_advisory_unlock(hashtextextended(%s, 714031))", (uid,))

    def due(self, now):
        with psycopg.connect(self.dsn) as connection:
            return [row[0] for row in connection.execute('''
                SELECT uid FROM account_deletions
                WHERE COALESCE(CAST(record->>'next_attempt' AS double precision), 0) <= %s
                  AND ((state IN ('pending', 'fenced', 'deleting') AND delete_after <= %s)
                   OR (state = 'cancelled' AND record->>'fence_owned' = 'true'))
                ORDER BY COALESCE(CAST(record->>'next_attempt' AS double precision), 0),
                         COALESCE(CAST(record->>'attempts' AS bigint), 0), delete_after, uid
                LIMIT 100
            ''', (now, now)).fetchall()]
