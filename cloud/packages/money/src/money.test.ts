import { describe, expect, it } from 'vitest';
import { Decimal } from 'decimal.js';
import {
  SANITY_MAX,
  InvalidMoneyError,
  discounted,
  exactSum,
  money,
  positiveCost,
} from './money';

// Golden vectors transcribed from server/images/service.py (money/discounted/exact_sum)
// and server/images/costing.py + tests/test_costing.py (positive_cost / SANITY_MAX),
// with expected values verified against CPython 3.12 `decimal` semantics.
//
// DIVERGENCE NOTE (deliberate, value-safe): decimal.js normalizes away trailing
// coefficient zeros ("0.030" prints as "0.03"), while Python Decimal preserves
// them (str(Decimal("0.1") * Decimal("0.30")) == "0.030"). Every value here is
// EXACTLY equal to the Python result — tests pin Python's exact golden value via
// .equals() and pin .toString() only where decimal.js's canonical form matches
// Python str() (i.e. where the value carries no trailing zero).

describe('money()', () => {
  it('parses strings exactly', () => {
    expect(money('0.1').toString()).toBe('0.1');
    expect(money('5.0e2').toString()).toBe('500');
    expect(money('.5').toString()).toBe('0.5');
    expect(money('5.').toString()).toBe('5');
    // CPython strips surrounding whitespace and ALL underscores unconditionally.
    expect(money(' 5 ').toString()).toBe('5');
    expect(money('  0.5\t').toString()).toBe('0.5');
    expect(money('1_000').toString()).toBe('1000');
  });

  it('accepts finite JS numbers via the exact String(value) conversion pin', () => {
    // The float 0.1 must become the decimal 0.1 — never a binary expansion.
    expect(money(0.1).toString()).toBe('0.1');
    expect(money(3).toString()).toBe('3');
    expect(money(0.15).toString()).toBe('0.15');
    expect(money(1e-7).toString()).toBe('1e-7');
  });

  it('accepts Decimal instances and re-applies the bounds', () => {
    expect(money(money('0.1')).toString()).toBe('0.1');
    expect(() => money(new Decimal('1e400'))).toThrow(InvalidMoneyError);
    expect(() => money(new Decimal('9'.repeat(129)))).toThrow(InvalidMoneyError);
    expect(() => money(new Decimal('-1'))).toThrow(InvalidMoneyError);
  });

  it('rejects negative, non-finite, bool, garbage, and out-of-bounds values', () => {
    const bad: unknown[] = [
      '-1',
      -1,
      '1e400',
      '1e-400',
      '1e129',
      '1e-129',
      '9'.repeat(129),             // 129 significant digits
      '1' + '0'.repeat(128),       // 129 coefficient digits
      '0.00e-400',                 // zero still carries its tuple exponent in Python
      Infinity,
      -Infinity,
      NaN,
      1e308,                       // finite double, exponent outside +/-128
      true,
      false,
      'abc',
      '',
      '   ',
      '0.1.2',
      '1,5',
      'e5',
      '5e',
      '5e+',
      '+',
      '.',
      null,
      undefined,
      {},
      [],
      ['0.1'],
    ];
    for (const value of bad) {
      expect(() => money(value as string), `money(${String(value)})`).toThrow(InvalidMoneyError);
    }
  });

  it('accepts values at the exact bounds (128 digits, exponent +/-128, adjusted 128)', () => {
    // Python str() prints 128 digits in plain notation; decimal.js switches to
    // exponential above 20 digits (toExpPos) — same exact value.
    expect(money('9'.repeat(128)).equals(new Decimal('9'.repeat(128)))).toBe(true);
    expect(money('9'.repeat(128)).sd()).toBe(128);
    expect(money('1e128').toString()).toBe('1e+128');
    expect(money('1e-128').toString()).toBe('1e-128');
    expect(money('0.' + '0'.repeat(127) + '1').toString()).toBe('1e-128');
    expect(money('-0').toString()).toBe('0'); // Python accepts Decimal('-0') (not < 0)
  });
});

describe('discounted()', () => {
  it('multiplies by 0.30 exactly at digits+2 precision (test_costing.py golden)', () => {
    // test_decimal_precision_matches_ledger:
    //   cost = Decimal('0.01161054'); discounted(cost) == cost * Decimal('0.30')
    const cost = money('0.01161054');
    const out = discounted(cost);
    expect(out.equals(cost.times('0.30'))).toBe(true);
    // Python: str(discounted(cost)) == '0.0034831620' (trailing zero is decimal.js-normalized).
    expect(out.equals(new Decimal('0.0034831620'))).toBe(true);
    expect(out.toString()).toBe('0.003483162');
  });

  it('is exact for 0.1 (Python golden: Decimal("0.030"))', () => {
    const out = discounted(money('0.1'));
    expect(out.equals(new Decimal('0.030'))).toBe(true);
    expect(out.toString()).toBe('0.03'); // canonical form of the same exact value
  });

  it('never rounds: 40-digit value needs precision digits+2, not the default 20', () => {
    const big = money('0.1234567890123456789012345678901234567890');
    // Python: discounted(big) == Decimal('0.037037036703703703670370370367037037036700')
    expect(discounted(big).equals(new Decimal('0.037037036703703703670370370367037037036700'))).toBe(true);
  });

  it('re-validates its input (Python discounted() calls money())', () => {
    expect(() => discounted(new Decimal('-1'))).toThrow(InvalidMoneyError);
    expect(() => discounted(new Decimal('1e400'))).toThrow(InvalidMoneyError);
  });
});

describe('exactSum()', () => {
  it('float-poisoning canary: 0.1 + 0.2 === "0.3"', () => {
    expect(exactSum([money('0.1'), money('0.2')]).toString()).toBe('0.3');
  });

  it('empty sum is 0', () => {
    expect(exactSum([]).toString()).toBe('0');
  });

  it('sums mixed magnitudes exactly (default decimal.js precision would corrupt this)', () => {
    // Python: exact_sum([Decimal('1e30'), Decimal('0.001')]) == Decimal('1000000000000000000000000000000.001')
    const out = exactSum([money('1e30'), money('0.001')]);
    expect(out.equals(new Decimal('1000000000000000000000000000000.001'))).toBe(true);
  });

  it('ledger golden from test_costing.py values', () => {
    const cost = money('0.01161054');
    // Python: exact_sum([cost, discounted(cost), Decimal('1290')]) == Decimal('1290.0150937020')
    const out = exactSum([cost, discounted(cost), money('1290')]);
    expect(out.equals(new Decimal('1290.0150937020'))).toBe(true);
  });
});

describe('SANITY_MAX and positiveCost()', () => {
  it('SANITY_MAX is Decimal("1000")', () => {
    expect(SANITY_MAX.toString()).toBe('1000');
    expect(SANITY_MAX.equals(money('1000'))).toBe(true);
  });

  it('brief vectors', () => {
    expect(positiveCost('0', null)).toBeNull();
    expect(positiveCost('1500', null)).toBeNull(); // above SANITY_MAX with no bound
    expect(positiveCost('1500', money('1000'))!.toString()).toBe('1000'); // capped at bound
    expect(positiveCost(true as unknown)).toBeNull();
  });

  it('test_costing.py test_rejects_garbage vectors', () => {
    const bad: unknown[] = [
      0,
      -1,
      NaN,
      Infinity,
      -Infinity,
      true,
      false,
      null,
      undefined,
      [],
      {},
      10 ** 9,
      '1e500',
      'abc',
      '',
      '-1',
      '0',
    ];
    for (const value of bad) {
      expect(positiveCost(value), `positiveCost(${String(value)})`).toBeNull();
    }
    expect(positiveCost(new Decimal('NaN'))).toBeNull();
    expect(positiveCost(new Decimal('Infinity'))).toBeNull();
  });

  it('accepts positive bounded values (costing.py positive_cost port)', () => {
    // test_header_wins golden: x-litellm-response-cost '0.0017928' survives.
    expect(positiveCost('0.0017928', null)!.toString()).toBe('0.0017928');
    expect(positiveCost(0.5, null)!.toString()).toBe('0.5');
    expect(positiveCost(' 5 ', null)!.toString()).toBe('5'); // _dec strips whitespace
    expect(positiveCost('1000', null)!.toString()).toBe('1000'); // SANITY_MAX is inclusive
    expect(positiveCost('1000.5', null)).toBeNull();
    expect(positiveCost('10', money('1000'))!.toString()).toBe('10'); // min(out, bound)
    expect(positiveCost(money('1500'), money('2000'))!.toString()).toBe('1500');
    expect(positiveCost(new Decimal('1500'), new Decimal('1000'))!.toString()).toBe('1000');
  });
});

describe('global config hygiene', () => {
  it('never mutates the shared decimal.js config (per-call Decimal.clone only)', () => {
    const precision = Decimal.precision;
    const rounding = Decimal.rounding;
    money('9'.repeat(128));
    discounted(money('0.1'));
    exactSum([money('0.1'), money('0.2'), money('1e30')]);
    positiveCost('500', money('1000'));
    expect(Decimal.precision).toBe(precision);
    expect(Decimal.rounding).toBe(rounding);
  });
});
