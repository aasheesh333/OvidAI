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
    this.globalVersionLabel = '',
    this.projects = const <V2MemoryProject>[],
    this.sessionFiles = const <V2MemoryFile>[],
    this.loading = false,
    this.errorMessage,
    this.onMemoryEnabledChanged,
    this.onShareSessionMemoryChanged,
    this.onEditGlobal,
    this.onProjectTap,
    this.onFileDownload,
    this.onExport,
    this.onResetAll,
    this.onRetry,
  });

  final bool memoryEnabled;

  /// Whether facts from this chat may be reused by projects and shared chats.
  final bool shareSessionMemory;
  final List<String> globalMemory;
  final String globalVersionLabel;
  final List<V2MemoryProject> projects;
  final List<V2MemoryFile> sessionFiles;
  final bool loading;
  final String? errorMessage;

  final ValueChanged<bool>? onMemoryEnabledChanged;
  final ValueChanged<bool>? onShareSessionMemoryChanged;
  final VoidCallback? onEditGlobal;
  final ValueChanged<String>? onProjectTap;
  final ValueChanged<String>? onFileDownload;
  final VoidCallback? onExport;
  final VoidCallback? onResetAll;
  final VoidCallback? onRetry;

  bool get isEmpty =>
      globalMemory.isEmpty && projects.isEmpty && sessionFiles.isEmpty;
}

/// Memory settings: what Ovid remembers between chats, and how to clear it.
class MemoryPage extends StatelessWidget {
  const MemoryPage({super.key, required this.data});

  final V2MemoryPageData data;

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
    if (data.isEmpty) {
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
            _toggleCard(context),
            _shareSessionCard(context),
            _globalMemory(context),
            _projectMemory(context),
            _sessionFiles(context),
            _footer(context),
          ],
        ),
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
    final entries = data.globalMemory.length;
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
                if (data.globalMemory.isEmpty)
                  Text(
                    'No global memories yet.',
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  )
                else
                  for (var i = 0; i < data.globalMemory.length; i++) ...[
                    if (i > 0) const SizedBox(height: OSpace.s),
                    _memoryLine(context, data.globalMemory[i]),
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

  Widget _memoryLine(BuildContext context, String text) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.m),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle_rounded, size: 18, color: c.accent),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Text(text, style: OType.bodySm.copyWith(color: c.text)),
          ),
        ],
      ),
    );
  }

  Widget _projectMemory(BuildContext context) {
    final c = OColors.of(context);
    final active = data.projects.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionHeader(
            context,
            'Project memory',
            Text('$active active', style: OType.caption.copyWith(color: c.success)),
          ),
          if (data.projects.isEmpty)
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
                  for (var i = 0; i < data.projects.length; i++) ...[
                    if (i > 0) Divider(color: c.hairline, height: 1),
                    OListRow(
                      icon: Icons.folder_rounded,
                      title: data.projects[i].name,
                      subtitle: data.projects[i].detail,
                      onTap: data.onProjectTap == null
                          ? null
                          : () => data.onProjectTap!(data.projects[i].id),
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
    final count = data.sessionFiles.length;
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
          if (data.sessionFiles.isEmpty)
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
                  for (var i = 0; i < data.sessionFiles.length; i++) ...[
                    if (i > 0) Divider(color: c.hairline, height: 1),
                    _fileRow(context, data.sessionFiles[i]),
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
