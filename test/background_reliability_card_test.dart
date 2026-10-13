import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/background_health.dart';
import 'package:ovid_ai/core/background_notifications.dart';
import 'package:ovid_ai/core/distribution.dart';
import 'package:ovid_ai/ui/background_reliability_card.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

BackgroundHealth health({
  int sdk = 34,
  String maker = 'Google',
  bool notifications = true,
  bool battery = true,
  bool exact = true,
}) => BackgroundHealth.fromMap({
  'sdk': sdk,
  'manufacturer': maker,
  'brand': maker,
  'notificationsEnabled': notifications,
  'batteryExempt': battery,
  'exactAlarmsAllowed': exact,
  'alarmMode': exact ? 'exact' : 'inexact',
  'keepActive': true,
});

void main() {
  group('settings card states (pure)', () {
    test('all granted on a stock phone → ready, three ticks', () {
      final rows = reliabilityRows(health());
      expect(rows.map((r) => r.toString()), [
        'notifications:ok',
        'battery:ok',
        'exactAlarms:ok',
      ]);
      expect(backgroundReady(rows), isTrue);
    });

    test('missing grants need action', () {
      final rows = reliabilityRows(
        health(notifications: false, battery: false, exact: false),
      );
      expect(
        rows.where((r) => r.state == ReliabilityState.actionNeeded),
        hasLength(3),
      );
      expect(backgroundReady(rows), isFalse);
    });

    test('exact alarms are not a separate grant before Android 12', () {
      final rows = reliabilityRows(health(sdk: 30, exact: false));
      expect(
        rows.firstWhere((r) => r.item == ReliabilityItem.exactAlarms).state,
        ReliabilityState.ok,
      );
    });

    test('OEM killers add a manual autostart row that does not block ready', () {
      final rows = reliabilityRows(health(maker: 'Xiaomi'));
      expect(rows.last, const ReliabilityRow(
        ReliabilityItem.oemAutostart,
        ReliabilityState.manual,
      ));
      expect(backgroundReady(rows), isTrue);
    });

    test('non-Android shows nothing', () {
      expect(reliabilityRows(BackgroundHealth.unavailable), isEmpty);
      expect(BackgroundHealth.fromMap(null).android, isFalse);
    });

    test('OEM detection by manufacturer or brand', () {
      expect(OemKiller.detect('Xiaomi'), OemKiller.xiaomi);
      expect(OemKiller.detect('', 'POCO'), OemKiller.xiaomi);
      expect(OemKiller.detect('samsung'), OemKiller.samsung);
      expect(OemKiller.detect('OPPO'), OemKiller.oppo);
      expect(OemKiller.detect('vivo'), OemKiller.vivo);
      expect(OemKiller.detect('HMD Global'), OemKiller.nokia);
      expect(OemKiller.detect('Google', 'google'), isNull);
      expect(OemKiller.xiaomi.guideUrl, 'https://dontkillmyapp.com/xiaomi');
      expect(OemKiller.transsion.guideUrl, 'https://dontkillmyapp.com/');
    });
  });

  group('settings card widget', () {
    late List<String> invoked;
    late List<Uri> opened;
    late BackgroundHealth current;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      BackgroundNotifier.I.resetForTest();
      BackgroundNotifier.I.invokeOverrideForTest = (_, _) async => true;
      invoked = [];
      opened = [];
      current = health();
      BackgroundHealthSource.load = () async => current;
      BackgroundHealthSource.invoke = (m) async => invoked.add(m);
      BackgroundReliabilityCard.requestNotifications = () async =>
          PermissionStatus.denied;
      BackgroundReliabilityCard.openUrl = (u) async {
        opened.add(u);
        return true;
      };
    });

    tearDown(() {
      BackgroundReliabilityCard.resetSeams();
      BackgroundNotifier.I.resetForTest();
      Distribution.playOverrideForTest = null;
    });

    Future<void> pump(WidgetTester tester, {bool compact = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BackgroundReliabilityCard(compact: compact),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('ticks for granted rows, Allow for missing ones', (tester) async {
      current = health(battery: false);
      await pump(tester);
      expect(find.text('Background reliability'), findsOneWidget);
      expect(find.text('1 setting needs attention'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
      expect(find.byKey(const ValueKey('background-fix-battery')), findsOneWidget);
      current = health();
      await tester.tap(find.byKey(const ValueKey('background-fix-battery')));
      await tester.pumpAndSettle();
      expect(invoked, ['requestBatteryExemption']);
      expect(find.text('All set. Ovid can run schedules and agent tasks while it is closed.'),
          findsOneWidget);
    });

    testWidgets('notifications: runtime prompt, then app settings if denied',
        (tester) async {
      current = health(notifications: false);
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('background-fix-notifications')));
      await tester.pumpAndSettle();
      expect(invoked, ['notifyOpenAppSettings']);
    });

    testWidgets('exact alarms open the Alarms & reminders grant', (tester) async {
      current = health(exact: false);
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('background-fix-exactAlarms')));
      await tester.pumpAndSettle();
      expect(invoked, ['bgRequestExactAlarm']);
    });

    testWidgets('OEM row links to autostart settings and the guide', (tester) async {
      current = health(maker: 'Xiaomi');
      await pump(tester);
      expect(find.text('Xiaomi background settings'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('background-fix-oemAutostart')));
      await tester.pumpAndSettle();
      expect(invoked, ['openAutoStartSettings']);
      await tester.tap(find.byKey(const ValueKey('background-oem-guide')));
      await tester.pumpAndSettle();
      expect(opened.single.toString(), 'https://dontkillmyapp.com/xiaomi');
    });

    testWidgets('compact card hides itself once everything is granted',
        (tester) async {
      await pump(tester, compact: true);
      expect(find.byKey(const ValueKey('background-reliability-card')), findsNothing);
      current = health(exact: false);
      await tester.pumpWidget(const SizedBox());
      await pump(tester, compact: true);
      expect(find.byKey(const ValueKey('background-reliability-card')), findsOneWidget);
      // Compact = requirements only.
      expect(find.byKey(const ValueKey('keep-active-switch')), findsNothing);
    });

    testWidgets('keep-active switch and per-type sound settings (sideload)',
        (tester) async {
      Distribution.playOverrideForTest = false;
      await pump(tester);
      expect(find.text('Keep Ovid active in background'), findsOneWidget);
      for (final c in OvidChannel.values) {
        expect(find.byKey(ValueKey('channel-${c.key}')), findsOneWidget);
        expect(find.byKey(ValueKey('channel-settings-${c.key}')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('channel-sound-background_status')),
          findsNothing, reason: 'the status channel is always silent');
      expect(find.text('Ovid chime'), findsNWidgets(2));
    });

    testWidgets('Play builds hide the keep-active switch', (tester) async {
      Distribution.playOverrideForTest = true;
      await pump(tester);
      expect(find.byKey(const ValueKey('keep-active-switch')), findsNothing);
    });
  });
}
