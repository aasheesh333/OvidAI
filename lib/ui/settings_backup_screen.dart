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
        setState(() => _status = '$operation failed. No data was changed. $e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() => _run('Export', () async {
    final support = await getApplicationSupportDirectory();
    // Only known attachment roots; never export arbitrary app documents,
    // secure storage, external folders, or a recursively discovered tree.
    final service = SettingsBackupService(
      attachmentRoots: [Directory('${support.path}/workspaces')],
    );
    final bytes = await service.export(List.of(AppState.I.sessions));
    final temp = await getTemporaryDirectory();
    final dir = await temp.createTemp('ovid-backup-');
    final file = File('${dir.path}/ovid-transcripts-v1.zip');
    try {
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      await dir.delete(recursive: true);
      rethrow;
    }
    if (mounted) {
      setState(() {
        _exported = file;
        _status =
            'Export complete. The transcript-only ZIP archive is ready to share or save.';
      });
    }
  });

  Future<void> _import({required bool restore}) =>
      _run(restore ? 'Restore' : 'Validate import', () async {
    // Capture ownership before the picker and all IO: an account handoff while
    // choosing a file must not redirect the import into the next account.
    final publisher = restore ? SettingsActions.restorePublisher : null;
    if (restore && publisher == null) {
      throw StateError('Restore unavailable: no state publisher is connected.');
    }
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
    final service = SettingsBackupService(
      publisher: publisher,
    );
    final temp = await getTemporaryDirectory();
    if (restore) {
      await service.restore(bytes, temp);
      if (mounted) {
        setState(
          () => _status =
              'Restore complete: transcripts restored as new, inactive sessions '
              'in the current account.',
        );
      }
    } else {
      final staged = await service.stage(bytes, temp);
      try {
        if (mounted) {
          setState(
            () => _status =
                'Import validation complete: ${staged.sessions.length} transcript(s), '
                '${staged.attachments.length} portable attachment(s). No data restored.',
          );
        }
      } finally {
        await staged.dispose();
      }
    }
  });

  @override
  Widget build(BuildContext context) {
    final restoreAvailable = SettingsActions.restorePublisher != null;
    final mibLimit = SettingsBackupService.maxArchiveBytes ~/ (1024 * 1024);
    final attLimit =
        SettingsBackupService.maxAttachmentBytes ~/ (1024 * 1024);
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: kToolbarHeight * (MediaQuery.textScalerOf(context).scale(20) / 20),
        title: const Text('Portable transcript backup'),
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
            liveRegion: true,
            label: 'Backup status: ${_busy ? '$_operation in progress' : _exported != null ? 'Archive ready to share' : 'Ready to export'}',
            child: Text(
              _busy
                  ? '$_operation in progress…'
                  : _exported != null
                  ? 'Archive ready to share'
                  : 'Ready to export',
              style: AetherType.label,
            ),
          ),
          const SizedBox(height: 12),
          AetherCard(
            title: const Text('Export-ready archive'),
            trailing: const AetherPill(
              label: 'V1',
              color: Aether.accent,
            ),
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
          const SizedBox(height: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsActionButton(
                label: 'Export',
                icon: Icons.file_download_outlined,
                primary: true,
                onPressed: _busy ? null : _export,
              ),
              const SizedBox(height: 8),
              SettingsActionButton(
                label: 'Import',
                icon: Icons.file_upload_outlined,
                onPressed: _busy ? null : () => _import(restore: false),
              ),
              const SizedBox(height: 8),
              Text('Import validates an archive without changing your chats.',
                style: AetherType.caption),
              const SizedBox(height: 8),
              Text(
                'Restore transcript archive as new inactive sessions: transcript-only data '
                'is published atomically for the current account. It never merges into existing chats.',
                style: AetherType.caption,
              ),
              const SizedBox(height: 8),
              SettingsActionButton(
                label: 'Share archive',
                icon: Icons.share_outlined,
                onPressed: _busy || _exported == null
                    ? null
                    : () => _run('Share', () async {
                        await NativeShare.file(_exported!.path);
                        if (mounted) {
                          setState(
                            () => _status =
                                'Share sheet opened. Choose a destination to save the archive.',
                          );
                        }
                      }),
              ),
              const SizedBox(height: 8),
              Text('Share archive opens Share / save for the archive you just exported.',
                style: AetherType.caption),
            ],
          ),
          const SizedBox(height: 12),
          SettingsActionButton(
            label: 'Restore as new sessions',
            icon: Icons.restore_outlined,
            onPressed: _busy || !restoreAvailable
                ? null
                : () => _import(restore: true),
          ),
          if (!restoreAvailable) ...[
            const SizedBox(height: 8),
            Text(
              'Restore unavailable in this build: the atomic state publisher is not connected. Validation never changes your chats.',
              style: AetherType.caption,
            ),
          ],
          if (_busy) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              semanticsLabel: '$_operation in progress',
            ),
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
