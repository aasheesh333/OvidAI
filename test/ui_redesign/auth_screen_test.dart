import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/account_deletion_panel.dart';
import 'package:ovid_ai/ui/auth_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal FirebaseService test double. Only the surface the redesigned
/// AuthScreen uses is implemented; everything else routes through
/// [noSuchMethod] so a stray call fails loudly instead of silently working.
///
/// Modeled on the `_GateService` pattern in test/ui_redesign/login_gate_test.dart.
class _FakeFirebaseService extends ChangeNotifier implements FirebaseService {
  @override
  bool isSignedIn = false;
  @override
  String? uid;
  @override
  String? displayName;
  @override
  String? email;
  @override
  String? phoneNumber;
  @override
  String? photoUrl;
  @override
  bool emailVerified = false;
  @override
  Set<String> linkedProviderIds = <String>{};
  @override
  final AuthProviders authProviders = AuthProviders();
  @override
  AccountDeletion? lastDeletionReceipt;

  int signOutCalls = 0;
  int updateNameCalls = 0;
  String? lastNameUpdate;
  String? updateNameError;

  @override
  List<AuthProviderCapability> get reauthProviders => authProviders.enabled
      .where((p) => linkedProviderIds.contains(p.id))
      .toList();

  @override
  late final AccountService accountService = AccountService(
    enabled: false,
    idToken: (_) async => null,
    appCheck: () async => null,
  );

  @override
  Future<String?> updateDisplayName(String name) async {
    updateNameCalls++;
    lastNameUpdate = name;
    if (updateNameError != null) return updateNameError;
    displayName = name;
    notifyListeners();
    return null;
  }

  @override
  Future<void> signOut() async {
    signOutCalls++;
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
  Future<AccountDeletion> requestAccountDeletion(String requestId) async {
    throw UnimplementedError('requestAccountDeletion not used by this test');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

Future<void> _pumpAuth(
  WidgetTester tester,
  _FakeFirebaseService service, {
  double width = 420,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1200);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(home: AuthScreen(service: service)),
  );
  await tester.pumpAndSettle();
}

_FakeFirebaseService _signedInFake({
  String uid = 'user-abc',
  String? displayName = 'Alex Kim',
  String? email = 'alex@example.com',
  String? phone,
  bool emailVerified = true,
  Set<String> linked = const {'google.com', 'phone'},
}) {
  return _FakeFirebaseService()
    ..isSignedIn = true
    ..uid = uid
    ..displayName = displayName
    ..email = email
    ..phoneNumber = phone
    ..emailVerified = emailVerified
    ..linkedProviderIds = linked;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
  });

  tearDown(() {
    AppState.resetTestInstance();
  });

  testWidgets(
    'signed-in renders avatar, name, FREE plan pill, account details, '
    'linked methods and danger zone',
    (tester) async {
      AppState.I.ovidCloudTier = 'free';
      final service = _signedInFake();

      await _pumpAuth(tester, service);

      // Profile header.
      expect(find.byType(AetherGradientHeader), findsOneWidget);
      expect(find.text('Alex Kim'), findsOneWidget);
      expect(find.text('alex@example.com'), findsWidgets);

      // Plan card — FREE pill for the free tier + a Manage plan ghost button.
      expect(find.text('Ovid Cloud plan'), findsOneWidget);
      expect(find.text('FREE'), findsOneWidget);
      expect(
        find.textContaining('Free plan'),
        findsOneWidget,
      );
      expect(find.text('Manage plan'), findsOneWidget);

      // Account details card.
      expect(find.text('Account details'), findsOneWidget);
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Email status'), findsOneWidget);
      expect(find.text('User ID'), findsOneWidget);
      expect(find.text('user-abc'), findsOneWidget);

      // Linked methods — pills for google + phone.
      expect(find.text('Linked sign-in methods'), findsOneWidget);
      expect(find.text('Google'), findsOneWidget);
      // 'Phone' appears both as the account-details label and the linked pill.
      expect(find.text('Phone'), findsNWidgets(2));

      // Danger zone + Sign out.
      expect(find.text('Danger zone'), findsOneWidget);
      expect(
        find.widgetWithText(AetherDangerButton, 'Sign out'),
        findsOneWidget,
      );
      // The AccountDeletionPanel is embedded inside the danger zone.
      expect(find.byType(AccountDeletionPanel), findsOneWidget);

      service.dispose();
    },
  );

  testWidgets('plan pill reflects paid tier (3x → PLUS)', (tester) async {
    AppState.I.ovidCloudTier = '3x';
    final service = _signedInFake();

    await _pumpAuth(tester, service);
    expect(find.text('PLUS'), findsOneWidget);
    expect(find.text('FREE'), findsNothing);
    expect(
      find.textContaining('Paid plan active'),
      findsOneWidget,
    );
    service.dispose();
  });

  testWidgets('edit name dialog saves through FirebaseService', (tester) async {
    final service = _signedInFake(displayName: 'Alex Kim');
    await _pumpAuth(tester, service);

    await tester.tap(find.byTooltip('Edit name').first);
    await tester.pumpAndSettle();
    expect(find.text('Edit name'), findsWidgets);

    await tester.enterText(find.byType(TextField).first, 'Alex Renamed');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(service.updateNameCalls, 1);
    expect(service.lastNameUpdate, 'Alex Renamed');
    expect(service.displayName, 'Alex Renamed');
    expect(find.text('Name updated.'), findsOneWidget);

    service.dispose();
  });

  testWidgets('copy icon writes the email to the Clipboard', (tester) async {
    final log = <MethodCall>[];
    TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      log.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final service = _signedInFake(email: 'copyme@example.com');
    await _pumpAuth(tester, service);

    await tester.tap(find.byTooltip('Copy Email').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    final copy = log.lastWhere((c) => c.method == 'Clipboard.setData');
    expect(
      (copy.arguments as Map)['text'],
      'copyme@example.com',
    );
    expect(find.text('Email copied'), findsOneWidget);

    service.dispose();
  });

  testWidgets('signed-out shows pending-deletion banner + auth methods picker',
      (tester) async {
    final service = _FakeFirebaseService()
      ..isSignedIn = false
      ..lastDeletionReceipt = AccountDeletion(
        'pending',
        DateTime.utc(2027, 1, 2, 3, 4, 5),
        'req-id',
      );

    await _pumpAuth(tester, service);

    // Pending-deletion banner card.
    expect(find.text('Deletion requested'), findsOneWidget);
    expect(
      find.textContaining('2027-01-02T03:04:05.000Z'),
      findsOneWidget,
    );

    // Sign-in picker from AuthMethods (configured providers include Google +
    // Phone by default).
    expect(find.text('Sign in to Ovid'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with Phone'), findsOneWidget);

    service.dispose();
  });

  testWidgets('legacy password provider renders dedicated warn card',
      (tester) async {
    final service = _signedInFake(linked: {'google.com', 'password'});
    await _pumpAuth(tester, service);

    expect(find.text('Legacy password sign-in'), findsOneWidget);
    expect(
      find.textContaining('identity-verified account recovery'),
      findsOneWidget,
    );
    // Password itself must not render as a chip in the linked list.
    expect(find.text('Password (legacy)'), findsNothing);
    service.dispose();
  });
}
