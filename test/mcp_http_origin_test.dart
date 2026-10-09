import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';

McpServer _server(Uri url) => McpServer(
  name: 'streamable-origin',
  author: 'test',
  description: 'streamable HTTP origin policy',
  category: 'Custom',
  command: '',
  custom: true,
  transport: 'http',
  url: url.toString(),
  headers: {'X-Mcp-Key': 'configured-secret'},
  startupTimeoutS: 2,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer approved;
  late HttpServer unapproved;
  late IOClient client;
  HttpOverrides? previousOverrides;
  final servers = <McpServer>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
    McpService.oauthSecureStorageDisabledForTest = true;
    approved = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unapproved = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // TestWidgetsFlutterBinding installs HttpOverrides.global that makes
    // every HttpClient return HTTP 400. These tests must exercise real
    // loopback HTTP, so build the client with the overrides removed.
    previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    client = IOClient(HttpClient());
  });

  tearDown(() async {
    for (final server in servers) {
      await McpService.I.disconnect(server.canonicalId);
      await McpService.I.clearMcpOAuthToken(server.canonicalId);
    }
    servers.clear();
    client.close();
    HttpOverrides.global = previousOverrides;
    McpService.I.httpClientForTest = null;
    McpService.oauthSecureStorageDisabledForTest = false;
    await approved.close(force: true);
    await unapproved.close(force: true);
    AppState.resetTestInstance();
  });

  test('keeps credentials and session on normal same-origin requests', () async {
    final received = <HttpRequest>[];
    approved.listen((request) async {
      received.add(request);
      final body = await utf8.decoder.bind(request).join();
      if (request.method != 'POST') {
        // Teardown sends a body-less DELETE to end the session.
        await request.response.close();
        return;
      }
      final method = jsonDecode(body)['method'];
      if (method == 'initialize') {
        request.response.headers.set('Mcp-Session-Id', 'same-origin-session');
      }
      if (method == 'notifications/initialized') {
        request.response.statusCode = HttpStatus.accepted;
      } else {
        final result = method == 'tools/list' ? {'tools': []} : {};
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'jsonrpc': '2.0',
          'id': jsonDecode(body)['id'],
          'result': result,
        }));
      }
      await request.response.close();
    });

    final server = _server(
      Uri.parse('http://127.0.0.1:${approved.port}/mcp'),
    );
    servers.add(server);
    await McpService.I.storeMcpOAuthToken(
      server.canonicalId,
      const McpOAuthToken(accessToken: 'same-origin-token'),
    );
    McpService.I.httpClientForTest = client;

    expect(await McpService.I.connect(server), contains('connected (http)'));
    expect(received, hasLength(3));
    expect(
      received.every(
        (request) =>
            request.headers.value(HttpHeaders.authorizationHeader) ==
                'Bearer same-origin-token' &&
            request.headers.value('x-mcp-key') == 'configured-secret',
      ),
      isTrue,
    );
    expect(
      received.skip(1).every(
        (request) =>
            request.headers.value('mcp-session-id') == 'same-origin-session',
      ),
      isTrue,
    );
  });

  test('does not follow a cross-origin redirect with MCP credentials', () async {
    var redirectRequests = 0;
    var stolenRequests = 0;
    unapproved.listen((request) async {
      stolenRequests++;
      await request.response.close();
    });
    approved.listen((request) async {
      redirectRequests++;
      request.response.statusCode = HttpStatus.temporaryRedirect;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        'http://127.0.0.1:${unapproved.port}/stolen',
      );
      await request.response.close();
    });

    final server = _server(
      Uri.parse('http://127.0.0.1:${approved.port}/mcp'),
    );
    servers.add(server);
    await McpService.I.storeMcpOAuthToken(
      server.canonicalId,
      const McpOAuthToken(accessToken: 'redirect-secret'),
    );
    McpService.I.httpClientForTest = client;

    expect(await McpService.I.connect(server), contains('connect failed'));
    expect(redirectRequests, 1);
    expect(stolenRequests, 0);
  });
}
