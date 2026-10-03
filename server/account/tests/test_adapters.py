import unittest
from unittest.mock import patch
from types import SimpleNamespace
import httpx
from firebase_admin import auth
from server.account.adapters import FirebaseAdmin, GatewayData, RedisData, SqlData
from server.account.domain import AccountError


class RedisFake:
    def __init__(self):
        self.values = {'user:alice:key': 'a', 'user:bob:key': 'b',
                       'freecap:alice:2026-10': '1', 'abuse:uid:alice': '2'}
        self.sets = {'ovid:uids': {'alice', 'bob'}, 'ipacct:1.2.3.4': {'alice', 'bob'}}

    def scan_iter(self, match):
        import fnmatch
        return iter(k for k in [*self.values, *self.sets] if fnmatch.fnmatchcase(k, match))

    def delete(self, key):
        self.values.pop(key, None)

    def srem(self, key, value):
        self.sets.get(key, set()).discard(value)


class AdapterTests(unittest.TestCase):
    def test_revoked_firebase_token_is_not_accepted_for_cancel(self):
        admin = FirebaseAdmin('app', ['android-app'])
        with patch('server.account.adapters.app_check.verify_token', return_value={'app_id': 'android-app'}), \
             patch('server.account.adapters.auth.verify_id_token', side_effect=auth.RevokedIdTokenError('revoked')):
            with self.assertRaises(AccountError):
                admin.verify('token', 'attestation', allow_disabled=True)

    def test_wrong_app_is_rejected_before_auth_token_verification(self):
        admin = FirebaseAdmin('app', ['android-app'])
        with patch('server.account.adapters.app_check.verify_token', return_value={'app_id': 'other-app'}), \
             patch('server.account.adapters.auth.verify_id_token') as verify:
            with self.assertRaises(AccountError):
                admin.verify('token', 'attestation')
            verify.assert_not_called()

    def test_disabled_cancel_token_still_checks_revocation_and_marks_claims(self):
        admin = FirebaseAdmin('app', ['android-app'])
        claims = {'uid': 'alice', 'auth_time': 1000,
                  'firebase': {'sign_in_provider': 'password'}}
        with patch('server.account.adapters.app_check.verify_token', return_value={'app_id': 'android-app'}), \
             patch('server.account.adapters.auth.verify_id_token', side_effect=[
                 auth.UserDisabledError('disabled'), claims]), \
             patch('server.account.adapters.auth.get_user', return_value=SimpleNamespace(tokens_valid_after_timestamp=900000)):
            self.assertTrue(admin.verify('token', 'attestation', allow_disabled=True)['_account_disabled'])

    def test_gateway_retains_token_ownership_when_sql_cleanup_retries(self):
        class Database:
            def __init__(self):
                self.key_rows = ['token-a', 'token-b']
                self.log_rows = ['token-a', 'token-b', 'other-user-token']
                self.fail = True

            def tokens(self, uid):
                self_uid = uid
                if self_uid != 'alice':
                    raise AssertionError('incorrect UID')
                return list(self.key_rows)

            def delete_data(self, uid, tokens):
                if self.fail:
                    raise RuntimeError('database unavailable')
                self.log_rows = [token for token in self.log_rows if token not in tokens]

        database, redis = Database(), RedisFake()
        def transport(request):
            import json
            payload = json.loads(request.content)
            if request.url.path == '/key/delete':
                self.assertEqual(payload, {'keys': ['token-a', 'token-b']})
                database.key_rows = []
            elif request.url.path == '/key/block':
                self.assertIn(payload['key'], ['token-a', 'token-b'])
            else:
                self.fail('unexpected endpoint')
            return httpx.Response(200, json={'ok': True})

        with httpx.Client(base_url='https://gateway.invalid', transport=httpx.MockTransport(transport)) as client:
            cleanup = GatewayData(database, RedisData(redis), client)
            context = cleanup.prepare('alice')
            cleanup.revoke_keys('alice', context)
            with self.assertRaises(RuntimeError):
                cleanup.delete_data('alice', context)
            self.assertEqual(database.key_rows, [])
            self.assertIn('user:alice:key', redis.values)
            database.fail = False
            cleanup.delete_data('alice', context)
        self.assertEqual(database.log_rows, ['other-user-token'])
        self.assertNotIn('user:alice:key', redis.values)

    def test_redis_cleanup_removes_only_uid_owned_data_and_memberships(self):
        redis = RedisFake()
        cleanup = RedisData(redis)
        cleanup.delete_data('alice')
        cleanup.delete_data('alice')
        self.assertEqual(redis.values, {'user:bob:key': 'b'})
        self.assertEqual(redis.sets, {'ovid:uids': {'bob'}, 'ipacct:1.2.3.4': {'bob'}})

    def test_sql_manifest_requires_explicit_key_user_and_log_scopes(self):
        with self.assertRaises(ValueError):
            SqlData('unused', {'scopes': []})
        with self.assertRaises(ValueError):
            SqlData('unused', {'scopes': [
                {'table': 'users; DROP TABLE users', 'column': 'user_id', 'kind': 'uid'}]})
