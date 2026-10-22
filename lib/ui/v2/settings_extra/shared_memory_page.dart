import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../settings/memory_page.dart';
import '../settings/settings_rows.dart';

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

/// Shared memory: one list, one scope filter, one switch per row.
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
  V2SharedMemoryScopeKind? _kindFilter;

  V2SharedMemoryPageData get data => widget.data;

  bool get _hasSharedFacts => _factCount > 0;

  List<V2SharedMemoryScope> get _visibleScopes => _kindFilter == null
      ? _scopeList
      : _scopeList.where((scope) => scope.kind == _kindFilter).toList();

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
    return OScreen(title: 'Shared memory', child: _body(context));
  }

  Widget _body(BuildContext context) {
    switch (data.status) {
      case V2SharedMemoryStatus.loading:
        return const OSkeletonList(rows: 6);
      case V2SharedMemoryStatus.error:
        return OErrorState(message: data.errorMessage, onRetry: data.onRetry);
      case V2SharedMemoryStatus.empty:
        return _empty();
      case V2SharedMemoryStatus.ready:
        return _content(context);
    }
  }

  Widget _empty() {
    final canTurnOn = !_enabled && data.onEnabledChanged != null;
    final Widget? action;
    if (canTurnOn) {
      action = OButton(
        label: 'Turn on sharing',
        icon: Icons.share_rounded,
        onPressed: () => _setEnabled(true),
      );
    } else if (data.onRetry != null) {
      action = OButton(
        label: 'Refresh',
        icon: Icons.refresh_rounded,
        onPressed: data.onRetry,
      );
    } else {
      action = null;
    }
    return OEmptyState(
      icon: Icons.share_outlined,
      title: 'Nothing is shared yet',
      message: 'Facts stay here until shared.',
      action: action,
    );
  }

  Widget _content(BuildContext context) {
    final scopes = _visibleScopes;
    final canToggle = data.onEnabledChanged != null;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _scopeFilter(),
          const SizedBox(height: OSpace.s),
          V2SettingsRowList(
            rows: [
              V2SettingsRow(
                icon: Icons.share_rounded,
                title: 'Share memory',
                showChevron: false,
                onTap: canToggle ? () => _setEnabled(!_enabled) : null,
                enabled: canToggle,
                trailing: _switch(
                  key: const ValueKey<String>('shared-memory-master-switch'),
                  label: 'Share memory',
                  value: _enabled,
                  onChanged: canToggle ? _setEnabled : null,
                ),
              ),
              for (final scope in scopes)
                V2SettingsRow(
                  icon: _scopeIcon(scope.kind),
                  title: scope.title,
                  subtitle: scope.audience,
                  showChevron: false,
                  enabled: _enabled,
                  onTap: data.onScopeChanged == null || !_enabled
                      ? null
                      : () => _setScope(scope.id, !scope.shared),
                  trailing: _switch(
                    key: ValueKey<String>(
                      'shared-memory-scope-${scope.id}-switch',
                    ),
                    label: scope.title,
                    value: scope.shared,
                    onChanged: data.onScopeChanged == null || !_enabled
                        ? null
                        : (next) => _setScope(scope.id, next),
                  ),
                ),
            ],
          ),
          if (data.onForget != null) ...[
            const SizedBox(height: OSpace.l),
            OButton(
              key: const ValueKey<String>('forget-shared-facts'),
              label: 'Forget shared facts',
              icon: Icons.delete_sweep_outlined,
              variant: OButtonVariant.danger,
              expand: true,
              onPressed: _hasSharedFacts ? () => _confirmForget(context) : null,
            ),
          ],
        ],
      ),
    );
  }

  Widget _scopeFilter() {
    return V2MemoryScopeBar(
      keyPrefix: 'shared-memory-filter',
      labels: [
        'All',
        for (final kind in V2SharedMemoryScopeKind.values)
          switch (kind) {
            V2SharedMemoryScopeKind.chat => 'Chat',
            V2SharedMemoryScopeKind.project => 'Project',
            V2SharedMemoryScopeKind.global => 'Global',
          },
      ],
      selected: _kindFilter == null ? 0 : _kindFilter!.index + 1,
      onSelected: (index) => setState(
        () => _kindFilter = index == 0
            ? null
            : V2SharedMemoryScopeKind.values[index - 1],
      ),
    );
  }

  Widget _switch({
    required Key key,
    required String label,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final c = OColors.of(context);
    final enabled = onChanged != null;
    return Semantics(
      label: label,
      toggled: value,
      button: true,
      enabled: enabled,
      onTap: enabled ? () => onChanged(!value) : null,
      child: ExcludeSemantics(
        child: Switch(
          key: key,
          value: value,
          onChanged: onChanged,
          activeThumbColor: enabled ? c.onAccent : c.textFaint,
          activeTrackColor: enabled ? c.accentFill : c.surfaceRaised,
          inactiveThumbColor: c.textFaint,
          inactiveTrackColor: c.surfaceRaised,
          trackOutlineColor: WidgetStatePropertyAll(c.hairlineStrong),
          materialTapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),
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
