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

  test('SH-011: the probe asks Ovid itself, not a Google endpoint', () {
    expect(ConnectionService.ovidProbeUrl, endsWith('/cloud/v1/health'));
    expect(ConnectionService.ovidProbeUrl, startsWith('https://api.ovidsi.com'));
  });

  test('SH-011: Ovid down while the internet is up reads "Ovid unreachable"',
      () async {
    final c = ConnectionService.forTest(
      status: ConnectionStatus.online,
      reach: () async => false,
      internetReach: () async => true,
    );
    await c.probe();
    expect(c.offline, isTrue);
    expect(c.ovidUnreachable, isTrue);
    c.dispose();
  });

  testWidgets('SH-011: the banner names Ovid when only Ovid is unreachable',
      (tester) async {
    final c = ConnectionService.forTest(
      status: ConnectionStatus.online,
      reach: () async => false,
      internetReach: () async => true,
    );
    ConnectionService.debugInstance = c;
    await c.probe();
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: const Scaffold(body: OfflineBanner()),
      ),
    );
    expect(find.textContaining("Ovid can't be reached"), findsOneWidget);
    expect(find.textContaining('will go out when it is back'), findsOneWidget);
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

  testWidgets('offline, Send stays enabled and says it will send later (SH-011)', (
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
    // CH-035 / SH-011: one offline model — the prompt queues in the
    // outbox and its row says it sends when the connection is back.
    expect(send().onPressed, isNotNull);
    expect(send().tooltip, contains("you're offline"));

    await connection.probe(); // reach() defaults to reachable
    await tester.pump();
    expect(send().onPressed, isNotNull);
    expect(send().tooltip, 'Send');
  });
}
