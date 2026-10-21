import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/cloud/cloud_backup.dart';
import '../../../core/settings_backup_service.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'confirm_typed_sheet.dart';
import 'export_picker_sheet.dart';

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
    this.checkedLabel = 'Checked just now',
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
    this.exportLimitLabel = 'Up to 64 MB · 1,000 sessions · 20,000 messages',
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
  final VoidCallback? onResetMemory;
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

/// Privacy and data controls: backup, permissions, crash reports and deletion.
class DataControlPage extends StatelessWidget {
  const DataControlPage({super.key, required this.data});

  final V2DataControlPageData data;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Data control'),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.loading) {
      return const OFadeSlide(child: OSkeletonList(rows: 6));
    }
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    if (!data.hasData) {
      return OEmptyState(
        icon: Icons.shield_outlined,
        title: 'No data to manage yet',
        message: 'Your chats, files, and memory will appear here.',
        action: OButton(
          label: 'Export or import',
          icon: Icons.swap_vert_rounded,
          onPressed: data.onExportImport ?? data.onChooseImport,
        ),
      );
    }
    return OFadeSlide(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          OSpace.screen,
          OSpace.l,
          OSpace.screen,
          OSpace.xxl,
        ),
        child: OStagger(
          children: [
            _intro(context),
            _backupCard(context),
            _generalControls(context),
            _dangerZone(context),
          ],
        ),
      ),
    );
  }

  Widget _intro(BuildContext context) {
    final c = OColors.of(context);
    final status = [
      data.lastExportLabel,
      data.backupSizeLabel,
    ].where((s) => s.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: c.accentSoft,
                    borderRadius: BorderRadius.circular(ORadius.m),
                  ),
                  child: Icon(
                    Icons.admin_panel_settings_outlined,
                    size: 24,
                    color: c.accent,
                  ),
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Privacy & Data Control',
                        style: OType.h2.copyWith(color: c.text),
                      ),
                      const SizedBox(height: OSpace.xs),
                      Text(
                        'Take full ownership of your data, exports, and permissions. You decide what stays and what goes.',
                        style: OType.bodySm.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.m),
            if (status.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(OSpace.m),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: c.success,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Text(
                        status,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _backupCard(BuildContext context) {
    final c = OColors.of(context);
    final check = data.importValidation;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Backup and restore',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: Text(
              'Encrypted',
              style: OType.caption.copyWith(color: c.success),
            ),
          ),
          OCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c.surfaceAlt,
                        borderRadius: BorderRadius.circular(ORadius.m),
                      ),
                      child: Icon(
                        Icons.inventory_2_outlined,
                        size: 19,
                        color: c.textMuted,
                      ),
                    ),
                    const SizedBox(width: OSpace.m),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Move your data in or out',
                            style: OType.body.copyWith(
                              color: c.text,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: OSpace.xs),
                          Text(
                            data.exportLimitLabel,
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (data.totalDataSizeLabel.isNotEmpty) ...[
                  const SizedBox(height: OSpace.m),
                  Container(
                    padding: const EdgeInsets.all(OSpace.m),
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(ORadius.m),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.data_usage_rounded,
                          size: 18,
                          color: c.textMuted,
                        ),
                        const SizedBox(width: OSpace.s),
                        Expanded(
                          child: Text(
                            'Total data in your account',
                            style: OType.caption.copyWith(color: c.textMuted),
                          ),
                        ),
                        const SizedBox(width: OSpace.s),
                        Flexible(
                          child: Text(
                            data.totalDataSizeLabel,
                            textAlign: TextAlign.end,
                            style: OType.caption.copyWith(
                              color: c.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: OSpace.m),
                Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.s,
                  children: [
                    OButton(
                      label: 'Export backup',
                      icon: Icons.download_rounded,
                      variant: OButtonVariant.secondary,
                      onPressed: data.onExport == null
                          ? null
                          : () => _handleExport(context),
                    ),
                    OButton(
                      key: const ValueKey('save-export-button'),
                      label: 'Save to device',
                      icon: Icons.save_alt_rounded,
                      variant: OButtonVariant.secondary,
                      onPressed: () => _handleExport(context, save: true),
                    ),
                    OButton(
                      label: 'Choose backup',
                      icon: Icons.upload_file_rounded,
                      variant: OButtonVariant.ghost,
                      onPressed: data.onChooseImport,
                    ),
                  ],
                ),
                if (data.showExportSelection) ...[
                  const SizedBox(height: OSpace.m),
                  _exportPickerNote(context),
                ],
                const SizedBox(height: OSpace.m),
                _importStatus(context, check),
                const SizedBox(height: OSpace.m),
                _heavyArtifactsNote(context),
              ],
            ),
          ),
        ],
      ),
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
      final path = writer != null ? await writer() : await _defaultSaveExport();
      if (!context.mounted) return;
      if (path == null) {
        _snack(context, 'Export cancelled.');
        return;
      }
      _snack(context, 'Saved to $path');
    } on BackupLimitException catch (e) {
      if (context.mounted) _snack(context, e.message);
    } catch (_) {
      if (context.mounted) {
        _snack(context, 'Could not save the export. Try again.');
      }
    }
  }

  Future<String?> _defaultSaveExport() async {
    final snapshot = await CloudBackup().fetchHistory();
    final plan = SettingsBackupService.planExport(snapshot.sessions);
    if (plan.included.isEmpty) {
      throw BackupLimitException(
        plan.limitHit ?? 'There is nothing to export yet.',
      );
    }
    final bytes = await SettingsBackupService().export(plan.included);
    return FilePicker.platform.saveFile(
      dialogTitle: 'Save Ovid backup',
      fileName: 'ovid-transcripts-v1.zip',
      type: FileType.custom,
      allowedExtensions: const <String>['zip'],
      bytes: bytes,
    );
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

  Widget _exportPickerNote(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      key: const ValueKey('export-picker-note'),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.filter_alt_outlined, size: 18, color: c.accent),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              'Your data is ${_mb(data.exportTotalBytes)}, over the '
              '${_mb(data.exportLimitBytes)} archive limit. Export backup '
              'opens a picker so you choose which chats to include.',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heavyArtifactsNote(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      key: const ValueKey('heavy-artifacts-note'),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.upload_file_rounded, size: 18, color: c.warn),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              'Heavy artifacts are not included in a backup. Large files, '
              'videos and generated assets must be re-uploaded after importing.',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _importStatus(BuildContext context, V2ImportValidation? check) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: data.importChecking
          ? Row(
              children: [
                const OSkeleton(width: 20, height: 20, radius: ORadius.pill),
                const SizedBox(width: OSpace.s),
                Expanded(
                  child: Text(
                    'Checking the backup file…',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
              ],
            )
          : check == null
          ? Text(
              'Choose a backup file to check its size and contents before importing.',
              style: OType.caption.copyWith(color: c.textMuted),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      check.valid
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      size: 20,
                      color: check.valid ? c.success : c.danger,
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            check.fileName,
                            style: OType.bodySm.copyWith(
                              color: c.text,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: OSpace.xs),
                          Text(
                            check.message,
                            style: OType.caption.copyWith(
                              color: check.valid ? c.textMuted : c.danger,
                            ),
                          ),
                          const SizedBox(height: OSpace.xs),
                          Text(
                            check.checkedLabel,
                            style: OType.caption.copyWith(color: c.textFaint),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: OSpace.s),
                Container(
                  key: const ValueKey('import-plan-quota'),
                  padding: const EdgeInsets.all(OSpace.s),
                  decoration: BoxDecoration(
                    color: check.fitsPlan
                        ? c.success.withValues(alpha: 0.10)
                        : c.danger.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(ORadius.s),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        check.fitsPlan
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off_outlined,
                        size: 18,
                        color: check.fitsPlan ? c.success : c.danger,
                      ),
                      const SizedBox(width: OSpace.s),
                      Expanded(
                        child: Text(
                          check.planQuotaLabel.isNotEmpty
                              ? check.planQuotaLabel
                              : check.fitsPlan
                              ? 'Fits your plan storage.'
                              : 'Not enough plan storage for this archive.',
                          style: OType.caption.copyWith(
                            color: check.fitsPlan ? c.textMuted : c.danger,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: OSpace.s),
                Align(
                  alignment: Alignment.centerRight,
                  child: check.canImport
                      ? OButton(
                          label: 'Import now',
                          icon: Icons.file_download_outlined,
                          variant: OButtonVariant.ghost,
                          onPressed: data.onImport,
                        )
                      : check.valid && !check.fitsPlan
                      ? OButton(
                          label: 'Manage storage',
                          icon: Icons.cloud_outlined,
                          variant: OButtonVariant.ghost,
                          onPressed: data.onStorage,
                        )
                      : OButton(
                          label: 'Choose another file',
                          icon: Icons.refresh_rounded,
                          variant: OButtonVariant.ghost,
                          onPressed: data.onChooseImport,
                        ),
                ),
              ],
            ),
    );
  }

  Widget _generalControls(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'General controls',
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                OListRow(
                  icon: Icons.swap_vert_rounded,
                  title: 'Export or import',
                  subtitle: data.exportLimitLabel,
                  onTap: data.onExportImport,
                ),
                Divider(color: c.hairline, height: 1),
                OListRow(
                  icon: Icons.verified_user_outlined,
                  title: 'Permissions',
                  subtitle: data.permissionSummary,
                  onTap: data.onPermissions,
                ),
              ],
            ),
          ),
          const SizedBox(height: OSpace.m),
          OCard(
            padding: EdgeInsets.zero,
            child: OListRow(
              icon: Icons.bug_report_outlined,
              title: 'Crash reports',
              subtitle:
                  'Anonymous diagnostics and usage. Never includes chats, '
                  'prompts or files.',
              showChevron: false,
              onTap: data.onCrashReportsChanged == null
                  ? null
                  : () => data.onCrashReportsChanged!(!data.crashReports),
              trailing: Semantics(
                label: 'Crash reports',
                toggled: data.crashReports,
                button: true,
                enabled: data.onCrashReportsChanged != null,
                onTap: data.onCrashReportsChanged == null
                    ? null
                    : () => data.onCrashReportsChanged!(!data.crashReports),
                child: ExcludeSemantics(
                  child: Switch(
                    value: data.crashReports,
                    onChanged: data.onCrashReportsChanged,
                    activeThumbColor: c.onAccent,
                    activeTrackColor: c.accentFill,
                    inactiveThumbColor: c.textFaint,
                    inactiveTrackColor: c.surfaceRaised,
                    trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: OSpace.m),
          _storageCard(context),
        ],
      ),
    );
  }

  Widget _storageCard(BuildContext context) {
    final c = OColors.of(context);
    final percent = (data.storageFraction.clamp(0, 1) * 100).round();
    return OCard(
      onTap: data.onStorage,
      semanticLabel: 'Storage, ${data.storageUsedLabel}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(Icons.cloud_outlined, size: 19, color: c.textMuted),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Storage',
                      style: OType.body.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: OSpace.xs),
                    if (data.storageUsedLabel.isNotEmpty)
                      Text(
                        '${data.storageUsedLabel} ($percent%)',
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
            ],
          ),
          const SizedBox(height: OSpace.m),
          OProgressBar(value: data.storageFraction),
          const SizedBox(height: OSpace.s),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Cloud storage for your plan',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
              const SizedBox(width: OSpace.s),
              Flexible(
                child: Text(
                  data.storageFreeLabel,
                  textAlign: TextAlign.end,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dangerZone(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: OSpace.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Danger zone',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: Text(
              'Irreversible actions',
              style: OType.caption.copyWith(color: c.danger),
            ),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                OListRow(
                  key: const ValueKey('delete-data-row'),
                  icon: Icons.delete_forever_outlined,
                  title: 'Delete your data',
                  subtitle:
                      'Permanently delete chats, workspace files, artifacts, '
                      'memory, drafts and shared links',
                  danger: true,
                  enabled: data.onDeleteData != null,
                  onTap: data.onDeleteData == null
                      ? null
                      : () => _confirmDelete(context),
                ),
                Divider(color: c.hairline, height: 1),
                OListRow(
                  key: const ValueKey('reset-memory-row'),
                  icon: Icons.history_rounded,
                  title: 'Reset memory',
                  subtitle:
                      'Erase global memory and the memory file for every session',
                  danger: true,
                  enabled: data.onResetMemory != null,
                  onTap: data.onResetMemory == null
                      ? null
                      : () => _confirmResetMemory(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
        intro:
            'Your account, plan and billing history are kept. Everything '
            'else is removed now.',
        graceNote:
            'Chats, files, artifacts, memory, connectors and shared links are '
            'deleted immediately. This cannot be undone.',
        playNote: '',
        confirmLabel: 'Delete everything',
        cancelLabel: 'Cancel',
      ),
    );
    if (confirmed) data.onDeleteData?.call();
  }

  Future<void> _confirmResetMemory(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ResetMemoryDialog(summary: data.memorySummaryLabel),
    );
    if (confirmed == true) data.onResetMemory?.call();
  }
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';

/// Extracts `42` from `42 messages` for the picker's message total. The page
/// does not carry a separate count, and a missing number simply contributes 0.
int _messageCount(String detail) {
  final match = RegExp(r'([0-9]+)').firstMatch(detail);
  return match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
}

/// Reset memory confirmation. Separate from Delete data because chats and
/// artifacts stay; only learned memory is removed.
class _ResetMemoryDialog extends StatelessWidget {
  const _ResetMemoryDialog({required this.summary});

  final String summary;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return AlertDialog(
      scrollable: true,
      backgroundColor: c.surface,
      icon: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: c.danger.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.history_rounded, color: c.danger),
      ),
      title: Text('Reset all memory?', style: OType.h2.copyWith(color: c.text)),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            summary.isEmpty
                ? 'Ovid forgets everything it learned about you:'
                : summary,
            style: OType.bodySm.copyWith(
              color: c.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: OSpace.s),
          Text(
            '• Global memory\n'
            '• Project memory for every project\n'
            '• The memory file for every session',
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.m),
          Text(
            'Chats, files and artifacts stay. This cannot be undone.',
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('reset-memory-confirm'),
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(
            backgroundColor: c.danger,
            foregroundColor: c.onDanger,
            minimumSize: const Size(0, OSpace.touch),
          ),
          child: const Text('Reset memory'),
        ),
      ],
    );
  }
}
