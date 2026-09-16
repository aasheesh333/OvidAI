import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/dev_utilities.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
    registerDevUtilities();
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
  });

  group('registration', () {
    test('all five Part B utilities are registered', () {
      for (final name in [
        'File Converter',
        'Markdown Editor',
        'Password Vault',
        'Env Manager',
        'Log Analyzer',
      ]) {
        expect(NativePluginRegistry.I.has(name), isTrue, reason: name);
      }
      expect(
        NativePluginRegistry.I.capabilityForSlug('file_converter'),
        isA<FileConverterCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('markdown_editor'),
        isA<MarkdownEditorCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('password_vault'),
        isA<PasswordVaultCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('env_manager'),
        isA<EnvManagerCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('log_analyzer'),
        isA<LogAnalyzerCapability>(),
      );
    });

    test('unknown tool names throw ArgumentError', () async {
      for (final slug in [
        'file_converter',
        'markdown_editor',
        'password_vault',
        'env_manager',
        'log_analyzer',
      ]) {
        final capability =
            NativePluginRegistry.I.capabilityForSlug(slug)!;
        await expectLater(
          capability.callTool('nope', {}),
          throwsA(isA<ArgumentError>()),
          reason: slug,
        );
      }
    });
  });

  group('File Converter', () {
    late NativePluginCapability converter;

    setUp(() {
      converter =
          NativePluginRegistry.I.capabilityFor('File Converter')!;
    });

    test('csv_to_json converts headers and rows to objects', () async {
      final out = await converter.callTool('csv_to_json', {
        'csv_text': 'name,age\nAlice,30\nBob,25',
      });
      expect(
        jsonDecode(out),
        [
          {'name': 'Alice', 'age': '30'},
          {'name': 'Bob', 'age': '25'},
        ],
      );
    });

    test('csv_to_json honors quoted commas and escaped quotes', () async {
      final out = await converter.callTool('csv_to_json', {
        'csv_text': 'name,note\nAlice,"likes, apples"\nBob,"says ""hi"""',
      });
      expect(
        jsonDecode(out),
        [
          {'name': 'Alice', 'note': 'likes, apples'},
          {'name': 'Bob', 'note': 'says "hi"'},
        ],
      );
    });

    test('csv_to_json rejects empty input', () async {
      await expectLater(
        converter.callTool('csv_to_json', {'csv_text': '  \n'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('csv_to_json requires csv_text', () async {
      await expectLater(
        converter.callTool('csv_to_json', {}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('json_to_csv flattens an array of objects', () async {
      final out = await converter.callTool('json_to_csv', {
        'json_text': '[{"a":1,"b":"x"},{"a":2,"b":"y"}]',
      });
      expect(out, 'a,b\n1,x\n2,y');
    });

    test('json_to_csv escapes commas and quotes', () async {
      final out = await converter.callTool('json_to_csv', {
        'json_text': '[{"a":"x,y","b":"q\\"z"}]',
      });
      expect(out, 'a,b\n"x,y","q""z"');
    });

    test('json_to_csv rejects non-array JSON', () async {
      await expectLater(
        converter.callTool('json_to_csv', {'json_text': '{"a":1}'}),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        converter.callTool('json_to_csv', {'json_text': '[1,2]'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('json_to_csv rejects invalid JSON', () async {
      await expectLater(
        converter.callTool('json_to_csv', {'json_text': '{oops'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('Markdown Editor', () {
    late NativePluginCapability editor;

    setUp(() {
      editor =
          NativePluginRegistry.I.capabilityFor('Markdown Editor')!;
    });

    test('render_html converts markdown to HTML', () async {
      final out = await editor.callTool('render_html', {
        'markdown': '# Hello\n\n**bold**',
      });
      expect(out, contains('<h1>Hello</h1>'));
      expect(out, contains('<strong>bold</strong>'));
    });

    test('extract_toc lists headers with levels and anchors', () async {
      final out = await editor.callTool('extract_toc', {
        'markdown': '# Title\n## Section One\n### Sub!\n## Section Two',
      });
      expect(
        jsonDecode(out),
        [
          {'level': 1, 'text': 'Title', 'anchor': 'title'},
          {'level': 2, 'text': 'Section One', 'anchor': 'section-one'},
          {'level': 3, 'text': 'Sub!', 'anchor': 'sub'},
          {'level': 2, 'text': 'Section Two', 'anchor': 'section-two'},
        ],
      );
    });

    test('stats reports words, characters, and reading time', () async {
      final out = await editor.callTool('stats', {
        'markdown': 'Hello world',
      });
      final stats = jsonDecode(out) as Map<String, dynamic>;
      expect(stats['words'], 2);
      expect(stats['characters'], 11);
      expect(stats['reading_time_minutes'], 1);
    });

    test('stats handles empty input', () async {
      final out = await editor.callTool('stats', {'markdown': ''});
      final stats = jsonDecode(out) as Map<String, dynamic>;
      expect(stats['words'], 0);
      expect(stats['characters'], 0);
      expect(stats['reading_time_minutes'], 0);
    });

    test('missing markdown argument throws ArgumentError', () async {
      await expectLater(
        editor.callTool('render_html', {}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Password Vault', () {
    late NativePluginCapability vault;

    setUp(() {
      vault = NativePluginRegistry.I.capabilityFor('Password Vault')!;
    });

    test('generate returns a password of the requested length', () async {
      final out = await vault.callTool('generate', {'length': 16});
      expect(out, hasLength(16));
    });

    test('generate honors charset selection', () async {
      final out = await vault.callTool('generate', {
        'length': 32,
        'uppercase': false,
        'lowercase': false,
        'numbers': true,
        'symbols': false,
      });
      expect(out, hasLength(32));
      expect(out, matches(RegExp(r'^[0-9]+$')));
    });

    test('generate produces distinct values', () async {
      final first = await vault.callTool('generate', {'length': 16});
      final second = await vault.callTool('generate', {'length': 16});
      expect(first, isNot(equals(second)));
    });

    test('generate rejects bad lengths and empty charsets', () async {
      await expectLater(
        vault.callTool('generate', {'length': 0}),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        vault.callTool('generate', {
          'length': 12,
          'uppercase': false,
          'lowercase': false,
          'numbers': false,
          'symbols': false,
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('store, get, and list round-trip without leaking values',
        () async {
      await vault.callTool('store', {
        'key': 'api_key',
        'secret': 's3cret-value',
      });
      expect(
        await vault.callTool('get', {'key': 'api_key'}),
        's3cret-value',
      );
      final listed = jsonDecode(await vault.callTool('list', {}))
          as Map<String, dynamic>;
      expect((listed['keys'] as List), contains('api_key'));
      expect(await vault.callTool('list', {}), isNot(contains('s3cret')));
    });

    test('get of a missing key throws ArgumentError', () async {
      await expectLater(
        vault.callTool('get', {'key': 'does-not-exist'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('store requires key and secret', () async {
      await expectLater(
        vault.callTool('store', {'key': 'k'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Env Manager', () {
    late NativePluginCapability env;

    setUp(() {
      env = NativePluginRegistry.I.capabilityFor('Env Manager')!;
    });

    test('parse handles comments, quotes, export, and empty values',
        () async {
      const content = '# a comment\n'
          'FOO=bar\n'
          'BAR="hello world"\n'
          "BAZ='single'\n"
          'export QUX=123\n'
          'EMPTY=\n';
      final out = await env.callTool('parse', {'env_content': content});
      expect(
        jsonDecode(out),
        {
          'FOO': 'bar',
          'BAR': 'hello world',
          'BAZ': 'single',
          'QUX': '123',
          'EMPTY': '',
        },
      );
    });

    test('parse strips inline comments from unquoted values', () async {
      final out = await env.callTool('parse', {
        'env_content': 'KEY=value # a comment',
      });
      expect(jsonDecode(out), {'KEY': 'value'});
    });

    test('set updates an existing key and preserves other lines',
        () async {
      const content = '# config\nFOO=old\nBAR=keep\n';
      final out = await env.callTool('set', {
        'env_content': content,
        'key': 'FOO',
        'value': 'new',
      });
      expect(out, '# config\nFOO=new\nBAR=keep\n');
    });

    test('set appends a missing key', () async {
      final out = await env.callTool('set', {
        'env_content': 'FOO=1\n',
        'key': 'BAR',
        'value': '2',
      });
      expect(out, contains('FOO=1'));
      expect(out, contains('BAR=2'));
    });

    test('set rejects invalid keys', () async {
      await expectLater(
        env.callTool('set', {
          'env_content': 'FOO=1\n',
          'key': 'not a key',
          'value': 'x',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('merge combines files with override winning', () async {
      final out = await env.callTool('merge', {
        'base_env': 'A=1\nB=2\n',
        'override_env': 'B=3\nC=4\n',
      });
      expect(out, contains('A=1'));
      expect(out, contains('B=3'));
      expect(out, isNot(contains('B=2')));
      expect(out, contains('C=4'));
    });
  });

  group('Log Analyzer', () {
    late NativePluginCapability logs;

    setUp(() {
      logs = NativePluginRegistry.I.capabilityFor('Log Analyzer')!;
    });

    const sample = 'INFO starting up\n'
        'ERROR failed to connect\n'
        'ERROR retry failed\n'
        'INFO recovered\n'
        'WARN disk nearly full\n'
        'DEBUG verbose detail\n'
        'FATAL unrecoverable\n'
        'plain line without a level';

    test('parse counts severities and finds error clusters', () async {
      final out = await logs.callTool('parse', {'log_text': sample});
      final parsed = jsonDecode(out) as Map<String, dynamic>;
      expect(parsed['total'], 8);
      final counts = parsed['counts'] as Map<String, dynamic>;
      expect(counts['INFO'], 2);
      expect(counts['ERROR'], 2);
      expect(counts['WARN'], 1);
      expect(counts['DEBUG'], 1);
      expect(counts['FATAL'], 1);
      expect(counts['UNKNOWN'], 1);
      final clusters = parsed['error_clusters'] as List;
      expect(clusters, hasLength(1));
      expect(clusters.first, [2, 3]);
    });

    test('filter selects lines by level', () async {
      final out = await logs.callTool('filter', {
        'log_text': sample,
        'level': 'ERROR',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['count'], 2);
      for (final line in decoded['matches'] as List) {
        expect(line as String, contains('ERROR'));
      }
    });

    test('filter combines level and query substring', () async {
      final out = await logs.callTool('filter', {
        'log_text': sample,
        'level': 'INFO',
        'query': 'recovered',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['count'], 1);
      expect((decoded['matches'] as List).first, contains('recovered'));
    });

    test('filter rejects unknown levels', () async {
      await expectLater(
        logs.callTool('filter', {
          'log_text': sample,
          'level': 'BOGUS',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('parse requires log_text', () async {
      await expectLater(
        logs.callTool('parse', {}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
