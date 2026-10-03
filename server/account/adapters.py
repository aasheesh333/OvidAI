"""Production cleanup adapters. No credentials or environment reads on import."""

import re

import psycopg
from psycopg import sql
from firebase_admin import auth, app_check
from .domain import AccountError, identity


class FirebaseAdmin:
    def __init__(self, app, allowed_app_ids):
        self.app, self.allowed_app_ids = app, set(allowed_app_ids)
        if not self.allowed_app_ids:
            raise ValueError('App Check app ID allowlist is required')

    def verify(self, token, attestation, allow_disabled=False):
        try:
            check = app_check.verify_token(attestation, app=self.app)
            if check.get('app_id') not in self.allowed_app_ids:
                raise AccountError('invalid_attestation', 401)
            try:
                claims = auth.verify_id_token(token, app=self.app, check_revoked=True)
            except auth.UserDisabledError:
                if not allow_disabled:
                    raise
                claims = auth.verify_id_token(token, app=self.app, check_revoked=False)
                user = auth.get_user(claims['uid'], app=self.app)
                if claims.get('auth_time', 0) * 1000 < user.tokens_valid_after_timestamp:
                    raise AccountError('revoked_token', 401)
                claims['_account_disabled'] = True
            # Verify legacy credentials, but let the lifecycle authorize only
            # existing deletion recovery. Ordinary access rejects password.
            identity(claims, allow_legacy_password=True)
            return claims
        except AccountError:
            raise
        except (ValueError, auth.InvalidIdTokenError, auth.RevokedIdTokenError,
                auth.UserDisabledError, auth.UserNotFoundError):
            raise AccountError('invalid_authentication', 401) from None

    def user(self, uid):
        try:
            user = auth.get_user(uid, app=self.app)
            return {'disabled': user.disabled,
                    'last_login_ms': user.user_metadata.last_sign_in_timestamp or 0}
        except auth.UserNotFoundError:
            return None

    def disable(self, uid):
        auth.update_user(uid, disabled=True, app=self.app)

    def enable(self, uid):
        auth.update_user(uid, disabled=False, app=self.app)

    def delete(self, uid):
        try:
            auth.delete_user(uid, app=self.app)
        except auth.UserNotFoundError:
            pass


class RedisData:
    def __init__(self, client):
        self.client = client

    def delete_data(self, uid):
        # identity() validates legacy key delimiters before these patterns.
        for pattern in (f'user:{uid}:*', f'freecap:{uid}:*', f'abuse:uid:{uid}',
                        f'mintlock:{uid}'):
            for key in self.client.scan_iter(match=pattern):
                self.client.delete(key)
        self.client.srem('ovid:uids', uid)
        for key in self.client.scan_iter(match='ipacct:*'):
            self.client.srem(key, uid)


class SqlData:
    """Explicit, operator-reviewed UID/token ownership manifest.

    LiteLLM's deployed `main-latest` schema cannot be safely guessed. Startup
    requires a complete manifest; identifiers are quoted, values parameterized.
    All scoped SQL data is deleted in ONE transaction before deleting Firebase.
    """

    def __init__(self, dsn, manifest):
        self.dsn = dsn
        self.scopes = manifest.get('scopes', [])
        required = {'keys', 'users', 'spend_logs'}
        if not required <= {scope.get('role') for scope in self.scopes}:
            raise ValueError('Cleanup manifest must include keys, users and spend_logs')
        if sum(scope.get('role') == 'keys' for scope in self.scopes) != 1:
            raise ValueError('Exactly one key ownership scope is required')
        for scope in self.scopes:
            for field in ('table', 'column'):
                if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', scope.get(field, '')):
                    raise ValueError('Invalid SQL identifier in cleanup manifest')
            if scope.get('kind') not in ('uid', 'token'):
                raise ValueError('Cleanup kind must be uid or token')
            if scope['role'] == 'keys':
                if scope['kind'] != 'uid' or not re.fullmatch(
                        r'[A-Za-z_][A-Za-z0-9_]*', scope.get('token_column', '')):
                    raise ValueError('Key scope requires UID ownership and token_column')

    def validate(self):
        with psycopg.connect(self.dsn) as connection:
            for scope in self.scopes:
                connection.execute(sql.SQL('SELECT {} FROM {} LIMIT 0').format(
                    sql.Identifier(scope['column']), sql.Identifier(scope['table'])))
                if scope['role'] == 'keys':
                    connection.execute(sql.SQL('SELECT {} FROM {} LIMIT 0').format(
                        sql.Identifier(scope['token_column']), sql.Identifier(scope['table'])))

    def tokens(self, uid):
        scope = next(s for s in self.scopes if s['role'] == 'keys')
        with psycopg.connect(self.dsn) as connection:
            return [row[0] for row in connection.execute(sql.SQL(
                'SELECT {} FROM {} WHERE {} = %s').format(
                    sql.Identifier(scope['token_column']), sql.Identifier(scope['table']),
                    sql.Identifier(scope['column'])), (uid,)).fetchall()]

    def delete_data(self, uid, tokens):
        with psycopg.connect(self.dsn) as connection:
            # Manifest order handles foreign keys; token scopes precede key rows.
            for scope in self.scopes:
                condition = '= %s' if scope['kind'] == 'uid' else '= ANY(%s)'
                connection.execute(sql.SQL('DELETE FROM {} WHERE {} ' + condition).format(
                    sql.Identifier(scope['table']), sql.Identifier(scope['column'])),
                    (uid if scope['kind'] == 'uid' else tokens,))


class GatewayData:
    def __init__(self, sql_data, redis_data, client):
        self.sql, self.redis, self.client = sql_data, redis_data, client

    def prepare(self, uid):
        return {'tokens': self.sql.tokens(uid)}

    def revoke_keys(self, uid, context):
        # Block rather than delete key rows first: token-linked spend/log scopes
        # still need those rows to find ownership. Handles every key, not only
        # the legacy Redis keyid. Repeating a block after a crash is harmless.
        for token in context['tokens']:
            response = self.client.post('/key/block', json={'key': token})
            response.raise_for_status()

    def deletion_steps(self):
        """Stable checkpoint names; each action must be retryable until saved.

        Acknowledged gateway deletion must not be replayed merely because a
        later SQL/Redis stage failed. Unknown outcomes still require the actual
        deployed adapter's idempotency contract, not an assumed HTTP 404 success.
        """
        return (('gateway', self._delete_gateway_keys),
                ('sql', self._delete_sql), ('redis', self._delete_redis))

    def delete_data(self, uid, context):
        for _, action in self.deletion_steps():
            action(uid, context)

    def _delete_gateway_keys(self, uid, context):
        # Delete via LiteLLM as well to evict its key caches. The durable cleanup
        # context preserves token ownership across retries. Blocking plus
        # cache eviction MUST be verified for the deployed LiteLLM release.
        tokens = context['tokens']
        if tokens:
            response = self.client.post('/key/delete', json={'keys': tokens})
            response.raise_for_status()

    def _delete_sql(self, uid, context):
        self.sql.delete_data(uid, context['tokens'])

    def _delete_redis(self, uid, context):
        self.redis.delete_data(uid)
