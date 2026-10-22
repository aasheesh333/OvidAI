import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/composer_plus_sheet.dart';

Widget _app(
  V2ComposerPlusData data, {
  bool dark = false,
  double textScale = 1,
  VoidCallback? onPhoto,
  VoidCallback? onCamera,
  VoidCallback? onFile,
  VoidCallback? onStudioFolder,
  VoidCallback? onConnectors,
  VoidCallback? onOpenStudio,
  VoidCallback? onPermission,
  String? permissionLabel,
  VoidCallback? onClose,
}) {
  return MaterialApp(
    theme: dark ? OTheme.dark() : OTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: V2ComposerPlusSheet(
        data: data,
        onPhoto: onPhoto,
        onCamera: onCamera,
        onFile: onFile,
        onStudioFolder: onStudioFolder,
        onConnectors: onConnectors,
        onOpenStudio: onOpenStudio,
        onPermission: onPermission,
        permissionLabel: permissionLabel,
        onClose: onClose,
      ),
    ),
  );
}

const _pickableFolderData = V2ComposerPlusData(
  plan: V2ComposerPlusPlan.plus,
  studioFolder: 'ovid/site',
);

const _rowKeys = [
  'composer-plus-file',
  'composer-plus-photo',
  'composer-plus-camera',
  'composer-plus-studio',
];

void main() {
  testWidgets('renders four one-line actions', (tester) async {
    for (final dark in [false, true]) {
      await tester.pumpWidget(_app(const V2ComposerPlusData(), dark: dark));
      await tester.pumpAndSettle();

      expect(find.text('Add to chat'), findsOneWidget);
      expect(find.text('Attach a photo, file or connector.'), findsNothing);
      for (final title in ['File', 'Photo', 'Camera', 'Studio folder']) {
        expect(
          find.text(title),
          findsOneWidget,
          reason: '$title in dark=$dark',
        );
      }
      expect(
        find.text('Connectors'),
        findsNothing,
        reason: 'the sheet is four rows; connectors live in their own screen',
      );
      expect(find.text('Free plan'), findsNothing);
      expect(find.text('Folder needed'), findsNothing);
      expect(find.text('Documents, code and images up to 8 MB.'), findsNothing);
      for (final key in _rowKeys) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
    }
  });

  testWidgets('a wired permission adds one row that reports the mode', (
    tester,
  ) async {
    var changes = 0;
    await tester.pumpWidget(
      _app(
        const V2ComposerPlusData(),
        onPermission: () => changes++,
        permissionLabel: 'General',
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('composer-plus-permission'));
    expect(row, findsOneWidget);
    expect(find.text('Permission: General'), findsOneWidget);
    expect(tester.getSize(row).height, greaterThanOrEqualTo(48));

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(changes, 1);
  });

  testWidgets('tapping File and Photo fires each callback', (tester) async {
    var photos = 0;
    var files = 0;

    await tester.pumpWidget(
      _app(
        const V2ComposerPlusData(),
        onPhoto: () => photos++,
        onFile: () => files++,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('composer-plus-file')));
    await tester.tap(find.byKey(const ValueKey('composer-plus-photo')));
    await tester.pumpAndSettle();

    expect(photos, 1);
    expect(files, 1);
  });

  testWidgets('Studio row opens Studio until a folder is picked', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var folders = 0;
    var studioOpens = 0;

    await tester.pumpWidget(
      _app(
        const V2ComposerPlusData(),
        onStudioFolder: () => folders++,
        onOpenStudio: () => studioOpens++,
      ),
    );
    await tester.pumpAndSettle();

    final row = tester
        .getSemantics(find.byKey(const ValueKey('composer-plus-studio')))
        .getSemanticsData();
    expect(row.label, contains('Folder needed'));
    expect(row.flagsCollection.isButton, isTrue);
    expect(
      row.flagsCollection.isEnabled,
      Tristate.isTrue,
      reason: 'the row is the way to pick a folder, so it stays tappable',
    );

    // The blocked row opens Studio instead of attaching a folder.
    await tester.tap(find.byKey(const ValueKey('composer-plus-studio')));
    await tester.pumpAndSettle();
    expect(folders, 0, reason: 'a blocked row must not attach a folder');
    expect(studioOpens, 1);

    // With a folder the row is enabled and attaches it.
    await tester.pumpWidget(
      _app(_pickableFolderData, onStudioFolder: () => folders++),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('composer-plus-studio')));
    await tester.pumpAndSettle();
    expect(folders, 1);

    handle.dispose();
  });

  testWidgets('unavailable camera is disabled and explains itself', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var cameras = 0;

    await tester.pumpWidget(
      _app(
        const V2ComposerPlusData(cameraAvailable: false),
        onCamera: () => cameras++,
      ),
    );
    await tester.pumpAndSettle();

    final row = tester
        .getSemantics(find.byKey(const ValueKey('composer-plus-camera')))
        .getSemanticsData();
    expect(row.label, contains('This device does not have a camera.'));
    expect(row.flagsCollection.isEnabled, Tristate.isFalse);

    await tester.tap(find.byKey(const ValueKey('composer-plus-camera')));
    await tester.pumpAndSettle();
    expect(cameras, 0);

    handle.dispose();
  });

  testWidgets('photo without permission stays tappable to request access', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var photos = 0;

    await tester.pumpWidget(
      _app(
        const V2ComposerPlusData(photoAccessGranted: false),
        onPhoto: () => photos++,
      ),
    );
    await tester.pumpAndSettle();

    final row = tester
        .getSemantics(find.byKey(const ValueKey('composer-plus-photo')))
        .getSemanticsData();
    expect(row.label, contains('Allow access'));
    expect(row.flagsCollection.isEnabled, Tristate.isTrue);

    await tester.tap(find.byKey(const ValueKey('composer-plus-photo')));
    await tester.pumpAndSettle();
    expect(photos, 1);

    handle.dispose();
  });

  testWidgets('close button reports its label', (tester) async {
    await tester.pumpWidget(_app(const V2ComposerPlusData(), onClose: () {}));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Close add menu'), findsOneWidget);
  });

  testWidgets('camera reason is caller-supplied', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const V2ComposerPlusData(
          cameraAvailable: false,
          cameraUnavailableReason: V2ComposerPlusSheet.cameraBuildReason,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('composer-plus-camera')))
          .getSemanticsData()
          .label,
      contains(V2ComposerPlusSheet.cameraBuildReason),
    );
    handle.dispose();
  });

  testWidgets('320 dp at 100 % text keeps one line per row', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    await tester.pumpWidget(_app(const V2ComposerPlusData()));
    await tester.pumpAndSettle();

    expect(errors, isEmpty);
    expect(find.text('File'), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets('fits 320 dp at 200 % text and keeps 48 dp rows '
        '(${dark ? 'dark' : 'light'})', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);

      var files = 0;
      for (final withFolder in [false, true]) {
        errors.clear();
        await tester.pumpWidget(
          _app(
            withFolder
                ? const V2ComposerPlusData(studioFolder: 'ovid/website')
                : const V2ComposerPlusData(),
            dark: dark,
            textScale: 2,
            onFile: () => files++,
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));

        for (final error in errors) {
          debugPrint('$error');
        }
        expect(
          errors,
          isEmpty,
          reason:
              'sheet overflowed at 320 dp / 200 % '
              '(${withFolder ? 'folder picked' : 'folder blocked'})',
        );

        for (final key in _rowKeys) {
          final size = tester.getSize(find.byKey(ValueKey(key)));
          expect(
            size.height,
            greaterThanOrEqualTo(48),
            reason: '$key is smaller than 48 dp',
          );
        }
      }

      final fileRow = find.byKey(const ValueKey('composer-plus-file'));
      await tester.ensureVisible(fileRow);
      await tester.tap(fileRow);
      await tester.pumpAndSettle();
      expect(files, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('opens as a centred dialog at 600 dp and wider', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showV2ComposerPlusSheet(
                  context,
                  data: const V2ComposerPlusData(),
                ),
                child: const Text('Open plus'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open plus'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    final sheet = tester.getRect(find.byType(V2ComposerPlusSheet));
    expect(sheet.width, lessThanOrEqualTo(560));
    expect(sheet.center.dx, closeTo(450, 1));
  });
}
