import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/data_utilities.dart';

void main() {
  setUp(() {
    NativePluginRegistry.I.clearForTest();
    registerDataUtilities();
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
  });

  group('registration', () {
    test('all five Part A utilities are registered', () {
      for (final name in [
        'JSON Visualizer',
        'Regex Builder',
        'SQL Formatter',
        'Cron Designer',
        'Color Palette Gen',
      ]) {
        expect(NativePluginRegistry.I.has(name), isTrue, reason: name);
      }
      expect(
        NativePluginRegistry.I.capabilityForSlug('json_visualizer'),
        isA<JsonVisualizerCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('regex_builder'),
        isA<RegexBuilderCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('sql_formatter'),
        isA<SqlFormatterCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('cron_designer'),
        isA<CronDesignerCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('color_palette_gen'),
        isA<ColorPaletteGenCapability>(),
      );
    });

    test('unknown tool names throw ArgumentError', () async {
      final json = NativePluginRegistry.I.capabilityFor('JSON Visualizer')!;
      await expectLater(
        json.callTool('nope', {}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('JSON Visualizer', () {
    late NativePluginCapability json;

    setUp(() {
      json = NativePluginRegistry.I.capabilityFor('JSON Visualizer')!;
    });

    test('format pretty-prints JSON', () async {
      final out = await json.callTool('format', {
        'json_string': '{"a":1,"b":[1,2]}',
        'indent': 2,
      });
      expect(out, contains('\n'));
      expect(jsonDecode(out), {'a': 1, 'b': [1, 2]});
      // Two-space indentation.
      expect(out, contains('\n  "a": 1'));
    });

    test('format accepts numeric-string indent', () async {
      final out = await json.callTool('format', {
        'json_string': '{"a":1}',
        'indent': '4',
      });
      expect(out, contains('\n    "a": 1'));
    });

    test('format rejects invalid JSON', () async {
      await expectLater(
        json.callTool('format', {'json_string': '{oops'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('minify strips whitespace', () async {
      final out = await json.callTool('minify', {
        'json_string': '{ "a" : [ 1 , 2 ] }',
      });
      expect(out, '{"a":[1,2]}');
    });

    test('query navigates dot-notated path with array index', () async {
      final out = await json.callTool('query', {
        'json_string': '{"a":{"b":[{"c":42}]}}',
        'path': 'a.b.0.c',
      });
      expect(jsonDecode(out), 42);
    });

    test('query throws on missing path', () async {
      await expectLater(
        json.callTool('query', {
          'json_string': '{"a":1}',
          'path': 'a.b.c',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('stats reports keys, depth, types, and size', () async {
      const raw = '{"a":1,"b":{"c":"x","d":[true,null]}}';
      final out = await json.callTool('stats', {'json_string': raw});
      final stats = jsonDecode(out) as Map<String, dynamic>;
      expect(stats['keys'], 4);
      expect(stats['max_depth'], 3);
      final types = stats['types'] as Map<String, dynamic>;
      expect(types['object'], 2);
      expect(types['array'], 1);
      expect(types['number'], 1);
      expect(types['string'], 1);
      expect(types['boolean'], 1);
      expect(types['null'], 1);
      expect(stats['size'], utf8.encode(raw).length);
    });
  });

  group('Regex Builder', () {
    late NativePluginCapability regex;

    setUp(() {
      regex = NativePluginRegistry.I.capabilityFor('Regex Builder')!;
    });

    test('test returns matches with indices', () async {
      final out = await regex.callTool('test', {
        'pattern': r'\d+',
        'text': 'a1b22',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['count'], 2);
      final matches = decoded['matches'] as List;
      expect(matches[0]['match'], '1');
      expect(matches[0]['start'], 1);
      expect(matches[0]['end'], 2);
      expect(matches[1]['match'], '22');
      expect(matches[1]['start'], 3);
      expect(matches[1]['end'], 5);
    });

    test('test honors case_sensitive=false', () async {
      final out = await regex.callTool('test', {
        'pattern': 'abc',
        'text': 'ABC abc',
        'case_sensitive': false,
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['count'], 2);
    });

    test('replace performs search and replace', () async {
      final out = await regex.callTool('replace', {
        'pattern': r'\d+',
        'replacement': '#',
        'text': 'a1b22',
      });
      expect(out, 'a#b#');
    });

    test('replace supports empty replacement (deletion)', () async {
      final out = await regex.callTool('replace', {
        'pattern': r'\d+',
        'replacement': '',
        'text': 'a1b22',
      });
      expect(out, 'ab');
    });

    test('test rejects invalid patterns', () async {
      await expectLater(
        regex.callTool('test', {'pattern': '([', 'text': 'x'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('explain describes groups, classes, and quantifiers', () async {
      final out = await regex.callTool('explain', {
        'pattern': r'^([a-z]+)\d*$',
      });
      expect(out, contains('anchor'));
      expect(out, contains('group'));
      expect(out, contains('character class'));
      expect(out, contains('quantifier'));
    });
  });

  group('SQL Formatter', () {
    late NativePluginCapability sql;

    setUp(() {
      sql = NativePluginRegistry.I.capabilityFor('SQL Formatter')!;
    });

    test('format indents clauses and uppercases keywords', () async {
      final out = await sql.callTool('format', {
        'sql': 'select a, b from users where age > 18 order by name',
      });
      expect(
        out,
        'SELECT a, b\nFROM users\nWHERE age > 18\nORDER BY name',
      );
    });

    test('format breaks joins and AND onto their own lines', () async {
      final out = await sql.callTool('format', {
        'sql': 'select * from a join b on a.id = b.id where x = 1 and y = 2',
      });
      expect(
        out,
        'SELECT *\nFROM a\nJOIN b\n  ON a.id = b.id\nWHERE x = 1\n  AND y = 2',
      );
    });

    test('validate accepts a balanced statement', () async {
      final out = await sql.callTool('validate', {
        'sql': "select * from users where name = 'ann'",
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['valid'], isTrue);
      expect(decoded['errors'], isEmpty);
    });

    test('validate flags unbalanced quotes and parentheses', () async {
      final unbalancedQuote = await sql.callTool('validate', {
        'sql': "select * from users where name = 'ann",
      });
      final q = jsonDecode(unbalancedQuote) as Map<String, dynamic>;
      expect(q['valid'], isFalse);
      expect((q['errors'] as List).join(' '), contains('quote'));

      final unbalancedParen = await sql.callTool('validate', {
        'sql': 'select (a from t',
      });
      final p = jsonDecode(unbalancedParen) as Map<String, dynamic>;
      expect(p['valid'], isFalse);
      expect((p['errors'] as List).join(' '), contains('parenthes'));
    });
  });

  group('Cron Designer', () {
    late NativePluginCapability cron;

    setUp(() {
      cron = NativePluginRegistry.I.capabilityFor('Cron Designer')!;
    });

    test('explain describes a weekday morning schedule', () async {
      final out = await cron.callTool('explain', {
        'expression': '0 9 * * 1-5',
      });
      expect(out, contains('09:00'));
      expect(out, contains('Monday'));
      expect(out, contains('Friday'));
    });

    test('explain rejects malformed expressions', () async {
      await expectLater(
        cron.callTool('explain', {'expression': 'not a cron'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('build generates a daily expression from time', () async {
      final out = await cron.callTool('build', {
        'frequency': 'daily',
        'time': '09:30',
      });
      expect(out, '30 9 * * *');
    });

    test('build generates a weekly expression from time and days', () async {
      final out = await cron.callTool('build', {
        'frequency': 'weekly',
        'time': '08:15',
        'days': [1, 3, 5],
      });
      expect(out, '15 8 * * 1,3,5');
    });

    test('next_runs returns increasing future timestamps', () async {
      final out = await cron.callTool('next_runs', {
        'expression': '0 9 * * *',
        'count': 3,
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      final runs = (decoded['runs'] as List).cast<String>();
      expect(runs, hasLength(3));
      final times = runs.map(DateTime.parse).toList();
      final now = DateTime.now().toUtc();
      for (var i = 0; i < times.length; i++) {
        expect(times[i].isAfter(now), isTrue);
        expect(times[i].minute, 0);
        expect(times[i].hour, 9);
        if (i > 0) {
          expect(times[i].isAfter(times[i - 1]), isTrue);
        }
      }
    });

    test('next_runs accepts numeric-string count', () async {
      final out = await cron.callTool('next_runs', {
        'expression': '0 9 * * *',
        'count': '3',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect((decoded['runs'] as List), hasLength(3));
    });

    test('step range N/S matches N..max stepped by S', () async {
      final out = await cron.callTool('next_runs', {
        'expression': '5/15 * * * *',
        'count': '20',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      final runs = (decoded['runs'] as List).cast<String>();
      expect(runs, isNotEmpty);
      const allowed = {5, 20, 35, 50};
      final seen = <int>{};
      for (final r in runs) {
        final minute = DateTime.parse(r).minute;
        expect(allowed, contains(minute), reason: 'run $r must match 5/15');
        seen.add(minute);
      }
      // Twenty consecutive matches of a 15-minute step cover all residues.
      expect(seen, containsAll([5, 20, 35, 50]));
    });
  });

  group('Color Palette Gen', () {
    late NativePluginCapability color;

    setUp(() {
      color = NativePluginRegistry.I.capabilityFor('Color Palette Gen')!;
    });

    test('from_hex derives complementary, analogous, and triadic', () async {
      final out = await color.callTool('from_hex', {'hex': '#ff0000'});
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['base'], '#ff0000');
      expect(decoded['complementary'], '#00ffff');
      expect((decoded['analogous'] as List), hasLength(2));
      expect((decoded['triadic'] as List), hasLength(2));
      expect((decoded['monochromatic'] as List), hasLength(3));
      for (final key in [
        'complementary',
        'analogous',
        'triadic',
        'monochromatic'
      ]) {
        final values =
            decoded[key] is List ? decoded[key] as List : [decoded[key]];
        for (final v in values) {
          expect(v, matches(RegExp(r'^#[0-9a-f]{6}$')));
        }
      }
    });

    test('from_hex rejects invalid input', () async {
      await expectLater(
        color.callTool('from_hex', {'hex': 'not-a-color'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('contrast computes WCAG ratio for black on white', () async {
      final out = await color.callTool('contrast', {
        'hex1': '#000000',
        'hex2': '#ffffff',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect((decoded['ratio'] as num).toDouble(), closeTo(21.0, 0.01));
      expect(decoded['aa_normal'], isTrue);
      expect(decoded['aaa_normal'], isTrue);
    });

    test('contrast of identical colors is 1.0 and fails AA', () async {
      final out = await color.callTool('contrast', {
        'hex1': '#336699',
        'hex2': '#336699',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect((decoded['ratio'] as num).toDouble(), closeTo(1.0, 0.001));
      expect(decoded['aa_normal'], isFalse);
    });
  });
}
