import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/conversation_share_service.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/cloud_usage_status.dart';
import 'package:ovid_ai/ui/conversation_share_sheet.dart';
import 'package:ovid_ai/ui/github_login_sheet.dart';
import 'package:ovid_ai/ui/image_receipt_panel.dart';
import 'package:ovid_ai/ui/share_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_share_service_test.dart'
    show shareReceipt, shareSession, shareUrl;
import 'image_studio_test.dart' show picture;

const _capture = bool.fromEnvironment('UI_REVIEW_CAPTURE');
const _captureKey = ValueKey('sharing-review-capture');
const _charge = '0.0370370367037037036703703703670';
const _request = 'recover-request-1234';
const _layouts = [
  (Size(360, 640), 2.0),
  (Size(320, 640), 1.0),
  (Size(1024, 768), 1.0),
];

Widget _host(Widget child, double scale) => MaterialApp(
  theme: Aether.theme(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: RepaintBoundary(
    key: _captureKey,
    child: Scaffold(body: child),
  ),
);

void _viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _frames(WidgetTester tester, [int count = 5]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      180,
      scrollable: find.descendant(
        of: find.byType(ListView), matching: find.byType(Scrollable),
      ).first,
    );
  }
  // The share list is nested inside the sheet's own scrolling viewport.
  // Lay out the closest viewport's new position before revealing the target
  // through its outer ancestors; a single top-aligned pass can clip it again.
  final target = tester.element(finder);
  await Scrollable.of(target).position.ensureVisible(
    target.findRenderObject()!,
    alignment: .5,
  );
  await tester.pump();
  await Scrollable.ensureVisible(target, alignment: .5);
  await _frames(tester);
  expect(finder.hitTestable(), findsOneWidget);
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => Aether.dark = true);

  for (final layout in _layouts) {
    for (final dark in [true, false]) {
      testWidgets('share copy/revoke ${layout.$1} ${layout.$2}x dark=$dark', (
        tester,
      ) async {
        _viewport(tester, layout.$1);
        Aether.dark = dark;
        final semantics = tester.ensureSemantics();
        try {
        String? copied;
        var active = true;
        var reads = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null));
        final service = ConversationShareService(
          baseUrl: 'https://share.example.test',
          idToken: () async => 'fixture',
          client: MockClient((request) async {
            if (request.method == 'DELETE') {
              active = false;
              return http.Response('', 204);
            }
            expect(request.method, 'GET');
            reads++;
            return http.Response(jsonEncode({
              'shares': active ? [shareReceipt()] : [],
            }), 200);
          }),
        );
        await tester.pumpWidget(_host(
          ConversationShareSheet(session: shareSession(), service: service),
          layout.$2,
        ));
        await _frames(tester);
        expect(tester.takeException(), isNull);
        expect(find.bySemanticsLabel('QR code for shared conversation'),
            findsOneWidget);
        final link = tester.widget<SelectableText>(find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == shareUrl,
        ));
        expect(link.maxLines, isNull, reason: 'The complete URL stays readable');
        if (_capture && dark && layout.$2 == 2) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(_captureKey),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            try {
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              await File('/tmp/opencode/ui-finish-13.png')
                  .writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        await _reveal(tester, find.text('Copy link'));
        final copyBox = tester.getSize(find.widgetWithText(TextButton, 'Copy link'));
        expect(copyBox.height, greaterThanOrEqualTo(44));
        await tester.tap(find.text('Copy link'));
        await _frames(tester);
        expect(copied, shareUrl);
        expect(reads, 2, reason: 'Copy revalidates the owner receipt');
        await _reveal(tester, find.text('Revoke'));
        await tester.tap(find.text('Revoke'));
        await _frames(tester);
        expect(active, isFalse);
        expect(find.text('Copy link'), findsNothing);
        expect(tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Create link'),
        ).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('share load retry and lost response preserve the frozen request', (
    tester,
  ) async {
    _viewport(tester, const Size(360, 640));
    var failLoad = true;
    final bodies = <Map<String, dynamic>>[];
    final session = shareSession();
    final service = ConversationShareService(
      baseUrl: 'https://share.example.test',
      idToken: () async => 'fixture',
      client: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response(failLoad ? '{}' : '{"shares":[]}', failLoad ? 503 : 200);
        }
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        if (bodies.length == 1) throw http.ClientException('lost response');
        return http.Response(jsonEncode(shareReceipt()), 201);
      }),
    );
    await tester.pumpWidget(_host(
      ConversationShareSheet(session: session, service: service), 2,
    ));
    await _frames(tester);
    expect(tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Create link'),
    ).onPressed, isNull);
    failLoad = false;
    await _reveal(tester, find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await _frames(tester);
    session.messages.first.content = 'Edited after opening';
    await _reveal(tester, find.text('Create link'));
    await tester.tap(find.text('Create link'));
    await _frames(tester);
    expect(find.text('Copy link'), findsNothing);
    await tester.tap(find.text('Create link'));
    await _frames(tester);
    expect(bodies, hasLength(2));
    expect(bodies[0]['request_id'], bodies[1]['request_id']);
    expect(bodies[1]['messages'], [
      {'role': 'user', 'content': 'Hello'},
      {'role': 'assistant', 'content': 'Answer'},
    ]);
    expect(tester.takeException(), isNull);
  });

  for (final layout in _layouts) {
  for (final dark in [true, false]) {
  testWidgets('GitHub copy/cancel ${layout.$1} ${layout.$2}x dark=$dark', (
    tester,
  ) async {
    _viewport(tester, layout.$1);
    Aether.dark = dark;
    // Preserve the singleton write queue's root-zone discipline.
    await tester.runAsync(() => GitHubService.I.signOut());
    final clipboard = Completer<void>();
    String? copied;
    var tokenRequests = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
          await clipboard.future;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final client = MockClient((request) async {
      if (request.url.path == '/login/device/code') {
        return http.Response(jsonEncode({
          'device_code': 'device-code',
          'user_code': 'ABCD-1234',
          'verification_uri': 'https://github.com/login/device',
          'expires_in': 900,
          'interval': 30,
        }), 200);
      }
      tokenRequests++;
      return http.Response('{"error":"authorization_pending"}', 200);
    });
    await tester.pumpWidget(_host(Builder(builder: (context) => TextButton(
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => GithubLoginSheet(client: client),
      ),
      child: const Text('Open'),
    )), layout.$2));
    await tester.tap(find.text('Open'));
    await _frames(tester);
    expect(find.text('ABCD-1234'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // A display-only code must have its full content area, not share a row
    // with the copy chip at 2x scale.
    if (layout.$2 == 2) {
      expect(tester.getSize(find.byType(TextField)).width, greaterThan(280));
    }
    await _reveal(tester, find.text('Copy'));
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, 'ABCD-1234');
    await tester.tap(find.text('Cancel'));
    await _frames(tester);
    clipboard.complete();
    await tester.pump(const Duration(seconds: 31));
    expect(find.byType(GithubLoginSheet), findsNothing);
    expect(tokenRequests, 0);
    expect(GitHubService.I.token, isNull);
    expect(tester.takeException(), isNull);
  });
  }
  }

  for (final layout in _layouts) {
  for (final dark in [true, false]) {
  testWidgets('native menu failure ${layout.$1} ${layout.$2}x dark=$dark', (
    tester,
  ) async {
    _viewport(tester, layout.$1);
    Aether.dark = dark;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('ovid/native'),
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/native'), null));
    await tester.pumpWidget(_host(ChatShareButton(session: shareSession()), layout.$2));
    await tester.tap(find.byTooltip('Share'));
    await _frames(tester);
    final label = find.text('Share chat transcript');
    final paragraph = tester.renderObject<RenderParagraph>(label);
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
    await tester.tap(label);
    await _frames(tester);
    expect(find.text('Could not open sharing. Please retry.'), findsOneWidget);
  });
  }
  }

  testWidgets('GitHub retries failed code loading and keeps code on browser error', (
    tester,
  ) async {
    _viewport(tester, const Size(360, 640));
    await tester.runAsync(() => GitHubService.I.signOut());
    var starts = 0;
    final client = MockClient((request) async {
      expect(request.url.path, '/login/device/code');
      if (++starts == 1) return http.Response('{}', 503);
      return http.Response(jsonEncode({
        'device_code': 'device-code', 'user_code': 'ABCD-1234',
        'verification_uri': 'https://github.com/login/device',
        'expires_in': 900, 'interval': 30,
      }), 200);
    });
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'), null,
    ));
    await tester.pumpWidget(_host(Builder(builder: (context) => TextButton(
      onPressed: () => showModalBottomSheet<void>(
        context: context, isScrollControlled: true,
        builder: (_) => GithubLoginSheet(client: client),
      ),
      child: const Text('Open'),
    )), 2));
    await tester.tap(find.text('Open'));
    await _frames(tester);
    expect(find.text('Something went wrong'), findsOneWidget);
    await _reveal(tester, find.text('Retry'));
    await tester.tap(find.text('Retry'));
    await _frames(tester);
    expect(starts, 2);
    await _reveal(tester, find.text('Sign in'));
    await tester.tap(find.text('Sign in'));
    await _frames(tester);
    expect(find.text('Could not open the browser.'), findsOneWidget);
    expect(find.text('ABCD-1234'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _frames(tester);
    await tester.pump(const Duration(seconds: 31));
    expect(tester.takeException(), isNull);
  });

  for (final layout in _layouts) {
  for (final dark in [true, false]) {
  testWidgets('receipt recovery ${layout.$1} ${layout.$2}x dark=$dark', (
    tester,
  ) async {
    _viewport(tester, layout.$1);
    Aether.dark = dark;
    // The receipt journal serializes process-wide; all journal/codec work runs
    // in the root zone, including callbacks initiated by taps.
    await tester.runAsync(() async {
      var broken = false;
      final store = ImageReceiptStore(preferences: () async {
        if (broken) throw StateError('journal unavailable');
        return SharedPreferences.getInstance();
      });
      await store.reserve(ImageRequestRecord(
        accountId: 'alice', requestId: _request, fingerprint: 'a' * 64,
      ), isCurrent: () => true, canSubmit: () => true);
      final png = base64Encode(await picture());
      final paths = <String>[];
      final studio = ImageStudio(
        receiptStore: store,
        client: MockClient((request) async {
          expect(request.method, 'GET');
          paths.add(request.url.path);
          return http.Response(jsonEncode({
            'receipt': {
              'account_id': 'alice', 'request_id': _request,
              'fingerprint': 'a' * 64, 'state': 'confirmed', 'charged': _charge,
            },
            if (request.url.path.endsWith('/result')) ...{
              'model': 'ovid-image',
              'data': [{'b64_json': png, 'mime_type': 'image/png'}],
            },
          }), 200);
        }),
      )..bindAccount('alice');
      broken = true;
      await expectLater(studio.loadReceipts(), throwsStateError);
      await tester.pumpWidget(_host(SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ImageReceiptPanel(studio: studio,
          headers: () async => {'Authorization': 'Bearer fixture'}),
      ), layout.$2));
      expect(find.textContaining('could not be loaded'), findsOneWidget);
      expect(find.text('No loaded image receipts for this account.'), findsNothing);
      expect(tester.takeException(), isNull);
      final loaded = Completer<void>();
      void onLoaded() {
        if (!studio.receiptsLoading && studio.receiptLoadError == null &&
            !loaded.isCompleted) {
          loaded.complete();
        }
      }
      studio.addListener(onLoaded);
      broken = false;
      await tester.tap(find.text('Retry loading receipts'));
      await loaded.future;
      studio.removeListener(onLoaded);
      await tester.pump();
      expect(find.text('Charge: not confirmed'), findsOneWidget);
      final recovered = Completer<void>();
      var publications = 0;
      studio.addListener(() {
        if (++publications == 2) recovered.complete();
      });
      await _reveal(tester, find.text('Recover image'));
      await tester.tap(find.text('Recover image'));
      await recovered.future;
      await tester.pump();
      await tester.pump();
      expect(paths, [
        '/v1/images/requests/$_request',
        '/v1/images/requests/$_request/result',
      ]);
      expect(find.text('Exact charge: $_charge'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      final imageFinder = find.byType(Image);
      final image = tester.widget<Image>(imageFinder);
      expect((image.image as MemoryImage).bytes, base64Decode(png));
      // Recovery decoding and Image's display stream are separate async work.
      // Wait for the actual display provider, then verify painted pixels and
      // viewport bounds rather than pointer hit testing a non-action widget.
      await precacheImage(image.image, tester.element(imageFinder));
      await tester.pump();
      await tester.ensureVisible(imageFinder);
      await tester.pump();
      final raw = tester.widget<RawImage>(find.descendant(
        of: imageFinder, matching: find.byType(RawImage),
      ));
      expect(raw.image, isNotNull);
      expect((raw.image!.width, raw.image!.height), (8, 6));
      final bounds = tester.getRect(imageFinder);
      expect(bounds.width, greaterThan(0));
      expect(bounds.height, greaterThan(0));
      expect((Offset.zero & layout.$1).contains(bounds.topLeft), isTrue);
      expect(bounds.right, lessThanOrEqualTo(layout.$1.width));
      expect(bounds.bottom, lessThanOrEqualTo(layout.$1.height));
      expect(tester.takeException(), isNull);
      studio.bindAccount('bob');
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.text('Exact charge: $_charge'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      studio.dispose();
    });
  });
  }
  }

  for (final layout in _layouts) {
  for (final dark in [true, false]) {
  testWidgets('allowance retry ${layout.$1} ${layout.$2}x dark=$dark', (
    tester,
  ) async {
    _viewport(tester, layout.$1);
    Aether.dark = dark;
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'fixture';
    var requests = 0;
    OvidCloudService.httpClientFactoryForTest = () => MockClient((_) async {
      requests++;
      return http.Response('{}', 503);
    });
    final store = CloudUsageStore.acquire(app);
    addTearDown(() {
      store.release();
      OvidCloudService.idTokenOverrideForTest = null;
      OvidCloudService.httpClientFactoryForTest = null;
      AgentService.I.debugPauseScheduleTimerForTest(false);
      AppState.resetTestInstance();
    });
    await tester.pumpWidget(_host(CloudUsageStatus(store: store), layout.$2));
    await _frames(tester);
    expect(find.text('OFFLINE'), findsNothing);
    final retry = find.widgetWithText(TextButton, 'Retry');
    expect(tester.getSize(retry).height, greaterThanOrEqualTo(44));
    final before = requests;
    await tester.tap(retry);
    await tester.pump(const Duration(seconds: 3));
    await _frames(tester);
    expect(requests, greaterThan(before));
    expect(tester.takeException(), isNull);
  });
  }
  }
}
