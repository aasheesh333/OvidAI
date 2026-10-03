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
             'firebase': {'sign_in_provider': 'password'}}, 'request-0001')
        now[0] = 87400
        restarted = Lifecycle(store, admin, data, lambda: now[0])
        self.assertEqual(sweep(restarted), 0)
        self.assertIn('alice', admin.users)
        now[0] += 61
        self.assertEqual(sweep(restarted), 0)
        self.assertNotIn('alice', admin.users)
        self.assertEqual(sweep(restarted), 0)
