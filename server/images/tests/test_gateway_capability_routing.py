"""Gateway: capability-based selection, public cards, ETag, admin, compat."""
import base64
import io
import json
import tempfile
import types
import unittest
from contextlib import contextmanager
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

import httpx
from fastapi import FastAPI
from fastapi.testclient import TestClient
from PIL import Image

from server.images.admin import mount_admin
from server.images.capabilities import cap, default_card, finalize, slug_for
from server.images.cardmanager import CardManager, Discovered
from server.images.cardstore import CardStore
from server.images.service import ImageError, Ledger
from server.images.verifier import Identity, mount_images
from server.images.tests.test_gateway_admission import load_gateway
from server.images.tests.test_routing import card as make_card


def png_b64(color='red'):
    out = io.BytesIO()
    Image.new('RGB', (8, 8), color).save(out, 'PNG')
    return base64.b64encode(out.getvalue()).decode()


class Fixture(unittest.TestCase):
    def setUp(self):
        self.gateway = load_gateway()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = Ledger(Path(self.tmp.name) / 'images.sqlite')
        self.cards = [
            make_card('prov/cheap', latency=4000, cost='low', quality='low'),
            make_card('prov/editor', edit=True, inpaint=True, multi=3, latency=20000, cost='med',
                      sizes=('1024x1024', '1536x1024'), ratios=['1:1', '3:2']),
            make_card('prov/pro', edit=True, inpaint=True, multi=8, transparent=True, latency=40000,
                      cost='high', quality='high', text='good', sizes=('1024x1024', '1536x1024', '1024x1536'),
                      ratios=['1:1', '3:2', '2:3']),
        ]
        self.slug = {c['model']: c['slug'] for c in self.cards}
        backends = [self.gateway._backend_from_card(c) for c in self.cards]
        self.service = self.gateway.LiteLLMImageService(types.SimpleNamespace(backends=lambda: backends), self.ledger)
        self.calls, self.spend = [], 0

    def transport(self, responses=None):
        def handle(request):
            if request.url.path == '/key/info':
                return httpx.Response(200, json={'info': {'spend': self.spend}})
            ctype = request.headers['content-type']
            body = json.loads(request.content) if ctype.startswith('application/json') else {}
            model = body.get('model') or (b'name="model"\r\n\r\n' in request.content and
                                          request.content.split(b'name="model"\r\n\r\n')[1].split(b'\r\n')[0].decode())
            self.calls.append((model, request.url.path, request.content))
            if responses:
                value = responses.pop(0)
                if value.status_code != 200:
                    return value
            self.spend += 0.1
            return httpx.Response(200, json={'data': [{'b64_json': png_b64()}]})
        client = httpx.Client
        return patch.object(self.gateway.httpx, 'Client', side_effect=lambda **kw: client(
            **kw, transport=httpx.MockTransport(handle)))

    def run_job(self, request='request-1234', operation='generate', **body):
        base = {'model': 'ovid-image', 'prompt': 'a cat', 'size': '1024x1024'}
        base.update(body)
        return self.service.execute('owner', request, operation, base, Decimal('10'))

    def edit_body(self, **extra):
        return {'image': 'data:image/png;base64,' + png_b64(), **extra}


class RoutingExecutionTest(Fixture):
    def test_legacy_alias_with_no_hints_still_works(self):
        with self.transport():
            result = self.run_job()
        self.assertEqual(result['model'], 'ovid-image')
        self.assertIn(result['model_slug'], self.slug.values())
        self.assertEqual(result['receipt']['model'], result['model_slug'])

    def test_auto_picks_cheapest_capable_model_by_preference(self):
        with self.transport():
            cheap = self.run_job('request-0001', preference='cost')
            fast = self.run_job('request-0002', preference='speed')
            best = self.run_job('request-0003', preference='quality')
        self.assertEqual([c[0] for c in self.calls], ['prov/cheap', 'prov/cheap', 'prov/pro'])
        self.assertEqual(best['model_slug'], self.slug['prov/pro'])

    def test_edit_is_routed_only_to_edit_models(self):
        with self.transport():
            result = self.run_job('request-0004', 'edit', preference='cost', **self.edit_body())
        self.assertEqual(self.calls[0][0], 'prov/editor')
        self.assertEqual(self.calls[0][1], '/v1/images/edits')
        self.assertEqual(result['model_slug'], self.slug['prov/editor'])

    def test_mask_inpaint_multi_image_and_transparent_requirements(self):
        with self.transport():
            self.run_job('request-0005', 'edit', preference='cost', mask='data:image/png;base64,' + png_b64(),
                         **self.edit_body())
            self.run_job('request-0006', 'edit', preference='cost',
                         images=['data:image/png;base64,' + png_b64()] * 3, **self.edit_body())
            self.run_job('request-0007', requirements={'transparent_background': True}, preference='cost')
        self.assertEqual([c[0] for c in self.calls], ['prov/editor', 'prov/pro', 'prov/pro'])
        self.assertIn(b'name="mask"', self.calls[0][2])
        self.assertIn(b'name="image[]"', self.calls[1][2])
        self.assertEqual(json.loads(self.calls[2][2])['background'], 'transparent')

    def test_size_and_ratio_requirements_filter_models(self):
        with self.transport():
            self.run_job('request-0008', size='1024x1536', preference='cost')
            self.run_job('request-0009', requirements={'aspect_ratio': '3:2'}, preference='cost')
        self.assertEqual([c[0] for c in self.calls], ['prov/pro', 'prov/editor'])

    def test_explicit_slug_is_honored(self):
        with self.transport():
            result = self.run_job('request-0010', model=self.slug['prov/pro'])
        self.assertEqual(self.calls[0][0], 'prov/pro')
        self.assertEqual(result['model_slug'], self.slug['prov/pro'])

    def test_explicit_slug_that_cannot_do_it_is_422_with_alternatives_and_no_charge(self):
        with self.transport(), self.assertRaises(ImageError) as caught:
            self.run_job('request-0011', 'edit', model=self.slug['prov/cheap'], **self.edit_body())
        error = caught.exception
        self.assertEqual((error.status, error.code), (422, 'unsupported_image_operation'))
        self.assertEqual(set(error.detail['alternatives']), {self.slug['prov/editor'], self.slug['prov/pro']})
        self.assertEqual(error.detail['unsupported'], ['edit'])
        self.assertEqual(self.calls, [])
        self.assertEqual(self.ledger.spent('owner', include_pending=True), Decimal('0'))

    def test_unknown_slug_and_unmatched_auto_are_422(self):
        for kwargs in ({'model': 'ovid-image:img-nope00'}, {'size': '2048x2048'}):
            with self.assertRaises(ImageError) as caught:
                self.run_job('request-0012', **kwargs)
            self.assertEqual(caught.exception.status, 422)
        self.assertEqual(caught.exception.detail['alternatives'], [])

    def test_bad_model_or_hints_are_400(self):
        for kwargs in ({'model': 'prov/pro'}, {'preference': 'wow'}, {'requirements': {'bogus': 1}}):
            with self.assertRaises(ImageError) as caught:
                self.run_job('request-0013', **kwargs)
            self.assertEqual(caught.exception.status, 400)

    def test_cooldown_model_is_skipped_for_next_capable_model(self):
        self.service._capacity_refused('prov/cheap', 30)
        with self.transport():
            self.run_job('request-0014', preference='cost')
        self.assertEqual(self.calls[0][0], 'prov/editor')

    def test_capacity_refusal_falls_back_to_next_ranked_model(self):
        busy = httpx.Response(503, json={'error': {'type': 'no_capacity'}})
        with self.transport([busy]):
            result = self.run_job('request-0015', preference='cost')
        self.assertEqual([c[0] for c in self.calls], ['prov/cheap', 'prov/editor'])
        self.assertEqual(result['model_slug'], self.slug['prov/editor'])

    def test_replay_keeps_original_served_slug(self):
        with self.transport():
            first = self.run_job('request-0016', preference='cost')
        with self.transport():
            self.assertEqual(self.run_job('request-0016', preference='cost'), first)
        self.assertEqual(len(self.calls), 1)

    def test_discovery_without_cards_is_generate_only_default(self):
        discovery = self.gateway._Discovery()
        discovery._at = 10 ** 12
        discovery._found = [Discovered('prov/new', {'model': 'new'}, {'mode': 'image_generation'})]
        service = self.gateway.LiteLLMImageService(discovery, self.ledger)
        card = service.cards()[0]
        self.assertEqual(card['sizes']['native'], ['1024x1024'])
        self.assertEqual(card['operations']['edit']['supported'], False)
        with self.assertRaises(ImageError) as caught:
            service.execute('owner', 'request-0017', 'edit', {'model': 'ovid-image', 'prompt': 'x', 'size': '1024x1024',
                                                              **self.edit_body()}, Decimal('10'))
        self.assertEqual(caught.exception.status, 422)


class HttpSurfaceTest(Fixture):
    def client(self):
        app = FastAPI()

        @contextmanager
        def admission(identity):
            yield 'window', Decimal('10')
        mount_images(types.SimpleNamespace(app=app), self.service, admission=admission,
                     auth=lambda headers: Identity('owner', 'key-id', 'free'))
        return TestClient(app)

    def test_capabilities_expose_public_cards_hash_and_legacy_operations(self):
        with self.client() as client:
            response = client.get('/v1/images/capabilities')
        body = response.json()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(body['model'], 'ovid-image')
        self.assertEqual(set(body['operations']), {'generate', 'edit'})   # old builds
        self.assertIn('1536x1024', body['operations']['edit'])
        self.assertEqual(len(body['models']), 3)
        self.assertEqual(response.headers['etag'], f'"{body["catalog_hash"]}"')
        text = response.text
        for secret in ('prov/', 'cost_usd', 'api_base', 'fingerprint', 'measured'):
            self.assertNotIn(secret, text)
        by_slug = {m['slug']: m for m in body['models']}
        self.assertNotIn('edit', by_slug[self.slug['prov/cheap']]['operations'])
        self.assertIn('transparent_output', by_slug[self.slug['prov/pro']]['operations'])

    def test_etag_conditional_get(self):
        with self.client() as client:
            etag = client.get('/v1/images/capabilities').headers['etag']
            again = client.get('/v1/images/capabilities', headers={'If-None-Match': etag})
            stale = client.get('/v1/images/capabilities', headers={'If-None-Match': '"other"'})
        self.assertEqual(again.status_code, 304)
        self.assertEqual(again.content, b'')
        self.assertEqual(stale.status_code, 200)

    def test_hash_changes_when_a_card_changes(self):
        with self.client() as client:
            before = client.get('/v1/images/capabilities').json()['catalog_hash']
            self.cards[0]['operations']['edit'] = cap(True, 'probed')
            finalize(self.cards[0])
            after = client.get('/v1/images/capabilities').json()['catalog_hash']
        self.assertNotEqual(before, after)

    def test_http_422_body_and_receipt_model(self):
        with self.client() as client, self.transport():
            bad = client.post('/v1/images/edits', headers={'Idempotency-Key': 'http-req-0001'}, json={
                'model': self.slug['prov/cheap'], 'prompt': 'x', 'size': '1024x1024', **self.edit_body()})
            ok = client.post('/v1/images/generations', headers={'Idempotency-Key': 'http-req-0002'}, json={
                'model': 'ovid-image', 'prompt': 'x', 'size': '1024x1024', 'preference': 'cost'})
            receipt = client.get('/v1/images/requests/http-req-0002').json()['receipt']
        self.assertEqual(bad.status_code, 422)
        self.assertEqual(bad.json()['error']['code'], 'unsupported_image_operation')
        self.assertEqual(len(bad.json()['error']['alternatives']), 2)
        self.assertNotIn('prov/', bad.text)
        self.assertEqual(ok.json()['model_slug'], self.slug['prov/cheap'])
        self.assertEqual(receipt['model'], self.slug['prov/cheap'])


class AdminTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = CardStore(Path(self.tmp.name) / 'c.sqlite')
        self.manager = CardManager(self.store, None)
        self.manager.tick(lambda: [Discovered('cb/gpt-image-2', {'model': 'gpt-image-2', 'api_base': 'https://p/v1'},
                                              {'mode': 'image_generation'})])
        self.woken = []
        app = FastAPI()
        mount_admin(app, self.manager, 'master-key', wake=lambda: self.woken.append(1))
        self.client = TestClient(app)
        self.good = {'Authorization': 'Bearer master-key'}

    def test_master_key_required(self):
        for headers in ({}, {'Authorization': 'Bearer nope'}, {'Authorization': 'master-key'}):
            self.assertEqual(self.client.get('/images/admin/cards', headers=headers).status_code, 403)
            self.assertEqual(self.client.post('/images/admin/reprobe', json={'model': 'x'}, headers=headers).status_code, 403)

    def test_cards_include_internal_detail(self):
        body = self.client.get('/images/admin/cards', headers=self.good).json()
        card = body['cards'][0]
        self.assertEqual(card['model'], 'cb/gpt-image-2')
        self.assertEqual(card['fingerprint'][:2].isalnum(), True)
        self.assertIn('probes', card)
        self.assertIn('history', card)
        self.assertEqual(card['slug'], slug_for('cb/gpt-image-2'))
        self.assertIn('probe_spend_24h_usd', body)

    def test_reprobe_by_name_or_slug(self):
        for ident in ('cb/gpt-image-2', slug_for('cb/gpt-image-2')):
            response = self.client.post('/images/admin/reprobe', json={'model': ident}, headers=self.good)
            self.assertEqual((response.status_code, response.json()), (202, {'queued': 'cb/gpt-image-2'}))
        self.assertEqual(len(self.woken), 2)
        self.assertEqual(self.client.post('/images/admin/reprobe', json={'model': 'zzz'}, headers=self.good).status_code, 404)
        self.assertEqual(self.client.post('/images/admin/reprobe', json={}, headers=self.good).status_code, 400)


if __name__ == '__main__':
    unittest.main()
