import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/ovid_cloud_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/account_deletion_panel.dart';
import 'package:ovid_ai/ui/auth_screen.dart';
import 'package:ovid_ai/ui/billing_screen.dart';
import 'package:ovid_ai/ui/profile_avatar.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Same external-service seam as ui_redesign/auth_screen_test.dart. The actual
// AuthScreen, auth picker, deletion panel, avatar and billing route render here.
class _AccountFixture extends ChangeNotifier implements FirebaseService {
  @override
  bool isSignedIn = true;
  @override
  String? uid = 'account-0123456789abcdefghijklmnopqrstuvwxyz0123456789';
  @override
  String? displayName = 'Alexandria Catherine Montgomery Rivera';
  @override
  String? email =
      'alexandria.catherine.montgomery+personal.account@example.com';
  @override
  String? phoneNumber = '+14155550123';
  @override
  String? photoUrl;
  @override
  bool emailVerified = true;
  @override
  Set<String> linkedProviderIds = {'google.com', 'github.com', 'phone', 'password'};
  @override
  final AuthProviders authProviders = AuthProviders();
  @override
  AccountDeletion? lastDeletionReceipt;
  @override
  late final AccountService accountService = AccountService(
    enabled: false,
    idToken: (_) async => null,
    appCheck: () async => null,
  );
  @override
  List<AuthProviderCapability> get reauthProviders => authProviders.enabled
      .where((provider) => linkedProviderIds.contains(provider.id))
      .toList();

  final socialCalls = <(String, AuthIntent)>[];
  int deletionCalls = 0;
  @override
  Future<String?> authenticateSocial(String id, AuthIntent intent) async {
    socialCalls.add((id, intent));
    return null;
  }

  @override
  PhoneAuthFlow createPhoneFlow(AuthIntent intent) => PhoneAuthFlow(
    currentUid: () => uid,
    verify: (_, _, _) async {},
    apply: (_) async {},
  );

  @override
  Future<String?> updateDisplayName(String name) async {
    displayName = name;
    notifyListeners();
    return null;
  }

  @override
  Future<void> signOut() async {
    isSignedIn = false;
    notifyListeners();
  }

  @override
  Future<AccountDeletion> requestAccountDeletion(String requestId) async {
    deletionCalls++;
    throw StateError('Deletion must remain gated in this fixture');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

final _captureKey = GlobalKey();

Future<void> _pumpAccount(
  WidgetTester tester,
  _AccountFixture service, {
  Size size = const Size(360, 640),
  double scale = 1,
  bool dark = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  Aether.dark = dark;
  await tester.pumpWidget(
    MaterialApp(
      theme: Aether.theme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: RepaintBoundary(
        key: _captureKey,
        child: AuthScreen(service: service),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    200,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 70,
  );
  await tester.pump(const Duration(milliseconds: 100));
  expect(tester.takeException(), isNull);
}

void _expectUntruncated(WidgetTester tester, Finder finder) {
  final text = tester.widget<Text>(finder);
  expect(text.maxLines, isNull);
  expect(text.overflow, isNot(TextOverflow.ellipsis));
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  expect(paragraph.didExceedMaxLines, isFalse);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late bool originalDark;
  setUp(() {
    originalDark = Aether.dark;
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    OvidCloudService.idTokenOverrideForTest = () async => 'account-test-token';
    OvidCloudService.httpClientFactoryForTest = () => MockClient(
      (_) async => http.Response(jsonEncode({
        'tier': 'free',
        'is_paid': false,
        'daily_budget_usd': 1,
        'daily_spent_usd': 0,
        'daily_remaining_usd': 1,
        'budget_window': '24h',
        'remaining_pct': 1,
        'models': <Object>[],
      }), 200),
    );
  });
  tearDown(() {
    OvidCloudService.idTokenOverrideForTest = null;
    OvidCloudService.httpClientFactoryForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    Aether.dark = originalDark;
  });

  for (final viewport in [
    (size: const Size(320, 640), scale: 1.0),
    (size: const Size(360, 640), scale: 2.0),
    (size: const Size(1024, 768), scale: 1.0),
  ]) {
    for (final dark in [true, false]) {
      testWidgets('long account identity ${viewport.size} '
          '${viewport.scale}x ${dark ? 'dark' : 'light'} stays readable', (tester) async {
        final service = _AccountFixture();
        await _pumpAccount(tester, service,
            size: viewport.size, scale: viewport.scale, dark: dark);
        expect(tester.takeException(), isNull);
        expect(find.byType(ProfileAvatar), findsOneWidget);
        if (viewport.size.width == 1024) {
          final content = tester.getRect(find.byType(ListView).first);
          expect(content.width, lessThanOrEqualTo(760));
          expect(content.center.dx, closeTo(512, 1));
        }
        _expectUntruncated(tester, find.text(service.displayName!));
        _expectUntruncated(tester, find.text(service.email!).first);
        await _reveal(tester, find.text('Manage plan'));
        await _reveal(tester, find.text(service.uid!));
        _expectUntruncated(tester, find.text(service.uid!));
        _expectUntruncated(tester, find.text(service.email!).last);
        await _reveal(tester, find.text('Linked sign-in methods'));
        expect(find.text('Google'), findsOneWidget);
        expect(find.text('GitHub'), findsOneWidget);
        expect(find.text('github.com'), findsNothing);
        expect(find.text('Linked'), findsWidgets);
        expect(find.text('Linked · Unavailable in this build'), findsOneWidget);
        await _reveal(tester, find.text('Legacy password sign-in'));
        _expectUntruncated(tester, find.text('Legacy password sign-in'));
        expect(find.text(legacyAuthMigrationHelp), findsOneWidget);
        await _reveal(tester, find.text('Sign out'));
        await _reveal(tester, find.text('Delete your account'));
        expect(service.deletionCalls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        service.dispose();
      });
    }
  }

  testWidgets('phone-only identity does not claim an unverified email', (tester) async {
    final service = _AccountFixture()
      ..displayName = null
      ..email = null
      ..emailVerified = false
      ..linkedProviderIds = {'phone'};
    await _pumpAccount(tester, service);
    expect(find.text(service.phoneNumber!), findsWidgets);
    await _reveal(tester, find.text('Email status'));
    expect(find.text('No email linked'), findsOneWidget);
    expect(find.text('Unverified'), findsNothing);
    expect(find.byTooltip('Copy Email'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets('plan updates while the account route remains open', (tester) async {
    final service = _AccountFixture();
    await _pumpAccount(tester, service);
    await _reveal(tester, find.text('Manage plan'));
    expect(find.text('FREE'), findsOneWidget);
    AppState.I.setOvidCloudTier('7x');
    await tester.pump();
    expect(find.text('PRO'), findsOneWidget);
    expect(find.text('FREE'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets('pending deletion keeps the server deadline readable at 2x', (tester) async {
    final service = _AccountFixture()
      ..isSignedIn = false
      ..lastDeletionReceipt = AccountDeletion(
        'pending', DateTime.utc(2027, 1, 2, 3, 4, 5), 'receipt-03',
      );
    await _pumpAccount(tester, service, scale: 2);
    _expectUntruncated(tester, find.text('Deletion requested'));
    expect(find.textContaining('2027-01-02T03:04:05.000Z'), findsOneWidget);
    await _reveal(tester, find.text('Continue with Phone'));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets('consecutive copies preserve complete values and replace feedback', (tester) async {
    final writes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          writes.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final service = _AccountFixture();
    await _pumpAccount(tester, service, scale: 2);
    String? previousMessage;
    for (final entry in [
      ('Email', service.email!),
      ('Phone', service.phoneNumber!),
      ('User ID', service.uid!),
    ]) {
      final copy = find.byTooltip('Copy ${entry.$1}');
      await _reveal(tester, copy);
      await tester.tap(copy);
      await tester.pump();
      expect(writes.last, entry.$2);
      expect(find.text('${entry.$1} copied'), findsOneWidget);
      if (previousMessage != null) {
        expect(find.text(previousMessage), findsNothing);
      }
      previousMessage = '${entry.$1} copied';
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(writes, [service.email, service.phoneNumber, service.uid]);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets('Manage plan opens actual billing and Back returns to account', (tester) async {
    final service = _AccountFixture();
    await _pumpAccount(tester, service);
    await _reveal(tester, find.text('Manage plan'));
    await tester.tap(find.text('Manage plan'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(BillingScreen), findsOneWidget);
    expect(find.text('Plans & Billing'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(BackButton).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(BillingScreen), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets('linking still requires verification with an existing identity', (tester) async {
    final service = _AccountFixture()..linkedProviderIds = {'phone'};
    await _pumpAccount(tester, service);
    await _reveal(tester, find.text('Link Google'));
    await tester.tap(find.text('Link Google'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Verify this account'), findsOneWidget);
    expect(find.text('Verify with Phone'), findsOneWidget);
    expect(service.socialCalls, isEmpty);
    await tester.tap(find.text('Cancel').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(service.socialCalls, isEmpty);
    expect(service.uid, 'account-0123456789abcdefghijklmnopqrstuvwxyz0123456789');
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets('sign out switches to sign-in without requesting deletion', (tester) async {
    final service = _AccountFixture();
    await _pumpAccount(tester, service);
    await _reveal(tester, find.text('Sign out'));
    await tester.tap(find.text('Sign out'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Sign in to Ovid'), findsOneWidget);
    expect(find.byType(AccountDeletionPanel), findsNothing);
    expect(service.deletionCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });

  testWidgets('capture actual account screen for visual review', (tester) async {
    final service = _AccountFixture()
      ..displayName = 'Alex Kim'
      ..email = 'alex@example.com';
    await _pumpAccount(tester, service, size: const Size(420, 1000));
    expect(find.text('Alex Kim'), findsOneWidget);
    expect(find.text('Manage plan'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final boundary = _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/opencode/ui-finish-03.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  }, skip: !const bool.fromEnvironment('UI_REVIEW_CAPTURE'));
}
