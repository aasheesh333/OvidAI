import 'package:flutter/material.dart';

import '../core/cloud/studio_files.dart';
import '../core/cloud/studio_remote_client.dart';
import '../core/theme.dart';
import 'studio_errors.dart';
import 'studio_layout.dart';

// ── Studio file management (ST-005, ST-008) ─────────────────────────────────
// New file / new folder / rename / delete, shared by the tree's row menu and
// header and the editor's "+" so every entry point validates and confirms the
// same way. Every action runs against the cloud workspace; nothing is local.

String _leafOf(String path) => path.substring(path.lastIndexOf('/') + 1);

/// Asks for a workspace path with inline validation. Returns the normalised
/// path, or null when cancelled.
Future<String?> promptStudioPath(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initial = '',
  String hint = 'path/to/file.txt',
  bool folder = false,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _StudioPathDialog(
        title: title,
        confirmLabel: confirmLabel,
        initial: initial,
        hint: hint,
        folder: folder,
      ),
    );

/// Owns its text controller: disposing it right after `showDialog` returned
/// crashed the dialog's exit animation ("controller used after dispose").
class _StudioPathDialog extends StatefulWidget {
  const _StudioPathDialog({
    required this.title,
    required this.confirmLabel,
    required this.initial,
    required this.hint,
    required this.folder,
  });

  final String title;
  final String confirmLabel;
  final String initial;
  final String hint;
  final bool folder;

  @override
  State<_StudioPathDialog> createState() => _StudioPathDialogState();
}

class _StudioPathDialogState extends State<_StudioPathDialog> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _ctrl = TextEditingController(text: initial)
      ..selection = TextSelection(
        baseOffset: initial.contains('/') ? initial.lastIndexOf('/') + 1 : 0,
        extentOffset: initial.contains('.') && !widget.folder
            ? initial.lastIndexOf('.')
            : initial.length,
      );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final normalized =
        normalizeStudioPath(_ctrl.text, allowTrailingSlash: widget.folder);
    if (normalized == null) {
      setState(() => _error = _ctrl.text.trim().isEmpty
          ? 'Enter a name.'
          : 'Use a relative path like src/app.dart — no leading "/" and '
              'no "..".');
      return;
    }
    Navigator.pop(context, normalized);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title, style: const TextStyle(fontSize: 16)),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        // It is a path in a code workspace — no autocorrect/suggestions.
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.done,
        style: const TextStyle(
          fontFamily: Aether.mono,
          fontFamilyFallback: kStudioMonoFallback,
          fontSize: 14,
        ),
        decoration: InputDecoration(
          hintText: widget.hint,
          errorText: _error,
          errorMaxLines: 3,
          isDense: true,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

/// "New file" (ST-005): never wipes a draft, never opens an existing server
/// file as empty, and the first save of a genuinely new file is create-only.
Future<void> studioNewFile(BuildContext context, String key,
    {String inFolder = ''}) async {
  final path = await promptStudioPath(
    context,
    title: 'New file',
    confirmLabel: 'Create',
    initial: inFolder.isEmpty ? '' : '$inFolder/',
  );
  if (path == null || !context.mounted) return;
  try {
    final outcome = await StudioRemoteClient.I.newStudioFile(key, path);
    if (!context.mounted) return;
    switch (outcome) {
      case StudioNewFileOutcome.openedExisting:
        showStudioToast(context, '${_leafOf(path)} already exists — opened it.');
      case StudioNewFileOutcome.isFolder:
        showStudioToast(context, '$path is a folder.', error: true);
      case StudioNewFileOutcome.invalid:
        showStudioToast(context, 'That name cannot be used.', error: true);
      case StudioNewFileOutcome.created:
        break;
    }
  } catch (error) {
    if (context.mounted) {
      showStudioToast(context, StudioFailure.messageOf(error), error: true);
    }
  }
}

/// "New folder" (ST-008).
Future<void> studioNewFolder(BuildContext context, String key,
    {String inFolder = ''}) async {
  final path = await promptStudioPath(
    context,
    title: 'New folder',
    confirmLabel: 'Create',
    initial: inFolder.isEmpty ? '' : '$inFolder/',
    hint: 'path/to/folder',
    folder: true,
  );
  if (path == null || !context.mounted) return;
  try {
    await StudioRemoteClient.I.createStudioFolder(key, path);
    if (context.mounted) showStudioToast(context, 'Created $path');
  } catch (error) {
    if (context.mounted) {
      showStudioToast(context, StudioFailure.messageOf(error), error: true);
    }
  }
}

/// Rename / move (ST-008). Open tabs and drafts follow the file.
Future<void> studioRename(BuildContext context, String key, String path,
    {required bool isFolder}) async {
  final target = await promptStudioPath(
    context,
    title: isFolder ? 'Rename folder' : 'Rename file',
    confirmLabel: 'Rename',
    initial: path,
    hint: isFolder ? 'path/to/folder' : 'path/to/file.txt',
    folder: isFolder,
  );
  if (target == null || target == path || !context.mounted) return;
  try {
    await StudioRemoteClient.I.renameStudioPath(key, path, target);
    if (context.mounted) {
      showStudioToast(context, 'Renamed to ${_leafOf(target)}');
    }
  } catch (error) {
    if (context.mounted) {
      showStudioToast(context, StudioFailure.messageOf(error), error: true);
    }
  }
}

/// Delete with a confirmation that names what is lost (ST-008).
Future<void> studioDelete(BuildContext context, String key, String path,
    {required bool isFolder}) async {
  final remote = StudioRemoteClient.I;
  final drafts = remote.dirtyFilesUnder(key, path);
  final name = _leafOf(path);
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(
        isFolder ? 'Delete folder $name?' : 'Delete $name?',
        style: const TextStyle(fontSize: 16),
      ),
      content: Text(
        [
          isFolder
              ? 'The folder and everything in it are removed from your cloud '
                  'workspace, for every chat and for the agent.'
              : 'The file is removed from your cloud workspace, for every '
                  'chat and for the agent.',
          if (drafts.isNotEmpty)
            drafts.length == 1
                ? 'Your unsaved changes to ${_leafOf(drafts.single)} will be lost.'
                : 'Unsaved changes in ${drafts.length} files will be lost.',
          'This cannot be undone.',
        ].join('\n\n'),
        style: const TextStyle(fontSize: 14),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, true),
          child: Text('Delete', style: TextStyle(color: Aether.danger)),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    await remote.deleteStudioPath(key, path, isFolder: isFolder);
    if (context.mounted) showStudioToast(context, 'Deleted $name');
  } catch (error) {
    if (context.mounted) {
      showStudioToast(context, StudioFailure.messageOf(error), error: true);
    }
  }
}

/// The long-press / secondary-click menu of a tree row.
Future<void> showStudioPathActions(
  BuildContext context,
  String key, {
  required String path,
  required bool isFolder,
}) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Aether.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(studioSheetRadius)),
    ),
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Text(
              path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: Aether.mono,
                fontFamilyFallback: kStudioMonoFallback,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (isFolder) ...[
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: const Text('New file here'),
              onTap: () => Navigator.pop(sheet, 'new-file'),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder here'),
              onTap: () => Navigator.pop(sheet, 'new-folder'),
            ),
          ],
          ListTile(
            leading: const Icon(Icons.drive_file_rename_outline),
            title: const Text('Rename or move'),
            onTap: () => Navigator.pop(sheet, 'rename'),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Aether.danger),
            title: Text('Delete', style: TextStyle(color: Aether.danger)),
            onTap: () => Navigator.pop(sheet, 'delete'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case 'new-file':
      await studioNewFile(context, key, inFolder: path);
    case 'new-folder':
      await studioNewFolder(context, key, inFolder: path);
    case 'rename':
      await studioRename(context, key, path, isFolder: isFolder);
    case 'delete':
      await studioDelete(context, key, path, isFolder: isFolder);
  }
}
