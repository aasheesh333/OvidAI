// Wave 4 (SE-013 / SE-014 / EM-014): Service status is a real screen with
// its own Scaffold and back button, checks Ovid Cloud's capabilities through
// the public status route plus this device's sign-in and live updates, and
// never shows raw exception text.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/account_settings_client.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/push_registration_coordinator.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/settings_health_screen.dart';

ServiceStatus _status(String overall, {String agents = 'ok', String models = 'ok'}) =>
    ServiceStatus.fromJson({
      'status': overall,
      'checks': {
        'api': 'ok',
        'storage': 'ok',
        'queue': 'ok',
        'agents': agents,
        'models': models,
      },
      'checkedAt': '2026-10-19T00:00:00Z',
    });

ServiceStatusProbes _probes({
  Future<ServiceStatus> Function()? server,
  bool signedIn = true,
  bool accountOk = true,
  PushHealthSnapshot? pushHealth,
}) => ServiceStatusProbes(
  server: server ?? () async => _status('ok'),
  account: () async {
    if (!accountOk) {
      throw CloudApiException(status: 401, code: 'unauthorized', message: 'x');
    }
  },
  live: () async {},
  signedIn: () => signedIn,
  pushHealth: () =>
      pushHealth ??
      const PushHealthSnapshot(
        osPermissionGranted: true,
        channelsReady: true,
        tokenAvailable: true,
        registered: true,
      ),
);

/// Pushed as a full route the way Settings does — no host Scaffold.
Future<void> _push(WidgetTester tester, ServiceStatusProbes probes) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Aether.theme(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SettingsHealthScreen(probes: probes),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('own Scaffold, app bar title and back button', (tester) async {
    await _push(tester, _probes());
    expect(find.byType(Scaffold), findsWidgets);
    expect(find.widgetWithText(AppBar, 'Service status'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.text('Everything is working'), findsOneWidget);
  });

  testWidgets('no agent consumer shows a problem, not "operational"', (
    tester,
  ) async {
    await _push(
      tester,
      _probes(server: () async => _status('down', agents: 'down')),
    );
    expect(find.textContaining("Something isn't working"), findsOneWidget);
    expect(find.text('Not working'), findsOneWidget);
  });

  testWidgets('unreachable cloud shows human copy without exception text', (
    tester,
  ) async {
    await _push(
      tester,
      _probes(server: () async => throw StateError('Bad state: socket 10.0.0.5')),
    );
    expect(find.textContaining("couldn't reach Ovid Cloud"), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('10.0.0.5'), findsNothing);
  });

  testWidgets('a rejected sign-in marks the account row', (tester) async {
    await _push(tester, _probes(accountOk: false));
    expect(find.text('Not working'), findsOneWidget);
  });

  testWidgets('unknown OS permission prevents an all-good headline', (
    tester,
  ) async {
    await _push(
      tester,
      _probes(
        pushHealth: const PushHealthSnapshot(
          channelsReady: true,
          tokenAvailable: true,
          registered: true,
        ),
      ),
    );

    expect(
      find.text('Mostly working. Some things may be slow or unavailable.'),
      findsOneWidget,
    );
    expect(find.text('Everything is working'), findsNothing);
  });

  testWidgets(
    'push facts stay independent and token presence is not registration',
    (tester) async {
      await _push(
        tester,
        _probes(
          pushHealth: const PushHealthSnapshot(
            osPermissionGranted: true,
            channelsReady: true,
            tokenAvailable: true,
            desiredUid: 'uid-a',
            generation: 2,
            registered: false,
            lastError: 'HTTP 503',
          ),
        ),
      );

      expect(
        find.text('Mostly working. Some things may be slow or unavailable.'),
        findsOneWidget,
      );
      expect(find.text('Everything is working'), findsNothing);
      expect(find.text('OS permission'), findsOneWidget);
      expect(find.text('Notification channels'), findsOneWidget);
      expect(find.text('Push token'), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
      expect(
        find.textContaining('This device isn\'t registered for notifications'),
        findsOneWidget,
      );
      expect(find.textContaining('HTTP 503'), findsOneWidget);
    },
  );
}
