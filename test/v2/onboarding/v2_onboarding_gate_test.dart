import 'dart:async';
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';
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
  int signOutCalls = 0;
  bool signOutFails = false;
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
  Future<void> signOut() async {
    signOutCalls++;
    if (signOutFails) throw StateError('sign out failed');
    signedIn = false;
    ready = false;
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
    expect(find.text('Ovid builds, ships and answers.'), findsNothing);

    auth.initGate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('Ovid builds, ships and answers.'), findsOneWidget);
  });

  testWidgets('a signed-in admitted account goes straight to the child', (
    tester,
  ) async {
    final auth = _FakeAuth()
      ..signedIn = true
      ..ready = true;
    await _pumpGate(tester, auth: auth);

    expect(find.text('APP CHILD'), findsOneWidget);
    expect(find.text('Ovid builds, ships and answers.'), findsNothing);
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

  testWidgets('a rejected account can sign out and use another account', (
    tester,
  ) async {
    final auth = _FakeAuth()..signedIn = true;
    await _pumpGate(tester, auth: auth, settle: false);

    expect(find.text('Confirming your account'), findsOneWidget);

    await tester.tap(find.byKey(const Key('account-use-another')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(auth.signOutCalls, 1);
    expect(find.text('Confirming your account'), findsNothing);
    // The rejected account is gone and the sign-in step can take another one.
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('APP CHILD'), findsNothing);
  });

  testWidgets('a failed sign-out keeps the account screen and explains', (
    tester,
  ) async {
    final auth = _FakeAuth()
      ..signedIn = true
      ..signOutFails = true;
    await _pumpGate(tester, auth: auth, settle: false);

    await tester.tap(find.byKey(const Key('account-use-another')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(auth.signOutCalls, 1);
    expect(find.text('Confirming your account'), findsOneWidget);
    expect(
      find.text('Could not sign out. Check your connection and retry.'),
      findsOneWidget,
    );
    expect(find.text('APP CHILD'), findsNothing);
  });

  testWidgets('welcome → language → sign-in → paywall → child', (tester) async {
    final auth = _FakeAuth();
    await _pumpGate(tester, auth: auth);

    expect(find.text('Ovid builds, ships and answers.'), findsOneWidget);

    await _tap(tester, find.byKey(const Key('welcome-get-started')));
    expect(find.text('VOICE LANGUAGE'), findsOneWidget);

    await _tap(tester, find.text('हिन्दी'));
    await _tap(tester, find.byKey(const Key('language-goal-continue')));
    expect(find.text('Welcome back'), findsOneWidget);

    await _tap(tester, find.text('Continue with Google'));
    expect(auth.socialCalls, 1);
    expect(auth.lastProvider, 'google.com');
    expect(find.text('Upgrade'), findsOneWidget);

    await _tap(tester, find.byIcon(Icons.close_rounded));
    expect(find.text('APP CHILD'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ovid_onboarding_language'), 'hi');
    expect(prefs.getString('ovid_first_goal'), 'build');
    // The reply-language preference belongs to AppState and must not be
    // overwritten with an onboarding id it can never produce.
    expect(prefs.getString('ovid_locale'), isNull);
  });

  testWidgets('sign-in offers only Google and phone, with no email form', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_locale': 'en',
    });
    final auth = _FakeAuth();
    await _pumpGate(tester, auth: auth);

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with phone'), findsOneWidget);
    // Email/password has no provider, so the form is gone entirely.
    expect(find.byKey(const Key('sign-in-email')), findsNothing);
    expect(find.byKey(const Key('sign-in-password')), findsNothing);
    expect(find.text('Forgot password?'), findsNothing);
    expect(find.text('Create an account'), findsNothing);
    expect(find.text('Continue with Apple'), findsNothing);
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
    expect(find.text('Upgrade'), findsNothing);
  });

  testWidgets('a failed social sign-in offers a retry that repeats it', (
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
    expect(auth.socialCalls, 1);
    expect(
      find.text('Sign-in failed. Check your connection and retry.'),
      findsOneWidget,
    );

    // The retry repeats the provider attempt; it does not only clear the
    // message (MINIMAL_UI_CONTRACT §8).
    await _tap(tester, find.text('Try again'));
    expect(auth.socialCalls, 2);
    expect(auth.lastProvider, 'google.com');
    expect(find.text('APP CHILD'), findsNothing);
  });

  testWidgets('an auth-layer failure is shown as its real message', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_onboarding_language': 'en',
    });
    final auth = _FakeAuth()
      ..socialFailure = FirebaseAuthException(code: 'network-request-failed');
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
    expect(find.text('Upgrade'), findsOneWidget);

    await _tap(tester, find.text('Ovid Go'));
    await _tap(tester, find.byKey(const Key('paywall-trial')));

    // A declined purchase is not a fake success: the gate simply continues.
    expect(purchased, ['go']);
    expect(find.text('APP CHILD'), findsOneWidget);
  });

  testWidgets('the paywall currency choice is persisted', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_onboarding_language': 'en',
    });
    await _pumpGate(tester, auth: _FakeAuth());

    await _tap(tester, find.text('Continue with Google'));
    await _tap(tester, find.byKey(const Key('paywall-currency-inr')));

    expect(find.text('₹1,799'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ovid_onboarding_currency'), 'inr');
  });

  testWidgets('a saved currency is restored on the paywall', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'ovid_welcome_version_v2': '1',
      'ovid_onboarding_language': 'en',
      'ovid_onboarding_currency': 'inr',
    });
    await _pumpGate(tester, auth: _FakeAuth());

    await _tap(tester, find.text('Continue with Google'));

    expect(find.text('₹1,799'), findsOneWidget);
    expect(find.text('\$18'), findsNothing);
  });

  testWidgets('finishing the welcome persists the v2 marker', (tester) async {
    final auth = _FakeAuth();
    await _pumpGate(tester, auth: auth);

    await _tap(tester, find.byKey(const Key('welcome-get-started')));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ovid_welcome_version_v2'), '1');
    expect(find.text('VOICE LANGUAGE'), findsOneWidget);
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

    expect(find.text('Ovid builds, ships and answers.'), findsOneWidget);
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

    expect(find.text('Ovid builds, ships and answers.'), findsOneWidget);
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
    expect(find.text('VOICE LANGUAGE'), findsNothing);

    // The goal survives too: Back shows it still selected.
    final handle = tester.ensureSemantics();
    await _tap(tester, find.byKey(const Key('sign-in-back')));
    expect(find.text('VOICE LANGUAGE'), findsOneWidget);
    expect(find.text('हिन्दी'), findsOneWidget);
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

    expect(find.text('Ovid builds, ships and answers.'), findsOneWidget);

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
    expect(find.text('VOICE LANGUAGE'), findsOneWidget);

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
      expect(find.text('Ovid builds, ships and answers.'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('welcome-get-started')));
      expect(tester.takeException(), isNull);
      expect(find.text('VOICE LANGUAGE'), findsOneWidget);

      await _tap(tester, find.byKey(const Key('language-goal-continue')));
      expect(tester.takeException(), isNull);
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);

      await _tap(tester, find.text('Continue with Google'));
      expect(tester.takeException(), isNull);
      expect(find.text('Upgrade'), findsOneWidget);

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
