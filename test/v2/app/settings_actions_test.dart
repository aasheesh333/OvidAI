import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/background_notifications.dart';
import 'package:ovid_ai/core/cloud_usage_store.dart';
import 'package:ovid_ai/core/presets.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/v2/app/v2_settings_actions.dart';

/// Settings actions that used to lie or double-ask: the channel switch must
/// never touch the account-wide flag, deleting a preset must not ask a second
/// time, and a preset created from the screen must be persisted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late CloudUsageStore usage;
  late V2SettingsActions actions;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    usage = CloudUsageStore.acquire(app);
    actions = V2SettingsActions(usage);
    PresetRegistry.clearCustom();
    BackgroundNotifier.I.resetForTest();
    BackgroundNotifier.I.invokeOverrideForTest = (method, args) async => null;
  });

  tearDown(() {
    usage.dispose();
    BackgroundNotifier.I.resetForTest();
    PresetRegistry.clearCustom();
    AppState.resetTestInstance();
  });

  test('a channel switch never flips the account-wide switch', () async {
    await app.setNotificationsEnabled(true);

    await actions.setNotificationChannel(
      OvidChannel.agentUpdates.key,
      false,
    );

    expect(
      BackgroundNotifier.I.settings.enabled[OvidChannel.agentUpdates],
      isFalse,
      reason: 'the per-channel preference is what the row edits',
    );
    expect(
      app.notificationsEnabled,
      isTrue,
      reason: 'the master switch has its own action',
    );
  });

  test('deletePreset does not confirm a second time', () async {
    app.saveCustomPresetForTest({
      'id': 'custom_1',
      'label': 'Reviewer',
      'description': 'Reviews diffs',
    });
    expect(PresetRegistry.all.any((p) => p.id == 'custom_1'), isTrue);

    // No BuildContext is supplied: a second confirmation would need one and
    // would throw. The screen already asked.
    await actions.deletePreset('custom_1');

    expect(PresetRegistry.all.any((p) => p.id == 'custom_1'), isFalse);
  });

  testWidgets('account deletion never claims success without the service', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => actions.deleteAccount(context),
              child: const Text('Delete account'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    // The confirmation is real; accept it.
    await tester.tap(find.text('Delete account').last);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Deletion scheduled'),
      findsNothing,
      reason: 'no receipt means no deletion was scheduled',
    );
    expect(
      find.textContaining('Verify the current account'),
      findsOneWidget,
      reason: 'the refusal is reported instead of a fake success',
    );
  });
}
