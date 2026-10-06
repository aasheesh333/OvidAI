import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_phone_flow.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/auth_methods.dart';

final _captureKey = GlobalKey();
Finder get _fields => find.descendant(
  of: find.byType(AuthPhoneDialog), matching: find.byType(TextField),
);
Finder get _number => _fields.first;
Finder _digit(int index) => _fields.at(index + 1);

Future<void> _tap(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text));
  await tester.pump();
  await tester.tap(find.text(text));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

class _PhoneFixture {
  final requests = <(String, int?)>[];
  final callbacks = <PhoneCallbacks>[];
  final codes = <String?>[];
  final busy = <bool>[];
  String? uid = 'alice';
  int successes = 0;
  bool rejectCode = false;
  Completer<void>? applying;

  PhoneAuthFlow create() => PhoneAuthFlow(
    currentUid: () => uid,
    verify: (number, token, cb) async {
      requests.add((number, token));
      callbacks.add(cb);
      cb.codeSent('verification-${requests.length}', requests.length);
    },
    apply: (credential) async {
      codes.add((credential as PhoneAuthCredential).smsCode);
      if (applying != null) await applying!.future;
      if (rejectCode) {
        throw FirebaseAuthException(code: 'invalid-verification-code');
      }
    },
  );

  AuthMethods picker({AuthIntent intent = AuthIntent.signIn}) => AuthMethods(
    providers: AuthProviders(google: false, phone: true),
    intent: intent,
    linkedIds: const {'phone'},
    phoneNumber: '+14155550100',
    social: (_) async => null,
    phone: create,
    onBusyChanged: busy.add,
    onSuccess: () => successes++,
  );
}

Future<void> _host(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(360, 640),
  double scale = 1,
  bool dark = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final previousDark = Aether.dark;
  Aether.dark = dark;
  addTearDown(() => Aether.dark = previousDark);
  await tester.pumpWidget(MaterialApp(
    theme: Aether.theme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: RepaintBoundary(key: _captureKey, child: child!),
    ),
    home: Scaffold(body: SingleChildScrollView(
      padding: const EdgeInsets.all(16), child: child,
    )),
  ));
}

Future<void> _openCode(WidgetTester tester, _PhoneFixture fixture) async {
  await _tap(tester, 'Continue with Phone');
  await tester.ensureVisible(_number);
  await tester.enterText(_number, '+1 (415) 555-0100');
  await _tap(tester, 'Send code');
  expect(fixture.requests, [('+14155550100', null)]);
  expect(_fields, findsNWidgets(7));
}

void main() {
  for (final dark in [true, false]) {
    for (final viewport in [
      (const Size(360, 640), 2.0),
      (const Size(320, 640), 1.0),
      (const Size(1024, 768), 1.0),
    ]) {
      testWidgets('phone actions remain reachable ${viewport.$1} '
          '${viewport.$2}x dark=$dark with keyboard', (tester) async {
        final fixture = _PhoneFixture();
        await _host(tester, fixture.picker(), size: viewport.$1,
          scale: viewport.$2, dark: dark);
        await _openCode(tester, fixture);
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.ensureVisible(_digit(0));
        await tester.enterText(_digit(0), '123456');
        await tester.pump();
        expect(tester.takeException(), isNull);
        // All six values survive a single paste even at large text sizes.
        for (var i = 0; i < 6; i++) {
          expect(tester.widget<TextField>(_digit(i)).controller!.text, '123456'[i]);
        }
        await _tap(tester, 'Verify code');
        expect(fixture.codes, ['123456']);
        expect(fixture.successes, 1);
        expect(fixture.busy, [true, false]);
        expect(find.byType(AuthPhoneDialog), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('configured provider labels wrap and busy/error/cancel release', (tester) async {
    var result = Completer<String?>();
    final calls = <String>[];
    final busy = <bool>[];
    var successes = 0;
    await _host(tester, AuthMethods(
      providers: AuthProviders(google: false, phone: false,
        socialIds: 'microsoft.com,password,unknown'),
      intent: AuthIntent.signIn,
      social: (id) { calls.add(id); return result.future; },
      phone: () => throw StateError('disabled'),
      onBusyChanged: busy.add,
      onSuccess: () => successes++,
    ), scale: 2);
    expect(find.text('Continue with Microsoft'), findsOneWidget);
    expect(find.text('Continue with Phone'), findsNothing);
    expect(find.text('Continue with Google'), findsNothing);
    final paragraph = tester.renderObject<RenderParagraph>(find.text('Continue with Microsoft'));
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(paragraph.overflow, isNot(TextOverflow.ellipsis));
    await _tap(tester, 'Continue with Microsoft');
    await _tap(tester, 'Continue with Microsoft');
    expect(calls, ['microsoft.com']);
    result.complete('Network unavailable. Check your connection and retry.');
    await tester.pump();
    expect(find.textContaining('Network unavailable'), findsOneWidget);
    result = Completer<String?>();
    await _tap(tester, 'Continue with Microsoft');
    result.complete('cancelled');
    await tester.pump();
    expect(find.text('cancelled'), findsNothing);
    expect(find.textContaining('Network unavailable'), findsNothing);
    expect(busy, [true, false, true, false]);
    expect(successes, 0);
    await _tap(tester, 'Existing account help');
    await tester.ensureVisible(find.textContaining('identity-verified account recovery'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('SMS autofill hint and keyboard submit deliver the complete code', (tester) async {
    final fixture = _PhoneFixture();
    await _host(tester, fixture.picker());
    await _openCode(tester, fixture);
    expect(tester.widget<TextField>(_digit(0)).autofillHints,
      contains(AutofillHints.oneTimeCode));
    await tester.ensureVisible(_digit(0));
    await tester.showKeyboard(_digit(0));
    // Platform autofill delivers a complete editing value, not six keystrokes.
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '654321', selection: TextSelection.collapsed(offset: 6),
    ));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(fixture.codes, ['654321']);
    expect(fixture.successes, 1);
  });

  testWidgets('resend clears cells, invalid code can retry, change number resets', (tester) async {
    final fixture = _PhoneFixture()..rejectCode = true;
    await _host(tester, fixture.picker());
    await _openCode(tester, fixture);
    await tester.enterText(_digit(0), '123456');
    await _tap(tester, 'Verify code');
    expect(find.textContaining('Incorrect verification code'), findsOneWidget);
    await tester.pump(const Duration(seconds: 61));
    await _tap(tester, 'Resend code');
    expect(fixture.requests, [('+14155550100', null), ('+14155550100', 1)]);
    for (var i = 0; i < 6; i++) {
      expect(tester.widget<TextField>(_digit(i)).controller!.text, isEmpty);
    }
    await _tap(tester, 'Verify code');
    expect(find.text('Enter the six-digit SMS code.'), findsOneWidget);
    expect(fixture.codes, ['123456']);
    await _tap(tester, 'Change number');
    expect(_fields, findsOneWidget);
    expect(tester.widget<TextField>(_number).enabled, isTrue);
    fixture.callbacks.first.completed(PhoneAuthProvider.credential(
      verificationId: 'stale', smsCode: '111111'));
    await tester.pump();
    expect(fixture.codes, ['123456']);
    await _tap(tester, 'Cancel');
    expect(fixture.successes, 0);
    expect(fixture.busy, [true, false]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reauth fixes number and rejects credentials after account switch', (tester) async {
    final fixture = _PhoneFixture();
    await _host(tester, fixture.picker(intent: AuthIntent.reauthenticate));
    expect(find.text('Existing account help'), findsNothing);
    await _tap(tester, 'Verify with Phone');
    expect(tester.widget<TextField>(_number).enabled, isFalse);
    await _tap(tester, 'Send code');
    expect(fixture.requests, [('+14155550100', null)]);
    expect(find.text('Change number'), findsNothing);
    fixture.uid = 'bob';
    await tester.enterText(_digit(0), '123456');
    await _tap(tester, 'Verify code');
    expect(fixture.codes, isEmpty);
    expect(find.textContaining('The account changed'), findsOneWidget);
    await _tap(tester, 'Cancel');
    expect(fixture.successes, 0);
  });

  testWidgets('link proof failure prevents creating phone flow', (tester) async {
    var created = 0;
    final busy = <bool>[];
    await _host(tester, AuthMethods(
      providers: AuthProviders(socialIds: 'github.com'),
      intent: AuthIntent.link,
      linkedIds: const {'google.com'},
      social: (_) async => null,
      beforePhone: () async => 'Verify a pre-existing linked provider again.',
      phone: () { created++; return _PhoneFixture().create(); },
      onBusyChanged: busy.add,
    ));
    expect(find.text('Link Google'), findsNothing);
    expect(find.text('Link GitHub'), findsOneWidget);
    await _tap(tester, 'Link Phone');
    expect(created, 0);
    expect(find.byType(AuthPhoneDialog), findsNothing);
    expect(find.textContaining('Verify a pre-existing'), findsOneWidget);
    expect(busy, [true, false]);
  });

  testWidgets('in-flight apply locks cancel and back until completion', (tester) async {
    final fixture = _PhoneFixture()..applying = Completer<void>();
    await _host(tester, fixture.picker());
    await _openCode(tester, fixture);
    await tester.enterText(_digit(0), '123456');
    await _tap(tester, 'Verify code');
    await _tap(tester, 'Cancel');
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(AuthPhoneDialog), findsOneWidget);
    expect(fixture.codes, ['123456']);
    fixture.applying!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(fixture.successes, 1);
    expect(find.byType(AuthPhoneDialog), findsNothing);
  });

  testWidgets('server SMS failure keeps cooldown and allows a later resend', (tester) async {
    final fixture = _PhoneFixture();
    await _host(tester, fixture.picker());
    await _openCode(tester, fixture);
    fixture.callbacks.single.failed(FirebaseAuthException(code: 'network-request-failed'));
    await tester.pump();
    expect(find.textContaining('Network unavailable'), findsOneWidget);
    expect(find.text('Waiting for SMS verification…'), findsNothing);
    final resendLabel = find.textContaining('Resend in');
    await tester.ensureVisible(resendLabel);
    await tester.tap(resendLabel);
    await tester.pump();
    expect(fixture.requests, hasLength(1));
    await tester.pump(const Duration(seconds: 61));
    await _tap(tester, 'Resend code');
    expect(fixture.requests, hasLength(2));
    expect(find.textContaining('Network unavailable'), findsNothing);
    await _tap(tester, 'Cancel');
    expect(fixture.successes, 0);
  });

  testWidgets('cancel invalidates automatic callbacks before route exit animation', (tester) async {
    final fixture = _PhoneFixture();
    await _host(tester, fixture.picker());
    await _openCode(tester, fixture);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    fixture.callbacks.single.completed(PhoneAuthProvider.credential(
      verificationId: 'late', smsCode: '123456'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(fixture.codes, isEmpty);
    expect(fixture.successes, 0);
    expect(fixture.busy, [true, false]);
    expect(find.byType(AuthPhoneDialog), findsNothing);
  });

  testWidgets('picker remains measurable inside the reauthentication alert', (tester) async {
    final fixture = _PhoneFixture();
    await _host(tester, Builder(builder: (context) => TextButton(
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Verify this account'),
          content: SingleChildScrollView(
            child: fixture.picker(intent: AuthIntent.reauthenticate),
          ),
        ),
      ),
      child: const Text('Open verification'),
    )), scale: 2);
    await _tap(tester, 'Open verification');
    expect(tester.takeException(), isNull);
    await _tap(tester, 'Verify with Phone');
    expect(find.byType(AuthPhoneDialog), findsOneWidget);
    await _tap(tester, 'Cancel');
    expect(fixture.successes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('real phone dialog review capture (opt-in)', (tester) async {
    final fixture = _PhoneFixture();
    await _host(tester, fixture.picker());
    await _openCode(tester, fixture);
    await tester.ensureVisible(_digit(0));
    await tester.pump();
    expect(find.byType(AuthPhoneDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('UI_REVIEW_CAPTURE')) {
      final boundary = _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('/tmp/opencode/ui-finish-02.png').writeAsBytes(data!.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      });
    }
    await _tap(tester, 'Cancel');
  });
}
