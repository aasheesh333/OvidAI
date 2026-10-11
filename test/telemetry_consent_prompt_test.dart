import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/shell.dart' show TelemetryConsentPrompter;

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
}
