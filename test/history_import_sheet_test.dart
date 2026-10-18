// P8 Task 20 — consent/progress sheet + login-gate hook tests.
//
// The sheet takes an optional `HistoryImportService`, so these tests subclass
// the concrete service and override only `plan()`/`run()`. No production seam
// was added to `history_import.dart`; the fake never touches the network.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/account_service.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/history_import.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/session_history_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/history_import_sheet.dart';
import 'package:ovid_ai/ui/login_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeHistoryImportService extends HistoryImportService {
  _FakeHistoryImportService({
    required super.prefs,
    this.planResult = const HistoryImportPlan(
      sessions: 0,
      messages: 0,
      alreadyImported: false,
    ),
    this.runResults = const <HistoryImportResult>[],
    this.planError,
    this.firstRunGate,
    this.progressEvents = const <(String, double)>[],
    String account = 'firebase:u1',
  }) : super(
          rest: CloudRestClient(
            headers: CloudHeaders.forTest(),
            restBase: 'http://test.invalid',
          ),
          history: SessionHistoryRepository.forTest(),
          account: account,
        );

  final HistoryImportPlan planResult;
  final List<HistoryImportResult> runResults;
  final Object? planError;
  final Completer<void>? firstRunGate;
  final List<(String, double)> progressEvents;

  int planCalls = 0;
  int runCalls = 0;
  bool? lastConsent;

  @override
  Future<HistoryImportPlan> plan() async {
    planCalls++;
    final error = planError;
    if (error != null) throw error;
    return planResult;
  }

  @override
  Future<HistoryImportResult> run(
    void Function(String stage, double progress) onProgress, {
    required bool consent,
  }) async {
    runCalls++;
    lastConsent = consent;
    for (final (stage, progress) in progressEvents) {
      onProgress(stage, progress);
    }
    if (runCalls == 1 && firstRunGate != null) {
      await firstRunGate!.future;
    }
    if (runResults.isEmpty) {
      return const HistoryImportResult(
        imported: 0,
        skipped: 0,
        failedSessionKeys: <String>[],
      );
    }
    final index = (runCalls - 1).clamp(0, runResults.length - 1);
    return runResults[index];
  }
}

class _GateService extends ChangeNotifier implements FirebaseService {
  @override
  bool get firstUserKnown => false;

  final initialization = Completer<void>();

  @override
  bool isAvailable = false;

  @override
  bool isSignedIn = false;

  @override
  bool accountReady = false;

  @override
  String? accountError;

  @override
  final authProviders = AuthProviders();

  @override
  AccountDeletion? lastDeletionReceipt;

  @override
  bool accountTransitionFailed = false;

  @override
  Future<void> recheckAccountState({bool force = false}) async {}

  @override
  Future<void> initialize() => initialization.future;

  @override
  Future<void> retryAccountLogin() async {
    accountError = null;
    accountReady = true;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('$invocation');
}

/// Opens the sheet through a host route so Skip/Done can pop it.
Future<void> _openSheet(
  WidgetTester tester, {
  required _FakeHistoryImportService service,
  required SharedPreferences prefs,
  String account = 'firebase:u1',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showHistoryImportSheet(
                context,
                service: service,
                account: account,
                prefs: prefs,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<SharedPreferences> _prefs([Map<String, Object> values = const {}]) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

void main() {
  tearDown(AppState.resetTestInstance);

  testWidgets('shows real plan counts, both choices, and the upload scope', (
    tester,
  ) async {
    final prefs = await _prefs();
    final service = _FakeHistoryImportService(
      prefs: prefs,
      planResult: const HistoryImportPlan(
        sessions: 3,
        messages: 7,
        alreadyImported: false,
      ),
    );

    await _openSheet(tester, service: service, prefs: prefs);

    expect(find.text('3 chats · 7 messages'), findsOneWidget);
    expect(find.text('Import my chats'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
    expect(
      find.textContaining('Chat transcripts: messages, roles, and timestamps.'),
      findsOneWidget,
    );
    expect(find.textContaining('Ovid Cloud, for this account only.'), findsOneWidget);
    expect(
      find.textContaining('Session event ledgers and memory files'),
      findsOneWidget,
    );
    expect(find.textContaining('no server endpoint'), findsOneWidget);
    expect(service.planCalls, 1);
    expect(service.runCalls, 0, reason: 'consent is not implied');
  });

  testWidgets('Skip writes the per-account marker and never runs the import', (
    tester,
  ) async {
    final prefs = await _prefs();
    final service = _FakeHistoryImportService(
      prefs: prefs,
      planResult: const HistoryImportPlan(
        sessions: 2,
        messages: 4,
        alreadyImported: false,
      ),
    );

    await _openSheet(tester, service: service, prefs: prefs);
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();

    expect(prefs.getBool('ovid_cloud_import_skipped_u1'), isTrue);
    expect(
      prefs.getBool('ovid_cloud_import_done_u1'),
      isNull,
      reason: 'the service owns the done marker',
    );
    expect(service.runCalls, 0, reason: 'skip must make no upload call');
    expect(service.lastConsent, isNull);
    expect(find.text('Import my chats'), findsNothing);
  });

  testWidgets('Import passes consent and shows live progress text', (
    tester,
  ) async {
    final prefs = await _prefs();
    final gate = Completer<void>();
    final service = _FakeHistoryImportService(
      prefs: prefs,
      planResult: const HistoryImportPlan(
        sessions: 2,
        messages: 4,
        alreadyImported: false,
      ),
      firstRunGate: gate,
      progressEvents: const <(String, double)>[
        ('transcripts', 0.1),
        ('session s1 chunk 1/1', 0.5),
        ('ledger', 0.9),
      ],
      runResults: const <HistoryImportResult>[
        HistoryImportResult(
          imported: 3,
          skipped: 2,
          failedSessionKeys: <String>['s1'],
        ),
      ],
    );

    await _openSheet(tester, service: service, prefs: prefs);
    await tester.tap(find.text('Import my chats'));
    await tester.pump();

    expect(service.runCalls, 1);
    expect(service.lastConsent, isTrue);
    expect(find.text('ledger'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 0.9);
    expect(find.text('Import my chats'), findsNothing,
        reason: 'choices are unavailable while the import runs');

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('Imported 3 messages'), findsOneWidget);
    expect(find.text('Skipped 2 items'), findsOneWidget);
    expect(find.textContaining('could not be uploaded'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('Try again resumes and a clean run reports completion', (
    tester,
  ) async {
    final prefs = await _prefs();
    final service = _FakeHistoryImportService(
      prefs: prefs,
      planResult: const HistoryImportPlan(
        sessions: 1,
        messages: 2,
        alreadyImported: false,
      ),
      runResults: const <HistoryImportResult>[
        HistoryImportResult(
          imported: 1,
          skipped: 0,
          failedSessionKeys: <String>['s1'],
        ),
        HistoryImportResult(
          imported: 2,
          skipped: 1,
          failedSessionKeys: <String>[],
        ),
      ],
    );

    await _openSheet(tester, service: service, prefs: prefs);
    await tester.tap(find.text('Import my chats'));
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(service.runCalls, 2);
    expect(service.lastConsent, isTrue);
    expect(find.text('Import complete'), findsOneWidget);
    expect(find.text('Imported 2 messages'), findsOneWidget);
    expect(find.text('Skipped 1 item'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('sheet copy never contains token- or key-like strings', (
    tester,
  ) async {
    final prefs = await _prefs();
    final service = _FakeHistoryImportService(
      prefs: prefs,
      planResult: const HistoryImportPlan(
        sessions: 1,
        messages: 2,
        alreadyImported: false,
      ),
    );

    await _openSheet(tester, service: service, prefs: prefs);

    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(text, isNot(contains('Bearer')));
    expect(text, isNot(contains('sk-')));
    expect(text, isNot(contains('eyJ')));
    expect(RegExp(r'[0-9a-fA-F]{32,}').hasMatch(text), isFalse);
    expect(
      RegExp(
        r'(api[_-]?key|secret|access[_-]?token)',
        caseSensitive: false,
      ).hasMatch(text),
      isFalse,
    );
  });

  group('login gate hook', () {
    Future<void> pumpGate(
      WidgetTester tester, {
      required _FakeHistoryImportService service,
      String account = 'firebase:u1',
    }) async {
      AppState.createForTest(sessionAccountIdForTest: account);
      final gateService = _GateService()
        ..isAvailable = true
        ..isSignedIn = true
        ..accountReady = true;
      gateService.initialization.complete();
      await tester.pumpWidget(
        MaterialApp(
          home: LoginGate(
            service: gateService,
            bindCloud: () async {},
            historyImportService: service,
            historyImportAccount: account,
            child: const Text('Protected app'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      addTearDown(gateService.dispose);
    }

    testWidgets('does not show when the done marker is set', (tester) async {
      final prefs = await _prefs(<String, Object>{
        'ovid_welcomed': true,
        'ovid_cloud_import_done_u1': true,
      });
      final service = _FakeHistoryImportService(
        prefs: prefs,
        planResult: const HistoryImportPlan(
          sessions: 1,
          messages: 2,
          alreadyImported: false,
        ),
      );

      await pumpGate(tester, service: service);

      expect(find.text('Protected app'), findsOneWidget);
      expect(find.text('Import my chats'), findsNothing);
      expect(service.planCalls, 0, reason: 'markers short-circuit the plan');
    });

    testWidgets('does not show when the skip marker is set', (tester) async {
      final prefs = await _prefs(<String, Object>{
        'ovid_welcomed': true,
        'ovid_cloud_import_skipped_u1': true,
      });
      final service = _FakeHistoryImportService(
        prefs: prefs,
        planResult: const HistoryImportPlan(
          sessions: 1,
          messages: 2,
          alreadyImported: false,
        ),
      );

      await pumpGate(tester, service: service);

      expect(find.text('Protected app'), findsOneWidget);
      expect(find.text('Import my chats'), findsNothing);
      expect(service.planCalls, 0, reason: 'markers short-circuit the plan');
    });

    testWidgets('shows once when neither marker is set', (tester) async {
      final prefs = await _prefs(<String, Object>{'ovid_welcomed': true});
      final service = _FakeHistoryImportService(
        prefs: prefs,
        planResult: const HistoryImportPlan(
          sessions: 2,
          messages: 5,
          alreadyImported: false,
        ),
      );

      await pumpGate(tester, service: service);

      expect(find.text('Protected app'), findsOneWidget);
      expect(find.text('Import my chats'), findsOneWidget);
      expect(find.text('2 chats · 5 messages'), findsOneWidget);
      expect(service.planCalls, greaterThanOrEqualTo(1));
    });

    testWidgets('never asks for a guest account', (tester) async {
      final prefs = await _prefs(<String, Object>{'ovid_welcomed': true});
      final service = _FakeHistoryImportService(
        prefs: prefs,
        planResult: const HistoryImportPlan(
          sessions: 1,
          messages: 2,
          alreadyImported: false,
        ),
      );

      await pumpGate(tester, service: service, account: 'guest');

      expect(find.text('Protected app'), findsOneWidget);
      expect(find.text('Import my chats'), findsNothing);
      expect(service.planCalls, 0);
    });

    testWidgets('a plan failure is logged and never blocks the app', (
      tester,
    ) async {
      final prefs = await _prefs(<String, Object>{'ovid_welcomed': true});
      final service = _FakeHistoryImportService(
        prefs: prefs,
        planError: StateError('local store unavailable'),
      );

      await pumpGate(tester, service: service);

      expect(find.text('Protected app'), findsOneWidget);
      expect(find.text('Import my chats'), findsNothing);
      expect(service.planCalls, 1);
    });
  });
}
