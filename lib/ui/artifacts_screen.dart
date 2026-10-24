import 'dart:async';

import 'package:flutter/material.dart';

import '../core/cloud/artifact_vault.dart';
import '../core/diag.dart';
import '../core/firebase_service.dart';
import '../core/session_artifacts.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'artifact_preview.dart';
import 'widgets/aether_confirm.dart';
import 'widgets/aether_primitives.dart';

enum ArtifactFilter { all, uploaded, generated }

/// The type filter of the cloud Vault list (`All types` + the categories the
/// server filters on).
enum VaultTypeFilter { all, image, html, code, document, other }

/// Artifacts — every file the user uploaded and every file, image, page or
/// document Ovid produced, for the current chat or across all chats.
///
/// Signed-in accounts get the cloud Artifact Vault (FE-004/005/022): the
/// authoritative account inventory from the gateway, never the local
/// transcript corpus, never a local fallback on request failure. Guests get
/// the separate legacy "On this device" view, sourced from the persisted
/// transcripts (see [collectSessionArtifacts]) so nothing there can drift
/// from the chat history. Tap previews; long-press (local view only) offers
/// Share and "Remove from list" (hides the entry, never the file).
class ArtifactsScreen extends StatefulWidget {
  const ArtifactsScreen({super.key, this.sessionId, this.controller});

  /// The chat to scope to first; null opens "All chats".
  final String? sessionId;

  /// The cloud Vault controller. Tests (and callers that already own one)
  /// provide it; the screen then NEVER falls back to the local corpus. When
  /// null and the user is signed in, the screen builds its own controller.
  final ArtifactVaultController? controller;

  @override
  State<ArtifactsScreen> createState() => _ArtifactsScreenState();
}

class _ArtifactsScreenState extends State<ArtifactsScreen> {
  // Cloud Vault mode (signed-in): provided or self-owned controller.
  ArtifactVaultController? _controller;
  bool _ownsController = false;
  ValueNotifier<String?>? _accountAdapter;

  // Legacy local mode (guest only).
  ArtifactFilter _filter = ArtifactFilter.all;
  late bool _allChats = widget.sessionId == null;
  bool? _scopeAllChats;

  Timer? _searchDebounce;
  late final TextEditingController _searchText = TextEditingController();
  VaultTypeFilter _typeFilter = VaultTypeFilter.all;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      _controller = widget.controller;
      unawaited(_controller!.reload());
    } else if (FirebaseService.I.isSignedIn) {
      _wireDefaultController();
      unawaited(_controller!.reload());
    } else {
      unawaited(ArtifactListPrefs.I.load());
      // Older chats may still be deferred (not yet decoded) at startup; the
      // overall list needs their messages.
      unawaited(_hydrate());
    }
  }

  /// Builds the production Vault controller: the shared CloudRestClient,
  /// the live Firebase account, and the account-change fencing wired to it.
  void _wireDefaultController() {
    final adapter = ValueNotifier<String?>(_currentAccount());
    _accountAdapter = adapter;
    FirebaseService.I.addListener(_onFirebaseAccount);
    _controller = ArtifactVaultController(
      client: ArtifactVaultClient(accountId: () => adapter.value),
      accountChanges: adapter,
    );
    _ownsController = true;
  }

  static String? _currentAccount() {
    final svc = FirebaseService.I;
    return svc.isSignedIn && svc.uid != null ? 'firebase:${svc.uid}' : null;
  }

  void _onFirebaseAccount() {
    if (!mounted) return;
    final next = _currentAccount();
    final adapter = _accountAdapter;
    if (adapter != null && adapter.value != next) adapter.value = next;
  }

  Future<void> _hydrate() async {
    try {
      await AppState.I.loadSessionsForSearch();
    } catch (e) {
      Diag.swallow('artifacts.hydrate', e);
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchText.dispose();
    if (_accountAdapter != null) {
      FirebaseService.I.removeListener(_onFirebaseAccount);
      _accountAdapter!.dispose();
    }
    if (_ownsController) _controller?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Cloud Vault mode
  // ---------------------------------------------------------------------

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final trimmed = value.trim();
    // Debounced: typing must not fire a request per keystroke.
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted || _controller == null) return;
      unawaited(
        _controller!.setFilters(search: trimmed.isEmpty ? null : trimmed),
      );
    });
  }

  Future<void> _setVaultSource(String source) async {
    final controller = _controller;
    if (controller == null) return;
    await controller.setFilters(
      source: source,
      sessionId: _vaultSessionScope(),
    );
  }

  Future<void> _setVaultType(VaultTypeFilter type) async {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _typeFilter = type);
    await controller.setFilters(
      category: switch (type) {
        VaultTypeFilter.all => null,
        VaultTypeFilter.image => 'image',
        VaultTypeFilter.html => 'html',
        VaultTypeFilter.code => 'code',
        VaultTypeFilter.document => 'document',
        VaultTypeFilter.other => 'other',
      },
    );
  }

  Future<void> _toggleVaultScope() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() {
      _scopeAllChats = !(_scopeAllChats ?? false);
    });
    await controller.setFilters(sessionId: _vaultSessionScope());
  }

  /// The session scope: the chat this screen was opened from, unless the
  /// user widened it to every chat.
  String? _vaultSessionScope() =>
      widget.sessionId != null && (_scopeAllChats ?? false)
      ? null
      : widget.sessionId;

  Widget _buildVault(BuildContext context) {
    final l10n = context.l10n;
    final controller = _controller!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            key: const ValueKey('vault-search'),
            controller: _searchText,
            onChanged: _onSearchChanged,
            textInputAction: TextInputAction.search,
            style: TextStyle(fontSize: 13.5, color: Aether.text),
            decoration: InputDecoration(
              hintText: l10n.vaultSearchHint,
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AetherRadius.rPill),
                borderSide: BorderSide(color: Aether.hairline),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AetherRadius.rPill),
                borderSide: BorderSide(color: Aether.hairline),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
          child: AetherSegmentedControl<String>(
            key: const ValueKey('vault-tabs'),
            value: controller.source,
            onChanged: (source) => unawaited(_setVaultSource(source)),
            options: [
              (value: 'generated', label: l10n.vaultTabGenerated, icon: null),
              (value: 'uploaded', label: l10n.vaultTabUploaded, icon: null),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _VaultTypeDropdown(
                value: _typeFilter,
                onChanged: (type) => unawaited(_setVaultType(type)),
              ),
              if (widget.sessionId != null)
                FilterChip(
                  key: const ValueKey('vault-scope-all'),
                  label: Text(l10n.artifactsScopeAllChats),
                  selected: _scopeAllChats ?? false,
                  onSelected: (_) => unawaited(_toggleVaultScope()),
                ),
            ],
          ),
        ),
        Expanded(
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => _buildVaultBody(context, controller),
          ),
        ),
      ],
    );
  }

  Widget _buildVaultBody(
    BuildContext context,
    ArtifactVaultController controller,
  ) {
    final l10n = context.l10n;
    if (controller.loading) {
      return const Center(
        key: ValueKey('vault-loading'),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (controller.pageError != null && controller.items.isEmpty) {
      // Cloud failure is never a local-corpus fallback: explicit error, one
      // retry affordance.
      return AetherEmptyState(
        key: const ValueKey('vault-error'),
        icon: Icons.cloud_off_outlined,
        title: l10n.vaultErrorTitle,
        message: controller.pageError,
        action: AetherSecondaryButton(
          key: const ValueKey('vault-retry'),
          label: l10n.actionRetry,
          onPressed: () => unawaited(controller.reload()),
        ),
      );
    }
    if (controller.items.isEmpty) {
      return AetherEmptyState(
        key: const ValueKey('vault-empty'),
        icon: Icons.folder_open_outlined,
        title: l10n.artifactsEmptyTitle,
        message: l10n.artifactsEmptyBody,
      );
    }
    final more = controller.nextCursor != null;
    return Column(
      children: [
        if (controller.pageError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    controller.pageError!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: Aether.danger),
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(controller.loadMore()),
                  child: Text(l10n.actionRetry),
                ),
              ],
            ),
          ),
        Expanded(
          child: ListView.separated(
            key: const ValueKey('vault-list'),
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
            // Rows, then the explicit load-more, then the account/link
            // policy note — inside the scroll so any text scale fits.
            itemCount: controller.items.length + (more ? 2 : 1),
            separatorBuilder: (_, _) =>
                Divider(height: 1, indent: 68, color: Aether.hairline),
            itemBuilder: (context, i) {
              if (i < controller.items.length) {
                final artifact = controller.items[i];
                return _ArtifactRow(
                  artifact: artifact,
                  onTap: () => unawaited(
                    openArtifactPreview(
                      context,
                      artifact,
                      vaultClient: controller.client,
                      accountChanges: _accountAdapter,
                    ),
                  ),
                );
              }
              if (i == controller.items.length && more) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Align(
                    alignment: Alignment.center,
                    child: controller.loadingMore
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : AetherSecondaryButton(
                            key: const ValueKey('vault-load-more'),
                            label: l10n.vaultLoadMore,
                            onPressed: () => unawaited(controller.loadMore()),
                          ),
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  l10n.vaultPolicyNote,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Aether.textFaint),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Legacy local mode (guest only)
  // ---------------------------------------------------------------------

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

  Widget _buildLocal(BuildContext context) {
    final l10n = context.l10n;
    final app = AppState.I;
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
              if (MediaQuery.textScalerOf(context).scale(14) > 20)
                _ArtifactFilterDropdown(
                  value: _filter,
                  onChanged: (f) => setState(() => _filter = f),
                  labels: {
                    ArtifactFilter.all: l10n.artifactsFilterAll,
                    ArtifactFilter.uploaded: l10n.artifactsFilterUploaded,
                    ArtifactFilter.generated: l10n.artifactsFilterGenerated,
                  },
                )
              else
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
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
          child: Text(
            l10n.vaultLocalScope,
            style: TextStyle(fontSize: 12, color: Aether.textFaint),
          ),
        ),
        Expanded(
          child: AnimatedBuilder(
            animation: Listenable.merge([app, ArtifactListPrefs.I.hidden]),
            builder: (context, _) {
              final items = _visible(app, ArtifactListPrefs.I.hidden.value);
              return items.isEmpty
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
                    );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final vault = _controller != null;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(title: Text(l10n.artifactsTitle)),
      body: SafeArea(
        child: vault ? _buildVault(context) : _buildLocal(context),
      ),
    );
  }
}

class _ArtifactRow extends StatelessWidget {
  const _ArtifactRow({
    required this.artifact,
    required this.onTap,
    this.onLongPress,
  });

  final SessionArtifact artifact;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

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

/// Compact local filter for the guest Artifacts view. A segmented control's
/// three 48 dp targets wrap into a tall stack at 200% text on a 320 dp phone;
/// one accessible dropdown preserves the same choices without overflow.
class _ArtifactFilterDropdown extends StatelessWidget {
  const _ArtifactFilterDropdown({
    required this.value,
    required this.onChanged,
    required this.labels,
  });

  final ArtifactFilter value;
  final ValueChanged<ArtifactFilter> onChanged;
  final Map<ArtifactFilter, String> labels;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<ArtifactFilter>(
      key: const ValueKey('artifacts-filter'),
      initialValue: value,
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final option in ArtifactFilter.values)
          PopupMenuItem(value: option, child: Text(labels[option]!)),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AetherRadius.rPill),
          border: Border.all(color: Aether.hairline),
          color: Aether.surfaceAlt,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                labels[value]!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.expand_more_rounded, size: 16, color: Aether.textMuted),
          ],
        ),
      ),
    );
  }
}

/// Compact type filter for the Vault header: one outlined pill + dropdown —
/// a six-way segmented control does not fit narrow large-text layouts.
class _VaultTypeDropdown extends StatelessWidget {
  const _VaultTypeDropdown({required this.value, required this.onChanged});

  final VaultTypeFilter value;
  final ValueChanged<VaultTypeFilter> onChanged;

  String _label(BuildContext context, VaultTypeFilter v) => switch (v) {
    VaultTypeFilter.all => context.l10n.vaultTypeAll,
    VaultTypeFilter.image => context.l10n.artifactKindImage,
    VaultTypeFilter.html => context.l10n.artifactKindHtml,
    VaultTypeFilter.code => context.l10n.artifactKindCode,
    VaultTypeFilter.document => context.l10n.artifactKindDocument,
    VaultTypeFilter.other => context.l10n.artifactKindFile,
  };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<VaultTypeFilter>(
      key: const ValueKey('vault-type'),
      initialValue: value,
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final v in VaultTypeFilter.values)
          PopupMenuItem(value: v, child: Text(_label(context, v))),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AetherRadius.rPill),
          border: Border.all(color: Aether.hairline),
          color: Aether.surfaceAlt,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _label(context, value),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.expand_more_rounded, size: 16, color: Aether.textMuted),
          ],
        ),
      ),
    );
  }
}
