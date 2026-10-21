import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/notifications_page.dart';

Future<void> _pump(
  WidgetTester tester,
  V2NotificationsPageData data, {
  bool dark = false,
  Size size = const Size(420, 1000),
  double textScale = 1,
  bool reduceMotion = false,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
          alwaysUse24HourFormat: true,
        ),
        child: NotificationsPage(data: data),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('renders the notification sections in light', (tester) async {
    await _pump(tester, const V2NotificationsPageData());

    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('ACTIVITY'), findsOneWidget);
    expect(find.text('Run finished'), findsOneWidget);
    expect(find.text('Quiet hours'), findsOneWidget);
    expect(
      find.text('22:00–08:00 · No alerts during this time'),
      findsOneWidget,
    );
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, const V2NotificationsPageData(), dark: true);

    expect(find.text('SECURITY'), findsOneWidget);
    expect(find.text('New sign-ins'), findsOneWidget);
  });

  testWidgets('toggles a notification category', (tester) async {
    String? toggledId;
    bool? toggledValue;
    await _pump(
      tester,
      V2NotificationsPageData(
        onToggle: (id, value) {
          toggledId = id;
          toggledValue = value;
        },
      ),
    );

    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(toggledId, 'run_finished');
    expect(toggledValue, isFalse);
  });

  testWidgets('opens quiet hours', (tester) async {
    var quietTaps = 0;
    await _pump(
      tester,
      V2NotificationsPageData(onQuietHours: () => quietTaps++),
    );

    final row = find.text('Quiet hours');
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(quietTaps, 1);
  });

  testWidgets('shows the blocked banner and opens system settings', (
    tester,
  ) async {
    var systemTaps = 0;
    await _pump(
      tester,
      V2NotificationsPageData(
        notificationsBlocked: true,
        onOpenSystem: () => systemTaps++,
      ),
    );

    expect(find.text('Notifications are blocked'), findsOneWidget);
    final button = find.text('Open Android settings');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(systemTaps, 1);
  });

  testWidgets('hides the blocked banner when notifications are allowed', (
    tester,
  ) async {
    await _pump(tester, const V2NotificationsPageData());

    expect(
      find.byKey(const ValueKey<String>('notifications-blocked-banner')),
      findsNothing,
    );
    expect(find.text('Notifications are blocked'), findsNothing);
  });

  testWidgets('blocked banner is keyed for the route-level state', (
    tester,
  ) async {
    await _pump(
      tester,
      const V2NotificationsPageData(notificationsBlocked: true),
    );

    expect(
      find.byKey(const ValueKey<String>('notifications-blocked-banner')),
      findsOneWidget,
    );
    expect(find.text('Open Android settings'), findsOneWidget);
  });

  testWidgets('renders quiet hours times and channel sounds', (tester) async {
    await _pump(tester, const V2NotificationsPageData());

    expect(find.text('CHANNEL SOUNDS'), findsOneWidget);
    expect(find.text('Agent updates'), findsOneWidget);
    expect(find.text('Scheduled results'), findsOneWidget);
    expect(find.text('Ovid chime'), findsNWidgets(2));
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);
    expect(find.text('22:00'), findsOneWidget);
    expect(find.text('08:00'), findsOneWidget);
  });

  testWidgets('toggles quiet hours', (tester) async {
    bool? quietEnabled;
    await _pump(
      tester,
      V2NotificationsPageData(
        onQuietHoursEnabledChanged: (value) => quietEnabled = value,
      ),
    );

    final toggle = find.byKey(const ValueKey<String>('quiet-hours-switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(quietEnabled, isFalse);
  });

  testWidgets('changes the quiet hours start time', (tester) async {
    TimeOfDay? start;
    await _pump(
      tester,
      V2NotificationsPageData(
        onQuietHoursStartChanged: (value) => start = value,
      ),
    );

    final row = find.text('Start');
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.text('Quiet hours Start'), findsOneWidget);

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '9');
    await tester.enterText(fields.at(1), '30');
    // The dialog follows the device 12-hour clock; pin the period so the
    // assertion is not tied to the initial 22:00 value.
    await tester.tap(find.text('AM'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(start, const TimeOfDay(hour: 9, minute: 30));
  });

  testWidgets('quiet hours times are disabled when quiet hours is off', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      const V2NotificationsPageData(
        quietHoursEnabled: false,
        onQuietHoursStartChanged: _ignoreTime,
        onQuietHoursEndChanged: _ignoreTime,
      ),
    );

    expect(find.text('Off · Alerts can arrive at any time'), findsOneWidget);

    final start = tester.getSemantics(find.text('Start')).getSemanticsData();
    expect(start.flagsCollection.isEnabled, Tristate.isFalse);

    handle.dispose();
  });

  testWidgets('selects a per-channel sound', (tester) async {
    String? channelId;
    V2NotificationSound? sound;
    await _pump(
      tester,
      V2NotificationsPageData(
        onSoundChanged: (id, value) {
          channelId = id;
          sound = value;
        },
      ),
    );

    final row = find.byKey(const ValueKey<String>('sound-row-agent_updates'));
    await tester.ensureVisible(row);
    await tester.tap(find.descendant(of: row, matching: find.text('System')));
    await tester.pumpAndSettle();

    expect(channelId, 'agent_updates');
    expect(sound, V2NotificationSound.system);
  });

  testWidgets('sound choices are disabled for a channel that is off', (
    tester,
  ) async {
    var changes = 0;
    await _pump(
      tester,
      V2NotificationsPageData(
        activity: const [
          V2NotificationSetting(
            id: 'agent_updates',
            title: 'Run finished',
            description: 'When Ovid completes a task.',
            value: false,
          ),
          V2NotificationSetting(
            id: 'scheduler_results',
            title: 'Schedule results',
            description: 'When a scheduled run finishes.',
          ),
        ],
        onSoundChanged: (_, _) => changes++,
      ),
    );

    final row = find.byKey(const ValueKey<String>('sound-row-agent_updates'));
    await tester.ensureVisible(row);
    expect(
      find.textContaining('Turn this channel on to pick a sound.'),
      findsOneWidget,
    );

    await tester.tap(find.descendant(of: row, matching: find.text('System')));
    await tester.pumpAndSettle();

    expect(changes, 0);
  });

  testWidgets('unwired quiet hours switch is announced as disabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, const V2NotificationsPageData());

    final quietSwitch = tester
        .getSemantics(find.byKey(const ValueKey<String>('quiet-hours-switch')))
        .getSemanticsData();
    expect(quietSwitch.flagsCollection.isEnabled, Tristate.isFalse);

    handle.dispose();
  });

  testWidgets('renders the empty state and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      V2NotificationsPageData(
        status: V2NotificationsStatus.empty,
        onRetry: () => retries++,
      ),
    );

    expect(find.text('No notification settings'), findsOneWidget);
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(retries, 1);
  });

  testWidgets('shows the error state and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      V2NotificationsPageData(
        status: V2NotificationsStatus.error,
        onRetry: () => retries++,
      ),
    );

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(
      find.text('We could not load your notification settings.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(retries, 1);
  });

  testWidgets('loading shows skeleton rows', (tester) async {
    await _pump(
      tester,
      const V2NotificationsPageData(status: V2NotificationsStatus.loading),
      settle: false,
    );
    // The shimmer never settles, so pump a frame instead of settling.
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.byType(OSkeletonList), findsOneWidget);
  });

  testWidgets('fits 320 dp at 200% text in light', (tester) async {
    await _pump(
      tester,
      const V2NotificationsPageData(notificationsBlocked: true),
      size: const Size(320, 640),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Notifications are blocked'), findsOneWidget);
    expect(find.text('Run finished'), findsOneWidget);

    // The delivery section sits at the bottom; it must stay reachable.
    await tester.ensureVisible(find.text('Vibration'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Quiet hours'), findsOneWidget);
  });

  testWidgets('fits 320 dp at 200% text in dark', (tester) async {
    await _pump(
      tester,
      const V2NotificationsPageData(),
      dark: true,
      size: const Size(320, 640),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Quiet hours'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Quiet hours'), findsOneWidget);
  });

  testWidgets('reduced motion still shows every section', (tester) async {
    await _pump(
      tester,
      const V2NotificationsPageData(notificationsBlocked: true),
      reduceMotion: true,
    );

    for (final label in const [
      'Notifications are blocked',
      'ACTIVITY',
      'SECURITY',
      'DELIVERY',
      'Quiet hours',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '$label is hidden');
    }
  });

  testWidgets('unwired controls are announced as disabled', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, const V2NotificationsPageData());

    final toggle = tester
        .getSemantics(find.byType(Switch).first)
        .getSemanticsData();
    // Tristate.none would mean the control does not announce its state at all.
    expect(toggle.flagsCollection.isEnabled, Tristate.isFalse);
    expect(toggle.flagsCollection.isToggled, Tristate.isTrue);

    final quietHours = tester
        .getSemantics(find.byType(OListRow))
        .getSemanticsData();
    expect(quietHours.flagsCollection.isEnabled, Tristate.isFalse);

    semantics.dispose();
  });

  testWidgets('wired controls are announced as enabled', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      V2NotificationsPageData(onToggle: (_, _) {}, onQuietHours: () {}),
    );

    final toggle = tester
        .getSemantics(find.byType(Switch).first)
        .getSemanticsData();
    expect(toggle.flagsCollection.isEnabled, Tristate.isTrue);

    // OListRow does not set the enabled flag on its tappable branch, so the
    // wired row reports Tristate.none; that is treated as enabled.
    final quietHours = tester
        .getSemantics(find.byType(OListRow))
        .getSemanticsData();
    expect(quietHours.flagsCollection.isEnabled, isNot(Tristate.isFalse));

    semantics.dispose();
  });
}

void _ignoreTime(TimeOfDay _) {}
