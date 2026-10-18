import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/studio_pty.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_drafts.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_editor.dart';
import 'package:ovid_ai/ui/studio_screen.dart';
import 'package:ovid_ai/ui/studio_terminal_tabs.dart';

import 'support/studio_fake_gateway.dart';

/// Studio drafts and file safety, re-pointed at the P7 workspace API.
///
/// The local `RepoCache` half of the old file is gone; the surviving
/// contracts are draft persistence/restore, binary/large-file guards (now
/// enforced from the server response) and controller pruning.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStudioGateway fake;
  late StudioRemoteClient remote;

  WsMultiplexer idleWs() => WsMultiplexer(
        mintTicket: () async => 'ticket',
        heartbeatInterval: const Duration(hours: 1),
        pongTimeout: const Duration(hours: 1),
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    StudioDraftStore.I.disableForTest();
    studioLoginPromptOverrideForTest = (_) {};
    studioPtyChannelFactoryOverrideForTest = (sessionId, tabId) =>
        CloudPtyChannel(
          sessionId: sessionId,
          tabId: tabId,
          ws: idleWs(),
          rawFramesOverride: const Stream<Map<String, dynamic>>.empty(),
          sendOverride: (_) async {},
        );
    fake = FakeStudioGateway();
    remote = installFakeStudio(fake);
  });

  tearDown(() {
    studioLoginPromptOverrideForTest = null;
    studioPtyChannelFactoryOverrideForTest = null;
    StudioDraftStore.I.disableForTest();
    remote.clearAll();
    AppState.resetTestInstance();
  });

  void setSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// StudioScreen keeps indeterminate progress animations alive, so
  /// pumpAndSettle never returns there; pump a bounded series of frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  TextEditingController controller(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(studioEditorFieldKey)).controller!;

  group('F-071 drafts survive process death', () {
    testWidgets('editor drafts are persisted and restored after process death',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('studio-drafts-');
      addTearDown(() => dir.deleteSync(recursive: true));
      StudioDraftStore.I.enable(root: () async => dir);

      fake.files['notes.txt'] = 'saved';
      await remote.openStudioFile(kFakeStudioSession, 'notes.txt');
      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: StudioEditor(sessionId: kFakeStudioSession),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(studioEditorFieldKey), 'unsaved work');
      await tester.pump();
      // App paused: pending drafts are written now.
      await tester.runAsync(() => StudioDraftStore.I.flush());

      // Process death: the in-memory client (and its buckets) is gone.
      await tester.pumpWidget(const SizedBox());
      remote = installFakeStudio(fake, drafts: StudioDraftStore.I);

      // The first access recreates the bucket and starts the async restore.
      await tester.runAsync(() async {
        expect(remote.fileBuffer(kFakeStudioSession)['notes.txt'], isNull);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();

      expect(remote.fileBuffer(kFakeStudioSession)['notes.txt'], 'unsaved work');
      expect(remote.isStudioFileDirty(kFakeStudioSession, 'notes.txt'), isTrue);
      expect(remote.activeFilePath(kFakeStudioSession), 'notes.txt');
    });

    testWidgets('back with a draft asks first; Discard restores the saved text',
        (tester) async {
      final app = AppState.createForTest();
      app.sessions.add(ChatSession(
        id: kFakeStudioSession,
        title: 'Studio',
        model: 'gpt-4o',
      ));
      app.activeSessionId = kFakeStudioSession;
      fake.files['lib/a.dart'] = 'void a() {}';
      await remote.openStudioFile(kFakeStudioSession, 'lib/a.dart');
      setSurface(tester, const Size(1000, 800));

      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        theme: Aether.theme(),
        home: const Scaffold(body: Text('home')),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const StudioScreen(),
      ));
      await settle(tester);

      await tester.enterText(find.byKey(studioEditorFieldKey), 'my draft');
      await tester.pump();
      expect(find.text('UNSAVED'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('Leave Studio with unsaved changes?'), findsOneWidget);
      expect(find.byType(StudioScreen), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(controller(tester).text, 'my draft');

      await tester.binding.handlePopRoute();
      await settle(tester);
      await tester.tap(find.text('Discard'));
      await settle(tester);
      expect(find.byType(StudioScreen), findsNothing);

      nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const StudioScreen(),
      ));
      await settle(tester);
      expect(controller(tester).text, 'void a() {}');
      expect(find.text('SAVED'), findsOneWidget);
      expect(remote.dirtyFiles(kFakeStudioSession), isEmpty);
    });
  });

  group('F-072 compact panel toggle keeps the editor', () {
    testWidgets('360x740: toggling the folder panel twice keeps state + UNSAVED',
        (tester) async {
      final app = AppState.createForTest();
      app.sessions.add(ChatSession(
        id: kFakeStudioSession,
        title: 'Studio',
        model: 'gpt-4o',
      ));
      app.activeSessionId = kFakeStudioSession;
      fake.files['lib/a.dart'] = 'void a() {}';
      await remote.openStudioFile(kFakeStudioSession, 'lib/a.dart');
      setSurface(tester, const Size(360, 740));

      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const StudioScreen()),
      );
      await settle(tester);
      await tester.enterText(find.byKey(studioEditorFieldKey), 'typed');
      await tester.pump();
      final before = tester.state<EditableTextState>(find.descendant(
        of: find.byKey(studioEditorFieldKey),
        matching: find.byType(EditableText),
      ));

      await tester.tap(find.byTooltip('Toggle files'));
      await settle(tester);
      expect(find.byType(StudioFileTree), findsOneWidget);
      await tester.tap(find.byTooltip('Toggle files'));
      await settle(tester);

      final after = tester.state<EditableTextState>(find.descendant(
        of: find.byKey(studioEditorFieldKey),
        matching: find.byType(EditableText),
      ));
      expect(identical(before, after), isTrue);
      expect(find.text('UNSAVED'), findsOneWidget);
      expect(controller(tester).text, 'typed');
    });
  });

  group('terminal session binding and resize (M1/M4)', () {
    testWidgets('switching session recreates terminals for the new session',
        (tester) async {
      final created = <String>[];
      final channels = <CloudPtyChannel>[];
      studioPtyChannelFactoryOverrideForTest = (sessionId, tabId) {
        created.add(sessionId);
        final channel = CloudPtyChannel(
          sessionId: sessionId,
          tabId: tabId,
          ws: idleWs(),
          rawFramesOverride: const Stream<Map<String, dynamic>>.empty(),
          sendOverride: (_) async {},
        );
        channels.add(channel);
        return channel;
      };

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: StudioTerminalTabs(sessionId: 'a'),
          ),
        ),
      ));
      await tester.pump();
      expect(created, ['a']);

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: StudioTerminalTabs(sessionId: 'b'),
          ),
        ),
      ));
      await tester.pump();

      expect(created.last, 'b',
          reason: 'existing tabs must rebind to the new session');
      expect(channels.first.closed, isTrue,
          reason: 'the old session channel must not keep sending to A');
    });

    testWidgets('the terminal pane reports its real cols/rows', (tester) async {
      final resizes = <(int, int)>[];
      studioPtyChannelFactoryOverrideForTest = (sessionId, tabId) =>
          _RecordingChannel(
            sessionId: sessionId,
            tabId: tabId,
            ws: idleWs(),
            onResize: (cols, rows) => resizes.add((cols, rows)),
          );

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: StudioTerminalTabs(sessionId: 's1'),
          ),
        ),
      ));
      await tester.pump();

      expect(resizes, isNotEmpty,
          reason: 'resize was implemented but never wired');
      final (cols, rows) = resizes.last;
      expect(cols, greaterThan(20));
      expect(rows, greaterThanOrEqualTo(4));
      expect(cols, lessThan(500));
    });
  });

  group('binary files', () {
    test('content sniffing', () {
      expect(looksBinaryBytes([0x50, 0x4b, 0x00, 0x03]), isTrue);
      expect(looksBinaryBytes(utf8.encode('plain text')), isFalse);
      expect(looksBinaryText('ab\u0000cd'), isTrue);
      expect(looksBinaryText('��ab'), isTrue);
      expect(looksBinaryText('héllo wörld'), isFalse);
    });

    test('a guarded file cannot be saved', () async {
      fake.files['app.db'] = 'SQLite format 3\u0000\u0001';
      await remote.openStudioFile(kFakeStudioSession, 'app.db');
      expect(remote.guardFor(kFakeStudioSession, 'app.db')?.binary, isTrue);
      await expectLater(
        remote.saveStudioFile(kFakeStudioSession, 'app.db'),
        throwsA(isA<StateError>()),
      );
      expect(fake.putCalls, 0);
    });

    testWidgets('a file with NUL bytes opens the binary placeholder',
        (tester) async {
      fake.files['data.db'] = 'SQLite format 3\u0000\u0001';
      await remote.openStudioFile(kFakeStudioSession, 'data.db');
      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: StudioEditor(sessionId: kFakeStudioSession),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Binary file — not editable'), findsOneWidget);
      expect(find.byKey(studioEditorFieldKey), findsNothing);
      expect(find.text('BINARY'), findsOneWidget);
    });
  });

  group('F-076 large files', () {
    testWidgets('a 3 MB redirect opens too-large WITHOUT downloading',
        (tester) async {
      fake.redirectPaths['big.txt'] = 3 * 1024 * 1024;
      await remote.openStudioFile(kFakeStudioSession, 'big.txt');

      // MEDIUM-5: the declared size arrives before the presigned body.
      expect(fake.downloadCalls, 0,
          reason: 'a too-large file must never be downloaded');
      expect(remote.guardFor(kFakeStudioSession, 'big.txt')?.kind,
          StudioFileGuardKind.tooLarge);

      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: StudioEditor(sessionId: kFakeStudioSession),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Too large to open on device'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(remote.fileBuffer(kFakeStudioSession)['big.txt'], isEmpty,
          reason: 'the content is never loaded into the editor');
    });

    testWidgets('a 300 KB file opens read-only; Edit anyway gives a field',
        (tester) async {
      final text = List.generate(30000, (i) => 'line $i').join('\n');
      expect(text.length, greaterThan(kStudioViewerThreshold));
      expect(text.length, lessThan(kStudioEditHardCap));
      fake.files['gen.txt'] = text;
      await remote.openStudioFile(kFakeStudioSession, 'gen.txt');

      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: StudioEditor(sessionId: kFakeStudioSession),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(studioEditorFieldKey), findsNothing);
      expect(find.text('READ-ONLY'), findsOneWidget);
      expect(find.text('line 0'), findsOneWidget);
      await tester.tap(find.text('Edit anyway'));
      await tester.pumpAndSettle();
      expect(find.byKey(studioEditorFieldKey), findsOneWidget);
      expect(find.text('SAVED'), findsOneWidget);
    });
  });

  group('F-077 controllers are pruned', () {
    testWidgets('closing a clean tab drops its field', (tester) async {
      fake.files['a.txt'] = 'A';
      fake.files['b.txt'] = 'B';
      await remote.openStudioFile(kFakeStudioSession, 'a.txt');
      await remote.openStudioFile(kFakeStudioSession, 'b.txt');
      await tester.pumpWidget(MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(
          body: StudioEditor(sessionId: kFakeStudioSession),
        ),
      ));
      await tester.pumpAndSettle();
      remote.selectStudioFile(kFakeStudioSession, 'a.txt');
      await tester.pumpAndSettle();
      expect(
        find.byKey(studioEditorFieldKey, skipOffstage: false),
        findsNWidgets(2),
      );
      remote.closeStudioFile(kFakeStudioSession, 'b.txt');
      await tester.pumpAndSettle();
      expect(
        find.byKey(studioEditorFieldKey, skipOffstage: false),
        findsOneWidget,
      );
      expect(controller(tester).text, 'A');
    });
  });
}

class _RecordingChannel extends CloudPtyChannel {
  _RecordingChannel({
    required super.sessionId,
    required super.tabId,
    required super.ws,
    required this.onResize,
  }) : super(
          rawFramesOverride: const Stream<Map<String, dynamic>>.empty(),
          sendOverride: (_) async {},
        );

  final void Function(int cols, int rows) onResize;

  @override
  void resize(int cols, int rows) => onResize(cols, rows);
}
