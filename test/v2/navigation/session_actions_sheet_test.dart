import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/sidebar/session_actions_sheet.dart';

const _data = V2SessionActionsData(
  title: 'Landing page redesign',
  modelLabel: 'Auto',
  timeLabel: 'Today at 10:24 AM',
  messageCount: 14,
  projectName: 'Mobile App Redesign',
);

const _labels = <String>[
  'Pin chat',
  'Rename chat',
  'Add to project',
  'Share chat',
  'Duplicate chat',
  'Export Markdown',
  'Delete chat',
];

V2SessionActionsHandlers _handlers({
  Future<void> Function(bool pinned)? setPinned,
  Future<void> Function(String title)? rename,
  Future<void> Function()? addToProject,
  Future<void> Function()? share,
  Future<void> Function()? duplicate,
  Future<void> Function()? exportMarkdown,
  Future<void> Function()? delete,
}) {
  return V2SessionActionsHandlers(
    setPinned: setPinned ?? (_) async {},
    rename: rename ?? (_) async {},
    addToProject: addToProject ?? () async {},
    share: share ?? () async {},
    duplicate: duplicate ?? () async {},
    exportMarkdown: exportMarkdown ?? () async {},
    delete: delete ?? () async {},
  );
}

Widget _app(Widget child, {ThemeData? theme, double scale = 1}) {
  return MaterialApp(
    theme: theme ?? OTheme.light(),
    builder: (context, widget) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: widget!,
    ),
    home: Scaffold(body: child),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double scale = 1,
  double width = 800,
  double height = 900,
  bool settle = true,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(_app(child, theme: theme, scale: scale));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Finder _row(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(OListRow),
);

Future<void> _tapAction(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  group('action availability', () {
    testWidgets('a sheet with no handlers renders no dead rows', (
      tester,
    ) async {
      await _pump(tester, const SessionActionsSheet(data: _data));

      expect(find.text('Landing page redesign'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
      for (final label in _labels) {
        expect(
          find.text(label),
          findsNothing,
          reason: '$label must not render without a handler',
        );
      }
    });

    testWidgets('each handler alone renders exactly its own row', (
      tester,
    ) async {
      final cases = <(String, V2SessionActionsHandlers)>[
        ('Pin chat', const V2SessionActionsHandlers(setPinned: _noopPin)),
        ('Rename chat', const V2SessionActionsHandlers(rename: _noopRename)),
        (
          'Add to project',
          const V2SessionActionsHandlers(addToProject: _noopVoid),
        ),
        ('Share chat', const V2SessionActionsHandlers(share: _noopVoid)),
        ('Duplicate chat', const V2SessionActionsHandlers(duplicate: _noopVoid)),
        (
          'Export Markdown',
          const V2SessionActionsHandlers(exportMarkdown: _noopVoid),
        ),
        ('Delete chat', const V2SessionActionsHandlers(delete: _noopVoid)),
      ];

      for (final (label, handlers) in cases) {
        await _pump(
          tester,
          SessionActionsSheet(data: _data, handlers: handlers),
        );
        expect(find.text(label), findsOneWidget, reason: label);
        for (final other in _labels.where((row) => row != label)) {
          expect(find.text(other), findsNothing, reason: '$other beside $label');
        }
      }
    });

    testWidgets('legacy callbacks keep every row live', (tester) async {
      var renames = 0;
      var deletes = 0;
      bool? pinned;

      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          onRename: () async => renames++,
          onDelete: () async => deletes++,
          onTogglePin: (value) => pinned = value,
        ),
      );

      await _tapAction(tester, 'Pin chat');
      expect(pinned, isTrue);
      await _tapAction(tester, 'Rename chat');
      await tester.pumpAndSettle();
      expect(renames, 1);
      await _tapAction(tester, 'Delete chat');
      await tester.pumpAndSettle();
      expect(deletes, 1);
    });

    test('row labels stay within the three-word budget', () {
      for (final label in <String>[..._labels, 'Unpin chat']) {
        expect(
          label.split(' ').where((word) => word.isNotEmpty).length,
          lessThanOrEqualTo(3),
          reason: label,
        );
      }
    });

    test('the header subtitle stays within the six-word budget', () {
      expect(_data.meta, 'Today at 10:24 AM · 14 messages');
      expect(
        _data.meta
            .split(RegExp(r'\s+'))
            .where((word) => word.isNotEmpty && word != '·')
            .length,
        lessThanOrEqualTo(6),
      );
      expect(
        const V2SessionActionsData(messageCount: 1, modelLabel: 'Auto').meta,
        '1 message · Auto',
      );
      expect(
        const V2SessionActionsData(modelLabel: '').meta,
        isEmpty,
      );
    });
  });

  group('rename', () {
    testWidgets('empty names are rejected inline and never persisted', (
      tester,
    ) async {
      final names = <String>[];
      var closes = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(rename: (name) async => names.add(name)),
          onClose: () => closes++,
        ),
      );

      await _tapAction(tester, 'Rename chat');
      expect(
        find.byKey(const ValueKey<String>('session-rename-field')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey<String>('session-rename-field')),
            )
            .controller
            ?.text,
        'Landing page redesign',
      );

      await tester.enterText(
        find.byKey(const ValueKey<String>('session-rename-field')),
        '   ',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('session-rename-save')),
      );
      await tester.pump();

      expect(find.text('Enter a name.'), findsOneWidget);
      expect(names, isEmpty);
      expect(
        find.byKey(const ValueKey<String>('session-rename-field')),
        findsOneWidget,
      );
      expect(closes, 0);
    });

    testWidgets('a trimmed name persists through the handler', (tester) async {
      final names = <String>[];
      var closes = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(rename: (name) async => names.add(name)),
          onClose: () => closes++,
        ),
      );

      await _tapAction(tester, 'Rename chat');
      await tester.enterText(
        find.byKey(const ValueKey<String>('session-rename-field')),
        '  Renamed chat  ',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('session-rename-save')),
      );
      await tester.pumpAndSettle();

      expect(names, <String>['Renamed chat']);
      // The header shows the name that was actually written.
      expect(find.text('Renamed chat'), findsOneWidget);
      expect(find.text('Landing page redesign'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('session-rename-field')),
        findsNothing,
      );
      // Renaming does not dismiss the sheet.
      expect(closes, 0);
    });

    testWidgets('a failed write stays inline and can be retried', (
      tester,
    ) async {
      final names = <String>[];
      var attempts = 0;
      var closes = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(
            rename: (name) async {
              attempts++;
              if (attempts == 1) throw StateError('offline');
              names.add(name);
            },
          ),
          onClose: () => closes++,
        ),
      );

      await _tapAction(tester, 'Rename chat');
      await tester.enterText(
        find.byKey(const ValueKey<String>('session-rename-field')),
        'First name',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('session-rename-save')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Rename failed.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('session-rename-field')),
        findsOneWidget,
      );
      expect(find.text('Landing page redesign'), findsOneWidget);
      expect(closes, 0);

      await tester.enterText(
        find.byKey(const ValueKey<String>('session-rename-field')),
        'Second name',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('session-rename-save')),
      );
      await tester.pumpAndSettle();

      expect(names, <String>['Second name']);
      expect(find.text('Second name'), findsOneWidget);
      expect(closes, 0);
    });

    testWidgets('a failing host-owned rename stays inline under the row', (
      tester,
    ) async {
      var closes = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          onRename: () async => throw StateError('offline'),
          onClose: () => closes++,
        ),
      );

      await _tapAction(tester, 'Rename chat');
      await tester.pumpAndSettle();

      expect(find.text('Rename failed.'), findsOneWidget);
      expect(find.text('Rename chat'), findsOneWidget);
      expect(closes, 0);
    });
  });

  group('delete', () {
    testWidgets('confirm names the chat and only closes after the delete', (
      tester,
    ) async {
      final delete = Completer<void>();
      var closes = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(delete: () => delete.future),
          onClose: () => closes++,
        ),
      );

      await _tapAction(tester, 'Delete chat');
      await tester.pumpAndSettle();

      expect(find.text('Delete “Landing page redesign”?'), findsOneWidget);
      expect(find.text('This cannot be undone.'), findsOneWidget);

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(delete.isCompleted, isFalse);
      expect(closes, 0);
      expect(find.text('Delete chat'), findsOneWidget);

      await _tapAction(tester, 'Delete chat');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      // Let the dialog's reverse transition finish; the write is still in
      // flight, so the sheet must stay and no success is claimed.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      // The dialog is gone, the write is still in flight, the sheet is open.
      expect(find.text('This cannot be undone.'), findsNothing);
      expect(closes, 0);

      delete.complete();
      await tester.pumpAndSettle();
      expect(closes, 1);
    });

    testWidgets('a failed delete stays open with an inline error', (
      tester,
    ) async {
      var closes = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(
            delete: () async => throw StateError('busy'),
          ),
          onClose: () => closes++,
        ),
      );

      await _tapAction(tester, 'Delete chat');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(closes, 0);
      expect(find.text('Delete failed. Nothing changed.'), findsOneWidget);
      expect(find.text('Delete chat'), findsOneWidget);
    });

    testWidgets('a host-owned delete waits for the flow, then closes', (
      tester,
    ) async {
      final delete = Completer<void>();
      var closes = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          onDelete: () => delete.future,
          onClose: () => closes++,
        ),
      );

      await _tapAction(tester, 'Delete chat');
      await tester.pump();
      expect(closes, 0);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      delete.complete();
      await tester.pumpAndSettle();
      expect(closes, 1);
    });

    testWidgets('a failing host-owned delete stays open with the error', (
      tester,
    ) async {
      var closes = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          onDelete: () async => throw StateError('busy'),
          onClose: () => closes++,
        ),
      );

      await _tapAction(tester, 'Delete chat');
      await tester.pumpAndSettle();

      expect(closes, 0);
      expect(find.text('Delete failed. Nothing changed.'), findsOneWidget);
      expect(find.text('Delete chat'), findsOneWidget);
    });
  });

  group('pin', () {
    testWidgets('the row reflects and announces the current state', (
      tester,
    ) async {
      final pinned = <bool>[];
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(setPinned: (value) async => pinned.add(value)),
        ),
      );

      expect(find.text('Pin chat'), findsOneWidget);
      expect(find.text('Unpin chat'), findsNothing);

      await _tapAction(tester, 'Pin chat');
      await tester.pumpAndSettle();

      expect(pinned, <bool>[true]);
      expect(find.text('Unpin chat'), findsOneWidget);
      expect(find.text('Pin chat'), findsNothing);

      await _tapAction(tester, 'Unpin chat');
      await tester.pumpAndSettle();
      expect(pinned, <bool>[true, false]);
      expect(find.text('Pin chat'), findsOneWidget);
    });

    testWidgets('a pinned chat opens with Unpin chat', (tester) async {
      await _pump(
        tester,
        SessionActionsSheet(
          data: const V2SessionActionsData(
            title: 'Landing page redesign',
            pinned: true,
          ),
          handlers: _handlers(),
        ),
      );

      expect(find.text('Unpin chat'), findsOneWidget);
      expect(find.text('Pin chat'), findsNothing);
    });

    testWidgets('a failed pin reverts and reports inline', (tester) async {
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(
            setPinned: (_) async => throw StateError('offline'),
          ),
        ),
      );

      await _tapAction(tester, 'Pin chat');
      await tester.pumpAndSettle();

      expect(find.text('Pin chat'), findsOneWidget);
      expect(find.text('Unpin chat'), findsNothing);
      expect(find.text('Pin did not update.'), findsOneWidget);
    });
  });

  group('export', () {
    testWidgets('is absent without a path and never claims success', (
      tester,
    ) async {
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: const V2SessionActionsHandlers(
            rename: _noopRename,
            delete: _noopVoid,
          ),
        ),
      );
      expect(find.text('Export Markdown'), findsNothing);

      final export = Completer<void>();
      var exports = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(
            exportMarkdown: () {
              exports++;
              return export.future;
            },
          ),
        ),
      );

      await _tapAction(tester, 'Export Markdown');
      await tester.pump();
      // The write is in flight: the row is busy and nothing is claimed.
      expect(exports, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      export.complete();
      await tester.pumpAndSettle();
      // Success feedback belongs to the export handler, which knows where the
      // Markdown went. The sheet itself must not claim "exported".
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('a failed export reports inline', (tester) async {
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(
            exportMarkdown: () async => throw StateError('disk full'),
          ),
        ),
      );

      await _tapAction(tester, 'Export Markdown');
      await tester.pumpAndSettle();

      expect(find.text('Export failed.'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a host-owned export gets the same busy and error state', (
      tester,
    ) async {
      final export = Completer<void>();
      var closes = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          onExportMarkdown: () => export.future,
          onClose: () => closes++,
        ),
      );

      await _tapAction(tester, 'Export Markdown');
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      export.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(closes, 0);
    });
  });

  group('action errors', () {
    testWidgets('a failed add to project stays by its row', (tester) async {
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(
            addToProject: () async => throw StateError('offline'),
          ),
        ),
      );

      await _tapAction(tester, 'Add to project');
      await tester.pumpAndSettle();

      expect(find.text('Project did not change.'), findsOneWidget);
    });

    testWidgets('a failed share stays by its row', (tester) async {
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(
            share: () async => throw StateError('no link'),
          ),
        ),
      );

      await _tapAction(tester, 'Share chat');
      await tester.pumpAndSettle();

      expect(find.text('Share failed.'), findsOneWidget);
    });

    testWidgets('a failed duplicate stays by its row', (tester) async {
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(
            duplicate: () async => throw StateError('no copy'),
          ),
        ),
      );

      await _tapAction(tester, 'Duplicate chat');
      await tester.pumpAndSettle();

      expect(find.text('Duplicate failed.'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('only the failing action carries the error', (tester) async {
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(
            share: () async => throw StateError('no link'),
            exportMarkdown: () async => throw StateError('disk full'),
          ),
        ),
      );

      await _tapAction(tester, 'Share chat');
      await tester.pumpAndSettle();
      expect(find.text('Share failed.'), findsOneWidget);
      expect(find.text('Export failed.'), findsNothing);

      // Starting another action clears the old error; the new one replaces it.
      await _tapAction(tester, 'Export Markdown');
      await tester.pumpAndSettle();
      expect(find.text('Export failed.'), findsOneWidget);
      expect(find.text('Share failed.'), findsNothing);
    });
  });

  group('busy state', () {
    testWidgets('one action at a time, no double tap', (tester) async {
      final share = Completer<void>();
      var shares = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(
            share: () {
              shares++;
              return share.future;
            },
          ),
        ),
      );

      await _tapAction(tester, 'Share chat');
      await tester.pump();
      expect(shares, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // The target row and every other row stop accepting taps until the
      // write settles.
      await tester.tap(find.text('Share chat'));
      await tester.pump();
      expect(shares, 1);
      for (final label in _labels) {
        final row = tester.widget<OListRow>(_row(label));
        expect(row.onTap, isNull, reason: label);
      }

      share.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('the busy row alone shows progress', (tester) async {
      final share = Completer<void>();
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(share: () => share.future),
        ),
      );

      await _tapAction(tester, 'Share chat');
      await tester.pump();
      expect(
        find.descendant(
          of: _row('Share chat'),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _row('Rename chat'),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );

      share.complete();
      await tester.pumpAndSettle();
    });
  });

  group('states and hosting', () {
    testWidgets('loading keeps one header, a skeleton and a close', (
      tester,
    ) async {
      var closes = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: const V2SessionActionsData(
            status: V2SessionActionsStatus.loading,
            title: 'Landing page redesign',
          ),
          onClose: () => closes++,
        ),
        settle: false,
      );

      expect(find.byType(OSkeletonList), findsOneWidget);
      // The header survives the loading state; a skeleton-only sheet reads as
      // a broken surface.
      expect(find.text('Landing page redesign'), findsOneWidget);
      expect(find.text('Pin chat'), findsNothing);
      await tester.tap(find.byIcon(Icons.close_rounded));
      expect(closes, 1);
    });

    testWidgets('empty state closes the sheet', (tester) async {
      var closes = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: const V2SessionActionsData(
            status: V2SessionActionsStatus.empty,
          ),
          onClose: () => closes++,
        ),
      );

      expect(find.text('Chat not found'), findsOneWidget);
      expect(find.text('Chat actions'), findsOneWidget);
      await tester.tap(find.text('Close'));
      expect(closes, 1);
    });

    testWidgets('error state retries, and drops retry without a handler', (
      tester,
    ) async {
      var retries = 0;
      await _pump(
        tester,
        SessionActionsSheet(
          data: const V2SessionActionsData(
            status: V2SessionActionsStatus.error,
            errorMessage: 'Check your connection and try again.',
          ),
          onRetry: () => retries++,
        ),
      );

      expect(find.text('Chat actions failed'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(retries, 1);

      await _pump(
        tester,
        const SessionActionsSheet(
          data: V2SessionActionsData(status: V2SessionActionsStatus.error),
        ),
      );
      // No retry control when the host has nothing to retry with.
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('an untitled chat falls back to a real name', (tester) async {
      await _pump(
        tester,
        SessionActionsSheet(
          data: const V2SessionActionsData(title: '   '),
          handlers: _handlers(),
        ),
      );

      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Rename chat'), findsOneWidget);
    });

    testWidgets('opens in the shared sheet and closes', (tester) async {
      var closes = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showSessionActionsSheet(
                    context,
                    data: _data,
                    handlers: _handlers(),
                    onClose: () => closes++,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Rename chat'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pumpAndSettle();
      expect(closes, 1);
      expect(find.text('Rename chat'), findsNothing);
    });
  });

  group('semantics', () {
    testWidgets('rows are buttons named by action and chat', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        SessionActionsSheet(data: _data, handlers: _handlers()),
      );

      for (final label in _labels.where((row) => row != 'Delete chat')) {
        final finder = find.bySemanticsLabel('$label, Landing page redesign');
        expect(finder, findsOneWidget, reason: label);
        expect(
          tester.getSemantics(finder).getSemanticsData().flagsCollection.isButton,
          isTrue,
          reason: label,
        );
      }

      final delete = tester.getSemantics(
        find.bySemanticsLabel(
          'Delete chat, Landing page redesign, destructive',
        ),
      );
      final deleteData = delete.getSemanticsData();
      expect(deleteData.flagsCollection.isButton, isTrue);
      expect(deleteData.hint, 'Cannot be undone');

      // The pin row is a live region: flipping it changes both the spoken
      // action and the state hint, so the change is announced.
      final pin = tester.getSemantics(
        find.bySemanticsLabel('Pin chat, Landing page redesign'),
      );
      expect(pin.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      expect(pin.getSemanticsData().hint, 'Not pinned');

      await _tapAction(tester, 'Pin chat');
      await tester.pumpAndSettle();
      final unpin = tester.getSemantics(
        find.bySemanticsLabel('Unpin chat, Landing page redesign'),
      );
      expect(unpin.getSemanticsData().hint, 'Pinned');

      handle.dispose();
    });

    testWidgets('the project row announces the current project', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        SessionActionsSheet(data: _data, handlers: _handlers()),
      );

      expect(
        tester
            .getSemantics(
              find.bySemanticsLabel(
                'Add to project, Landing page redesign',
              ),
            )
            .getSemanticsData()
            .hint,
        'In Mobile App Redesign',
      );

      handle.dispose();
    });

    testWidgets('destructive is more than a colour', (tester) async {
      await _pump(
        tester,
        SessionActionsSheet(data: _data, handlers: _handlers()),
      );

      final delete = tester.widget<OListRow>(_row('Delete chat'));
      expect(delete.danger, isTrue);
      expect(delete.showChevron, isFalse);
      expect(delete.icon, Icons.delete_outline_rounded);
      // No other row carries the destructive treatment.
      for (final label in _labels.where((row) => row != 'Delete chat')) {
        final row = tester.widget<OListRow>(_row(label));
        expect(row.danger, isFalse, reason: label);
        expect(row.icon, isNot(Icons.delete_outline_rounded), reason: label);
      }
    });

    testWidgets('renaming renames the target in every row label', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        SessionActionsSheet(
          data: _data,
          handlers: _handlers(rename: (_) async {}),
        ),
      );

      await _tapAction(tester, 'Rename chat');
      await tester.enterText(
        find.byKey(const ValueKey<String>('session-rename-field')),
        'Renamed chat',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('session-rename-save')),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('Share chat, Renamed chat'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Delete chat, Renamed chat, destructive'),
        findsOneWidget,
      );

      handle.dispose();
    });
  });

  group('responsive', () {
    testWidgets('320 to 1280, scale 1 and 2, light and dark', (tester) async {
      for (final width in <double>[320, 360, 412, 600, 800, 1024, 1280]) {
        for (final scale in <double>[1, 2]) {
          for (final dark in <bool>[false, true]) {
            await _pump(
              tester,
              SessionActionsSheet(data: _data, handlers: _handlers()),
              theme: dark ? OTheme.dark() : OTheme.light(),
              scale: scale,
              width: width,
            );

            final reason = '$width dp at ${scale}x, dark: $dark';
            expect(tester.takeException(), isNull, reason: reason);
            final surface = tester.getSize(
              find.byKey(const ValueKey<String>('session-actions-surface')),
            );
            expect(surface.width, lessThanOrEqualTo(560), reason: reason);
            if (width >= 600) {
              expect(surface.width, 560, reason: '$width dp is capped at 560');
            }
            for (final label in _labels) {
              expect(
                tester.getSize(_row(label)).height,
                greaterThanOrEqualTo(48),
                reason: '$label, $reason',
              );
            }
          }
        }
      }
    });

    testWidgets('every state fits 320 dp at 200 % text, both themes', (
      tester,
    ) async {
      for (final dark in <bool>[false, true]) {
        final theme = dark ? OTheme.dark() : OTheme.light();
        for (final status in <V2SessionActionsStatus>[
          V2SessionActionsStatus.loading,
          V2SessionActionsStatus.error,
          V2SessionActionsStatus.empty,
        ]) {
          await _pump(
            tester,
            SessionActionsSheet(
              data: V2SessionActionsData(
                status: status,
                title: 'Landing page redesign',
                errorMessage: 'Check your connection and try again.',
              ),
              onClose: () {},
              onRetry: () {},
            ),
            theme: theme,
            scale: 2,
            width: 320,
            settle: status != V2SessionActionsStatus.loading,
          );
          expect(tester.takeException(), isNull, reason: '$status, dark: $dark');
          // One header and a way out in every state.
          expect(find.byIcon(Icons.close_rounded), findsOneWidget);
        }
      }
    });

    testWidgets('the rename editor fits 320 dp at 200 % text', (tester) async {
      for (final dark in <bool>[false, true]) {
        await _pump(
          tester,
          SessionActionsSheet(
            key: ValueKey<String>('rename-$dark'),
            data: _data,
            handlers: _handlers(rename: (_) async {}),
          ),
          theme: dark ? OTheme.dark() : OTheme.light(),
          scale: 2,
          width: 320,
        );

        await _tapAction(tester, 'Rename chat');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'dark: $dark');
        expect(
          find.byKey(const ValueKey<String>('session-rename-field')),
          findsOneWidget,
        );
        expect(
          tester
              .getSize(
                find.byKey(const ValueKey<String>('session-rename-save')),
              )
              .height,
          greaterThanOrEqualTo(48),
        );
      }
    });

    testWidgets('the confirmation fits 320 dp at 200 % text', (tester) async {
      for (final dark in <bool>[false, true]) {
        await _pump(
          tester,
          SessionActionsSheet(data: _data, handlers: _handlers()),
          theme: dark ? OTheme.dark() : OTheme.light(),
          scale: 2,
          width: 320,
        );

        await _tapAction(tester, 'Delete chat');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'dark: $dark');
        expect(find.text('Delete “Landing page redesign”?'), findsOneWidget);
        expect(find.text('This cannot be undone.'), findsOneWidget);
        await tester.tap(find.text('Keep'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('the real sheet host fits 320 dp at 200 % text', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          builder: (context, widget) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: widget!,
          ),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showSessionActionsSheet(
                    context,
                    data: _data,
                    handlers: _handlers(rename: (_) async {}),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await _tapAction(tester, 'Rename chat');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey<String>('session-rename-field')),
        findsOneWidget,
      );
    });
  });
}

Future<void> _noopPin(bool _) async {}

Future<void> _noopRename(String _) async {}

Future<void> _noopVoid() async {}
