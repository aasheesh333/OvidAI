"""Gateway settlement from header / usage tokens / spend delta (fakes only)."""
import base64
import io
import json
import types
import unittest
from decimal import Decimal
from pathlib import Path
import tempfile
from unittest.mock import patch

import httpx
from PIL import Image

from server.images import costing
from server.images.service import ImageError, Ledger
from server.images.tests.test_gateway_admission import load_gateway

USAGE = {'total_tokens': 1296, 'input_tokens': 6, 'output_tokens': 1290}
INFO = {'data': [{'model_name': 'image-a', 'model_info': {
    'input_cost_per_token': 9e-08, 'output_cost_per_token': 9e-06}}]}


def png():
    out = io.BytesIO()
    Image.new('RGB', (8, 8), 'red').save(out, 'PNG')
    return base64.b64encode(out.getvalue()).decode()


class GatewayCostingTest(unittest.TestCase):
    def setUp(self):
        self.gateway = load_gateway()
        self.gateway.SPEND_RETRY_SECONDS = 0
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = Ledger(Path(self.tmp.name) / 'images.sqlite')
        backends = [self.gateway._Backend('image-a', ['1024x1024'], True),
                    self.gateway._Backend('image-b', ['1024x1024'], True)]
        self.service = self.gateway.LiteLLMImageService(
            types.SimpleNamespace(backends=lambda: backends), self.ledger)
        self.info, self.spends, self.info_calls = INFO, [0, 0], 0

    def run_job(self, reply, request='req-cost-1', info=None):
        if info is not None:
            self.info = info
        spends = list(self.spends)

        def handle(request_):
            path = request_.url.path
            if path == '/key/info':
                return httpx.Response(200, json={'info': {'spend': spends.pop(0) if len(spends) > 1 else spends[0]}})
            if path == '/model/info':
                self.info_calls += 1
                return httpx.Response(200, json=self.info)
            return reply
        client = httpx.Client
        self.gateway._PRICES = costing.PriceBook(self.gateway._fetch_model_info, background=False)
        with patch.object(self.gateway.httpx, 'Client', side_effect=lambda **kw: client(
                **kw, transport=httpx.MockTransport(handle))):
            return self.service.execute('owner', request, 'generate', {
                'model': 'ovid-image', 'prompt': 'red', 'size': '1024x1024'}, Decimal('10'))

    def reply(self, headers=None, usage=USAGE):
        body = {'data': [{'b64_json': png()}]}
        if usage is not None:
            body['usage'] = usage
        return httpx.Response(200, json=body, headers=headers or {})

    def test_tokens_no_header_zero_spend_settles_done_with_image(self):
        result = self.run_job(self.reply())
        self.assertEqual(result['receipt']['state'], 'confirmed')
        actual = Decimal('6') * Decimal('9e-08') + Decimal('1290') * Decimal('9e-06')
        self.assertEqual(Decimal(result['receipt']['charged']), actual * Decimal('0.30'))
        self.assertTrue(result['data'][0]['b64_json'])

    def test_header_path(self):
        result = self.run_job(self.reply({'x-litellm-response-cost': '0.0017928'}))
        self.assertEqual(Decimal(result['receipt']['charged']), Decimal('0.0017928') * Decimal('0.30'))
        self.assertEqual(self.info_calls, 0)

    def test_cap_path(self):
        result = self.run_job(self.reply({'x-litellm-response-cost': '50'}))
        self.assertEqual(Decimal(result['receipt']['charged']), self.gateway.MAX_UPSTREAM_USD * Decimal('0.30'))

    def test_spend_delta_still_third_source(self):
        self.spends = [1.0, 1.25]
        result = self.run_job(self.reply(usage=None), info={'data': []})
        self.assertEqual(Decimal(result['receipt']['charged']), Decimal('0.25') * Decimal('0.30'))

    def test_no_usable_cost_ends_pending(self):
        with self.assertRaises(ImageError) as caught:
            self.run_job(self.reply(usage=None), info={'data': []})
        self.assertEqual(caught.exception.code, 'image_request_pending')
        self.assertEqual(caught.exception.receipt['state'], 'unknown')

    def test_log_line_has_source_and_no_secrets(self):
        with self.assertLogs(self.gateway._LOG, 'INFO') as logs:
            self.run_job(self.reply())
        line = next(l for l in logs.output if 'image_cost' in l)
        self.assertIn('source=tokens', line)
        self.assertNotIn('test-key', line)


if __name__ == '__main__':
    unittest.main()
