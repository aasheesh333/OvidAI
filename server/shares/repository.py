"""Durable SQLite snapshots, idempotency receipts and account-deletion fence."""

import hashlib
import json
import secrets
import sqlite3
import time
from contextlib import contextmanager

from .snapshot import CreateShare


class ShareError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


class ShareRepository:
    def __init__(self, path, *, clock=time.time, ttl_seconds=30 * 86400):
        if str(path) == ':memory:' or ttl_seconds <= 0:
            raise ValueError('A durable database path and positive TTL are required')
        self.path, self.clock, self.ttl = str(path), clock, ttl_seconds
        with self._connection() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS shares (
                    token TEXT PRIMARY KEY,
                    owner_uid TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    request_id TEXT NOT NULL,
                    fingerprint TEXT NOT NULL,
                    snapshot TEXT,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL,
                    revoked INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(owner_uid, request_id)
                );
                CREATE INDEX IF NOT EXISTS shares_owner_session
                    ON shares(owner_uid, session_id);
                CREATE TABLE IF NOT EXISTS deleted_accounts (uid TEXT PRIMARY KEY);
            ''')

    @contextmanager
    def _connection(self, *, write=False):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        try:
            db.execute('PRAGMA synchronous=FULL')
            if write:
                db.execute('BEGIN IMMEDIATE')
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    @staticmethod
    def _receipt(row):
        return {'id': row['token'], 'session_id': row['session_id'],
                'request_id': row['request_id'],
                'created_at': row['created_at'], 'expires_at': row['expires_at']}

    def create(self, uid, body):
        # Validate even for callers other than HTTP. Ownership comes separately.
        if not isinstance(uid, str) or not uid.strip():
            raise ShareError(401, 'invalid_identity')
        body = CreateShare.model_validate(body).model_dump()
        snapshot = json.dumps({'messages': body['messages']}, ensure_ascii=False,
                              sort_keys=True, separators=(',', ':'))
        fingerprint = hashlib.sha256((body['session_id'] + '\n' + snapshot).encode()).hexdigest()
        now = self.clock()
        with self._connection(write=True) as db:
            if db.execute('SELECT 1 FROM deleted_accounts WHERE uid=?', (uid,)).fetchone():
                raise ShareError(403, 'account_deleted')
            previous = db.execute('SELECT * FROM shares WHERE owner_uid=? AND request_id=?',
                                  (uid, body['request_id'])).fetchone()
            if previous:
                if previous['fingerprint'] != fingerprint or previous['revoked'] or previous['expires_at'] <= now:
                    raise ShareError(409, 'request_already_used')
                return self._receipt(previous)
            count = db.execute('SELECT count(*) FROM shares WHERE owner_uid=? AND revoked=0 AND expires_at>?',
                               (uid, now)).fetchone()[0]
            if count >= 100:
                raise ShareError(429, 'share_limit_reached')
            # Count revoked and expired receipts too. Never discard deduplication
            # history and accidentally allow an old request to republish text.
            total = db.execute('SELECT count(*) FROM shares WHERE owner_uid=?',
                               (uid,)).fetchone()[0]
            if total >= 1000:
                raise ShareError(429, 'share_storage_limit_reached')
            token = secrets.token_urlsafe(32)
            db.execute('INSERT INTO shares VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)',
                       (token, uid, body['session_id'], body['request_id'], fingerprint,
                        snapshot, now, now + self.ttl))
            return {'id': token, 'session_id': body['session_id'],
                    'request_id': body['request_id'],
                    'created_at': now, 'expires_at': now + self.ttl}

    def list(self, uid, session_id=None):
        with self._connection() as db:
            rows = db.execute('''SELECT * FROM shares WHERE owner_uid=? AND revoked=0
                AND expires_at>? AND (? IS NULL OR session_id=?) ORDER BY created_at DESC, token''',
                              (uid, self.clock(), session_id, session_id)).fetchall()
            return [self._receipt(row) for row in rows]

    def public(self, token):
        with self._connection() as db:
            row = db.execute('SELECT snapshot FROM shares WHERE token=? AND revoked=0 AND expires_at>?',
                             (token, self.clock())).fetchone()
            return json.loads(row['snapshot']) if row and row['snapshot'] else None

    def revoke(self, uid, token):
        with self._connection(write=True) as db:
            result = db.execute('UPDATE shares SET revoked=1, snapshot=NULL WHERE owner_uid=? AND token=?',
                                (uid, token))
            if result.rowcount != 1:
                raise ShareError(404, 'share_not_found')

    def delete_account(self, uid):
        """Idempotent cleanup hook. Fence and erase in the same write transaction.

        Call from the account worker after its durable deletion fence; never on
        logout or during the cancellable grace period. Concurrent create cannot
        restore data even if token verification completed before cleanup.
        """
        with self._connection(write=True) as db:
            db.execute('INSERT OR IGNORE INTO deleted_accounts VALUES (?)', (uid,))
            db.execute('DELETE FROM shares WHERE owner_uid=?', (uid,))

    def purge_expired(self):
        # Retain minimal dedup receipts until account deletion so a retry never
        # silently republishes an expired or revoked snapshot.
        with self._connection(write=True) as db:
            db.execute('UPDATE shares SET snapshot=NULL WHERE expires_at<=?', (self.clock(),))
