import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../settings/memory_page.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

enum V2MemoryFilesStatus { loading, ready, empty, error }

enum V2MemoryFileGroup {
  global('Global'),
  project('Project'),
  session('Session');

  const V2MemoryFileGroup(this.label);

  final String label;
}

/// One memory file Ovid keeps for the user.
@immutable
class V2MemoryFileEntry {
  const V2MemoryFileEntry({
    required this.id,
    required this.name,
    required this.group,
    required this.sizeLabel,
    required this.updatedLabel,
    required this.preview,
    this.content = '',
  });

  final String id;
  final String name;
  final V2MemoryFileGroup group;
  final String sizeLabel;
  final String updatedLabel;
  final String preview;

  /// Editable body of the file, shown in the editor sheet.
  final String content;

  /// Scope, size and last update, for the row and its screen-reader label.
  String get metaLabel {
    final parts = <String>[group.label, sizeLabel];
    if (updatedLabel.isNotEmpty) parts.add('Updated $updatedLabel');
    return parts.join(' · ');
  }

  String get semanticsLabel {
    final parts = <String>[name, metaLabel];
    if (preview.isNotEmpty) parts.add(preview);
    return parts.join(', ');
  }
}

/// Saves an edited memory file. [content] is the full new body.
typedef V2MemoryFileSave = void Function(String id, String content);

/// Injected state for the Memory files screen.
@immutable
class V2MemoryFilesPageData {
  const V2MemoryFilesPageData({
    this.status = V2MemoryFilesStatus.ready,
    this.files = const <V2MemoryFileEntry>[],
    this.totalSizeLabel = '0 KB',
    this.onOpen,
    this.onSave,
    this.onDelete,
    this.onExportAll,
    this.onRetry,
    this.errorMessage = 'We could not load your memory files.',
  });

  final V2MemoryFilesStatus status;
  final List<V2MemoryFileEntry> files;
  final String totalSizeLabel;

  /// Opens a file read-only. Used as the fallback when [onSave] is missing.
  final ValueChanged<String>? onOpen;

  /// Persists an edited file. When set, tapping a row opens the editor.
  final V2MemoryFileSave? onSave;
  final ValueChanged<String>? onDelete;
  final VoidCallback? onExportAll;
  final VoidCallback? onRetry;
  final String errorMessage;
}

/// Memory files: one list, one scope filter and one delete per row — the same
/// shape as Memory and Shared memory.
class MemoryFilesPage extends StatefulWidget {
  const MemoryFilesPage({super.key, required this.data});

  final V2MemoryFilesPageData data;

  @override
  State<MemoryFilesPage> createState() => _MemoryFilesPageState();
}

class _MemoryFilesPageState extends State<MemoryFilesPage> {
  /// null means "All". Selecting a group really filters the list below.
  V2MemoryFileGroup? _filter;

  V2MemoryFilesPageData get data => widget.data;

  List<V2MemoryFileEntry> get _visibleFiles => _filter == null
      ? data.files
      : data.files.where((file) => file.group == _filter).toList();

  @override
  Widget build(BuildContext context) {
    // Title-only header: Memory, Memory files and Shared memory share one
    // chrome, with the single action at the bottom.
    return OScreen(title: 'Memory files', child: _body(context));
  }

  Widget _body(BuildContext context) {
    if (data.status == V2MemoryFilesStatus.loading) {
      return const OSkeletonList(rows: 7);
    }
    if (data.status == V2MemoryFilesStatus.error) {
      return OErrorState(message: data.errorMessage, onRetry: data.onRetry);
    }
    if (data.status == V2MemoryFilesStatus.empty || data.files.isEmpty) {
      return OEmptyState(
        icon: Icons.folder_open_rounded,
        title: 'No memory files yet',
        message: 'Ovid saves notes here as you chat.',
        action: data.onRetry == null
            ? null
            : OButton(
                label: 'Refresh',
                icon: Icons.refresh_rounded,
                onPressed: data.onRetry,
              ),
      );
    }

    final c = OColors.of(context);
    final files = _visibleFiles;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _scopeFilter(),
          const SizedBox(height: OSpace.s),
          if (files.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: OSpace.m),
              child: Text(
                'No files in this scope',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            OCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < files.length; i++) ...[
                    if (i > 0) Divider(color: c.hairline, height: 1),
                    _fileRow(context, files[i]),
                  ],
                ],
              ),
            ),
          if (data.onExportAll != null) ...[
            const SizedBox(height: OSpace.l),
            OButton(
              key: const ValueKey<String>('memory-files-export'),
              label: 'Export all',
              icon: Icons.download_rounded,
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: data.onExportAll,
            ),
          ],
        ],
      ),
    );
  }

  /// Filter chips for the three scopes. `All` clears the filter.
  Widget _scopeFilter() {
    return V2MemoryScopeBar(
      keyPrefix: 'memory-files-filter',
      labels: [
        'All',
        for (final group in V2MemoryFileGroup.values) group.label,
      ],
      selected: _filter == null ? 0 : _filter!.index + 1,
      onSelected: (index) => setState(
        () => _filter = index == 0 ? null : V2MemoryFileGroup.values[index - 1],
      ),
    );
  }

  Widget _fileRow(BuildContext context, V2MemoryFileEntry file) {
    final canActivate =
        data.onSave != null || data.onOpen != null || _hasContent(file);
    return OListRow(
      key: ValueKey<String>('memory-file-${file.id}'),
      icon: _groupIcon(file.group),
      title: file.name,
      subtitle: file.metaLabel,
      showChevron: false,
      enabled: canActivate,
      onTap: canActivate ? () => _activate(context, file) : null,
      trailing: data.onDelete == null
          ? null
          : OIconButton(
              key: ValueKey<String>('memory-file-delete-${file.id}'),
              icon: Icons.delete_outline_rounded,
              semanticLabel: 'Delete ${file.name}',
              tooltip: 'Delete',
              onPressed: () => _confirmDelete(context, file),
            ),
    );
  }

  void _activate(BuildContext context, V2MemoryFileEntry file) {
    if (data.onSave != null) {
      _openEditor(context, file);
      return;
    }
    if (data.onOpen != null) {
      data.onOpen!.call(file.id);
      return;
    }
    _openViewer(context, file);
  }

  bool _hasContent(V2MemoryFileEntry file) =>
      file.content.trim().isNotEmpty || file.preview.trim().isNotEmpty;

  /// Read-only viewer for a file the caller did not route elsewhere.
  Future<void> _openViewer(BuildContext context, V2MemoryFileEntry file) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: OColors.of(context).surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ORadius.xl)),
      ),
      builder: (_) =>
          _MemoryFileViewer(file: file, canDelete: data.onDelete != null),
    );
    if (action == 'delete' && context.mounted) {
      await _confirmDelete(context, file);
    }
  }

  Future<void> _openEditor(BuildContext context, V2MemoryFileEntry file) async {
    final content = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: OColors.of(context).surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ORadius.xl)),
      ),
      builder: (_) => _MemoryFileEditor(file: file),
    );
    if (content != null) {
      data.onSave?.call(file.id, content);
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    V2MemoryFileEntry file,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final dialogColors = OColors.of(context);
        return AlertDialog(
          backgroundColor: dialogColors.surface,
          title: Text(
            'Delete this memory file?',
            style: OType.h2.copyWith(color: dialogColors.text),
          ),
          content: Text(
            'This removes ${file.name} from Ovid\'s memory. '
            'This cannot be undone.',
            style: OType.bodySm.copyWith(color: dialogColors.textMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: TextButton.styleFrom(foregroundColor: dialogColors.danger),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      data.onDelete?.call(file.id);
    }
  }

  IconData _groupIcon(V2MemoryFileGroup group) {
    return switch (group) {
      V2MemoryFileGroup.global => Icons.public_rounded,
      V2MemoryFileGroup.project => Icons.folder_outlined,
      V2MemoryFileGroup.session => Icons.forum_outlined,
    };
  }
}

/// Read-only sheet for one memory file. Shows the stored body and, when the
/// caller wired it, a Delete action that pops `'delete'`.
class _MemoryFileViewer extends StatelessWidget {
  const _MemoryFileViewer({required this.file, required this.canDelete});

  final V2MemoryFileEntry file;
  final bool canDelete;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final body = file.content.trim().isEmpty ? file.preview : file.content;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(OSpace.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  file.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.h2.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  file.metaLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.m),
                Container(
                  key: const ValueKey<String>('memory-file-viewer-content'),
                  padding: const EdgeInsets.all(OSpace.m),
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(ORadius.m),
                    border: Border.all(color: c.hairline),
                  ),
                  child: SelectableText(
                    body.isEmpty ? 'This file is empty.' : body,
                    style: OType.bodySm.copyWith(color: c.text),
                  ),
                ),
                const SizedBox(height: OSpace.m),
                OButton(
                  key: const ValueKey<String>('memory-file-viewer-close'),
                  label: 'Close',
                  variant: OButtonVariant.secondary,
                  expand: true,
                  onPressed: () => Navigator.pop(context),
                ),
                if (canDelete) ...[
                  const SizedBox(height: OSpace.s),
                  OButton(
                    key: const ValueKey<String>('memory-file-viewer-delete'),
                    label: 'Delete',
                    icon: Icons.delete_outline_rounded,
                    variant: OButtonVariant.danger,
                    expand: true,
                    onPressed: () => Navigator.pop(context, 'delete'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Editor sheet for one memory file. Owns its controller so it is disposed
/// with the route, not while the sheet is still animating out.
class _MemoryFileEditor extends StatefulWidget {
  const _MemoryFileEditor({required this.file});

  final V2MemoryFileEntry file;

  @override
  State<_MemoryFileEditor> createState() => _MemoryFileEditorState();
}

class _MemoryFileEditorState extends State<_MemoryFileEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.file.content,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final file = widget.file;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.9,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(OSpace.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Edit memory file',
                  style: OType.h2.copyWith(color: c.text),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  '${file.name} · ${file.group.label}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: OSpace.m),
                TextField(
                  key: const ValueKey<String>('memory-file-editor-field'),
                  controller: _controller,
                  minLines: 6,
                  maxLines: 12,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  style: OType.bodySm.copyWith(color: c.text),
                  decoration: InputDecoration(
                    hintText: 'Write what Ovid should remember…',
                    hintStyle: OType.bodySm.copyWith(color: c.textFaint),
                    filled: true,
                    fillColor: c.surfaceAlt,
                    contentPadding: const EdgeInsets.all(OSpace.m),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(ORadius.m),
                      borderSide: BorderSide(color: c.hairline),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(ORadius.m),
                      borderSide: BorderSide(color: c.hairline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(ORadius.m),
                      borderSide: BorderSide(color: c.accentFill),
                    ),
                  ),
                ),
                const SizedBox(height: OSpace.m),
                Row(
                  children: [
                    Expanded(
                      child: OButton(
                        label: 'Cancel',
                        variant: OButtonVariant.secondary,
                        onPressed: () => Navigator.pop(context),
                      ),
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: OButton(
                        label: 'Save',
                        icon: Icons.check_rounded,
                        onPressed: () =>
                            Navigator.pop(context, _controller.text),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
