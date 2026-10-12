import unittest

from server.images.capabilities import cap, default_card, finalize, merge_facts
from server.images.routing import (PREFERENCES, Task, alternatives, missing, parse_model, pick_backends,
                                   task_from_request)


def card(model, *, edit=False, inpaint=False, multi=0, transparent=False, sizes=('1024x1024',), ratios=None,
         latency=None, cost='med', quality='med', text='none', state='probed'):
    c = default_card(model)
    c['state'] = state
    c['operations']['edit'] = cap(edit, 'probed')
    c['operations']['inpaint'] = cap(inpaint, 'probed')
    c['operations']['multi_image'] = cap(bool(multi), 'probed', max_inputs=multi or 0)
    c['operations']['transparent_output'] = cap(transparent, 'probed')
    c['sizes'] = {'native': list(sizes), 'aspect_ratios': ratios or ['1:1'], 'source': 'probed', 'confidence': 0.9}
    c.update(latency_ms_p50=latency, cost_tier=cost, quality=quality)
    c['text_rendering'] = {'level': text, 'source': 'inferred', 'confidence': 0.5}
    return finalize(c)


CARDS = [
    card('cheap-fast', latency=4000, cost='low', quality='low', sizes=('1024x1024',)),
    card('editor', edit=True, inpaint=True, multi=3, latency=20000, cost='med', quality='med',
         sizes=('1024x1024', '1536x1024'), ratios=['1:1', '3:2']),
    card('pro', edit=True, inpaint=True, multi=8, transparent=True, latency=40000, cost='high', quality='high',
         text='good', sizes=('1024x1024', '1536x1024', '1024x1536'), ratios=['1:1', '3:2', '2:3']),
]


def models(task, **kw):
    return [c['model'] for c in pick_backends(task, CARDS, **kw)]


class RoutingTest(unittest.TestCase):
    def test_generate_balanced_and_preferences(self):
        self.assertEqual(models(Task(preference='cost'))[0], 'cheap-fast')
        self.assertEqual(models(Task(preference='speed'))[0], 'cheap-fast')
        self.assertEqual(models(Task(preference='quality'))[0], 'pro')

    def test_hard_filters(self):
        self.assertEqual(sorted(models(Task('edit', n_inputs=1))), ['editor', 'pro'])
        self.assertEqual(models(Task('inpaint', mask=True, n_inputs=1, preference='cost')), ['editor', 'pro'])
        self.assertEqual(models(Task('edit', n_inputs=5)), ['pro'])
        self.assertEqual(models(Task('generate', transparent=True)), ['pro'])
        self.assertEqual(sorted(models(Task('generate', size='1536x1024'))), ['editor', 'pro'])
        self.assertEqual(models(Task('generate', aspect_ratio='2:3')), ['pro'])
        self.assertEqual(models(Task('generate', size='2048x2048')), [])

    def test_text_need_overrides_cost_preference(self):
        self.assertEqual(models(Task(text_rendering=True, preference='cost'))[0], 'pro')

    def test_cooldown_models_are_skipped(self):
        self.assertEqual(models(Task('edit', n_inputs=1, preference='quality'), unavailable={'pro'}), ['editor'])
        self.assertEqual(models(Task(), unavailable=lambda m: m != 'editor'), ['editor'])

    def test_verified_card_beats_guessed_when_equal(self):
        guessed = card('guess', state='inferred')
        proven = card('proof', state='probed')
        self.assertEqual([c['model'] for c in pick_backends(Task(), [guessed, proven])], ['proof', 'guess'])

    def test_missing_and_alternatives(self):
        self.assertEqual(missing(CARDS[0], Task('edit', n_inputs=1)), ['edit'])
        self.assertEqual(set(alternatives(Task('edit', n_inputs=1), CARDS)), {CARDS[1]['slug'], CARDS[2]['slug']})

    def test_stable_ties_keep_input_order(self):
        twins = [card('b'), card('a')]
        self.assertEqual([c['model'] for c in pick_backends(Task(), twins)], ['b', 'a'])

    def test_all_preferences_known(self):
        for pref in PREFERENCES:
            self.assertTrue(models(Task(preference=pref)))


class ParseTest(unittest.TestCase):
    def test_model_parse(self):
        self.assertIsNone(parse_model('ovid-image'))
        self.assertEqual(parse_model('ovid-image:img-abc123'), 'ovid-image:img-abc123')
        for bad in ('gpt-image-2', 'ovid-image:', 'ovid-image:a b', None, 3):
            with self.assertRaises(ValueError):
                parse_model(bad)

    def test_task_from_request(self):
        t = task_from_request('generate', {'prompt': 'x', 'size': '1024x1024'})
        self.assertEqual((t.operation, t.size, t.n_inputs), ('generate', '1024x1024', 0))
        t = task_from_request('edit', {'image': 'i', 'mask': 'm'})
        self.assertEqual((t.operation, t.mask, t.n_inputs), ('inpaint', True, 1))
        t = task_from_request('edit', {'image': 'i', 'images': ['a', 'b']})
        self.assertEqual((t.operation, t.n_inputs), ('multi_image', 3))
        t = task_from_request('edit', {'image': 'i', 'requirements': {'operation': 'remove_background'}, 'preference': 'cost'})
        self.assertEqual((t.operation, t.preference), ('remove_background', 'cost'))
        for bad in ({'requirements': {'x': 1}}, {'preference': 'fancy'}, {'requirements': {'operation': 'edit'}},
                    {'requirements': {'aspect_ratio': 'wide'}}):
            with self.assertRaises(ValueError):
                task_from_request('generate', bad)
