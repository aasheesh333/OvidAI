import { describe, expect, it } from 'vitest';
import { Decimal } from 'decimal.js';
import { money } from './money';
import { pyNumStr, pyRound, pyRound6 } from './pyCompat';

// Golden vectors verified against CPython 3.12:
//   round(), str(float) semantics — the reference behaviour the Python image
//   service relies on (server/images/service.py, usage float fields).

describe('pyRound() — Python round() parity', () => {
  it('rounds half-even, never half-up', () => {
    expect(pyRound(2.5, 0)).toBe(2);
    expect(pyRound(3.5, 0)).toBe(4);
    expect(pyRound(-2.5, 0)).toBe(-2);
    expect(pyRound(0.25, 1)).toBe(0.2);
  });

  it('rounds the exact binary double, like Python (not its decimal spelling)', () => {
    // Python: round(2.675, 2) == 2.67 — the double is 2.67499999999999982236...
    expect(pyRound(2.675, 2)).toBe(2.67);
    // Python: round(0.15, 1) == 0.1 — the double is 0.14999999999999999444...
    expect(pyRound(0.15, 1)).toBe(0.1);
    expect(pyRound(0.125, 2)).toBe(0.12); // exact tie -> half-even down
    // Python: round(0.135, 2) == 0.14 — the double is 0.13500000000000000888...
    expect(pyRound(0.135, 2)).toBe(0.14);
  });

  it('float-poisoning canary through the exact-double path', () => {
    // Python: round(0.1 + 0.2, 6) == 0.3 — the exact double is 0.30000000000000004440...
    expect(pyRound(0.1 + 0.2, 6)).toBe(0.3);
  });

  it('pyRound6 golden: Python round(1.234567895, 6) == 1.234568', () => {
    expect(pyRound6(1.234567895)).toBe(1.234568);
    expect(pyRound6(money('1.234567895'))).toBe(1.234568);
  });

  it('rounds Money (Decimal) inputs half-even on the exact decimal value', () => {
    expect(pyRound(money('2.5'), 0)).toBe(2);
    expect(pyRound(money('0.125'), 2)).toBe(0.12);
    expect(pyRound(money('0.135'), 2)).toBe(0.14);
  });

  it('negative places round to powers of ten (Python round(x, -2))', () => {
    expect(pyRound(1234.5, -2)).toBe(1200);
    expect(pyRound(1250, -2)).toBe(1200); // exact tie at 1250 -> half-even to 1200
    expect(pyRound(1350, -2)).toBe(1400);
    expect(pyRound(-1234.5, -2)).toBe(-1200);
  });

  it('passes non-finite values through like Python round(nan/inf, n)', () => {
    expect(pyRound(NaN, 2)).toBeNaN();
    expect(pyRound(Infinity, 2)).toBe(Infinity);
    expect(pyRound(-Infinity, 2)).toBe(-Infinity);
  });
});

describe('pyNumStr() — Python str(float) parity', () => {
  it('brief vectors', () => {
    expect(pyNumStr(3)).toBe('3.0');
    expect(pyNumStr(0.15)).toBe('0.15');
    expect(pyNumStr(100000)).toBe('100000.0');
  });

  it('matches Python repr thresholds and exponent padding', () => {
    expect(pyNumStr(0)).toBe('0.0');
    expect(pyNumStr(-0)).toBe('-0.0');
    expect(pyNumStr(0.5)).toBe('0.5');
    expect(pyNumStr(-1.5)).toBe('-1.5');
    expect(pyNumStr(0.0001)).toBe('0.0001'); // plain at Python's 1e-4 threshold
    expect(pyNumStr(1.5e-4)).toBe('0.00015');
    expect(pyNumStr(1e-5)).toBe('1e-05'); // exponent padded to two digits
    expect(pyNumStr(1.5e-5)).toBe('1.5e-05');
    expect(pyNumStr(1e15)).toBe('1000000000000000.0'); // plain below 1e16
    expect(pyNumStr(1e16)).toBe('1e+16'); // exponential at Python's 1e16 threshold
    expect(pyNumStr(1e21)).toBe('1e+21');
    // Both languages print the shortest round-tripping decimal.
    expect(pyNumStr(1234567890123456.75)).toBe('1234567890123456.8');
  });

  it('never mutates the shared decimal.js config', () => {
    const precision = Decimal.precision;
    const rounding = Decimal.rounding;
    pyRound(2.675, 2);
    pyRound6(1.234567895);
    pyRound(money('2.5'), 0);
    expect(Decimal.precision).toBe(precision);
    expect(Decimal.rounding).toBe(rounding);
  });
});
