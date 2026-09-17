import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/native_plugins/rest_descriptors_aimedia.dart';
import 'package:ovid_ai/core/native_plugins/rest_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pluginNames = [
    'OpenAI DALL·E MCP',
    'ElevenLabs MCP',
    'Notion Sync',
    'Google Drive MCP',
    'Stripe MCP',
    'YouTube Summarizer',
    'LangChain MCP',
    'AutoGPT Bridge',
  ];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NativePluginRegistry.I.clearForTest();
    registerAiMedia();
    for (final name in pluginNames) {
      final cap = NativePluginRegistry.I.capabilityFor(name);
      if (cap != null && cap.configFields.isNotEmpty) {
        await NativePluginConfigStore.I.clear(
          pluginName: name,
          fields: cap.configFields,
        );
      }
    }
    NativePluginRegistry.I.clearForTest();
  });

  tearDown(() {
    NativePluginRegistry.I.clearForTest();
  });

  Future<NativePluginCapability> capFor(
    String pluginName,
    Future<http.Response> Function(http.Request) onRequest, {
    Map<String, String> values = const {},
  }) async {
    final client = MockClient((request) async => onRequest(request));
    late final NativePluginCapability cap;
    switch (pluginName) {
      case 'OpenAI DALL·E MCP':
        cap = DalleCapability(client: client);
      case 'ElevenLabs MCP':
        cap = ElevenLabsCapability(client: client);
      case 'Notion Sync':
        cap = NotionSyncCapability(client: client);
      case 'Google Drive MCP':
        cap = GoogleDriveCapability(client: client);
      case 'Stripe MCP':
        cap = StripeCapability(client: client);
      case 'YouTube Summarizer':
        cap = YouTubeSummarizerCapability(client: client);
      case 'LangChain MCP':
        cap = LangChainMcpCapability();
      case 'AutoGPT Bridge':
        cap = AutoGptBridgeCapability();
      default:
        throw ArgumentError('No aimedia capability: $pluginName');
    }
    if (values.isNotEmpty) await cap.configure(values);
    return cap;
  }

  group('descriptors', () {
    test('batch exposes the 6 REST service descriptors with spec-exact names', () {
      final names = aiMediaDescriptors.map((d) => d.pluginName).toList();
      expect(names, contains('OpenAI DALL·E MCP'));
      expect(names, contains('ElevenLabs MCP'));
      expect(names, contains('Notion Sync'));
      expect(names, contains('Google Drive MCP'));
      expect(names, contains('Stripe MCP'));
      expect(names, contains('YouTube Summarizer'));
      expect(aiMediaDescriptors, hasLength(6));
    });

    test('auth schemes match spec §4.5', () {
      final byName = {for (final d in aiMediaDescriptors) d.pluginName: d};
      expect(byName['OpenAI DALL·E MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['OpenAI DALL·E MCP']!.authPrefix, 'Bearer ');
      expect(byName['ElevenLabs MCP']!.auth, RestAuthKind.apiKeyHeader);
      expect(byName['ElevenLabs MCP']!.authHeader, 'xi-api-key');
      expect(byName['Notion Sync']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Notion Sync']!.authPrefix, 'Bearer ');
      expect(byName['Google Drive MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Google Drive MCP']!.authPrefix, 'Bearer ');
      expect(byName['Stripe MCP']!.auth, RestAuthKind.bearerHeader);
      expect(byName['Stripe MCP']!.authPrefix, 'Bearer ');
      expect(byName['YouTube Summarizer']!.auth, RestAuthKind.none);
    });

    test('tool rosters match spec §4.5', () {
      Iterable<String> toolsOf(String name) => aiMediaDescriptors
          .firstWhere((d) => d.pluginName == name)
          .tools
          .map((t) => t.name);

      expect(toolsOf('OpenAI DALL·E MCP'), containsAll(['generate_image']));
      expect(toolsOf('ElevenLabs MCP'), containsAll(['list_voices', 'speak']));
      expect(
        toolsOf('Notion Sync'),
        containsAll(['search', 'query_database', 'create_page', 'get_page']),
      );
      expect(
        toolsOf('Google Drive MCP'),
        containsAll(['search', 'get_file', 'download_text', 'upload_text']),
      );
      expect(
        toolsOf('Stripe MCP'),
        containsAll([
          'list_customers',
          'list_invoices',
          'list_charges',
          'create_invoice',
        ]),
      );
      expect(toolsOf('YouTube Summarizer'), containsAll(['get_details']));

      final lc = LangChainMcpCapability();
      expect(lc.tools.map((t) => t.name), containsAll(['chain_design', 'agent_plan']));

      final agpt = AutoGptBridgeCapability();
      expect(agpt.tools.map((t) => t.name), containsAll(['decompose']));
    });
  });

  group('OpenAI DALL·E MCP', () {
    test('generate_image POSTs to /v1/images/generations with Bearer and returns image URL', () async {
      http.Request? seen;
      final cap = await capFor(
        'OpenAI DALL·E MCP',
        (request) async {
          seen = request;
          return http.Response(
            jsonEncode({
              'data': [
                {'url': 'https://images.openai.com/test-img.png'}
              ]
            }),
            200,
          );
        },
        values: {'openai_api_key': 'sk-openai-test'},
      );

      final out = await cap.callTool('generate_image', {
        'prompt': 'A golden retriever playing guitar',
        'size': '512x512',
      });

      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://api.openai.com/v1/images/generations');
      expect(seen!.headers['Authorization'], 'Bearer sk-openai-test');
      expect(seen!.headers['Content-Type'], contains('application/json'));
      final reqBody = jsonDecode(seen!.body) as Map;
      expect(reqBody['prompt'], 'A golden retriever playing guitar');
      expect(reqBody['size'], '512x512');
      expect(out, 'Image URL: https://images.openai.com/test-img.png');
    });

    test('generate_image requires prompt', () async {
      final cap = await capFor(
        'OpenAI DALL·E MCP',
        (_) async => http.Response('{}', 200),
        values: {'openai_api_key': 'sk-openai-test'},
      );
      expect(
        () => cap.callTool('generate_image', {}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('generate_image missing credentials gates honestly', () async {
      final cap = await capFor(
        'OpenAI DALL·E MCP',
        (_) async => http.Response('{}', 200),
      );
      final out = await cap.callTool('generate_image', {'prompt': 'cats'});
      expect(out, contains('Configure OpenAI API key first'));
      expect(out, contains('openai_api_key'));
    });

    test('non-2xx response passes through verbatim', () async {
      final cap = await capFor(
        'OpenAI DALL·E MCP',
        (_) async => http.Response('{"error":{"message":"Quota exceeded"}}', 429),
        values: {'openai_api_key': 'sk-openai-test'},
      );
      final out = await cap.callTool('generate_image', {'prompt': 'sunset'});
      expect(out, contains('HTTP 429'));
      expect(out, contains('Quota exceeded'));
    });
  });

  group('ElevenLabs MCP', () {
    test('list_voices GETs /v1/voices with xi-api-key', () async {
      http.Request? seen;
      final cap = await capFor(
        'ElevenLabs MCP',
        (request) async {
          seen = request;
          return http.Response('{"voices":[{"voice_id":"voice1"}]}', 200);
        },
        values: {'api_key': 'el-key-123'},
      );

      final out = await cap.callTool('list_voices', {});
      expect(seen!.method, 'GET');
      expect(seen!.url.toString(), 'https://api.elevenlabs.io/v1/voices');
      expect(seen!.headers['xi-api-key'], 'el-key-123');
      expect(out, contains('voice1'));
    });

    test('speak POSTs text-to-speech, returns base64 and byte count', () async {
      http.Request? seen;
      final fakeBytes = utf8.encode('RIFF....WAVEfmt');
      final cap = await capFor(
        'ElevenLabs MCP',
        (request) async {
          seen = request;
          return http.Response.bytes(fakeBytes, 200);
        },
        values: {'api_key': 'el-key-123'},
      );

      final out = await cap.callTool('speak', {
        'text': 'Hello world',
        'voice_id': 'custom-voice',
      });

      expect(seen!.method, 'POST');
      expect(
        seen!.url.toString(),
        'https://api.elevenlabs.io/v1/text-to-speech/custom-voice',
      );
      expect(seen!.headers['xi-api-key'], 'el-key-123');
      final body = jsonDecode(seen!.body) as Map;
      expect(body['text'], 'Hello world');
      expect(out, contains('Synthesized ${fakeBytes.length} bytes of audio'));
      expect(out, contains('Base64: ${base64Encode(fakeBytes)}'));
    });

    test('speak enforces 2000-character cap with ArgumentError', () async {
      final cap = await capFor(
        'ElevenLabs MCP',
        (_) async => http.Response('', 200),
        values: {'api_key': 'el-key-123'},
      );

      final longText = 'A' * 2001;
      expect(
        () => cap.callTool('speak', {'text': longText}),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('2000 characters'),
        )),
      );
    });

    test('speak accepts exactly 2000 characters', () async {
      http.Request? seen;
      final cap = await capFor(
        'ElevenLabs MCP',
        (req) async {
          seen = req;
          return http.Response.bytes([1, 2, 3], 200);
        },
        values: {'api_key': 'el-key-123'},
      );

      final maxText = 'B' * 2000;
      final out = await cap.callTool('speak', {'text': maxText});
      expect(seen, isNotNull);
      expect(out, contains('Synthesized 3 bytes of audio'));
    });

    test('missing api_key gates honestly', () async {
      final cap = await capFor(
        'ElevenLabs MCP',
        (_) async => http.Response('{}', 200),
      );
      final out = await cap.callTool('list_voices', {});
      expect(out, contains('Configure ElevenLabs API key first'));
    });
  });

  group('Notion Sync', () {
    test('includes Notion-Version: 2022-06-28 and Bearer on all requests', () async {
      http.Request? seen;
      final cap = await capFor(
        'Notion Sync',
        (req) async {
          seen = req;
          return http.Response('{"results":[]}', 200);
        },
        values: {'api_key': 'secret_notion_123'},
      );

      await cap.callTool('search', {'query': 'docs'});
      expect(seen!.headers['Authorization'], 'Bearer secret_notion_123');
      expect(seen!.headers['Notion-Version'], '2022-06-28');
    });

    test('search POSTs to /search', () async {
      http.Request? seen;
      final cap = await capFor(
        'Notion Sync',
        (req) async {
          seen = req;
          return http.Response('{"results":[]}', 200);
        },
        values: {'api_key': 'secret_notion_123'},
      );

      final out = await cap.callTool('search', {'query': 'project plan'});
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://api.notion.com/v1/search');
      final body = jsonDecode(seen!.body) as Map;
      expect(body['query'], 'project plan');
      expect(out, contains('results'));
    });

    test('query_database POSTs filter to /databases/{db_id}/query', () async {
      http.Request? seen;
      final cap = await capFor(
        'Notion Sync',
        (req) async {
          seen = req;
          return http.Response('{"results":[{"id":"page-1"}]}', 200);
        },
        values: {'api_key': 'secret_notion_123'},
      );

      final out = await cap.callTool('query_database', {
        'db_id': 'db-xyz',
        'filter_json': '{"property":"Status","select":{"equals":"Done"}}',
      });
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://api.notion.com/v1/databases/db-xyz/query');
      final body = jsonDecode(seen!.body) as Map;
      expect(body['property'], 'Status');
      expect(out, contains('page-1'));
    });

    test('create_page constructs parent, title, and rich_text children', () async {
      http.Request? seen;
      final cap = await capFor(
        'Notion Sync',
        (req) async {
          seen = req;
          return http.Response('{"id":"page-new"}', 200);
        },
        values: {'api_key': 'secret_notion_123'},
      );

      final out = await cap.callTool('create_page', {
        'parent_id': 'db-parent-1',
        'title': 'Roadmap Q3',
        'text': 'Detailed roadmap contents here.',
      });
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://api.notion.com/v1/pages');
      final body = jsonDecode(seen!.body) as Map;
      expect(body['parent']['database_id'], 'db-parent-1');
      expect(body['properties']['title']['title'][0]['text']['content'], 'Roadmap Q3');
      expect(body['children'][0]['paragraph']['rich_text'][0]['text']['content'], 'Detailed roadmap contents here.');
      expect(out, contains('page-new'));
    });

    test('get_page GETs /v1/pages/{id}', () async {
      http.Request? seen;
      final cap = await capFor(
        'Notion Sync',
        (req) async {
          seen = req;
          return http.Response('{"id":"page-999"}', 200);
        },
        values: {'api_key': 'secret_notion_123'},
      );

      final out = await cap.callTool('get_page', {'id': 'page-999'});
      expect(seen!.method, 'GET');
      expect(seen!.url.toString(), 'https://api.notion.com/v1/pages/page-999');
      expect(out, contains('page-999'));
    });

    test('missing credential gates honestly', () async {
      final cap = await capFor(
        'Notion Sync',
        (_) async => http.Response('{}', 200),
      );
      final out = await cap.callTool('search', {});
      expect(out, contains('Configure Notion API key first'));
    });
  });

  group('Google Drive MCP', () {
    test('search GETs /files with query params', () async {
      http.Request? seen;
      final cap = await capFor(
        'Google Drive MCP',
        (req) async {
          seen = req;
          return http.Response('{"files":[]}', 200);
        },
        values: {'access_token': 'oauth-token-xyz'},
      );

      final out = await cap.callTool('search', {'query': "name contains 'specs'", 'limit': '15'});
      expect(seen!.method, 'GET');
      expect(seen!.url.host, 'www.googleapis.com');
      expect(seen!.url.path, '/drive/v3/files');
      expect(seen!.url.queryParameters['q'], "name contains 'specs'");
      expect(seen!.url.queryParameters['pageSize'], '15');
      expect(seen!.headers['Authorization'], 'Bearer oauth-token-xyz');
      expect(out, contains('files'));
    });

    test('get_file GETs /files/{id}', () async {
      http.Request? seen;
      final cap = await capFor(
        'Google Drive MCP',
        (req) async {
          seen = req;
          return http.Response('{"id":"file-100","name":"design.pdf"}', 200);
        },
        values: {'access_token': 'oauth-token-xyz'},
      );

      final out = await cap.callTool('get_file', {'id': 'file-100'});
      expect(seen!.method, 'GET');
      expect(seen!.url.path, '/drive/v3/files/file-100');
      expect(seen!.headers['Authorization'], 'Bearer oauth-token-xyz');
      expect(out, contains('file-100'));
    });

    test('download_text GETs /files/{id}?alt=media', () async {
      http.Request? seen;
      final cap = await capFor(
        'Google Drive MCP',
        (req) async {
          seen = req;
          return http.Response('Hello from file content', 200);
        },
        values: {'access_token': 'oauth-token-xyz'},
      );

      final out = await cap.callTool('download_text', {'id': 'file-100'});
      expect(seen!.method, 'GET');
      expect(seen!.url.path, '/drive/v3/files/file-100');
      expect(seen!.url.queryParameters['alt'], 'media');
      expect(out, 'Hello from file content');
    });

    test('upload_text builds valid multipart/related body and sends to upload endpoint', () async {
      http.Request? seen;
      final cap = await capFor(
        'Google Drive MCP',
        (req) async {
          seen = req;
          return http.Response('{"id":"new-uploaded-file-id"}', 200);
        },
        values: {'access_token': 'oauth-token-xyz'},
      );

      final out = await cap.callTool('upload_text', {
        'name': 'notes.txt',
        'text': 'Meeting notes content here',
        'folder_id': 'folder-555',
      });

      expect(seen!.method, 'POST');
      expect(seen!.url.host, 'www.googleapis.com');
      expect(seen!.url.path, '/upload/drive/v3/files');
      expect(seen!.url.queryParameters['uploadType'], 'multipart');
      expect(seen!.headers['Authorization'], 'Bearer oauth-token-xyz');
      expect(seen!.headers['Content-Type'], contains('multipart/related; boundary='));

      final body = seen!.body;
      expect(body, contains('Content-Type: application/json; charset=UTF-8'));
      expect(body, contains('"name":"notes.txt"'));
      expect(body, contains('"parents":["folder-555"]'));
      expect(body, contains('Content-Type: text/plain'));
      expect(body, contains('Meeting notes content here'));
      expect(out, contains('new-uploaded-file-id'));
    });

    test('missing access_token gates honestly', () async {
      final cap = await capFor(
        'Google Drive MCP',
        (_) async => http.Response('{}', 200),
      );
      final out = await cap.callTool('search', {});
      expect(out, contains('Configure Google OAuth access token first'));
    });
  });

  group('Stripe MCP', () {
    test('list_customers GETs /v1/customers with Bearer', () async {
      http.Request? seen;
      final cap = await capFor(
        'Stripe MCP',
        (req) async {
          seen = req;
          return http.Response('{"data":[{"id":"cus_123"}]}', 200);
        },
        values: {'secret_key': 'sk_test_stripe'},
      );

      final out = await cap.callTool('list_customers', {'limit': 5});
      expect(seen!.method, 'GET');
      expect(seen!.url.toString(), 'https://api.stripe.com/v1/customers?limit=5');
      expect(seen!.headers['Authorization'], 'Bearer sk_test_stripe');
      expect(out, contains('cus_123'));
    });

    test('list_invoices GETs /v1/invoices', () async {
      http.Request? seen;
      final cap = await capFor(
        'Stripe MCP',
        (req) async {
          seen = req;
          return http.Response('{"data":[{"id":"in_123"}]}', 200);
        },
        values: {'secret_key': 'sk_test_stripe'},
      );

      final out = await cap.callTool('list_invoices', {});
      expect(seen!.method, 'GET');
      expect(seen!.url.path, '/v1/invoices');
      expect(out, contains('in_123'));
    });

    test('list_charges GETs /v1/charges', () async {
      http.Request? seen;
      final cap = await capFor(
        'Stripe MCP',
        (req) async {
          seen = req;
          return http.Response('{"data":[{"id":"ch_123"}]}', 200);
        },
        values: {'secret_key': 'sk_test_stripe'},
      );

      final out = await cap.callTool('list_charges', {});
      expect(seen!.method, 'GET');
      expect(seen!.url.path, '/v1/charges');
      expect(out, contains('ch_123'));
    });

    test('create_invoice encodes form body correctly (application/x-www-form-urlencoded)', () async {
      http.Request? seen;
      final cap = await capFor(
        'Stripe MCP',
        (req) async {
          seen = req;
          return http.Response('{"id":"in_new","customer":"cus_abc"}', 200);
        },
        values: {'secret_key': 'sk_test_stripe'},
      );

      final out = await cap.callTool('create_invoice', {
        'customer_id': 'cus_abc',
        'description': 'Dev services',
        'amount_cents': 5000,
        'currency': 'eur',
      });

      expect(seen!.method, 'POST');
      expect(seen!.url.path, '/v1/invoices');
      expect(seen!.headers['Authorization'], 'Bearer sk_test_stripe');
      expect(seen!.headers['content-type'], contains('application/x-www-form-urlencoded'));

      final parsedBody = Uri.splitQueryString(seen!.body);
      expect(parsedBody['customer'], 'cus_abc');
      expect(parsedBody['description'], 'Dev services');
      expect(parsedBody['amount'], '5000');
      expect(parsedBody['currency'], 'eur');
      expect(out, contains('in_new'));
    });

    test('missing secret_key gates honestly', () async {
      final cap = await capFor(
        'Stripe MCP',
        (_) async => http.Response('{}', 200),
      );
      final out = await cap.callTool('list_customers', {});
      expect(out, contains('Configure Stripe secret key first'));
    });
  });

  group('YouTube Summarizer', () {
    test('get_details queries oEmbed without auth and returns metadata with honesty notice', () async {
      http.Request? seen;
      final cap = await capFor(
        'YouTube Summarizer',
        (req) async {
          seen = req;
          return http.Response(
            jsonEncode({
              'title': 'Flutter in Production',
              'author_name': 'Tech Channel',
              'description': 'A detailed talk on building robust Flutter applications.',
            }),
            200,
          );
        },
      );

      final out = await cap.callTool('get_details', {'url': 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'});
      expect(seen!.method, 'GET');
      expect(seen!.url.host, 'www.youtube.com');
      expect(seen!.url.path, '/oembed');
      expect(seen!.url.queryParameters['url'], 'https://www.youtube.com/watch?v=dQw4w9WgXcQ');
      expect(seen!.url.queryParameters['format'], 'json');
      expect(seen!.headers['Authorization'], isNull);

      expect(out, contains('Title: Flutter in Production'));
      expect(out, contains('Author: Tech Channel'));
      expect(out, contains('Description:\nA detailed talk on building robust Flutter applications.'));
      expect(out, contains('Notice: No captions track available via oEmbed'));
    });

    test('get_details handles thin description honestly', () async {
      final cap = await capFor(
        'YouTube Summarizer',
        (_) async => http.Response(
          jsonEncode({
            'title': 'Silent Video',
            'author_name': 'Artist',
          }),
          200,
        ),
      );

      final out = await cap.callTool('get_details', {'url': 'https://www.youtube.com/watch?v=123'});
      expect(out, contains('Title: Silent Video'));
      expect(out, contains('Author: Artist'));
      expect(out, contains('Description: (none provided)'));
      expect(out, contains('Notice: No captions track available via oEmbed'));
    });

    test('get_details requires url', () async {
      final cap = await capFor(
        'YouTube Summarizer',
        (_) async => http.Response('{}', 200),
      );
      expect(
        () => cap.callTool('get_details', {}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('LangChain MCP (NativePromptCapability)', () {
    final cap = LangChainMcpCapability();

    test('taskSystemPrompt is defined', () {
      expect(cap.taskSystemPrompt, contains('LangChain'));
    });

    test('chain_design builds prompt with LCEL blueprint instructions', () {
      final prompt = cap.buildPrompt('chain_design', {
        'task': 'Extract structured entities from emails and store in SQL',
      });
      expect(prompt, contains('Design an LCEL blueprint'));
      expect(prompt, contains('Extract structured entities from emails'));
    });

    test('agent_plan builds prompt with agent/tools instructions', () {
      final prompt = cap.buildPrompt('agent_plan', {
        'goal': 'Autonomous research assistant for medical papers',
      });
      expect(prompt, contains('Create a detailed agent plan'));
      expect(prompt, contains('Autonomous research assistant for medical papers'));
    });

    test('callTool returns prompt-runner direction', () async {
      final res = await cap.callTool('chain_design', {'task': 'foo'});
      expect(res, contains('runs its tools through the agent'));
    });
  });

  group('AutoGPT Bridge (NativePromptCapability)', () {
    final cap = AutoGptBridgeCapability();

    test('taskSystemPrompt is defined', () {
      expect(cap.taskSystemPrompt, contains('multi-agent'));
    });

    test('decompose builds prompt with sub-agent delegation plan', () {
      final prompt = cap.buildPrompt('decompose', {
        'goal': 'Build and deploy a full-stack e-commerce store',
      });
      expect(prompt, contains('Decompose this goal into a structured sub-agent delegation plan'));
      expect(prompt, contains('Build and deploy a full-stack e-commerce store'));
    });

    test('callTool returns prompt-runner direction', () async {
      final res = await cap.callTool('decompose', {'goal': 'foo'});
      expect(res, contains('runs its tools through the agent'));
    });
  });

  group('Roster halves and integration', () {
    test('roster half: plugin__openai_dall_e_mcp__generate_image resolves', () {
      registerAiMedia();
      const canonical = 'plugin__openai_dall_e_mcp__generate_image';
      final slug = canonical.substring('plugin__'.length).split('__').first;
      final tool = canonical.split('__').last;
      final cap = NativePluginRegistry.I.capabilityForSlug(slug);
      expect(cap, isNotNull);
      expect(cap!.pluginName, 'OpenAI DALL·E MCP');
      expect(cap.tools.map((t) => t.name), contains(tool));
    });

    test('roster half: plugin__stripe_mcp__create_invoice resolves', () {
      registerAiMedia();
      const canonical = 'plugin__stripe_mcp__create_invoice';
      final slug = canonical.substring('plugin__'.length).split('__').first;
      final tool = canonical.split('__').last;
      final cap = NativePluginRegistry.I.capabilityForSlug(slug);
      expect(cap, isNotNull);
      expect(cap!.pluginName, 'Stripe MCP');
      expect(cap.tools.map((t) => t.name), contains(tool));
    });

    test('roster half: plugin__youtube_summarizer__get_details resolves', () {
      registerAiMedia();
      const canonical = 'plugin__youtube_summarizer__get_details';
      final slug = canonical.substring('plugin__'.length).split('__').first;
      final tool = canonical.split('__').last;
      final cap = NativePluginRegistry.I.capabilityForSlug(slug);
      expect(cap, isNotNull);
      expect(cap!.pluginName, 'YouTube Summarizer');
      expect(cap.tools.map((t) => t.name), contains(tool));
    });

    test('roster half: plugin__autogpt_bridge__decompose resolves', () {
      registerAiMedia();
      const canonical = 'plugin__autogpt_bridge__decompose';
      final slug = canonical.substring('plugin__'.length).split('__').first;
      final tool = canonical.split('__').last;
      final cap = NativePluginRegistry.I.capabilityForSlug(slug);
      expect(cap, isNotNull);
      expect(cap!.pluginName, 'AutoGPT Bridge');
      expect(cap.tools.map((t) => t.name), contains(tool));
    });
  });
}
