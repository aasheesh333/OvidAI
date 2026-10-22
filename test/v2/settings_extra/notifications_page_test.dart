import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/background_notifications.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/settings_rows.dart';
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
  testWidgets('renders one master switch, the wired channels, quiet hours and '
      'one sound row', (tester) async {
    await _pump(tester, const V2NotificationsPageData());

    expect(find.text('Notifications'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('notifications-master-switch')),
      findsOneWidget,
    );
    expect(find.text('Run finished'), findsOneWidget);
    expect(find.text('Schedule results'), findsOneWidget);
    expect(find.text('Quiet hours'), findsOneWidget);
    expect(find.text('22:00–08:00'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('notifications-sound-row')),
      findsOneWidget,
    );
    // One sound for every channel, not a chip row per channel.
    expect(find.text('Ovid chime'), findsOneWidget);

    // Channels with no backend are removed, and switch rows carry no
    // description line.
    expect(find.text('Shares and invites'), findsNothing);
    expect(find.text('Collaboration'), findsNothing);
    expect(find.text('New sign-ins'), findsNothing);
    expect(find.text('Billing'), findsNothing);
    expect(find.text('When Ovid completes a task.'), findsNothing);
    expect(find.text('When a scheduled run finishes.'), findsNothing);
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, const V2NotificationsPageData(), dark: true);

    expect(find.text('Run finished'), findsOneWidget);
    expect(find.text('Quiet hours'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('notifications-sound-row')),
      findsOneWidget,
    );
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

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(master, isFalse);
    expect(
      tester
          .widget<Switch>(
            find.byKey(
              const ValueKey<String>('notification-switch-run_finished'),
            ),
          )
          .onChanged,
      isNull,
    );
  });

  testWidgets('master off disables the channels and the sound row', (
    tester,
  ) async {
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

    final channel = find.byKey(
      const ValueKey<String>('notification-switch-run_finished'),
    );
    expect(tester.widget<Switch>(channel).onChanged, isNull);
    await tester.tap(channel);
    await tester.pumpAndSettle();
    expect(toggles, 0);

    final sound = find.byKey(const ValueKey<String>('notifications-sound-row'));
    await tester.ensureVisible(sound);
    await tester.tap(sound);
    await tester.pumpAndSettle();
    expect(sounds, 0);
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
    expect(find.text('Get notified when a run finishes'), findsOneWidget);

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

    expect(
      find.byKey(const ValueKey<String>('notifications-blocked-banner')),
      findsOneWidget,
    );
    final button = find.text('Open settings');
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

  testWidgets('a channel with no backend is removed, not a fake switch', (
    tester,
  ) async {
    var toggles = 0;
    await _pump(tester, V2NotificationsPageData(onToggle: (_, _) => toggles++));

    expect(
      find.byKey(const ValueKey<String>('notification-switch-shares_invites')),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey<String>('notification-unavailable-shares_invites'),
      ),
      findsNothing,
    );
    expect(find.text('Shares and invites'), findsNothing);
    // The contract bans the "not available yet" placeholder.
    expect(find.textContaining('Not available'), findsNothing);
    expect(toggles, 0);
  });

  testWidgets('quiet hours is one row that shows the range', (tester) async {
    await _pump(tester, const V2NotificationsPageData());

    expect(
      find.byKey(const ValueKey<String>('notifications-quiet-hours-row')),
      findsOneWidget,
    );
    expect(find.text('22:00–08:00'), findsOneWidget);
    // The range is edited in a sheet, not as two extra rows on the page.
    expect(find.text('Start'), findsNothing);
    expect(find.text('End'), findsNothing);
  });

  testWidgets('quiet hours shows the range and toggles', (tester) async {
    bool? quietEnabled;
    await _pump(
      tester,
      V2NotificationsPageData(
        onQuietHoursEnabledChanged: (value) => quietEnabled = value,
      ),
    );

    expect(find.text('22:00–08:00'), findsOneWidget);

    final toggle = find.byKey(const ValueKey<String>('quiet-hours-switch'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(quietEnabled, isFalse);
    expect(find.text('Off'), findsOneWidget);
  });

  testWidgets('tapping the quiet hours row turns it on when it is off', (
    tester,
  ) async {
    bool? quietEnabled;
    await _pump(
      tester,
      V2NotificationsPageData(
        quietHoursEnabled: false,
        onQuietHoursEnabledChanged: (value) => quietEnabled = value,
      ),
    );

    final row = find.byKey(
      const ValueKey<String>('notifications-quiet-hours-row'),
    );
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(quietEnabled, isTrue);
    expect(find.text('22:00–08:00'), findsOneWidget);
  });

  testWidgets('quiet hours row opens the caller editor when it has no value', (
    tester,
  ) async {
    var quietTaps = 0;
    await _pump(
      tester,
      V2NotificationsPageData(onQuietHours: () => quietTaps++),
    );

    final row = find.byKey(
      const ValueKey<String>('notifications-quiet-hours-row'),
    );
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(quietTaps, 1);
  });

  testWidgets('changes the quiet hours start time', (tester) async {
    TimeOfDay? start;
    await _pump(
      tester,
      V2NotificationsPageData(
        onQuietHoursStartChanged: (value) => start = value,
      ),
    );

    final row = find.byKey(
      const ValueKey<String>('notifications-quiet-hours-row'),
    );
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.text('Start'), findsOneWidget);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    expect(find.text('Quiet hours Start'), findsOneWidget);

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '9');
    await tester.enterText(fields.at(1), '30');
    final am = find.text('AM');
    if (am.evaluate().isNotEmpty) await tester.tap(am);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(start, const TimeOfDay(hour: 9, minute: 30));
  });

  testWidgets('quiet hours row edits the range in a sheet', (tester) async {
    TimeOfDay? start;
    TimeOfDay? end;
    await _pump(
      tester,
      V2NotificationsPageData(
        onQuietHoursStartChanged: (value) => start = value,
        onQuietHoursEndChanged: (value) => end = value,
      ),
    );

    final row = find.byKey(
      const ValueKey<String>('notifications-quiet-hours-row'),
    );
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.text('Start'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);

    await tester.tap(find.text('End'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '7');
    await tester.enterText(fields.at(1), '0');
    final am = find.text('AM');
    if (am.evaluate().isNotEmpty) await tester.tap(am);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(end, const TimeOfDay(hour: 7, minute: 0));
    expect(start, isNull);
  });

  testWidgets('one sound choice applies to every channel', (tester) async {
    final calls = <String, V2NotificationSound>{};
    await _pump(
      tester,
      V2NotificationsPageData(onSoundChanged: (id, sound) => calls[id] = sound),
    );

    final row = find.byKey(const ValueKey<String>('notifications-sound-row'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.text('System'), findsOneWidget);
    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();

    expect(calls, {
      'agent_updates': V2NotificationSound.system,
      'scheduler_results': V2NotificationSound.system,
    });
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Ovid chime'), findsNothing);
  });

  testWidgets('choosing Silent turns every channel silent', (tester) async {
    final calls = <String, V2NotificationSound>{};
    await _pump(
      tester,
      V2NotificationsPageData(onSoundChanged: (id, sound) => calls[id] = sound),
    );

    final row = find.byKey(const ValueKey<String>('notifications-sound-row'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Silent'));
    await tester.pumpAndSettle();

    expect(calls, {
      'agent_updates': V2NotificationSound.silent,
      'scheduler_results': V2NotificationSound.silent,
    });
    expect(find.text('Silent'), findsOneWidget);
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

    expect(find.text('That did not work'), findsOneWidget);
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

    await tester.scrollUntilVisible(
      find.text('Quiet hours'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
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
    expect(find.text('Get notified when a run finishes'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Quiet hours'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('centres the content at 600 dp', (tester) async {
    await _pump(
      tester,
      const V2NotificationsPageData(),
      size: const Size(600, 1000),
    );

    final list = find.byType(V2SettingsRowList).first;
    expect(tester.getSize(list).width, lessThanOrEqualTo(640));
    expect(tester.getCenter(list).dx, closeTo(300, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('quiet hours sheet fits 320 dp at 200% text', (tester) async {
    await _pump(
      tester,
      V2NotificationsPageData(
        onQuietHoursStartChanged: (_) {},
        onQuietHoursEndChanged: (_) {},
      ),
      size: const Size(320, 640),
      textScale: 2,
    );

    final row = find.byKey(
      const ValueKey<String>('notifications-quiet-hours-row'),
    );
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.text('Start'), findsOneWidget);
    expect(find.text('End'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion still shows every section', (tester) async {
    await _pump(
      tester,
      const V2NotificationsPageData(notificationsBlocked: true),
      reduceMotion: true,
    );

    for (final label in const [
      'Notifications are blocked',
      'Run finished',
      'Quiet hours',
      'Sound',
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
    expect(toggle.flagsCollection.isEnabled, Tristate.isFalse);
    expect(toggle.flagsCollection.isToggled, Tristate.isTrue);

    final master = tester
        .getSemantics(
          find.byKey(const ValueKey<String>('notifications-master-switch')),
        )
        .getSemanticsData();
    expect(master.flagsCollection.isEnabled, Tristate.isFalse);

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
    expect(toggle.flagsCollection.isEnabled, isNot(Tristate.isFalse));

    semantics.dispose();
  });

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

  testWidgets('a zero-length quiet window is shown as off, not all day', (
    tester,
  ) async {
    await _pump(
      tester,
      const V2NotificationsPageData(
        quietHoursStart: TimeOfDay(hour: 22, minute: 0),
        quietHoursEnd: TimeOfDay(hour: 22, minute: 0),
      ),
    );

    expect(find.text('Off'), findsOneWidget);
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
  });

  testWidgets('a parent rebuild with the same snapshot keeps the tap', (
    tester,
  ) async {
    await _pump(tester, V2NotificationsPageData(onToggle: (_, _) {}));

    final toggle = find.byKey(
      const ValueKey<String>('notification-switch-run_finished'),
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(toggle).value, isFalse);

    // A fresh data object with the same values is what a parent `setState`
    // produces; it must not undo the optimistic tap.
    await _pump(tester, V2NotificationsPageData(onToggle: (_, _) {}));
    expect(tester.widget<Switch>(toggle).value, isFalse);
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

    expect(find.text('22:00–06:00'), findsOneWidget);

    final row = find.byKey(
      const ValueKey<String>('notifications-quiet-hours-row'),
    );
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    await tester.tap(find.text('End'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '7');
    await tester.enterText(fields.at(1), '0');
    final am = find.text('AM');
    if (am.evaluate().isNotEmpty) await tester.tap(am);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('22:00–07:00'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(NotificationSettings.quietHoursStartKey), 22 * 60);
    expect(prefs.getInt(NotificationSettings.quietHoursEndKey), 7 * 60);
    expect(prefs.getBool(NotificationSettings.quietHoursEnabledKey), isTrue);
  });

  testWidgets('the single sound choice persists for every channel', (
    tester,
  ) async {
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

    final row = find.byKey(const ValueKey<String>('notifications-sound-row'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text('System'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(NotificationSettings.soundKey(OvidChannel.agentUpdates)),
      'system',
    );
    expect(
      prefs.getString(
        NotificationSettings.soundKey(OvidChannel.schedulerResults),
      ),
      'system',
    );
  });

  testWidgets('OS denial is the master truth and cannot be overridden', (
    tester,
  ) async {
    var changes = 0;
    var opened = 0;
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      V2NotificationsPageData(
        notificationsBlocked: true,
        masterEnabled: true,
        onMasterChanged: (_) => changes++,
        onOpenSystem: () => opened++,
      ),
    );

    final toggle = find.byKey(
      const ValueKey<String>('notifications-master-switch'),
    );
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(tester.widget<Switch>(toggle).onChanged, isNull);
    expect(find.text('Blocked in system settings'), findsOneWidget);

    final data = tester.getSemantics(toggle).getSemanticsData();
    expect(data.value, 'Blocked in system settings');
    expect(data.flagsCollection.isToggled, Tristate.isFalse);
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(changes, 0);

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    semantics.dispose();
  });

  testWidgets('an unavailable service is named and every control is disabled', (
    tester,
  ) async {
    var calls = 0;
    await _pump(
      tester,
      V2NotificationsPageData(
        serviceAvailable: false,
        onMasterChanged: (_) => calls++,
        onToggle: (_, _) => calls++,
        onQuietHoursEnabledChanged: (_) => calls++,
        onSoundChanged: (_, _) => calls++,
      ),
    );

    expect(find.text('Notifications unavailable'), findsOneWidget);
    expect(find.text('This device cannot show notifications.'), findsOneWidget);

    final master = find.byKey(
      const ValueKey<String>('notifications-master-switch'),
    );
    final channel = find.byKey(
      const ValueKey<String>('notification-switch-run_finished'),
    );
    final quiet = find.byKey(const ValueKey<String>('quiet-hours-switch'));
    final sound = find.byKey(const ValueKey<String>('notifications-sound-row'));

    expect(tester.widget<Switch>(master).value, isFalse);
    expect(tester.widget<Switch>(master).onChanged, isNull);
    expect(tester.widget<Switch>(channel).onChanged, isNull);
    expect(tester.widget<Switch>(quiet).onChanged, isNull);
    expect(tester.widget<V2SettingsRow>(sound).onTap, isNull);

    await tester.tap(master);
    await tester.ensureVisible(channel);
    await tester.tap(channel);
    await tester.ensureVisible(quiet);
    await tester.tap(quiet);
    await tester.ensureVisible(sound);
    await tester.tap(sound);
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('saving keeps the chosen values but blocks a second write', (
    tester,
  ) async {
    var calls = 0;
    await _pump(
      tester,
      V2NotificationsPageData(
        saving: true,
        onMasterChanged: (_) => calls++,
        onToggle: (_, _) => calls++,
        onQuietHoursEnabledChanged: (_) => calls++,
        onSoundChanged: (_, _) => calls++,
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('notifications-saving')),
      findsOneWidget,
    );
    expect(find.text('Saving…'), findsOneWidget);

    final master = find.byKey(
      const ValueKey<String>('notifications-master-switch'),
    );
    final channel = find.byKey(
      const ValueKey<String>('notification-switch-run_finished'),
    );
    final quiet = find.byKey(const ValueKey<String>('quiet-hours-switch'));
    final sound = find.byKey(const ValueKey<String>('notifications-sound-row'));

    expect(tester.widget<Switch>(master).value, isTrue);
    expect(tester.widget<Switch>(master).onChanged, isNull);
    expect(tester.widget<Switch>(channel).onChanged, isNull);
    expect(tester.widget<Switch>(quiet).onChanged, isNull);
    expect(tester.widget<V2SettingsRow>(sound).onTap, isNull);

    await tester.tap(master);
    await tester.ensureVisible(channel);
    await tester.tap(channel);
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('new sign-ins is a real channel that persists', (tester) async {
    String? toggledId;
    bool? toggledValue;
    await _pump(
      tester,
      V2NotificationsPageData(
        security: const [
          V2NotificationSetting(
            id: 'new_signins',
            title: 'New sign-ins',
            description: 'When a new device signs in.',
            value: true,
          ),
        ],
        onToggle: (id, value) {
          toggledId = id;
          toggledValue = value;
        },
      ),
    );

    final toggle = find.byKey(
      const ValueKey<String>('notification-switch-new_signins'),
    );
    expect(toggle, findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(toggledId, 'new_signins');
    expect(toggledValue, isFalse);
  });

  testWidgets('quiet hours rejects a zero-length range', (tester) async {
    TimeOfDay? start;
    TimeOfDay? end;
    await _pump(
      tester,
      V2NotificationsPageData(
        quietHoursStart: const TimeOfDay(hour: 22, minute: 0),
        quietHoursEnd: const TimeOfDay(hour: 6, minute: 0),
        onQuietHoursStartChanged: (value) => start = value,
        onQuietHoursEndChanged: (value) => end = value,
      ),
    );

    final row = find.byKey(
      const ValueKey<String>('notifications-quiet-hours-row'),
    );
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    await tester.tap(find.text('End'));
    await tester.pumpAndSettle();
    var fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '10');
    await tester.enterText(fields.at(1), '00');
    final pm = find.text('PM');
    if (pm.evaluate().isNotEmpty) await tester.tap(pm);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('Start and end must differ.'), findsOneWidget);
    expect(start, isNull);
    expect(end, isNull);
    expect(find.text('22:00–06:00'), findsOneWidget);

    await tester.tap(find.text('End'));
    await tester.pumpAndSettle();
    fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '7');
    await tester.enterText(fields.at(1), '0');
    final am = find.text('AM');
    if (am.evaluate().isNotEmpty) await tester.tap(am);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(end, const TimeOfDay(hour: 7, minute: 0));
    expect(find.text('Start and end must differ.'), findsNothing);
  });

  testWidgets('quiet hours announces the range and its state', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, const V2NotificationsPageData());

    final data = tester
        .getSemantics(find.byKey(const ValueKey<String>('quiet-hours-switch')))
        .getSemanticsData();
    expect(data.label, 'Quiet hours');
    expect(data.value, '22:00–08:00');
    expect(data.flagsCollection.isToggled, Tristate.isTrue);

    semantics.dispose();
  });

  testWidgets('every switch row is at least 56 dp', (tester) async {
    await _pump(
      tester,
      const V2NotificationsPageData(
        security: [
          V2NotificationSetting(
            id: 'new_signins',
            title: 'New sign-ins',
            description: 'When a new device signs in.',
          ),
        ],
      ),
      size: const Size(800, 1400),
    );

    for (final key in const [
      'notification-row-master',
      'notification-row-run_finished',
      'notification-row-schedule_results',
      'notification-row-new_signins',
      'notifications-quiet-hours-row',
      'notifications-sound-row',
    ]) {
      expect(
        tester.getSize(find.byKey(ValueKey<String>(key))).height,
        greaterThanOrEqualTo(56),
        reason: '$key is shorter than a touch row',
      );
    }
  });

  for (final width in const [320.0, 412.0, 600.0, 800.0, 1024.0, 1280.0]) {
    for (final textScale in const [1.0, 2.0]) {
      for (final dark in const [false, true]) {
        testWidgets(
          'fits ${width.toInt()} dp at ${textScale}x (${dark ? 'dark' : 'light'})',
          (tester) async {
            await _pump(
              tester,
              const V2NotificationsPageData(
                notificationsBlocked: true,
                security: [
                  V2NotificationSetting(
                    id: 'new_signins',
                    title: 'New sign-ins',
                    description: 'When a new device signs in.',
                  ),
                ],
              ),
              size: Size(width, 900),
              textScale: textScale,
              dark: dark,
            );

            expect(tester.takeException(), isNull);

            await tester.scrollUntilVisible(
              find.byKey(const ValueKey<String>('notifications-sound-row')),
              200,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);

            final list = find.byType(V2SettingsRowList).first;
            expect(tester.getSize(list).width, lessThanOrEqualTo(640));
            if (width >= 600) {
              expect(tester.getCenter(list).dx, closeTo(width / 2, 0.5));
            }
          },
        );
      }
    }
  }
}
