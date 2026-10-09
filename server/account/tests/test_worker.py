import unittest
from server.account.domain import Lifecycle
from server.account.worker import sweep
from test_lifecycle import MemoryStore, Admin, Data


class WorkerTests(unittest.TestCase):
    def test_restart_sweep_reads_durable_pending_rows(self):
        now = [1000]
        store, admin, data = MemoryStore(), Admin(), Data()
        Lifecycle(store, admin, data, lambda: now[0]).request(
            {'uid': 'alice', 'auth_time': 1000,
             'firebase': {'sign_in_provider': 'google.com'}}, 'request-0001')
        now[0] = 87400
        restarted = Lifecycle(store, admin, data, lambda: now[0])
        self.assertEqual(sweep(restarted), 0)
        self.assertIn('alice', admin.users)
        now[0] += 61
        self.assertEqual(sweep(restarted), 0)
        self.assertNotIn('alice', admin.users)
        self.assertEqual(sweep(restarted), 0)

    def test_poison_first_100_do_not_starve_later_rows(self):
        now = [100000]
        store, admin, data = MemoryStore(), Admin(), Data()
        for index in range(101):
            uid = f'user-{index:03}'
            store.save(dict(uid=uid, request_id=f'request-{index:03}', state='deleting',
                            delete_after=1000 + index, fence_owned=True,
                            completed=[], cleanup_context={}))
        revoke = data.revoke_keys
        def poison(uid, context):
            if uid != 'user-100':
                raise RuntimeError('poison')
            revoke(uid, context)
        data.revoke_keys = poison
        service = Lifecycle(store, admin, data, lambda: now[0])
        self.assertEqual(sweep(service), 100)
        restarted = Lifecycle(store, admin, data, lambda: now[0])
        self.assertEqual(sweep(restarted), 0)
        self.assertEqual(store.get('user-100')['state'], 'deleted')
        self.assertEqual(store.get('user-000')['attempts'], 1)
        self.assertGreater(store.get('user-000')['next_attempt'], now[0])
        now[0] = store.get('user-000')['next_attempt']
        self.assertEqual(sweep(restarted), 100)
        self.assertEqual(store.get('user-000')['attempts'], 2)

    def test_cancel_recovery_failures_back_off_and_remain_recoverable(self):
        now = [1000]
        store, admin, data = MemoryStore(), Admin(), Data()
        service = Lifecycle(store, admin, data, lambda: now[0])
        claims = {'uid': 'alice', 'auth_time': 1000,
                  'firebase': {'sign_in_provider': 'google.com'}}
        service.request(claims, 'request-cancel')
        now[0] = 87400
        sweep(service)
        enable = admin.enable
        admin.enable = lambda uid: (_ for _ in ()).throw(RuntimeError('offline'))
        claims['auth_time'] = 87399
        with self.assertRaises(RuntimeError):
            service.cancel(claims)
        now[0] = 87460
        self.assertEqual(sweep(service), 1)
        self.assertEqual(store.get('alice')['state'], 'cancelled')
        self.assertEqual(store.get('alice')['next_attempt'], 87580)
        self.assertEqual(sweep(service), 0)
        admin.enable = enable
        now[0] = 87580
        self.assertEqual(sweep(service), 0)
        self.assertFalse(admin.users['alice']['disabled'])
        self.assertIn('alice', data.profiles)
        self.assertEqual(store.due(now[0]), [])
