import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/startup_coordinator.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/shell.dart';
import 'package:ovid_ai/ui/sidebar.dart';
import 'package:ovid_ai/ui/startup_progress_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _provider = 'A very long enterprise research provider name';
const _model = 'research-model-with-a-long-readable-deployment-name';
const _reason = 'The workspace runtime could not finish preparing. '
    'Reconnect the device, then retry this step without removing your files.';

final class _StartupTask implements StartupTask {
  _StartupTask(this.body);
  final Future<StartupItemStatus> Function() body;
  @override
  String get id => 'review.runtime';
  @override
  String get label => 'Preparing the workspace runtime and installed tools';
  @override
  StartupItemKind get kind => StartupItemKind.plugin;
  @override
  Duration get timeout => const Duration(seconds: 30);
  @override
  StartupDisable? get onDisable => null;
  @override
  Future<StartupItemStatus> run() => body();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState app;
  late bool previousDark;

  setUp(() {
    previousDark = Aether.dark;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentService.I.clearAttachment();
    AgentService.I.clearQueueForTest();
    AgentService.I.runBucketForTest('ui-finish-11').activeRunId = null;
    app.providers.clear();
    app.providers.add(ProviderConfig(
      id: 'review-provider',
      name: _provider,
      description: 'Review fixture',
      baseUrl: 'https://example.test/v1',
      apiKey: 'fixture-key',
      models: [_model, 'gpt-research-long-effort-model', 'other-model'],
      isFree: true,
    ));
    app.sessions.clear();
    app.sessions.add(ChatSession(
      id: 'ui-finish-11',
      title: 'Workspace research with a long conversation title',
      providerId: 'review-provider',
      model: _model,
      mode: 'auto',
      messages: [Message(role: 'assistant', content: 'Ready to help with your workspace.')],
    ));
    app.activeSessionId = 'ui-finish-11';
  });

  tearDown(() {
    Aether.dark = previousDark;
    AgentService.I.runBucketForTest('ui-finish-11').activeRunId = null;
    AgentService.I.clearQueueForTest();
    AgentService.I.clearAttachment();
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
  });

  Future<void> pumpAt(
    WidgetTester tester,
    Widget child, {
    required Size size,
    double scale = 1,
    double keyboard = 0,
    GlobalKey? captureKey,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(MaterialApp(
      theme: Aether.theme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: captureKey, child: child!),
      ),
      home: child,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> reveal(WidgetTester tester, Finder target, Finder scroll, {bool reverse = false}) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (var i = 0; i < 30 && target.hitTestable().evaluate().isEmpty; i++) {
      await tester.drag(scroll, Offset(0, reverse ? 100 : -100));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(target.hitTestable(), findsOneWidget);
  }

  for (final size in [const Size(320, 640), const Size(360, 640), const Size(1024, 768)]) {
    for (final dark in [true, false]) {
      final scale = size.width == 360 ? 2.0 : 1.0;
      testWidgets('chat, long picker names and search at $size ${scale}x dark=$dark', (tester) async {
        Aether.dark = dark;
        app.activeSession!.model = 'other-model';
        final keyboard = size.width == 360 ? 280.0 : 0.0;
        await pumpAt(tester, const OvidShell(), size: size, scale: scale, keyboard: keyboard);
        final field = find.byKey(const ValueKey('chat-composer'));
        expect(tester.widget<TextField>(field).enabled, isTrue);
        await tester.enterText(field, 'A long draft\nwith several lines\nthat stays editable\nabove the keyboard\nand keeps send reachable');
        await tester.pump();
        expect(find.byTooltip('Send').hitTestable(), findsOneWidget);
        expect(tester.getRect(find.byTooltip('Send')).bottom, lessThanOrEqualTo(size.height - keyboard));
        expect(tester.takeException(), isNull);

        await tester.tap(find.byIcon(Icons.unfold_more).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        final search = find.byKey(const ValueKey('model-picker-search'));
        await tester.enterText(search, 'research-model-with');
        await tester.pump();
        final list = find.byKey(const ValueKey('model-picker-list'));
        final target = find.descendant(of: list, matching: find.text(_model));
        await reveal(tester, target, list);
        expect(find.descendant(of: list, matching: find.text('other-model')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(target);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(list, findsNothing);
        expect(app.activeSession!.providerId, 'review-provider');
        expect(app.activeSession!.model, _model);
        expect(tester.widget<TextField>(field).controller!.text, contains('keeps send reachable'));
        await tester.pumpWidget(const SizedBox());
      });
    }
  }

  testWidgets('sidebar remains scrollable with keyboard and filters real sessions', (tester) async {
    app.sessions.add(ChatSession(id: 'other', title: 'Unrelated conversation', model: 'different-model', mode: 'auto'));
    await pumpAt(tester, const Scaffold(body: SessionsSidebar(isDrawer: false)), size: const Size(360, 640), scale: 2, keyboard: 280);
    final search = find.byType(TextField);
    await tester.ensureVisible(search);
    await tester.enterText(search, 'research-model');
    await tester.pump();
    final scrollable = find.descendant(of: find.byType(SessionsSidebar), matching: find.byType(Scrollable)).first;
    final session = find.text('Workspace research with a long conversation title');
    await tester.scrollUntilVisible(session, 150, scrollable: scrollable);
    expect(find.text('Unrelated conversation'), findsNothing);
    await tester.tap(session);
    await tester.pump();
    expect(app.activeSessionId, 'ui-finish-11');
    await tester.scrollUntilVisible(find.text('Settings'), 150, scrollable: scrollable);
    await tester.pump();
    expect(find.text('Settings').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('running composer queues drafts and Stop targets its session', (tester) async {
    final agent = AgentService.I;
    final run = agent.runBucketForTest('ui-finish-11');
    run.activeRunId = 'review-run';
    final other = agent.runBucketForTest('other-review-run');
    other.activeRunId = 'other-active';
    addTearDown(() => other.activeRunId = null);
    await pumpAt(tester, const ChatScreen(), size: const Size(360, 640), scale: 2, keyboard: 280);
    final field = find.byKey(const ValueKey('chat-composer'));
    expect(find.byTooltip('Stop session').hitTestable(), findsOneWidget);
    await tester.enterText(field, 'Queue this draft');
    await tester.pump();
    await tester.tap(find.byTooltip('Add to queue'));
    await tester.pump();
    expect(agent.queuedMessagesFor('ui-finish-11'), ['Queue this draft']);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    // Remove the queued fixture before Stop so this assertion does not start
    // a real continuation/network request.
    agent.removeQueuedMessage(0);
    app.refresh();
    await tester.pump();
    await tester.tap(find.byTooltip('Stop session'));
    await tester.pump();
    expect(agent.busyFor('ui-finish-11'), isFalse);
    expect(agent.busyFor('other-review-run'), isTrue);
    expect(tester.takeException(), isNull);
    AgentNotificationService.I.resetForTest();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('empty picker results scroll above keyboard and effort selection applies', (tester) async {
    await pumpAt(tester, const ChatScreen(), size: const Size(360, 640), scale: 2, keyboard: 280);
    await tester.tap(find.byIcon(Icons.unfold_more).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final search = find.byKey(const ValueKey('model-picker-search'));
    final scroll = find.byKey(const ValueKey('model-picker-list'));
    await tester.enterText(search, 'a query without any matching provider');
    await tester.pump();
    await reveal(tester, find.text('No matches'), scroll);
    expect(find.text('No matches').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await reveal(tester, search, scroll, reverse: true);
    await tester.enterText(search, 'gpt-research');
    await tester.pump();
    final model = find.text('gpt-research-long-effort-model');
    await reveal(tester, model, scroll);
    await tester.tap(model);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('High'), findsOneWidget);
    await reveal(tester, find.text('High'), scroll);
    await tester.tap(find.text('High'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(app.activeSession!.model, 'gpt-research-long-effort-model · High');
    expect(app.activeSession!.providerId, 'review-provider');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('startup progress keeps composer usable and full failure reason readable', (tester) async {
    final gate = Completer<StartupItemStatus>();
    final coordinator = StartupCoordinator.forTest(deadline: const Duration(seconds: 60));
    final task = _StartupTask(() => gate.future);
    final startup = coordinator.start([task]);
    await pumpAt(tester, ChatScreen(startupCoordinator: coordinator), size: const Size(360, 640), scale: 2, keyboard: 280);
    await tester.tap(find.byKey(const ValueKey('startup-panel-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('startup-progress-bar')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('chat-composer')), '/');
    await tester.pump();
    expect(find.byTooltip('Send').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    gate.complete(StartupItemStatus(id: task.id, kind: task.kind, label: task.label, state: StartupItemState.failed, reason: _reason));
    await startup;
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('startup-panel-toggle')));
    await tester.pump();
    final reason = find.text(_reason);
    final text = tester.widget<Text>(reason);
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    final panelScroll = find.ancestor(of: find.byType(StartupProgressPanel), matching: find.byType(SingleChildScrollView)).first;
    await tester.scrollUntilVisible(find.byKey(ValueKey('startup-retry-${task.id}')), 100, scrollable: find.descendant(of: panelScroll, matching: find.byType(Scrollable)).first);
    expect(find.byKey(ValueKey('startup-retry-${task.id}')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    coordinator.dispose();
  });

  testWidgets('cloud retry keeps its key and actual picker capture is opt-in', (tester) async {
    app.providers.insert(0, ProviderConfig(id: 'ovid-cloud', name: 'Ovid Cloud', description: 'Managed', baseUrl: 'https://example.test', models: ['auto']));
    OvidCloudService.I.setConnectionForTest(app, const CloudConnectionState(CloudConnectionStatus.failed, error: 'Connection unavailable. Retry to reconnect your account.'));
    final capture = GlobalKey();
    await pumpAt(tester, const ChatScreen(), size: const Size(360, 640), scale: 2, captureKey: capture);
    await tester.tap(find.byIcon(Icons.unfold_more).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final retry = find.byKey(const ValueKey('cloud-connection-retry'));
    await tester.ensureVisible(retry);
    expect(tester.widget<TextButton>(find.descendant(of: retry, matching: find.byType(TextButton))).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('UI_REVIEW_CAPTURE')) {
      await tester.pump();
      final boundary = capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/opencode/ui-finish-11.png').writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    }
    await tester.pumpWidget(const SizedBox());
  });
}
