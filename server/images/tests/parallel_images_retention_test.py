import sqlite3
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from decimal import Decimal
from types import SimpleNamespace
import threading

from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.images.service import ImageError, ImageService, Ledger, UpstreamNotAccepted
from server.images.verifier import Identity, mount_images
import parallel_images_receipts_test as fixtures


class RetentionTests(unittest.TestCase):
    setUp = fixtures.ReceiptTests.setUp
    upstream = fixtures.ReceiptTests.upstream
    service = fixtures.ReceiptTests.service
    execute = fixtures.ReceiptTests.execute

    def timed_ledger(self):
        self.now = 1000
        self.ledger = Ledger(self.path, clock=lambda: self.now,
                             replay_retention=10, receipt_retention=20)

    def test_expired_blobs_and_receipts_leave_non_billable_tombstone(self):
        self.timed_ledger()
        first = self.execute(self.service())
        self.now = 1010
        with self.assertRaises(ImageError) as caught:
            self.execute(self.service())
        self.assertEqual(caught.exception.code, 'image_replay_expired')
        self.assertEqual(self.ledger.receipt('owner', 'request-1234')['charged'], first['receipt']['charged'])
        self.ledger.purge_expired()
        with self.ledger.connect() as db:
            self.assertIsNone(db.execute('SELECT response FROM image_jobs').fetchone()[0])
        self.now = 1020
        self.ledger.purge_expired()
        with self.assertRaises(ImageError) as caught:
            self.ledger.receipt('owner', 'request-1234')
        self.assertEqual(caught.exception.status, 410)
        restarted = Ledger(self.path, clock=lambda: self.now)
        with self.assertRaises(ImageError) as caught:
            self.execute(self.service(ledger=restarted))
        self.assertEqual(caught.exception.code, 'image_replay_expired')
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(restarted.spent('owner'), Decimal('0.0370370367037037036703703703670'))

    def test_pending_reservation_does_not_expire_or_allow_window_reset_overdraw(self):
        self.timed_ledger()
        self.ledger.begin('owner', 'pending-1234', 'fingerprint', Decimal('0.30'), Decimal('1'), 'old')
        self.now += 100000
        self.ledger.purge_expired()
        self.assertEqual(self.ledger.receipt('owner', 'pending-1234')['state'], 'pending')
        with self.assertRaises(ImageError) as caught:
            self.service().execute('owner', 'new-request', 'generate', self.body, Decimal('0.59'), budget_window='new')
        self.assertEqual(caught.exception.code, 'image_limit_reached')
        self.assertEqual(self.calls, [])

    def test_delete_during_pending_job_fences_late_output_and_all_new_requests(self):
        started, finish = threading.Event(), threading.Event()

        def send(backend, operation, payload):
            self.calls.append(payload)
            started.set()
            self.assertTrue(finish.wait(5))
            return {'data': [{'b64_json': self.encoded}], 'usage': {'cost': '0.10'}}

        service = ImageService(self.backends, self.ledger, send, Decimal('1'))
        with ThreadPoolExecutor() as pool:
            future = pool.submit(self.execute, service)
            self.assertTrue(started.wait(5))
            try:
                self.ledger.delete_account('owner')
                self.ledger.delete_account('owner')
            finally:
                finish.set()
            with self.assertRaises(ImageError) as caught:
                future.result()
        self.assertEqual(caught.exception.code, 'image_account_deleted')
        restarted = Ledger(self.path)
        for request in ('request-1234', 'new-request'):
            with self.assertRaises(ImageError) as caught:
                self.execute(self.service(ledger=restarted), request)
            self.assertEqual(caught.exception.code, 'image_account_deleted')
        with restarted.connect() as db:
            self.assertIsNone(db.execute('SELECT response FROM image_jobs').fetchone()[0])
        self.assertEqual(restarted.spent('owner'), Decimal('0.0300'))
        self.assertEqual(len(self.calls), 1)

    def test_deletion_clears_completed_blobs_but_preserves_unknown_reservation(self):
        self.execute(self.service())
        self.ledger.begin('owner', 'pending-1234', 'fingerprint', Decimal('0.30'), Decimal('10'), 'old')
        self.ledger.unknown('owner', 'pending-1234')
        self.ledger.delete_account('owner')
        with self.ledger.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM image_jobs WHERE response IS NOT NULL').fetchone()[0], 0)
        self.assertEqual(self.ledger.spent('owner', include_pending=True), Decimal('0.3370370367037037036703703703670'))
        with self.assertRaises(ImageError) as caught:
            self.ledger.receipt('owner', 'request-1234')
        self.assertEqual(caught.exception.status, 410)

    def test_deletion_after_refusal_fences_next_backend_submission(self):
        def send(backend, operation, payload):
            self.calls.append(payload)
            self.ledger.delete_account('owner')
            # Synthetic verified pre-submission rejection, not an HTTP status.
            raise UpstreamNotAccepted(429)

        with self.assertRaises(ImageError) as caught:
            self.execute(ImageService(self.backends, self.ledger, send, Decimal('1')))
        self.assertEqual(caught.exception.code, 'image_account_deleted')
        self.assertEqual(len(self.calls), 1)

    def test_legacy_ledger_migration_retains_paid_dedup_and_pending_reservation(self):
        legacy = self.path.with_name('legacy.db')
        with sqlite3.connect(legacy) as db:
            db.execute('''CREATE TABLE image_jobs (
                account TEXT NOT NULL, request TEXT NOT NULL, fingerprint TEXT NOT NULL,
                state TEXT NOT NULL, reserved TEXT NOT NULL, charged TEXT NOT NULL DEFAULT '0',
                actual TEXT, response TEXT, budget_window TEXT NOT NULL,
                PRIMARY KEY(account, request))''')
            db.execute("INSERT INTO image_jobs VALUES ('owner','legacy-paid','fp','done','0.30','0.03','0.1','{}','old')")
            db.execute("INSERT INTO image_jobs VALUES ('owner','legacy-pending','fp','pending','0.30','0',NULL,NULL,'old')")
        ledger = Ledger(legacy)
        self.assertEqual(ledger.receipt('owner', 'legacy-paid')['charged'], '0.03')
        with self.assertRaises(ImageError) as caught:
            ledger.begin('owner', 'legacy-paid', 'fp', Decimal('0.30'), Decimal('1'), 'new')
        self.assertEqual(caught.exception.code, 'image_replay_expired')
        self.assertEqual(ledger.spent('owner', include_pending=True), Decimal('0.33'))


class ReceiptRouteTests(unittest.TestCase):
    setUp = fixtures.ReceiptTests.setUp
    upstream = fixtures.ReceiptTests.upstream
    service = fixtures.ReceiptTests.service
    execute = fixtures.ReceiptTests.execute

    def app(self, service, wired=True):
        app = FastAPI()

        def auth(headers):
            uid = headers.get('authorization')
            if uid not in ('owner', 'other'):
                raise ImageError(401, 'sign_in_required')
            return Identity(uid, 'fixture-key', 'paid')

        @contextmanager
        def admission(identity):
            yield 'window', Decimal('10')

        mount_images(SimpleNamespace(app=app), service, auth=auth,
                     admission=admission if wired else None)
        return app

    def test_status_is_authenticated_account_scoped_read_only_and_no_store(self):
        service = self.service()
        result = self.execute(service)
        with TestClient(self.app(service)) as client:
            path = '/v1/images/requests/request-1234'
            self.assertEqual(client.get(path).status_code, 401)
            self.assertEqual(client.get(path, headers={'authorization': 'other'}).status_code, 404)
            response = client.get(path, headers={'authorization': 'owner'})
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json(), {'receipt': result['receipt']})
            self.assertEqual(response.headers['cache-control'], 'no-store')
            self.assertEqual(client.get(path, headers={'authorization': 'revoked'}).status_code, 401)
        self.assertEqual(len(self.calls), 1)

    def test_ambiguous_http_response_contains_receipt_and_status_recovers_it(self):
        def disconnected(request):
            self.calls.append(request)
            raise TimeoutError('accepted then disconnected')

        with TestClient(self.app(self.service(disconnected))) as client:
            headers = {'authorization': 'owner', 'idempotency-key': 'request-1234'}
            response = client.post('/v1/images/generations', json=self.body, headers=headers)
            self.assertEqual(response.status_code, 409)
            receipt = response.json().get('receipt', {})
            self.assertEqual(receipt.get('state'), 'unknown')
            self.assertEqual(response.headers['cache-control'], 'no-store')
            status = client.get('/v1/images/requests/request-1234', headers=headers)
            self.assertEqual(status.json(), {'receipt': receipt})
            client.post('/v1/images/generations', json=self.body, headers=headers)
        self.assertEqual(len(self.calls), 1)

    def test_status_stays_closed_without_authority_even_with_local_receipt(self):
        service = self.service()
        self.execute(service)
        with TestClient(self.app(service, wired=False)) as client:
            response = client.get('/v1/images/requests/request-1234', headers={'authorization': 'owner'})
            self.assertEqual(response.status_code, 503)
            self.assertNotIn('receipt', response.json())


if __name__ == '__main__':
    unittest.main()
