import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/commands.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';
import 'package:ovid_ai/core/private_sync/production.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'private_sync_review_composition_test.dart' show Harness;

// Delay the deletion boundary, then perform the actual production file write.
// Failure is a real on-disk obstruction, not a successful no-op mock.
class _DelayedDeletion extends PrivateSyncProduction {
  _DelayedDeletion(
    Harness h,
    Iterable<SyncUploadRecord> Function(String) snapshot,
  ) : super(
        endpoint: 'https://sync.example',
        rootDirectory: () async => h.root,
        accountReady: () => true,
        currentUid: () => h.uid,
        idToken: (_) async => 'token',
        appCheckToken: () async => 'check',
        httpClientFactory: h.client,
        clock: h.clock,
        snapshot: snapshot,
      );
  final entered = Completer<void>();
  final diskReady = Completer<void>();
  final settled = Completer<void>();
  @override
  Future<void> recordLocalDeletion({
    Set<String> conversationIds = const {},
    Set<String> recordIds = const {},
    String? providerId,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await diskReady.future;
    try {
      await super.recordLocalDeletion(
        conversationIds: conversationIds,
        recordIds: recordIds,
        providerId: providerId,
      );
    } finally {
      if (!settled.isCompleted) settled.complete();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState app;
  late ChatSession session;
  late Directory root;
  late _DelayedDeletion owner;
  final composer = find.byKey(const ValueKey('chat-composer'));

  Future<void> setup() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    AgentNotificationService.I.resetForTest();
    AgentService.I.clearAttachment();
    AgentService.I.clearQueueForTest();
    app.providers
      ..clear()
      ..add(
        ProviderConfig(
          id: 'p',
          name: 'Provider',
          description: '',
          baseUrl: 'https://example.test/v1',
          apiKey: 'key',
          models: ['m'],
        ),
      );
    session = ChatSession(
      id: 'delete-chat',
      title: 'Chat',
      model: 'm',
      providerId: 'p',
      messages: [
        Message(role: 'user', content: 'Original question'),
        Message(role: 'assistant', content: 'Original answer'),
      ],
    );
    app.sessions
      ..clear()
      ..add(session);
    app.activeSessionId = session.id;
    AgentService.I.runBucketForTest(session.id).activeRunId = null;
    app.registerProductionAccountFeatures();
    final snapshot = app.privateSync!.snapshot!;
    root = await Directory.systemTemp.createTemp('sync-chat-deletion-');
    owner = _DelayedDeletion(Harness(root), snapshot);
    app.privateSync = owner;
    await owner.bind('alice', 1);
    await owner.enroll();
    await owner.setForeground(true);
    await owner.refresh();
    await owner.refresh();
    await owner.setForeground(false);
  }

  Future<void> cleanup() async {
    await owner.release();
    await app.flushSessionPersistenceForTest();
    AgentService.I.runBucketForTest(session.id).activeRunId = null;
    AgentNotificationService.I.resetForTest();
    AppState.resetTestInstance();
    await root.delete(recursive: true);
  }

  Future<void> obstructDisk() async {
    final file = File(
      '${root.path}/private-sync/${accountDirectoryName('alice')}/outbox.json',
    );
    await file.delete();
    await Directory(file.path).create();
  }

  test('clear waits for durable deletion before success', () async {
    await setup();
    addTearDown(cleanup);
    CommandService.I.registerBuiltins();
    var completed = false;
    final result = CommandService.I.execute('/clear').then((value) {
      completed = true;
      return value;
    });
    await owner.entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(completed, false);
    expect(session.messages, hasLength(2));
    owner.diskReady.complete();
    expect((await result)!.feedback, 'Session cleared.');
    expect(session.messages, isEmpty);
  });

  test(
    'clear failure returns readable feedback and keeps command draft',
    () async {
      await setup();
      addTearDown(cleanup);
      CommandService.I.registerBuiltins();
      await obstructDisk();
      final result = CommandService.I.execute('/clear');
      await owner.entered.future;
      owner.diskReady.complete();
      final response = (await result)!;
      expect(response.clearInput, false);
      expect(response.feedback, contains('could not'));
      expect(response.feedback, isNot(contains('Original')));
      expect(session.messages, hasLength(2));
    },
  );

  for (final action in [
    'Regenerate',
    'Revert',
    'Edit & resend',
    'Earlier edit',
  ]) {
    testWidgets(
      '$action waits for disk and displays failure without losing draft',
      (tester) async {
        await tester.runAsync(setup);
        if (action == 'Revert' || action == 'Edit & resend') {
          session.messages.removeLast();
        }
        tester.view.physicalSize = const Size(700, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        final runEpoch = AgentService.I.runBucketForTest(session.id).runEpoch;
        if (action == 'Regenerate' || action == 'Revert') {
          await tester.enterText(composer, 'Unsubmitted draft');
        }
        await tester.tap(
          find.byTooltip(action == 'Earlier edit' ? 'Edit & resend' : action),
        );
        if (action == 'Earlier edit') {
          await tester.pumpAndSettle();
          await tester.enterText(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            ),
            'Edited draft',
          );
          await tester.tap(find.widgetWithText(TextButton, 'Edit in composer'));
        }
        await tester.pump();
        expect(owner.entered.isCompleted, true);
        expect(AgentService.I.busyFor(session.id), false);
        expect(AgentService.I.runBucketForTest(session.id).runEpoch, runEpoch);
        expect(
          session.messages.last.content,
          action == 'Revert' || action == 'Edit & resend'
              ? 'Original question'
              : 'Original answer',
        );
        await tester.runAsync(obstructDisk);
        owner.diskReady.complete();
        for (var i = 0; i < 100 && !owner.settled.isCompleted; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(owner.settled.isCompleted, true);
        await tester.pump();
        expect(find.textContaining('could not'), findsOneWidget);
        expect(AgentService.I.busyFor(session.id), false);
        expect(AgentService.I.runBucketForTest(session.id).runEpoch, runEpoch);
        expect(
          tester.widget<TextField>(composer).controller!.text,
          action == 'Earlier edit'
              ? 'Edited draft'
              : action == 'Edit & resend'
              ? 'Original question'
              : 'Unsubmitted draft',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        var cleaned = false;
        final cleaning = cleanup().then((_) => cleaned = true);
        for (var i = 0; i < 100 && !cleaned; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(cleaned, true);
        await cleaning;
      },
    );
  }
}
