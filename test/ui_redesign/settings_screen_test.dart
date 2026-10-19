// Settings navigation stays one whole-row tap target after the Wave 4 regrouping.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/settings_backup_screen.dart';
import 'package:ovid_ai/ui/settings_health_screen.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
  });
  tearDown(AppState.resetTestInstance);

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(540, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(theme: Aether.theme(), home: const SettingsScreen()));
    await tester.pump();
  }

  Future<void> openRow(WidgetTester tester, String title) async {
    await tester.scrollUntilVisible(find.text(title), 300, scrollable: find.byType(Scrollable).first);
    await tester.ensureVisible(find.text(title));
    await tester.tap(find.text(title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('Settings groups expose working response and data routes', (tester) async {
    await pumpSettings(tester);
    for (final title in ['ACCOUNT', 'CHAT', 'MODELS & KEYS', 'NOTIFICATIONS', 'DATA & PRIVACY']) {
      await tester.scrollUntilVisible(find.text(title), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text(title), findsOneWidget);
    }
    expect(find.byType(AetherCard), findsWidgets);
    expect(find.text('Providers'), findsNothing);
  });

  testWidgets('theme controls persist the selected light and dark mode', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(Aether.dark, isFalse);
    expect(AppState.I.themeMode, 'light');
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(Aether.dark, isTrue);
    expect(AppState.I.themeMode, 'dark');
  });

  testWidgets('the Export & import row opens cloud backup', (tester) async {
    await pumpSettings(tester);
    await openRow(tester, 'Export & import');
    expect(find.byType(SettingsBackupScreen), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('the Service status row opens a route with its own back button', (tester) async {
    await pumpSettings(tester);
    await openRow(tester, 'Service status');
    expect(find.byType(SettingsHealthScreen), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 4)));
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsHealthScreen), findsNothing);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });
}
