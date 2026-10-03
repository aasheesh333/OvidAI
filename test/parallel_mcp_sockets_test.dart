import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Wrap only observation around real socket I/O. Cancellation must come from
// the service; the fixture deliberately leaves initialize unanswered.
class _ObservedClient extends http.BaseClient {
  final inner = IOClient();
  final cancelled = Completer<void>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    if (request.method != 'GET') return response;
    late StreamSubscription<List<int>> subscription;
    late StreamController<List<int>> stream;
    stream = StreamController<List<int>>(
      onListen: () {
        subscription = response.stream.listen(stream.add,
            onError: stream.addError, onDone: stream.close);
      },
      onCancel: () {
        if (!cancelled.isCompleted) cancelled.complete();
        return subscription.cancel();
      },
    );
    return http.StreamedResponse(stream.stream, response.statusCode,
        headers: response.headers);
  }
  @override
  void close() => inner.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);
  for (final abort in ['timeout', 'disconnect']) {
    test('$abort cancels real SSE stream during initialize', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      AppState.createForTest();
      final fixture = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = _ObservedClient();
      final initialized = Completer<void>();
      fixture.listen((request) async {
        if (request.method == 'GET') {
          request.response.headers.contentType = ContentType('text', 'event-stream');
          request.response.bufferOutput = false;
          request.response.write('event: endpoint\ndata: /message\n\n');
          await request.response.flush();
        } else {
          final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          if (body['method'] == 'initialize') initialized.complete();
          request.response.statusCode = 202;
          await request.response.close();
        }
      });
      final server = McpServer(name: 'parallel-sse-$abort', author: 'test',
          description: '', category: 'Custom', command: '', transport: 'sse',
          url: 'http://127.0.0.1:${fixture.port}/sse');
      final svc = McpService.I;
      svc.httpClientForTest = client;
      addTearDown(() async {
        await svc.disconnect(server.canonicalId);
        svc.httpClientForTest = null;
        client.close();
        await fixture.close(force: true);
        AppState.resetTestInstance();
      });
      final connecting = svc.connectOutcome(server,
          handshakeBudget: const Duration(seconds: 2));
      await initialized.future.timeout(const Duration(seconds: 3));
      if (abort == 'disconnect') await svc.disconnect(server.canonicalId);
      final outcome = await connecting;
      expect(outcome.isReady, isFalse);
      await client.cancelled.future.timeout(const Duration(milliseconds: 300));
      expect(svc.isConnected(server.canonicalId), isFalse);
      expect(svc.hasPendingReconnectForTest(server.canonicalId), isFalse);
    });
  }
}
