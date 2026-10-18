import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ovid_ai/core/native_mcp.dart';
import 'package:ovid_ai/core/ssrf_guard.dart';

/// M3: the SSRF guard classifies every address family and resolves names,
/// refusing when ANY resolved address is non-public.
void main() {
  tearDown(() => SsrfGuard.resolverForTest = null);

  group('address classification table', () {
    const nonPublic = <String>[
      // IPv4
      '0.0.0.0', '0.1.2.3', '10.0.0.1', '10.255.255.255',
      '100.64.0.1', '100.100.100.200', '100.127.255.254',
      '127.0.0.1', '127.8.9.10', '169.254.169.254', '169.254.0.1',
      '172.16.0.1', '172.31.255.255', '192.0.0.8', '192.168.1.1',
      '198.18.0.1', '198.19.255.255', '224.0.0.1', '239.255.255.250',
      '240.0.0.1', '255.255.255.255',
      // IPv6
      '::', '::1', 'fc00::1', 'fd12:3456::1', 'fe80::1', 'febf::1',
      'fec0::1', 'ff02::1',
      // IPv4-embedding IPv6 forms
      '::ffff:127.0.0.1', '::ffff:10.0.0.1', '::ffff:169.254.169.254',
      '::ffff:100.64.0.1', '::127.0.0.1', '64:ff9b::a9fe:a9fe',
      '64:ff9b::7f00:1', '2002:7f00:1::1', '2002:c0a8:101::1',
    ];
    const public = <String>[
      '1.1.1.1', '8.8.8.8', '93.184.216.34', '100.63.255.255',
      '100.128.0.1', '172.15.255.255', '172.32.0.1', '192.0.1.1',
      '192.169.0.1', '198.17.0.1', '198.20.0.1', '223.255.255.254',
      '2606:4700:4700::1111', '2001:4860:4860::8888', '::ffff:8.8.8.8',
      '64:ff9b::808:808', '2002:808:808::1', 'fbff::1', 'fe7f::1',
    ];

    for (final a in nonPublic) {
      test('$a is non-public', () {
        expect(SsrfGuard.isNonPublicAddress(InternetAddress(a)), isTrue);
      });
    }
    for (final a in public) {
      test('$a is public', () {
        expect(SsrfGuard.isNonPublicAddress(InternetAddress(a)), isFalse);
      });
    }

    test('metadata/link-local subset', () {
      for (final a in [
        '169.254.169.254',
        '100.100.100.200',
        'fe80::1',
        '::ffff:169.254.169.254',
        '64:ff9b::a9fe:a9fe',
      ]) {
        expect(
          SsrfGuard.isMetadataOrLinkLocalAddress(InternetAddress(a)),
          isTrue,
          reason: a,
        );
      }
      for (final a in ['127.0.0.1', '10.0.0.1', '8.8.8.8', 'fd00::1']) {
        expect(
          SsrfGuard.isMetadataOrLinkLocalAddress(InternetAddress(a)),
          isFalse,
          reason: a,
        );
      }
    });
  });

  group('DNS resolution', () {
    void resolveTo(Map<String, List<String>> table) {
      SsrfGuard.resolverForTest = (host) async => [
        for (final a in table[host] ?? const <String>[]) InternetAddress(a),
      ];
    }

    test('a name with ANY internal address is refused', () async {
      resolveTo({
        'mixed.example': ['93.184.216.34', '10.0.0.5'],
        'mapped.example': ['::ffff:127.0.0.1'],
        'cgnat.example': ['100.64.1.1'],
        'ula.example': ['fd00::5'],
        'public.example': ['93.184.216.34', '2606:4700::1'],
      });
      for (final host in [
        'mixed.example',
        'mapped.example',
        'cgnat.example',
        'ula.example',
        'localhost',
        'api.localhost',
      ]) {
        expect(await SsrfGuard.nonPublicHostReason(host), isNotNull,
            reason: host);
      }
      expect(await SsrfGuard.nonPublicHostReason('public.example'), isNull);
      expect(await SsrfGuard.nonPublicHostReason('[::1]'), isNotNull);
    });

    test('resolution failure does not fabricate a refusal', () async {
      SsrfGuard.resolverForTest = (_) async => throw const SocketException('x');
      expect(await SsrfGuard.nonPublicHostReason('nx.example'), isNull);
    });

    test('metadata by DNS is detected', () async {
      resolveTo({'meta.example': ['169.254.169.254']});
      expect(await SsrfGuard.resolvesToMetadataOrLinkLocal('meta.example'),
          isTrue);
      resolveTo({'lan.example': ['192.168.1.2']});
      expect(await SsrfGuard.resolvesToMetadataOrLinkLocal('lan.example'),
          isFalse);
    });

    test('fetch MCP refuses names resolving inside, incl. via redirect', () async {
      resolveTo({
        'rebind.example': ['127.0.0.1'],
        'ok.example': ['93.184.216.34'],
        'inner.example': ['::ffff:10.1.2.3'],
      });
      final requested = <Uri>[];
      final client = MockClient((req) async {
        requested.add(req.url);
        if (req.url.host == 'ok.example') {
          return http.Response('', 302,
              headers: {'location': 'http://inner.example/admin'});
        }
        return http.Response('reached', 200);
      });
      final handler = NativeFetchMcpHandler(httpClient: client);
      final direct = await handler.callTool('fetch', {
        'url': 'http://rebind.example/',
      });
      expect(direct.isError, isTrue);
      expect(direct.error, contains('non-public'));
      final redirected = await handler.callTool('fetch', {
        'url': 'http://ok.example/',
      });
      expect(redirected.isError, isTrue);
      expect(redirected.error, contains('Blocked redirect'));
      expect(requested.map((u) => u.host), ['ok.example']);
      final literal = await handler.callTool('fetch', {
        'url': 'http://[fd00::1]/',
      });
      expect(literal.isError, isTrue);
      await handler.dispose();
    });

  });
}
