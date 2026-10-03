import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugins/dev_utilities.dart';

void main() {
  final converter = FileConverterCapability();
  Future<dynamic> parse(String csv) async => jsonDecode(
        await converter.callTool('csv_to_json', {'csv_text': csv}),
      );

  test('CSV preserves multiline fields, escaped quotes and CRLF verbatim', () async {
    expect(await parse('name,note\r\nAda,"one\r\n\r\ntwo, ""three"""\r\n'), [
      {'name': 'Ada', 'note': 'one\r\n\r\ntwo, "three"'},
    ]);
  });

  test('CSV string-object roundtrip preserves headers and empty final records', () async {
    final corpus = [
      [
        {' key ': ' leading and trailing ', 'multi\nline': 'a\nb\rc\r\nd', 'q"': '雪,☃'},
        {' key ': '', 'multi\nline': '"quoted"', 'q"': ''},
      ],
      [
        {'value': 'first'},
        {'value': ''},
        {'value': ''},
      ],
    ];
    for (final rows in corpus) {
      final csv = await converter.callTool('json_to_csv', {'json_text': jsonEncode(rows)});
      expect(await parse(csv), rows);
    }
  });

  test('CSV accepts CR record separators and preserves blank one-column records', () async {
    expect(await parse('value\rfirst\r\r""\r'), [
      {'value': 'first'},
      {'value': ''},
      {'value': ''},
    ]);
  });

  for (final fixture in <String, String>{
    'duplicate header': 'a,a\nx,y',
    'empty header': 'a,\nx,y',
    'whitespace header': 'a,  \nx,y',
    'short row': 'a,b\nx',
    'long row': 'a,b\nx,y,z',
    'quote inside unquoted field': 'a\nab"cd"',
    'text after closing quote': 'a\n"x"junk',
    'space after closing quote': 'a\n"x" ',
    'unterminated multiline quote': 'a\n"x\ny',
  }.entries) {
    test('CSV rejects ${fixture.key} with a format error', () async {
      await expectLater(parse(fixture.value), throwsA(isA<FormatException>()));
    });
  }

  for (final json in ['[{"":1}]', '[{"  ":1}]', '[{}]']) {
    test('JSON to CSV rejects unrepresentable headers in $json', () async {
      await expectLater(
        converter.callTool('json_to_csv', {'json_text': json}),
        throwsA(isA<FormatException>()),
      );
    });
  }

  test('CSV header-only input and trailing delimiters retain their meaning', () async {
    expect(await parse('a,b\r\n'), isEmpty);
    expect(await parse('a,b\r\nx,\r\n'), [{'a': 'x', 'b': ''}]);
  });
}
