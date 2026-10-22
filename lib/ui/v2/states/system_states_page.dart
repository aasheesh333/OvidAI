import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'state_tiles.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// The live conditions that can stop a chat, in one small value object.
///
/// [precedence] is the reading order: a dead connection leads because no
/// server condition can be verified without one; a blocked account outranks an
/// exhausted allowance, which outranks a short rate limit. The app update is a
/// client-level notice and follows the chat conditions. Every flag maps to at
/// most one [V2StateTileKind], so the screen can never render the same
/// condition twice.
@immutable
class V2SystemStatesData {
  const V2SystemStatesData({
    this.offline = false,
    this.blocked = false,
    this.allowanceUsed = false,
    this.allowanceResetsAt,
    this.rateLimitedUntil,
    this.updateRequired = false,
  });

  /// The device cannot reach Ovid; messages wait in the queue.
  final bool offline;

  /// The account is suspended and needs support.
  final bool blocked;

  /// The plan allowance is spent. Clears automatically once
  /// [allowanceResetsAt] has passed (or immediately when no reset is known).
  final bool allowanceUsed;

  /// The server's allowance reset instant, when one is known.
  final DateTime? allowanceResetsAt;

  /// The instant the short rate-limit window closes. Null means no rate limit;
  /// a past instant is already clear.
  final DateTime? rateLimitedUntil;

  /// This build is too old to keep chatting.
  final bool updateRequired;

  /// One condition, one tile, in the order a person should read them.
  static const precedence = <V2StateTileKind>[
    V2StateTileKind.offline,
    V2StateTileKind.abuseBlocked,
    V2StateTileKind.planLimited,
    V2StateTileKind.rateLimited,
    V2StateTileKind.updateRequired,
  ];

  /// Returns each active condition exactly once, in [precedence] order.
  ///
  /// Passing [now] makes the derived allowance and rate-limit windows
  /// testable. A deadline in the past clears its condition instead of leaving
  /// a zero-countdown tile behind.
  List<V2StateTileKind> activeConditions({DateTime? now}) {
    final at = now ?? DateTime.now();
    final active = <V2StateTileKind>{
      if (offline) V2StateTileKind.offline,
      if (blocked) V2StateTileKind.abuseBlocked,
      if (allowanceUsed &&
          (allowanceResetsAt == null || allowanceResetsAt!.isAfter(at)))
        V2StateTileKind.planLimited,
      if (rateLimitedUntil != null && rateLimitedUntil!.isAfter(at))
        V2StateTileKind.rateLimited,
      if (updateRequired) V2StateTileKind.updateRequired,
    };
    return <V2StateTileKind>[
      for (final kind in precedence)
        if (active.contains(kind)) kind,
    ];
  }
}

/// The conditions blocking chat, with one real exit per condition.
///
/// This is deliberately not a gallery: a state is shown only while its
/// condition is live, and the screen recovers to one calm "All clear" view
/// when nothing is wrong. The host supplies the callbacks; a tile whose exit
/// has no handler still shows the label but announces itself as disabled, so
/// the preview never invents a route that does not exist.
class V2SystemStatesPage extends StatelessWidget {
  const V2SystemStatesPage({
    super.key,
    this.data = const V2SystemStatesData(),
    this.onRetryConnection,
    this.onSeePlans,
    this.onContactSupport,
    this.onRetryRateLimit,
    this.onOpenStore,
    this.onBackToChat,
    this.clock,
  });

  final V2SystemStatesData data;

  /// Offline: probe the connection again.
  final VoidCallback? onRetryConnection;

  /// Allowance used: open the plan chooser.
  final VoidCallback? onSeePlans;

  /// Blocked: open the support channel.
  final VoidCallback? onContactSupport;

  /// Rate limited: retry once the countdown reaches zero.
  final VoidCallback? onRetryRateLimit;

  /// Update required: open the platform store listing.
  final VoidCallback? onOpenStore;

  /// Recovered: return to the conversation.
  final VoidCallback? onBackToChat;

  /// Clock source for the live countdowns. Defaults to [DateTime.now].
  final DateTime Function()? clock;

  @override
  Widget build(BuildContext context) {
    final now = clock?.call() ?? DateTime.now();
    final kinds = data.activeConditions(now: now);
    final Widget body;
    if (kinds.isEmpty) {
      body = OEmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: 'All clear',
        message: 'Ovid is ready when you are.',
        action: onBackToChat == null
            ? null
            : OButton(
                label: 'Back to chat',
                variant: OButtonVariant.secondary,
                onPressed: onBackToChat,
              ),
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
        itemCount: kinds.length,
        separatorBuilder: (_, _) => const SizedBox(height: OSpace.m),
        itemBuilder: (context, index) => _buildTile(kinds[index]),
      );
    }

    return OScreen(
      title: 'System states',
      subtitle: 'What is blocking chat',
      child: body,
    );
  }

  Widget _buildTile(V2StateTileKind kind) {
    return switch (kind) {
      V2StateTileKind.offline => V2StateTile.offline(
        clock: clock,
        onAction: onRetryConnection,
      ),
      V2StateTileKind.planLimited => V2StateTile.planLimited(
        deadline: data.allowanceResetsAt,
        clock: clock,
        onAction: onSeePlans,
      ),
      V2StateTileKind.abuseBlocked => V2StateTile.abuseBlocked(
        clock: clock,
        onAction: onContactSupport,
      ),
      V2StateTileKind.rateLimited => V2StateTile.rateLimited(
        deadline: data.rateLimitedUntil,
        clock: clock,
        onAction: onRetryRateLimit,
      ),
      V2StateTileKind.updateRequired => V2StateTile.updateRequired(
        clock: clock,
        onAction: onOpenStore,
      ),
      // [V2SystemStatesData.precedence] only names the five live conditions
      // above; the remaining kinds stay available to other screens through
      // the tile component.
      _ => V2StateTile(kind: kind, clock: clock),
    };
  }
}
