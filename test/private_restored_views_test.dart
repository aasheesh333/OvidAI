import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';
import 'package:ovid_ai/core/private_sync/production.dart';
import 'package:ovid_ai/core/private_sync/store.dart';
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
}
