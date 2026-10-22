import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'project_memory_editor.dart';

// TODO(l10n): route all user-facing copy through the ARB pass.

enum V2ProjectDetailStatus { loading, content, empty, error }

/// Immutable view data for the project detail sheet.
@immutable
class V2ProjectDetailData {
  const V2ProjectDetailData({
    this.projectName = '',
    this.shared = false,
    this.chatCount = 0,
    this.chats = const <V2ProjectChat>[],
    this.memoryFiles = const <V2ProjectMemoryFile>[],
    this.storageLabel = '',
    this.storageFraction = 0,
    this.status = V2ProjectDetailStatus.content,
    this.errorMessage,
  });

  final String projectName;
  final bool shared;
  final int chatCount;
  final List<V2ProjectChat> chats;
  final List<V2ProjectMemoryFile> memoryFiles;

  /// Human storage line, e.g. "340 MB of 3 GB".
  final String storageLabel;

  /// Share of the storage allowance in use, 0..1.
  final double storageFraction;

  final V2ProjectDetailStatus status;
  final String? errorMessage;

  String get chatLabel => chatCount == 1 ? '1 chat' : '$chatCount chats';

  String get memoryLabel => switch (memoryFiles.length) {
    0 => 'No memory files',
    1 => '1 memory file',
    final count => '$count memory files',
  };

  bool get isEmpty => chats.isEmpty && memoryFiles.isEmpty;
}

@immutable
class V2ProjectChat {
  const V2ProjectChat({
    required this.id,
    required this.title,
    this.modelLabel = '',
    this.timeLabel = '',
  });

  final String id;
  final String title;
  final String modelLabel;
  final String timeLabel;

  String get meta {
    final parts = <String>[
      if (modelLabel.isNotEmpty) modelLabel,
      if (timeLabel.isNotEmpty) timeLabel,
    ];
    return parts.join(' · ');
  }
}

@immutable
class V2ProjectMemoryFile {
  const V2ProjectMemoryFile({
    required this.id,
    required this.name,
    required this.sizeLabel,
    this.updatedLabel = '',
    this.preview = '',
  });

  final String id;
  final String name;
  final String sizeLabel;
  final String updatedLabel;
  final String preview;

  String get meta {
    final parts = <String>[
      if (sizeLabel.isNotEmpty) sizeLabel,
      if (updatedLabel.isNotEmpty) updatedLabel,
    ];
    return parts.join(' · ');
  }
}

/// A memory file the user is adding or editing. [id] is null for a new file.
@immutable
class V2ProjectMemoryDraft {
  const V2ProjectMemoryDraft({
    this.id,
    required this.name,
    required this.content,
  });

  final String? id;
  final String name;
  final String content;

  bool get isNew => id == null;
}

/// Project detail: chats in the project, the files it remembers, storage used
/// and the memory add/edit/delete affordances. All data arrives through
/// [data]; every action leaves through a callback.
class ProjectDetailPage extends StatelessWidget {
  const ProjectDetailPage({
    super.key,
    required this.data,
    this.onChatTap,
    this.onSaveMemory,
    this.onDeleteMemory,
    this.onRetry,
  });

  final V2ProjectDetailData data;
  final ValueChanged<V2ProjectChat>? onChatTap;
  final ValueChanged<V2ProjectMemoryDraft>? onSaveMemory;
  final ValueChanged<V2ProjectMemoryFile>? onDeleteMemory;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Project'),
      body: OFadeSlide(
        child: ProjectDetailContent(
          data: data,
          onChatTap: onChatTap,
          onSaveMemory: onSaveMemory,
          onDeleteMemory: onDeleteMemory,
          onRetry: onRetry,
        ),
      ),
    );
  }
}

/// The body of the project detail, shared by [ProjectDetailPage] and
/// [showProjectDetailSheet].
class ProjectDetailContent extends StatelessWidget {
  const ProjectDetailContent({
    super.key,
    required this.data,
    this.onChatTap,
    this.onSaveMemory,
    this.onDeleteMemory,
    this.onRetry,
  });

  final V2ProjectDetailData data;
  final ValueChanged<V2ProjectChat>? onChatTap;
  final ValueChanged<V2ProjectMemoryDraft>? onSaveMemory;
  final ValueChanged<V2ProjectMemoryFile>? onDeleteMemory;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (data.status == V2ProjectDetailStatus.loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: OSpace.screen),
        child: OSkeletonList(rows: 5),
      );
    }
    if (data.status == V2ProjectDetailStatus.error) {
      return SizedBox(
        height: 360,
        child: OErrorState(
          title: 'Project did not load',
          message: data.errorMessage ?? 'Check your connection and try again.',
          onRetry: onRetry,
        ),
      );
    }
    if (data.status == V2ProjectDetailStatus.empty || data.isEmpty) {
      return SizedBox(
        height: 380,
        child: OEmptyState(
          icon: Icons.folder_open_rounded,
          title: 'No memories yet',
          message: 'Memories from this project appear here.',
          action: onSaveMemory == null
              ? null
              : OButton(
                  key: const Key('v2-project-detail-empty-add'),
                  label: 'Add memory',
                  icon: Icons.add_rounded,
                  onPressed: () => _openEditor(context, null),
                ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.screen,
        OSpace.s,
        OSpace.screen,
        OSpace.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DetailHeader(data: data),
          const SizedBox(height: OSpace.m),
          _StorageCard(
            label: data.storageLabel,
            fraction: data.storageFraction,
          ),
          if (data.chats.isNotEmpty) ...[
            const SizedBox(height: OSpace.s),
            OSectionHeader(
              label: 'Chats',
              trailing: Text(
                data.chatLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: OType.caption.copyWith(
                  color: OColors.of(context).textFaint,
                ),
              ),
              padding: const EdgeInsets.fromLTRB(
                OSpace.s,
                OSpace.l,
                OSpace.s,
                OSpace.xs,
              ),
            ),
            OStagger(
              children: [
                for (final chat in data.chats)
                  _ChatRow(chat: chat, onTap: onChatTap),
              ],
            ),
          ],
          const SizedBox(height: OSpace.s),
          OSectionHeader(
            label: 'Memory',
            trailing: onSaveMemory == null
                ? null
                : OIconButton(
                    icon: Icons.add_rounded,
                    semanticLabel: 'Add memory',
                    size: 18,
                    onPressed: () => _openEditor(context, null),
                  ),
            padding: const EdgeInsets.fromLTRB(
              OSpace.s,
              OSpace.l,
              OSpace.s,
              OSpace.xs,
            ),
          ),
          OStagger(
            children: [
              if (data.memoryFiles.isEmpty)
                _MemoryHint(
                  onAdd: onSaveMemory == null
                      ? null
                      : () => _openEditor(context, null),
                )
              else
                for (final file in data.memoryFiles)
                  _MemoryRow(
                    file: file,
                    onTap: onSaveMemory == null
                        ? null
                        : () => _openEditor(context, file),
                    onDelete: onDeleteMemory == null
                        ? null
                        : () => _confirmDelete(context, file),
                  ),
            ],
          ),
        ],
      ),
    );
  }

  /// Opens the shared memory editor for a new file ([file] null) or an
  /// existing one, and hands the saved draft back through [onSaveMemory].
  ///
  /// The project's other file names go in as taken so the editor can reject a
  /// duplicate before the write; the file being edited is not its own conflict.
  Future<void> _openEditor(
    BuildContext context,
    V2ProjectMemoryFile? file,
  ) async {
    final save = onSaveMemory;
    if (save == null) return;
    final takenNames = <String>[
      for (final other in data.memoryFiles)
        if (other.id != file?.id) other.name,
    ];
    await showProjectMemoryEditor(
      context,
      data: V2ProjectMemoryEditorData(
        fileId: file?.id,
        name: file?.name ?? '',
        content: file?.preview ?? '',
        projectName: data.projectName,
        takenNames: takenNames,
      ),
      onSave: (draft) => save(
        V2ProjectMemoryDraft(
          id: draft.id,
          name: draft.name,
          content: draft.content,
        ),
      ),
      onDelete: onDeleteMemory == null ? null : _deleteById,
    );
  }

  /// The editor reports a delete by id; the screen's public callback takes the
  /// whole file, so map it back through the injected list.
  void _deleteById(String id) {
    final delete = onDeleteMemory;
    if (delete == null) return;
    for (final file in data.memoryFiles) {
      if (file.id == id) {
        delete(file);
        return;
      }
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    V2ProjectMemoryFile file,
  ) async {
    final delete = onDeleteMemory;
    if (delete == null) return;
    final c = OColors.of(context);
    await showOSheet<void>(
      context,
      title: 'Delete memory?',
      builder: (sheetContext) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          OSpace.l,
          OSpace.s,
          OSpace.l,
          OSpace.l,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'This removes "${file.name}" from the project memory. This '
              'cannot be undone.',
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.l),
            OButton(
              key: const Key('v2-delete-memory-confirm'),
              label: 'Delete memory',
              icon: Icons.delete_outline_rounded,
              variant: OButtonVariant.dangerFill,
              expand: true,
              onPressed: () {
                delete(file);
                Navigator.maybePop(sheetContext);
              },
            ),
            const SizedBox(height: OSpace.s),
            OButton(
              label: 'Keep file',
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: () => Navigator.maybePop(sheetContext),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({required this.data});

  final V2ProjectDetailData data;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      padding: const EdgeInsets.all(OSpace.m),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(Icons.folder_rounded, size: 24, color: c.accent),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      data.projectName.isEmpty ? 'Project' : data.projectName,
                      style: OType.bodyStrong.copyWith(color: c.text),
                    ),
                    OPill(
                      label: data.shared ? 'Shared' : 'Personal',
                      tone: data.shared ? OPillTone.accent : OPillTone.neutral,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${data.chatLabel} · ${data.memoryLabel}',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.label, required this.fraction});

  final String label;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_outlined, size: 18, color: c.textMuted),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  'Storage used',
                  style: OType.bodySm.copyWith(color: c.text),
                ),
              ),
              if (label.isNotEmpty)
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          OProgressBar(value: fraction),
        ],
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({required this.chat, this.onTap});

  final V2ProjectChat chat;
  final ValueChanged<V2ProjectChat>? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OPressable(
      onTap: onTap == null ? null : () => onTap!(chat),
      semanticLabel: chat.meta.isEmpty
          ? chat.title
          : '${chat.title}, ${chat.meta}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OSpace.listRow),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.s,
            vertical: OSpace.s,
          ),
          child: Row(
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 18,
                color: c.textFaint,
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      chat.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.bodySm.copyWith(
                        color: c.text,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (chat.meta.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        chat.meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemoryRow extends StatelessWidget {
  const _MemoryRow({required this.file, this.onTap, this.onDelete});

  final V2ProjectMemoryFile file;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      children: [
        Expanded(
          child: OPressable(
            onTap: onTap,
            semanticLabel: file.meta.isEmpty
                ? '${file.name}, memory file'
                : '${file.name}, ${file.meta}',
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: OSpace.listRow),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: OSpace.s,
                  vertical: OSpace.s,
                ),
                child: Row(
                  children: [
                    Icon(Icons.description_outlined, size: 18, color: c.accent),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            file.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: OType.bodySm.copyWith(
                              color: c.text,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (file.meta.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              file.meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: OType.caption.copyWith(color: c.textMuted),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (onDelete != null)
          OIconButton(
            icon: Icons.delete_outline_rounded,
            semanticLabel: 'Delete memory ${file.name}',
            size: 18,
            onPressed: onDelete,
          ),
      ],
    );
  }
}

class _MemoryHint extends StatelessWidget {
  const _MemoryHint({this.onAdd});

  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: OSpace.s),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.auto_awesome_rounded, size: 18, color: c.accent),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No memory files yet',
                  style: OType.bodySm.copyWith(color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  'Memory is what this project remembers between chats.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                if (onAdd != null) ...[
                  const SizedBox(height: OSpace.s),
                  OButton(
                    label: 'Add memory',
                    icon: Icons.add_rounded,
                    size: OButtonSize.compact,
                    onPressed: onAdd,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the project detail in the shared bottom sheet container.
Future<void> showProjectDetailSheet(
  BuildContext context, {
  required V2ProjectDetailData data,
  ValueChanged<V2ProjectChat>? onChatTap,
  ValueChanged<V2ProjectMemoryDraft>? onSaveMemory,
  ValueChanged<V2ProjectMemoryFile>? onDeleteMemory,
  VoidCallback? onRetry,
}) {
  return showOSheet<void>(
    context,
    builder: (_) => ProjectDetailContent(
      data: data,
      onChatTap: onChatTap,
      onSaveMemory: onSaveMemory,
      onDeleteMemory: onDeleteMemory,
      onRetry: onRetry,
    ),
  );
}
