"""Native PostgreSQL collaboration authority over an explicitly deployed schema.

Lock order: acting collab_accounts row, then collab_sessions rows in ID order.
The session row serializes capacity, invite use, generation, sequence, quotas,
and idempotency across hosts. Reads take the same locks for a coherent DTO.
Cleanup takes the account row even when there is no membership yet, fencing
concurrent create/join. No operation locks another participant's account row.

Lifecycle.access must surround public API calls. It owns the account advisory
lock on another connection; this repository never reacquires it. The lifecycle
query here is a defensive check, while the collaboration tombstone independently
fences direct calls racing cleanup. Constructors perform reads only.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
import secrets
import time
from contextlib import contextmanager

import psycopg
from psycopg import sql
from psycopg.rows import dict_row

from . import events as ev
from . import repository as policy
from .repository import CollabError, CollabRepository, _hash, _rfc3339


class PostgresCollabUnavailable(CollabError):
    """Storage failure using the transport's existing non-sensitive error code."""

    def __init__(self):
        # SQLite's domain error table intentionally contains only domain errors.
        Exception.__init__(self, 'temporarily_unavailable')
        self.code, self.status = 'temporarily_unavailable', 500


class PostgresCollabRepository:
    durability = 'durable'
    authority = 'server'

    # These helpers contain no storage access. Keep wire/signature semantics
    # identical to SQLite, including recovery of already-issued credentials.
    _identity = staticmethod(CollabRepository._identity)
    _require_active = staticmethod(CollabRepository._require_active)
    _request_key = staticmethod(CollabRepository._request_key)
    _member_dto = staticmethod(CollabRepository._member_dto)
    _retry_token = staticmethod(CollabRepository._retry_token)
    _fingerprint = staticmethod(CollabRepository._fingerprint)
    _authority_stamp = staticmethod(CollabRepository._authority_stamp)
    _cursor = CollabRepository._cursor
    _invite_code = CollabRepository._invite_code

    def __init__(self, account_authority=None, schema='public', clock=None, *,
                 dsn=None, authority_id=None):
        if account_authority is not None:
            if dsn is not None:
                raise ValueError('provide one explicit PostgreSQL authority')
            source = getattr(account_authority, 'store', account_authority)
            dsn = source if isinstance(source, str) else getattr(source, 'dsn', None)
        if type(dsn) is not str or not dsn.strip():
            raise ValueError('an explicit PostgreSQL authority or DSN is required')
        if type(schema) is not str or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]{0,62}', schema):
            raise ValueError('invalid PostgreSQL schema')
        self._dsn, self.schema = dsn, schema
        self.clock = time.time if clock is None else clock
        with self._connection() as db:
            stored = {r['name']: r['secret'] for r in db.execute(
                "SELECT name, secret FROM collab_secrets WHERE name IN ('cursor','authority')")}
        try:
            self._secret = bytes.fromhex(stored['cursor'])
            self.authority_identity = stored['authority']
            if len(self._secret) != 32 or not self.authority_identity:
                raise ValueError()
        except (KeyError, TypeError, ValueError):
            raise PostgresCollabUnavailable() from None
        if authority_id is not None and authority_id != self.authority_identity:
            raise ValueError('collaboration authority identity mismatch')

    @contextmanager
    def _connection(self, *, write=False):
        # write is accepted for compatibility with operational callers. Public
        # reads also acquire authority row locks and therefore use read/write txs.
        try:
            with psycopg.connect(self._dsn, row_factory=dict_row, connect_timeout=10) as db:
                db.execute('SET TRANSACTION ISOLATION LEVEL READ COMMITTED')
                db.execute(sql.SQL('SET LOCAL search_path TO {}').format(sql.Identifier(self.schema)))
                db.execute("SET LOCAL lock_timeout = '10s'")
                db.execute("SET LOCAL statement_timeout = '30s'")
                yield db
        except psycopg.Error:
            # Driver diagnostics can contain payloads and credentials.
            raise PostgresCollabUnavailable() from None

    @contextmanager
    def _transaction(self, uid, *, deleting=False):
        self._identity(uid)
        with self._connection(write=True) as db:
            db.execute('INSERT INTO collab_accounts VALUES (%s) ON CONFLICT DO NOTHING', (uid,))
            db.execute('SELECT uid FROM collab_accounts WHERE uid=%s FOR UPDATE', (uid,)).fetchone()
            if not deleting:
                self._not_deleted(db, uid)
            yield db

    @staticmethod
    def _not_deleted(db, uid):
        if db.execute('SELECT 1 FROM deleted_accounts WHERE uid=%s', (uid,)).fetchone():
            raise CollabError('account_deleted')
        lifecycle = db.execute('SELECT state FROM account_deletions WHERE uid=%s', (uid,)).fetchone()
        if lifecycle and lifecycle['state'] != 'cancelled':
            raise CollabError('account_deleted' if lifecycle['state'] == 'deleted'
                              else 'account_deletion_pending')

    def _session(self, db, uid, token):
        self._identity(uid)
        if not isinstance(token, str) or not policy._TOKEN.fullmatch(token):
            raise CollabError('session_not_found')
        row = db.execute('SELECT * FROM collab_sessions WHERE token_hash=%s FOR UPDATE',
                         (_hash(token),)).fetchone()
        if row is None:
            raise CollabError('session_not_found')
        return row

    @staticmethod
    def _membership(db, session_id, uid):
        return db.execute('SELECT * FROM collab_memberships WHERE session_id=%s AND uid=%s',
                          (session_id, uid)).fetchone()

    def _active_member(self, db, session, uid):
        member = self._membership(db, session['session_id'], uid)
        if (member is None or member['status'] != 'active' or
                member['generation'] != session['generation']):
            raise CollabError('not_member')
        return member

    def _owner(self, db, session, uid):
        member = self._active_member(db, session, uid)
        if member['role'] != 'owner':
            raise CollabError('not_owner')
        return member

    def _session_dto(self, db, session):
        owner = db.execute("SELECT participant_id FROM collab_memberships WHERE session_id=%s AND role='owner'",
                           (session['session_id'],)).fetchone()
        return {'schemaVersion': ev.SCHEMA_VERSION, 'sessionId': session['session_id'],
                'ownerParticipantId': owner['participant_id'], 'lifecycle': session['lifecycle']}

    def _prior_request(self, db, session, member, uid, operation, key, payload):
        fingerprint = hashlib.sha256(ev.canonical_bytes(payload)).hexdigest()
        prior = db.execute('SELECT * FROM collab_requests WHERE session_id=%s AND uid=%s '
                           'AND operation=%s AND request_id=%s',
                           (session['session_id'], uid, operation, key)).fetchone()
        if prior is not None:
            if (prior['fingerprint'] != fingerprint or member is None or
                    member['status'] != 'active' or
                    prior['membership_epoch'] != member['cursor_epoch']):
                raise CollabError('request_already_used')
            return fingerprint, json.loads(prior['result'])
        return fingerprint, None

    @staticmethod
    def _save_request(db, session, member, uid, operation, key, fingerprint, result):
        data = ev.canonical_bytes(result)
        usage = db.execute('SELECT count(*) AS n, coalesce(sum(octet_length(result)),0) AS size '
                           'FROM collab_requests WHERE session_id=%s', (session['session_id'],)).fetchone()
        if usage['n'] >= policy.MAX_REQUEST_RECORDS or usage['size'] + len(data) > policy.MAX_REQUEST_RESULT_BYTES:
            raise CollabError('quota_exhausted')
        db.execute('INSERT INTO collab_requests VALUES (%s,%s,%s,%s,%s,%s,%s)',
                   (session['session_id'], uid, operation, key, fingerprint,
                    member['cursor_epoch'], data.decode()))

    def _rate(self, db, session_id, operation, limit):
        now = self.clock()
        # Session-scoped pruning avoids cross-session lock inversions.
        db.execute('DELETE FROM collab_rates WHERE session_id=%s AND created_at<=%s',
                   (session_id, now - 60))
        count = db.execute('SELECT count(*) AS n FROM collab_rates WHERE session_id=%s AND operation=%s',
                           (session_id, operation)).fetchone()['n']
        if count >= limit:
            raise CollabError('rate_limited')
        db.execute('INSERT INTO collab_rates VALUES (%s,%s,%s)', (session_id, operation, now))

    def _admit_rate(self, uid, token, operation, limit):
        with self._transaction(uid) as db:
            session = self._session(db, uid, token)
            self._require_active(session)
            member = self._active_member(db, session, uid)
            self._rate(db, session['session_id'], operation, limit)
            return self._authority_stamp(session, member)

    @staticmethod
    def _bump_generation(db, session_id):
        return db.execute('UPDATE collab_sessions SET generation=generation+1 WHERE session_id=%s '
                          'RETURNING generation', (session_id,)).fetchone()['generation']

    def _insert_event(self, db, session_id, sender, kind, payload, event_id, now):
        sequence = db.execute('UPDATE collab_sessions SET next_sequence=next_sequence+1 '
                              'WHERE session_id=%s RETURNING next_sequence-1 AS sequence',
                              (session_id,)).fetchone()['sequence']
        envelope = {'schemaVersion': ev.SCHEMA_VERSION, 'eventId': event_id,
                    'sessionId': session_id, 'eventSequence': sequence,
                    'senderParticipantId': sender, 'kind': kind,
                    'createdAt': _rfc3339(now), 'payload': payload}
        ev.check_size(envelope)
        data = ev.canonical_bytes(envelope)
        if kind not in ('membership', 'system') or (kind == 'membership' and payload['action'] == 'joined'):
            usage = db.execute('SELECT coalesce(sum(size),0) AS retained, '
                               'count(*) FILTER (WHERE created_at>%s) AS rolling '
                               'FROM collab_events WHERE session_id=%s', (now - 86400, session_id)).fetchone()
            if usage['retained'] + len(data) > policy.MAX_RETAINED_BYTES or usage['rolling'] >= policy.MAX_ROLLING_EVENTS:
                raise CollabError('quota_exhausted')
        db.execute('INSERT INTO collab_events VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s)',
                   (session_id, sequence, event_id, sender, kind, data.decode(),
                    self._fingerprint(sender, kind, payload), len(data), now))
        return envelope

    def _membership_event(self, db, session_id, sender, action, participant_id, now):
        payload = ev.validate_payload('membership', {'action': action, 'participantId': participant_id,
                                                     'role': 'participant' if action == 'joined' else None})
        self._insert_event(db, session_id, sender, 'membership', payload, 'srv:' + secrets.token_hex(16), now)

    def create_session(self, uid, request_id):
        self._identity(uid)
        if not isinstance(request_id, str) or not policy._REQUEST_ID.fullmatch(request_id):
            raise CollabError('invalid_request')
        with self._transaction(uid) as db:
            session = db.execute('SELECT * FROM collab_sessions WHERE owner_uid=%s AND request_id=%s FOR UPDATE',
                                 (uid, request_id)).fetchone()
            if session is None:
                sid, pid, now = 's' + secrets.token_hex(16), 'p' + secrets.token_hex(16), self.clock()
                token = self._retry_token(sid, uid, request_id)
                session = db.execute("INSERT INTO collab_sessions VALUES (%s,%s,%s,%s,'active',1,1,%s,NULL) RETURNING *",
                                     (sid, _hash(token), uid, request_id, now)).fetchone()
                db.execute("INSERT INTO collab_memberships VALUES (%s,%s,%s,'owner','active',1,NULL,0,%s,%s,NULL,1)",
                           (sid, uid, pid, now, now))
            else:
                token = self._retry_token(session['session_id'], uid, request_id)
                if _hash(token) != session['token_hash']:
                    raise CollabError('request_already_used')
            member = self._membership(db, session['session_id'], uid)
            return {'sessionToken': token, 'session': self._session_dto(db, session),
                    'member': self._member_dto(member), 'cursor': self._cursor(session, member, 0)}

    def create_invite(self, uid, token, *, max_uses=1, ttl_seconds=policy.DEFAULT_INVITE_TTL_SECONDS,
                      idempotency_key=None):
        self._identity(uid)
        if (type(max_uses) is not int or not 1 <= max_uses <= policy.MAX_INVITE_USES or
                type(ttl_seconds) is not int or not 1 <= ttl_seconds <= policy.MAX_INVITE_TTL_SECONDS):
            raise CollabError('invalid_request')
        with self._transaction(uid) as db:
            session = self._session(db, uid, token)
            self._require_active(session)
            member = self._owner(db, session, uid)
            key = self._request_key(idempotency_key)
            fingerprint, result = self._prior_request(db, session, member, uid, 'invite', key, [max_uses, ttl_seconds])
            if result is not None:
                return {**result, 'inviteCode': self._invite_code(result['inviteId'])}
            if db.execute('SELECT 1 FROM collab_invite_requests WHERE session_id=%s AND owner_uid=%s AND request_id=%s',
                          (session['session_id'], uid, key)).fetchone():
                raise CollabError('request_already_used')
            invite_id, now = 'i' + secrets.token_hex(16), self.clock()
            code = self._invite_code(invite_id)
            db.execute('INSERT INTO collab_invites VALUES (%s,%s,%s,%s,%s,0,0,%s,%s)',
                       (invite_id, session['session_id'], _hash(code), session['generation'], max_uses, now, now + ttl_seconds))
            db.execute('INSERT INTO collab_invite_requests VALUES (%s,%s,%s,%s)',
                       (session['session_id'], uid, key, invite_id))
            result = {'inviteId': invite_id, 'expiresAt': _rfc3339(now + ttl_seconds), 'maxUses': max_uses}
            self._save_request(db, session, member, uid, 'invite', key, fingerprint, result)
            return {**result, 'inviteCode': code}

    def revoke_invite(self, uid, token, invite_id):
        with self._transaction(uid) as db:
            session = self._session(db, uid, token)
            self._require_active(session)
            self._owner(db, session, uid)
            if not db.execute('UPDATE collab_invites SET revoked=1 WHERE invite_id=%s AND session_id=%s RETURNING invite_id',
                              (invite_id, session['session_id'])).fetchone():
                raise CollabError('invite_not_found')

    def join(self, uid, token, invite_code, *, idempotency_key=None, with_cursor=False):
        self._identity(uid)
        key = self._request_key(idempotency_key)
        if not isinstance(invite_code, str) or len(invite_code) > 512:
            raise CollabError('invalid_request')
        with self._transaction(uid) as db:
            session = self._session(db, uid, token)
            self._require_active(session)
            sid = session['session_id']
            existing = self._membership(db, sid, uid)
            fingerprint, prior = self._prior_request(db, session, existing, uid, 'join', key, invite_code)
            if prior is not None:
                return prior if with_cursor else prior['member']
            if existing is not None and existing['status'] == 'active':
                if existing['generation'] != session['generation']:
                    raise CollabError('not_member')
                member = existing
            else:
                invite = db.execute('SELECT * FROM collab_invites WHERE session_id=%s AND code_hash=%s',
                                    (sid, _hash(invite_code))).fetchone()
                if existing is not None and existing['status'] == 'revoked' and (
                        invite is None or invite['issued_generation'] < existing['revoked_generation']):
                    raise CollabError('membership_revoked')
                if invite is None or invite['revoked'] or invite['uses'] >= invite['max_uses'] or invite['expires_at'] <= self.clock():
                    raise CollabError('invite_invalid')
                active = db.execute("SELECT count(*) AS n FROM collab_memberships WHERE session_id=%s AND status='active'",
                                    (sid,)).fetchone()['n']
                if active >= policy.MAX_ACTIVE_MEMBERS:
                    raise CollabError('session_full')
                now = self.clock()
                if existing is None:
                    pid = 'p' + secrets.token_hex(16)
                    db.execute("INSERT INTO collab_memberships VALUES (%s,%s,%s,'participant','active',%s,NULL,%s,%s,%s,NULL,1)",
                               (sid, uid, pid, session['generation'], active, now, now))
                else:
                    pid = existing['participant_id']
                    db.execute("UPDATE collab_memberships SET status='active', cursor_epoch = cursor_epoch + 1, generation=%s, "
                               'updated_at=%s, revoked_generation=NULL, revoked_at=NULL WHERE session_id=%s AND uid=%s',
                               (session['generation'], now, sid, uid))
                db.execute('UPDATE collab_invites SET uses=uses+1 WHERE invite_id=%s', (invite['invite_id'],))
                self._membership_event(db, sid, pid, 'joined', pid, now)
                member = self._membership(db, sid, uid)
            result = {'member': self._member_dto(member), 'cursor': self._cursor(session, member, 0)}
            self._save_request(db, session, member, uid, 'join', key, fingerprint, result)
            return result if with_cursor else result['member']

    def get_state(self, uid, token):
        with self._transaction(uid) as db:
            session = self._session(db, uid, token)
            self._require_active(session)
            member = self._active_member(db, session, uid)
            # SQLite's session/participant index breaks joined_order ties by
            # participant ID. Make that tie-break explicit across PG heap updates.
            rows = db.execute("SELECT * FROM collab_memberships WHERE session_id=%s AND status='active' ORDER BY joined_order, participant_id",
                              (session['session_id'],)).fetchall()
            owner = db.execute("SELECT * FROM collab_memberships WHERE session_id=%s AND role='owner'",
                               (session['session_id'],)).fetchone()
            return {'session': self._session_dto(db, session), 'member': self._member_dto(member),
                    'members': [self._member_dto(row) for row in rows], 'initialMembers': [self._member_dto(owner)],
                    'replayThroughSequence': session['next_sequence'] - 1, 'cursor': self._cursor(session, member, 0)}

    def revoke_member(self, uid, token, participant_id):
        with self._transaction(uid) as db:
            session = self._session(db, uid, token)
            self._require_active(session)
            self._owner(db, session, uid)
            sid = session['session_id']
            row = db.execute('SELECT * FROM collab_memberships WHERE session_id=%s AND participant_id=%s',
                             (sid, participant_id)).fetchone()
            if row is None:
                raise CollabError('member_not_found')
            if row['role'] == 'owner':
                raise CollabError('owner_not_removable')
            if row['status'] == 'revoked':
                return {'member': self._member_dto(row)}
            generation, now = self._bump_generation(db, sid), self.clock()
            db.execute("UPDATE collab_memberships SET generation=%s WHERE session_id=%s AND status='active'", (generation, sid))
            db.execute("UPDATE collab_memberships SET status='revoked', revoked_generation=%s, generation=%s, updated_at=%s, "
                       'revoked_at=%s WHERE session_id=%s AND participant_id=%s', (generation, generation, now, now, sid, participant_id))
            self._membership_event(db, sid, participant_id, 'revoked', participant_id, now)
            return {'member': {**self._member_dto(row), 'status': 'revoked'}}

    def leave(self, uid, token):
        with self._transaction(uid) as db:
            session = self._session(db, uid, token)
            self._require_active(session)
            existing = self._membership(db, session['session_id'], uid)
            if existing is not None and existing['status'] == 'left':
                return {'member': self._member_dto(existing)}
            member = self._active_member(db, session, uid)
            if member['role'] == 'owner':
                raise CollabError('owner_not_removable')
            now = self.clock()
            db.execute("UPDATE collab_memberships SET status='left', generation=generation+1, updated_at=%s WHERE session_id=%s AND uid=%s",
                       (now, session['session_id'], uid))
            self._membership_event(db, session['session_id'], member['participant_id'], 'left', member['participant_id'], now)
            return {'member': {**self._member_dto(member), 'status': 'left'}}

    def append(self, uid, token, raw_event):
        return self.append_batch(uid, token, [raw_event])['events'][0]

    def append_batch(self, uid, token, raw_events, *, idempotency_key=None):
        admitted = self._admit_rate(uid, token, 'append', 60)
        key = self._request_key(idempotency_key)
        if type(raw_events) is not list or not 1 <= len(raw_events) <= policy.MAX_BATCH_EVENTS:
            raise CollabError('invalid_request')
        events = [ev.validate_client_event(event) for event in raw_events]
        if len(ev.canonical_bytes(events)) > policy.MAX_BATCH_BYTES:
            raise CollabError('payload_too_large')
        if len({event['eventId'] for event in events}) != len(events):
            raise CollabError('invalid_request')
        with self._transaction(uid) as db:
            session = self._session(db, uid, token)
            self._require_active(session)
            member = self._active_member(db, session, uid)
            if admitted != self._authority_stamp(session, member):
                raise CollabError('not_member')
            fingerprint, prior = self._prior_request(db, session, member, uid, 'append', key, events)
            if prior is not None:
                return prior
            result = []
            for event in events:
                old = db.execute('SELECT * FROM collab_events WHERE session_id=%s AND event_id=%s',
                                 (session['session_id'], event['eventId'])).fetchone()
                if old is not None:
                    if old['fingerprint'] != self._fingerprint(member['participant_id'], event['kind'], event['payload']):
                        raise CollabError('event_id_conflict')
                    result.append(json.loads(old['envelope']))
                else:
                    result.append(self._insert_event(db, session['session_id'], member['participant_id'], event['kind'],
                                                     event['payload'], event['eventId'], self.clock()))
            page = {'events': result, 'nextCursor': self._cursor(session, member, max(e['eventSequence'] for e in result)),
                    'hasMore': False}
            self._save_request(db, session, member, uid, 'append', key, fingerprint, page)
            return page

    def replay(self, uid, token, cursor=None, *, limit=policy.MAX_REPLAY_EVENTS, max_bytes=policy.MAX_REPLAY_BYTES):
        self._identity(uid)
        admitted = self._admit_rate(uid, token, 'replay', 120)
        if (type(limit) is not int or not 1 <= limit <= policy.MAX_REPLAY_EVENTS or
                type(max_bytes) is not int or not 1 <= max_bytes <= policy.MAX_REPLAY_BYTES):
            raise CollabError('invalid_request')
        with self._transaction(uid) as db:
            session = self._session(db, uid, token)
            self._require_active(session)
            member = self._active_member(db, session, uid)
            if admitted != self._authority_stamp(session, member):
                raise CollabError('cursor_reset')
            start = 0
            if cursor is not None:
                if not isinstance(cursor, str) or len(cursor) > policy.MAX_CURSOR_LENGTH:
                    raise CollabError('cursor_reset')
                try:
                    decoded = base64.b64decode(cursor + '=' * (-len(cursor) % 4), altchars=b'-_', validate=True).decode()
                    raw, signature = decoded.rsplit(':', 1)
                    if not hmac.compare_digest(signature, hmac.new(self._secret, raw.encode(), hashlib.sha256).hexdigest()):
                        raise ValueError()
                    version, sid, participant, generation, epoch, expires, sequence = raw.split(':')
                    if (version != 'v3' or sid != session['session_id'] or participant != member['participant_id'] or
                            int(generation) != session['generation'] or int(epoch) != member['cursor_epoch'] or int(expires) <= self.clock()):
                        raise ValueError()
                    start = int(sequence)
                except (ValueError, UnicodeDecodeError):
                    raise CollabError('cursor_reset') from None
            head = session['next_sequence'] - 1
            if start > head:
                raise CollabError('cursor_reset')
            rows = db.execute('SELECT envelope, size FROM collab_events WHERE session_id=%s AND sequence>%s ORDER BY sequence LIMIT %s',
                              (session['session_id'], start, limit)).fetchall()
            events, size = [], 0
            for row in rows:
                if events and size + row['size'] > max_bytes:
                    break
                events.append(json.loads(row['envelope']))
                size += row['size']
            last = events[-1]['eventSequence'] if events else start
            return {'events': events, 'hasMore': last < head, 'cursor': self._cursor(session, member, last)}

    def close(self, uid, token, *, idempotency_key=None):
        self._identity(uid)
        self._request_key(idempotency_key)
        with self._transaction(uid) as db:
            session = self._session(db, uid, token)
            member = self._membership(db, session['session_id'], uid)
            if member is None or member['status'] != 'active' or member['role'] != 'owner':
                raise CollabError('not_owner')
            if session['lifecycle'] == 'closed':
                return self._session_dto(db, session)
            sid, now = session['session_id'], self.clock()
            generation = self._bump_generation(db, sid)
            db.execute("UPDATE collab_memberships SET generation=%s WHERE session_id=%s AND status='active'", (generation, sid))
            db.execute("UPDATE collab_sessions SET lifecycle='closing' WHERE session_id=%s", (sid,))
            self._insert_event(db, sid, member['participant_id'], 'system', {'code': 'sessionClosing'}, 'srv:' + secrets.token_hex(16), now)
            session = db.execute("UPDATE collab_sessions SET lifecycle='closed', closed_at=%s WHERE session_id=%s RETURNING *", (now, sid)).fetchone()
            self._insert_event(db, sid, member['participant_id'], 'system', {'code': 'sessionClosed'}, 'srv:' + secrets.token_hex(16), now)
            return self._session_dto(db, session)

    def delete_account(self, uid):
        with self._transaction(uid, deleting=True) as db:
            # Lock sessions before children, just as normal requests do. Sorted
            # acquisition prevents deadlocks between overlapping account cleanup.
            sessions = db.execute('SELECT s.* FROM collab_sessions s WHERE s.owner_uid=%s OR EXISTS '
                                  '(SELECT 1 FROM collab_memberships m WHERE m.session_id=s.session_id AND m.uid=%s) '
                                  'ORDER BY s.session_id FOR UPDATE OF s', (uid, uid)).fetchall()
            db.execute('DELETE FROM collab_requests WHERE uid=%s', (uid,))
            db.execute('DELETE FROM collab_invite_requests WHERE owner_uid=%s', (uid,))
            inserted = db.execute('INSERT INTO deleted_accounts VALUES (%s) ON CONFLICT DO NOTHING RETURNING uid', (uid,)).fetchone()
            if inserted is None:
                return
            now = self.clock()
            for session in sessions:
                sid = session['session_id']
                if session['owner_uid'] == uid:
                    db.execute('INSERT INTO deleted_sessions VALUES (%s,%s) ON CONFLICT DO NOTHING', (sid, session['token_hash']))
                    for table in ('collab_events', 'collab_invites', 'collab_memberships',
                                  'collab_invite_requests', 'collab_requests', 'collab_rates'):
                        db.execute(sql.SQL('DELETE FROM {} WHERE session_id=%s').format(sql.Identifier(table)), (sid,))
                    db.execute('DELETE FROM collab_sessions WHERE session_id=%s', (sid,))
                else:
                    member = self._membership(db, sid, uid)
                    if member is not None and member['status'] == 'active':
                        self._membership_event(db, sid, member['participant_id'], 'left', member['participant_id'], now)
            db.execute('DELETE FROM collab_memberships WHERE uid=%s', (uid,))

    def purge_expired(self, *, limit=500):
        """Bounded housekeeping of expired rate admissions; never prune replay,
        credentials, idempotency results, or deletion fences. Safe across workers.
        """
        if type(limit) is not int or not 1 <= limit <= 10000:
            raise ValueError('invalid retention batch size')
        with self._connection(write=True) as db:
            return db.execute('WITH expired AS (SELECT ctid FROM collab_rates WHERE created_at<=%s '
                              'ORDER BY created_at LIMIT %s FOR UPDATE SKIP LOCKED) '
                              'DELETE FROM collab_rates r USING expired e WHERE r.ctid=e.ctid',
                              (self.clock() - 60, limit)).rowcount
