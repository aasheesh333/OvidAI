// P8 Task 13 — SettingsHealthScreen becomes a thin card over cloud health.
//
// The local runtime health probes (HealthService) die with the sandbox. The
// successor is the ONE public gateway route, `GET /cloud/v1/health`, whose
// built wire shape is `{status, checks:{db, redisQ}}` (Task 5's CloudHealth).
// Both the 200-ok and 503-degraded variants carry the same body; the client
// parses them identically and the SCREEN owns the degraded presentation.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/settings_health_screen.dart';

class _FakeHealthRest extends CloudRestClient {
  _FakeHealthRest({this.result, this.error})
      : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  CloudHealth? result;
  CloudApiException? error;
  int calls = 0;

  @override
  Future<CloudHealth> health() async {
    calls++;
    if (error != null) throw error!;
    return result!;
  }
}

Widget _host(Widget child) =>
    MaterialApp(theme: Aether.theme(), home: Scaffold(body: child));

void main() {
  testWidgets('degraded health renders the banner and per-check rows',
      (tester) async {
    final rest = _FakeHealthRest(
      result: const CloudHealth(
        status: 'degraded',
        checks: CloudHealthChecks(db: true, redisQ: false),
      ),
    );

    await tester.pumpWidget(_host(SettingsHealthScreen(rest: rest)));
    await tester.pumpAndSettle();

    expect(find.text('Degraded'), findsOneWidget);
    expect(find.text('Database'), findsOneWidget);
    expect(find.text('Redis queue'), findsOneWidget);
    expect(find.text('Operational'), findsOneWidget);
    expect(find.text('Unavailable'), findsOneWidget);
  });

  testWidgets('healthy status renders no degraded banner', (tester) async {
    final rest = _FakeHealthRest(
      result: const CloudHealth(
        status: 'ok',
        checks: CloudHealthChecks(db: true, redisQ: true),
      ),
    );

    await tester.pumpWidget(_host(SettingsHealthScreen(rest: rest)));
    await tester.pumpAndSettle();

    expect(find.text('Degraded'), findsNothing);
    expect(find.text('Operational'), findsNWidgets(2));
  });

  testWidgets('a 503 unavailable envelope renders the retry affordance',
      (tester) async {
    final rest = _FakeHealthRest(
      error: CloudApiException(
        status: 503,
        code: 'unavailable',
        message: 'Ovid Cloud is temporarily unavailable.',
      ),
    );

    await tester.pumpWidget(_host(SettingsHealthScreen(rest: rest)));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    expect(
      find.textContaining('temporarily unavailable'),
      findsOneWidget,
    );

    // Retry re-runs the probe.
    rest.error = null;
    rest.result = const CloudHealth(
      status: 'ok',
      checks: CloudHealthChecks(db: true, redisQ: true),
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(rest.calls, 2);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Operational'), findsNWidgets(2));
  });
}
