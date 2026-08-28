import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;

  setUpAll(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.I;
    await app.initialize();
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await GitHubService.I.signOut();
    app.sessions.clear();
    app.activeSessionId = null;
  });

  test(
    'agent sends newest history and streams into originating session',
    () async {
      final provider = app.providerById('ollama-local')!;
      final originalBaseUrl = provider.baseUrl;
      final originalModels = List<String>.of(provider.models);
      final originalSelectedModel = provider.selectedModel;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestReceived = Completer<List<Map<String, dynamic>>>();
      final releaseResponse = Completer<void>();

      final original = ChatSession(
        id: 'original',
        title: 'Original',
        providerId: provider.id,
        model: 'test-model',
        messages: [
          for (var i = 0; i < 15; i++)
            Message(
              role: i.isEven ? 'user' : 'assistant',
              content: 'message-$i',
            ),
        ],
      );
      final other = ChatSession(
        id: 'other',
        title: 'Other',
        model: 'Select a provider',
      );
      app.sessions.addAll([original, other]);
      app.activeSessionId = original.id;
      provider
        ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
        ..models = ['test-model'];

      final serverTask = server.first.then((request) async {
        final body = await utf8.decoder.bind(request).join();
        final payload = jsonDecode(body) as Map<String, dynamic>;
        requestReceived.complete(
          (payload['messages'] as List).cast<Map<String, dynamic>>(),
        );
        await releaseResponse.future;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType('text', 'event-stream')
          ..write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': 'response for original'},
                  'finish_reason': 'stop',
                },
              ],
            })}\n\n',
          );
        await request.response.close();
      });

      try {
        final run = AgentService.I.runTask('unused');
        final sentMessages = await requestReceived.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => throw StateError(
            'Agent did not send an HTTP request. Events: '
            '${AgentService.I.events.map((event) => event.text).join(' | ')}',
          ),
        );
        app.activeSessionId = other.id;
        releaseResponse.complete();
        await run.timeout(const Duration(seconds: 5));
        await serverTask.timeout(const Duration(seconds: 5));

        expect(sentMessages, hasLength(13));
        expect(sentMessages.first['role'], 'system');
        expect(sentMessages[1]['content'], 'message-3');
        expect(sentMessages.last['content'], 'message-14');
        expect(original.messages.last.content, 'response for original');
        expect(other.messages, isEmpty);
      } finally {
        provider
          ..baseUrl = originalBaseUrl
          ..models = originalModels
          ..selectedModel = originalSelectedModel;
        await server.close(force: true);
      }
    },
  );

  test('model reconciliation understands reasoning effort suffixes', () {
    final provider = app.providerById('openai')!;
    final originalModels = List<String>.of(provider.models);
    final originalSelectedModel = provider.selectedModel;
    final retained = ChatSession(
      id: 'retained',
      title: 'Retained',
      providerId: provider.id,
      model: 'gpt-5.2 · High',
    );
    final removed = ChatSession(
      id: 'removed',
      title: 'Removed',
      providerId: provider.id,
      model: 'removed-model · Low',
    );
    app.sessions.addAll([retained, removed]);
    app.activeSessionId = retained.id;
    provider
      ..models = ['gpt-5.2']
      ..selectedModel = 'gpt-5.2 · High';

    try {
      app.reconcileProviderModels(provider.id);

      expect(provider.selectedModel, 'gpt-5.2 · High');
      expect(retained.providerId, provider.id);
      expect(retained.model, 'gpt-5.2 · High');
      expect(removed.providerId, isNull);
      expect(removed.model, 'Select a provider');
    } finally {
      provider
        ..models = originalModels
        ..selectedModel = originalSelectedModel;
    }
  });

  test('provider API keys persist only in secure storage', () async {
    const storage = FlutterSecureStorage();
    final provider = app.providerById('openai')!;

    await app.updateProviderApiKey(provider, 'secret-key');
    expect(await storage.read(key: 'ovid_provider_key_openai'), 'secret-key');
    expect(provider.toPersistedJson(), isNot(contains('apiKey')));

    provider.apiKey = '';
    await app.loadProviderCredentials();
    expect(provider.apiKey, 'secret-key');

    await app.updateProviderApiKey(provider, '');
    expect(await storage.read(key: 'ovid_provider_key_openai'), isNull);
  });

  test('custom provider creation securely persists its API key', () async {
    const storage = FlutterSecureStorage();

    final error = await app.addCustomProvider(
      name: 'Test provider',
      baseUrl: 'https://example.com/v1',
      apiKey: 'custom-secret',
    );

    expect(error, isNull);
    expect(
      await storage.read(key: 'ovid_provider_key_custom-test-provider'),
      'custom-secret',
    );
    final provider = app.providerById('custom-test-provider')!;
    expect(provider.toPersistedJson(), isNot(contains('apiKey')));
    app.providers.remove(provider);
    await storage.delete(key: 'ovid_provider_key_custom-test-provider');
  });

  test('GitHub restores and deletes a securely stored token', () async {
    const storage = FlutterSecureStorage();
    await storage.write(key: 'ovid_github_token', value: 'stored-token');
    final client = MockClient((request) async {
      expect(request.url.path, '/user');
      expect(request.headers['Authorization'], 'Bearer stored-token');
      return http.Response(jsonEncode({'login': 'octocat'}), 200);
    });

    await GitHubService.I.initialize(client: client);
    expect(GitHubService.I.token, 'stored-token');
    expect(GitHubService.I.login, 'octocat');

    await GitHubService.I.signOut();
    expect(GitHubService.I.isLoggedIn, isFalse);
    expect(await storage.read(key: 'ovid_github_token'), isNull);
    client.close();
  });

  test(
    'GitHub keeps a stored token after a transient restore failure',
    () async {
      const storage = FlutterSecureStorage();
      await storage.write(key: 'ovid_github_token', value: 'stored-token');
      final client = MockClient((request) async {
        return http.Response('temporarily unavailable', 503);
      });

      await GitHubService.I.initialize(client: client);

      expect(GitHubService.I.isInitializing, isFalse);
      expect(GitHubService.I.isLoggedIn, isFalse);
      expect(await storage.read(key: 'ovid_github_token'), 'stored-token');
      client.close();
    },
  );

  test('GitHub deletes a stored token rejected as unauthorized', () async {
    const storage = FlutterSecureStorage();
    await storage.write(key: 'ovid_github_token', value: 'invalid-token');
    final client = MockClient((request) async {
      return http.Response('unauthorized', 401);
    });

    await GitHubService.I.initialize(client: client);

    expect(GitHubService.I.isInitializing, isFalse);
    expect(GitHubService.I.isLoggedIn, isFalse);
    expect(await storage.read(key: 'ovid_github_token'), isNull);
    client.close();
  });

  test('sign out invalidates an in-flight GitHub authorization', () async {
    final profileRequested = Completer<void>();
    final releaseProfile = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.path == '/login/oauth/access_token') {
        return http.Response(jsonEncode({'access_token': 'token'}), 200);
      }
      if (request.url.path == '/user') {
        profileRequested.complete();
        await releaseProfile.future;
        return http.Response(jsonEncode({'login': 'octocat'}), 200);
      }
      return http.Response('not found', 404);
    });

    final poll = GitHubService.I.pollForToken(
      deviceCode: 'device-code',
      intervalSec: 1,
      maxWait: const Duration(seconds: 5),
      client: client,
    );
    await profileRequested.future;
    final signOut = GitHubService.I.signOut();
    releaseProfile.complete();

    await expectLater(
      poll,
      throwsA(
        isA<GitHubAuthException>().having(
          (error) => error.code,
          'code',
          'cancelled',
        ),
      ),
    );
    expect(GitHubService.I.isLoggedIn, isFalse);
    expect(GitHubService.I.login, isNull);
    await signOut;
    expect(
      await const FlutterSecureStorage().read(key: 'ovid_github_token'),
      isNull,
    );
    client.close();
  });

  test('GitHub repository APIs fail before sending when signed out', () async {
    var requested = false;
    final client = MockClient((request) async {
      requested = true;
      return http.Response('unexpected request', 500);
    });

    await expectLater(
      GitHubService.I.listRepos(client: client),
      throwsA(
        isA<GitHubAuthException>().having(
          (error) => error.code,
          'code',
          'not_authenticated',
        ),
      ),
    );
    expect(requested, isFalse);
    client.close();
  });

  test('repository sync does not publish results after a rebind', () async {
    final contentRequested = Completer<void>();
    final releaseContent = Completer<void>();
    final client = MockClient((request) async {
      if (request.url.path.contains('/git/trees/')) {
        expect(request.url.path, contains('/repos/owner/first/'));
        return http.Response(
          jsonEncode({
            'tree': [
              {'type': 'blob', 'path': 'README.md'},
            ],
          }),
          200,
        );
      }
      expect(request.url.path, '/repos/owner/first/contents/README.md');
      contentRequested.complete();
      await releaseContent.future;
      return http.Response('first repository', 200);
    });

    RepoCache.I.bind('owner/first', 'token');
    final sync = RepoCache.I.sync(client: client);
    await contentRequested.future;
    RepoCache.I.bind('owner/second', 'token');
    releaseContent.complete();

    await expectLater(sync, throwsA(isA<StateError>()));
    expect(RepoCache.I.repoFull, 'owner/second');
    expect(RepoCache.I.files, isEmpty);
    client.close();
  });

  test('repository commit keeps requests on the captured binding', () async {
    final shaRequested = Completer<void>();
    final releaseSha = Completer<void>();
    var putRequested = false;
    final client = MockClient((request) async {
      expect(request.url.path, contains('/repos/owner/first/'));
      if (request.method == 'GET') {
        shaRequested.complete();
        await releaseSha.future;
        return http.Response(jsonEncode({'sha': 'old-sha'}), 200);
      }
      putRequested = true;
      return http.Response('{}', 200);
    });

    RepoCache.I.bind('owner/first', 'token');
    RepoCache.I.write('README.md', 'updated');
    final commit = RepoCache.I.commitAll('Update README', client: client);
    await shaRequested.future;
    RepoCache.I.bind('owner/second', 'token');
    releaseSha.complete();

    await expectLater(commit, throwsA(isA<StateError>()));
    expect(putRequested, isFalse);
    expect(RepoCache.I.repoFull, 'owner/second');
    expect(RepoCache.I.hasPending, isTrue);
    client.close();
  });

  test('agent HTTP fetch rejects oversized responses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverTask = server.first.then((request) async {
      request.response
        ..contentLength = 5
        ..add([1, 2, 3, 4, 5]);
      await request.response.close();
    });

    try {
      await expectLater(
        HttpShim.get(
          Uri.parse('http://${server.address.host}:${server.port}'),
          maxResponseBytes: 4,
        ),
        throwsA(isA<HttpException>()),
      );
      await serverTask.timeout(const Duration(seconds: 5));
    } finally {
      await server.close(force: true);
    }
  });

  test('agent HTTP fetch has a total response deadline', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverTask = server.first.then((request) async {
      request.response.headers.chunkedTransferEncoding = true;
      try {
        for (var i = 0; i < 10; i++) {
          request.response.add([i]);
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      } catch (_) {
        // The expected client timeout closes the response while it is streaming.
      } finally {
        await request.response.close();
      }
    });

    try {
      await expectLater(
        HttpShim.get(
          Uri.parse('http://${server.address.host}:${server.port}'),
          timeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await serverTask.timeout(const Duration(seconds: 5));
    } finally {
      await server.close(force: true);
    }
  });

  test(
    'agent HTTP fetch deadline covers headers and body in one window',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestReceived = Completer<void>();
      final serverTask = server.first.then((request) async {
        requestReceived.complete();
        // Hold response headers for 80ms, then trickle the body.
        await Future<void>.delayed(const Duration(milliseconds: 80));
        request.response.headers.chunkedTransferEncoding = true;
        try {
          for (var i = 0; i < 10; i++) {
            request.response.add([i]);
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
        } catch (_) {
          // Expected client timeout while streaming.
        } finally {
          await request.response.close();
        }
      });

      try {
        final stopwatch = Stopwatch()..start();
        await expectLater(
          HttpShim.get(
            Uri.parse('http://${server.address.host}:${server.port}'),
            timeout: const Duration(milliseconds: 150),
          ),
          throwsA(isA<TimeoutException>()),
        );
        stopwatch.stop();
        await requestReceived.future;
        // Headers (80ms) + trickle — the single 150ms window must cover both.
        expect(stopwatch.elapsedMilliseconds, lessThan(400));
        await serverTask.timeout(const Duration(seconds: 5));
      } finally {
        await server.close(force: true);
      }
    },
  );

  test('SSE splitter bounds a single oversized newline-free line', () async {
    final provider = app.providerById('ollama-local')!;
    final originalBaseUrl = provider.baseUrl;
    final originalModels = List<String>.of(provider.models);
    final originalSelectedModel = provider.selectedModel;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

    final session = ChatSession(
      id: 'sse-cap',
      title: 'SSE cap',
      providerId: provider.id,
      model: 'test-model',
      messages: [Message(role: 'user', content: 'hello')],
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;
    provider
      ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
      ..models = ['test-model'];

    final serverTask = server.first.then((request) async {
      request.response.headers.chunkedTransferEncoding = true;
      // One giant SSE line with no newline — 9 MB of 'data: ' payload.
      request.response.add(utf8.encode('data: '));
      final chunk = List<int>.filled(1024 * 1024, 97); // 'a'
      for (var i = 0; i < 9; i++) {
        request.response.add(chunk);
        await request.response.flush();
      }
      try {
        await request.response.close();
      } catch (_) {}
    });

    try {
      final run = AgentService.I.runTask('unused');
      await run.timeout(const Duration(seconds: 15));
      await serverTask.timeout(const Duration(seconds: 15));

      final errors = AgentService.I.events
          .where((event) => event.kind == 'err')
          .map((event) => event.text)
          .join(' | ');
      expect(errors, contains('exceeded'));
      expect(session.messages.last.content, isNot(contains('a' * 100)));
    } finally {
      provider
        ..baseUrl = originalBaseUrl
        ..models = originalModels
        ..selectedModel = originalSelectedModel;
      await server.close(force: true);
    }
  });

  test('SSE splitter handles chunk-split lines and CRLF', () async {
    final bytes = <int>[
      ...utf8.encode('data: fir'),
      ...utf8.encode('st\r\ndata: second\n\n'),
    ];
    final lines = await Stream.value(
      bytes,
    ).transform(const SseLineSplitter(maxBytes: 1024)).toList();
    expect(lines, ['data: first', 'data: second']);
  });

  // ── PR1 regression tests ──────────────────────────────────────────────

  group('PR1: quick fixes', () {
    test('cleanReasoningText strips think wrapper tags and zero-width chars',
        () {
      const raw = '<think>some thinking here</think> rest';
      final cleaned = cleanReasoningText(raw);
      expect(cleaned, contains('some thinking here'));
      expect(cleaned, isNot(contains('<think>')));
      expect(cleaned, isNot(contains('</think>')));
    });

    test('cleanTruncate respects max length and appends ellipsis', () {
      final long = 'a' * 1000;
      final t = cleanTruncate(long, 100);
      expect(t.length, lessThanOrEqualTo(101)); // 100 + ellipsis
      expect(t.endsWith('…'), isTrue);
    });

    test('cleanTruncate does not truncate short strings', () {
      expect(cleanTruncate('short', 100), 'short');
    });

    test('new session inherits the last selected model', () {
      // Simulate user selecting a model on the current session.
      final provider = app.providerById('ollama-local')!;
      provider.models = ['llama-test'];
      app.setModel(provider.id, 'llama-test');

      // Now create a new session — it should carry the model forward.
      app.newSession();
      final newS = app.activeSession!;
      expect(newS.model, 'llama-test');
      expect(newS.providerId, provider.id);
    });

    test(
        'model picker should only show providers with API keys (hasKey filter)',
        () {
      final provider = app.providerById('openai')!;
      final originalKey = provider.apiKey;
      provider
        ..apiKey = ''
        ..models = ['gpt-4o'];

      // Provider has models but no key — should be excluded from configured.
      final configured = app.providers
          .where((p) => p.hasKey && p.models.isNotEmpty)
          .toList();
      expect(configured.any((p) => p.id == 'openai'), isFalse);

      // Add key — now should be included.
      provider.apiKey = 'sk-test';
      final configured2 = app.providers
          .where((p) => p.hasKey && p.models.isNotEmpty)
          .toList();
      expect(configured2.any((p) => p.id == 'openai'), isTrue);

      provider.apiKey = originalKey;
    });
  });

  // ── PR3 regression tests: queue, cancel, auto-run-next ────────────────
  group('PR3: send/stop/queue', () {
    test('enqueue/edit/remove queued messages', () {
      final agent = AgentService.I;
      agent
        ..clearQueueForTest()
        ..enqueueMessage('first')
        ..enqueueMessage('second')
        ..enqueueMessage('third');
      expect(agent.queuedMessages, ['first', 'second', 'third']);

      agent.editQueuedMessage(1, 'edited');
      expect(agent.queuedMessages, ['first', 'edited', 'third']);

      agent.removeQueuedMessage(0);
      expect(agent.queuedMessages, ['edited', 'third']);

      agent.clearQueueForTest();
      expect(agent.queuedMessages, isEmpty);
    });

    test('cancelRun is a no-op when no run is active', () {
      final agent = AgentService.I;
      agent.clearQueueForTest();
      expect(agent.busy, isFalse);
      // Must not throw.
      agent.cancelRun();
      expect(agent.busy, isFalse);
    });
  });

  // ── PR4 regression tests: catalog management + MCP JSON ───────────────
  group('PR4: catalog + MCP', () {
    test('add and remove a custom provider', () async {
      final err = await app.addCustomProvider(
        name: 'Test Provider',
        baseUrl: 'https://api.testprovider.example/v1',
        apiKey: 'sk-test-123',
      );
      expect(err, isNull);

      final p = app.providerById('custom-test-provider');
      expect(p, isNotNull);
      expect(p!.hasKey, isTrue);

      // Remove it.
      final rmErr = await app.removeCustomProvider('custom-test-provider');
      expect(rmErr, isNull);
      expect(app.providerById('custom-test-provider'), isNull);
    });

    test('removeCustomProvider rejects built-in providers', () async {
      final err = await app.removeCustomProvider('openai');
      expect(err, isNotNull);
      expect(err, contains('built-in'));
    });

    test('addCustomMcpServer + updateCustomMcpServer', () {
      app.addCustomMcpServer(
        name: 'Test MCP',
        command: 'npx',
        args: ['-y', '@test/mcp-server'],
      );
      final s = app.mcpServers.firstWhere((e) => e.name == 'Test MCP');
      expect(s.command, 'npx');
      expect(s.args, ['-y', '@test/mcp-server']);
      expect(s.custom, isTrue);

      // Update via the edit path.
      app.updateCustomMcpServer(
        s,
        command: 'uvx',
        args: ['test-mcp'],
      );
      expect(s.command, 'uvx');
      expect(s.args, ['test-mcp']);

      app.removeMcpServer(s);
      expect(app.mcpServers.any((e) => e.name == 'Test MCP'), isFalse);
    });

    test('marketplace URL normalization', () {
      expect(app.addMarketplace('https://github.com/foo/bar'), isTrue);
      expect(app.marketplaces, contains('foo/bar'));
      expect(app.addMarketplace('foo/bar'), isFalse); // duplicate
      app.removeMarketplace('foo/bar');
      expect(app.marketplaces, isNot(contains('foo/bar')));
    });
  });
}
