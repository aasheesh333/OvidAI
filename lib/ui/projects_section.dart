import 'package:flutter/material.dart';

import '../core/cloud/models.dart';
import '../core/theme.dart';

/// W1 Projects section — folder rows above the session list (owner spec §3
/// Screen 4). Each row shows the plan-derived file count, expands to reveal
/// its sessions, and offers rename/delete. The sidebar supplies the session
/// tiles so this widget stays independent of the session-row implementation.
class ProjectsSection extends StatelessWidget {
  const ProjectsSection({
    super.key,
    required this.projects,
    required this.expanded,
    required this.sessionTiles,
    required this.onToggle,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
    this.compact = false,
  });

  final List<ProjectDto> projects;
  final Set<String> expanded;

  /// Project id → already-built session tiles, in recency order.
  final Map<String, List<Widget>> sessionTiles;
  final ValueChanged<String> onToggle;
  final VoidCallback onCreate;
  final ValueChanged<ProjectDto> onRename;
  final ValueChanged<ProjectDto> onDelete;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 8, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'PROJECTS',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color: Aether.textFaint,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('projects-create'),
                tooltip: 'New project',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.create_new_folder_outlined, size: 17, color: Aether.textMuted),
                onPressed: onCreate,
              ),
            ],
          ),
        ),
        if (projects.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 16, 8),
            child: Text(
              'No projects yet',
              style: TextStyle(fontSize: 12.5, color: Aether.textFaint),
            ),
          )
        else
          for (final project in projects) ...[
            _ProjectRow(
              project: project,
              expanded: expanded.contains(project.id),
              compact: compact,
              onToggle: () => onToggle(project.id),
              onRename: () => onRename(project),
              onDelete: () => onDelete(project),
            ),
            if (expanded.contains(project.id))
              if ((sessionTiles[project.id] ?? const <Widget>[]).isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(44, 2, 16, 8),
                  child: Text(
                    'No sessions in this project',
                    style: TextStyle(fontSize: 12, color: Aether.textFaint),
                  ),
                )
              else
                ...sessionTiles[project.id]!,
          ],
        const SizedBox(height: 4),
      ],
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.project,
    required this.expanded,
    required this.compact,
    required this.onToggle,
    required this.onRename,
    required this.onDelete,
  });

  final ProjectDto project;
  final bool expanded;
  final bool compact;
  final VoidCallback onToggle;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final files = '${project.fileCount}/${project.fileCap} files';
    return Padding(
      key: ValueKey('project-${project.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 4, 9),
                child: Row(
                  children: [
                    Icon(
                      expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
                      size: 15,
                      color: Aether.accent,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            project.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Aether.text,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            compact
                                ? files
                                : '$files · ${project.sessionCount} session${project.sessionCount == 1 ? '' : 's'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, color: Aether.textFaint),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Project actions',
            icon: Icon(Icons.more_horiz, size: 18, color: Aether.textMuted),
            onSelected: (value) {
              if (value == 'rename') onRename();
              if (value == 'delete') onDelete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename project')),
              PopupMenuItem(value: 'delete', child: Text('Delete project')),
            ],
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

/// Create/rename dialog. Returns the trimmed name, or null on cancel.
Future<String?> showProjectNameDialog(
  BuildContext context, {
  required String title,
  String? initial,
  String confirmLabel = 'Save',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _ProjectNameDialog(
      title: title,
      initial: initial,
      confirmLabel: confirmLabel,
    ),
  );
}

/// Owns its controller so it is disposed with the dialog's element (after the
/// exit animation), not while the closing route still rebuilds the field.
class _ProjectNameDialog extends StatefulWidget {
  const _ProjectNameDialog({
    required this.title,
    required this.confirmLabel,
    this.initial,
  });

  final String title;
  final String? initial;
  final String confirmLabel;

  @override
  State<_ProjectNameDialog> createState() => _ProjectNameDialogState();
}

class _ProjectNameDialogState extends State<_ProjectNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? '',
  );
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final clean = _controller.text.trim();
    if (clean.isEmpty) {
      setState(() => _errorText = 'Enter a project name.');
      return;
    }
    Navigator.pop(context, clean);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        widget.title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 80,
        style: const TextStyle(fontSize: 14),
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          hintText: 'Project name',
          errorText: _errorText,
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: Text(
            widget.confirmLabel,
            style: TextStyle(color: Aether.accent),
          ),
        ),
      ],
    );
  }
}

/// A confirmed project choice; [projectId] is null for "No project".
class ProjectSelection {
  const ProjectSelection(this.projectId);
  final String? projectId;
}

/// "Add to Project" picker shared by the session row menu (and available to
/// the chat overflow menu). Returns null when dismissed.
Future<ProjectSelection?> showAddToProjectSheet(
  BuildContext context, {
  required String sessionTitle,
  required List<ProjectDto> projects,
  required String? currentProjectId,
}) {
  return showModalBottomSheet<ProjectSelection>(
    context: context,
    backgroundColor: Aether.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (sheetCtx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Add to Project',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Aether.text),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                sessionTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: Aether.textFaint),
              ),
            ),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.folder_off_outlined, size: 19),
            title: const Text('No project', style: TextStyle(fontSize: 13.5)),
            trailing: currentProjectId == null
                ? Icon(Icons.check, size: 18, color: Aether.accent)
                : null,
            onTap: () => Navigator.pop(sheetCtx, const ProjectSelection(null)),
          ),
          for (final project in projects)
            ListTile(
              dense: true,
              leading: Icon(Icons.folder_outlined, size: 19, color: Aether.accent),
              title: Text(project.name, style: const TextStyle(fontSize: 13.5)),
              subtitle: Text(
                '${project.fileCount}/${project.fileCap} files',
                style: TextStyle(fontSize: 12.5, color: Aether.textFaint),
              ),
              trailing: currentProjectId == project.id
                  ? Icon(Icons.check, size: 18, color: Aether.accent)
                  : null,
              onTap: () => Navigator.pop(
                sheetCtx,
                ProjectSelection(project.id),
              ),
            ),
          if (projects.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Text(
                'Create a project from the sidebar first.',
                style: TextStyle(fontSize: 12.5, color: Aether.textFaint),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
