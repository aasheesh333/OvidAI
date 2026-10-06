import base64
import io
import json
import tempfile
import unittest
from decimal import Decimal, localcontext
from pathlib import Path

import httpx
from PIL import Image

from server.images import adapters
from server.images.inferhub import InferHub
from server.images.service import (
    Backend, ImageError, ImageService, Ledger, UpstreamError, UpstreamNotAccepted,
)

SIZES = ('1024x1024', '1536x1024', '1024x1536', '2048x2048')
CONFIGURED = tuple(
    Backend(model, SIZES, True)
    for model in ('cb/gemini-2.5-flash-image', 'cb/gemini-3.1-flash-image', 'cb/gpt-image-2')
)


def png():
    out = io.BytesIO()
    Image.new('RGB', (2, 2), 'red').save(out, 'PNG')
    return base64.b64encode(out.getvalue()).decode()


def success(cost, encoded):
    return httpx.Response(200, content=(
        '{"data":[{"b64_json":' + json.dumps(encoded) + '}],"usage":{"cost":' + cost + '}}'))


class ContractTests(unittest.TestCase):
    def test_repository_config_backends_share_the_contract(self):
        config = json.loads((Path(__file__).resolve().parents[1] / 'config.json').read_text())
        self.assertEqual(config['alias'], 'ovid-image')
        self.assertEqual([row['model'] for row in config['backends']],
                         [backend.model for backend in CONFIGURED])
        for row in config['backends']:
            contract = adapters.ProviderContract(row['model'], tuple(row['sizes']), row['edit'])
            for size in row['sizes']:
                payload = contract.request('generate', {'prompt': 'x'}, size)
                self.assertEqual(payload['model'], row['model'])
                self.assertEqual(payload['size'], size)

    def test_request_shape_matches_documented_oi_contract_for_configured_backends(self):
        for backend in CONFIGURED:
            contract = adapters.ProviderContract(backend.model, backend.sizes, backend.edit)
            for size in SIZES:
                self.assertEqual(
                    contract.request('generate', {'prompt': 'a cat'}, size),
                    {'model': backend.model, 'prompt': 'a cat', 'size': size,
                     'n': 1, 'response_format': 'b64_json'})
            image = 'data:image/png;base64,AA=='
            self.assertEqual(
                contract.request('edit', {'prompt': 'a cat', 'image': image}, '1024x1024'),
                {'model': backend.model, 'prompt': 'a cat', 'size': '1024x1024',
                 'n': 1, 'response_format': 'b64_json', 'image': image})
            self.assertEqual(contract.endpoint('generate'), '/v1/images/generations')
            self.assertEqual(contract.endpoint('edit'), '/v1/images/edits')

    def test_contract_refuses_unsupported_size_operation_and_edit(self):
        contract = adapters.ProviderContract('cb/gpt-image-2', ('1024x1024',), False)
        with self.assertRaises(ValueError):
            contract.request('generate', {'prompt': 'x'}, '2048x2048')
        with self.assertRaises(ValueError):
            contract.request('edit', {'prompt': 'x', 'image': 'data:image/png;base64,AA=='}, '1024x1024')
        with self.assertRaises(ValueError):
            contract.endpoint('animate')
        with self.assertRaises(ValueError):
            adapters.ProviderContract('', ('1024x1024',), True)

    def test_only_structured_documented_refusals_are_verified(self):
        for code in ('not_an_image_model', 'unsupported_modality', 'unsupported_n'):
            self.assertTrue(adapters.is_verified_refusal(400, {'error': {'code': code, 'message': 'x'}}))
        self.assertTrue(adapters.is_verified_refusal(503, {'error': {'code': 'no_provider', 'message': 'x'}}))
        self.assertTrue(adapters.is_verified_refusal(429, {'error': {'code': 'rate_limited', 'message': 'x'}}))
        for status, body in (
                (429, None), (503, None), (500, None),
                (500, {'error': {'code': 'server_error'}}),
                (400, {'error': {'code': 'validation_error'}}),
                (400, {'error': {'code': 'upstream_error'}}),
                (400, {'error': 'nope'}), (400, {}), (400, 'not json')):
            self.assertFalse(adapters.is_verified_refusal(status, body), (status, body))


class InferHubContractTests(unittest.TestCase):
    def invoke(self, response, backend=CONFIGURED[0], operation='generate'):
        seen = []
        client = httpx.Client(transport=httpx.MockTransport(lambda request: (seen.append(request), response)[1]))
        self.addCleanup(client.close)
        hub = InferHub('fixture-secret', client)
        body = {'prompt': 'a cat', 'image': 'data:image/png;base64,AA=='}
        payload = adapters.request_shape(backend.model, operation, body, '1024x1024')
        try:
            return hub(backend, operation, payload), seen
        except Exception as error:
            return error, seen

    def test_typed_signal_only_from_structured_verified_refusal(self):
        for response, status in (
                (httpx.Response(400, json={'error': {'code': 'unsupported_n', 'message': 'x'}}), 400),
                (httpx.Response(503, json={'error': {'code': 'no_provider', 'message': 'x'}}), 503),
                (httpx.Response(429, json={'error': {'code': 'rate_limited', 'message': 'x'}}), 429)):
            error, _ = self.invoke(response)
            self.assertIsInstance(error, UpstreamNotAccepted)
            self.assertEqual(error.status, status)
        for response in (httpx.Response(503), httpx.Response(429), httpx.Response(500),
                         httpx.Response(400, json={'error': {'code': 'validation_error', 'message': 'x'}}),
                         httpx.Response(400, text='not json')):
            error, _ = self.invoke(response)
            self.assertIsInstance(error, UpstreamError)
            self.assertNotIsInstance(error, UpstreamNotAccepted)

    def test_generation_request_url_and_body_match_documented_shape(self):
        result, seen = self.invoke(success('0.5', png()))
        self.assertEqual(result['usage']['cost'], Decimal('0.5'))
        self.assertEqual(len(seen), 1)
        request = seen[0]
        self.assertEqual(request.method, 'POST')
        self.assertEqual(request.url.path, '/v1/images/generations')
        self.assertEqual(json.loads(request.content), {
            'model': CONFIGURED[0].model, 'prompt': 'a cat', 'size': '1024x1024',
            'n': 1, 'response_format': 'b64_json'})
        self.assertEqual(request.headers['authorization'], 'Bearer fixture-secret')


class ServiceContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'images.db'
        self.ledger = Ledger(self.path)
        self.encoded = png()

    def service(self, handler, backends=CONFIGURED[:2], ledger=None):
        client = httpx.Client(transport=httpx.MockTransport(handler))
        self.addCleanup(client.close)
        return ImageService(backends, ledger or self.ledger, InferHub('fixture-secret', client), Decimal('1'))

    def body(self):
        return {'model': 'ovid-image', 'prompt': 'a cat', 'size': '1024x1024'}

    def test_verified_refusal_falls_back_and_charges_once(self):
        posts = []

        def handler(request):
            posts.append(json.loads(request.content))
            if len(posts) == 1:
                return httpx.Response(503, json={'error': {'code': 'no_provider', 'message': 'x'}})
            return success('0.25', self.encoded)

        result = self.service(handler).execute('owner', 'request-1234', 'generate', self.body(), Decimal('10'))
        self.assertEqual(len(posts), 2)
        self.assertEqual(posts[0], {'model': CONFIGURED[0].model, 'prompt': 'a cat',
                                    'size': '1024x1024', 'n': 1, 'response_format': 'b64_json'})
        self.assertEqual(posts[1]['model'], CONFIGURED[1].model)
        self.assertEqual(result['receipt']['state'], 'confirmed')
        self.assertEqual(result['receipt']['charged'], '0.0750')

    def test_verified_pre_provider_refusal_falls_back_to_next_backend(self):
        posts = []

        def handler(request):
            posts.append(json.loads(request.content))
            if len(posts) == 1:
                return httpx.Response(400, json={'error': {'code': 'unsupported_modality', 'message': 'x'}})
            return success('0.50', self.encoded)

        result = self.service(handler).execute('owner', 'request-1234', 'generate', self.body(), Decimal('10'))
        self.assertEqual([post['model'] for post in posts], [CONFIGURED[0].model, CONFIGURED[1].model])
        self.assertEqual(result['receipt']['state'], 'confirmed')
        self.assertEqual(result['receipt']['charged'], '0.1500')

    def test_bare_status_never_falls_back_and_keeps_reservation(self):
        posts = []

        def handler(request):
            posts.append(request)
            return httpx.Response(503)

        service = self.service(handler)
        with self.assertRaises(ImageError) as caught:
            service.execute('owner', 'request-1234', 'generate', self.body(), Decimal('10'))
        self.assertEqual(caught.exception.code, 'image_request_pending')
        self.assertEqual(caught.exception.receipt['state'], 'unknown')
        self.assertEqual(len(posts), 1)
        with self.assertRaises(ImageError):
            service.execute('owner', 'request-1234', 'generate', self.body(), Decimal('10'))
        self.assertEqual(len(posts), 1)
        self.assertEqual(self.ledger.spent('owner', include_pending=True), Decimal('0.30'))

    def test_edit_request_carries_one_data_url_and_never_generates(self):
        posts = []

        def handler(request):
            posts.append(request)
            return success('0.10', self.encoded)

        image = 'data:image/png;base64,' + self.encoded
        body = {'model': 'ovid-image', 'prompt': 'a cat', 'size': '1024x1024', 'image': image}
        self.service(handler).execute('owner', 'edit-request-1234', 'edit', body, Decimal('10'))
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0].url.path, '/v1/images/edits')
        self.assertEqual(json.loads(posts[0].content)['image'], image)

    def test_exact_decimal_and_request_id_dedup_survive_restart(self):
        posts = []

        def handler(request):
            posts.append(request)
            return success('0.12345678901234567890123456789', self.encoded)

        with localcontext() as context:
            context.prec = 6
            first = self.service(handler).execute('owner', 'request-1234', 'generate', self.body(), Decimal('10'))
        self.assertEqual(first['receipt']['charged'], '0.0370370367037037036703703703670')
        restarted = Ledger(self.path)
        self.assertEqual(
            self.service(handler, ledger=restarted).execute('owner', 'request-1234', 'generate', self.body(), Decimal('10')),
            first)
        self.assertEqual(len(posts), 1)
        self.assertEqual(restarted.spent('owner'), Decimal('0.0370370367037037036703703703670'))

    def test_transport_loss_is_unknown_and_never_double_charges(self):
        posts = []

        def handler(request):
            posts.append(request)
            raise httpx.ConnectError('accepted then disconnected')

        with self.assertRaises(ImageError) as caught:
            self.service(handler).execute('owner', 'request-1234', 'generate', self.body(), Decimal('10'))
        self.assertEqual(caught.exception.receipt['state'], 'unknown')
        self.assertEqual(len(posts), 1)
        with self.assertRaises(ImageError):
            self.service(handler, ledger=Ledger(self.path)).execute(
                'owner', 'request-1234', 'generate', self.body(), Decimal('10'))
        self.assertEqual(len(posts), 1)
        self.assertEqual(Ledger(self.path).spent('owner', include_pending=True), Decimal('0.30'))


if __name__ == '__main__':
    unittest.main()
