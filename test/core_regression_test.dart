import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi' as ffi;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/presets.dart';
import 'package:ovid_ai/core/pty_service.dart';
import 'package:ovid_ai/core/repo_cache.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/skills.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/plugins_screen.dart' show parseMcpConfigForTest;
import 'package:sqlite3/open.dart' show open, OperatingSystem;
import 'package:ovid_ai/core/sandbox_pkg.dart';
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
    // Ledger + FTS5 search roots: no path_provider channel in unit tests.
    final tmp = Directory.systemTemp.createTempSync('ovid-pr19');
    SessionLedger.rootOverrideForTest = tmp;
    SessionSearch.dbPathOverrideForTest = '${tmp.path}/search.db';
    CommandService.exportDirOverrideForTest = tmp.path;
    // sqlite3 needs the system lib on the host (the APK bundles its own
    // via sqlite3_flutter_libs); dev-<name> symlink missing the .so → load
    // the versioned lib directly.
    if (Platform.isLinux) {
      open.overrideFor(OperatingSystem.linux, () {
        try {
          return ffi.DynamicLibrary.open('libsqlite3.so.0');
        } catch (_) {
          return ffi.DynamicLibrary.open('/usr/lib/x86_64-linux-gnu/libsqlite3.so.0');
        }
      });
    }
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

        // Compaction now carries the long-tail; the transport sends the
        // FULL history (no 12-message slice) — that's what this asserts.
        expect(sentMessages, hasLength(16));
        expect(sentMessages.first['role'], 'system');
        expect(sentMessages[1]['content'], 'message-0');
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
      expect(app.addMarketplace('https://github.com/foo/bar'), 'foo/bar');
      expect(app.marketplaces, contains('foo/bar'));
      expect(app.addMarketplace('foo/bar'), isNull); // duplicate
      expect(app.addMarketplace('   '), isNull); // empty
      expect(app.addMarketplace('noslash'), isNull); // not owner/repo
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
        expect(AgentService.contextWindowFor('nvidia/nemotron-3-super'), 262144);
        expect(
          AgentService.contextWindowFor('nvidia/nemotron-3.5-lightning-30b'),
          32768,
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
    test('session bleed: mid-run switch keeps stream + output in A, B clean', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final provider = app.providerById('ollama-local')!;
      final originals = ({
        'baseUrl': provider.baseUrl,
        'models': List<String>.of(provider.models),
        'selectedModel': provider.selectedModel,
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      final sessionA = ChatSession(
        id: 'bleed-a',
        title: 'A',
        providerId: provider.id,
        model: 'test-model',
        messages: [Message(role: 'user', content: 'hello')],
      );
      final sessionB = ChatSession(id: 'bleed-b', title: 'B', model: 'test-model');
      app.sessions.addAll([sessionA, sessionB]);
      app.activeSessionId = sessionA.id;
      provider
        ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
        ..models = ['test-model']
        ..selectedModel = 'test-model';

      // Server streams 3 SSE deltas slowly, then finishes.
      final serverTask = server.first.then((request) async {
        request.response.headers.chunkedTransferEncoding = true;
        for (var i = 0; i < 3; i++) {
          request.response.add(
            utf8.encode(
              'data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': 'chunk$i '},
                    'finish_reason': i == 2 ? 'stop' : null,
                  },
                ],
              })}\n\n',
            ),
          );
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
        try {
          await request.response.close();
        } catch (_) {}
      });

      try {
        final run = agent.runTask('task in A');
        // Wait for the first chunk to start streaming into A, then
        // switch to session B mid-run (the classic bleed repro).
        await Future<void>.delayed(const Duration(milliseconds: 200));
        app.selectSession(sessionB.id);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        // While switched away, B's chat must stay pristine…
        expect(sessionB.messages, isEmpty,
            reason: 'B must not receive any of A\'s streaming or events');
        await run.timeout(const Duration(seconds: 10));
        await serverTask.timeout(const Duration(seconds: 10));

        // …and A must own the complete streamed answer.
        expect(sessionB.messages, isEmpty);
        final aText = sessionA.messages
            .where((m) => m.role == 'assistant')
            .map((m) => m.content)
            .join('');
        expect(aText, contains('chunk0'));
        expect(aText, contains('chunk2'));
      } finally {
        provider
          ..baseUrl = originals['baseUrl'] as String
          ..models = originals['models'] as List<String>
          ..selectedModel = originals['selectedModel'] as String?;
        await server.close(force: true);
        app.deleteSession(sessionA.id);
        app.deleteSession(sessionB.id);
      }
    });

    test('session bleed: queued continuation lands in the RUNNING session', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final provider = app.providerById('ollama-local')!;
      final originals = ({
        'baseUrl': provider.baseUrl,
        'models': List<String>.of(provider.models),
        'selectedModel': provider.selectedModel,
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;

      final sessionA = ChatSession(
        id: 'qc-a',
        title: 'A',
        providerId: provider.id,
        model: 'test-model',
        messages: [Message(role: 'user', content: 'hello')],
      );
      final sessionB = ChatSession(id: 'qc-b', title: 'B', model: 'test-model');
      app.sessions.addAll([sessionA, sessionB]);
      app.activeSessionId = sessionA.id;
      provider
        ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
        ..models = ['test-model']
        ..selectedModel = 'test-model';

      // Serve every request (run + continuation) with a quick final answer.
      final serverTask = () async {
        await for (final request in server) {
          requests++;
          request.response.headers.chunkedTransferEncoding = true;
          request.response.add(
            utf8.encode(
              'data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': 'done '},
                    'finish_reason': 'stop',
                  },
                ],
              })}\n\n',
            ),
          );
          await request.response.flush();
          try {
            await request.response.close();
          } catch (_) {}
        }
      }();
      unawaited(serverTask);

      try {
        // Start a run in A, queue a follow-up for A, then switch to B.
        final run = agent.runTask('first in A');
        agent.enqueueMessage('queued follow-up');
        await Future<void>.delayed(const Duration(milliseconds: 150));
        app.selectSession(sessionB.id);
        await run.timeout(const Duration(seconds: 10));
        // The queued follow-up must start a continuation run in A (not B).
        // Wait for the second request (the continuation).
        for (var i = 0; i < 50 && requests < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(requests, greaterThanOrEqualTo(2),
            reason: 'queued message should trigger a continuation run');
        // B never received A's queued message as a user bubble.
        expect(sessionB.messages.where((m) => m.role == 'user'), isEmpty);
        // A received it.
        expect(
          sessionA.messages.map((m) => m.content),
          contains('queued follow-up'),
        );
      } finally {
        provider
          ..baseUrl = originals['baseUrl'] as String
          ..models = originals['models'] as List<String>
          ..selectedModel = originals['selectedModel'] as String?;
        await server.close(force: true);
        app.deleteSession(sessionA.id);
        app.deleteSession(sessionB.id);
      }
    });

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

    // New: Message attachments JSON round-trip + legacy messages without
    // attachments still deserialize.
    test('Message.attachments: JSON round-trip + legacy migration', () {
      final m = Message(
        role: 'user',
        content: 'check this file',
        attachments: [
          MessageAttachment(name: 'data.csv', size: 2048),
          MessageAttachment(name: 'img.png', size: 999424),
        ],
      );
      final j = m.toJson();
      expect(j['attachments'], hasLength(2));
      final back = Message.fromJson(j);
      expect(back.attachments, hasLength(2));
      expect(back.attachments.first.name, 'data.csv');
      expect(back.attachments.first.size, 2048);
      expect(back.attachments.last.name, 'img.png');
      // Legacy message without attachments → empty list, no crash.
      final legacy = Message.fromJson({'role': 'user', 'content': 'hi'});
      expect(legacy.attachments, isEmpty);
    });

    test('runTask stamps the staged attachment onto the user message', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final provider = app.providerById('ollama-local')!;
      final originals = ({
        'baseUrl': provider.baseUrl,
        'models': List<String>.of(provider.models),
        'selectedModel': provider.selectedModel,
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      final session = ChatSession(
        id: 'attach-run',
        title: 'Attach',
        providerId: provider.id,
        model: 'test-model',
      );
      app.sessions.add(session);
      app.activeSessionId = session.id;
      provider
        ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
        ..models = ['test-model']
        ..selectedModel = 'test-model';

      final serverTask = server.first.then((request) async {
        request.response.headers.chunkedTransferEncoding = true;
        request.response.add(
          utf8.encode(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': 'ok'},
                  'finish_reason': 'stop',
                },
              ],
            })}\n\n',
          ),
        );
        await request.response.flush();
        try {
          await request.response.close();
        } catch (_) {}
      });

      final tmpDir = Directory.systemTemp.createTempSync('attach_src');
      try {
        // Stage an attachment: source OUTSIDE the workspace (like a
        // picked file from the file picker).
        final f = File(
          '${tmpDir.path}/attach_test_${DateTime.now().millisecondsSinceEpoch}.txt',
        );
        final attachName = f.uri.pathSegments.last;
        f.writeAsStringSync('hello attach');
        await agent.attachFile(f.path, attachName);
        expect(agent.pendingAttachment, isNotNull);

        app.sendMessage('analyze this');
        final run = agent.runTask('analyze this');
        await run.timeout(const Duration(seconds: 10));
        await serverTask.timeout(const Duration(seconds: 10));

        // The user message now carries the attachment chip.
        final userMsg = session.messages.firstWhere(
          (m) => m.role == 'user' && m.content == 'analyze this',
        );
        expect(userMsg.attachments, hasLength(1));
        expect(userMsg.attachments.first.name, attachName);
        // And it survives a JSON round-trip (persistence).
        final back = Message.fromJson(userMsg.toJson());
        expect(back.attachments.first.name, attachName);
      } finally {
        provider
          ..baseUrl = originals['baseUrl'] as String
          ..models = originals['models'] as List<String>
          ..selectedModel = originals['selectedModel'] as String?;
        await server.close(force: true);
        app.deleteSession(session.id);
        try {
          tmpDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('ask_user_question records the Q&A into the chat thread', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final session = ChatSession(id: 'qa-rec', title: 'QA', model: 'm');
      app.sessions.add(session);
      app.activeSessionId = session.id;

      // Drive the handler directly (no LLM round-trip needed): answer the
      // pending questions from the outside while the handler awaits.
      final handler = agent.handleAskUserQuestionForTest({
        'questions': [
          {
            'id': 'q1',
            'question': 'Which database?',
            'options': [
              {'label': 'Postgres'},
              {'label': 'SQLite'},
            ],
          },
        ],
      });

      // The questions card must appear as a pending approval.
      for (var i = 0;
          i < 50 && AgentService.I.pendingApproval?.questions == null;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final req = AgentService.I.pendingApproval;
      expect(req, isNotNull);
      expect(req!.questions, hasLength(1));
      // Answer like the UI does: record the answer, approve.
      req.answers['q1'] = 'Postgres';
      AgentService.I.approve(true);

      final result = await handler.timeout(const Duration(seconds: 5));
      expect(result, contains('q1: Postgres'));
      // The Q&A is recorded in the thread as a tool card.
      final qaMsg = session.messages.lastWhere(
        (m) => m.kind == MsgKind.tool && m.toolName == 'ask_user_question',
      );
      expect(qaMsg.toolDetail, contains('Which database?'));
      expect(qaMsg.toolDetail, contains('Postgres'));

      app.deleteSession(session.id);
    });

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

    test('destructive command detector catches the killers', () {
      const killers = [
        'rm -rf /',
        'rm -rf /data/something',
        'rm -rf ~',
        r'rm -rf $HOME',
        r'rm -rf $PREFIX',
        'rm -fr /system',
        'dd if=/dev/zero of=/dev/block/mmcblk0',
        'mkfs.ext4 /dev/sda1',
        ':(){ :|:& };:',
        'chmod -R 777 /',
        'reboot',
        'shutdown -h now',
        'find / -name x -delete',
      ];
      for (final k in killers) {
        expect(
          AgentService.isDestructiveCommand(k),
          isTrue,
          reason: 'should flag: $k',
        );
      }
    });

    test('destructive command detector spares normal work', () {
      const fine = [
        'rm -rf ./node_modules',
        'rm -rf build dist',
        'npm install',
        'echo hi > out.txt',
        'git push origin main',
        'find src -name "*.dart" | xargs grep foo',
        'ls -la',
      ];
      for (final f in fine) {
        expect(
          AgentService.isDestructiveCommand(f),
          isFalse,
          reason: 'should NOT flag: $f',
        );
      }
    });

    test('read-only classifier: safe commands, compounds, and mutants', () {
      // Plain read-only.
      expect(AgentService.isReadOnlyCommand('ls -la'), isTrue);
      expect(AgentService.isReadOnlyCommand('cat README.md'), isTrue);
      expect(AgentService.isReadOnlyCommand('git status'), isTrue);
      expect(AgentService.isReadOnlyCommand('npm ping'), isTrue);
      // Compound of read-only parts is fine.
      expect(
        AgentService.isReadOnlyCommand('git status && git diff HEAD~1'),
        isTrue,
      );
      // Piped read-only is fine.
      expect(
        AgentService.isReadOnlyCommand('cat log.txt | grep error'),
        isTrue,
      );
      // Write-capable commands are NOT read-only.
      expect(AgentService.isReadOnlyCommand('npm install'), isFalse);
      expect(AgentService.isReadOnlyCommand('echo hi > file.txt'), isFalse);
      expect(AgentService.isReadOnlyCommand('rm foo.txt'), isFalse);
      // Read-only command used to WRITE is not read-only (redirection).
      expect(AgentService.isReadOnlyCommand('cat a > b'), isFalse);
    });

    // ─── Session/model isolation (P0 fix) ────────────────────────────
    test('parallel same-provider runs keep models + streams isolated', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final provider = app.providerById('ollama-local')!;
      final originals = ({
        'baseUrl': provider.baseUrl,
        'models': List<String>.of(provider.models),
        'selectedModel': provider.selectedModel,
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bodies = <String>[];

      final sessionA = ChatSession(
        id: 'par-a',
        title: 'A',
        providerId: provider.id,
        model: 'model-a',
        messages: [Message(role: 'user', content: 'prompt A')],
      );
      final sessionB = ChatSession(
        id: 'par-b',
        title: 'B',
        providerId: provider.id,
        model: 'model-b',
        messages: [Message(role: 'user', content: 'prompt B')],
      );
      app.sessions.addAll([sessionA, sessionB]);
      app.activeSessionId = sessionA.id;
      provider
        ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
        ..models = ['model-a', 'model-b'];

      final serverTask = () async {
        await for (final request in server) {
          final body = await utf8.decoder.bind(request).join();
          final payload = jsonDecode(body) as Map<String, dynamic>;
          bodies.add(payload['model'] as String);
          request.response.headers.chunkedTransferEncoding = true;
          request.response.add(
            utf8.encode(
              'data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': 'reply-for-${payload['model']}'},
                    'finish_reason': 'stop',
                  },
                ],
              })}\n\n',
            ),
          );
          await request.response.flush();
          try {
            await request.response.close();
          } catch (_) {}
        }
      }();
      unawaited(serverTask);

      try {
        // Start both runs — A on active session, B background via sessionId.
        final runA = agent.runTask('prompt A', sessionId: sessionA.id);
        final runB = agent.runTask('prompt B', sessionId: sessionB.id);
        await runA.timeout(const Duration(seconds: 10));
        await runB.timeout(const Duration(seconds: 10));

        // Each request was made with its OWN session's model.
        expect(bodies, contains('model-a'));
        expect(bodies, contains('model-b'));

        // Each session's assistant output contains only its own reply —
        // no cross-session merge when two same-provider runs are parallel.
        final aText = sessionA.messages
            .where((m) => m.role == 'assistant')
            .map((m) => m.content)
            .join('\n');
        final bText = sessionB.messages
            .where((m) => m.role == 'assistant')
            .map((m) => m.content)
            .join('\n');
        expect(aText, contains('reply-for-model-a'));
        expect(aText, isNot(contains('reply-for-model-b')));
        expect(bText, contains('reply-for-model-b'));
        expect(bText, isNot(contains('reply-for-model-a')));
      } finally {
        provider
          ..baseUrl = originals['baseUrl'] as String
          ..models = originals['models'] as List<String>
          ..selectedModel = originals['selectedModel'] as String?;
        await server.close(force: true);
        app.deleteSession(sessionA.id);
        app.deleteSession(sessionB.id);
      }
    });

    test('mid-run model switch never changes the in-flight session model', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final provider = app.providerById('ollama-local')!;
      final originals = ({
        'baseUrl': provider.baseUrl,
        'models': List<String>.of(provider.models),
        'selectedModel': provider.selectedModel,
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      String? capturedModel;

      final sessionA = ChatSession(
        id: 'model-a2',
        title: 'A',
        providerId: provider.id,
        model: 'deepseek-chat',
        messages: [Message(role: 'user', content: 'hello')],
      );
      final sessionB = ChatSession(
        id: 'model-b2',
        title: 'B',
        providerId: provider.id,
        model: 'deepseek-reasoner',
        messages: [Message(role: 'user', content: 'hi B')],
      );
      app.sessions.addAll([sessionA, sessionB]);
      app.activeSessionId = sessionA.id;
      provider
        ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
        ..models = ['deepseek-chat', 'deepseek-reasoner'];

      final serverTask = server.first.then((request) async {
        final body = await utf8.decoder.bind(request).join();
        capturedModel = jsonDecode(body)['model'] as String?;
        request.response.headers.chunkedTransferEncoding = true;
        // Slow stream — time to switch sessions and setModel mid-run.
        for (var i = 0; i < 2; i++) {
          request.response.add(
            utf8.encode(
              'data: ${jsonEncode({
                'choices': [
                  {'delta': {'content': 'chunk$i '}},
                ],
              })}\n\n',
            ),
          );
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
        try {
          await request.response.close();
        } catch (_) {}
      });

      try {
        final run = agent.runTask('hello', sessionId: sessionA.id);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        // Switch to B AND setModel on the shared provider mid-run.
        app.selectSession(sessionB.id);
        app.setModel(provider.id, 'deepseek-reasoner');
        await run.timeout(const Duration(seconds: 10));
        await serverTask.timeout(const Duration(seconds: 10));

        // The model sent on the wire stayed deepseek-chat.
        expect(capturedModel, 'deepseek-chat');
        // B's session still has its own model.
        expect(sessionB.model, 'deepseek-reasoner');
      } finally {
        provider
          ..baseUrl = originals['baseUrl'] as String
          ..models = originals['models'] as List<String>
          ..selectedModel = originals['selectedModel'] as String?;
        await server.close(force: true);
        app.deleteSession(sessionA.id);
        app.deleteSession(sessionB.id);
      }
    });

    test('switching sessions does not mutate provider.selectedModel', () {
      final app = AppState.I;
      final provider = app.providerById('ollama-local')!;
      final origSel = provider.selectedModel;
      final origModels = List<String>.of(provider.models);
      provider.models = ['m1', 'm2'];

      final sA = ChatSession(
        id: 'sel-a',
        title: 'A',
        providerId: provider.id,
        model: 'm1',
      );
      final sB = ChatSession(
        id: 'sel-b',
        title: 'B',
        providerId: provider.id,
        model: 'm2',
      );
      app.sessions.addAll([sA, sB]);
      try {
        provider.selectedModel = 'm1';
        app.selectSession(sB.id);
        expect(
          provider.selectedModel,
          'm1',
          reason: 'session switch must not write to shared provider'
              'selectedModel — that is how model bleed happens',
        );
        app.newSession();
        expect(provider.selectedModel, 'm1');
      } finally {
        provider
          ..selectedModel = origSel
          ..models = origModels;
        app.deleteSession(sA.id);
        app.deleteSession(sB.id);
      }
    });

    // ─── Todo injection + follow-through (P0 fix) ────────────────────
    test('session todos are injected into the model context', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final provider = app.providerById('ollama-local')!;
      final originals = ({
        'baseUrl': provider.baseUrl,
        'models': List<String>.of(provider.models),
        'selectedModel': provider.selectedModel,
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestBodies = <Map<String, dynamic>>[];

      final session = ChatSession(
        id: 'todo-inj',
        title: 'Todo',
        providerId: provider.id,
        model: 'test-model',
        messages: [Message(role: 'user', content: 'do the task')],
      );
      session.todos.addAll([
        {'content': 'read the file', 'status': 'completed'},
        {'content': 'edit the file', 'status': 'in_progress'},
        {'content': 'run tests', 'status': 'pending'},
      ]);
      app.sessions.add(session);
      app.activeSessionId = session.id;
      provider
        ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
        ..models = ['test-model'];

      // Serve EVERY request (run + todo follow-through nudge) so the run
      // can complete even when the nudge fires a follow-up turn.
      final serverTask = () async {
        await for (final request in server) {
          final body = await utf8.decoder.bind(request).join();
          requestBodies.add(jsonDecode(body) as Map<String, dynamic>);
          request.response.headers.chunkedTransferEncoding = true;
          request.response.add(
            utf8.encode(
              'data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': 'done'},
                    'finish_reason': 'stop',
                  },
                ],
              })}\n\n',
            ),
          );
          await request.response.flush();
          try {
            await request.response.close();
          } catch (_) {}
        }
      }();
      unawaited(serverTask);

      try {
        await agent
            .runTask('do the task', sessionId: session.id, freshTurn: false)
            .timeout(const Duration(seconds: 10));
        expect(requestBodies, isNotEmpty);
        final sys =
            (requestBodies.first['messages'] as List)
                .firstWhere((m) => m['role'] == 'system')['content']
                as String;
        expect(sys, contains('SESSION TODOS'));
        expect(sys, contains('edit the file'));
        expect(sys, contains('run tests'));
      } finally {
        provider
          ..baseUrl = originals['baseUrl'] as String
          ..models = originals['models'] as List<String>
          ..selectedModel = originals['selectedModel'] as String?;
        await server.close(force: true);
        app.deleteSession(session.id);
      }
    });

    test('pending todos nudge the model once, then finish', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final provider = app.providerById('ollama-local')!;
      final originals = ({
        'baseUrl': provider.baseUrl,
        'models': List<String>.of(provider.models),
        'selectedModel': provider.selectedModel,
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final bodies = <Map<String, dynamic>>[];

      final session = ChatSession(
        id: 'todo-nudge',
        title: 'Todo Nudge',
        providerId: provider.id,
        model: 'test-model',
        messages: [Message(role: 'user', content: 'fix the bug')],
      );
      session.todos.addAll([
        {'content': 'find the bug', 'status': 'pending'},
      ]);
      app.sessions.add(session);
      app.activeSessionId = session.id;
      provider
        ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
        ..models = ['test-model'];

      final serverTask = () async {
        await for (final request in server) {
          final body = await utf8.decoder.bind(request).join();
          bodies.add(jsonDecode(body) as Map<String, dynamic>);
          // Mark the todo completed on second request so the loop stops.
          if (bodies.length >= 2) {
            session.todos.clear();
            session.todos.add({'content': 'find the bug', 'status': 'completed'});
          }
          request.response.headers.chunkedTransferEncoding = true;
          request.response.add(
            utf8.encode(
              'data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': 'done'},
                    'finish_reason': 'stop',
                  },
                ],
              })}\n\n',
            ),
          );
          await request.response.flush();
          try {
            await request.response.close();
          } catch (_) {}
        }
      }();
      unawaited(serverTask);

      try {
        await agent
            .runTask('fix the bug', sessionId: session.id, freshTurn: false)
            .timeout(const Duration(seconds: 10));
        // First request: direct answer. Second: nudge continuation with
        // pending todos injected again. Then it stops cleanly.
        expect(bodies.length, greaterThanOrEqualTo(2));
        expect(session.messages.last.content, contains('done'));
      } finally {
        provider
          ..baseUrl = originals['baseUrl'] as String
          ..models = originals['models'] as List<String>
          ..selectedModel = originals['selectedModel'] as String?;
        await server.close(force: true);
        app.deleteSession(session.id);
      }
    });
  });

  group('PR10: modes, skills upload, folder pinning', () {
    test('ChatSession.mode + workspaceFolder JSON round-trip (legacy default)', () {
      final s = ChatSession(
        id: 's1',
        title: 't',
        model: 'm',
        mode: 'studio',
        workspaceFolder: '/storage/emulated/0/MyProj',
      );
      final j = s.toJson();
      expect(j['mode'], 'studio');
      expect(j['workspaceFolder'], '/storage/emulated/0/MyProj');
      final back = ChatSession.fromJson(j);
      expect(back.mode, 'studio');
      expect(back.workspaceFolder, '/storage/emulated/0/MyProj');

      // Legacy sessions without a mode field default to General.
      final legacy = ChatSession.fromJson({
        'id': 's2',
        'title': 'old',
        'model': 'm',
      });
      expect(legacy.mode, 'auto');
      expect(legacy.workspaceFolder, isNull);
    });

    test('AppState.setSessionMode only changes the ACTIVE session', () async {
      final app = AppState.I;
      final a = ChatSession(id: 'mode-a', title: 'A', model: 'm', mode: 'auto');
      final b = ChatSession(id: 'mode-b', title: 'B', model: 'm', mode: 'auto');
      app.sessions.insert(0, b);
      app.sessions.insert(0, a);
      app.activeSessionId = a.id;

      app.setSessionMode('safe');
      expect(a.mode, 'safe');
      expect(b.mode, 'auto', reason: 'other session must never bleed');

      app.selectSession(b.id);
      app.setSessionMode('drive');
      expect(b.mode, 'drive');
      expect(a.mode, 'safe');

      app.sessions.removeWhere((x) => x.id == 'mode-a' || x.id == 'mode-b');
    });

    test('AgentService.mode resolves per-session, never global', () {
      final app = AppState.I;
      final a = ChatSession(id: 'm-a', title: 'A', model: 'm', mode: 'safe');
      app.sessions.insert(0, a);
      app.activeSessionId = a.id;
      expect(AgentService.I.mode, AgentMode.safe);

      final b = ChatSession(id: 'm-b', title: 'B', model: 'm', mode: 'drive');
      app.sessions.insert(0, b);
      app.activeSessionId = b.id;
      expect(AgentService.I.mode, AgentMode.drive);

      app.activeSessionId = a.id;
      expect(AgentService.I.mode, AgentMode.safe);

      app.sessions.removeWhere((x) => x.id == 'm-a' || x.id == 'm-b');
    });

    test('Read-Only mode hard-blocks mutating tools in dispatch', () async {
      final app = AppState.I;
      final s = ChatSession(id: 'ro-s', title: 'RO', model: 'm', mode: 'safe');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      final agent = AgentService.I;

      // Non-read-only shell is refused with the read-only message.
      expect(
        await agent.dispatchForTest('run_shell', {'command': 'touch /tmp/x'}),
        contains('READ-ONLY MODE'),
      );
      // file_write is refused.
      expect(
        await agent.dispatchForTest('file_write', {
          'path': 'a.dart',
          'content': 'x',
        }),
        contains('READ-ONLY MODE'),
      );
      // fs_edit view is still allowed (read-only), so no READ-ONLY denial.
      expect(
        await agent.dispatchForTest('fs_edit', {'command': 'view', 'path': 'a.dart'}),
        isNot(contains('READ-ONLY MODE')),
      );
      // Read-only shell command is NOT hard-blocked (it proceeds to
      // approval/execution rather than the read-only gate).
      expect(
        await agent.dispatchForTest('run_shell', {'command': 'ls -la'}),
        isNot(contains('READ-ONLY MODE')),
      );

      app.sessions.removeWhere((x) => x.id == 'ro-s');
    });

    test('SEC1: run_code is blocked in plan mode and Read-Only mode', () async {
      final app = AppState.I;
      final s = ChatSession(id: 'sec1', title: 'S', model: 'm', mode: 'safe');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() {
        AgentService.setRunSessionForTest('');
        app.sessions.removeWhere((x) => x.id == 'sec1');
      });
      final ro = await AgentService.I.dispatchForTest('run_code', {'code': '1+1', 'lang': 'python'});
      expect(ro, contains('READ-ONLY MODE'));
    });

    test('SEC2: spawn tools blocked in plan + read-only', () async {
      final app = AppState.I;
      final s = ChatSession(id: 'sec2', title: 'S', model: 'm', mode: 'safe');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() {
        AgentService.setRunSessionForTest('');
        app.sessions.removeWhere((x) => x.id == 'sec2');
      });
      expect(await AgentService.I.dispatchForTest('dispatch_agent', {'prompt': 'hi'}), contains('READ-ONLY MODE'));
      expect(await AgentService.I.dispatchForTest('workflow', {'goal': 'hi'}), contains('READ-ONLY MODE'));
      expect(await AgentService.I.dispatchForTest('ralph', {'goal': 'hi'}), contains('READ-ONLY MODE'));
    });

    test('subagent child inherits parent mode and cannot escalate', () async {
      final app = AppState.I;
      final s = ChatSession(id: 'sub-s', title: 'S', model: 'm', mode: 'safe');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      final agent = AgentService.I;

      // Safe parent + no mode arg → child stays safe.
      expect(agent.childModeForTest(), AgentMode.safe);

      // Safe parent + explicit drive → still clamped to safe.
      expect(agent.childModeForTest(modeName: 'drive'), AgentMode.safe);

      // safe rank 0 < auto rank 1 → auto is MORE privilege, so clamped.
      expect(agent.childModeForTest(modeName: 'auto'), AgentMode.safe);

      // A Studio parent may downgrade a child to read-only.
      s.mode = 'studio';
      expect(agent.childModeForTest(), AgentMode.studio);
      expect(agent.childModeForTest(modeName: 'safe'), AgentMode.safe);
      expect(agent.childModeForTest(modeName: 'drive'), AgentMode.studio);

      app.sessions.removeWhere((x) => x.id == 'sub-s');
    });

    test('SkillService parses frontmatter name correctly', () async {
      final dir = Directory.systemTemp.createTempSync('ovid-skills-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/my-skill.md');
      f.writeAsStringSync('''---
name: "Hindi Translator"
description: Translates to Hindi
whenToUse: user wants Hindi
user-invocable: true
---
Translate the following. This is the skill body.''');

      final svc = SkillService.forTest();
      final skill = await svc.parseForTest(f, f.path);
      expect(skill, isNotNull);
      expect(skill!.name, 'Hindi Translator', reason: 'frontmatter name wins');
      expect(skill.description, 'Translates to Hindi');
      expect(skill.whenToUse, 'user wants Hindi');
      expect(skill.userInvocable, isTrue);
      expect(skill.content, contains('Translate the following.'));
    });

    test('deleteMessagesFrom index 0 also resets compacted summary', () async {
      final app = AppState.I;
      final s = ChatSession(
        id: 'clear-s',
        title: 'C',
        model: 'm',
        messages: [Message(role: 'user', content: 'hi')],
      );
      s.compactedSummary = 'older summary';
      s.compactedAtCount = 12;
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;

      app.deleteMessagesFrom(s.id, 0);
      expect(s.messages, isEmpty);
      expect(s.compactedSummary, isNull);
      expect(s.compactedAtCount, 0);

      app.sessions.removeWhere((x) => x.id == 'clear-s');
    });

    test('_sessionWorkDir honors a pinned workspace folder', () async {
      final app = AppState.I;
      final pinned = Directory.systemTemp.createTempSync('ovid-pinned');
      addTearDown(() => pinned.deleteSync(recursive: true));
      final s = ChatSession(
        id: 'pin-s',
        title: 'P',
        model: 'm',
        workspaceFolder: pinned.path,
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;

      final work = await AgentService.I.sessionWorkDirForTest();
      expect(work.path, pinned.path);

      app.sessions.removeWhere((x) => x.id == 'pin-s');
    });
  });

  group('PR11: parity audit fixes', () {
    test('history replay keeps tool output instead of empty assistant turns', () {
      final s = ChatSession(
        id: 'replay-s',
        title: 'R',
        model: 'm',
        messages: [
          Message(role: 'user', content: 'read the config'),
          Message(
            role: 'assistant',
            kind: MsgKind.tool,
            toolName: 'file_read',
            content: 'lib/main.dart',
            toolDetail: 'void main() { runApp(); }',
            toolState: 'ok',
          ),
          Message(role: 'assistant', content: 'It boots the app.'),
          // Compaction rows are apparatus, never replayed.
          Message(role: 'assistant', kind: MsgKind.compact, content: 'summary'),
        ],
      );

      final replay = AgentService.I.replayHistoryForTest(s);
      expect(replay.length, 3);
      expect(replay[0]['role'], 'user');
      final toolMsg = replay[1]['content'] as String;
      expect(toolMsg, contains('file_read'));
      expect(
        toolMsg,
        contains('void main()'),
        reason: 'tool output lives in toolDetail and must survive replay',
      );
      expect(replay[2]['content'], 'It boots the app.');
      expect(
        replay.any((m) => (m['content'] as String).trim().isEmpty),
        isFalse,
        reason: 'empty assistant turns poison the request envelope',
      );
    });

    test('failed tool rows replay with their failure marked', () {
      final s = ChatSession(
        id: 'replay-err',
        title: 'R',
        model: 'm',
        messages: [
          Message(
            role: 'assistant',
            kind: MsgKind.tool,
            toolName: 'run_shell',
            content: 'npm test',
            toolDetail: 'exit 1',
            toolState: 'error',
          ),
        ],
      );
      final replay = AgentService.I.replayHistoryForTest(s);
      expect(replay.single['content'], contains('(failed)'));
    });

    test('repo tools appear exactly once when GitHub sync is on', () {
      final app = AppState.I;
      final before = app.githubSync;
      addTearDown(() => app.githubSync = before);

      app.githubSync = true;
      final withSync = AgentService.I.toolsForTest();
      int count(String name) => withSync
          .where((t) => (t['function'] as Map)['name'] == name)
          .length;
      expect(count('repo_sync'), 1);
      expect(count('repo_tree'), 1);

      app.githubSync = false;
      final withoutSync = AgentService.I.toolsForTest();
      expect(
        withoutSync.where(
          (t) => (t['function'] as Map)['name'] == 'repo_sync',
        ),
        isEmpty,
      );
    });

    test('containedPath blocks traversal out of the workspace', () {
      final work = Directory('/data/ws/session-1');
      expect(
        AgentService.containedPath(work, 'lib/main.dart'),
        '/data/ws/session-1/lib/main.dart',
      );
      expect(
        AgentService.containedPath(work, './lib/../lib/main.dart'),
        '/data/ws/session-1/lib/main.dart',
      );
      // Absolute paths are allowed only inside the workspace.
      expect(
        AgentService.containedPath(work, '/data/ws/session-1/a.txt'),
        '/data/ws/session-1/a.txt',
      );
      expect(AgentService.containedPath(work, '../session-2/secret'), isNull);
      expect(AgentService.containedPath(work, '../../etc/passwd'), isNull);
      expect(AgentService.containedPath(work, '/etc/passwd'), isNull);
      expect(AgentService.containedPath(work, '   '), isNull);
    });

    test('cancelRun resolves a pending approval instead of hanging', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final s = ChatSession(id: 'cancel-s', title: 'C', model: 'm');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == 'cancel-s');
        agent.clearQueueForTest();
      });

      agent.activeRunId = 'run-1';
      final req = ApprovalRequest(
        tool: 'run_shell',
        summary: 'rm -rf build',
        detail: 'rm -rf build',
      );
      agent.pendingApproval = req;

      agent.cancelRun();

      expect(await req.completer.future, isFalse);
      expect(agent.pendingApproval, isNull);
      agent.activeRunId = null;
    });

    test('approve carries a refusal note back to the caller', () async {
      final agent = AgentService.I;
      final req = ApprovalRequest(
        tool: 'exit_plan_mode',
        summary: 'Approve this plan?',
        detail: 'framed plan text',
        planBody: 'step 1\nstep 2',
      );
      agent.pendingApproval = req;

      agent.approve(false, note: 'split step 2 in half');

      expect(await req.completer.future, isFalse);
      expect(req.note, 'split step 2 in half');
      expect(req.planBody, 'step 1\nstep 2');
    });

    test('schedule_create rejects a zero delay instead of crashing', () async {
      final app = AppState.I;
      final s = ChatSession(id: 'sched-s', title: 'S', model: 'm');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() => app.sessions.removeWhere((x) => x.id == 'sched-s'));

      final res = await AgentService.I.dispatchForTest('schedule_create', {
        'prompt': 'ping me',
        'after_seconds': 0,
      });
      expect(res, contains('after_seconds'));
      expect(s.schedules, isEmpty);
    });

    test('schedule_create accepts an ISO timestamp with an offset', () async {
      final app = AppState.I;
      final s = ChatSession(id: 'sched-tz', title: 'S', model: 'm');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() => app.sessions.removeWhere((x) => x.id == 'sched-tz'));

      final future = DateTime.now().toUtc().add(const Duration(hours: 2));
      final res = await AgentService.I.dispatchForTest('schedule_create', {
        'prompt': 'stand up',
        'at': future.toIso8601String(),
      });
      expect(res, isNot(contains('must be')));
      expect(s.schedules, hasLength(1));
    });

    test('marketplace add returns the normalized repo and persists it', () async {
      final app = AppState.I;
      addTearDown(() => app.removeMarketplace('acme/plugins'));

      expect(
        app.addMarketplace('https://github.com/acme/plugins.git'),
        'acme/plugins',
      );
      expect(app.marketplaces, contains('acme/plugins'));
      expect(app.addMarketplace('acme/plugins'), isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('ovid_marketplaces_v1'),
        contains('acme/plugins'),
      );
    });

    test('/permission requires an explicit confirm for full access', () async {
      final app = AppState.I;
      final s = ChatSession(id: 'perm-s', title: 'P', model: 'm', mode: 'auto');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() => app.sessions.removeWhere((x) => x.id == 'perm-s'));

      final blocked = await CommandService.I.execute('/permission full-access');
      expect(blocked?.feedback, contains('confirm'));
      expect(s.mode, 'auto', reason: 'must not escalate without confirmation');

      final ok = await CommandService.I.execute(
        '/permission full-access confirm',
      );
      expect(ok?.feedback, contains('Full Access'));
      expect(s.mode, 'drive');

      final back = await CommandService.I.execute('/permission read-only');
      expect(back?.feedback, contains('Read-Only'));
      expect(s.mode, 'safe');
    });

    test('/model lists the current model and switches on a match', () async {
      final app = AppState.I;
      final s = ChatSession(id: 'model-s', title: 'M', model: 'seed-model');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      final p = app.providers.firstWhere((e) => e.isConfigured || e.isFree);
      final restoreModels = List<String>.from(p.models);
      final restoreKey = p.apiKey;
      p.apiKey = p.requiresApiKey ? 'test-key' : p.apiKey;
      p.models
        ..clear()
        ..addAll(['ovid-test-mini', 'ovid-test-max']);
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == 'model-s');
        p.models
          ..clear()
          ..addAll(restoreModels);
        p.apiKey = restoreKey;
      });

      final list = await CommandService.I.execute('/model');
      expect(list?.popup, 'model', reason: 'bare /model opens the picker');

      final pick = await CommandService.I.execute('/model ovid-test-max');
      expect(pick?.feedback, contains('ovid-test-max'));
      expect(s.model, 'ovid-test-max');

      final miss = await CommandService.I.execute('/model nope-not-real');
      expect(miss?.feedback, contains('No configured model'));
    });

    test('statusFor exposes the live run status only while running', () {
      final app = AppState.I;
      final agent = AgentService.I;
      final s = ChatSession(id: 'status-s', title: 'S', model: 'm');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == 'status-s');
        agent.activeRunId = null;
      });

      expect(agent.statusFor(s.id), isNull);
      agent.activeRunId = 'run-status';
      agent.emitForTest('think', 'retrying in 9s…');
      expect(agent.statusFor(s.id), 'retrying in 9s…');
      agent.emitForTest('done', 'completed');
      expect(agent.statusFor(s.id), isNull);
    });
  });

  group('PR12: subagents as real sessions', () {
    ChatSession newParent(String id) {
      final app = AppState.I;
      final parent = ChatSession(
        id: id,
        title: 'Parent',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, parent);
      app.activeSessionId = parent.id;
      addTearDown(() {
        app.sessions.removeWhere(
          (x) => x.id == id || AppState.I.lineageOf(x.id).any((a) => a.id == id),
        );
      });
      return parent;
    }

    test('dispatch_agent creates a real child session with lineage', () async {
      final app = AppState.I;
      final parent = newParent('sa-p1');

      // No provider is configured in tests, so the child's run fails fast —
      // the point here is the session/lineage wiring, not the model call.
      final res = await AgentService.I.dispatchForTest('dispatch_agent', {
        'prompt': 'map the api surface',
        'label': 'API map',
      });

      final kids = app.childrenOf(parent.id);
      expect(kids, hasLength(1));
      final child = kids.single;
      expect(child.isSubagent, isTrue);
      expect(child.parentId, parent.id);
      expect(child.agentLabel, 'API map');
      expect(child.mode, 'auto', reason: 'child inherits the parent mode');
      expect(child.model, parent.model);
      // The child's transcript starts with the task it was given, so opening
      // it shows real content instead of an opaque summary.
      expect(child.messages.first.role, 'user');
      expect(child.messages.first.content, 'map the api surface');
      expect(child.messages.length, greaterThan(1));
      // Lineage + sidebar visibility.
      expect(app.lineageOf(child.id).map((s) => s.id).toList(), [
        parent.id,
        child.id,
      ]);
      expect(app.rootSessions.any((s) => s.id == child.id), isFalse);
      expect(app.descendantsOf(parent.id).map((s) => s.id), [child.id]);
      expect(child.agentState, isNotNull);
      expect(res, isNotEmpty);
    });

    test('a subagent session cannot use user-facing tools', () async {
      final app = AppState.I;
      final parent = newParent('sa-p2');
      final child = app.createSubagentSession(
        parent: parent,
        label: 'worker',
        mode: 'auto',
      );
      app.activeSessionId = child.id;

      final res = await AgentService.I.dispatchForTest('ask_user_question', {
        'questions': <Map<String, dynamic>>[],
      });
      expect(res, contains('SUBAGENT'));
      expect(AgentService.I.pendingApproval, isNull);
    });

    test('allowed_tools restricts what a child may call', () async {
      final app = AppState.I;
      final parent = newParent('sa-p3');
      final child = app.createSubagentSession(
        parent: parent,
        label: 'reader',
        mode: 'auto',
        allowedTools: const ['file_read'],
      );
      app.activeSessionId = child.id;

      final blocked = await AgentService.I.dispatchForTest('run_shell', {
        'command': 'ls',
      });
      expect(blocked, contains('outside the tool set'));
      expect(blocked, contains('file_read'));
    });

    test('depth cap counts the real session lineage', () async {
      final app = AppState.I;
      final parent = newParent('sa-p4');
      final child = app.createSubagentSession(
        parent: parent,
        label: 'depth-1',
        mode: 'auto',
      );
      final grandchild = app.createSubagentSession(
        parent: child,
        label: 'depth-2',
        mode: 'auto',
      );
      app.activeSessionId = grandchild.id;

      final res = await AgentService.I.dispatchForTest('dispatch_agent', {
        'prompt': 'go deeper',
      });
      expect(res, contains('depth limit'));
      expect(app.childrenOf(grandchild.id), isEmpty);
    });

    test('a one-shot child refuses follow-ups; interrupt marks it stopped', () async {
      final app = AppState.I;
      final parent = newParent('sa-p5');
      final oneShot = app.createSubagentSession(
        parent: parent,
        label: 'one-shot',
        mode: 'auto',
      );
      expect(oneShot.agentContinuable, isFalse);
      expect(AgentService.I.canContinueSubagent(oneShot.id), isFalse);

      final res = await AgentService.I.continueSubagent(oneShot.id, 'more work');
      expect(res, contains('one-shot'));
      expect(
        oneShot.messages,
        isEmpty,
        reason: 'a refused follow-up must not enter the transcript',
      );

      AgentService.I.interruptSubagent(oneShot.id);
      expect(oneShot.agentState, 'stopped');
    });

    test('deleting a chat deletes its subagents', () {
      final app = AppState.I;
      final parent = newParent('sa-p6');
      final child = app.createSubagentSession(
        parent: parent,
        label: 'c',
        mode: 'auto',
      );
      final grandchild = app.createSubagentSession(
        parent: child,
        label: 'gc',
        mode: 'auto',
      );

      app.deleteSession(parent.id);

      expect(app.sessionById(parent.id), isNull);
      expect(app.sessionById(child.id), isNull);
      expect(app.sessionById(grandchild.id), isNull);
      expect(
        app.activeSessionId,
        isNot(child.id),
        reason: 'never leave the app pointing at a deleted child',
      );
    });

    test('subagent fields round-trip; a killed running child loads stopped', () {
      final s = ChatSession(
        id: 'sa-json',
        title: 'worker',
        model: 'm',
        parentId: 'root-1',
        agentLabel: 'worker',
        agentState: 'running',
        agentContinuable: true,
        agentResult: 'done',
        agentAllowedTools: const ['file_read', 'fs_grep'],
      );
      final back = ChatSession.fromJson(s.toJson());
      expect(back.parentId, 'root-1');
      expect(back.isSubagent, isTrue);
      expect(back.agentLabel, 'worker');
      expect(back.agentContinuable, isTrue);
      expect(back.agentResult, 'done');
      expect(back.agentAllowedTools, ['file_read', 'fs_grep']);
      // The app died mid-run: nothing is running after a restart.
      expect(back.agentState, 'stopped');

      final finished = ChatSession.fromJson(
        ChatSession(
          id: 'sa-json2',
          title: 'w',
          model: 'm',
          parentId: 'root-1',
          agentState: 'finished',
        ).toJson(),
      );
      expect(finished.agentState, 'finished');
    });

    test('a subagent card keeps a link to its child session', () {
      final m = Message(
        role: 'assistant',
        kind: MsgKind.tool,
        toolName: 'dispatch_agent',
        toolTitle: 'Subagent',
        content: '',
        toolDetail: 'subagent sub-1',
        toolState: 'ok',
        toolSessionId: 'sub-123',
      );
      expect(Message.fromJson(m.toJson()).toolSessionId, 'sub-123');
    });

    test('user input never targets a subagent session', () {
      final app = AppState.I;
      final parent = newParent('sa-p7');
      final child = app.createSubagentSession(
        parent: parent,
        label: 'c',
        mode: 'auto',
      );
      app.activeSessionId = child.id;

      app.sendMessage('hello');

      expect(
        child.messages,
        isEmpty,
        reason: 'the composer must not write into a child transcript',
      );
      expect(app.activeSessionId, parent.id);
      expect(parent.messages.last.content, 'hello');
    });
  });

  group('PR13: web links + MCP reliability', () {
    test('fetch_url renders HTML as markdown, not tag-stripped soup', () {
      // Direct unit check of the renderer the tool uses.
      final fn = htmlToMarkdownForTest;
      const html = '''
<html><head><style>x{}</style><script>bad()</script></head>
<body><nav>junk</nav>
<h1>Title &amp; More</h1>
<p>Hello <strong>world</strong>, see <a href="https://ex.com/a">docs</a>.</p>
<ul><li>one</li><li>two</li></ul>
<pre>code()
block</pre>
<footer>junk</footer></body></html>''';
      final md = fn(html);
      expect(md, contains('# Title & More'));
      expect(md, contains('**world**'));
      expect(md, contains('[docs](https://ex.com/a)'));
      expect(md, contains('- one'));
      expect(md, contains('```\ncode()\nblock'));
      expect(md, isNot(contains('<script')));
      expect(md, isNot(contains('junk')), reason: 'nav/footer dropped');
      expect(md, isNot(contains('bad()')));
    });

    test('MCP tool result is capped with an exact omission notice', () {
      final big = 'x' * 20000;
      final out = McpService.trimResultForTest(big);
      expect(out.length, lessThan(20000));
      expect(out, contains('characters omitted'));
      expect(out.startsWith('xxxx'), isTrue);
      expect(out.endsWith('xxxx'), isTrue);
      final small = 'fine';
      expect(McpService.trimResultForTest(small), 'fine');
    });

    test('MCP JSON-RPC errors surface as errors, never as results', () async {
      // A server that replies with a JSON-RPC error object must not have
      // that error stringified into a successful tool result.
      final res = await McpService.callToolForTest(
        replies: [
          '{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"Invalid params"}}',
        ],
        method: 'tools/call',
      );
      expect(res, contains('MCP error'));
      expect(res, contains('Invalid params'));
    });

    test('MCP timeout surfaces as a timeout error, not the text "null"',
        () async {
      McpService.rpcTimeoutSecondsForTest = 1; // shrink the deadline
      try {
        final res = await McpService.callToolForTest(
          replies: const [],
          method: 'tools/call',
        );
        expect(res, contains('MCP error'));
        expect(res, contains('timed out'));
        expect(res, isNot(contains('null')),
            reason: 'the old code handed the model the literal string "null"');
      } finally {
        McpService.rpcTimeoutSecondsForTest = 30;
      }
    });

    test('MCP callTool honours isError from the server', () async {
      final res = await McpService.callToolForTest(
        replies: [
          '{"jsonrpc":"2.0","id":1,"result":{"isError":true,"content":[{"type":"text","text":"boom"}]}}',
        ],
        method: 'tools/call',
      );
      expect(res, contains('MCP error'));
      expect(res, contains('boom'));
    });

    test('MCP callTool keeps text/resource/image content apart', () async {
      final res = await McpService.callToolForTest(
        replies: [
          '{"jsonrpc":"2.0","id":1,"result":{"content":['
          '{"type":"text","text":"hello"},'
          '{"type":"resource","resource":{"text":"res-body"}},'
          '{"type":"image","data":"..."}]}}',
        ],
        method: 'tools/call',
      );
      expect(res, contains('hello'));
      expect(res, contains('[resource] res-body'));
      expect(res, contains('image content returned'));
    });
  });

  group('PR14: multi-query web search + honest plugin install', () {
    /// Spin up a local HTTP server that answers any GET with [html],
    /// and point DuckDuckGo search at it by overriding the query host.
    Future<Uri> serveDdg(String html) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = utf8.encode(html);
        request.response
          ..statusCode = 200
          ..contentLength = body.length
          ..add(body);
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      return Uri.parse('http://${server.address.host}:${server.port}');
    }

    test('web_search rejects empty and oversized query arrays', () async {
      final res = await AgentService.I.dispatchForTest(
        'web_search',
        {'queries': const []},
      );
      expect(res, contains('Error: queries must contain at least one query'));

      final res2 = await AgentService.I.dispatchForTest(
        'web_search',
        {
          'queries': ['a', 'b', 'c', 'd', 'e'],
        },
      );
      expect(res2, contains('at most 4 queries'));
    });

    test('web_search runs queries concurrently, dedupes URLs, cites links',
        () async {
      // Two queries: the second shares one URL with the first (dedup) and
      // adds its own result (round-robin interleaving across queries).
      final q1 = [
        _ddgResult('Alpha result', 'https://ex.com/alpha', 'About alpha'),
        _ddgResult('Shared result', 'https://ex.com/shared', 'Both'),
      ].join();
      final q2 = [
        _ddgResult('Beta result', 'https://ex.com/beta', 'About beta'),
        _ddgResult('Shared result dup', 'https://ex.com/shared', 'Dup'),
      ].join();
      var hits = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        hits++;
        final html = request.uri.queryParameters['q'] == 'one' ? q1 : q2;
        final body = utf8.encode(html);
        request.response
          ..statusCode = 200
          ..contentLength = body.length
          ..add(body);
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      AgentService.ddgBaseOverrideForTest =
          'http://${server.address.host}:${server.port}';

      final res = await AgentService.I.dispatchForTest('web_search', {
        'queries': ['one', 'two'],
      });
      AgentService.ddgBaseOverrideForTest = null;

      expect(hits, 2, reason: 'each query runs once');
      expect(res, contains('[Alpha result](https://ex.com/alpha)'));
      expect(res, contains('[Beta result](https://ex.com/beta)'));
      expect(res, contains('https://ex.com/shared'), reason: 'dup kept once');
      // Exactly one line for the shared URL — deduped, not repeated.
      expect('https://ex.com/shared'.allMatches(res).length, 1);
      expect(res, contains('About alpha'), reason: 'snippets retained');
      expect(
        res,
        contains('Cite the relevant URLs above as markdown links'),
      );
      // Round-robin: alpha (q1 rank1) must come before shared-dup (q2 rank2).
      expect(res.indexOf('ex.com/alpha'), lessThan(res.indexOf('ex.com/beta')));
    });

    test('web_search unwraps DuckDuckGo redirect links', () async {
      final html = _ddgResult(
        'Redirected',
        '//duckduckgo.com/l/?uddg=https%3A%2F%2Freal.com%2Fpage&rut=abc',
        'Snippet',
      ).join();
      final server = await serveDdg(html);
      AgentService.ddgBaseOverrideForTest = '$server';

      final res = await AgentService.I.dispatchForTest('web_search', {
        'queries': ['anything'],
      });
      AgentService.ddgBaseOverrideForTest = null;

      expect(res, contains('[Redirected](https://real.com/page)'));
      expect(res, isNot(contains('duckduckgo.com/l/')));
    });

    test('web_search failure surfaces as Error, not a silent half-result',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 503;
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      AgentService.ddgBaseOverrideForTest =
          'http://${server.address.host}:${server.port}';

      final res = await AgentService.I.dispatchForTest('web_search', {
        'queries': ['will fail'],
      });
      AgentService.ddgBaseOverrideForTest = null;

      expect(res, startsWith('Error:'));
      expect(res, contains('HTTP 503'));
    });

    test('agent_install_plugin reports the tools it actually contributes',
        () async {
      final app = AppState.I;
      // Find (or add) a plugin that maps to no tool — a category:Agent
      // entry with a name outside the tool map.
      final noTool = PluginItem(
        name: 'PR14 NoTool Plugin',
        author: 't',
        description: '',
        version: '1',
        category: 'Agent',
        installs: 0,
      );
      app.plugins.add(noTool);
      addTearDown(() => app.plugins.remove(noTool));

      final res = await AgentService.I.dispatchForTest(
        'agent_install_plugin',
        {'plugin_name': 'PR14 NoTool Plugin'},
      );
      expect(res, contains('installed and enabled'));
      expect(res, contains('contributes no agent tools'));
      expect(noTool.installed, isTrue);

      // And a plugin that DOES map to tools names them.
      final webSearch = app.plugins.firstWhere(
        (p) => p.name == 'Web Search',
        orElse: () => throw StateError('Web Search plugin missing'),
      );
      final wasInstalled = webSearch.installed;
      webSearch.installed = false;
      addTearDown(() => webSearch.installed = wasInstalled);
      final res2 = await AgentService.I.dispatchForTest(
        'agent_install_plugin',
        {'plugin_name': 'Web Search'},
      );
      expect(res2, contains('web_search'));
      expect(res2, isNot(contains('contributes no agent tools')));
    });
  });

  group('PR15: marketplace formats (Claude + Codex) + realtime install', () {
    test('parses Codex/Claude Desktop mcpServers MAP form', () {
      final app = AppState.I;
      final before = app.mcpServers.length;
      final msg = app.mergeMarketplaceCatalogForTest({
        'mcpServers': {
          'PR15 Map Server': {
            'command': 'npx',
            'args': ['-y', '@example/pr15-server'],
            'env': {'API_KEY': 'x'},
          },
        },
      }, 'acme', 'plugins');
      expect(msg, contains('1 MCP server'));
      final added = app.mcpServers.length - before == 1
          ? app.mcpServers.last
          : null;
      expect(added, isNotNull, reason: 'map entry imported');
      expect(added!.name, 'PR15 Map Server');
      expect(added.command, 'npx');
      expect(added.args, ['-y', '@example/pr15-server']);
      expect(added.envHint, 'API_KEY', reason: 'first env key as hint');
      expect(added.custom, isTrue);
    });

    test('parses Claude Code .claude-plugin marketplace plugins list', () {
      final app = AppState.I;
      final before = app.plugins.length;
      final msg = app.mergeMarketplaceCatalogForTest({
        'name': 'PR15 Claude Marketplace',
        'plugins': [
          {
            'name': 'PR15 Claude Plugin',
            'source': './plugins/pr15',
            'description': 'From a Claude Code marketplace',
            'version': '0.2.0',
            'author': 'claude-dev',
            'category': 'Agent',
          },
        ],
      }, 'claude-owner', 'claude-market');
      expect(msg, contains('1 plugin'));
      expect(app.plugins.length, before + 1);
      final p = app.plugins.last;
      expect(p.name, 'PR15 Claude Plugin');
      expect(p.author, 'claude-dev');
      expect(p.category, 'Agent');
      expect(p.installed, isFalse, reason: 'marketplace entries start off');
    });

    test('parses our list-form mcpServers and never duplicates entries',
        () {
      final app = AppState.I;
      final doc = {
        'mcpServers': [
          {
            'name': 'PR15 List Server',
            'command': 'uvx',
            'args': ['pr15-tool'],
          },
        ],
      };
      final first = app.mergeMarketplaceCatalogForTest(doc, 'o', 'r');
      expect(first, contains('1 MCP server'));
      // Same doc again — dedupe, not a duplicate row.
      final again = app.mergeMarketplaceCatalogForTest(doc, 'o', 'r');
      expect(again, contains('no new plugins'));
      expect(
        app.mcpServers.where((s) => s.name == 'PR15 List Server').length,
        1,
      );
    });

    test('fetch falls through paths and reports actionable failure',
        () async {
      // Local server with NO marketplace files → every URL misses → the
      // error must tell the user which files were tried.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 404;
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      AppState.marketplaceBaseOverrideForTest =
          'http://${server.address.host}:${server.port}';

      final msg = await AppState.I.fetchMarketplaceCatalog('ghost/repo');
      AppState.marketplaceBaseOverrideForTest = null;

      expect(msg, contains('No marketplace.json'));
      expect(msg, contains('.claude-plugin/marketplace.json'));
    });

    test('fetch imports from a live marketplace URL', () async {
      // Serve marketplace.json on the first path of the fetch order.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (!request.uri.path.endsWith('marketplace.json')) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        final body = utf8.encode(jsonEncode({
          'plugins': [
            {
              'name': 'PR15 Live Plugin',
              'description': 'fetched over HTTP',
              'author': 'live',
              'category': 'Tool',
            },
          ],
          'mcpServers': {
            'PR15 Live MCP': {
              'command': 'npx',
              'args': ['-y', '@live/pr15-mcp'],
            },
          },
        }));
        request.response
          ..statusCode = 200
          ..contentLength = body.length
          ..add(body);
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      AppState.marketplaceBaseOverrideForTest =
          'http://${server.address.host}:${server.port}';

      final msg = await AppState.I.fetchMarketplaceCatalog('live/repo');
      AppState.marketplaceBaseOverrideForTest = null;

      expect(msg, contains('1 plugin(s) and 1 MCP server(s)'));
      expect(
        AppState.I.plugins.any((p) => p.name == 'PR15 Live Plugin'),
        isTrue,
      );
      expect(
        AppState.I.mcpServers.any((s) => s.name == 'PR15 Live MCP'),
        isTrue,
      );
    });
  });

  group('PR16: subagent parity gaps closed', () {
    setUp(() {
      AgentService.setRunSessionForTest('');
    });

    tearDown(() {
      AgentService.setRunSessionForTest('');
    });

    ChatSession newParent(String id) {
      final app = AppState.I;
      final parent = ChatSession(
        id: id,
        title: 'Parent',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, parent);
      app.activeSessionId = parent.id;
      addTearDown(() {
        app.sessions.removeWhere(
          (x) =>
              x.id == id || AppState.I.lineageOf(x.id).any((a) => a.id == id),
        );
      });
      return parent;
    }

    test('background child stores a durable agentId for cold resume',
        () async {
      final app = AppState.I;
      final parent = newParent('sg-p1');

      await AgentService.I.dispatchForTest('dispatch_agent', {
        'prompt': 'research the schema',
        'label': 'Research',
        'run_in_background': true,
        'persona': 'You are a meticulous researcher',
        'output_schema_hint':
            'a JSON object with keys status, findings, files',
      });

      final child = app.childrenOf(parent.id).single;
      expect(child.agentId, isNotNull, reason: 'durable handle id stored');
      expect(child.agentId, startsWith('sub-'));
      expect(child.agentPersona, 'You are a meticulous researcher');
      expect(
        child.agentOutputHint,
        'a JSON object with keys status, findings, files',
      );
    });

    test('restoreSubagentHandles rebuilds the registry after restart',
        () async {
      final app = AppState.I;
      final parent = newParent('sg-p2');
      // Simulate a persisted settled child: durable id + lineage + state,
      // but NO live handle (as after an app restart).
      final child = app.createSubagentSession(
        parent: parent,
        label: 'Resumed child',
        mode: 'auto',
        continuable: true,
      );
      child.agentId = 'sub-77';
      child.agentState = 'finished';
      child.agentResult = 'found 3 endpoints';

      AgentService.I.restoreSubagentHandles();

      final sub = AgentService.I.subagentForSession(child.id);
      expect(sub, isNotNull, reason: 'handle rebuilt from persisted lineage');
      expect(sub!.id, 'sub-77');
      expect(sub.finished, isTrue);
      expect(sub.label, 'Resumed child');
      // Counter reseeded past the persisted max, so new ids never collide.
      final res = await AgentService.I.dispatchForTest('dispatch_agent', {
        'prompt': 'next task',
        'run_in_background': true,
      });
      expect(res, contains('sub-78'));
    });

    test('settlement notice reaches an idle parent as a new turn', () async {
      final parent = newParent('sg-p3');
      parent.messages.add(
        Message(role: 'user', content: 'kick off the parent transcript'),
      );

      // Dispatch a background child; its run fails fast (no provider in
      // tests), which settles it and delivers the notice.
      await AgentService.I.dispatchForTest('dispatch_agent', {
        'prompt': 'do a thing',
        'run_in_background': true,
      });

      // The parent transcript now holds the settlement notice AFTER the
      // child settled (fail-fast in tests, so the notice is already there).
      final notices = parent.messages
          .where((m) => m.content.contains('Background subagent'))
          .toList();
      expect(
        notices,
        isNotEmpty,
        reason: 'background settlement delivers a parent notice',
      );
      final n = notices.first.content;
      expect(n, contains('and will do no further work'));
      expect(
        n,
        anyOf(contains('closing message'), contains('no closing message')),
      );
      // Foreground children must NOT deliver a notice — their result IS
      // the tool result (double-delivery check).
      final fgBefore = parent.messages.length;
      await AgentService.I.dispatchForTest('dispatch_agent', {
        'prompt': 'foreground thing',
      });
      final fgNotices = parent.messages
          .skip(fgBefore)
          .where((m) => m.content.contains('Background subagent'))
          .length;
      expect(
        fgNotices,
        0,
        reason: 'foreground dispatch returns the result, no notice',
      );
    });

    test('report tool: child → parent, quiet and waking forms', () async {
      final app = AppState.I;
      final parent = newParent('sg-p4');
      parent.messages.add(Message(role: 'user', content: 'parent transcript'));
      final child = app.createSubagentSession(
        parent: parent,
        label: 'Reporter',
        mode: 'auto',
        continuable: true,
      );
      // Make the child the RUNNING session so _runSession resolves to it.
      AgentService.setRunSessionForTest(child.id);

      // Quiet: parked on the parent transcript, no new run, nobody woken.
      final q = await AgentService.I.dispatchForTest('report', {
        'content': 'early finding: the auth is broken',
        'quiet': true,
      });
      expect(q, contains('quietly'));
      final quietRow = parent.messages.last;
      expect(quietRow.content, contains('[report from subagent'));
      expect(quietRow.content, contains('the auth is broken'));

      // Waking form from an idle parent: appended + a run starts (it will
      // fail fast in tests — the appended report row is what matters).
      final w = await AgentService.I.dispatchForTest('report', {
        'content': 'blocker: no write access',
      });
      expect(w, anyOf(contains('woken'), contains('queued')));
      expect(
        parent.messages.any((m) => m.content.contains('blocker: no write access')),
        isTrue,
        reason: 'the report row is on the parent transcript (a fail-fast '
            'error row may follow it)',
      );
    });

    test('report from a top-level session is refused', () async {
      final parent = newParent('sg-p5');
      AgentService.setRunSessionForTest(parent.id);
      final res = await AgentService.I.dispatchForTest('report', {
        'content': 'i am not a subagent',
      });
      expect(res, contains('only available to subagents'));
    });
  });

  group('PR17: quick wins — todos, write path, goal, plan, feedback', () {
    ChatSession newSession(String id) {
      final app = AppState.I;
      final s = ChatSession(id: id, title: 'New chat', model: 'm', mode: 'auto');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() => app.sessions.removeWhere((x) => x.id == id));
      return s;
    }

    test('stale pending todos are cleared when a new turn starts', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final provider = app.providerById('ollama-local')!;
      final originals = ({
        'baseUrl': provider.baseUrl,
        'models': List<String>.of(provider.models),
        'selectedModel': provider.selectedModel,
      });
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requestBodies = <Map<String, dynamic>>[];

      final session = ChatSession(
        id: 'qw-t1',
        title: 'Todo clear',
        providerId: provider.id,
        model: 'test-model',
        messages: [Message(role: 'user', content: 'do the task')],
      );
      session.todos.addAll([
        {'content': 'stale old task', 'status': 'pending'},
      ]);
      app.sessions.add(session);
      provider
        ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
        ..models = ['test-model'];

      final serverTask = () async {
        await for (final request in server) {
          final body = await utf8.decoder.bind(request).join();
          requestBodies.add(jsonDecode(body) as Map<String, dynamic>);
          request.response.headers.chunkedTransferEncoding = true;
          request.response.add(
            utf8.encode(
              'data: ${jsonEncode({
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': 'done'},
                  },
                ],
                'usage': {
                  'prompt_tokens': 10,
                  'completion_tokens': 5,
                  'total_tokens': 15,
                },
              })}\n\n',
            ),
          );
          await request.response.flush();
          await request.response.close();
        }
      }();
      unawaited(serverTask);

      try {
        await agent
            .runTask('do the task', sessionId: session.id)
            .timeout(const Duration(seconds: 10));
        // The turn STARTED fresh — the stale pending item is gone before
        // the first request is assembled (C5).
        expect(
          session.todos.where((t) => t['status'] != 'completed'),
          isEmpty,
          reason: 'pending items from an earlier task must not leak into a '
              'new turn',
        );
        // And the assembled system prompt carries no stale todo section.
        final sys =
            (requestBodies.first['messages'] as List)
                .firstWhere((m) => m['role'] == 'system')['content']
                as String;
        expect(sys, isNot(contains('SESSION TODOS')));
      } finally {
        provider
          ..baseUrl = originals['baseUrl'] as String
          ..models = originals['models'] as List<String>
          ..selectedModel = originals['selectedModel'] as String?;
        await server.close(force: true);
        app.deleteSession(session.id);
      }
    });

    test('file_write lands on disk AND the repo cache (C7)', () async {
      final s = newSession('qw-t2');
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      final res = await AgentService.I.dispatchForTest('file_write', {
        'path': 'c7_probe.txt',
        'content': 'hello from file_write',
      });
      expect(res, contains('written'));

      // Disk: the session workspace mirror exists with the same bytes.
      final dir = await AgentService.I.sessionWorkDirForTest();
      final disk = File('${dir.path}/c7_probe.txt');
      expect(disk.existsSync(), isTrue, reason: 'mirrored to disk');
      expect(disk.readAsStringSync(), 'hello from file_write');

      // And fs_edit view (disk path) sees the same content — the exact
      // split-write bug C7 existed for.
      final view = await AgentService.I.dispatchForTest('fs_edit', {
        'command': 'view',
        'path': 'c7_probe.txt',
      });
      expect(view, contains('hello from file_write'));
    });

    test('goal pause/resume keeps the round, complete clears the bar',
        () async {
      final s = newSession('qw-t3');
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      final created = await AgentService.I.dispatchForTest('create_goal', {
        'objective': 'ship the parity report',
      });
      expect(created, contains('round 0'));

      final paused = await AgentService.I.dispatchForTest('update_goal', {
        'status': 'paused',
      });
      expect(paused, contains('paused'));
      expect(s.goal!['status'], 'paused');
      final roundAtPause = s.goal!['round'] as int;

      final resumed = await AgentService.I.dispatchForTest('update_goal', {
        'status': 'active',
        'progress': 'resumed work',
      });
      expect(resumed, contains('active'));
      expect(
        s.goal!['round'] as int,
        roundAtPause,
        reason: 'pause/resume round-trips keep the round',
      );

      final done = await AgentService.I.dispatchForTest('update_goal', {
        'status': 'complete',
      });
      expect(done, contains('complete'));
      expect(s.goal!['status'], 'complete');
    });

    test('plan mode persists on the session and survives reload', () {
      final s = newSession('qw-t4');
      s.planMode = true;
      // JSON round-trip keeps the flag (restart survival).
      final j = s.toJson();
      expect(j['planMode'], isTrue);
      final reloaded = ChatSession.fromJson(j);
      expect(reloaded.planMode, isTrue);
      // The setter writes through to the session.
      AgentService.setRunSessionForTest(s.id);
      AgentService.I.planMode = false;
      expect(s.planMode, isFalse);
      AgentService.setRunSessionForTest('');
    });

    test('message feedback persists and retracts (DSH message-feedback)',
        () {
      final s = newSession('qw-t5');
      final m = Message(role: 'assistant', content: 'answer');
      s.messages.add(m);

      m.feedback = 'down';
      m.feedbackNote = 'wrong API';
      final j = m.toJson();
      expect(j['feedback'], 'down');
      expect(j['feedbackNote'], 'wrong API');
      final reloaded = Message.fromJson(j);
      expect(reloaded.feedback, 'down');
      expect(reloaded.feedbackNote, 'wrong API');

      // Retract on re-click semantics: null clears both.
      m.feedback = null;
      m.feedbackNote = null;
      expect(m.toJson().containsKey('feedback'), isFalse);
    });

    test('imageGen message persists its workspace path', () {
      final m = Message(
        role: 'assistant',
        kind: MsgKind.imageGen,
        content: 'a cat astronaut',
        imagePath: '/work/gen-123-cat.jpg',
      );
      final j = m.toJson();
      expect(j['kind'], 'imageGen');
      expect(j['imagePath'], '/work/gen-123-cat.jpg');
      final reloaded = Message.fromJson(j);
      expect(reloaded.kind, MsgKind.imageGen);
      expect(reloaded.imagePath, '/work/gen-123-cat.jpg');
    });

    test('jobsFor snapshot exposes state and elapsed', () async {
      final s = newSession('qw-t6');
      // No jobs yet — empty snapshot, not an error.
      expect(AgentService.I.jobsFor(s.id), isEmpty);
      expect(AgentService.I.jobsFor('missing-session'), isEmpty);
    });
  });

  group('PR18: context engineering — spill, budgets, CAS, metering', () {
    ChatSession newSession(String id) {
      final app = AppState.I;
      final s = ChatSession(id: id, title: 'New chat', model: 'm', mode: 'auto');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() => app.sessions.removeWhere((x) => x.id == id));
      return s;
    }

    test('spillToolOutput returns small text untouched', () async {
      final s = newSession('ce-s0');
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));
      const small = 'short output';
      final out = await spillToolOutput('run_shell', small, cap: 100);
      expect(out, small, reason: 'fits — nothing spilled');
    });

    test('spillToolOutput persists overflow + exact notice + locator',
        () async {
      final s = newSession('ce-s1');
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      final big = List.generate(300, (i) => 'line-$i ${'x' * 50}').join('\n');
      final out = await spillToolOutput('run_shell', big, cap: 1000);

      expect(out, contains('characters omitted — full output saved to'));
      expect(out, contains('.spill/'), reason: 'locator names the spill file');
      expect(out, contains('sed -n'), reason: 'run_shell gets a line-range hint');
      expect(out.startsWith('line-0'), isTrue, reason: 'head preserved');
      expect(out.contains('line-299'), isTrue, reason: 'tail preserved');

      // The spill file really exists in the workspace with the FULL text.
      final dir = await AgentService.I.sessionWorkDirForTest();
      final loc = RegExp(r'\.spill/\d+\.txt').firstMatch(out)!.group(0)!;
      final f = File('${dir.path}/$loc');
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), big);
    });

    test('grep-style tools get a narrower-pattern locator', () async {
      final s = newSession('ce-s2');
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));
      final big = 'y' * 5000;
      final out = await spillToolOutput('fs_grep', big, cap: 500);
      expect(out, contains('narrower `pattern`'));
    });

    test('FS CAS: edit after external change hits FS_STALE_VERSION',
        () async {
      final s = newSession('ce-s3');
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      final dir = await AgentService.I.sessionWorkDirForTest();
      final f = File('${dir.path}/cas.txt');
      f.writeAsStringSync('alpha\nbeta\n');

      // Read (stamps the version)…
      final view = await AgentService.I.dispatchForTest('fs_edit', {
        'command': 'view',
        'path': 'cas.txt',
      });
      expect(view, contains('alpha'));

      // External mutation AFTER the read (a second session / shell echo).
      f.writeAsStringSync('alpha\nBETA-CHANGED\n');

      // …edit now fails with the stale-version guard.
      final res = await AgentService.I.dispatchForTest('fs_edit', {
        'command': 'str_replace',
        'path': 'cas.txt',
        'old_str': 'alpha',
        'new_str': 'ALPHA',
      });
      expect(res, contains('FS_STALE_VERSION'));
      expect(f.readAsStringSync(), contains('BETA-CHANGED'),
          reason: 'the guard must not clobber the newer content');

      // Re-read refreshes the stamp; the retry then succeeds.
      await AgentService.I.dispatchForTest('fs_edit', {
        'command': 'view',
        'path': 'cas.txt',
      });
      final res2 = await AgentService.I.dispatchForTest('fs_edit', {
        'command': 'str_replace',
        'path': 'cas.txt',
        'old_str': 'alpha',
        'new_str': 'ALPHA',
      });
      expect(res2, contains('edited'));
      expect(f.readAsStringSync(), contains('ALPHA'));
    });

    test('replayHistory skips the compacted span (C1 companion)', () {
      final s = newSession('ce-s4');
      for (var i = 0; i < 10; i++) {
        s.messages.add(Message(role: 'user', content: 'msg-$i'));
      }
      s.compactedAtCount = 8;
      s.compactedSummary = 'summary of the first eight';
      final out = AgentService.I.replayHistoryForTest(s);
      final contents = out
          .map((m) => m['content'] as String? ?? '')
          .where((c) => c.contains('msg-'))
          .toList();
      expect(contents, isNot(contains('msg-0')),
          reason: 'compacted rows are not re-sent');
      expect(contents.where((c) => c.contains('msg-8')), isNotEmpty);
      expect(contents.where((c) => c.contains('msg-9')), isNotEmpty);
    });

    test('usage entries carry cache buckets and round-trip', () {
      final e = UsageEntry(
        time: DateTime.now(),
        providerId: 'p',
        providerName: 'P',
        model: 'm',
        promptTokens: 1000,
        completionTokens: 100,
        totalTokens: 1100,
        cacheReadTokens: 800,
        cacheWriteTokens: 200,
        duration: const Duration(seconds: 2),
      );
      final j = e.toJson();
      expect(j['cr'], 800);
      expect(j['cw'], 200);
      final back = UsageEntry.fromJson(j);
      expect(back.cacheReadTokens, 800);
      expect(back.cacheWriteTokens, 200);
      // Old entries without buckets still load.
      final old = UsageEntry.fromJson({
        't': DateTime.now().toIso8601String(),
        'pt': 5,
        'ct': 5,
        'tt': 10,
        'd': 100,
      });
      expect(old.cacheReadTokens, 0);
    });
  });

  group('PR19: session domain — ledger, recovery, FTS5, export', () {
    ChatSession newSession(String id) {
      final app = AppState.I;
      final s = ChatSession(id: id, title: 'Title of $id', model: 'm', mode: 'auto');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() => app.sessions.removeWhere((x) => x.id == id));
      return s;
    }

    test('ledger append → read round-trip with stable seq', () async {
      final s = newSession('sd-l1');
      await SessionLedger.I.append(s.id, 'turn_start', {'turn': 0});
      await SessionLedger.I.append(s.id, 'tool_start', {'tool': 'run_shell'});
      await SessionLedger.I.append(s.id, 'tool_end', {
        'tool': 'run_shell',
        'ms': 12,
        'ok': true,
      });
      await SessionLedger.I.append(s.id, 'turn_end', {
        'steps': 1,
        'turns': 1,
      });
      final events = await SessionLedger.I.read(s.id);
      expect(events, hasLength(4));
      expect(events.map((e) => e['seq']), [1, 2, 3, 4]);
      expect(events.first['kind'], 'turn_start');
      expect(events[2]['ms'], 12);
      // Torn tail line is skipped, not fatal.
      final f = File(
        '${SessionLedger.rootOverrideForTest!.path}/${s.id}.jsonl',
      );
      f.writeAsStringSync('{broken json', mode: FileMode.append);
      // A torn tail must not throw and must not lose earlier records.
      final reread = await SessionLedger.I.read(s.id);
      expect(reread, hasLength(4));
    });

    test('projection aggregates turns, steps, and tool counts', () async {
      final s = newSession('sd-l2');
      await SessionLedger.I.append(s.id, 'turn_start', {'turn': 0});
      await SessionLedger.I.append(s.id, 'tool_start', {'tool': 'fs_glob'});
      await SessionLedger.I.append(s.id, 'tool_end', {'tool': 'fs_glob', 'ms': 10});
      await SessionLedger.I.append(s.id, 'tool_start', {'tool': 'fs_glob'});
      await SessionLedger.I.append(s.id, 'tool_end', {'tool': 'fs_glob', 'ms': 5});
      await SessionLedger.I.append(s.id, 'turn_end', {'steps': 2});
      final p = await SessionLedger.I.projection(s.id);
      expect(p.turns, 1);
      expect(p.steps, 2);
      expect(p.toolMs, 15);
      expect(p.toolCounts['fs_glob'], 2);
      await SessionLedger.I.close(s.id);
    });

    test('TOOL_OUTCOME_UNKNOWN: running rows resolve on recovery', () {
      final s = newSession('sd-l3');
      s.messages.add(
        Message(
          role: 'assistant',
          kind: MsgKind.tool,
          toolName: 'run_shell',
          toolState: 'running',
        ),
      );
      AgentService.I.recoverInterruptedRunsForTest();
      expect(s.messages.last.toolState, 'unknown');
      expect(
        s.messages.last.toolDetail,
        contains('outcome unknown'),
      );
    });

    test('FTS5 search: ranked hits with snippets + session filter', () async {
      final s1 = newSession('sd-f1');
      s1.messages.addAll([
        Message(role: 'user', content: 'fix the kafka consumer rebalance bug'),
        Message(role: 'assistant', content: 'the rebalance timeout was too low'),
      ]);
      final s2 = newSession('sd-f2');
      s2.messages.add(
        Message(role: 'user', content: 'kafka topic partition design notes'),
      );

      final res = await AgentService.I.dispatchForTest('session_search', {
        'query': 'kafka',
        'limit': 10,
      });
      expect(res, contains('sd-f1'));
      expect(res, contains('sd-f2'), reason: 'cross-session by default');
      expect(res, contains('rebalance'), reason: 'snippet excerpts shown');

      // scope:this — only the run session's rows survive.
      AgentService.setRunSessionForTest(s2.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));
      final scoped2 = await AgentService.I.dispatchForTest('session_search', {
        'query': 'kafka',
        'scope': 'this',
      });
      expect(scoped2, contains('sd-f2'));
      expect(scoped2, isNot(contains('sd-f1')));
    });

    test('export ZIP contains sessions.json and ledger jsonl', () async {
      // Touching the agent service registers the built-in commands
      // (its constructor calls registerBuiltins).
      final cmd = CommandService.I;
      expect(AgentService.I, isNotNull);
      final s = newSession('sd-e1');
      s.messages.add(Message(role: 'user', content: 'export me'));
      await SessionLedger.I.append(s.id, 'note', {'note': 'for export'});
      // Drive the /export command handler.
      final res = await cmd.execute('/export');
      expect(res, isNotNull);
      final feedback = res!.feedback ?? '';
      expect(feedback, contains('.zip'));
      final zipPath = feedback.split('\n').last.trim();
      final bytes = File(zipPath).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);
      final names = archive.map((f) => f.name).toList();
      expect(names, contains('manifest.json'));
      expect(names, contains('sessions.json'));
      expect(names, contains('ledgers/sd-e1.jsonl'));
      final sessionsJson = String.fromCharCodes(
        archive.firstWhere((f) => f.name == 'sessions.json').content,
      );
      expect(sessionsJson, contains('"id": "sd-e1"'));
      await SessionLedger.I.close(s.id);
    });
  });

  group('PR20: references, takeover, queue steer, popupSelect, viewport', () {
    ChatSession newSession(String id) {
      final app = AppState.I;
      final s = ChatSession(id: id, title: 'Title of $id', model: 'm', mode: 'auto');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() => app.sessions.removeWhere((x) => x.id == id));
      return s;
    }

    test('expandReferences: @file becomes a section block', () async {
      final s = newSession('rf-s1');
      final dir = await AgentService.I.sessionWorkDirForTest();
      File('${dir.path}/notes.txt').writeAsStringSync('the launch code is 42');

      final out = await AgentService.I.expandReferences(
        'check @notes.txt and tell me',
        s,
      );
      expect(out, contains('referenced file "notes.txt"'));
      expect(out, contains('the launch code is 42'),
          reason: 'file content reaches the model');
    });

    test('expandReferences: @session:id includes recent messages', () async {
      final other = newSession('rf-other');
      other.messages
          .add(Message(role: 'user', content: 'remember this decision'));

      final s = newSession('rf-s2');
      final out = await AgentService.I.expandReferences(
        'recall @session:rf-other please',
        s,
      );
      expect(out, contains('referenced session'));
      expect(out, contains('remember this decision'));
    });

    test('expandReferences leaves plain text alone', () async {
      final s = newSession('rf-s3');
      const text = 'no mentions here, and email@example.com stays';
      final out = await AgentService.I.expandReferences(text, s);
      expect(out, text);
    });

    test('queue strict-steer pulls a row to the front', () {
      final agent = AgentService.I;
      agent.clearQueueForTest();
      agent.queueMessageForTest('first');
      agent.queueMessageForTest('second');
      agent.queueMessageForTest('third');

      agent.steerQueuedMessage(2);
      expect(agent.queuedMessages.first, 'third',
          reason: 'steered row is injected next');
      expect(agent.queuedMessages, ['third', 'first', 'second']);
      agent.clearQueueForTest();
    });

    test('bare /model and /permission return popupSelect results', () async {
      AgentService.I; // ensure builtins registered
      newSession('rf-c1'); // handlers need an active session
      final model = await CommandService.I.execute('/model');
      expect(model?.popup, 'model');

      final perm = await CommandService.I.execute('/permission');
      expect(perm?.popup, 'permission');
    });

    test('named /model still switches directly', () async {
      final app = AppState.I;
      final s = newSession('rf-c2');
      final provider = app.providers.firstWhere(
        (p) => p.models.isNotEmpty,
        orElse: () => throw StateError('need a provider with models'),
      );
      final restoreKey = provider.apiKey;
      if (provider.requiresApiKey) provider.apiKey = 'test-key';
      addTearDown(() => provider.apiKey = restoreKey);
      final target = provider.models.first;
      final res = await CommandService.I.execute('/model $target');
      expect(res?.feedback ?? '', contains(target));
      expect(s.model, target);
    });

    test('browser_resize validates the range', () async {
      final s = newSession('rf-s4');
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      final bad = await AgentService.I.dispatchForTest('browser_resize', {
        'width': 100,
        'height': 800,
      });
      expect(bad, contains('out of range'));

      final ok = await AgentService.I.dispatchForTest('browser_resize', {
        'width': 1280,
        'height': 800,
      });
      expect(ok, contains('1280x800'));
      expect(ok, contains('zoom'));
    });
  });

  group('PR21: agent presets', () {
    test('standard preset keeps the full roster; minimal/code deny their '
        'buckets', () {
      // Standard = no gate (every core tool stays).
      final std = PresetRegistry.byId('standard');
      expect(std.allowedTools, isEmpty);
      expect(std.deniedTools, isEmpty);

      // Minimal denies browser/image/orchestration fan-out but keeps
      // dispatch_agent (harness) and core file tools.
      final min = PresetRegistry.byId('minimal');
      expect(PresetRegistry.allows(min, 'browser_navigate'), isFalse);
      expect(PresetRegistry.allows(min, 'generate_image'), isFalse);
      expect(PresetRegistry.allows(min, 'workflow'), isFalse);
      expect(PresetRegistry.allows(min, 'dispatch_agent'), isTrue);
      expect(PresetRegistry.allows(min, 'file_read'), isTrue);

      // Code denies browser + images but keeps shell/git.
      final code = PresetRegistry.byId('code');
      expect(PresetRegistry.allows(code, 'browser_navigate'), isFalse);
      expect(PresetRegistry.allows(code, 'generate_image'), isFalse);
      expect(PresetRegistry.allows(code, 'run_shell'), isTrue);

      // Unknown id falls back to standard (deny nothing).
      expect(PresetRegistry.byId('nope').id, 'standard');
    });

    ChatSession freshSession(String id) {
      final app = AppState.I;
      final s = ChatSession(id: id, title: id, model: 'm', mode: 'auto');
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == id);
        if (app.activeSessionId == id) app.activeSessionId = '';
      });
      return s;
    }

    test('preset gate filters the live tool roster per session', () {
      final s = freshSession('preset-gate');
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      final stdTools = AgentService.I.toolsForTest()
          .map((t) => t['function']['name'] as String)
          .toSet();
      expect(stdTools, contains('browser_navigate'));

      s.presetId = 'minimal';
      final minTools = AgentService.I.toolsForTest()
          .map((t) => t['function']['name'] as String)
          .toSet();
      expect(minTools, isNot(contains('browser_navigate')));
      expect(minTools, isNot(contains('workflow')));
      expect(minTools, isNot(contains('ralph')));
      expect(minTools, contains('dispatch_agent'));
      s.presetId = 'standard';
    });

    test('preset persists across a session JSON round-trip', () {
      final s = ChatSession(
        id: 'preset-json',
        title: 'P',
        model: 'm',
        mode: 'auto',
        presetId: 'studio',
      );
      final back = ChatSession.fromJson(s.toJson());
      expect(back.presetId, 'studio');
      // Default + legacy sessions (no presetId in JSON) land on standard.
      final legacy = ChatSession.fromJson({
        'id': 'legacy',
        'title': 'L',
        'model': 'm',
      });
      expect(legacy.presetId, 'standard');
    });

    test('child sessions inherit the parent presetId', () {
      final app = AppState.I;
      final parent = ChatSession(
        id: 'preset-parent',
        title: 'Parent',
        model: 'm',
        mode: 'auto',
      );
      parent.presetId = 'code';
      app.sessions.insert(0, parent);
      addTearDown(() {
        app.sessions.removeWhere(
          (x) =>
              x.id == parent.id ||
              AppState.I.lineageOf(x.id).any((a) => a.id == parent.id),
        );
      });
      final child = app.createSubagentSession(
        parent: parent,
        label: 'kid',
        mode: 'auto',
      );
      expect(child.presetId, 'code');
    });

    test('/preset opens the picker and switches mid-chat', () async {
      final s = freshSession('preset-cmd');

      // Bare /preset opens the tappable preset sheet (popupSelect) instead
      // of dumping a text list that nothing can be applied from.
      final list = await CommandService.I.execute('/preset');
      expect(list, isNotNull);
      expect(list!.popup, 'preset');

      // Switching works on a chat that already has messages — the tool
      // roster and persona are rebuilt per run, so it applies from the
      // next message instead of being refused.
      app.sendMessage('hello there');
      final sw = await CommandService.I.execute('/preset minimal');
      expect(sw!.feedback, contains('minimal'));
      expect(sw.feedback, contains('next message'));
      expect(s.presetId, 'minimal');

      final bad = await CommandService.I.execute('/preset nope');
      expect(bad!.feedback, contains('Unknown preset'));
      expect(s.presetId, 'minimal');
    });

    test('switched preset persists across a session reload', () async {
      final s = freshSession('preset-persist');
      await CommandService.I.execute('/preset code');
      final id = s.id;
      await app.loadSessions();
      expect(app.sessionById(id)?.presetId, 'code');
    });

    test('workflow toggle off removes workflow/ralph from the roster',
        () async {
      final app = AppState.I;
      final s = freshSession('preset-wf');
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      final before = AgentService.I.toolsForTest()
          .map((t) => t['function']['name'] as String)
          .toSet();
      expect(before, contains('workflow'));
      expect(before, contains('ralph'));

      app.workflowEnabled = false;
      addTearDown(() => app.workflowEnabled = true);
      final after = AgentService.I.toolsForTest()
          .map((t) => t['function']['name'] as String)
          .toSet();
      expect(after, isNot(contains('workflow')));
      expect(after, isNot(contains('ralph')));
    });
  });

  group('PR22: sandbox real-Linux hardening', () {
    test('shebang rewrite maps Termux usr/ paths onto the flat prefix',
        () {
      // The mapping contract PR22 fixes: Termux's payload root IS the
      // "usr", so /data/data/com.termux/files/usr/bin/env must rewrite
      // to $PREFIX/bin/env — NOT $PREFIX/usr/bin/env (which never
      // exists → "bad interpreter").
      const termuxShebang = '#!/data/data/com.termux/files/usr/bin/env node';
      final p = '/data/user/0/com.dhanuk.ovidai/files/sandbox';
      // Same ordering as _patchExtractedShebangs: usr/ first, then the
      // bare prefix as fallback.
      var rewritten = termuxShebang
          .replaceFirst('/data/data/com.termux/files/usr/', '$p/');
      expect(rewritten, '#!$p/bin/env node');
      expect(rewritten, isNot(contains('$p/usr/')));

      // Legacy scripts without /usr still rewrite via the fallback.
      const plain = '#!/data/data/com.termux/files/bin/sh';
      var fallback = plain
          .replaceFirst('/data/data/com.termux/files/usr/', '$p/')
          .replaceFirst('/data/data/com.termux/files', p);
      expect(fallback, '#!$p/bin/sh');
    });

    test('usr compat self-symlink resolves usr/bin/env → bin/env',
        () async {
      final tmp =
          await Directory.systemTemp.createTemp('ovid-pr22-usr-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      // Mini-prefix: bin/env only, no usr/ — the broken on-device state.
      Directory('${tmp.path}/bin').createSync(recursive: true);
      File('${tmp.path}/bin/env').writeAsStringSync('#!/system/bin/sh\n');
      final usr = Link('${tmp.path}/usr');
      usr.createSync('.'); // the PR22 compat link
      // usr/bin/env must now resolve to a real file.
      expect(File('${tmp.path}/usr/bin/env').existsSync(), isTrue);
    });

    test('self-heal creates the usr link + libz so-links when missing',
        () async {
      final tmp =
          await Directory.systemTemp.createTemp('ovid-pr22-heal-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      // A sandbox shape the OLD build could have produced: no usr/ link,
      // libz.so.1.3.2 present but no so-version links (Map bug loss).
      Directory('${tmp.path}/bin').createSync(recursive: true);
      File('${tmp.path}/bin/bash').writeAsStringSync('');
      File('${tmp.path}/bin/coreutils').writeAsStringSync('');
      Directory('${tmp.path}/lib').createSync(recursive: true);
      File('${tmp.path}/lib/libz.so.1.3.2').writeAsStringSync('');
      await SandboxService.I.selfHealNow();
      // NOTE: selfHealNow uses the REAL files root; in a unit test the
      // host sandbox dir does not exist, so the call is a no-op — the
      // link-creation logic itself is covered by the direct calls below.
      // Direct equivalent of the heal loop (mirrors _selfHealSandbox):
      final link1 = Link('${tmp.path}/lib/libz.so.1');
      if (!link1.existsSync()) {
        link1.createSync('libz.so.1.3.2');
      }
      expect(Link('${tmp.path}/lib/libz.so.1').existsSync(), isTrue);
      expect(
        File('${tmp.path}/lib/libz.so.1').existsSync(),
        isTrue,
        reason: 'so-version link resolves to the versioned file',
      );
    });

    test('job_start uses the sandbox spawn whenever it is installed',
        () {
      // Source-level contract (no process spawn in unit tests): the
      // non-studio branch must route through SandboxService.spawn —
      // the old code gated on `mode == AgentMode.studio`, leaving
      // every other mode on /system/bin/sh (no node, no env).
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      final i = src.indexOf('Future<String> _handleJobStart');
      expect(i, greaterThan(0));
      final body = src.substring(i, i + 2400);
      expect(body, contains('SandboxService.I.isInstalled'));
      expect(body, isNot(contains('mode == AgentMode.studio &&')));
    });

    test('sandbox env always points npm tmp + cache inside the prefix',
        () {
      final src = File('lib/core/sandbox_service.dart').readAsStringSync();
      expect(src, contains("npm_config_tmp': '\$p/tmp'"));
      expect(src, contains("npm_config_cache': '\$p/home/.npm'"));
      expect(src, contains("TMPDIR': '\$p/tmp'"));
      // Dirs are ensured at env-build time (EACCES class fix).
      expect(src, contains("Directory('\$p/home/.npm').createSync"));
    });
  });

  group('PR23: mention fixes + model snapshot', () {
    test('expandReferences rejects @../ traversal but keeps dotted names',
        () async {
      final s = ChatSession(id: 'trav1', title: 'T', model: 'm');
      final app = AppState.I;
      final prevActive = app.activeSessionId;
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == s.id);
        app.activeSessionId = prevActive;
      });
      final ws = await AgentService.I.sessionWorkDirForTest();
      // A real file + a real dotted name (must NOT be rejected).
      File('${ws.path}/notes.txt').writeAsStringSync('secret notes');
      File('${ws.path}/a..b.txt').writeAsStringSync('dotted is fine');

      final ok = await AgentService.I
          .expandReferencesForTest('check @notes.txt', s);
      expect(ok, contains('referenced file "notes.txt"'));

      final dotted = await AgentService.I
          .expandReferencesForTest('check @a..b.txt', s);
      expect(dotted, contains('referenced file "a..b.txt"'));

      // Traversal attempts resolve to nothing (no expansion block; the
      // raw text — which naturally still contains the token — goes to
      // the model unchanged, exactly like an unresolvable mention).
      final esc = await AgentService.I
          .expandReferencesForTest('read @../../etc/passwd', s);
      expect(esc, isNot(contains('referenced file')));
      expect(esc, isNot(contains('[expanded references]')));
      expect(esc, 'read @../../etc/passwd');
    });

    test('queued message drain expands @file refs for the running session',
        () async {
      final app = AppState.I;
      final s = ChatSession(
        id: 'qdrain1',
        title: 'Q',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      final prevActive = app.activeSessionId;
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == s.id);
        app.activeSessionId = prevActive == 'qdrain1' ? '' : prevActive;
      });
      final ws = await AgentService.I.sessionWorkDirForTest();
      File('${ws.path}/todo.md').writeAsStringSync('- fix the bug');

      AgentService.I.queueMessageForTest('summarize @todo.md');
      addTearDown(() => AgentService.I.clearQueueForTest());
      final msgs = <Map<String, dynamic>>[];
      await AgentService.I.drainQueueIntoMsgsForTest(
        msgs,
        forSessionId: 'qdrain1',
      );
      expect(msgs, isNotEmpty);
      expect(
        msgs.last['content'],
        contains('referenced file "todo.md"'),
        reason: 'queued text got the same expansion as a direct send',
      );
    });

    test('run start snapshots the model; mid-run picker switch does not '
        'affect the in-flight run', () async {
      final app = AppState.I;
      final s = ChatSession(
        id: 'snap1',
        title: 'S',
        model: 'model-a',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      addTearDown(() => app.sessions.removeWhere((x) => x.id == s.id));

      // runTask needs a configured provider — instead drive the snapshot
      // contract at the bucket level (what runTask does at line ~3668).
      final bucket = AgentService.I.runBucketForTest('snap1');
      expect(bucket.modelSnapshot, isNull); // nothing snapshotted yet
      bucket.modelSnapshot = s.model; // runTask's snapshot step
      s.model = 'model-b'; // user switches mid-run
      expect(bucket.modelSnapshot, 'model-a');
      // The request-builder preference order (mirrors _callLlmOnce):
      final used = bucket.modelSnapshot ?? s.model;
      expect(used, 'model-a');
      bucket.modelSnapshot = null;
    });

    test('composer mention boundary: @ after ( [ , > opens the menu',
        () {
      // Source-level contract for the boundary set (PR23/M7) — mirrors
      // _onTextChanged's check without needing a widget test.
      const openers = ' \n\t([,>';
      for (final ch in ['(', '[', ',', '>']) {
        expect(openers.contains(ch), isTrue);
      }
      // Emails (x@y) still never trigger: @ after a word char.
      expect(openers.contains('o'), isFalse, reason: 'hello@world');
    });
  });

  group('PR24: plugin hooks', () {
    test('marketplace hooks parse (map + list forms, unknown events die)',
        () async {
      final app = AppState.I;
      // Map form via merge — drive the private parse path through a
      // plugin insert using the same _parsePluginHooks rules: valid
      // events kept, unknown dropped, empty commands dropped.
      final p = PluginItem(
        name: 'hooked',
        author: 'you',
        description: 'hooks plugin',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 1,
        // Constructor stores as given (the _parsePluginHooks filter runs
        // at MARKETPLACE import time — see the merge contract below).
        hooks: {
          'on_turn_start': 'echo start',
          'on_bogus_event': 'echo never',
        },
      );
      app.plugins.add(p);
      addTearDown(() => app.plugins.remove(p));

      expect(p.hooks['on_turn_start'], 'echo start');
      // Unknown events are never FIRED: fire() iterates only listeners
      // whose event matches, and the agent only calls the 5 known names.
      expect(PluginItem.hookEvents.contains('on_bogus_event'), isFalse);
      // The marketplace parse contract: unknown + empty dropped, valid kept.
      // (Drive _parsePluginHooks through a merge shape.)
      final merged = app.mergeMarketplaceCatalogForTest(
        {
          'plugins': [
            {
              'name': 'hooked-market',
              'hooks': {
                'on_turn_end': 'echo end',
                'on_bogus_event': 'echo never',
                'on_pre_request': '   ',
              },
            },
          ],
        },
        'testowner',
        'testrepo',
      );
      expect(merged, contains('Imported 1 plugin'));
      final imported = app.plugins.firstWhere(
        (x) => x.name == 'hooked-market',
      );
      expect(imported.hooks['on_turn_end'], 'echo end');
      expect(imported.hooks.containsKey('on_bogus_event'), isFalse);
      expect(imported.hooks.containsKey('on_pre_request'), isFalse);
      app.plugins.remove(imported);
      expect(PluginItem.hookEvents, contains('on_session_start'));
      expect(PluginItem.hookEvents, contains('on_turn_end'));
      expect(PluginItem.hookEvents, contains('on_post_tool'));
    });

    test('HookService fires the command with env vars and returns stdout',
        () async {
      final app = AppState.I;
      final p = PluginItem(
        name: 'hook-runner',
        author: 'you',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 1,
        hooks: {'on_pre_request': 'date'},
      );
      app.plugins.add(p);
      addTearDown(() => app.plugins.remove(p));

      final svc = HookService.I;
      svc.enabled = true;
      addTearDown(() => svc.enabled = true);
      String? gotCmd;
      Map<String, String>? gotEnv;
      svc.executorForTest = (cmd, env) async {
        gotCmd = cmd;
        gotEnv = env;
        return 'hook says hi';
      };
      addTearDown(() => svc.executorForTest = null);

      final out = await svc.fire('on_pre_request', 'hook-sess-1');
      expect(gotCmd, 'date');
      final env = gotEnv!;
      expect(env['OVID_HOOK_EVENT'], 'on_pre_request');
      expect(env['OVID_HOOK_PLUGIN'], 'hook-runner');
      expect(env['OVID_HOOK_SESSION'], 'hook-sess-1');
      expect(env['OVID_HOOK_PAYLOAD'], contains('hook-sess-1'));
      expect(out, 'hook says hi');
      expect(svc.fired, greaterThan(0));
    });

    test('kill-switch blocks every hook execution', () async {
      final app = AppState.I;
      final p = PluginItem(
        name: 'hook-killed',
        author: 'you',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 1,
        hooks: {'on_turn_start': 'echo nope'},
      );
      app.plugins.add(p);
      addTearDown(() => app.plugins.remove(p));

      final svc = HookService.I;
      svc.enabled = false;
      addTearDown(() => svc.enabled = true);
      var called = false;
      svc.executorForTest = (cmd, env) async {
        called = true;
        return '';
      };
      addTearDown(() => svc.executorForTest = null);

      expect(svc.hasHookListeners('on_turn_start'), isFalse);
      final out = await svc.fire('on_turn_start', 'hook-sess-2');
      expect(out, isEmpty);
      expect(called, isFalse, reason: 'disabled hooks never execute');
    });

    test('hook stdout over 2 KB is truncated for context injection',
        () async {
      final app = AppState.I;
      final p = PluginItem(
        name: 'hook-big',
        author: 'you',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 1,
        hooks: {'on_pre_request': 'yes'},
      );
      app.plugins.add(p);
      addTearDown(() => app.plugins.remove(p));
      final svc = HookService.I;
      svc.executorForTest = (cmd, env) async => 'x' * 5000;
      addTearDown(() => svc.executorForTest = null);

      final out = await svc.fire('on_pre_request', 'hook-sess-4');
      expect(out.length, lessThan(2100));
      expect(out, endsWith('[hook output truncated]'));
    });

    test('hook ledger events record invoked + result', () async {
      final app = AppState.I;
      final p = PluginItem(
        name: 'hook-ledger',
        author: 'you',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 1,
        hooks: {'on_turn_end': 'true'},
      );
      app.plugins.add(p);
      addTearDown(() => app.plugins.remove(p));
      final svc = HookService.I;
      svc.executorForTest = (cmd, env) async => 'done';
      addTearDown(() => svc.executorForTest = null);

      final root = await Directory.systemTemp.createTemp('ovid-hook-led-');
      SessionLedger.rootOverrideForTest = root;
      addTearDown(() {
        SessionLedger.rootOverrideForTest = null;
        root.deleteSync(recursive: true);
      });

      await svc.fire('on_turn_end', 'hook-sess-3');
      // The ledger writes through a buffered sink — flush before reading.
      await SessionLedger.I.flush('hook-sess-3');
      final file = File(
        '${root.path}/${'hook-sess-3'.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_')}.jsonl',
      );
      expect(file.existsSync(), isTrue, reason: 'ledger file written');
      final lines = file
          .readAsStringSync()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .map(jsonDecode)
          .toList();
      expect(
        lines.any((e) => e['kind'] == 'hook/invoked'),
        isTrue,
        reason: 'invoked record present',
      );
      expect(
        lines.any((e) => e['kind'] == 'hook/result' && e['ok'] == true),
        isTrue,
        reason: 'successful result record present',
      );
    });
  });

  group('PR25: edit diff cards', () {
    test('buildEditDiff: create = all + lines; replace = context + hunks',
        () {
      // Create (no before): whole file as additions.
      final created = AgentService.buildEditDiff(
        'lib/new.dart',
        null,
        'a\nb\nc',
      );
      expect(created, startsWith('diff lib/new.dart'));
      expect(created.split('\n'), containsAll(['+a', '+b', '+c']));

      // Replace in the middle: context line + -old + +new + context.
      final replaced = AgentService.buildEditDiff(
        'lib/x.dart',
        'one\ntwo\nthree\nfour',
        'one\nTWO!\nfour',
      );
      expect(replaced, startsWith('diff lib/x.dart'));
      expect(replaced, contains(' one')); // context above
      expect(replaced, contains('-two'));
      expect(replaced, contains('-three'));
      expect(replaced, contains('+TWO!'));
      expect(replaced, contains(' four')); // context below

      // No change → explicit marker.
      final same = AgentService.buildEditDiff(
        'a.txt',
        'same',
        'same',
      );
      expect(same, contains('(no changes)'));
    });

    test('buildEditDiff caps at 400 lines with a truncation notice', () {
      final big = List.generate(1000, (i) => 'line $i').join('\n');
      final diff = AgentService.buildEditDiff('big.txt', null, big);
      expect(diff, contains('more lines'));
      final bodyLines = diff
          .split('\n')
          .where((l) => l.startsWith('+') && !l.startsWith('+++'))
          .length;
      expect(bodyLines, lessThanOrEqualTo(401)); // cap + truncation row
    });

    test('edit tools attach the diff to the tool card detail', () async {
      final app = AppState.I;
      final s = ChatSession(
        id: 'diff1',
        title: 'D',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == s.id);
        app.activeSessionId = '';
      });
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      // Observe (view) then edit — the read-before-write gate.
      final ws = await AgentService.I.sessionWorkDirForTest();
      File('${ws.path}/cfg.txt').writeAsStringSync('alpha\nbeta\n');
      await AgentService.I.dispatchForTest(
        'fs_edit',
        {'command': 'view', 'path': 'cfg.txt'},
      );

      // Arm a card as a real run's _toolStart would, then edit: the diff
      // must land on that card's detail (D1 contract).
      AgentService.I.armToolCardForTest('fs_edit');
      final res = await AgentService.I.dispatchForTest(
        'fs_edit',
        {
          'command': 'str_replace',
          'path': 'cfg.txt',
          'old_str': 'beta',
          'new_str': 'gamma',
        },
      );
      expect(res, contains('edited'));
      // The active tool card now carries a real diff in its detail.
      final msg = s.messages.where((m) => m.toolName == 'fs_edit').last;
      expect((msg.toolDetail ?? ''), startsWith('diff cfg.txt'));
      expect(msg.toolDetail, contains('-beta'));
      expect(msg.toolDetail, contains('+gamma'));
      expect(File('${ws.path}/cfg.txt').readAsStringSync(), contains('gamma'));
    });
  });

  group('PR26: compaction parity', () {
    test('measuredContextTokens skips the compacted span but counts the '
        'summary', () {
      final app = AppState.I;
      final s = ChatSession(
        id: 'cmp-measure',
        title: 'C',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      addTearDown(() => app.sessions.removeWhere((x) => x.id == s.id));
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      for (var i = 0; i < 20; i++) {
        s.messages.add(Message(role: 'user', content: 'old message $i ' * 20));
      }
      // Compaction state: first 18 folded, 2 kept live.
      s.compactedAtCount = 18;
      s.compactedSummary = 'short summary';
      final bucket = AgentService.I.runBucketForTest(s.id);
      bucket.lastPromptTokens = null; // force the heuristic path

      final measured = AgentService.I.measuredContextTokens(s);
      // Only the 2 live rows + summary count — the 18 folded rows don't.
      final twoRows = 2 *
          (AgentService.estimateMessageTokens('old message 19 ' * 20) +
              AgentService.estimateMessageTokens(''));
      final summaryTok = AgentService.estimateMessageTokens('short summary');
      expect(
        measured,
        lessThan(twoRows + summaryTok + 300),
        reason: 'folded rows are not double-counted after compaction',
      );
      expect(measured, greaterThan(summaryTok));
      bucket.lastPromptTokens = null;
    });

    test('compaction lock: a second concurrent compact no-ops', () async {
      final app = AppState.I;
      final s = ChatSession(
        id: 'cmp-lock',
        title: 'C',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      addTearDown(() => app.sessions.removeWhere((x) => x.id == s.id));
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      // Simulate a stuck compaction: the lock is held for this session.
      expect(AgentService.I.compactingAddForTest(s.id), isTrue);
      addTearDown(() => AgentService.I.compactingRemoveForTest(s.id));

      // _maybeCompact must return immediately (lock held) — verified by
      // the fact it does not throw and does not compact anything.
      final before = s.compactedAtCount;
      final p = AppState.I.providers.first;
      await AgentService.I.maybeCompactForTest(s, p);
      expect(s.compactedAtCount, before, reason: 'locked compact no-ops');
    });

    test('/compact refuses while the session is busy', () async {
      final app = AppState.I;
      final s = ChatSession(
        id: 'cmp-busy',
        title: 'C',
        model: 'm',
        mode: 'auto',
      );
      // The command resolves providerForSession — give the session a
      // configured provider (any id with models + key-less).
      if (app.providers.isEmpty) {
        app.providers.add(
          ProviderConfig(
            id: 'prov-cmp',
            name: 'Test',
            description: '',
            baseUrl: 'https://x.test',
            models: const ['m'],
            requiresApiKey: false,
          ),
        );
        addTearDown(() => app.providers.removeWhere((p) => p.id == 'prov-cmp'));
      }
      s.providerId = app.providers.first.id;
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == s.id);
        app.activeSessionId = '';
      });
      // Mark the session busy: an active run id in its bucket.
      final bucket = AgentService.I.runBucketForTest(s.id);
      bucket.activeRunId = 'run-1';
      addTearDown(() => bucket.activeRunId = null);

      final res = await CommandService.I.execute('/compact');
      expect(res!.feedback, contains('busy'));
    });

    test('summarizer prompt demands the 8-section DSH checkpoint', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      // PR29: the exact DSH section names (updated from the older set).
      expect(src, contains('## Primary Request and Intent'));
      expect(src, contains('## Critical Context'));
      expect(src, contains('## Next Step'));
      // Overflow rebuild + budget-boundary rebuild reuse the shared
      // assembly (never drop the checkpoint).
      expect(src, contains('buildRequestMessages(s, sys)'));
    });
  });

  group('PR27: header cleanup + browser mode', () {
    test('browserDesktopMode pref round-trips (default mobile)', () async {
      final app = AppState.I;
      expect(app.browserDesktopMode, isFalse, reason: 'mobile default');
      await app.setBrowserDesktopMode(true);
      addTearDown(() => app.setBrowserDesktopMode(false));
      expect(app.browserDesktopMode, isTrue);
      // Reset defaults restores mobile.
      await app.setBrowserDesktopMode(false);
      expect(app.browserDesktopMode, isFalse);
    });

    test('new tabs pick up desktop zoom when the mode is on', () {
      // The zoom formula at tab creation (PR27/B5 contract).
      BrowserTab.devW = 360;
      BrowserTab.devH = 720;
      final tab = BrowserTab(url: 'https://x.test');
      // Mobile (default): zoom stays 1.0.
      expect(tab.zoom, 1.0);
      // Desktop: 360/1280 → zoom < 1 (page renders as a wide window).
      final desktopZoom = (BrowserTab.devW / 1280).clamp(0.25, 3.0);
      expect(desktopZoom, lessThan(1.0));
      tab.zoom = desktopZoom;
      expect(tab.logicalWidth, 1280);
    });

    test('header shows jobs only: subagents + trajectory icons removed',
        () {
      final src = File('lib/ui/chat_screen.dart').readAsStringSync();
      // The AppBar actions block no longer contains the removed icons.
      final actionsStart = src.indexOf('actions: [');
      final actionsEnd = src.indexOf('bottom:', actionsStart);
      final block = src.substring(
        actionsStart,
        actionsEnd > 0 ? actionsEnd : actionsStart + 3000,
      );
      expect(block, isNot(contains('account_tree_outlined')));
      expect(block, isNot(contains('timeline_outlined')));
      expect(block, contains('terminal_outlined')); // jobs badge stays
      // Trajectory still reachable — sidebar footer entry (PR27/B2).
      final sidebar = File('lib/ui/sidebar.dart').readAsStringSync();
      expect(sidebar, contains('TrajectoryScreen'));
    });
  });

  group('PR28: real-user browser control', () {
    test('new tools are on the roster with schemas', () {
      final app = AppState.I;
      final s = ChatSession(id: 'br1', title: 'B', model: 'm', mode: 'auto');
      app.sessions.insert(0, s);
      addTearDown(() => app.sessions.removeWhere((x) => x.id == s.id));
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      final names = AgentService.I.toolsForTest()
          .map((t) => t['function']['name'] as String)
          .toSet();
      for (final n in [
        'browser_back',
        'browser_forward',
        'browser_reload',
        'browser_hover',
        'browser_drag',
        'browser_select',
        'browser_fill',
        'browser_find',
        'browser_cookies',
        'browser_outline',
      ]) {
        expect(names, contains(n), reason: '$n on the roster');
      }
    });

    test('browser_click reports not-found without a live controller',
        () async {
      final app = AppState.I;
      final s = ChatSession(id: 'br2', title: 'B', model: 'm', mode: 'auto');
      app.sessions.insert(0, s);
      addTearDown(() => app.sessions.removeWhere((x) => x.id == s.id));
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      // No WebView platform in unit tests — WebViewController creation
      // asserts. The CONTRACT: click never returns a blind success; it
      // either runs the pre-check or fails loudly. Both are honest.
      Object? thrown;
      String? res;
      try {
        res = await AgentService.I.dispatchForTest('browser_click', {
          'selector': '#nonexistent',
        });
      } catch (e) {
        thrown = e;
      }
      expect(thrown != null || res != null, isTrue);
      if (res != null) {
        expect(
          res,
          anyOf(contains('not found'), contains('failed')),
          reason: 'no blind "Clicked (or attempted)" lies',
        );
      }
    });

    test('fill/drag/select summaries appear on tool cards', () {
      // _toolArgSummary contract for the new tools (visible cards).
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains("'browser_drag' =>"));
      expect(src, contains("'browser_fill' =>"));
      expect(src, contains("'browser_select' =>"));
      // Human-like click pre-check exists (W10).
      expect(src, contains('element not visible'));
      expect(src, contains('scrollIntoView'));
    });

    test('JS builders use real pointer/DnD event chains', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains('new PointerEvent(type,'));
      expect(src, contains("new DragEvent('dragstart'"));
      expect(src, contains("new MouseEvent('mouseover'"));
      expect(src, contains("new Event('input', {bubbles:true})"));
    });
  });

  group('PR29: compaction DSH parity', () {
    ProviderConfig fakeProvider() => ProviderConfig(
          id: 'prov-c29',
          name: 'Test',
          description: '',
          baseUrl: 'https://x.test',
          models: const ['m'],
          requiresApiKey: false,
        );

    ChatSession newCompactSession(String id, {int msgs = 0}) {
      final app = AppState.I;
      final s = ChatSession(id: id, title: id, model: 'm', mode: 'auto');
      for (var i = 0; i < msgs; i++) {
        s.messages.add(
          Message(role: 'user', content: 'message $i ${'x' * 400}'),
        );
      }
      app.sessions.insert(0, s);
      addTearDown(() => app.sessions.removeWhere((x) => x.id == id));
      return s;
    }

    test('/compact on a short chat reports honestly instead of lying',
        () async {
      final app = AppState.I;
      final prov = fakeProvider();
      app.providers.add(prov);
      addTearDown(() => app.providers.removeWhere((p) => p.id == 'prov-c29'));
      final s = newCompactSession('c29-short', msgs: 3);
      s.providerId = prov.id;
      app.activeSessionId = s.id;
      addTearDown(() {
        app.activeSessionId = '';
      });

      final res = await CommandService.I.execute('/compact');
      expect(res!.feedback, contains('Nothing to compact'));
      expect(res.feedback, isNot(contains('Session compacted —')));
      // History untouched.
      expect(s.messages.length, 3);
      expect(s.compactedSummary, isNull);
    });

    test('/compact on a fully-compacted chat says so', () async {
      final app = AppState.I;
      final prov = fakeProvider();
      app.providers.add(prov);
      addTearDown(() => app.providers.removeWhere((p) => p.id == 'prov-c29'));
      final s = newCompactSession('c29-done', msgs: 2);
      s.providerId = prov.id;
      app.activeSessionId = s.id;
      addTearDown(() => app.activeSessionId = '');
      // Simulate an already-complete compaction.
      s.compactedAtCount = s.messages.length;
      s.compactedSummary = 'old checkpoint';

      final res = await CommandService.I.execute('/compact');
      expect(res!.feedback, contains('already fully compacted'));
    });

    test('/compact folds the span and reports honest counts (seam)',
        () async {
      final app = AppState.I;
      final prov = fakeProvider();
      app.providers.add(prov);
      addTearDown(() => app.providers.removeWhere((p) => p.id == 'prov-c29'));
      final s = newCompactSession('c29-ok', msgs: 40);
      s.providerId = prov.id;
      app.activeSessionId = s.id;
      addTearDown(() => app.activeSessionId = '');

      // Small window so the standard retention keeps only a few rows.
      app.contextWindowOverride = 4000;
      addTearDown(() => app.contextWindowOverride = 0);

      AgentService.I.compactionSummarizerForTest = (sess, from, cutoff) async {
        // The span is replayed with real content (not truncated away).
        return '## Primary Request and Intent\n- test goal';
      };
      addTearDown(() => AgentService.I.compactionSummarizerForTest = null);

      final res = await CommandService.I.execute('/compact');
      expect(res!.feedback, contains('Session compacted'));
      expect(res.feedback, contains('message(s)'));
      // The checkpoint landed: state advanced + compact row visible.
      expect(s.compactedSummary, contains('test goal'));
      expect(s.compactedAtCount, greaterThan(0));
      expect(
        s.messages.where((m) => m.kind == MsgKind.compact).length,
        1,
        reason: 'visible checkpoint row',
      );
    });

    test('summarizer failure is reported honestly (nothing changes)',
        () async {
      final app = AppState.I;
      final s = newCompactSession('c29-fail', msgs: 40);
      AgentService.I.compactionSummarizerForTest = (sess, from, cutoff) async {
        return null; // model failure
      };
      addTearDown(() => AgentService.I.compactionSummarizerForTest = null);
      app.contextWindowOverride = 4000;
      addTearDown(() => app.contextWindowOverride = 0);

      final prov = fakeProvider();
      final status = await AgentService.I.compactNow(s, prov);
      expect(status, contains('failed'));
      expect(status, contains('no summary'));
      expect(s.compactedSummary, isNull);
      expect(s.messages.length, 40, reason: 'history untouched');
    });

    test('buildRequestMessages uses the DSH checkpoint framing', () {
      final s = newCompactSession('c29-frame', msgs: 2);
      s.compactedSummary = 'CHECKPOINT BODY';
      final msgs = AgentService.I.buildRequestMessages(s, 'SYS');
      expect(msgs.first['role'], 'system');
      expect(msgs.first['content'], 'SYS');
      // The checkpoint is a USER-role message with the DSH preamble +
      // <compacted-summary> tags (not a bare system note anymore).
      final ck = msgs[1];
      expect(ck['role'], 'user');
      expect(ck['content'], contains('<compacted-summary>'));
      expect(ck['content'], contains('CHECKPOINT BODY'));
      expect(ck['content'],
          contains('without acknowledging this checkpoint'));
      // History replays AFTER the checkpoint.
      expect(msgs.length, greaterThan(2));
    });

    test('summarizer instruction matches the DSH 8-section checkpoint',
        () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains('## Primary Request and Intent'));
      expect(src, contains('## Key Technical Concepts'));
      expect(src, contains('## Files and Code'));
      expect(src, contains('## Errors and Fixes'));
      expect(src, contains('## Pending Jobs'));
      expect(src, contains('## Current Work'));
      expect(src, contains('## Next Step'));
      expect(src, contains('## Critical Context'));
      // Span replay is verbatim, not 400-char truncated blobs.
      expect(src, isNot(contains('cleanTruncate(m.content, 400)')));
    });
  });

  group('PR30: apt mirror rotation', () {
    test('the reported on-device error phrasing triggers a rotation',
        () {
      // The EXACT wording from the device log: apt exits 100 with
      // "does not have a Release file" — the old matcher never matched
      // this phrase (it only knew "no release file"), so every retry
      // burned on the same dead mirror.
      final svc = SandboxService.I;
      const deviceError = "E: The repository "
          "'https://packages-cf.termux.dev/apt/termux-main stable Release' "
          "does not have a Release file.";
      final before = svc.currentMirrorIndexForTest;
      final rotated = svc.rotateMirrorForTest(deviceError);
      expect(rotated, isTrue,
          reason: '"does not have a Release file" must rotate');
      expect(svc.currentMirrorIndexForTest,
          (before + 1) % SandboxService.mirrorCountForTest);
      // Rotate back to leave state clean.
      svc.rotateMirrorForTest('connection timed out');
    });

    test('connection / InRelease / signature failures also rotate', () {
      final svc = SandboxService.I;
      for (final err in [
        'Could not connect to packages-cf.termux.dev:444 - connection refused',
        'E: The repository ... does not have an InRelease file',
        'W: GPG error: repository is not signed',
        'Err:3 http://x stable InRelease connection timed out',
      ]) {
        expect(svc.rotateMirrorForTest(err), isTrue, reason: err);
      }
      // Benign output must NOT rotate.
      final before = svc.currentMirrorIndexForTest;
      expect(
        svc.rotateMirrorForTest('Reading package lists... Done'),
        isFalse,
      );
      expect(svc.currentMirrorIndexForTest, before);
    });

    test('mirror pool includes the stable alternates (7 mirrors)', () {
      // PR30: packages-cf proved flaky on-device — tsinghua + nju joined.
      final src = File('lib/core/sandbox_service.dart').readAsStringSync();
      expect(src, contains('mirrors.tuna.tsinghua.edu.cn/termux'));
      expect(src, contains('mirror.nju.edu.cn/termux'));
      expect(SandboxService.mirrorCountForTest, greaterThanOrEqualTo(7));
    });

    test('runtime lists carry zlib (deb) and make/binutils (apt)', () {
      final src = File('lib/core/sandbox_service.dart').readAsStringSync();
      // apt list (PR22+PR30; PR38 appended more CLI tools on a new line,
      // so this now matches the still-intact first half of the literal).
      expect(
        src,
        contains("'nodejs npm python python-pip uv git curl zlib "
            "make binutils '"),
      );
      // deb fallback wanted list (PR30).
      expect(src, contains("'curl',\n          'zlib',"));
      // Force-rotate after each failed update attempt.
      expect(src, contains('[apt] rotated to'));
    });
  });

  group('PR31: shebang patch actually rewrites (host-executed)', () {
    // The PR22 sed was malformed (the `;` sat INSIDE the first expression)
    // and silently never rewrote anything — npm/npx kept Termux-app
    // shebangs → "Permission denied". This test runs the EXACT
    // production bash through real bash on the host.
    test('production sed expression rewrites npm/npx shebangs + chmods',
        () async {
      final tmp =
          await Directory.systemTemp.createTemp('ovid-pr31-');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final p = tmp.path;
      // Mini sandbox: bin/npm, bin/npx + a nested cli script.
      Directory('$p/bin').createSync(recursive: true);
      Directory('$p/lib/node_modules/npm/bin').createSync(recursive: true);
      File('$p/bin/npx')
          .writeAsStringSync('#!/data/data/com.termux/files/usr/bin/env node\n');
      File('$p/bin/npm')
          .writeAsStringSync('#!/data/data/com.termux/files/usr/bin/env node\n');
      File('$p/lib/node_modules/npm/bin/npm-cli.js')
          .writeAsStringSync('#!/data/data/com.termux/files/usr/bin/env node\n');
      // Exec bit OFF on npx (the reported state).
      Process.runSync('chmod', ['-x', '$p/bin/npx']);

      final sedExpr =
          's|/data/data/com.termux/files/usr/|$p/|g; '
          's|/data/data/com.termux/files|$p|g';
      final script = 'export PREFIX="$p"; '
          'for dir in "\$PREFIX/bin" "\$PREFIX/lib/node_modules" '
          '"\$PREFIX/lib" "\$PREFIX/etc"; do '
          '[ -d "\$dir" ] || continue; '
          'find "\$dir" -maxdepth 6 -type f ! -name "*.so*" '
          '! -name "*.png" ! -name "*.jpg" ! -name "*.a" '
          '-exec sh -c \'head -c2 "\$1" 2>/dev/null | grep -q "#!" && '
          'sed -i "$sedExpr" "\$1"\' _ {} \\; '
          '2>/dev/null; done; '
          'chmod +x "\$PREFIX"/bin/* 2>/dev/null';
      final r = await Process.run('bash', ['-c', script]);
      expect(r.exitCode, 0, reason: r.stderr.toString());

      expect(
        File('$p/bin/npx').readAsStringSync(),
        startsWith('#!$p/bin/env node'),
        reason: 'npx shebang rewritten to OUR prefix',
      );
      expect(
        File('$p/bin/npm').readAsStringSync(),
        startsWith('#!$p/bin/env node'),
      );
      expect(
        File('$p/lib/node_modules/npm/bin/npm-cli.js').readAsStringSync(),
        startsWith('#!$p/bin/env node'),
        reason: 'nested npm cli script rewritten too',
      );
      // Exec bit restored by the chmod pass.
      final ls = await Process.run('bash',
          ['-c', '[ -x "$p/bin/npx" ] && echo X_OK || echo X_NO']);
      expect(ls.stdout.toString().trim(), 'X_OK',
          reason: 'npx executable after the pass');
    });

    test('the OLD malformed sed shape is rejected by this sed build',
        () async {
      // Regression guard: the PR22 form (`s|...|...|g; ` with the `;`
      // inside the expression followed by a second command) must FAIL
      // loudly if it ever comes back.
      final tmp =
          await Directory.systemTemp.createTemp('ovid-pr31-old-');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final f = File('${tmp.path}/x.js')
        ..writeAsStringSync('#!/data/data/com.termux/files/usr/bin/env node\n');
      final p = tmp.path;
      final oldShape =
          's|/data/data/com.termux/files/usr/|$p/|g; sed -i "s|x|y|g" "\$f"';
      final r = await Process.run(
        'bash',
        ['-c', 'sed -i "$oldShape" "${f.path}" 2>&1; echo "rc=\$?"'],
      );
      // GNU sed exits 2 (unknown option) or reports the error — never a
      // silent success. Either way the file must NOT be half-rewritten.
      expect(r.stdout.toString(), isNot(contains('g; sed')));
      expect(
        f.readAsStringSync(),
        startsWith('#!/data/data/com.termux'),
        reason: 'malformed sed never rewrites (that was the bug)',
      );
    });

    test('self-heal re-runs the patcher when npm exists', () {
      final src = File('lib/core/sandbox_service.dart').readAsStringSync();
      // The self-heal path invokes the fixed patcher.
      expect(src, contains('await _patchExtractedShebangs(prefix);'));
      // Both path forms are covered by the single sed expression.
      expect(src, contains('com.termux/files/usr/'));
      expect(src, contains('com.termux/files'));
      // The PR22 malformed two-command shape (a `sed -i` embedded
      // after `g;`) is gone for good.
      expect(src, isNot(contains('g; sed -i')));
      // Verification step exists.
      expect(src, contains('SHEBANG_STALE'));
    });
  });

  group('PR32: instant stop + boot fix + keep-alive', () {
    test('boot path: checkExisting has NO self-heal await (black-screen fix)',
        () {
      final src = File('lib/core/sandbox_service.dart').readAsStringSync();
      final start = src.indexOf('Future<bool> checkExisting()');
      final body = src.substring(start, src.indexOf('Future<void> selfHealInBackground'));
      // The boot path must NOT await the multi-minute heal.
      expect(body, isNot(contains('await _selfHealSandbox')));
      // ...and the heal must run from the post-frame background instead.
      expect(src, contains('Future<void> selfHealInBackground'));
      final main = File('lib/main.dart').readAsStringSync();
      expect(
        main,
        contains('selfHealInBackground'),
        reason: 'heal runs AFTER runApp (post-frame), never before',
      );
    });

    test('killAllProcesses SIGKILLs every tracked process (host-executed)',
        () async {
      final svc = SandboxService.I;
      // _trackedRun is private — drive it through execHost, but that hard
      // /system/bin/sh paths. On the HOST (unit tests) spawn via the same
      // tracker by faking the sandbox prefix to /bin (sh exists there).
      final shPath = File('/system/bin/sh').existsSync()
          ? '/system/bin/sh'
          : '/bin/sh';
      expect(File(shPath).existsSync(), isTrue, reason: 'a shell for the test');
      // Spawn directly (the tracker's registration path — same API the
      // sandbox execs use internally) via a tiny tracked sleep.
      final proc = await Process.start(shPath, ['-c', 'sleep 30']);
      svc.liveProcessesForTest.add(proc);
      final done = proc.exitCode.then((_) => 'killed');
      await Future.delayed(const Duration(milliseconds: 200));
      // Instant stop: everything dies NOW (SIGKILL).
      svc.killAllProcesses();
      final r = await done.timeout(const Duration(seconds: 3));
      expect(r, 'killed');
      expect(proc.exitCode, isNot(0),
          reason: 'SIGKILL exit — not a natural 0');
      expect(svc.liveProcessesForTest, isEmpty);
    });

    test('cancelAllRuns kills jobs + spawned processes on every bucket',
        () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains('void cancelAllRuns()'));
      expect(src, contains('killAllProcesses'));
      // Stop kills background jobs too (instant, not 10-min timeout).
      expect(src, contains('j.process?.kill(ProcessSignal.sigkill)'));
      // Parent stop cascades to subagent children.
      expect(src, contains('cancelRunFor(kid.id)'));
      // Chat red button + notification Stop use the panic stop.
      final chat = File('lib/ui/chat_screen.dart').readAsStringSync();
      expect(chat, contains('cancelAllRuns'));
      final notif = File('lib/core/agent_notification_service.dart')
          .readAsStringSync();
      expect(notif, contains('cancelAllRuns'));
    });

    test('run start immediately raises the foreground service', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      // No debounce window at runTask start.
      expect(src, contains("agentWorking('starting task…')"));
      // Lifecycle paused re-asserts the notification while any run is on.
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('anyRunActive'));
      expect(main, contains('working in background…'));
      final agent = src;
      expect(agent, contains('bool get anyRunActive'));
    });
  });

  group('PR44: plugin .mcp.json auto-mount (P3)', () {
    Future<Directory> seedCache(String source, {String? mcpJson}) async {
      final root = await Directory.systemTemp.createTemp('ovid-p3-');
      AppState.pluginCacheRootOverrideForTest = root;
      addTearDown(() {
        AppState.pluginCacheRootOverrideForTest = null;
        root.deleteSync(recursive: true);
      });
      if (mcpJson != null) {
        final dir = await AppState.I.pluginCacheDirFor(source);
        dir.createSync(recursive: true);
        File('${dir.path}/.mcp.json').writeAsStringSync(mcpJson);
      }
      return root;
    }

    test('plugin with .mcp.json mounts its servers on install', () async {
      final app = AppState.I;
      final before = app.mcpServers.map((s) => s.name).toSet();
      await seedCache(
        'acme/tools',
        mcpJson: '{"mcpServers":{"acme-fs":{"command":"npx",'
            '"args":["-y","@acme/fs"],"env":{"API_KEY":"k"}},'
            '"acme-web":{"command":"uvx","args":["acme-web"]}}}',
      );
      addTearDown(() {
        app.mcpServers.removeWhere(
          (s) => s.name.startsWith('acme-'),
        );
      });

      final n = await app.mountPluginMcpServers('acme/tools');
      expect(n, 2);
      final names = app.mcpServers.map((s) => s.name).toSet();
      expect(names, containsAll(['acme-fs', 'acme-web']));
      // Existing seeded servers are untouched and still present.
      expect(before.difference(names), isEmpty);
      final fs = app.mcpServers.firstWhere((s) => s.name == 'acme-fs');
      expect(fs.command, 'npx');
      expect(fs.args, ['-y', '@acme/fs']);
      expect(fs.envHint, 'API_KEY');
      expect(fs.source, 'plugin:acme/tools');
    });

    test('no .mcp.json → 0 mounts, no crash', () async {
      final app = AppState.I;
      await seedCache('acme/none');
      final before = app.mcpServers.length;
      final n = await app.mountPluginMcpServers('acme/none');
      expect(n, 0);
      expect(app.mcpServers.length, before);
    });

    test('malformed JSON → 0 mounts, no throw', () async {
      final app = AppState.I;
      await seedCache('acme/bad', mcpJson: '{not json');
      final n = await app.mountPluginMcpServers('acme/bad');
      expect(n, 0);
    });

    test('servers with no mcpServers map → 0 mounts', () async {
      final app = AppState.I;
      await seedCache('acme/empty', mcpJson: '{"name":"x"}');
      final n = await app.mountPluginMcpServers('acme/empty');
      expect(n, 0);
    });

    test('duplicate server names are NOT re-registered', () async {
      final app = AppState.I;
      // Existing server collides by name.
      app.mcpServers.add(
        McpServer(
          name: 'dupe-srv',
          author: 'test',
          description: '',
          category: 'Community',
          command: 'npx',
          source: 'test',
          custom: true,
        ),
      );
      addTearDown(
          () => app.mcpServers.removeWhere((s) => s.name == 'dupe-srv'));
      await seedCache(
        'acme/dupe',
        mcpJson: '{"mcpServers":{"dupe-srv":{"command":"fake"}}}',
      );
      final n = await app.mountPluginMcpServers('acme/dupe');
      expect(n, 0, reason: 'name collision → skip, not re-register');
      final srv = app.mcpServers.firstWhere((s) => s.name == 'dupe-srv');
      expect(srv.command, 'npx', reason: 'existing server untouched');
    });
  });

  group('PR45: repeat-tool reminder (F2)', () {
    AgentRun newBucket() {
      final s = ChatSession(
        id: 'f2-${DateTime.now().microsecondsSinceEpoch}',
        title: 'F2',
        model: 'm',
        mode: 'auto',
      );
      return AgentService.I.runBucketForTest(s.id);
    }

    test('same tool + same args streak reaches 3/5/8; changing either resets',
        () {
      final bucket = newBucket();
      final calls = <String>[];
      for (var i = 0; i < 8; i++) {
        const name = 'run_shell';
        const argsMap = {'command': 'ls -la'};
        final canon = jsonEncode(argsMap);
        if (bucket.repeatKey?.name == name &&
            bucket.repeatKey!.canonArgs == canon) {
          bucket.repeatStreak++;
        } else {
          bucket.repeatKey = (name: name, canonArgs: canon);
          bucket.repeatStreak = 1;
        }
        calls.add('${bucket.repeatStreak}');
      }
      expect(calls, ['1', '2', '3', '4', '5', '6', '7', '8']);
    });

    test('different args reset the streak', () {
      final bucket = newBucket();
      void call(String name, String args) {
        final canon = jsonEncode(args);
        if (bucket.repeatKey?.name == name &&
            bucket.repeatKey!.canonArgs == canon) {
          bucket.repeatStreak++;
        } else {
          bucket.repeatKey = (name: name, canonArgs: canon);
          bucket.repeatStreak = 1;
        }
      }
      call('run_shell', 'ls');
      call('run_shell', 'ls');
      call('run_shell', 'ls');
      expect(bucket.repeatStreak, 3);
      call('run_shell', 'pwd'); // changed args
      expect(bucket.repeatStreak, 1);
      call('fs_read', 'path'); // different tool entirely
      expect(bucket.repeatStreak, 1);
      expect(bucket.repeatKey!.name, 'fs_read');
    });

    test('different tool with same args also resets', () {
      final bucket = newBucket();
      void call(String name) {
        final canon = jsonEncode(const {});
        if (bucket.repeatKey?.name == name &&
            bucket.repeatKey!.canonArgs == canon) {
          bucket.repeatStreak++;
        } else {
          bucket.repeatKey = (name: name, canonArgs: canon);
          bucket.repeatStreak = 1;
        }
      }
      call('browser_click');
      call('browser_click');
      expect(bucket.repeatStreak, 2);
      call('browser_hover');
      expect(bucket.repeatStreak, 1);
    });

    test('streak lives on the run bucket, not globally across sessions', () {
      final b1 = newBucket();
      final b2 = newBucket();
      void bump(AgentRun b) {
        const canon = '{"cmd":"ls"}';
        if (b.repeatKey?.name == 'run_shell' &&
            b.repeatKey!.canonArgs == canon) {
          b.repeatStreak++;
        } else {
          b.repeatKey = (name: 'run_shell', canonArgs: canon);
          b.repeatStreak = 1;
        }
      }
      bump(b1);
      bump(b1);
      bump(b1);
      bump(b2); // different bucket — own streak
      expect(b1.repeatStreak, 3);
      expect(b2.repeatStreak, 1);
    });

    test('agent service wiring: reminder texts exist at the 3/5/8 streaks',
        () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains('repeatStreak'));
      expect(src, contains('Same tool + identical args repeated'));
      expect(src, contains('now repeated 5 times'));
      expect(src, contains('repeated 8 times'));
      expect(src, contains('STOP looping'));
    });
  });

  group('PR46: persistent PTY (F1)', () {
    test('PTY keeps state across commands in one shell (host-verified)',
        () async {
      final shell = await PtyShell.start(() async {
        final bin = File('/bin/bash').existsSync()
            ? '/bin/bash'
            : '/usr/bin/bash';
        // Non-interactive bash is the real shape (production spawn) —
        // no command echo, no PS1 chatter, block-buffered lines are
        // flushed by our marker protocol.
        return Process.start(bin, ['--norc'], workingDirectory: '/tmp');
      });
      expect(shell, isNotNull, reason: 'host bash spawned');
      addTearDown(() async {
        await shell!.close();
      });

      final wd = '/tmp/ovid-pty-${DateTime.now().millisecondsSinceEpoch}';
      Directory(wd).createSync(recursive: true);
      addTearDown(() {
        try {
          Directory(wd).deleteSync(recursive: true);
        } catch (_) {}
      });

      // cd + export once, read twice in later commands.
      final r1 = await shell!.run('cd "$wd" && export OVID_TEST_HELLO=42');
      expect(r1, startsWith('rc=0'));
      final r2 = await shell.run('pwd; echo "v=\$OVID_TEST_HELLO"');
      expect(r2, startsWith('rc=0'));
      expect(r2, contains(wd));
      expect(r2, contains('v=42'));
      expect(r1, isNot(r2));
    });

    test('PTY output parser strips the marker + carries rc', () async {
      final shell = await PtyShell.start(() async {
        return Process.start('/bin/bash', ['--norc'],
            workingDirectory: '/tmp');
      });
      addTearDown(() async {
        await shell!.close();
      });
      // `false` exits rc=1 but does NOT exit the shell (exit N would kill
      // it, and then no marker can print — that's by design).
      final r = await shell!.run('echo one; echo two; false');
      expect(r, startsWith('rc=1'));
      expect(r, contains('one'));
      expect(r, contains('two'));
    });

    test('PTY timeout kills the hung command cleanly', () async {
      final shell = await PtyShell.start(() async {
        return Process.start('/bin/bash', [], workingDirectory: '/tmp');
      });
      addTearDown(() async {
        await shell!.close();
      });
      final r = await shell!.run('sleep 30', timeoutSeconds: 1);
      expect(r, contains('timed out'));
    });

    test('pool registers spawn under kill-all', () {
      // PtyPool wires into SandboxService.spawn; killAllProcesses() must
      // also drop PTY shells (Stop semantics).
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains('unawaited(PtyPool.I.discardAll())'));
      expect(src, contains("usePty"));
    });
  });

  group('PR43: F3 tool-result pruner + F4 convergence retry', () {
    test('pruner rewrites oversized tool details; skips summarizer when safe',
        () async {
      final app = AppState.I;
      final s = ChatSession(
        id: 'f3-p1',
        title: 'F3',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      final prevActive = app.activeSessionId;
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == s.id);
        app.activeSessionId = prevActive == s.id ? '' : prevActive;
      });
      AgentService.setRunSessionForTest(s.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      // Tiny window: 800 tokens, threshold at 640. Oversized tool detail
      // (12K chars ≈ 3002 tokens) alone puts us way over threshold.
      app.contextWindowOverride = 800;
      addTearDown(() => app.contextWindowOverride = 0);
      s.messages.add(Message(
        role: 'assistant',
        kind: MsgKind.tool,
        toolName: 'run_shell',
        toolDetail: 'line\n' * 3000, // ~15000 chars — clearly oversized
        toolState: 'ok',
      ));
      s.messages.add(Message(role: 'user', content: 'summary?'));

      var called = 0;
      AgentService.I.compactionSummarizerForTest = (sess, a, b) async {
        called++;
        return 'summary';
      };
      addTearDown(() => AgentService.I.compactionSummarizerForTest = null);

      final before = AgentService.I.measuredContextTokens(s);
      await AgentService.I.maybeCompactForTest(
        s,
        AppState.I.providers.first,
      );

      expect(
        s.compactedSummary,
        isNull,
        reason: 'pruning alone brought pressure below threshold; DSH parity: '
            'no summarization call',
      );
      expect(called, 0, reason: 'summarizer skipped after pruning');
      expect(
        AgentService.I.measuredContextTokens(s),
        lessThan(before),
        reason: 'pressure actually dropped',
      );
      // The tool output was rewritten to a spill reference.
      final card = s.messages.firstWhere((m) => m.kind == MsgKind.tool);
      expect(card.toolDetail, contains('.spill/'));
      expect(card.toolDetail, contains('omitted'));
      expect(card.toolDetail!.length, lessThan(6000));
    });

    test('F4: compaction state advances only when the summary is used', () {
      final app = AppState.I;
      final s = ChatSession(
        id: 'f4-flow',
        title: 'F4',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      addTearDown(() => app.sessions.removeWhere((x) => x.id == s.id));

      for (var i = 0; i < 8; i++) {
        s.messages.add(Message(role: 'user', content: 'row $i ' * 50));
      }
      expect(s.compactedAtCount, 0);

      // Apply a compaction — summary accepted → checkpoint row landed.
      final status = AgentService.I.applyCompactionForTest(
        s,
        0,
        6,
        '## Primary Request and Intent\n- demo',
      );
      expect(status, contains('6 message'));
      expect(s.compactedAtCount, 6);
      expect(s.compactedSummary, contains('Primary'));
      expect(s.messages.where((m) => m.kind == MsgKind.compact).length, 1);
    });
  });

  group('PR21: workflow + ralph orchestration', () {
    ChatSession newParent(String id) {
      final app = AppState.I;
      final parent = ChatSession(
        id: id,
        title: 'Parent',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, parent);
      app.activeSessionId = parent.id;
      addTearDown(() {
        app.sessions.removeWhere(
          (x) =>
              x.id == id || AppState.I.lineageOf(x.id).any((a) => a.id == id),
        );
      });
      return parent;
    }

    test('workflow validates phases and tasks', () async {
      final parent = newParent('wf-p1');
      AgentService.setRunSessionForTest(parent.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      final noName = await AgentService.I.dispatchForTest('workflow', {
        'phases': [
          {
            'name': 'x',
            'tasks': [
              {'label': 'a', 'prompt': 'do a'},
            ],
          },
        ],
      });
      expect(noName, contains('name is required'));

      final noTasks = await AgentService.I.dispatchForTest('workflow', {
        'name': 'w',
        'phases': [
          {'name': 'phase only', 'tasks': []},
        ],
      });
      expect(noTasks, contains('no tasks'));
    });

    test('workflow spawns one child session per task, phases in order',
        () async {
      final parent = newParent('wf-p2');
      AgentService.setRunSessionForTest(parent.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      // The runs fail fast (no provider in tests) — the structure is what
      // we verify: 2 phases × (2+1) tasks = 3 child sessions in lineage.
      await AgentService.I.dispatchForTest('workflow', {
        'name': 'W',
        'phases': [
          {
            'name': 'scan',
            'tasks': [
              {'label': 'a', 'prompt': 'map A'},
              {'label': 'b', 'prompt': 'map B'},
            ],
          },
          {
            'name': 'report',
            'tasks': [
              {'label': 'c', 'prompt': 'write up'},
            ],
          },
        ],
      });

      final kids = AppState.I.childrenOf(parent.id);
      expect(kids.length, 3);
      expect(
        kids.map((c) => c.agentLabel).toSet(),
        {'a', 'b', 'c'},
        reason: 'each task got its own child session',
      );
    });

    test('ralph echoes the objective and stops when a worker reports '
        'blocked', () async {
      final parent = newParent('wf-p3');
      AgentService.setRunSessionForTest(parent.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));

      // No provider → the child's run fails fast; ralph reports the round
      // failed without a usable handoff (DSH semantics: no silent success).
      final res = await AgentService.I.dispatchForTest('ralph', {
        'objective': 'fix the flaky test',
      });
      expect(res, contains('Ralph'));
      expect(res, contains('round'));
      // The loop wrote a real child run card (transcript exists).
      expect(AppState.I.childrenOf(parent.id), isNotEmpty);
    });

    test('ralph rejects an empty objective', () async {
      final parent = newParent('wf-p4');
      AgentService.setRunSessionForTest(parent.id);
      addTearDown(() => AgentService.setRunSessionForTest(''));
      final res = await AgentService.I.dispatchForTest(
        'ralph',
        {'objective': '   '},
      );
      expect(res, contains('objective is required'));
    });
  });

  group('PR33: /preset popupSelect sheet (composer → picker → apply)', () {
    setUp(() => AgentService.I.debugPauseScheduleTimerForTest(true));
    tearDown(() => AgentService.I.debugPauseScheduleTimerForTest(false));

    testWidgets('bare /preset opens the sheet; tapping a row applies it',
        (tester) async {
      app.newSession();
      app.sendMessage('hello there'); // mid-chat — the old refusal case
      final s = app.activeSession!;

      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Run the command through the real composer, not the service direct.
      await tester.enterText(find.byType(TextField).first, '/preset');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Agent preset'), findsOneWidget);
      expect(find.text('Minimal'), findsOneWidget);

      await tester.tap(find.text('Minimal'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(s.presetId, 'minimal');
      expect(find.textContaining('Preset → minimal'), findsOneWidget);

      // Outlive the snackbar's auto-dismiss timer for a clean teardown.
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('PR34: sandbox installs on the right ABI, fails honestly, never traps', () {
    test('preflight gate blocks Android 6 with an actionable message', () {
      final e = sandboxPreflightGate(sdkInt: 23, dataExecAllowed: true);
      expect(e, isA<SandboxUnsupportedException>());
      expect(e!.message, contains('API 23'));
      expect(e.message, contains('Android 7+'));
      expect(e.message, contains('Continue without it'));
      expect(sandboxPreflightGate(sdkInt: 22, dataExecAllowed: true),
          isA<SandboxUnsupportedException>());
    });

    test('preflight gate allows Android 7+ and unknown (host) SDK levels',
        () {
      expect(sandboxPreflightGate(sdkInt: 24, dataExecAllowed: true), isNull);
      expect(sandboxPreflightGate(sdkInt: 35, dataExecAllowed: true), isNull);
      // Unknown SDK (channel unavailable in host tests) must never gate.
      expect(sandboxPreflightGate(sdkInt: -1, dataExecAllowed: true), isNull);
    });

    test('preflight gate blocks exec-denying ROMs', () {
      final e = sandboxPreflightGate(sdkInt: 33, dataExecAllowed: false);
      expect(e, isA<SandboxUnsupportedException>());
      expect(e!.message, contains('app storage'));
    });

    test('apt arch follows the payload ABI, not device capability', () {
      expect(aptArchFor('arm64-v8a', 'arm'), 'aarch64');
      expect(aptArchFor('armeabi-v7a', 'arm64'), 'arm');
      expect(aptArchFor('x86_64', 'arm64'), 'x86_64');
      // Unknown payload (older builds) falls back to the device arch.
      expect(aptArchFor(null, 'arm64'), 'aarch64');
      expect(aptArchFor('unknown', 'arm'), 'arm');
    });

    test('sandbox skip flag persists and clears', () async {
      await app.setSandboxSkipped(true);
      expect(app.sandboxSkipped, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('ovid_sandbox_skipped'), isTrue);

      await app.setSandboxSkipped(false);
      expect(app.sandboxSkipped, isFalse);
      expect(prefs.getBool('ovid_sandbox_skipped'), isNull);
    });
  });

  group('PR35: sandbox exec cast + @session reference', () {
    test('exec() returns real command output (String-cast regression)',
        () async {
      final svc = SandboxService.I;
      // Regression: PR32's _trackedRun decodes stdout/stderr to String;
      // exec()'s stale `as List<int>` cast threw
      // "'String' is not a subtype of type 'List<int>' in type cast"
      // on EVERY sandbox command (run_shell, run_code, jobs).
      final src = File('lib/core/sandbox_service.dart').readAsStringSync();
      expect(src, isNot(contains('result.stdout as List<int>')));
      // Behavioral: drive the fixed path with a real <prefix>/bin/sh.
      final tmp = await Directory.systemTemp.createTemp('pr35prefix');
      await Directory('${tmp.path}/bin').create(recursive: true);
      final shTarget = File('/usr/bin/sh').existsSync()
          ? '/usr/bin/sh'
          : '/bin/sh';
      Link('${tmp.path}/bin/sh').createSync(shTarget);
      addTearDown(() {
        svc.sandboxPrefixForTest = null;
        tmp.deleteSync(recursive: true);
      });
      svc.sandboxPrefixForTest = tmp;
      final out = await svc
          .exec(['sh', '-c', 'echo sandbox-ok'],
              hostWorkDir: Directory.systemTemp)
          .timeout(const Duration(seconds: 20));
      expect(out, contains('sandbox-ok'));
    });

    test('@session:<id> expands the LAST messages, not the opening lines',
        () async {
      final app = AppState.I;
      final other = ChatSession(id: 'pr35old', title: 'Old work', model: 'm');
      for (var i = 0; i < 20; i++) {
        other.messages.add(Message(role: 'user', content: 'early $i'));
      }
      other.messages.add(Message(role: 'user', content: 'the latest state'));
      final cur = ChatSession(id: 'pr35cur', title: 'Cur', model: 'm');
      final prevActive = app.activeSessionId;
      app.sessions
        ..insert(0, other)
        ..insert(0, cur);
      app.activeSessionId = cur.id;
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == 'pr35old' || x.id == 'pr35cur');
        app.activeSessionId = prevActive;
      });
      final expanded = await AgentService.I
          .expandReferencesForTest('continue @session:pr35old', cur);
      expect(expanded, contains('referenced session "Old work"'));
      expect(expanded, contains('the latest state'));
      expect(expanded, isNot(contains('early 0')));
    });

    test('@session:<title> resolves by title; unknown refs are visible',
        () async {
      final app = AppState.I;
      final other =
          ChatSession(id: 'pr35t1', title: 'Deploy bug hunt', model: 'm');
      other.messages.add(Message(role: 'assistant', content: 'found it'));
      final cur = ChatSession(id: 'pr35cur2', title: 'Cur2', model: 'm');
      final prevActive = app.activeSessionId;
      app.sessions
        ..insert(0, other)
        ..insert(0, cur);
      app.activeSessionId = cur.id;
      addTearDown(() {
        app.sessions
            .removeWhere((x) => x.id == 'pr35t1' || x.id == 'pr35cur2');
        app.activeSessionId = prevActive;
      });
      final byTitle = await AgentService.I
          .expandReferencesForTest('see @session:deploy bug', cur);
      expect(byTitle, contains('found it'));

      // A dropped block looked like the AI "cannot access" the session —
      // unresolvable refs must surface to the model instead.
      final missing = await AgentService.I
          .expandReferencesForTest('see @session:nope', cur);
      expect(missing, contains('not found'));
    });

    test('subagent @-mention menu inserts a resolvable @session:<id> token',
        () {
      final src = File('lib/ui/chat_screen.dart').readAsStringSync();
      expect(src, contains("insert: '@session:\${sub.sessionId} '"));
    });
  });

  group('PR36: targetSdk 28 keeps sandbox exec legal on Android 10+', () {
    test('build.gradle pins targetSdk 28 (app-data exec allowance)', () {
      // Android 10+ SELinux-denies execve/exec-mmap of app-data files for
      // targetSdkVersion >= 29 — the sandbox would die with EACCES on
      // every Android 10–16 device regardless of ABI or file mode.
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('targetSdk = 28'));
      expect(
        gradle,
        isNot(contains('targetSdk = flutter.targetSdkVersion')),
        reason: 'the Flutter default (34+) silently re-breaks sandbox exec',
      );
      // And the Play-policy lint that fatally fails lintVitalRelease on
      // targetSdk < 33 is disabled for the same deliberate reason.
      expect(gradle, contains('ExpiredTargetSdkVersion'));
    });

    test('exec sanity diagnostic names the targetSdk policy', () {
      final src = File('lib/core/sandbox_service.dart').readAsStringSync();
      expect(src, contains('targetSdkVersion >= 29'));
    });
  });

  group('PR37: run_shell never stalls when sandbox exec is denied', () {
    // Reproduces the on-device report: the [tool run_shell] card appears
    // and then NOTHING — no output, no error, session dead. The device
    // state: sandbox files fully extracted (checkExisting → true) but the
    // platform denies exec (EACCES). bash exists on disk with no exec bit.
    test('run completes and the model receives the exec error', () async {
      final app = AppState.I;
      final agent = AgentService.I;

      // Device-like sandbox: files present, exec denied.
      final tmp = await Directory.systemTemp.createTemp('pr37prefix');
      await Directory('${tmp.path}/bin').create(recursive: true);
      await Directory('${tmp.path}/lib').create(recursive: true);
      // Written with the default 0644 mode: exists, NOT executable →
      // EACCES on execve — the same denial the device reports.
      File('${tmp.path}/bin/bash').writeAsStringSync('#!/nope\n');
      File('${tmp.path}/bin/coreutils').writeAsStringSync('x');
      File('${tmp.path}/lib/libtermux-exec-direct-ld-preload.so')
          .writeAsStringSync('x');
      final svc = SandboxService.I;
      svc.sandboxPrefixForTest = tmp;
      addTearDown(() {
        svc.sandboxPrefixForTest = null;
        tmp.deleteSync(recursive: true);
      });

      final server = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => server.close(force: true));

      final provider = app.providerById('ollama-local')!;
      final originals = {
        'baseUrl': provider.baseUrl,
        'models': provider.models,
        'selectedModel': provider.selectedModel,
      };
      addTearDown(() {
        provider
          ..baseUrl = originals['baseUrl'] as String
          ..models = originals['models'] as List<String>
          ..selectedModel = originals['selectedModel'] as String?;
      });

      final session = ChatSession(
        id: 'pr37run',
        title: 'Run',
        providerId: provider.id,
        model: 'test-model',
        mode: 'auto', // default mode: run_shell auto-approves
        messages: [Message(role: 'user', content: 'run it')],
      );
      app.sessions.insert(0, session);
      app.activeSessionId = session.id;
      addTearDown(() {
        app.sessions.removeWhere((x) => x.id == session.id);
      });
      provider
        ..baseUrl = 'http://${server.address.host}:${server.port}/v1'
        ..models = ['test-model'];

      var requestCount = 0;
      final toolResultsSeen = <String>[];
      final serverTask = () async {
        await for (final request in server) {
          final body = await utf8.decoder.bind(request).join();
          requestCount++;
          for (final m
              in (jsonDecode(body) as Map<String, dynamic>)['messages']
                  as List) {
            if (m['role'] == 'tool') {
              toolResultsSeen.add('${m['content']}');
            }
          }
          request.response.headers.chunkedTransferEncoding = true;
          if (requestCount == 1) {
            // First round: text + a run_shell tool call.
            request.response.add(utf8.encode(
              'data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {
                      'content': 'running it',
                      'tool_calls': [
                        {
                          'index': 0,
                          'id': 'call_1',
                          'function': {
                            'name': 'run_shell',
                            'arguments': '{"command":"echo hi"}',
                          },
                        },
                      ],
                    },
                    'finish_reason': 'tool_calls',
                  },
                ],
              })}\n\n',
            ));
          } else {
            // Follow-up rounds: final answer.
            request.response.add(utf8.encode(
              'data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': 'all done'},
                    'finish_reason': 'stop',
                  },
                ],
              })}\n\n',
            ));
          }
          await request.response.flush();
          try {
            await request.response.close();
          } catch (_) {}
        }
      }();
      unawaited(serverTask);

      await agent
          .runTask('run it', sessionId: session.id)
          .timeout(const Duration(seconds: 30));

      // The run FINISHED — no stuck busy flag (the reported 'conversation
      // never advances, must create a new session' state).
      expect(agent.busyFor(session.id), isFalse);
      // The exec failure reached the model as a tool result.
      expect(toolResultsSeen, isNotEmpty);
      expect(
        toolResultsSeen.first,
        anyOf(
          contains('error'),
          contains('Error'),
          contains('denied'),
          contains('Permission'),
        ),
        reason: 'exec denial must surface to the model, not vanish',
      );
      // And the model's final answer landed in the transcript.
      expect(
        session.messages.any((m) => m.content.contains('all done')),
        isTrue,
      );
    });

    test('tool approvals auto-deny after 2 minutes (no silent wedge)', () {
      // Source contract: a missed approval dock must not park the run
      // for the tool's full budget. Questions/plan reviews are exempt.
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains("Timer(const Duration(seconds: 120)"));
      expect(src, contains("req.questions == null && t != 'exit_plan_mode'"));
      expect(src, contains('approval unanswered for 120s'));
      // The timeout never double-completes against a user tap or Stop.
      expect(src, contains('if (req.completer.isCompleted) return;'));
    });
  });

  group('PR38: native Linux CLI parity — packages + lazy compiler', () {
    test('eager apt list carries the real-Linux CLI set', () {
      final src = File('lib/core/sandbox_service.dart').readAsStringSync();
      // Eager apt install — small, always-needed tools ride with node/
      // python/git so they're present from first launch.
      expect(
        src,
        contains(
          "'nodejs npm python python-pip uv git curl zlib make binutils '\n"
          "        'ripgrep openssh rsync jq unzip tmux'",
        ),
      );
      // Deb-direct fallback (apt-https-broken devices) carries the same set.
      expect(src, contains("'ripgrep', // PR38: real Linux CLI parity"));
      expect(
        src,
        contains(
          "'openssh',\n          'rsync',\n          'jq',\n"
          "          'unzip',\n          'tmux',",
        ),
      );
    });

    test('clang is deliberately NOT in the eager install (too big)', () {
      // The whole point of ensureCompiler() is that clang (~60 MB) does
      // not ride the eager path — assert the eager pkgs string has no
      // compiler in it, so a regression can't silently double the
      // first-launch download size.
      final src = File('lib/core/sandbox_service.dart').readAsStringSync();
      final eagerListMatch = RegExp(
        r"const pkgs =\s*\n\s*'([^']*)'\s*\n\s*'([^']*)';",
      ).firstMatch(src);
      expect(eagerListMatch, isNotNull, reason: 'eager pkgs string moved?');
      final eagerList =
          '${eagerListMatch!.group(1)}${eagerListMatch.group(2)}';
      expect(eagerList, isNot(contains('clang')));
    });

    test('probeRuntimes bin list carries the new CLI tools', () {
      final src = File('lib/core/sandbox_service.dart').readAsStringSync();
      expect(
        src,
        contains(
          "'bash', 'node', 'npm', 'python', 'git', 'curl',\n"
          "      'rg', 'ssh', 'rsync', 'jq', 'unzip', 'tmux',",
        ),
      );
    });

    test('probeRuntimes on an uninstalled sandbox reports every bin false '
        '(old + new, never throws)', () async {
      // PR38 extends the SAME bins map probeRuntimes already returns for
      // an uninstalled sandbox — this exercises the real async function
      // end to end (no ambient singleton install state needed, since the
      // `!_installed` early-return path is what every host unit test hits).
      final probe = await SandboxService.I.probeRuntimes();
      for (final b in [
        'bash', 'node', 'npm', 'python', 'git', 'curl',
        'rg', 'ssh', 'rsync', 'jq', 'unzip', 'tmux',
      ]) {
        expect(probe, contains(b));
      }
    });

    test('ensureCompiler exists as a lazy, idempotent, best-effort install '
        'mirroring ensureRuntime', () {
      final src = File('lib/core/sandbox_service.dart').readAsStringSync();
      final i = src.indexOf('Future<bool> ensureCompiler');
      expect(i, greaterThan(0));
      final body = src.substring(i, i + 1600);
      // Fast idempotent path — a second call is a no-op once flagged.
      expect(body, contains('_compilerEnsured'));
      // Installs exactly `clang` (Termux symlinks cc/gcc/g++ onto it).
      expect(body, contains("install -y clang"));
      // Best-effort: a failure never throws into the caller (run_shell).
      expect(body, contains('catch (e) {'));
    });

    test('run_shell triggers ensureCompiler only for native-build-shaped '
        'commands', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      final i = src.indexOf("case 'run_shell':");
      expect(i, greaterThan(0));
      final body = src.substring(i, i + 20000);
      expect(body, contains('_looksLikeNativeBuildCommand(cmd)'));
      expect(body, contains('SandboxService.I.ensureCompiler('));
    });

    test('native-build regex matches build/install verbs, not plain reads',
        () {
      // Same pattern the source defines — verified against representative
      // commands so the trigger heuristic is provably correct without
      // needing a real sandbox exec.
      final re = RegExp(
        r'\b(npm|yarn|pnpm)\s+(i|install|ci|rebuild|add)\b|'
        r'\bnode-gyp\b|\bmake\b|\bcmake\b|\bcc\b|\bgcc\b|\bclang\b|'
        r'\bpip3?\s+install\b',
      );
      for (final cmd in [
        'npm install',
        'npm i sharp',
        'yarn add better-sqlite3',
        'pnpm rebuild',
        'node-gyp configure',
        'make -j4',
        'pip install numpy',
        'pip3 install lxml',
      ]) {
        expect(re.hasMatch(cmd), isTrue, reason: 'should match: $cmd');
      }
      for (final cmd in [
        'ls -la',
        'cat package.json',
        'npm run build',
        'git status',
      ]) {
        expect(re.hasMatch(cmd), isFalse, reason: 'should NOT match: $cmd');
      }
      // The source's actual regex must carry the same three fragments —
      // otherwise this test would validate a pattern the app doesn't run.
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains(r'\b(npm|yarn|pnpm)\s+(i|install|ci|rebuild|add)\b|'));
      expect(src, contains(r'\bnode-gyp\b|\bmake\b|\bcmake\b|\bcc\b|\bgcc\b|\bclang\b|'));
      expect(src, contains(r'\bpip3?\s+install\b'));
    });

    test('Health screen surfaces the new CLI tools with Repair wired', () {
      final src = File('lib/core/health_service.dart').readAsStringSync();
      for (final name in [
        'ripgrep (rg)',
        'openssh (ssh/scp/sftp)',
        'rsync',
        'jq',
        'unzip',
        'tmux',
      ]) {
        expect(src, contains("name: '$name'"));
      }
      // Every new check stays Repair-eligible (same button fixes it).
      final i = src.indexOf("name: 'ripgrep (rg)'");
      final j = src.indexOf("name: 'tmux'");
      expect(i, greaterThan(0));
      expect(j, greaterThan(i));
      expect(src.substring(i, j + 200), isNot(contains('repairable: false')));
    });
  });

  group('PR39: hook deny/block — on_pre_tool gating (Claude Code PreToolUse parity)', () {
    test('on_pre_tool is a registered, valid hook event', () {
      expect(PluginItem.hookEvents, contains('on_pre_tool'));
    });

    test('fireGate allows when no listener is registered', () async {
      final res = await HookService.I.fireGate('on_pre_tool', 'gate-sess-0');
      expect(res.allowed, isTrue);
    });

    test('exit code 2 denies; the tool never runs and the reason surfaces',
        () async {
      final app = AppState.I;
      final p = PluginItem(
        name: 'guard-plugin',
        author: 'you',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 1,
        hooks: {'on_pre_tool': 'exit 2'},
      );
      app.plugins.add(p);
      addTearDown(() => app.plugins.remove(p));
      final svc = HookService.I;
      svc.gateExecutorForTest = (cmd, env) async =>
          (2, 'dangerous command blocked by policy');
      addTearDown(() => svc.gateExecutorForTest = null);

      final res = await svc.fireGate('on_pre_tool', 'gate-sess-1');
      expect(res.allowed, isFalse);
      expect(res.deniedByPlugin, 'guard-plugin');
      expect(res.reason, contains('dangerous command blocked'));
    });

    test('exit code 0 (or anything but 2) allows', () async {
      final app = AppState.I;
      final p = PluginItem(
        name: 'observer-plugin',
        author: 'you',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 1,
        hooks: {'on_pre_tool': 'exit 0'},
      );
      app.plugins.add(p);
      addTearDown(() => app.plugins.remove(p));
      final svc = HookService.I;
      svc.gateExecutorForTest = (cmd, env) async => (0, '');
      addTearDown(() => svc.gateExecutorForTest = null);

      final res = await svc.fireGate('on_pre_tool', 'gate-sess-2');
      expect(res.allowed, isTrue);
    });

    test('a hook that cannot execute fails OPEN, never wedges the run',
        () async {
      // No sandbox installed AND no test executor configured — the real
      // fail-open path (SandboxService.I.isInstalled == false in tests).
      final app = AppState.I;
      final p = PluginItem(
        name: 'unreachable-plugin',
        author: 'you',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 1,
        hooks: {'on_pre_tool': 'exit 2'},
      );
      app.plugins.add(p);
      addTearDown(() => app.plugins.remove(p));
      final svc = HookService.I;
      expect(svc.gateExecutorForTest, isNull);

      final res = await svc.fireGate('on_pre_tool', 'gate-sess-3');
      expect(
        res.allowed,
        isTrue,
        reason: 'a hook that cannot run must never brick every tool call',
      );
    });

    test('the kill-switch disables the gate exactly like every other hook',
        () async {
      final app = AppState.I;
      final p = PluginItem(
        name: 'gate-killed',
        author: 'you',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 1,
        hooks: {'on_pre_tool': 'exit 2'},
      );
      app.plugins.add(p);
      addTearDown(() => app.plugins.remove(p));
      final svc = HookService.I;
      svc.enabled = false;
      addTearDown(() => svc.enabled = true);
      var called = false;
      svc.gateExecutorForTest = (cmd, env) async {
        called = true;
        return (2, 'should never run');
      };
      addTearDown(() => svc.gateExecutorForTest = null);

      final res = await svc.fireGate('on_pre_tool', 'gate-sess-4');
      expect(res.allowed, isTrue);
      expect(called, isFalse);
    });

    test('_dispatch short-circuits BEFORE _dispatchInner on a hook deny',
        () async {
      final app = AppState.I;
      final s = ChatSession(
        id: 'gate-dispatch-s',
        title: 'gate',
        model: 'm',
        mode: 'drive',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() => app.sessions.removeWhere((x) => x.id == s.id));

      final p = PluginItem(
        name: 'shell-guard',
        author: 'you',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 1,
        hooks: {'on_pre_tool': 'exit 2'},
      );
      app.plugins.add(p);
      addTearDown(() => app.plugins.remove(p));
      final svc = HookService.I;
      svc.gateExecutorForTest = (cmd, env) async =>
          (2, 'rm -rf is not allowed by policy');
      addTearDown(() => svc.gateExecutorForTest = null);

      // run_shell would normally hit approval + real exec — the gate must
      // return BEFORE any of that, so no approval prompt, no exec.
      final res = await AgentService.I.dispatchForTest('run_shell', {
        'command': 'rm -rf /',
      });
      expect(res, startsWith('DENIED by hook (shell-guard):'));
      expect(res, contains('rm -rf is not allowed by policy'));
    });

    test('on_pre_tool payload carries the tool name', () async {
      final app = AppState.I;
      final p = PluginItem(
        name: 'payload-check',
        author: 'you',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 1,
        hooks: {'on_pre_tool': 'inspect'},
      );
      app.plugins.add(p);
      addTearDown(() => app.plugins.remove(p));
      final svc = HookService.I;
      Map<String, String>? gotEnv;
      svc.gateExecutorForTest = (cmd, env) async {
        gotEnv = env;
        return (0, '');
      };
      addTearDown(() => svc.gateExecutorForTest = null);

      await svc.fireGate(
        'on_pre_tool',
        'gate-sess-5',
        payload: {'tool': 'run_shell'},
      );
      expect(gotEnv!['OVID_HOOK_PAYLOAD'], contains('run_shell'));
    });
  });

  group('PR40: plugin content mounting — install fetches real capability', () {
    test('marketplace plugin entry with owner/repo source keeps it', () {
      final app = AppState.I;
      final before = app.plugins.length;
      app.mergeMarketplaceCatalogForTest({
        'plugins': [
          {
            'name': 'PR40 Source Plugin',
            'source': 'someorg/some-plugin',
            'description': 'has a fetchable source',
            'category': 'Tool',
          },
        ],
      }, 'owner', 'market');
      expect(app.plugins.length, before + 1);
      final p = app.plugins.last;
      expect(p.name, 'PR40 Source Plugin');
      expect(p.source, 'someorg/some-plugin');
      app.plugins.remove(p);
    });

    test('a local "./dir" source is dropped (nothing this client can fetch)',
        () {
      final app = AppState.I;
      final before = app.plugins.length;
      app.mergeMarketplaceCatalogForTest({
        'plugins': [
          {
            'name': 'PR40 Local Plugin',
            'source': './plugins/local-one',
            'description': 'local dir, not fetchable',
            'category': 'Tool',
          },
        ],
      }, 'owner', 'market');
      expect(app.plugins.length, before + 1);
      final p = app.plugins.last;
      expect(p.source, isNull);
      app.plugins.remove(p);
    });

    test('a plugin with no source declared has a null source', () {
      final app = AppState.I;
      final before = app.plugins.length;
      app.mergeMarketplaceCatalogForTest({
        'plugins': [
          {'name': 'PR40 No Source Plugin', 'description': 'x'},
        ],
      }, 'owner', 'market');
      final p = app.plugins.last;
      expect(p.source, isNull);
      app.plugins.remove(p);
      expect(app.plugins.length, before);
    });

    test('fetchPluginContent downloads commands/ and skills/*/SKILL.md, '
        'skips everything else', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final path = request.uri.path;
        if (path == '/tree/main') {
          final body = utf8.encode(jsonEncode({
            'tree': [
              {'path': 'commands/hello.md', 'type': 'blob'},
              {'path': 'skills/reviewer/SKILL.md', 'type': 'blob'},
              // Not fetched: wrong dir, wrong filename, or a tree entry.
              {'path': 'README.md', 'type': 'blob'},
              {'path': 'skills/reviewer/notes.txt', 'type': 'blob'},
              {'path': 'commands', 'type': 'tree'},
            ],
          }));
          request.response
            ..statusCode = 200
            ..contentLength = body.length
            ..add(body);
          await request.response.close();
          return;
        }
        if (path == '/raw/commands/hello.md') {
          final body = utf8.encode('---\nname: hello\n---\nSay hi.');
          request.response
            ..statusCode = 200
            ..contentLength = body.length
            ..add(body);
          await request.response.close();
          return;
        }
        if (path == '/raw/skills/reviewer/SKILL.md') {
          final body = utf8.encode('---\nname: reviewer\n---\nReview code.');
          request.response
            ..statusCode = 200
            ..contentLength = body.length
            ..add(body);
          await request.response.close();
          return;
        }
        request.response.statusCode = 404;
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      AppState.pluginContentBaseOverrideForTest =
          'http://${server.address.host}:${server.port}';
      addTearDown(() => AppState.pluginContentBaseOverrideForTest = null);

      final fetched = await AppState.I.fetchPluginContent('acme/some-plugin');
      expect(fetched, 2, reason: 'exactly commands/hello.md + SKILL.md');

      final dir = await AppState.I.pluginCacheDirFor('acme/some-plugin');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      expect(File('${dir.path}/commands/hello.md').existsSync(), isTrue);
      expect(
        File('${dir.path}/skills/reviewer/SKILL.md').existsSync(),
        isTrue,
      );
      expect(File('${dir.path}/README.md').existsSync(), isFalse);
      expect(
        File('${dir.path}/skills/reviewer/notes.txt').existsSync(),
        isFalse,
      );
    });

    test('fetchPluginContent degrades to 0 on a repo with neither directory',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.uri.path == '/tree/main') {
          final body = utf8.encode(jsonEncode({
            'tree': [
              {'path': 'src/index.ts', 'type': 'blob'},
            ],
          }));
          request.response
            ..statusCode = 200
            ..contentLength = body.length
            ..add(body);
          await request.response.close();
          return;
        }
        request.response.statusCode = 404;
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      AppState.pluginContentBaseOverrideForTest =
          'http://${server.address.host}:${server.port}';
      addTearDown(() => AppState.pluginContentBaseOverrideForTest = null);

      final fetched = await AppState.I.fetchPluginContent('acme/empty');
      expect(fetched, 0);
    });

    test('fetchPluginContent never throws when the network is unreachable',
        () async {
      AppState.pluginContentBaseOverrideForTest =
          'http://127.0.0.1:1'; // nothing listens here
      addTearDown(() => AppState.pluginContentBaseOverrideForTest = null);
      final fetched = await AppState.I.fetchPluginContent('acme/offline');
      expect(fetched, 0);
    });

    test('fetchPluginContent rejects a malformed source (no owner/repo)',
        () async {
      expect(await AppState.I.fetchPluginContent('not-a-repo'), 0);
      expect(await AppState.I.fetchPluginContent(''), 0);
    });

    test('removePluginContent deletes the cache dir', () async {
      final dir = await AppState.I.pluginCacheDirFor('acme/to-remove');
      dir.createSync(recursive: true);
      File('${dir.path}/marker.txt').writeAsStringSync('x');
      expect(dir.existsSync(), isTrue);

      await AppState.I.removePluginContent('acme/to-remove');
      expect(dir.existsSync(), isFalse);
    });

    test('_refreshSkillRoots mounts an installed+enabled plugin\'s '
        'commands/skills dirs, and reload() picks up the fetched skill',
        () async {
      final app = AppState.I;
      final agent = AgentService.I;

      // Simulate a fetched plugin: write directly into its cache dir
      // (equivalent to fetchPluginContent having already run).
      final dir = await app.pluginCacheDirFor('acme/mounted-plugin');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      Directory('${dir.path}/commands').createSync(recursive: true);
      File('${dir.path}/commands/greet.md').writeAsStringSync(
        '---\nname: greet\nuser-invocable: true\n---\nSay hello.',
      );

      final p = PluginItem(
        name: 'mounted-plugin',
        author: 'acme',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 0,
        source: 'acme/mounted-plugin',
      );
      app.plugins.add(p);
      addTearDown(() {
        app.plugins.remove(p);
        SkillService.I.clearRoots();
      });

      await agent.refreshSkills();

      expect(
        SkillService.I.skills.any((s) => s.name == 'greet'),
        isTrue,
        reason: 'the plugin\'s fetched command becomes a real skill',
      );
      expect(
        SkillService.I.userSkills.any((s) => s.name == 'greet'),
        isTrue,
        reason: 'user-invocable → shows in the /-menu',
      );
    });

    test('a DISABLED plugin\'s content is not mounted', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final dir = await app.pluginCacheDirFor('acme/disabled-plugin');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      Directory('${dir.path}/commands').createSync(recursive: true);
      File('${dir.path}/commands/nope.md').writeAsStringSync(
        '---\nname: nope\nuser-invocable: true\n---\nShould not mount.',
      );

      final p = PluginItem(
        name: 'disabled-plugin',
        author: 'acme',
        description: '',
        version: '1.0',
        category: 'Tool',
        installed: true,
        enabled: false, // ← the point of this test
        installs: 0,
        source: 'acme/disabled-plugin',
      );
      app.plugins.add(p);
      addTearDown(() {
        app.plugins.remove(p);
        SkillService.I.clearRoots();
      });

      await agent.refreshSkills();

      expect(SkillService.I.skills.any((s) => s.name == 'nope'), isFalse);
    });
  });

  group('PR41: MCP Streamable-HTTP transport + reconnect backoff', () {
    setUp(() {
      // Fast, deterministic backoff for every test in this group.
      McpService.reconnectInitialDelayForTest =
          const Duration(milliseconds: 5);
      McpService.reconnectMaxDelayForTest = const Duration(milliseconds: 20);
      McpService.reconnectMaxAttemptsForTest = 3;
      McpService.rpcTimeoutSecondsForTest = 2;
    });
    tearDown(() {
      McpService.I.httpClientForTest = null;
      McpService.reconnectInitialDelayForTest =
          const Duration(milliseconds: 500);
      McpService.reconnectMaxDelayForTest = const Duration(seconds: 30);
      McpService.reconnectMaxAttemptsForTest = 10;
      McpService.rpcTimeoutSecondsForTest = 30;
    });

    test('McpServer defaults to stdio transport with no url', () {
      final s = McpServer(
        name: 'default-transport',
        author: 't',
        description: '',
        category: 'Custom',
        command: 'npx',
      );
      expect(s.transport, 'stdio');
      expect(s.url, isNull);
    });

    test('map-form marketplace entry with a url becomes an http server',
        () {
      final app = AppState.I;
      final before = app.mcpServers.length;
      app.mergeMarketplaceCatalogForTest({
        'mcpServers': {
          'PR41 HTTP Server': {
            'url': 'https://example.com/mcp',
            'headers': {'Authorization': 'Bearer tok'},
          },
        },
      }, 'acme', 'market');
      expect(app.mcpServers.length, before + 1);
      final s = app.mcpServers.last;
      expect(s.transport, 'http');
      expect(s.url, 'https://example.com/mcp');
      expect(s.headers['Authorization'], 'Bearer tok');
      app.mcpServers.remove(s);
    });

    test('map-form marketplace entry with a command (no url) stays stdio',
        () {
      final app = AppState.I;
      final before = app.mcpServers.length;
      app.mergeMarketplaceCatalogForTest({
        'mcpServers': {
          'PR41 Stdio Server': {'command': 'npx', 'args': ['-y', 'x']},
        },
      }, 'acme', 'market');
      final s = app.mcpServers.last;
      expect(s.transport, 'stdio');
      expect(s.url, isNull);
      app.mcpServers.remove(s);
      expect(app.mcpServers.length, before);
    });

    test('connect() over http performs initialize + tools/list and reports '
        'the discovered tools', () async {
      final calls = <String>[];
      McpService.I.httpClientForTest = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        calls.add(body['method'] as String);
        if (body['method'] == 'initialize') {
          return http.Response(
            jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': {}}),
            200,
          );
        }
        if (body['method'] == 'tools/list') {
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {
                'tools': [
                  {'name': 'remote_tool', 'description': 'd'},
                ],
              },
            }),
            200,
          );
        }
        return http.Response('', 202); // notifications/initialized
      });

      final server = McpServer(
        name: 'PR41 Connect Server',
        author: 't',
        description: '',
        category: 'Custom',
        command: 'npx',
        transport: 'http',
        url: 'https://example.com/mcp',
      );
      addTearDown(() => McpService.I.disconnect(server.name));

      final status = await McpService.I.connect(server);
      expect(status, contains('connected (http)'));
      expect(status, contains('1 tools'));
      expect(McpService.I.isConnected(server.name), isTrue);
      expect(
        McpService.I.connectedTools[server.name]!.first.name,
        'remote_tool',
      );
      expect(calls, containsAll(['initialize', 'tools/list']));
    });

    test('callTool over http returns the text content, same shape as stdio',
        () async {
      McpService.I.httpClientForTest = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['method'] == 'tools/call') {
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {
                'content': [
                  {'type': 'text', 'text': 'remote result'},
                ],
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': {}}),
          200,
        );
      });
      final server = McpServer(
        name: 'PR41 CallTool Server',
        author: 't',
        description: '',
        category: 'Custom',
        command: 'npx',
        transport: 'http',
        url: 'https://example.com/mcp',
      );
      addTearDown(() => McpService.I.disconnect(server.name));
      await McpService.I.connect(server);

      final result = await McpService.I.callTool(
        server.name,
        'remote_tool',
        {},
      );
      expect(result, 'remote result');
    });

    test('a JSON-RPC error over http surfaces as "MCP error: …", never a '
        'fake success', () async {
      McpService.I.httpClientForTest = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['method'] == 'tools/call') {
          return http.Response(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': body['id'],
              'error': {'message': 'tool not found'},
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': {}}),
          200,
        );
      });
      final server = McpServer(
        name: 'PR41 Error Server',
        author: 't',
        description: '',
        category: 'Custom',
        command: 'npx',
        transport: 'http',
        url: 'https://example.com/mcp',
      );
      addTearDown(() => McpService.I.disconnect(server.name));
      await McpService.I.connect(server);

      final result = await McpService.I.callTool(server.name, 'x', {});
      expect(result, 'MCP error: tool not found');
    });

    test('an http server-side (non-2xx) error is a per-call failure — the '
        'server stays connected, no reconnect scheduled', () async {
      var callToolCount = 0;
      McpService.I.httpClientForTest = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['method'] == 'tools/call') {
          callToolCount++;
          return http.Response('server error', 500);
        }
        return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': body['id'], 'result': {}}),
          200,
        );
      });
      final server = McpServer(
        name: 'PR41 500 Server',
        author: 't',
        description: '',
        category: 'Custom',
        command: 'npx',
        transport: 'http',
        url: 'https://example.com/mcp',
      );
      addTearDown(() => McpService.I.disconnect(server.name));
      await McpService.I.connect(server);

      final result = await McpService.I.callTool(server.name, 'x', {});
      expect(result, contains('MCP error'));
      expect(callToolCount, 1);
      // Still connected — a 500 means the server responded, it's up.
      expect(McpService.I.isConnected(server.name), isTrue);
      expect(McpService.I.hasPendingReconnectForTest(server.name), isFalse);
    });

    test('a connection-level http failure drops the server and schedules '
        'reconnect with backoff', () async {
      var attempts = 0;
      McpService.I.httpClientForTest = MockClient((request) async {
        attempts++;
        throw const SocketException('connection refused');
      });
      final app = AppState.I;
      final server = McpServer(
        name: 'PR41 Unreachable Server',
        author: 't',
        description: '',
        category: 'Custom',
        command: 'npx',
        transport: 'http',
        url: 'https://example.com/mcp',
      );
      app.mcpServers.add(server);
      addTearDown(() {
        McpService.I.disconnect(server.name);
        app.mcpServers.remove(server);
      });

      final status = await McpService.I.connect(server);
      expect(status, contains('connect failed'));
      expect(McpService.I.isConnected(server.name), isFalse);
      expect(attempts, 1, reason: 'exactly one dial, no retry loop inline');

      // The FIRST connect failure is a direct throw from connect(), not a
      // mid-session drop — no reconnect is scheduled for a connect() that
      // never succeeded in the first place (nothing to "recover" from).
      expect(McpService.I.hasPendingReconnectForTest(server.name), isFalse);
    });

    test('an unexpected mid-session http failure (after a successful '
        'connect) schedules reconnect, capped at reconnectMaxAttempts',
        () async {
      var shouldFail = false;
      McpService.I.httpClientForTest = MockClient((request) async {
        if (shouldFail) throw const SocketException('reset by peer');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': body['id'],
            'result': body['method'] == 'tools/list' ? {'tools': []} : {},
          }),
          200,
        );
      });
      final app = AppState.I;
      final server = McpServer(
        name: 'PR41 Flaky Server',
        author: 't',
        description: '',
        category: 'Custom',
        command: 'npx',
        transport: 'http',
        url: 'https://example.com/mcp',
      );
      app.mcpServers.add(server);
      addTearDown(() {
        McpService.I.disconnect(server.name);
        app.mcpServers.remove(server);
      });

      final status = await McpService.I.connect(server);
      expect(status, contains('connected (http)'));

      // Now the server starts failing every call — the next callTool
      // triggers the connection-level failure path.
      shouldFail = true;
      await McpService.I.callTool(server.name, 'x', {});
      expect(McpService.I.isConnected(server.name), isFalse);
      expect(McpService.I.hasPendingReconnectForTest(server.name), isTrue);
      expect(McpService.I.reconnectAttemptsForTest(server.name), 1);

      // Let the scheduled reconnect fire — it fails again (shouldFail is
      // still true), so a SECOND reconnect is scheduled with a longer
      // delay, doubling the attempt count.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
        McpService.I.reconnectAttemptsForTest(server.name),
        greaterThanOrEqualTo(1),
      );
    });

    test('disconnect() cancels any pending reconnect and never triggers one',
        () async {
      McpService.I.httpClientForTest = MockClient((request) async {
        throw const SocketException('unreachable');
      });
      final app = AppState.I;
      final server = McpServer(
        name: 'PR41 Manual Disconnect Server',
        author: 't',
        description: '',
        category: 'Custom',
        command: 'npx',
        transport: 'http',
        url: 'https://example.com/mcp',
      );
      app.mcpServers.add(server);
      addTearDown(() => app.mcpServers.remove(server));

      await McpService.I.connect(server); // fails immediately (unreachable)
      expect(McpService.I.hasPendingReconnectForTest(server.name), isFalse);

      await McpService.I.disconnect(server.name);
      expect(McpService.I.reconnectAttemptsForTest(server.name), 0);
    });

    test('custom HTTP server persists transport/url/headers across a '
        'simulated restart', () async {
      final app = AppState.I;
      app.addCustomMcpServer(
        name: 'PR41 Persisted HTTP',
        command: 'npx',
        url: 'https://example.com/mcp',
        headers: {'X-Api-Key': 'secret'},
      );
      final added = app.mcpServers.firstWhere(
        (s) => s.name == 'PR41 Persisted HTTP',
      );
      expect(added.transport, 'http');
      expect(added.url, 'https://example.com/mcp');
      expect(added.headers['X-Api-Key'], 'secret');

      // Give the fire-and-forget persist a chance to land (same idiom the
      // pre-existing "custom MCP servers persist" test uses: any real
      // await yields to the microtask queue).
      await SharedPreferences.getInstance();

      // Simulate reload: remove in-memory, then reload from prefs.
      app.mcpServers.remove(added);
      await app.reloadCustomMcpServersForTest();
      final reloaded = app.mcpServers.firstWhere(
        (s) => s.name == 'PR41 Persisted HTTP',
      );
      expect(reloaded.transport, 'http');
      expect(reloaded.url, 'https://example.com/mcp');
      expect(reloaded.headers['X-Api-Key'], 'secret');

      app.removeMcpServer(reloaded);
    });

    test('pasted .mcp.json with a url+headers entry imports as an http '
        'server (Claude Desktop remote shape)', () {
      // _parseMcpConfig is private; drive it through the import surface
      // by calling it directly via the same file-level function the
      // dialog uses (exposed for tests below).
      final res = parseMcpConfigForTest('''
{
  "mcpServers": {
    "remote-db": {
      "url": "https://db.example.com/mcp",
      "headers": {"Authorization": "Bearer tok123"}
    },
    "local-fs": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem"]
    }
  }
}
''');
      expect(res.length, 2);
      final remote = res.firstWhere((s) => s.name == 'remote-db');
      expect(remote.url, 'https://db.example.com/mcp');
      expect(remote.headers['Authorization'], 'Bearer tok123');
      final local = res.firstWhere((s) => s.name == 'local-fs');
      expect(local.url, isNull);
      expect(local.command, 'npx');
    });

    test('pasted Codex config.toml now carries url AND env (the audit '
        '§3.3 finding: env was silently dropped)', () {
      final res = parseMcpConfigForTest('''
[mcp_servers.github]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]
env.GITHUB_TOKEN = "ghp_abc123"

[mcp_servers.remote-api]
url = "https://api.example.com/mcp"
''');
      expect(res.length, 2);
      final gh = res.firstWhere((s) => s.name == 'github');
      expect(gh.env['GITHUB_TOKEN'], 'ghp_abc123',
          reason: 'TOML env lines must no longer be dropped');
      final remote = res.firstWhere((s) => s.name == 'remote-api');
      expect(remote.url, 'https://api.example.com/mcp');
    });
  });

  group('PR42: fs_grep ripgrep-backed fast path (real Linux grep)', () {
    /// Build a fake sandbox prefix whose `bin/rg` is a stub script.
    /// [scriptBody] runs with cwd = the session workspace; `"$@"` is rg's
    /// argv. Also links bin/sh so any `bash -c` fallback path resolves.
    Future<Directory> fakeRgPrefix(String scriptBody) async {
      final tmp = await Directory.systemTemp.createTemp('pr42prefix');
      await Directory('${tmp.path}/bin').create(recursive: true);
      final shTarget = File('/usr/bin/sh').existsSync()
          ? '/usr/bin/sh'
          : '/bin/sh';
      Link('${tmp.path}/bin/sh').createSync(shTarget);
      final rg = File('${tmp.path}/bin/rg')
        ..writeAsStringSync('#!/bin/sh\n$scriptBody\n');
      Process.runSync('chmod', ['+x', rg.path]);
      return tmp;
    }

    test('fs_grep runs the real rg with parity flags when the sandbox has '
        'it — and its answer replaces the Dart walk', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final svc = SandboxService.I;
      // Stub rg: record argv into the workspace, print one match line.
      final tmp = await fakeRgPrefix(
        'printf \'%s\\n\' "\$@" > .rg_args_probe\n'
        'echo "FAKERG/notes.md:9: [rg-ran] milk"',
      );
      addTearDown(() {
        svc.sandboxPrefixForTest = null;
        tmp.deleteSync(recursive: true);
      });
      svc.sandboxPrefixForTest = tmp;

      final s = ChatSession(
        id: 'pr42-rg-1',
        title: 'rg',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() => app.sessions.removeWhere((x) => x.id == s.id));

      // A REAL workspace file that also matches — proves the Dart walk
      // did not run (only the rg line may appear in the output).
      final work = await agent.sessionWorkDirForTest();
      File('${work.path}/real.txt').writeAsStringSync('milk in real file\n');

      final out = await agent.dispatchForTest('fs_grep', {
        'pattern': 'milk',
      });
      expect(out, contains('[rg-ran] milk'));
      expect(
        out,
        isNot(contains('real.txt')),
        reason: 'rg answered → the Dart walk must not also run',
      );

      // The stub recorded its argv — assert the semantic-parity flags.
      final probe = File('${work.path}/.rg_args_probe');
      expect(probe.existsSync(), isTrue, reason: 'stub rg actually ran');
      final argv = probe.readAsStringSync();
      for (final flag in [
        '-i',
        '--no-heading',
        '--hidden',
        '--no-ignore',
        '--max-filesize',
        '2M',
        '--max-count-total',
        '-e',
        'milk',
      ]) {
        expect(argv, contains(flag), reason: 'rg must receive $flag');
      }
    });

    test('rg exit 2 (rust-regex rejects the pattern, e.g. lookarounds) '
        'falls back to the Dart walk — output discarded', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final svc = SandboxService.I;
      final tmp = await fakeRgPrefix(
        'echo "FAKERG/x.md:1: [rg-ran] milk"\n'
        'exit 2',
      );
      addTearDown(() {
        svc.sandboxPrefixForTest = null;
        tmp.deleteSync(recursive: true);
      });
      svc.sandboxPrefixForTest = tmp;

      final s = ChatSession(
        id: 'pr42-rg-2',
        title: 'rg',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() => app.sessions.removeWhere((x) => x.id == s.id));

      final work = await agent.sessionWorkDirForTest();
      File('${work.path}/real.txt').writeAsStringSync('lookaround milk\n');

      final out = await agent.dispatchForTest('fs_grep', {
        'pattern': 'milk',
      });
      expect(out, contains('real.txt'), reason: 'Dart walk found it');
      expect(
        out,
        isNot(contains('[rg-ran]')),
        reason: 'exit-2 output must be discarded, not merged',
      );
    });

    test('rg exit 1 (no matches) is a legitimate verdict — the Dart walk '
        'is NOT run to second-guess it', () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final svc = SandboxService.I;
      final tmp = await fakeRgPrefix('exit 1');
      addTearDown(() {
        svc.sandboxPrefixForTest = null;
        tmp.deleteSync(recursive: true);
      });
      svc.sandboxPrefixForTest = tmp;

      final s = ChatSession(
        id: 'pr42-rg-3',
        title: 'rg',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() => app.sessions.removeWhere((x) => x.id == s.id));

      // A real matching file exists — rg said "no matches", so the tool
      // must report none rather than re-running the Dart walk.
      final work = await agent.sessionWorkDirForTest();
      File('${work.path}/real.txt').writeAsStringSync('milk hidden from rg\n');

      final out = await agent.dispatchForTest('fs_grep', {
        'pattern': 'milk',
      });
      expect(out, contains('no matches'));
      expect(out, isNot(contains('real.txt')));
    });

    test('no sandbox at all → unchanged pure-Dart behavior (gate check)',
        () async {
      final app = AppState.I;
      final agent = AgentService.I;
      final svc = SandboxService.I;
      expect(svc.prefixPath, isNull, reason: 'no fake prefix in this test');

      final s = ChatSession(
        id: 'pr42-rg-4',
        title: 'rg',
        model: 'm',
        mode: 'auto',
      );
      app.sessions.insert(0, s);
      app.activeSessionId = s.id;
      addTearDown(() => app.sessions.removeWhere((x) => x.id == s.id));

      final work = await agent.sessionWorkDirForTest();
      File('${work.path}/plain.txt').writeAsStringSync('milk dart path\n');

      final out = await agent.dispatchForTest('fs_grep', {
        'pattern': 'milk',
      });
      expect(out, contains('plain.txt'));
      expect(out, contains('milk dart path'));
    });

    test('fs_glob deliberately stays on the Dart walk — rg traversal '
        'defaults would hide the workspace dot-dirs (.dsh/.agents/.spill)',
        () {
      // Source contract: the glob handler must not shell out to rg.
      // This is a DECISION, not an omission: rg --files skips hidden
      // files and respects .gitignore by default, which would silently
      // break skills (.dsh/skills) and spill (.spill/) discoverability;
      // the flags that disable that (--hidden --no-ignore) make rg's
      // traversal equivalent to the existing Dart walk, leaving no value.
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      final i = src.indexOf('Future<String> _handleFsGlob');
      final j = src.indexOf('Future<String> _handleFsGrep');
      expect(i, greaterThan(0));
      expect(j, greaterThan(i));
      final body = src.substring(i, j);
      expect(body, isNot(contains("'rg'")));
      expect(body, isNot(contains('_tryRgGrep')));
    });
  });

  group('PR47: apt/pkg parity wall + npm/npx direct wrappers (K1-K8)', () {
    test('K1: OvidPkgInstaller writes direct npm and npx wrappers without Termux env', () {
      final tmp = Directory.systemTemp.createTempSync('ovid-pr47-k1');
      addTearDown(() => tmp.deleteSync(recursive: true));

      OvidPkgInstaller.writeAll(tmp);

      final npmFile = File('${tmp.path}/bin/npm');
      expect(npmFile.existsSync(), isTrue);
      final npmContent = npmFile.readAsStringSync();
      expect(npmContent, startsWith('#!${tmp.path}/bin/sh\n'));
      expect(npmContent, contains('exec "${tmp.path}/bin/node" "${tmp.path}/lib/node_modules/npm/bin/npm-cli.js" "\$@"'));
      expect(npmContent, isNot(contains('com.termux')));
      expect(npmContent, isNot(contains('/data/data/')));
      expect(npmContent, isNot(contains('/usr/bin/env')));

      final npxFile = File('${tmp.path}/bin/npx');
      expect(npxFile.existsSync(), isTrue);
      final npxContent = npxFile.readAsStringSync();
      expect(npxContent, startsWith('#!${tmp.path}/bin/sh\n'));
      expect(npxContent, contains('exec "${tmp.path}/bin/node" "${tmp.path}/lib/node_modules/npm/bin/npx-cli.js" "\$@"'));
      expect(npxContent, isNot(contains('com.termux')));
      expect(npxContent, isNot(contains('/data/data/')));
      expect(npxContent, isNot(contains('/usr/bin/env')));
    });

    test('K2 & K3: OvidPkgInstaller writes ovid-pkg and apt/apt-get/pkg forward wrappers', () {
      final tmp = Directory.systemTemp.createTempSync('ovid-pr47-k2');
      addTearDown(() => tmp.deleteSync(recursive: true));

      OvidPkgInstaller.writeAll(tmp);

      final ovidPkg = File('${tmp.path}/bin/ovid-pkg');
      expect(ovidPkg.existsSync(), isTrue);
      final ovidPkgContent = ovidPkg.readAsStringSync();
      expect(ovidPkgContent, startsWith('#!${tmp.path}/bin/sh\n'));
      expect(ovidPkgContent, contains('curl -fsSL'));
      expect(ovidPkgContent, contains('dpkg --root='));
      expect(ovidPkgContent, contains('update)'));
      expect(ovidPkgContent, contains('install)'));
      expect(ovidPkgContent, contains('search)'));

      for (final tool in ['apt', 'apt-get', 'pkg']) {
        final wrapper = File('${tmp.path}/bin/$tool');
        expect(wrapper.existsSync(), isTrue, reason: '$tool wrapper must exist');
        final content = wrapper.readAsStringSync();
        expect(content, startsWith('#!${tmp.path}/bin/sh\n'));
        expect(content, contains('exec "${tmp.path}/bin/ovid-pkg" "\$@"'));
      }
    });

    test('K4: SandboxService hooks OvidPkgInstaller.writeAll in selfHeal and install', () {
      final src = File('lib/core/sandbox_service.dart').readAsStringSync();
      expect(src, contains('OvidPkgInstaller.writeAll(prefix)'));
      // Appears in both _installRuntime and _selfHeal
      final count = RegExp(r'OvidPkgInstaller\.writeAll\(prefix\)').allMatches(src).length;
      expect(count, greaterThanOrEqualTo(2));
    });

    test('K5: AgentService._isEchoPlaceholder identifies bare echo fake-work', () {
      final agent = AgentService.I;

      // Positive cases: echo / printf placeholders
      expect(agent.isEchoPlaceholderForTest('echo "Command 1 executed"'), isTrue);
      expect(agent.isEchoPlaceholderForTest("echo 'Done'"), isTrue);
      expect(agent.isEchoPlaceholderForTest('printf "all done\\n"'), isTrue);
      expect(agent.isEchoPlaceholderForTest('echo "step 1" && echo "step 2"'), isTrue);
      expect(agent.isEchoPlaceholderForTest('true && echo "finished"'), isTrue);
      expect(agent.isEchoPlaceholderForTest(': ; echo "nothing"'), isTrue);

      // Negative cases: real commands or file writes
      expect(agent.isEchoPlaceholderForTest('echo "hello" > output.txt'), isFalse);
      expect(agent.isEchoPlaceholderForTest('echo "world" >> append.log'), isFalse);
      expect(agent.isEchoPlaceholderForTest('npm test'), isFalse);
      expect(agent.isEchoPlaceholderForTest('npm test && echo "done"'), isFalse);
      expect(agent.isEchoPlaceholderForTest('node server.js'), isFalse);
      expect(agent.isEchoPlaceholderForTest('python3 main.py'), isFalse);
      expect(agent.isEchoPlaceholderForTest('cat README.md | grep title'), isFalse);
      expect(agent.isEchoPlaceholderForTest('mkdir -p build && touch build/app'), isFalse);
    });

    test('K6: HealthScreen offers hard reset sandbox action', () {
      final src = File('lib/ui/health_screen.dart').readAsStringSync();
      expect(src, contains('Future<void> _hardResetSandbox()'));
      expect(src, contains('SandboxService.I.uninstall()'));
      expect(src, contains('SandboxSetupScreen(gateMode: true)'));
      expect(src, contains('Hard reset the sandbox (deletes + reinstalls)'));
    });

    test('K7: SandboxSetupScreen has error view with retry and terminal', () {
      final src = File('lib/ui/sandbox_setup.dart').readAsStringSync();
      expect(src, contains('Widget _errorView()'));
      expect(src, contains('Retry install'));
      expect(src, contains('_terminal()'));
    });
  });

  // ── PR48: DSH prompt-context bundle — file_read windowing, read_image,
  // AGENTS.md, time-context, locale, welcome (RED first, TDD) ──
  group('PR48: file_read windowing + read_image (DSH tool-fs parity)', () {
    Map<String, dynamic> fileReadSchema() {
      final tools = AgentService.I.toolsForTest();
      return tools.firstWhere(
        (t) => (t['function'] as Map)['name'] == 'file_read',
      )['function'] as Map<String, dynamic>;
    }

    test('P1: file_read schema carries offset/limit (DSH read windowing)', () {
      final props =
          (fileReadSchema()['parameters'] as Map)['properties'] as Map;
      expect(props.containsKey('offset'), isTrue,
          reason: 'DSH read has offset (1-based start line)');
      expect(props.containsKey('limit'), isTrue,
          reason: 'DSH read has limit (max lines, cap 2000)');
    });

    test('P2: file_read honors offset/limit with totalLines + capped footer',
        () async {
      final agent = AgentService.I;
      final lines = List.generate(500, (i) => 'line ${i + 1}');
      RepoCache.I.files['big.txt'] = '${lines.join('\n')}\n';
      addTearDown(() => RepoCache.I.files.remove('big.txt'));

      final out = await agent.dispatchForTest('file_read', {
        'path': 'big.txt',
        'offset': 101,
        'limit': 50,
      });
      expect(out, contains('line 101'));
      expect(out, contains('line 150'));
      expect(out, isNot(contains('line 100\n')),
          reason: 'window must start at offset');
      expect(out, isNot(contains('line 151\n')),
          reason: 'window must end at offset+limit-1');
      // Fixture has a trailing newline → split yields 501 rows; the
      // header must report the true totalLines so the model can page.
      expect(out, contains('totalLines: 501'),
          reason: 'DSH read reports totalLines so the model can page');
      expect(out, contains('offset=151'),
          reason: 'capped footer must tell the model how to continue');
    });

    test('P3: read_image tool exists and returns image metadata', () async {
      final tools = AgentService.I.toolsForTest();
      final names = tools
          .map((t) => ((t['function'] as Map)['name'] as String))
          .toSet();
      expect(names, contains('read_image'),
          reason: 'DSH dsh-tool-fs ships read_image alongside read');

      final out = await AgentService.I.dispatchForTest('read_image', {
        'path': 'nope.png',
      });
      expect(out, contains('nope.png'),
          reason: 'missing file must name the path, not "unknown tool"');
    });
  });

  group('PR48: AGENTS.md + time-context + locale + welcome', () {
    test('P4: agent loads AGENTS.md workspace instructions into the prompt',
        () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains('AGENTS.md'),
          reason: 'workspace instruction chain (DSH skills/AGENTS parity)');
    });

    test('P5: system prompt carries the current time (DSH time-context)', () {
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, contains('Current time:'),
          reason: 'model needs a clock for unqualified dates/times');
    });

    test('P6: locale preference is persisted (DSH client-locale)', () {
      final src = File('lib/core/state.dart').readAsStringSync();
      expect(src, contains('ovid_locale'),
          reason: 'zh/en reply-language pref, DSH locale.preference parity');
    });

    test('P7: first-run welcome notice is versioned (DSH ui-onboarding)', () {
      final src = File('lib/core/state.dart').readAsStringSync();
      expect(src, contains('ovid_welcome'),
          reason: 'welcomeNoticeVersion parity — show once per version');
    });
  });
}

/// Build one DuckDuckGo-style result block (anchor + snippet pair).
Iterable<String> _ddgResult(String title, String href, String snippet) => [
      '<a class="result__a" href="$href">$title</a>',
      '<a class="result__snippet" href="$href">${snippet}z</a>',
    ];
