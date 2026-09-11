import 'package:flutter/material.dart';

import '../core/startup_coordinator.dart';
import '../core/theme.dart';

/// Exact user-facing state copy (spec §6.2). No item is ever labelled
/// `Working` solely because it is enabled.
String startupItemStateLabel(StartupItemState state) => switch (state) {
  StartupItemState.queued ||
  StartupItemState.running => 'Loading',
  StartupItemState.ready => 'Ready',
  StartupItemState.needsSetup => 'Needs setup',
  StartupItemState.migrationRequired => 'Migration required',
  StartupItemState.unsupported => 'Unsupported on this device',
  StartupItemState.degraded ||
  StartupItemState.skipped => 'Degraded',
  StartupItemState.failed => 'Failed',
  StartupItemState.disabled => 'Disabled',
};

/// Retry is offered for every recoverable terminal state.
bool startupItemCanRetry(StartupItemState state) =>
    state == StartupItemState.failed ||
    state == StartupItemState.degraded ||
    state == StartupItemState.skipped;

/// Only plugin/MCP items own a runtime that can be disabled.
bool startupItemCanDisable(StartupItemStatus item) =>
    item.kind == StartupItemKind.plugin || item.kind == StartupItemKind.mcp;

/// Setup/migration problems are fixed on the Plugins screen.
bool startupItemOpensPlugins(StartupItemState state) =>
    state == StartupItemState.needsSetup ||
    state == StartupItemState.migrationRequired;

bool _isProblem(StartupItemState state) =>
    state != StartupItemState.ready &&
    state != StartupItemState.disabled &&
    state != StartupItemState.queued &&
    state != StartupItemState.running;

Color _stateColor(StartupItemState state) => switch (state) {
  StartupItemState.ready => Aether.success,
  StartupItemState.failed => Aether.dangerC,
  StartupItemState.unsupported => Aether.dangerC,
  StartupItemState.disabled => Aether.textFaint,
  StartupItemState.queued || StartupItemState.running => Aether.accent,
  _ => Aether.accent,
};

IconData _stateIcon(StartupItemState state) => switch (state) {
  StartupItemState.ready => Icons.check_circle_outline,
  StartupItemState.failed => Icons.error_outline,
  StartupItemState.unsupported => Icons.block_outlined,
  StartupItemState.needsSetup => Icons.settings_outlined,
  StartupItemState.migrationRequired => Icons.upgrade_outlined,
  StartupItemState.disabled => Icons.power_settings_new,
  StartupItemState.degraded || StartupItemState.skipped => Icons.warning_amber,
  StartupItemState.queued || StartupItemState.running =>
    Icons.hourglass_empty,
};

/// Non-blocking startup readiness dashboard (spec §6.1).
///
/// A three-pixel header progress bar plus an expandable
/// `Finishing setup · X of Y` panel with one row per startup item. The
/// panel owns the single [AnimatedBuilder] that listens to the
/// [StartupCoordinator], so startup transitions never rebuild the chat
/// transcript or the composer.
class StartupProgressPanel extends StatefulWidget {
  const StartupProgressPanel({
    super.key,
    this.coordinator,
    this.onOpenPlugins,
  });

  /// Coordinator to observe. Defaults to the process singleton in
  /// production; tests inject an isolated coordinator.
  final StartupCoordinator? coordinator;

  /// Called with the item's canonical owner id (or null) when the user taps
  /// `Open Plugins`.
  final void Function(String? canonicalId)? onOpenPlugins;

  @override
  State<StartupProgressPanel> createState() => _StartupProgressPanelState();
}

class _StartupProgressPanelState extends State<StartupProgressPanel> {
  late bool _expanded;
  bool _collapseScheduled = false;

  StartupCoordinator get _coordinator =>
      widget.coordinator ?? StartupCoordinator.I;

  @override
  void initState() {
    super.initState();
    _expanded = !_coordinator.snapshot.readinessComplete;
  }

  @override
  void didUpdateWidget(StartupProgressPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coordinator != widget.coordinator) {
      _expanded = !_coordinator.snapshot.readinessComplete;
      _collapseScheduled = false;
    }
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      _collapseScheduled = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _coordinator,
      builder: (context, _) {
        final snapshot = _coordinator.snapshot;
        if (snapshot.total == 0) return const SizedBox.shrink();
        final allTerminal = snapshot.readinessComplete;

        // The panel defaults collapsed once every item reaches a terminal
        // state; the user can still re-expand it afterwards. This is derived
        // state, so it is applied during build without another frame.
        if (!allTerminal) {
          _collapseScheduled = false;
        } else if (!_collapseScheduled) {
          _collapseScheduled = true;
          _expanded = false;
        }

        final completed = snapshot.completed;
        final total = snapshot.total;
        final anyProblem = snapshot.items.any((item) => _isProblem(item.state));

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!allTerminal)
              LinearProgressIndicator(
                key: const ValueKey('startup-progress-bar'),
                value: total == 0 ? null : completed / total,
                minHeight: 3,
                backgroundColor: Aether.surfaceAlt,
                color: Aether.accent,
                semanticsLabel: 'Startup progress',
              ),
            Semantics(
              button: true,
              container: true,
              label:
                  'Finishing setup, $completed of $total'
                  '${_expanded ? ', expanded' : ', collapsed'}',
              child: InkWell(
                key: const ValueKey('startup-panel-toggle'),
                onTap: _toggle,
                child: Container(
                  color: Aether.surface,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      if (anyProblem)
                        Container(
                          key: const ValueKey('startup-warning-dot'),
                          width: 7,
                          height: 7,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: Aether.dangerC,
                            shape: BoxShape.circle,
                          ),
                        ),
                      Expanded(
                        child: Text(
                          'Finishing setup · $completed of $total',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: Aether.textMuted,
                          ),
                        ),
                      ),
                      Icon(
                        _expanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18,
                        color: Aether.textFaint,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_expanded)
              for (final item in snapshot.items)
                _StartupItemRow(
                  key: ValueKey('startup-item-${item.id}'),
                  item: item,
                  onRetry: () => _coordinator.retry(item.id),
                  onDisable: startupItemCanDisable(item)
                      ? () => _coordinator.disable(item.id)
                      : null,
                  onOpenPlugins: startupItemOpensPlugins(item.state)
                      ? () => widget.onOpenPlugins?.call(item.ownerId)
                      : null,
                ),
          ],
        );
      },
    );
  }
}

class _StartupItemRow extends StatelessWidget {
  const _StartupItemRow({
    super.key,
    required this.item,
    required this.onRetry,
    this.onDisable,
    this.onOpenPlugins,
  });

  final StartupItemStatus item;
  final VoidCallback onRetry;
  final VoidCallback? onDisable;
  final VoidCallback? onOpenPlugins;

  @override
  Widget build(BuildContext context) {
    final color = _stateColor(item.state);
    final showRetry = startupItemCanRetry(item.state);
    return Container(
      color: Aether.surface,
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(_stateIcon(item.state), size: 16, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        item.label,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      startupItemStateLabel(item.state),
                      style: TextStyle(fontSize: 11.5, color: color),
                    ),
                  ],
                ),
                if (item.reason != null && item.reason!.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    item.reason!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: Aether.textFaint),
                  ),
                ],
                if (showRetry || onDisable != null || onOpenPlugins != null) ...[
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 2,
                    children: [
                      if (showRetry)
                        TextButton(
                          key: ValueKey('startup-retry-${item.id}'),
                          onPressed: onRetry,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            minimumSize: const Size(0, 30),
                          ),
                          child: const Text(
                            'Retry',
                            style: TextStyle(fontSize: 11.5),
                          ),
                        ),
                      if (onDisable != null)
                        TextButton(
                          key: ValueKey('startup-disable-${item.id}'),
                          onPressed: onDisable,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            minimumSize: const Size(0, 30),
                          ),
                          child: const Text(
                            'Disable',
                            style: TextStyle(fontSize: 11.5),
                          ),
                        ),
                      if (onOpenPlugins != null)
                        TextButton(
                          key: ValueKey('startup-open-plugins-${item.id}'),
                          onPressed: onOpenPlugins,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            minimumSize: const Size(0, 30),
                          ),
                          child: const Text(
                            'Open Plugins',
                            style: TextStyle(fontSize: 11.5),
                          ),
                        ),
                    ],
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
