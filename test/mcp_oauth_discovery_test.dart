import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/mcp_oauth_discovery.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake MCP server + authorization server on one loopback port:
///  * `/mcp` answers 401 + `WWW-Authenticate: Bearer resource_metadata=…`
///    until the request carries the issued token;
///  * RFC 9728 metadata at `/.well-known/oauth-protected-resource/mcp`;
///  * RFC 8414 metadata for issuer `/auth`;
///  * RFC 7591 registration at `/auth/register`;
///  * a token endpoint that verifies PKCE and the `resource` indicator.
class _FakeAuthServer {
  late HttpServer _server;
  String get origin => 'http://127.0.0.1:${_server.port}';
  String get mcpUrl => '$origin/mcp';
  final registrations = <Map<String, dynamic>>[];
  final tokenRequests = <Map<String, String>>[];
  final metadataHits = <String>[];
  String? expectedChallenge;
  bool withProtectedResourceMetadata = true;
  static const issuedToken = 'issued-access-token';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _json(HttpRequest r, Object body, {int status = 200}) async {
    r.response.statusCode = status;
    r.response.headers.contentType = ContentType.json;
    r.response.write(jsonEncode(body));
    await r.response.close();
  }

  Future<void> _handle(HttpRequest r) async {
    final path = r.uri.path;
    final body = await utf8.decoder.bind(r).join();
    if (path.startsWith('/.well-known/')) metadataHits.add(path);
    switch (path) {
      case '/mcp':
        if (r.headers.value('authorization') != 'Bearer $issuedToken') {
          r.response.statusCode = 401;
          r.response.headers.set(
            'www-authenticate',
            withProtectedResourceMetadata
                ? 'Bearer realm="mcp", resource_metadata='
                      '"$origin/.well-known/oauth-protected-resource/mcp", '
                      'scope="read write"'
                : 'Bearer realm="mcp"',
          );
          await r.response.close();
          return;
        }
        final message = jsonDecode(body) as Map;
        if (!message.containsKey('id')) {
          r.response.statusCode = 202;
          await r.response.close();
          return;
        }
        await _json(r, {
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': message['method'] == 'initialize'
              ? {
                  'protocolVersion': '2024-11-05',
                  'capabilities': {'tools': {}},
                }
              : {'tools': []},
        });
        return;
      case '/.well-known/oauth-protected-resource/mcp':
        if (!withProtectedResourceMetadata) break;
        await _json(r, {
          'resource': mcpUrl,
          'authorization_servers': ['$origin/auth'],
          'scopes_supported': ['ignored-when-challenge-has-scope'],
        });
        return;
      case '/.well-known/oauth-authorization-server/auth':
        await _json(r, {
          'issuer': '$origin/auth',
          'authorization_endpoint': '$origin/auth/authorize',
          'token_endpoint': '$origin/auth/token',
          'registration_endpoint': '$origin/auth/register',
          'code_challenge_methods_supported': ['S256'],
        });
        return;
      case '/.well-known/oauth-authorization-server':
        if (withProtectedResourceMetadata) break;
        await _json(r, {
          'issuer': origin,
          'authorization_endpoint': '$origin/legacy/authorize',
          'token_endpoint': '$origin/auth/token',
          'registration_endpoint': '$origin/auth/register',
        });
        return;
      case '/auth/register':
        final reg = (jsonDecode(body) as Map).cast<String, dynamic>();
        registrations.add(reg);
        await _json(r, {
          'client_id': 'dyn-client-${registrations.length}',
          'redirect_uris': reg['redirect_uris'],
        }, status: 201);
        return;
      case '/auth/token':
        final fields = Uri.splitQueryString(body);
        tokenRequests.add(fields);
        final verifier = fields['code_verifier'] ?? '';
        final challenge = base64Url
            .encode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', '');
        if (fields['code'] != 'good-code' ||
            challenge != expectedChallenge ||
            fields['resource'] != mcpUrl) {
          await _json(r, {'error': 'invalid_grant'}, status: 400);
          return;
        }
        await _json(r, {
          'access_token': issuedToken,
          'token_type': 'Bearer',
          'expires_in': 3600,
          'refresh_token': 'refresh-1',
        });
        return;
    }
    r.response.statusCode = 404;
    await r.response.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);
  final svc = McpService.I;
  late _FakeAuthServer auth;
  late McpServer server;
  var serial = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
    auth = _FakeAuthServer();
    await auth.start();
    server = McpServer(
      name: 'remote-${serial++}',
      author: 'fixture',
      description: '',
      category: 'Custom',
      command: '',
      transport: 'http',
      url: auth.mcpUrl,
    );
    AppState.I.mcpServers.add(server);
  });

  tearDown(() async {
    await svc.removeMcpOAuth(server.canonicalId);
    await auth.close();
    AppState.resetTestInstance();
  });

  String callbackFor(
    McpOAuthAuthorization attempt, {
    String code = 'good-code',
  }) {
    final state = Uri.parse(attempt.authorizationUrl).queryParameters['state'];
    return '${McpService.mcpOAuthRedirectUri}?code=$code&state=$state';
  }

  void rememberChallenge(McpOAuthAuthorization attempt) {
    auth.expectedChallenge = Uri.parse(
      attempt.authorizationUrl,
    ).queryParameters['code_challenge'];
  }

  test('Bearer challenge parsing reads resource_metadata, scope and error', () {
    final c = McpBearerChallenge.parse(
      'Basic realm="x", Bearer error="invalid_token", '
      'resource_metadata="https://a.test/.well-known/oauth-protected-resource",'
      ' scope="files:read files:write"',
    )!;
    expect(c.error, 'invalid_token');
    expect(
      c.resourceMetadata,
      'https://a.test/.well-known/oauth-protected-resource',
    );
    expect(c.scope, 'files:read files:write');
    expect(McpBearerChallenge.parse('Basic realm="x"'), isNull);
  });

  test('401 + WWW-Authenticate → discovery, DCR, PKCE, callback after '
      'process death, then a ready reconnect', () async {
    final key = server.canonicalId;
    final first = await svc.connectOutcome(
      server,
      handshakeBudget: const Duration(seconds: 3),
    );
    expect(first.isReady, isFalse);
    expect(first.kind, McpConnectOutcomeKind.needsSetup);
    expect(svc.mcpNeedsOAuthSignIn(key), isTrue);

    final attempt = await svc.beginMcpOAuthAuthorization(key);
    rememberChallenge(attempt);
    final authorize = Uri.parse(attempt.authorizationUrl);
    expect(authorize.path, '/auth/authorize');
    expect(authorize.queryParameters['client_id'], 'dyn-client-1');
    expect(authorize.queryParameters['resource'], auth.mcpUrl);
    expect(authorize.queryParameters['scope'], 'read write');
    expect(authorize.queryParameters['code_challenge_method'], 'S256');
    expect(
      authorize.queryParameters['redirect_uri'],
      McpService.mcpOAuthRedirectUri,
    );
    expect(auth.registrations.single['redirect_uris'], [
      McpService.mcpOAuthRedirectUri,
    ]);
    expect(auth.registrations.single['token_endpoint_auth_method'], 'none');

    // Android kills the app while the browser is in front.
    svc.forgetOAuthMemoryForTest();

    final callback = Uri.parse(callbackFor(attempt));
    expect(McpService.isMcpOAuthCallback(callback), isTrue);
    expect(await svc.mcpOAuthServerForCallback(callback), key);
    final token = await svc.completeMcpOAuthAuthorization(
      key,
      callback.toString(),
    );
    expect(token.accessToken, _FakeAuthServer.issuedToken);
    expect(auth.tokenRequests.single['client_id'], 'dyn-client-1');
    expect(svc.mcpNeedsOAuthSignIn(key), isFalse);
    // The attempt was one-use and its persisted copy is gone.
    expect(await svc.mcpOAuthServerForCallback(callback), isNull);

    final second = await svc.connectOutcome(
      server,
      handshakeBudget: const Duration(seconds: 3),
    );
    expect(second.isReady, isTrue, reason: second.reason);
    await svc.disconnect(key);

    // The registered client is reused by the next sign-in.
    await svc.beginMcpOAuthAuthorization(key);
    expect(auth.registrations, hasLength(1));
  });

  test(
    'a bad paste keeps the attempt; the real callback still works',
    () async {
      final key = server.canonicalId;
      svc.recordOAuthChallengeForTest(key, '');
      final attempt = await svc.beginMcpOAuthAuthorization(key);
      rememberChallenge(attempt);
      await expectLater(
        svc.completeMcpOAuthAuthorization(key, attempt.authorizationUrl),
        throwsA(
          isA<McpOAuthException>().having(
            (e) => e.kind,
            'kind',
            McpOAuthErrorKind.redirectMismatch,
          ),
        ),
      );
      final token = await svc.completeMcpOAuthAuthorization(
        key,
        callbackFor(attempt),
      );
      expect(token.accessToken, _FakeAuthServer.issuedToken);
    },
  );

  test('error=access_denied is typed and consumes the attempt', () async {
    final key = server.canonicalId;
    final attempt = await svc.beginMcpOAuthAuthorization(key);
    final state = Uri.parse(attempt.authorizationUrl).queryParameters['state'];
    final denied =
        '${McpService.mcpOAuthRedirectUri}?error=access_denied&state=$state';
    await expectLater(
      svc.completeMcpOAuthAuthorization(key, denied),
      throwsA(
        isA<McpOAuthException>().having(
          (e) => e.kind,
          'kind',
          McpOAuthErrorKind.denied,
        ),
      ),
    );
    await expectLater(
      svc.completeMcpOAuthAuthorization(key, callbackFor(attempt)),
      throwsA(
        isA<McpOAuthException>().having(
          (e) => e.kind,
          'kind',
          McpOAuthErrorKind.expired,
        ),
      ),
    );
    expect(auth.tokenRequests, isEmpty);
  });

  test('servers without resource metadata fall back to the MCP origin '
      '(2025-03-26)', () async {
    auth.withProtectedResourceMetadata = false;
    final key = server.canonicalId;
    final attempt = await svc.beginMcpOAuthAuthorization(key);
    final authorize = Uri.parse(attempt.authorizationUrl);
    expect(authorize.path, '/legacy/authorize');
    expect(authorize.queryParameters['resource'], auth.mcpUrl);
    expect(
      auth.metadataHits,
      containsAllInOrder([
        '/.well-known/oauth-protected-resource/mcp',
        '/.well-known/oauth-protected-resource',
        '/.well-known/oauth-authorization-server',
      ]),
    );
  });
}
