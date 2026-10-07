"""Durable SQLite snapshots, idempotency receipts and account-deletion fence."""

import hashlib
import json
import math
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager

from .snapshot import CreateShare, ForkShare


class ShareError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


class ShareRepository:
    def __init__(self, path, *, clock=time.time, ttl_seconds=30 * 86400):
        if str(path) == ':memory:' or not math.isfinite(ttl_seconds) or ttl_seconds <= 0:
            raise ValueError('A durable database path and finite positive TTL are required')
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
                CREATE INDEX IF NOT EXISTS shares_expiry ON shares(expires_at)
                    WHERE snapshot IS NOT NULL;
                CREATE TABLE IF NOT EXISTS share_forks (
                    owner_uid TEXT NOT NULL,
                    request_id TEXT NOT NULL,
                    source_token TEXT NOT NULL,
                    session_id TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY(owner_uid, request_id)
                );
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
        with self._connection(write=True) as db:
            # Lock acquisition can outlive a receipt's remaining TTL. Evaluate
            # expiry and quota against transaction time, not pre-lock time.
            now = self.clock()
            if db.execute('SELECT 1 FROM deleted_accounts WHERE uid=?', (uid,)).fetchone():
                raise ShareError(403, 'account_deleted')
            previous = db.execute('SELECT * FROM shares WHERE owner_uid=? AND request_id=?',
                                  (uid, body['request_id'])).fetchone()
            if previous:
                if (previous['fingerprint'] != fingerprint or previous['revoked'] or
                        previous['snapshot'] is None or previous['expires_at'] <= now):
                    raise ShareError(409, 'request_already_used')
                return self._receipt(previous)
            count = db.execute('SELECT count(*) FROM shares WHERE owner_uid=? AND revoked=0 AND snapshot IS NOT NULL AND expires_at>?',
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
                AND snapshot IS NOT NULL AND expires_at>? AND (? IS NULL OR session_id=?) ORDER BY created_at DESC, token''',
                              (uid, self.clock(), session_id, session_id)).fetchall()
            return [self._receipt(row) for row in rows]

    def public(self, token):
        with self._connection() as db:
            row = db.execute('SELECT snapshot, session_id FROM shares WHERE token=? AND revoked=0 AND expires_at>?',
                             (token, self.clock())).fetchone()
            if not row or not row['snapshot']:
                return None
            snapshot = json.loads(row['snapshot'])
            snapshot['session_id'] = row['session_id']
            return snapshot

    def revoke(self, uid, token):
        with self._connection(write=True) as db:
            result = db.execute('UPDATE shares SET revoked=1, snapshot=NULL WHERE owner_uid=? AND token=?',
                                (uid, token))
            if result.rowcount != 1:
                raise ShareError(404, 'share_not_found')

    def fork(self, uid, token, body):
        if not isinstance(uid, str) or not uid.strip():
            raise ShareError(401, 'invalid_identity')
        if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', token):
            raise ShareError(409, 'share_unavailable')
        body = ForkShare.model_validate(body).model_dump()
        with self._connection(write=True) as db:
            now = self.clock()
            if db.execute('SELECT 1 FROM deleted_accounts WHERE uid=?', (uid,)).fetchone():
                raise ShareError(403, 'account_deleted')
            source = db.execute(
                'SELECT snapshot FROM shares WHERE token=? AND revoked=0 AND expires_at>?',
                (token, now)).fetchone()
            if source is None or source['snapshot'] is None:
                raise ShareError(409, 'share_unavailable')
            previous = db.execute(
                'SELECT session_id, source_token FROM share_forks WHERE owner_uid=? AND request_id=?',
                (uid, body['request_id'])).fetchone()
            if previous:
                if previous['source_token'] != token:
                    raise ShareError(409, 'request_already_used')
                return {'session_id': previous['session_id']}
            session_id = secrets.token_urlsafe(16)
            db.execute(
                'INSERT INTO share_forks VALUES (?, ?, ?, ?, ?)',
                (uid, body['request_id'], token, session_id, now))
            return {'session_id': session_id}

    def delete_account(self, uid):
        """Idempotent cleanup hook. Fence and erase in the same write transaction.

        Call from the account worker after its durable deletion fence; never on
        logout or during the cancellable grace period. Concurrent create cannot
        restore data even if token verification completed before cleanup.
        """
        with self._connection(write=True) as db:
            db.execute('INSERT OR IGNORE INTO deleted_accounts VALUES (?)', (uid,))
            db.execute('DELETE FROM shares WHERE owner_uid=?', (uid,))
            db.execute('DELETE FROM share_forks WHERE owner_uid=?', (uid,))

    def purge_expired(self, limit=500):
        # Retain minimal dedup receipts until account deletion so a retry never
        # silently republishes an expired or revoked snapshot.
        if type(limit) is not int or not 1 <= limit <= 10000:
            raise ValueError('Retention batch size must be between 1 and 10000')
        with self._connection(write=True) as db:
            result = db.execute('''UPDATE shares SET snapshot=NULL WHERE rowid IN
                (SELECT rowid FROM shares WHERE snapshot IS NOT NULL AND expires_at<=?
                 ORDER BY expires_at, rowid LIMIT ?)''', (self.clock(), limit))
            return result.rowcount
