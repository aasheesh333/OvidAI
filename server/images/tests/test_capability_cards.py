"""Card schema, static extraction, fingerprinting and the public projection."""
import json
import unittest

from server.images.capabilities import (
    assign_cost_tiers, catalog_hash, cap, default_card, finalize, fingerprint, legacy_card,
    merge_facts, public_card, slug_for, supports,
)
from server.images.extraction import cost_map_lookup, provider_models_entry, static_extract

PARAMS = {'model': 'openai/gpt-image-2', 'api_base': 'https://secret-provider.example/v1'}
COST_MAP = {'gpt-image-2': {'mode': 'image_generation', 'supported_endpoints': ['/v1/images/generations', '/v1/images/edits'],
                            'output_cost_per_image': 0.04}}


class StaticExtractionTest(unittest.TestCase):
    def test_model_info_and_cost_map_declare_edit_and_cost(self):
        facts, meta = static_extract('cb/gpt-image-2', PARAMS, {'mode': 'image_generation'}, COST_MAP)
        self.assertTrue(facts['operations']['generate']['supported'])
        self.assertEqual(facts['operations']['edit'], {'supported': True, 'source': 'declared', 'confidence': 0.85})
        self.assertEqual(facts['measured_cost_usd'], 0.04)
        self.assertIn('litellm.supported_endpoints', meta['sources'])

    def test_endpoints_without_edits_mark_edit_unsupported(self):
        info = {'mode': 'image_generation', 'supported_endpoints': ['/v1/images/generations']}
        facts, _ = static_extract('x/some-model', {'model': 'some-model'}, info)
        self.assertIs(facts['operations']['edit']['supported'], False)

    def test_unknown_model_gets_no_guessed_edit(self):
        facts, _ = static_extract('mystery', {}, {'mode': 'image_generation'})
        card = merge_facts(default_card('mystery'), facts)
        self.assertFalse(supports(card, 'edit'))
        self.assertEqual(card['sizes']['native'], ['1024x1024'])

    def test_openrouter_style_architecture(self):
        entry = provider_models_entry({'data': [{'id': 'vendor/pic', 'architecture': {
            'input_modalities': ['text', 'image'], 'output_modalities': ['image']}}]}, 'openrouter/vendor/pic')
        self.assertEqual(entry['id'], 'vendor/pic')
        entry = provider_models_entry({'data': [{'id': 'pic', 'architecture': {
            'input_modalities': ['text', 'image'], 'output_modalities': ['image']}}]}, 'openai/pic')
        facts, meta = static_extract('pic', {'model': 'openai/pic'}, {}, None, entry)
        self.assertTrue(facts['operations']['edit']['supported'])
        self.assertIn('provider.architecture', meta['sources'])

    def test_replicate_style_input_schema(self):
        entry = {'id': 'm', 'input_schema': {'properties': {'prompt': {}, 'image': {}, 'mask': {}, 'aspect_ratio': {}}}}
        facts, _ = static_extract('m', {'model': 'm'}, {'mode': 'image_generation'}, None, entry)
        self.assertTrue(facts['operations']['inpaint']['supported'])
        self.assertTrue(facts['operations']['edit']['supported'])

    def test_family_hints_are_low_confidence_inferred(self):
        facts, _ = static_extract('cb/dall-e-3', {'model': 'dall-e-3'}, {'mode': 'image_generation'})
        self.assertIs(facts['operations']['edit']['supported'], False)
        self.assertEqual(facts['operations']['edit']['source'], 'inferred')
        self.assertIn('1792x1024', facts['sizes']['native'])
        self.assertEqual(facts['sizes']['source'], 'inferred')

    def test_cost_map_lookup_matches_tail(self):
        self.assertEqual(cost_map_lookup(COST_MAP, 'openai/gpt-image-2')['output_cost_per_image'], 0.04)


class CardBasicsTest(unittest.TestCase):
    def test_default_card_is_conservative(self):
        card = default_card('m')
        self.assertTrue(supports(card, 'generate'))
        for op in ('edit', 'inpaint', 'multi_image', 'transparent_output', 'upscale'):
            self.assertFalse(supports(card, op))
        self.assertEqual(card['sizes']['native'], ['1024x1024'])
        self.assertEqual(card['state'], 'default')

    def test_fingerprint_changes_with_model_or_base_url_not_key(self):
        a = fingerprint('m', {'model': 'x', 'api_base': 'https://a/v1', 'api_key': 'k1'})
        self.assertEqual(a, fingerprint('m', {'model': 'x', 'api_base': 'https://a/v1/', 'api_key': 'k2'}))
        self.assertNotEqual(a, fingerprint('m', {'model': 'x', 'api_base': 'https://b/v1'}))
        self.assertNotEqual(a, fingerprint('m', {'model': 'y', 'api_base': 'https://a/v1'}))
        self.assertNotEqual(a, fingerprint('n', {'model': 'x', 'api_base': 'https://a/v1'}))

    def test_probed_source_is_not_downgraded_by_inferred_merge(self):
        card = default_card('m')
        card['operations']['edit'] = cap(True, 'probed', 0.9)
        merge_facts(card, {'operations': {'edit': cap(False, 'inferred', 0.4)}})
        self.assertTrue(supports(card, 'edit'))

    def test_cost_tiers_are_relative(self):
        cards = [default_card(n) for n in 'abc']
        for card, cost in zip(cards, (0.01, 0.04, 0.2)):
            card['measured_cost_usd'] = cost
        assign_cost_tiers(cards)
        self.assertEqual([c['cost_tier'] for c in cards], ['low', 'med', 'high'])

    def test_public_card_never_leaks_internals(self):
        facts, meta = static_extract('cb/gpt-image-2', PARAMS, {'mode': 'image_generation'}, COST_MAP)
        card = merge_facts(default_card('cb/gpt-image-2', fingerprint('cb/gpt-image-2', PARAMS)), facts)
        card['static'] = meta
        card['latency_ms_p50'] = 9000
        finalize(card)
        public = public_card(card)
        blob = json.dumps(public)
        for secret in ('gpt-image', 'cb/', 'secret-provider', 'openai', 'cost_usd', '0.04', 'fingerprint', 'api_base'):
            self.assertNotIn(secret, blob)
        self.assertTrue(public['slug'].startswith('ovid-image:img-'))
        self.assertEqual(public['slug'], slug_for('cb/gpt-image-2'))
        self.assertEqual(public['cost_tier'], 'med')
        self.assertIn('edit', public['operations'])
        self.assertEqual(public['speed'], 'medium')

    def test_catalog_hash_is_order_independent_and_content_sensitive(self):
        a, b = public_card(legacy_card('a', ['1024x1024'], True)), public_card(legacy_card('b', ['1024x1024'], False))
        self.assertEqual(catalog_hash([a, b]), catalog_hash([b, a]))
        self.assertNotEqual(catalog_hash([a, b]), catalog_hash([a]))
