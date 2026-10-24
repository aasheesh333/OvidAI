// The Data control screen's server-backed destructive action
//   POST /cloud/v1/data/delete-all
// (the memory reset keeps the Settings hub's existing "Reset memory" row and
// its own client test):
//
// These tests pin the promises the screen makes:
//   * a destructive warning and a typed email come BEFORE anything is sent;
//   * nothing is claimed until the server's answer arrives (the counts are
//     the server's, never a local guess);
//   * one refusal renders one plain sentence, and a raw exception never
//     reaches the screen;
//   * the screen keeps its four states (loading / empty / error / content)
//     and the settled row layout.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/data_control_client.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings/data_control_export.dart';
import 'package:ovid_ai/ui/v2/settings/data_control_page.dart';
import 'package:ovid_ai/ui/v2/settings/server_data_control.dart';

Widget _app(Widget home) => MaterialApp(theme: OTheme.light(), home: home);

void _usePhone(WidgetTester tester, {double width = 420, double height = 900}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The page only needs a service to decide which platform rows exist; the
/// destructive rows here are backed by the injected server callbacks.
class _UnavailableService implements V2DataControlService {
  const _UnavailableService();

  @override
  bool get available => false;

  @override
  Future<V2ExportOutcome> exportBackup({
    Set<String>? sessionIds,
    void Function(V2TransferProgress progress)? onProgress,
  }) async => const V2ExportOutcome.failed('unavailable');

  @override
  Future<V2ImportPreview?> pickImport() async => null;

  @override
  Future<V2ImportOutcome> importBackup(
    V2ImportPreview preview, {
    void Function(V2TransferProgress progress)? onProgress,
  }) async => const V2ImportOutcome.failed('unavailable');

  @override
  Future<int> cacheBytes() async => 0;

  @override
  Future<int> clearCache() async => 0;

  @override
  Future<V2DeleteOutcome> deleteDeviceData() async =>
      const V2DeleteOutcome.failed('unavailable');
}

/// A device service that records a reset, so a test can prove the server
/// delete never reaches it.
class _TrackingService extends _UnavailableService {
  int deviceDeletes = 0;

  @override
  bool get available => true;

  @override
  Future<V2DeleteOutcome> deleteDeviceData() async {
    deviceDeletes++;
    return const V2DeleteOutcome(completed: 0, failures: {}, verified: true);
  }
}

V2DataControlPageData _data({
  String accountContact = 'me@example.com',
  bool hasData = true,
  bool loading = false,
  String? errorMessage,
  VoidCallback? onRetry,
  V2DataControlService? service,
  Future<DataDeletionCounts> Function(String confirmation)? onServerDeleteAll,
}) {
  return V2DataControlPageData(
    service: service ?? const _UnavailableService(),
    hasData: hasData,
    loading: loading,
    errorMessage: errorMessage,
    onRetry: onRetry,
    accountContact: accountContact,
    onServerDeleteAll: onServerDeleteAll,
  );
}

Future<void> _confirmWithEmail(WidgetTester tester, String email) async {
  await tester.enterText(
    find.byKey(const ValueKey('confirm-typed-field')),
    email,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(
    find.byKey(const ValueKey('confirm-typed-button')),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('confirm-typed-button')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('delete warns, then sends only the typed email, then reports '
      'what the server counted', (tester) async {
    _usePhone(tester);
    final sent = <String>[];
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            onServerDeleteAll: (confirmation) async {
              sent.add(confirmation);
              return const DataDeletionCounts(
                sessions: 3,
                attachments: 2,
                artifacts: 1,
                workspaceFiles: 4,
                storageObjects: 5,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The row names the cloud scope it now has, and is marked destructive.
    expect(find.text('Delete data'), findsOneWidget);
    expect(find.text('Account'), findsOneWidget);
    expect(find.text('This device'), findsNothing);

    await tester.tap(find.text('Delete data'));
    await tester.pumpAndSettle();

    // The warning comes first and names what goes.
    expect(find.text('Delete all data?'), findsOneWidget);
    expect(find.text('Cannot be undone'), findsOneWidget);
    expect(find.text('Removed from your account'), findsOneWidget);
    expect(find.text('Every chat and message'), findsOneWidget);
    expect(find.text('Chat memory'), findsOneWidget);
    expect(sent, isEmpty, reason: 'nothing is sent before the typed email');

    final button = tester.widget<OButton>(
      find.byKey(const ValueKey('confirm-typed-button')),
    );
    expect(button.onPressed, isNull, reason: 'the typed email unlocks it');

    await _confirmWithEmail(tester, 'me@example.com');

    expect(sent, <String>['me@example.com']);
    expect(find.text('Deleted'), findsOneWidget);
    // The counts are the server's: 3 chats, 2+1+4 files.
    expect(find.text('3 chats · 7 files'), findsOneWidget);
  });

  testWidgets('the server delete never runs the device reset', (tester) async {
    _usePhone(tester);
    final device = _TrackingService();
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            service: device,
            onServerDeleteAll: (_) async =>
                const DataDeletionCounts(sessions: 1),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The device's own copy keeps its separate, clearly-labelled row.
    expect(find.text('Clear cache'), findsOneWidget);

    await tester.tap(find.text('Delete data'));
    await tester.pumpAndSettle();
    await _confirmWithEmail(tester, 'me@example.com');

    expect(find.text('Deleted'), findsOneWidget);
    expect(
      device.deviceDeletes,
      0,
      reason: 'deleting cloud data must not silently wipe this device',
    );
  });

  testWidgets('delete claims nothing while the server has not answered', (
    tester,
  ) async {
    _usePhone(tester);
    final gate = Completer<DataDeletionCounts>();
    await tester.pumpWidget(
      _app(DataControlPage(data: _data(onServerDeleteAll: (_) => gate.future))),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete data'));
    await tester.pumpAndSettle();
    await _confirmWithEmail(tester, 'me@example.com');

    expect(find.byKey(const ValueKey('data-control-progress')), findsOneWidget);
    expect(find.text('Deleted'), findsNothing);
    expect(find.textContaining('chats'), findsNothing);

    gate.complete(const DataDeletionCounts(sessions: 1));
    await tester.pumpAndSettle();

    expect(find.text('Deleted'), findsOneWidget);
    expect(find.text('1 chat · 0 files'), findsOneWidget);
  });

  testWidgets('a refused delete shows one plain sentence and offers a retry', (
    tester,
  ) async {
    _usePhone(tester);
    var attempts = 0;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            onServerDeleteAll: (_) async {
              attempts++;
              throw const DataControlFailure(
                status: 503,
                code: 'storage_delete_failed',
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete data'));
    await tester.pumpAndSettle();
    await _confirmWithEmail(tester, 'me@example.com');

    expect(find.text('Delete failed'), findsOneWidget);
    expect(
      find.text(
        'Your chats were not deleted. Stored-file removal may be '
        'incomplete; try again to finish.',
      ),
      findsOneWidget,
    );
    expect(find.text('Deleted'), findsNothing);
    expect(find.textContaining('storage_delete_failed'), findsNothing);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Delete all data?'), findsOneWidget);
    expect(attempts, 1, reason: 'the retry confirms again before sending');
  });

  testWidgets('a raw throw never reaches the screen', (tester) async {
    _usePhone(tester);
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            onServerDeleteAll: (_) async =>
                throw StateError('boom: provider stack trace'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete data'));
    await tester.pumpAndSettle();
    await _confirmWithEmail(tester, 'me@example.com');

    expect(find.text('Delete failed'), findsOneWidget);
    expect(
      find.text(
        'Ovid could not confirm the result. Check your data before trying again.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('boom'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
  });

  testWidgets('no registered email means no confirmation to offer', (
    tester,
  ) async {
    _usePhone(tester);
    var calls = 0;
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            accountContact: '',
            onServerDeleteAll: (_) async {
              calls++;
              return const DataDeletionCounts();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete data'));
    await tester.pumpAndSettle();

    // Phone is not a confirmation target: the server cannot check one, so the
    // screen says the action is unavailable instead of offering DELETE.
    expect(
      find.text('This action needs an email address on your account.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('confirm-typed-field')), findsNothing);
    expect(find.text('DELETE'), findsNothing);
    expect(calls, 0);
  });

  testWidgets('a second delete that finds nothing says so, not "deleted"', (
    tester,
  ) async {
    _usePhone(tester);
    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            onServerDeleteAll: (_) async => const DataDeletionCounts(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete data'));
    await tester.pumpAndSettle();
    await _confirmWithEmail(tester, 'me@example.com');

    expect(find.text('Nothing'), findsOneWidget);
    expect(find.text('Deleted'), findsNothing);
  });

  // The reset action keeps the hub's existing "Reset memory" row; its
  // confirmation copy is pinned here so it can never fall back to a phone or
  // the sheet's DELETE word, which the gateway cannot verify.
  test('the reset confirmation asks for the email and offers no phone', () {
    final data = serverResetConfirmation('me@example.com');
    expect(data.contact, 'me@example.com');
    expect(data.hasContact, isTrue);
    expect(data.isEmailContact, isTrue);
    expect(data.confirmationTarget, 'me@example.com');
    expect(data.confirmLabel, 'Reset memory');
    expect(data.removals, contains('Global memory'));
  });

  testWidgets('the four states still hold with the server rows present', (
    tester,
  ) async {
    Future<DataDeletionCounts> never(String _) async =>
        const DataDeletionCounts();

    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(loading: true, onServerDeleteAll: never)),
      ),
    );
    await tester.pump();
    expect(find.byType(OSkeletonList), findsOneWidget);

    await tester.pumpWidget(
      _app(
        DataControlPage(
          data: _data(
            errorMessage: 'Could not load your data.',
            onServerDeleteAll: never,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not load your data.'), findsOneWidget);

    await tester.pumpWidget(
      _app(
        DataControlPage(data: _data(hasData: false, onServerDeleteAll: never)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No data yet'), findsOneWidget);

    await tester.pumpWidget(
      _app(DataControlPage(data: _data(onServerDeleteAll: never))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('delete-data-row')), findsOneWidget);
    // The settled layout has no extra reset row: that action keeps its own
    // hub row, so the data-control list is unchanged.
    expect(find.byKey(const ValueKey('reset-memory-row')), findsNothing);
  });
}
