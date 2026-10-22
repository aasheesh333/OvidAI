import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/cloud/account_settings_client.dart';
import '../../../core/cloud/cloud_rest.dart';
import '../../../core/cloud/projects.dart';
import '../../../core/native_share.dart';
import '../../../core/state.dart';
import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../settings/settings_rows.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

enum V2MemoryFilesStatus { loading, ready, empty, error }

/// The three real scopes the memory API keeps files in.
///
/// `global` is the shared scope (`GET /memory` answers `scope: "shared"`),
/// `project` is `GET /projects/:id/memory`, and `session` is the per-chat
/// scope of `GET /memory`. [slug] is stable for widget keys and tests.
enum V2MemoryFileGroup {
  global('Global', 'global'),
  project('Project', 'project'),
  session('Chat', 'chat');

  const V2MemoryFileGroup(this.label, this.slug);

  final String label;
  final String slug;
}

/// One memory file Ovid keeps for the user.
@immutable
class V2MemoryFileEntry {
  const V2MemoryFileEntry({
    required this.id,
    required this.name,
    required this.group,
    required this.sizeLabel,
    this.sizeBytes = 0,
    this.updatedLabel = '',
    this.preview = '',
    this.content = '',
    this.revision = '',
    this.projectId,
  });

  /// Stable across a reload: the scope, the project and the file name.
  final String id;
  final String name;
  final V2MemoryFileGroup group;
  final String sizeLabel;
  final int sizeBytes;

  /// Kept for callers that already have a timestamp. The service does not
  /// return one, so the row does not render it.
  final String updatedLabel;
  final String preview;

  /// Editable body of the file, when the caller already loaded it.
  final String content;

  /// Server revision (`sha256`), sent back on save to prevent lost updates.
  final String revision;

  /// Set for project files; the project read/write routes need it.
  final String? projectId;

  /// Scope and size — one meta line, exactly what the row can prove.
  String get metaLabel =>
      sizeLabel.isEmpty ? group.label : '${group.label} · $sizeLabel';

  /// What a screen reader hears for the row: name, scope and size.
  String get semanticsLabel {
    final size = sizeLabel.isEmpty ? 'size unknown' : sizeLabel;
    return '$name, ${group.label} file, $size';
  }

  V2MemoryFileEntry copyWith({
    String? content,
    String? sizeLabel,
    int? sizeBytes,
    String? revision,
  }) {
    return V2MemoryFileEntry(
      id: id,
      name: name,
      group: group,
      sizeLabel: sizeLabel ?? this.sizeLabel,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      updatedLabel: updatedLabel,
      preview: preview,
      content: content ?? this.content,
      revision: revision ?? this.revision,
      projectId: projectId,
    );
  }
}

/// A memory document as the service returned it.
@immutable
class V2MemoryFileDocument {
  const V2MemoryFileDocument({required this.content, this.revision = ''});

  final String content;
  final String revision;
}

/// What one "Export all" produced, in the caller's own words.
@immutable
class V2MemoryFilesExportOutcome {
  const V2MemoryFilesExportOutcome({required this.message, this.path});

  /// Already user-facing and within the toast budget.
  final String message;

  /// The archive the share sheet received, when the export wrote one.
  final String? path;
}

/// Reads one file's body. Implementations must hit the real service.
typedef V2MemoryFileRead = Future<V2MemoryFileDocument> Function(
  V2MemoryFileEntry file,
);

/// Saves a body and returns the server's new revision.
typedef V2MemoryFileSave = Future<String> Function(
  V2MemoryFileEntry file,
  String content,
  String revision,
);

/// Builds the archive and reports the real outcome.
typedef V2MemoryFilesExport = Future<V2MemoryFilesExportOutcome> Function(
  List<V2MemoryFileEntry> files,
);

/// Injected state for the Memory files screen.
@immutable
class V2MemoryFilesPageData {
  const V2MemoryFilesPageData({
    this.status = V2MemoryFilesStatus.ready,
    this.files = const <V2MemoryFileEntry>[],
    this.totalSizeLabel = '',
    this.onOpen,
    this.onRead,
    this.onSave,
    this.onDelete,
    this.onExport,
    this.onExportAll,
    this.onRetry,
    this.errorMessage = 'We could not load your memory files.',
  });

  final V2MemoryFilesStatus status;
  final List<V2MemoryFileEntry> files;

  /// Total bytes across the scopes, when the caller measured it. The screen
  /// does not render a second total line; it is kept for callers that do.
  final String totalSizeLabel;

  /// Opens a file in the caller's own viewer. Used only when the page has no
  /// [onRead] handler; the page's viewer is the richer path.
  final ValueChanged<String>? onOpen;

  /// Reads the real body. When set, tapping a row opens the page's viewer.
  final V2MemoryFileRead? onRead;

  /// Persists an edited body. When set, the viewer offers Edit and the page
  /// owns the saving and rollback states.
  final V2MemoryFileSave? onSave;

  /// Deletes one file by id. The page asks for confirmation first.
  final ValueChanged<String>? onDelete;

  /// Exports every file as a real archive and reports what happened.
  final V2MemoryFilesExport? onExport;

  /// Legacy synchronous export. Kept so the existing loader still compiles;
  /// the page does not render it because a void callback cannot report whether
  /// an archive was produced. Mount [MemoryFilesPage.live] or pass [onExport].
  final VoidCallback? onExportAll;

  final VoidCallback? onRetry;
  final String errorMessage;

  /// A real archive path must be able to report its outcome.
  bool get canExport => onExport != null;
}

/// Memory files: one list, one scope filter with real counts, and one action.
///
/// Presentational by default: every read, write, delete and export leaves
/// through a callback. Use [MemoryFilesPage.live] to mount the same screen on
/// the real `/memory` and `/projects/:id/memory` services.
class MemoryFilesPage extends StatefulWidget {
  const MemoryFilesPage({super.key, required this.data})
    : source = null;

  /// Mounts the screen on the real services.
  const MemoryFilesPage.live({super.key, this.source}) : data = null;

  final V2MemoryFilesPageData? data;

  /// Overrides the production service in tests.
  final V2MemoryFilesSource? source;

  @override
  State<MemoryFilesPage> createState() => _MemoryFilesPageState();
}

class _MemoryFilesPageState extends State<MemoryFilesPage> {
  V2MemoryFilesSource? _source;
  List<V2MemoryFileEntry> _liveFiles = const <V2MemoryFileEntry>[];
  V2MemoryFilesStatus _liveStatus = V2MemoryFilesStatus.loading;
  String? _liveError;

  @override
  void initState() {
    super.initState();
    if (widget.data == null) {
      _source = widget.source ?? V2MemoryFilesService();
      unawaited(_reload());
    }
  }

  Future<void> _reload() async {
    final source = _source;
    if (source == null) return;
    if (mounted) {
      setState(() {
        _liveStatus = V2MemoryFilesStatus.loading;
        _liveError = null;
      });
    }
    try {
      final files = await source.list();
      if (!mounted) return;
      setState(() {
        _liveFiles = files;
        _liveStatus = files.isEmpty
            ? V2MemoryFilesStatus.empty
            : V2MemoryFilesStatus.ready;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _liveStatus = V2MemoryFilesStatus.error;
        _liveError = 'We could not load your memory files.';
      });
    }
  }

  Future<void> _delete(V2MemoryFileEntry file) async {
    final source = _source;
    if (source == null) return;
    try {
      await source.delete(file);
      await _reload();
    } catch (_) {
      if (!mounted) return;
      showOSnack(context, 'Could not delete that file.');
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (data != null) return _MemoryFilesView(data: data);
    final source = _source;
    return _MemoryFilesView(
      data: V2MemoryFilesPageData(
        status: _liveStatus,
        files: _liveFiles,
        errorMessage: _liveError ?? 'We could not load your memory files.',
        onRead: source?.read,
        onSave: source == null
            ? null
            : (file, content, revision) =>
                  source.save(file, content, revision: revision),
        onDelete: source == null
            ? null
            : (id) {
                final file = _liveFiles.where((f) => f.id == id).firstOrNull;
                if (file != null) unawaited(_delete(file));
              },
        onExport: source?.export,
        onRetry: _reload,
      ),
    );
  }
}

class _MemoryFilesView extends StatefulWidget {
  const _MemoryFilesView({required this.data});

  final V2MemoryFilesPageData data;

  @override
  State<_MemoryFilesView> createState() => _MemoryFilesViewState();
}

class _MemoryFilesViewState extends State<_MemoryFilesView> {
  /// null means "All". Selecting a group really filters the list below.
  V2MemoryFileGroup? _filter;

  /// Working copy: a successful save updates the size in place, a failed save
  /// restores the previous entry, and a delete removes it before the reload.
  late List<V2MemoryFileEntry> _files = [...widget.data.files];

  bool _exporting = false;

  V2MemoryFilesPageData get data => widget.data;

  List<V2MemoryFileEntry> get _visibleFiles => _filter == null
      ? _files
      : _files.where((file) => file.group == _filter).toList();

  @override
  void didUpdateWidget(covariant _MemoryFilesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A parent rebuild is the source of truth: a delete that failed server-side
    // reappears instead of staying hidden.
    if (!identical(oldWidget.data, widget.data)) {
      _files = [...widget.data.files];
    }
  }

  int _count(V2MemoryFileGroup group) =>
      _files.where((file) => file.group == group).length;

  @override
  Widget build(BuildContext context) {
    // One header, one title, no second heading in the body.
    return OScreen(
      title: 'Memory files',
      maxWidth: 640,
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.status == V2MemoryFilesStatus.loading) {
      return const OSkeletonList(rows: 7);
    }
    if (data.status == V2MemoryFilesStatus.error) {
      return OErrorState(message: data.errorMessage, onRetry: data.onRetry);
    }
    if (data.status == V2MemoryFilesStatus.empty || _files.isEmpty) {
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

    final files = _visibleFiles;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.s),
          sliver: SliverToBoxAdapter(child: _scopeFilter(context)),
        ),
        if (files.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: OSpace.m),
              child: Text(
                'No files in this scope',
                style: OType.bodySm.copyWith(color: OColors.of(context).textMuted),
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: files.length,
            itemBuilder: (context, index) {
              final file = files[index];
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (index > 0)
                    Divider(
                      height: 1,
                      thickness: 1,
                      indent: v2SettingsRowDividerIndent,
                      color: OColors.of(context).hairline,
                    ),
                  _fileRow(context, file),
                ],
              );
            },
          ),
        if (data.canExport)
          SliverPadding(
            padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
            sliver: SliverToBoxAdapter(
              child: OButton(
                key: const ValueKey<String>('memory-files-export'),
                label: _exporting ? 'Exporting…' : 'Export all',
                icon: Icons.download_rounded,
                variant: OButtonVariant.secondary,
                expand: true,
                loading: _exporting,
                semanticLabel: 'Export all memory files',
                onPressed: _exporting ? null : () => _export(context),
              ),
            ),
          )
        else
          const SliverToBoxAdapter(child: SizedBox(height: OSpace.xxl)),
      ],
    );
  }

  /// Filter chips for the three real scopes, with the counts they actually
  /// hold. `All` clears the filter; a zero count is shown, never hidden.
  Widget _scopeFilter(BuildContext context) {
    final entries = <({String label, V2MemoryFileGroup? group, int count})>[
      (label: 'All', group: null, count: _files.length),
      for (final group in V2MemoryFileGroup.values)
        (label: group.label, group: group, count: _count(group)),
    ];
    return Wrap(
      spacing: OSpace.s,
      runSpacing: OSpace.s,
      children: [
        for (final entry in entries)
          OChip(
            key: ValueKey<String>(
              'memory-files-filter-${entry.group?.slug ?? 'all'}',
            ),
            label: '${entry.label} ${entry.count}',
            selected: _filter == entry.group,
            semanticLabel:
                '${entry.label}, ${entry.count} '
                '${entry.count == 1 ? 'file' : 'files'}',
            onTap: () => setState(() => _filter = entry.group),
          ),
      ],
    );
  }

  Widget _fileRow(BuildContext context, V2MemoryFileEntry file) {
    final canActivate = _canActivate(file);
    return V2SettingsRow(
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

  bool _canActivate(V2MemoryFileEntry file) =>
      data.onRead != null ||
      data.onSave != null ||
      data.onOpen != null ||
      _contentOf(file).trim().isNotEmpty;

  String _contentOf(V2MemoryFileEntry file) =>
      file.content.trim().isNotEmpty ? file.content : file.preview;

  void _activate(BuildContext context, V2MemoryFileEntry file) {
    if (data.onRead != null) {
      _openViewer(context, file);
      return;
    }
    // Never seed an editor with a preview snippet: saving would overwrite the
    // real file with the snippet. Editing needs the loaded body or a reader.
    if (data.onSave != null && file.content.trim().isNotEmpty) {
      _openEditor(context, file);
      return;
    }
    if (data.onOpen != null) {
      data.onOpen!.call(file.id);
      return;
    }
    _openViewer(context, file);
  }

  /// The page's viewer: real content, loading and error states, read-only
  /// unless a save handler exists.
  Future<void> _openViewer(
    BuildContext context,
    V2MemoryFileEntry file,
  ) async {
    final result = await showOSheet<_ViewerResult>(
      context,
      builder: (_) => _MemoryFileViewer(
        file: file,
        // With a real reader the service is the source of truth; a cached
        // body would only be a stale copy.
        initialContent: data.onRead == null ? _contentOf(file) : '',
        onRead: data.onRead,
        canEdit:
            data.onSave != null &&
            (data.onRead != null || file.content.trim().isNotEmpty),
        canDelete: data.onDelete != null,
      ),
    );
    if (!context.mounted || result == null) return;
    switch (result.action) {
      case 'delete':
        await _confirmDelete(context, file);
      case 'edit':
        await _openEditor(
          context,
          file,
          seed: result.content,
          revision: result.revision,
        );
    }
  }

  Future<void> _openEditor(
    BuildContext context,
    V2MemoryFileEntry file, {
    String? seed,
    String? revision,
  }) async {
    if (data.onSave == null) return;
    final result = await showOSheet<_EditorResult>(
      context,
      builder: (_) => _MemoryFileEditor(
        file: file,
        initialContent: seed ?? _contentOf(file),
        initialRevision: revision ?? file.revision,
        onSave: (content, currentRevision) =>
            _saveFile(file, content, currentRevision),
      ),
    );
    if (!mounted || result == null) return;
    // [_saveFile] already applied the revision; nothing else to commit.
  }

  /// Optimistically shows the new body, then rolls the row back when the
  /// handler throws. The editor stays open on failure, so the typed text is
  /// never lost either.
  Future<String> _saveFile(
    V2MemoryFileEntry file,
    String content,
    String revision,
  ) async {
    final save = data.onSave;
    if (save == null) return revision;
    final index = _files.indexWhere((entry) => entry.id == file.id);
    final previous = index >= 0 ? _files[index] : file;
    final bytes = utf8.encode(content).length;
    if (index >= 0) {
      setState(() {
        _files[index] = previous.copyWith(
          content: content,
          sizeLabel: _formatBytes(bytes),
          sizeBytes: bytes,
        );
      });
    }
    try {
      final nextRevision = await save(file, content, revision);
      if (mounted) {
        final at = _files.indexWhere((entry) => entry.id == file.id);
        if (at >= 0) {
          setState(() {
            _files[at] = _files[at].copyWith(
              content: content,
              revision: nextRevision,
            );
          });
        }
      }
      return nextRevision;
    } catch (_) {
      if (mounted) {
        final at = _files.indexWhere((entry) => entry.id == file.id);
        if (at >= 0) setState(() => _files[at] = previous);
      }
      rethrow;
    }
  }

  Future<void> _export(BuildContext context) async {
    if (_exporting) return;
    final export = data.onExport;
    if (export == null) return;
    setState(() => _exporting = true);
    try {
      final outcome = await export(List<V2MemoryFileEntry>.unmodifiable(_files));
      if (!context.mounted) return;
      showOSnack(context, outcome.message);
    } catch (_) {
      if (!context.mounted) return;
      showOSnack(context, 'Export failed. Try again.');
    } finally {
      if (context.mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    V2MemoryFileEntry file,
  ) async {
    final delete = data.onDelete;
    if (delete == null) return;
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Delete file?',
      builder: (sheetContext) => _DeleteConfirm(
        fileName: file.name,
        onDelete: () => Navigator.pop<bool>(sheetContext, true),
        onCancel: () => Navigator.pop<bool>(sheetContext, false),
      ),
    );
    if (confirmed != true || !mounted) return;
    delete(file.id);
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
/// caller wired it, an Edit action that pops the loaded body.
class _MemoryFileViewer extends StatefulWidget {
  const _MemoryFileViewer({
    required this.file,
    required this.initialContent,
    required this.onRead,
    required this.canEdit,
    required this.canDelete,
  });

  final V2MemoryFileEntry file;
  final String initialContent;
  final V2MemoryFileRead? onRead;
  final bool canEdit;
  final bool canDelete;

  @override
  State<_MemoryFileViewer> createState() => _MemoryFileViewerState();
}

class _MemoryFileViewerState extends State<_MemoryFileViewer> {
  late String _content = widget.initialContent;
  late String _revision = widget.file.revision;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (_content.trim().isEmpty && widget.onRead != null) {
      _loading = true;
      unawaited(_fetch());
    }
  }

  Future<void> _fetch() async {
    final read = widget.onRead;
    if (read == null) return;
    try {
      final doc = await read(widget.file);
      if (!mounted) return;
      setState(() {
        _content = doc.content;
        _revision = doc.revision;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _failed = false;
    });
    unawaited(_fetch());
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final file = widget.file;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          OSpace.l,
          OSpace.s,
          OSpace.l,
          OSpace.l,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OSheetHeader(
              title: file.name,
              subtitle: file.metaLabel,
              onClose: () => Navigator.pop(context),
              closeLabel: 'Close file',
              padding: EdgeInsets.zero,
            ),
            const SizedBox(height: OSpace.m),
            if (_loading)
              const SizedBox(height: 200, child: OSkeletonList(rows: 3))
            else if (_failed)
              OErrorState(
                message: 'Could not open this file.',
                onRetry: _retry,
              )
            else
              Container(
                key: const ValueKey<String>('memory-file-viewer-content'),
                padding: const EdgeInsets.all(OSpace.m),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                  border: Border.all(color: c.hairline),
                ),
                child: SelectableText(
                  _content.trim().isEmpty ? 'This file is empty.' : _content,
                  style: OType.mono.copyWith(color: c.text, height: 1.5),
                ),
              ),
            const SizedBox(height: OSpace.l),
            if (widget.canEdit) ...[
              OButton(
                key: const ValueKey<String>('memory-file-viewer-edit'),
                label: 'Edit',
                icon: Icons.edit_outlined,
                expand: true,
                onPressed: _loading || _failed
                    ? null
                    : () => Navigator.pop(
                        context,
                        _ViewerResult(
                          'edit',
                          content: _content,
                          revision: _revision,
                        ),
                      ),
              ),
              const SizedBox(height: OSpace.s),
            ],
            OButton(
              key: const ValueKey<String>('memory-file-viewer-close'),
              label: 'Close',
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: () => Navigator.pop(context),
            ),
            if (widget.canDelete) ...[
              const SizedBox(height: OSpace.s),
              OButton(
                key: const ValueKey<String>('memory-file-viewer-delete'),
                label: 'Delete',
                icon: Icons.delete_outline_rounded,
                variant: OButtonVariant.danger,
                expand: true,
                onPressed: () =>
                    Navigator.pop(context, const _ViewerResult('delete')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Editor sheet for one memory file. Owns its controller so it is disposed
/// with the route, not while the sheet is still animating out.
class _MemoryFileEditor extends StatefulWidget {
  const _MemoryFileEditor({
    required this.file,
    required this.initialContent,
    required this.initialRevision,
    required this.onSave,
  });

  final V2MemoryFileEntry file;
  final String initialContent;
  final String initialRevision;
  final Future<String> Function(String content, String revision)? onSave;

  @override
  State<_MemoryFileEditor> createState() => _MemoryFileEditorState();
}

class _MemoryFileEditorState extends State<_MemoryFileEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialContent,
  );

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final save = widget.onSave;
    if (save == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final revision = await save(_controller.text, widget.initialRevision);
      if (!mounted) return;
      Navigator.pop(
        context,
        _EditorResult(content: _controller.text, revision: revision),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _saveError(error);
      });
    }
  }

  String _saveError(Object error) {
    if (error is StateError) return 'Could not save. Try again.';
    if (error is CloudApiException && error.code == 'baseline_mismatch') {
      return 'This file changed. Reopen it.';
    }
    return 'Could not save. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final file = widget.file;
    return PopScope(
      canPop: !_saving,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            OSpace.l,
            OSpace.s,
            OSpace.l,
            OSpace.l,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OSheetHeader(
                title: 'Edit memory file',
                subtitle: '${file.name} · ${file.group.label}',
                onClose: _saving ? null : () => Navigator.pop(context),
                closeLabel: 'Close editor',
                padding: EdgeInsets.zero,
              ),
              const SizedBox(height: OSpace.m),
              TextField(
                key: const ValueKey<String>('memory-file-editor-field'),
                controller: _controller,
                enabled: !_saving,
                minLines: 6,
                maxLines: 12,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                style: OType.mono.copyWith(color: c.text, height: 1.5),
                decoration: InputDecoration(
                  hintText: 'Write what Ovid should remember…',
                  hintStyle: OType.mono.copyWith(color: c.textFaint),
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
              if (_error != null) ...[
                const SizedBox(height: OSpace.m),
                Text(
                  _error!,
                  key: const ValueKey<String>('memory-file-editor-error'),
                  style: OType.bodySm.copyWith(color: c.danger),
                ),
              ],
              const SizedBox(height: OSpace.m),
              Row(
                children: [
                  Expanded(
                    child: OButton(
                      key: const ValueKey<String>('memory-file-editor-cancel'),
                      label: 'Cancel',
                      variant: OButtonVariant.secondary,
                      onPressed: _saving
                          ? null
                          : () => Navigator.pop(context),
                    ),
                  ),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    child: OButton(
                      key: const ValueKey<String>('memory-file-editor-save'),
                      label: _saving ? 'Saving…' : 'Save',
                      icon: Icons.check_rounded,
                      loading: _saving,
                      semanticLabel: _saving
                          ? 'Saving memory file'
                          : 'Save memory file',
                      onPressed: _saving ? null : _save,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Second step of a delete: names the file and the consequence.
class _DeleteConfirm extends StatelessWidget {
  const _DeleteConfirm({
    required this.fileName,
    required this.onDelete,
    required this.onCancel,
  });

  final String fileName;
  final VoidCallback onDelete;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.l, OSpace.s, OSpace.l, OSpace.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '"$fileName" is removed from Ovid\'s memory. This cannot be '
            'undone.',
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.l),
          OButton(
            key: const ValueKey<String>('memory-file-delete-confirm'),
            label: 'Delete',
            icon: Icons.delete_outline_rounded,
            variant: OButtonVariant.dangerFill,
            expand: true,
            onPressed: onDelete,
          ),
          const SizedBox(height: OSpace.s),
          OButton(
            key: const ValueKey<String>('memory-file-delete-cancel'),
            label: 'Keep',
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }
}

@immutable
class _ViewerResult {
  const _ViewerResult(this.action, {this.content = '', this.revision = ''});

  final String action;
  final String content;
  final String revision;
}

@immutable
class _EditorResult {
  const _EditorResult({required this.content, required this.revision});

  final String content;
  final String revision;
}

/// `640 bytes`, `3.2 KB`, `1.0 MB` — the one size format the screen uses.
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// The real memory-file source behind [MemoryFilesPage.live].
///
/// * global / chat: `GET /memory?sessionId=`, read/write/delete with
///   `ifRevision`;
/// * project: `GET /projects/:id/memory` and its read/write/delete routes;
/// * export: one zip of every `.md` file, handed to the share sheet.
///
/// The service returns only names, scopes and sizes the gateway reported. It
/// never invents a `MEMORY.md` or a file for a scope the API did not list.
abstract class V2MemoryFilesSource {
  Future<List<V2MemoryFileEntry>> list();

  Future<V2MemoryFileDocument> read(V2MemoryFileEntry file);

  Future<String> save(
    V2MemoryFileEntry file,
    String content, {
    String revision = '',
  });

  Future<void> delete(V2MemoryFileEntry file);

  Future<V2MemoryFilesExportOutcome> export(List<V2MemoryFileEntry> files);
}

class V2MemoryFilesService implements V2MemoryFilesSource {
  V2MemoryFilesService({
    AccountSettingsClient? client,
    CloudRestClient? rest,
    ProjectsController? projects,
    Future<String?> Function()? sessionId,
  }) : _client = client ?? AccountSettingsClient.I,
       _rest = rest ?? CloudRestClient.I,
       _projects = projects ?? ProjectsController.I,
       _sessionId = sessionId ?? (() async => AppState.I.activeSessionId);

  final AccountSettingsClient _client;
  final CloudRestClient _rest;
  final ProjectsController _projects;
  final Future<String?> Function() _sessionId;

  @override
  Future<List<V2MemoryFileEntry>> list() async {
    final files = <V2MemoryFileEntry>[];

    final sessionId = await _sessionId();
    if (sessionId != null && sessionId.isNotEmpty) {
      final listing = await _client.memoryFiles(sessionId);
      final group = listing.shared
          ? V2MemoryFileGroup.global
          : V2MemoryFileGroup.session;
      for (final file in listing.files) {
        files.add(
          V2MemoryFileEntry(
            id: '${group.slug}:${file.name}',
            name: file.name,
            group: group,
            sizeLabel: _formatBytes(file.sizeBytes),
            sizeBytes: file.sizeBytes,
          ),
        );
      }
    }

    // Re-read the project counts: the cached list may predate files added in
    // another session, and a stale count would hide a real project file.
    await _projects.refresh();
    // A failed project listing would silently drop real files; show the error
    // and let the screen's Retry ask again instead.
    if (_projects.error != null && _projects.projects.isEmpty) {
      throw StateError('Could not load your projects.');
    }
    for (final project in _projects.projects) {
      if (project.fileBreakdown.memory <= 0) continue;
      final json = await _rest.getJson(
        '/projects/${Uri.encodeComponent(project.id)}/memory',
      );
      final items = json['items'];
      if (items is! List) continue;
      for (final item in items) {
        if (item is! Map || item['name'] is! String) continue;
        final name = item['name'] as String;
        final bytes = (item['sizeBytes'] as num?)?.toInt() ?? 0;
        files.add(
          V2MemoryFileEntry(
            id: 'project:${project.id}:$name',
            name: name,
            group: V2MemoryFileGroup.project,
            sizeLabel: _formatBytes(bytes),
            sizeBytes: bytes,
            projectId: project.id,
          ),
        );
      }
    }

    files.sort((a, b) {
      final byGroup = a.group.index.compareTo(b.group.index);
      return byGroup != 0 ? byGroup : a.name.compareTo(b.name);
    });
    return files;
  }

  @override
  Future<V2MemoryFileDocument> read(V2MemoryFileEntry file) async {
    if (file.group == V2MemoryFileGroup.project) {
      final projectId = file.projectId;
      if (projectId == null) throw StateError('Missing project.');
      final json = await _rest.getJson(
        '/projects/${Uri.encodeComponent(projectId)}/memory/'
        '${Uri.encodeComponent(file.name)}',
      );
      return V2MemoryFileDocument(
        content: json['content'] as String? ?? '',
        revision: json['revision'] as String? ?? '',
      );
    }
    final sessionId = await _requireSession();
    final doc = await _client.readMemory(sessionId, file.name);
    return V2MemoryFileDocument(
      content: doc.content,
      revision: doc.revision,
    );
  }

  @override
  Future<String> save(
    V2MemoryFileEntry file,
    String content, {
    String revision = '',
  }) async {
    final ifRevision = revision.isEmpty ? null : revision;
    if (file.group == V2MemoryFileGroup.project) {
      final projectId = file.projectId;
      if (projectId == null) throw StateError('Missing project.');
      final json = await _rest.putJson(
        '/projects/${Uri.encodeComponent(projectId)}/memory/'
        '${Uri.encodeComponent(file.name)}',
        body: <String, Object>{'content': content, 'ifRevision': ?ifRevision},
      );
      return json['revision'] as String? ?? '';
    }
    final sessionId = await _requireSession();
    final saved = await _client.writeMemory(
      sessionId,
      file.name,
      content,
      ifRevision: ifRevision,
    );
    return saved.revision;
  }

  @override
  Future<void> delete(V2MemoryFileEntry file) async {
    if (file.group == V2MemoryFileGroup.project) {
      final projectId = file.projectId;
      if (projectId == null) throw StateError('Missing project.');
      await _rest.delete(
        '/projects/${Uri.encodeComponent(projectId)}/memory/'
        '${Uri.encodeComponent(file.name)}',
      );
      return;
    }
    final sessionId = await _requireSession();
    await _client.deleteMemory(sessionId, file.name);
  }

  @override
  Future<V2MemoryFilesExportOutcome> export(
    List<V2MemoryFileEntry> files,
  ) async {
    final archive = Archive();
    var count = 0;
    for (final file in files) {
      final doc = await read(file);
      final bytes = utf8.encode(doc.content);
      final folder = switch (file.group) {
        V2MemoryFileGroup.global => 'global',
        V2MemoryFileGroup.session => 'chat',
        V2MemoryFileGroup.project =>
          'projects/${_safeSegment(file.projectId ?? 'project')}',
      };
      archive.add(
        ArchiveFile.noCompress(
          '$folder/${_safeSegment(file.name)}',
          bytes.length,
          bytes,
        ),
      );
      count++;
    }
    if (count == 0) {
      return const V2MemoryFilesExportOutcome(
        message: 'No memory files to export.',
      );
    }
    final encoded = ZipEncoder().encode(archive);
    final directory = await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final path = '${directory.path}/ovid-memory-$stamp.zip';
    await File(path).writeAsBytes(encoded, flush: true);
    await NativeShare.file(path);
    return V2MemoryFilesExportOutcome(
      message:
          'Exported $count memory ${count == 1 ? 'file' : 'files'}.',
      path: path,
    );
  }

  Future<String> _requireSession() async {
    final sessionId = await _sessionId();
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('Open a chat first.');
    }
    return sessionId;
  }

  /// Archive paths never become filesystem paths; keep them to a safe set.
  String _safeSegment(String raw) =>
      raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}
