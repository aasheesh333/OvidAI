import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

/// One project's learned memory.
@immutable
class V2MemoryProject {
  const V2MemoryProject({
    required this.id,
    required this.name,
    required this.detail,
  });

  final String id;
  final String name;
  final String detail;
}

/// The scope a memory entry belongs to. Also used by the filter chips so the
/// screen can show one scope at a time instead of one long list.
enum V2MemoryScope {
  all('All'),
  global('Global'),
  project('Project'),
  session('Session');

  const V2MemoryScope(this.label);

  final String label;
}

/// One learned fact with a stable id, so it can be forgotten individually.
@immutable
class V2MemoryEntry {
  const V2MemoryEntry({required this.id, required this.text});

  final String id;
  final String text;
}

/// A file cached for the current chat.
@immutable
class V2MemoryFile {
  const V2MemoryFile({
    required this.id,
    required this.name,
    required this.detail,
    this.icon = Icons.description_outlined,
  });

  final String id;
  final String name;
  final String detail;
  final IconData icon;
}

/// Injected state for the Memory screen.
@immutable
class V2MemoryPageData {
  const V2MemoryPageData({
    this.memoryEnabled = true,
    this.shareSessionMemory = false,
    this.globalMemory = const <String>[],
    this.globalEntries,
    this.globalVersionLabel = '',
    this.projects = const <V2MemoryProject>[],
    this.sessionFiles = const <V2MemoryFile>[],
    this.initialScope = V2MemoryScope.all,
    this.loading = false,
    this.errorMessage,
    this.onMemoryEnabledChanged,
    this.onShareSessionMemoryChanged,
    this.onEditGlobal,
    this.onProjectTap,
    this.onFileDownload,
    this.onForgetMemory,
    this.onExport,
    this.onResetAll,
    this.onRetry,
  });

  final bool memoryEnabled;

  /// Whether facts from this chat may be reused by projects and shared chats.
  final bool shareSessionMemory;
  final List<String> globalMemory;

  /// Facts with stable ids. When null, [globalMemory] is shown and each fact's
  /// text doubles as its id.
  final List<V2MemoryEntry>? globalEntries;
  final String globalVersionLabel;
  final List<V2MemoryProject> projects;
  final List<V2MemoryFile> sessionFiles;

  /// Scope selected when the screen opens. The chips then change it locally.
  final V2MemoryScope initialScope;
  final bool loading;
  final String? errorMessage;

  final ValueChanged<bool>? onMemoryEnabledChanged;
  final ValueChanged<bool>? onShareSessionMemoryChanged;
  final VoidCallback? onEditGlobal;
  final ValueChanged<String>? onProjectTap;
  final ValueChanged<String>? onFileDownload;

  /// Deletes one entry. Global entries pass their id (or text when no id was
  /// supplied), project rows their project id and session rows their file id.
  final void Function(V2MemoryScope scope, String id)? onForgetMemory;
  final VoidCallback? onExport;
  final VoidCallback? onResetAll;
  final VoidCallback? onRetry;

  /// Global facts as entries, whether the caller supplied ids or plain text.
  List<V2MemoryEntry> get resolvedGlobalEntries {
    final explicit = globalEntries;
    if (explicit != null) return explicit;
    return [
      for (var i = 0; i < globalMemory.length; i++)
        V2MemoryEntry(id: '$i:${globalMemory[i]}', text: globalMemory[i]),
    ];
  }

  bool get isEmpty =>
      globalMemory.isEmpty &&
      (globalEntries?.isEmpty ?? true) &&
      projects.isEmpty &&
      sessionFiles.isEmpty;
}

/// Memory settings: what Ovid remembers between chats, and how to clear it.
class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key, required this.data});

  final V2MemoryPageData data;

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  late V2MemoryScope _scope = widget.data.initialScope;
  late List<V2MemoryEntry> _global = widget.data.resolvedGlobalEntries;
  late List<V2MemoryProject> _projects = widget.data.projects;
  late List<V2MemoryFile> _files = widget.data.sessionFiles;

  @override
  void didUpdateWidget(covariant MemoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A parent rebuild is the source of truth: re-sync the working copies so a
    // delete that failed server-side reappears instead of staying hidden.
    if (!identical(oldWidget.data, widget.data)) {
      _global = widget.data.resolvedGlobalEntries;
      _projects = widget.data.projects;
      _files = widget.data.sessionFiles;
    }
  }

  V2MemoryPageData get data => widget.data;

  bool _shows(V2MemoryScope scope) =>
      _scope == V2MemoryScope.all || _scope == scope;

  int get _scopeCount => switch (_scope) {
    V2MemoryScope.all => _global.length + _projects.length + _files.length,
    V2MemoryScope.global => _global.length,
    V2MemoryScope.project => _projects.length,
    V2MemoryScope.session => _files.length,
  };

  bool get _locallyEmpty =>
      _global.isEmpty && _projects.isEmpty && _files.isEmpty;

  /// Removes the entry locally, then reports it so the owner can delete it for
  /// real. The list updates immediately, which is what makes "Forget" honest.
  void _forget(V2MemoryScope scope, String id) {
    setState(() {
      switch (scope) {
        case V2MemoryScope.global:
          _global = [
            for (final entry in _global)
              if (entry.id != id) entry,
          ];
        case V2MemoryScope.project:
          _projects = [
            for (final project in _projects)
              if (project.id != id) project,
          ];
        case V2MemoryScope.session:
          _files = [
            for (final file in _files)
              if (file.id != id) file,
          ];
        case V2MemoryScope.all:
          break;
      }
    });
    data.onForgetMemory?.call(scope, id);
  }

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Memory'),
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
    if (_locallyEmpty) {
      final canTurnOn =
          !data.memoryEnabled && data.onMemoryEnabledChanged != null;
      return OEmptyState(
        icon: Icons.psychology_alt_outlined,
        title: 'No memories yet',
        message: 'Ovid will remember useful details as you chat.',
        action: canTurnOn
            ? OButton(
                label: 'Turn on memory',
                icon: Icons.toggle_on_rounded,
                onPressed: () => data.onMemoryEnabledChanged!(true),
              )
            : OButton(
                label: 'Add a memory',
                icon: Icons.edit_rounded,
                onPressed: data.onEditGlobal,
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
            _notice(context),
            _scopeFilter(context),
            _toggleCard(context),
            _shareSessionCard(context),
            if (_shows(V2MemoryScope.global)) _globalMemory(context),
            if (_shows(V2MemoryScope.project)) _projectMemory(context),
            if (_shows(V2MemoryScope.session)) _sessionFiles(context),
            _footer(context),
          ],
        ),
      ),
    );
  }

  /// Scope chips. Selecting one really filters the sections and their counts;
  /// it is not a label. `All` restores the full screen.
  Widget _scopeFilter(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SHOW', style: OType.overline.copyWith(color: c.textMuted)),
          const SizedBox(height: OSpace.s),
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            children: [
              for (final scope in V2MemoryScope.values)
                OChip(
                  key: ValueKey<String>('memory-scope-${scope.name}'),
                  label: scope.label,
                  selected: _scope == scope,
                  onTap: () => setState(() => _scope = scope),
                ),
            ],
          ),
          const SizedBox(height: OSpace.xs),
          Text(
            _scope == V2MemoryScope.all
                ? '$_scopeCount memories across every scope'
                : '$_scopeCount ${_scope.label.toLowerCase()} '
                      '${_scopeCount == 1 ? 'memory' : 'memories'}',
            key: const ValueKey<String>('memory-scope-count'),
            style: OType.caption.copyWith(color: c.textFaint),
          ),
        ],
      ),
    );
  }

  Widget _notice(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        padding: const EdgeInsets.all(OSpace.m),
        child: Row(
          children: [
            Icon(Icons.psychology_alt_rounded, size: 20, color: c.accent),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                'Memory automatically gathers useful details across chats.',
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toggleCard(BuildContext context) {
    final c = OColors.of(context);
    final enabled = data.memoryEnabled;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: enabled ? c.success : c.textFaint,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: OSpace.s),
                      Flexible(
                        child: Text(
                          enabled ? 'Memory on' : 'Memory off',
                          style: OType.h2.copyWith(color: c.text),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    enabled
                        ? 'Ovid remembers useful details between chats.'
                        : 'Ovid starts each chat fresh.',
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.m),
            Semantics(
              key: const ValueKey<String>('memory-master-toggle'),
              label: 'Memory',
              toggled: enabled,
              button: true,
              enabled: data.onMemoryEnabledChanged != null,
              onTap: data.onMemoryEnabledChanged == null
                  ? null
                  : () => data.onMemoryEnabledChanged!(!enabled),
              child: ExcludeSemantics(
                child: Switch(
                  key: const ValueKey<String>('memory-master-switch'),
                  value: enabled,
                  onChanged: data.onMemoryEnabledChanged,
                  activeThumbColor: c.onAccent,
                  activeTrackColor: c.accentFill,
                  inactiveThumbColor: c.textFaint,
                  inactiveTrackColor: c.surfaceRaised,
                  trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shareSessionCard(BuildContext context) {
    final c = OColors.of(context);
    final enabled = data.shareSessionMemory;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: OCard(
        padding: EdgeInsets.zero,
        child: OListRow(
          icon: Icons.people_outline_rounded,
          title: 'Share session memory',
          subtitle: enabled
              ? 'Projects and shared chats can reuse facts from this chat.'
              : 'This chat stays private. Its facts are not shared.',
          showChevron: false,
          onTap: data.onShareSessionMemoryChanged == null
              ? null
              : () => data.onShareSessionMemoryChanged!(!enabled),
          enabled: data.onShareSessionMemoryChanged != null,
          trailing: Semantics(
            label: 'Share session memory',
            toggled: enabled,
            button: true,
            enabled: data.onShareSessionMemoryChanged != null,
            onTap: data.onShareSessionMemoryChanged == null
                ? null
                : () => data.onShareSessionMemoryChanged!(!enabled),
            child: ExcludeSemantics(
              child: Switch(
                key: const ValueKey<String>('memory-share-session-switch'),
                value: enabled,
                onChanged: data.onShareSessionMemoryChanged,
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
    );
  }

  Widget _globalMemory(BuildContext context) {
    final c = OColors.of(context);
    final entries = _global.length;
    final largeText = _largeText(context);
    final editButton = OButton(
      label: 'Edit',
      icon: Icons.edit_rounded,
      variant: OButtonVariant.ghost,
      onPressed: data.onEditGlobal,
    );
    // The label and the Edit action share one row at normal text sizes. At
    // large text they stack, otherwise the action squeezes the label into a
    // one-character column.
    final header = Row(
      children: [
        Icon(Icons.terminal_rounded, size: 18, color: c.textMuted),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(
            'ACTIVE PREFERENCES',
            style: OType.overline.copyWith(color: c.textMuted),
          ),
        ),
        if (!largeText) editButton,
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionHeader(
            context,
            'Global memory',
            OPill(
              label: '$entries ${entries == 1 ? 'entry' : 'entries'}',
              tone: OPillTone.accent,
            ),
          ),
          OCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                if (largeText) ...[
                  const SizedBox(height: OSpace.xs),
                  Align(alignment: Alignment.centerRight, child: editButton),
                ],
                const SizedBox(height: OSpace.xs),
                if (data.globalVersionLabel.isNotEmpty)
                  Text(
                    data.globalVersionLabel,
                    style: OType.caption.copyWith(color: c.textFaint),
                  ),
                const SizedBox(height: OSpace.s),
                if (_global.isEmpty)
                  Text(
                    'No global memories yet.',
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  )
                else
                  for (var i = 0; i < _global.length; i++) ...[
                    if (i > 0) const SizedBox(height: OSpace.s),
                    _memoryLine(context, _global[i]),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Section label plus its count. At large text the count moves under the
  /// label, so neither is squeezed into an ellipsis on a narrow screen.
  Widget _sectionHeader(BuildContext context, String label, Widget trailing) {
    if (!_largeText(context)) {
      return OSectionHeader(
        label: label,
        padding: const EdgeInsets.only(bottom: OSpace.s),
        trailing: trailing,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OSectionHeader(
          label: label,
          padding: const EdgeInsets.only(bottom: OSpace.xs),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: OSpace.s),
          child: trailing,
        ),
      ],
    );
  }

  /// True when text is scaled far enough that side-by-side label/action rows
  /// stop fitting on a narrow phone.
  bool _largeText(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(14) > 18;

  Widget _memoryLine(BuildContext context, V2MemoryEntry entry) {
    final c = OColors.of(context);
    final canForget = data.onForgetMemory != null;
    return Container(
      padding: EdgeInsets.fromLTRB(
        OSpace.m,
        OSpace.m,
        canForget ? OSpace.xs : OSpace.m,
        OSpace.m,
      ),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.check_circle_rounded, size: 18, color: c.accent),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Text(
              entry.text,
              style: OType.bodySm.copyWith(color: c.text),
            ),
          ),
          if (canForget)
            OIconButton(
              key: ValueKey<String>('memory-forget-global-${entry.id}'),
              icon: Icons.delete_outline_rounded,
              semanticLabel: 'Forget ${entry.text}',
              tooltip: 'Forget this memory',
              onPressed: () => _forget(V2MemoryScope.global, entry.id),
            ),
        ],
      ),
    );
  }

  Widget _projectMemory(BuildContext context) {
    final c = OColors.of(context);
    final active = _projects.length;
    final canForget = data.onForgetMemory != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionHeader(
            context,
            'Project memory',
            Text(
              '$active active',
              style: OType.caption.copyWith(color: c.success),
            ),
          ),
          if (_projects.isEmpty)
            OCard(
              child: Text(
                'No project memories yet. Ovid learns a project as you work in it.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            OCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < _projects.length; i++) ...[
                    if (i > 0) Divider(color: c.hairline, height: 1),
                    OListRow(
                      icon: Icons.folder_rounded,
                      title: _projects[i].name,
                      subtitle: _projects[i].detail,
                      onTap: data.onProjectTap == null
                          ? null
                          : () => data.onProjectTap!(_projects[i].id),
                      trailing: !canForget
                          ? null
                          : OIconButton(
                              key: ValueKey<String>(
                                'memory-forget-project-${_projects[i].id}',
                              ),
                              icon: Icons.delete_outline_rounded,
                              semanticLabel:
                                  'Forget ${_projects[i].name} memory',
                              tooltip: 'Forget project memory',
                              onPressed: () => _forget(
                                V2MemoryScope.project,
                                _projects[i].id,
                              ),
                            ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _sessionFiles(BuildContext context) {
    final c = OColors.of(context);
    final count = _files.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionHeader(
            context,
            'Session files',
            Text(
              '$count ${count == 1 ? 'file' : 'files'} cached',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          if (_files.isEmpty)
            OCard(
              child: Text(
                'No files are cached for this chat. Add a file in chat to keep it here.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            OCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < _files.length; i++) ...[
                    if (i > 0) Divider(color: c.hairline, height: 1),
                    _fileRow(context, _files[i]),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// File row. Built locally rather than with [OListRow] so the file name can
  /// wrap to two lines and then ellipsize: file names are long unbreakable
  /// tokens, and at 200 % text they would otherwise paint outside their column.
  Widget _fileRow(BuildContext context, V2MemoryFile file) {
    final c = OColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.m,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Icon(file.icon, size: 19, color: c.textMuted),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    file.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.body.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    file.detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.s),
            OIconButton(
              icon: Icons.download_rounded,
              semanticLabel: 'Download ${file.name}',
              onPressed: data.onFileDownload == null
                  ? null
                  : () => data.onFileDownload!(file.id),
            ),
            if (data.onForgetMemory != null)
              OIconButton(
                key: ValueKey<String>('memory-forget-file-${file.id}'),
                icon: Icons.delete_outline_rounded,
                semanticLabel: 'Forget ${file.name}',
                tooltip: 'Forget this file',
                onPressed: () => _forget(V2MemoryScope.session, file.id),
              ),
          ],
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: OSpace.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OButton(
            label: 'Export memory',
            icon: Icons.download_rounded,
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: data.onExport,
          ),
          const SizedBox(height: OSpace.s),
          OButton(
            label: 'Reset all memory',
            icon: Icons.warning_amber_rounded,
            variant: OButtonVariant.danger,
            expand: true,
            onPressed: data.onResetAll,
          ),
          const SizedBox(height: OSpace.s),
          Text(
            'Resetting removes every learned fact and project preference. This cannot be undone.',
            textAlign: TextAlign.center,
            style: OType.caption.copyWith(color: c.textFaint),
          ),
        ],
      ),
    );
  }
}
