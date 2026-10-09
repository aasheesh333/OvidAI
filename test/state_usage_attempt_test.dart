import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/usage_attempt.dart';
import 'package:ovid_ai/core/usage_attempt_store.dart';

UsageEntry legacy() => UsageEntry(
  time: DateTime.utc(2026, 10, 8),
  providerId: 'custom',
  providerName: 'Custom',
  model: 'model',
  promptTokens: 3,
  completionTokens: 0,
  totalTokens: 3,
  duration: const Duration(seconds: 1),
);

UsageAttempt attempt(String id, {int revision = 1, int tokens = 3}) =>
    UsageAttempt(
      attemptId: id,
      requestId: 'request-$id',
      revision: revision,
      sourceDevice: 'device',
      provider: 'custom',
      requestedModel: 'model',
      purpose: 'chat',
      startedAt: DateTime.utc(2026, 10, 8),
      dispatchStage: UsageDispatchStage.completed,
      outcome: UsageOutcome.succeeded,
      inputTokens: UsageTokenCount.reported(tokens),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppState app;
  var allowanceRequests = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('state-usage-');
    SessionSearch.dbPathOverrideForTest = '${root.path}/search.db';
    app = AppState.createForTest(usageRoot: root);
    allowanceRequests = 0;
    OvidCloudService.idTokenOverrideForTest = () async => 'test';
    OvidCloudService.httpClientFactoryForTest = () => MockClient((_) async {
      allowanceRequests++;
      return http.Response(
        '{"tier":"free","remaining_pct":0.73,"models":[]}',
        200,
      );
    });
  });
  tearDown(() async {
    await SessionSearch.I.close();
    SessionSearch.dbPathOverrideForTest = null;
    AppState.resetTestInstance();
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    await root.delete(recursive: true);
  });

  test(
    'duplicate legacy rows migrate once with durable distinct IDs',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('ovid_usage_log', [
        jsonEncode(legacy().toJson()),
        jsonEncode(legacy().toJson()),
      ]);
      final owner = app.sessionAccountToken;
      final first = app.prepareUsageAttempts(owner: owner);
      expect(identical(first, app.prepareUsageAttempts(owner: owner)), isTrue);
      await first;
      expect(app.usageAttempts.length, 2);
      final ids = app.usageAttempts.map((a) => a.attemptId).toSet();
      expect(ids.length, 2);
      expect(
        app.usageAttempts.map((a) => a.inputTokens!.provenance),
        everyElement(UsageProvenance.legacyUnspecified),
      );
      expect(app.usageAttempts.map((a) => a.outputTokens!.value), [0, 0]);
      expect(app.usageLog.length, 2);
      AppState.resetTestInstance();
      app = AppState.createForTest(usageRoot: root);
      await app.prepareUsageAttempts(owner: app.sessionAccountToken);
      expect(app.usageAttempts.map((a) => a.attemptId).toSet(), ids);
    },
  );

  test('later legacy appends survive migration and restart', () async {
    final owner = app.sessionAccountToken;
    await app.prepareUsageAttempts(owner: owner);
    app.appendUsage(legacy(), owner: owner);
    app.appendUsage(legacy(), owner: owner);
    await app.flushUsage(owner: owner);
    expect(app.usageAttempts.length, 2);
    final journal = await root
        .list(recursive: true)
        .where((e) => e is File && e.path.endsWith('usage_attempts.json'))
        .single;
    final reopened = await UsageAttemptStore.open(accountRoot: journal.parent);
    expect(reopened.snapshot.length, 2);
    AppState.resetTestInstance();
    app = AppState.createForTest(usageRoot: root);
    await app.prepareUsageAttempts(owner: app.sessionAccountToken);
    expect(app.usageAttempts.length, 2);
    expect(app.usageLog.length, 2);
  });

  test(
    'same-count changed legacy content imports once without collapsing duplicates',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final row = jsonEncode(legacy().toJson());
      await prefs.setStringList('ovid_usage_log', [row, row]);
      await app.prepareUsageAttempts();
      final changed = jsonEncode({...legacy().toJson(), 'pt': 8, 'tt': 8});
      await prefs.setStringList('ovid_usage_log', [row, changed]);
      await app.prepareUsageAttempts();
      expect(app.usageAttempts.length, 3);
      expect(app.usageAttempts.map((e) => e.inputTokens!.value), contains(8));
      final revision = app.usageRevision;
      await app.prepareUsageAttempts();
      expect(app.usageAttempts.length, 3);
      expect(app.usageRevision, revision);
    },
  );

  test(
    'account hydration reports explicit journal errors even with no legacy rows',
    () async {
      final blocked = File('${root.path}/blocked');
      await blocked.writeAsString('not a directory');
      AppState.resetTestInstance();
      app = AppState.createForTest(usageRoot: Directory(blocked.path));
      await expectLater(
        app.transitionSessionAccount('firebase:B'),
        throwsA(isA<FileSystemException>()),
      );
      expect(app.usageStorageError, isA<FileSystemException>());
    },
  );

  test(
    'legacy append without a journal root needs no native path provider',
    () async {
      AppState.resetTestInstance();
      app = AppState.createForTest();
      app.appendUsage(legacy());
      await app.flushUsage(owner: app.sessionAccountToken);
      expect(app.usageStorageError, isNull);
      expect(
        (await SharedPreferences.getInstance()).getStringList('ovid_usage_log'),
        hasLength(1),
      );
    },
  );

  test(
    'durable revisions update immutable snapshots without insertion',
    () async {
      final owner = app.sessionAccountToken;
      expect(await app.recordUsageAttempt(attempt('a'), owner: owner), isTrue);
      final before = app.usageAttempts;
      final revision = app.usageRevision;
      expect(await app.recordUsageAttempt(attempt('a'), owner: owner), isFalse);
      expect(app.usageRevision, revision);
      await app.recordUsageAttempt(
        attempt('a', revision: 2, tokens: 9),
        owner: owner,
      );
      expect(app.usageRevision, greaterThan(revision));
      expect(app.usageAttempts.single.inputTokens!.value, 9);
      expect(before.single.inputTokens!.value, 3);
      expect(() => before.clear(), throwsUnsupportedError);
    },
  );

  test(
    'same UID epoch rejects an old recorder and invalidates open future',
    () async {
      await app.transitionSessionAccount('firebase:private/uid');
      final old = app.sessionAccountToken;
      await app.recordUsageAttempt(attempt('a'), owner: old);
      final opening = app.prepareUsageAttempts(owner: old);
      await app.transitionSessionAccount('firebase:private/uid');
      expect(identical(old, app.sessionAccountToken), isFalse);
      await expectLater(
        app.recordUsageAttempt(attempt('stale'), owner: old),
        throwsStateError,
      );
      final next = app.prepareUsageAttempts(owner: app.sessionAccountToken);
      expect(identical(opening, next), isFalse);
      await next;
      expect(app.usageAttempts.map((a) => a.attemptId), ['a']);
      final paths = await root
          .list(recursive: true)
          .map((e) => e.path)
          .toList();
      expect(
        paths.any((p) => p.contains('private') || p.contains('firebase:')),
        isFalse,
      );
    },
  );

  test(
    'switch during queued open cannot publish or write into replacement account',
    () async {
      final owner = app.sessionAccountToken;
      final opening = app.prepareUsageAttempts(owner: owner);
      await app.transitionSessionAccount('firebase:B');
      try {
        await opening;
      } catch (_) {
        // A slow native open is fenced; a fast open is harmless because the
        // transition clears the published store before B is hydrated.
      }
      await app.recordUsageAttempt(
        attempt('b'),
        owner: app.sessionAccountToken,
      );
      expect(app.usageAttempts.map((a) => a.attemptId), ['b']);
      await app.transitionSessionAccount('guest');
      await app.prepareUsageAttempts(owner: app.sessionAccountToken);
      expect(app.usageAttempts, isEmpty);
    },
  );

  test('open failures surface and permit a later retry', () async {
    final file = File('${root.path}/blocked');
    await file.writeAsString('not a directory');
    AppState.resetTestInstance();
    app = AppState.createForTest(usageRoot: Directory(file.path));
    final owner = app.sessionAccountToken;
    await expectLater(
      app.prepareUsageAttempts(owner: owner),
      throwsA(isA<FileSystemException>()),
    );
    expect(app.usageStorageError, isNotNull);
    expect(app.usageAttempts, isEmpty);
    await file.delete();
    await app.recordUsageAttempt(attempt('recovered'), owner: owner);
    expect(app.usageStorageError, isNull);
    expect(app.usageAttempts.single.attemptId, 'recovered');
  });

  testWidgets(
    'local activity never refetches allowance but configuration still does',
    (tester) async {
      final owner = app.sessionAccountToken;
      await tester.runAsync(
        () => app.recordUsageAttempt(attempt('a'), owner: owner),
      );
      final cloud = CloudUsageStore.acquire(app);
      await tester.runAsync(() async {
        cloud.usage = await cloud.service.fetchUsage(throwOnError: true);
        cloud.stale = false;
      });
      await tester.pump();
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(cloud.usage!.remainingPct, 0.73);
      expect(cloud.stale, isFalse);
      await tester.pump();
      final revision = app.usageRevision;
      await tester.runAsync(
        () => app.recordUsageAttempt(
          attempt('a', revision: 2, tokens: 999999),
          owner: owner,
        ),
      );
      expect(app.usageRevision, greaterThan(revision));
      expect(cloud.stale, isFalse);
      expect(cloud.usage!.remainingPct, 0.73);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(cloud.stale, isFalse);
      final requests = allowanceRequests;
      app.usageLog.addAll([legacy(), legacy()]);
      app.refresh();
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(cloud.stale, isFalse);
      app.usageLog[0] = legacy();
      app.refresh();
      expect(cloud.stale, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(allowanceRequests, requests);
      app.setOvidCloudTier('3x');
      await tester.pump();
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.runAsync(() async {
        cloud.usage = await cloud.service.fetchUsage(throwOnError: true);
        cloud.stale = false;
      });
      expect(allowanceRequests, greaterThan(requests));
      cloud.release();
      await tester.pump();
    },
  );
}
