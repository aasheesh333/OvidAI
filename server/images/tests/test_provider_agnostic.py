"""Provider-agnostic behaviour: pricing gate, admin visibility, unknown families, URL replies,
error classification, probe budget. Fakes only; no real provider is ever called."""
import base64
import io
import logging
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path

import httpx
from fastapi import FastAPI
from fastapi.testclient import TestClient
from PIL import Image

from server.images import costing
from server.images.admin import mount_admin
from server.images.capabilities import default_card, supports
from server.images.cardmanager import CardManager, Discovered
from server.images.cardstore import CardStore
from server.images.extraction import provider_models_entry, static_extract
from server.images.probes import (AUTH, BUDGET, INCONCLUSIVE, TRANSIENT, UNSUPPORTED, URL_RESPONSE,
                                  LiteLLMProbeTransport, ProbeOutcome, ProbeRunner, classify_error)
from server.images.routing import Task, alternatives, missing, pick_backends
from server.images.service import ImageError
from server.images.tests.test_gateway_capability_routing import Fixture, png_b64
from server.images.tests.test_probes import FakeLiteLLM, png_bytes
from server.images.tests.test_routing import card as make_card

PRICED = {'mode': 'image_generation', 'output_cost_per_image': 0.04}
UNPRICED = {'mode': 'image_generation'}


def webp_bytes():
    out = io.BytesIO()
    Image.new('RGB', (8, 8), (9, 9, 9)).save(out, 'WEBP')
    return out.getvalue()


class PricedFlagTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = CardStore(Path(self.tmp.name) / 'c.sqlite')

    def test_price_status_rules(self):
        self.assertEqual(costing.price_status({'input_cost_per_token': 1e-6})[:2], (True, 'tokens'))
        self.assertEqual(costing.price_status({'output_cost_per_token': 1e-5})[:2], (True, 'tokens'))
        self.assertEqual(costing.price_status({'output_cost_per_image': 0.04})[:2], (True, 'per_image'))
        self.assertEqual(costing.price_status({'input_cost_per_image': 0.01})[:2], (True, 'per_image'))
        self.assertEqual(costing.price_status({}, header_seen=True)[:2], (True, 'header'))
        priced, source, warns = costing.price_status({'output_cost_per_image': 0, 'ovid_flat_cost_usd': 1})
        self.assertEqual((priced, source), (False, None))   # no gateway-side price source exists
        self.assertEqual(warns, ["unpriced: set the model's price in LiteLLM "
                                 "(input/output cost per token, or output cost per image)"])
        self.assertEqual(costing.missing_price_fields({'output_cost_per_image': 0.04}),
                         ['input_cost_per_token', 'output_cost_per_token', 'input_cost_per_image'])

    def test_manager_flags_warns_once_and_reevaluates_on_price_change(self):
        manager = CardManager(self.store, None)
        found = [Discovered('new/model', {'model': 'm', 'api_base': 'https://p/v1'}, UNPRICED)]
        with self.assertLogs('ovid.images.cards', 'WARNING') as logs:
            manager.tick(lambda: found)
            manager.observe(found)
        self.assertEqual(len([l for l in logs.output if 'new/model' in l]), 1)
        card = manager.cards()[0]
        self.assertFalse(card['priced'])
        self.assertEqual(card['warnings'], [costing.UNPRICED_WARNING])
        # owner sets a price in LiteLLM: next discovery flips it, no restart, no re-probe needed
        manager.observe([Discovered('new/model', found[0].params, {**UNPRICED, 'input_cost_per_token': 1e-6})])
        card = manager.cards()[0]
        self.assertTrue(card['priced'])
        self.assertEqual((card['cost_source'], card['warnings']), ('tokens', []))

    def test_header_seen_by_probe_marks_priced(self):
        class HeaderTransport:
            def call(self, model, kind, p):
                return ProbeOutcome(True, None, 10, 0.03, (png_bytes(),), cost_source=costing.HEADER)
        runner = ProbeRunner(HeaderTransport(), self.store, max_sizes=1)
        manager = CardManager(self.store, runner)
        manager.tick(lambda: [Discovered('h/model', {'model': 'm'}, UNPRICED)])
        card = manager.cards()[0]
        self.assertTrue(card['priced'] and card['cost_source'] == 'header')


class RoutingGateTest(Fixture):
    def test_unpriced_skipped_for_auto_and_explicit_with_422(self):
        for c in self.cards:
            c['priced'] = c['model'] != 'prov/cheap'
        cards = [dict(c) for c in self.cards]
        self.assertIn('unpriced', missing(cards[0], Task()))
        ranked = [c['model'] for c in pick_backends(Task(preference='cost'), cards)]
        self.assertNotIn('prov/cheap', ranked)
        self.assertNotIn(cards[0]['slug'], alternatives(Task(), cards))

    def test_service_returns_422_no_priced_model(self):
        for c in self.cards:
            c['priced'] = False
        with self.transport(), self.assertRaises(ImageError) as caught:
            self.run_job('request-7001')
        self.assertEqual((caught.exception.status, caught.exception.code), (422, 'unsupported_image_operation'))
        self.assertEqual(caught.exception.detail, {'alternatives': [], 'reason': 'no_priced_model'})
        self.assertEqual(self.calls, [])
        self.assertEqual(self.ledger.spent('owner', include_pending=True), Decimal('0'))

    def test_priced_models_still_served_when_others_unpriced(self):
        self.cards[0]['priced'] = False
        with self.transport():
            result = self.run_job('request-7002', preference='cost')
        self.assertNotEqual(self.calls[0][0], 'prov/cheap')


class AdminTest(unittest.TestCase):
    def test_admin_shows_priced_warnings_budget_and_refresh(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = CardStore(Path(tmp) / 'c.sqlite')
            runner = ProbeRunner(FakeLiteLLM(), store, per_probe_cap=0.5, daily_cap=5.0)
            manager = CardManager(store, runner)
            info = [UNPRICED]
            manager.observe([Discovered('u/m', {'model': 'm'}, info[0])])
            refreshed = []
            app = FastAPI()
            mount_admin(app, manager, 'k', refresh_prices=lambda: (
                refreshed.append(1), manager.observe([Discovered('u/m', {'model': 'm'}, PRICED)])))
            client, auth = TestClient(app), {'Authorization': 'Bearer k'}
            body = client.get('/images/admin/cards', headers=auth).json()
            card = body['cards'][0]
            self.assertEqual((card['priced'], card['cost_source']), (False, None))
            self.assertEqual(card['warnings'], [costing.UNPRICED_WARNING])
            self.assertEqual(body['probe_budget']['probe_daily_cap_usd'], 5.0)
            self.assertEqual(body['probe_budget']['probe_daily_left_usd'], 5.0)
            self.assertEqual(body['probe_budget']['probe_per_call_cap_usd'], 0.5)
            self.assertEqual(client.post('/images/admin/refresh-prices').status_code, 403)
            r = client.post('/images/admin/refresh-prices', headers=auth)
            self.assertEqual(r.json()['priced'], {'u/m': True})
            self.assertEqual(refreshed, [1])


class CostingRulesTest(unittest.TestCase):
    def test_no_gateway_side_price_source(self):
        cost, source = costing.determine_cost(usage=None, prices={'ovid_flat_cost_usd': Decimal('1')})
        self.assertEqual((cost, source), (None, None))
        self.assertNotIn('ovid_flat_cost_usd', costing.normalize_prices({'ovid_flat_cost_usd': 1}))


class UnknownFamilyTest(unittest.TestCase):
    def test_no_hint_no_metadata_is_conservative_and_never_crashes(self):
        facts, meta = static_extract('zz-quux-9000', {}, {}, None, None)
        self.assertEqual(facts['operations'], {})
        self.assertNotIn('sizes', facts)
        card = default_card('zz-quux-9000')
        self.assertTrue(supports(card, 'generate') and not supports(card, 'edit'))
        static_extract('x', None, None, 'garbage', 'garbage')

    def test_foreign_models_listing_schemas_are_ignored(self):
        for listing in (None, 'x', 3, [], ['a', 'b'], {'data': 'nope'}, {'data': [None, 3, {'id': 5}]},
                        {'models': [{'id': 'm'}]}, {'data': [{'id': 'm', 'architecture': 'weird',
                                                              'input_schema': 'weird'}]}):
            entry = provider_models_entry(listing, 'prov/m')
            facts, _ = static_extract('m', {'model': 'prov/m'}, {}, None, entry)
            self.assertIsInstance(facts['operations'], dict)

    def test_probes_establish_truth_for_unknown_family(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = CardStore(Path(tmp) / 'c.sqlite')
            manager = CardManager(store, ProbeRunner(FakeLiteLLM(edit=True, mask=False, multi=False), store))
            manager.tick(lambda: [Discovered('zz-quux', {'model': 'quux'}, PRICED)])
            card = manager.cards()[0]
            self.assertEqual(card['state'], 'probed')
            self.assertTrue(supports(card, 'edit') and not supports(card, 'inpaint'))


class UrlAndFormatTest(unittest.TestCase):
    def transport(self, handler):
        return LiteLLMProbeTransport('http://litellm', 'sk-probe', master_key='m', spend_wait=0,
                                     client_factory=lambda **kw: httpx.Client(**kw, transport=httpx.MockTransport(handler)))

    def handler(self, payload):
        def handle(request):
            if request.url.path == '/key/info':
                return httpx.Response(200, json={'info': {'spend': 0}})
            return httpx.Response(200, json=payload)
        return handle

    def test_url_reply_is_detected_never_fetched(self):
        fetched = []

        def handle(request):
            if request.url.host != 'litellm':
                fetched.append(request.url)
            return self.handler({'data': [{'url': 'https://cdn.example/x.png'}]})(request)
        out = self.transport(handle).call('m', 'generate', {'prompt': 'p', 'size': '1024x1024'})
        self.assertEqual((out.ok, out.error_class), (False, URL_RESPONSE))
        self.assertEqual(fetched, [])

    def test_url_provider_gets_unsupported_card_with_warning(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = CardStore(Path(tmp) / 'c.sqlite')

            class UrlTransport:
                def call(self, model, kind, p):
                    return ProbeOutcome(False, URL_RESPONSE, 10, 0.0)
            manager = CardManager(store, ProbeRunner(UrlTransport(), store))
            manager.tick(lambda: [Discovered('u/m', {'model': 'm'}, PRICED)])
            card = manager.cards()[0]
            self.assertFalse(supports(card, 'generate'))
            self.assertTrue(any(w.startswith('returns_urls:') for w in card['warnings']))
            self.assertEqual(card['state'], 'inferred')

    def test_non_image_payload_is_inconclusive_not_a_fact(self):
        out = self.transport(self.handler({'data': [{'b64_json': base64.b64encode(b'<html>').decode()}]})).call(
            'm', 'generate', {'prompt': 'p', 'size': '1024x1024'})
        self.assertEqual((out.ok, out.error_class), (False, INCONCLUSIVE))

    def test_webp_output_is_accepted_and_recorded(self):
        raw = webp_bytes()

        class WebpTransport:
            def call(self, model, kind, p):
                return ProbeOutcome(True, None, 10, 0.01, (raw,))
        with tempfile.TemporaryDirectory() as tmp:
            card, _ = ProbeRunner(WebpTransport(), CardStore(Path(tmp) / 'c.sqlite')).run(default_card('w'))
        self.assertEqual(card['output_formats'], ['webp'])
        out = self.transport(self.handler({'data': [{'b64_json': base64.b64encode(raw).decode()}]})).call(
            'm', 'generate', {'prompt': 'p', 'size': '1024x1024'})
        self.assertTrue(out.ok)

    def test_cost_source_header_propagates(self):
        def handle(request):
            if request.url.path == '/key/info':
                return httpx.Response(200, json={'info': {'spend': 0}})
            return httpx.Response(200, headers={'x-litellm-response-cost': '0.02'},
                                  json={'data': [{'b64_json': base64.b64encode(png_bytes()).decode()}]})
        out = self.transport(handle).call('m', 'generate', {'prompt': 'p', 'size': '1024x1024'})
        self.assertEqual(out.cost_source, costing.HEADER)


class ClassificationTest(unittest.TestCase):
    def test_classes(self):
        cases = [(401, '', AUTH), (403, 'forbidden', AUTH), (402, '', BUDGET),
                 (429, 'insufficient_quota: you exceeded your current quota', BUDGET),
                 (400, 'Budget has been exceeded', BUDGET),
                 (429, 'rate limit reached', TRANSIENT), (500, 'boom', TRANSIENT), (503, '', TRANSIENT),
                 (400, 'invalid size 512x512', UNSUPPORTED), (404, 'model not found', UNSUPPORTED),
                 (400, '{"code":"unsupported_modality"}', UNSUPPORTED),
                 (400, 'your request was rejected by the safety system', INCONCLUSIVE),
                 (400, 'image too small, minimum 256', INCONCLUSIVE)]
        for status, text, expected in cases:
            self.assertEqual(classify_error(status, text), expected, (status, text))

    def test_rejected_size_marks_only_that_size(self):
        fake = FakeLiteLLM(sizes=('1024x1024',))
        with tempfile.TemporaryDirectory() as tmp:
            card, _ = ProbeRunner(fake, CardStore(Path(tmp) / 'c.sqlite'), max_sizes=3).run(default_card('m'))
        self.assertEqual(card['sizes']['native'], ['1024x1024'])


class ProbeBudgetTest(unittest.TestCase):
    def test_estimate_over_cap_skips_probing_with_warning(self):
        fake = FakeLiteLLM()
        with tempfile.TemporaryDirectory() as tmp:
            store = CardStore(Path(tmp) / 'c.sqlite')
            manager = CardManager(store, ProbeRunner(fake, store, per_probe_cap=0.5))
            manager.tick(lambda: [Discovered('big/m', {'model': 'm'}, {**UNPRICED, 'output_cost_per_image': 2.0})])
            card = manager.cards()[0]
        self.assertEqual(fake.calls, [])
        self.assertTrue(any(w.startswith('probe_skipped:') for w in card['warnings']))
        self.assertEqual(card['state'], 'inferred')

    def test_new_model_probes_are_staggered(self):
        now = [1000.0]
        fake = FakeLiteLLM()
        with tempfile.TemporaryDirectory() as tmp:
            store = CardStore(Path(tmp) / 'c.sqlite', clock=lambda: now[0])
            runner = ProbeRunner(fake, store, clock=lambda: now[0])
            manager = CardManager(store, runner, clock=lambda: now[0], probe_gap=30)
            found = [Discovered('a/m', {'model': 'a'}, PRICED), Discovered('b/m', {'model': 'b'}, PRICED)]
            self.assertEqual(manager.tick(lambda: found), 'a/m')
            self.assertIsNone(manager.tick(lambda: found))        # too soon: second model waits
            now[0] += 31
            self.assertEqual(manager.tick(lambda: found), 'b/m')
            self.assertEqual(fake.max_active, 1)


if __name__ == '__main__':
    unittest.main()
