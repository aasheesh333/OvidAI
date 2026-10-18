import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(() {
    AppState.resetTestInstance();
  });

  testWidgets('Settings no longer lists Private sync or Collaboration', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const SettingsScreen()),
    );
    await tester.pump();

    // Sharing (Read only / Collab) lives on the chat's share sheet now.
    expect(find.text('Private sync'), findsNothing);
    expect(find.text('Collaboration'), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
  });
}
