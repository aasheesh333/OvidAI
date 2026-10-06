import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/mcp_catalog_tools.dart';

/// Fake service surface: proves the exposure layer maps catalogs without any
/// real transport, sandbox, or network.
class _FakeBackend implements McpCatalogBackend {
  _FakeBackend({this.info});

  McpCatalogServer? info;
  List<Map<String, dynamic>> prompts = const [];
  List<Map<String, dynamic>> resources = const [];
  List<Map<String, dynamic>> templates = const [];
  Map<String, dynamic> promptPayload = const {};
  Map<String, dynamic> resourcePayload = const {};
  final calls = <String>[];

  @override
  Future<McpCatalogServer?> serverInfo(String serverName) async => info;

  @override
  Future<List<Map<String, dynamic>>> listPrompts(
    String serverName, {
    Duration? timeout,
    bool refresh = false,
  }) async {
    calls.add('prompts:$serverName:refresh=$refresh');
    return prompts;
  }

  @override
  Future<List<Map<String, dynamic>>> listResources(
    String serverName, {
    Duration? timeout,
    bool refresh = false,
  }) async {
    calls.add('resources:$serverName:refresh=$refresh');
    return resources;
  }

  @override
  Future<List<Map<String, dynamic>>> listResourceTemplates(
    String serverName, {
    Duration? timeout,
    bool refresh = false,
  }) async {
    calls.add('templates:$serverName:refresh=$refresh');
    return templates;
  }

  @override
  Future<Map<String, dynamic>> getPrompt(
    String serverName,
    String name, {
    Map<String, String> arguments = const {},
    Duration? timeout,
  }) async {
    calls.add('getPrompt:$serverName:$name:$arguments');
    return promptPayload;
  }

  @override
  Future<Map<String, dynamic>> readResource(
    String serverName,
    String uri, {
    Duration? timeout,
  }) async {
    calls.add('readResource:$serverName:$uri');
    return resourcePayload;
  }
}

McpCatalogServer _userServer() =>
    const McpCatalogServer(name: 'files', transport: 'stdio');

McpCatalogServer _pluginServer({bool visible = true}) => McpCatalogServer(
  name: 'acme/notes',
  transport: 'http',
  ownerPluginId: 'acme',
  ownerVisible: visible,
);

void main() {
  group('catalog mapping', () {
    test('listPrompts maps identity, description and typed arguments', () async {
      final fake = _FakeBackend(info: _userServer())
        ..prompts = [
          {
            'name': 'summarize',
            'title': 'Summarize',
            'description': 'Summarize a topic',
            'arguments': [
              {'name': 'topic', 'description': 'What to summarize', 'required': true},
              {'name': 'style'},
            ],
          },
        ];
      final tools = McpCatalogTools(backend: fake);

      final result = await tools.listPrompts('files');

      expect(result.tool, McpCatalogTools.listPromptsTool);
      expect(result.kind, McpCatalogKind.prompts);
      expect(result.total, 1);
      expect(result.truncated, isFalse);
      final entry = result.entries.single;
      expect(entry.identity, 'summarize');
      expect(entry.title, 'Summarize');
      expect(entry.description, 'Summarize a topic');
      expect(entry.arguments.map((a) => a.name), ['topic', 'style']);
      expect(entry.arguments.first.required, isTrue);
      expect(entry.arguments.last.required, isFalse);
      expect(fake.calls, ['prompts:files:refresh=false']);
    });

    test('listResources maps uri as identity', () async {
      final fake = _FakeBackend(info: _userServer())
        ..resources = [
          {'name': 'readme', 'uri': 'file:///readme.md', 'mimeType': 'text/markdown'},
        ];
      final tools = McpCatalogTools(backend: fake);

      final result = await tools.listResources('files');

      expect(result.kind, McpCatalogKind.resources);
      final entry = result.entries.single;
      expect(entry.identity, 'file:///readme.md');
      expect(entry.name, 'readme');
      expect(entry.mimeType, 'text/markdown');
      expect(result.toJson()['kind'], 'resource');
    });

    test('listResourceTemplates maps uriTemplate as identity', () async {
      final fake = _FakeBackend(info: _userServer())
        ..templates = [
          {'name': 'by-id', 'uriTemplate': 'db://rows/{id}'},
        ];
      final tools = McpCatalogTools(backend: fake);

      final result = await tools.listResourceTemplates('files');

      expect(result.kind, McpCatalogKind.resourceTemplates);
      expect(result.entries.single.identity, 'db://rows/{id}');
    });

    test('refresh is forwarded to the backend', () async {
      final fake = _FakeBackend(info: _userServer());
      final tools = McpCatalogTools(backend: fake);

      await tools.listPrompts('files', refresh: true);

      expect(fake.calls, ['prompts:files:refresh=true']);
    });

    test('getPrompt passes through the validated payload', () async {
      final fake = _FakeBackend(info: _userServer())
        ..promptPayload = {
          'description': 'A greeting',
          'messages': [
            {'role': 'user', 'content': {'type': 'text', 'text': 'hi'}},
          ],
        };
      final tools = McpCatalogTools(backend: fake);

      final result = await tools.getPrompt(
        'files',
        'greet',
        arguments: {'who': 'world'},
      );

      expect(result.tool, McpCatalogTools.getPromptTool);
      expect(result.payload, same(fake.promptPayload));
      expect(fake.calls, ['getPrompt:files:greet:{who: world}']);
    });

    test('readResource passes through the validated payload', () async {
      final fake = _FakeBackend(info: _userServer())
        ..resourcePayload = {
          'contents': [
            {'uri': 'file:///a.txt', 'text': 'body'},
          ],
        };
      final tools = McpCatalogTools(backend: fake);

      final result = await tools.readResource('files', 'file:///a.txt');

      expect(result.tool, McpCatalogTools.readResourceTool);
      expect(result.payload, same(fake.resourcePayload));
      expect(fake.calls, ['readResource:files:file:///a.txt']);
    });
  });

  group('per-owner visibility notes', () {
    test('user-owned server reports every-session visibility', () async {
      final fake = _FakeBackend(info: _userServer())..prompts = [];
      final tools = McpCatalogTools(backend: fake);

      final result = await tools.listPrompts('files');

      expect(result.server.ownerPluginId, isNull);
      expect(result.server.visibilityNote, contains('every session'));
      expect(result.toJson()['owner_visible'], isTrue);
    });

    test('inactive plugin owner is flagged as not visible', () async {
      final fake = _FakeBackend(info: _pluginServer(visible: false))
        ..prompts = [];
      final tools = McpCatalogTools(backend: fake);

      final result = await tools.listPrompts('acme/notes');

      expect(result.server.visibilityNote, contains('NOT visible'));
      expect(result.toJson()['owner_plugin'], 'acme');
      expect(result.toJson()['owner_visible'], isFalse);
      expect(result.render(), contains('NOT visible'));
    });
  });

  group('bounds', () {
    test('entry cap truncates and records the omitted count', () async {
      final fake = _FakeBackend(info: _userServer())
        ..prompts = [
          for (var i = 0; i < 5; i++) {'name': 'p$i'},
        ];
      final tools = McpCatalogTools(backend: fake, maxEntries: 2);

      final result = await tools.listPrompts('files');

      expect(result.entries.length, 2);
      expect(result.total, 5);
      expect(result.truncated, isTrue);
      expect(result.notice, contains('3 more'));
      expect(result.render(), contains('showing 2 of 5'));
    });

    test('character cap bounds rendered output with an omission notice', () async {
      final fake = _FakeBackend(info: _userServer())
        ..prompts = [
          {'name': 'big', 'description': 'x' * 5000},
        ];
      final tools = McpCatalogTools(backend: fake, maxChars: 200);

      final result = await tools.listPrompts('files');
      final rendered = result.render(maxChars: tools.maxChars);

      expect(rendered.length, lessThanOrEqualTo(200));
      expect(rendered, contains('characters omitted'));
      expect(rendered, startsWith(McpCatalogTools.listPromptsTool));
    });

    test('getPrompt payload rendering is bounded', () async {
      final fake = _FakeBackend(info: _userServer())
        ..promptPayload = {'text': 'y' * 8000};
      final tools = McpCatalogTools(backend: fake, maxChars: 128);

      final result = await tools.getPrompt('files', 'p');
      final rendered = result.render(maxChars: tools.maxChars);

      expect(rendered.length, lessThanOrEqualTo(128));
      expect(rendered, contains('characters omitted'));
    });
  });

  group('unsupported native transport', () {
    test('every catalog entry point throws UnsupportedError', () async {
      final fake = _FakeBackend(
        info: const McpCatalogServer(name: 'native-srv', transport: 'native'),
      );
      final tools = McpCatalogTools(backend: fake);

      await expectLater(
        tools.listPrompts('native-srv'),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        tools.listResources('native-srv'),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        tools.listResourceTemplates('native-srv'),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        tools.getPrompt('native-srv', 'p'),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        tools.readResource('native-srv', 'uri://x'),
        throwsA(isA<UnsupportedError>()),
      );
      // The service is never touched.
      expect(fake.calls, isEmpty);
    });

    test('dispatch surfaces the native refusal', () async {
      final fake = _FakeBackend(
        info: const McpCatalogServer(name: 'native-srv', transport: 'native'),
      );
      final tools = McpCatalogTools(backend: fake);

      await expectLater(
        tools.dispatch(McpCatalogTools.listResourcesTool, {'server': 'native-srv'}),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('dispatch and specs', () {
    test('handles only its own tool names', () {
      final tools = McpCatalogTools(backend: _FakeBackend());
      expect(tools.handles(McpCatalogTools.listPromptsTool), isTrue);
      expect(tools.handles(McpCatalogTools.readResourceTool), isTrue);
      expect(tools.handles('mcp_github'), isFalse);
      expect(tools.handles('catalog_list_mcp'), isFalse);
    });

    test('toolSpecs exposes five well-formed function tools', () {
      final tools = McpCatalogTools(backend: _FakeBackend());
      final specs = tools.toolSpecs;

      expect(specs.length, 5);
      final names = <String>{};
      for (final spec in specs) {
        expect(spec['type'], 'function');
        final fn = spec['function'] as Map<String, dynamic>;
        names.add(fn['name'] as String);
        final params = fn['parameters'] as Map<String, dynamic>;
        expect((params['required'] as List).contains('server'), isTrue);
      }
      expect(names, McpCatalogTools.toolNames);
    });

    test('dispatch maps get_prompt arguments and bounds the result', () async {
      final fake = _FakeBackend(info: _userServer())
        ..promptPayload = {'messages': []};
      final tools = McpCatalogTools(backend: fake);

      final out = await tools.dispatch(McpCatalogTools.getPromptTool, {
        'server': 'files',
        'name': 'greet',
        'arguments': {'who': 'world', 'count': 3},
      });

      expect(fake.calls, ['getPrompt:files:greet:{who: world, count: 3}']);
      expect(out, contains(McpCatalogTools.getPromptTool));
      expect(out, contains('user-owned server'));
    });

    test('unknown server fails closed', () async {
      final tools = McpCatalogTools(backend: _FakeBackend());
      await expectLater(
        tools.listPrompts('missing'),
        throwsA(isA<StateError>()),
      );
    });

    test('unknown tool is rejected', () async {
      final tools = McpCatalogTools(backend: _FakeBackend(info: _userServer()));
      await expectLater(
        tools.dispatch('catalog_mcp_nope', {'server': 'files'}),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('missing required dispatch argument is rejected', () async {
      final tools = McpCatalogTools(backend: _FakeBackend(info: _userServer()));
      await expectLater(
        tools.dispatch(McpCatalogTools.listPromptsTool, {}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
