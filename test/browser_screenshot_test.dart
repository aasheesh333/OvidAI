import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/plan_mode.dart';
import 'package:ovid_ai/core/state.dart';

/// `browser_screenshot` — real pixels from the active tab (2026-09-29).
///
/// webview_flutter ships NO screenshot API, so until this tool the agent could
/// read a page's text (`browser_read`), outline (`browser_outline`) and element
/// skeleton (`browser_snapshot`) but never SEE it. Layout, a rendered chart,
/// and "did that click actually log me in" were all unverifiable from Dart —
/// which is exactly the evidence the plan agent needs.
///
/// The native side is PixelCopy in OvidWebViewHandler.kt. These tests pin the
/// Dart half through a mocked `ovid/webview` channel, and deliberately pin the
/// three properties that make the tool trustworthy:
///
///   • it stages REAL PNG bytes for a vision-capable model, and says so;
///   • for a text-only model it reports that the image was NOT attached — never
///     pretend the model saw something (read_image's honesty rule);
///   • it writes NOTHING to disk, which is why it is safe in plan mode.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A minimal PNG header, matching the bytes the native capture would produce.
  // base64Encode([137, 80, 78, 71]) == 'iVBORw==' (same fixture the
  // device_screenshot test uses, so the two vision paths stay comparable).
  final png = base64Encode([137, 80, 78, 71]);

  late ChatSession session;
  late List<MethodCall> calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I
      ..debugPauseScheduleTimerForTest(true)
      ..clearBrowserTabsForTest();
    calls = <MethodCall>[];

    session = ChatSession(id: 'shot-1', title: 'S', model: 'gpt-4o', mode: 'auto');
    app.sessions.insert(0, session);
    app.activeSessionId = session.id;
    AgentService.setRunSessionForTest(session.id);
  });

  tearDown(() {
    AgentService.setRunSessionForTest('');
    AgentService.I
      ..clearBrowserTabsForTest()
      ..debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  /// Install a mocked native handler answering `capturePixels` with [reply].
  void mockCapture(Object? reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('ovid/webview'), (
          call,
        ) async {
          calls.add(call);
          return call.method == 'capturePixels' ? reply : null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('ovid/webview'), null);
    });
  }

  Future<String> shot([Map<String, dynamic> args = const {}]) =>
      AgentService.I.dispatchForTest('browser_screenshot', args);

  List<Map<String, dynamic>> staged() {
    final out = <Map<String, dynamic>>[];
    AgentService.I.appendPendingVisionMessagesForTest(out);
    return out;
  }

  group('the tool is declared', () {
    test('it is on the roster with a maxEdge parameter', () {
      final decl = AgentService.I.toolsForTest().firstWhere(
        (t) => t['function']['name'] == 'browser_screenshot',
        orElse: () => <String, dynamic>{},
      );
      expect(decl, isNotEmpty, reason: 'browser_screenshot must be declared');
      final fn = decl['function'] as Map;
      expect((fn['description'] as String), contains('PixelCopy'));
      final props =
          (fn['parameters'] as Map)['properties'] as Map<String, dynamic>;
      expect(props, contains('maxEdge'));
    });

    test('the stale "no pixel screenshot API" claim is gone', () {
      // browser_outline used to advertise itself as the workaround for a
      // missing screenshot API. Keeping that text now would be a lie, and it
      // is what told the model a visual check was impossible.
      final src = File('lib/core/agent_service.dart').readAsStringSync();
      expect(src, isNot(contains('webview_flutter has no pixel')));
      final outline = AgentService.I.toolsForTest().firstWhere(
        (t) => t['function']['name'] == 'browser_outline',
      );
      expect(
        (outline['function'] as Map)['description'] as String,
        isNot(contains('no pixel')),
      );
    });

    test('it has a UI label', () {
      expect(
        AgentService.toolTitleFor('browser_screenshot'),
        'Screenshot',
        reason: 'the tool card must not fall through to the raw tool name',
      );
    });
  });

  group('a successful capture', () {
    test('stages the PNG for a vision model and reports the geometry',
        () async {
      mockCapture({
        'captured': true,
        'base64': png,
        'width': 412,
        'height': 915,
        'sourceWidth': 1080,
        'sourceHeight': 2400,
      });

      final out = await shot();
      expect(out, contains('SCREENSHOT'));
      expect(out, contains('412x915'));
      expect(out, contains('attached to the next model request'));

      final messages = staged();
      expect(messages, hasLength(1), reason: 'exactly one vision part');
      final content = messages.single['content'] as List;
      expect((content.first as Map)['text'], contains('browser_screenshot'));
      expect((content.last as Map)['type'], 'image_url');
      expect(
        (((content.last as Map)['image_url'] as Map)['url'] as String),
        startsWith('data:image/png;base64,iVBORw=='),
      );
    });

    test('it addresses the native handler with the tab identity', () async {
      mockCapture({'captured': true, 'base64': png, 'width': 1, 'height': 1});

      await shot();
      expect(calls.map((c) => c.method), contains('capturePixels'));
      final args = calls.singleWhere(
        (c) => c.method == 'capturePixels',
      ).arguments as Map;
      // Identity keys ride along so one tab's capture can never resolve to
      // another tab's WebView (same contract as setDesktopViewport).
      expect(args, contains('tabId'));
      expect(args, contains('webViewIdentifier'));
      // Omitted → the native DEFAULT_CAPTURE_EDGE decides, not a Dart guess.
      expect(args.containsKey('maxEdge'), isFalse);
    });

    test('maxEdge is forwarded, and a non-positive one is dropped', () async {
      mockCapture({'captured': true, 'base64': png, 'width': 1, 'height': 1});

      await shot({'maxEdge': 640});
      var args = calls
          .singleWhere((c) => c.method == 'capturePixels')
          .arguments as Map;
      expect(args['maxEdge'], 640);

      await shot({'maxEdge': 0});
      args = calls.last.arguments as Map;
      expect(
        args.containsKey('maxEdge'),
        isFalse,
        reason: '0 must not be sent as a real cap',
      );
    });

    test('it writes NOTHING to disk — the property that keeps it plan-safe',
        () async {
      mockCapture({'captured': true, 'base64': png, 'width': 4, 'height': 4});
      final before = AgentService.I.producedFiles.length;

      await shot();

      expect(
        AgentService.I.producedFiles.length,
        before,
        reason: 'a capture is staged as bytes, never as a workspace file',
      );
    });
  });

  group('honest failures', () {
    test('a native refusal is surfaced verbatim', () async {
      mockCapture({'captured': false, 'reason': 'webview not laid out'});

      final out = await shot();
      expect(out, contains('screenshot failed'));
      expect(out, contains('webview not laid out'));
      expect(staged(), isEmpty, reason: 'nothing was captured to attach');
    });

    test('an unresolvable WebView says so', () async {
      mockCapture({'captured': false, 'reason': 'no attached webview'});
      expect(await shot(), contains('no attached webview'));
    });

    test('a missing captured flag is a failure, not a silent success',
        () async {
      mockCapture({'base64': png});
      expect(await shot(), contains('screenshot failed'));
      expect(staged(), isEmpty);
    });

    test('an unimplemented channel degrades without throwing', () async {
      // null reply — what a platform without the handler returns.
      mockCapture(null);
      expect(await shot(), contains('screenshot failed'));
    });

    test('malformed base64 is reported, not thrown at the model', () async {
      mockCapture({'captured': true, 'base64': '!!!not base64!!!'});
      expect(await shot(), contains('screenshot failed'));
      expect(staged(), isEmpty);
    });

    test('empty bytes are refused', () async {
      mockCapture({'captured': true, 'base64': '', 'width': 1, 'height': 1});
      expect(await shot(), contains('screenshot failed'));
      expect(staged(), isEmpty);
    });
  });

  group('vision capability', () {
    test('a text-only model is told the image was NOT attached', () async {
      mockCapture({'captured': true, 'base64': png, 'width': 9, 'height': 9});
      session.model = 'deepseek-chat';

      final out = await shot();
      expect(out, contains('not marked vision-capable'));
      expect(out, contains('was NOT attached'));
      expect(staged(), isEmpty);
      // …and pointed at the tools that DO work without vision.
      expect(out, contains('browser_read'));
      expect(out, contains('browser_outline'));
    });
  });

  group('plan mode may use it', () {
    test('it is in the read-only allowlist and the catalogue', () {
      expect(PlanModePolicy.allowedTools, contains('browser_screenshot'));
      expect(PlanModePolicy.catalogue, contains('browser_screenshot'));
    });

    test('the gate lets it through while planning', () async {
      // The plan gate refuses tools whose IDENTITY is mutating. A capture is
      // not one: no disk write, no page state change. If this ever starts
      // returning "PLAN MODE ACTIVE", the tool stopped being a read and the
      // plan agent lost its only way to see a page.
      mockCapture({'captured': true, 'base64': png, 'width': 2, 'height': 2});
      AgentService.planModeRootForTest = '/tmp/jail';
      addTearDown(() => AgentService.planModeRootForTest = null);
      await CommandService.I.execute('/plan');
      addTearDown(() => CommandService.I.execute('/plan'));

      final out = await shot();
      expect(out, isNot(contains('PLAN MODE ACTIVE')));
      expect(out, contains('attached to the next model request'));
    });
  });
}
