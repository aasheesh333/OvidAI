import base64
import io
import json
import tempfile
import unittest
from contextlib import contextmanager
from decimal import Decimal
from pathlib import Path
from types import SimpleNamespace

import httpx
from fastapi import FastAPI
from fastapi.testclient import TestClient
from PIL import Image

from server.images.inferhub import InferHub
from server.images.catalog import PublicCatalog
from server.images.service import Backend, ImageError, ImageService, Ledger
from server.images.verifier import Identity, VerifierAuth, mount_images


class VerifierTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.app = FastAPI()
        self.mint = SimpleNamespace(app=self.app, APPCHECK_ENABLED=True,
            LITELLM_BASE='http://litellm:4000', LITELLM_MASTER_KEY='fixture-master',
            rds=SimpleNamespace(get=lambda key: {'user:u:key': 'fixture-key', 'user:u:keyid': 'fixture-id'}.get(key)),
            verify_app_check=lambda token: None if token == 'fixture-attest' else self.fail('wrong attestation'),
            verify_google_id_token=lambda token: {'sub': 'u'},
            is_banned=lambda uid, ip: False, effective_tier=lambda uid: 'free',
            free_cap_remaining=lambda uid: 10)
        self.info = {'user_id': 'u', 'metadata': {'ovid_uid': 'u'}, 'models': ['ovid-image']}
        self.key_client = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json={'info': self.info})), base_url='http://litellm')
        self.auth = VerifierAuth(self.mint, self.key_client)
        self.headers = {'Authorization': 'Bearer fixture-token', 'X-Ovid-Key': 'fixture-key', 'X-Firebase-AppCheck': 'fixture-attest', 'Idempotency-Key': 'request-1234'}

    def tearDown(self):
        self.key_client.close()
        self.tmp.cleanup()

    def test_closed_until_shared_budget_bridge_is_present(self):
        mount_images(self.mint, auth=self.auth)
        with TestClient(self.app) as client:
            response = client.get('/v1/images/capabilities', headers=self.headers)
            self.assertEqual(response.status_code, 503)
            self.assertNotIn('model', response.json())

    def test_public_catalog_strips_private_ids_and_image_prices(self):
        projection = PublicCatalog([Backend('private/image-a', ('1024x1024',), True)], lambda: True)
        rows = [{'model': 'private/image-a', 'input_cost_per_token': 99},
                {'model': 'image-a', 'output_cost_per_token': 99},
                {'model': 'ovid-image', 'input_cost_per_token': 99},
                {'model': 'chat-model', 'input_cost_per_token': 1}]
        usage = projection.usage(rows)
        self.assertEqual(usage[-1], {'model': 'ovid-image'})
        self.assertEqual(len(usage), 2)
        models = projection.models(rows)
        self.assertNotIn('cost', json.dumps(models))
        self.assertNotIn('private', json.dumps(models))

    def test_key_revocation_scope_owner_expiry_and_ban_are_rechecked(self):
        self.assertEqual(self.auth({k.lower(): v for k, v in self.headers.items()}).uid, 'u')
        for change in ({'models': []}, {'models': ['other']}, {'blocked': True},
                       {'user_id': 'someone-else'}, {'metadata': {}}, {'expires': '2000-01-01T00:00:00Z'}):
            saved = self.info.copy()
            self.info.update(change)
            with self.subTest(change=change), self.assertRaises(ImageError):
                self.auth({k.lower(): v for k, v in self.headers.items()})
            self.info = saved
        for field in ['Authorization', 'X-Ovid-Key', 'X-Firebase-AppCheck']:
            headers = {k.lower(): v for k, v in self.headers.items() if k != field}
            with self.subTest(field=field), self.assertRaises(ImageError):
                self.auth(headers)
        self.mint.is_banned = lambda uid, ip: True
        with self.assertRaises(ImageError):
            self.auth({k.lower(): v for k, v in self.headers.items()})

    def test_http_generation_and_edit_contract_redacts_and_replays(self):
        image = io.BytesIO()
        Image.new('RGB', (2, 2)).save(image, 'PNG')
        encoded = base64.b64encode(image.getvalue()).decode()
        posts = []

        def upstream(request):
            if request.method == 'GET':
                return httpx.Response(200, json={'data': [{'id': b.model, 'output_modality': 'image', 'modality': 'text,image'} for b in backends]})
            posts.append(request)
            return httpx.Response(200, json={'model': 'private-backend', 'secret': 'never-return',
                'data': [{'b64_json': encoded, 'revised_prompt': 'private'}], 'usage': {'cost': '0.001234'}})

        backends = [Backend('fixture-a', ('1024x1024',), True), Backend('fixture-b', ('1024x1024',), True)]
        transport = InferHub('fixture-secret', httpx.Client(transport=httpx.MockTransport(upstream)))
        transport.verify_catalog(backends)
        service = ImageService(backends, Ledger(Path(self.tmp.name) / 'ledger.db'), transport, Decimal('1'))

        @contextmanager
        def admission(identity):
            self.assertEqual(identity, Identity('u', 'fixture-id', 'free'))
            yield 'window-1', Decimal('10')

        mount_images(self.mint, service, admission=admission, auth=self.auth)
        with TestClient(self.app) as client:
            body = {'model': 'ovid-image', 'prompt': 'a square', 'size': '1024x1024'}
            first = client.post('/v1/images/generations', json=body, headers=self.headers)
            self.assertEqual(first.status_code, 200)
            self.assertEqual(client.post('/v1/images/generations', json=body, headers=self.headers).json(), first.json())
            self.assertEqual(len(posts), 1)
            self.assertNotIn('private', first.text)
            self.assertNotIn('cost', first.text)
            edit = {**body, 'image': 'data:image/png;base64,' + encoded}
            headers = {**self.headers, 'Idempotency-Key': 'edit-request-1234'}
            self.assertEqual(client.post('/v1/images/edits', json=edit, headers=headers).status_code, 200)
            self.assertEqual(posts[-1].url.path, '/v1/images/edits')
            self.assertEqual(json.loads(posts[-1].content)['image'], edit['image'])
            self.assertEqual(service.ledger.spent('u'), Decimal('0.0007404'))
            bad = client.post('/v1/images/edits', content='invalid', headers={**headers, 'Content-Type': 'application/json'})
            self.assertEqual(bad.status_code, 400)
        transport.client.close()
