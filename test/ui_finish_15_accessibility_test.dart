import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/account_deletion_panel.dart';
import 'package:ovid_ai/ui/profile_avatar.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

Widget _host(Widget child, {double scale = 1, bool reduceMotion = false}) =>
    MaterialApp(
      theme: Aether.theme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduceMotion,
        ),
        child: child!,
      ),
      home: Scaffold(body: child),
    );

void _viewport(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  setUp(() => Aether.dark = true);
  tearDown(() => Aether.dark = true);

  testWidgets('loading actions keep names and cannot activate', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
    var calls = 0;
    await tester.pumpWidget(_host(Column(children: [
      AetherPrimaryButton(label: 'Save', loading: true, onPressed: () => calls++),
      AetherSecondaryButton(label: 'Retry', loading: true, onPressed: () => calls++),
      AetherGhostButton(label: 'Later', loading: true, onPressed: () => calls++),
      AetherDangerButton(label: 'Delete', loading: true, onPressed: () => calls++),
    ])));
    for (final label in ['Save', 'Retry', 'Later', 'Delete']) {
      final node = tester.getSemantics(find.bySemanticsLabel(label));
      expect(node.flagsCollection.isButton, isTrue);
      expect(node.flagsCollection.isEnabled, ui.Tristate.isFalse);
      expect(node.getSemanticsData().value, contains('Loading'));
      expect(node.getSemanticsData().hasAction(ui.SemanticsAction.tap), isFalse);
    }
    await tester.tap(find.byType(AetherPrimaryButton));
    await tester.pump(const Duration(milliseconds: 100));
    expect(calls, 0);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('icon actions expose role and disabled state with 44px targets', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
    var calls = 0;
    await tester.pumpWidget(_host(Column(children: [
      AetherGhostButton(
        label: 'Open tools', iconOnly: true, iconSize: 24,
        icon: Icons.build, onPressed: () => calls++,
      ),
      const AetherDangerButton(label: 'Stop', iconOnly: true, iconSize: 32),
    ])));
    final enabled = tester.getSemantics(find.bySemanticsLabel('Open tools'));
    expect(enabled.flagsCollection.isButton, isTrue);
    expect(enabled.flagsCollection.isEnabled, ui.Tristate.isTrue);
    expect(enabled.rect.width, greaterThanOrEqualTo(44));
    expect(enabled.rect.height, greaterThanOrEqualTo(44));
    final disabled = tester.getSemantics(find.bySemanticsLabel('Stop'));
    expect(disabled.flagsCollection.isEnabled, ui.Tristate.isFalse);
    await tester.tap(find.byType(AetherGhostButton));
    await tester.pump();
    expect(calls, 1);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('field name stays attached to editable node when label is hidden', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(_host(AetherField(
      label: 'Phone number', showLabel: false, controller: controller,
      fieldKey: const ValueKey('phone-input'), errorText: 'Enter a valid phone number.',
    )));
    final node = tester.getSemantics(find.byKey(const ValueKey('phone-input')));
    expect(node.flagsCollection.isTextField, isTrue);
    expect(node.label, contains('Phone number'));
    expect(node.label, contains('Enter a valid phone number.'));
    expect(tester.getSemantics(find.text('Enter a valid phone number.'))
        .flagsCollection.isLiveRegion, isTrue);
    await tester.enterText(find.byKey(const ValueKey('phone-input')), '123');
    expect(controller.text, '123');
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('OTP distributes paste and supports empty-cell hardware backspace', (tester) async {
    String code = '';
    await tester.pumpWidget(_host(AetherOtpField(length: 6, onChanged: (v) => code = v)));
    final fields = find.byType(TextField);
    await tester.enterText(fields.first, '12 34-56');
    await tester.pump();
    expect(code, '123456');
    expect(tester.widget<TextField>(fields.last).focusNode!.hasFocus, isTrue);
    expect(tester.widget<TextField>(fields.at(2)).controller!.text, '3');
    await tester.enterText(fields.last, '');
    await tester.pump();
    expect(code, '12345');
    expect(tester.widget<TextField>(fields.at(4)).focusNode!.hasFocus, isTrue);
    await tester.tap(fields.last);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(code, '1234');
    expect(tester.widget<TextField>(fields.at(4)).focusNode!.hasFocus, isTrue);
    await tester.enterText(fields.first, '987654');
    await tester.pump();
    expect(code, '987654');
    expect(tester.widget<TextField>(fields.first).controller!.text, '9');
    expect(tester.takeException(), isNull);
  });

  testWidgets('OTP selects a filled destination and survives length updates', (tester) async {
    var length = 6;
    late StateSetter rebuild;
    String code = '';
    await tester.pumpWidget(_host(StatefulBuilder(builder: (_, setState) {
      rebuild = setState;
      return AetherOtpField(length: length, onChanged: (v) => code = v);
    })));
    await tester.enterText(find.byType(TextField).first, '123456');
    await tester.pump();
    final last = tester.widget<TextField>(find.byType(TextField).last);
    expect(last.controller!.selection, const TextSelection(baseOffset: 0, extentOffset: 1));
    tester.widget<TextField>(find.byType(TextField).at(2)).focusNode!.requestFocus();
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField).at(2)).controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 1));
    rebuild(() => length = 4);
    await tester.pump();
    expect(find.byType(TextField), findsNWidgets(4));
    await tester.enterText(find.byType(TextField).last, '9');
    expect(code, '1239');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion stops and can resume a pulsing status dot', (tester) async {
    Widget dot(bool reduced, {bool pulsing = true}) => _host(
      AetherStatusDot(color: Aether.success, pulsing: pulsing),
      reduceMotion: reduced,
    );
    await tester.pumpWidget(dot(false));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(dot(true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(dot(false));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await tester.pumpWidget(dot(false, pulsing: false));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('avatar announces only its image label, not the fallback glyph', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
    await tester.pumpWidget(_host(const ProfileAvatar(displayName: 'Ada'), scale: 2));
    final node = tester.getSemantics(find.byType(ProfileAvatar));
    expect(node.label, 'Profile image');
    expect(node.flagsCollection.isImage, isTrue);
    } finally {
      semantics.dispose();
    }
  });

  for (final size in [const Size(320, 640), const Size(360, 640), const Size(1024, 768)]) {
    for (final dark in [true, false]) {
      final scale = size.width == 360 ? 2.0 : 1.0;
      testWidgets('primitives fit $size at ${scale}x dark=$dark', (tester) async {
        _viewport(tester, size);
        Aether.dark = dark;
        final semantics = tester.ensureSemantics();
        try {
        await tester.pumpWidget(_host(SingleChildScrollView(child: Padding(
          padding: const EdgeInsets.all(16),
          child: AetherCard(
            title: const Text('Account controls and verification'),
            trailing: AetherGhostButton(label: 'Review account details', onPressed: () {}),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              AetherPrimaryButton(label: 'Continue with this linked social provider', onPressed: () {}),
              AetherOtpField(length: 6, onChanged: (_) {}),
              AetherSegmentedControl<int>(value: 0, onChanged: (_) {}, options: const [
                (value: 0, label: 'One-off', icon: Icons.event),
                (value: 1, label: 'Daily schedule', icon: Icons.today),
                (value: 2, label: 'Repeating interval', icon: Icons.repeat),
              ]),
              AetherStepper(value: 0, min: 0, max: 1, label: 'Retries', onChanged: (_) {}),
            ]),
          ),
        )), scale: scale));
        expect(tester.takeException(), isNull);
        for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
          expect(tester.getSize(find.byWidget(field)).width, greaterThanOrEqualTo(44));
          expect(tester.getSize(find.byWidget(field)).height, greaterThanOrEqualTo(44));
        }
        final paragraph = tester.renderObject<RenderParagraph>(find.text('Continue with this linked social provider'));
        expect(paragraph.didExceedMaxLines, isFalse);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('card supplies Material for interactive descendants without Scaffold', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(home: Center(child: AetherCard(
      child: InkWell(onTap: () => taps++, child: const Text('Card action')),
    ))));
    await tester.tap(find.text('Card action'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stepper labels expose bounds and retain 44px hit targets', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
    var value = 0;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (_, setState) =>
      AetherStepper(value: value, min: 0, max: 1, label: 'Retries',
        onChanged: (next) => setState(() => value = next)),
    )));
    final decrease = tester.getSemantics(find.byTooltip('Decrease Retries'));
    expect(decrease.flagsCollection.isEnabled, ui.Tristate.isFalse);
    final increase = tester.getSemantics(find.byTooltip('Increase Retries'));
    expect(increase.flagsCollection.isButton, isTrue);
    expect(increase.rect.width, greaterThanOrEqualTo(44));
    expect(increase.rect.height, greaterThanOrEqualTo(44));
    await tester.tap(find.byTooltip('Increase Retries'));
    await tester.pump();
    expect(value, 1);
    expect(tester.getSemantics(find.byTooltip('Increase Retries')).flagsCollection.isEnabled,
        ui.Tristate.isFalse);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('buttons remain keyboard activatable', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_host(Column(children: [
      AetherPrimaryButton(label: 'Save changes', onPressed: () => calls++),
      AetherGhostButton(label: 'Open tools', iconOnly: true, onPressed: () => calls++),
    ])));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls, 2);
  });

  for (final parentInset in [false, true]) {
  testWidgets('sheet wraps actions above keyboard with parent inset=$parentInset', (tester) async {
    _viewport(tester, const Size(360, 640));
    var calls = 0;
    await tester.pumpWidget(_host(Builder(builder: (context) => TextButton(
      onPressed: () => showModalBottomSheet<void>(
        context: context, isScrollControlled: true,
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.only(bottom: parentInset ? MediaQuery.viewInsetsOf(sheetContext).bottom : 0),
          child: AetherSheet(
          title: 'Review linked account',
          actions: [
            AetherGhostButton(label: 'Keep current account', onPressed: () {}),
            AetherPrimaryButton(label: 'Confirm account changes', onPressed: () => calls++),
          ],
          child: const SingleChildScrollView(child: AetherField(label: 'Account name')),
          ),
        ),
      ),
      child: const Text('Open sheet'),
    )), scale: 2));
    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final action = find.byType(AetherPrimaryButton);
    await tester.ensureVisible(action);
    await tester.pump();
    expect(tester.getBottomRight(action).dy, lessThanOrEqualTo(400));
    await tester.tap(action);
    expect(calls, 1);
  });
  }

  testWidgets('sheet preserves bounded Expanded list bodies and reachable actions', (tester) async {
    _viewport(tester, const Size(360, 640));
    var calls = 0;
    await tester.pumpWidget(_host(AetherSheet(
      title: 'Review available accounts',
      actions: [AetherPrimaryButton(label: 'Confirm selection', onPressed: () => calls++)],
      child: Column(children: [
        const Text('Available accounts'),
        Expanded(child: ListView(
          children: List.generate(20, (i) => ListTile(title: Text('Account $i'))),
        )),
      ]),
    ), scale: 2));
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(find.descendant(
      of: find.byType(ListView), matching: find.byType(Scrollable),
    )).position.pixels, greaterThan(0));
    await tester.ensureVisible(find.byType(AetherPrimaryButton));
    await tester.pump();
    await tester.tap(find.byType(AetherPrimaryButton));
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large-text deletion dialog scrolls to cancel and confirm safely', (tester) async {
    _viewport(tester, const Size(360, 640));
    final captureKey = GlobalKey();
    final reauth = Completer<String?>();
    var requests = 0;
    final service = AccountService(
      enabled: true, idToken: (_) async => 'token', appCheck: () async => 'app',
      client: MockClient((_) async => http.Response('{"state":"active"}', 200)),
    );
    addTearDown(service.client!.close);
    await tester.pumpWidget(RepaintBoundary(key: captureKey, child: _host(
      SingleChildScrollView(child: AccountDeletionPanel(
        service: service,
        reauthenticate: (_) => reauth.future,
        requestDeletion: (id) async {
          requests++;
          return AccountDeletion('pending', DateTime.now().add(const Duration(hours: 24)), id);
        },
      )), scale: 2,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete your account'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(requests, 0);
    if (const bool.fromEnvironment('UI_REVIEW_CAPTURE')) {
      final boundary = captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/opencode/ui-finish-15.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.ensureVisible(find.text('Keep account'));
    await tester.tap(find.text('Keep account'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(requests, 0);
    await tester.tap(find.text('Delete your account'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Request deletion'));
    await tester.tap(find.text('Request deletion'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(requests, 0, reason: 'Deletion must wait for reauthentication');
    reauth.complete(null);
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('Deletion requested'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
