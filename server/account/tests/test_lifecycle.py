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
        return [uid for uid, r in self.rows.items()
                if r['state'] in ('pending', 'fenced', 'deleting')
                and r['delete_after'] <= now]


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
                       'firebase': {'sign_in_provider': 'password'}}

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
