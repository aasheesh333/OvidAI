import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../core/cloud/cloud_backup.dart';
import '../core/cloud/cloud_session_store.dart';
import '../core/diag.dart';
import '../core/native_share.dart';
import '../core/settings_backup_service.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'settings_action_widgets.dart';
import 'user_error.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/error_views.dart';

/// Settings → Export & import. Both directions go through Ovid Cloud (SE-008,
/// SE-009): export pages the account's full history from the server, import
/// uploads an archive's chats into the account through the import route.
class SettingsBackupScreen extends StatefulWidget {
  const SettingsBackupScreen({super.key, this.backup});

  /// Test seam; production uses the signed-in account's REST client.
  final CloudBackup? backup;

  @override
  State<SettingsBackupScreen> createState() => _SettingsBackupScreenState();
}

class _SettingsBackupScreenState extends State<SettingsBackupScreen> {
  bool _busy = false;
  String? _status;
  String? _statusDetail;
  String _operation = 'Export';
  File? _exported;

  /// Live progress line and fraction (null fraction = indeterminate).
  String? _progress;
  double? _fraction;
  CloudBackupCancelToken? _cancel;

  CloudBackup get _backup => widget.backup ?? CloudBackup();

  Future<void> _run(String operation, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _operation = operation;
      _status = null;
      _statusDetail = null;
      _progress = null;
      _fraction = null;
    });
    try {
      await action();
    } on CloudBackupCancelled {
      if (mounted) {
        setState(
          () => _status = operation == 'Import'
              ? CloudBackupCopy.importStopped
              : CloudBackupCopy.exportStopped,
        );
      }
    } catch (e, st) {
      Diag.swallow('settings_backup_screen.$operation', e, st);
      if (mounted) {
        final message = _failureMessage(context.l10n, operation, e);
        setState(() {
          _status = message;
          _statusDetail = UserError.detailOf(
            e is CloudRestorePartial ? e.cause : e,
          );
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _cancel = null;
          _progress = null;
          _fraction = null;
        });
      }
    }
  }

  String _failureMessage(AppLocalizations l, String operation, Object error) {
    if (error is CloudRestorePartial) {
      final cause = error.cause;
      final reason = cause is CloudBackupCancelled ? '' : _reason(l, cause);
      return CloudBackupCopy.importPartial(error.chatsUploaded, reason);
    }
    return l.backupFailedUnchanged(operation, _reason(l, error));
  }

  String _reason(AppLocalizations l, Object error) {
    // A named backup limit is already user-facing copy (PR-6d).
    if (error is BackupLimitException) return error.message;
    if (error is FormatException) return l.backupInvalidArchive;
    if (UserError.from(error).kind == UserErrorKind.unauthorized) {
      return CloudBackupCopy.signInRequired;
    }
    return friendlyError(error, l10n: l);
  }

  void _onProgress(CloudBackupProgress p) {
    if (!mounted) return;
    setState(() {
      _fraction = p.fraction;
      _progress = switch (p.phase) {
        CloudBackupPhase.listing => CloudBackupCopy.listing(p.done),
        CloudBackupPhase.downloading => CloudBackupCopy.downloading(
          p.done,
          p.total,
        ),
        CloudBackupPhase.uploading => CloudBackupCopy.uploading(
          p.done,
          p.total,
        ),
      };
    });
  }

  /// Pages the account's full history from Ovid Cloud with visible progress.
  Future<CloudExportSnapshot> _fetchHistory() async {
    final cancel = CloudBackupCancelToken();
    setState(() => _cancel = cancel);
    try {
      return await _backup.fetchHistory(
        onProgress: _onProgress,
        cancel: cancel,
      );
    } finally {
      // Past this point there is nothing left to stop.
      if (mounted) setState(() => _cancel = null);
    }
  }

  /// Opens the share sheet for [file] so the user picks where to save it.
  /// Never surfaces the private app path.
  Future<bool> _share(File file) async {
    try {
      await NativeShare.file(file.path);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _export() => _run('Export', () async {
    final snapshot = await _fetchHistory();
    final plan = SettingsBackupService.planExport(snapshot.sessions);
    if (!plan.isComplete) {
      final proceed = await _confirmPartial(plan);
      if (proceed != true || plan.included.isEmpty) {
        if (mounted) {
          setState(
            () => _status = CloudBackupCopy.exportLimit(plan.limitHit ?? ''),
          );
        }
        return;
      }
    }
    // Server transcripts only: no device attachment roots are read, so the
    // archive never claims files it could not fetch.
    final bytes = await SettingsBackupService().export(plan.included);
    final temp = await getTemporaryDirectory();
    final dir = await temp.createTemp('ovid-backup-');
    final file = File('${dir.path}/ovid-transcripts-v1.zip');
    try {
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      await dir.delete(recursive: true);
      rethrow;
    }
    if (mounted) setState(() => _exported = file);
    final messages = plan.included.fold<int>(
      0,
      (sum, s) => sum + s.messages.length,
    );
    final summary = StringBuffer(
      CloudBackupCopy.exported(plan.included.length, messages),
    );
    if (!plan.isComplete) {
      summary.write(
        CloudBackupCopy.exportPartial(
          plan.included.length,
          plan.skipped.length,
          plan.limitHit ?? '',
        ),
      );
    }
    if (snapshot.skippedMessages > 0) {
      summary.write(CloudBackupCopy.leftOutTool(snapshot.skippedMessages));
    }
    final shared = await _share(file);
    summary.write(
      shared ? CloudBackupCopy.exportShared : CloudBackupCopy.exportNotShared,
    );
    if (mounted) setState(() => _status = summary.toString());
  });

  Future<bool?> _confirmPartial(BackupExportPlan plan) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.backupLimitReachedTitle),
      content: Text(
        CloudBackupCopy.exportPartialPrompt(
          plan.included.length,
          plan.skipped.length,
          plan.limitHit ?? '',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.backupCancel),
        ),
        if (plan.included.isNotEmpty)
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.backupExportRecent),
          ),
      ],
    ),
  );

  Future<void> _exportJson() => _run('JSON export', () async {
    final snapshot = await _fetchHistory();
    final temp = await getTemporaryDirectory();
    // Remove plaintext left behind by an interrupted earlier export.
    await for (final entity in temp.list(followLinks: false)) {
      if (entity is Directory &&
          entity.uri.pathSegments
              .where((segment) => segment.isNotEmpty)
              .last
              .startsWith('ovid-json-')) {
        await entity.delete(recursive: true);
      }
    }
    final dir = await temp.createTemp('ovid-json-');
    final bool shared;
    try {
      final file = await SettingsBackupService.writeJsonExport(
        snapshot.sessions,
        dir,
      );
      // The native share path copies the file into its own short-lived share
      // cache before the chooser opens, so no plaintext copy is kept here.
      shared = await _share(file);
    } finally {
      await dir.delete(recursive: true).catchError((Object e) {
        Diag.swallow('settings_backup_screen.json_cleanup', e);
        return dir;
      });
    }
    if (mounted) {
      setState(
        () => _status = shared
            ? CloudBackupCopy.jsonShared
            : CloudBackupCopy.jsonNotShared,
      );
    }
  });

  /// One flow: pick an archive, validate it, show what it holds, and upload
  /// it to the Ovid Cloud account only after the user confirms.
  Future<void> _import() => _run('Import', () async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;
    final path = picked.files.single.path;
    if (path == null) {
      throw const FormatException(
        'This file provider did not supply a readable path.',
      );
    }
    final file = File(path);
    if (await file.length() > SettingsBackupService.maxArchiveBytes) {
      throw const FormatException('Archive exceeds 64 MiB.');
    }
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(
      0,
      SettingsBackupService.maxArchiveBytes + 1,
    )) {
      buffer.add(chunk);
    }
    final bytes = buffer.takeBytes();
    final temp = await getTemporaryDirectory();
    final staged = await SettingsBackupService().stage(bytes, temp);
    final List<Map<String, dynamic>> sessions;
    try {
      sessions = List.of(staged.sessions);
    } finally {
      await staged.dispose();
    }
    final messages = sessions.fold<int>(
      0,
      (sum, s) => sum + ((s['messages'] as List?)?.length ?? 0),
    );
    final summary = CloudBackupCopy.archiveSummary(sessions.length, messages);
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.backupRestoreTitle),
        content: Text('$summary\n\n${CloudBackupCopy.importConfirm}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.backupCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.backupRestoreConfirm),
          ),
        ],
      ),
    );
    if (confirm != true) {
      if (mounted) {
        setState(() => _status = '$summary${CloudBackupCopy.importDeclined}');
      }
      return;
    }
    final cancel = CloudBackupCancelToken();
    if (mounted) setState(() => _cancel = cancel);
    final CloudRestoreReport report;
    try {
      report = await _backup.uploadArchiveSessions(
        sessions,
        onProgress: _onProgress,
        cancel: cancel,
      );
    } finally {
      // Bring the uploaded chats (all, or the part uploaded before a stop)
      // into the sidebar as ordinary cloud chats.
      try {
        await CloudSessionStore.I.refreshSessions();
      } catch (e, st) {
        Diag.swallow('settings_backup_screen.refresh', e, st);
      }
    }
    if (mounted) setState(() => _status = CloudBackupCopy.imported(report));
  });

  @override
  Widget build(BuildContext context) {
    final mibLimit = SettingsBackupService.maxArchiveBytes ~/ (1024 * 1024);
    final idle = _exported != null
        ? CloudBackupCopy.archiveReady
        : CloudBackupCopy.idle;
    final live = _busy ? (_progress ?? '$_operation in progress…') : idle;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        toolbarHeight:
            kToolbarHeight * (MediaQuery.textScalerOf(context).scale(20) / 20),
        title: const Text(CloudBackupCopy.screenTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const AetherSectionTitle(
            eyebrow: CloudBackupCopy.screenTitle,
            subtitle: CloudBackupCopy.screenSubtitle,
          ),
          const SizedBox(height: 12),
          Semantics(
            container: true,
            liveRegion: true,
            label: CloudBackupCopy.statusPrefix + live,
            child: ExcludeSemantics(child: Text(live, style: AetherType.label)),
          ),
          if (_busy) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(
                    value: _fraction,
                    semanticsLabel: live,
                  ),
                ),
                if (_cancel != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _cancel!.isCancelled
                        ? null
                        : () => setState(() => _cancel!.cancel()),
                    child: const Text(CloudBackupCopy.stop),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SettingsActionButton(
                  label: CloudBackupCopy.exportButton,
                  icon: Icons.file_download_outlined,
                  primary: true,
                  onPressed: _busy ? null : _export,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SettingsActionButton(
                  label: 'Share archive',
                  icon: Icons.share_outlined,
                  onPressed: _busy || _exported == null
                      ? null
                      : () => _run('Share', () async {
                          final shared = await _share(_exported!);
                          if (mounted) {
                            setState(
                              () => _status = shared
                                  ? CloudBackupCopy.shareOpened
                                  : CloudBackupCopy.shareFailed,
                            );
                          }
                        }),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(CloudBackupCopy.exportHelp, style: AetherType.caption),
          const SizedBox(height: 16),
          SettingsActionButton(
            label: CloudBackupCopy.importButton,
            icon: Icons.file_upload_outlined,
            onPressed: _busy ? null : _import,
          ),
          const SizedBox(height: 8),
          Text(CloudBackupCopy.importHelp, style: AetherType.caption),
          const SizedBox(height: 16),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _busy ? null : _exportJson,
              icon: const Icon(Icons.data_object, size: 18),
              label: Text(context.l10n.backupJsonExport),
            ),
          ),
          Text(CloudBackupCopy.jsonHelp, style: AetherType.caption),
          const SizedBox(height: 16),
          AetherCard(
            title: Text(context.l10n.backupExportReadyTitle),
            trailing: AetherPill(label: 'V1', color: Aether.accent),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(CloudBackupCopy.scope, style: AetherType.body),
                const SizedBox(height: 10),
                Text(
                  CloudBackupCopy.limits(
                    mibLimit,
                    SettingsBackupService.maxSessions,
                    SettingsBackupService.maxMessages,
                  ),
                  style: AetherType.bodyMuted,
                ),
                const SizedBox(height: 10),
                Text(CloudBackupCopy.secrets, style: AetherType.bodyMuted),
              ],
            ),
          ),
          if (_status != null) ...[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              label: CloudBackupCopy.statusPrefix + _status!,
              child: SelectableText(_status!, style: AetherType.body),
            ),
            if (_statusDetail != null) ErrorDetails(detail: _statusDetail!),
          ],
        ],
      ),
    );
  }
}
