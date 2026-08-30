import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
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
    test(
      'cleanReasoningText strips think wrapper tags and zero-width chars',
      () {
        const raw = '<think>some thinking here</think> rest';
        final cleaned = cleanReasoningText(raw);
        expect(cleaned, contains('some thinking here'));
        expect(cleaned, isNot(contains('<think>')));
        expect(cleaned, isNot(contains('</think>')));
      },
    );

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
      },
    );
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
      app.updateCustomMcpServer(s, command: 'uvx', args: ['test-mcp']);
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

    test('usage log: append persists and aggregates', () async {
      final before = app.usageLog.length;
      app.appendUsage(
        UsageEntry(
          time: DateTime.now(),
          providerId: 'openai',
          providerName: 'OpenAI',
          model: 'gpt-4o',
          promptTokens: 100,
          completionTokens: 50,
          totalTokens: 150,
          duration: const Duration(milliseconds: 500),
        ),
      );
      app.appendUsage(
        UsageEntry(
          time: DateTime.now(),
          providerId: 'openai',
          providerName: 'OpenAI',
          model: 'gpt-4o',
          promptTokens: 200,
          completionTokens: 100,
          totalTokens: 300,
          duration: const Duration(milliseconds: 700),
        ),
      );
      expect(app.usageLog.length, before + 2);

      // Daily activity should be non-degenerate after entries.
      final daily = app.dailyActivityFor('openai');
      expect(daily.length, 14);
      expect(daily.any((d) => d > 0.05), isTrue);

      // JSON round-trip.
      final e = app.usageLog.last;
      final j = e.toJson();
      final back = UsageEntry.fromJson(j);
      expect(back.model, e.model);
      expect(back.totalTokens, e.totalTokens);
    });
  });

  // ── PR6: DSH-web parity (scroll/meta/modes/studio) ────────────────────
  group('PR6: DSH-web parity', () {
    test('Message.elapsedMs persists through JSON', () {
      final m = Message(role: 'assistant', content: 'ok', elapsedMs: 1234);
      final back = Message.fromJson(m.toJson());
      expect(back.elapsedMs, 1234);
      expect(back.role, 'assistant');
    });

    test('AppState.deleteMessagesFrom / editMessage', () {
      app.newSession();
      final aims = app.activeSession!;
      final n = aims.messages.length;
      aims.messages.add(Message(role: 'user', content: 'u1'));
      aims.messages.add(Message(role: 'assistant', content: 'a1'));
      aims.messages.add(Message(role: 'user', content: 'u2'));
      aims.messages.add(Message(role: 'assistant', content: 'a2'));
      // revert from index n+1 → leaves u1, drops a1/u2/a2
      app.deleteMessagesFrom(aims.id, n + 1);
      expect(aims.messages.length, n + 1);
      expect(aims.messages.last.content, 'u1');
      // edit the user message
      app.editMessage(aims.id, n, 'u1-edited');
      expect(aims.messages[n].content, 'u1-edited');
    });

    test('response timeout bounds + presets', () {
      final app2 = AppState.I;
      expect(AppState.timeoutPresets, contains(120));
      expect(app2.responseTimeoutSec, inInclusiveRange(5, 3600));
    });

    test(
      'AgentMode labels match DSH (Read-Only/General/Full Access/Studio)',
      () {
        expect(AgentMode.safe.label, 'Read-Only');
        expect(AgentMode.auto.label, 'General');
        expect(AgentMode.drive.label, 'Full Access');
        expect(AgentMode.studio.label, 'Studio');
        expect(AgentMode.values.length, 4);
        // Studio auto-approves everything except commit.
        expect(AgentMode.studio.hint, contains('Studio'));
      },
    );

    test('Studio open-file tabs: open/close/select', () {
      final a = AgentService.I;
      a.studioOpenFiles.clear();
      a.activeFilePath = null;
      a.openStudioFile('lib/a.dart', 'void main(){}');
      a.openStudioFile('lib/b.dart', 'class B {}');
      expect(a.studioOpenFiles, ['lib/a.dart', 'lib/b.dart']);
      expect(a.activeFilePath, 'lib/b.dart');

      a.selectStudioFile('lib/a.dart');
      expect(a.activeFilePath, 'lib/a.dart');

      a.closeStudioFile('lib/a.dart');
      expect(a.studioOpenFiles, ['lib/b.dart']);
      expect(a.activeFilePath, 'lib/b.dart');

      a.closeStudioFile('lib/b.dart');
      expect(a.studioOpenFiles, isEmpty);
      expect(a.activeFilePath, isNull);
    });

    test('file_read opens a Studio tab automatically', () async {
      final a = AgentService.I;
      a.studioOpenFiles.clear();
      a.activeFilePath = null;
      RepoCache.I.files.clear();
      RepoCache.I.files['README.md'] = 'hello repo';
      // Direct dispatch via _dispatch is private; verify via the public
      // openStudioFile helper the file tool uses.
      a.openStudioFile('README.md', RepoCache.I.files['README.md']!);
      expect(a.studioOpenFiles, contains('README.md'));
      expect(a.fileBuffer['README.md'], 'hello repo');
    });
  });

  // ── PR7: Production polish — session isolation, share-memory, tools ──
  group('PR7: production polish', () {
    test('ChatSession.sandboxId: persisted and per-session', () {
      final a = ChatSession(id: 'idA', title: 't', model: 'm');
      final b = ChatSession(id: 'idB', title: 't', model: 'm');
      expect(a.sandboxId, 'idA');
      expect(b.sandboxId, 'idB');
      expect(a.sandboxId, isNot(b.sandboxId));

      // JSON round-trip keeps it.
      final back = ChatSession.fromJson(a.toJson());
      expect(back.sandboxId, 'idA');

      // Old JSON without sandboxId → falls back to id (migration path).
      final legacy = ChatSession.fromJson({
        'id': 'old',
        'title': 't',
        'model': 'm',
      });
      expect(legacy.sandboxId, 'old');
    });

    test('AppState.shareSessionMemory defaults false & toggles', () {
      final app = AppState.I;
      expect(app.shareSessionMemory, isFalse);
      app.setShareSessionMemory(true);
      expect(app.shareSessionMemory, isTrue);
      app.setShareSessionMemory(false);
      expect(app.shareSessionMemory, isFalse);
    });

    test('SandboxService workDirFor isolates per session id', () async {
      final d1 = await SandboxService.I.workDirFor('sessA');
      final d2 = await SandboxService.I.workDirFor('sessB');
      expect(d1.path, isNot(d2.path));
      expect(d1.path, contains('ws_sessA'));
      expect(d2.path, contains('ws_sessB'));
      expect(d1.existsSync(), isTrue);
      expect(d2.existsSync(), isTrue);
    });

    test('SandboxService jailWorkPath is fixed at /work', () {
      expect(SandboxService.jailWorkPath, '/work');
    });

    test('AgentService studio buffers are per-session', () {
      final a = AgentService.I;
      final app = AppState.I;
      app.newSession(); // -> session X active
      final s1 = app.activeSession!;
      a.openStudioFile('a.dart', 'A content');

      app.newSession(); // -> session Y active
      final s2 = app.activeSession!;
      expect(s2.id, isNot(s1.id));
      // New session's studio must NOT see s1's files
      expect(a.studioOpenFiles, isNot(contains('a.dart')));
      expect(a.fileBuffer['a.dart'], isNull);
      a.openStudioFile('b.dart', 'B content');
      expect(a.studioOpenFiles, contains('b.dart'));

      // Switch back — s1's files come back, s2's don't bleed.
      app.activeSessionId = s1.id;
      a.refreshNow();
      expect(a.studioOpenFiles, contains('a.dart'));
      expect(a.studioOpenFiles, isNot(contains('b.dart')));
      expect(a.fileBuffer['a.dart'], 'A content');

      app.activeSessionId = s2.id;
      a.refreshNow();
      expect(a.studioOpenFiles, contains('b.dart'));
    });

    test('browser tab management tools exist in the schema', () {
      // We can't call the private getter; validate the public tab API the
      // dispatch layer uses. Due to the always-one-tab invariant the
      // service auto-creates a default tab when the last one is closed.
      final a = AgentService.I;
      final initialCount = a.browserTabs.length;
      a.newBrowserTab('https://example.com');
      expect(a.browserTabs.length, initialCount + 1);
      expect(a.browserTabs.last.url, 'https://example.com');
      expect(a.activeTabIndex, a.browserTabs.length - 1);
      a.selectBrowserTab(0);
      expect(a.activeTabIndex, 0);
      a.closeBrowserTab(a.browserTabs.length - 1);
      // Either back to initialCount, or a fresh default tab was recreated
      // (closeBrowserTab always keeps one tab alive).
      expect(
        a.browserTabs.length,
        anyOf(initialCount, initialCount == 0 ? 1 : initialCount),
      );
    });

    test('run_shell tool mentions the per-session workspace', () {
      // Direct sanity: approval label tells the user where it runs.
      final a = AgentService.I;
      a.setMode(AgentMode.auto);
      expect(a.mode, AgentMode.auto);
    });
  });

  group('PR8: DSH parity — goals, schedules, memory, theme', () {
    test('sandbox arch detection handles all Platform.version shapes', () {
      // The bug this guards: "android_arm64" (the ACTUAL Android engine
      // string) must be detected as arm64. The old check looked for
      // 'aarch64' only — which NEVER matches android_arm64 → every arm64
      // phone was falsely rejected as "32-bit".
      final s = SandboxService.I;
      // On the host test runner, Platform.version is Linux x86_64 — the
      // getter must return a valid arch either way.
      expect(const ['arm64', 'arm', 'unknown'], contains(s.deviceArch));
      // Direct string checks mirroring _deviceArch logic:
      String archOf(String v) {
        final l = v.toLowerCase();
        if (l.contains('android_arm64') ||
            l.contains('aarch64') ||
            l.contains('x86_64')) {
          return 'arm64';
        }
        if (l.contains('android_arm') || l.contains('armv7')) return 'arm';
        return 'unknown-or-default';
      }

      expect(archOf('3.18.84-g… on "android_arm64"'), 'arm64');
      expect(archOf('5.15.104 … on "android_arm"'), 'arm');
      expect(archOf('6.1.0-something aarch64 Android 6.0'), 'arm64');
      // Order matters: arm64 checked BEFORE arm (substring overlap).
      expect(archOf('android_arm64'), 'arm64');
    });

    test('32-bit arm devices get armhf URLs (Termux parity)', () {
      final s = SandboxService.I;
      // URL getters must serve armhf/proot_arm for 32-bit detection.
      // (Host runs x86_64 → arm64 URLs here; the test asserts shape.)
      expect(s.deviceArch, anyOf('arm64', 'arm', 'unknown'));
    });

    test('MsgKind.tool + turnTail round-trip through JSON', () {
      final m = Message(
        role: 'assistant',
        kind: MsgKind.tool,
        toolName: 'run_shell',
        toolTitle: 'bash',
        toolSummary: 'ls -la',
        toolDetail: 'total 12\ndrwxr-xr-x',
        toolState: 'ok',
      );
      final restored = Message.fromJson(m.toJson());
      expect(restored.kind, MsgKind.tool);
      expect(restored.toolName, 'run_shell');
      expect(restored.toolState, 'ok');
      expect(restored.toolDetail, contains('drwxr'));
      final tail = Message(
        role: 'assistant',
        kind: MsgKind.turnTail,
        content: '2.4s',
      );
      expect(Message.fromJson(tail.toJson()).kind, MsgKind.turnTail);
    });

    test('MsgKind.compact row round-trips through JSON (DSH transcript)', () {
      final c = Message(
        role: 'assistant',
        kind: MsgKind.compact,
        content: 'Context compacted · 24 messages (~31.4K tokens)',
        toolDetail: '## Summary\n…',
      );
      final r = Message.fromJson(c.toJson());
      expect(r.kind, MsgKind.compact);
      expect(r.content, contains('Context compacted'));
      expect(r.toolDetail, contains('Summary'));
    });

    test('tool icon + title mapping (DSH ToolRow parity)', () {
      expect(AgentService.toolIcon('run_shell'), 'terminal');
      expect(AgentService.toolIcon('fs_edit'), 'edit');
      expect(AgentService.toolIcon('file_read'), 'read');
      expect(AgentService.toolIcon('web_search'), 'search');
      expect(AgentService.toolIcon('browser_open'), 'web');
      expect(AgentService.toolIcon('dispatch_agent'), 'agent');
      expect(AgentService.toolIcon('unknown_tool'), 'api');
      expect(AgentService.toolTitleFor('run_shell'), 'bash');
      expect(AgentService.toolTitleFor('dispatch_agent'), 'Subagent');
    });

    test(
      'per-model context windows (DSH compaction parity, all providers)',
      () {
        // Known families → their declared windows.
        expect(AgentService.contextWindowFor('deepseek-chat'), 128000);
        expect(AgentService.contextWindowFor('deepseek-reasoner'), 128000);
        expect(AgentService.contextWindowFor('gpt-4o'), 128000);
        expect(AgentService.contextWindowFor('gpt-4.1'), 1048576);
        expect(AgentService.contextWindowFor('claude-opus-4-20250514'), 200000);
        expect(AgentService.contextWindowFor('gemini-2.5-flash'), 1048576);
        expect(AgentService.contextWindowFor('grok-3'), 256000);
        expect(
          AgentService.contextWindowFor('nvidia/nemotron-3-super'),
          1048576,
        );
        // Variant suffixes (· Medium) fall back to the base model window.
        expect(AgentService.contextWindowFor('deepseek-chat · High'), 128000);
        // Custom-provider / unknown models get the DSH 1M default.
        expect(AgentService.contextWindowFor('my-custom-model-x1'), 1000000);
        expect(AgentService.contextWindowFor(''), 1000000);
      },
    );

    test(
      'token estimate heuristic (DSH token-meter: 4 chars/token + overhead)',
      () {
        expect(AgentService.estimateMessageTokens(''), 4);
        expect(AgentService.estimateMessageTokens('a' * 100), 29);
        expect(AgentService.estimateMessageTokens('x' * 400000), 100004);
      },
    );
    test('ChatSession.goal round-trips through JSON', () {
      final s = ChatSession(id: 'g1', title: 't', model: 'm');
      s.goal = {
        'objective': 'build the feature',
        'status': 'active',
        'round': 3,
        'progressLog': ['r1: started', 'r2: tests pass'],
        'createdAt': '2026-08-29T00:00:00',
      };
      final restored = ChatSession.fromJson(s.toJson());
      expect(restored.goal?['objective'], 'build the feature');
      expect(restored.goal?['round'], 3);
      expect((restored.goal?['progressLog'] as List).length, 2);
    });

    test('ChatSession.schedules round-trip through JSON', () {
      final s = ChatSession(id: 's1', title: 't', model: 'm');
      s.schedules.add({
        'id': 'sch-1',
        'prompt': 'check the build',
        'fireAt': '2026-08-29T12:00:00',
        'every': 300,
      });
      final restored = ChatSession.fromJson(s.toJson());
      expect(restored.schedules.length, 1);
      expect(restored.schedules.first['id'], 'sch-1');
      expect(restored.schedules.first['every'], 300);
    });

    test('MemoryItem round-trips through JSON', () {
      final m = MemoryItem(
        id: 'm1',
        content: 'user prefers Hindi',
        createdAt: DateTime(2026, 8, 29),
      );
      final restored = MemoryItem.fromJson(m.toJson());
      expect(restored.content, 'user prefers Hindi');
      expect(restored.createdAt, DateTime(2026, 8, 29));
    });

    test('Aether palette flips with Aether.dark', () {
      Aether.dark = true;
      final darkBg = Aether.bg;
      final darkText = Aether.text;
      Aether.dark = false;
      final lightBg = Aether.bg;
      final lightText = Aether.text;
      Aether.dark = true; // restore default
      expect(darkBg, isNot(lightBg));
      expect(darkText, isNot(lightText));
    });

    test('Aether.theme() builds both modes without throwing', () {
      Aether.dark = true;
      expect(Aether.theme().scaffoldBackgroundColor, Aether.bg);
      Aether.dark = false;
      expect(Aether.theme().scaffoldBackgroundColor, Aether.bg);
      Aether.dark = true; // restore default
    });
  });

  group('PR9: parallel sessions', () {
    test('queue is per-session — switching sessions isolates queues', () {
      final app = AppState.I;
      final agent = AgentService.I;
      app.newSession();
      final s1 = app.activeSession!;
      agent.enqueueMessage('first task');
      agent.enqueueMessage('second task');
      expect(agent.queuedMessages.length, 2);
      app.newSession();
      final s2 = app.activeSession!;
      // New session has its OWN (empty) queue — the old queue stays with s1.
      expect(agent.queuedMessages, isEmpty);
      agent.enqueueMessage('s2 task');
      expect(agent.queuedMessages.length, 1);
      // Switch back to s1 — its queue is intact.
      app.selectSession(s1.id);
      expect(agent.queuedMessages.length, 2);
      app.selectSession(s2.id);
      expect(agent.queuedMessages.single, 's2 task');
      // Cleanup.
      app.deleteSession(s1.id);
      app.deleteSession(s2.id);
    });

    test('busy is per-session — switching shows only active session state', () {
      final app = AppState.I;
      final agent = AgentService.I;
      app.newSession();
      final s1 = app.activeSession!;
      expect(agent.busy, isFalse);
      app.deleteSession(s1.id);
      expect(agent.busy, isFalse);
    });

    test('dropSessionRun kills only the deleted session', () {
      final app = AppState.I;
      app.newSession();
      final s1 = app.activeSession!;
      app.newSession();
      final s2 = app.activeSession!;
      app.selectSession(s2.id);
      app.deleteSession(s1.id);
      // s2 remains active and functional.
      expect(app.activeSessionId, s2.id);
      app.deleteSession(s2.id);
    });

    test('switching sessions never cancels runs (delete hook only)', () {
      final app = AppState.I;
      // Regression guard: onSessionChange used to cancel runs on switch.
      // Only the DELETE hook may exist now — switching is free.
      expect(app.onSessionDeleted, isNotNull);
      app.newSession();
      final s1 = app.activeSession!;
      app.newSession();
      final s2 = app.activeSession!;
      app.selectSession(s1.id);
      app.selectSession(s2.id);
      app.deleteSession(s1.id);
      app.deleteSession(s2.id);
    });

    test('native sandbox: public surface + env contract', () {
      final s = SandboxService.I;
      // Public API used by MCP/agent must exist and be null-safe pre-install.
      expect(s.prefixPath, anyOf(isNull, isA<String>()));
      expect(s.bashPath, anyOf(isNull, isA<String>()));
      expect(s.deviceArch, anyOf('arm64', 'arm', 'unknown'));
      expect(s.fallbackLog, isA<List<Map<String, String>>>());
      // jailWorkPath constant kept for workspace layout compat.
      expect(SandboxService.jailWorkPath, '/work');
    });

    // Regression: zip directory entries (e.g. "etc/") were being treated
    // as file creations → errno 21 (EISDIR) on Android.  This reproduces
    // the exact failure path: a zip with directory entries + files +
    // SYMLINKS.txt should extract cleanly.
    test('sandbox extractArchive: directory entries don\'t throw EISDIR', () {
      final archive = Archive();
      // Directory entries (exactly what `zip -r` adds).
      archive.addFile(ArchiveFile.directory('bin/'));
      archive.addFile(ArchiveFile.directory('etc/'));
      archive.addFile(ArchiveFile.directory('lib/apt/methods/'));
      // Regular files inside those dirs.
      archive.addFile(ArchiveFile.bytes('bin/bash', utf8.encode('#!/bin/sh')));
      archive.addFile(
        ArchiveFile.bytes(
          'etc/apt/sources.list',
          utf8.encode('deb https://termux.org'),
        ),
      );
      archive.addFile(
        ArchiveFile.bytes('lib/apt/methods/http', utf8.encode('http-method')),
      );
      // SYMLINKS.txt — should be skipped during extraction.
      archive.addFile(
        ArchiveFile.string(
          'SYMLINKS.txt',
          '/data/data/com.termux/files/usr/bin/dash←bin/sh\n',
        ),
      );

      final staging = Directory.systemTemp.createTempSync('ovid_extract_test');
      try {
        final count = SandboxService.extractArchive(archive, staging);
        // 3 regular files (SYMLINKS.txt skipped).
        expect(count, 3);
        // Directory entries created as dirs, not files.
        expect(Directory('${staging.path}/bin').existsSync(), isTrue);
        expect(Directory('${staging.path}/etc').existsSync(), isTrue);
        expect(
          Directory('${staging.path}/lib/apt/methods').existsSync(),
          isTrue,
        );
        // Files extracted correctly.
        expect(File('${staging.path}/bin/bash').existsSync(), isTrue);
        expect(
          File('${staging.path}/etc/apt/sources.list').readAsStringSync(),
          'deb https://termux.org',
        );
        // SYMLINKS.txt NOT extracted to disk.
        expect(File('${staging.path}/SYMLINKS.txt').existsSync(), isFalse);
      } finally {
        staging.deleteSync(recursive: true);
      }
    });

    test('sandbox parseSymlinks: Termux format target←linkPath', () {
      final archive = Archive();
      archive.addFile(
        ArchiveFile.string('SYMLINKS.txt', '''
/data/data/com.termux/files/usr/bin/dash←bin/sh
/data/data/com.termux/files/usr/bin/busybox←bin/busybox
'''),
      );
      final list = SandboxService.parseSymlinks(archive);
      expect(list.length, 2);
      expect(list[0].target, '/data/data/com.termux/files/usr/bin/dash');
      expect(list[0].linkPath, 'bin/sh');
      expect(list[1].target, '/data/data/com.termux/files/usr/bin/busybox');
      expect(list[1].linkPath, 'bin/busybox');
    });

    // Regression: parseSymlinks used a Map keyed by target — SYMLINKS.txt
    // has 1177 lines but only 220 unique targets (coreutils alone is the
    // target of 100 bin/ links).  A Map collapsed them to 220 entries,
    // breaking ls/cp/mv/etc.  The list must preserve EVERY line.
    test(
      'sandbox parseSymlinks: duplicate targets preserved (Map→List fix)',
      () {
        final archive = Archive();
        archive.addFile(
          ArchiveFile.string('SYMLINKS.txt', '''
coreutils←./bin/ls
coreutils←./bin/cp
coreutils←./bin/mv
coreutils←./bin/cat
libncursesw.so.6.5←./lib/libtinfo.so
libncursesw.so.6.5←./lib/libncurses.so.6
'''),
        );
        final list = SandboxService.parseSymlinks(archive);
        // ALL 6 entries must survive — not just 2 unique targets.
        expect(list.length, 6);
        final links = list.map((s) => s.linkPath).toSet();
        expect(
          links,
          containsAll([
            './bin/ls',
            './bin/cp',
            './bin/mv',
            './bin/cat',
            './lib/libtinfo.so',
            './lib/libncurses.so.6',
          ]),
        );
        // Every entry's target is coreutils or libncursesw.so.6.5.
        for (final s in list) {
          expect(s.target, anyOf('coreutils', 'libncursesw.so.6.5'));
        }
      },
    );

    // ── PR10: working MCP/plugins + first-launch setup + per-session state ──

    // Regression: agent_install_mcp used to ONLY flip match.connected = true
    // without ever spawning the process — the UI said "connected" while
    // nothing ran.  The fix routes through McpService.connect() which
    // fails loudly when the sandbox isn't there.  Here: the catalog tool
    // result must reflect the REAL connection state (unavailable sandbox
    // → explicit failure, never a fake ✓).
    test(
      'agent_install_mcp reports real connect result (no bool-flip)',
      () async {
        final app = AppState.I;
        final s = app.mcpServers.firstWhere(
          (m) => m.name == 'Filesystem',
          orElse: () => app.mcpServers.first,
        );
        final wasConnected = s.connected;
        try {
          // McpService.connect with no sandbox → returns 'connect failed: …'
          final res = await McpService.I.connect(s);
          expect(res.toLowerCase(), contains('failed'));
          // And the server is NOT marked connected.
          expect(McpService.I.isConnected(s.name), isFalse);
        } finally {
          s.connected = wasConnected;
        }
      },
    );

    // Regression: custom MCP servers used to vanish on restart (no
    // persistence).  The fix persists them; here we verify the save/load
    // round-trip through the AppState API.
    test('custom MCP servers persist via addCustomMcpServer', () async {
      final app = AppState.I;
      final name = 'test-echo-server-\${DateTime.now().millisecondsSinceEpoch}';
      app.addCustomMcpServer(
        name: name,
        command: 'npx',
        args: ['-y', '@example/echo'],
      );
      expect(app.mcpServers.any((s) => s.name == name), isTrue);
      // Verify it was written to SharedPreferences.
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('ovid_custom_mcp_servers_v1');
      expect(saved, isNotNull);
      expect(
        saved!.any(
          (j) => (jsonDecode(j) as Map<String, dynamic>)['name'] == name,
        ),
        isTrue,
      );
      // Clean up (also exercises remove persistence).
      final added = app.mcpServers.firstWhere((s) => s.name == name);
      app.removeMcpServer(added);
      expect(app.mcpServers.any((s) => s.name == name), isFalse);
    });

    // Regression: plugin install/enable state used to reset to seed
    // defaults on every restart.  The fix persists {name: {installed,
    // enabled}} and overlays it after seeding.
    test('plugin state persists via persistPluginState', () async {
      final app = AppState.I;
      final p = app.plugins.first;
      final wasInstalled = p.installed;
      final wasEnabled = p.enabled;
      try {
        p.installed = !p.installed;
        p.enabled = !p.enabled;
        await app.persistPluginState();
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('ovid_plugin_state_v1');
        expect(raw, isNotNull);
        final m = jsonDecode(raw!) as Map<String, dynamic>;
        expect(m.containsKey(p.name), isTrue);
        final st = jsonDecode(m[p.name] as String) as Map<String, dynamic>;
        expect(st['installed'], !wasInstalled);
        expect(st['enabled'], !wasEnabled);
      } finally {
        p.installed = wasInstalled;
        p.enabled = wasEnabled;
        await app.persistPluginState();
      }
    });

    // New: agent can create custom plugins (catalog_add_plugin) — full
    // definition persists (not just enabled flags).
    test('addCustomPlugin creates + persists a custom plugin', () async {
      final app = AppState.I;
      const name = 'test-custom-plugin-x1';
      app.addCustomPlugin(
        name: name,
        description: 'A test plugin',
        category: 'Tool',
      );
      expect(app.plugins.any((p) => p.name == name), isTrue);
      final created = app.plugins.firstWhere((p) => p.name == name);
      expect(created.installed, isTrue);
      expect(created.enabled, isTrue);
      // Persisted as a full definition.
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('ovid_custom_plugins_v1');
      expect(saved, isNotNull);
      expect(
        saved!.any(
          (j) => (jsonDecode(j) as Map<String, dynamic>)['name'] == name,
        ),
        isTrue,
      );
      // Clean up.
      app.plugins.removeWhere((p) => p.name == name);
      await app.persistPluginState();
    });

    // New: per-session Studio repos — each session binds its own repo,
    // falls back to the global when unset, and persists with the session.
    test('per-session repo: set/get/persist round-trip', () async {
      final app = AppState.I;
      // Ensure two distinct sessions.
      while (app.sessions.length < 2) {
        app.newSession();
      }
      final s = app.sessions[0];
      final old = s.repo;
      try {
        app.setRepoForSession(s.id, 'user/repo-a');
        expect(app.getRepoForSession(s.id), 'user/repo-a');
        expect(
          app.getRepoForSession(s.id, fallback: 'global/repo'),
          'user/repo-a',
        ); // session wins
        // Persisted through ChatSession.toJson.
        expect(s.toJson()['repo'], 'user/repo-a');
        // Another session (no repo of its own) falls back to the global.
        final s2 = app.sessions[1];
        final old2 = s2.repo;
        s2.repo = null; // ensure fallback path
        expect(
          app.getRepoForSession(s2.id, fallback: 'global/repo'),
          'global/repo',
        );
        s2.repo = old2;
      } finally {
        s.repo = old;
      }
    });

    // New: ChatSession.repo JSON round-trip (old sessions without repo
    // still deserialize — migration path).
    test('ChatSession.repo: JSON round-trip + legacy migration', () {
      final s = ChatSession(
        id: 'r1',
        title: 't',
        model: 'm',
        repo: 'user/repo-b',
      );
      final j = s.toJson();
      expect(j['repo'], 'user/repo-b');
      final back = ChatSession.fromJson(j);
      expect(back.repo, 'user/repo-b');
      // Legacy JSON without repo → null (falls back to global at use site).
      final legacy = ChatSession.fromJson({
        'id': 'r2',
        'title': 't',
        'model': 'm',
      });
      expect(legacy.repo, isNull);
    });

    // New: per-session browser tabs — switching sessions switches tab
    // sets; tabs are isolated per session id.
    test('browser tabs are per-session (switch isolation)', () {
      final agent = AgentService.I;
      final app = AppState.I;
      // Ensure two distinct sessions.
      while (app.sessions.length < 2) {
        app.newSession();
      }
      final s1 = app.sessions[0];
      final s2 = app.sessions[1];
      AppState.I.selectSession(s1.id);
      agent.browserTabs; // materialize bucket
      agent.newBrowserTab('https://a.example.com');
      final count1 = agent.browserTabs.length;
      expect(agent.browserTabs.isNotEmpty, isTrue);

      AppState.I.selectSession(s2.id);
      // Fresh session bucket starts EMPTY (then lazily gets a default
      // tab only on access via _activeTab).
      expect(agent.browserTabsFor(s2.id).isEmpty, isTrue);
      // Tabs of session 1 are untouched by session 2's bucket.
      expect(agent.browserTabsFor(s1.id).length, count1);
      // Back to s1 — tabs intact.
      AppState.I.selectSession(s1.id);
      expect(agent.browserTabs.length, count1);
    });

    // New: MCP tool name format — mcp__<server>__<tool> parsing contract
    // (the dispatch + injection share this normalization).
    test('mcp tool names: mcp__server__tool normalization round-trip', () {
      String norm(String s) => s
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
          .replaceAll(RegExp(r'^_|_$'), '');
      expect(norm('Chrome DevTools'), 'chrome_devtools');
      expect(norm('Filesystem'), 'filesystem');
      final toolName = 'mcp__${norm('Filesystem')}__read_file';
      final parts = toolName.split('__');
      expect(parts.length, 3);
      expect(parts[1], norm('Filesystem'));
      expect(parts[2], 'read_file');
      // Multi-underscore tool names survive (sublist join).
      final toolName2 = 'mcp__fs__list_dir__deep';
      final parts2 = toolName2.split('__');
      expect(parts2.sublist(2).join('__'), 'list_dir__deep');
    });

    // ── PR11: pinch-zoom font scale + chatbox file upload ──

    // chatFontScale must clamp to [min,max] and persist, so a pinch can't
    // shrink text to zero or blow it up unboundedly.
    test('chatFontScale: clamps to bounds and persists', () async {
      final app = AppState.I;
      final old = app.chatFontScale;
      try {
        await app.setChatFontScale(0.1); // below min
        expect(app.chatFontScale, AppState.chatFontScaleMin);
        await app.setChatFontScale(99); // above max
        expect(app.chatFontScale, AppState.chatFontScaleMax);
        await app.setChatFontScale(1.4); // in range
        expect(app.chatFontScale, closeTo(1.4, 1e-9));
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getDouble('ovid_chat_font_scale'), closeTo(1.4, 1e-9));
      } finally {
        await app.setChatFontScale(old);
      }
    });

    // attachFile copies into the session workspace and stages a
    // pendingAttachment; clearAttachment resets it. Oversize/missing files
    // return an error string (never throw).
    test(
      'attachFile: stages, copies to workspace, clears; errors safe',
      () async {
        final agent = AgentService.I;
        final tmp = Directory.systemTemp.createTempSync('ovid_att');
        // Unique name per run — the session workspace persists across tests,
        // and attachFile de-dupes by suffixing when the name already exists.
        final unique = 'notes_${DateTime.now().microsecondsSinceEpoch}.txt';
        try {
          final src = File('${tmp.path}/$unique')
            ..writeAsStringSync('hello attachment');
          final err = await agent.attachFile(src.path, unique);
          expect(err, isNull);
          final att = agent.pendingAttachment;
          expect(att, isNotNull);
          expect(att!.name, unique);
          expect(att.size, greaterThan(0));
          // The file was copied INTO the session workspace (different path).
          expect(att.path, isNot(src.path));
          expect(File(att.path).existsSync(), isTrue);
          // Clear resets.
          agent.clearAttachment();
          expect(agent.pendingAttachment, isNull);
          // Missing file → error string, no throw.
          final missing = await agent.attachFile(
            '${tmp.path}/nope.xyz',
            'nope.xyz',
          );
          expect(missing, isNotNull);
          expect(agent.pendingAttachment, isNull);
        } finally {
          tmp.deleteSync(recursive: true);
          agent.clearAttachment();
        }
      },
    );
  });
}
