import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/web_and_db_utilities.dart';

void main() {
  setUp(() {
    NativePluginRegistry.I.clearForTest();
    registerWebAndDbUtilities();
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
  });

  group('registration', () {
    test('all five Part C utilities are registered', () {
      for (final name in [
        'API Tester',
        'Web Scraper Pro',
        'Prompt Library',
        'DB Designer',
        'Web Clipper',
      ]) {
        expect(NativePluginRegistry.I.has(name), isTrue, reason: name);
      }
      expect(
        NativePluginRegistry.I.capabilityForSlug('api_tester'),
        isA<ApiTesterCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('web_scraper_pro'),
        isA<WebScraperProCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('prompt_library'),
        isA<PromptLibraryCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('db_designer'),
        isA<DbDesignerCapability>(),
      );
      expect(
        NativePluginRegistry.I.capabilityForSlug('web_clipper'),
        isA<WebClipperCapability>(),
      );
    });

    test('unknown tool names throw ArgumentError', () async {
      for (final slug in [
        'api_tester',
        'web_scraper_pro',
        'prompt_library',
        'db_designer',
        'web_clipper',
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

  group('API Tester', () {
    test('GET returns status, headers, and body', () async {
      final tester = ApiTesterCapability(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.toString(), 'https://example.com/items');
          return http.Response(
            '{"ok":true}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      final out = await tester.callTool('request', {
        'url': 'https://example.com/items',
        'method': 'GET',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['status'], 200);
      expect(decoded['body'], '{"ok":true}');
      expect(
        (decoded['headers'] as Map).keys.map((k) => k.toString().toLowerCase()),
        contains('content-type'),
      );
      expect(decoded['elapsed_ms'], isA<num>());
    });

    test('POST sends headers and body', () async {
      final tester = ApiTesterCapability(
        client: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.headers['x-token'], 'abc');
          expect(request.body, '{"name":"x"}');
          return http.Response('created', 201);
        }),
      );
      final out = await tester.callTool('request', {
        'url': 'https://example.com/items',
        'method': 'post',
        'headers': {'x-token': 'abc'},
        'body': '{"name":"x"}',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['status'], 201);
      expect(decoded['body'], 'created');
    });

    test('missing url throws ArgumentError', () async {
      final tester = ApiTesterCapability(
        client: MockClient((_) async => http.Response('', 200)),
      );
      await expectLater(
        tester.callTool('request', {'method': 'GET'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('invalid url throws FormatException', () async {
      final tester = ApiTesterCapability(
        client: MockClient((_) async => http.Response('', 200)),
      );
      await expectLater(
        tester.callTool('request', {'url': 'not a url at all %%'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('unsupported method throws ArgumentError', () async {
      final tester = ApiTesterCapability(
        client: MockClient((_) async => http.Response('', 200)),
      );
      await expectLater(
        tester.callTool('request', {
          'url': 'https://example.com/',
          'method': 'BREW',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Web Scraper Pro', () {
    late NativePluginCapability scraper;

    setUp(() {
      scraper = NativePluginRegistry.I.capabilityFor('Web Scraper Pro')!;
    });

    const html = '''
<html><body>
<a href="https://a.example/">Alpha</a>
<a href="/beta">Beta link</a>
<img src="pic.png" alt="A picture">
<p>Hello world</p>
<p>Goodbye world</p>
</body></html>
''';

    test('extracts link hrefs', () async {
      final out = await scraper.callTool('extract', {
        'html': html,
        'tag': 'a',
        'attribute': 'href',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['count'], 2);
      final values = [
        for (final r in decoded['results'] as List) (r as Map)['value'],
      ];
      expect(values, contains('https://a.example/'));
      expect(values, contains('/beta'));
    });

    test('extracts image src attributes', () async {
      final out = await scraper.callTool('extract', {
        'html': html,
        'tag': 'img',
        'attribute': 'src',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['count'], 1);
      expect(
        ((decoded['results'] as List).first as Map)['value'],
        'pic.png',
      );
    });

    test('extracts element text with contains_text filter', () async {
      final out = await scraper.callTool('extract', {
        'html': html,
        'tag': 'p',
        'contains_text': 'goodbye',
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['count'], 1);
      expect(
        ((decoded['results'] as List).first as Map)['text'],
        contains('Goodbye'),
      );
    });

    test('extracts all text blocks when no tag is given', () async {
      final out = await scraper.callTool('extract', {'html': html});
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect((decoded['count'] as num), greaterThan(0));
    });

    test('missing html throws ArgumentError', () async {
      await expectLater(
        scraper.callTool('extract', {'tag': 'a'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Prompt Library', () {
    late NativePluginCapability library;

    setUp(() {
      library = NativePluginRegistry.I.capabilityFor('Prompt Library')!;
    });

    test('save, get, list, and delete round-trip', () async {
      await library.callTool('save', {
        'title': 'Summarize',
        'prompt': 'Summarize this: {{text}}',
        'tags': ['writing'],
      });
      expect(
        await library.callTool('get', {'title': 'Summarize'}),
        'Summarize this: {{text}}',
      );
      final listed =
          jsonDecode(await library.callTool('list', {})) as List;
      expect(
        listed.map((e) => (e as Map)['title']),
        contains('Summarize'),
      );
      await library.callTool('delete', {'title': 'Summarize'});
      await expectLater(
        library.callTool('get', {'title': 'Summarize'}),
        throwsA(isA<ArgumentError>()),
      );
      final after =
          jsonDecode(await library.callTool('list', {})) as List;
      expect(
        after.map((e) => (e as Map)['title']),
        isNot(contains('Summarize')),
      );
    });

    test('list filters by tag', () async {
      await library.callTool('save', {
        'title': 'Code Review',
        'prompt': 'Review this code.',
        'tags': ['code'],
      });
      await library.callTool('save', {
        'title': 'Haiku',
        'prompt': 'Write a haiku.',
        'tags': ['writing'],
      });
      final filtered =
          jsonDecode(await library.callTool('list', {'tag': 'code'}))
              as List;
      expect(
        filtered.map((e) => (e as Map)['title']),
        contains('Code Review'),
      );
      expect(
        filtered.map((e) => (e as Map)['title']),
        isNot(contains('Haiku')),
      );
    });

    test('save requires title and prompt', () async {
      await expectLater(
        library.callTool('save', {'title': 'No prompt'}),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        library.callTool('save', {'prompt': 'No title'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('get of a missing prompt throws ArgumentError', () async {
      await expectLater(
        library.callTool('get', {'title': 'does-not-exist'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('delete of a missing prompt throws ArgumentError', () async {
      await expectLater(
        library.callTool('delete', {'title': 'does-not-exist'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('DB Designer', () {
    late NativePluginCapability designer;

    setUp(() {
      designer = NativePluginRegistry.I.capabilityFor('DB Designer')!;
    });

    const schema = '''
{
  "tables": [
    {
      "name": "teams",
      "columns": [
        {"name": "id", "type": "INTEGER", "primary_key": true},
        {"name": "name", "type": "TEXT", "nullable": false, "unique": true}
      ]
    },
    {
      "name": "users",
      "columns": [
        {"name": "id", "type": "INTEGER", "primary_key": true},
        {"name": "email", "type": "TEXT", "nullable": false, "unique": true},
        {"name": "team_id", "type": "INTEGER", "references": "teams(id)"}
      ]
    }
  ]
}
''';

    test('generate_ddl emits PostgreSQL DDL', () async {
      final out = await designer.callTool('generate_ddl', {
        'schema': schema,
        'dialect': 'postgres',
      });
      expect(out, contains('CREATE TABLE "teams"'));
      expect(out, contains('CREATE TABLE "users"'));
      expect(out, contains('PRIMARY KEY'));
      expect(out, contains('REFERENCES teams(id)'));
    });

    test('generate_ddl emits SQLite DDL', () async {
      final out = await designer.callTool('generate_ddl', {
        'schema': schema,
        'dialect': 'sqlite',
      });
      expect(out, contains('CREATE TABLE "teams"'));
      expect(out, contains('CREATE TABLE "users"'));
    });

    test('generate_ddl rejects invalid JSON', () async {
      await expectLater(
        designer.callTool('generate_ddl', {'schema': '{oops'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('generate_ddl rejects unknown dialect', () async {
      await expectLater(
        designer.callTool('generate_ddl', {
          'schema': schema,
          'dialect': 'oracle',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('validate_schema accepts a valid schema', () async {
      final out = await designer.callTool('validate_schema', {
        'schema': schema,
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['valid'], isTrue);
      expect((decoded['errors'] as List), isEmpty);
    });

    test('validate_schema flags missing PK, bad types, dangling FK',
        () async {
      const bad = '''
{
  "tables": [
    {
      "name": "users",
      "columns": [
        {"name": "id", "type": "NOTATYPE"},
        {"name": "team_id", "type": "INTEGER", "references": "teams(id)"}
      ]
    }
  ]
}
''';
      final out = await designer.callTool('validate_schema', {
        'schema': bad,
      });
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['valid'], isFalse);
      final errors = (decoded['errors'] as List).join('\n');
      expect(errors, contains('primary key'));
      expect(errors, contains('NOTATYPE'));
      expect(errors, contains('teams'));
    });

    test('validate_schema requires schema argument', () async {
      await expectLater(
        designer.callTool('validate_schema', {}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('Web Clipper', () {
    const page = '''
<html><head><title>Example Page</title></head>
<body>
<h1>Welcome</h1>
<p>Hello <a href="https://example.com/more">read more</a>.</p>
<script>var x = 1;</script>
</body></html>
''';

    test('clip fetches a page and returns markdown', () async {
      final clipper = WebClipperCapability(
        client: MockClient((request) async {
          expect(request.url.toString(), 'https://example.com/');
          return http.Response(page, 200);
        }),
      );
      final out = await clipper.callTool('clip', {
        'url': 'https://example.com/',
      });
      expect(out, contains('# Example Page'));
      expect(out, contains('Welcome'));
      expect(out, contains('[read more](https://example.com/more)'));
      expect(out, isNot(contains('var x = 1')));
    });

    test('clip reports HTTP errors as FormatException', () async {
      final clipper = WebClipperCapability(
        client: MockClient((_) async => http.Response('nope', 404)),
      );
      await expectLater(
        clipper.callTool('clip', {'url': 'https://example.com/missing'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('clip requires url', () async {
      final clipper = WebClipperCapability(
        client: MockClient((_) async => http.Response('', 200)),
      );
      await expectLater(
        clipper.callTool('clip', {}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
