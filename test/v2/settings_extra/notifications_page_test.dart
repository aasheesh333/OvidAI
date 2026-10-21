import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/background_notifications.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/notifications_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  testWidgets('master switch is on by default and reports changes', (
    tester,
  ) async {
    bool? master;
    await _pump(
      tester,
      V2NotificationsPageData(onMasterChanged: (value) => master = value),
    );

    final toggle = find.byKey(
      const ValueKey<String>('notifications-master-switch'),
    );
    expect(tester.widget<Switch>(toggle).value, isTrue);
    expect(
      find.textContaining('On: get notified when a cloud run finishes'),
      findsOneWidget,
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(master, isFalse);
  });

  testWidgets('master off disables channels, delivery and sounds', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var toggles = 0;
    var sounds = 0;
    await _pump(
      tester,
      V2NotificationsPageData(
        masterEnabled: false,
        onMasterChanged: (_) {},
        onToggle: (_, _) => toggles++,
        onSoundChanged: (_, _) => sounds++,
      ),
    );

    expect(
      find.textContaining('Off: Ovid Cloud sends no notifications'),
      findsOneWidget,
    );

    final channel = find.byKey(
      const ValueKey<String>('notification-switch-run_finished'),
    );
    expect(tester.widget<Switch>(channel).onChanged, isNull);
    expect(
      tester.getSemantics(channel).getSemanticsData().flagsCollection.isEnabled,
      Tristate.isFalse,
    );
    await tester.tap(channel);
    await tester.pumpAndSettle();
    expect(toggles, 0);

    final soundToggle = find.byKey(
      const ValueKey<String>('notification-switch-sound'),
    );
    await tester.ensureVisible(soundToggle);
    await tester.tap(soundToggle);
    await tester.pumpAndSettle();
    expect(toggles, 0);

    final soundRow = find.byKey(
      const ValueKey<String>('sound-row-agent_updates'),
    );
    await tester.ensureVisible(soundRow);
    expect(
      find.textContaining('Turn push notifications on to pick a sound.'),
      findsNWidgets(2),
    );
    await tester.tap(
      find.descendant(of: soundRow, matching: find.text('System')),
    );
    await tester.pumpAndSettle();
    expect(sounds, 0);

    handle.dispose();
  });

  testWidgets('first-run prompt explains the permission and can be deferred', (
    tester,
  ) async {
    var allowed = 0;
    var dismissed = 0;
    await _pump(
      tester,
      V2NotificationsPageData(
        showPermissionPrompt: true,
        onAllowNotifications: () => allowed++,
        onDismissPermissionPrompt: () => dismissed++,
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('notifications-permission-prompt')),
      findsOneWidget,
    );
    expect(find.text('Get notified when Ovid Si finishes'), findsOneWidget);
    expect(find.textContaining('Ovid Si works in the cloud'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('notifications-permission-later')),
    );
    await tester.pumpAndSettle();
    expect(dismissed, 1);

    await tester.tap(
      find.byKey(const ValueKey<String>('notifications-permission-allow')),
    );
    await tester.pumpAndSettle();
    expect(allowed, 1);
  });

  testWidgets('first-run prompt gives way to the blocked banner', (
    tester,
  ) async {
    await _pump(
      tester,
      const V2NotificationsPageData(
        showPermissionPrompt: true,
        notificationsBlocked: true,
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('notifications-permission-prompt')),
      findsNothing,
    );
    expect(find.text('Notifications are blocked'), findsOneWidget);
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

    await tester.tap(
      find.byKey(const ValueKey<String>('notification-switch-run_finished')),
    );
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
      const V2NotificationsPageData(
        showPermissionPrompt: true,
        masterEnabled: false,
      ),
      dark: true,
      size: const Size(320, 640),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Get notified when Ovid Si finishes'), findsOneWidget);
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
      'PUSH NOTIFICATIONS',
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
        .getSemantics(
          find.byKey(
            const ValueKey<String>('notification-switch-run_finished'),
          ),
        )
        .getSemanticsData();
    // Tristate.none would mean the control does not announce its state at all.
    expect(toggle.flagsCollection.isEnabled, Tristate.isFalse);
    expect(toggle.flagsCollection.isToggled, Tristate.isTrue);

    final master = tester
        .getSemantics(
          find.byKey(const ValueKey<String>('notifications-master-switch')),
        )
        .getSemanticsData();
    expect(master.flagsCollection.isEnabled, Tristate.isFalse);
    expect(master.flagsCollection.isToggled, Tristate.isTrue);

    final quietHours = tester
        .getSemantics(
          find.byKey(const ValueKey<String>('notifications-quiet-hours-row')),
        )
        .getSemanticsData();
    expect(quietHours.flagsCollection.isEnabled, Tristate.isFalse);

    semantics.dispose();
  });

  testWidgets('wired controls are announced as enabled', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      V2NotificationsPageData(
        onToggle: (_, _) {},
        onMasterChanged: (_) {},
        onQuietHours: () {},
      ),
    );

    final toggle = tester
        .getSemantics(
          find.byKey(
            const ValueKey<String>('notification-switch-run_finished'),
          ),
        )
        .getSemanticsData();
    expect(toggle.flagsCollection.isEnabled, Tristate.isTrue);

    // OListRow does not set the enabled flag on its tappable branch, so the
    // wired row reports Tristate.none; that is treated as enabled.
    final quietHours = tester
        .getSemantics(
          find.byKey(const ValueKey<String>('notifications-quiet-hours-row')),
        )
        .getSemanticsData();
    expect(quietHours.flagsCollection.isEnabled, isNot(Tristate.isFalse));

    semantics.dispose();
  });

  // ---------------------------------------------------------------------
  // Wiring fixes: no silent reverts, a real quiet-hours window and a sound
  // switch that reaches the per-channel setting core actually stores.
  // ---------------------------------------------------------------------

  test('quiet hours window is wrap-aware', () {
    const overnight = V2QuietHoursWindow(
      start: TimeOfDay(hour: 22, minute: 0),
      end: TimeOfDay(hour: 6, minute: 0),
    );
    expect(overnight.wrapsMidnight, isTrue);
    expect(overnight.durationMinutes, 8 * 60);
    expect(overnight.durationLabel, '8 h');
    expect(overnight.contains(const TimeOfDay(hour: 23, minute: 30)), isTrue);
    expect(overnight.contains(const TimeOfDay(hour: 0, minute: 1)), isTrue);
    expect(overnight.contains(const TimeOfDay(hour: 5, minute: 59)), isTrue);
    expect(overnight.contains(const TimeOfDay(hour: 6, minute: 0)), isFalse);
    expect(overnight.contains(const TimeOfDay(hour: 12, minute: 0)), isFalse);

    const sameDay = V2QuietHoursWindow(
      start: TimeOfDay(hour: 9, minute: 0),
      end: TimeOfDay(hour: 17, minute: 30),
    );
    expect(sameDay.wrapsMidnight, isFalse);
    expect(sameDay.durationMinutes, 8 * 60 + 30);
    expect(sameDay.durationLabel, '8 h 30 min');

    const empty = V2QuietHoursWindow(
      start: TimeOfDay(hour: 22, minute: 0),
      end: TimeOfDay(hour: 22, minute: 0),
    );
    expect(empty.isEmpty, isTrue);
    expect(empty.durationMinutes, 0);
    expect(empty.contains(const TimeOfDay(hour: 22, minute: 0)), isFalse);
  });

  testWidgets('a 22:00–06:00 quiet window is labelled as overnight', (
    tester,
  ) async {
    await _pump(
      tester,
      const V2NotificationsPageData(
        quietHoursStart: TimeOfDay(hour: 22, minute: 0),
        quietHoursEnd: TimeOfDay(hour: 6, minute: 0),
      ),
    );

    expect(
      find.text('22:00–06:00 · No alerts during this time'),
      findsOneWidget,
    );
    expect(find.text('Runs overnight · 8 h'), findsOneWidget);
  });

  testWidgets('a zero-length quiet window is not shown as all day', (
    tester,
  ) async {
    await _pump(
      tester,
      const V2NotificationsPageData(
        quietHoursStart: TimeOfDay(hour: 22, minute: 0),
        quietHoursEnd: TimeOfDay(hour: 22, minute: 0),
      ),
    );

    expect(find.text('Off · Start and end are the same time'), findsOneWidget);
    expect(find.byKey(const ValueKey('quiet-hours-span')), findsNothing);
  });

  testWidgets('a tapped switch keeps its new value (no silent revert)', (
    tester,
  ) async {
    await _pump(tester, V2NotificationsPageData(onToggle: (_, _) {}));

    final toggle = find.byKey(
      const ValueKey<String>('notification-switch-run_finished'),
    );
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(find.textContaining('When Ovid completes a task.'), findsOneWidget);
  });

  testWidgets('a row with no backend is honest, not a fake switch', (
    tester,
  ) async {
    var toggles = 0;
    await _pump(
      tester,
      V2NotificationsPageData(
        activity: const [
          V2NotificationSetting(
            id: 'shares_invites',
            title: 'Shares and invites',
            description: 'When someone shares a chat or invites you.',
            available: false,
          ),
        ],
        security: const [],
        onToggle: (_, _) => toggles++,
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('notification-switch-shares_invites')),
      findsNothing,
    );
    expect(find.text('Not available yet'), findsOneWidget);
    expect(toggles, 0);
  });

  testWidgets('the Sound switch reaches both per-channel settings', (
    tester,
  ) async {
    final calls = <String, V2NotificationSound>{};
    await _pump(
      tester,
      V2NotificationsPageData(onSoundChanged: (id, sound) => calls[id] = sound),
    );

    final soundSwitch = find.byKey(
      const ValueKey<String>('notification-switch-sound'),
    );
    await tester.ensureVisible(soundSwitch);
    await tester.tap(soundSwitch);
    await tester.pumpAndSettle();

    expect(calls, {
      'agent_updates': V2NotificationSound.silent,
      'scheduler_results': V2NotificationSound.silent,
    });
    expect(tester.widget<Switch>(soundSwitch).value, isFalse);

    await tester.tap(soundSwitch);
    await tester.pumpAndSettle();

    expect(calls, {
      'agent_updates': V2NotificationSound.chime,
      'scheduler_results': V2NotificationSound.chime,
    });
    expect(tester.widget<Switch>(soundSwitch).value, isTrue);
  });

  testWidgets('a chosen channel sound stays selected (no silent revert)', (
    tester,
  ) async {
    await _pump(tester, V2NotificationsPageData(onSoundChanged: (_, _) {}));

    final row = find.byKey(const ValueKey<String>('sound-row-agent_updates'));
    await tester.ensureVisible(row);
    await tester.tap(find.descendant(of: row, matching: find.text('System')));
    await tester.pumpAndSettle();

    final chip = tester.widget<Semantics>(
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              (widget.properties.label?.startsWith('System') ?? false),
        ),
      ),
    );
    expect(chip.properties.selected, isTrue);
  });

  testWidgets('quiet hours times persist through the notifier', (tester) async {
    SharedPreferences.setMockInitialValues({});
    BackgroundNotifier.I.resetForTest();
    addTearDown(BackgroundNotifier.I.resetForTest);

    Future<void> write(TimeOfDay time, {required bool start}) =>
        BackgroundNotifier.I.setQuietHours(
          enabled: true,
          startMinutes: start ? time.hour * 60 + time.minute : null,
          endMinutes: start ? null : time.hour * 60 + time.minute,
        );

    await _pump(
      tester,
      V2NotificationsPageData(
        quietHoursStart: const TimeOfDay(hour: 22, minute: 0),
        quietHoursEnd: const TimeOfDay(hour: 6, minute: 0),
        onQuietHoursStartChanged: (time) => write(time, start: true),
        onQuietHoursEndChanged: (time) => write(time, start: false),
      ),
    );

    // Move the end to 07:00 through the real time picker.
    await tester.ensureVisible(find.text('End'));
    await tester.tap(find.text('End'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '7');
    await tester.enterText(fields.at(1), '0');
    await tester.tap(find.text('AM'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(
      find.text('22:00–07:00 · No alerts during this time'),
      findsOneWidget,
    );
    expect(find.text('Runs overnight · 9 h'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(NotificationSettings.quietHoursStartKey), 22 * 60);
    expect(prefs.getInt(NotificationSettings.quietHoursEndKey), 7 * 60);
    expect(prefs.getBool(NotificationSettings.quietHoursEnabledKey), isTrue);

    // The stored window still wraps midnight: 23:30 is quiet, 12:00 is not.
    expect(
      BackgroundNotifier.I.settings.inQuietHours(DateTime(2026, 1, 1, 23, 30)),
      isTrue,
    );
    expect(
      BackgroundNotifier.I.settings.inQuietHours(DateTime(2026, 1, 1, 12, 0)),
      isFalse,
    );
  });

  testWidgets('a channel sound persists through the notifier', (tester) async {
    SharedPreferences.setMockInitialValues({});
    BackgroundNotifier.I.resetForTest();
    addTearDown(BackgroundNotifier.I.resetForTest);

    await _pump(
      tester,
      V2NotificationsPageData(
        onSoundChanged: (id, sound) {
          final channel = OvidChannel.values.firstWhere((c) => c.key == id);
          BackgroundNotifier.I.setChannelSound(channel, switch (sound) {
            V2NotificationSound.chime => NotificationSound.chime,
            V2NotificationSound.system => NotificationSound.system,
            V2NotificationSound.silent => NotificationSound.silent,
          });
        },
      ),
    );

    final row = find.byKey(const ValueKey<String>('sound-row-agent_updates'));
    await tester.ensureVisible(row);
    await tester.tap(find.descendant(of: row, matching: find.text('System')));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(NotificationSettings.soundKey(OvidChannel.agentUpdates)),
      'system',
    );
    expect(
      BackgroundNotifier.I.settings.sounds[OvidChannel.agentUpdates],
      NotificationSound.system,
    );
  });
}

void _ignoreTime(TimeOfDay _) {}
