import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/settings/data_control_page.dart';

Widget _app(Widget home, {required ThemeData theme}) =>
    MaterialApp(theme: theme, home: home);

V2DataControlPageData _data({
  VoidCallback? onExportImport,
  VoidCallback? onExport,
  VoidCallback? onChooseImport,
  VoidCallback? onImport,
  VoidCallback? onPermissions,
  ValueChanged<bool>? onCrashReportsChanged,
  VoidCallback? onDeleteData,
  V2ImportValidation? importValidation,
}) {
  return V2DataControlPageData(
    lastExportLabel: 'Last export: today at 4:15 AM',
    backupSizeLabel: '12 MB ready',
    permissionSummary: 'Browser, files and connectors',
    storageUsedLabel: '1.2 GB of 3 GB used',
    storageFraction: 0.4,
    storageFreeLabel: '1.8 GB free',
    crashReports: true,
    importValidation: importValidation,
    onExportImport: onExportImport,
    onExport: onExport,
    onChooseImport: onChooseImport,
    onImport: onImport,
    onPermissions: onPermissions,
    onCrashReportsChanged: onCrashReportsChanged,
    onDeleteData: onDeleteData,
  );
}

void main() {
  testWidgets('renders data controls in light mode', (tester) async {
    await tester.pumpWidget(
      _app(DataControlPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Data control'), findsOneWidget);
    expect(find.text('Privacy & Data Control'), findsOneWidget);
    expect(find.text('Export or import'), findsOneWidget);
    expect(
      find.text('Up to 64 MB · 1,000 sessions · 20,000 messages'),
      findsWidgets,
    );
    expect(find.text('Crash reports'), findsOneWidget);
    expect(find.text('BACKUP AND RESTORE'), findsOneWidget);
    expect(
      find.text('Last export: today at 4:15 AM · 12 MB ready'),
      findsOneWidget,
    );
    expect(find.text('Browser, files and connectors'), findsOneWidget);
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(DataControlPage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Data control'), findsOneWidget);
    expect(find.text('Delete your data'), findsOneWidget);
    expect(find.text('Reset memory'), findsOneWidget);
  });

  testWidgets('empty state offers export or import', (tester) async {
    var exported = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: V2DataControlPageData(
            hasData: false,
            onExportImport: () => exported = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No data to manage yet'), findsOneWidget);
    await tester.tap(find.text('Export or import'));
    expect(exported, isTrue);
  });

  testWidgets('export row fires the primary callback', (tester) async {
    var exported = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onExportImport: () => exported = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Export or import'));
    expect(exported, isTrue);
  });

  testWidgets('crash report switch reports the new value', (tester) async {
    bool? next;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(onCrashReportsChanged: (value) => next = value),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    expect(next, isFalse);
  });

  testWidgets('choose backup fires the import picker callback', (tester) async {
    var chosen = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onChooseImport: () => chosen = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Choose backup'));
    await tester.tap(find.text('Choose backup'));
    expect(chosen, isTrue);
  });

  testWidgets('valid import shows the check result and imports', (
    tester,
  ) async {
    var imported = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            onImport: () => imported = true,
            importValidation: const V2ImportValidation(
              fileName: 'ovid-backup-2026-10-21.zip',
              message: 'Ready to import: 12 MB · 42 chats · 860 messages.',
              valid: true,
            ),
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ovid-backup-2026-10-21.zip'), findsOneWidget);
    expect(
      find.text('Ready to import: 12 MB · 42 chats · 860 messages.'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Import now'));
    await tester.tap(find.text('Import now'));
    expect(imported, isTrue);
  });

  testWidgets('invalid import explains the problem without an import action', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            importValidation: const V2ImportValidation(
              fileName: 'too-big.zip',
              message: 'This file is 71 MB. The limit is 64 MB.',
              valid: false,
            ),
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('too-big.zip'), findsOneWidget);
    expect(
      find.text('This file is 71 MB. The limit is 64 MB.'),
      findsOneWidget,
    );
    expect(find.text('Import now'), findsNothing);
    expect(find.text('Choose another file'), findsOneWidget);
  });

  testWidgets('defaults carry no demo values', (tester) async {
    await tester.pumpWidget(
      _app(
        const DataControlPage(data: V2DataControlPageData()),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Data control'), findsOneWidget);
    expect(find.textContaining('4:15'), findsNothing);
    expect(find.textContaining('12 MB ready'), findsNothing);
    expect(find.textContaining('1.2 GB'), findsNothing);
    expect(find.textContaining('Browser, files and connectors'), findsNothing);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'no overflow at 320 dp and 200% text (${dark ? 'dark' : 'light'})',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? OTheme.dark() : OTheme.light(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: DataControlPage(
                data: _data(
                  importValidation: const V2ImportValidation(
                    fileName: 'ovid-backup-2026-10-21.zip',
                    message:
                        'Ready to import: 12 MB · 42 chats · 860 messages.',
                    valid: true,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expect(tester.takeException(), isNull);
        _expectTextInsideViewport(tester);
      },
    );
  }

  testWidgets('crash report toggle is announced as disabled', (tester) async {
    await tester.pumpWidget(
      _app(DataControlPage(data: _data()), theme: OTheme.light()),
    );
    await tester.pumpAndSettle();

    Semantics toggleNode() => tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == 'Crash reports',
      ),
    );

    expect(toggleNode().properties.enabled, isFalse);
    expect(toggleNode().properties.toggled, isTrue);
  });

  testWidgets('crash report toggle is announced as enabled when wired', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onCrashReportsChanged: (_) {})),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = tester.widget<Semantics>(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == 'Crash reports',
      ),
    );
    expect(toggle.properties.enabled, isTrue);
  });

  testWidgets('content stays visible when motion is reduced', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            disableAnimations: true,
          ),
          child: DataControlPage(data: _data()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Privacy & Data Control'), findsOneWidget);
    expect(find.text('Delete your data'), findsOneWidget);
  });

  testWidgets('loading state shows a skeleton list', (tester) async {
    await tester.pumpWidget(
      _app(
        const DataControlPage(data: V2DataControlPageData(loading: true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pump();

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Privacy & Data Control'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('every control is at least 48 dp tall', (tester) async {
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            onExportImport: () {},
            onExport: () {},
            onChooseImport: () {},
            onPermissions: () {},
            onCrashReportsChanged: (_) {},
            onDeleteData: () {},
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    final buttons = find.byType(OButton);
    expect(buttons, findsWidgets);
    for (var i = 0; i < buttons.evaluate().length; i++) {
      expect(
        tester.getSize(buttons.at(i)).height,
        greaterThanOrEqualTo(OSpace.touch),
      );
    }
    expect(
      tester.getSize(find.byType(Switch)).height,
      greaterThanOrEqualTo(OSpace.touch),
    );
  });

  testWidgets('error state offers a retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: V2DataControlPageData(
            errorMessage: 'Your data settings could not load.',
            onRetry: () => retried = true,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Your data settings could not load.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });
}

/// Fails when a text run is laid out outside the 320 dp viewport, which is how
/// clipped copy shows up at 200 % text. Text inside the viewport may still be
/// ellipsized (allowed by the contract) or below the fold (the body scrolls).
void _expectTextInsideViewport(WidgetTester tester) {
  for (final element in find.byType(Text).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final label = (element.widget as Text).data ?? '<rich>';
    expect(
      rect.left,
      greaterThanOrEqualTo(-0.5),
      reason: '"$label" starts left of the screen',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(320.5),
      reason: '"$label" runs past the right edge',
    );
  }
}
