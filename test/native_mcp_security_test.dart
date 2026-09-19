import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/native_mcp.dart';

class _TrackingClient extends http.BaseClient {
  bool closed = false;
  int sends = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sends++;
    return http.StreamedResponse(Stream.value(<int>[0x6f, 0x6b]), 200);
  }

  @override
  void close() {
    closed = true;
  }
}

class _CountingStreamClient extends http.BaseClient {
  _CountingStreamClient({required this.chunkBytes, required this.chunks});

  final int chunkBytes;
  final int chunks;
  int served = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> body() async* {
      for (var i = 0; i < chunks; i++) {
        served++;
        yield List<int>.filled(chunkBytes, 0x41);
      }
    }

    return http.StreamedResponse(body(), 200, headers: {'content-type': 'text/plain'});
  }
}

void main() {
  group('NativeFetchMcpHandler URL policy', () {
    Future<void> expectBlocked(String url) async {
      var requests = 0;
      final client = MockClient((req) async {
        requests++;
        return http.Response('should not be reached', 200);
      });
      final handler = NativeFetchMcpHandler(httpClient: client);
      final res = await handler.callTool('fetch', {'url': url});
      expect(res.isError, isTrue, reason: '$url should be blocked');
      expect(res.error, contains('Blocked URL'), reason: '$url should report a policy error');
      expect(requests, equals(0), reason: '$url must be rejected before any request is sent');
      await handler.dispose();
    }

    test('rejects non-http(s) schemes', () async {
      await expectBlocked('ftp://example.com/file');
      await expectBlocked('file:///etc/passwd');
      await expectBlocked('javascript:alert(1)');
    });

    test('blocks loopback IPv4 literals', () async {
      await expectBlocked('http://127.0.0.1/admin');
      await expectBlocked('http://127.10.20.30/admin');
    });

    test('blocks private IPv4 ranges', () async {
      await expectBlocked('http://10.0.0.1/');
      await expectBlocked('http://172.16.5.5/');
      await expectBlocked('http://172.31.255.254/');
      await expectBlocked('http://192.168.1.1/');
    });

    test('blocks link-local and cloud metadata IPv4', () async {
      await expectBlocked('http://169.254.169.254/latest/meta-data/');
    });

    test('blocks IPv6 loopback and link-local literals', () async {
      await expectBlocked('http://[::1]/');
      await expectBlocked('http://[fe80::1]/');
    });

    test('blocks localhost and .local hostnames', () async {
      await expectBlocked('http://localhost/');
      await expectBlocked('http://service.local/');
    });

    test('allows explicitly overridden hosts for tests', () async {
      final client = MockClient((req) async => http.Response('ok', 200));
      final handler = NativeFetchMcpHandler(
        httpClient: client,
        allowedHosts: {'127.0.0.1'},
      );
      final res = await handler.callTool('fetch', {
        'url': 'http://127.0.0.1:9/ping',
        'raw': true,
      });
      expect(res.isError, isFalse);
      expect((res.value['content'] as List).first['text'], equals('ok'));
      await handler.dispose();
    });
  });

  group('NativeFetchMcpHandler read and redirect limits', () {
    test('caps the streamed read instead of buffering the whole body', () async {
      final client = _CountingStreamClient(chunkBytes: 512 * 1024, chunks: 10);
      final handler = NativeFetchMcpHandler(httpClient: client);
      final res = await handler.callTool('fetch', {
        'url': 'https://example.com/huge',
        'raw': true,
      });
      expect(res.isError, isFalse);
      final text = (res.value['content'] as List).first['text'] as String;
      expect(text.length, lessThanOrEqualTo(2 * 1024 * 1024));
      expect(client.served, lessThan(client.chunks));
      await handler.dispose();
    });

    test('still applies max_length after the byte cap', () async {
      final client = _CountingStreamClient(chunkBytes: 1024, chunks: 8);
      final handler = NativeFetchMcpHandler(httpClient: client);
      final res = await handler.callTool('fetch', {
        'url': 'https://example.com/huge',
        'raw': true,
        'max_length': 40,
      });
      expect(res.isError, isFalse);
      final text = (res.value['content'] as List).first['text'] as String;
      expect(text.length, lessThan(80));
      expect(text, contains('[truncated]'));
      await handler.dispose();
    });

    test('rejects a redirect into a blocked host', () async {
      var requests = 0;
      final client = MockClient((req) async {
        requests++;
        return http.Response('', 302, headers: {'location': 'http://127.0.0.1:8080/secret'});
      });
      final handler = NativeFetchMcpHandler(httpClient: client);
      final res = await handler.callTool('fetch', {'url': 'https://example.com/start'});
      expect(res.isError, isTrue);
      expect(res.error, contains('Blocked redirect'));
      expect(requests, equals(1));
      await handler.dispose();
    });

    test('caps the number of followed redirects', () async {
      var requests = 0;
      final client = MockClient((req) async {
        requests++;
        return http.Response('', 302, headers: {'location': '/next'});
      });
      final handler = NativeFetchMcpHandler(httpClient: client);
      final res = await handler.callTool('fetch', {'url': 'https://example.com/start'});
      expect(res.isError, isTrue);
      expect(res.error, contains('too many redirects'));
      expect(requests, lessThanOrEqualTo(8));
      await handler.dispose();
    });
  });

  group('NativeFetchMcpHandler client lifecycle', () {
    test('closes the injected client on dispose', () async {
      final client = _TrackingClient();
      final handler = NativeFetchMcpHandler(httpClient: client);
      await handler.dispose();
      expect(client.closed, isTrue);
    });

    test('reuses one internally-created client and closes it on dispose', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        req.response.statusCode = 200;
        req.response.write('ok');
        req.response.close();
      });

      final handler = NativeFetchMcpHandler(allowedHosts: {'127.0.0.1'});
      final url = 'http://127.0.0.1:${server.port}/';

      final first = await handler.callTool('fetch', {'url': url, 'raw': true});
      expect(first.isError, isFalse);
      final second = await handler.callTool('fetch', {'url': url, 'raw': true});
      expect(second.isError, isFalse);

      await handler.dispose();

      final afterDispose = await handler.callTool('fetch', {'url': url, 'raw': true});
      expect(afterDispose.isError, isTrue);

      await server.close(force: true);
    });
  });
}
