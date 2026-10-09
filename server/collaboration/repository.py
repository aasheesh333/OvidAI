"""Durable SQLite collaboration authority: sessions, membership, invites, events.

Relay/data only. Nothing here calls a model/provider, spawns a process, opens a
network connection, or accepts a callback: events are validated inert JSON and
are stored, ordered, and returned verbatim.

Every invariant that spans rows (single owner, owner-inclusive capacity of 10,
invite consumption, revocation fencing, sequence allocation, event-id dedupe,
account-deletion fencing) is checked and mutated inside ONE `BEGIN IMMEDIATE`
transaction, so independent connections/processes serialize on the database
write lock and no process-local counter is ever authoritative.

Identity (`uid`) is supplied by the caller from verified authentication and is
never read from a request body. Error codes are fixed and never echo tokens,
invite codes, or payloads.
"""

import base64
import hashlib
import math
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime, timezone

from . import events as ev

MAX_ACTIVE_MEMBERS = 10  # including the owner
MAX_INVITE_USES = MAX_ACTIVE_MEMBERS - 1
MAX_INVITE_TTL_SECONDS = 7 * 86400
DEFAULT_INVITE_TTL_SECONDS = 86400
MAX_REPLAY_EVENTS = 100
MAX_REPLAY_BYTES = 256 * 1024
MAX_CURSOR_LENGTH = 512

_TOKEN = re.compile(r'[A-Za-z0-9_-]{43}')
_REQUEST_ID = re.compile(r'[A-Za-z0-9_-]{1,128}')
_CURSOR = re.compile(r'v1:(s[0-9a-f]{32}):(0|[1-9][0-9]{0,17})')

_STATUS = {
    'invalid_request': 400, 'invalid_identity': 401, 'account_deleted': 403,
    'not_member': 403, 'not_owner': 403, 'invite_invalid': 403, 'membership_revoked': 403,
    'session_not_found': 404, 'member_not_found': 404, 'invite_not_found': 404,
    'session_closed': 409, 'session_full': 409, 'owner_not_removable': 409,
    'event_id_conflict': 409, 'request_already_used': 409, 'cursor_reset': 410,
}


class CollabError(Exception):
    """Fixed, non-sensitive failure. `code` is stable; message never echoes input."""

    def __init__(self, code):
        super().__init__(code)
        self.code, self.status = code, _STATUS[code]


def _hash(secret):
    return hashlib.sha256(secret.encode('utf-8')).hexdigest()


def _rfc3339(ts):
    moment = datetime.fromtimestamp(ts, timezone.utc)
    return moment.strftime('%Y-%m-%dT%H:%M:%S.') + f'{moment.microsecond // 1000:03d}Z'


def _encode_cursor(session_id, sequence):
    raw = f'v1:{session_id}:{sequence}'.encode('ascii')
    return base64.urlsafe_b64encode(raw).decode('ascii').rstrip('=')


class CollabRepository:
    def __init__(self, path, *, clock=time.time):
        if str(path) == ':memory:':
            raise ValueError('A durable database path is required')
        self.path, self.clock = str(path), clock
        with self._connection() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS collab_sessions (
                    session_id TEXT PRIMARY KEY,
                    token_hash TEXT NOT NULL UNIQUE,
                    owner_uid TEXT NOT NULL,
                    request_id TEXT NOT NULL,
                    lifecycle TEXT NOT NULL CHECK (lifecycle IN ('active','closing','closed')),
                    generation INTEGER NOT NULL,
                    next_sequence INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    closed_at REAL,
                    UNIQUE(owner_uid, request_id)
                );
                CREATE TABLE IF NOT EXISTS collab_memberships (
                    session_id TEXT NOT NULL,
                    uid TEXT NOT NULL,
                    participant_id TEXT NOT NULL,
                    role TEXT NOT NULL CHECK (role IN ('owner','participant')),
                    status TEXT NOT NULL CHECK (status IN ('active','left','revoked')),
                    generation INTEGER NOT NULL,
                    revoked_generation INTEGER,
                    joined_order INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    revoked_at REAL,
                    PRIMARY KEY(session_id, uid),
                    UNIQUE(session_id, participant_id)
                );
                -- Defense in depth for "exactly one owner" per session.
                CREATE UNIQUE INDEX IF NOT EXISTS collab_one_owner
                    ON collab_memberships(session_id) WHERE role='owner';
                CREATE INDEX IF NOT EXISTS collab_memberships_uid ON collab_memberships(uid);
                CREATE TABLE IF NOT EXISTS collab_invites (
                    invite_id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    code_hash TEXT NOT NULL UNIQUE,
                    issued_generation INTEGER NOT NULL,
                    max_uses INTEGER NOT NULL,
                    uses INTEGER NOT NULL DEFAULT 0,
                    revoked INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    expires_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS collab_invites_session ON collab_invites(session_id);
                CREATE TABLE IF NOT EXISTS collab_events (
                    session_id TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    event_id TEXT NOT NULL,
                    sender_participant_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    envelope TEXT NOT NULL,
                    fingerprint TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY(session_id, sequence),
                    UNIQUE(session_id, event_id)
                );
                CREATE TABLE IF NOT EXISTS deleted_accounts (uid TEXT PRIMARY KEY);
                CREATE TABLE IF NOT EXISTS deleted_sessions (
                    session_id TEXT PRIMARY KEY,
                    token_hash TEXT NOT NULL UNIQUE
                );
            ''')
            # Unprefixed aliases used by tests/ops queries.
            for name in ('sessions', 'memberships', 'invites', 'events'):
                db.execute(f'CREATE VIEW IF NOT EXISTS {name} AS SELECT * FROM collab_{name}')

    @contextmanager
    def _connection(self, *, write=False):
        db = sqlite3.connect(self.path, timeout=30, isolation_level=None)
        db.row_factory = sqlite3.Row
        try:
            db.execute('PRAGMA synchronous=FULL')
            # Reads use one snapshot; writes take the database write lock up front.
            db.execute('BEGIN IMMEDIATE' if write else 'BEGIN')
            yield db
            db.execute('COMMIT')
        except BaseException:
            if db.in_transaction:
                db.execute('ROLLBACK')
            raise
        finally:
            db.close()

    # ------------------------------------------------------------------
    # Shared guards (always called inside the operation's transaction)
    # ------------------------------------------------------------------

    @staticmethod
    def _identity(uid):
        if not isinstance(uid, str) or not uid.strip() or len(uid) > 256:
            raise CollabError('invalid_identity')

    @staticmethod
    def _not_deleted(db, uid):
        if db.execute('SELECT 1 FROM deleted_accounts WHERE uid=?', (uid,)).fetchone():
            raise CollabError('account_deleted')

    def _session(self, db, uid, token):
        self._identity(uid)
        self._not_deleted(db, uid)
        if not isinstance(token, str) or not _TOKEN.fullmatch(token):
            raise CollabError('session_not_found')
        row = db.execute('SELECT * FROM collab_sessions WHERE token_hash=?',
                         (_hash(token),)).fetchone()
        if row is None:
            raise CollabError('session_not_found')
        return row

    @staticmethod
    def _require_active(session):
        if session['lifecycle'] != 'active':
            raise CollabError('session_closed')

    @staticmethod
    def _membership(db, session_id, uid):
        return db.execute('SELECT * FROM collab_memberships WHERE session_id=? AND uid=?',
                          (session_id, uid)).fetchone()

    def _active_member(self, db, session, uid):
        member = self._membership(db, session['session_id'], uid)
        if member is None or member['status'] != 'active':
            raise CollabError('not_member')
        return member

    def _owner(self, db, session, uid):
        member = self._active_member(db, session, uid)
        if member['role'] != 'owner':
            raise CollabError('not_owner')
        return member

    @staticmethod
    def _bump_generation(db, session_id):
        db.execute('UPDATE collab_sessions SET generation=generation+1 WHERE session_id=?',
                   (session_id,))
        return db.execute('SELECT generation FROM collab_sessions WHERE session_id=?',
                          (session_id,)).fetchone()[0]

    @staticmethod
    def _member_dto(row):
        return {'participantId': row['participant_id'], 'role': row['role'],
                'status': row['status']}

    def _session_dto(self, db, session):
        owner = db.execute("SELECT participant_id FROM collab_memberships "
                           "WHERE session_id=? AND role='owner'",
                           (session['session_id'],)).fetchone()
        return {'schemaVersion': ev.SCHEMA_VERSION, 'sessionId': session['session_id'],
                'ownerParticipantId': owner['participant_id'],
                'lifecycle': session['lifecycle']}

    def _insert_event(self, db, session_id, sender, kind, payload, event_id, now):
        """Allocate the next sequence and append, in the caller's transaction."""
        sequence = db.execute('SELECT next_sequence FROM collab_sessions WHERE session_id=?',
                              (session_id,)).fetchone()[0]
        envelope = {'schemaVersion': ev.SCHEMA_VERSION, 'eventId': event_id,
                    'sessionId': session_id, 'eventSequence': sequence,
                    'senderParticipantId': sender, 'kind': kind,
                    'createdAt': _rfc3339(now), 'payload': payload}
        ev.check_size(envelope)
        data = ev.canonical_bytes(envelope)
        db.execute('INSERT INTO collab_events VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
                   (session_id, sequence, event_id, sender, kind, data.decode('utf-8'),
                    self._fingerprint(sender, kind, payload), len(data), now))
        db.execute('UPDATE collab_sessions SET next_sequence=? WHERE session_id=?',
                   (sequence + 1, session_id))
        return envelope

    @staticmethod
    def _fingerprint(sender, kind, payload):
        return hashlib.sha256(ev.canonical_bytes([sender, kind, payload])).hexdigest()

    def _membership_event(self, db, session_id, sender, action, participant_id, now):
        payload = ev.validate_payload('membership', {
            'action': action, 'participantId': participant_id,
            'role': 'participant' if action == 'joined' else None})
        self._insert_event(db, session_id, sender, 'membership', payload,
                           'srv:' + secrets.token_hex(16), now)

    # ------------------------------------------------------------------
    # Sessions
    # ------------------------------------------------------------------

    def create_session(self, uid, request_id):
        """Create a session owned by `uid`. Durable-idempotent per (uid, request_id)."""
        self._identity(uid)
        if not isinstance(request_id, str) or not _REQUEST_ID.fullmatch(request_id):
            raise CollabError('invalid_request')
        with self._connection(write=True) as db:
            now = self.clock()
            self._not_deleted(db, uid)
            session = db.execute('SELECT * FROM collab_sessions WHERE owner_uid=? AND request_id=?',
                                 (uid, request_id)).fetchone()
            if session is not None:
                # The token is never stored in plaintext, so a retry cannot be
                # answered with it after the original response was lost.
                raise CollabError('request_already_used') if self._token_for_retry is None \
                    else CollabError('request_already_used')
            token = secrets.token_urlsafe(32)
            session_id = 's' + secrets.token_hex(16)
            participant_id = 'p' + secrets.token_hex(16)
            db.execute('INSERT INTO collab_sessions VALUES (?, ?, ?, ?, ?, 1, 1, ?, NULL)',
                       (session_id, _hash(token), uid, request_id, 'active', now))
            db.execute('INSERT INTO collab_memberships VALUES '
                       '(?, ?, ?, ?, ?, 1, NULL, 0, ?, ?, NULL)',
                       (session_id, uid, participant_id, 'owner', 'active', now, now))
            session = db.execute('SELECT * FROM collab_sessions WHERE session_id=?',
                                 (session_id,)).fetchone()
            return {'sessionToken': token, 'session': self._session_dto(db, session),
                    'member': {'participantId': participant_id, 'role': 'owner',
                               'status': 'active'},
                    'cursor': _encode_cursor(session_id, 0)}

    _token_for_retry = None
