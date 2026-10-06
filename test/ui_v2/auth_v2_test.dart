import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/account_deletion_panel.dart';
import 'package:ovid_ai/ui/auth_methods.dart';
import 'package:ovid_ai/ui/auth_screen.dart';
import 'package:ovid_ai/ui/login_gate.dart';
import 'package:ovid_ai/ui/profile_avatar.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2 auth polish: calm login (wordmark + one tagline + providers + one-line
/// legal), one shared deletion-pending banner format, and an account screen
/// ordered hero → plan → details → linked methods → danger zone. All pumps
/// are bounded; fakes never reach real Firebase, cloud, or network code.

// ---------------------------------------------------------------------------
// Fakes (modeled on test/ui_redesign fakes; self-contained on purpose).
// ---------------------------------------------------------------------------

class _GateFake extends ChangeNotifier implements FirebaseService {
  final initialization = Completer<void>();
  @override
  bool isAvailable = true;
  @override
  bool isSignedIn = false;
  @override
  bool accountReady = false;
  @override
  String? accountError;
  @override
  final authProviders = AuthProviders();
  @override
  AccountDeletion? lastDeletionReceipt;

  PhoneAuthFlow Function(AuthIntent intent)? phoneFactory;

  @override
  Future<void> initialize() => initialization.future;

  @override
  Future<String?> authenticateSocial(String id, AuthIntent intent) async =>
      'cancelled';

  @override
  PhoneAuthFlow createPhoneFlow(AuthIntent intent) =>
      phoneFactory?.call(intent) ??
      PhoneAuthFlow(
        currentUid: () => null,
        verify: (_, _, _) async {},
        apply: (_) async {},
      );

  @override
  Future<void> signOut() async {
    isSignedIn = false;
    accountReady = false;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

class _AccountFake extends ChangeNotifier implements FirebaseService {
  @override
  bool isSignedIn = true;
  @override
  String? uid = 'uid-ada';
  @override
  String? displayName = 'Ada Lovelace';
  @override
  String? email = 'ada@example.com';
  @override
  String? phoneNumber;
  @override
  String? photoUrl;
  @override
  bool emailVerified = true;
  @override
  Set<String> linkedProviderIds = {'google.com', 'phone'};
  @override
  final authProviders = AuthProviders();
  @override
  AccountDeletion? lastDeletionReceipt;

  @override
  List<AuthProviderCapability> get reauthProviders => authProviders.enabled
      .where((p) => linkedProviderIds.contains(p.id))
      .toList();

  @override
  late final accountService = AccountService(
    enabled: false,
    idToken: (_) async => null,
    appCheck: () async => null,
  );

  @override
  Future<String?> updateDisplayName(String name) async => null;

  @override
  Future<void> signOut() async {
    isSignedIn = false;
    notifyListeners();
  }

  @override
  Future<String?> authenticateSocial(String id, AuthIntent intent) async =>
      'cancelled';

  @override
  PhoneAuthFlow createPhoneFlow(AuthIntent intent) => PhoneAuthFlow(
    currentUid: () => uid,
    verify: (_, _, _) async {},
    apply: (_) async {},
  );

  @override
  Future<AccountDeletion> requestAccountDeletion(String requestId) =>
      throw UnimplementedError('not used in v2 tests');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

// ---------------------------------------------------------------------------
// Pump helpers — bounded only.
// ---------------------------------------------------------------------------

void _setView(
  WidgetTester tester, {
  required Size logical,
  double dpr = 1,
  double keyboard = 0,
}) {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = logical * dpr;
  if (keyboard > 0) {
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
  }
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
}

Future<void> _pumpLogin(
  WidgetTester tester,
  _GateFake service, {
  Size logical = const Size(360, 640),
  double dpr = 2,
}) async {
  _setView(tester, logical: logical, dpr: dpr);
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
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _pumpAccount(
  WidgetTester tester,
  _AccountFake service, {
  Size logical = const Size(420, 1200),
  double dpr = 1,
}) async {
  _setView(tester, logical: logical, dpr: dpr);
  await tester.pumpWidget(MaterialApp(home: AuthScreen(service: service)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pump(const Duration(milliseconds: 100));
  expect(target.hitTestable(), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LoginGate.disabledForTest = false;
    SharedPreferences.setMockInitialValues({'ovid_welcomed': true});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(() {
    LoginGate.disabledForTest = false;
    AppState.resetTestInstance();
  });

  testWidgets('login renders wordmark, one tagline, providers, minimal legal', (
    tester,
  ) async {
    final service = _GateFake();
    await _pumpLogin(tester, service);

    // Wordmark + exactly one tagline.
    expect(find.text('Ovid'), findsOneWidget);
    expect(find.text('Your AI, grounded on your data'), findsOneWidget);

    // Provider buttons (social + phone only).
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Phone'), findsOneWidget);
    expect(find.text('Sign in with email'), findsNothing);

    // Minimal legal line — a single short sentence, no paragraph wall.
    expect(
      find.text('By continuing you agree to use Ovid responsibly.'),
      findsOneWidget,
    );
    expect(find.textContaining('automated farming'), findsNothing);

    // Reduced chrome: the old card heading is gone.
    expect(find.text('Sign in or create an account'), findsNothing);

    // The gate never leaks the protected child while signed out.
    expect(find.text('Protected app'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets('account hero: avatar, name, plan pill above plan; danger zone', (
    tester,
  ) async {
    AppState.I.ovidCloudTier = 'free';
    final service = _AccountFake();
    await _pumpAccount(tester, service);

    // Hero: avatar + name + the plan pill rendered exactly once.
    expect(find.byType(ProfileAvatar), findsOneWidget);
    expect(find.text('Ada Lovelace'), findsOneWidget);
    expect(find.text('FREE'), findsOneWidget);

    // The pill lives in the hero, above the plan card title.
    final pillY = tester.getCenter(find.text('FREE')).dy;
    final planTitleY = tester.getCenter(find.text('Ovid Cloud plan')).dy;
    expect(
      pillY,
      lessThan(planTitleY),
      reason: 'Plan pill must sit in the hero above the plan card',
    );

    // Plan card links to billing (Money).
    expect(find.text('Manage plan'), findsOneWidget);

    // Details copy rows.
    expect(find.text('Account details'), findsOneWidget);
    expect(find.text('User ID'), findsOneWidget);
    expect(find.text('uid-ada'), findsOneWidget);
    expect(find.byTooltip('Copy Email'), findsOneWidget);

    // Linked methods + danger zone.
    expect(find.text('Linked sign-in methods'), findsOneWidget);
    expect(find.text('Google'), findsOneWidget);
    expect(find.text('Danger zone'), findsOneWidget);
    expect(find.byType(AccountDeletionPanel), findsOneWidget);
    expect(find.widgetWithText(AetherDangerButton, 'Sign out'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets(
    'deletion banner uses one shared format on login and account screens',
    (tester) async {
      final receipt = AccountDeletion(
        'pending',
        DateTime.utc(2027, 1, 2, 3, 4, 5),
        'req-v2',
      );

      // ── Login gate (signed out) ──
      final gate = _GateFake()..lastDeletionReceipt = receipt;
      await _pumpLogin(tester, gate);

      // Formatted once: a single banner, a single title, a single schedule line.
      expect(find.byType(DeletionPendingBanner), findsOneWidget);
      expect(find.text('Deletion requested'), findsOneWidget);
      final loginLine = find.textContaining('2027-01-02T03:04:05.000Z');
      expect(loginLine, findsOneWidget);
      expect(
        find.textContaining('Sign in before then to cancel.'),
        findsOneWidget,
      );
      // The old divergent login format is gone.
      expect(find.text('Account deletion pending'), findsNothing);
      final loginText = tester.widget<Text>(loginLine).data;
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      gate.dispose();

      // ── Account screen (signed out) — identical format ──
      final account = _AccountFake()
        ..isSignedIn = false
        ..lastDeletionReceipt = receipt;
      await _pumpAccount(tester, account);

      expect(find.byType(DeletionPendingBanner), findsOneWidget);
      expect(find.text('Deletion requested'), findsOneWidget);
      final accountLine = find.textContaining('2027-01-02T03:04:05.000Z');
      expect(accountLine, findsOneWidget);
      expect(
        tester.widget<Text>(accountLine).data,
        loginText,
        reason: 'Login and account must render the identical banner copy',
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      account.dispose();
    },
  );

  testWidgets('OTP dialog sends code and verifies through the login gate', (
    tester,
  ) async {
    late PhoneCallbacks callbacks;
    var applied = 0;
    final service = _GateFake()
      ..phoneFactory = (intent) => PhoneAuthFlow(
        currentUid: () => null,
        verify: (_, _, cb) async {
          callbacks = cb;
        },
        apply: (_) async {
          applied++;
        },
      );
    await _pumpLogin(tester, service);

    await _reveal(tester, find.text('Continue with Phone'));
    await tester.tap(find.text('Continue with Phone'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Dialog opened on the root navigator.
    expect(find.text('VERIFY PHONE'), findsOneWidget);

    final phoneField = find.byType(TextField).first;
    await tester.enterText(phoneField, '+14155550100');
    await tester.tap(find.text('Send code'));
    await tester.pump();

    // Firebase delivers the verification id → six OTP cells appear.
    callbacks.codeSent('v2-vid', 7);
    await tester.pump();
    // 1 phone field + 6 OTP cells.
    expect(find.byType(TextField), findsNWidgets(7));

    const code = '123456';
    for (var i = 0; i < code.length; i++) {
      await tester.enterText(find.byType(TextField).at(i + 1), code[i]);
    }
    await tester.pump();

    await tester.tap(find.text('Verify code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(applied, 1);
    expect(find.text('VERIFY PHONE'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets('login stays calm and centered on a wide viewport', (
    tester,
  ) async {
    final service = _GateFake();
    await _pumpLogin(tester, service, logical: const Size(1024, 768), dpr: 1);

    // Content column is capped and centered, not stretched edge to edge.
    final card = find.ancestor(
      of: find.byType(AuthMethods),
      matching: find.byType(AetherCard),
    );
    expect(tester.getSize(card).width, lessThanOrEqualTo(420));
    expect(tester.getCenter(find.text('Ovid')).dx, closeTo(512, 1));
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets('account content stays capped and centered on a wide viewport', (
    tester,
  ) async {
    final service = _AccountFake();
    await _pumpAccount(tester, service, logical: const Size(1024, 768));

    final content = tester.getRect(find.byType(ListView).first);
    expect(content.width, lessThanOrEqualTo(760));
    expect(content.center.dx, closeTo(512, 1));
    expect(find.text('Danger zone'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets('phone entry remains usable above the keyboard at 360x640', (
    tester,
  ) async {
    final service = _GateFake();
    await _pumpLogin(tester, service, dpr: 1);

    await _reveal(tester, find.text('Continue with Phone'));
    await tester.tap(find.text('Continue with Phone'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('VERIFY PHONE'), findsOneWidget);

    // Keyboard slides up (280 logical px).
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final dialog = find.byType(AuthPhoneDialog);
    final field = find.descendant(of: dialog, matching: find.byType(TextField));
    await _reveal(tester, field.first);
    expect(tester.getRect(field.first).bottom, lessThanOrEqualTo(360));

    await tester.enterText(field.first, '+14155550100');
    expect(
      tester.widget<TextField>(field.first).controller!.text,
      '+14155550100',
    );

    await _reveal(tester, find.text('Send code'));
    await _reveal(tester, find.text('Cancel'));
    expect(tester.getRect(find.text('Cancel')).bottom, lessThanOrEqualTo(360));

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AuthPhoneDialog), findsNothing);
    expect(find.text('Protected app'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });
}
