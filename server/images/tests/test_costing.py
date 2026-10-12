import unittest
from decimal import Decimal

from server.images import costing as c
from server.images.service import discounted

P25 = {'input_cost_per_token': Decimal('9e-08'), 'output_cost_per_token': Decimal('9e-06')}
USAGE25 = {'total_tokens': 1296, 'input_tokens': 6, 'output_tokens': 1290,
           'input_tokens_details': {}, 'output_tokens_details': None}


class CostingTest(unittest.TestCase):
    def test_header_wins(self):
        cost, src = c.determine_cost(headers={c.COST_HEADER: '0.0017928'}, usage=USAGE25, prices=P25)
        self.assertEqual((cost, src), (Decimal('0.0017928'), 'header'))

    def test_bad_header_falls_to_tokens(self):
        for bad in ('nan', 'inf', '-1', '0', 'abc', '', '1e999', '5000'):
            cost, src = c.determine_cost(headers={c.COST_HEADER: bad}, usage=USAGE25, prices=P25)
            self.assertEqual(src, 'tokens', bad)

    def test_tokens_gemini25(self):
        cost, src = c.determine_cost(headers={}, usage=USAGE25, prices=lambda: P25)
        self.assertEqual(src, 'tokens')
        self.assertEqual(cost, Decimal('6') * Decimal('9e-08') + Decimal('1290') * Decimal('9e-06'))
        self.assertAlmostEqual(float(cost), 0.0116, places=4)

    def test_usage_naming_variants(self):
        u = {'prompt_tokens': 6, 'completion_tokens': 1290}
        self.assertEqual(c.token_cost(u, P25), c.token_cost(USAGE25, P25))

    def test_per_image_fallback(self):
        prices = c.normalize_prices({'input_cost_per_image': 0.01, 'output_cost_per_image': 0.03})
        self.assertEqual(c.token_cost(None, prices, n=2), Decimal('0.08'))
        self.assertEqual(c.token_cost({'input_tokens': 0, 'output_tokens': 0}, prices), Decimal('0.04'))

    def test_tokens_preferred_over_per_image(self):
        prices = dict(P25, input_cost_per_image=Decimal('0.5'))
        self.assertEqual(c.token_cost(USAGE25, prices), c.token_cost(USAGE25, P25))

    def test_missing_prices_fall_to_spend_delta(self):
        cost, src = c.determine_cost(headers={}, usage=USAGE25, prices={}, spend_before=1.0,
                                     spend_read=lambda: 1.25)
        self.assertEqual((cost, src), (Decimal('0.25'), 'spend_delta'))

    def test_spend_lag_one_delayed_reread(self):
        reads, sleeps = [1.0, 1.5], []
        cost, src = c.determine_cost(spend_before=1.0, spend_read=lambda: reads.pop(0), spend_wait=1.5,
                                     spend_poll=1.5, sleep=sleeps.append)
        self.assertEqual((cost, src, sleeps), (Decimal('0.5'), 'spend_delta', [1.5]))

    def test_spend_retry_is_bounded(self):
        n, sleeps = [0], []
        def read():
            n[0] += 1
            return 1.0
        self.assertEqual(c.determine_cost(spend_before=1.0, spend_read=read, spend_wait=1.5,
                                          spend_poll=1.5, sleep=sleeps.append), (None, None))
        self.assertEqual((n[0], sleeps), (2, [1.5]))

    def test_nothing_usable_is_none(self):
        self.assertEqual(c.determine_cost(headers={}, usage={}, prices=P25, spend_before=None), (None, None))
        self.assertEqual(c.determine_cost(), (None, None))

    def test_rejects_garbage(self):
        for bad in (0, -1, float('nan'), float('inf'), True, None, [], 10**9, '1e500', Decimal('NaN')):
            self.assertIsNone(c.positive_cost(bad), repr(bad))
        for u in ({'input_tokens': -5, 'output_tokens': -5}, {'output_tokens': float('nan')},
                  {'output_tokens': 10**12}, {'output_tokens': True}):
            self.assertIsNone(c.token_cost(u, P25), u)
        self.assertEqual(c.normalize_prices({'input_cost_per_token': -1, 'output_cost_per_token': 'x',
                                             'input_cost_per_image': 99}), {})
        self.assertIsNone(c.spend_delta_cost(1.0, float('inf')))
        self.assertIsNone(c.spend_delta_cost(2.0, 1.0))

    def test_cap_at_bound(self):
        self.assertEqual(c.determine_cost(headers={c.COST_HEADER: '5'}, bound=Decimal('1.00'))[0], Decimal('1.00'))
        self.assertEqual(c.token_cost({'output_tokens': 10_000_000}, P25, bound=Decimal('1')), Decimal('1'))
        self.assertEqual(c.spend_delta_cost(0.0, 7.0, Decimal('1')), Decimal('1'))

    def test_decimal_precision_matches_ledger(self):
        cost = c.token_cost(USAGE25, P25)
        self.assertEqual(cost, Decimal('0.01161054'))
        self.assertEqual(discounted(cost), cost * Decimal('0.30'))

    def test_pricebook_cache_and_miss(self):
        t, calls = [0.0], []
        def fetch():
            calls.append(1)
            return {'m': {'output_cost_per_token': 1e-6}}
        book = c.PriceBook(fetch, ttl=300, miss_interval=30, clock=lambda: t[0], background=False)
        self.assertEqual(book.get('m'), {'output_cost_per_token': Decimal('1E-6')})
        book.get('m')
        self.assertEqual(len(calls), 1)
        self.assertIsNone(book.get('unknown'))      # rate limited miss
        self.assertEqual(len(calls), 1)
        t[0] = 31
        self.assertIsNone(book.get('unknown'))
        self.assertEqual(len(calls), 2)
        t[0] = 400
        book.get('m')
        self.assertEqual(len(calls), 3)

    def test_pricebook_error_keeps_old_and_none(self):
        def boom():
            raise RuntimeError('x')
        self.assertIsNone(c.PriceBook(boom).get('m'))

    def test_parse_model_info(self):
        out = c.parse_model_info({'data': [
            {'model_name': 'a', 'model_info': {}},
            {'model_name': 'a', 'model_info': {'output_cost_per_token': 1e-6}},
            {'model_name': 5}, 'junk']})
        self.assertEqual(c.normalize_prices(out['a']), {'output_cost_per_token': Decimal('1E-6')})


if __name__ == '__main__':
    unittest.main()
