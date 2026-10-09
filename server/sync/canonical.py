"""RFC 8785 JSON Canonicalization Scheme (JCS) and a strict JSON decoder.

``canonical_bytes`` is the only serializer used for hashing, storage, quota
accounting and replay. It is deliberately *not* ``json.dumps(sort_keys=True)``:
object keys are ordered by UTF-16 code units and numbers use the ECMAScript
shortest round-trip form required by RFC 8785 section 3.2.2.3.
"""

from __future__ import annotations

import json
import math

from server.sync.errors import SyncError

MAX_DEPTH = 64
# Integers outside the IEEE-754 exactly-representable range cannot round-trip
# through an I-JSON consumer, so they are refused rather than silently rounded.
MAX_SAFE_INTEGER = 2**53

_SHORT_ESCAPES = {
    0x08: "\\b",
    0x09: "\\t",
    0x0A: "\\n",
    0x0C: "\\f",
    0x0D: "\\r",
    0x22: '\\"',
    0x5C: "\\\\",
}


class CanonicalizationError(ValueError):
    """Value cannot be represented under RFC 8785. Carries no input data."""

    def __init__(self, reason: str):
        super().__init__(reason)


def canonical_bytes(value: object) -> bytes:
    """Serialize ``value`` as RFC 8785 canonical JSON, encoded as UTF-8."""
    parts: list[str] = []
    _encode(value, parts, 0)
    return "".join(parts).encode("utf-8")


def _encode(value: object, out: list, depth: int) -> None:
    if depth > MAX_DEPTH:
        raise CanonicalizationError("nesting too deep")
    kind = type(value)
    if value is None:
        out.append("null")
    elif value is True:
        out.append("true")
    elif value is False:
        out.append("false")
    elif kind is int:
        if not -MAX_SAFE_INTEGER <= value <= MAX_SAFE_INTEGER:
            raise CanonicalizationError("integer outside exact IEEE-754 range")
        out.append(str(value))
    elif kind is float:
        out.append(_number(value))
    elif kind is str:
        out.append(_string(value))
    elif kind is list:
        out.append("[")
        for index, item in enumerate(value):
            if index:
                out.append(",")
            _encode(item, out, depth + 1)
        out.append("]")
    elif kind is dict:
        for key in value:
            if type(key) is not str:
                raise CanonicalizationError("object keys must be strings")
        out.append("{")
        for index, key in enumerate(sorted(value, key=_utf16_key)):
            if index:
                out.append(",")
            out.append(_string(key))
            out.append(":")
            _encode(value[key], out, depth + 1)
        out.append("}")
    else:
        raise CanonicalizationError("unsupported type")


def _utf16_key(key: str) -> bytes:
    # Big-endian UTF-16 bytes compare exactly like UTF-16 code-unit sequences.
    try:
        return key.encode("utf-16-be")
    except UnicodeEncodeError:
        raise CanonicalizationError("lone surrogate") from None


def _string(value: str) -> str:
    out = ['"']
    for char in value:
        code = ord(char)
        if 0xD800 <= code <= 0xDFFF:
            # Python strs never hold valid pairs as two code points legitimately;
            # any surrogate code point is unpaired from Unicode's perspective.
            raise CanonicalizationError("lone surrogate")
        escape = _SHORT_ESCAPES.get(code)
        if escape is not None:
            out.append(escape)
        elif code < 0x20:
            out.append("\\u%04x" % code)
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def _number(value: float) -> str:
    """ECMAScript Number::toString for finite doubles (RFC 8785 3.2.2.3)."""
    if not math.isfinite(value):
        raise CanonicalizationError("non-finite number")
    if value == 0:
        return "0"  # covers -0.0
    sign = "-" if value < 0 else ""
    # repr() yields the shortest digit string that round-trips (same as ES).
    mantissa, _, exponent = repr(abs(value)).partition("e")
    whole, _, fraction = mantissa.partition(".")
    raw = whole + fraction
    stripped = raw.lstrip("0")
    # value == 0.<digits> * 10**n, with digits having no leading/trailing zeros.
    n = len(whole) + (int(exponent) if exponent else 0) - (len(raw) - len(stripped))
    digits = stripped.rstrip("0")
    k = len(digits)
    if k <= n <= 21:
        body = digits + "0" * (n - k)
    elif 0 < n <= 21:
        body = digits[:n] + "." + digits[n:]
    elif -6 < n <= 0:
        body = "0." + "0" * (-n) + digits
    else:
        e = n - 1
        exp = ("+" if e >= 0 else "-") + str(abs(e))
        body = digits + "e" + exp if k == 1 else digits[0] + "." + digits[1:] + "e" + exp
    return sign + body


# --------------------------------------------------------------------------
# Strict decoder


class _Invalid(Exception):
    pass


def _reject_constant(_name):
    raise _Invalid()


def _parse_float(text):
    number = float(text)
    if not math.isfinite(number):
        raise _Invalid()
    return number


def _parse_int(text):
    # Bound the digit count before int() (doubles never exceed 309 digits).
    if len(text.lstrip("-")) > 309:
        raise _Invalid()
    number = int(text)
    if -MAX_SAFE_INTEGER <= number <= MAX_SAFE_INTEGER:
        return number
    # JSON numbers are IEEE-754 doubles: accept a large integer literal only if
    # it is exactly a double (e.g. JCS output "100000000000000000000"), and
    # surface it as float so DTO integer fields still reject it.
    try:
        as_float = float(number)
    except OverflowError:
        raise _Invalid() from None
    if int(as_float) != number:
        raise _Invalid()
    return as_float


def _pairs(pairs):
    result = {}
    for key, item in pairs:
        if key in result:
            raise _Invalid()
        result[key] = item
    return result


def decode_strict(data: object) -> object:
    """Decode UTF-8 JSON, rejecting duplicate keys, NaN/Infinity, lone
    surrogates, BOMs, huge integers, deep nesting and trailing data.

    Every failure is ``SyncError('invalid_request')`` with no input echo.
    """
    try:
        if type(data) in (bytes, bytearray):
            text = bytes(data).decode("utf-8", errors="strict")
        elif type(data) is str:
            text = data
        else:
            raise _Invalid()
        if text.startswith("\ufeff"):
            raise _Invalid()
        value = json.loads(
            text,
            object_pairs_hook=_pairs,
            parse_constant=_reject_constant,
            parse_float=_parse_float,
            parse_int=_parse_int,
        )
        _check_tree(value)
    except (_Invalid, ValueError, RecursionError, UnicodeDecodeError):
        raise SyncError("invalid_request") from None
    return value


def _check_tree(value: object) -> None:
    stack = [(value, 0)]
    while stack:
        item, depth = stack.pop()
        if depth > MAX_DEPTH:
            raise _Invalid()
        if type(item) is str:
            _check_scalar_string(item)
        elif type(item) is list:
            stack.extend((child, depth + 1) for child in item)
        elif type(item) is dict:
            for key, child in item.items():
                _check_scalar_string(key)
                stack.append((child, depth + 1))


def _check_scalar_string(text: str) -> None:
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        raise _Invalid() from None
