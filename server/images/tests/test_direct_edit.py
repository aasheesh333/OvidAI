"""Direct JSON edit transport: request shape, SSRF guard, cards, probes, billing.

Fakes only (httpx.MockTransport). No real provider or LiteLLM is ever called.
"""
import base64
import io
import json
import logging
import tempfile
import types
import unittest
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

import httpx
from PIL import Image

from server.images.capabilities import public_card, supports
from server.images.cardmanager import CardManager
from server.images.cardstore import CardStore
from server.images.directedit import DirectEdit, provider_model_id
from server.images.probes import (INCONCLUSIVE, UNSUPPORTED, LiteLLMProbeTransport, ProbeRunner,
                                  classify_direct_error)
from server.images.service import ImageError, Ledger, discounted
from server.images.tests.test_gateway_admission import load_gateway

KEY = 'sk-inferhub-SECRET-0123456789'
BASE = 'https://api.inferhub.dev/v1'
MODEL = 'cb/gpt-image-2'


def png_bytes(color='red'):
    out = io.BytesIO()
    Image.new('RGB', (8, 8), color).save(out, 'PNG')
    return out.getvalue()


def png_b64(color='red'):
    return base64.b64encode(png_bytes(color)).decode()


def model_info(name=MODEL, base=BASE):
    return {'data': [{'model_name': name, 'model_info': {'mode': 'image_generation'},
                      'litellm_params': {'model': f'openai/{name}', 'api_base': base,
                                         'api_key': 'sk-LITELLM-PROVIDER-KEY'}}]}


class DirectFixture(unittest.TestCase):
    cost = '0.04'
    key = KEY

    def setUp(self):
        self.gateway = load_gateway()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ledger = Ledger(Path(self.tmp.name) / 'images.sqlite')
        self.direct = DirectEdit(self.key, 'api.inferhub.dev', self.cost)
        self.provider, self.litellm = [], []
        self.reply = lambda request: httpx.Response(200, json={'data': [{'b64_json': png_b64('blue')}]})
        self.catalog = model_info()
        self.build()

    def build(self):
        self.manager = CardManager(CardStore(Path(self.tmp.name) / 'cards.sqlite'), None)
        self.discovery = self.gateway._Discovery(self.manager, self.direct)
        with self.transport():
            for found in self.discovery.discovered(force=True):
                self.manager.refresh(found.name)
        self.service = self.gateway.LiteLLMImageService(self.discovery, self.ledger, direct_edit=self.direct)

    def transport(self):
        def handle(request):
            if request.url.host == 'api.inferhub.dev':
                self.provider.append(request)
                return self.reply(request)
            self.litellm.append(request)
            if request.url.path == '/model/info':
                return httpx.Response(200, json=self.catalog)
            if request.url.path == '/key/info':
                return httpx.Response(200, json={'info': {'spend': 0}})
            return httpx.Response(500, json={'error': 'litellm must not serve this'})
        client = httpx.Client
        return patch.object(self.gateway.httpx, 'Client', side_effect=lambda **kw: client(
            **kw, transport=httpx.MockTransport(handle)))

    def edit(self, request='request-1234', **extra):
        body = {'model': 'ovid-image', 'prompt': 'make it blue', 'size': '1024x1024',
                'image': 'data:image/png;base64,' + png_b64(), **extra}
        return self.service.execute('owner', request, 'edit', body, Decimal('10'))

    def spent(self):
        return self.ledger.spent('owner', include_pending=True)


class DirectEditSuccessTest(DirectFixture):
    def test_cards_declare_edit_without_inpaint_multi_or_transparent_edit(self):
        card = self.service.cards()[0]
        self.assertEqual(card['edit_transport'], 'direct')
        self.assertTrue(supports(card, 'edit'))
        self.assertEqual(card['operations']['edit']['source'], 'declared')
        for op in ('inpaint', 'multi_image', 'outpaint', 'reference_style', 'remove_background'):
            self.assertFalse(supports(card, op), op)
        self.assertEqual(public_card(card)['input']['max_images'], 1)
        self.assertIn('edit', public_card(card)['operations'])

    def test_exact_json_request_and_settlement(self):
        with self.transport():
            result = self.edit()
        self.assertEqual(len(self.provider), 1)
        request = self.provider[0]
        self.assertEqual(str(request.url), 'https://api.inferhub.dev/v1/images/edits')
        self.assertEqual(request.method, 'POST')
        self.assertTrue(request.headers['content-type'].startswith('application/json'))
        self.assertEqual(request.headers['authorization'], f'Bearer {KEY}')
        self.assertEqual(json.loads(request.content), {
            'model': MODEL, 'prompt': 'make it blue', 'size': '1024x1024', 'n': 1,
            'response_format': 'b64_json', 'image': 'data:image/png;base64,' + png_b64()})
        self.assertNotIn(b'multipart', request.headers['content-type'].encode())
        # LiteLLM was only used for discovery, never for the edit itself.
        self.assertFalse([r for r in self.litellm if r.url.path == '/v1/images/edits'])
        self.assertEqual(result['data'][0]['mime_type'], 'image/png')
        self.assertEqual(result['receipt']['state'], 'confirmed')
        # Settlement: flat configured price, discounted like any other charge, debited from the budget.
        self.assertEqual(Decimal(result['receipt']['charged']), discounted('0.04'))
        self.assertEqual(self.ledger.spent('owner'), discounted('0.04'))
        self.assertNotIn(KEY, json.dumps(result))

    def test_budget_is_debited_and_exhausted_budget_blocks_before_provider(self):
        with self.transport():
            self.edit('request-0001')
        self.assertEqual(self.ledger.spent('owner'), Decimal('0.012'))
        # Reservation is the discounted upstream bound (0.30); remaining 0.20 cannot cover it.
        with self.transport(), self.assertRaises(ImageError) as caught:
            self.service.execute('owner', 'request-0002', 'edit', {
                'model': 'ovid-image', 'prompt': 'again', 'image': 'data:image/png;base64,' + png_b64()},
                Decimal('0.20'))
        self.assertEqual(caught.exception.status, 402)
        self.assertEqual(len(self.provider), 1)

    def test_provider_usage_cost_preferred_but_never_above_bound(self):
        self.reply = lambda r: httpx.Response(200, json={'data': [{'b64_json': png_b64()}],
                                                         'usage': {'cost': 0.02}})
        with self.transport():
            first = self.edit('request-0001')
        self.assertEqual(Decimal(first['receipt']['charged']), discounted('0.02'))
        self.reply = lambda r: httpx.Response(200, json={'data': [{'b64_json': png_b64()}],
                                                         'usage': {'cost': 99}})
        with self.transport():
            second = self.edit('request-0002')
        self.assertEqual(Decimal(second['receipt']['charged']), discounted(self.gateway.MAX_UPSTREAM_USD))

    def test_default_flat_price_is_the_upstream_bound(self):
        direct = DirectEdit.from_env(Decimal('1.00'), env={'INFERHUB_API_KEY': KEY})
        self.assertEqual(direct.edit_cost, Decimal('1.00'))
        capped = DirectEdit.from_env(Decimal('1.00'), env={'INFERHUB_API_KEY': KEY,
                                                           'OVID_IMAGE_EDIT_COST_USD': '5'})
        self.assertEqual(capped.edit_cost, Decimal('1.00'))
        bad = DirectEdit.from_env(Decimal('1.00'), env={'OVID_IMAGE_EDIT_COST_USD': 'abc'})
        self.assertEqual(bad.edit_cost, Decimal('1.00'))

    def test_model_id_mapping(self):
        self.assertEqual(provider_model_id('openai/cb/gpt-image-2'), 'cb/gpt-image-2')
        self.assertEqual(provider_model_id('cb/gemini-2.5-flash-image'), 'cb/gemini-2.5-flash-image')
        self.assertIsNone(provider_model_id(None))


class SsrfGuardTest(unittest.TestCase):
    def test_only_allowlisted_https_hosts(self):
        direct = DirectEdit(KEY, 'api.inferhub.dev')
        good = {'model': 'openai/cb/x', 'api_base': BASE}
        self.assertEqual(direct.target(good), ('https://api.inferhub.dev/v1/images/edits', 'cb/x'))
        for base in ('http://api.inferhub.dev/v1', 'https://evil.example/v1', 'https://api.inferhub.dev.evil.io/v1',
                     'https://user:pw@api.inferhub.dev/v1', 'https://api.inferhub.dev:8443/v1',
                     'https://api.inferhub.dev/v1?x=1', 'https://169.254.169.254/v1', 'ftp://api.inferhub.dev', '',
                     None, 'https://'):
            self.assertIsNone(direct.target({'model': 'openai/cb/x', 'api_base': base}), base)
        self.assertIsNone(direct.target({'api_base': BASE}))
        self.assertFalse(direct.enabled_for({}))

    def test_custom_allowlist_and_missing_key(self):
        other = DirectEdit(KEY, 'edge.example.com , api.inferhub.dev')
        self.assertTrue(other.enabled_for({'model': 'openai/m', 'api_base': 'https://edge.example.com/v1'}))
        self.assertFalse(DirectEdit('', 'api.inferhub.dev').enabled_for({'model': 'openai/m', 'api_base': BASE}))
        self.assertFalse(DirectEdit('  ', 'api.inferhub.dev').has_key)

    def test_disabled_reason_logged_once_without_secrets(self):
        direct = DirectEdit(KEY, 'api.inferhub.dev')
        with self.assertLogs('ovid.images.directedit', level='WARNING') as logs:
            for _ in range(3):
                direct.target({'model': 'openai/m', 'api_base': 'https://evil.example/v1'})
        self.assertEqual(len(logs.output), 1)
        self.assertNotIn(KEY, ''.join(logs.output))

    def test_post_refuses_a_non_allowlisted_target(self):
        with self.assertRaises(RuntimeError):
            DirectEdit(KEY).post({'model': 'openai/m', 'api_base': 'https://evil.example/v1'}, 'p', '1024x1024', 'x')

    def test_redirects_are_not_followed(self):
        seen = []

        def handle(request):
            seen.append(str(request.url))
            return httpx.Response(302, headers={'location': 'https://evil.example/steal'})
        direct = DirectEdit(KEY, client_factory=lambda **kw: httpx.Client(**kw, transport=httpx.MockTransport(handle)))
        response = direct.post({'model': 'openai/m', 'api_base': BASE}, 'p', '1024x1024', 'data:image/png;base64,AA==')
        self.assertEqual(response.status_code, 302)
        self.assertEqual(seen, ['https://api.inferhub.dev/v1/images/edits'])


class WithoutKeyTest(DirectFixture):
    key = ''

    def test_cards_say_edit_unsupported_and_edit_is_a_clean_422(self):
        card = self.service.cards()[0]
        self.assertEqual(card['edit_transport'], 'none')
        self.assertFalse(supports(card, 'edit'))
        self.assertNotIn('edit', self.service.catalog()['models'][0]['operations'])
        self.assertEqual(self.service.catalog()['operations']['edit'], [])
        with self.transport(), self.assertRaises(ImageError) as caught:
            self.edit()
        self.assertEqual((caught.exception.status, caught.exception.code), (422, 'unsupported_image_operation'))
        self.assertEqual(caught.exception.detail['alternatives'], [])
        self.assertEqual(self.provider, [])
        self.assertEqual(self.spent(), Decimal('0'))

    def test_generation_still_works(self):
        self.reply = lambda r: httpx.Response(200, json={'data': [{'b64_json': png_b64()}]})

        generated = []

        def handle(request):
            if request.url.path == '/key/info':
                return httpx.Response(200, json={'info': {'spend': 0.1 if generated else 0}})
            generated.append(request)
            return httpx.Response(200, json={'data': [{'b64_json': png_b64()}]})
        client = httpx.Client
        with patch.object(self.gateway.httpx, 'Client', side_effect=lambda **kw: client(
                **kw, transport=httpx.MockTransport(handle))):
            result = self.service.execute('owner', 'request-gen1', 'generate',
                                          {'model': 'ovid-image', 'prompt': 'cat'}, Decimal('10'))
        self.assertEqual(result['receipt']['state'], 'confirmed')


class WrongHostTest(DirectFixture):
    def test_non_allowlisted_api_base_disables_edit(self):
        self.catalog = model_info(base='https://other.example/v1')
        self.build()
        self.assertFalse(supports(self.service.cards()[0], 'edit'))
        with self.transport(), self.assertRaises(ImageError) as caught:
            self.edit()
        self.assertEqual(caught.exception.status, 422)
        self.assertEqual(self.provider, [])


class UnsupportedInputsTest(DirectFixture):
    def assert_rejected_before_admission(self, **extra):
        with self.transport(), self.assertRaises(ImageError) as caught:
            self.edit(**extra)
        self.assertEqual((caught.exception.status, caught.exception.code), (422, 'unsupported_image_operation'))
        self.assertEqual(self.provider, [])
        self.assertEqual(self.spent(), Decimal('0'))
        with self.assertRaises(ImageError):
            self.ledger.receipt('owner', 'request-1234')   # nothing was even admitted

    def test_mask(self):
        self.assert_rejected_before_admission(mask='data:image/png;base64,' + png_b64())

    def test_extra_images(self):
        self.assert_rejected_before_admission(images=['data:image/png;base64,' + png_b64()])

    def test_transparent_edit(self):
        self.assert_rejected_before_admission(requirements={'transparent_background': True})

    def test_explicit_slug_gets_the_unsupported_list(self):
        slug = self.service.cards()[0]['slug']
        with self.transport(), self.assertRaises(ImageError) as caught:
            self.edit(model=slug, mask='data:image/png;base64,' + png_b64())
        self.assertIn('inpaint', caught.exception.detail['unsupported'])
        self.assertEqual(self.spent(), Decimal('0'))


class ProviderErrorMappingTest(DirectFixture):
    def run_error(self, response, request='request-err1'):
        self.reply = lambda r: response
        with self.transport(), self.assertLogs(level='DEBUG') as logs, self.assertRaises(ImageError) as caught:
            logging.getLogger('probe').debug('keepalive')
            self.edit(request)
        blob = json.dumps({'code': caught.exception.code, 'receipt': caught.exception.receipt,
                           'detail': caught.exception.detail}) + ''.join(logs.output)
        self.assertNotIn(KEY, blob)
        self.assertNotIn('LITELLM-PROVIDER-KEY', blob)
        return caught.exception

    def test_ambiguous_failures_stay_pending_and_are_never_resubmitted(self):
        for status, body in ((400, {'error': {'code': 'validation_error', 'message': 'body must be JSON'}}),
                             (401, {'error': {'message': 'bad key'}}), (402, {'error': {'message': 'credit'}}),
                             (429, {'error': {'message': 'slow down'}}), (503, {'error': {'message': 'boom'}}),
                             (500, {})):
            with self.subTest(status=status):
                self.provider.clear()
                error = self.run_error(httpx.Response(status, json=body), f'request-st{status}')
                self.assertEqual((error.status, error.code), (409, 'image_request_pending'))
                self.assertEqual(len(self.provider), 1)
                self.assertIsNone(error.receipt['charged'])

    def test_pre_provider_refusal_is_a_clean_unavailable(self):
        error = self.run_error(httpx.Response(400, json={'error': {'code': 'unsupported_modality'}}))
        self.assertEqual((error.status, error.code), (502, 'image_unavailable'))
        self.assertEqual(error.receipt['state'], 'failed')
        self.assertEqual(self.ledger.spent('owner'), Decimal('0'))

    def test_no_capacity_sets_cooldown_and_blocks_the_next_call(self):
        refusal = httpx.Response(503, headers={'Retry-After': '17'},
                                 json={'error': {'type': 'no_capacity', 'message': 'try later'}})
        error = self.run_error(refusal)
        self.assertEqual((error.status, error.code), (503, 'image_capacity_unavailable'))
        self.assertEqual(error.retry_after_seconds, 17)
        self.assertEqual(self.ledger.spent('owner'), Decimal('0'))
        self.assertEqual(len(self.provider), 1)
        with self.transport(), self.assertRaises(ImageError) as second:
            self.edit('request-err2')
        self.assertEqual(second.exception.code, 'image_capacity_unavailable')
        self.assertEqual(len(self.provider), 1, 'cooldown must skip the provider')

    def test_invalid_image_response_is_never_settled(self):
        error = self.run_error(httpx.Response(200, json={'data': [{'b64_json': 'not-an-image'}]}))
        self.assertEqual(error.status, 409)
        self.assertEqual(self.ledger.spent('owner'), Decimal('0'))


class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.litellm, self.provider = [], []
        self.edit_reply = lambda r: httpx.Response(200, json={'data': [{'b64_json': png_b64('blue')}]})

    def runner(self, direct, cap=0.5):
        def lite(request):
            self.litellm.append(request)
            if request.url.path == '/v1/images/generations':
                body = json.loads(request.content)
                if body.get('background'):
                    return httpx.Response(200, json={'data': [{'b64_json': png_b64()}]})
                return httpx.Response(200, json={'data': [{'b64_json': png_b64()}] * body.get('n', 1)})
            return httpx.Response(404)

        def prov(request):
            self.provider.append(request)
            return self.edit_reply(request)
        direct.client_factory = lambda **kw: httpx.Client(**kw, transport=httpx.MockTransport(prov))
        params = {'model': f'openai/{MODEL}', 'api_base': BASE, 'edit_transport':
                  'direct' if direct.enabled_for({'model': f'openai/{MODEL}', 'api_base': BASE}) else 'none'}
        transport = LiteLLMProbeTransport(
            'http://litellm:4000', 'probe-key', spend_wait=0, direct=direct,
            params_for=lambda model: params,
            client_factory=lambda **kw: httpx.Client(**kw, transport=httpx.MockTransport(lite)))
        store = CardStore(Path(self.tmp.name) / 'c.sqlite')
        from server.images.cardmanager import Discovered
        from server.images.probes import ProbeRunner as PR
        manager = CardManager(store, PR(transport, store, per_probe_cap=cap, daily_cap=50, max_sizes=1))
        manager.observe([Discovered(MODEL, params, {'mode': 'image_generation'})])
        return manager

    def probe(self, direct, **kw):
        manager = self.runner(direct, **kw)
        return manager.refresh(MODEL)

    def test_probe_uses_the_direct_json_path_only(self):
        card = self.probe(DirectEdit(KEY, 'api.inferhub.dev', '0.04'))
        self.assertEqual(len(self.provider), 1)       # edit only; no mask / multi-image probes
        body = json.loads(self.provider[0].content)
        self.assertTrue(body['image'].startswith('data:image/png;base64,'))
        self.assertEqual(self.provider[0].headers['authorization'], f'Bearer {KEY}')
        self.assertFalse([r for r in self.litellm if r.url.path == '/v1/images/edits'])
        self.assertTrue(supports(card, 'edit'))
        self.assertEqual(card['operations']['edit']['source'], 'probed')
        for op in ('inpaint', 'multi_image', 'remove_background'):
            self.assertFalse(supports(card, op), op)
        self.assertNotIn(KEY, json.dumps(card))

    def test_http_400_is_inconclusive_not_unsupported(self):
        self.edit_reply = lambda r: httpx.Response(
            400, json={'error': {'message': "body must be JSON: invalid character '-'", 'type': 'invalid_request'}})
        card = self.probe(DirectEdit(KEY, 'api.inferhub.dev', '0.04'))
        edit_probe = next(p for p in card['probes'] if p['probe'] == 'edit')
        self.assertEqual(edit_probe['error_class'], INCONCLUSIVE)
        self.assertTrue(supports(card, 'edit'), 'a malformed probe must never mark edit absent')
        self.assertEqual(card['operations']['edit']['source'], 'declared')
        self.assertEqual(card['state'], 'inferred')   # incomplete: will be retried with backoff

    def test_structured_modality_refusal_is_a_real_unsupported(self):
        self.edit_reply = lambda r: httpx.Response(400, json={'error': {'code': 'unsupported_modality'}})
        card = self.probe(DirectEdit(KEY, 'api.inferhub.dev', '0.04'))
        self.assertFalse(supports(card, 'edit'))
        self.assertEqual(card['operations']['edit']['source'], 'probed')

    def test_classifier(self):
        self.assertEqual(classify_direct_error(400, httpx.Response(400, json={'error': {'type': 'invalid_request'}})),
                         INCONCLUSIVE)
        self.assertEqual(classify_direct_error(404, httpx.Response(404)), INCONCLUSIVE)
        self.assertEqual(classify_direct_error(400, httpx.Response(400, text='<html>')), INCONCLUSIVE)
        self.assertEqual(classify_direct_error(400, httpx.Response(400, json={'error': {'code': 'not_an_image_model'}})),
                         UNSUPPORTED)
        self.assertEqual(classify_direct_error(401, httpx.Response(401)), 'auth')
        self.assertEqual(classify_direct_error(429, httpx.Response(429)), 'transient')

    def test_without_key_edit_is_not_probed_and_stays_false(self):
        card = self.probe(DirectEdit('', 'api.inferhub.dev'))
        self.assertEqual(self.provider, [])
        self.assertFalse([r for r in self.litellm if r.url.path == '/v1/images/edits'])
        self.assertFalse(supports(card, 'edit'))
        self.assertTrue(supports(card, 'generate'))

    def test_probe_spend_cap_blocks_an_expensive_edit(self):
        card = self.probe(DirectEdit(KEY, 'api.inferhub.dev', '0.90'), cap=0.5)
        self.assertEqual(self.provider, [])
        self.assertTrue(supports(card, 'edit'))   # still declared, simply not verified


if __name__ == '__main__':
    unittest.main()
