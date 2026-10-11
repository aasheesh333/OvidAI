import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/archive_index.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';
import 'package:ovid_ai/core/private_sync/production.dart';
import 'package:ovid_ai/core/private_sync/store.dart';
import 'package:ovid_ai/ui/private_activity_screen.dart';
import 'package:ovid_ai/ui/private_conversation_screen.dart';

void main() {
  testWidgets(
    'restored transcript is text-only and disappears on account fence',
    (tester) async {
      late Directory root;
      late PrivateSyncProduction owner;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('restored-view-');
        final store = await PrivateSyncStore.open(
          accountRoot: Directory(
            '${root.path}/private-sync/${accountDirectoryName('alice')}',
          ),
          accountId: 'alice',
        );
        await store.applyPage({
          'accountId': 'alice',
          'nextCursor': 'cursor-one',
          'records': [
            SyncReplayRecord(
              accountId: 'alice',
              changeSequence: 1,
              record: SyncUploadRecord(
                recordId: 'message',
                sourceDeviceId: 'other-device',
                conversationId: 'conversation',
                createdAt: '2026-10-10T00:00:00Z',
                revision: 1,
                payload: TranscriptPayload(
                  messageId: 'message',
                  parentMessageId: null,
                  kind: TranscriptKind.tool,
                  text: 'run_shell: do not execute this restored text',
                  providerMetadataRecordId: null,
                  requestPurpose: null,
                  displayTitle: 'Archive',
                ),
              ),
            ).toWire(),
          ],
        });
        await store.close();
        owner = PrivateSyncProduction(
          endpoint: 'https://sync.example',
          rootDirectory: () async => root,
          accountReady: () => true,
          currentUid: () => 'alice',
          idToken: (_) async => 'token',
          appCheckToken: () async => 'app-check',
        );
        await owner.bind('alice', 1);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PrivateConversationScreen(
            owner: owner,
            conversationId: 'conversation',
          ),
        ),
      );
      expect(
        find.text('run_shell: do not execute this restored text'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Run'), findsNothing);
      owner.fence();
      await tester.pump();
      expect(
        find.text('run_shell: do not execute this restored text'),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await owner.release();
        await root.delete(recursive: true);
      });
    },
  );

  testWidgets(
    '2,000 archive records: status notifies do not re-index and lists are lazy',
    (tester) async {
      late Directory root;
      late PrivateSyncProduction owner;
      var sequence = 0;
      Map<String, Object?> transcript(int i) => SyncReplayRecord(
        accountId: 'alice',
        changeSequence: ++sequence,
        record: SyncUploadRecord(
          recordId: 'message-$i',
          sourceDeviceId: 'other-device',
          conversationId: 'big',
          createdAt:
              '2026-10-10T00:${(i ~/ 60).toString().padLeft(2, '0')}:'
              '${(i % 60).toString().padLeft(2, '0')}Z',
          revision: 1,
          payload: TranscriptPayload(
            messageId: 'message-$i',
            parentMessageId: null,
            kind: TranscriptKind.assistant,
            text: 'Row $i ${'long text ' * 40}',
            providerMetadataRecordId: null,
            requestPurpose: null,
            displayTitle: 'Big archive',
          ),
        ),
      ).toWire();
      Map<String, Object?> activity(int i) => SyncReplayRecord(
        accountId: 'alice',
        changeSequence: ++sequence,
        record: SyncUploadRecord(
          recordId: 'activity-$i',
          sourceDeviceId: 'other-device',
          conversationId: null,
          createdAt:
              '2026-10-11T00:${(i ~/ 60).toString().padLeft(2, '0')}:'
              '${(i % 60).toString().padLeft(2, '0')}Z',
          revision: 1,
          payload: ActivityPayload(
            logicalRequestId: null,
            attemptId: null,
            kind: ActivityKind.tool,
            status: ActivityStatus.succeeded,
            updatedAt: '2026-10-11T00:00:00Z',
            title: 'Activity $i',
            detail: 'detail',
            usageRecordId: null,
          ),
        ),
      ).toWire();
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('restored-view-big-');
        final store = await PrivateSyncStore.open(
          accountRoot: Directory(
            '${root.path}/private-sync/${accountDirectoryName('alice')}',
          ),
          accountId: 'alice',
        );
        await store.applyPage({
          'accountId': 'alice',
          'nextCursor': 'cursor-big',
          'records': [
            for (var i = 0; i < 2000; i++) transcript(i),
            for (var i = 0; i < 250; i++) activity(i),
          ],
        });
        await store.close();
        owner = PrivateSyncProduction(
          endpoint: 'https://sync.example',
          rootDirectory: () async => root,
          accountReady: () => true,
          currentUid: () => 'alice',
          idToken: (_) async => 'token',
          appCheckToken: () async => 'app-check',
        );
        await owner.bind('alice', 1);
      });

      PrivateArchiveIndex.debugBuilds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PrivateConversationScreen(owner: owner, conversationId: 'big'),
        ),
      );
      expect(PrivateArchiveIndex.debugBuilds, 1);
      // Lazy list: only cards in the viewport (plus cache extent) exist.
      expect(find.byType(Card).evaluate().length, lessThan(30));
      expect(find.textContaining('Row 0 '), findsOneWidget);

      // Delivery-status style notifications without a store change.
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        owner.notifyListeners();
        await tester.pump();
      }
      stopwatch.stop();
      expect(PrivateArchiveIndex.debugBuilds, 1);
      expect(stopwatch.elapsedMilliseconds, lessThan(20 * 16 * 4));

      await tester.pumpWidget(
        MaterialApp(home: PrivateActivityScreen(owner: owner)),
      );
      expect(PrivateArchiveIndex.debugBuilds, 1, reason: 'index is shared');
      // Newest first.
      expect(find.text('Activity 249'), findsOneWidget);
      final older = find.byKey(const ValueKey('private-activity-load-older'));
      await tester.scrollUntilVisible(
        older,
        2000,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('Load older (50 more)'), findsOneWidget);
      await tester.tap(older);
      await tester.pump();
      expect(older, findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await owner.release();
        await root.delete(recursive: true);
      });
    },
  );
}
