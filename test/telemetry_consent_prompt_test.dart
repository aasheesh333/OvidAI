import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/ui/shell.dart' show TelemetryConsentPrompter;
import 'package:shared_preferences/shared_preferences.dart';

class _CanaryError {
  @override
  String toString() =>
      'sk-live-canary https://internal.example.test/private?signature=secret raw prompt';
}

class _FakeConsent extends ChangeNotifier {
  bool available = false;
  bool asked = false;
  final choices = <bool>[];
  void ready() {
    available = true;
    notifyListeners();
  }
}

void main() {
  late _FakeConsent fake;
  late TelemetryConsentPrompter prompter;

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            prompter.attach(() => context);
            return const Scaffold(body: Text('shell'));
          },
        ),
      ),
    );
  }

  setUp(() {
    fake = _FakeConsent();
    prompter = TelemetryConsentPrompter(
      source: fake,
      isAvailable: () => fake.available,
      consentAsked: () => fake.asked,
      setConsent: (allow) async {
        fake.choices.add(allow);
        fake.asked = true;
      },
    );
  });

  testWidgets('three notifies before the first frame show one dialog', (
    tester,
  ) async {
    await pumpHost(tester);
    fake.ready();
    fake.notifyListeners();
    fake.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    // Later notifications never stack a second copy.
    fake.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    prompter.detach();
  });

  testWidgets('barrier tap and back do not dismiss; a choice does', (
    tester,
  ) async {
    fake.available = true;
    await pumpHost(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tap(find.text('No thanks'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(fake.choices, [false]);
    prompter.detach();
  });

  testWidgets('does not ask when consent was already recorded', (
    tester,
  ) async {
    fake
      ..available = true
      ..asked = true;
    await pumpHost(tester);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    prompter.detach();
  });

  test('zone reporting is consent-gated, release-tagged and sanitized', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final reports = <Map<String, Object?>>[];
    final service = FirebaseService.forTest(
      initializeApp: () async {},
      configure: () async {},
      setCrashCollection: (enabled) async {},
      setAnalyticsCollection: (enabled) async {},
      crashRecorder: (error, stack, fatal) async {
        reports.add(<String, Object?>{
          'error': error,
          'fatal': fatal,
          'release': (error as dynamic).release,
          'stack': stack,
        });
      },
    );
    await service.initialize();

    await service.setConsent(false);
    expect(
      await service.recordZoneError(_CanaryError(), StackTrace.current),
      isFalse,
    );
    expect(reports, isEmpty);

    await service.setConsent(true);
    expect(
      await service.recordZoneError(_CanaryError(), StackTrace.current),
      isTrue,
    );
    expect(reports, hasLength(1));
    expect(reports.single['release'], '1.0.0+3');
    expect(reports.single['fatal'], isTrue);
    expect(reports.single['stack'].toString(), StackTrace.empty.toString());
    expect(reports.single['error'].toString(), 'Error');
    expect(
      reports.single.toString(),
      isNot(anyOf(
        contains('sk-live-canary'),
        contains('internal.example.test'),
        contains('signature=secret'),
        contains('raw prompt'),
      )),
    );
  });

  test('unconfigured zone reporting returns false after real init failures', () async {
    var crashCalls = 0;
    final service = FirebaseService.forTest(
      initializeApp: () async { throw StateError('not configured'); },
      configure: () async {},
      setCrashCollection: (enabled) async {},
      setAnalyticsCollection: (enabled) async {},
      crashRecorder: (error, stack, fatal) async {
        crashCalls += 1;
      },
    );

    await expectLater(service.initialize(), throwsStateError);
    await service.initializeCrashReporting();
    expect(service.isAvailable, isFalse);
    expect(
      await service.recordZoneError(StateError('boot failed'), StackTrace.current),
      isFalse,
    );
    expect(crashCalls, 0);
  });
}
