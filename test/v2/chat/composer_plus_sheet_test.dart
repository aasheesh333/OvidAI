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
        onClose: onClose,
      ),
    ),
  );
}

const _pickableFolderData = V2ComposerPlusData(
  plan: V2ComposerPlusPlan.plus,
  studioFolder: 'ovid/site',
);

void main() {
  testWidgets('renders the five actions and their availability states', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await tester.pumpWidget(_app(const V2ComposerPlusData(), dark: dark));
      await tester.pumpAndSettle();

      expect(find.text('Add to chat'), findsOneWidget);
      for (final title in [
        'Photo',
        'Camera',
        'File',
        'Studio folder',
        'Connectors',
      ]) {
        expect(
          find.text(title),
          findsOneWidget,
          reason: '$title in dark=$dark',
        );
      }
      expect(find.text('Free plan'), findsOneWidget);
      expect(find.text('Folder needed'), findsOneWidget);
      expect(
        find.text('Studio chat stays blocked until you pick a folder.'),
        findsOneWidget,
      );
      expect(
        find.text('Built-in apps only. Custom connectors start on Go.'),
        findsOneWidget,
      );
    }
  });

  testWidgets('tapping Photo, File and Connectors fires each callback', (
    tester,
  ) async {
    var photos = 0;
    var files = 0;
    var connectors = 0;

    await tester.pumpWidget(
      _app(
        const V2ComposerPlusData(),
        onPhoto: () => photos++,
        onFile: () => files++,
        onConnectors: () => connectors++,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('composer-plus-photo')));
    await tester.tap(find.byKey(const ValueKey('composer-plus-file')));
    await tester.tap(find.byKey(const ValueKey('composer-plus-connectors')));
    await tester.pumpAndSettle();

    expect(photos, 1);
    expect(files, 1);
    expect(connectors, 1);
  });

  testWidgets('Studio row is blocked until a folder is picked', (tester) async {
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
    expect(row.flagsCollection.isEnabled, Tristate.isFalse);

    await tester.tap(find.byKey(const ValueKey('composer-plus-studio')));
    await tester.pumpAndSettle();
    expect(folders, 0, reason: 'a blocked row must not attach a folder');

    await tester.tap(find.byKey(const ValueKey('composer-plus-studio-note')));
    await tester.pumpAndSettle();
    expect(studioOpens, 1);

    // With a folder the row is enabled, shows the folder and attaches it.
    await tester.pumpWidget(
      _app(_pickableFolderData, onStudioFolder: () => folders++),
    );
    await tester.pumpAndSettle();
    expect(find.text('Use files from ovid/site.'), findsOneWidget);
    expect(
      find.text('Studio chat stays blocked until you pick a folder.'),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('composer-plus-studio')));
    await tester.pumpAndSettle();
    expect(folders, 1);

    handle.dispose();
  });

  testWidgets('unavailable camera is disabled and explains why', (
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

    expect(find.text('No camera'), findsOneWidget);
    expect(find.text('This device does not have a camera.'), findsOneWidget);

    final row = tester
        .getSemantics(find.byKey(const ValueKey('composer-plus-camera')))
        .getSemanticsData();
    expect(row.label, contains('No camera'));
    expect(row.flagsCollection.isEnabled, Tristate.isFalse);

    await tester.tap(find.byKey(const ValueKey('composer-plus-camera')));
    await tester.pumpAndSettle();
    expect(cameras, 0);

    handle.dispose();
  });

  testWidgets('photo without permission stays tappable to request access', (
    tester,
  ) async {
    var photos = 0;

    await tester.pumpWidget(
      _app(
        const V2ComposerPlusData(photoAccessGranted: false),
        onPhoto: () => photos++,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Allow access'), findsOneWidget);
    expect(
      find.text('Photo access is off. Allow it to pick an image.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('composer-plus-photo')));
    await tester.pumpAndSettle();
    expect(photos, 1);
  });

  testWidgets('connectors describe the plan and a used-up allowance', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const V2ComposerPlusData(
          plan: V2ComposerPlusPlan.go,
          customConnectorsUsed: 2,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Go plan'), findsOneWidget);
    expect(find.text('Go includes 5 custom connectors.'), findsOneWidget);

    await tester.pumpWidget(
      _app(
        const V2ComposerPlusData(
          plan: V2ComposerPlusPlan.go,
          customConnectorsUsed: 5,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Limit reached'), findsOneWidget);
    expect(find.text('All 5 custom connectors are in use.'), findsOneWidget);

    await tester.pumpWidget(
      _app(
        const V2ComposerPlusData(
          plan: V2ComposerPlusPlan.pro,
          customConnectorsUsed: 3,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pro plan'), findsOneWidget);
    expect(find.text('Pro includes 20 custom connectors.'), findsOneWidget);
  });

  testWidgets('close button reports its label', (tester) async {
    await tester.pumpWidget(_app(const V2ComposerPlusData(), onClose: () {}));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Close add menu'), findsOneWidget);
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
      // Both the blocked Studio note and the picked-folder row must fit.
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

        for (final key in [
          'composer-plus-photo',
          'composer-plus-camera',
          'composer-plus-file',
          'composer-plus-studio',
          'composer-plus-connectors',
        ]) {
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
}
