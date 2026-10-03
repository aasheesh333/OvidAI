import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';

// Real sockets are essential here: MockClient does not exercise automatic
// redirects or credential forwarding by the production IO transport.
class _SseFixture {
  _SseFixture(this.server, this.secure) {
    server.listen(_handle);
  }

  final HttpServer server;
  final bool secure;
  final requests = <({String method, String path, bool auth, bool custom})>[];
  final messages = <Map<String, dynamic>>[];
  final redirects = <String, ({int status, String location})>{};
  final acknowledgments = <String>{};
  String? endpoint;
  String responsePrefix = '';
  bool deferToolResponses = false;
  HttpResponse? stream;

  Uri get base => Uri.parse(
    '${secure ? 'https' : 'http'}'
    '://127.0.0.1:${server.port}',
  );

  static Future<_SseFixture> start({SecurityContext? tls}) async => _SseFixture(
    tls == null
        ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        : await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, tls),
    tls != null,
  );

  Future<void> _handle(HttpRequest request) async {
    requests.add((
      method: request.method,
      path: request.uri.toString(),
      auth: request.headers.value(HttpHeaders.authorizationHeader) != null,
      custom: request.headers.value('x-mcp-key') != null,
    ));
    final body = await utf8.decoder.bind(request).join();
    final redirect = redirects[request.uri.path];
    if (redirect != null) {
      request.response.statusCode = redirect.status;
      request.response.headers.set('location', redirect.location);
      await request.response.close();
      return;
    }
    if (request.uri.path.endsWith('/sse')) {
      stream = request.response;
      stream!.headers.contentType = ContentType('text', 'event-stream');
      stream!.bufferOutput = false;
      await emit(
        'event: endpoint\ndata: ${endpoint ?? base.resolve('/message')}',
      );
      return;
    }
    if (request.method == 'POST') {
      final message = jsonDecode(body) as Map<String, dynamic>;
      messages.add(message);
      final result = switch (message['method']) {
        'initialize' => <String, dynamic>{
          'protocolVersion': '2024-11-05',
          'capabilities': {},
          'serverInfo': {'name': 'origin-fixture', 'version': '1'},
        },
        'tools/list' => <String, dynamic>{
          'tools': [
            {
              'name': 'ping',
              'description': 'fixture ping',
              'inputSchema': {'type': 'object'},
            },
          ],
        },
        'tools/call' => <String, dynamic>{
          'content': [
            {'type': 'text', 'text': 'pong'},
          ],
        },
        _ => null,
      };
      if (result != null &&
          stream != null &&
          !(deferToolResponses && message['method'] == 'tools/call')) {
        await emit(
          '${responsePrefix}data: ${jsonEncode({'jsonrpc': '2.0', 'id': message['id'], 'result': result})}',
        );
      }
    }
    if (request.method == 'POST' &&
        acknowledgments.contains(request.uri.path)) {
      request.response.statusCode = HttpStatus.seeOther;
      request.response.headers.set('location', '/ack');
    } else {
      request.response.statusCode = HttpStatus.accepted;
    }
    await request.response.close();
  }

  Future<void> emit(String event) async {
    stream!.write('$event\n\n');
    await stream!.flush();
  }

  Future<void> close() => server.close(force: true);
}

// Observes real HTTP acknowledgments and stream cancellation. It never
// fabricates responses; the extra event turn lets post() enter nextResponse().
class _ObservedClient extends http.BaseClient {
  final _inner = IOClient();
  final streamCancelled = Completer<void>();
  final toolAcknowledged = Completer<void>();
  final twoToolsAcknowledged = Completer<void>();
  int toolAcknowledgments = 0;
  Future<void>? holdToolAcknowledgment;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (request is http.Request &&
        request.method == 'POST' &&
        (jsonDecode(request.body) as Map)['method'] == 'tools/call') {
      Timer.run(() {
        if (!toolAcknowledged.isCompleted) toolAcknowledged.complete();
        if (++toolAcknowledgments == 2) twoToolsAcknowledged.complete();
      });
      await holdToolAcknowledgment;
    }
    if (request.method != 'GET') return response;
    late StreamSubscription<List<int>> subscription;
    late StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        subscription = response.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onCancel: () {
        if (!streamCancelled.isCompleted) streamCancelled.complete();
        return subscription.cancel();
      },
    );
    return http.StreamedResponse(
      controller.stream,
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() => _inner.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SseFixture approved;
  late _SseFixture unapproved;
  late Directory certificates;
  late SecurityContext serverTls;
  late SecurityContext clientTls;
  final servers = <McpServer>[];
  IOClient? tlsClient;

  setUpAll(() async {
    HttpOverrides.global = null;
    // Ephemeral loopback-only test identity; no checked-in private key and no
    // certificate bypass. The real client trusts only this generated CA.
    certificates = await Directory.systemTemp.createTemp('mcp-sse-tls-');
    final cert = '${certificates.path}/cert.pem';
    final key = '${certificates.path}/key.pem';
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '1',
      '-subj',
      '/CN=127.0.0.1',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
      '-keyout',
      key,
      '-out',
      cert,
    ]);
    expect(result.exitCode, 0, reason: 'generate loopback TLS fixture');
    serverTls = SecurityContext()
      ..useCertificateChain(cert)
      ..usePrivateKey(key);
    clientTls = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(cert);
  });

  tearDownAll(() => certificates.delete(recursive: true));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
    McpService.oauthSecureStorageDisabledForTest = true;
    approved = await _SseFixture.start();
    unapproved = await _SseFixture.start();
  });

  tearDown(() async {
    for (final server in servers) {
      await McpService.I.disconnect(server.canonicalId);
      await McpService.I.clearMcpOAuthToken(server.canonicalId);
    }
    servers.clear();
    tlsClient?.close();
    tlsClient = null;
    McpService.I.httpClientForTest = null;
    McpService.oauthSecureStorageDisabledForTest = false;
    await approved.close();
    await unapproved.close();
    AppState.resetTestInstance();
  });

  Future<McpServer> configured({Uri? url}) async {
    final server = McpServer(
      name: 'sse-origin-${servers.length}',
      author: 'test',
      description: 'origin policy fixture',
      category: 'Custom',
      command: '',
      custom: true,
      transport: 'sse',
      url: (url ?? approved.base.resolve('/configured/sse')).toString(),
      headers: {'X-Mcp-Key': 'fixture-only-key'},
      startupTimeoutS: 1,
    );
    servers.add(server);
    await McpService.I.storeMcpOAuthToken(
      server.canonicalId,
      const McpOAuthToken(accessToken: 'fixture-only-token'),
    );
    return server;
  }

  Future<void> useTls() async {
    await approved.close();
    approved = await _SseFixture.start(tls: serverTls);
    tlsClient = IOClient(HttpClient(context: clientTls));
    McpService.I.httpClientForTest = tlsClient;
  }

  Future<void> expectRefused(McpServer server) async {
    final status = await McpService.I.connect(server);
    // Inspect fixture receipts before status so credential leaks fail directly.
    expect(
      unapproved.requests,
      isEmpty,
      reason: 'unapproved server must receive no request or credentials',
    );
    expect(status, contains('SSE destination rejected'));
    expect(status, isNot(contains('fixture-only')));
    expect(McpService.I.isConnected(server.canonicalId), isFalse);
  }

  for (final relative in ['message?session=one', '/message?session=one']) {
    test(
      'relative endpoint $relative completes handshake and tool call',
      () async {
        approved.endpoint = relative;
        final server = await configured();
        expect(await McpService.I.connect(server), contains('connected (sse)'));
        expect(
          await McpService.I.callTool(server.canonicalId, 'ping', {}),
          'pong',
        );
        final posts = approved.requests.where((r) => r.method == 'POST');
        expect(posts, hasLength(4));
        expect(posts.every((r) => r.auth && r.custom), isTrue);
        expect(posts.map((r) => r.path).toSet(), {
          relative.startsWith('/')
              ? '/message?session=one'
              : '/configured/message?session=one',
        });
        expect(approved.messages.map((m) => m['method']), [
          'initialize',
          'notifications/initialized',
          'tools/list',
          'tools/call',
        ]);
      },
    );
  }

  test(
    'absolute same-origin HTTPS endpoint keeps authenticated MCP working',
    () async {
      await useTls();
      final server = await configured();
      expect(await McpService.I.connect(server), contains('connected (sse)'));
      expect(
        await McpService.I.callTool(server.canonicalId, 'ping', {}),
        'pong',
      );
      expect(approved.requests.every((r) => r.auth && r.custom), isTrue);
    },
  );

  for (final kind in [
    'absolute cross-origin',
    'network-path cross-origin',
    'userinfo',
    'empty userinfo',
    'non-HTTP',
    'malformed',
    'fragment',
    'empty',
  ]) {
    test('refuses $kind endpoint before credential transport', () async {
      approved.endpoint = switch (kind) {
        'absolute cross-origin' =>
          unapproved.base.resolve('/message').toString(),
        'network-path cross-origin' =>
          '//127.0.0.1:${unapproved.server.port}/message',
        'userinfo' =>
          approved.base
              .replace(
                userInfo: 'fixture-only-user:fixture-only-password',
                path: '/message',
              )
              .toString(),
        'empty userinfo' => 'http://@127.0.0.1:${approved.server.port}/message',
        'non-HTTP' => 'file:///message',
        'malformed' => 'http://[invalid',
        'empty' => '',
        _ => '${approved.base}/message#fixture-only-fragment',
      };
      await expectRefused(await configured());
      expect(approved.requests.where((r) => r.method == 'POST'), isEmpty);
    });
  }

  test('refuses HTTPS endpoint downgrade before sending credentials', () async {
    await useTls();
    approved.endpoint = unapproved.base.resolve('/message').toString();
    await expectRefused(await configured());
  });

  for (final status in [301, 302, 303, 307, 308]) {
    test(
      'refuses cross-origin GET redirect $status before transport',
      () async {
        approved.redirects['/configured/sse'] = (
          status: status,
          location: unapproved.base.resolve('/sse').toString(),
        );
        await expectRefused(await configured());
      },
    );
  }

  for (final status in [303, 307, 308]) {
    test(
      'refuses cross-origin POST redirect $status before transport',
      () async {
        approved.redirects['/message'] = (
          status: status,
          location: unapproved.base.resolve('/message').toString(),
        );
        await expectRefused(await configured());
      },
    );
  }

  test(
    'rechecks every GET hop and resolves endpoint against configured URL',
    () async {
      approved.redirects['/configured/sse'] = (
        status: 302,
        location: '/moved/sse',
      );
      approved.endpoint = 'message';
      final server = await configured();
      expect(await McpService.I.connect(server), contains('connected (sse)'));
      expect(
        approved.requests
            .where((r) => r.method == 'POST')
            .map((r) => r.path)
            .toSet(),
        {'/configured/message'},
      );
      expect(approved.requests.every((r) => r.auth && r.custom), isTrue);
    },
  );

  test('rejects cross-origin second GET hop', () async {
    approved.redirects['/configured/sse'] = (status: 302, location: '/next');
    approved.redirects['/next'] = (
      status: 307,
      location: '${unapproved.base}/sse',
    );
    await expectRefused(await configured());
  });

  for (final status in [307, 308]) {
    test(
      'same-origin POST $status preserves JSON-RPC body and credentials',
      () async {
        approved.redirects['/message'] = (
          status: status,
          location: '/accepted',
        );
        final server = await configured();
        expect(await McpService.I.connect(server), contains('connected (sse)'));
        expect(
          await McpService.I.callTool(server.canonicalId, 'ping', {}),
          'pong',
        );
        expect(approved.messages.map((m) => m['method']), [
          'initialize',
          'notifications/initialized',
          'tools/list',
          'tools/call',
        ]);
        expect(approved.requests.every((r) => r.auth && r.custom), isTrue);
      },
    );
  }

  test('HTTPS stream redirect cannot downgrade', () async {
    await useTls();
    approved.redirects['/configured/sse'] = (
      status: 302,
      location: '${unapproved.base}/sse',
    );
    await expectRefused(await configured());
  });

  test('HTTPS POST redirect cannot downgrade', () async {
    await useTls();
    approved.redirects['/message'] = (
      status: 303,
      location: '${unapproved.base}/message',
    );
    await expectRefused(await configured());
  });

  test('invalid configured URL is refused before its first request', () async {
    final url = approved.base.replace(
      userInfo: 'fixture-only-user',
      path: '/sse',
    );
    await expectRefused(await configured(url: url));
    expect(approved.requests, isEmpty);
  });

  test('malformed configured URL error does not expose URL material', () async {
    final server = await configured();
    server.url = 'https://[fixture-only-private-material';
    await expectRefused(server);
    expect(approved.requests, isEmpty);
  });

  for (final kind in [
    'userinfo',
    'empty userinfo',
    'non-HTTP',
    'malformed',
    'different host',
  ]) {
    test('rejects $kind redirect before a second request', () async {
      approved.redirects['/configured/sse'] = (
        status: 302,
        location: switch (kind) {
          'userinfo' =>
            approved.base
                .replace(userInfo: 'fixture-only-user', path: '/sse')
                .toString(),
          'empty userinfo' => 'http://@127.0.0.1:${approved.server.port}/sse',
          'non-HTTP' => 'file:///sse',
          'malformed' => 'http://[fixture-only-private-material',
          _ =>
            approved.base.replace(host: 'localhost', path: '/sse').toString(),
        },
      );
      await expectRefused(await configured());
      expect(approved.requests, hasLength(1));
    });
  }

  test('redirect loop terminates with a truthful bounded refusal', () async {
    approved.redirects['/configured/sse'] = (
      status: 302,
      location: '/configured/sse',
    );
    await expectRefused(await configured());
    expect(approved.requests.length, lessThanOrEqualTo(6));
  });

  test('rechecks POST redirect after an approved hop', () async {
    approved.redirects['/message'] = (status: 307, location: '/next');
    approved.redirects['/next'] = (
      status: 308,
      location: '${unapproved.base}/message',
    );
    await expectRefused(await configured());
    expect(
      approved.requests.where((r) => r.path == '/next').single.method,
      'POST',
    );
  });

  test('same-origin POST 303 acknowledgment preserves SSE responses', () async {
    // The endpoint accepts the RPC, responds over SSE, and uses 303 for an
    // acknowledgment resource. This was supported by IOClient before W08.02.
    approved.acknowledgments.add('/message');
    final server = await configured();
    approved.redirects['/ack'] = (status: 302, location: '/ack-final');
    expect(await McpService.I.connect(server), contains('connected (sse)'));
    expect(await McpService.I.callTool(server.canonicalId, 'ping', {}), 'pong');
    final acks = approved.requests.where((r) => r.path == '/ack-final');
    expect(acks, hasLength(4));
    expect(acks.every((r) => r.method == 'GET' && r.auth && r.custom), isTrue);
  });

  test('endpoint updates during handshake cannot switch origin', () async {
    approved.responsePrefix =
        'event: endpoint\ndata: ${unapproved.base}/message\n\n';
    await expectRefused(await configured());
    expect(approved.requests.where((r) => r.method == 'POST'), hasLength(1));
  });

  test('later valid event cannot reopen a refused channel', () async {
    approved.endpoint =
        '${unapproved.base}/message\n\n'
        'event: endpoint\ndata: ${approved.base}/message';
    await expectRefused(await configured());
    expect(approved.requests.where((r) => r.method == 'POST'), isEmpty);
  });

  test(
    'refusal preserves shared client and allows explicit corrected retry',
    () async {
      await useTls();
      final server = await configured();
      approved.endpoint = '${unapproved.base}/message';
      await expectRefused(server);
      // Same real injected client remains usable; a new channel owns the retry.
      approved.endpoint = '/message';
      expect(await McpService.I.connect(server), contains('connected (sse)'));
      expect(
        await McpService.I.callTool(server.canonicalId, 'ping', {}),
        'pong',
      );
      expect(unapproved.requests, isEmpty);
    },
  );

  group('round1 policy refusal', () {
    late _ObservedClient client;

    setUp(() {
      client = _ObservedClient();
      McpService.I.httpClientForTest = client;
      addTearDown(client.close);
    });

    Future<void> rejectEndpoint() async {
      await approved.emit(
        'event: endpoint\n'
        'data: ${unapproved.base}/message?fixture-only-private-query',
      );
      await client.streamCancelled.future.timeout(const Duration(seconds: 2));
    }

    void expectPolicyError(String result) {
      expect(result, startsWith('MCP error:'));
      expect(result, contains('SSE destination rejected'));
      expect(result, isNot(contains('fixture-only')));
      expect(result, isNot(contains('pong')));
      expect(unapproved.requests, isEmpty);
    }

    test(
      'post-handshake refusal immediately removes advertised connection',
      () async {
        final server = await configured();
        expect(await McpService.I.connect(server), contains('connected (sse)'));
        expect(McpService.I.connectedTools[server.canonicalId], hasLength(1));

        await rejectEndpoint();

        expect(McpService.I.isConnected(server.canonicalId), isFalse);
        expect(
          McpService.I.connectedTools,
          isNot(contains(server.canonicalId)),
        );
        expect(
          McpService.I.connectedToolEntries.where(
            (e) => e.server.canonicalId == server.canonicalId,
          ),
          isEmpty,
        );
        expectPolicyError(
          await McpService.I.callTool(server.canonicalId, 'ping', {}),
        );
        expect(
          approved.messages.where((m) => m['method'] == 'tools/call'),
          isEmpty,
        );
      },
    );

    test(
      'post-handshake subsequent calls retain sanitized policy error',
      () async {
        final server = await configured();
        expect(await McpService.I.connect(server), contains('connected (sse)'));
        await rejectEndpoint();

        for (var i = 0; i < 2; i++) {
          expectPolicyError(
            await McpService.I.callTool(server.canonicalId, 'ping', {}),
          );
        }
        expect(McpService.I.isConnected(server.canonicalId), isFalse);
        expect(
          approved.messages.where((m) => m['method'] == 'tools/call'),
          isEmpty,
        );
      },
    );

    for (final queuedResponse in [false, true]) {
      test(
        'post-ack refusal overrides ${queuedResponse ? 'queued response' : 'response wait'}',
        () async {
          final server = await configured();
          expect(
            await McpService.I.connect(server),
            contains('connected (sse)'),
          );
          approved.deferToolResponses = true;
          final call = McpService.I.callTool(
            server.canonicalId,
            'ping',
            {},
            timeout: const Duration(seconds: 3),
          );
          await client.toolAcknowledged.future.timeout(
            const Duration(seconds: 2),
          );
          if (queuedResponse) {
            // One SSE write queues a success then refuses the destination before
            // the waiting RPC resumes. Refusal must take precedence over the queue.
            final id = approved.messages.last['id'];
            await approved.emit(
              'data: ${jsonEncode({
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'content': [
                    {'type': 'text', 'text': 'pong'},
                  ],
                },
              })}\n\nevent: endpoint\n'
              'data: ${unapproved.base}/message?fixture-only-private-query',
            );
          } else {
            await rejectEndpoint();
          }

          expectPolicyError(await call.timeout(const Duration(seconds: 2)));
          expect(McpService.I.isConnected(server.canonicalId), isFalse);
          expectPolicyError(
            await McpService.I.callTool(server.canonicalId, 'ping', {}),
          );
          expect(
            approved.messages.where((m) => m['method'] == 'tools/call'),
            hasLength(1),
          );
        },
      );
    }

    test('refusal wakes all post-ack callers with the policy reason', () async {
      final server = await configured();
      expect(await McpService.I.connect(server), contains('connected (sse)'));
      approved.deferToolResponses = true;
      final first = McpService.I.callTool(server.canonicalId, 'ping', {});
      await client.toolAcknowledged.future.timeout(const Duration(seconds: 2));
      final second = McpService.I.callTool(server.canonicalId, 'ping', {});
      await client.twoToolsAcknowledged.future.timeout(
        const Duration(seconds: 2),
      );
      await rejectEndpoint();
      for (final result in await Future.wait([
        first,
        second,
      ]).timeout(const Duration(seconds: 2))) {
        expectPolicyError(result);
      }
      expect(McpService.I.isConnected(server.canonicalId), isFalse);
    });

    test(
      'late refused call cannot invalidate a corrected replacement',
      () async {
        final server = await configured();
        expect(await McpService.I.connect(server), contains('connected (sse)'));
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        client.holdToolAcknowledgment = release.future;
        final oldCall = McpService.I.callTool(server.canonicalId, 'ping', {});
        await client.toolAcknowledged.future.timeout(
          const Duration(seconds: 2),
        );
        await rejectEndpoint();
        expect(McpService.I.isConnected(server.canonicalId), isFalse);

        client.holdToolAcknowledgment = null;
        expect(await McpService.I.connect(server), contains('connected (sse)'));
        release.complete();
        expectPolicyError(await oldCall.timeout(const Duration(seconds: 2)));
        expect(McpService.I.isConnected(server.canonicalId), isTrue);
        expect(
          await McpService.I.callTool(server.canonicalId, 'ping', {}),
          'pong',
        );
        expect(McpService.I.connectedTools[server.canonicalId], hasLength(1));
        expect(unapproved.requests, isEmpty);
      },
    );
  });
}
