import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/cloud/account_health.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';

/// The exact shape `GET /cloud/v1/account/health` answers.
Map<String, Object?> _full() => {
  'plan': {
    'tier': '7x',
    'id': 'plus',
    'name': 'Ovid Plus',
    'expiresAt': '2026-11-20T00:00:00.000Z',
    'limits': {
      'storageBytes': 16106127360,
      'customConnectors': 20,
      'projectFiles': 150,
      'manualModels': true,
      'autoMultiplier': 5,
      'uploads': {'count': 80, 'windowHours': 3},
    },
  },
  'storage': {
    'usedBytes': 1073741824,
    'quotaBytes': 16106127360,
    'remainingBytes': 15032385536,
  },
  'usage': {
    'today': {
      'since': '2026-10-23T00:00:00.000Z',
      'until': '2026-10-23T12:00:00.000Z',
      'used': {
        'runs': 2,
        'modelCalls': 3,
        'inputTokens': 1000,
        'outputTokens': 200,
        'cacheReadTokens': 0,
        'cacheWriteTokens': 0,
      },
      'remainingUsd': null,
      'tokensUsed': 1200,
      'tokenCap': 50000000,
      'tokensRemaining': 49998800,
    },
    'month': {
      'since': '2026-10-01T00:00:00.000Z',
      'until': '2026-10-23T12:00:00.000Z',
      'used': {
        'runs': 9,
        'modelCalls': 12,
        'inputTokens': 8000,
        'outputTokens': 900,
        'cacheReadTokens': 0,
        'cacheWriteTokens': 0,
      },
      'remainingUsd': null,
      'tokensUsed': 8900,
      'tokenCap': 1500000000,
      'tokensRemaining': 1499991100,
    },
  },
  'standing': {
    'banned': false,
    'bannedAt': null,
    'bannedReason': null,
    'multiIpFlags': null,
    'deletion': null,
  },
};

void main() {
  test('parses the gateway answer without inventing any value', () {
    final health = AccountHealth.fromJson(_full());

    expect(health.isEmpty, isFalse);
    expect(health.plan?.tier, '7x');
    expect(health.plan?.id, 'plus');
    expect(health.plan?.name, 'Ovid Plus');
    expect(health.plan?.expiresAt, DateTime.parse('2026-11-20T00:00:00.000Z'));
    expect(health.plan?.limits?.storageBytes, 16106127360);
    expect(health.plan?.limits?.customConnectors, 20);
    expect(health.plan?.limits?.projectFiles, 150);
    expect(health.plan?.limits?.manualModels, isTrue);
    expect(health.plan?.limits?.autoMultiplier, 5);
    expect(health.plan?.limits?.uploads?.count, 80);
    expect(health.plan?.limits?.uploads?.windowHours, 3);

    expect(health.storage?.usedBytes, 1073741824);
    expect(health.storage?.quotaBytes, 16106127360);
    expect(health.storage?.remainingBytes, 15032385536);
    expect(health.storage?.usedFraction, closeTo(1 / 15, 1e-9));

    expect(health.usage?.today?.used?.runs, 2);
    expect(health.usage?.today?.used?.modelCalls, 3);
    expect(health.usage?.today?.used?.totalTokens, 1200);
    expect(health.usage?.month?.used?.totalTokens, 8900);
    expect(health.usage?.today?.remainingUsd, isNull);
    expect(health.usage?.month?.remainingUsd, isNull);

    expect(health.standing?.banned, isFalse);
    expect(health.standing?.bannedAt, isNull);
    expect(health.standing?.bannedReason, isNull);
    // The gateway has no multi-IP detector; null means "not checked".
    expect(health.standing?.multiIpFlags, isNull);
    expect(health.standing?.deletion, isNull);

    expect(health.usage?.today?.tokensUsed, 1200);
    expect(health.usage?.today?.tokenCap, 50000000);
    expect(health.usage?.today?.tokensRemaining, 49998800);
    expect(health.usage?.month?.tokensUsed, 8900);
    expect(health.usage?.month?.tokenCap, 1500000000);
    expect(health.usage?.month?.tokensRemaining, 1499991100);
  });

  test('token fields are unknown when absent, never zero', () {
    // An older gateway does not answer these keys. An absent field is
    // unknown; a zero would read as a real measurement (and as a spent cap).
    final absent = AccountHealth.fromJson(const {
      'usage': {
        'today': {'remainingUsd': null},
        'month': {'remainingUsd': null},
      },
    });
    expect(absent.usage?.today?.tokensUsed, isNull);
    expect(absent.usage?.today?.tokenCap, isNull);
    expect(absent.usage?.today?.tokensRemaining, isNull);

    // A zero is a real value the server may send: an exhausted window.
    final zero = AccountHealth.fromJson(const {
      'usage': {
        'today': {'tokensUsed': 0, 'tokenCap': 0, 'tokensRemaining': 0},
      },
    });
    expect(zero.usage?.today?.tokensUsed, 0);
    expect(zero.usage?.today?.tokenCap, 0);
    expect(zero.usage?.today?.tokensRemaining, 0);

    // Wrong type / negative / null values degrade to unknown.
    final bad = AccountHealth.fromJson(const {
      'usage': {
        'today': {
          'tokensUsed': 'many',
          'tokenCap': -1,
          'tokensRemaining': null,
        },
      },
    });
    expect(bad.usage?.today?.tokensUsed, isNull);
    expect(bad.usage?.today?.tokenCap, isNull);
    expect(bad.usage?.today?.tokensRemaining, isNull);
  });

  test('a missing or null field is unknown, never zero', () {
    final health = AccountHealth.fromJson(const {});

    expect(health.isEmpty, isTrue);
    expect(health.plan, isNull);
    expect(health.storage, isNull);
    expect(health.usage, isNull);
    expect(health.standing, isNull);

    final partial = AccountHealth.fromJson({
      'plan': {
        'tier': null,
        'id': null,
        'name': null,
        'expiresAt': null,
        'limits': null,
      },
      'storage': {
        'usedBytes': null,
        'quotaBytes': null,
        'remainingBytes': null,
      },
      'usage': {
        'today': {
          'since': null,
          'until': null,
          'used': null,
          'remainingUsd': null,
        },
      },
      'standing': {
        'banned': null,
        'bannedAt': null,
        'bannedReason': null,
        'multiIpFlags': null,
        'deletion': null,
      },
    });

    expect(partial.plan?.tier, isNull);
    expect(partial.plan?.expiresAt, isNull);
    expect(partial.plan?.limits, isNull);
    expect(partial.storage?.usedBytes, isNull);
    expect(partial.storage?.quotaBytes, isNull);
    expect(partial.storage?.remainingBytes, isNull);
    expect(partial.storage?.usedFraction, isNull);
    expect(partial.usage?.today?.since, isNull);
    expect(partial.usage?.today?.until, isNull);
    expect(partial.usage?.today?.used, isNull);
    expect(partial.usage?.today?.usedTokens, isNull);
    expect(partial.usage?.today?.remainingUsd, isNull);
    expect(partial.usage?.month, isNull);
    expect(partial.standing?.banned, isNull);
    expect(partial.standing?.deletion, isNull);
  });

  test('a recorded zero is a fact, not unknown', () {
    final health = AccountHealth.fromJson({
      'plan': {
        'limits': {
          'storageBytes': 0,
          'customConnectors': 0,
          'projectFiles': 0,
          'uploads': {'count': 0, 'windowHours': 0},
        },
      },
      'storage': {'usedBytes': 0, 'quotaBytes': 0, 'remainingBytes': 0},
      'usage': {
        'today': {
          'used': {'inputTokens': 0, 'outputTokens': 0},
          'remainingUsd': 0,
        },
      },
      'standing': {
        'banned': false,
        'deletion': {'state': 'cancelled', 'pending': false},
      },
    });

    expect(health.plan?.limits?.storageBytes, 0);
    expect(health.plan?.limits?.customConnectors, 0);
    expect(health.plan?.limits?.projectFiles, 0);
    expect(health.plan?.limits?.uploads?.count, 0);
    expect(health.plan?.limits?.uploads?.windowHours, 0);
    expect(health.storage?.usedBytes, 0);
    expect(health.storage?.quotaBytes, 0);
    expect(health.storage?.remainingBytes, 0);
    // 0 / 0 is not a fraction; it is unknown, never a fake 0 %.
    expect(health.storage?.usedFraction, isNull);
    expect(health.usage?.today?.used?.totalTokens, 0);
    expect(health.usage?.today?.remainingUsd, 0);
    expect(health.standing?.banned, isFalse);
    expect(health.standing?.deletion?.pending, isFalse);
  });

  test('wrongly typed fields degrade to unknown instead of throwing', () {
    final health = AccountHealth.fromJson({
      'plan': {
        'tier': 7,
        'id': <String>[],
        'expiresAt': 'not-a-date',
        'limits': 'none',
      },
      'storage': {
        'usedBytes': 'lots',
        'quotaBytes': -1,
        'remainingBytes': double.nan,
      },
      'usage': {
        'today': {'used': 'many'},
        'month': 42,
      },
      'standing': {
        'banned': 'yes',
        'bannedAt': 123,
        'multiIpFlags': false,
        'deletion': 'gone',
      },
    });

    expect(health.plan?.tier, isNull);
    expect(health.plan?.id, isNull);
    expect(health.plan?.expiresAt, isNull);
    expect(health.plan?.limits, isNull);
    expect(health.storage?.usedBytes, isNull);
    expect(health.storage?.quotaBytes, isNull);
    expect(health.storage?.remainingBytes, isNull);
    expect(health.usage?.today?.used, isNull);
    expect(health.usage?.month, isNull);
    expect(health.standing?.banned, isNull);
    expect(health.standing?.bannedAt, isNull);
    expect(health.standing?.multiIpFlags, isNull);
    expect(health.standing?.deletion, isNull);
  });

  test('a banned account with a pending deletion keeps both facts', () {
    final health = AccountHealth.fromJson({
      'standing': {
        'banned': true,
        'bannedAt': '2026-10-01T08:30:00.000Z',
        'bannedReason': 'auto',
        'multiIpFlags': null,
        'deletion': {
          'state': 'pending',
          'pending': true,
          'deleteAfter': '2026-11-20T00:00:00.000Z',
        },
      },
    });

    expect(health.standing?.banned, isTrue);
    expect(
      health.standing?.bannedAt,
      DateTime.parse('2026-10-01T08:30:00.000Z'),
    );
    expect(health.standing?.bannedReason, 'auto');
    expect(health.standing?.deletion?.state, 'pending');
    expect(health.standing?.deletion?.pending, isTrue);
    expect(
      health.standing?.deletion?.deleteAfter,
      DateTime.parse('2026-11-20T00:00:00.000Z'),
    );
  });

  test('the client sends the caller calendar and parses the answer', () async {
    final requests = <http.Request>[];
    final rest = CloudRestClient(
      restBase: 'https://cloud.test',
      headers: CloudHeaders.forTest(),
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode(_full()), 200);
      }),
    );

    final health = await AccountHealthClient(
      rest: rest,
      utcOffsetMinutes: () => 9999,
    ).fetch();

    expect(requests.single.url.path, '/account/health');
    expect(requests.single.url.queryParameters, {'utcOffsetMinutes': '840'});
    expect(requests.single.headers['Authorization'], 'Bearer test-id-token');
    expect(health.plan?.id, 'plus');
  });

  test(
    'the client clamps a negative offset and an empty answer is empty',
    () async {
      final requests = <http.Request>[];
      final rest = CloudRestClient(
        restBase: 'https://cloud.test',
        headers: CloudHeaders.forTest(),
        httpClient: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );

      final health = await AccountHealthClient(
        rest: rest,
        utcOffsetMinutes: () => -9999,
      ).fetch();

      expect(requests.single.url.queryParameters, {'utcOffsetMinutes': '-840'});
      expect(health.isEmpty, isTrue);
    },
  );
}
