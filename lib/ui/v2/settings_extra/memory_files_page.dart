import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

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
  });

  final String id;
  final String name;
  final V2MemoryFileGroup group;
  final String sizeLabel;
  final String updatedLabel;
  final String preview;
}

/// Injected state for the Memory files screen.
@immutable
class V2MemoryFilesPageData {
  const V2MemoryFilesPageData({
    this.status = V2MemoryFilesStatus.ready,
    this.files = const <V2MemoryFileEntry>[],
    this.totalSizeLabel = '0 KB',
    this.onOpen,
    this.onDelete,
    this.onExportAll,
    this.onRetry,
    this.errorMessage = 'We could not load your memory files.',
  });

  final V2MemoryFilesStatus status;
  final List<V2MemoryFileEntry> files;
  final String totalSizeLabel;

  final ValueChanged<String>? onOpen;
  final ValueChanged<String>? onDelete;
  final VoidCallback? onExportAll;
  final VoidCallback? onRetry;
  final String errorMessage;
}

/// Memory files grouped by scope, with open, delete and export actions.
class MemoryFilesPage extends StatelessWidget {
  const MemoryFilesPage({super.key, required this.data});

  final V2MemoryFilesPageData data;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Memory files'),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.status == V2MemoryFilesStatus.loading) {
      return OFadeSlide(
        child: Semantics(
          label: 'Loading your memory files',
          child: const OSkeletonList(rows: 7),
        ),
      );
    }
    if (data.status == V2MemoryFilesStatus.error) {
      return OErrorState(message: data.errorMessage, onRetry: data.onRetry);
    }
    if (data.status == V2MemoryFilesStatus.empty || data.files.isEmpty) {
      return OEmptyState(
        icon: Icons.folder_open_rounded,
        title: 'No memory files yet',
        message: 'Ovid will save notes here as you chat.',
        action: OButton(
          label: 'Refresh',
          icon: Icons.refresh_rounded,
          onPressed: data.onRetry,
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
            _explainer(context),
            for (final group in V2MemoryFileGroup.values)
              if (data.files.any((file) => file.group == group))
                _groupSection(context, group),
            _export(context),
          ],
        ),
      ),
    );
  }

  Widget _explainer(BuildContext context) {
    final c = OColors.of(context);
    final count = data.files.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: OCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.accentSoft,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Icon(
                Icons.description_outlined,
                size: 21,
                color: c.accent,
              ),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'What Ovid remembers',
                    style: OType.bodyStrong.copyWith(color: c.text),
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    'Ovid saves small notes while it works. Open a file to see '
                    'what it remembers, or remove one you no longer need.',
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                  const SizedBox(height: OSpace.s),
                  Wrap(
                    spacing: OSpace.s,
                    runSpacing: OSpace.s,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _pill(
                        context,
                        label: '$count ${count == 1 ? 'file' : 'files'}',
                        foreground: c.accent,
                        background: c.accentSoft,
                      ),
                      Text(
                        'Total ${data.totalSizeLabel}',
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupSection(BuildContext context, V2MemoryFileGroup group) {
    final c = OColors.of(context);
    final files = data.files.where((file) => file.group == group).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: '${group.label} files',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: Text(
              '${files.length} ${files.length == 1 ? 'file' : 'files'}',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
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
        ],
      ),
    );
  }

  Widget _fileRow(BuildContext context, V2MemoryFileEntry file) {
    final c = OColors.of(context);
    final canOpen = data.onOpen != null;
    return Semantics(
      label:
          '${file.name}, ${file.sizeLabel}, updated ${file.updatedLabel}, '
          '${file.preview}',
      button: canOpen,
      enabled: canOpen,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: canOpen ? () => data.onOpen!(file.id) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: OSpace.l,
              vertical: OSpace.m,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The label above already carries this text, so the visual
                // copy is hidden from screen readers to avoid reading it twice.
                ExcludeSemantics(
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(ORadius.m),
                    ),
                    child: Icon(
                      _groupIcon(file.group),
                      size: 19,
                      color: c.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          file.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.body.copyWith(
                            color: c.text,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${file.sizeLabel} · Updated ${file.updatedLabel}',
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                        const SizedBox(height: OSpace.xs),
                        Text(
                          file.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.bodySm.copyWith(color: c.textFaint),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: OSpace.xs),
                _fileMenu(context, file),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fileMenu(BuildContext context, V2MemoryFileEntry file) {
    final c = OColors.of(context);
    final canOpen = data.onOpen != null;
    final canDelete = data.onDelete != null;
    return SizedBox(
      width: OSpace.touch,
      height: OSpace.touch,
      child: PopupMenuButton<String>(
        enabled: canOpen || canDelete,
        tooltip: 'File options for ${file.name}',
        icon: Icon(Icons.more_vert_rounded, color: c.textMuted),
        onSelected: (value) {
          if (value == 'open') {
            data.onOpen?.call(file.id);
          } else if (value == 'delete') {
            _confirmDelete(context, file);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem<String>(
            value: 'open',
            enabled: canOpen,
            child: Row(
              children: [
                Icon(Icons.open_in_new_rounded, size: 18, color: c.textMuted),
                const SizedBox(width: OSpace.m),
                Text('Open', style: OType.bodySm.copyWith(color: c.text)),
              ],
            ),
          ),
          PopupMenuItem<String>(
            value: 'delete',
            enabled: canDelete,
            child: Row(
              children: [
                Icon(Icons.delete_outline_rounded, size: 18, color: c.danger),
                const SizedBox(width: OSpace.m),
                Text('Delete', style: OType.bodySm.copyWith(color: c.danger)),
              ],
            ),
          ),
        ],
      ),
    );
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

  Widget _export(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OButton(
          label: 'Export all',
          icon: Icons.download_rounded,
          variant: OButtonVariant.secondary,
          expand: true,
          onPressed: data.onExportAll,
        ),
        const SizedBox(height: OSpace.s),
        Text(
          'Exports every memory file in one zip.',
          textAlign: TextAlign.center,
          style: OType.caption.copyWith(color: c.textFaint),
        ),
      ],
    );
  }

  Widget _pill(
    BuildContext context, {
    required String label,
    required Color foreground,
    required Color background,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: OSpace.xs),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: OType.caption.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  IconData _groupIcon(V2MemoryFileGroup group) {
    return switch (group) {
      V2MemoryFileGroup.global => Icons.public_rounded,
      V2MemoryFileGroup.project => Icons.folder_outlined,
      V2MemoryFileGroup.session => Icons.forum_outlined,
    };
  }
}
