import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/legal_links.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/login_gate.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:ovid_ai/ui/widgets/external_link.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_login_gate_test.dart' show GateService;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Uri> launched;
  var launchResult = true;

  setUp(() {
    launched = [];
    launchResult = true;
    externalLinkLauncherForTest = (uri) async {
      launched.add(uri);
      return launchResult;
    };
  });
  tearDown(() => externalLinkLauncherForTest = null);

  group('login', () {
    setUp(
      () => SharedPreferences.setMockInitialValues({'ovid_welcomed': true}),
    );

    testWidgets('exposes Terms and Privacy as 48dp links before sign-up', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final service = GateService()..isAvailable = true;
      service.initialization.complete();
      await tester.pumpWidget(
        MaterialApp(
          home: LoginGate(
            service: service,
            bindCloud: () async {},
            child: const Text('Protected app'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final (label, url) in [
        ('Terms of Service', LegalLinks.terms),
        ('Privacy Policy', LegalLinks.privacyPolicy),
      ]) {
        final link = find.widgetWithText(ExternalLinkButton, label);
        await tester.ensureVisible(link);
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(link),
          matchesSemantics(
            label: label,
            isLink: true,
            hasTapAction: true,
          ),
        );
        final size = tester.getSize(
          find.ancestor(of: find.text(label), matching: find.byType(TextButton)),
        );
        expect(size.height, greaterThanOrEqualTo(48));
        expect(size.width, greaterThanOrEqualTo(48));
        await tester.tap(link);
        await tester.pump();
        expect(launched.last, Uri.parse(url));
      }
      expect(find.text('Protected app'), findsNothing);
      handle.dispose();
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    });
  });

  group('settings', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      AppState.resetTestInstance();
      AppState.createForTest();
      AgentService.I.debugPauseScheduleTimerForTest(true);
    });
    tearDown(() {
      AgentService.I.debugPauseScheduleTimerForTest(false);
      AppState.resetTestInstance();
    });

    Future<void> pumpSettings(WidgetTester tester) async {
      tester.view.physicalSize = const Size(540, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const SettingsScreen()),
      );
      await tester.pump();
    }

    Future<void> reveal(WidgetTester tester, Finder target) async {
      await tester.scrollUntilVisible(
        target,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
    }

    Future<void> openAbout(WidgetTester tester) async {
      final about = find.widgetWithText(ListTile, 'About');
      await reveal(tester, about);
      await tester.tap(about);
      await tester.pumpAndSettle();
    }

    testWidgets('hub privacy row opens the dedicated policy directly', (
      tester,
    ) async {
      await pumpSettings(tester);
      final row = find.widgetWithText(ListTile, 'Privacy policy');
      await reveal(tester, row);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(launched, [Uri.parse(LegalLinks.privacyPolicy)]);
      expect(LegalLinks.privacyPolicy, isNot(LegalLinks.website));
    });

    testWidgets('failed launch offers a copy-link fallback', (tester) async {
      launchResult = false;
      await pumpSettings(tester);
      final row = find.widgetWithText(ListTile, 'Privacy policy');
      await reveal(tester, row);
      await tester.tap(row);
      await tester.pump();
      expect(find.text('Could not open ${LegalLinks.privacyPolicy}'),
          findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, 'Copy link'), findsOneWidget);
    });

    testWidgets('About links Terms and pushes the open-source LicensePage', (
      tester,
    ) async {
      await pumpSettings(tester);
      await openAbout(tester);
      await tester.tap(find.widgetWithText(ListTile, 'Terms of Service'));
      await tester.pump();
      expect(launched, [Uri.parse(LegalLinks.terms)]);
      final licenses = find.widgetWithText(ListTile, 'Open-source licenses');
      await tester.ensureVisible(licenses);
      await tester.pumpAndSettle();
      await tester.tap(licenses);
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
    });
  });
}
