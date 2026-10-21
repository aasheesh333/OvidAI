import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

enum V2SharedMemoryStatus { loading, ready, empty, error }

/// Where a shared fact may be reused.
enum V2SharedMemoryScopeKind { chat, project, global }

/// One place facts from this chat can be shared with.
@immutable
class V2SharedMemoryScope {
  const V2SharedMemoryScope({
    required this.id,
    required this.kind,
    required this.title,
    required this.description,
    required this.audience,
    this.shared = false,
  });

  final String id;
  final V2SharedMemoryScopeKind kind;
  final String title;
  final String description;

  /// Who can see facts shared in this scope, in plain language.
  final String audience;
  final bool shared;
}

/// Injected state for the Shared memory screen.
///
/// The page is presentational: it never reads [AppState] itself. The caller
/// maps the switches to `memoryEnabled` / `setShareSessionMemory` and owns the
/// "forget" request.
@immutable
class V2SharedMemoryPageData {
  const V2SharedMemoryPageData({
    this.status = V2SharedMemoryStatus.ready,
    this.enabled = false,
    this.scopes = defaultScopes,
    this.factCount = 0,
    this.retentionLabel =
        'Shared facts stay until you forget them. Project members keep their '
        'own copy of anything they already used.',
    this.onEnabledChanged,
    this.onScopeChanged,
    this.onForget,
    this.onRetry,
    this.errorMessage = 'We could not load shared memory.',
  });

  /// The three scopes the product offers, in display order.
  static const defaultScopes = <V2SharedMemoryScope>[
    V2SharedMemoryScope(
      id: 'chat',
      kind: V2SharedMemoryScopeKind.chat,
      title: 'This chat',
      description: 'Facts learned in this conversation.',
      audience: 'Only you',
      shared: true,
    ),
    V2SharedMemoryScope(
      id: 'project',
      kind: V2SharedMemoryScopeKind.project,
      title: 'Project',
      description: 'Facts this project can reuse.',
      audience: 'Project members',
    ),
    V2SharedMemoryScope(
      id: 'global',
      kind: V2SharedMemoryScopeKind.global,
      title: 'Global',
      description: 'Facts reused in every chat you start.',
      audience: 'Only you, everywhere',
    ),
  ];

  final V2SharedMemoryStatus status;

  /// Master sharing switch. Off keeps every fact inside this chat.
  final bool enabled;
  final List<V2SharedMemoryScope> scopes;
  final int factCount;
  final String retentionLabel;

  final ValueChanged<bool>? onEnabledChanged;

  /// Called with the scope id and the requested value.
  final void Function(String id, bool value)? onScopeChanged;

  /// Removes every shared fact. The page asks for confirmation first.
  final VoidCallback? onForget;
  final VoidCallback? onRetry;
  final String errorMessage;

  bool get hasSharedFacts => factCount > 0;

  int get sharedScopeCount => scopes.where((scope) => scope.shared).length;
}

/// Shared memory: what leaves this chat, who sees it, and how to forget it.
class SharedMemoryPage extends StatefulWidget {
  const SharedMemoryPage({super.key, required this.data});

  final V2SharedMemoryPageData data;

  @override
  State<SharedMemoryPage> createState() => _SharedMemoryPageState();
}

class _SharedMemoryPageState extends State<SharedMemoryPage> {
  late bool _enabled = widget.data.enabled;
  late List<V2SharedMemoryScope> _scopeList = widget.data.scopes;
  late int _factCount = widget.data.factCount;

  V2SharedMemoryPageData get data => widget.data;

  bool get _hasSharedFacts => _factCount > 0;

  int get _sharedScopeCount =>
      _scopeList.where((scope) => scope.shared).length;

  @override
  void didUpdateWidget(covariant SharedMemoryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.data, widget.data)) {
      _enabled = widget.data.enabled;
      _scopeList = widget.data.scopes;
      _factCount = widget.data.factCount;
    }
  }

  /// The switch updates immediately and then reports to the owner. Without the
  /// local copy a screen that is not rebuilt by its parent would look dead.
  void _setEnabled(bool value) {
    setState(() => _enabled = value);
    data.onEnabledChanged?.call(value);
  }

  void _setScope(String id, bool value) {
    setState(() {
      _scopeList = [
        for (final scope in _scopeList)
          scope.id == id
              ? V2SharedMemoryScope(
                  id: scope.id,
                  kind: scope.kind,
                  title: scope.title,
                  description: scope.description,
                  audience: scope.audience,
                  shared: value,
                )
              : scope,
      ];
    });
    data.onScopeChanged?.call(id, value);
  }

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'Shared memory'),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    switch (data.status) {
      case V2SharedMemoryStatus.loading:
        return OFadeSlide(
          child: Semantics(
            label: 'Loading shared memory',
            child: const OSkeletonList(rows: 6),
          ),
        );
      case V2SharedMemoryStatus.error:
        return OErrorState(message: data.errorMessage, onRetry: data.onRetry);
      case V2SharedMemoryStatus.empty:
        return _empty(context);
      case V2SharedMemoryStatus.ready:
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
                _masterCard(context),
                _scopes(context),
                _retention(context),
                _danger(context),
              ],
            ),
          ),
        );
    }
  }

  Widget _empty(BuildContext context) {
    final canTurnOn = !_enabled && data.onEnabledChanged != null;
    return OEmptyState(
      icon: Icons.share_outlined,
      title: 'Nothing is shared yet',
      message:
          'Facts from your chats stay private until you choose a scope to '
          'share them with.',
      action: canTurnOn
          ? OButton(
              label: 'Turn on sharing',
              icon: Icons.share_rounded,
              onPressed: () => _setEnabled(true),
            )
          : OButton(
              label: 'Refresh',
              icon: Icons.refresh_rounded,
              onPressed: data.onRetry,
            ),
    );
  }

  Widget _explainer(BuildContext context) {
    final c = OColors.of(context);
    final count = _factCount;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
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
              child: Icon(Icons.share_rounded, size: 21, color: c.accent),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'What shared memory does',
                    style: OType.bodyStrong.copyWith(color: c.text),
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    'Facts from this chat can be reused by project members, so '
                    'nobody has to repeat the same context.',
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                  const SizedBox(height: OSpace.s),
                  Wrap(
                    spacing: OSpace.m,
                    runSpacing: OSpace.xs,
                    children: [
                      Text(
                        '$count ${count == 1 ? 'fact' : 'facts'} shared',
                        style: OType.caption.copyWith(
                          color: count == 0 ? c.textMuted : c.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        _enabled ? 'Sharing on' : 'Sharing off',
                        style: OType.caption.copyWith(
                          color: _enabled ? c.success : c.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
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

  Widget _masterCard(BuildContext context) {
    final c = OColors.of(context);
    final enabled = _enabled;
    final canToggle = data.onEnabledChanged != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
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
                          enabled ? 'Sharing on' : 'Sharing off',
                          style: OType.h2.copyWith(color: c.text),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: OSpace.xs),
                  Text(
                    enabled
                        ? 'Facts you mark below can leave this chat.'
                        : 'Facts stay inside this chat.',
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.m),
            Semantics(
              key: const ValueKey<String>('shared-memory-master-toggle'),
              label: 'Share memory',
              toggled: enabled,
              button: true,
              enabled: canToggle,
              onTap: canToggle ? () => _setEnabled(!enabled) : null,
              child: ExcludeSemantics(
                child: Switch(
                  key: const ValueKey<String>('shared-memory-master-switch'),
                  value: enabled,
                  onChanged: canToggle ? _setEnabled : null,
                  activeThumbColor: canToggle ? c.onAccent : c.textFaint,
                  activeTrackColor: canToggle ? c.accentFill : c.surfaceRaised,
                  inactiveThumbColor: c.textFaint,
                  inactiveTrackColor: c.surfaceRaised,
                  trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scopes(BuildContext context) {
    final c = OColors.of(context);
    final total = _scopeList.length;
    final shared = _sharedScopeCount;
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: 'Scopes',
            padding: const EdgeInsets.only(bottom: OSpace.s),
            trailing: Text(
              '$shared of $total shared',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < _scopeList.length; i++) ...[
                  if (i > 0) Divider(color: c.hairline, height: 1),
                  _scopeRow(context, _scopeList[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _scopeRow(BuildContext context, V2SharedMemoryScope scope) {
    final c = OColors.of(context);
    final canToggle = data.onScopeChanged != null && _enabled;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.m,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Icon(
                _scopeIcon(scope.kind),
                size: 19,
                color: canToggle ? c.textMuted : c.textFaint,
              ),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    scope.title,
                    style: OType.body.copyWith(
                      color: canToggle ? c.text : c.textMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    scope.description,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                  const SizedBox(height: OSpace.xs),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.visibility_outlined,
                        size: 14,
                        color: c.textFaint,
                      ),
                      const SizedBox(width: OSpace.xs),
                      Flexible(
                        child: Text(
                          'Who can see it: ${scope.audience}',
                          style: OType.caption.copyWith(color: c.textFaint),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.s),
            Semantics(
              label: scope.title,
              toggled: scope.shared,
              button: true,
              enabled: canToggle,
              onTap: canToggle
                  ? () => _setScope(scope.id, !scope.shared)
                  : null,
              child: ExcludeSemantics(
                child: Switch(
                  key: ValueKey<String>(
                    'shared-memory-scope-${scope.id}-switch',
                  ),
                  value: scope.shared,
                  onChanged: canToggle
                      ? (next) => _setScope(scope.id, next)
                      : null,
                  activeThumbColor: canToggle ? c.onAccent : c.textFaint,
                  activeTrackColor: canToggle ? c.accentFill : c.surfaceRaised,
                  inactiveThumbColor: c.textFaint,
                  inactiveTrackColor: c.surfaceRaised,
                  trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _retention(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: OCard(
        padding: const EdgeInsets.all(OSpace.m),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.schedule_rounded, size: 20, color: c.textMuted),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                data.retentionLabel,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _danger(BuildContext context) {
    final c = OColors.of(context);
    final canForget = data.onForget != null && _hasSharedFacts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OButton(
          key: const ValueKey<String>('forget-shared-facts'),
          label: 'Forget shared facts',
          icon: Icons.delete_sweep_outlined,
          variant: OButtonVariant.danger,
          expand: true,
          onPressed: canForget ? () => _confirmForget(context) : null,
        ),
        const SizedBox(height: OSpace.s),
        Text(
          _hasSharedFacts
              ? 'Removes every shared fact for everyone it was shared with. '
                    'This cannot be undone.'
              : 'There are no shared facts to forget.',
          textAlign: TextAlign.center,
          style: OType.caption.copyWith(color: c.textFaint),
        ),
      ],
    );
  }

  Future<void> _confirmForget(BuildContext context) async {
    final count = _factCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final c = OColors.of(dialogContext);
        return AlertDialog(
          backgroundColor: c.surface,
          title: Text(
            'Forget shared facts?',
            style: OType.h2.copyWith(color: c.text),
          ),
          content: Text(
            'This removes $count shared ${count == 1 ? 'fact' : 'facts'}. '
            'Project members will no longer be able to reuse them. '
            'This cannot be undone.',
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: TextButton.styleFrom(foregroundColor: c.danger),
              child: const Text('Forget'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      // Forget really removes the shared facts: the count drops to zero and
      // every scope stops sharing, so the screen cannot keep claiming there
      // are facts that the server just deleted.
      setState(() {
        _factCount = 0;
        _scopeList = [
          for (final scope in _scopeList)
            V2SharedMemoryScope(
              id: scope.id,
              kind: scope.kind,
              title: scope.title,
              description: scope.description,
              audience: scope.audience,
            ),
        ];
      });
      data.onForget?.call();
    }
  }

  IconData _scopeIcon(V2SharedMemoryScopeKind kind) {
    return switch (kind) {
      V2SharedMemoryScopeKind.chat => Icons.forum_outlined,
      V2SharedMemoryScopeKind.project => Icons.folder_outlined,
      V2SharedMemoryScopeKind.global => Icons.public_rounded,
    };
  }
}
