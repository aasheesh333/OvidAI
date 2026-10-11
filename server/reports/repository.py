"""Durable SQLite queue of in-app content reports (AI output and UGC).

Play's AI-Generated Content and User Generated Content policies require an
in-app way to report offensive content to the developer. Reports are a
moderation queue: reviewers triage `open` rows and mark them `actioned` or
`dismissed`. Rows expire after the retention window and are erased with the
reporter's account.
"""

import json
import secrets
import sqlite3
import time
from contextlib import contextmanager

KINDS = frozenset({'ai_output', 'shared_conversation', 'collab_message', 'collab_participant'})
REASONS = frozenset({'sexual', 'child_safety', 'hate', 'violence', 'self_harm', 'illegal',
                     'misleading', 'privacy', 'spam', 'other'})
STATUSES = frozenset({'open', 'actioned', 'dismissed'})


class ReportError(Exception):
    def __init__(self, status, code):
        super().__init__(code)
        self.status, self.code = status, code


class ReportRepository:
    def __init__(self, path, *, clock=time.time, daily_limit=50, retention_seconds=180 * 86400):
        if str(path) == ':memory:' or daily_limit <= 0 or retention_seconds <= 0:
            raise ValueError('A durable database path, positive daily limit and retention are required')
        self.path, self.clock = str(path), clock
        self.daily_limit, self.retention = daily_limit, retention_seconds
        with self._connection() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS reports (
                    id TEXT PRIMARY KEY,
                    reporter_uid TEXT NOT NULL,
                    request_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    details TEXT NOT NULL,
                    excerpt TEXT NOT NULL,
                    target_id TEXT,
                    model TEXT,
                    status TEXT NOT NULL DEFAULT 'open',
                    created_at REAL NOT NULL,
                    UNIQUE(reporter_uid, request_id)
                );
                CREATE INDEX IF NOT EXISTS reports_status ON reports(status, created_at);
                CREATE INDEX IF NOT EXISTS reports_reporter ON reports(reporter_uid, created_at);
            ''')

    @contextmanager
    def _connection(self):
        db = sqlite3.connect(self.path, timeout=15)
        db.row_factory = sqlite3.Row
        try:
            db.execute('PRAGMA synchronous=FULL')
            with db:
                yield db
        finally:
            db.close()

    def create(self, uid, body):
        if body['kind'] not in KINDS or body['reason'] not in REASONS:
            raise ReportError(422, 'invalid_report')
        now = self.clock()
        with self._connection() as db:
            db.execute('BEGIN IMMEDIATE')
            existing = db.execute('SELECT id, created_at FROM reports WHERE reporter_uid=? AND request_id=?',
                                  (uid, body['request_id'])).fetchone()
            if existing:
                return {'id': existing['id'], 'created': False}
            recent = db.execute('SELECT COUNT(*) FROM reports WHERE reporter_uid=? AND created_at>?',
                                (uid, now - 86400)).fetchone()[0]
            if recent >= self.daily_limit:
                raise ReportError(429, 'report_limit_reached')
            report_id = secrets.token_urlsafe(16)
            db.execute('''INSERT INTO reports (id, reporter_uid, request_id, kind, reason, details,
                          excerpt, target_id, model, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)''',
                       (report_id, uid, body['request_id'], body['kind'], body['reason'],
                        body.get('details', ''), body.get('excerpt', ''), body.get('target_id'),
                        body.get('model'), now))
            return {'id': report_id, 'created': True}

    def open_reports(self, limit=100):
        """Reviewer queue, oldest first."""
        with self._connection() as db:
            rows = db.execute('''SELECT id, kind, reason, details, excerpt, target_id, model, created_at
                                 FROM reports WHERE status='open' ORDER BY created_at LIMIT ?''',
                              (limit,)).fetchall()
            return [dict(row) for row in rows]

    def resolve(self, report_id, status):
        if status not in STATUSES - {'open'}:
            raise ReportError(422, 'invalid_status')
        with self._connection() as db:
            if db.execute('UPDATE reports SET status=? WHERE id=?', (status, report_id)).rowcount != 1:
                raise ReportError(404, 'report_not_found')

    def purge_expired(self):
        with self._connection() as db:
            return db.execute('DELETE FROM reports WHERE created_at<?',
                              (self.clock() - self.retention,)).rowcount

    def delete_account(self, uid):
        """Account deletion: erase every report filed by this UID."""
        with self._connection() as db:
            return db.execute('DELETE FROM reports WHERE reporter_uid=?', (uid,)).rowcount

    def export(self, uid):
        with self._connection() as db:
            rows = db.execute('SELECT kind, reason, details, created_at FROM reports WHERE reporter_uid=?',
                              (uid,)).fetchall()
            return json.dumps([dict(row) for row in rows])
