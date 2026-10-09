/// RFC 8785 JSON Canonicalization Scheme (JCS) for private account sync.
///
/// This is the only serializer used for sync hashing, quota accounting,
/// storage and replay. `jsonEncode` is intentionally not used: it neither sorts
/// keys nor follows the ECMAScript number and string rules required by JCS.
///
/// The module is pure data code. It must not import Flutter UI, HTTP, app
/// state, or anything executable.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

/// Largest integer magnitude accepted as a Dart `int` (2^53 - 1).
const int maxSafeInteger = 9007199254740991;

/// Maximum array/object nesting accepted by the encoder and decoder.
const int maxCanonicalDepth = 128;

/// Rejection raised by the canonical encoder or strict decoder.
///
/// Messages are fixed strings; input text is never echoed so that private
/// transcript content cannot leak through error paths.
class CanonicalJsonException extends FormatException {
  const CanonicalJsonException(super.message);

  @override
  String toString() => 'CanonicalJsonException: $message';
}

/// Returns the RFC 8785 canonical UTF-8 bytes for [value].
///
/// Accepted values: `null`, `bool`, `int` within ±(2^53 - 1), finite
/// `double`, `String` without lone surrogates, `List`, and `Map` with `String`
/// keys.
Uint8List canonicalSyncBytes(Object? value) =>
    Uint8List.fromList(utf8.encode(canonicalJsonString(value)));

/// Returns the RFC 8785 canonical text for [value]. See [canonicalSyncBytes].
String canonicalJsonString(Object? value) {
  final out = StringBuffer();
  _encode(value, out, 0);
  return out.toString();
}

void _encode(Object? value, StringBuffer out, int depth) {
  if (value == null) {
    out.write('null');
  } else if (value is bool) {
    out.write(value ? 'true' : 'false');
  } else if (value is int) {
    if (value > maxSafeInteger || value < -maxSafeInteger) {
      throw const CanonicalJsonException('integer outside the safe range');
    }
    out.write(value.toString());
  } else if (value is double) {
    out.write(formatEcmaScriptNumber(value));
  } else if (value is String) {
    _encodeString(value, out);
  } else if (value is List) {
    if (depth >= maxCanonicalDepth) {
      throw const CanonicalJsonException('nesting too deep');
    }
    out.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) out.write(',');
      _encode(value[i], out, depth + 1);
    }
    out.write(']');
  } else if (value is Map) {
    if (depth >= maxCanonicalDepth) {
      throw const CanonicalJsonException('nesting too deep');
    }
    final keys = <String>[];
    for (final key in value.keys) {
      if (key is! String) {
        throw const CanonicalJsonException('object key is not a string');
      }
      keys.add(key);
    }
    // Dart String.compareTo orders by UTF-16 code units, which is exactly the
    // RFC 8785 property sort rule.
    keys.sort();
    out.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) out.write(',');
      _encodeString(keys[i], out);
      out.write(':');
      _encode(value[keys[i]], out, depth + 1);
    }
    out.write('}');
  } else {
    throw const CanonicalJsonException('unsupported value type');
  }
}

const _hex = '0123456789abcdef';

void _encodeString(String value, StringBuffer out) {
  out.writeCharCode(0x22);
  final length = value.length;
  for (var i = 0; i < length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (i + 1 >= length) {
        throw const CanonicalJsonException('lone surrogate');
      }
      final next = value.codeUnitAt(i + 1);
      if (next < 0xDC00 || next > 0xDFFF) {
        throw const CanonicalJsonException('lone surrogate');
      }
      out.writeCharCode(unit);
      out.writeCharCode(next);
      i++;
      continue;
    }
    if (unit >= 0xDC00 && unit <= 0xDFFF) {
      throw const CanonicalJsonException('lone surrogate');
    }
    switch (unit) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x08:
        out.write(r'\b');
      case 0x0C:
        out.write(r'\f');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        if (unit < 0x20) {
          out
            ..write(r'\u00')
            ..write(_hex[unit >> 4])
            ..write(_hex[unit & 0xF]);
        } else {
          out.writeCharCode(unit);
        }
    }
  }
  out.writeCharCode(0x22);
}

/// Formats [value] as ECMAScript `Number.prototype.toString` (ES2019 7.1.12.1)
/// would, which is the RFC 8785 number serialization.
///
/// Dart's `double.toString` already yields the shortest round-trip digit
/// sequence; only the layout differs from ECMAScript, so the digits and
/// decimal exponent are extracted and re-laid out here.
String formatEcmaScriptNumber(double value) {
  if (value.isNaN || value.isInfinite) {
    throw const CanonicalJsonException('non-finite number');
  }
  if (value == 0) return '0';
  final negative = value < 0;
  var text = (negative ? -value : value).toString();

  var exponent = 0;
  final e = text.indexOf('e');
  if (e >= 0) {
    exponent = int.parse(text.substring(e + 1));
    text = text.substring(0, e);
  }
  final dot = text.indexOf('.');
  String digits;
  int pointPosition; // n in the ECMAScript algorithm, before trimming.
  if (dot >= 0) {
    digits = text.substring(0, dot) + text.substring(dot + 1);
    pointPosition = dot + exponent;
  } else {
    digits = text;
    pointPosition = text.length + exponent;
  }
  // Trim leading zeros (adjusting the point) and trailing zeros.
  var start = 0;
  while (start < digits.length - 1 && digits.codeUnitAt(start) == 0x30) {
    start++;
  }
  digits = digits.substring(start);
  pointPosition -= start;
  var end = digits.length;
  while (end > 1 && digits.codeUnitAt(end - 1) == 0x30) {
    end--;
  }
  digits = digits.substring(0, end);

  final k = digits.length;
  final n = pointPosition;
  final buffer = StringBuffer();
  if (negative) buffer.write('-');
  if (k <= n && n <= 21) {
    buffer
      ..write(digits)
      ..write('0' * (n - k));
  } else if (0 < n && n <= 21) {
    buffer
      ..write(digits.substring(0, n))
      ..write('.')
      ..write(digits.substring(n));
  } else if (-6 < n && n <= 0) {
    buffer
      ..write('0.')
      ..write('0' * -n)
      ..write(digits);
  } else {
    final exp = n - 1;
    buffer.write(digits[0]);
    if (k > 1) {
      buffer
        ..write('.')
        ..write(digits.substring(1));
    }
    buffer
      ..write('e')
      ..write(exp >= 0 ? '+' : '-')
      ..write(exp.abs());
  }
  return buffer.toString();
}

/// Strictly decodes UTF-8 JSON [bytes]. Rejects malformed UTF-8, a byte order
/// mark, and everything [decodeStrictJson] rejects.
Object? decodeStrictJsonUtf8(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    throw const CanonicalJsonException('byte order mark');
  }
  String text;
  try {
    text = const Utf8Decoder(allowMalformed: false).convert(bytes);
  } on FormatException {
    throw const CanonicalJsonException('malformed UTF-8');
  }
  return decodeStrictJson(text);
}

/// Strictly decodes RFC 8259 JSON [text].
///
/// Unlike `jsonDecode`, this rejects duplicate object keys (compared after
/// unescaping), lone surrogates (raw or escaped), integers that cannot be
/// represented exactly as an IEEE-754 number, numbers that overflow to
/// infinity, a leading byte order mark, and nesting deeper than
/// [maxCanonicalDepth]. Integers without fraction or exponent decode as `int`
/// when within the safe integer range, or as an exact `double` when they are
/// outside that range; other numbers decode as `double`. Returned maps and
/// lists are unmodifiable; maps keep source key order.
Object? decodeStrictJson(String text) => _StrictParser(text).parseDocument();

class _StrictParser {
  _StrictParser(this._text);

  final String _text;
  int _pos = 0;

  Never _fail(String message) => throw CanonicalJsonException(message);

  Object? parseDocument() {
    _skipWhitespace();
    final value = _parseValue(0);
    _skipWhitespace();
    if (_pos != _text.length) _fail('trailing content');
    return value;
  }

  void _skipWhitespace() {
    while (_pos < _text.length) {
      final c = _text.codeUnitAt(_pos);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        _pos++;
      } else {
        break;
      }
    }
  }

  int _peek() {
    if (_pos >= _text.length) _fail('unexpected end of input');
    return _text.codeUnitAt(_pos);
  }

  Object? _parseValue(int depth) {
    final c = _peek();
    switch (c) {
      case 0x7B: // {
        return _parseObject(depth);
      case 0x5B: // [
        return _parseArray(depth);
      case 0x22: // "
        return _parseString();
      case 0x74: // t
        _expectLiteral('true');
        return true;
      case 0x66: // f
        _expectLiteral('false');
        return false;
      case 0x6E: // n
        _expectLiteral('null');
        return null;
      default:
        if (c == 0x2D || (c >= 0x30 && c <= 0x39)) return _parseNumber();
        _fail('unexpected character');
    }
  }

  void _expectLiteral(String literal) {
    if (!_text.startsWith(literal, _pos)) _fail('invalid literal');
    _pos += literal.length;
  }

  Map<String, Object?> _parseObject(int depth) {
    if (depth >= maxCanonicalDepth) _fail('nesting too deep');
    _pos++; // {
    final result = <String, Object?>{};
    _skipWhitespace();
    if (_peek() == 0x7D) {
      _pos++;
      return UnmodifiableMapView(result);
    }
    while (true) {
      _skipWhitespace();
      if (_peek() != 0x22) _fail('expected object key');
      final key = _parseString();
      if (result.containsKey(key)) _fail('duplicate object key');
      _skipWhitespace();
      if (_peek() != 0x3A) _fail('expected colon');
      _pos++;
      _skipWhitespace();
      result[key] = _parseValue(depth + 1);
      _skipWhitespace();
      final c = _peek();
      _pos++;
      if (c == 0x2C) continue;
      if (c == 0x7D) break;
      _fail('expected comma or closing brace');
    }
    return UnmodifiableMapView(result);
  }

  List<Object?> _parseArray(int depth) {
    if (depth >= maxCanonicalDepth) _fail('nesting too deep');
    _pos++; // [
    final result = <Object?>[];
    _skipWhitespace();
    if (_peek() == 0x5D) {
      _pos++;
      return List.unmodifiable(result);
    }
    while (true) {
      _skipWhitespace();
      result.add(_parseValue(depth + 1));
      _skipWhitespace();
      final c = _peek();
      _pos++;
      if (c == 0x2C) continue;
      if (c == 0x5D) break;
      _fail('expected comma or closing bracket');
    }
    return List.unmodifiable(result);
  }

  String _parseString() {
    _pos++; // opening quote
    final out = StringBuffer();
    while (true) {
      final c = _peek();
      _pos++;
      if (c == 0x22) break;
      if (c < 0x20) _fail('control character in string');
      if (c == 0x5C) {
        final e = _peek();
        _pos++;
        switch (e) {
          case 0x22:
            out.writeCharCode(0x22);
          case 0x5C:
            out.writeCharCode(0x5C);
          case 0x2F:
            out.writeCharCode(0x2F);
          case 0x62:
            out.writeCharCode(0x08);
          case 0x66:
            out.writeCharCode(0x0C);
          case 0x6E:
            out.writeCharCode(0x0A);
          case 0x72:
            out.writeCharCode(0x0D);
          case 0x74:
            out.writeCharCode(0x09);
          case 0x75:
            out.writeCharCode(_readHex4());
          default:
            _fail('invalid escape');
        }
      } else {
        out.writeCharCode(c);
      }
    }
    final value = out.toString();
    _checkSurrogates(value);
    return value;
  }

  int _readHex4() {
    if (_pos + 4 > _text.length) _fail('truncated unicode escape');
    var result = 0;
    for (var i = 0; i < 4; i++) {
      final c = _text.codeUnitAt(_pos + i);
      int digit;
      if (c >= 0x30 && c <= 0x39) {
        digit = c - 0x30;
      } else if (c >= 0x41 && c <= 0x46) {
        digit = c - 0x41 + 10;
      } else if (c >= 0x61 && c <= 0x66) {
        digit = c - 0x61 + 10;
      } else {
        _fail('invalid unicode escape');
      }
      result = (result << 4) | digit;
    }
    _pos += 4;
    return result;
  }

  void _checkSurrogates(String value) {
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (i + 1 < value.length) {
          final next = value.codeUnitAt(i + 1);
          if (next >= 0xDC00 && next <= 0xDFFF) {
            i++;
            continue;
          }
        }
        _fail('lone surrogate');
      }
      if (unit >= 0xDC00 && unit <= 0xDFFF) _fail('lone surrogate');
    }
  }

  bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  Object _parseNumber() {
    final start = _pos;
    var isInteger = true;
    if (_text.codeUnitAt(_pos) == 0x2D) _pos++;
    if (_pos >= _text.length) _fail('invalid number');
    final first = _text.codeUnitAt(_pos);
    if (first == 0x30) {
      _pos++;
    } else if (_isDigit(first)) {
      while (_pos < _text.length && _isDigit(_text.codeUnitAt(_pos))) {
        _pos++;
      }
    } else {
      _fail('invalid number');
    }
    if (_pos < _text.length && _text.codeUnitAt(_pos) == 0x2E) {
      isInteger = false;
      _pos++;
      if (_pos >= _text.length || !_isDigit(_text.codeUnitAt(_pos))) {
        _fail('invalid number');
      }
      while (_pos < _text.length && _isDigit(_text.codeUnitAt(_pos))) {
        _pos++;
      }
    }
    if (_pos < _text.length &&
        (_text.codeUnitAt(_pos) == 0x65 || _text.codeUnitAt(_pos) == 0x45)) {
      isInteger = false;
      _pos++;
      if (_pos < _text.length &&
          (_text.codeUnitAt(_pos) == 0x2B || _text.codeUnitAt(_pos) == 0x2D)) {
        _pos++;
      }
      if (_pos >= _text.length || !_isDigit(_text.codeUnitAt(_pos))) {
        _fail('invalid number');
      }
      while (_pos < _text.length && _isDigit(_text.codeUnitAt(_pos))) {
        _pos++;
      }
    }
    final literal = _text.substring(start, _pos);
    if (isInteger) {
      final parsed = int.tryParse(literal);
      if (parsed != null &&
          parsed <= maxSafeInteger &&
          parsed >= -maxSafeInteger) {
        return parsed;
      }
      final asDouble = double.tryParse(literal);
      if (asDouble == null ||
          asDouble.isInfinite ||
          asDouble.isNaN ||
          BigInt.from(asDouble) != BigInt.parse(literal)) {
        _fail('integer outside the safe range');
      }
      return asDouble;
    }
    final parsed = double.parse(literal);
    if (parsed.isInfinite || parsed.isNaN) _fail('number out of range');
    return parsed;
  }
}
