import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/settings/confirm_typed_sheet.dart';

Widget _app(Widget child, {bool dark = false, double textScale = 1}) =>
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      builder: (context, home) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: home!,
      ),
      home: Scaffold(body: child),
    );

void _phoneSize(
  WidgetTester tester, {
  double width = 320,
  double height = 640,
}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

const _data = V2ConfirmTypedSheetData(contact: 'aarav@example.com');

Finder get _field => find.byKey(const ValueKey('confirm-typed-field'));

Finder get _confirmButton => find.byKey(const ValueKey('confirm-typed-button'));

FilledButton _filled(WidgetTester tester) => tester.widget<FilledButton>(
  find.widgetWithText(FilledButton, _data.confirmLabel),
);

Future<void> _tapConfirm(WidgetTester tester) async {
  await tester.ensureVisible(_confirmButton);
  await tester.pumpAndSettle();
  await tester.tap(_confirmButton);
  await tester.pump();
}

void main() {
  group('V2ConfirmTypedSheetData', () {
    test('email match ignores case and outer spaces', () {
      expect(_data.matches('  AARAV@Example.COM '), isTrue);
      expect(_data.matches('aarav@example.com'), isTrue);
      expect(_data.matches('aarav@example.co'), isFalse);
      expect(_data.matches(''), isFalse);
    });

    test('phone match ignores spacing, dashes and brackets', () {
      const phone = V2ConfirmTypedSheetData(contact: '+91 98765 43210');
      expect(phone.isEmailContact, isFalse);
      expect(phone.matches('+919876543210'), isTrue);
      expect(phone.matches('+91 (98765) 43210'), isTrue);
      expect(phone.matches('+91-98765-43210'), isTrue);
      expect(phone.matches('9876543210'), isFalse);
    });

    test('falls back to DELETE without a contact', () {
      const legacy = V2ConfirmTypedSheetData(contact: '  ');
      expect(legacy.hasContact, isFalse);
      expect(legacy.confirmationTarget, 'DELETE');
      expect(legacy.matches('delete'), isTrue);
      expect(legacy.matches('aarav@example.com'), isFalse);
    });
  });

  testWidgets('shows what is removed and the Play note', (
    tester,
  ) async {
    for (final dark in <bool>[false, true]) {
      await tester.pumpWidget(
        _app(const V2ConfirmTypedSheet(data: _data), dark: dark),
      );
      await tester.pumpAndSettle();

      expect(find.text(_data.title), findsOneWidget);
      expect(find.text(_data.irreversibleLabel), findsOneWidget);
      expect(find.text(_data.removalsTitle), findsOneWidget);
      for (final removal in _data.removals) {
        expect(find.text(removal), findsOneWidget);
      }
      expect(find.text(_data.playNote), findsOneWidget);
      expect(find.text(_data.confirmationTarget), findsWidgets);
      expect(find.text(_data.prompt), findsOneWidget);
      expect(find.text(_data.confirmLabel), findsOneWidget);
      expect(find.text(_data.cancelLabel), findsOneWidget);
    }
  });

  testWidgets('confirm stays disabled until the contact matches', (
    tester,
  ) async {
    var confirmed = 0;
    await tester.pumpWidget(
      _app(
        V2ConfirmTypedSheet(
          data: _data,
          onConfirm: () => confirmed++,
          onCancel: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_filled(tester).onPressed, isNull);
    expect(find.text(_data.lockHint), findsOneWidget);

    await tester.enterText(_field, 'wrong@example.com');
    await tester.pump();
    expect(find.text(_data.mismatchMessage), findsOneWidget);
    expect(find.text(_data.matchedMessage), findsNothing);
    expect(_filled(tester).onPressed, isNull);
    expect(confirmed, 0);

    await tester.enterText(_field, '  AARAV@Example.COM  ');
    await tester.pump();
    expect(find.text(_data.mismatchMessage), findsNothing);
    expect(find.text(_data.matchedMessage), findsOneWidget);
    expect(_filled(tester).onPressed, isNotNull);

    await _tapConfirm(tester);
    expect(confirmed, 1);
  });

  testWidgets('phone accounts accept unformatted input', (tester) async {
    const phoneData = V2ConfirmTypedSheetData(contact: '+91 98765 43210');
    var confirmed = 0;
    await tester.pumpWidget(
      _app(V2ConfirmTypedSheet(data: phoneData, onConfirm: () => confirmed++)),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(_field);
    expect(field.keyboardType, TextInputType.phone);
    expect(find.text(phoneData.confirmationTarget), findsWidgets);

    await tester.enterText(_field, '+919876543210');
    await tester.pump();
    expect(find.text(phoneData.matchedMessage), findsOneWidget);

    await _tapConfirm(tester);
    expect(confirmed, 1);
  });

  testWidgets('the Play note action is wired and optional', (tester) async {
    var managed = 0;
    await tester.pumpWidget(
      _app(
        V2ConfirmTypedSheet(
          data: _data,
          onManageSubscription: () => managed++,
          onConfirm: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('confirm-typed-play-button')));
    expect(managed, 1);

    // Without a Play note the section, and its action, disappear.
    await tester.pumpWidget(
      _app(
        const V2ConfirmTypedSheet(
          data: V2ConfirmTypedSheetData(
            contact: 'aarav@example.com',
            playNote: '',
          ),
          onManageSubscription: null,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('confirm-typed-play-note')), findsNothing);
    expect(find.text(_data.playNote), findsNothing);
  });

  testWidgets('copy, removals and labels are replaceable', (tester) async {
    const custom = V2ConfirmTypedSheetData(
      contact: 'aarav@example.com',
      title: 'Delete this project?',
      irreversibleLabel: '',
      removalsTitle: 'Only this project goes away:',
      removals: <String>['The launch chat', 'Its uploaded files'],
      playNote: '',
      prompt: 'Type the account email to confirm',
      confirmLabel: 'Delete project',
      cancelLabel: 'Keep project',
    );
    var cancelled = 0;
    await tester.pumpWidget(
      _app(
        V2ConfirmTypedSheet(
          data: custom,
          onCancel: () => cancelled++,
          onConfirm: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Delete this project?'), findsOneWidget);
    expect(find.text(_data.title), findsNothing);
    expect(find.text('The launch chat'), findsOneWidget);
    expect(find.text('Its uploaded files'), findsOneWidget);
    expect(find.text(_data.removals.first), findsNothing);
    expect(find.text('Cannot be undone'), findsNothing);
    expect(find.byKey(const ValueKey('confirm-typed-grace')), findsNothing);
    expect(find.text('Delete project'), findsOneWidget);

    await tester.tap(find.text('Keep project'));
    expect(cancelled, 1);
  });

  testWidgets('danger styling marks the irreversible action', (tester) async {
    await tester.pumpWidget(_app(const V2ConfirmTypedSheet(data: _data)));
    await tester.pumpAndSettle();

    // The irreversible action is named by a danger pill, not a decorative
    // warning icon.
    expect(find.text(_data.irreversibleLabel), findsOneWidget);

    final button = _filled(tester);
    expect(
      button.style?.backgroundColor?.resolve(<WidgetState>{}),
      OColors.light.danger,
    );
    expect(
      button.style?.foregroundColor?.resolve(<WidgetState>{}),
      OColors.light.onDanger,
    );
  });

  testWidgets('the confirm button announces its enabled state', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(V2ConfirmTypedSheet(data: _data, onConfirm: () {})),
    );
    await tester.pumpAndSettle();

    final disabled = tester
        .getSemantics(find.widgetWithText(FilledButton, _data.confirmLabel))
        .flagsCollection;
    expect(disabled.isButton, isTrue);
    expect(disabled.isEnabled, Tristate.isFalse);

    await tester.enterText(_field, 'aarav@example.com');
    await tester.pump();

    final enabled = tester
        .getSemantics(find.widgetWithText(FilledButton, _data.confirmLabel))
        .flagsCollection;
    expect(enabled.isEnabled, Tristate.isTrue);

    expect(find.text('Email or phone'), findsOneWidget);
    expect(find.text(_data.confirmationTarget), findsWidgets);
    semantics.dispose();
  });

  testWidgets('helper resolves true on confirm and false on cancel', (
    tester,
  ) async {
    _phoneSize(tester, width: 390, height: 844);
    bool? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => OButton(
            label: 'Open confirm',
            onPressed: () async {
              result = await showConfirmTypedSheet(
                context,
                data: _data,
                onManageSubscription: () {},
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open confirm'));
    await tester.pumpAndSettle();
    expect(find.text(_data.title), findsOneWidget);

    await tester.ensureVisible(find.text(_data.cancelLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_data.cancelLabel));
    await tester.pumpAndSettle();
    expect(result, isFalse);

    await tester.tap(find.text('Open confirm'));
    await tester.pumpAndSettle();
    await tester.enterText(_field, 'aarav@example.com');
    await tester.pump();
    await tester.ensureVisible(_confirmButton);
    await tester.pumpAndSettle();
    await tester.tap(_confirmButton);
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(find.text(_data.title), findsNothing);
  });

  testWidgets('falls back to DELETE copy and locks until it is typed', (
    tester,
  ) async {
    const noContact = V2ConfirmTypedSheetData(contact: '');
    var confirmed = 0;
    await tester.pumpWidget(
      _app(V2ConfirmTypedSheet(data: noContact, onConfirm: () => confirmed++)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Type DELETE to confirm'), findsOneWidget);
    expect(find.text('Confirmation word'), findsOneWidget);
    expect(
      find.text('The button below stays locked until you type DELETE.'),
      findsOneWidget,
    );
    expect(find.text('Type your email or phone to confirm'), findsNothing);

    await tester.enterText(_field, 'delete me');
    await tester.pump();
    expect(_filled(tester).onPressed, isNull);
    expect(confirmed, 0);

    await tester.enterText(_field, 'delete');
    await tester.pump();
    expect(_filled(tester).onPressed, isNotNull);

    await _tapConfirm(tester);
    expect(confirmed, 1);
  });

  testWidgets('fits 320 dp at 200% text in light and dark', (tester) async {
    _phoneSize(tester);
    for (final dark in <bool>[false, true]) {
      var confirmed = 0;
      await tester.pumpWidget(
        _app(
          V2ConfirmTypedSheet(
            data: _data,
            onConfirm: () => confirmed++,
            onCancel: () {},
            onManageSubscription: () {},
          ),
          dark: dark,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('confirm-typed-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('confirm-typed-play-button')),
        200,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(_field);
      await tester.pumpAndSettle();
      await tester.enterText(_field, 'aarav@example.com');
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        _confirmButton,
        200,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(_confirmButton);
      await tester.pump();
      expect(confirmed, 1);
    }
  });
}
