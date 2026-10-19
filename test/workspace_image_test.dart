import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/link_safety.dart';
import 'package:ovid_ai/ui/workspace_image.dart';

// 1x1 transparent PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA'
  '60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  final calls = <String>[];

  setUp(() {
    calls.clear();
    WorkspaceImage.debugClearCache();
    WorkspaceImage.debugResolverOverride = (_) async => 'srv-1';
    WorkspaceImage.debugLoaderOverride = (serverId, path) async {
      calls.add('$serverId:$path');
      return WorkspaceImageBytes(_png, contentType: 'image/png');
    };
  });

  tearDown(() {
    WorkspaceImage.debugLoaderOverride = null;
    WorkspaceImage.debugResolverOverride = null;
    WorkspaceImage.debugClearCache();
  });

  Future<void> pumpImage(WidgetTester tester, String src,
      {String? alt}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: safeMarkdownImage(Uri.parse(src), null, alt),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  bool hasMemoryImage(WidgetTester tester) => tester
      .widgetList<Image>(find.byType(Image))
      .any((img) =>
          img.image is MemoryImage ||
          (img.image is ResizeImage &&
              (img.image as ResizeImage).imageProvider is MemoryImage));

  group('normalizeWorkspaceImagePath', () {
    test('accepts and normalises safe relative image paths', () {
      expect(normalizeWorkspaceImagePath('chart.png'), 'chart.png');
      expect(normalizeWorkspaceImagePath('./out/chart.PNG'), 'out/chart.PNG');
      expect(normalizeWorkspaceImagePath('out//my%20plot.webp'),
          'out/my plot.webp');
      expect(normalizeWorkspaceImagePath('a.jpeg'), 'a.jpeg');
      expect(normalizeWorkspaceImagePath('a.gif'), 'a.gif');
    });

    test('refuses unsafe paths and non-image types', () {
      for (final bad in [
        '../x.png',
        'a/../../x.png',
        '%2E%2E/x.png',
        '/etc/x.png',
        '%2Fetc/x.png',
        '~/x.png',
        r'a\x.png',
        'a%5Cx.png',
        'file:x.png',
        'C:/x.png',
        'notes.txt',
        'x.svg',
        'png',
        '',
        '%E0%A4%A.png',
      ]) {
        expect(normalizeWorkspaceImagePath(bad), isNull, reason: bad);
      }
    });
  });

  group('safeMarkdownImage workspace images', () {
    testWidgets('relative chart.png renders an Image from fetched bytes',
        (tester) async {
      await pumpImage(tester, 'chart.png', alt: 'Chart');
      expect(calls, ['srv-1:chart.png']);
      expect(find.byType(WorkspaceImage), findsOneWidget);
      expect(hasMemoryImage(tester), isTrue);
      expect(find.textContaining('Image not shown'), findsNothing);
      final img = tester.widget<Image>(
          find.byKey(const ValueKey('workspace-image')));
      expect((img.image as ResizeImage).width, isNotNull);
    });

    testWidgets('shows a loading placeholder before bytes arrive',
        (tester) async {
      WorkspaceImage.debugLoaderOverride = (_, _) =>
          Future.delayed(const Duration(seconds: 1),
              () => WorkspaceImageBytes(_png, contentType: 'image/png'));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: safeMarkdownImage(Uri.parse('c.png'), null, null)),
      ));
      expect(find.byKey(const ValueKey('workspace-image-loading')),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(hasMemoryImage(tester), isTrue);
    });

    testWidgets('cached per (server session, path): no refetch on rebuild',
        (tester) async {
      await pumpImage(tester, 'chart.png');
      await tester.pumpWidget(const SizedBox());
      await pumpImage(tester, './chart.png');
      expect(calls, ['srv-1:chart.png']);
      expect(hasMemoryImage(tester), isTrue);
    });

    for (final bad in ['../x.png', '/etc/x.png', 'file:///x.png']) {
      testWidgets('$bad is refused without a fetch', (tester) async {
        await pumpImage(tester, bad);
        expect(calls, isEmpty);
        expect(find.byType(WorkspaceImage), findsNothing);
        expect(find.byType(Image), findsNothing);
        expect(find.textContaining('Image not shown'), findsOneWidget);
      });
    }

    testWidgets('non-image extension is refused', (tester) async {
      await pumpImage(tester, 'secrets.txt');
      expect(calls, isEmpty);
      expect(find.textContaining('Image not shown'), findsOneWidget);
    });

    testWidgets('a failing fetch shows the calm note', (tester) async {
      WorkspaceImage.debugLoaderOverride =
          (_, _) async => throw StateError('boom 500');
      await pumpImage(tester, 'chart.png', alt: 'Chart');
      expect(find.text('[Image could not be shown: Chart]'), findsOneWidget);
      expect(find.textContaining('boom'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no server session yet shows the calm note', (tester) async {
      WorkspaceImage.debugResolverOverride = (_) async => null;
      await pumpImage(tester, 'chart.png');
      expect(calls, isEmpty);
      expect(find.text('[Image could not be shown]'), findsOneWidget);
    });

    testWidgets('a non-image content type is refused', (tester) async {
      WorkspaceImage.debugLoaderOverride = (_, _) async =>
          WorkspaceImageBytes(_png, contentType: 'text/html');
      await pumpImage(tester, 'chart.png');
      expect(find.text('[Image could not be shown]'), findsOneWidget);
    });

    testWidgets('remote http images still wait for a tap', (tester) async {
      await pumpImage(tester, 'https://example.com/a.png');
      expect(find.byType(WorkspaceImage), findsNothing);
      expect(find.byKey(const ValueKey('remote-image-placeholder')),
          findsOneWidget);
      expect(calls, isEmpty);
    });
  });

  group('fetchWorkspaceImage', () {
    CloudRestClient restWith(Map<String, Object?> body) => CloudRestClient(
          restBase: 'https://api.test/cloud/v1',
          headers: CloudHeaders.forTest(),
          httpClient: MockClient((req) async {
            expect(req.url.path, '/cloud/v1/sessions/srv-1/workspace/file');
            expect(req.url.queryParameters['path'], 'out/chart.png');
            return http.Response(jsonEncode(body), 200,
                headers: {'content-type': 'application/json'});
          }),
        );

    test('inline base64 is decoded', () async {
      final r = await fetchWorkspaceImage('srv-1', 'out/chart.png',
          rest: restWith({
            'path': 'out/chart.png',
            'sizeBytes': _png.length,
            'contentType': 'image/png',
            'encoding': 'base64',
            'content': base64Encode(_png),
          }));
      expect(r.bytes, _png);
    });

    test('redirect fetches the presigned https URL', () async {
      final r = await fetchWorkspaceImage('srv-1', 'out/chart.png',
          rest: restWith({
            'path': 'out/chart.png',
            'sizeBytes': _png.length,
            'contentType': 'image/png',
            'downloadUrl': 'https://r2.test/obj?sig=1',
            'expiresAt': '2026-10-19T00:00:00Z',
          }),
          httpClient: MockClient((req) async {
            expect(req.url.host, 'r2.test');
            return http.Response.bytes(_png, 200);
          }));
      expect(r.bytes, _png);
    });

    test('oversized and insecure redirects are refused', () async {
      await expectLater(
        fetchWorkspaceImage('srv-1', 'out/chart.png',
            rest: restWith({
              'sizeBytes': kWorkspaceImageMaxBytes + 1,
              'contentType': 'image/png',
              'downloadUrl': 'https://r2.test/obj',
            })),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        fetchWorkspaceImage('srv-1', 'out/chart.png',
            rest: restWith({
              'contentType': 'image/png',
              'downloadUrl': 'http://r2.test/obj',
            })),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
