"""Exercise the deployed gateway, including its HTTP boundary and real ledger."""
import importlib.util
import base64
import io
import json
import os
import sys
import tempfile
import types
import unittest
from concurrent.futures import ThreadPoolExecutor
from threading import Event
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

import httpx
from PIL import Image

from server.images.service import ImageError, Ledger


def load_gateway():
    # The deployed module mounts into mint on import. Supply an already-mounted
    # host so tests don't start services, read secrets, or touch the live ledger.
    host = types.SimpleNamespace(
        app=types.SimpleNamespace(state=types.SimpleNamespace(ovid_images_mounted=True)),
        rds=types.SimpleNamespace(get=lambda key: 'test-key'),
    )
    spec = importlib.util.spec_from_file_location(
        'gateway_under_test',
        os.environ.get('OVID_TEST_GATEWAY_PATH') or
        Path(__file__).parents[1] / 'deploy' / 'images_gateway.py',
    )
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, mint=host), patch.dict(os.environ, LITELLM_MASTER_KEY='test'):
        spec.loader.exec_module(module)
    return module


class GatewayAdmissionTest(unittest.TestCase):
    def setUp(self):
        self.gateway = load_gateway()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = Ledger(Path(self.tmp.name) / 'images.sqlite')
        backends = [self.gateway._Backend(name, ['1024x1024'], True)
                    for name in ('image-a', 'image-b')]
        self.service = self.gateway.LiteLLMImageService(
            types.SimpleNamespace(backends=lambda: backends), self.ledger)
        self.calls = []
        self.spend = 0

    def execute(self, request='request-1234'):
        return self.service.execute('owner', request, 'generate', {
            'model': 'ovid-image', 'prompt': 'red square', 'size': '1024x1024',
        }, Decimal('10'))

    def transport(self, responses):
        def handle(request):
            if request.url.path == '/key/info':
                return httpx.Response(200, json={'info': {'spend': self.spend}})
            self.calls.append(json.loads(request.content)['model'])
            value = responses.pop(0)
            if isinstance(value, Exception):
                raise value
            if callable(value):
                value = value()
            if value.status_code == 200:
                self.spend = 0.1
            return value
        client = httpx.Client
        return patch.object(self.gateway.httpx, 'Client',
                            side_effect=lambda **kwargs: client(
                                **kwargs, transport=httpx.MockTransport(handle)))

    @staticmethod
    def no_capacity(model):
        # LiteLLM wraps the upstream structured no_capacity in its public
        # service-unavailable envelope; this matches the observed incident.
        return httpx.Response(503, json={'error': {
            'message': 'litellm.ServiceUnavailableError: ServiceUnavailableError: '
                       f'OpenAIException - no available provider for {model} '
                       '(all offers exhausted or in cooldown); try again shortly',
            'type': 'service_unavailable_error', 'param': None, 'code': '503',
        }})

    def test_exhausted_capacity_falls_back_and_returns_terminal_zero_receipt(self):
        with self.transport([self.no_capacity('image-a'), self.no_capacity('image-b')]):
            with self.assertRaises(ImageError) as caught:
                self.execute()
        self.assertEqual(self.calls, ['image-a', 'image-b'])
        self.assertEqual(caught.exception.code, 'image_unavailable')
        self.assertEqual(caught.exception.receipt['state'], 'failed')
        self.assertEqual(caught.exception.receipt['charged'], '0')
        self.assertEqual(self.ledger.spent('owner', include_pending=True), Decimal('0'))
        # Repeating the old ID never makes another upstream request.
        with self.transport([]), self.assertRaises(ImageError) as replay:
            self.execute()
        self.assertEqual(replay.exception.receipt['state'], 'failed')

    def test_structured_no_capacity_allows_fallback(self):
        with self.transport([
            httpx.Response(503, json={'error': {'type': 'no_capacity', 'message': 'Unavailable'}}),
            httpx.Response(404, json={'error': {'code': 'model_not_found'}}),
        ]), self.assertRaises(ImageError) as caught:
            self.execute()
        self.assertEqual(self.calls, ['image-a', 'image-b'])
        self.assertEqual(caught.exception.receipt['state'], 'failed')

    def test_ambiguous_failure_never_falls_back_or_releases_reservation(self):
        cases = [
            httpx.Response(503, json={'error': {'message': 'upstream disconnected'}}),
            httpx.Response(503, text='<html>gateway unavailable</html>'),
            httpx.Response(503, json={'error': {'message': 'no_capacity'}}),
            self.no_capacity('another-model'),
            httpx.Response(500, json={'error': {'type': 'no_capacity'}}),
            httpx.ReadTimeout('lost response'),
        ]
        for index, response in enumerate(cases):
            with self.subTest(index=index), self.transport([response]):
                self.calls.clear()
                with self.assertRaises(ImageError) as caught:
                    self.execute(f'uncertain-{index}')
                self.assertEqual(self.calls, ['image-a'])
                self.assertEqual(caught.exception.receipt['state'], 'unknown')
                self.assertIsNone(caught.exception.receipt['charged'])

    def test_non_capacity_failure_after_fallback_remains_unknown(self):
        with self.transport([self.no_capacity('image-a'), httpx.Response(502)]):
            with self.assertRaises(ImageError) as caught:
                self.execute()
        self.assertEqual(self.calls, ['image-a', 'image-b'])
        self.assertEqual(caught.exception.receipt['state'], 'unknown')

    def test_successful_fallback_has_one_receipt_and_replays_without_paid_call(self):
        out = io.BytesIO()
        Image.new('RGB', (8, 8), 'red').save(out, 'PNG')
        encoded = base64.b64encode(out.getvalue()).decode()
        with self.transport([self.no_capacity('image-a'), httpx.Response(
                200, json={'data': [{'b64_json': encoded}]})]):
            result = self.execute()
        self.assertEqual(self.calls, ['image-a', 'image-b'])
        self.assertEqual(result['receipt']['state'], 'confirmed')
        self.assertEqual(Decimal(result['receipt']['charged']), Decimal('0.03'))
        self.assertEqual(result['data'][0]['b64_json'], encoded)
        with self.transport([]):
            self.assertEqual(self.execute(), result)

    def test_concurrent_same_id_never_submits_twice(self):
        entered, release = Event(), Event()

        def wait_for_release():
            entered.set()
            if not release.wait(5):
                raise RuntimeError('test synchronization timed out')
            return httpx.Response(503)

        with self.transport([wait_for_release]), ThreadPoolExecutor(2) as pool:
            first = pool.submit(self.execute)
            try:
                self.assertTrue(entered.wait(5))
                with self.assertRaises(ImageError) as duplicate:
                    self.execute()
                self.assertEqual(duplicate.exception.receipt['state'], 'pending')
                self.assertEqual(self.calls, ['image-a'])
            finally:
                release.set()
            with self.assertRaises(ImageError):
                first.result(timeout=5)


if __name__ == '__main__':
    unittest.main()
