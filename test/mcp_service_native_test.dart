import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/native_mcp.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeNativeHandler implements NativeMcpHandler {
  bool initialized = false;
  bool disposed = false;

  @override
  Future<Map<String, dynamic>> initialize(Map<String, dynamic> params) async {
    initialized = true;
    return {
      'protocolVersion': '2024-11-05',
      'capabilities': {'tools': {}},
      'serverInfo': {'name': 'test-native', 'version': '1.0.0'},
    };
  }

  @override
  Future<List<McpToolDef>> listTools() async {
    return [
      McpToolDef(
        name: 'echo_test',
        description: 'Echoes back test arguments',
        inputSchema: {
          'type': 'object',
          'properties': {
            'text': {'type': 'string'},
          },
        },
      ),
      McpToolDef(
        name: 'fail_tool',
        description: 'Fails intentionally',
        inputSchema: {'type': 'object'},
      ),
    ];
  }

  @override
  Future<McpRpcResult> callTool(String toolName, Map<String, dynamic> args) async {
    if (toolName == 'echo_test') {
      return McpRpcResult.ok({
        'content': [
          {'type': 'text', 'text': 'echo: ${args['text']}'},
        ],
        'isError': false,
      });
    }
    if (toolName == 'fail_tool') {
      return const McpRpcResult.error('intentional test failure');
    }
    return McpRpcResult.error('unknown tool $toolName');
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    McpService.I.clearNativeHandlers();
  });

  tearDown(() async {
    await McpService.I.disconnectAll();
    McpService.I.clearNativeHandlers();
    AppState.resetTestInstance();
  });

  group('McpService Native Transport', () {
    test('connects to custom native handler, discovers tools, calls tool, and disconnects', () async {
      final fakeHandler = _FakeNativeHandler();
      McpService.I.registerNativeHandler('custom-native', (_) => fakeHandler);

      final server = McpServer(
        name: 'custom-native',
        author: 'test',
        description: 'Custom native handler for test',
        category: 'Test',
        command: '',
        args: const [],
        transport: 'native',
      );

      final outcome = await McpService.I.connectOutcome(
        server,
        handshakeBudget: const Duration(seconds: 5),
      );

      expect(outcome.kind, equals(McpConnectOutcomeKind.ready));
      expect(fakeHandler.initialized, isTrue);
      expect(McpService.I.isConnected(server.canonicalId), isTrue);

      final tools = McpService.I.connectedTools[server.canonicalId] ?? [];
      expect(tools.any((t) => t.name == 'echo_test'), isTrue);

      // Call tool successfully
      final res = await McpService.I.callTool(
        server.canonicalId,
        'echo_test',
        {'text': 'hello native'},
      );
      expect(res, equals('echo: hello native'));

      // Call tool that returns error
      final errRes = await McpService.I.callTool(
        server.canonicalId,
        'fail_tool',
        {},
      );
      expect(errRes, contains('MCP error: intentional test failure'));

      // Disconnect
      await McpService.I.disconnect(server.canonicalId);
      expect(McpService.I.isConnected(server.canonicalId), isFalse);
      expect(fakeHandler.disposed, isTrue);
    });

    test('connects to built-in native handlers: filesystem, fetch, memory', () async {
      final tempDir = Directory.systemTemp.createTempSync('mcp_fs_test_');
      addTearDown(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      // 1. Filesystem
      final fsServer = McpServer(
        name: 'Filesystem',
        author: 'modelcontextprotocol',
        description: 'Filesystem',
        category: 'Official',
        command: '',
        args: const [],
        transport: 'native',
        cwd: tempDir.path,
      );

      final fsOutcome = await McpService.I.connectOutcome(
        fsServer,
        handshakeBudget: const Duration(seconds: 5),
      );
      expect(fsOutcome.kind, equals(McpConnectOutcomeKind.ready));
      expect(McpService.I.isConnected('Filesystem'), isTrue);

      // Write a file through callTool
      final writeRes = await McpService.I.callTool(
        'Filesystem',
        'write_file',
        {'path': 'hello.txt', 'content': 'native mcp content'},
      );
      expect(writeRes, contains('File written successfully'));
      expect(File('${tempDir.path}/hello.txt').readAsStringSync(), equals('native mcp content'));

      await McpService.I.disconnect('Filesystem');

      // 2. Fetch
      final mockClient = MockClient((req) async {
        return http.Response('<html><body><h1>Mock Title</h1></body></html>', 200,
            headers: {'content-type': 'text/html'});
      });
      McpService.I.httpClientForTest = mockClient;

      final fetchServer = McpServer(
        name: 'Fetch',
        author: 'modelcontextprotocol',
        description: 'Fetch',
        category: 'Official',
        command: '',
        args: const [],
        transport: 'native',
      );

      final fetchOutcome = await McpService.I.connectOutcome(
        fetchServer,
        handshakeBudget: const Duration(seconds: 5),
      );
      expect(fetchOutcome.kind, equals(McpConnectOutcomeKind.ready));
      expect(McpService.I.isConnected('Fetch'), isTrue);

      final fetchRes = await McpService.I.callTool(
        'Fetch',
        'fetch',
        {'url': 'https://example.com/test'},
      );
      expect(fetchRes, contains('Mock Title'));

      await McpService.I.disconnect('Fetch');

      // 3. Memory
      final memoryFile = File('${tempDir.path}/memory.json');
      McpService.memoryStoragePathOverrideForTest = memoryFile.path;

      final memoryServer = McpServer(
        name: 'Memory',
        author: 'modelcontextprotocol',
        description: 'Memory',
        category: 'Official',
        command: '',
        args: const [],
        transport: 'native',
      );

      final memOutcome = await McpService.I.connectOutcome(
        memoryServer,
        handshakeBudget: const Duration(seconds: 5),
      );
      expect(memOutcome.kind, equals(McpConnectOutcomeKind.ready));
      expect(McpService.I.isConnected('Memory'), isTrue);

      final memRes = await McpService.I.callTool(
        'Memory',
        'create_entities',
        {
          'entities': [
            {
              'name': 'NativeMCP',
              'entityType': 'Architecture',
              'observations': ['Runs in-process inside Ovid']
            }
          ]
        },
      );
      expect(memRes, contains('NativeMCP'));

      await McpService.I.disconnect('Memory');
    });

    test('GitHub native handler auto-injects GitHubService.I.token or reports needsSetup', () async {
      final ghServer = McpServer(
        name: 'GitHub',
        author: 'modelcontextprotocol',
        description: 'GitHub',
        category: 'Official',
        command: '',
        args: const [],
        transport: 'native',
        envHint: 'GITHUB_TOKEN',
      );

      // 1. When not signed in and no env token
      final outcomeNoAuth = await McpService.I.connectOutcome(
        ghServer,
        handshakeBudget: const Duration(seconds: 5),
      );
      expect(outcomeNoAuth.kind, equals(McpConnectOutcomeKind.needsSetup));
      expect(outcomeNoAuth.reason, contains('Please log in to GitHub or set GITHUB_TOKEN'));

      // 2. When signed in via GitHubService
      final mockClient = MockClient((req) async {
        if (req.url.path == '/users/testuser' || req.url.path == '/user') {
          return http.Response(
            jsonEncode({'login': 'testuser', 'id': 12345}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });
      McpService.I.httpClientForTest = mockClient;

      // Save token in GitHubService (mocked via secure storage)
      FlutterSecureStorage.setMockInitialValues({'ovid_github_token': 'gho_secret_test_token'});
      await GitHubService.I.initialize();
      expect(GitHubService.I.isLoggedIn, isTrue);

      final outcomeAuth = await McpService.I.connectOutcome(
        ghServer,
        handshakeBudget: const Duration(seconds: 5),
      );
      expect(outcomeAuth.kind, equals(McpConnectOutcomeKind.ready));
      expect(McpService.I.isConnected('GitHub'), isTrue);

      final userRes = await McpService.I.callTool(
        'GitHub',
        'get_user',
        {'username': 'testuser'},
      );
      expect(userRes, contains('testuser'));

      await McpService.I.disconnect('GitHub');
    });
  });

  group('AppState Built-in Seed MCPs & Persistence', () {
    test('official seeds have native transport', () {
      final app = AppState.createForTest();
      final nativeSeeds = app.mcpServers.where((s) => s.transport == 'native').map((s) => s.name).toSet();

      expect(nativeSeeds, containsAll(['Filesystem', 'GitHub', 'Fetch', 'Memory']));

      final gh = app.mcpServers.firstWhere((s) => s.name == 'GitHub');
      expect(gh.transport, equals('native'));
      expect(gh.command, isEmpty);

      final fs = app.mcpServers.firstWhere((s) => s.name == 'Filesystem');
      expect(fs.transport, equals('native'));
      expect(fs.command, isEmpty);
    });

    test('removing built-in seed records removal in _kRemovedBuiltinSeeds and persists across reload', () async {
      SharedPreferences.setMockInitialValues({});
      final app = AppState.createForTest();
      expect(app.mcpServers.any((s) => s.name == 'Fetch'), isTrue);

      final fetchServer = app.mcpServers.firstWhere((s) => s.name == 'Fetch');
      await app.removeMcpServer(fetchServer);

      // Verify removed from memory
      expect(app.mcpServers.any((s) => s.name == 'Fetch'), isFalse);

      // Verify recorded in prefs
      final prefs = await SharedPreferences.getInstance();
      final removed = prefs.getStringList(AppState.kRemovedBuiltinSeeds);
      expect(removed, contains('Fetch'));

      // Create a new AppState and reload removed seeds
      final freshApp = AppState.createForTest();
      expect(freshApp.mcpServers.any((s) => s.name == 'Fetch'), isTrue); // initial seed has it
      await freshApp.reloadRemovedBuiltinSeedsForTest();
      expect(freshApp.mcpServers.any((s) => s.name == 'Fetch'), isFalse); // pruned!
    });
  });
}
