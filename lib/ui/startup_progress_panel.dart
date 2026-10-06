import 'package:flutter/material.dart';

import '../core/startup_coordinator.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Exact user-facing state copy (spec §6.2). No item is ever labelled
/// `Working` solely because it is enabled.
String startupItemStateLabel(StartupItemState state) => switch (state) {
  StartupItemState.queued ||
  StartupItemState.running => 'Loading',
  StartupItemState.ready => 'Ready',
  StartupItemState.needsSetup => 'Needs setup',
  StartupItemState.migrationRequired => 'Migration required',
  StartupItemState.unsupported => 'Unsupported on this device',
  StartupItemState.degraded => 'Degraded',
  // Skipped is informational (not installed / cooled down), never an
  // error — it must not read as a Degraded warning.
  StartupItemState.skipped => 'Skipped',
  StartupItemState.failed => 'Failed',
  StartupItemState.disabled => 'Disabled',
};

/// Retry is offered for every recoverable terminal state.
bool startupItemCanRetry(StartupItemState state) =>
    state == StartupItemState.failed ||
    state == StartupItemState.degraded ||
    state == StartupItemState.skipped;

/// Only items whose backing task exposes a real disable callback can be
/// disabled. The coordinator sets [StartupItemStatus.canDisable] from the
/// task's `onDisable`; aggregate rows never have one.
bool startupItemCanDisable(StartupItemStatus item) => item.canDisable;

/// Setup/migration problems are fixed on the Plugins screen.
bool startupItemOpensPlugins(StartupItemState state) =>
    state == StartupItemState.needsSetup ||
    state == StartupItemState.migrationRequired;

/// States that need no attention: success, user-disabled, or informationally
/// skipped (not installed / cooled down). Anything else keeps the bar
/// visible; when every item is benign-terminal the whole bar is gone.
bool _isBenignTerminal(StartupItemState state) =>
    state == StartupItemState.ready ||
    state == StartupItemState.disabled ||
    state == StartupItemState.skipped;

bool _isProblem(StartupItemState state) => !_isBenignTerminal(state) &&
    state != StartupItemState.queued &&
    state != StartupItemState.running;

Color _stateColor(StartupItemState state) => switch (state) {
  StartupItemState.ready => Aether.successLight,
  StartupItemState.failed => Aether.dangerC,
  StartupItemState.unsupported => Aether.dangerC,
  StartupItemState.disabled => Aether.textFaint,
  StartupItemState.skipped => Aether.textFaint,
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
  StartupItemState.degraded => Icons.warning_amber,
  StartupItemState.skipped => Icons.info_outline,
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
    this.onInstallSandbox,
    this.sandboxInstalled = false,
  });

  /// Coordinator to observe. Defaults to the process singleton in
  /// production; tests inject an isolated coordinator.
  final StartupCoordinator? coordinator;

  /// Called with the item's canonical owner id (or null) when the user taps
  /// `Open Plugins`.
  final void Function(String? canonicalId)? onOpenPlugins;

  /// Called when the user taps `Install` on the sandbox row (sandbox not
  /// installed): the host is expected to open Studio setup. Null hides the
  /// button (tests, embeds without Studio).
  final VoidCallback? onInstallSandbox;

  /// Whether the native sandbox already exists on this device. `Install` on
  /// the sandbox row means "the sandbox is missing, go set it up"; offering
  /// it beside a Degraded-but-installed row reads as "reinstall now" and
  /// invites the user to nuke a working sandbox. Defaults to false so a host
  /// that never reports the flag keeps the historical actionable behaviour.
  final bool sandboxInstalled;

  @override
  State<StartupProgressPanel> createState() => _StartupProgressPanelState();
}

class _StartupProgressPanelState extends State<StartupProgressPanel> {
  late bool _expanded;
  bool _wasIncomplete = false;

  StartupCoordinator get _coordinator =>
      widget.coordinator ?? StartupCoordinator.I;

  @override
  void initState() {
    super.initState();
    _expanded = false;
  }

  @override
  void didUpdateWidget(StartupProgressPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coordinator != widget.coordinator) {
      _expanded = false;
      _wasIncomplete = false;
    }
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _coordinator,
      builder: (context, _) {
        final snapshot = _coordinator.snapshot;
        if (snapshot.total == 0) {
          _wasIncomplete = false;
          return const SizedBox.shrink();
        }
        final allTerminal = snapshot.readinessComplete;

        // Readiness starts post-frame in production: the first build sees an
        // empty snapshot, then tasks queue on a later notification. The
        // panel stays collapsed unless the user expands it — the header
        // row plus warning dot carry the signal. Auto-collapse once every
        // item is terminal so a stale expansion never sticks.
        if (!allTerminal && !_wasIncomplete) {
          _wasIncomplete = true;
        } else if (allTerminal && _wasIncomplete) {
          _wasIncomplete = false;
          _expanded = false;
        }

        final completed = snapshot.completed;
        final total = snapshot.total;
        final anyProblem = snapshot.items.any((item) => _isProblem(item.state));

        // Nothing left that needs attention (every item ready, disabled,
        // or skipped): the bar is gone entirely instead of lingering as
        // an empty "Finishing setup" shell.
        if (allTerminal && !anyProblem) {
          _wasIncomplete = false;
          return const SizedBox.shrink();
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!allTerminal)
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  key: const ValueKey('startup-progress-bar'),
                  value: total == 0 ? null : completed / total,
                  minHeight: 3,
                  backgroundColor: Aether.surfaceAlt,
                  color: Aether.accent,
                  semanticsLabel: 'Startup progress',
                ),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
                child: AetherCard(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                  color: Aether.surface,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Step label + caption summarising what the panel
                      // is doing right now (the currently running task's
                      // label when any, otherwise the aggregate "finished"
                      // caption). This also doubles as the AetherCard
                      // header mandated by the UI redesign brief.
                      _StartupStepHeader(
                        snapshot: snapshot,
                        allTerminal: allTerminal,
                        anyProblem: anyProblem,
                      ),
                      const SizedBox(height: 6),
                      Divider(
                        height: 1,
                        thickness: 1,
                        color: Aether.hairline,
                      ),
                      const SizedBox(height: 6),
                      for (final item in snapshot.items)
                        _StartupItemRow(
                          key: ValueKey('startup-item-${item.id}'),
                          item: item,
                          onRetry: () => _coordinator.retry(item.id),
                          onDisable: startupItemCanDisable(item)
                              ? () => _coordinator.disable(item.id)
                              : null,
                          onOpenPlugins: startupItemOpensPlugins(item.state) &&
                                  widget.onOpenPlugins != null
                              ? () =>
                                    widget.onOpenPlugins?.call(item.ownerId)
                              : null,
                          // Sandbox-not-installed is actionable (not just
                          // retryable): one tap opens Studio setup. Once
                          // the sandbox exists the row must not offer
                          // Install — a Degraded installed sandbox needs
                          // Retry/Repair, not a reinstall.
                          onInstallSandbox:
                              item.id == 'sandbox.selfHeal' &&
                                  !widget.sandboxInstalled &&
                                  widget.onInstallSandbox != null
                              ? widget.onInstallSandbox
                              : null,
                          // A live (possibly deadline-abandoned) invocation
                          // makes Retry/Disable no-ops in the coordinator,
                          // so say so instead of accepting a tap that
                          // silently does nothing.
                          busy: _coordinator.isItemRunning(item.id),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Compact header above the item rows summarising the current wave:
/// the currently running step label (so the user sees "Mounting skills…"
/// not just an abstract bar) with a caption underneath. When nothing is
/// still working, it falls back to a problem/complete caption.
class _StartupStepHeader extends StatelessWidget {
  const _StartupStepHeader({
    required this.snapshot,
    required this.allTerminal,
    required this.anyProblem,
  });

  final StartupSnapshot snapshot;
  final bool allTerminal;
  final bool anyProblem;

  @override
  Widget build(BuildContext context) {
    final running = snapshot.items.firstWhere(
      (i) =>
          i.state == StartupItemState.running ||
          i.state == StartupItemState.queued,
      orElse: () => snapshot.items.first,
    );
    final isRunning =
        running.state == StartupItemState.running ||
        running.state == StartupItemState.queued;

    final title = isRunning
        ? running.label
        : (anyProblem
            ? 'Some items need attention'
            : 'All startup items ready');
    final caption = isRunning
        ? 'Working on this step while the rest queues…'
        : (anyProblem
            ? 'Review the rows below to retry, disable or install.'
            : 'You are good to go.');
    final color = anyProblem && !isRunning
        ? Aether.dangerC
        : (isRunning ? Aether.accent : Aether.successLight);
    final icon = anyProblem && !isRunning
        ? Icons.warning_amber_rounded
        : (isRunning
            ? Icons.hourglass_bottom_rounded
            : Icons.check_circle_outline);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                caption,
                style: AetherType.caption,
              ),
            ],
          ),
        ),
      ],
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
    this.onInstallSandbox,
    this.busy = false,
  });

  final StartupItemStatus item;
  final VoidCallback onRetry;
  final VoidCallback? onDisable;
  final VoidCallback? onOpenPlugins;
  final VoidCallback? onInstallSandbox;

  /// True while the coordinator still has a live invocation for this item
  /// (including one its own deadline abandoned). Retry/Disable are no-ops in
  /// that window, so the row shows a disabled `Working…` rather than a
  /// button that appears broken.
  final bool busy;

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
                    // Long state copy ("Unsupported on this device",
                    // "Migration required") must wrap, not overflow the row at
                    // large text scales.
                    Flexible(
                      child: Text(
                        startupItemStateLabel(item.state),
                        textAlign: TextAlign.end,
                        softWrap: true,
                        style: TextStyle(fontSize: 11.5, color: color),
                      ),
                    ),
                  ],
                ),
                if (item.reason != null && item.reason!.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    item.reason!,
                    style: TextStyle(fontSize: 11, color: Aether.textFaint),
                  ),
                ],
                if (showRetry || busy ||
                    onDisable != null ||
                    onOpenPlugins != null ||
                    onInstallSandbox != null) ...[
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 2,
                    children: [
                      if (onInstallSandbox != null)
                        TextButton(
                          key: ValueKey('startup-install-${item.id}'),
                          onPressed: onInstallSandbox,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            minimumSize: const Size(0, 30),
                          ),
                          child: const Text(
                            'Install',
                            style: TextStyle(fontSize: 11.5),
                          ),
                        ),
                      // `busy` renders the row even when the state is not
                      // normally retryable: a deadline-abandoned invocation is
                      // still live, so Retry/Disable are no-ops and the row must
                      // SAY so (disabled `Working…`) rather than hide the only
                      // affordance that explains why nothing responds.
                      if (showRetry || busy)
                        TextButton(
                          key: ValueKey('startup-retry-${item.id}'),
                          onPressed: busy ? null : onRetry,
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                            ),
                            minimumSize: const Size(0, 30),
                          ),
                          child: Text(
                            busy ? 'Working…' : 'Retry',
                            style: const TextStyle(fontSize: 11.5),
                          ),
                        ),
                      if (onDisable != null)
                        TextButton(
                          key: ValueKey('startup-disable-${item.id}'),
                          onPressed: busy ? null : onDisable,
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
