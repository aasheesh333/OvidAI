import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/usage_history.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/usage_page.dart';

void main() {
  test('unknown provider cost and images remain unknown rather than zero', () {
    final run = UsageRunRow.fromJson({
      'runId': 'r1',
      'models': ['auto'],
    });
    expect(run.requestedModels, ['auto']);
    expect(run.providerModels, isNull);
    expect(run.costUsd, isNull);
    expect(run.counts.costUsd, isNull);
    expect(run.costMicros, isNull);
    expect(run.imagesGenerated, isNull);
    expect(run.imagesEdited, isNull);
    expect(formatUsageValue(run.costMicros), '—');
    expect(formatUsageValue(run.imagesGenerated), '—');
    expect(formatUsageCostMicros(run.costMicros), '—');
  });

  test(
    'run measurements retain requested and provider models and real zeros',
    () {
      final run = UsageRunRow.fromJson({
        'runId': 'r1',
        'requestedModels': ['auto', 'reasoning'],
        'providerModels': ['openai/gpt-5', 'openai/gpt-5-mini'],
        'costUsd': '0.0000000001',
        'costMicros': 123456,
        'imagesGenerated': 2,
        'imagesEdited': 1,
      });

      expect(run.requestedModels, ['auto', 'reasoning']);
      expect(run.providerModels, ['openai/gpt-5', 'openai/gpt-5-mini']);
      expect(run.costUsd, '0.0000000001');
      expect(run.counts.costUsd, '0.0000000001');
      expect(run.costMicros, 123456);
      expect(run.imagesGenerated, 2);
      expect(run.imagesEdited, 1);

      final zero = UsageRunRow.fromJson({
        'runId': 'r0',
        'costUsd': '0.0000000000',
        'costMicros': 0,
        'imagesGenerated': 0,
        'imagesEdited': 0,
      });
      expect(zero.costUsd, '0.0000000000');
      expect(zero.costMicros, 0);
      expect(zero.imagesGenerated, 0);
      expect(zero.imagesEdited, 0);
      expect(formatUsageValue(zero.costMicros), '0');
    },
  );

  test('exact cost and nested images stay attached to their DTO buckets', () {
    final history = UsageHistory.fromJson({
      'totals': {
        'runs': 2,
        'modelCalls': 4,
        'inputTokens': 100,
        'outputTokens': 50,
        'costUsd': '0.1000000001',
      },
      'images': {
        'generateCount': 5,
        'editCount': 2,
        'costUsd': '0.2000000001',
      },
      'days': [
        {'date': '2026-10-24', 'costUsd': '0.0000000001'},
      ],
      'models': [
        {'model': 'auto', 'costUsd': '0.1000000000'},
      ],
      'sessions': [
        {
          'sessionId': 's1',
          'title': 'Design',
          'runs': 2,
          'modelCalls': 4,
          'inputTokens': 100,
          'outputTokens': 50,
          'costUsd': '0.1000000001',
          'images': {
            'generateCount': 3,
            'editCount': 1,
            'costUsd': '0.0000000001',
          },
          'lastAt': '2026-10-24T10:00:00.000Z',
        },
        {
          'sessionId': 's2',
          'title': 'No measured images',
          'costUsd': null,
          'images': {
            'generateCount': null,
            'editCount': null,
            'costUsd': null,
          },
          'lastAt': '2026-10-23T10:00:00.000Z',
        },
      ],
      'runs': const [],
    });

    expect(history.totals.costUsd, '0.1000000001');
    expect(history.days.single.counts.costUsd, '0.0000000001');
    expect(history.models.single.counts.costUsd, '0.1000000000');
    expect(history.images.generateCount, 5);
    expect(history.images.editCount, 2);
    expect(history.images.costUsd, '0.2000000001');

    final attributed = history.sessions.first;
    expect(attributed.costUsd, '0.1000000001');
    expect(attributed.counts.costUsd, '0.1000000001');
    expect(attributed.images.generateCount, 3);
    expect(attributed.images.editCount, 1);
    expect(attributed.images.costUsd, '0.0000000001');

    // Global historical images must not be guessed into a session whose image
    // aggregate is unknown. Null historical attribution stays unattributed.
    final unknown = history.sessions.last;
    expect(unknown.costUsd, isNull);
    expect(unknown.images.generateCount, isNull);
    expect(unknown.images.editCount, isNull);
    expect(unknown.images.costUsd, isNull);
  });

  test('legacy costMicros never reconstructs or rounds exact costUsd', () {
    final both = UsageCounts.fromJson(const {
      'costUsd': '0.0000000001',
      'costMicros': 123456,
    });
    final microsOnly = UsageCounts.fromJson(const {'costMicros': 1000000});
    final exactOnly = UsageCounts.fromJson(const {
      'costUsd': '0.0000000001',
    });

    expect(both.costUsd, '0.0000000001');
    expect(both.costMicros, 123456);
    expect(microsOnly.costUsd, isNull);
    expect(microsOnly.costMicros, 1000000);
    expect(exactOnly.costUsd, '0.0000000001');
    expect(exactOnly.costMicros, isNull);
  });

  test('old payloads without additive keys retain legacy measurements', () {
    final history = UsageHistory.fromJson({
      'totals': {
        'runs': 1,
        'modelCalls': 1,
        'inputTokens': 10,
        'outputTokens': 5,
        'costMicros': 1000000,
        'imagesGenerated': 2,
        'imagesEdited': 1,
      },
      'sessions': [
        {
          'sessionId': 'legacy-session',
          'costMicros': 1000000,
          'imagesGenerated': 2,
          'imagesEdited': 1,
        },
      ],
      'runs': [
        {
          'runId': 'legacy-run',
          'models': ['auto'],
          'costMicros': 1000000,
        },
      ],
    });

    expect(history.totals.costUsd, isNull);
    expect(history.totals.costMicros, 1000000);
    expect(history.totals.imagesGenerated, 2);
    expect(history.totals.imagesEdited, 1);
    expect(history.images.generateCount, isNull);
    expect(history.images.editCount, isNull);
    expect(history.images.costUsd, isNull);
    expect(history.sessions.single.costUsd, isNull);
    expect(history.sessions.single.costMicros, 1000000);
    expect(history.sessions.single.images.generateCount, isNull);
    expect(history.sessions.single.imagesGenerated, 2);
    expect(history.runs.single.requestedModels, ['auto']);
    expect(history.runs.single.providerModels, isNull);
    expect(history.runs.single.costUsd, isNull);
    expect(history.runs.single.costMicros, 1000000);
  });

  test('explicit null provider models never fall back to auto', () {
    final run = UsageRunRow.fromJson({
      'runId': 'unknown-provider',
      'models': ['auto'],
      'requestedModels': ['auto'],
      'providerModels': null,
    });

    expect(run.models, ['auto']);
    expect(run.requestedModels, ['auto']);
    expect(run.providerModels, isNull);
  });

  test('missing or malformed session aggregates are unknown, not zero', () {
    final missing = UsageHistory.fromJson(const {});
    final malformed = UsageHistory.fromJson(const {'sessions': 'broken'});
    final badRow = UsageHistory.fromJson(const {
      'sessions': [
        {'title': 'missing id'},
      ],
    });
    final empty = UsageHistory.fromJson(const {'sessions': <Object?>[]});

    expect(missing.sessionsKnown, isFalse);
    expect(malformed.sessionsKnown, isFalse);
    expect(badRow.sessionsKnown, isFalse);
    expect(empty.sessionsKnown, isTrue);
    expect(formatUsageSessionCount(missing), '—');
    expect(formatUsageSessionCount(malformed), '—');
    expect(formatUsageSessionCount(badRow), '—');
    expect(formatUsageSessionCount(empty), '0');
    expect(const V2UsageData(sessionsLabel: '—').measurementsText, '—');
  });

  test('cost formatting is measured USD micros, never inferred INR', () {
    expect(formatUsageCostMicros(null), '—');
    expect(formatUsageCostMicros(0), r'$0.00');
    expect(formatUsageCostMicros(1000000), r'$1.00');
    expect(formatUsageCostMicros(123456), r'$0.123456');
    expect(formatUsageCostMicros(1234567), r'$1.234567');
    expect(formatUsageCostMicros(1234567), isNot(contains('₹')));
  });

  testWidgets('usage renders measured cost, images and session aggregates', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: const UsagePage(
          data: V2UsageData(
            dailyUsedLabel: '150',
            costLabel: r'$0.123456',
            sessionsLabel: '2',
            imagesGeneratedLabel: '3',
            imagesEditedLabel: '1',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(r'$0.123456 · 2 sessions · 3 generated · 1 edited'),
      findsOneWidget,
    );
    expect(find.textContaining('₹'), findsNothing);
  });
}
