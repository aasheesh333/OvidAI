import 'dart:async';

import 'package:flutter/material.dart';

import '../core/diag.dart';
import '../core/session_artifacts.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'artifact_preview.dart';
import 'widgets/aether_confirm.dart';
import 'widgets/aether_primitives.dart';

enum ArtifactFilter { all, uploaded, generated }

/// Artifacts — every file the user uploaded and every file, image, page or
/// document Ovid produced, for the current chat or across all chats.
///
/// Sourced from the persisted transcripts (see [collectSessionArtifacts]), so
/// nothing here can drift from the chat history. Tap previews; long-press
/// offers Share and "Remove from list" (hides the entry, never the file).
class ArtifactsScreen extends StatefulWidget {
  const ArtifactsScreen({super.key, this.sessionId});

  /// The chat to scope to first; null opens "All chats".
  final String? sessionId;

  @override
  State<ArtifactsScreen> createState() => _ArtifactsScreenState();
}

class _ArtifactsScreenState extends State<ArtifactsScreen> {
  ArtifactFilter _filter = ArtifactFilter.all;
  late bool _allChats = widget.sessionId == null;

  @override
  void initState() {
    super.initState();
    unawaited(ArtifactListPrefs.I.load());
    // Older chats may still be deferred (not yet decoded) at startup; the
    // overall list needs their messages.
    unawaited(_hydrate());
  }

  Future<void> _hydrate() async {
    try {
      await AppState.I.loadSessionsForSearch();
    } catch (e) {
      Diag.swallow('artifacts.hydrate', e);
    }
  }

  Iterable<ChatSession> _scopeSessions(AppState app) {
    if (_allChats || widget.sessionId == null) return app.sessions;
    final root = app.sessionById(widget.sessionId);
    if (root == null) return const [];
    return [root, ...app.descendantsOf(root.id)];
  }

  List<SessionArtifact> _visible(AppState app, Set<String> hidden) {
    return [
      for (final a in collectSessionArtifacts(_scopeSessions(app)))
        if (!hidden.contains(a.id) &&
            switch (_filter) {
              ArtifactFilter.all => true,
              ArtifactFilter.uploaded => a.origin == ArtifactOrigin.uploaded,
              ArtifactFilter.generated => a.origin == ArtifactOrigin.generated,
            })
          a,
    ];
  }

  Future<void> _remove(SessionArtifact a) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    await ArtifactListPrefs.I.hide(a.id);
    showUndoSnackBar(
      messenger,
      message: l10n.artifactRemoved,
      onUndo: () => ArtifactListPrefs.I.unhide(a.id),
    );
  }

  void _actions(SessionArtifact a) {
    final l10n = context.l10n;
    showModalBottomSheet<void>(
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
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AetherType.title,
              ),
            ),
            if (a.html == null)
              ListTile(
                leading: const Icon(Icons.ios_share_rounded, size: 20),
                title: Text(l10n.artifactShare),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  shareArtifact(context, a);
                },
              ),
            ListTile(
              leading: Icon(
                Icons.playlist_remove_rounded,
                size: 20,
                color: Aether.danger,
              ),
              title: Text(
                l10n.artifactRemoveFromList,
                style: TextStyle(color: Aether.danger),
              ),
              onTap: () {
                Navigator.pop(sheetCtx);
                _remove(a);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final app = AppState.I;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(title: Text(l10n.artifactsTitle)),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([app, ArtifactListPrefs.I.hidden]),
          builder: (context, _) {
            final items = _visible(app, ArtifactListPrefs.I.hidden.value);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      AetherSegmentedControl<ArtifactFilter>(
                        key: const ValueKey('artifacts-filter'),
                        value: _filter,
                        onChanged: (f) => setState(() => _filter = f),
                        options: [
                          (
                            value: ArtifactFilter.all,
                            label: l10n.artifactsFilterAll,
                            icon: null,
                          ),
                          (
                            value: ArtifactFilter.uploaded,
                            label: l10n.artifactsFilterUploaded,
                            icon: null,
                          ),
                          (
                            value: ArtifactFilter.generated,
                            label: l10n.artifactsFilterGenerated,
                            icon: null,
                          ),
                        ],
                      ),
                      if (widget.sessionId != null)
                        FilterChip(
                          key: const ValueKey('artifacts-scope-all'),
                          label: Text(l10n.artifactsScopeAllChats),
                          selected: _allChats,
                          onSelected: (v) => setState(() => _allChats = v),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: items.isEmpty
                      ? AetherEmptyState(
                          icon: Icons.folder_open_outlined,
                          title: l10n.artifactsEmptyTitle,
                          message: l10n.artifactsEmptyBody,
                        )
                      : ListView.separated(
                          key: const ValueKey('artifacts-list'),
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
                          itemCount: items.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            indent: 68,
                            color: Aether.hairline,
                          ),
                          itemBuilder: (context, i) => _ArtifactRow(
                            artifact: items[i],
                            onTap: () => openArtifactPreview(context, items[i]),
                            onLongPress: () => _actions(items[i]),
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ArtifactRow extends StatelessWidget {
  const _ArtifactRow({
    required this.artifact,
    required this.onTap,
    required this.onLongPress,
  });

  final SessionArtifact artifact;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final uploaded = artifact.origin == ArtifactOrigin.uploaded;
    return Semantics(
      button: true,
      onLongPressHint: l10n.artifactActionsHint,
      child: InkWell(
        key: ValueKey('artifact-row-${artifact.id}'),
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        onTap: onTap,
        onLongPress: onLongPress,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                ArtifactThumb(artifact: artifact, size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        artifact.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Aether.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        artifactListSubtitle(context, artifact),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: Aether.textMuted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: uploaded
                      ? l10n.artifactOriginUploaded
                      : l10n.artifactOriginGenerated,
                  child: Icon(
                    uploaded
                        ? Icons.upload_rounded
                        : Icons.auto_awesome_rounded,
                    key: ValueKey(
                      uploaded ? 'artifact-origin-up' : 'artifact-origin-gen',
                    ),
                    size: 16,
                    color: uploaded ? Aether.textFaint : Aether.accent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
