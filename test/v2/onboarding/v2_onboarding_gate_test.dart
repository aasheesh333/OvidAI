import 'dart:async';
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';
import 'package:ovid_ai/core/legal_links.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_onboarding_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake auth surface: mirrors the two facts the gate trusts
/// (`isSignedIn` / `accountReady`) without Firebase.
class _FakeAuth extends ChangeNotifier implements V2OnboardingAuth {
  bool available = true;
  bool signedIn = false;
  bool ready = false;
  bool initFails = false;
  Completer<void>? initGate;
  String? socialError;
  String? accountErrorValue;

  int initCalls = 0;
  int socialCalls = 0;
  String? lastProvider;
  Object? socialFailure;

  @override
  bool get isAvailable => available;

  @override
  bool get isSignedIn => signedIn;

  @override
  bool get accountReady => signedIn && ready;

  @override
  String? get accountError => accountErrorValue;

  @override
  String get accountLabel => 'ada@example.com';

  @override
  Future<void> initialize() async {
    initCalls++;
    if (initGate != null) await initGate!.future;
    if (initFails) throw StateError('firebase unavailable');
  }

  @override
  Future<void> retryAccountLogin() async {
    if (!signedIn) return;
    ready = true;
    notifyListeners();
  }

  @override
  Future<String?> authenticateSocial(
    String providerId,
    AuthIntent intent,
  ) async {
    socialCalls++;
    lastProvider = providerId;
    final failure = socialFailure;
    if (failure != null) throw failure;
    final error = socialError;
    if (error != null) return error;
    signedIn = true;
    ready = true;
    notifyListeners();
    return null;
  }

  @override
  PhoneAuthFlow createPhoneFlow(AuthIntent intent) {
    throw UnimplementedError('phone flow is not exercised by these tests');
  }
}

/// In-memory store with controllable phases and real failure modes.
class _FakeStore extends V2OnboardingStore {
  V2OnboardingSnapshot snapshot = const V2OnboardingSnapshot(
    welcomeSeen: false,
  );
  Completer<void>? loadGate;
  bool saveFails = false;
  bool welcomeFails = false;
  int loadCalls = 0;
  bool welcomeMarked = false;
  String? savedLanguage;
  Set<String>? savedGoals;

  @override
  Future<V2OnboardingSnapshot> load({required String welcomeVersion}) async {
    loadCalls++;
    if (loadGate != null) await loadGate!.future;
    return snapshot;
  }

  @override
  Future<void> markWelcomeSeen(String version) async {
    if (welcomeFails) throw StateError('disk full');
    welcomeMarked = true;
  }

  @override
  Future<void> saveChoices({
    required String languageId,
    required Set<String> goalIds,
  }) async {
    if (saveFails) throw StateError('disk full');
    savedLanguage = languageId;
    savedGoals = Set.of(goalIds);
  }
}

Future<void> _pumpGate(
  WidgetTester tester, {
  required _FakeAuth auth,
  V2OnboardingStore? store,
  Future<bool> Function(String planId)? purchase,
  bool? testStore,
  Future<bool> Function(Uri uri)? openUrl,
  bool dark = false,
  Size size = const Size(390, 844),
  double textScale = 1,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: V2OnboardingGate(
        auth: auth,
        store: store,
        purchase: purchase,
        testStore: testStore,
        openUrl: openUrl,
        child: const Text('APP CHILD'),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // The account-check spinner animates forever; pump frames, never settle.
    await tester.pump();
    await tester.pump();
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('splash renders first while startup is pending', (tester) async {
    final auth = _FakeAuth()..initGate = Completer<void>();
    await _pumpGate(tester, auth: auth);

    expect(find.text('Ovid Si'), findsOneWidget);
    expect(find.text('Starting your agent'), findsOneWidget);
    expect(find.text('Your always-on personal agent.'), findsNothing);

    auth.initGate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('Your always-on personal agent.'), findsOneWidget);
  });

  testWidgets('a signed-in admitted account goes straight to the child', (
    tester,
  ) async {
    final auth = _FakeAuth()
      ..signedIn = true
      ..ready = true;
    await _pumpGate(tester, auth: auth);

    expect(find.text('APP CHILD'), findsOneWidget);
    expect(find.text('Your always-on personal agent.'), findsNothing);
    expect(find.text('Welcome back'), findsNothing);
  });

  testWidgets(
    'signed in but not admitted shows the account check and retries',
    (tester) async {
      final auth = _FakeAuth()..signedIn = true;
      await _pumpGate(tester, auth: auth, settle: false);

      expect(find.text('Confirming your account'), findsOneWidget);
      expect(find.text('APP CHILD'), findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('APP CHILD'), findsOneWidget);
    },
  );

  testWidgets('welcome → language → sign-in → paywall → child', (tester) async {
    final auth = _FakeAuth();
    await _pumpGate(tester, auth: auth);

    expect(find.text('Your always-on personal agent.'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('welcome-get-started')));
    expect(find.text('Which language do you think in?'), findsOneWidget);

    await _tap(tester, find.text('हिन्दी'));
    await _tap(tester, find.byKey(const Key('language-goal-continue')));
    expect(find.text('Welcome back'), findsOneWidget);

    await _tap(tester, find.text('Continue with Google'));
    expect(auth.socialCalls, 1);
    expect(auth.lastProvider, 'google.com');
    expect(find.text('Do more with Ovid Plus'), findsOneWidget);

    await _tap(tester, find.byIcon(Icons.close_rounded));
    expect(find.text('APP CHILD'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ovid_onboarding_language'), 'hi');
    expect(prefs.getString('ovid_first_goal'), 'build');
    // The reply-language preference belongs to AppState and must not be
    // overwritten with an onboarding id it can never produce.
    expect(prefs.getString('ovid_locale'), isNull);
  });

  testWidgets('email submit explains that email sign-in is unavailable', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_locale': 'en',
    });
    final auth = _FakeAuth();
    await _pumpGate(tester, auth: auth);

    expect(find.text('Welcome back'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('sign-in-email')),
      'ada@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('sign-in-password')),
      'secret-pass',
    );
    await _tap(tester, find.byKey(const Key('sign-in-submit')));

    expect(
      find.text('Email sign-in is not available yet. Use Google or phone.'),
      findsOneWidget,
    );
    // Nothing to retry: no fake "Try again" that only clears the message.
    expect(find.text('Try again'), findsNothing);
    expect(auth.socialCalls, 0);
    expect(find.text('APP CHILD'), findsNothing);
  });

  testWidgets('a failed social sign-in shows the error and stays put', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_locale': 'en',
    });
    final auth = _FakeAuth()
      ..socialError = 'Sign-in failed. Check your connection and retry.';
    await _pumpGate(tester, auth: auth);

    await _tap(tester, find.text('Continue with Google'));

    expect(
      find.text('Sign-in failed. Check your connection and retry.'),
      findsOneWidget,
    );
    expect(find.text('APP CHILD'), findsNothing);
    expect(find.text('Do more with Ovid Plus'), findsNothing);
  });

  testWidgets('an auth-layer failure is shown as its real message', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_onboarding_language': 'en',
    });
    final auth = _FakeAuth()
      ..socialFailure = FirebaseAuthException(
        code: 'network-request-failed',
      );
    await _pumpGate(tester, auth: auth);

    await _tap(tester, find.text('Continue with Google'));

    // The message comes from authError(), not a generic "sign-in failed".
    expect(
      find.text('Network unavailable. Check your connection and retry.'),
      findsOneWidget,
    );
    expect(find.text('APP CHILD'), findsNothing);
  });

  testWidgets('paywall selection passes the plan to the purchase callback', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_locale': 'en',
    });
    final auth = _FakeAuth();
    final purchased = <String>[];
    await _pumpGate(
      tester,
      auth: auth,
      purchase: (planId) async {
        purchased.add(planId);
        return false;
      },
    );

    await _tap(tester, find.text('Continue with Google'));
    expect(find.text('Do more with Ovid Plus'), findsOneWidget);

    await _tap(tester, find.text('Ovid Go'));
    await _tap(tester, find.byKey(const Key('paywall-trial')));

    // A declined purchase is not a fake success: the gate simply continues.
    expect(purchased, ['go']);
    expect(find.text('APP CHILD'), findsOneWidget);
  });

  testWidgets('finishing the welcome persists the v2 marker', (tester) async {
    final auth = _FakeAuth();
    await _pumpGate(tester, auth: auth);

    await _tap(tester, find.byKey(const Key('welcome-get-started')));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ovid_welcome_version_v2'), '1');
    expect(find.text('Which language do you think in?'), findsOneWidget);
  });

  testWidgets('startup failure shows an error and retry recovers', (
    tester,
  ) async {
    final auth = _FakeAuth()..initFails = true;
    await _pumpGate(tester, auth: auth);

    expect(
      find.text('Ovid could not start. Check your connection and try again.'),
      findsOneWidget,
    );

    auth.initFails = false;
    await _tap(tester, find.text('Try again'));

    expect(find.text('Your always-on personal agent.'), findsOneWidget);
    // The retry actually ran startup again instead of only clearing the error.
    expect(auth.initCalls, 2);
  });

  testWidgets('startup progress follows the real work, phase by phase', (
    tester,
  ) async {
    final auth = _FakeAuth()..initGate = Completer<void>();
    final store = _FakeStore()..loadGate = Completer<void>();
    await _pumpGate(tester, auth: auth, store: store);

    double barValue() => tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .value!;

    // Firebase init is still running: nothing has been restored yet.
    expect(find.text('Starting your agent'), findsOneWidget);
    expect(barValue(), 0);
    expect(store.loadCalls, 0);

    auth.initGate!.complete();
    await tester.pumpAndSettle();

    // Init finished, preferences are the blocking step.
    expect(find.text('Restoring your choices'), findsOneWidget);
    expect(barValue(), closeTo(0.5, 0.001));
    expect(store.loadCalls, 1);

    store.loadGate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('Your always-on personal agent.'), findsOneWidget);
  });

  testWidgets('the saved language and goal are re-read on a fresh launch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_onboarding_language': 'hi',
      'ovid_first_goal': 'build,research',
    });
    final auth = _FakeAuth();
    await _pumpGate(tester, auth: auth);

    // A returning user is not asked for the language again.
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Which language do you think in?'), findsNothing);
    expect(find.text('Hindi'), findsOneWidget);

    // The goal survives too: Back shows it still selected.
    final handle = tester.ensureSemantics();
    await _tap(tester, find.byKey(const Key('sign-in-back')));
    expect(find.text('Which language do you think in?'), findsOneWidget);
    final research = tester.getSemantics(find.bySemanticsLabel('Research'));
    expect(research.flagsCollection.isSelected, ui.Tristate.isTrue);
    handle.dispose();
  });

  testWidgets('Back from language returns to welcome and keeps the choice', (
    tester,
  ) async {
    final store = _FakeStore();
    final auth = _FakeAuth();
    await _pumpGate(tester, auth: auth, store: store);

    await _tap(tester, find.byKey(const Key('welcome-get-started')));
    await _tap(tester, find.text('हिन्दी'));
    await _tap(tester, find.byKey(const Key('language-goal-back')));

    expect(find.text('Your always-on personal agent.'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('welcome-get-started')));
    await _tap(tester, find.byKey(const Key('language-goal-continue')));

    expect(store.savedLanguage, 'hi');
    expect(store.savedGoals, contains('build'));
  });

  testWidgets('Back from sign-in goes to language, and back again to sign-in', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_onboarding_language': 'en',
    });
    final auth = _FakeAuth();
    await _pumpGate(tester, auth: auth);

    await _tap(tester, find.byKey(const Key('sign-in-back')));
    expect(find.text('Which language do you think in?'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('language-goal-back')));
    expect(find.text('Welcome back'), findsOneWidget);
  });

  testWidgets('the test-mode note appears in a Test Store build', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_onboarding_language': 'en',
    });
    await _pumpGate(tester, auth: _FakeAuth(), testStore: true);
    await _tap(tester, find.text('Continue with Google'));
    expect(
      find.text('Test mode: purchases are simulated and never charge you.'),
      findsOneWidget,
    );
  });

  testWidgets('a real build shows no test-mode note', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_onboarding_language': 'en',
    });
    await _pumpGate(tester, auth: _FakeAuth(), testStore: false);
    await _tap(tester, find.text('Continue with Google'));
    expect(
      find.text('Test mode: purchases are simulated and never charge you.'),
      findsNothing,
    );
  });

  testWidgets('Continue with Free from the paywall enters the app', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_onboarding_language': 'en',
    });
    final purchases = <String>[];
    await _pumpGate(
      tester,
      auth: _FakeAuth(),
      purchase: (planId) async {
        purchases.add(planId);
        return true;
      },
    );

    await _tap(tester, find.text('Continue with Google'));
    await _tap(tester, find.byKey(const Key('paywall-continue-free')));

    expect(find.text('APP CHILD'), findsOneWidget);
    expect(purchases, isEmpty);
  });

  testWidgets('the legal links open the real documents', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_onboarding_language': 'en',
    });
    final opened = <Uri>[];
    await _pumpGate(
      tester,
      auth: _FakeAuth(),
      openUrl: (uri) async {
        opened.add(uri);
        return true;
      },
    );

    await _tap(tester, find.text('Terms'));
    await _tap(tester, find.text('Privacy Policy'));

    expect(opened, [Uri.parse(LegalLinks.terms), Uri.parse(LegalLinks.privacyPolicy)]);
  });

  for (final dark in [false, true]) {
    testWidgets('survives 320 dp and 200 % text through sign-in '
        '(${dark ? 'dark' : 'light'})', (tester) async {
      final auth = _FakeAuth();
      await _pumpGate(
        tester,
        auth: auth,
        dark: dark,
        size: const Size(320, 640),
        textScale: 2,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Your always-on personal agent.'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('welcome-get-started')));
      expect(tester.takeException(), isNull);
      expect(find.text('Which language do you think in?'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('language-goal-continue')));
      expect(tester.takeException(), isNull);
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);

      await _tap(tester, find.text('Continue with Google'));
      expect(tester.takeException(), isNull);
      expect(find.text('Do more with Ovid Plus'), findsOneWidget);

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -4000),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('paywall-trial')), findsOneWidget);
    });
  }
}
