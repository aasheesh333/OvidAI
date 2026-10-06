import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/health_service.dart';
import 'package:ovid_ai/core/settings_actions.dart';
import 'package:ovid_ai/ui/settings_action_widgets.dart';
import 'package:ovid_ai/ui/settings_health_screen.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('health cancellation remains pending until worker settles', (
    tester,
  ) async {
    final stopped = Completer<void>();
    final health = HealthService(
      installed: () async => true,
      exec: (_) async => (127, 'missing'),
      workspace: () async {},
      providerConfigured: () => false,
      repairWorker: (_, cancellation, _) async {
        await stopped.future;
        cancellation.throwIfCancelled();
      },
    );
    await tester.pumpWidget(
      MaterialApp(home: SettingsHealthScreen(service: health)),
    );
    await tester.pumpAndSettle();
    final firstCheckbox = find.byType(Checkbox, skipOffstage: false).first;
    await tester.ensureVisible(firstCheckbox);
    await tester.pumpAndSettle();
    await tester.tap(firstCheckbox);
    await tester.pumpAndSettle();
    // The repair controls may have been recycled once the list scrolled to
    // reach a repairable runtime; scroll back up before driving them.
    await tester.scrollUntilVisible(
      find.text('Repair selected runtimes'),
      -300,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repair selected runtimes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel repair'));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for worker to stop…'), findsOneWidget);
    stopped.complete();
    await tester.pumpAndSettle();
    expect(find.textContaining('Repair cancelled'), findsOneWidget);
    expect(find.text('Selected runtime checks now pass.'), findsNothing);
  });
  testWidgets(
    'actual memory control persists and survives reopening settings',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      AppState.I.memoryEnabled = true;
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      final memory = find.widgetWithText(SettingsSwitchTile, 'Memory');
      await tester.scrollUntilVisible(memory, 300);
      final memorySwitch = find.descendant(
        of: memory,
        matching: find.byType(Switch),
      );
      await tester.ensureVisible(memorySwitch);
      await tester.pumpAndSettle();
      await tester.tap(memorySwitch);
      await tester.pumpAndSettle();
      expect(
        (await SharedPreferences.getInstance()).getBool('ovid_memory_enabled'),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.scrollUntilVisible(memory, 300);
      expect(
        tester
            .widget<Switch>(
              find.descendant(of: memory, matching: find.byType(Switch)),
            )
            .value,
        isFalse,
      );
      AppState.I.memoryEnabled = true;
    },
  );
  test('readback rejects setters that silently fail persistence', () async {
    SharedPreferences.setMockInitialValues({'setting': false});
    await expectLater(
      SettingsActions.persist('setting', true, () async {}),
      throwsStateError,
    );
    await SettingsActions.persist('setting', true, () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('setting', true);
    });
    expect((await SharedPreferences.getInstance()).getBool('setting'), isTrue);
  });

  testWidgets(
    'pending toggle blocks duplicate writes and failed save is visible',
    (tester) async {
      final done = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsSwitchTile(
              title: 'Memory',
              subtitleOn: 'on',
              subtitleOff: 'off',
              icon: Icons.memory,
              listenable: ValueNotifier(false),
              getter: () => false,
              setter: (_) {
                calls++;
                return done.future;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.byType(Switch));
      expect(calls, 1);
      done.completeError(StateError('storage unavailable'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not save Memory'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    },
  );

  testWidgets(
    'reset without owner is disabled, partial result never says all deleted',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsResetScreen()));
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsResetScreen(
            reset: () async => const SettingsResetResult(
              completed: ['sessions'],
              failures: {'keys': 'locked'},
            ),
          ),
        ),
      );
      await tester.tap(find.text('Delete all data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete everything'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Incomplete reset'), findsOneWidget);
      expect(find.textContaining('keys: locked'), findsOneWidget);
      expect(find.text('All data deleted.'), findsNothing);
    },
  );

  testWidgets(
    'health exposes unavailable worker and configuration separately at large font',
    (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final health = HealthService(
        installed: () async => true,
        exec: (_) async => (127, 'not found'),
        workspace: () async {},
        providerConfigured: () => false,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: SettingsHealthScreen(service: health),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('Targeted repair unavailable'),
        300,
      );
      expect(
        find.textContaining('Targeted repair unavailable'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('AI provider configuration'),
        500,
      );
      expect(find.textContaining('Missing configuration'), findsOneWidget);
    },
  );
}
