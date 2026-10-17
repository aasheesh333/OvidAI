import { Decimal } from 'decimal.js';

/**
 * Exact decimal money core — a faithful port of `server/images/service.py`
 * (`money`, `discounted`, `exact_sum`) and `server/images/costing.py`
 * (`SANITY_MAX`, `positive_cost`).
 *
 * MONEY IS SACRED: no binary float ever touches a money value. Every value is a
 * decimal.js Decimal; JS numbers are accepted only through the exact
 * `String(value)` pin, and every arithmetic path runs under a per-call
 * `Decimal.clone(...)` context (the global decimal.js config is never mutated).
 */

/** decimal.js instance, always finite, >= 0, bounded to 128 digits / ±128 exponent via money(). */
export type Money = Decimal;

/** Callers map this to their contract (images: 502 invalid_image_response). */
export class InvalidMoneyError extends Error {
  constructor(message = 'invalid money value') {
    super(message);
    this.name = 'InvalidMoneyError';
  }
}

const MAX_DIGITS = 128;
const MAX_EXPONENT = 128;

/** Python `Decimal('0.30')` — the discount multiplier from service.py. */
const MULTIPLIER = '0.30';

/** Absolute ceiling when no bound is given (costing.py SANITY_MAX). */
export const SANITY_MAX: Money = new Decimal('1000');

interface DecimalTuple {
  /** as_tuple().digits length */
  digits: number;
  /** as_tuple().exponent */
  exponent: number;
  /** adjusted(): exponent of the most significant digit */
  adjusted: number;
}

/**
 * Python `Decimal.as_tuple()` semantics for a decimal.js Decimal.
 * decimal.js normalizes trailing zeros, so this yields the tuple of the
 * canonical form (what Python produces for arithmetic results).
 */
function tupleOfDecimal(value: Decimal): DecimalTuple {
  const digits = value.sd();
  // decimal.js `.e` is the exponent of the most significant digit == Python adjusted().
  const adjusted = value.e;
  return { digits, exponent: adjusted - digits + 1, adjusted };
}

/**
 * Python Decimal string grammar: optional sign, digits with optional fraction
 * and exponent, at least one digit. CPython strips surrounding whitespace and
 * ALL underscores unconditionally (Decimal('_1') == 1); we mirror that, then
 * derive the tuple as CPython does: leading zeros stripped, trailing zeros
 * kept, zero keeps its literal exponent.
 */
function parseTuple(raw: string): DecimalTuple | null {
  const s = raw.trim().replace(/_/g, '');
  if (s === '') return null;
  let i = 0;
  if (s[i] === '+' || s[i] === '-') i += 1;

  let intPart = '';
  while (i < s.length && s[i] >= '0' && s[i] <= '9') intPart += s[i++];
  let fracPart = '';
  if (s[i] === '.') {
    i += 1;
    while (i < s.length && s[i] >= '0' && s[i] <= '9') fracPart += s[i++];
  }
  if (intPart.length + fracPart.length === 0) return null;

  let expDigits = '';
  let expSign = 1;
  if (i < s.length) {
    if (s[i] !== 'e' && s[i] !== 'E') return null;
    i += 1;
    if (s[i] === '+' || s[i] === '-') {
      if (s[i] === '-') expSign = -1;
      i += 1;
    }
    const start = i;
    while (i < s.length && s[i] >= '0' && s[i] <= '9') expDigits += s[i++];
    if (i === start || i < s.length) return null; // '5e', '5e+', trailing garbage
  }
  const expValue = expSign * (expDigits === '' ? 0 : Number(expDigits));

  const coefficient = (intPart + fracPart).replace(/^0+/, '');
  if (coefficient === '') {
    // Zero: Python keeps the literal exponent ('0.00' -> digits (0,), exponent -2).
    const exponent = expValue - fracPart.length;
    return { digits: 1, exponent, adjusted: exponent };
  }
  const exponent = expValue - fracPart.length;
  const digits = coefficient.length; // trailing zeros kept, as in Python's tuple
  return { digits, exponent, adjusted: exponent + digits - 1 };
}

/** service.py money() bounds: <=128 digits, exponent within ±128, adjusted <= 128. */
function assertWithinBounds(tuple: DecimalTuple): void {
  if (
    tuple.digits > MAX_DIGITS ||
    tuple.exponent > MAX_EXPONENT ||
    tuple.exponent < -MAX_EXPONENT ||
    tuple.adjusted > MAX_EXPONENT
  ) {
    throw new InvalidMoneyError(
      `money out of bounds: digits=${tuple.digits} exponent=${tuple.exponent} adjusted=${tuple.adjusted}`,
    );
  }
}

/**
 * Port of service.py money(): parse exactly, reject non-finite / negative /
 * bool / oversized input. JS numbers are accepted via the exact String(value)
 * conversion pin (money(0.1) is the decimal 0.1); strings and Decimals are
 * parsed/bounded exactly.
 */
export function money(value: string | number | Decimal): Money {
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new InvalidMoneyError('non-finite number');
    if (value < 0) throw new InvalidMoneyError('negative money');
    const tuple = parseTuple(String(value));
    if (tuple === null) throw new InvalidMoneyError(`unparseable: ${String(value)}`);
    assertWithinBounds(tuple);
    return new Decimal(String(value));
  }
  if (typeof value === 'string') {
    const tuple = parseTuple(value);
    if (tuple === null) throw new InvalidMoneyError(`unparseable: ${JSON.stringify(value)}`);
    assertWithinBounds(tuple);
    const cleaned = value.trim().replace(/_/g, '');
    let out: Decimal;
    try {
      out = new Decimal(cleaned);
    } catch {
      throw new InvalidMoneyError(`unparseable: ${JSON.stringify(value)}`);
    }
    if (!out.isFinite() || (out.isNeg() && !out.isZero())) {
      throw new InvalidMoneyError(`not finite/non-negative: ${JSON.stringify(value)}`);
    }
    return out;
  }
  if (value instanceof Decimal) {
    if (!value.isFinite()) throw new InvalidMoneyError('non-finite Decimal');
    if (value.isNeg() && !value.isZero()) throw new InvalidMoneyError('negative money');
    assertWithinBounds(tupleOfDecimal(value));
    return value;
  }
  throw new InvalidMoneyError(`unsupported type: ${typeof value}`);
}

/**
 * Port of service.py discounted(): value × Decimal('0.30') under a local
 * context of prec = digits(value) + 2 with ROUND_HALF_EVEN. An n-digit value
 * times 0.30 has at most n + 2 digits, so the multiplication never rounds —
 * Python's precision rule exists precisely to guarantee that.
 */
export function discounted(value: Money): Money {
  const m = money(value);
  const digits = m.sd();
  const Ctx = Decimal.clone({ precision: digits + 2, rounding: Decimal.ROUND_HALF_EVEN });
  return Ctx(m.toString()).times(MULTIPLIER);
}

/**
 * Port of service.py exact_sum(): sum under
 * prec = max(adjusted) - min(exponent) + len(str(n)) + 2 — enough significant
 * digits that the sum is always exact (the float-poisoning canary
 * exactSum([0.1, 0.2]) === "0.3" must hold).
 */
export function exactSum(values: Money[]): Money {
  if (values.length === 0) return new Decimal(0);
  let maxAdjusted = -Infinity;
  let minExponent = Infinity;
  for (const value of values) {
    const tuple = tupleOfDecimal(value);
    if (tuple.adjusted > maxAdjusted) maxAdjusted = tuple.adjusted;
    if (tuple.exponent < minExponent) minExponent = tuple.exponent;
  }
  const precision = maxAdjusted - minExponent + String(values.length).length + 2;
  const Ctx = Decimal.clone({ precision, rounding: Decimal.ROUND_HALF_EVEN });
  let acc = new Ctx(0);
  for (const value of values) acc = acc.plus(Ctx(value.toString()));
  return acc;
}

/**
 * Port of costing.py _dec(): untrusted scalar -> finite non-negative Money, else null.
 * Accepts number/string/Decimal; rejects bool, null, undefined, arrays, objects.
 */
function dec(value: unknown): Money | null {
  let candidate: string | number | Decimal;
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return null;
    candidate = value;
  } else if (typeof value === 'string') {
    candidate = value.trim(); // costing.py _dec: str(value).strip()
  } else if (value instanceof Decimal) {
    candidate = value;
  } else {
    return null;
  }
  try {
    return money(candidate);
  } catch {
    return null;
  }
}

/**
 * Port of costing.py positive_cost(): positive finite money capped at `bound`
 * (or rejected above SANITY_MAX when no bound is given), else null.
 */
export function positiveCost(value: unknown, bound?: Money | null): Money | null {
  const out = dec(value);
  if (out === null || out.isZero()) return null; // out >= 0 by construction, so <= 0 means zero
  if (bound === null || bound === undefined) {
    return out.lessThanOrEqualTo(SANITY_MAX) ? out : null;
  }
  return Decimal.min(out, bound);
}
