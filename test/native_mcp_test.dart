import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_mcp.dart';

void main() {
  group('NativeGitHubMcpHandler', () {
    test('initializes and lists tools', () async {
      final handler = NativeGitHubMcpHandler(token: 'test-token');
      final init = await handler.initialize({});
      expect(init['serverInfo']['name'], equals('github'));
      expect(init['capabilities']['tools'], isNotNull);

      final tools = await handler.listTools();
      final toolNames = tools.map((t) => t.name).toSet();
      expect(toolNames, containsAll([
        'search_repositories',
        'get_file_contents',
        'create_or_update_file',
        'create_issue',
        'list_issues',
        'get_issue',
        'add_issue_comment',
        'create_pull_request',
        'list_pull_requests',
        'fork_repository',
        'list_commits',
        'get_user',
      ]));
      await handler.dispose();
    });

    test('fails gracefully when no auth token is available', () async {
      final handler = NativeGitHubMcpHandler(tokenProvider: () => null);
      final res = await handler.callTool('get_user', {'username': 'octocat'});
      expect(res.isError, isTrue);
      expect(res.error, contains('Please log in to GitHub or set GITHUB_TOKEN'));
      await handler.dispose();
    });

    test('search_repositories dispatches GET query', () async {
      final mockClient = MockClient((req) async {
        expect(req.method, equals('GET'));
        expect(req.url.path, equals('/search/repositories'));
        expect(req.url.queryParameters['q'], equals('flutter'));
        expect(req.headers['authorization'], equals('Bearer test-token'));
        return http.Response(
          jsonEncode({
            'total_count': 1,
            'items': [
              {'name': 'flutter', 'full_name': 'flutter/flutter'}
            ]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final handler = NativeGitHubMcpHandler(
        token: 'test-token',
        httpClient: mockClient,
      );
      final res = await handler.callTool('search_repositories', {'query': 'flutter'});
      expect(res.isError, isFalse);
      final text = (res.value['content'] as List).first['text'] as String;
      expect(text, contains('flutter/flutter'));
      await handler.dispose();
    });

    test('get_file_contents decodes base64 content', () async {
      final mockClient = MockClient((req) async {
        expect(req.url.path, equals('/repos/owner/repo/contents/README.md'));
        return http.Response(
          jsonEncode({
            'name': 'README.md',
            'path': 'README.md',
            'sha': '12345',
            'size': 13,
            'encoding': 'base64',
            'content': base64Encode(utf8.encode('Hello, world!')),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final handler = NativeGitHubMcpHandler(
        token: 'test-token',
        httpClient: mockClient,
      );
      final res = await handler.callTool('get_file_contents', {
        'owner': 'owner',
        'repo': 'repo',
        'path': 'README.md',
      });
      expect(res.isError, isFalse);
      final text = (res.value['content'] as List).first['text'] as String;
      expect(text, contains('Hello, world!'));
      await handler.dispose();
    });

    test('create_or_update_file sends PUT with base64 encoded content', () async {
      final mockClient = MockClient((req) async {
        expect(req.method, equals('PUT'));
        expect(req.url.path, equals('/repos/owner/repo/contents/test.txt'));
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['message'], equals('Add test file'));
        expect(utf8.decode(base64Decode(body['content'] as String)), equals('File body content'));
        return http.Response(
          jsonEncode({'commit': {'sha': 'abc1234'}}),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final handler = NativeGitHubMcpHandler(
        token: 'test-token',
        httpClient: mockClient,
      );
      final res = await handler.callTool('create_or_update_file', {
        'owner': 'owner',
        'repo': 'repo',
        'path': 'test.txt',
        'content': 'File body content',
        'message': 'Add test file',
      });
      expect(res.isError, isFalse);
      await handler.dispose();
    });

    test('create_issue and add_issue_comment send POST requests', () async {
      int postCount = 0;
      final mockClient = MockClient((req) async {
        postCount++;
        if (req.url.path == '/repos/owner/repo/issues') {
          final body = jsonDecode(req.body);
          expect(body['title'], equals('Bug report'));
          return http.Response(jsonEncode({'number': 42, 'title': 'Bug report'}), 201);
        } else if (req.url.path == '/repos/owner/repo/issues/42/comments') {
          final body = jsonDecode(req.body);
          expect(body['body'], equals('Investigating'));
          return http.Response(jsonEncode({'id': 101, 'body': 'Investigating'}), 201);
        }
        return http.Response('Not found', 404);
      });

      final handler = NativeGitHubMcpHandler(
        token: 'test-token',
        httpClient: mockClient,
      );

      final issueRes = await handler.callTool('create_issue', {
        'owner': 'owner',
        'repo': 'repo',
        'title': 'Bug report',
      });
      expect(issueRes.isError, isFalse);
      expect((issueRes.value['content'] as List).first['text'], contains('"number":42'));

      final commentRes = await handler.callTool('add_issue_comment', {
        'owner': 'owner',
        'repo': 'repo',
        'issue_number': 42,
        'body': 'Investigating',
      });
      expect(commentRes.isError, isFalse);
      expect(postCount, equals(2));
      await handler.dispose();
    });
  });

  group('NativeFilesystemMcpHandler', () {
    late Directory tempDir;
    late NativeFilesystemMcpHandler handler;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('mcp_fs_test_');
      handler = NativeFilesystemMcpHandler(rootPath: tempDir.path);
    });

    tearDown(() async {
      await handler.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('initializes and lists tools', () async {
      final init = await handler.initialize({});
      expect(init['serverInfo']['name'], equals('filesystem'));

      final tools = await handler.listTools();
      final names = tools.map((t) => t.name).toSet();
      expect(names, containsAll([
        'read_file',
        'write_file',
        'list_directory',
        'get_file_info',
        'search_files',
        'delete_file',
      ]));
    });

    test('writes, reads, inspects, searches, and deletes files', () async {
      // 1. write_file
      final writeRes = await handler.callTool('write_file', {
        'path': 'sub/hello.txt',
        'content': 'Hello, MCP Filesystem!',
      });
      expect(writeRes.isError, isFalse);

      // 2. read_file
      final readRes = await handler.callTool('read_file', {
        'path': 'sub/hello.txt',
      });
      expect(readRes.isError, isFalse);
      expect((readRes.value['content'] as List).first['text'], equals('Hello, MCP Filesystem!'));

      // 3. get_file_info
      final infoRes = await handler.callTool('get_file_info', {
        'path': 'sub/hello.txt',
      });
      expect(infoRes.isError, isFalse);
      expect((infoRes.value['content'] as List).first['text'], contains('"isFile":true'));

      // 4. list_directory
      final listRes = await handler.callTool('list_directory', {
        'path': 'sub',
      });
      expect(listRes.isError, isFalse);
      expect((listRes.value['content'] as List).first['text'], contains('hello.txt'));

      // 5. search_files
      final searchRes = await handler.callTool('search_files', {
        'path': '.',
        'pattern': 'hello',
      });
      expect(searchRes.isError, isFalse);
      expect((searchRes.value['content'] as List).first['text'], contains('sub/hello.txt'));

      // 6. delete_file
      final deleteRes = await handler.callTool('delete_file', {
        'path': 'sub/hello.txt',
      });
      expect(deleteRes.isError, isFalse);

      // read after delete should fail
      final readAfterDelete = await handler.callTool('read_file', {
        'path': 'sub/hello.txt',
      });
      expect(readAfterDelete.isError, isTrue);
    });

    test('prevents path traversal outside rootPath', () async {
      final res = await handler.callTool('read_file', {
        'path': '../secret.txt',
      });
      expect(res.isError, isTrue);
      expect(res.error, contains('Access denied'));
    });
  });

  group('NativeFetchMcpHandler', () {
    test('initializes and lists tools', () async {
      final handler = NativeFetchMcpHandler();
      final init = await handler.initialize({});
      expect(init['serverInfo']['name'], equals('fetch'));

      final tools = await handler.listTools();
      expect(tools.map((t) => t.name), contains('fetch'));
      await handler.dispose();
    });

    test('fetches HTML and converts to clean markdown', () async {
      final mockClient = MockClient((req) async {
        expect(req.url.toString(), equals('https://example.com/page'));
        return http.Response(
          '<html><head><style>body { color: red; }</style></head>'
          '<body><h1>Title</h1><p>Check <a href="https://flutter.dev">Flutter</a>!</p>'
          '<script>alert("bad");</script>'
          '</body></html>',
          200,
          headers: {'content-type': 'text/html'},
        );
      });

      final handler = NativeFetchMcpHandler(httpClient: mockClient);
      final res = await handler.callTool('fetch', {'url': 'https://example.com/page'});
      expect(res.isError, isFalse);
      final text = (res.value['content'] as List).first['text'] as String;
      expect(text, contains('# Title'));
      expect(text, contains('[Flutter](https://flutter.dev)'));
      expect(text, isNot(contains('alert("bad")')));
      expect(text, isNot(contains('body { color: red; }')));
      await handler.dispose();
    });

    test('fetches raw content when raw is true', () async {
      final mockClient = MockClient((req) async {
        return http.Response('<h1>Raw HTML</h1>', 200);
      });

      final handler = NativeFetchMcpHandler(httpClient: mockClient);
      final res = await handler.callTool('fetch', {
        'url': 'https://example.com/raw',
        'raw': true,
      });
      expect(res.isError, isFalse);
      final text = (res.value['content'] as List).first['text'] as String;
      expect(text, equals('<h1>Raw HTML</h1>'));
      await handler.dispose();
    });

    test('truncates content when max_length is reached', () async {
      final mockClient = MockClient((req) async {
        return http.Response('<p>${'A' * 500}</p>', 200);
      });

      final handler = NativeFetchMcpHandler(httpClient: mockClient);
      final res = await handler.callTool('fetch', {
        'url': 'https://example.com/long',
        'max_length': 50,
      });
      expect(res.isError, isFalse);
      final text = (res.value['content'] as List).first['text'] as String;
      expect(text.length, lessThan(100));
      expect(text, contains('[truncated]'));
      await handler.dispose();
    });
  });

  group('NativeMemoryMcpHandler', () {
    late File tempFile;
    late NativeMemoryMcpHandler handler;

    setUp(() {
      final tempDir = Directory.systemTemp.createTempSync('mcp_memory_test_');
      tempFile = File('${tempDir.path}/memory.json');
      handler = NativeMemoryMcpHandler(storageFile: tempFile);
    });

    tearDown(() async {
      await handler.dispose();
      final dir = tempFile.parent;
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    });

    test('initializes and lists tools', () async {
      final init = await handler.initialize({});
      expect(init['serverInfo']['name'], equals('memory'));

      final tools = await handler.listTools();
      final names = tools.map((t) => t.name).toSet();
      expect(names, containsAll([
        'create_entities',
        'create_relations',
        'add_observations',
        'read_graph',
        'search_nodes',
        'open_nodes',
      ]));
    });

    test('creates entities, adds observations, creates relations, and queries graph', () async {
      // 1. create_entities
      final createRes = await handler.callTool('create_entities', {
        'entities': [
          {
            'name': 'Ovid',
            'entityType': 'App',
            'observations': ['AI super-app with built-in MCP'],
          },
          {
            'name': 'Dart',
            'entityType': 'Language',
            'observations': ['Client-optimized programming language'],
          }
        ],
      });
      expect(createRes.isError, isFalse);

      // 2. add_observations
      final addObsRes = await handler.callTool('add_observations', {
        'observations': [
          {
            'entityName': 'Ovid',
            'contents': ['Runs on Android and Linux'],
          }
        ],
      });
      expect(addObsRes.isError, isFalse);

      // 3. create_relations
      final relRes = await handler.callTool('create_relations', {
        'relations': [
          {
            'from': 'Ovid',
            'to': 'Dart',
            'relationType': 'written_in',
          }
        ],
      });
      expect(relRes.isError, isFalse);

      // 4. read_graph
      final readRes = await handler.callTool('read_graph', {});
      expect(readRes.isError, isFalse);
      final graphText = (readRes.value['content'] as List).first['text'] as String;
      final graph = jsonDecode(graphText) as Map<String, dynamic>;
      final entities = (graph['entities'] as List).cast<Map<String, dynamic>>();
      final relations = (graph['relations'] as List).cast<Map<String, dynamic>>();
      expect(entities.length, equals(2));
      expect(relations.length, equals(1));
      final ovid = entities.firstWhere((e) => e['name'] == 'Ovid');
      expect(ovid['observations'], contains('Runs on Android and Linux'));

      // 5. search_nodes
      final searchRes = await handler.callTool('search_nodes', {'query': 'Android'});
      expect(searchRes.isError, isFalse);
      final searchPayload = jsonDecode((searchRes.value['content'] as List).first['text']);
      expect((searchPayload['entities'] as List).any((e) => e['name'] == 'Ovid'), isTrue);

      // 6. open_nodes
      final openRes = await handler.callTool('open_nodes', {
        'names': ['Ovid']
      });
      expect(openRes.isError, isFalse);
      final openPayload = jsonDecode((openRes.value['content'] as List).first['text']);
      expect((openPayload['entities'] as List).length, equals(1));
      expect((openPayload['relations'] as List).length, equals(1));

      // 7. Test persistence across handler reload
      await handler.dispose();
      final newHandler = NativeMemoryMcpHandler(storageFile: tempFile);
      final reloadedRes = await newHandler.callTool('read_graph', {});
      final reloadedGraph = jsonDecode((reloadedRes.value['content'] as List).first['text']);
      expect((reloadedGraph['entities'] as List).length, equals(2));
      await newHandler.dispose();
    });
  });
}
