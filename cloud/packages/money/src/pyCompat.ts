import { Decimal } from 'decimal.js';
import type { Money } from './money.js';

/**
 * Python compatibility helpers: round() and str(float) parity with CPython 3,
 * matching the behaviour the Python image service relies on for usage float
 * fields and bounded settings values. No global decimal.js config is mutated.
 */

/**
 * Exact decimal expansion of an IEEE-754 binary64 double, derived from the bit
 * pattern via BigInt. This is the value Python's round(float, n) actually
 * operates on — NOT the shortest decimal spelling (round(2.675, 2) is 2.67
 * because the double is 2.67499999999999982236...).
 */
function doubleToExactString(n: number): string {
  const buffer = new ArrayBuffer(8);
  new Float64Array(buffer)[0] = n;
  const bits = new BigUint64Array(buffer)[0];
  const negative = (bits & 0x8000000000000000n) !== 0n;
  const biased = Number((bits >> 52n) & 0x7ffn);
  let mantissa = bits & 0xfffffffffffffn;
  let exponent: number;
  if (biased === 0) {
    exponent = -1074; // subnormal
  } else {
    mantissa |= 1n << 52n;
    exponent = biased - 1075;
  }
  if (mantissa === 0n) return negative ? '-0' : '0';
  let digits: string;
  let scale: number; // value = BigInt(digits) * 10^-scale
  if (exponent >= 0) {
    digits = (mantissa << BigInt(exponent)).toString();
    scale = 0;
  } else {
    // mantissa * 2^exponent = (mantissa * 5^-exponent) * 10^exponent
    digits = (mantissa * 5n ** BigInt(-exponent)).toString();
    scale = -exponent;
  }
  let text: string;
  if (scale === 0) {
    text = digits;
  } else if (digits.length > scale) {
    text = `${digits.slice(0, -scale)}.${digits.slice(-scale)}`;
  } else {
    text = `0.${'0'.repeat(scale - digits.length)}${digits}`;
  }
  return negative ? `-${text}` : text;
}

const EXACT = Decimal.clone({ precision: 1e9 });

/** Python round(Decimal|float, n): ROUND_HALF_EVEN, independent of context precision. */
function roundToPlaces(value: Decimal, places: number): Decimal {
  if (places >= 0) {
    return value.toDecimalPlaces(places, Decimal.ROUND_HALF_EVEN);
  }
  // Negative places: round to the nearest multiple of 10^(-places).
  const scale = EXACT(10).pow(-places);
  return EXACT(value.toString()).div(scale).toDecimalPlaces(0, Decimal.ROUND_HALF_EVEN).times(scale);
}

/**
 * Python round(): ROUND_HALF_EVEN applied to the exact value (the binary
 * expansion for float inputs, the decimal itself for Money), then converted to
 * the nearest double — Python round(2.5) is 2, round(3.5) is 4, round(2.675, 2)
 * is 2.67.
 */
export function pyRound(value: Money | number, places: number): number {
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return value; // round(nan/inf, n) == nan/inf
    if (Object.is(value, -0)) return -0;
    const rounded = roundToPlaces(new Decimal(doubleToExactString(value)), places);
    const out = Number(rounded.toString());
    // Python keeps the sign of zero: round(-0.001, 2) == -0.0.
    return out === 0 && value < 0 ? -0 : out;
  }
  return Number(roundToPlaces(value, places).toString());
}

/** pyRound(v, 6) — the /usage float fields' rounding. */
export function pyRound6(value: Money | number): number {
  return pyRound(value, 6);
}

/**
 * Python str(float) parity: 3 -> "3.0", 0.15 -> "0.15", 100000 -> "100000.0".
 * Plain notation exactly on CPython's [1e-4, 1e16) window; exponential outside
 * it, with the exponent padded to at least two digits (1e-05, 1e+16).
 */
export function pyNumStr(n: number): string {
  if (Number.isNaN(n)) return 'nan';
  if (n === Infinity) return 'inf';
  if (n === -Infinity) return '-inf';
  if (Object.is(n, -0)) return '-0.0';
  if (n === 0) return '0.0';
  const abs = Math.abs(n);
  if (abs >= 1e16 || abs < 1e-4) {
    const [mantissa, exponent] = n.toExponential().split('e');
    const exp = Number(exponent);
    return `${mantissa}e${exp < 0 ? '-' : '+'}${String(Math.abs(exp)).padStart(2, '0')}`;
  }
  const text = String(n); // shortest round-tripping decimal, as in Python repr
  return text.includes('.') ? text : `${text}.0`;
}
