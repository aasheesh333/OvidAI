// Streamable-HTTP completeness: protocol-version negotiation, initialize
// result parsing, tools/list pagination, cancellation on timeout, session
// DELETE on disconnect, and richer tool-result content.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';

McpServer _httpServer(String name) => McpServer(
  name: name,
  author: 't',
  description: 'http completeness',
  category: 'Custom',
  command: '',
  custom: true,
  transport: 'http',
  url: 'https://http.test/mcp',
);

Map<String, dynamic> _decode(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

String _result(Object? id, Map<String, dynamic> result) => jsonEncode({
  'jsonrpc': '2.0',
  'id': id,
  'result': result,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.createForTest();
  });

  tearDown(() async {
    for (final s in List<McpServer>.of(AppState.I.mcpServers)) {
      await McpService.I.disconnect(s.canonicalId);
    }
    McpService.I.httpClientForTest = null;
    McpService.rpcTimeoutSecondsForTest = null;
    AppState.resetTestInstance();
  });

  test(
    'sends the negotiated MCP-Protocol-Version after initialize, never on it',
    () async {
      final initHeaders = <String, String>{};
      final postInitHeaders = <String, String>{};
      McpService.I.httpClientForTest = MockClient((request) async {
        final body = _decode(request);
        final method = body['method'] as String;
        if (method == 'initialize') {
          initHeaders.addAll(request.headers);
          return http.Response(
            _result(body['id'], {
              'protocolVersion': '2025-03-26',
              'capabilities': {
                'tools': {'listChanged': true},
              },
            }),
            200,
          );
        }
        if (method == 'tools/list') postInitHeaders.addAll(request.headers);
        return http.Response(
          _result(body['id'], method == 'tools/list' ? {'tools': []} : {}),
          200,
        );
      });
      final server = _httpServer('negotiated-version');

      final status = await McpService.I.connect(server);

      expect(status, contains('connected'));
      expect(
        initHeaders.containsKey('MCP-Protocol-Version'),
        isFalse,
        reason: 'the initialize call must not carry the version header',
      );
      expect(postInitHeaders['MCP-Protocol-Version'], '2025-03-26');
      expect(
        McpService.I.protocolVersionForTest(server.canonicalId),
        '2025-03-26',
      );
      expect(
        McpService.I.capabilitiesForTest(server.canonicalId)['tools'],
        isA<Map>(),
      );
    },
  );

  test('defaults MCP-Protocol-Version to 2024-11-05 when omitted', () async {
    final seen = <String, String>{};
    McpService.I.httpClientForTest = MockClient((request) async {
      final body = _decode(request);
      final method = body['method'] as String;
      if (method == 'tools/list') seen.addAll(request.headers);
      return http.Response(
        _result(body['id'], method == 'tools/list' ? {'tools': []} : {}),
        200,
      );
    });
    final server = _httpServer('default-version');

    await McpService.I.connect(server);

    expect(seen['MCP-Protocol-Version'], '2024-11-05');
    expect(
      McpService.I.protocolVersionForTest(server.canonicalId),
      '2024-11-05',
    );
  });

  test('tools/list follows nextCursor and merges every page', () async {
    final cursors = <Object?>{};
    McpService.I.httpClientForTest = MockClient((request) async {
      final body = _decode(request);
      final method = body['method'] as String;
      if (method != 'tools/list') {
        return http.Response(_result(body['id'], {}), 200);
      }
      final params = (body['params'] as Map?)?.cast<String, dynamic>() ?? {};
      cursors.add(params['cursor']);
      if (params['cursor'] == null) {
        return http.Response(
          _result(body['id'], {
            'tools': [
              {'name': 'page-one'},
            ],
            'nextCursor': 'c1',
          }),
          200,
        );
      }
      return http.Response(
        _result(body['id'], {
          'tools': [
            {'name': 'page-two'},
          ],
        }),
        200,
      );
    });
    final server = _httpServer('paginated');

    final status = await McpService.I.connect(server);

    expect(status, contains('connected'));
    expect(
      McpService.I.connectedTools[server.canonicalId]!.map((t) => t.name),
      ['page-one', 'page-two'],
    );
    expect(cursors, containsAll(<Object?>[null, 'c1']));
  });

  test('tools/list pagination is bounded against an endless cursor', () async {
    var pages = 0;
    McpService.I.httpClientForTest = MockClient((request) async {
      final body = _decode(request);
      final method = body['method'] as String;
      if (method != 'tools/list') {
        return http.Response(_result(body['id'], {}), 200);
      }
      pages++;
      return http.Response(
        _result(body['id'], {
          'tools': [
            {'name': 't$pages'},
          ],
          'nextCursor': 'more',
        }),
        200,
      );
    });
    final server = _httpServer('endless-cursor');

    final status = await McpService.I.connect(server);

    expect(status, contains('connected'));
    expect(pages, greaterThan(1));
    expect(pages, lessThanOrEqualTo(50));
  });

  test('an HTTP tool timeout sends notifications/cancelled for that id', () async {
    final cancelled = Completer<Map<String, dynamic>>();
    int? callId;
    McpService.I.httpClientForTest = MockClient((request) async {
      final body = _decode(request);
      final method = body['method'] as String;
      if (method == 'initialize' || method == 'tools/list') {
        return http.Response(
          _result(body['id'], method == 'tools/list' ? {'tools': []} : {}),
          200,
        );
      }
      if (method == 'notifications/cancelled') {
        if (!cancelled.isCompleted) cancelled.complete(body);
        return http.Response('', 202);
      }
      callId = body['id'] as int?;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      return http.Response(_result(body['id'], {}), 200);
    });
    final server = _httpServer('slow-tool');
    await McpService.I.connect(server);

    final result = await McpService.I.callTool(
      server.canonicalId,
      'slow',
      {},
      timeout: const Duration(milliseconds: 40),
    );

    expect(result, contains('timed out'));
    final note = await cancelled.future.timeout(const Duration(seconds: 2));
    expect(note['method'], 'notifications/cancelled');
    final params = (note['params'] as Map).cast<String, dynamic>();
    expect(params['requestId'], callId);
  });

  test('disconnect DELETEs the endpoint with the remembered session id', () async {
    final deletes = <http.Request>[];
    McpService.I.httpClientForTest = MockClient((request) async {
      if (request.method == 'DELETE') {
        deletes.add(request);
        return http.Response('', 204);
      }
      final body = _decode(request);
      final method = body['method'] as String;
      final responseHeaders = <String, String>{};
      if (method == 'initialize') {
        responseHeaders['Mcp-Session-Id'] = 'sess-abc';
      }
      return http.Response(
        _result(body['id'], method == 'tools/list' ? {'tools': []} : {}),
        200,
        headers: responseHeaders,
      );
    });
    final server = _httpServer('delete-session');
    await McpService.I.connect(server);
    expect(McpService.I.httpSessionIdForTest(server.canonicalId), 'sess-abc');

    await McpService.I.disconnect(server.canonicalId);

    expect(deletes, hasLength(1));
    expect(deletes.single.url, Uri.parse('https://http.test/mcp'));
    expect(deletes.single.headers['Mcp-Session-Id'], 'sess-abc');
  });

  test('callTool surfaces structuredContent, audio, and resource blobs', () async {
    final audio = base64Encode(List<int>.filled(4, 7));
    final blob = base64Encode(List<int>.filled(6, 9));
    final res = await McpService.callToolForTest(
      replies: [
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'result': {
            'content': [
              {'type': 'text', 'text': 'hello'},
              {
                'type': 'audio',
                'data': audio,
                'mimeType': 'audio/wav',
              },
              {
                'type': 'resource',
                'resource': {'blob': blob, 'mimeType': 'application/pdf'},
              },
            ],
            'structuredContent': {'answer': 42},
          },
        }),
      ],
    );

    expect(res, contains('hello'));
    expect(res, contains('audio/wav'));
    expect(res, contains('4 bytes'));
    expect(res, contains('application/pdf'));
    expect(res, contains('6 bytes'));
    expect(res, contains('"answer":42'));
  });

  test('callTool still flags isError with richer content intact', () async {
    final res = await McpService.callToolForTest(
      replies: [
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'result': {
            'isError': true,
            'content': [
              {'type': 'text', 'text': 'boom'},
            ],
            'structuredContent': {'code': 7},
          },
        }),
      ],
    );

    expect(res, contains('MCP error'));
    expect(res, contains('boom'));
    expect(res, contains('"code":7'));
  });
}
