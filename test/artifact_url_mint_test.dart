// Presigned artifact URL re-minting (browser/artifacts audit, client P2 A).
//
// Presigned artifact URLs live ~1h, transcripts persist them verbatim, and
// nothing under lib/ called the gateway's re-mint route
// (GET /sessions/:id/artifacts/:artifactId/url) — so every cloud artifact
// older than the TTL rendered (and shared) a dead capability. These tests
// pin the recovery chain:
//   - cloudArtifactIdOf                   — the workspace-object id recovered
//                                            from the URL path (R2 key layout,
//                                            cloud/packages/storage/src/keys.ts)
//   - CloudRestClient.mintArtifactUrl     — wire shape (cloud_rest_client_test.dart)
//   - ArtifactThumb / ArtifactPreviewScreen / shareArtifact — mint-on-use with
//                                            a stale-URL fallback when minting fails.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/session_artifacts.dart';
import 'package:ovid_ai/ui/artifact_preview.dart';

const _restBase = 'https://cloud.test';
const _artifactId = '01234567-89ab-7cde-8f01-23456789abcd';
const _sessionId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

/// A presigned-style artifact URL: R2 key `users/{uid}/artifacts/{sid}/{id}-{name}`.
String _presigned(String sig) =>
    'https://r2.test/bucket/users/u1/artifacts/$_sessionId/$_artifactId-shot.png'
    '?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Signature=$sig';

SessionArtifact _imageArtifact(String url) => SessionArtifact(
      id: 'a1',
      name: 'shot.png',
      sessionId: _sessionId,
      sessionTitle: 'Chat',
      time: DateTime(2026, 10, 18, 10),
      origin: ArtifactOrigin.generated,
      kind: ArtifactKind.image,
      url: url,
    );

CloudRestClient _install({required http.Client mock}) {
  final client = CloudRestClient(
    httpClient: mock,
    headers: CloudHeaders.forTest(),
    restBase: _restBase,
  );
  CloudRestClient.installForTest(client);
  return client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), null);
  });

  group('cloudArtifactIdOf', () {
    test('recovers the workspace-object id from a presigned artifact URL',
        () {
      expect(cloudArtifactIdOf(_presigned('stale')), _artifactId);
    });

    test('recovers the workspace-object id from a signed CDN URL', () {
      final key = 'users/u1/artifacts/$_sessionId/$_artifactId-shot.png';
      final opaque =
          base64Url.encode(utf8.encode(key)).replaceAll('=', '');
      expect(
        cloudArtifactIdOf(
          'https://cdn.ovidsi.com/o/$opaque?t=tok&e=1700000000&c=immutable',
        ),
        _artifactId,
      );
    });

    test('returns null for URLs without the artifact key layout', () {
      expect(cloudArtifactIdOf(null), isNull);
      expect(cloudArtifactIdOf(''), isNull);
      expect(cloudArtifactIdOf('/local/workspace/shot.png'), isNull);
      expect(
        cloudArtifactIdOf('https://example.com/downloads/shot.png?sig=1'),
        isNull,
      );
      // `artifacts` with no session-id + object segments after it.
      expect(
        cloudArtifactIdOf('https://r2.test/artifacts/only-one.png'),
        isNull,
      );
    });

    test('returns null when the object segment is not a UUID prefix', () {
      // The session id is a UUID, but the object piece must start with one.
      expect(
        cloudArtifactIdOf(
          'https://r2.test/users/u1/artifacts/$_sessionId/not-a-uuid-shot.png',
        ),
        isNull,
      );
    });
  });

  group('mint-on-use', () {
    /// The preview Image resizes network images (Aether.imageCacheWidth), which
/// wraps the provider in a ResizeImage — unwrap it to read the URL.
String networkUrlOf(Image image) {
  var provider = image.image;
  if (provider is ResizeImage) provider = provider.imageProvider;
  return (provider as NetworkImage).url;
}

testWidgets('the remote-image preview swaps in the minted URL', (
      tester,
    ) async {
      final requests = <http.Request>[];
      _install(
        mock: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'url': _presigned('fresh'),
              'expiresAt': '2026-10-18T12:00:00.000Z',
            }),
            200,
          );
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ArtifactPreviewScreen(
            artifact: _imageArtifact(_presigned('stale')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // The mint went to the gateway route with the recovered artifact id.
      expect(
        requests.single.url.toString(),
        '$_restBase/sessions/$_sessionId/artifacts/$_artifactId/url',
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(networkUrlOf(image), _presigned('fresh'));
    });

    testWidgets('a mint failure falls back to the stale persisted URL', (
      tester,
    ) async {
      _install(
        mock: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'error': {'code': 'storage_not_configured', 'message': 'no storage'},
            }),
            503,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ArtifactPreviewScreen(
            artifact: _imageArtifact(_presigned('stale')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // Better a maybe-working old URL than nothing.
      final image = tester.widget<Image>(find.byType(Image));
      expect(networkUrlOf(image), _presigned('stale'));
    });

    testWidgets('the thumbnail renders stale first, then the minted URL', (
      tester,
    ) async {
      _install(
        mock: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'url': _presigned('fresh'),
              'expiresAt': '2026-10-18T12:00:00.000Z',
            }),
            200,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ArtifactThumb(artifact: _imageArtifact(_presigned('stale'))),
          ),
        ),
      );
      // First frame: the persisted URL (the image cache may still honor it).
      var image = tester.widget<Image>(find.byType(Image));
      expect(networkUrlOf(image), _presigned('stale'));

      await tester.pump();
      await tester.pump();
      image = tester.widget<Image>(find.byType(Image));
      expect(networkUrlOf(image), _presigned('fresh'));
    });

    testWidgets('sharing a cloud artifact shares a freshly minted URL', (
      tester,
    ) async {
      _install(
        mock: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'url': _presigned('fresh'),
              'expiresAt': '2026-10-18T12:00:00.000Z',
            }),
            200,
          ),
        ),
      );
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ovid/native'),
              (call) async {
        calls.add(call);
        return true;
      });

      await tester.pumpWidget(
        MaterialApp(
          home: ArtifactPreviewScreen(
            artifact: _imageArtifact(_presigned('stale')),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Share'));
      await tester.pump();
      await tester.pump();

      // The sheet receives the re-minted capability, not the stale one.
      expect(calls.single.method, 'shareText');
      expect((calls.single.arguments as Map)['text'], _presigned('fresh'));
    });
  });
}
