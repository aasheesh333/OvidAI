import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/data_control_export.dart';
import 'package:ovid_ai/ui/v2/settings/data_control_page.dart';
import 'package:ovid_ai/ui/v2/settings/settings_rows.dart';

const _mb = 1024 * 1024;

Widget _app(Widget home, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? OTheme.light(), home: home);

Widget _scaledApp(Widget home, {required ThemeData theme}) => MaterialApp(
  theme: theme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: const TextScaler.linear(2)),
    child: child!,
  ),
  home: home,
);

void _usePhone(WidgetTester tester, {double width = 320, double height = 700}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The real work, faked so a widget test can drive every outcome.
class _FakeService implements V2DataControlService {
  _FakeService({
    this.available = true,
    V2ExportOutcome? exportOutcome,
    this.preview,
    V2ImportOutcome? importOutcome,
    V2DeleteOutcome? deleteOutcome,
  }) : exportOutcome =
           exportOutcome ??
           const V2ExportOutcome.shared(
             chats: 42,
             messages: 860,
             bytes: 12 * _mb,
           ),
       importOutcome =
           importOutcome ??
           const V2ImportOutcome.completed(chats: 42, messages: 860),
       deleteOutcome =
           deleteOutcome ??
           const V2DeleteOutcome(completed: 8, failures: {}, verified: true);

  @override
  bool available;

  int cache = 142 * _mb;
  int freed = 142 * _mb;
  int cacheReads = 0;
  int clearCalls = 0;
  int exportCalls = 0;
  int importCalls = 0;
  int deleteCalls = 0;
  int pickCalls = 0;
  Set<String>? lastExportIds;
  Object? pickError;
  V2ImportPreview? preview;
  V2ExportOutcome exportOutcome;
  V2ImportOutcome importOutcome;
  V2DeleteOutcome deleteOutcome;
  final List<V2TransferProgress> progress = [];
  Completer<void>? exportGate;
  Completer<void>? importGate;

  @override
  Future<V2ExportOutcome> exportBackup({
    Set<String>? sessionIds,
    void Function(V2TransferProgress progress)? onProgress,
  }) async {
    exportCalls++;
    lastExportIds = sessionIds;
    const tick = V2TransferProgress(
      label: 'Downloading chat 1 of 2…',
      fraction: 0.5,
    );
    progress.add(tick);
    onProgress?.call(tick);
    final gate = exportGate;
    if (gate != null) await gate.future;
    return exportOutcome;
  }

  @override
  Future<V2ImportPreview?> pickImport() async {
    pickCalls++;
    final error = pickError;
    if (error != null) throw error;
    return preview;
  }

  @override
  Future<V2ImportOutcome> importBackup(
    V2ImportPreview preview, {
    void Function(V2TransferProgress progress)? onProgress,
  }) async {
    importCalls++;
    onProgress?.call(
      const V2TransferProgress(label: 'Uploading chat 1 of 2…', fraction: 0.5),
    );
    final gate = importGate;
    if (gate != null) await gate.future;
    return importOutcome;
  }

  @override
  Future<int> cacheBytes() async {
    cacheReads++;
    return cache;
  }

  @override
  Future<int> clearCache() async {
    clearCalls++;
    final before = cache;
    cache = 0;
    return freed > before ? before : freed;
  }

  @override
  Future<V2DeleteOutcome> deleteDeviceData() async {
    deleteCalls++;
    return deleteOutcome;
  }
}

V2DataControlPageData _data({
  bool hasData = true,
  bool loading = false,
  String? errorMessage,
  VoidCallback? onRetry,
  String totalDataSizeLabel = '',
  List<V2ExportSession> exportSessions = const <V2ExportSession>[],
  String accountContact = 'me@example.com',
  V2DataControlService? service,
  VoidCallback? onExport,
  VoidCallback? onChooseImport,
  VoidCallback? onDeleteData,
}) {
  return V2DataControlPageData(
    hasData: hasData,
    loading: loading,
    errorMessage: errorMessage,
    onRetry: onRetry,
    totalDataSizeLabel: totalDataSizeLabel,
    exportSessions: exportSessions,
    accountContact: accountContact,
    service: service,
    onExport: onExport,
    onChooseImport: onChooseImport,
    onDeleteData: onDeleteData,
  );
}

const _overCapSessions = <V2ExportSession>[
  V2ExportSession(
    id: 'a',
    name: 'Q3 launch plan',
    sizeBytes: 50 * _mb,
    sizeLabel: '50 MB',
    detail: '42 messages',
  ),
  V2ExportSession(
    id: 'b',
    name: 'Market research',
    sizeBytes: 40 * _mb,
    sizeLabel: '40 MB',
    detail: '18 messages',
  ),
];

void main() {
  testWidgets('one header and four real rows with their scope', (tester) async {
    final service = _FakeService();
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            service: service,
            totalDataSizeLabel: '1.2 GB across 42 chats',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Data control'), findsOneWidget);
    expect(find.text('Export backup'), findsOneWidget);
    expect(find.text('Import backup'), findsOneWidget);
    expect(find.text('Clear cache'), findsOneWidget);
    expect(find.text('Delete data'), findsOneWidget);

    // The cache row shows the measured size, not a placeholder.
    expect(find.text('142 MB'), findsOneWidget);
    // Rows carry their scope as the meta line.
    expect(find.text('1.2 GB across 42 chats'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    // Every row is a real action.
    for (final key in <String>[
      'export-backup-row',
      'import-backup-row',
      'clear-cache-row',
      'delete-data-row',
    ]) {
      final row = tester.widget<V2SettingsRow>(find.byKey(ValueKey(key)));
      expect(row.onTap, isNotNull, reason: '$key must do something');
    }
  });

  testWidgets('crash consent shows the real value and reports the change', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: V2DataControlPageData(
            service: _FakeService(),
            crashReports: false,
            onCrashReportsChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The row names what leaves the device, and the switch is the stored value.
    expect(find.text('Crash reports'), findsOneWidget);
    expect(find.text('Crash logs and anonymous usage counts'), findsOneWidget);
    final toggle = find.byKey(const ValueKey<String>('crash-reports-switch'));
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(changes, <bool>[true]);
    expect(tester.widget<Switch>(toggle).value, isTrue);
  });

  testWidgets('no crash row without a host that persists it', (tester) async {
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: _FakeService()))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('crash-reports-row')), findsNothing);
  });

  testWidgets('export opens the scope sheet, shows progress and the result', (
    tester,
  ) async {
    final service = _FakeService();
    service.exportGate = Completer<void>();
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(service: service, totalDataSizeLabel: '42 chats'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();
    expect(find.text('Export scope'), findsOneWidget);
    expect(find.text('All chats'), findsOneWidget);
    // The cap is stated because the service and picker enforce it, and the
    // sheet names what a transcript archive cannot carry.
    expect(find.text('64 MB per backup'), findsOneWidget);
    expect(
      find.text('Chats only. Files and memory stay online.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Export'));
    await tester.pump();

    // Exporting: a live progress card, not a toast.
    expect(find.byKey(const ValueKey('data-control-progress')), findsOneWidget);
    expect(find.text('Downloading chat 1 of 2…'), findsOneWidget);
    expect(service.exportCalls, 1);
    expect(service.lastExportIds, isNull, reason: 'all chats');

    service.exportGate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('Backup shared'), findsOneWidget);
    expect(find.text('42 chats · 12 MB'), findsOneWidget);
  });

  testWidgets('over the cap the scope sheet asks which chats', (tester) async {
    final service = _FakeService();
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(service: service, exportSessions: _overCapSessions),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();

    // Every chat together is over 64 MB, so only a subset can be exported.
    expect(find.text('Over the archive limit'), findsOneWidget);
    expect(find.text('Choose chats'), findsOneWidget);

    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(find.text('Export chats'), findsOneWidget);
    expect(find.text('90 MB of 64 MB selected'), findsOneWidget);

    // Deselect the 40 MB chat, leaving a selection that fits.
    await tester.tap(find.byKey(const ValueKey('export-picker-session-b')));
    await tester.pump();
    expect(find.text('50 MB of 64 MB selected'), findsOneWidget);

    await tester.tap(find.text('Export selection'));
    await tester.pumpAndSettle();

    expect(service.lastExportIds, <String>{'a'});
    expect(find.text('Backup shared'), findsOneWidget);
  });

  testWidgets('an export failure names the reason and offers a retry', (
    tester,
  ) async {
    final service = _FakeService(
      exportOutcome: const V2ExportOutcome.failed(
        'Sign in to Ovid Cloud first.',
      ),
    );
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: service))),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(find.text('Export failed'), findsOneWidget);
    expect(find.text('Sign in to Ovid Cloud first.'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Export scope'), findsOneWidget);
  });

  testWidgets('a truncated archive says what it left out and why', (
    tester,
  ) async {
    final service = _FakeService(
      exportOutcome: const V2ExportOutcome.shared(
        chats: 1000,
        messages: 20000,
        bytes: 64 * _mb,
        skippedChats: 3,
        limitHit: 'the backup limit of 1,000 chats',
      ),
    );
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: service))),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();

    expect(find.textContaining('3 left out'), findsOneWidget);
    expect(
      find.text('Stopped by the backup limit of 1,000 chats.'),
      findsOneWidget,
    );
  });

  testWidgets('import previews the archive, then reports what was added', (
    tester,
  ) async {
    final service = _FakeService(
      preview: const V2ImportPreview(
        fileName: 'ovid-backup.zip',
        bytes: 12 * _mb,
        chats: 2,
        messages: 20,
        filesIncluded: 3,
      ),
    );
    service.importGate = Completer<void>();
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: service))),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import backup'));
    await tester.pumpAndSettle();

    // Nothing is uploaded before the preview is confirmed.
    expect(find.text('ovid-backup.zip'), findsOneWidget);
    expect(find.text('2 chats · 20 messages · 12 MB'), findsOneWidget);
    expect(find.text('3 files included'), findsOneWidget);
    expect(service.importCalls, 0);

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    // Importing: the real phase is shown while the upload runs.
    expect(find.byKey(const ValueKey('data-control-progress')), findsOneWidget);
    expect(find.text('Uploading chat 1 of 2…'), findsOneWidget);

    service.importGate!.complete();
    await tester.pumpAndSettle();

    expect(service.importCalls, 1);
    expect(find.text('Import complete'), findsOneWidget);
    expect(find.text('42 chats · 860 messages added'), findsOneWidget);
  });

  testWidgets('import reports per-item failures', (tester) async {
    final service = _FakeService(
      preview: const V2ImportPreview(
        fileName: 'ovid-backup.zip',
        bytes: 12 * _mb,
        chats: 2,
        messages: 20,
      ),
      importOutcome: const V2ImportOutcome.completed(
        chats: 1,
        messages: 10,
        failures: [
          V2ImportFailure(
            item: 'Broken chat',
            reason: 'The server rejected this chat.',
          ),
        ],
      ),
    );
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: service))),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.text('Import stopped'), findsOneWidget);
    expect(find.text('Broken chat'), findsOneWidget);
    expect(find.text('The server rejected this chat.'), findsOneWidget);
  });

  testWidgets('an unreadable file is reported with its reason', (tester) async {
    final service = _FakeService()
      ..pickError = const V2BackupException('That file is not an Ovid backup.');
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: service))),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import backup'));
    await tester.pumpAndSettle();

    expect(find.text('Import failed'), findsOneWidget);
    expect(find.text('That file is not an Ovid backup.'), findsOneWidget);
    expect(find.text('Choose file'), findsOneWidget);
    expect(service.importCalls, 0);
  });

  testWidgets('clear cache shows the real size and updates afterwards', (
    tester,
  ) async {
    final service = _FakeService();
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: service))),
    );
    await tester.pumpAndSettle();

    expect(find.text('142 MB'), findsOneWidget);

    await tester.tap(find.text('Clear cache'));
    await tester.pumpAndSettle();

    expect(service.clearCalls, 1);
    expect(find.text('Freed 142 MB.'), findsOneWidget);
    // The row now reports what is left, not what was there before.
    expect(find.text('0 B'), findsOneWidget);
    expect(find.text('142 MB'), findsNothing);
  });

  testWidgets('delete is typed, scoped and names what it removes', (
    tester,
  ) async {
    _usePhone(tester, width: 420, height: 900);
    final handle = tester.ensureSemantics();
    final service = _FakeService();
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: service))),
    );
    await tester.pumpAndSettle();

    // The row announces that it is destructive before it is tapped.
    final row = tester.getSemantics(
      find.bySemanticsLabel('Delete data, this device'),
    );
    expect(row.hint, contains('Destructive'));

    await tester.tap(find.text('Delete data'));
    await tester.pumpAndSettle();

    expect(find.text('Delete device data?'), findsOneWidget);
    expect(find.text('Removed from device'), findsOneWidget);
    expect(find.text('Chats and messages'), findsOneWidget);
    expect(find.text('Saved keys and sign-in'), findsOneWidget);
    expect(service.deleteCalls, 0, reason: 'nothing before confirmation');

    final button = tester.widget<OButton>(
      find.byKey(const ValueKey('confirm-typed-button')),
    );
    expect(button.onPressed, isNull, reason: 'typing unlocks the action');

    await tester.enterText(
      find.byKey(const ValueKey('confirm-typed-field')),
      'me@example.com',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('confirm-typed-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-typed-button')));
    await tester.pumpAndSettle();

    expect(service.deleteCalls, 1);
    expect(find.text('Device data deleted'), findsOneWidget);
    expect(find.text('Cloud chats were kept.'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('delete reports the stores it could not remove', (tester) async {
    _usePhone(tester, width: 420, height: 900);
    final service = _FakeService(
      deleteOutcome: const V2DeleteOutcome(
        completed: 6,
        verified: false,
        failures: {'cache': 'A file was in use.'},
      ),
    );
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: service))),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete data'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('confirm-typed-field')),
      'me@example.com',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('confirm-typed-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-typed-button')));
    await tester.pumpAndSettle();

    expect(find.text('Delete incomplete'), findsOneWidget);
    expect(find.text('6 of 7 items removed.'), findsOneWidget);
    expect(find.text('Cache'), findsOneWidget);
    expect(find.text('A file was in use.'), findsOneWidget);
  });

  testWidgets('a row with no path is removed', (tester) async {
    final service = _FakeService(available: false);
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: service))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Export backup'), findsNothing);
    expect(find.text('Import backup'), findsNothing);
    expect(find.text('Clear cache'), findsNothing);
    expect(find.text('Delete data'), findsNothing);
  });

  testWidgets('a host callback still backs its row on web', (tester) async {
    var exports = 0;
    final service = _FakeService(available: false);
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(service: service, onExport: () => exports++),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Export backup'), findsOneWidget);
    await tester.tap(find.text('Export backup'));
    expect(exports, 1);
  });

  testWidgets('loading renders skeletons and error offers a retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(service: _FakeService(), loading: true)),
      ),
    );
    await tester.pump();
    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Export backup'), findsNothing);

    var retried = false;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            service: _FakeService(),
            errorMessage: 'Could not load data control.',
            onRetry: () => retried = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not load data control.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });

  testWidgets('empty state offers the real import action', (tester) async {
    final service = _FakeService(
      preview: const V2ImportPreview(
        fileName: 'ovid-backup.zip',
        bytes: 12 * _mb,
        chats: 1,
        messages: 2,
      ),
    );
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: service, hasData: false))),
    );
    await tester.pumpAndSettle();

    expect(find.text('No data yet'), findsOneWidget);
    await tester.tap(find.text('Import backup'));
    await tester.pumpAndSettle();
    expect(find.text('ovid-backup.zip'), findsOneWidget);
  });

  testWidgets('progress is a live region', (tester) async {
    final handle = tester.ensureSemantics();
    final service = _FakeService()..exportGate = Completer<void>();
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: service))),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export'));
    await tester.pump();

    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('Exporting backup')),
    );
    expect(node.flagsCollection.isLiveRegion, isTrue);
    expect(node.label, contains('Downloading chat 1 of 2'));

    service.exportGate!.complete();
    await tester.pumpAndSettle();
    handle.dispose();
  });

  testWidgets('fits 320 dp at 200% text in light and dark', (tester) async {
    _usePhone(tester);
    final service = _FakeService(
      preview: const V2ImportPreview(
        fileName: 'ovid-backup-2026-10-21-with-a-long-name.zip',
        bytes: 12 * _mb,
        chats: 42,
        messages: 860,
        filesIncluded: 3,
        filesUnavailable: 2,
      ),
    );
    for (final theme in <ThemeData>[OTheme.light(), OTheme.dark()]) {
      await tester.pumpWidget(
        _scaledApp(
          DataControlPage(
            data: _data(
              service: service,
              totalDataSizeLabel: '1.2 GB across 42 chats',
            ),
          ),
          theme: theme,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // The scope sheet and the import preview also fit.
      await tester.tap(find.text('Export backup'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Import backup'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('rows are at least 56 dp tall', (tester) async {
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(service: _FakeService()))),
    );
    await tester.pumpAndSettle();

    for (final key in <String>[
      'export-backup-row',
      'import-backup-row',
      'clear-cache-row',
      'delete-data-row',
    ]) {
      expect(
        tester.getSize(find.byKey(ValueKey(key))).height,
        greaterThanOrEqualTo(56),
        reason: key,
      );
    }
  });

  testWidgets('content is centred and capped at 600 and 900 dp', (
    tester,
  ) async {
    for (final size in <Size>[const Size(600, 900), const Size(900, 900)]) {
      _usePhone(tester, width: size.width, height: size.height);
      await tester.pumpWidget(
        _app(DataControlPage(data: _data(service: _FakeService()))),
      );
      await tester.pumpAndSettle();

      final row = tester.getRect(
        find.byKey(const ValueKey('export-backup-row')),
      );
      final cap = size.width >= 900 ? 720.0 : 640.0;
      expect(row.width, lessThanOrEqualTo(cap));
      expect(row.left, greaterThan(0));
      expect(row.right, lessThan(size.width));
    }
  });
}
