"""Product-contract tests for the 24-hour account-deletion grace facade."""

import unittest

from server.account.deletion import (
    GRACE_SECONDS,
    PLAY_SUBSCRIPTION_MANAGEMENT_URL,
    AccountDeletion,
    DeletionService,
    process_expired,
    sweep,
)
from server.account.deletion_worker import run_once
from server.account.domain import AccountError
from test_lifecycle import Admin, Data, MemoryStore


class DeletionGraceTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        self.store, self.admin, self.data = MemoryStore(), Admin(), Data()
        self.service = AccountDeletion.compose(
            self.store, self.admin, self.data, clock=lambda: self.now)
        self.claims = {'uid': 'alice', 'auth_time': 1000,
                       'firebase': {'sign_in_provider': 'google.com'}}

    def sign_in(self, at=None):
        if at is not None:
            self.now = at
        self.claims['auth_time'] = self.now
        return self.service.sign_in(self.claims)

    def test_request_sets_pending_deadline_grace_and_play_link(self):
        receipt = self.service.request_deletion(self.claims, 'request-0001')

        self.assertEqual(receipt['state'], 'pending')
        self.assertEqual(receipt['delete_after'], 1000 + 24 * 60 * 60)
        self.assertEqual(receipt['delete_after'] - 1000, GRACE_SECONDS)
        self.assertEqual(receipt['grace_seconds'], 86400)
        self.assertTrue(receipt['can_restore'])
        self.assertTrue(receipt['restore_requires_sign_in'])
        self.assertFalse(receipt['subscription_cancelled_automatically'])
        self.assertEqual(receipt['manage_subscription_url'],
                         PLAY_SUBSCRIPTION_MANAGEMENT_URL)
        self.assertEqual(receipt['manage_subscription_url'],
                         'https://play.google.com/store/account/subscriptions')

        row = self.store.get('alice')
        self.assertEqual(row['state'], 'pending')
        self.assertEqual(row['delete_after'], receipt['delete_after'])

    def test_duplicate_request_never_extends_the_grace_deadline(self):
        first = self.service.request_deletion(self.claims, 'request-0001')
        self.now = 2000
        later = self.service.request_deletion(
            {**self.claims, 'auth_time': 2000}, 'request-0002')

        self.assertEqual(first, later)
        self.assertEqual(later['delete_after'], 87400)
        self.assertEqual(self.store.get('alice')['state'], 'pending')

    def test_sign_in_reports_restore_without_mutating_then_restore_cancels(self):
        self.service.request_deletion(self.claims, 'request-0001')

        signed_in = self.sign_in(2000)
        self.assertEqual(signed_in['state'], 'pending')
        self.assertTrue(signed_in['can_restore'])
        self.assertEqual(self.store.get('alice')['state'], 'pending')

        restored = self.service.restore(self.claims)
        self.assertEqual(restored['state'], 'cancelled')
        self.assertTrue(restored['restored'])
        self.assertFalse(restored['can_restore'])
        self.assertEqual(restored['manage_subscription_url'],
                         PLAY_SUBSCRIPTION_MANAGEMENT_URL)
        self.assertFalse(self.admin.users['alice']['disabled'])
        self.assertIn('alice', self.data.keys)
        self.assertIn('alice', self.data.profiles)

    def test_sign_in_and_restore_is_the_explicit_two_step_ux(self):
        self.service.request_deletion(self.claims, 'request-0001')
        self.now = 2000
        receipt = self.service.sign_in_and_restore({**self.claims, 'auth_time': 2000})

        self.assertEqual(receipt['state'], 'cancelled')
        self.assertTrue(receipt['restored'])

        # The account is still usable long after the original deadline.
        self.now = 200_000
        self.assertEqual(sweep(self.service), 0)
        self.assertIn('alice', self.admin.users)
        self.assertIn('alice', self.data.profiles)

    def test_restore_is_allowed_at_the_deadline_and_rejected_after_it(self):
        self.service.request_deletion(self.claims, 'request-0001')
        self.now = 87400
        self.claims['auth_time'] = 87400
        self.assertEqual(self.service.restore(self.claims)['state'], 'cancelled')

        self.store.rows.clear()
        self.now = 1000
        self.service.request_deletion(
            {**self.claims, 'auth_time': 1000}, 'request-0002')
        self.now = 87401
        self.claims['auth_time'] = 87401
        with self.assertRaisesRegex(AccountError, 'deletion_in_progress'):
            self.service.restore(self.claims)
        self.assertEqual(self.store.get('alice')['state'], 'pending')

    def test_sign_in_after_the_deadline_offers_no_restore(self):
        self.service.request_deletion(self.claims, 'request-0001')
        receipt = self.sign_in(87401)
        self.assertEqual(receipt['state'], 'pending')
        self.assertFalse(receipt['can_restore'])
        self.assertEqual(self.store.get('alice')['state'], 'pending')

    def test_worker_fences_then_hard_deletes_after_the_deadline(self):
        self.service.request_deletion(self.claims, 'request-0001')

        self.now = 87399
        self.assertEqual(sweep(self.service), 0)
        self.assertEqual(self.store.get('alice')['state'], 'pending')
        self.assertIn('alice', self.admin.users)

        self.now = 87400
        self.assertEqual(sweep(self.service), 0)
        row = self.store.get('alice')
        self.assertEqual(row['state'], 'fenced')
        self.assertTrue(self.admin.users['alice']['disabled'])
        # Settlement starts only after the disable succeeded.
        self.assertEqual(row['fence_at'], 87400)
        self.assertIn('alice', self.data.keys)

        self.now = 87460
        self.assertEqual(sweep(self.service), 0)
        self.assertEqual(self.store.get('alice')['state'], 'deleted')
        self.assertNotIn('alice', self.admin.users)
        self.assertNotIn('alice', self.data.keys)
        self.assertNotIn('alice', self.data.profiles)
        self.assertEqual(self.data.keys['bob'], ['key-b'])
        self.assertEqual(sweep(self.service), 0)

    def test_expiry_worker_entrypoint_uses_the_same_sweep(self):
        self.service.request_deletion(self.claims, 'request-0001')
        self.now = 87400
        self.assertEqual(run_once(self.service), 0)
        self.assertEqual(self.store.get('alice')['state'], 'fenced')
        self.now = 87460
        self.assertEqual(run_once(self.service), 0)
        self.assertEqual(self.store.get('alice')['state'], 'deleted')

    def test_restore_inside_worker_settlement_reenables_the_account(self):
        self.service.request_deletion(self.claims, 'request-0001')
        self.now = 87400
        self.service.expire('alice')
        self.assertTrue(self.admin.users['alice']['disabled'])

        self.now = 87410
        self.claims['auth_time'] = 87410
        receipt = self.service.restore(self.claims)
        self.assertEqual(receipt['state'], 'cancelled')
        self.assertTrue(receipt['restored'])
        self.assertFalse(self.admin.users['alice']['disabled'])

        self.now = 200_000
        self.assertEqual(sweep(self.service), 0)
        self.assertIn('alice', self.admin.users)
        self.assertIn('alice', self.data.profiles)

    def test_failed_cleanup_is_retried_by_a_later_sweep(self):
        self.service.request_deletion(self.claims, 'request-0001')
        self.now = 87400
        sweep(self.service)
        self.data.fail = True
        self.now = 87460
        self.assertEqual(sweep(self.service), 1)
        self.assertEqual(self.store.get('alice')['state'], 'deleting')
        self.assertIn('alice', self.admin.users)

        self.data.fail = False
        self.now = self.store.get('alice')['next_attempt']
        self.assertEqual(sweep(self.service), 0)
        self.assertEqual(self.store.get('alice')['state'], 'deleted')
        self.assertNotIn('alice', self.admin.users)

    def test_every_receipt_carries_the_play_subscription_link(self):
        active = self.service.status(self.claims)
        self.assertEqual(active['state'], 'active')
        self.assertEqual(active['manage_subscription_url'],
                         PLAY_SUBSCRIPTION_MANAGEMENT_URL)

        self.service.request_deletion(self.claims, 'request-0001')
        pending = self.service.status(self.claims)
        self.assertEqual(pending['manage_subscription_url'],
                         PLAY_SUBSCRIPTION_MANAGEMENT_URL)

        pending = self.sign_in(2000)
        cancelled = self.service.cancel_deletion(self.claims)
        for receipt in (pending, cancelled):
            self.assertEqual(receipt['manage_subscription_url'],
                             PLAY_SUBSCRIPTION_MANAGEMENT_URL)

    def test_service_alias_and_process_expired_alias(self):
        self.assertIs(DeletionService, AccountDeletion)
        self.service.request_deletion(self.claims, 'request-0001')
        self.now = 87400
        self.assertEqual(process_expired(self.service), 0)
        self.now = 87460
        self.assertEqual(process_expired(self.service), 0)
        self.assertEqual(self.store.get('alice')['state'], 'deleted')


if __name__ == '__main__':
    unittest.main()
