import copy
import threading
import unittest
from contextlib import contextmanager

from server.account.domain import AccountError, Lifecycle


class MemoryStore:
    def __init__(self):
        self.rows = {}
        self.mutex = threading.RLock()

    @contextmanager
    def locked(self, uid):
        with self.mutex:
            yield self

    def get(self, uid):
        return copy.deepcopy(self.rows.get(uid))

    def save(self, row):
        self.rows[row['uid']] = copy.deepcopy(row)

    def due(self, now):
        rows = [r for r in self.rows.values()
                if r.get('next_attempt', 0) <= now and (
                    (r['state'] in ('pending', 'fenced', 'deleting')
                     and r['delete_after'] <= now) or
                    (r['state'] == 'cancelled' and r['fence_owned']))]
        rows.sort(key=lambda r: (r.get('next_attempt', 0), r.get('attempts', 0),
                                 r['delete_after'], r['uid']))
        return [r['uid'] for r in rows[:100]]


class Admin:
    def __init__(self):
        self.users = {'alice': {'disabled': False, 'last_login_ms': 900_000}}
        self.on_disable = None

    def user(self, uid):
        return copy.deepcopy(self.users.get(uid))

    def disable(self, uid):
        self.users[uid]['disabled'] = True
        if self.on_disable:
            self.on_disable()

    def enable(self, uid):
        self.users[uid]['disabled'] = False

    def delete(self, uid):
        self.users.pop(uid, None)


class Data:
    def __init__(self):
        self.keys = {'alice': ['key-a'], 'bob': ['key-b']}
        self.profiles = {'alice': {'tier': 'free'}, 'bob': {'tier': '7x'}}
        self.fail = False

    def prepare(self, uid):
        return {}

    def revoke_keys(self, uid, context):
        self.keys.pop(uid, None)

    def delete_data(self, uid, context):
        if self.fail:
            raise RuntimeError('storage unavailable')
        self.profiles.pop(uid, None)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        self.store, self.admin, self.data = MemoryStore(), Admin(), Data()
        self.service = Lifecycle(self.store, self.admin, self.data, lambda: self.now)
        self.claims = {'uid': 'alice', 'auth_time': 1000,
                       'firebase': {'sign_in_provider': 'google.com'}}

    def request(self, request_id='request-0001'):
        return self.service.request(self.claims, request_id)

    def expire(self):
        self.now = 87_400
        self.service.finalize('alice')
        self.now += 61
        return self.service.finalize('alice')

    def test_request_is_durable_and_duplicate_does_not_extend_grace(self):
        first = self.request()
        self.now += 100
        second = self.request()
        self.assertEqual(first['delete_after'], 87_400)
        self.assertEqual(first, second)
        self.assertEqual(self.store.get('alice')['state'], 'pending')

    def test_reauth_and_nonanonymous_identity_are_required(self):
        for update in ({'auth_time': 600}, {'auth_time': 2000},
                        {'firebase': {'sign_in_provider': 'anonymous'}},
                        {'firebase': {'sign_in_provider': 'custom'}},
                        {'firebase': {'sign_in_provider': 'oidc.example'}},
                        {'firebase': {'sign_in_provider': ['google.com']}},
                        {'firebase': None},
                       {'uid': ''}):
            with self.subTest(update=update), self.assertRaises(AccountError):
                self.service.request({**self.claims, **update}, 'request-0001')
        self.assertEqual(self.store.rows, {})

    def test_login_during_grace_cancels_and_duplicate_request_cannot_resurrect(self):
        self.request()
        self.now = 2000
        self.claims['auth_time'] = 2000
        self.assertEqual(self.service.login(self.claims)['state'], 'cancelled')
        self.assertEqual(self.request()['state'], 'cancelled')
        self.assertEqual(self.expire()['state'], 'cancelled')
        self.assertIn('alice', self.admin.users)
        self.assertIn('alice', self.data.keys)

    def test_old_session_does_not_cancel_pending_deletion(self):
        self.request()
        self.now = 2000
        self.claims['auth_time'] = 900
        with self.assertRaises(AccountError):
            self.service.login(self.claims)
        self.assertEqual(self.store.get('alice')['state'], 'pending')

    def test_restoring_requesting_session_in_same_second_does_not_cancel(self):
        self.request()
        with self.assertRaises(AccountError):
            self.service.login(self.claims)
        self.assertEqual(self.store.get('alice')['state'], 'pending')

    def test_cancel_wins_at_exact_deadline_before_worker_claim(self):
        self.request()
        self.now = 87_400
        self.claims['auth_time'] = 87_400
        self.service.login(self.claims)
        self.service.finalize('alice')
        self.assertIn('alice', self.admin.users)

    def test_firebase_login_during_fence_cancels_before_any_data_is_deleted(self):
        self.request()
        self.admin.on_disable = lambda: self.admin.users['alice'].update(
            last_login_ms=87_399_999)
        self.assertEqual(self.expire()['state'], 'cancelled')
        self.assertFalse(self.admin.users['alice']['disabled'])
        self.assertIn('alice', self.data.keys)

    def test_late_arriving_grace_login_ack_can_cancel_fenced_request(self):
        self.request()
        self.now = 87_400
        self.service.finalize('alice')
        self.now += 10
        self.claims['auth_time'] = 87_399
        self.assertEqual(self.service.login(self.claims)['state'], 'cancelled')
        self.assertFalse(self.admin.users['alice']['disabled'])
        self.assertIn('alice', self.data.profiles)

    def test_expired_login_cannot_cancel(self):
        self.request()
        self.now = 87_401
        self.claims['auth_time'] = 87_401
        with self.assertRaises(AccountError):
            self.service.login(self.claims)

    def test_cleanup_retries_after_restart_and_deletes_only_bound_uid(self):
        self.request()
        self.data.fail = True
        with self.assertRaises(RuntimeError):
            self.expire()
        self.assertEqual(self.store.get('alice')['state'], 'deleting')
        self.assertIn('alice', self.admin.users)
        self.assertNotIn('alice', self.data.keys)
        self.data.fail = False
        restarted = Lifecycle(self.store, self.admin, self.data, lambda: self.now)
        self.assertEqual(restarted.finalize('alice')['state'], 'deleted')
        self.assertNotIn('alice', self.admin.users)
        self.assertNotIn('alice', self.data.profiles)
        self.assertEqual(self.data.keys['bob'], ['key-b'])
        self.assertEqual(restarted.finalize('alice')['state'], 'deleted')

    def test_worker_waits_for_grace_and_fence_settlement(self):
        self.request()
        self.now = 87_399
        self.assertEqual(self.service.finalize('alice')['state'], 'pending')
        self.now += 1
        self.assertEqual(self.service.finalize('alice')['state'], 'fenced')
        self.assertIn('alice', self.data.profiles)

    def test_crash_before_disable_does_not_skip_fence_settlement_on_retry(self):
        self.request()
        self.now = 87_400
        disable = self.admin.disable
        self.admin.disable = lambda uid: (_ for _ in ()).throw(RuntimeError('offline'))
        with self.assertRaises(RuntimeError):
            self.service.finalize('alice')
        self.now += 120
        self.admin.disable = disable
        self.assertEqual(self.service.finalize('alice')['state'], 'fenced')
        self.assertIn('alice', self.data.keys)

    def test_latest_login_after_deadline_cannot_hide_an_earlier_grace_login(self):
        self.request()
        # Firebase exposes only the latest login, not the login history. A late
        # worker cannot prove there was no earlier login during grace.
        self.admin.users['alice']['last_login_ms'] = 87_401_000
        self.assertEqual(self.expire()['state'], 'cancelled')
        self.assertIn('alice', self.data.keys)

    def test_request_ids_remain_idempotent_after_new_request(self):
        self.request()
        self.now = 2000
        self.claims['auth_time'] = 2000
        self.service.login(self.claims)
        second = self.request('request-0002')
        with self.assertRaises(AccountError):
            self.request('request-0001')
        self.assertEqual(self.store.get('alice')['request_id'], second['request_id'])

    def test_coalesced_request_b_cannot_resurrect_cancelled_a_after_restart(self):
        first = self.request('request-aaaa')
        self.assertEqual(self.request('request-bbbb'), first)
        self.now = 1001
        self.claims['auth_time'] = 1001
        self.service.login(self.claims)
        self.service = Lifecycle(self.store, self.admin, self.data, lambda: self.now)
        self.assertEqual(self.request('request-bbbb')['state'], 'cancelled')
        self.request('request-cccc')
        with self.assertRaisesRegex(AccountError, 'request_already_completed'):
            self.request('request-bbbb')
        self.assertEqual(self.store.get('alice')['request_id'], 'request-cccc')

    def test_request_rechecks_recent_auth_after_lock_wait(self):
        locked = self.store.locked
        @contextmanager
        def delayed(uid):
            with locked(uid) as db:
                self.now = 1301
                yield db
        self.store.locked = delayed
        with self.assertRaisesRegex(AccountError, 'reauthentication_required'):
            self.request()
        self.assertEqual(self.store.rows, {})

    def test_request_rechecks_recent_auth_after_admin_wait(self):
        user = self.admin.user
        def delayed(uid):
            self.now = 1301
            return user(uid)
        self.admin.user = delayed
        with self.assertRaisesRegex(AccountError, 'reauthentication_required'):
            self.request()
        self.assertEqual(self.store.rows, {})

    def test_deadline_uses_acceptance_time_after_lock_and_admin_wait(self):
        locked, user = self.store.locked, self.admin.user
        @contextmanager
        def delayed_lock(uid):
            with locked(uid) as db:
                self.now += 20
                yield db
        def delayed_admin(uid):
            self.now += 30
            return user(uid)
        self.store.locked, self.admin.user = delayed_lock, delayed_admin
        self.assertEqual(self.request()['delete_after'], 87450)
        self.assertEqual(self.store.rows['alice']['requested_at'], 1050)

    def test_supported_social_and_phone_providers(self):
        for provider in ('google.com', 'github.com', 'apple.com', 'microsoft.com',
                         'facebook.com', 'twitter.com', 'yahoo.com', 'phone'):
            with self.subTest(provider=provider):
                self.store.rows.clear()
                claims = {**self.claims, 'firebase': {'sign_in_provider': provider}}
                self.assertEqual(self.service.request(claims, 'request-social')['state'], 'pending')

    def test_password_cannot_start_new_request_or_gain_normal_access(self):
        claims = {**self.claims, 'firebase': {'sign_in_provider': 'password'}}
        for action in (lambda: self.service.request(claims, 'request-password'),
                       lambda: self.service.login(claims),
                       lambda: self.service.status(claims)):
            with self.assertRaisesRegex(AccountError, 'unsupported_identity'):
                action()
        with self.assertRaisesRegex(AccountError, 'unsupported_identity'), self.service.access(claims):
            self.fail('password identity must not gain ordinary access')

    def test_legacy_password_keeps_existing_deletion_and_fence_recovery(self):
        self.request()
        self.now = 87400
        self.service.finalize('alice')
        claims = {**self.claims, 'auth_time': 87399, '_account_disabled': True,
                  'firebase': {'sign_in_provider': 'password'}}
        enable = self.admin.enable
        self.admin.enable = lambda uid: (_ for _ in ()).throw(RuntimeError('offline'))
        with self.assertRaises(RuntimeError):
            self.service.login(claims)
        self.admin.enable = enable
        self.assertEqual(self.service.login(claims)['state'], 'cancelled')
        self.assertFalse(self.admin.users['alice']['disabled'])
        self.assertEqual(self.service.status(claims)['state'], 'cancelled')
        self.assertEqual(self.service.request(claims, 'request-0001')['state'], 'cancelled')
        with self.assertRaisesRegex(AccountError, 'unsupported_identity'):
            self.service.request(claims, 'request-newpassword')

    def test_fence_settlement_uses_clock_after_admin_wait(self):
        self.request()
        self.now = 87400
        self.service.finalize('alice')
        self.now = 87459
        user = self.admin.user
        def delayed(uid):
            self.now += 2
            return user(uid)
        self.admin.user = delayed
        self.assertEqual(self.service.finalize('alice')['state'], 'deleted')

    def test_scheduled_retry_rechecks_due_time_under_lock(self):
        self.request()
        self.now = 87400
        self.service.finalize('alice', scheduled=True)
        self.assertEqual(self.store.get('alice')['attempts'], 1)
        self.now = 87459
        self.assertEqual(self.service.finalize('alice', scheduled=True)['state'], 'fenced')
        self.assertEqual(self.store.get('alice')['attempts'], 1)
        self.now = 87460
        self.assertEqual(self.service.finalize('alice', scheduled=True)['state'], 'deleted')

    def test_retry_backoff_from_end_of_slow_failure_is_capped(self):
        self.request()
        self.now = 87400
        self.service.finalize('alice')
        self.now = 87461
        def fail(uid, context):
            self.now += 500
            raise RuntimeError('slow failure')
        self.data.delete_data = fail
        for delay in (120, 240, 480, 960, 1920, 3600, 3600):
            with self.assertRaises(RuntimeError):
                self.service.finalize('alice', scheduled=True)
            row = self.store.get('alice')
            self.assertEqual(row['next_attempt'], self.now + delay)
            self.assertEqual(row['completed'], ['keys'])
            self.now = row['next_attempt']

    def test_crash_retry_intent_is_saved_before_external_effect(self):
        self.request()
        self.now = 87400
        def crash(uid):
            raise SystemExit('simulated process crash')
        self.admin.disable = crash
        with self.assertRaises(SystemExit):
            self.service.finalize('alice', scheduled=True)
        row = self.store.get('alice')
        self.assertEqual(row['attempts'], 1)
        self.assertEqual(row['next_attempt'], 87460)
        self.assertEqual(row['state'], 'fenced')
        self.assertIsNone(row['fence_at'])

    def test_disabled_account_without_worker_owned_fence_cannot_login(self):
        with self.assertRaises(AccountError):
            self.service.login({**self.claims, '_account_disabled': True})

    def test_cancel_checkpoint_survives_enable_failure(self):
        self.request()
        self.now = 87_400
        self.service.finalize('alice')
        self.claims['auth_time'] = 87_399
        enable = self.admin.enable
        self.admin.enable = lambda uid: (_ for _ in ()).throw(RuntimeError('offline'))
        with self.assertRaises(RuntimeError):
            self.service.login(self.claims)
        self.assertEqual(self.store.get('alice')['state'], 'cancelled')
        self.admin.enable = enable
        self.now += 120
        self.service.finalize('alice')
        self.assertFalse(self.admin.users['alice']['disabled'])
        self.assertIn('alice', self.data.keys)

    def test_two_workers_finalize_same_uid_without_duplicate_effects(self):
        self.request()
        self.now = 87_400
        self.service.finalize('alice')
        self.now += 61
        effects = []
        original = self.admin.delete
        def delete(uid):
            effects.append(uid)
            original(uid)
        self.admin.delete = delete
        workers = [threading.Thread(target=self.service.finalize, args=('alice',)) for _ in range(2)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join()
        self.assertEqual(effects, ['alice'])

    def test_gateway_guard_blocks_stale_sessions_and_deleted_uid(self):
        self.request()
        with self.assertRaises(AccountError), self.service.access(self.claims):
            self.fail('pending account may not mint keys')
        self.expire()
        with self.assertRaises(AccountError), self.service.access(self.claims):
            self.fail('deleted account may not mint keys')


if __name__ == '__main__':
    unittest.main()
