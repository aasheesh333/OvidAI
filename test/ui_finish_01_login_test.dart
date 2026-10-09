import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/auth_methods.dart';
import 'package:ovid_ai/ui/login_gate.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:ovid_ai/ui/widgets/ovid_mark.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_login_gate_test.dart' show GateService;

class _LoginService extends GateService {
  final socialCalls = <(String, AuthIntent)>[];
  AuthIntent? phoneIntent;

  @override
  Future<String?> authenticateSocial(String id, AuthIntent intent) async {
    socialCalls.add((id, intent));
    return 'Provider could not connect. Please try again.';
  }

  @override
  PhoneAuthFlow createPhoneFlow(AuthIntent intent) {
    phoneIntent = intent;
    return PhoneAuthFlow(
      currentUid: () => null,
      verify: (_, _, _) async {},
      apply: (_) async {},
    );
  }

  @override
  Future<void> signOut() async {
    isSignedIn = false;
    accountReady = false;
    notifyListeners();
  }
}

const _captureKey = ValueKey('login-review-capture');

Future<void> _pumpGate(
  WidgetTester tester,
  GateService service, {
  required Size size,
  double scale = 1,
  bool accessibleNavigation = false,
  Future<void> Function()? bindCloud,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    service.dispose();
  });
  service.initialization.complete();
  await tester.pumpWidget(
    MaterialApp(
      theme: Aether.theme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          accessibleNavigation: accessibleNavigation,
        ),
        child: child!,
      ),
      home: RepaintBoundary(
        key: _captureKey,
        child: LoginGate(
          service: service,
          bindCloud: bindCloud ?? () async {},
          child: const Scaffold(body: Text('Protected app')),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(target, 180,
        scrollable: find.descendant(
          of: find.byType(LoginGate),
          matching: find.byType(Scrollable),
        ).first);
  }
  // Use the target's scroll ancestors (the dialog has its own viewport),
  // centering instead of putting an oversized paragraph's center off-screen.
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await tester.pump(const Duration(milliseconds: 100));
  expect(target.hitTestable(), findsOneWidget);
  expect(tester.takeException(), isNull);
}

Future<void> _readWholeParagraph(WidgetTester tester, Finder target) async {
  await _reveal(tester, target);
  final box = tester.renderObject<RenderBox>(target);
  final scroll = Scrollable.of(tester.element(target));
  final viewport = RenderAbstractViewport.of(box);
  // Check overlapping readable sections, including the first and last lines.
  // A long paragraph cannot fit on screen all at once at large text scales.
  final sections = (box.size.height / (scroll.position.viewportDimension / 2))
      .ceil();
  for (var section = 0; section <= sections; section++) {
    final fraction = section / sections;
    final y = 1 + (box.size.height - 2) * fraction;
    final offset = viewport.getOffsetToReveal(
      box, 0.5, rect: Rect.fromLTWH(0, y, box.size.width, 1),
    ).offset;
    scroll.position.jumpTo(offset.clamp(
        scroll.position.minScrollExtent, scroll.position.maxScrollExtent));
    await tester.pump();
    expect(target.hitTestable(at: Alignment(0, 2 * y / box.size.height - 1)),
        findsOneWidget,
        reason: 'Help section $section of $sections must be readable');
    expect(tester.takeException(), isNull);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'ovid_welcomed': true});
    final wasDark = Aether.dark;
    addTearDown(() => Aether.dark = wasDark);
  });

  for (final dark in [true, false]) {
    for (final viewport in [
      (size: const Size(320, 640), scale: 1.0),
      (size: const Size(360, 640), scale: 2.0),
      (size: const Size(1024, 768), scale: 1.0),
    ]) {
      testWidgets('login actions and legal copy remain reachable '
          '${viewport.size} ${viewport.scale}x dark=$dark', (tester) async {
        Aether.dark = dark;
        final service = _LoginService()..isAvailable = true;
        await _pumpGate(tester, service,
            size: viewport.size, scale: viewport.scale);
        expect(find.byType(OvidWordmark), findsOneWidget);
        expect(find.textContaining('new account is created automatically'),
            findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Protected app'), findsNothing);
        await _reveal(tester, find.text('Continue with Google'));
        await tester.tap(find.text('Continue with Google'));
        await tester.pump();
        expect(service.socialCalls, [('google.com', AuthIntent.signIn)]);
        await _reveal(tester, find.textContaining('Provider could not connect'));
        await _reveal(tester, find.text('Existing account help'));
        await tester.tap(find.text('Existing account help'));
        await tester.pump();
        await _readWholeParagraph(tester,
            find.textContaining('identity-verified account recovery'));
        await _reveal(tester,
            find.textContaining('By continuing you agree to use Ovid responsibly.'));
        expect(find.text('Protected app'), findsNothing);
      });
    }
  }

  testWidgets('pending deletion preserves the server deadline and login access',
      (tester) async {
    final service = _LoginService()
      ..isAvailable = true
      ..lastDeletionReceipt = AccountDeletion(
          'pending', DateTime.utc(2026, 10, 6, 13, 45), 'deletion-request');
    await _pumpGate(tester, service, size: const Size(360, 640), scale: 2);
    await _reveal(tester, find.text('Account deletion pending'));
    await _reveal(tester, find.textContaining('2026-10-06'));
    expect(find.textContaining('13:45:00.000 UTC'), findsOneWidget);
    await _reveal(
      tester,
      find.textContaining('Signing in does not cancel deletion'),
    );
    await _reveal(tester, find.text('Continue with Google'));
    await tester.tap(find.text('Continue with Google'));
    await tester.pump();
    expect(service.socialCalls, [('google.com', AuthIntent.signIn)]);
    expect(find.text('Protected app'), findsNothing);
  });

  testWidgets('phone entry and cancellation work above a small-screen keyboard',
      (tester) async {
    final service = _LoginService()..isAvailable = true;
    await _pumpGate(tester, service, size: const Size(360, 640), scale: 2);
    await _reveal(tester, find.text('Continue with Phone'));
    await tester.tap(find.text('Continue with Phone'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(service.phoneIntent, AuthIntent.signIn);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    // First rebuild starts Dialog's inset animation; the following bounded
    // pump completes it before computing a scroll offset for the phone field.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final dialog = find.byType(AuthPhoneDialog);
    final field = find.descendant(of: dialog, matching: find.byType(TextField));
    final dialogScroll = tester.state<ScrollableState>(find.descendant(
      of: dialog, matching: find.byType(Scrollable),
    ).first);
    expect(Scrollable.of(tester.element(field)), same(dialogScroll));
    await _reveal(tester, field);
    expect(tester.getRect(field).bottom, lessThanOrEqualTo(360));
    await tester.enterText(field, '+14155550100');
    expect(tester.widget<TextField>(field).controller!.text, '+14155550100');
    await _reveal(tester, find.text('Send code'));
    await _reveal(tester, find.text('Cancel'));
    expect(tester.getRect(find.text('Cancel')).bottom, lessThanOrEqualTo(360));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AuthPhoneDialog), findsNothing);
    expect(find.text('Protected app'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final available in [false, true]) {
    testWidgets('recovery remains readable and gates cloud binding: $available',
        (tester) async {
      final service = _LoginService()
        ..isAvailable = available
        ..isSignedIn = available
        ..accountError = available
            ? 'The account server could not confirm your account. '
                'Please check your connection and try again.'
            : null;
      var binds = 0;
      await _pumpGate(tester, service,
          size: const Size(360, 640), scale: 2,
          bindCloud: () async { binds++; });
      expect(find.byType(OvidWordmark), findsOneWidget);
      expect(find.text('Protected app'), findsNothing);
      expect(binds, 0);
      await _reveal(tester, find.widgetWithText(FilledButton, 'Retry'));
      if (!available) service.isAvailable = true;
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(binds, available ? 1 : 0);
      if (available) {
        expect(find.text('Protected app'), findsOneWidget);
        service.notifyListeners();
        await tester.pump();
        expect(binds, 1);
      } else {
        expect(find.byType(AuthMethods), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('account confirmation spinner blocks the app and permits signout '
      'after a server failure', (tester) async {
    final service = _LoginService()
      ..isAvailable = true
      ..isSignedIn = true;
    var binds = 0;
    await _pumpGate(tester, service,
        size: const Size(360, 640), scale: 2,
        bindCloud: () async { binds++; });
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Protected app'), findsNothing);
    expect(binds, 0);
    expect(tester.takeException(), isNull);
    service.accountError = 'The server could not confirm your account.';
    service.notifyListeners();
    await tester.pump();
    await _reveal(tester, find.text('Sign out'));
    await tester.tap(find.text('Sign out'));
    await tester.pump();
    expect(find.byType(AuthMethods), findsOneWidget);
    expect(find.text('Protected app'), findsNothing);
    expect(binds, 0);
  });

  for (final size in [const Size(360, 640), const Size(1024, 768)]) {
    testWidgets('welcome stays bounded above keyboard and dismisses: $size',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final service = _LoginService()
        ..isAvailable = true
        ..isSignedIn = true
        ..accountReady = true;
      await _pumpGate(tester, service, size: size,
          scale: size.width < 400 ? 2 : 1, accessibleNavigation: true);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pump(const Duration(milliseconds: 400));
      final card = find.ancestor(
          of: find.text('Welcome to Ovid Si'), matching: find.byType(AetherCard));
      expect(tester.getSize(card).width, lessThanOrEqualTo(420));
      expect(tester.getRect(card).center.dx, closeTo(size.width / 2, 1));
      await _reveal(tester, find.text("Let's go"));
      expect(tester.getRect(find.text("Let's go")).bottom,
          lessThanOrEqualTo(size.height - 280));
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('Welcome to Ovid Si'), findsOneWidget,
          reason: 'Accessible navigation needs time to read and dismiss.');
      await tester.tap(find.text("Let's go"));
      await tester.pump();
      expect(find.text('Welcome to Ovid Si'), findsNothing);
      expect(find.text('Protected app'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('capture actual login screen for UI review', (tester) async {
    Aether.dark = true;
    final service = _LoginService()..isAvailable = true;
    await _pumpGate(tester, service, size: const Size(390, 844));
    expect(find.text('Continue with Google').hitTestable(), findsOneWidget);
    expect(find.textContaining('By continuing').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('UI_REVIEW_CAPTURE')) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_captureKey));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/opencode/ui-finish-01.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    }
  });
}
