import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// The platform seam models a secure-store write already in progress on device.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/mcp_config_parse.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DelayedStore extends FlutterSecureStoragePlatform {
  final values = <String, String>{};
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async {
    if (key.startsWith('ovid_mcp_oauth_') && !key.startsWith('ovid_mcp_oauth_cfg_')) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    values[key] = value;
  }
  @override
  Future<String?> read({required String key, required Map<String, String> options}) async => values[key];
  @override
  Future<void> delete({required String key, required Map<String, String> options}) async { values.remove(key); }
  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async => values.containsKey(key);
  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async => Map.of(values);
  @override
  Future<void> deleteAll({required Map<String, String> options}) async => values.clear();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);
  final svc = McpService.I;
  var serial = 0;
  late String key;
  late HttpServer endpoint;
  late McpOAuthConfig config;
  late Completer<void> entered;
  late Completer<void> release;
  late List<Map<String, String>> requests;
  late Map<String, dynamic> tokenResponse;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
    key = 'wave2-oauth-${serial++}';
    requests = [];
    tokenResponse = {'access_token': 'fresh', 'expires_in': 3600};
    entered = Completer<void>();
    release = Completer<void>();
    endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint.listen((request) async {
      requests.add(Uri.splitQueryString(await utf8.decoder.bind(request).join()));
      if (!entered.isCompleted) entered.complete();
      await release.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(tokenResponse));
      await request.response.close();
    });
    config = McpOAuthConfig(
      authorizationUrl: 'http://127.0.0.1:${endpoint.port}/authorize',
      tokenUrl: 'http://127.0.0.1:${endpoint.port}/token',
      clientId: 'fixture', redirectUri: 'ovid://oauth/callback?provider=mcp',
    );
    await svc.setMcpOAuthConfig(key, config);
    await svc.storeMcpOAuthToken(key, const McpOAuthToken(
      accessToken: 'old', refreshToken: 'refresh',
    ));
  });
  tearDown(() async {
    if (!release.isCompleted) release.complete();
    await svc.clearMcpOAuthToken(key);
    await endpoint.close(force: true);
    AppState.resetTestInstance();
  });

  test('concurrent refresh callers share a single token request', () async {
    final a = svc.refreshMcpOAuthToken(key);
    await entered.future;
    final b = svc.refreshMcpOAuthToken(key);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    release.complete();
    expect((await a)?.accessToken, 'fresh');
    expect((await b)?.accessToken, 'fresh');
    expect(requests, hasLength(1));
    expect((await svc.mcpOAuthTokenFor(key))?.refreshToken, 'refresh');
  });

  test('clear during refresh cannot resurrect a token in memory or storage', () async {
    final refreshing = svc.refreshMcpOAuthToken(key);
    await entered.future;
    await svc.clearMcpOAuthToken(key);
    release.complete();
    expect(await refreshing, isNull);
    expect(await svc.mcpOAuthTokenFor(key), isNull);
    expect(await const FlutterSecureStorage().read(key: 'ovid_mcp_oauth_$key'), isNull);
  });

  test('replacement token wins over an older in-flight refresh', () async {
    final refreshing = svc.refreshMcpOAuthToken(key);
    await entered.future;
    await svc.storeMcpOAuthToken(key, const McpOAuthToken(accessToken: 'replacement'));
    release.complete();
    expect(await refreshing, isNull);
    expect((await svc.mcpOAuthTokenFor(key))?.accessToken, 'replacement');
  });

  test('OAuth import rejects conflicting authorize aliases atomically', () {
    expect(parseMcpConfig(jsonEncode({'mcpServers': {'fixture': {
      'url': 'https://example.test/mcp', 'oauth': {
        'authorization_url': 'https://one.test/auth',
        'authorize_url': 'https://two.test/auth', 'client_id': 'fixture',
      },
    }}})), isEmpty);
  });

  test('authorization binds state PKCE redirect and consumes callback once', () async {
    final attempt = await svc.beginMcpOAuthAuthorization(key);
    final url = Uri.parse(attempt.authorizationUrl);
    expect(url.queryParameters['state']!.length, greaterThanOrEqualTo(43));
    expect(url.queryParameters['code_challenge_method'], 'S256');
    final callback = 'ovid://oauth/callback?provider=mcp&code=fixture-code&state=${url.queryParameters['state']}';
    release.complete();
    final token = await svc.completeMcpOAuthAuthorization(key, callback);
    expect(token.accessToken, 'fresh');
    final verifier = requests.single['code_verifier']!;
    expect(verifier.length, inInclusiveRange(43, 128));
    expect(base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', ''),
        url.queryParameters['code_challenge']);
    expect(requests.single['redirect_uri'], 'ovid://oauth/callback?provider=mcp');
    expect((await svc.mcpOAuthTokenFor(key))?.accessToken, 'fresh');
    await expectLater(svc.completeMcpOAuthAuthorization(key, callback), throwsStateError);
    expect(requests, hasLength(1));
  });

  for (final invalid in ['state', 'path', 'host', 'query', 'duplicate', 'fragment', 'extra', 'username']) {
    test('rejects $invalid callback before token endpoint', () async {
      final attempt = await svc.beginMcpOAuthAuthorization(key);
      final state = Uri.parse(attempt.authorizationUrl).queryParameters['state'];
      final callback = switch (invalid) {
        'state' => 'ovid://oauth/callback?provider=mcp&code=c&state=wrong',
        'path' => 'ovid://oauth/other?provider=mcp&code=c&state=$state',
        'host' => 'ovid://other/callback?provider=mcp&code=c&state=$state',
        'query' => 'ovid://oauth/callback?provider=other&code=c&state=$state',
        'duplicate' => 'ovid://oauth/callback?provider=mcp&code=c&state=$state&state=$state',
        'extra' => 'ovid://oauth/callback?provider=mcp&code=c&state=$state&other=1',
        'username' => 'ovid://user@oauth/callback?provider=mcp&code=c&state=$state',
        _ => 'ovid://oauth/callback?provider=mcp&code=c&state=$state#bad',
      };
      await expectLater(svc.completeMcpOAuthAuthorization(key, callback), throwsStateError);
      expect(requests, isEmpty);
    });
  }

  test('removal during code exchange prevents token and config resurrection', () async {
    final attempt = await svc.beginMcpOAuthAuthorization(key);
    final state = Uri.parse(attempt.authorizationUrl).queryParameters['state'];
    final exchanging = svc.completeMcpOAuthAuthorization(key,
        'ovid://oauth/callback?provider=mcp&code=c&state=$state');
    final rejected = expectLater(exchanging, throwsStateError);
    await entered.future;
    await svc.removeMcpOAuth(key);
    release.complete();
    await rejected;
    expect(await svc.mcpOAuthTokenFor(key), isNull);
    expect(await svc.mcpOAuthConfigForAsync(key), isNull);
  });

  test('remove then re-add same identity fences old refresh', () async {
    final refreshing = svc.refreshMcpOAuthToken(key);
    await entered.future;
    await svc.removeMcpOAuth(key);
    await svc.setMcpOAuthConfig(key, config);
    await svc.storeMcpOAuthToken(key, const McpOAuthToken(accessToken: 'new-owner'));
    release.complete();
    expect(await refreshing, isNull);
    expect((await svc.mcpOAuthTokenFor(key))?.accessToken, 'new-owner');
  });

  test('disconnect during refresh fences completion without erasing durable token', () async {
    final refreshing = svc.refreshMcpOAuthToken(key);
    await entered.future;
    await svc.disconnect(key);
    release.complete();
    expect(await refreshing, isNull);
    expect((await svc.mcpOAuthTokenFor(key))?.accessToken, 'old');
  });

  test('config replacement during refresh fences older token response', () async {
    final refreshing = svc.refreshMcpOAuthToken(key);
    await entered.future;
    await svc.setMcpOAuthConfig(key, config);
    release.complete();
    expect(await refreshing, isNull);
    expect((await svc.mcpOAuthTokenFor(key))?.accessToken, 'old');
  });

  for (final invalid in [
    {'access_token': 42},
    {'access_token': 'fresh', 'token_type': 'Bearer\r\nInjected: bad'},
    {'access_token': 'fresh', 'expires_in': '3600'},
    {'access_token': 'fresh', 'refresh_token': 42},
  ]) {
    test('rejects malformed token response $invalid', () async {
      tokenResponse = invalid;
      release.complete();
      expect(await svc.refreshMcpOAuthToken(key), isNull);
      expect((await svc.mcpOAuthTokenFor(key))?.accessToken, 'old');
    });
  }

  test('expired token refreshes before protected HTTP handshake', () async {
    await svc.storeMcpOAuthToken(key, McpOAuthToken(accessToken: 'expired',
        refreshToken: 'refresh', expiresAt: DateTime(2000)));
    final mcp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seenAuth = <String?>[];
    mcp.listen((request) async {
      seenAuth.add(request.headers.value('authorization'));
      if (seenAuth.last != 'Bearer fresh') {
        request.response.statusCode = 401;
      } else {
        final message = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        request.response.headers.contentType = ContentType.json;
        if (message.containsKey('id')) {
          request.response.write(jsonEncode({
          'jsonrpc': '2.0', 'id': message['id'], 'result': message['method'] == 'initialize'
            ? {'protocolVersion': '2024-11-05', 'capabilities': {'tools': {}}}
            : {'tools': []},
          }));
        }
      }
      await request.response.close();
    });
    addTearDown(() async {
      await svc.disconnect(key);
      await mcp.close(force: true);
    });
    release.complete();
    final server = McpServer(name: key, author: 'fixture', description: '', category: 'Custom',
        command: '', transport: 'http', url: 'http://127.0.0.1:${mcp.port}/mcp');
    final outcome = await svc.connectOutcome(server, handshakeBudget: const Duration(seconds: 3));
    expect(outcome.isReady, isTrue, reason: outcome.reason);
    expect(seenAuth, everyElement('Bearer fresh'));
    expect(requests, hasLength(1));
  });

  test('expired authorization attempt never calls token endpoint', () async {
    final attempt = await svc.beginMcpOAuthAuthorization(key);
    McpService.clockForTest = () => attempt.expiresAt;
    addTearDown(() => McpService.clockForTest = DateTime.now);
    final state = Uri.parse(attempt.authorizationUrl).queryParameters['state'];
    await expectLater(svc.completeMcpOAuthAuthorization(key,
        'ovid://oauth/callback?provider=mcp&code=c&state=$state'), throwsStateError);
    expect(requests, isEmpty);
  });

  test('remove orders durable delete after a platform token write already started', () async {
    final original = FlutterSecureStoragePlatform.instance;
    final store = DelayedStore();
    FlutterSecureStoragePlatform.instance = store;
    try {
      release.complete();
      final refresh = svc.refreshMcpOAuthToken(key);
      await store.entered.future;
      final removing = svc.removeMcpOAuth(key);
      store.release.complete();
      await removing;
      expect(await refresh, isNull);
      expect(store.values, isEmpty);
      expect(await svc.mcpOAuthTokenFor(key), isNull);
      expect(await svc.mcpOAuthConfigForAsync(key), isNull);
    } finally {
      if (!store.release.isCompleted) store.release.complete();
      FlutterSecureStoragePlatform.instance = original;
    }
  });

  test('begin authorization does not cancel queued config persistence', () async {
    final freshKey = '$key-import';
    final storing = svc.setMcpOAuthConfig(freshKey, config);
    await svc.beginMcpOAuthAuthorization(freshKey);
    await storing;
    final raw = await const FlutterSecureStorage().read(key: 'ovid_mcp_oauth_cfg_$freshKey');
    expect(raw, isNotNull);
    expect(jsonDecode(raw!)['client_id'], 'fixture');
    await svc.removeMcpOAuth(freshKey);
  });

  test('token endpoint never follows a redirect or sends credentials to its target', () async {
    final destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var forwarded = 0;
    destination.listen((request) async {
      forwarded++;
      await request.response.close();
    });
    addTearDown(() => destination.close(force: true));
    await endpoint.close(force: true);
    endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint.listen((request) async {
      if (!entered.isCompleted) entered.complete();
      request.response.statusCode = HttpStatus.temporaryRedirect;
      request.response.headers.set('location', 'http://127.0.0.1:${destination.port}/stolen');
      await request.response.close();
    });
    await svc.setMcpOAuthConfig(key, McpOAuthConfig(
      authorizationUrl: config.authorizationUrl,
      tokenUrl: 'http://127.0.0.1:${endpoint.port}/token',
      clientId: config.clientId,
      redirectUri: config.redirectUri,
    ));
    expect(await svc.refreshMcpOAuthToken(key), isNull);
    expect(forwarded, 0);
  });
}
