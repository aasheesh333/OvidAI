import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

/// Result of checking a backup file before it is imported.
@immutable
class V2ImportValidation {
  const V2ImportValidation({
    required this.fileName,
    required this.message,
    required this.valid,
    this.checkedLabel = 'Checked just now',
  });

  final String fileName;
  final String message;
  final bool valid;
  final String checkedLabel;
}

/// Injected state for the Data control screen.
@immutable
class V2DataControlPageData {
  const V2DataControlPageData({
    this.lastExportLabel = '',
    this.backupSizeLabel = '',
    this.exportLimitLabel = 'Up to 64 MB · 1,000 sessions · 20,000 messages',
    this.permissionSummary = '',
    this.storageUsedLabel = '',
    this.storageFraction = 0,
    this.storageFreeLabel = '',
    this.crashReports = false,
    this.importValidation,
    this.importChecking = false,
    this.hasData = true,
    this.loading = false,
    this.errorMessage,
    this.onExportImport,
    this.onExport,
    this.onChooseImport,
    this.onImport,
    this.onPermissions,
    this.onCrashReportsChanged,
    this.onStorage,
    this.onDeleteData,
    this.onResetMemory,
    this.onRetry,
  });

  final String lastExportLabel;
  final String backupSizeLabel;
  final String exportLimitLabel;
  final String permissionSummary;
  final String storageUsedLabel;
  final double storageFraction;
  final String storageFreeLabel;
  final bool crashReports;
  final V2ImportValidation? importValidation;
  final bool importChecking;
  final bool hasData;
  final bool loading;
  final String? errorMessage;

  final VoidCallback? onExportImport;
  final VoidCallback? onExport;
  final VoidCallback? onChooseImport;
  final VoidCallback? onImport;
  final VoidCallback? onPermissions;
  final ValueChanged<bool>? onCrashReportsChanged;
  final VoidCallback? onStorage;
  final VoidCallback? onDeleteData;
  final VoidCallback? onResetMemory;
  final VoidCallback? onRetry;
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
                const SizedBox(height: OSpace.m),
                Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.s,
                  children: [
                    OButton(
                      label: 'Export backup',
                      icon: Icons.download_rounded,
                      variant: OButtonVariant.secondary,
                      onPressed: data.onExport,
                    ),
                    OButton(
                      label: 'Choose backup',
                      icon: Icons.upload_file_rounded,
                      variant: OButtonVariant.ghost,
                      onPressed: data.onChooseImport,
                    ),
                  ],
                ),
                const SizedBox(height: OSpace.m),
                _importStatus(context, check),
              ],
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
                Align(
                  alignment: Alignment.centerRight,
                  child: check.valid
                      ? OButton(
                          label: 'Import now',
                          icon: Icons.file_download_outlined,
                          variant: OButtonVariant.ghost,
                          onPressed: data.onImport,
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
              subtitle: 'Send anonymous diagnostic logs to improve stability',
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
                  'Synced locally & cloud',
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
                  icon: Icons.delete_forever_outlined,
                  title: 'Delete your data',
                  subtitle:
                      'Permanently delete conversations, files, and generated code',
                  danger: true,
                  onTap: data.onDeleteData,
                ),
                Divider(color: c.hairline, height: 1),
                OListRow(
                  icon: Icons.history_rounded,
                  title: 'Reset memory',
                  subtitle:
                      'Wipe learned facts, project preferences, and personas',
                  danger: true,
                  onTap: data.onResetMemory,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
