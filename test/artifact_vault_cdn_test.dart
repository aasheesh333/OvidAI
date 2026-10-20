// W12 — client preference for signed CDN artifact URLs, with a canonical
// presign fallback. These tests pin the fallback contract: a deployment
// without the CDN must behave exactly as before, while typed object verdicts
// are never masked by a second request.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ovid_ai/core/cloud/artifact_vault.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/session_artifacts.dart';

const _sessionId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

Map<String, Object?> _item(String id, {String source = 'generated', String name = 'shot.png'}) => {
      'id': id,
      'sessionId': _sessionId,
      'sessionTitle': 'Research',
      'name': name,
      'origin': source,
      'category': 'image',
      'sizeBytes': 4,
      'contentType': 'image/png',
      'createdAt': '2026-10-19T10:00:00.000Z',
      'availability': 'unverified',
    };

SessionArtifact _artifact({String source = 'generated'}) =>
    VaultArtifact.fromJson(_item('canonical-id', source: source))
        .toSessionArtifact('firebase:a');

CloudRestClient _rest(MockClient mock) => CloudRestClient(
      restBase: 'https://cloud.test',
      headers: CloudHeaders.forTest(),
      httpClient: mock,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('prefers the CDN mint and never persists the URL', () async {
    final requests = <http.Request>[];
    final rest = _rest(MockClient((r) async {
      requests.add(r);
      return http.Response(
        jsonEncode({
          'url': 'https://cdn.ovidsi.com/o/abc?t=tok&e=1700000900&c=immutable',
          'expiresAt': '2023-11-14T22:28:20.000Z',
          'cacheClass': 'immutable',
        }),
        200,
      );
    }));
    final client = ArtifactVaultClient(rest: rest, accountId: () => 'firebase:a');

    final minted = await client.mintPreferredUrl(_artifact());

    expect(requests.single.url.path, '/artifacts/canonical-id/cdn-url');
    expect(requests.single.url.queryParameters, {'source': 'generated'});
    expect(minted.url, contains('cdn.ovidsi.com/o/'));
    expect(minted.expiresAt, DateTime.utc(2023, 11, 14, 22, 28, 20));
    // The row/artifact itself carries no URL after the mint.
    expect(_artifact().url, isNull);
  });

  test('asks for an attachment disposition on download/share', () async {
    final requests = <http.Request>[];
    final rest = _rest(MockClient((r) async {
      requests.add(r);
      return http.Response(
        jsonEncode({'url': 'https://cdn.test/o/x?t=t&e=1', 'expiresAt': '2023-11-14T22:28:20.000Z'}),
        200,
      );
    }));
    final client = ArtifactVaultClient(rest: rest, accountId: () => 'firebase:a');

    await client.mintPreferredUrl(_artifact(), download: true);

    expect(requests.single.url.queryParameters, {'source': 'generated', 'download': '1'});
  });

  test('falls back to the canonical presign when the CDN is not configured', () async {
    final requests = <http.Request>[];
    final rest = _rest(MockClient((r) async {
      requests.add(r);
      if (r.url.path.endsWith('/cdn-url')) {
        return http.Response(
          jsonEncode({
            'error': {'code': 'cdn_not_configured', 'message': 'no cdn'},
          }),
          503,
        );
      }
      return http.Response(
        jsonEncode({
          'url': 'https://r2.test/bucket/users/u1/artifacts/s/a-shot.png?sig=1',
          'expiresAt': '2023-11-14T23:13:20.000Z',
        }),
        200,
      );
    }));
    final client = ArtifactVaultClient(rest: rest, accountId: () => 'firebase:a');

    final minted = await client.mintPreferredUrl(_artifact());

    expect(requests.map((r) => r.url.path), [
      '/artifacts/canonical-id/cdn-url',
      '/artifacts/canonical-id/url',
    ]);
    expect(minted.url, contains('r2.test'));

    // The client remembers the CDN is unavailable: the next mint skips the
    // doomed CDN round trip and goes straight to the canonical route.
    await client.mintPreferredUrl(_artifact());
    expect(requests.map((r) => r.url.path), [
      '/artifacts/canonical-id/cdn-url',
      '/artifacts/canonical-id/url',
      '/artifacts/canonical-id/url',
    ]);
  });

  test('does not mask typed object verdicts with a fallback request', () async {
    final requests = <http.Request>[];
    final rest = _rest(MockClient((r) async {
      requests.add(r);
      return http.Response(
        jsonEncode({
          'error': {'code': 'artifact_unavailable', 'message': 'gone'},
        }),
        404,
      );
    }));
    final client = ArtifactVaultClient(rest: rest, accountId: () => 'firebase:a');

    await expectLater(
      client.mintPreferredUrl(_artifact()),
      throwsA(isA<CloudApiException>()
          .having((e) => e.code, 'code', 'artifact_unavailable')
          .having((e) => e.status, 'status', 404)),
    );
    expect(requests, hasLength(1));
  });

  test('fences an artifact bound to another account before any request', () async {
    var requests = 0;
    final rest = _rest(MockClient((r) async {
      requests++;
      return http.Response('{}', 200);
    }));
    final client = ArtifactVaultClient(rest: rest, accountId: () => 'firebase:b');

    await expectLater(
      client.mintPreferredUrl(_artifact()),
      throwsA(isA<CloudApiException>().having((e) => e.code, 'code', 'account_changed')),
    );
    expect(requests, 0);
  });

  test('a signed-out caller sends no request', () async {
    var requests = 0;
    final rest = _rest(MockClient((r) async {
      requests++;
      return http.Response('{}', 200);
    }));
    final client = ArtifactVaultClient(rest: rest, accountId: () => null);

    await expectLater(
      client.mintPreferredUrl(_artifact()),
      throwsA(isA<CloudApiException>().having((e) => e.code, 'code', 'account_changed')),
    );
    expect(requests, 0);
  });
}
