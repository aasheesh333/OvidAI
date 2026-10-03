"""Server-owned deletion state machine. All times are server Unix seconds.

The store's UID lock MUST span external effects and checkpoint commits. A worker
never relies on a stale due-list item. Gateway mutations use the same lock.
"""

import math
import re
import time
from contextlib import contextmanager

GRACE_SECONDS = 24 * 60 * 60
RECENT_AUTH_SECONDS = 5 * 60
FENCE_SETTLE_SECONDS = 60


class AccountError(Exception):
    def __init__(self, code, status=409):
        self.code, self.status = code, status
        super().__init__(code)


def identity(claims):
    uid = claims.get('uid') or claims.get('sub')
    # Current Firebase-generated UIDs. Reject delimiters/globs before any
    # legacy Redis key operations; custom UID migrations need an explicit map.
    if not isinstance(uid, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', uid):
        raise AccountError('invalid_identity', 401)
    if claims.get('firebase', {}).get('sign_in_provider') not in ('google.com', 'password'):
        raise AccountError('unsupported_identity', 403)
    return uid


def auth_time(claims):
    value = claims.get('auth_time')
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise AccountError('reauthentication_required', 401)
    return value


def public(row):
    if row is None:
        return {'state': 'active', 'delete_after': None, 'request_id': None}
    return {key: row.get(key) for key in ('state', 'delete_after', 'request_id')}


class Lifecycle:
    def __init__(self, store, admin, data, clock=time.time):
        self.store, self.admin, self.data, self.clock = store, admin, data, clock

    def request(self, claims, request_id):
        uid = identity(claims)
        now = self.clock()
        if not 0 <= now - auth_time(claims) <= RECENT_AUTH_SECONDS:
            raise AccountError('reauthentication_required', 401)
        if not isinstance(request_id, str) or not re.fullmatch(r'[A-Za-z0-9_-]{8,100}', request_id):
            raise AccountError('invalid_request_id', 400)
        with self.store.locked(uid) as db:
            old = db.get(uid)
            if old and request_id in old.get('previous_requests', []):
                raise AccountError('request_already_completed')
            if old and (old['request_id'] == request_id or old['state'] == 'pending'):
                return public(old)
            if old and old['state'] in ('fenced', 'deleting', 'deleted'):
                raise AccountError('deletion_in_progress')
            user = self.admin.user(uid)
            if user is None or user['disabled']:
                raise AccountError('account_unavailable', 403)
            row = dict(uid=uid, request_id=request_id, state='pending',
                       requested_at=now, delete_after=now + GRACE_SECONDS,
                       baseline_login_ms=user['last_login_ms'],
                       fence_at=None, fence_owned=False, completed=[],
                       previous_requests=(old.get('previous_requests', []) +
                                          [old['request_id']] if old else []))
            db.save(row)
            return public(row)

    def status(self, claims):
        uid = identity(claims)
        with self.store.locked(uid) as db:
            return public(db.get(uid))

    def _cancel(self, db, row):
        # Persist cancellation intent before undoing the fence. A crash while
        # enabling is retried by login or worker; data deletion is already barred.
        row['state'] = 'cancelled'
        db.save(row)
        if row['fence_owned']:
            if self.admin.user(row['uid']) is not None:
                self.admin.enable(row['uid'])
            row['fence_owned'] = False
            db.save(row)
        return public(row)

    def login(self, claims):
        uid = identity(claims)
        now = self.clock()
        signed_at = auth_time(claims)
        if signed_at > now:
            raise AccountError('invalid_auth_time', 401)
        with self.store.locked(uid) as db:
            row = db.get(uid)
            if claims.get('_account_disabled') and not (
                    row and row['fence_owned'] and row['state'] in ('fenced', 'cancelled')):
                raise AccountError('account_unavailable', 403)
            if row is None:
                return public(None)
            if row['state'] == 'cancelled':
                return self._cancel(db, row)
            if row['state'] == 'fenced' and not row['fence_owned']:
                raise AccountError('account_unavailable', 403)
            if row['state'] in ('deleting', 'deleted'):
                raise AccountError('deletion_in_progress')
            # A restored, old session cannot undo a deletion request. A real
            # login during grace may arrive while the worker is fencing.
            fresh_metadata = self._grace_login(row, self.admin.user(uid))
            if not (int(row['requested_at']) < signed_at <= row['delete_after'] or
                    (signed_at == int(row['requested_at']) and fresh_metadata)):
                raise AccountError('deletion_pending_sign_in_again')
            return self._cancel(db, row)

    @contextmanager
    def access(self, claims):
        """Quota/mint integration: hold across the ENTIRE UID-owned mutation.

        Call login separately for explicit sign-in. Background usage/token
        refresh must never silently cancel deletion.
        """
        uid = identity(claims)
        with self.store.locked(uid) as db:
            row = db.get(uid)
            if row and row['state'] not in ('cancelled', 'active'):
                raise AccountError('account_deletion_pending', 403)
            yield uid

    def _grace_login(self, row, user):
        # Firebase only exposes the latest login, not history. Any newer login
        # conservatively cancels: a login after the deadline could mask one
        # during grace when the worker was offline. Never delete on ambiguity.
        return user is not None and row['baseline_login_ms'] < user['last_login_ms']

    def finalize(self, uid):
        with self.store.locked(uid) as db:
            row = db.get(uid)
            if row is None or row['state'] == 'deleted':
                return public(row)
            if row['state'] == 'cancelled':
                return self._cancel(db, row)
            now = self.clock()
            if now < row['delete_after']:
                return public(row)
            if row['state'] == 'pending':
                user = self.admin.user(uid)
                if self._grace_login(row, user):
                    return self._cancel(db, row)
                row.update(state='fenced', fence_at=None,
                           fence_owned=user is not None and not user['disabled'])
                db.save(row)
            if row['state'] == 'fenced':
                user = self.admin.user(uid)
                if user is not None and row['fence_owned']:
                    self.admin.disable(uid)
                if row['fence_at'] is None:
                    # Only start settlement after the disable has succeeded.
                    row['fence_at'] = self.clock()
                    db.save(row)
                # Re-read AFTER disabling, including on crash recovery. This
                # captures Firebase sign-ins racing the deadline/fence even if
                # the client never delivered its login acknowledgement.
                if self._grace_login(row, self.admin.user(uid)):
                    return self._cancel(db, row)
                if now < row['fence_at'] + FENCE_SETTLE_SECONDS:
                    return public(row)
                row['state'] = 'deleting'
                db.save(row)
            if 'cleanup_context' not in row:
                row['cleanup_context'] = self.data.prepare(uid)
                db.save(row)
            for name, action in (('keys', self.data.revoke_keys),
                                 ('data', self.data.delete_data),
                                 ('auth', lambda uid, context: self.admin.delete(uid))):
                if name not in row['completed']:
                    action(uid, row['cleanup_context'])
                    row['completed'].append(name)
                    db.save(row)
            row['state'] = 'deleted'
            row.pop('cleanup_context', None)
            db.save(row)
            return public(row)
