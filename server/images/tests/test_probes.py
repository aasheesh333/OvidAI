"""Probe runner + card manager against fakes. No real provider is ever called."""
import base64
import io
import tempfile
import threading
import unittest
from pathlib import Path

import httpx
from PIL import Image

from server.images.capabilities import fingerprint, supports
from server.images.cardmanager import CardManager, Discovered
from server.images.cardstore import CardStore
from server.images.probes import (BUDGET, INCONCLUSIVE, TRANSIENT, UNSUPPORTED, LiteLLMProbeTransport,
                                  ProbeBusy, ProbeOutcome, ProbeRunner, classify_error, synthetic_png)


def png_bytes(alpha=False):
    out = io.BytesIO()
    Image.new('RGBA' if alpha else 'RGB', (8, 8), (1, 2, 3, 0) if alpha else (1, 2, 3)).save(out, 'PNG')
    return out.getvalue()


class FakeLiteLLM:
    """Programmable transport: `rules` maps probe kind to an outcome factory."""

    def __init__(self, *, sizes=('1024x1024', '1536x1024'), edit=True, mask=True, multi=True,
                 transparent=True, n2=True, cost=0.02, transient=(), latency=1500):
        self.sizes, self.edit, self.mask, self.multi = set(sizes), edit, mask, multi
        self.transparent, self.n2, self.cost, self.latency = transparent, n2, cost, latency
        self.transient = set(transient)   # probe labels that fail transiently
        self.calls = []
        self.active = 0
        self.max_active = 0
        self.hold = None

    def label(self, kind, p):
        if kind == 'generate':
            if p.get('background'):
                return 'transparent'
            if p.get('n', 1) == 2:
                return 'variations'
            return 'generate'
        if p.get('mask'):
            return 'inpaint'
        return 'multi_image' if len(p['images']) > 1 else 'edit'

    def call(self, model, kind, p):
        self.active += 1
        self.max_active = max(self.max_active, self.active)
        try:
            if self.hold:
                self.hold.wait(5)
            label = self.label(kind, p)
            self.calls.append((model, label, p.get('size')))
            if label in self.transient:
                return ProbeOutcome(False, TRANSIENT, 100, 0.0)
            ok = {'generate': p['size'] in self.sizes, 'edit': self.edit, 'inpaint': self.edit and self.mask,
                  'multi_image': self.edit and self.multi, 'transparent': True, 'variations': self.n2}[label]
            if not ok:
                return ProbeOutcome(False, UNSUPPORTED, 50, 0.0)
            if label == 'variations':
                return ProbeOutcome(True, None, self.latency, self.cost, (png_bytes(), png_bytes()))
            return ProbeOutcome(True, None, self.latency, self.cost, (png_bytes(alpha=label == 'transparent' and self.transparent),))
        finally:
            self.active -= 1


class ProbeRunnerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.now = [1_000_000.0]
        self.store = CardStore(Path(self.tmp.name) / 'cards.sqlite', clock=lambda: self.now[0])

    def runner(self, transport, **kw):
        return ProbeRunner(transport, self.store, clock=lambda: self.now[0], **kw)

    def card(self, name='m'):
        from server.images.capabilities import default_card
        return default_card(name)

    def test_full_capable_model_becomes_probed_card(self):
        fake = FakeLiteLLM()
        card, summary = self.runner(fake).run(self.card())
        self.assertEqual(card['state'], 'probed')
        for op in ('generate', 'edit', 'inpaint', 'multi_image', 'transparent_output', 'variations', 'outpaint'):
            self.assertTrue(supports(card, op), op)
        self.assertEqual(card['operations']['edit']['source'], 'probed')
        self.assertEqual(card['operations']['outpaint']['source'], 'inferred')
        self.assertEqual(card['sizes']['native'], ['1024x1024', '1536x1024'])
        self.assertIn('3:2', card['sizes']['aspect_ratios'])
        self.assertEqual(card['latency_ms_p50'], 1500)
        self.assertAlmostEqual(card['measured_cost_usd'], 0.02)
        self.assertEqual(card['max_n'], 2)
        self.assertGreater(card['probed_at'], 0)
        self.assertEqual(self.store.spent_since(0), summary['spent'])

    def test_unsupported_ops_are_marked_absent_and_dependents_skipped(self):
        fake = FakeLiteLLM(edit=False, transparent=False, n2=False)
        card, _ = self.runner(fake).run(self.card())
        self.assertTrue(supports(card, 'generate'))
        for op in ('edit', 'inpaint', 'multi_image', 'transparent_output', 'variations'):
            self.assertFalse(supports(card, op), op)
        labels = [c[1] for c in fake.calls]
        self.assertNotIn('inpaint', labels)
        self.assertNotIn('multi_image', labels)
        self.assertEqual(card['state'], 'probed')

    def test_transient_error_does_not_mark_capability_absent(self):
        fake = FakeLiteLLM(transient=('edit',))
        before = self.card()
        before['operations']['edit'] = {'supported': True, 'source': 'declared', 'confidence': 0.85}
        card, summary = self.runner(fake).run(before)
        self.assertTrue(supports(card, 'edit'))           # static claim survives a transient failure
        self.assertEqual(card['operations']['edit']['source'], 'declared')
        self.assertTrue(summary['transient'] and summary['incomplete'])
        self.assertEqual(card['state'], 'inferred')       # not promoted to verified
        self.assertNotIn('inpaint', [c[1] for c in fake.calls])

    def test_size_candidates_are_capped(self):
        fake = FakeLiteLLM(sizes=('1024x1024',))
        self.runner(fake, max_sizes=2).run(self.card())
        self.assertEqual({c[2] for c in fake.calls}, {'1024x1024', '1536x1024'})

    def test_per_probe_cap_stops_run(self):
        fake = FakeLiteLLM(cost=0.9)
        card, summary = self.runner(fake, per_probe_cap=0.5).run(self.card())
        self.assertEqual(summary['stop'], 'per_probe_cap')
        self.assertEqual(len(fake.calls), 1)
        self.assertEqual(card['state'], 'inferred')

    def test_daily_budget_is_enforced_across_runs(self):
        fake = FakeLiteLLM(cost=0.02)
        runner = self.runner(fake, daily_cap=0.05, estimated_cost=0.02)
        _, first = runner.run(self.card())
        self.assertEqual(first['stop'], 'daily_budget')
        used = len(fake.calls)
        _, second = runner.run(self.card())
        self.assertEqual(second['stop'], 'daily_budget')
        self.assertEqual(len(fake.calls), used)        # nothing more spent today
        self.now[0] += 25 * 3600                        # window rolls over
        runner.run(self.card())
        self.assertGreater(len(fake.calls), used)

    def test_budget_error_aborts(self):
        class Broke(FakeLiteLLM):
            def call(self, *a):
                return ProbeOutcome(False, BUDGET, 10, 0.0)
        card, summary = self.runner(Broke()).run(self.card())
        self.assertEqual(summary['stop'], BUDGET)
        self.assertEqual(card['state'], 'inferred')

    def test_concurrency_is_one(self):
        fake = FakeLiteLLM()
        fake.hold = threading.Event()
        runner = self.runner(fake)
        first = threading.Thread(target=lambda: runner.run(self.card('a')))
        first.start()
        while not fake.active:
            pass
        with self.assertRaises(ProbeBusy):
            self.runner(FakeLiteLLM()).run(self.card('b'))
        fake.hold.set()
        first.join(10)
        self.assertEqual(fake.max_active, 1)


class ErrorClassTest(unittest.TestCase):
    def test_classification(self):
        self.assertEqual(classify_error(400, 'size not supported'), UNSUPPORTED)
        self.assertEqual(classify_error(422, ''), UNSUPPORTED)
        self.assertEqual(classify_error(429, 'rate limit'), TRANSIENT)
        self.assertEqual(classify_error(503, 'no_capacity'), TRANSIENT)
        self.assertEqual(classify_error(500, 'model does not support edits'), UNSUPPORTED)
        self.assertEqual(classify_error(400, 'image too small, minimum 256'), INCONCLUSIVE)
        self.assertEqual(classify_error(400, 'Budget has been exceeded'), BUDGET)
        self.assertEqual(classify_error(401, ''), 'auth')


class HttpTransportTest(unittest.TestCase):
    def transport(self, handler):
        return LiteLLMProbeTransport('http://litellm', 'sk-probe', master_key='master', spend_wait=0,
                                     client_factory=lambda **kw: httpx.Client(**kw, transport=httpx.MockTransport(handler)))

    def test_generate_uses_probe_key_and_cost_header(self):
        seen = {}

        def handler(request):
            if request.url.path == '/key/info':
                return httpx.Response(200, json={'info': {'spend': 0}})
            seen['auth'] = request.headers['authorization']
            seen['body'] = request.content
            return httpx.Response(200, headers={'x-litellm-response-cost': '0.03'},
                                  json={'data': [{'b64_json': base64.b64encode(png_bytes()).decode()}]})
        out = self.transport(handler).call('cb/x', 'generate', {'prompt': 'p', 'size': '1024x1024'})
        self.assertTrue(out.ok)
        self.assertEqual(out.cost_usd, 0.03)
        self.assertEqual(seen['auth'], 'Bearer sk-probe')

    def test_edit_sends_mask_and_multiple_images_and_classifies_refusal(self):
        seen = {}

        def handler(request):
            if request.url.path == '/key/info':
                return httpx.Response(200, json={'info': {'spend': 0}})
            seen['body'] = request.content
            return httpx.Response(400, json={'error': {'message': 'mask is not supported'}})
        out = self.transport(handler).call('m', 'edit', {'prompt': 'p', 'size': '1024x1024',
                                                         'images': [synthetic_png(), synthetic_png()],
                                                         'mask': synthetic_png(alpha=True)})
        self.assertEqual((out.ok, out.error_class), (False, UNSUPPORTED))
        self.assertIn(b'name="image[]"', seen['body'])
        self.assertIn(b'name="mask"', seen['body'])

    def test_network_error_is_transient(self):
        def handler(request):
            if request.url.path == '/key/info':
                return httpx.Response(200, json={'info': {'spend': 0}})
            raise httpx.ConnectTimeout('slow')
        self.assertEqual(self.transport(handler).call('m', 'generate', {'prompt': 'p', 'size': '1024x1024'}).error_class,
                         TRANSIENT)

    def test_spend_delta_fallback(self):
        spend = [0.0]

        def handler(request):
            if request.url.path == '/key/info':
                return httpx.Response(200, json={'info': {'spend': spend[0]}})
            spend[0] = 0.07
            return httpx.Response(200, json={'data': [{'b64_json': base64.b64encode(png_bytes()).decode()}]})
        out = self.transport(handler).call('m', 'generate', {'prompt': 'p', 'size': '1024x1024'})
        self.assertAlmostEqual(out.cost_usd, 0.07)

    def test_gemini_style_usage_tokens_give_measured_cost(self):
        def handler(request):
            if request.url.path == '/key/info':
                return httpx.Response(200, json={'info': {'spend': 0}})
            if request.url.path == '/model/info':
                return httpx.Response(200, json={'data': [{'model_name': 'cb/g', 'model_info': {
                    'input_cost_per_token': 9e-08, 'output_cost_per_token': 9e-06}}]})
            return httpx.Response(200, json={'usage': {'input_tokens': 6, 'output_tokens': 1290},
                                             'data': [{'b64_json': base64.b64encode(png_bytes()).decode()}]})
        out = self.transport(handler).call('cb/g', 'generate', {'prompt': 'p', 'size': '1024x1024'})
        self.assertTrue(out.ok)
        self.assertAlmostEqual(out.cost_usd, 0.01161054)


class ManagerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.now = [1_000_000.0]
        self.store = CardStore(Path(self.tmp.name) / 'cards.sqlite', clock=lambda: self.now[0])
        self.fake = FakeLiteLLM()
        self.runner = ProbeRunner(self.fake, self.store, clock=lambda: self.now[0])
        self.manager = CardManager(self.store, self.runner, clock=lambda: self.now[0], ttl=7 * 86400)
        self.params = {'model': 'openai/m', 'api_base': 'https://a/v1'}

    def discover(self, params=None):
        return lambda: [Discovered('cb/m', params or self.params, {'mode': 'image_generation'})]

    def test_card_is_default_until_background_tick_then_probed(self):
        self.manager.observe(self.discover()())
        self.assertEqual(self.manager.card('cb/m')['state'], 'default')
        self.assertFalse(supports(self.manager.card('cb/m'), 'edit'))
        self.assertEqual(self.fake.calls, [])             # request path never probes
        self.assertEqual(self.manager.tick(self.discover()), 'cb/m')
        card = self.manager.card('cb/m')
        self.assertEqual(card['state'], 'probed')
        self.assertTrue(supports(card, 'edit'))
        self.assertIsNone(self.manager.tick(self.discover()))   # nothing due now

    def test_static_card_is_stored_before_probes_run(self):
        seen = []
        orig = self.fake.call

        def spy(model, kind, p):
            seen.append(self.store.get('cb/m')['state'])
            return orig(model, kind, p)
        self.fake.call = spy
        self.manager.tick(self.discover())
        self.assertEqual(seen[0], 'inferred')

    def test_changed_fingerprint_triggers_reprobe_and_keeps_history(self):
        self.manager.tick(self.discover())
        calls = len(self.fake.calls)
        changed = {'model': 'openai/m', 'api_base': 'https://other/v1'}
        self.assertEqual(self.manager.card('cb/m', changed)['state'], 'default')   # old card not trusted
        self.assertEqual(self.manager.tick(self.discover(changed)), 'cb/m')
        self.assertGreater(len(self.fake.calls), calls)
        self.assertEqual(self.manager.card('cb/m', changed)['fingerprint'], fingerprint('cb/m', changed))
        self.assertGreaterEqual(len(self.store.history('cb/m')), 4)

    def test_weekly_reprobe_and_admin_force(self):
        self.manager.tick(self.discover())
        self.now[0] += 6 * 86400
        self.assertIsNone(self.manager.tick(self.discover()))
        self.now[0] += 2 * 86400
        self.assertEqual(self.manager.tick(self.discover()), 'cb/m')
        self.assertIsNone(self.manager.tick(self.discover()))
        self.assertTrue(self.manager.reprobe('cb/m'))
        self.assertEqual(self.manager.tick(self.discover()), 'cb/m')
        self.assertFalse(self.manager.reprobe('nope'))

    def test_transient_failure_backs_off_exponentially(self):
        self.fake.transient = {'generate'}
        self.manager.tick(self.discover())
        state = self.store.probe_state('cb/m')
        self.assertEqual(state['attempts'], 1)
        self.assertIsNone(self.manager.tick(self.discover()))      # inside backoff window
        self.now[0] += 301
        self.assertEqual(self.manager.tick(self.discover()), 'cb/m')
        self.assertEqual(self.store.probe_state('cb/m')['attempts'], 2)
        self.assertGreaterEqual(self.store.probe_state('cb/m')['next_attempt_at'], self.now[0] + 600)

    def test_cards_survive_restart(self):
        self.manager.tick(self.discover())
        again = CardManager(self.store, None)
        again.observe(self.discover()())
        self.assertEqual(again.card('cb/m')['state'], 'probed')

    def test_without_probe_key_static_card_only_and_no_loop(self):
        manager = CardManager(self.store, None, clock=lambda: self.now[0])
        self.assertEqual(manager.tick(self.discover()), 'cb/m')
        self.assertIsNone(manager.tick(self.discover()))
        self.assertEqual(manager.card('cb/m')['state'], 'inferred')
        self.assertEqual(self.fake.calls, [])

    def test_provider_metadata_is_used_when_base_url_exposes_it(self):
        manager = CardManager(self.store, None, fetch_json=lambda url: {'data': [{'id': 'm', 'architecture': {
            'input_modalities': ['text', 'image'], 'output_modalities': ['image']}}]})
        manager.tick(self.discover())
        self.assertTrue(supports(manager.card('cb/m'), 'edit'))
        self.assertIn('provider.architecture', manager.card('cb/m')['static']['sources'])
