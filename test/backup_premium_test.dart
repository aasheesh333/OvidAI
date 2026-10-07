import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/settings_backup_screen.dart';

void main() {
  setUp(() {
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(AppState.resetTestInstance);

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: SettingsBackupScreen()),
    );
    await tester.pump();
  }

  testWidgets('describes the export-ready archive scope and share action', (
    tester,
  ) async {
    await pumpScreen(tester);

    expect(find.text('Export-ready archive'), findsOneWidget);
    expect(find.textContaining('Transcript-only export'), findsOneWidget);
    expect(find.textContaining('ZIP archive'), findsOneWidget);
    expect(find.text('Share archive'), findsOneWidget);
    expect(find.textContaining('Share / save'), findsOneWidget);
  });

  testWidgets('exposes operation-specific accessible idle status', (tester) async {
    await pumpScreen(tester);

    expect(find.bySemanticsLabel('Backup status: Ready to export'), findsOneWidget);
    expect(
      find.textContaining('Restore transcript archive as new inactive sessions'),
      findsOneWidget,
    );
    expect(find.textContaining('atomic'), findsOneWidget);
    expect(find.textContaining('current account'), findsOneWidget);
  });
}
