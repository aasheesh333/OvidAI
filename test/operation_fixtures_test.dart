import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const fixtureNames = [
  'notifications.json',
  'billing.json',
  'quota.json',
  'account-health.json',
];

/// Canonical fixtures live in the Backend checkout and are mirrored into the
/// Web checkout. Neither sibling repository exists in the Flutter-only CI
/// checkout, so the cross-repo byte-parity assertion is skipped there with an
/// explicit reason instead of failing on a missing path. Set
/// OVID_BACKEND_ROOT / OVID_WEB_ROOT to point at the checkouts elsewhere.
final String _backendRoot =
    Platform.environment['OVID_BACKEND_ROOT'] ?? '../OvidBackend';
final String _webRoot = Platform.environment['OVID_WEB_ROOT'] ?? '../OvidWeb';
final String? _paritySkip = () {
  final missing = <String>[
    if (!Directory('$_backendRoot/cloud/packages/shared/contracts/fixtures')
        .existsSync())
      '$_backendRoot/cloud/packages/shared/contracts/fixtures',
    if (!Directory('$_webRoot/web/test/fixtures').existsSync())
      '$_webRoot/web/test/fixtures',
  ];
  return missing.isEmpty
      ? null
      : 'Cross-repo fixture mirrors unavailable: ${missing.join(', ')}';
}();

Map<String, dynamic> map(Object? value) =>
    (value! as Map).cast<String, dynamic>();

List<Map<String, dynamic>> maps(Object? value) =>
    (value! as List).map(map).toList();

Map<String, dynamic> fixture(String name) =>
    map(jsonDecode(File('test/fixtures/operations/$name').readAsStringSync()));

class NotificationDto {
  const NotificationDto(
    this.kind,
    this.channel,
    this.sessionId,
    this.route,
    this.sound,
    this.androidChannelId,
  );

  factory NotificationDto.fromJson(Map<String, dynamic> json) {
    final data = map(json['data']);
    return NotificationDto(
      data['kind'] as String,
      data['channel'] as String,
      data['sessionId'] as String,
      data['route'] as String,
      json['sound'] as String,
      json['androidChannelId'] as String,
    );
  }

  final String kind;
  final String channel;
  final String sessionId;
  final String route;
  final String sound;
  final String androidChannelId;
}

class BillingEntitlementDto {
  const BillingEntitlementDto(
    this.tier,
    this.productId,
    this.period,
    this.expiresAt,
    this.autoRenewing,
    this.purchaseState,
  );

  factory BillingEntitlementDto.fromJson(Map<String, dynamic> json) =>
      BillingEntitlementDto(
        json['tier'] as String,
        json['productId'] as String,
        json['period'] as String?,
        json['expiresAt'] as int?,
        json['autoRenewing'] as bool,
        json['purchaseState'] as String,
      );

  final String tier;
  final String productId;
  final String? period;
  final int? expiresAt;
  final bool autoRenewing;
  final String purchaseState;
}

class QuotaReservationDto {
  const QuotaReservationDto(
    this.reservationId,
    this.source,
    this.reservedTokens,
    this.status,
  );

  factory QuotaReservationDto.fromJson(Map<String, dynamic> json) =>
      QuotaReservationDto(
        json['reservationId'] as String,
        json['source'] as String,
        json['reservedTokens'] as int,
        json['status'] as String,
      );

  final String reservationId;
  final String source;
  final int reservedTokens;
  final String status;
}

class AccountHealthDto {
  const AccountHealthDto(
    this.remainingUsd,
    this.monthlyRemainingUsd,
    this.multiIpFlags,
    this.appCheck,
    this.anomaly,
    this.mailOutcome,
  );

  factory AccountHealthDto.fromJson(Map<String, dynamic> json) {
    final usage = map(json['usage']);
    final standing = map(json['standing']);
    final security = map(json['security']);
    return AccountHealthDto(
      map(usage['today'])['remainingUsd'],
      map(usage['month'])['remainingUsd'],
      standing['multiIpFlags'] as bool?,
      security['appCheck'] as String?,
      security['anomaly'],
      security['mailOutcome'] as String?,
    );
  }

  final Object? remainingUsd;
  final Object? monthlyRemainingUsd;
  final bool? multiIpFlags;
  final String? appCheck;
  final Object? anomaly;
  final String? mailOutcome;
}

void main() {
  test(
    'all four fixtures have byte-identical canonical and Web mirrors',
    () {
      for (final name in fixtureNames) {
        final canonical = File(
          '$_backendRoot/cloud/packages/shared/contracts/fixtures/operations/$name',
        ).readAsBytesSync();
        final flutter = File('test/fixtures/operations/$name').readAsBytesSync();
        final web = File(
          '$_webRoot/web/test/fixtures/operations/$name',
        ).readAsBytesSync();
        expect(flutter, orderedEquals(canonical), reason: 'Flutter $name');
        expect(web, orderedEquals(canonical), reason: 'Web $name');
      }
    },
    skip: _paritySkip,
  );

  test(
    'notification DTOs accept additive fields and retain all channel metadata',
    () {
      final messages = maps(fixture('notifications.json')['messages']);
      expect(messages.map((message) => map(message['data'])['channel']), [
        'agent_updates',
        'scheduler_results',
        'background_status',
      ]);
      final agent = NotificationDto.fromJson(messages[0]);
      expect(agent.kind, 'agentFinished');
      expect(agent.channel, 'agent_updates');
      expect(agent.sessionId, 'session-fixture-agent');
      expect(agent.route, '/c/session-fixture-agent');
      expect(agent.sound, 'chime');
      expect(agent.androidChannelId, 'ovid_agent_updates.chime.v1');
      final scheduler = NotificationDto.fromJson(messages[1]);
      expect(scheduler.kind, 'scheduleSucceeded');
      expect(scheduler.channel, 'scheduler_results');
      expect(scheduler.sessionId, 'session-fixture-scheduler');
      expect(scheduler.route, '/schedule/session-fixture-scheduler');
      final background = NotificationDto.fromJson(messages[2]);
      expect(background.kind, 'backgroundStatus');
      expect(background.channel, 'background_status');
      expect(background.sound, 'silent');
      expect(background.androidChannelId, 'ovid_background_status.silent.v1');
      expect(map(messages[0]['data'])['futureMetadata'], {'additive': true});
    },
  );

  test(
    'billing DTO accepts additive fields without yearly-to-monthly fallback',
    () {
      final billing = fixture('billing.json');
      final entitlement = BillingEntitlementDto.fromJson(
        map(billing['entitlement']),
      );
      expect(entitlement.tier, 'plus');
      expect(entitlement.productId, 'ovid_pro_yearly');
      expect(entitlement.period, 'yearly');
      expect(entitlement.expiresAt, 1800000000000);
      expect(entitlement.autoRenewing, isTrue);
      expect(entitlement.purchaseState, 'active');
      expect(
        map(billing['entitlement'])['futureEntitlementField'],
        'additive-v2',
      );
      final unavailable = map(billing['unavailableYearly']);
      expect(unavailable['requestedProductId'], 'ovid_pro_yearly');
      expect(unavailable['selectedPackage'], isNull);
      expect(unavailable['reason'], 'not_configured');
    },
  );

  test(
    'quota DTO accepts additive fields and leaves actual upload facts unknown',
    () {
      final quota = fixture('quota.json');
      final model = QuotaReservationDto.fromJson(
        map(quota['modelReservation']),
      );
      expect(model.reservationId, 'quota-reservation-fixture-1');
      expect(model.source, 'schedule_tick');
      expect(model.reservedTokens, 2000);
      expect(model.status, 'reserved');
      expect(map(quota['modelReservation'])['futureReservationField'], {
        'additive': true,
      });
      expect(map(quota['settlement'])['costUsd'], '0.0000000001');
      expect(map(quota['unknownUsage']), {
        'providerModel': null,
        'costUsd': null,
      });
      final upload = map(quota['uploadReservation']);
      expect(upload['actorUserId'], 'actor-fixture');
      expect(upload['ownerUserId'], 'owner-fixture');
      expect(upload['declaredBytes'], 99);
      expect(upload['actualBytes'], isNull);
      expect(upload['actualContentType'], isNull);
    },
  );

  test(
    'account-health DTO accepts additive fields and preserves nullable facts',
    () {
      final accountHealth = fixture('account-health.json')['accountHealth'];
      final health = AccountHealthDto.fromJson(map(accountHealth));
      expect(health.remainingUsd, isNull);
      expect(health.monthlyRemainingUsd, isNull);
      expect(health.multiIpFlags, isNull);
      expect(health.appCheck, isNull);
      expect(health.anomaly, isNull);
      expect(health.mailOutcome, isNull);
      expect(map(accountHealth)['futureHealthField'], {'additive': true});
      final uploadWindow = map(map(accountHealth)['uploadWindow']);
      expect(uploadWindow['used'], isNull);
      expect(uploadWindow['remaining'], isNull);
      expect(uploadWindow['cap'], 50);
    },
  );
}
