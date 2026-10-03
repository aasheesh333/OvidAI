import unittest
from contextlib import contextmanager
from decimal import Decimal
from types import SimpleNamespace

import httpx
from fastapi import FastAPI
from fastapi.testclient import TestClient

from server.images.service import ImageError, ImageService, Ledger, UpstreamError
from server.images.verifier import VerifierAuth, mount_images
import parallel_images_receipts_test as fixtures


class Round1Tests(unittest.TestCase):
    setUp = fixtures.ReceiptTests.setUp
    upstream = fixtures.ReceiptTests.upstream
    service = fixtures.ReceiptTests.service
    execute = fixtures.ReceiptTests.execute

    def test_bare_http_429_preserves_reservation_without_fallback_or_restart_send(self):
        def limited(request):
            self.calls.append(request)
            return httpx.Response(429, headers={'retry-after': '1'})

        with self.assertRaises(ImageError) as caught:
            self.execute(self.service(limited))
        self.assertEqual(caught.exception.receipt['state'], 'unknown')
        self.assertEqual(self.ledger.spent('owner', include_pending=True), Decimal('0.30'))
        with self.assertRaises(ImageError):
            self.execute(self.service(ledger=Ledger(self.path)))
        self.assertEqual(len(self.calls), 1)

    def test_status_only_adapter_errors_are_not_verified_nonacceptance(self):
        for status in (429, 503, 400):
            with self.subTest(status=status):
                calls = []

                def send(*args):
                    calls.append(args)
                    raise UpstreamError(status)

                service = ImageService(self.backends, self.ledger, send, Decimal('1'))
                request = 'request-' + str(status)
                with self.assertRaises(ImageError) as caught:
                    self.execute(service, request)
                self.assertEqual(caught.exception.receipt['state'], 'unknown')
                with self.assertRaises(ImageError):
                    self.execute(service, request)
                self.assertEqual(len(calls), 1)
        self.assertEqual(self.ledger.spent('owner', include_pending=True), Decimal('0.90'))

    def test_nonfinite_retention_is_rejected_before_opening_database(self):
        for index, (replay, receipt) in enumerate(((1, float('inf')), (float('inf'), float('inf')),
                                (1, float('nan')), (float('nan'), 2),
                                (0, 2), (-1, 2), (3, 2), (True, 2))):
            with self.subTest(replay=replay, receipt=receipt):
                path = self.path.with_name(f'invalid-policy-{index}.db')
                with self.assertRaises(ValueError):
                    Ledger(path, replay_retention=replay, receipt_retention=receipt)
                self.assertFalse(path.exists())

    def test_production_auth_receipt_read_ignores_zero_budget_but_keeps_security(self):
        service = self.service()
        expected = self.execute(service)['receipt']
        info = {'user_id': 'owner', 'metadata': {'ovid_uid': 'owner'}, 'models': ['ovid-image']}
        keys = {'user:owner:key': 'fixture-key', 'user:owner:keyid': 'fixture-id'}
        quota_reads, admissions = [], []

        def quota(uid):
            quota_reads.append(uid)
            return 0

        mint = SimpleNamespace(app=FastAPI(), APPCHECK_ENABLED=True,
            rds=SimpleNamespace(get=keys.get), LITELLM_MASTER_KEY='fixture-master',
            verify_app_check=lambda token: None,
            verify_google_id_token=lambda token: {'sub': 'owner'},
            is_banned=lambda uid, ip: False, effective_tier=lambda uid: 'free',
            free_cap_remaining=quota)
        key_client = httpx.Client(base_url='http://fixture', transport=httpx.MockTransport(
            lambda request: httpx.Response(200, json={'info': info})))
        self.addCleanup(key_client.close)

        @contextmanager
        def admission(identity):
            admissions.append(identity)
            yield 'window', Decimal('0')

        mount_images(mint, service, auth=VerifierAuth(mint, key_client), admission=admission)
        headers = {'authorization': 'Bearer fixture-token', 'x-ovid-key': 'fixture-key',
                   'x-firebase-appcheck': 'fixture-attest', 'idempotency-key': 'new-request'}
        path = '/v1/images/requests/request-1234'
        with TestClient(mint.app) as client:
            response = client.get(path, headers=headers)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json(), {'receipt': expected})
            self.assertEqual(response.headers['cache-control'], 'no-store')
            self.assertEqual(quota_reads, [])
            self.assertEqual(client.post('/v1/images/generations', json=self.body, headers=headers).status_code, 402)
            self.assertEqual(quota_reads, ['owner'])
            self.assertEqual(admissions, [])
            self.assertEqual(client.get(path).status_code, 401)
            self.assertEqual(client.get(path, headers={**headers, 'x-firebase-appcheck': ''}).status_code, 401)
            for change, status in (({'blocked': True}, 403), ({'models': []}, 403),
                                   ({'user_id': 'other'}, 403), ({'metadata': {}}, 403),
                                   ({'expires': '2000-01-01T00:00:00Z'}, 401)):
                saved = info.copy()
                info.update(change)
                self.assertEqual(client.get(path, headers=headers).status_code, status)
                info.clear()
                info.update(saved)
            keys['user:owner:key'] = 'revoked'
            self.assertEqual(client.get(path, headers=headers).status_code, 401)
            keys['user:owner:key'] = 'fixture-key'
            mint.is_banned = lambda uid, ip: True
            self.assertEqual(client.get(path, headers=headers).status_code, 403)
            mint.is_banned = lambda uid, ip: False
            service.ledger.delete_account('owner')
            self.assertEqual(client.get(path, headers=headers).status_code, 410)
        self.assertEqual(len(self.calls), 1)
