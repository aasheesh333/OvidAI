import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_drafts.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_file_tree.dart';
import 'package:ovid_ai/ui/studio_layout.dart';
import 'package:ovid_ai/ui/studio_screen.dart';

import 'support/studio_fake_gateway.dart';

// Wave 2 Studio screen behaviour against the faked cloud workspace. Finding
// ids from docs/audit-2026-10-19/02-studio.md.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStudioGateway fake;
  late StudioRemoteClient remote;
  late StreamController<CloudSessionEvent> events;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    StudioDraftStore.I.disableForTest();
    final app = AppState.createForTest();
    app.sessions.add(ChatSession(id: 'chat-1', title: 'Chat', model: 'm'));
    app.activeSessionId = 'chat-1';
    events = StreamController<CloudSessionEvent>.broadcast();
  });

  tearDown(() async {
    remote.clearAll();
    await events.close();
    AppState.resetTestInstance();
  });

  void install(FakeStudioGateway gateway) {
    fake = gateway;
    remote = installFakeStudio(
      fake,
      wakePollInterval: const Duration(seconds: 1),
      agentRefreshDebounce: const Duration(milliseconds: 300),
    );
  }

  Future<void> pumpStudio(WidgetTester tester,
      {Size size = const Size(1200, 900)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: Aether.theme(),
      home: StudioScreen(
        workspaceKey: kFakeStudioSession,
        agentEvents: events.stream,
      ),
    ));
    await settle(tester);
  }

  CloudSessionEvent event(String type, [Map<String, dynamic>? payload]) =>
      CloudSessionEvent(
        sessionId: 'srv-chat',
        seq: '${DateTime.now().microsecondsSinceEpoch}-0',
        type: type,
        payload: payload ?? const <String, dynamic>{},
        ts: DateTime.utc(2026, 10, 19),
      );

  group('ST-004 / ST-011 / ST-018: no GitHub, no terminal', () {
    testWidgets('opening Studio never prompts for GitHub and shows no '
        'terminal or sandbox copy', (tester) async {
      install(FakeStudioGateway());
      await pumpStudio(tester);

      expect(find.textContaining('GitHub'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.textContaining('erminal'), findsNothing);
      expect(find.textContaining('andbox'), findsNothing);
    });

    testWidgets('the read-only agent activity log replaces the terminal',
        (tester) async {
      install(FakeStudioGateway());
      await pumpStudio(tester);

      final log = find.byKey(studioAgentLogKey);
      expect(log, findsOneWidget);
      expect(find.byTooltip('Agent activity'), findsOneWidget);
    });
  });

  group('ST-009 / ST-010: one inline error surface with human copy', () {
    testWidgets('a failed load shows ONE strip, no toast, no raw exception; '
        'Retry recovers', (tester) async {
      install(FakeStudioGateway(
        files: {'a.txt': 'x'},
        roots: const [FakeNode.file('a.txt')],
      )..treeError = (503, 'unavailable'));
      await pumpStudio(tester);

      expect(find.byKey(studioStatusErrorKey), findsOneWidget);
      expect(
          find.text('Your cloud workspace is temporarily unavailable. Try '
              'again in a moment.'),
          findsOneWidget);
      expect(find.byType(SnackBar), findsNothing,
          reason: 'a tree load failure must not ALSO toast');
      expect(find.textContaining('CloudApiException'), findsNothing);
      expect(find.textContaining('details are below'), findsNothing);
      expect(find.textContaining('Could not load the workspace tree'),
          findsNothing,
          reason: 'the tree no longer repeats the error');

      fake.treeError = null;
      await tester.tap(find.text('Retry'));
      await settle(tester);

      expect(find.byKey(studioStatusErrorKey), findsNothing);
      expect(find.text('a.txt'), findsOneWidget);
    });

    testWidgets('signed out maps to "Sign in to use Studio."', (tester) async {
      install(FakeStudioGateway()..treeError = (401, 'unauthenticated'));
      await pumpStudio(tester);
      expect(find.text('Sign in to use Studio.'), findsOneWidget);
    });

    testWidgets('only ONE refresh affordance (ST-019)', (tester) async {
      install(FakeStudioGateway());
      await pumpStudio(tester);
      expect(find.byTooltip('Refresh files'), findsOneWidget);
      expect(find.byTooltip('Refresh workspace'), findsNothing);
    });
  });

  group('ST-013: a cold workspace wakes with progress', () {
    testWidgets('cold → "Waking…" strip + hydrate; warm → files', (tester) async {
      install(FakeStudioGateway(
        files: {'a.txt': 'x'},
        roots: const [FakeNode.file('a.txt')],
      )..state = 'cold');
      await pumpStudio(tester);

      expect(find.byKey(studioStatusWakeKey), findsOneWidget);
      expect(find.textContaining('Waking your workspace'), findsOneWidget);
      expect(fake.hydrateCalls, 1);

      fake.state = 'warm';
      await tester.pump(const Duration(seconds: 1));
      await settle(tester);

      expect(find.byKey(studioStatusWakeKey), findsNothing);
      expect(find.text('a.txt'), findsOneWidget);
    });
  });

  group('ST-006: live updates from agent events', () {
    testWidgets('an agent write refreshes the open file and the tree',
        (tester) async {
      install(FakeStudioGateway(
        files: {'a.txt': 'v1'},
        roots: [const FakeNode.file('a.txt')],
      ));
      await remote.openStudioFile(kFakeStudioSession, 'a.txt');
      await pumpStudio(tester);
      expect(remote.fileBuffer(kFakeStudioSession)['a.txt'], 'v1');

      fake.files['a.txt'] = 'v2 from the agent';
      fake.files['new.txt'] = 'n';
      fake.roots.add(const FakeNode.file('new.txt'));
      events.add(event('tool_completed', {'name': 'write_file'}));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);

      expect(remote.fileBuffer(kFakeStudioSession)['a.txt'],
          'v2 from the agent');
      expect(find.text('new.txt'), findsOneWidget);
    });
  });

  group('ST-008: file management from the tree', () {
    testWidgets('long-press → Delete asks first, then deletes on the server',
        (tester) async {
      install(FakeStudioGateway(
        files: {'README.md': '# hi', 'b.txt': 'b'},
        roots: [
          const FakeNode.file('README.md'),
          const FakeNode.file('b.txt'),
        ],
      ));
      await pumpStudio(tester);

      await tester.longPress(find.text('README.md'));
      await settle(tester);
      expect(find.text('Rename or move'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await settle(tester);

      expect(find.text('Delete README.md?'), findsOneWidget);
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      fake.roots.removeWhere((n) => n.path == 'README.md');
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await settle(tester);

      expect(fake.files.containsKey('README.md'), isFalse);
      expect(find.text('Deleted README.md'), findsOneWidget);
    });

    testWidgets('New file validates inline and opens an existing file instead '
        'of blanking it (ST-005)', (tester) async {
      install(FakeStudioGateway(
        files: {'README.md': '# real'},
        roots: const [FakeNode.file('README.md')],
      ));
      await pumpStudio(tester);

      await tester.tap(find.byKey(studioTreeNewFileKey));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, '../escape.txt');
      await tester.tap(find.text('Create'));
      await settle(tester);
      expect(find.textContaining('no ".."'), findsOneWidget,
          reason: 'the dialog explains the bad path instead of sending it');

      await tester.enterText(find.byType(TextField).last, 'README.md');
      await tester.tap(find.text('Create'));
      await settle(tester);

      expect(find.text('README.md already exists — opened it.'), findsOneWidget);
      expect(remote.fileBuffer(kFakeStudioSession)['README.md'], '# real');
      expect(fake.putCalls, 0);
    });

    testWidgets('a pruned folder offers "Show N more" and loads it (ST-015)',
        (tester) async {
      install(FakeStudioGateway(roots: const [FakeNode.pruned('big', 2)])
        ..subtrees['big'] = const [
          FakeNode.file('big/inner.ts'),
          FakeNode.file('big/other.ts'),
        ]);
      await pumpStudio(tester);

      await tester.tap(find.text('big'));
      await settle(tester);
      expect(find.text('Show 2 more items'), findsOneWidget,
          reason: 'a pruned folder must not just open empty');

      await tester.tap(find.text('Show 2 more items'));
      await settle(tester);

      expect(find.text('inner.ts'), findsOneWidget);
      expect(find.text('other.ts'), findsOneWidget);
      expect(find.text('Show 2 more items'), findsNothing);
      expect(fake.log, contains('GET /cloud/v1/sessions/$kFakeStudioSession/workspace/tree?path=big'));
    });
  });

  group('ST-019 / ST-020: compact layout and accessibility', () {
    testWidgets('a 360dp phone keeps the editor header on one row with an '
        'overflow, and nothing overflows', (tester) async {
      install(FakeStudioGateway(
        files: {'lib/a.dart': 'void a() {}'},
        roots: const [FakeNode.file('lib/a.dart')],
      ));
      await remote.openStudioFile(kFakeStudioSession, 'lib/a.dart');
      await pumpStudio(tester, size: const Size(360, 640));

      expect(tester.takeException(), isNull);
      expect(find.byTooltip('More editor actions'), findsOneWidget);
      expect(find.byTooltip('Undo'), findsNothing,
          reason: 'undo/redo/find live in the overflow on a phone');
    });

    testWidgets('tabs announce their position', (tester) async {
      install(FakeStudioGateway(files: {'a.txt': 'a', 'b.txt': 'b'}));
      await remote.openStudioFile(kFakeStudioSession, 'a.txt');
      await remote.openStudioFile(kFakeStudioSession, 'b.txt');
      await pumpStudio(tester);

      final labels = tester
          .widgetList<StudioTapTarget>(find.byType(StudioTapTarget))
          .map((t) => t.label ?? '')
          .toList();
      expect(labels, contains('a.txt, tab 1 of 2'));
      expect(labels, contains('b.txt, tab 2 of 2, active'));
    });

    testWidgets('tree rows use at least 13px type', (tester) async {
      install(FakeStudioGateway(roots: const [FakeNode.file('a.txt')]));
      await pumpStudio(tester);
      final text = tester.widget<Text>(find.descendant(
        of: find.byType(StudioFileTree),
        matching: find.text('a.txt'),
      ));
      expect(text.style!.fontSize, greaterThanOrEqualTo(13));
    });
  });
}

/// StudioScreen can keep a progress indicator animating; pump a bounded
/// series of frames instead of pumpAndSettle.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
