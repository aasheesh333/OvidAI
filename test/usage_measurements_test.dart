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
        'costMicros': 123456,
        'imagesGenerated': 2,
        'imagesEdited': 1,
      });

      expect(run.requestedModels, ['auto', 'reasoning']);
      expect(run.providerModels, ['openai/gpt-5', 'openai/gpt-5-mini']);
      expect(run.costMicros, 123456);
      expect(run.imagesGenerated, 2);
      expect(run.imagesEdited, 1);

      final zero = UsageRunRow.fromJson({
        'runId': 'r0',
        'costMicros': 0,
        'imagesGenerated': 0,
        'imagesEdited': 0,
      });
      expect(zero.costMicros, 0);
      expect(zero.imagesGenerated, 0);
      expect(zero.imagesEdited, 0);
      expect(formatUsageValue(zero.costMicros), '0');
    },
  );

  test('cost and image session aggregates stay attached to their buckets', () {
    final history = UsageHistory.fromJson({
      'totals': {
        'runs': 2,
        'modelCalls': 4,
        'inputTokens': 100,
        'outputTokens': 50,
        'costMicros': 700,
        'imagesGenerated': 5,
        'imagesEdited': 2,
      },
      'sessions': [
        {
          'sessionId': 's1',
          'title': 'Design',
          'runs': 2,
          'modelCalls': 4,
          'inputTokens': 100,
          'outputTokens': 50,
          'costMicros': 400,
          'imagesGenerated': 3,
          'imagesEdited': 1,
          'lastAt': '2026-10-24T10:00:00.000Z',
        },
      ],
      'runs': const [],
    });

    expect(history.totals.costMicros, 700);
    expect(history.totals.imagesGenerated, 5);
    expect(history.totals.imagesEdited, 2);
    expect(history.sessions.single.costMicros, 400);
    expect(history.sessions.single.imagesGenerated, 3);
    expect(history.sessions.single.imagesEdited, 1);
    expect(history.sessions.single.counts.costMicros, 400);
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
