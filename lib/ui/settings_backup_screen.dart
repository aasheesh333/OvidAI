import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../core/native_share.dart';
import '../core/settings_actions.dart';
import '../core/settings_backup_service.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'settings_action_widgets.dart';
import 'widgets/aether_primitives.dart';

class SettingsBackupScreen extends StatefulWidget {
  const SettingsBackupScreen({super.key});
  @override
  State<SettingsBackupScreen> createState() => _SettingsBackupScreenState();
}

class _SettingsBackupScreenState extends State<SettingsBackupScreen> {
  bool _busy = false;
  String? _status;
  String _operation = 'Backup';
  File? _exported;

  Future<void> _run(String operation, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _operation = operation;
      _status = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        final reason = e is FormatException ? e.message : '$e';
        setState(
          () => _status =
              'Operation failed during $operation. No data was changed. $reason',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
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
    final sessions = List.of(AppState.I.sessions);
    final plan = SettingsBackupService.planExport(sessions);
    if (!plan.isComplete) {
      final proceed = await _confirmPartial(plan);
      if (proceed != true || plan.included.isEmpty) {
        if (mounted) {
          setState(
            () => _status =
                'Export cancelled. Your chats exceed ${plan.limitHit}.',
          );
        }
        return;
      }
    }
    final support = await getApplicationSupportDirectory();
    // Only known attachment roots; never export arbitrary app documents,
    // secure storage, external folders, or a recursively discovered tree.
    final service = SettingsBackupService(
      attachmentRoots: [Directory('${support.path}/workspaces')],
    );
    final bytes = await service.export(plan.included);
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
    final shared = await _share(file);
    if (mounted) {
      final scope = plan.isComplete
          ? ''
          : ' It holds your ${plan.included.length} most recent chat(s); '
                '${plan.skipped.length} older chat(s) were left out because '
                'of ${plan.limitHit}.';
      setState(() {
        _status = shared
            ? 'Export complete. Choose where to save the archive in the share sheet.$scope'
            : 'Export complete. Tap Share archive to save it.$scope';
      });
    }
  });

  Future<bool?> _confirmPartial(BackupExportPlan plan) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Backup limit reached'),
      content: Text(
        'Your chats exceed ${plan.limitHit}. '
        '${plan.included.isEmpty ? 'No chat fits in a backup.' : 'Export your ${plan.included.length} most recent chat(s) now? ${plan.skipped.length} older chat(s) will not be included.'}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        if (plan.included.isNotEmpty)
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Export recent chats'),
          ),
      ],
    ),
  );

  Future<void> _exportJson() => _run('JSON export', () async {
    final temp = await getTemporaryDirectory();
    final dir = await temp.createTemp('ovid-json-');
    final file = await SettingsBackupService.writeJsonExport(
      List.of(AppState.I.sessions),
      dir,
    );
    final shared = await _share(file);
    if (mounted) {
      setState(
        () => _status = shared
            ? 'JSON export ready. Choose where to save it in the share sheet. '
                  'JSON files are for other tools and cannot be restored.'
            : 'JSON export could not open the share sheet. Try again.',
      );
    }
  });

  /// One flow: pick an archive, validate it, show what it holds, and restore
  /// only after the user confirms.
  Future<void> _import() => _run('Import', () async {
    // Capture ownership before the picker and all IO: an account handoff while
    // choosing a file must not redirect the import into the next account.
    final publisher = SettingsActions.restorePublisher;
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
    final int sessions;
    final int messages;
    final int attachments;
    try {
      sessions = staged.sessions.length;
      messages = staged.sessions.fold<int>(
        0,
        (sum, s) => sum + ((s['messages'] as List?)?.length ?? 0),
      );
      attachments = staged.attachments.length;
    } finally {
      await staged.dispose();
    }
    final summary =
        'Archive valid: $sessions transcript(s), $messages message(s), '
        '$attachments portable attachment(s).';
    if (publisher == null) {
      if (mounted) {
        setState(
          () => _status =
              '$summary Restore is unavailable in this build. No data restored.',
        );
      }
      return;
    }
    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text(
          '$summary\n\nThey will be added as new, inactive chats in the '
          'current account. Existing chats are not changed or merged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirm != true) {
      if (mounted) setState(() => _status = '$summary No data restored.');
      return;
    }
    await SettingsBackupService(publisher: publisher).restore(bytes, temp);
    if (mounted) {
      setState(
        () => _status =
            'Transcripts restored: $sessions new, inactive chat(s) '
            'in the current account.',
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final restoreAvailable = SettingsActions.restorePublisher != null;
    final mibLimit = SettingsBackupService.maxArchiveBytes ~/ (1024 * 1024);
    final attLimit = SettingsBackupService.maxAttachmentBytes ~/ (1024 * 1024);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight:
            kToolbarHeight * (MediaQuery.textScalerOf(context).scale(20) / 20),
        title: const Text('Export data'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const AetherSectionTitle(
            eyebrow: 'Backup',
            subtitle: 'Portable, versioned transcript archive.',
          ),
          const SizedBox(height: 12),
          Semantics(
            container: true,
            liveRegion: true,
            label:
                'Backup status: ${_busy
                    ? '$_operation in progress'
                    : _exported != null
                    ? 'Archive ready to share'
                    : 'Ready to export'}',
            child: ExcludeSemantics(
              child: Text(
                _busy
                    ? '$_operation in progress…'
                    : _exported != null
                    ? 'Archive ready to share'
                    : 'Ready to export',
                style: AetherType.label,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SettingsActionButton(
                  label: 'Export',
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
                                  ? 'Share sheet opened. Choose a destination to save the archive.'
                                  : 'The share sheet could not be opened.',
                            );
                          }
                        }),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Export opens Share / save so you choose where the archive goes.',
            style: AetherType.caption,
          ),
          const SizedBox(height: 16),
          SettingsActionButton(
            label: 'Import backup…',
            icon: Icons.file_upload_outlined,
            onPressed: _busy ? null : _import,
          ),
          const SizedBox(height: 8),
          Text(
            'Restore transcript archive as new inactive sessions: Import checks the '
            'archive, shows what it holds, and restores only after you confirm. '
            'Restored transcripts are published atomically for the current account '
            'and never merge into existing chats.',
            style: AetherType.caption,
          ),
          if (!restoreAvailable) ...[
            const SizedBox(height: 8),
            Text(
              'Restore unavailable in this build: the state publisher is not connected. Import only validates and never changes your chats.',
              style: AetherType.caption,
            ),
          ],
          const SizedBox(height: 16),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _busy ? null : _exportJson,
              icon: const Icon(Icons.data_object, size: 18),
              label: const Text('JSON (for other tools)'),
            ),
          ),
          Text(
            'A full JSON dump for other tools. It cannot be restored.',
            style: AetherType.caption,
          ),
          const SizedBox(height: 16),
          AetherCard(
            title: const Text('Export-ready archive'),
            trailing: const AetherPill(label: 'V1', color: Aether.accent),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Transcript-only export: completed text, reasoning and compacted transcript rows. '
                  'It excludes settings, credentials, grants, schedules, tool output, generated images, '
                  'HTML artifacts and running turns. This is not a full app backup.',
                  style: AetherType.body,
                ),
                const SizedBox(height: 10),
                Text(
                  'File summary: regular attachments inside approved app workspace roots only; '
                  '$attLimit MiB each, ${SettingsBackupService.maxAttachments} total. '
                  'Missing, external or oversized files are marked unavailable. '
                  'Archive limit: $mibLimit MiB; transcript manifest: '
                  '${SettingsBackupService.maxManifestBytes ~/ (1024 * 1024)} MiB; '
                  '${SettingsBackupService.maxSessions} sessions / '
                  '${SettingsBackupService.maxMessages} messages.',
                  style: AetherType.bodyMuted,
                ),
                const SizedBox(height: 10),
                Text(
                  'Chat text and attachments may contain secrets you put in them. Their contents are not redacted. '
                  'The export is a ZIP archive with unencrypted stored entries. Modified, compressed or legacy JSON archives cannot be restored.',
                  style: AetherType.bodyMuted,
                ),
              ],
            ),
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(semanticsLabel: '$_operation in progress'),
          ],
          if (_status != null) ...[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              label: 'Backup status: $_status',
              child: SelectableText(_status!, style: AetherType.body),
            ),
          ],
        ],
      ),
    );
  }
}
