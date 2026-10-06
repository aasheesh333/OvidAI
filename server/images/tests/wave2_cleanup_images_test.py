import base64
import io
import json
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace

import httpx
from fastapi import FastAPI
from fastapi.testclient import TestClient
from PIL import Image

from server.images.service import Ledger


def fixture(tmp_path):
    from server.images.runtime import mount_configured_images
    ledger = Ledger(tmp_path / 'images.db')
    now = [1000]
    ledger.clock = lambda: now[0]
    stores = SimpleNamespace(images=ledger, identities={'images': 'fixture', 'shares': 'fixture-share'})
    state = {'active': True, 'quota': 10, 'posts': 0, 'locked': False}
    claims = {'uid': 'alice', 'firebase': {'sign_in_provider': 'google.com'}}

    @contextmanager
    def access(claims):
        from server.account.domain import AccountError
        if not state['active']:
            raise AccountError('account_deletion_pending', 403)
        state['locked'] = True
        try:
            yield claims['uid']
        finally:
            state['locked'] = False

    lifecycle = SimpleNamespace(access=access, data=SimpleNamespace(stores=stores))
    def verify(token, check, allow_disabled=False):
        if token != 'token' or check != 'check' or allow_disabled:
            raise ValueError('invalid credentials')
        return claims
    admin = SimpleNamespace(verify=verify)
    mint = SimpleNamespace(app=FastAPI(), APPCHECK_ENABLED=True,
        LITELLM_BASE='https://litellm.invalid', LITELLM_MASTER_KEY='fixture',
        rds=SimpleNamespace(get=lambda key: {'user:alice:key': 'key', 'user:alice:keyid': 'id'}.get(key)),
        verify_app_check=lambda check: None,
        verify_google_id_token=lambda token: {'sub': 'alice'},
        is_banned=lambda uid, ip: False, effective_tier=lambda uid: 'free',
        free_cap_remaining=lambda uid: state['quota'])
    key_client = httpx.Client(base_url=mint.LITELLM_BASE, transport=httpx.MockTransport(
        lambda request: httpx.Response(200, json={'info': {'user_id': 'alice',
        'metadata': {'ovid_uid': 'alice'}, 'models': ['ovid-image']}})))
    config = tmp_path / 'image-config.json'
    config.write_text(json.dumps({'alias': 'ovid-image', 'base_url': 'https://api.inferhub.dev/v1',
        'backends': [{'model': name, 'sizes': ['1024x1024'], 'edit': True} for name in ('fixture-a', 'fixture-b')]}))
    output = io.BytesIO()
    Image.new('RGB', (2, 2)).save(output, 'PNG')
    class Transport:
        def verify_catalog(self, backends):
            assert len(backends) == 2
        def __call__(self, *args):
            assert state['locked']
            state['posts'] += 1
            return {'usage': {'cost': '1'}, 'data': [{'b64_json': base64.b64encode(output.getvalue()).decode()}]}
    @contextmanager
    def admission(identity):
        assert state['locked']
        yield 'window', '10'
    def mount(**overrides):
        options = dict(transport=Transport(), admission=admission,
                       enforced_max_upstream_cost='1', key_client=key_client)
        options.update(overrides)
        mount_configured_images(mint, lifecycle, admin, stores, config, **options)
        return TestClient(mint.app)
    headers = {'Authorization': 'Bearer token', 'X-Firebase-AppCheck': 'check',
               'X-Ovid-Key': 'key', 'Idempotency-Key': 'image-request'}
    return mount, headers, state, now, ledger, mint, key_client


class ConfiguredImagesTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp_path = Path(tmp.name)

    def test_factory_receipt_and_result_read_at_zero_quota_and_restart(self):
        mount, headers, state, now, ledger, mint, key_client = fixture(self.tmp_path)
        with key_client, mount() as client:
            body = {'model': 'ovid-image', 'prompt': 'square', 'size': '1024x1024'}
            first = client.post('/v1/images/generations', headers=headers, json=body)
            self.assertEqual(first.status_code, 200, first.text)
            state['quota'] = 0
            self.assertEqual(client.post('/v1/images/generations', headers=headers, json=body).status_code, 402)
            self.assertEqual(client.get('/v1/images/requests/image-request', headers=headers).json()['receipt']['charged'], '0.30')
            replay = client.get('/v1/images/requests/image-request/result', headers=headers)
            self.assertEqual(replay.status_code, 200)
            self.assertEqual(replay.json(), first.json())
            self.assertEqual(replay.headers['cache-control'], 'no-store')
            self.assertEqual(state['posts'], 1)
            restarted = Ledger(ledger.path, clock=lambda: now[0])
            self.assertEqual(restarted.replay('alice', 'image-request'), first.json())
            state['active'] = False
            self.assertEqual(client.get('/v1/images/requests/image-request/result', headers=headers).status_code, 403)
            self.assertIn(client.get('/v1/images/capabilities', headers=headers).status_code, (402, 403))
            state['active'] = True
            now[0] += 86400
            self.assertEqual(client.get('/v1/images/requests/image-request/result', headers=headers).status_code, 410)
            self.assertEqual(client.get('/v1/images/requests/image-request', headers=headers).status_code, 200)
            ledger.delete_account('alice')
            self.assertEqual(client.get('/v1/images/requests/image-request', headers=headers).status_code, 410)

    def test_production_image_factory_keeps_routes_closed_without_authorities(self):
        for missing in ('admission', 'transport', 'enforced_max_upstream_cost', 'appcheck'):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as tmp:
                mount, headers, state, now, ledger, mint, key_client = fixture(Path(tmp))
                options = {missing: None}
                if missing == 'appcheck':
                    mint.APPCHECK_ENABLED = False
                    options = {}
                with key_client, mount(**options) as client:
                    for path in ('capabilities', 'requests/image-request', 'requests/image-request/result'):
                        self.assertEqual(client.get('/v1/images/' + path, headers=headers).status_code, 503)
                    self.assertEqual(state['posts'], 0)
