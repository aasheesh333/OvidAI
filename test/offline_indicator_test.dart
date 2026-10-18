import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/connection_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/chat_screen.dart';
import 'package:ovid_ai/ui/shell.dart' show OfflineBanner;
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    app.seenWelcomeVersion = AppState.welcomeVersion;
    app.sessions.clear();
    app.activeSessionId = null;
  });

  tearDown(() {
    ConnectionService.debugInstance = null;
    AppState.resetTestInstance();
  });

  test('offline re-check timer runs only while offline', () async {
    var reachable = false;
    final c = ConnectionService.forTest(
      status: ConnectionStatus.online,
      reach: () async => reachable,
      periodicRecheck: true,
    );
    await c.probe();
    expect(c.offline, isTrue);
    reachable = true;
    await c.probe();
    expect(c.offline, isFalse);
    c.dispose();
  });

  testWidgets('offline banner shows and Retry clears it once reachable', (
    tester,
  ) async {
    var reachable = false;
    ConnectionService.debugInstance = ConnectionService.forTest(
      status: ConnectionStatus.offline,
      reach: () async => reachable,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(body: OfflineBanner()),
      ),
    );
    expect(find.byKey(const ValueKey('offline-banner')), findsOneWidget);
    expect(find.textContaining("You're offline"), findsOneWidget);

    reachable = true;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('offline-banner')), findsNothing);
  });

  testWidgets('Send is disabled with a "You\'re offline" tooltip', (
    tester,
  ) async {
    final connection = ConnectionService.forTest(
      status: ConnectionStatus.offline,
    );
    ConnectionService.debugInstance = connection;
    final app = AppState.I;
    final s = ChatSession(id: 'off', title: 'Off', model: 'm');
    app.sessions.add(s);
    app.activeSessionId = s.id;
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const ChatScreen()),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'hello');
    await tester.pump();

    AetherPrimaryButton send() => tester.widget<AetherPrimaryButton>(
      find.ancestor(
        of: find.byIcon(Icons.arrow_upward),
        matching: find.byType(AetherPrimaryButton),
      ),
    );
    expect(send().onPressed, isNull);
    expect(send().tooltip, "You're offline");

    await connection.probe(); // reach() defaults to reachable
    await tester.pump();
    expect(send().onPressed, isNotNull);
    expect(send().tooltip, 'Send');
  });
}
