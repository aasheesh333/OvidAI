import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/main_web_preview.dart' as preview;
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/v2_gallery.dart';
import 'package:ovid_ai/ui/v2/v2_registry_web.dart';

/// The web preview must stay a faithful mirror of the v2 registry, so these
/// tests guard both its coverage and the gallery chrome around it.

Widget _host(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? OTheme.light(),
  home: Scaffold(body: child),
);

void main() {
  group('web registry', () {
    test('ids are unique', () {
      final ids = v2ScreensWeb.map((entry) => entry.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate screen id');
    });

    test('covers every group a reviewer walks', () {
      final groups = v2ScreensWeb.map((entry) => entry.group).toSet();
      expect(
        groups,
        containsAll(<String>[
          'Identity',
          'Chat',
          'Navigation',
          'Work',
          'Connectors',
          'Library',
          'Schedules',
          'Sharing',
          'Runs',
          'Settings',
        ]),
      );
    });

    test('never imports the native-only account screen', () {
      // The account page reaches Play billing -> Firebase -> sqlite3 (FFI),
      // which cannot compile for web. It must stay out of this registry.
      expect(v2ScreensWeb.where((entry) => entry.id == 'account'), isEmpty);
    });

    testWidgets('every screen renders at phone and tablet width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final width in <double>[360, 412, 800]) {
        tester.view.physicalSize = Size(width, 900);
        addTearDown(tester.view.resetPhysicalSize);
        for (final dark in <bool>[false, true]) {
          for (final entry in v2ScreensWeb) {
            await tester.pumpWidget(
              _host(
                Builder(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(size: Size(width, 900)),
                    child: entry.builder(context),
                  ),
                ),
                theme: dark ? OTheme.dark() : OTheme.light(),
              ),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(
              tester.takeException(),
              isNull,
              reason:
                  '${entry.id} threw at $width (${dark ? 'dark' : 'light'})',
            );
          }
        }
      }
    });
  });

  group('deep links', () {
    test('width comes from ?w and falls back to 360', () {
      expect(
        preview.PreviewWidth.fromQuery('412'),
        preview.PreviewWidth.largePhone,
      );
      expect(
        preview.PreviewWidth.fromQuery('800'),
        preview.PreviewWidth.tablet,
      );
      expect(preview.PreviewWidth.fromQuery('360'), preview.PreviewWidth.phone);
      expect(preview.PreviewWidth.fromQuery(null), preview.PreviewWidth.phone);
      expect(
        preview.PreviewWidth.fromQuery('nope'),
        preview.PreviewWidth.phone,
      );
      expect(
        preview.PreviewWidth.fromQuery('1000'),
        preview.PreviewWidth.phone,
      );
    });
  });

  group('preview shell', () {
    Future<void> pumpPreview(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const preview.OvidWebPreview());
      await tester.pumpAndSettle();
    }

    double galleryWidth(WidgetTester tester) =>
        MediaQuery.sizeOf(tester.element(find.byType(V2GalleryPage))).width;

    testWidgets('starts at phone width with all three width choices', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpPreview(tester);

      expect(galleryWidth(tester), 360);
      for (final label in <String>[
        'Preview at 360 dp, Phone',
        'Preview at 412 dp, Large phone',
        'Preview at 800 dp, Tablet',
      ]) {
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      }
      semantics.dispose();
    });

    testWidgets('a width choice relayouts the gallery and pushed screens', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpPreview(tester);

      await tester.tap(find.bySemanticsLabel('Preview at 800 dp, Tablet'));
      await tester.pumpAndSettle();
      expect(galleryWidth(tester), 800);

      await tester.tap(find.text('Splash'));
      await tester.pumpAndSettle();
      expect(
        MediaQuery.sizeOf(tester.element(find.byType(V2PreviewPage))).width,
        800,
      );
      // The chrome stays reachable while a screen is open.
      expect(find.bySemanticsLabel('Preview at 360 dp, Phone'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('the theme toggle flips the previewed screen', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPreview(tester);

      await tester.tap(find.bySemanticsLabel('Preview in dark theme'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(V2GalleryPage))).brightness,
        Brightness.dark,
      );

      await tester.tap(find.bySemanticsLabel('Preview in light theme'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(V2GalleryPage))).brightness,
        Brightness.light,
      );
      semantics.dispose();
    });

    testWidgets('the toolbar survives 320 dp at 200 % text', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: const preview.OvidWebPreview(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.bySemanticsLabel('Preview at 800 dp, Tablet'),
        findsOneWidget,
      );
      semantics.dispose();
    });
  });
}
