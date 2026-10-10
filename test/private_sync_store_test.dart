import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/private_sync/dto.dart';
import 'package:ovid_ai/core/private_sync/protocol.dart';
import 'package:ovid_ai/core/private_sync/store.dart';

class TestPage {
  TestPage({
    required this.accountId,
    required this.cursor,
    required this.records,
  });

  final String accountId;
  final String cursor;
  final List<SyncReplayRecord> records;
}

SyncReplayRecord record(String id, {int revision = 1}) => SyncReplayRecord(
  accountId: 'account-1',
  changeSequence: revision,
  record: SyncUploadRecord(
    recordId: id,
    sourceDeviceId: 'device-1',
    conversationId: null,
    createdAt: '2026-10-08T12:00:00Z',
    revision: revision,
    payload: TranscriptPayload(
      messageId: id,
      parentMessageId: null,
      kind: TranscriptKind.user,
      text: 'private $id',
      providerMetadataRecordId: null,
      requestPurpose: null,
      displayTitle: null,
    ),
  ),
);

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('private-sync-store-');
  });

  tearDown(() => root.delete(recursive: true));

  test('applies a typed page atomically and reopens with its cursor', () async {
    final store = await PrivateSyncStore.open(accountRoot: root);
    await store.applyPage(
      TestPage(
        accountId: 'account-1',
        cursor: 'cursor-1',
        records: [record('one')],
      ),
    );

    expect(store.cursor, 'cursor-1');
    expect(store.records.single.recordId, 'one');
    final reopened = await PrivateSyncStore.open(accountRoot: root);
    expect(reopened.cursor, 'cursor-1');
    expect(reopened.records.single, record('one'));
  });

  test('consumes the shared protocol change-page shape', () async {
    final store = await PrivateSyncStore.open(
      accountRoot: root,
      accountId: 'account-1',
    );
    await store.applyPage(
      SyncChangePage(
        nextCursor: 'protocol-cursor',
        hasMore: false,
        records: [record('protocol')],
      ),
    );
    expect(store.cursor, 'protocol-cursor');
    expect(store.records.single.recordId, 'protocol');
  });

  test('installs accountId from an empty state page', () async {
    final store = await PrivateSyncStore.open(accountRoot: root);
    await store.installState(SyncStatePage(
      accountId: 'account-1',
      currentCursor: '',
      records: const [],
      enrollmentStatus: 'active',
      retentionMarkers: const [],
    ));
    expect(store.accountId, 'account-1');
  });

  test(
    'duplicate page is idempotent and stale revisions do not overwrite',
    () async {
      final store = await PrivateSyncStore.open(accountRoot: root);
      final page = TestPage(
        accountId: 'account-1',
        cursor: 'c1',
        records: [record('one', revision: 2)],
      );
      await store.applyPage(page);
      await store.applyPage(page);
      await store.applyPage(
        TestPage(
          accountId: 'account-1',
          cursor: 'c2',
          records: [record('one', revision: 2)],
        ),
      );
      expect(store.records.single.record.revision, 2);
      expect(store.cursor, 'c2');
      expect(store.revision, 1);
    },
  );

  test('tombstones prevent late records from resurrecting', () async {
    final store = await PrivateSyncStore.open(accountRoot: root);
    await store.applyPage(
      TestPage(accountId: 'account-1', cursor: 'c1', records: [record('gone')]),
    );
    await store.applyPage(
      TestPage(
        accountId: 'account-1',
        cursor: 'c2',
        records: [
          SyncReplayRecord(
            accountId: 'account-1',
            changeSequence: 2,
            record: SyncUploadRecord(
              recordId: 'tombstone-1',
              sourceDeviceId: 'device-1',
              conversationId: null,
              createdAt: '2026-10-08T12:00:00Z',
              revision: 1,
              payload: TombstonePayload(
                targetRecordId: 'gone',
                deletionRevision: 2,
                deletedAt: '2026-10-08T12:00:00Z',
                reason: TombstoneReason.user,
              ),
            ),
          ),
        ],
      ),
    );
    await store.applyPage(
      TestPage(
        accountId: 'account-1',
        cursor: 'c3',
        records: [record('gone', revision: 99)],
      ),
    );
    expect(store.records, isEmpty);
  });

  test('failed persistence leaves cursor and records unchanged', () async {
    var fail = false;
    final store = await PrivateSyncStore.open(
      accountRoot: root,
      writeStagedFile: (file, bytes) async {
        if (fail) throw const FileSystemException('injected');
        await file.writeAsBytes(bytes, flush: true);
      },
    );
    await store.applyPage(
      TestPage(accountId: 'account-1', cursor: 'c1', records: [record('one')]),
    );
    fail = true;
    await expectLater(
      store.applyPage(
        TestPage(
          accountId: 'account-1',
          cursor: 'c2',
          records: [record('two')],
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.cursor, 'c1');
    expect(store.records.single.recordId, 'one');
    expect((await PrivateSyncStore.open(accountRoot: root)).cursor, 'c1');
  });

  test('owner fencing rejects stale writes', () async {
    var owned = true;
    final store = await PrivateSyncStore.open(
      accountRoot: root,
      ownerFence: () => owned,
    );
    owned = false;
    await expectLater(
      store.applyPage(
        TestPage(
          accountId: 'account-1',
          cursor: 'c1',
          records: [record('one')],
        ),
      ),
      throwsStateError,
    );
  });
}
