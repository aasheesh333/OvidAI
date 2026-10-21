import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/settings/confirm_typed_sheet.dart';
import 'package:ovid_ai/ui/v2/settings/data_control_page.dart';
import 'package:ovid_ai/ui/v2/settings/export_picker_sheet.dart';

Widget _app(Widget home, {required ThemeData theme}) =>
    MaterialApp(theme: theme, home: home);

const _mb = 1024 * 1024;

const _sessions = <V2ExportSession>[
  V2ExportSession(
    id: 'launch',
    name: 'Q3 launch plan',
    detail: '42 messages',
    sizeBytes: 40 * _mb,
    sizeLabel: '40 MB',
    heavyArtifacts: true,
  ),
  V2ExportSession(
    id: 'research',
    name: 'Market research',
    detail: '18 messages',
    sizeBytes: 30 * _mb,
    sizeLabel: '30 MB',
  ),
  V2ExportSession(
    id: 'notes',
    name: 'Meeting notes',
    detail: '6 messages',
    sizeBytes: 20 * _mb,
    sizeLabel: '20 MB',
  ),
];

V2DataControlPageData _data({
  String? totalDataSizeLabel = '1.2 GB across 42 chats',
  String accountContact = 'aarav@example.com',
  String memorySummaryLabel = '',
  bool crashReports = true,
  List<V2ExportSession> exportSessions = const <V2ExportSession>[],
  int exportLimitBytes = 64 * _mb,
  V2ImportValidation? importValidation,
  VoidCallback? onExportImport,
  VoidCallback? onExport,
  VoidCallback? onChooseImport,
  VoidCallback? onImport,
  V2ExportSessionToggle? onExportSessionToggled,
  VoidCallback? onPermissions,
  ValueChanged<bool>? onCrashReportsChanged,
  VoidCallback? onStorage,
  VoidCallback? onDeleteData,
  VoidCallback? onResetMemory,
}) {
  return V2DataControlPageData(
    lastExportLabel: 'Last export: today at 4:15 AM',
    backupSizeLabel: '12 MB ready',
    totalDataSizeLabel: totalDataSizeLabel ?? '',
    permissionSummary: 'Browser, files and connectors',
    storageUsedLabel: '1.2 GB of 3 GB used',
    storageFraction: 0.4,
    storageFreeLabel: '1.8 GB free',
    crashReports: crashReports,
    exportSessions: exportSessions,
    exportLimitBytes: exportLimitBytes,
    importValidation: importValidation,
    accountContact: accountContact,
    memorySummaryLabel: memorySummaryLabel,
    onExportImport: onExportImport,
    onExport: onExport,
    onChooseImport: onChooseImport,
    onImport: onImport,
    onExportSessionToggled: onExportSessionToggled,
    onPermissions: onPermissions,
    onCrashReportsChanged: onCrashReportsChanged,
    onStorage: onStorage,
    onDeleteData: onDeleteData,
    onResetMemory: onResetMemory,
  );
}

OButton _button(WidgetTester tester, String label) => tester.widget<OButton>(
  find.byWidgetPredicate(
    (widget) => widget is OButton && widget.label == label,
  ),
);

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
    expect(find.text('1.2 GB across 42 chats'), findsOneWidget);
    expect(find.text('Crash reports'), findsOneWidget);
    expect(find.text('BACKUP AND RESTORE'), findsOneWidget);
    expect(
      find.text('Last export: today at 4:15 AM · 12 MB ready'),
      findsOneWidget,
    );
    expect(find.text('Browser, files and connectors'), findsOneWidget);
    expect(
      find.textContaining('must be re-uploaded after importing'),
      findsOneWidget,
    );
  });

  testWidgets('renders in dark mode', (tester) async {
    await tester.pumpWidget(
      _app(DataControlPage(data: _data()), theme: OTheme.dark()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Data control'), findsOneWidget);
    expect(find.text('Delete your data'), findsOneWidget);
    expect(find.text('Reset memory'), findsOneWidget);
    expect(
      find.textContaining(
        'global memory and the memory file for every session',
      ),
      findsOneWidget,
    );
  });

  testWidgets('crash reports are on by default and can be opted out', (
    tester,
  ) async {
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

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    expect(next, isFalse);
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

    await tester.ensureVisible(find.text('Export or import'));
    await tester.tap(find.text('Export or import'));
    expect(exported, isTrue);
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

  testWidgets('valid import shows the check result, quota and imports', (
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
              planQuotaLabel: 'Needs 12 MB · 1.8 GB free on your plan.',
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
    expect(
      find.text('Needs 12 MB · 1.8 GB free on your plan.'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Import now'));
    await tester.tap(find.text('Import now'));
    expect(imported, isTrue);
  });

  testWidgets('import over the plan quota is blocked and offers storage', (
    tester,
  ) async {
    var imported = false;
    var openedStorage = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            onImport: () => imported = true,
            onStorage: () => openedStorage = true,
            importValidation: const V2ImportValidation(
              fileName: 'big-backup.zip',
              message: 'Ready to import: 1.8 GB · 42 chats.',
              valid: true,
              fitsPlan: false,
              planQuotaLabel: 'Needs 1.8 GB · 1.2 GB free on your plan.',
            ),
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Needs 1.8 GB · 1.2 GB free on your plan.'),
      findsOneWidget,
    );
    expect(find.text('Import now'), findsNothing);
    expect(find.text('Manage storage'), findsOneWidget);

    await tester.ensureVisible(find.text('Manage storage'));
    await tester.tap(find.text('Manage storage'));
    expect(openedStorage, isTrue);
    expect(imported, isFalse);
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

  testWidgets('over-limit export opens the picker instead of an inline list', (
    tester,
  ) async {
    var exported = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            exportSessions: _sessions,
            onExport: () => exported = true,
            onExportSessionToggled: (_, _) {},
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    // The old inline selection window and its checkboxes are gone.
    expect(find.byKey(const ValueKey('export-selection-window')), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byKey(const ValueKey('export-picker-note')), findsOneWidget);
    expect(
      find.textContaining('Your data is 90 MB, over the 64 MB archive limit'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Export backup'));
    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();

    expect(find.byType(ExportPickerSheet), findsOneWidget);
    expect(find.text('Choose chats to export'), findsOneWidget);
    expect(find.text('90 MB of 64 MB selected'), findsOneWidget);
    expect(find.text('3 of 1,000 chats'), findsOneWidget);
    expect(find.text('66 of 20,000 messages'), findsOneWidget);
    expect(find.text('Q3 launch plan'), findsOneWidget);
    expect(find.text('Market research'), findsOneWidget);
    expect(find.byType(Checkbox), findsAtLeastNWidgets(3));
    expect(find.textContaining('must be re-uploaded'), findsWidgets);

    // 90 MB is over the 64 MB cap, so the picker's export stays disabled
    // until chats are deselected.
    expect(_button(tester, 'Export selection').onPressed, isNull);
    expect(exported, isFalse);
  });

  testWidgets('checkbox toggles report the chat and the new value', (
    tester,
  ) async {
    String? toggledId;
    bool? toggledValue;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            exportSessions: _sessions,
            onExport: () {},
            onExportSessionToggled: (id, value) {
              toggledId = id;
              toggledValue = value;
            },
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Export backup'));
    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('export-picker-session-launch')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('export-picker-session-launch')),
    );
    expect(toggledId, 'launch');
    expect(toggledValue, isFalse);
  });

  testWidgets('a selection under the limit enables export', (tester) async {
    var exported = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            exportSessions: const [
              V2ExportSession(
                id: 'launch',
                name: 'Q3 launch plan',
                sizeBytes: 40 * _mb,
                sizeLabel: '40 MB',
                selected: false,
              ),
              V2ExportSession(
                id: 'research',
                name: 'Market research',
                sizeBytes: 30 * _mb,
                sizeLabel: '30 MB',
              ),
              V2ExportSession(
                id: 'notes',
                name: 'Meeting notes',
                sizeBytes: 20 * _mb,
                sizeLabel: '20 MB',
                selected: false,
              ),
            ],
            onExport: () => exported = true,
            onExportSessionToggled: (_, _) {},
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Export backup'));
    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();

    expect(find.text('30 MB of 64 MB selected'), findsOneWidget);
    expect(find.text('1 of 1,000 chats'), findsOneWidget);
    expect(_button(tester, 'Export selection').onPressed, isNotNull);

    await tester.ensureVisible(find.text('Export selection'));
    await tester.tap(find.text('Export selection'));
    await tester.pumpAndSettle();
    expect(exported, isTrue);
  });

  testWidgets('picker select all reports each changed chat', (tester) async {
    final changes = <String, bool>{};
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            exportSessions: const [
              V2ExportSession(
                id: 'big',
                name: 'Big chat',
                sizeBytes: 50 * _mb,
                sizeLabel: '50 MB',
              ),
              V2ExportSession(
                id: 'small-a',
                name: 'Small A',
                sizeBytes: 10 * _mb,
                sizeLabel: '10 MB',
                selected: false,
              ),
              V2ExportSession(
                id: 'small-b',
                name: 'Small B',
                sizeBytes: 10 * _mb,
                sizeLabel: '10 MB',
                selected: false,
              ),
            ],
            onExport: () {},
            onExportSessionToggled: (id, value) => changes[id] = value,
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Export backup'));
    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();

    // Only one 10 MB chat still fits under the 64 MB archive limit.
    await tester.tap(
      find.byKey(const ValueKey('export-picker-select-all-checkbox')),
    );
    await tester.pump();

    expect(changes, {'small-a': true});
  });

  testWidgets('delete data requires typing the registered email', (
    tester,
  ) async {
    var deleted = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onDeleteData: () => deleted = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Delete your data'));
    await tester.tap(find.text('Delete your data'));
    await tester.pumpAndSettle();

    expect(find.byType(V2ConfirmTypedSheet), findsOneWidget);
    expect(find.text('Delete all your data?'), findsOneWidget);
    expect(find.text('Every chat and message'), findsOneWidget);
    expect(
      find.text('Workspace files and generated artifacts'),
      findsOneWidget,
    );
    expect(find.text('aarav@example.com'), findsWidgets);

    final confirm = find.byKey(const ValueKey('confirm-typed-button'));
    expect(tester.widget<OButton>(confirm).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('confirm-typed-field')),
      'wrong@example.com',
    );
    await tester.pump();
    expect(
      find.text('That does not match the email or phone on your account.'),
      findsOneWidget,
    );
    expect(tester.widget<OButton>(confirm).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('confirm-typed-field')),
      'AARAV@example.com',
    );
    await tester.pump();
    expect(tester.widget<OButton>(confirm).onPressed, isNotNull);

    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
  });

  testWidgets('cancelling delete keeps the data', (tester) async {
    var deleted = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(onDeleteData: () => deleted = true)),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Delete your data'));
    await tester.tap(find.text('Delete your data'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Delete all your data?'), findsNothing);
    expect(deleted, isFalse);
  });

  testWidgets('reset memory has its own confirm and names every scope', (
    tester,
  ) async {
    var reset = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            onResetMemory: () => reset = true,
            memorySummaryLabel: 'Global memory and 12 session files',
          ),
        ),
        theme: OTheme.light(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Reset memory'));
    await tester.tap(find.text('Reset memory'));
    await tester.pumpAndSettle();

    expect(find.text('Reset all memory?'), findsOneWidget);
    expect(find.text('Global memory and 12 session files'), findsOneWidget);
    expect(
      find.textContaining('Project memory for every project'),
      findsOneWidget,
    );
    expect(
      find.textContaining('The memory file for every session'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(reset, isFalse);

    await tester.ensureVisible(find.text('Reset memory'));
    await tester.tap(find.text('Reset memory'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('reset-memory-confirm')));
    await tester.pumpAndSettle();
    expect(reset, isTrue);
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
                  exportSessions: _sessions,
                  onExport: () {},
                  onExportSessionToggled: (_, _) {},
                  importValidation: const V2ImportValidation(
                    fileName: 'ovid-backup-2026-10-21.zip',
                    message:
                        'Ready to import: 12 MB · 42 chats · 860 messages.',
                    valid: true,
                    planQuotaLabel: 'Needs 12 MB · 1.8 GB free on your plan.',
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

  for (final dark in [false, true]) {
    testWidgets(
      'destructive dialogs fit 320 dp at 200% (${dark ? 'dark' : 'light'})',
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
                data: _data(onDeleteData: () {}, onResetMemory: () {}),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('Delete your data'));
        await tester.tap(find.text('Delete your data'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Delete all your data?'), findsOneWidget);

        await tester.ensureVisible(find.text('Cancel'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.text('Reset memory'));
        await tester.tap(find.text('Reset memory'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Reset all memory?'), findsOneWidget);
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
            onResetMemory: () {},
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
