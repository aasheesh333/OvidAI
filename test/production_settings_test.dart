import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/reset_coordinator.dart';

void main() {
  test('app registration installs concrete account owners', () {
    final app = AppState.createForTest();
    app.registerProductionAccountFeatures();
    expect(app.privateSync, isNotNull);
    expect(app.collaboration, isNotNull);
    app.setAccountFeaturesForeground(false);
    AppState.resetTestInstance();
  });

  test('feature reset uses its own clear and durable readback', () async {
    var syncData = true;
    var collaborationData = true;
    AccountLifecycleDependencies owner(
      void Function() clear,
      bool Function() empty,
    ) => AccountLifecycleDependencies(
      onFence: () {},
      onRevoke: () {},
      onBind: (_, _) {},
      onClear: clear,
      onVerifyEmpty: empty,
    );
    final integration = AccountLifecycleIntegration.production(
      dependencies: owner(() {}, () => false),
      resetDependencies: {
        'private-sync': owner(() => syncData = false, () => !syncData),
        'collaboration': owner(
          () => collaborationData = false,
          () => !collaborationData,
        ),
      },
    );
    final sync = integration.asResetStore('private-sync');
    await sync.stage();
    await sync.delete();
    expect(await sync.verifyDeleted(), true);
    expect(collaborationData, true);
    final collaboration = integration.asResetStore('collaboration');
    expect(await collaboration.verifyDeleted(), false);
    await collaboration.delete();
    expect(await collaboration.verifyDeleted(), true);
  });
  testWidgets(
    'default private sync cannot report enrollment without configuration',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: PrivateSyncSettingsScreen()),
      );
      expect(find.textContaining('Not configured'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Enable private sync'),
      );
      expect(button.onPressed, isNull);
    },
  );
}
