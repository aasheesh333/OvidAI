import base64
import io
import json
import tempfile
import unittest
from decimal import Decimal, localcontext
from pathlib import Path

import httpx
from PIL import Image

from server.images.inferhub import InferHub
from server.images.service import Backend, ImageError, ImageService, Ledger, money


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'images.db'
        self.ledger = Ledger(self.path)
        image = io.BytesIO()
        Image.new('RGB', (2, 2), 'red').save(image, 'PNG')
        self.encoded = base64.b64encode(image.getvalue()).decode()
        self.body = {'model': 'ovid-image', 'prompt': 'square'}
        self.backends = [Backend('fixture-a', ('1024x1024',), True),
                         Backend('fixture-b', ('1024x1024',), True)]
        self.calls = []

    def upstream(self, request):
        self.calls.append(request)
        return httpx.Response(200, content=(
            '{"data":[{"b64_json":' + json.dumps(self.encoded) + '}],'
            '"usage":{"cost":0.12345678901234567890123456789}}'))

    def service(self, handler=None, ledger=None):
        client = httpx.Client(transport=httpx.MockTransport(handler or self.upstream))
        self.addCleanup(client.close)
        return ImageService(self.backends, ledger or self.ledger,
                            InferHub('fixture-secret', client), Decimal('1'))

    def execute(self, service, request='request-1234'):
        return service.execute('owner', request, 'generate', self.body, Decimal('10'))

    def test_numeric_provider_cost_and_receipt_survive_restart_exactly(self):
        # JSON float parsing OR ambient Decimal precision would lose these digits.
        with localcontext() as context:
            context.prec = 6
            first = self.execute(self.service())
        receipt = first.get('receipt', {})
        self.assertEqual(receipt.get('charged'), '0.0370370367037037036703703703670')
        self.assertEqual(receipt['account_id'], 'owner')
        self.assertEqual(receipt['request_id'], 'request-1234')
        self.assertEqual(receipt['state'], 'confirmed')
        self.assertRegex(receipt['fingerprint'], r'^[0-9a-f]{64}$')
        restarted = Ledger(self.path)
        self.assertEqual(self.execute(self.service(ledger=restarted)), first)
        self.assertEqual(restarted.receipt('owner', 'request-1234'), receipt)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(restarted.spent('owner'), Decimal('0.0370370367037037036703703703670'))
        self.assertNotIn('fixture', json.dumps(first))

    def test_binary_float_money_is_rejected(self):
        with self.assertRaises(ImageError):
            money(0.12345678901234568)

    def test_duplicate_reordered_settlement_returns_first_durable_result(self):
        first = self.execute(self.service())
        other = {'model': 'ovid-image', 'data': [{'b64_json': 'different'}]}
        replay = self.ledger.settle('owner', 'request-1234', Decimal('9'), other)
        self.assertEqual(replay, first)
        self.ledger.fail('owner', 'request-1234')
        self.assertEqual(self.execute(self.service()), first)
        self.assertEqual(self.ledger.spent('owner'), Decimal('0.0370370367037037036703703703670'))

    def test_gateway_500_or_503_may_be_paid_and_never_release_or_fallback(self):
        for status in (500, 503):
            with self.subTest(status=status):
                request_id = 'request-' + str(status)
                before = len(self.calls)

                def response(request):
                    self.calls.append(request)
                    return httpx.Response(status)

                with self.assertRaises(ImageError) as caught:
                    self.execute(self.service(response), request_id)
                self.assertEqual(caught.exception.code, 'image_request_pending')
                receipt = self.ledger.receipt('owner', request_id)
                self.assertEqual(receipt['state'], 'unknown')
                self.assertIsNone(receipt['charged'])
                with self.assertRaises(ImageError):
                    self.execute(self.service(ledger=Ledger(self.path)), request_id)
                self.assertEqual(len(self.calls), before + 1)
        self.assertEqual(self.ledger.spent('owner', include_pending=True), Decimal('0.60'))

    def test_malformed_success_exposes_unknown_receipt_without_resubmission(self):
        def malformed(request):
            self.calls.append(request)
            return httpx.Response(200, json={'data': [], 'usage': {'cost': '0.1'}})

        with self.assertRaises(ImageError) as caught:
            self.execute(self.service(malformed))
        self.assertEqual(getattr(caught.exception, 'receipt', {}).get('state'), 'unknown')
        with self.assertRaises(ImageError):
            self.execute(self.service(ledger=Ledger(self.path)))
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.ledger.spent('owner', include_pending=True), Decimal('0.30'))

    def test_settlement_storage_failure_is_unknown_and_restart_does_not_send(self):
        class UnwritableSettlement(Ledger):
            def settle(self, *args):
                raise OSError('fixture disk failure')

        with self.assertRaises(ImageError) as caught:
            self.execute(self.service(ledger=UnwritableSettlement(self.path)))
        self.assertEqual(caught.exception.code, 'image_request_pending')
        self.assertEqual(caught.exception.receipt['state'], 'unknown')
        with self.assertRaises(ImageError):
            self.execute(self.service(ledger=Ledger(self.path)))
        self.assertEqual(len(self.calls), 1)

    def test_budget_comparison_does_not_round_away_a_small_overdraw(self):
        self.ledger.begin('owner', 'already-paid', 'fp', Decimal('1'), Decimal('2'), 'default')
        self.ledger.settle('owner', 'already-paid', Decimal('0.00000000000000000000000000001'), {})
        with localcontext() as context:
            context.prec = 6
            with self.assertRaises(ImageError) as caught:
                self.service().execute('owner', 'request-1234', 'generate', self.body, Decimal('0.30'))
        self.assertEqual(caught.exception.code, 'image_limit_reached')
        self.assertEqual(self.calls, [])

    def test_lost_settlement_ack_replays_committed_receipt_without_resubmission(self):
        class LostAck(Ledger):
            def settle(self, *args):
                super().settle(*args)
                raise OSError('fixture lost commit ack')

        with self.assertRaises(ImageError) as caught:
            self.execute(self.service(ledger=LostAck(self.path)))
        self.assertEqual(caught.exception.receipt['state'], 'confirmed')
        restarted = Ledger(self.path)
        self.assertEqual(self.execute(self.service(ledger=restarted))['receipt'], caught.exception.receipt)
        self.assertEqual(len(self.calls), 1)


if __name__ == '__main__':
    unittest.main()
