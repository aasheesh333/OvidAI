import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/cloud/data_control_client.dart';
import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'confirm_typed_sheet.dart';
import 'data_control_export.dart'
    if (dart.library.io) 'data_control_export_io.dart';
import 'export_picker_sheet.dart';
import 'server_data_control.dart';
import 'settings_rows.dart';
import 'storage_breakdown.dart' show formatStorageBytes;

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

/// One chat in the export selection window, measured from this device.
@immutable
class V2ExportSession {
  const V2ExportSession({
    required this.id,
    required this.name,
    required this.sizeBytes,
    required this.sizeLabel,
    this.detail = '',
    this.selected = true,
    this.heavyArtifacts = false,
  });

  /// The server session id the archive will carry.
  final String id;
  final String name;
  final int sizeBytes;
  final String sizeLabel;

  /// A measured line such as "42 messages".
  final String detail;

  final bool selected;

  /// True when the chat contains videos or other large files that are not
  /// part of a transcript archive and must be re-uploaded after an import.
  final bool heavyArtifacts;
}

/// Called with the chat id and its new selected state.
typedef V2ExportSessionToggle = void Function(String id, bool selected);

/// `POST /data/delete-all`. Returns only what the server confirmed.
typedef V2ServerDeleteAll =
    Future<DataDeletionCounts> Function(String confirmation);

/// `POST /memory/reset`. Returns the file count the server reported.
typedef V2ServerResetMemory = Future<int> Function(String confirmation);

/// Injected state for the Data control screen.
///
/// The export, import, cache and delete rows are backed by [service] (real on
/// device, unavailable on web). The callbacks below are the host's hooks: the
/// async ones take over a flow when supplied; the older `VoidCallback`s are
/// only used on a platform with no service (web) and are kept so existing hosts
/// still compile.
@immutable
class V2DataControlPageData {
  const V2DataControlPageData({
    this.totalDataSizeLabel = '',
    this.exportLimitBytes = 64 * 1024 * 1024,
    this.exportSessions = const <V2ExportSession>[],
    this.hasData = true,
    this.loading = false,
    this.errorMessage,
    this.accountContact = '',
    this.service,
    this.onExport,
    this.onChooseImport,
    this.onDeleteData,
    this.onExportSessionToggled,
    this.onRetry,
    this.onClearCache,
    this.onClearCacheAndReport,

    // The server-backed delete. When [onServerDeleteAll] is supplied the
    // delete row deletes the account's cloud data (the gateway's
    // `POST /data/delete-all`) instead of this device's copy. The device's
    // own copy keeps its separate, clearly-labelled "Clear cache" row.
    this.onServerDeleteAll,

    // Retained for hosts that still pass them. Permissions, storage and memory
    // have their own pages; only the crash-report consent is rendered here,
    // because its Settings row routes to this page.
    this.onExportImport,
    this.onPermissions,
    this.onStorage,
    this.onResetMemory,
    // Off unless the host passes the stored consent; a consent flag must never
    // default to yes.
    this.crashReports = false,
    this.onCrashReportsChanged,
    this.permissionSummary = '',
    this.storageUsedLabel = '',
    this.storageFraction = 0,
    this.storageFreeLabel = '',
  });

  /// A real measured total, for example "1.2 GB across 42 chats".
  final String totalDataSizeLabel;

  /// The archive cap the service and the picker enforce.
  final int exportLimitBytes;

  /// Per-chat sizes, used when the account is larger than the cap.
  final List<V2ExportSession> exportSessions;

  final bool hasData;
  final bool loading;
  final String? errorMessage;

  /// The registered email the server compares the typed confirmation against.
  ///
  /// Email only: the gateway stores no phone number, so a typed phone could
  /// never be verified. An empty value disables the server-backed actions
  /// rather than falling back to a word the server would refuse.
  final String accountContact;

  /// The real work behind the rows. Defaults to the platform service.
  final V2DataControlService? service;

  /// `POST /data/delete-all` with the typed email. Returns only what the
  /// server confirmed; a throw means nothing may be claimed.
  final V2ServerDeleteAll? onServerDeleteAll;

  /// Legacy export hook, used only where [service] is unavailable (web).
  final VoidCallback? onExport;

  /// Legacy import hook, used only where [service] is unavailable (web).
  final VoidCallback? onChooseImport;

  /// Legacy delete hook, used only where [service] is unavailable (web).
  final VoidCallback? onDeleteData;

  /// Reports the picker's ticks so the host can persist the selection.
  final V2ExportSessionToggle? onExportSessionToggled;
  final VoidCallback? onRetry;

  /// Legacy cache hooks. A measured reporter wins over the service.
  final VoidCallback? onClearCache;
  final Future<int> Function()? onClearCacheAndReport;

  // Deprecated host hooks retained so existing call sites compile.
  final VoidCallback? onExportImport;
  final VoidCallback? onPermissions;
  final VoidCallback? onStorage;
  final VoidCallback? onResetMemory;

  /// Whether anonymous crash reports and usage counts may be sent. Read from
  /// the real consent store by the host, never guessed here.
  final bool crashReports;

  /// Called with the new choice; the host persists it and applies it.
  final ValueChanged<bool>? onCrashReportsChanged;
  final String permissionSummary;
  final String storageUsedLabel;
  final double storageFraction;
  final String storageFreeLabel;

  int get exportTotalBytes =>
      exportSessions.fold<int>(0, (sum, session) => sum + session.sizeBytes);

  int get exportSelectedBytes => exportSessions
      .where((session) => session.selected)
      .fold<int>(0, (sum, session) => sum + session.sizeBytes);

  int get exportSelectedCount =>
      exportSessions.where((session) => session.selected).length;

  int get exportTotalMessages => exportSessions.fold<int>(
    0,
    (sum, session) => sum + _messageCount(session.detail),
  );

  bool get exportOverLimit =>
      exportTotalBytes > exportLimitBytes ||
      exportSessions.length > v2ExportPickerChatLimit ||
      exportTotalMessages > v2ExportPickerMessageLimit;

  bool get exportSelectionOverLimit => exportSelectedBytes > exportLimitBytes;

  bool get showExportSelection => exportSessions.isNotEmpty && exportOverLimit;

  bool get canExport =>
      !exportOverLimit ||
      (exportSelectedCount > 0 && !exportSelectionOverLimit);
}

enum _Phase { idle, exporting, importing, deleting }

/// Privacy and data controls: the crash-report consent, export, import, cache
/// and the destructive delete. Every row does real work, and every flow reports
/// what happened.
class DataControlPage extends StatefulWidget {
  const DataControlPage({super.key, required this.data});

  final V2DataControlPageData data;

  @override
  State<DataControlPage> createState() => _DataControlPageState();
}

class _DataControlPageState extends State<DataControlPage> {
  late final V2DataControlService _service =
      widget.data.service ?? createDataControlService();

  _Phase _phase = _Phase.idle;
  bool _clearing = false;
  V2TransferProgress? _progress;
  V2ExportOutcome? _exportOutcome;
  V2ImportOutcome? _importOutcome;
  V2DeleteOutcome? _deleteOutcome;
  // The server's answer, held separately from the device reset's outcome: the
  // two flows make different claims and must not share a status card.
  DataDeletionCounts? _serverDeleteCounts;
  String? _serverDeleteError;
  int? _cacheBytes;
  String? _cacheError;
  String? _cacheMessage;

  /// The consent choice shown on the switch. Seeded from the host's real value
  /// and kept in step with it; the host is still the one that persists it.
  late bool _crashReports = widget.data.crashReports;

  bool get _busy => _phase != _Phase.idle || _clearing;

  /// The switch only appears when the host can actually persist a change.
  bool get _canCrashReports => widget.data.onCrashReportsChanged != null;

  bool get _canExport => _service.available || widget.data.onExport != null;

  bool get _canImport =>
      _service.available || widget.data.onChooseImport != null;

  bool get _canDelete =>
      _service.available ||
      widget.data.onDeleteData != null ||
      widget.data.onServerDeleteAll != null;

  /// The delete row deletes the account's cloud data when the host can reach
  /// the gateway; otherwise it falls back to the device-only reset.
  bool get _serverDelete => widget.data.onServerDeleteAll != null;

  bool get _canClear =>
      _service.available ||
      widget.data.onClearCache != null ||
      widget.data.onClearCacheAndReport != null;

  @override
  void initState() {
    super.initState();
    if (_service.available) unawaited(_loadCache());
  }

  @override
  void didUpdateWidget(covariant DataControlPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Consent changed somewhere else (the first-run sheet, another device
    // flow): show the host's value, not a stale local copy.
    if (oldWidget.data.crashReports != widget.data.crashReports) {
      _crashReports = widget.data.crashReports;
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final status = data.loading
        ? OStatus.loading
        : data.errorMessage != null
        ? OStatus.error
        : data.hasData
        ? OStatus.content
        : OStatus.empty;
    final state = OStateView(
      status: status,
      errorMessage: data.errorMessage,
      onRetry: data.onRetry,
      skeletonRows: 5,
      emptyTitle: 'No data yet',
      emptyBody: 'Chats and files appear here.',
      emptyActionLabel: _canImport ? 'Import backup' : null,
      onEmptyAction: _canImport ? _import : null,
      child: _content(context),
    );
    if (!_canCrashReports) return OScreen(title: 'Data control', child: state);
    // The consent switch is a control, not measured data: it stays on screen
    // while the rows load, are empty or fail, so the Settings hub's
    // "Crash reports" row always lands on the setting it names.
    final c = OColors.of(context);
    return OScreen(
      title: 'Data control',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: OSpace.s),
            child: _crashRow(),
          ),
          Divider(
            height: 1,
            thickness: 1,
            indent: v2SettingsRowDividerIndent,
            color: c.hairline,
          ),
          Expanded(child: state),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    final blocks = <Widget>[
      if (_canExport) _Block(row: _exportRow(), status: _exportStatus(context)),
      if (_canImport) _Block(row: _importRow(), status: _importStatus(context)),
      if (_canClear) _Block(row: _cacheRow(), status: _cacheStatus(context)),
      if (_canDelete) _Block(row: _deleteRow(), status: _deleteStatus(context)),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < blocks.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: v2SettingsRowDividerIndent,
                color: c.hairline,
              ),
            blocks[i],
          ],
        ],
      ),
    );
  }

  // ── Rows ──────────────────────────────────────────────────────────────────

  /// The telemetry opt-in the hub's "Crash reports" row promises.
  ///
  /// The switch mirrors the consent store's real value and names what leaves
  /// the device, so turning it off is a decision the user can make here.
  Widget _crashRow() {
    final c = OColors.of(context);
    final value = _crashReports;
    void toggle() => _setCrashReports(!value);
    return V2SettingsRow(
      key: const ValueKey<String>('crash-reports-row'),
      icon: Icons.bug_report_outlined,
      title: 'Crash reports',
      subtitle: 'Crash logs and usage counts',
      showChevron: false,
      onTap: toggle,
      trailing: Semantics(
        label: 'Crash reports',
        value: value ? 'On' : 'Off',
        toggled: value,
        enabled: true,
        onTap: toggle,
        child: ExcludeSemantics(
          child: Switch(
            key: const ValueKey<String>('crash-reports-switch'),
            value: value,
            onChanged: _setCrashReports,
            activeThumbColor: c.onAccent,
            activeTrackColor: c.accentFill,
            inactiveThumbColor: c.textMuted,
            inactiveTrackColor: c.surfaceRaised,
            trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
            materialTapTargetSize: MaterialTapTargetSize.padded,
          ),
        ),
      ),
    );
  }

  /// Shows the choice at once, then hands it to the host. The host writes the
  /// same value to the consent store, so the two cannot disagree.
  void _setCrashReports(bool value) {
    final onChanged = widget.data.onCrashReportsChanged;
    if (onChanged == null || value == _crashReports) return;
    setState(() => _crashReports = value);
    onChanged(value);
  }

  Widget _exportRow() {
    final total = widget.data.totalDataSizeLabel;
    return V2SettingsRow(
      key: const ValueKey<String>('export-backup-row'),
      icon: Icons.save_alt_rounded,
      title: 'Export backup',
      subtitle: total.isEmpty ? null : total,
      enabled: !_busy,
      onTap: _busy ? null : _export,
    );
  }

  Widget _importRow() {
    return V2SettingsRow(
      key: const ValueKey<String>('import-backup-row'),
      icon: Icons.upload_file_rounded,
      title: 'Import backup',
      enabled: !_busy,
      onTap: _busy ? null : _import,
    );
  }

  Widget _cacheRow() {
    final value = !_service.available
        ? null
        : _cacheBytes != null
        ? formatStorageBytes(_cacheBytes!)
        : (_cacheError == null ? '…' : null);
    return V2SettingsRow(
      key: const ValueKey<String>('clear-cache-row'),
      icon: Icons.cleaning_services_outlined,
      title: 'Clear cache',
      subtitle: _cacheError,
      value: value,
      showChevron: false,
      enabled: !_busy,
      onTap: _busy ? null : _clearCache,
    );
  }

  Widget _deleteRow() {
    final row = V2SettingsRow(
      key: const ValueKey<String>('delete-data-row'),
      icon: Icons.delete_forever_outlined,
      title: 'Delete data',
      // The row's scope is what the action actually removes: the account's
      // chats and files when the gateway is reachable, this device's copy on
      // a host with no server seam.
      subtitle: _serverDelete ? 'Chats and files' : 'This device',
      danger: true,
      showChevron: false,
      enabled: !_busy,
      onTap: _busy ? null : _delete,
    );
    // The shared row announces its label and scope; the destructive warning is
    // added here so TalkBack says it before the action runs.
    return Semantics(
      container: true,
      button: true,
      enabled: !_busy,
      label: _serverDelete
          ? 'Delete data, chats and files'
          : 'Delete data, this device',
      hint: 'Destructive, cannot be undone.',
      onTap: _busy ? null : _delete,
      child: ExcludeSemantics(child: row),
    );
  }

  // ── Status under each row ─────────────────────────────────────────────────

  Widget? _exportStatus(BuildContext context) {
    if (_phase == _Phase.exporting) {
      return _ProgressCard(title: 'Exporting backup', progress: _progress);
    }
    final outcome = _exportOutcome;
    if (outcome == null) return null;
    if (outcome.cancelled) {
      return const _ResultCard(
        icon: Icons.info_outline_rounded,
        title: 'Export cancelled',
        meta: 'Nothing was saved.',
      );
    }
    if (outcome.isFailure) {
      return _ResultCard(
        icon: Icons.error_outline_rounded,
        tone: OColors.of(context).danger,
        title: 'Export failed',
        meta: outcome.message,
        action: OButton(
          label: 'Try again',
          variant: OButtonVariant.ghost,
          onPressed: _busy ? null : _export,
        ),
      );
    }
    final meta = StringBuffer(
      '${_plural(outcome.chats, 'chat', 'chats')} · '
      '${formatStorageBytes(outcome.bytes)}',
    );
    if (outcome.skippedChats > 0) {
      meta.write(' · ${outcome.skippedChats} left out');
    }
    final limit = outcome.limitHit;
    return _ResultCard(
      icon: Icons.check_circle_outline_rounded,
      tone: OColors.of(context).success,
      title: outcome.path == null ? 'Backup shared' : 'Backup saved',
      meta: meta.toString(),
      details: [
        if (limit != null)
          Padding(
            padding: const EdgeInsets.only(top: OSpace.s),
            child: Text(
              'Stopped by $limit.',
              style: OType.caption.copyWith(
                color: OColors.of(context).textMuted,
              ),
            ),
          ),
      ],
    );
  }

  Widget? _importStatus(BuildContext context) {
    if (_phase == _Phase.importing) {
      return _ProgressCard(title: 'Importing backup', progress: _progress);
    }
    final outcome = _importOutcome;
    if (outcome == null) return null;
    if (outcome.cancelled) {
      return const _ResultCard(
        icon: Icons.info_outline_rounded,
        title: 'Import cancelled',
        meta: 'Nothing was uploaded.',
      );
    }
    if (outcome.isFailure) {
      return _ResultCard(
        icon: Icons.error_outline_rounded,
        tone: OColors.of(context).danger,
        title: 'Import failed',
        meta: outcome.message,
        details: _failureDetails(context, outcome.failures),
        action: OButton(
          label: 'Choose file',
          variant: OButtonVariant.ghost,
          onPressed: _busy ? null : _import,
        ),
      );
    }
    final meta = StringBuffer(
      '${_plural(outcome.chats, 'chat', 'chats')} · '
      '${_plural(outcome.messages, 'message', 'messages')} added',
    );
    if (outcome.skippedChats > 0) {
      meta.write(' · ${outcome.skippedChats} already there');
    }
    return _ResultCard(
      icon: outcome.failures.isEmpty
          ? Icons.check_circle_outline_rounded
          : Icons.error_outline_rounded,
      tone: outcome.failures.isEmpty
          ? OColors.of(context).success
          : OColors.of(context).warn,
      title: outcome.failures.isEmpty ? 'Import complete' : 'Import stopped',
      meta: meta.toString(),
      details: _failureDetails(context, outcome.failures),
    );
  }

  Widget? _cacheStatus(BuildContext context) {
    if (_clearing) {
      return const _ProgressCard(title: 'Clearing cache', progress: null);
    }
    final message = _cacheMessage;
    if (message == null) return null;
    return _ResultCard(icon: Icons.cleaning_services_outlined, title: message);
  }

  Widget? _deleteStatus(BuildContext context) {
    if (_serverDelete) return _serverDeleteStatus(context);
    if (_phase == _Phase.deleting) {
      return _ProgressCard(title: 'Deleting device', progress: _progress);
    }
    final outcome = _deleteOutcome;
    if (outcome == null) return null;
    final c = OColors.of(context);
    if (outcome.success) {
      return _ResultCard(
        icon: Icons.check_circle_outline_rounded,
        tone: c.success,
        title: 'Device data deleted',
        meta: 'Cloud chats were kept.',
      );
    }
    final failures = [
      for (final entry in outcome.failures.entries)
        V2ImportFailure(item: _storeLabel(entry.key), reason: entry.value),
    ];
    return _ResultCard(
      icon: Icons.error_outline_rounded,
      tone: c.danger,
      title: outcome.message == null ? 'Delete incomplete' : 'Delete failed',
      meta:
          outcome.message ??
          '${outcome.completed} of ${outcome.total} items removed.',
      details: _failureDetails(context, failures),
      action: OButton(
        label: 'Try again',
        variant: OButtonVariant.ghost,
        onPressed: _busy ? null : _delete,
      ),
    );
  }

  /// The server-confirmed delete. Only a returned [DataDeletionCounts] is a
  /// success; a refusal or a dropped connection is one sentence and a retry.
  Widget? _serverDeleteStatus(BuildContext context) {
    if (_phase == _Phase.deleting) {
      return _ProgressCard(title: 'Deleting data', progress: _progress);
    }
    final c = OColors.of(context);
    final error = _serverDeleteError;
    if (error != null) {
      return _ResultCard(
        icon: Icons.error_outline_rounded,
        tone: c.danger,
        title: 'Delete failed',
        meta: error,
        action: OButton(
          label: 'Try again',
          variant: OButtonVariant.ghost,
          onPressed: _busy ? null : _delete,
        ),
      );
    }
    final counts = _serverDeleteCounts;
    if (counts == null) return null;
    if (counts.isEmpty) {
      // A second call is a success with zeroes; saying "deleted" here would
      // claim work the server did not do.
      return const _ResultCard(
        icon: Icons.info_outline_rounded,
        title: 'Nothing deleted',
        meta: 'Your account had no chats or files.',
      );
    }
    return _ResultCard(
      icon: Icons.check_circle_outline_rounded,
      tone: c.success,
      title: 'Data deleted',
      meta: serverDeleteSummary(counts),
    );
  }

  /// Per-item failures: the chat or store, then the reason it gave.
  List<Widget> _failureDetails(
    BuildContext context,
    List<V2ImportFailure> failures,
  ) {
    if (failures.isEmpty) return const <Widget>[];
    final c = OColors.of(context);
    const shown = 5;
    return [
      for (final failure in failures.take(shown))
        Padding(
          padding: const EdgeInsets.only(top: OSpace.s),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.close_rounded, size: 14, color: c.danger),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      failure.item,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      failure.reason,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      if (failures.length > shown)
        Padding(
          padding: const EdgeInsets.only(top: OSpace.xs),
          child: Text(
            '+${failures.length - shown} more',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ),
    ];
  }

  // ── Export ────────────────────────────────────────────────────────────────

  Future<void> _export() async {
    if (_busy) return;
    if (!_service.available) {
      // Web: the host's own export runs and reports its own result.
      widget.data.onExport?.call();
      return;
    }
    setState(() => _exportOutcome = null);
    final scope = await showExportScopeSheet(
      context,
      data: V2ExportScopeSheetData(
        summaryLabel: _exportSummary(),
        chatCount: widget.data.exportSessions.length,
        overLimit: widget.data.exportOverLimit,
        limitLabel: formatStorageBytes(widget.data.exportLimitBytes),
      ),
    );
    if (!mounted || scope == null || scope.cancelled) return;
    Set<String>? ids;
    if (scope.chooseChats) {
      ids = await showExportPickerSheet(
        context,
        data: _pickerData(),
        onToggleSession: widget.data.onExportSessionToggled,
        onSelectAll: _applySelection,
        onRetry: widget.data.onRetry,
      );
      if (!mounted || ids == null) return;
    }
    await _runExport(ids);
  }

  String _exportSummary() {
    final total = widget.data.totalDataSizeLabel;
    if (total.isNotEmpty) return total;
    final sessions = widget.data.exportSessions;
    if (sessions.isEmpty) return '';
    return '${_plural(sessions.length, 'chat', 'chats')} · '
        '${formatStorageBytes(widget.data.exportTotalBytes)}';
  }

  V2ExportPickerSheetData _pickerData() {
    return V2ExportPickerSheetData(
      sessions: [
        for (final session in widget.data.exportSessions)
          V2ExportPickerSession(
            id: session.id,
            name: session.name,
            sizeBytes: session.sizeBytes,
            sizeLabel: session.sizeLabel,
            messageCount: _messageCount(session.detail),
            detail: session.detail,
            selected: session.selected,
            heavyArtifacts: session.heavyArtifacts,
          ),
      ],
      limitBytes: widget.data.exportLimitBytes,
      limitChats: v2ExportPickerChatLimit,
      limitMessages: v2ExportPickerMessageLimit,
    );
  }

  /// Reports the picker's complete id set as individual toggles so the host
  /// stays the owner of its persisted selection.
  void _applySelection(List<String> ids) {
    final toggle = widget.data.onExportSessionToggled;
    if (toggle == null) return;
    final selected = ids.toSet();
    for (final session in widget.data.exportSessions) {
      final next = selected.contains(session.id);
      if (next != session.selected) toggle(session.id, next);
    }
  }

  Future<void> _runExport(Set<String>? ids) async {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.exporting;
      _progress = const V2TransferProgress(label: 'Reading your chats…');
      _exportOutcome = null;
    });
    final outcome = await _service.exportBackup(
      sessionIds: ids,
      onProgress: _onProgress,
    );
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _progress = null;
      _exportOutcome = outcome;
    });
    // The archive (or the scratch copy) changed the cache.
    unawaited(_loadCache());
  }

  void _onProgress(V2TransferProgress progress) {
    if (!mounted) return;
    setState(() => _progress = progress);
  }

  // ── Import ────────────────────────────────────────────────────────────────

  Future<void> _import() async {
    if (_busy) return;
    if (!_service.available) {
      widget.data.onChooseImport?.call();
      return;
    }
    setState(() {
      _importOutcome = null;
      _phase = _Phase.importing;
      _progress = const V2TransferProgress(label: 'Reading backup…');
    });
    V2ImportPreview? preview;
    try {
      preview = await _service.pickImport();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.idle;
        _progress = null;
        _importOutcome = V2ImportOutcome.failed(_reasonOf(error));
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _progress = null;
    });
    final ready = preview;
    if (ready == null) return; // The file picker was dismissed.

    final confirmed = await showImportPreviewSheet(
      context,
      data: V2ImportPreviewData(
        fileName: ready.fileName,
        summaryLabel:
            '${_plural(ready.chats, 'chat', 'chats')} · '
            '${_plural(ready.messages, 'message', 'messages')} · '
            '${formatStorageBytes(ready.bytes)}',
        filesIncluded: ready.filesIncluded,
        filesUnavailable: ready.filesUnavailable,
      ),
    );
    if (!mounted || !confirmed) return;

    setState(() {
      _phase = _Phase.importing;
      _progress = V2TransferProgress(
        label: 'Uploading chat 0 of ${ready.chats}…',
      );
    });
    final outcome = await _service.importBackup(ready, onProgress: _onProgress);
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _progress = null;
      _importOutcome = outcome;
    });
  }

  // ── Cache ─────────────────────────────────────────────────────────────────

  Future<void> _loadCache() async {
    if (!_service.available) return;
    try {
      final bytes = await _service.cacheBytes();
      if (!mounted) return;
      setState(() {
        _cacheBytes = bytes;
        _cacheError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _cacheError = 'Size unavailable');
    }
  }

  Future<void> _clearCache() async {
    if (_busy) return;
    final reporter = widget.data.onClearCacheAndReport;
    final legacy = widget.data.onClearCache;
    if (!_service.available && reporter == null && legacy == null) return;
    setState(() {
      _clearing = true;
      _cacheMessage = null;
    });
    int? freed;
    String? failure;
    try {
      if (reporter != null) {
        freed = await reporter();
      } else if (_service.available) {
        freed = await _service.clearCache();
      } else {
        legacy?.call();
      }
    } catch (_) {
      failure = 'Could not clear.';
    }
    if (!mounted) return;
    setState(() {
      _clearing = false;
      _cacheMessage =
          failure ??
          (freed == null
              ? 'Cache cleared.'
              : freed > 0
              ? 'Freed ${formatStorageBytes(freed)}.'
              : 'Cache was empty.');
    });
    // Re-measure: the row's number is what is left, not what it was.
    await _loadCache();
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  Future<void> _delete() async {
    if (_busy) return;
    if (_serverDelete) {
      await _deleteServerData();
      return;
    }
    final confirmed = await showConfirmTypedSheet(
      context,
      data: V2ConfirmTypedSheetData(
        contact: widget.data.accountContact,
        title: 'Delete device data?',
        irreversibleLabel: 'Cannot be undone',
        removalsTitle: 'Removed from device',
        removals: const <String>[
          'Chats and messages',
          'Drafts and files',
          'Cache and downloads',
          'Saved keys and sign-in',
        ],
        // No Play billing note: this is a device reset, not an account delete.
        playNote: '',
        confirmLabel: 'Delete data',
        cancelLabel: 'Cancel',
      ),
    );
    if (!mounted || !confirmed) return;
    if (!_service.available) {
      widget.data.onDeleteData?.call();
      return;
    }
    setState(() {
      _deleteOutcome = null;
      _phase = _Phase.deleting;
      _progress = const V2TransferProgress(label: 'Deleting device data…');
    });
    final outcome = await _service.deleteDeviceData();
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _progress = null;
      _deleteOutcome = outcome;
    });
    unawaited(_loadCache());
  }

  /// The email the server will compare. Empty means there is nothing to type
  /// that the server could verify; the screen says so instead of offering the
  /// sheet's `DELETE` fallback or a phone.
  String get _confirmationEmail => widget.data.accountContact.trim();

  /// `POST /data/delete-all`, behind the destructive warning and a typed
  /// email. The server's counts are the only success signal.
  Future<void> _deleteServerData() async {
    final request = widget.data.onServerDeleteAll;
    if (request == null) return;
    final email = _confirmationEmail;
    setState(() {
      _serverDeleteCounts = null;
      _serverDeleteError = null;
    });
    if (email.isEmpty) {
      setState(
        () => _serverDeleteError = dataControlFailureMessage(
          status: 409,
          code: 'confirmation_unavailable',
        ),
      );
      return;
    }
    final confirmed = await showConfirmTypedSheet(
      context,
      data: serverDeleteConfirmation(email),
    );
    if (!mounted || !confirmed) return;
    setState(() {
      _phase = _Phase.deleting;
      _progress = const V2TransferProgress(label: 'Deleting your data…');
    });
    DataDeletionCounts? counts;
    String? failure;
    try {
      counts = await request(email);
    } on DataControlFailure catch (error) {
      failure = error.message;
    } catch (_) {
      // Never render the thrown object: a provider dump is not a sentence.
      failure = dataControlFailureMessage(status: 0, code: 'unknown');
    }
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _progress = null;
      _serverDeleteCounts = counts;
      _serverDeleteError = failure;
    });
    unawaited(_loadCache());
  }
}

/// A settings row with its own status line underneath.
class _Block extends StatelessWidget {
  const _Block({required this.row, this.status});

  final Widget row;
  final Widget? status;

  @override
  Widget build(BuildContext context) {
    final status = this.status;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(bottom: OSpace.m),
            child: status,
          ),
      ],
    );
  }
}

/// One live progress line plus its bar. Announced as a live region so a
/// screen reader hears each phase without re-reading the row.
class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.title, required this.progress});

  final String title;
  final V2TransferProgress? progress;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final progress = this.progress;
    final label = progress?.label ?? 'Working…';
    final percent = progress?.fraction == null
        ? null
        : '${(progress!.fraction! * 100).round()}%';
    return Semantics(
      container: true,
      liveRegion: true,
      label: '$title. $label',
      value: percent,
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('data-control-progress'),
          padding: const EdgeInsets.all(OSpace.m),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: c.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: OType.bodySm.copyWith(
                  color: c.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: OSpace.xxs),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
              if (progress?.fraction != null) ...[
                const SizedBox(height: OSpace.s),
                OProgressBar(value: progress!.fraction!, height: 6),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One finished outcome: icon, one-line title, one meta line, optional
/// per-item details and one action.
class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.icon,
    required this.title,
    this.meta,
    this.tone,
    this.details = const <Widget>[],
    this.action,
  });

  final IconData icon;
  final String title;
  final String? meta;
  final Color? tone;
  final List<Widget> details;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final color = tone ?? c.textMuted;
    return Semantics(
      container: true,
      liveRegion: true,
      label: meta == null ? title : '$title. $meta',
      child: ExcludeSemantics(
        child: Container(
          key: const ValueKey('data-control-result'),
          padding: const EdgeInsets.all(OSpace.m),
          decoration: BoxDecoration(
            color: c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: tone == null ? c.hairline : color),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: OType.bodySm.copyWith(
                            color: c.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (meta != null) ...[
                          const SizedBox(height: OSpace.xxs),
                          Text(
                            meta!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              ...details,
              if (action != null) ...[
                const SizedBox(height: OSpace.s),
                Align(alignment: Alignment.centerLeft, child: action!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _plural(int count, String one, String many) =>
    '$count ${count == 1 ? one : many}';

String _reasonOf(Object error) {
  if (error is V2BackupException) return error.message;
  if (error is FormatException) return 'That file is not an Ovid backup.';
  return 'The file could not be read.';
}

/// Store ids are internal; the failure list speaks the product's language.
String _storeLabel(String id) {
  return switch (id) {
    'sessions' => 'Chats',
    'search' => 'Search index',
    'memory' => 'Memory files',
    'account' => 'Sign-in',
    'imageReceipts' => 'Image receipts',
    'shares' => 'Shared links',
    'collaboration' => 'Collaboration',
    'configuration' => 'Configuration',
    'secrets' => 'Saved keys',
    'preferences' => 'Preferences',
    'skills' => 'Skills',
    'exports' => 'Old exports',
    'cache' => 'Cache',
    'cookies' => 'Cookies',
    'drafts' => 'Drafts',
    _ => id,
  };
}

/// Extracts `42` from `42 messages` for the picker's message total. A missing
/// number contributes 0, which the picker shows as "0 of 20,000 messages".
int _messageCount(String detail) {
  final match = RegExp(r'([0-9]+)').firstMatch(detail);
  return match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
}
