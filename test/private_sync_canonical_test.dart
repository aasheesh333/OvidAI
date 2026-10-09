import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/canonical.dart';

double _bits(int hi, int lo) {
  final data = ByteData(8)
    ..setUint32(0, hi)
    ..setUint32(4, lo);
  return data.getFloat64(0);
}

String _c(Object? value) => canonicalJsonString(value);

void main() {
  group('RFC 8785 published examples', () {
    test('section 3.2.2 sample (numbers, strings, literals)', () {
      // Parsed with the strict decoder so the original number spellings are
      // exercised exactly as published.
      const input = r'''
{
  "numbers": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001],
  "string": "\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\"\/",
  "literals": [null, true, false]
}''';
      final value = decodeStrictJson(input);
      expect(
        _c(value),
        r'{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'
        "'"
        r'B\"\\\\\"/"}',
      );
      expect(
        canonicalSyncBytes(value),
        utf8.encode(
          r'{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'
          "'"
          r'B\"\\\\\"/"}',
        ),
      );
    });

    test('section 3.2.3 property sorting by UTF-16 code units', () {
      const input = r'''
{
  "\u20ac": "Euro Sign",
  "\r": "Carriage Return",
  "\ufb33": "Hebrew Letter Dalet With Dagesh",
  "1": "One",
  "\ud83d\ude00": "Emoji: Grinning Face",
  "\u0080": "Control",
  "\u00f6": "Latin Small Letter O With Diaeresis"
}''';
      expect(
        _c(decodeStrictJson(input)),
        '{"\\r":"Carriage Return","1":"One","\u0080":"Control",'
        '"\u00f6":"Latin Small Letter O With Diaeresis","\u20ac":"Euro Sign",'
        '"\u{1F600}":"Emoji: Grinning Face",'
        '"\ufb33":"Hebrew Letter Dalet With Dagesh"}',
      );
    });

    test('non-BMP key sorts before U+FB33 (UTF-16, not code point order)', () {
      // Code-point order would put U+FB33 before U+1F600.
      expect(_c({'\ufb33': 1, '\u{1F600}': 2}), '{"\u{1F600}":2,"\ufb33":1}');
    });

    test('appendix B number serialization table', () {
      final table = <List<Object>>[
        [0x00000000, 0x00000000, '0'],
        [0x80000000, 0x00000000, '0'],
        [0x00000000, 0x00000001, '5e-324'],
        [0x80000000, 0x00000001, '-5e-324'],
        [0x7fefffff, 0xffffffff, '1.7976931348623157e+308'],
        [0xffefffff, 0xffffffff, '-1.7976931348623157e+308'],
        [0x43400000, 0x00000000, '9007199254740992'],
        [0xc3400000, 0x00000000, '-9007199254740992'],
        [0x44300000, 0x00000000, '295147905179352830000'],
        [0x44b52d02, 0xc7e14af5, '9.999999999999997e+22'],
        [0x44b52d02, 0xc7e14af6, '1e+23'],
        [0x44b52d02, 0xc7e14af7, '1.0000000000000001e+23'],
        [0x444b1ae4, 0xd6e2ef4e, '999999999999999700000'],
        [0x444b1ae4, 0xd6e2ef4f, '999999999999999900000'],
        [0x444b1ae4, 0xd6e2ef50, '1e+21'],
        [0x3eb0c6f7, 0xa0b5ed8c, '9.999999999999997e-7'],
        [0x3eb0c6f7, 0xa0b5ed8d, '0.000001'],
        [0x41b3de43, 0x55555553, '333333333.3333332'],
        [0x41b3de43, 0x55555554, '333333333.33333325'],
        [0x41b3de43, 0x55555555, '333333333.3333333'],
        [0x41b3de43, 0x55555556, '333333333.3333334'],
        [0x41b3de43, 0x55555557, '333333333.33333343'],
        [0xbecbf647, 0x612f3696, '-0.0000033333333333333333'],
        [0x43143ff3, 0xc1cb0959, '1424953923781206.2'],
      ];
      for (final row in table) {
        final value = _bits(row[0] as int, row[1] as int);
        expect(_c(value), row[2], reason: 'bits ${row[0]}:${row[1]}');
      }
    });

    test('NaN and Infinity are rejected', () {
      expect(() => _c(_bits(0x7fffffff, 0xffffffff)),
          throwsA(isA<CanonicalJsonException>()));
      expect(() => _c(double.infinity), throwsA(isA<CanonicalJsonException>()));
      expect(() => _c(double.negativeInfinity),
          throwsA(isA<CanonicalJsonException>()));
      expect(() => _c([double.nan]), throwsA(isA<CanonicalJsonException>()));
    });
  });

  group('encoder', () {
    test('no whitespace and nested sorting', () {
      expect(
        _c({
          'b': [1, {'z': null, 'a': true}],
          'a': 'x',
        }),
        '{"a":"x","b":[1,{"a":true,"z":null}]}',
      );
    });

    test('integers within the safe range and integral doubles', () {
      expect(_c(0), '0');
      expect(_c(-0.0), '0');
      expect(_c(4.0), '4');
      expect(_c(9007199254740991), '9007199254740991');
      expect(_c(-9007199254740991), '-9007199254740991');
      expect(_c(4294967295), '4294967295');
      expect(_c(1e21), '1e+21');
      expect(_c(1e20), '100000000000000000000');
      expect(_c(0.1), '0.1');
      expect(_c(1e-7), '1e-7');
      expect(_c(123e-8), '0.00000123');
    });

    test('integers beyond 2^53 - 1 are rejected', () {
      expect(() => _c(9007199254740992), throwsA(isA<CanonicalJsonException>()));
      expect(
          () => _c(-9007199254740992), throwsA(isA<CanonicalJsonException>()));
      expect(() => _c(1 << 62), throwsA(isA<CanonicalJsonException>()));
    });

    test('string escaping follows RFC 8785', () {
      expect(_c('"\\/\b\f\n\r\t'), r'"\"\\/\b\f\n\r\t"');
      expect(_c('\u0000\u0001\u001f'), r'"\u0000\u0001\u001f"');
      // DEL, U+2028 and non-ASCII are emitted literally.
      expect(_c('\u007f\u2028\u00e9\u{1F600}'), '"\u007f\u2028\u00e9\u{1F600}"');
    });

    test('lone surrogates are rejected in values and keys', () {
      expect(() => _c('a\ud800b'), throwsA(isA<CanonicalJsonException>()));
      expect(() => _c('\udc00'), throwsA(isA<CanonicalJsonException>()));
      expect(() => _c('x\ud83d'), throwsA(isA<CanonicalJsonException>()));
      expect(() => _c({'\ud800': 1}), throwsA(isA<CanonicalJsonException>()));
      expect(_c('\ud83d\ude00'), '"\u{1F600}"');
    });

    test('unsupported values and non-string keys are rejected', () {
      expect(() => _c(DateTime(2026)), throwsA(isA<CanonicalJsonException>()));
      expect(() => _c({1: 'a'}), throwsA(isA<CanonicalJsonException>()));
      expect(() => _c(Object()), throwsA(isA<CanonicalJsonException>()));
    });

    test('bytes are UTF-8 of the canonical string', () {
      final bytes = canonicalSyncBytes({'k': '\u20ac'});
      expect(bytes, isA<Uint8List>());
      expect(bytes, [0x7b, 0x22, 0x6b, 0x22, 0x3a, 0x22, 0xe2, 0x82, 0xac, 0x22, 0x7d]);
    });

    test('does not equal jsonEncode for differing cases', () {
      final value = {'b': 1.0, 'a': '\u2028'};
      expect(_c(value), isNot(jsonEncode(value)));
      expect(_c(value), '{"a":"\u2028","b":1}');
    });
  });

  group('strict decoder', () {
    test('rejects duplicate keys, including escaped duplicates', () {
      expect(() => decodeStrictJson('{"a":1,"a":2}'),
          throwsA(isA<CanonicalJsonException>()));
      expect(() => decodeStrictJson(r'{"a":1,"\u0061":2}'),
          throwsA(isA<CanonicalJsonException>()));
      expect(() => decodeStrictJson('{"x":{"a":1,"a":1}}'),
          throwsA(isA<CanonicalJsonException>()));
    });

    test('parses standard JSON with typed numbers', () {
      final value = decodeStrictJson(
          ' { "i": -12, "d": 1.0, "e": 1e2, "s": "\\ud83d\\ude00", "l": [true, false, null] } ');
      expect(value, {
        'i': -12,
        'd': 1.0,
        'e': 100.0,
        's': '\u{1F600}',
        'l': [true, false, null],
      });
      final map = value as Map<String, Object?>;
      expect(map['i'], isA<int>());
      expect(map['d'], isA<double>());
    });

    test('accepts exact integral doubles emitted in RFC 8785 integer form', () {
      final value = decodeStrictJson('100000000000000000000');
      expect(value, 1e20);
      expect(value, isA<double>());
      expect(_c(value), '100000000000000000000');
      expect(() => decodeStrictJson('9007199254740993'),
          throwsA(isA<CanonicalJsonException>()));
    });

    test('rejects malformed input', () {
      const bad = <String>[
        '',
        '{',
        '{"a":1,}',
        '[1,]',
        '01',
        '1.',
        '.5',
        '+1',
        '-',
        '1e',
        'NaN',
        'Infinity',
        '1e400',
        "{'a':1}",
        '{"a" 1}',
        '"abc',
        '"\t"',
        r'"\x"',
        r'"\u12"',
        r'"\ud800"',
        r'"\udc00\ud800"',
        r'"\ud800x"',
        'true false',
        '[1] x',
        'tru',
        '{"a":1}}',
        '\ufeff{}',
      ];
      for (final text in bad) {
        expect(() => decodeStrictJson(text),
            throwsA(isA<CanonicalJsonException>()),
            reason: 'input: ${jsonEncode(text)}');
      }
    });

    test('rejects raw lone surrogates in the input string', () {
      expect(() => decodeStrictJson('"\ud800"'),
          throwsA(isA<CanonicalJsonException>()));
    });

    test('rejects excessive nesting depth', () {
      final deep = '${'[' * 200}${']' * 200}';
      expect(() => decodeStrictJson(deep), throwsA(isA<CanonicalJsonException>()));
      final ok = '${'[' * 64}${']' * 64}';
      expect(decodeStrictJson(ok), isA<List<Object?>>());
    });

    test('UTF-8 byte decoding is strict', () {
      expect(decodeStrictJsonUtf8(utf8.encode('{"a":"\u20ac"}')), {'a': '\u20ac'});
      expect(() => decodeStrictJsonUtf8([0x22, 0xff, 0x22]),
          throwsA(isA<CanonicalJsonException>()));
      // CESU-8 encoded surrogate U+D800.
      expect(() => decodeStrictJsonUtf8([0x22, 0xed, 0xa0, 0x80, 0x22]),
          throwsA(isA<CanonicalJsonException>()));
      // UTF-8 BOM.
      expect(() => decodeStrictJsonUtf8([0xef, 0xbb, 0xbf, 0x7b, 0x7d]),
          throwsA(isA<CanonicalJsonException>()));
    });

    test('decoded maps are unmodifiable', () {
      final value = decodeStrictJson('{"a":[1]}') as Map<String, Object?>;
      expect(() => value['b'] = 1, throwsUnsupportedError);
      expect(() => (value['a'] as List<Object?>).add(2), throwsUnsupportedError);
    });

    test('decode then encode round-trips canonical text exactly', () {
      const canonical =
          '{"a":[1,2.5,-0.001,1e+30],"b":"\\u0000\\n\u{1F600}","c":{"":null}}';
      expect(_c(decodeStrictJson(canonical)), canonical);
    });
  });
}
