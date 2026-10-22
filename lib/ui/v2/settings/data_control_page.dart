import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'confirm_typed_sheet.dart';
import 'data_control_export.dart'
    if (dart.library.io) 'data_control_export_io.dart';
import 'export_picker_sheet.dart';
import 'settings_rows.dart';
import 'storage_breakdown.dart';
import 'storage_page.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

/// Writes a backup archive to a destination the user chose and returns that
/// destination, or null when the user cancelled the save dialog.
typedef V2ExportFileWriter = Future<String?> Function();

/// Result of checking a backup file before it is imported.
@immutable
class V2ImportValidation {
  const V2ImportValidation({
    required this.fileName,
    required this.message,
    required this.valid,
    this.checkedLabel = 'Checked now',
    this.planQuotaLabel = '',
    this.fitsPlan = true,
  });

  final String fileName;
  final String message;
  final bool valid;
  final String checkedLabel;

  /// Plain-language result of the plan-storage check, for example
  /// "Needs 1.4 GB · 2.1 GB free on your plan".
  final String planQuotaLabel;

  /// False when the archive is valid but the account does not have enough
  /// plan storage for it. Import stays blocked until the user frees space.
  final bool fitsPlan;

  bool get canImport => valid && fitsPlan;
}

/// One chat in the export selection window. Only used when the account is over
/// the 64 MB archive limit.
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

  final String id;
  final String name;
  final int sizeBytes;
  final String sizeLabel;
  final String detail;
  final bool selected;

  /// True when the chat contains videos or other large files that are not
  /// part of a transcript archive and must be re-uploaded after an import.
  final bool heavyArtifacts;
}

/// Called with the chat id and its new selected state.
typedef V2ExportSessionToggle = void Function(String id, bool selected);

/// Injected state for the Data control screen.
@immutable
class V2DataControlPageData {
  const V2DataControlPageData({
    this.lastExportLabel = '',
    this.backupSizeLabel = '',
    this.totalDataSizeLabel = '',
    this.exportLimitLabel = 'Up to 64 MB · 1,000 chats · 20,000 messages',
    this.exportLimitBytes = 64 * 1024 * 1024,
    this.exportSessions = const <V2ExportSession>[],
    this.permissionSummary = '',
    this.storageUsedLabel = '',
    this.storageFraction = 0,
    this.storageFreeLabel = '',
    this.crashReports = true,
    this.importValidation,
    this.importChecking = false,
    this.hasData = true,
    this.loading = false,
    this.errorMessage,
    this.accountContact = '',
    this.memorySummaryLabel = '',
    this.onExportImport,
    this.onExport,
    this.onSaveExport,
    this.onChooseImport,
    this.onImport,
    this.onExportSessionToggled,
    this.onPermissions,
    this.onCrashReportsChanged,
    this.onStorage,
    this.onDeleteData,
    this.onResetMemory,
    this.onClearCache,
    this.onClearCacheAndReport,
    this.onRetry,
  });

  final String lastExportLabel;
  final String backupSizeLabel;

  /// Total size of everything in the account, shown beside the export limits.
  final String totalDataSizeLabel;
  final String exportLimitLabel;
  final int exportLimitBytes;

  /// Per-chat sizes. The selection window appears automatically when their
  /// total is larger than [exportLimitBytes].
  final List<V2ExportSession> exportSessions;

  final String permissionSummary;
  final String storageUsedLabel;
  final double storageFraction;
  final String storageFreeLabel;

  /// Opt-out crash reports and anonymous analytics. On by default.
  final bool crashReports;
  final V2ImportValidation? importValidation;
  final bool importChecking;
  final bool hasData;
  final bool loading;
  final String? errorMessage;

  /// Registered email or phone the user must type to delete their data.
  final String accountContact;

  /// Optional summary such as "Global memory and 12 session files".
  final String memorySummaryLabel;

  final VoidCallback? onExportImport;
  final VoidCallback? onExport;

  /// Saves the archive to a real destination. When null the page writes a real
  /// zip and opens the platform save dialog itself.
  final V2ExportFileWriter? onSaveExport;
  final VoidCallback? onChooseImport;
  final VoidCallback? onImport;
  final V2ExportSessionToggle? onExportSessionToggled;
  final VoidCallback? onPermissions;
  final ValueChanged<bool>? onCrashReportsChanged;
  final VoidCallback? onStorage;
  final VoidCallback? onDeleteData;

  /// Retained for hosts that still pass it; memory reset lives on the Memory
  /// page, so Data control no longer renders a row for it.
  final VoidCallback? onResetMemory;

  /// Clears the on-device cache. When null the page clears the app's
  /// temporary directory itself, so the row always does real work.
  final VoidCallback? onClearCache;

  /// Clears the cache and returns the bytes actually freed. Wins over
  /// [onClearCache] when the host can measure the result itself.
  final Future<int> Function()? onClearCacheAndReport;
  final VoidCallback? onRetry;

  int get exportTotalBytes =>
      exportSessions.fold<int>(0, (sum, session) => sum + session.sizeBytes);

  int get exportSelectedBytes => exportSessions
      .where((session) => session.selected)
      .fold<int>(0, (sum, session) => sum + session.sizeBytes);

  int get exportSelectedCount =>
      exportSessions.where((session) => session.selected).length;

  bool get exportOverLimit => exportTotalBytes > exportLimitBytes;

  bool get exportSelectionOverLimit => exportSelectedBytes > exportLimitBytes;

  bool get showExportSelection => exportSessions.isNotEmpty && exportOverLimit;

  bool get canExport =>
      !exportOverLimit ||
      (exportSelectedCount > 0 && !exportSelectionOverLimit);

  bool get canImport => importValidation?.canImport ?? false;
}

/// Privacy and data controls: four rows — export, import, cache and the
/// destructive delete. Every row is an action; there are no explanatory
/// paragraphs.
class DataControlPage extends StatelessWidget {
  const DataControlPage({super.key, required this.data});

  final V2DataControlPageData data;

  @override
  Widget build(BuildContext context) {
    final status = data.loading
        ? OStatus.loading
        : data.errorMessage != null
        ? OStatus.error
        : data.hasData
        ? OStatus.content
        : OStatus.empty;
    return OScreen(
      title: 'Data control',
      child: OStateView(
        status: status,
        errorMessage: data.errorMessage,
        onRetry: data.onRetry,
        skeletonRows: 5,
        emptyTitle: 'No data to manage',
        emptyBody: 'Chats and files appear here.',
        emptyActionLabel: 'Export data',
        onEmptyAction: data.onExportImport ?? data.onExport,
        child: _content(context),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final export = _exportTap(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          V2SettingsRowList(
            rows: [
              if (export != null)
                V2SettingsRow(
                  key: const ValueKey<String>('export-backup-row'),
                  icon: Icons.save_alt_rounded,
                  title: 'Export backup',
                  onTap: export,
                ),
              if (data.onChooseImport != null)
                V2SettingsRow(
                  key: const ValueKey<String>('import-backup-row'),
                  icon: Icons.upload_file_rounded,
                  title: 'Import',
                  onTap: data.onChooseImport,
                ),
              if (data.importChecking || data.importValidation != null)
                _importRow(context),
              V2SettingsRow(
                key: const ValueKey<String>('clear-cache-row'),
                icon: Icons.cleaning_services_outlined,
                title: 'Clear cache',
                showChevron: false,
                onTap: () => _clearCache(context),
              ),
              if (data.onDeleteData != null)
                V2SettingsRow(
                  key: const ValueKey<String>('delete-data-row'),
                  icon: Icons.delete_forever_outlined,
                  title: 'Delete data',
                  danger: true,
                  showChevron: false,
                  onTap: () => _confirmDelete(context),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The export row's real tap: the archive flow when the host exports, the
  /// save dialog when it only writes files. A page with neither omits the row.
  VoidCallback? _exportTap(BuildContext context) {
    if (data.onExport != null) return () => _handleExport(context);
    if (data.onSaveExport != null) {
      return () => _handleExport(context, save: true);
    }
    return null;
  }

  /// The checked backup, or the check in flight. One row, no paragraphs.
  Widget _importRow(BuildContext context) {
    final check = data.importValidation;
    if (data.importChecking || check == null) {
      return const V2SettingsRow(
        icon: Icons.hourglass_empty_rounded,
        title: 'Checking backup…',
        showChevron: false,
      );
    }
    final action = check.canImport
        ? OButton(
            label: 'Import',
            variant: OButtonVariant.ghost,
            onPressed: data.onImport,
          )
        : check.valid && !check.fitsPlan && data.onStorage != null
        ? OButton(
            label: 'Storage',
            variant: OButtonVariant.ghost,
            onPressed: data.onStorage,
          )
        : OButton(
            label: 'Choose',
            variant: OButtonVariant.ghost,
            onPressed: data.onChooseImport,
          );
    return Column(
      key: const ValueKey<String>('import-check-row'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        V2SettingsRow(
          icon: check.valid
              ? Icons.check_circle_outline_rounded
              : Icons.error_outline_rounded,
          title: check.fileName,
          subtitle: check.message,
          showChevron: false,
        ),
        // The action sits under the text instead of beside it: at 200 % text
        // a trailing button and a long file name cannot share one line.
        Align(alignment: Alignment.centerRight, child: action),
      ],
    );
  }

  /// Clears the on-device cache and reports the real bytes freed, exactly
  /// like the Storage row: a host callback wins, otherwise the page measures
  /// the temporary directory itself.
  Future<void> _clearCache(BuildContext context) async {
    final reporter = data.onClearCacheAndReport;
    if (reporter != null) {
      final freed = await reporter();
      if (!context.mounted) return;
      _snackFreed(context, freed);
      return;
    }
    if (data.onClearCache != null) {
      data.onClearCache!();
      if (context.mounted) _snack(context, 'Cache cleared.');
      return;
    }
    try {
      final freed = await clearTemporaryCache();
      if (!context.mounted) return;
      _snackFreed(context, freed);
    } catch (_) {
      if (context.mounted) {
        _snack(context, 'Could not clear the cache. Try again.');
      }
    }
  }

  void _snackFreed(BuildContext context, int freed) {
    _snack(
      context,
      freed > 0
          ? 'Freed ${formatStorageBytes(freed)} of cache.'
          : 'Cache is already empty.',
    );
  }

  /// Over the archive cap, exporting opens the shared picker instead of an
  /// inline list. Everything the sheet shows comes from this page's immutable
  /// session list; every checkbox and the export action go back through the
  /// page's callbacks.
  Future<void> _handleExport(BuildContext context, {bool save = false}) async {
    final export = data.onExport;
    if (!save && export == null) return;
    if (!data.showExportSelection) {
      if (save) {
        await _saveExport(context);
      } else {
        export!();
      }
      return;
    }
    final toggle = data.onExportSessionToggled;
    await showExportPickerSheet(
      context,
      data: V2ExportPickerSheetData(
        sessions: [
          for (final session in data.exportSessions)
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
        limitBytes: data.exportLimitBytes,
        limitChats: v2ExportPickerChatLimit,
        limitMessages: v2ExportPickerMessageLimit,
      ),
      onToggleSession: toggle,
      onSelectAll: toggle == null ? null : _applySelection,
      onExport: () {
        Navigator.of(context).maybePop();
        if (save) {
          _saveExport(context);
        } else {
          export?.call();
        }
      },
      onRetry: data.onRetry,
    );
  }

  /// Writes the archive to a destination the person picks. The default writer
  /// builds the same zip the export uses and hands it to the platform save
  /// dialog, so "Save to device" produces a real file instead of a toast.
  Future<void> _saveExport(BuildContext context) async {
    try {
      final writer = data.onSaveExport;
      if (writer != null) {
        final path = await writer();
        if (!context.mounted) return;
        _snack(context, path == null ? 'Export cancelled.' : 'Saved to $path');
        return;
      }
      final result = await saveHistoryExport();
      if (!context.mounted) return;
      if (result.path != null) {
        _snack(context, 'Saved to ${result.path}');
      } else if (result.message != null) {
        _snack(context, result.message!);
      } else {
        _snack(context, 'Export cancelled.');
      }
    } catch (_) {
      if (context.mounted) {
        _snack(context, 'Could not save the export. Try again.');
      }
    }
  }

  /// Applies the picker's complete id set as individual toggles, so the page's
  /// injected callback remains the single owner of the selection.
  void _applySelection(List<String> ids) {
    final selected = ids.toSet();
    final toggle = data.onExportSessionToggled;
    if (toggle == null) return;
    for (final session in data.exportSessions) {
      final next = selected.contains(session.id);
      if (next != session.selected) toggle(session.id, next);
    }
  }

  void _snack(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showConfirmTypedSheet(
      context,
      data: V2ConfirmTypedSheetData(
        contact: data.accountContact,
        title: 'Delete all your data?',
        confirmLabel: 'Delete everything',
        cancelLabel: 'Cancel',
      ),
    );
    if (confirmed) data.onDeleteData?.call();
  }
}

/// Extracts `42` from `42 messages` for the picker's message total. The page
/// does not carry a separate count, and a missing number simply contributes 0.
int _messageCount(String detail) {
  final match = RegExp(r'([0-9]+)').firstMatch(detail);
  return match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
}
