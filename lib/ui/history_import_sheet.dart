// P8 Task 20 — one-time history-import consent, progress and result sheet.
//
// This file is deliberately the only place that owns the user-facing side of
// the import contract:
//
//   * Nothing leaves the device before the user taps "Import my chats".
//     `HistoryImportService.plan()` is read-only, and the default service is
//     constructed here without touching the network.
//   * Both choices are first-class buttons. "Skip for now" writes the
//     per-account skip marker (`ovid_cloud_import_skipped_<uid>`), so the login
//     gate asks once per account instead of on every launch. The service owns
//     the `done` marker and only writes it after a run with no failed
//     sessions; this sheet never writes that marker itself.
//   * While a run is in flight the sheet cannot be dismissed casually (no
//     drag, no barrier tap, no system back) — but a deliberate Cancel is
//     always offered. Dismissal is safe because the service persists
//     per-chunk progress after every acknowledged chunk; a cancelled or
//     interrupted run stays resumable.
//   * A partial result keeps the sheet open with a plain-language line and a
//     "Try again" action. Re-running is safe: the service resumes at the last
//     acknowledged chunk and its deterministic `clientMsgId`s make duplicate
//     messages impossible.

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/cloud/cloud_rest.dart';
import '../core/cloud/history_import.dart';
import '../core/diag.dart';
import '../core/session_history_store.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// The account form used in the import markers: `firebase:<uid>` becomes
/// `<uid>`, matching `HistoryImportService`'s own `done`/`progress` keys.
String historyImportMarkerAccount(String account) =>
    account.startsWith('firebase:')
        ? account.substring('firebase:'.length)
        : account;

/// `ovid_cloud_import_done_<uid>` — written by the service, read by the gate.
String historyImportDoneMarkerKey(String account) =>
    'ovid_cloud_import_done_${historyImportMarkerAccount(account)}';

/// `ovid_cloud_import_skipped_<uid>` — written by this sheet when the user
/// chooses "Skip for now".
String historyImportSkippedMarkerKey(String account) =>
    'ovid_cloud_import_skipped_${historyImportMarkerAccount(account)}';

/// Shows the consent/progress sheet as a non-dismissible modal bottom sheet.
///
/// [service] is a test seam (the production path builds the real service from
/// the process singletons); [account] and [prefs] are seams so tests never
/// touch Firebase or path_provider.
Future<void> showHistoryImportSheet(
  BuildContext context, {
  HistoryImportService? service,
  String? account,
  SharedPreferences? prefs,
}) {
  return showAetherSheet<void>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => HistoryImportSheet(
      service: service,
      account: account,
      prefs: prefs,
    ),
  );
}

/// One account's consent, progress and result for the local-history import.
class HistoryImportSheet extends StatefulWidget {
  const HistoryImportSheet({
    super.key,
    this.service,
    this.account,
    this.prefs,
  });

  /// Test seam. When null the sheet builds a [HistoryImportService] over the
  /// process REST client and history repository.
  final HistoryImportService? service;

  /// Account whose markers and transcripts are used. Defaults to
  /// [AppState.sessionAccountId] (`firebase:<uid>` / `guest`).
  final String? account;

  /// Test seam for the skip marker. Defaults to [SharedPreferences.getInstance].
  final SharedPreferences? prefs;

  @override
  State<HistoryImportSheet> createState() => _HistoryImportSheetState();
}

enum _Phase { loading, consent, running, result, error }

class _HistoryImportSheetState extends State<HistoryImportSheet> {
  _Phase _phase = _Phase.loading;
  HistoryImportPlan? _plan;
  HistoryImportResult? _result;
  HistoryImportService? _service;
  SharedPreferences? _prefs;
  String? _account;
  String _stage = 'Preparing…';
  double _progress = 0;
  String? _error;
  bool _cancelled = false;

  bool get _running => _phase == _Phase.running;

  @override
  void initState() {
    super.initState();
    _loadPlan();
  }

  Future<void> _loadPlan() async {
    try {
      final prefs = widget.prefs ?? await SharedPreferences.getInstance();
      final account = widget.account ?? AppState.I.sessionAccountId;
      final service = widget.service ??
          HistoryImportService(
            rest: CloudRestClient.I,
            history: SessionHistoryRepository.I,
            prefs: prefs,
            account: account,
          );
      // `plan()` is read-only: it reads local rows and the completion marker
      // and never opens a connection.
      final plan = await service.plan();
      if (!mounted) return;
      setState(() {
        _prefs = prefs;
        _account = account;
        _service = service;
        _plan = plan;
        _phase = _Phase.consent;
      });
    } catch (e, st) {
      Diag.swallow('history_import.plan', e, st);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = 'The import could not be prepared. You can skip it for now '
            'and continue using Ovid.';
      });
    }
  }

  Future<void> _skip() async {
    final prefs = widget.prefs ?? _prefs;
    final account = widget.account ?? _account;
    try {
      final resolved = prefs ?? await SharedPreferences.getInstance();
      if (account != null && account.isNotEmpty) {
        await resolved.setBool(historyImportSkippedMarkerKey(account), true);
      }
    } catch (e, st) {
      // A failed marker must not trap the user in the sheet; it only means
      // the question may be asked again on a later launch.
      Diag.swallow('history_import.skip_marker', e, st);
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _import() async {
    final service = _service;
    if (service == null || _running) return;
    setState(() {
      _phase = _Phase.running;
      _stage = 'Preparing…';
      _progress = 0;
      _error = null;
    });
    try {
      final result = await service.run(
        (stage, progress) {
          if (!mounted) return;
          setState(() {
            _stage = stage;
            _progress = progress.clamp(0.0, 1.0).toDouble();
          });
        },
        // Explicit consent, enforced again by the service before it reads or
        // sends anything.
        consent: true,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _phase = _Phase.result;
      });
    } catch (e, st) {
      Diag.swallow('history_import.run', e, st);
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = 'The import stopped before it finished. Nothing was lost — '
            'your local chats are still here. Try again, or skip for now.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // A running import must not be dismissed casually: it is resumable, but
      // leaving mid-flight without a deliberate choice would hide its state.
      // After a Cancel tap the sheet has made that deliberate choice, so the
      // system back is allowed again (the button pops directly).
      canPop: !_running || _cancelled,
      child: AetherSheet(
        title: 'Import your chats',
        pinActions: true,
        actions: _actions(),
        child: SingleChildScrollView(
          child: switch (_phase) {
            _Phase.loading => _loadingBody(),
            _Phase.consent => _consentBody(_plan!),
            _Phase.running => _progressBody(),
            _Phase.result => _resultBody(_result!),
            _Phase.error => _errorBody(),
          },
        ),
      ),
    );
  }

  List<Widget> _actions() => switch (_phase) {
    _Phase.consent => [
      AetherSecondaryButton(
        label: 'Skip for now',
        onPressed: _skip,
      ),
      AetherPrimaryButton(
        label: 'Import my chats',
        onPressed: _import,
      ),
    ],
    _Phase.running => [
      // Escape hatch: without it a hung upload would trap the user in the
      // sheet forever (isDismissible:false, drag off, no other button).
      AetherSecondaryButton(label: 'Cancel', onPressed: _cancel),
    ],
    _Phase.result => [
      if ((_result?.failedSessionKeys ?? const <String>[]).isEmpty)
        AetherPrimaryButton(label: 'Done', onPressed: _close)
      else ...[
        AetherSecondaryButton(label: 'Done', onPressed: _close),
        AetherPrimaryButton(label: 'Try again', onPressed: _import),
      ],
    ],
    _Phase.error => [
      AetherSecondaryButton(label: 'Skip for now', onPressed: _skip),
      AetherPrimaryButton(label: 'Try again', onPressed: _retryPlan),
    ],
    _ => const <Widget>[],
  };

  void _close() => Navigator.of(context).pop();

  /// Deliberate exit from a running import. Safe by contract: the service
  /// persists per-chunk progress (`ovid_cloud_import_progress_<uid>`) after
  /// every acknowledged chunk and its `clientMsgId`s are deterministic, so a
  /// later run resumes at the last acknowledged chunk and can never
  /// duplicate a message. The in-flight run is allowed to finish in the
  /// background — its progress callbacks are mounted-guarded — so whatever
  /// still lands is durable too.
  void _cancel() {
    setState(() => _cancelled = true);
    Navigator.of(context).pop();
  }

  Future<void> _retryPlan() async {
    setState(() {
      _phase = _Phase.loading;
      _error = null;
    });
    await _loadPlan();
  }

  Widget _loadingBody() => Padding(
    padding: const EdgeInsets.symmetric(vertical: AetherSpacing.space6),
    child: Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          semanticsLabel: 'Preparing the import',
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation<Color>(Aether.accent),
        ),
      ),
    ),
  );

  Widget _consentBody(HistoryImportPlan plan) {
    final countText =
        '${_plural(plan.sessions, 'chat', 'chats')} · '
        '${_plural(plan.messages, 'message', 'messages')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Ovid can copy the chats saved on this device into Ovid Cloud. '
          'Nothing is uploaded until you choose to import.',
          style: AetherType.bodyMuted,
        ),
        const SizedBox(height: AetherSpacing.space4),
        const _ImportFact(
          label: 'Uploaded',
          value: 'Chat transcripts: messages, roles, and timestamps.',
        ),
        const SizedBox(height: AetherSpacing.space3),
        const _ImportFact(
          label: 'Stored in',
          value: 'Ovid Cloud, for this account only.',
        ),
        const SizedBox(height: AetherSpacing.space3),
        const _ImportFact(
          label: 'Not uploaded',
          value: 'Session event ledgers and memory files — there is no server '
              'endpoint for them yet.',
        ),
        const SizedBox(height: AetherSpacing.space4),
        Container(
          padding: const EdgeInsets.all(AetherSpacing.space4),
          decoration: BoxDecoration(
            color: context.aether.surfaceAlt,
            borderRadius: BorderRadius.circular(AetherRadius.rMd),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ready to import', style: AetherType.label),
              const SizedBox(height: AetherSpacing.space1),
              Text(countText, style: AetherType.title),
            ],
          ),
        ),
      ],
    );
  }

  Widget _progressBody() {
    final percent = (_progress * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Importing your chats…', style: AetherType.title),
        const SizedBox(height: AetherSpacing.space3),
        LinearProgressIndicator(value: _progress),
        const SizedBox(height: AetherSpacing.space2),
        Semantics(
          liveRegion: true,
          child: Text(
            _stage,
            key: const ValueKey('history-import-stage'),
            style: AetherType.bodyMuted,
          ),
        ),
        const SizedBox(height: AetherSpacing.space1),
        Text('$percent%', style: AetherType.caption),
        const SizedBox(height: AetherSpacing.space4),
        Text(
          'Keep this open while the import runs. If it stops, it resumes from '
          'where it left off.',
          style: AetherType.bodyMuted,
        ),
      ],
    );
  }

  Widget _resultBody(HistoryImportResult result) {
    final failed = result.failedSessionKeys.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          failed ? 'Import paused' : 'Import complete',
          style: AetherType.h1,
        ),
        const SizedBox(height: AetherSpacing.space3),
        Text(
          'Imported ${_plural(result.imported, 'message', 'messages')}',
          style: AetherType.title,
        ),
        const SizedBox(height: AetherSpacing.space1),
        Text(
          'Skipped ${_plural(result.skipped, 'item', 'items')}',
          style: AetherType.bodyMuted,
        ),
        if (result.skipped > 0) ...[
          const SizedBox(height: AetherSpacing.space3),
          Text(
            'Skipped items include messages the server already had, and stores '
            'with no server endpoint (session event ledgers and memory files).',
            style: AetherType.bodyMuted,
          ),
        ],
        if (failed) ...[
          const SizedBox(height: AetherSpacing.space4),
          Semantics(
            liveRegion: true,
            child: Text(
              'Some chats could not be uploaded. You can try again — the '
              'import resumes where it stopped.',
              style: AetherType.body.copyWith(color: Aether.warn),
            ),
          ),
        ],
      ],
    );
  }

  Widget _errorBody() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Import unavailable', style: AetherType.h1),
      const SizedBox(height: AetherSpacing.space3),
      Semantics(
        liveRegion: true,
        child: Text(
          _error ?? 'The import could not start.',
          style: AetherType.bodyMuted,
        ),
      ),
    ],
  );

  static String _plural(int count, String one, String many) =>
      '$count ${count == 1 ? one : many}';
}

class _ImportFact extends StatelessWidget {
  const _ImportFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: AetherType.label),
      const SizedBox(height: 2),
      Text(value, style: AetherType.body),
    ],
  );
}
