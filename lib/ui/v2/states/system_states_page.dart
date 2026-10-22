import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'state_tiles.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// Copy for the calm system states used across chat.
///
/// The page renders one [V2StateTile] for each state. Every line can be
/// overridden by the caller; the six built-in tile copies in `state_tiles.dart`
/// supply the defaults for the newer states (storage, suspension and pending
/// deletion) when a line is left null.
@immutable
class V2SystemStatesData {
  const V2SystemStatesData({
    this.emptyTitle = 'Start with a hello',
    this.emptyMessage =
        'Ask a coding question, brainstorm ideas, or let Ovid browse the web for you.',
    this.emptyActionLabel = 'Try an example prompt',
    this.offlineTitle = 'You are offline',
    this.offlineMessage =
        'No internet connection detected. Your messages will send when you reconnect.',
    this.offlineActionLabel = 'Retry connection',
    this.errorTitle = 'Something went wrong',
    this.errorMessage =
        'Ovid could not finish this run because the service timed out. Your changes are safe.',
    this.errorActionLabel = 'Try again',
    this.errorDetailsLabel = 'View error details',
    this.limitTitle = 'Daily limit reached',
    this.limitMessage =
        "You have used all 50M of today's free tokens. Your allowance resets "
        'at the end of its 24-hour window.',
    this.limitResetLabel = 'Resets soon',
    this.limitActionLabel = 'See plans',
    this.storageTitle,
    this.storageMessage,
    this.storageActionLabel,
    this.abuseTitle,
    this.abuseMessage,
    this.abuseActionLabel,
    this.deletionTitle,
    this.deletionMessage,
    this.deletionActionLabel,
    this.footerNote =
        'Your chats and files stay safe in every state. Nothing is lost.',
  });

  final String emptyTitle;
  final String emptyMessage;
  final String emptyActionLabel;
  final String offlineTitle;
  final String offlineMessage;
  final String offlineActionLabel;
  final String errorTitle;
  final String errorMessage;
  final String errorActionLabel;
  final String errorDetailsLabel;
  final String limitTitle;
  final String limitMessage;
  final String limitResetLabel;
  final String limitActionLabel;

  /// Optional overrides for the storage-full tile. Null keeps the shared
  /// [V2StateTileCopy.storageFull] line.
  final String? storageTitle;
  final String? storageMessage;
  final String? storageActionLabel;

  /// Optional overrides for the suspended-account tile.
  final String? abuseTitle;
  final String? abuseMessage;
  final String? abuseActionLabel;

  /// Optional overrides for the pending-deletion tile.
  final String? deletionTitle;
  final String? deletionMessage;
  final String? deletionActionLabel;

  final String footerNote;
}

/// A calm showcase of the system states used across chat.
///
/// It also keeps the friendly empty state, so the page shows every state a
/// conversation can start or stop in.
///
/// Every action is optional: a tile whose handler is null renders without an
/// action button instead of showing a control that cannot do anything. The
/// gallery registry supplies none, so it stays a pure preview.
class V2SystemStatesPage extends StatelessWidget {
  const V2SystemStatesPage({
    super.key,
    this.data = const V2SystemStatesData(),
    this.onTryExample,
    this.onRetryConnection,
    this.onTryAgain,
    this.onViewErrorDetails,
    this.onSeePlans,
    this.onManageStorage,
    this.onGetHelp,
    this.onRestoreAccount,
  });

  final V2SystemStatesData data;
  final VoidCallback? onTryExample;
  final VoidCallback? onRetryConnection;
  final VoidCallback? onTryAgain;
  final VoidCallback? onViewErrorDetails;
  final VoidCallback? onSeePlans;
  final VoidCallback? onManageStorage;
  final VoidCallback? onGetHelp;
  final VoidCallback? onRestoreAccount;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    // A null handler hides its button: the gallery must never render a next
    // step that cannot run.
    String labelFor(String label, VoidCallback? handler) =>
        handler == null ? '' : label;
    String labelOr(String? override, String fallback, VoidCallback? handler) =>
        handler == null ? '' : (override ?? fallback);
    return OScaffold(
      appBar: const OAppBar(
        title: 'System states',
        subtitle: 'Calm feedback when things change',
      ),
      body: OFadeSlide(
        child: OContent(
          padding: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              OSpace.screen,
              OSpace.l,
              OSpace.screen,
              OSpace.xxl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              OStagger(
                children: [
                  _tile(
                    V2StateTile(
                      // The copy is fully custom, so the kind only supplies the
                      // shared card layout.
                      kind: V2StateTileKind.offline,
                      copy: V2StateTileCopy(
                        icon: Icons.waving_hand_rounded,
                        title: data.emptyTitle,
                        message: data.emptyMessage,
                        actionLabel: labelFor(
                          data.emptyActionLabel,
                          onTryExample,
                        ),
                        actionVariant: OButtonVariant.secondary,
                      ),
                      onAction: onTryExample,
                    ),
                  ),
                  _tile(
                    V2StateTile.offline(
                      copy: V2StateTileCopy.offline.copyWith(
                        title: data.offlineTitle,
                        message: data.offlineMessage,
                        actionLabel: labelFor(
                          data.offlineActionLabel,
                          onRetryConnection,
                        ),
                      ),
                      onAction: onRetryConnection,
                    ),
                  ),
                  _tile(
                    V2StateTile.planLimited(
                      copy: V2StateTileCopy.planLimited.copyWith(
                        title: data.limitTitle,
                        message: data.limitMessage,
                        actionLabel: labelFor(
                          data.limitActionLabel,
                          onSeePlans,
                        ),
                      ),
                      detail: data.limitResetLabel,
                      onAction: onSeePlans,
                    ),
                  ),
                  _tile(
                    V2StateTile.serverError(
                      copy: V2StateTileCopy.serverError.copyWith(
                        title: data.errorTitle,
                        message: data.errorMessage,
                        actionLabel: labelFor(
                          data.errorActionLabel,
                          onTryAgain,
                        ),
                        secondaryActionLabel: labelFor(
                          data.errorDetailsLabel,
                          onViewErrorDetails,
                        ),
                      ),
                      onAction: onTryAgain,
                      onSecondaryAction: onViewErrorDetails,
                    ),
                  ),
                  _tile(
                    V2StateTile.storageFull(
                      copy: V2StateTileCopy.storageFull.copyWith(
                        title: data.storageTitle,
                        message: data.storageMessage,
                        actionLabel: labelOr(
                          data.storageActionLabel,
                          V2StateTileCopy.storageFull.actionLabel,
                          onManageStorage,
                        ),
                      ),
                      onAction: onManageStorage,
                    ),
                  ),
                  _tile(
                    V2StateTile.abuseBlocked(
                      copy: V2StateTileCopy.abuseBlocked.copyWith(
                        title: data.abuseTitle,
                        message: data.abuseMessage,
                        actionLabel: labelOr(
                          data.abuseActionLabel,
                          V2StateTileCopy.abuseBlocked.actionLabel,
                          onGetHelp,
                        ),
                      ),
                      onAction: onGetHelp,
                    ),
                  ),
                  _tile(
                    V2StateTile.deletionPending(
                      copy: V2StateTileCopy.deletionPending.copyWith(
                        title: data.deletionTitle,
                        message: data.deletionMessage,
                        actionLabel: labelOr(
                          data.deletionActionLabel,
                          V2StateTileCopy.deletionPending.actionLabel,
                          onRestoreAccount,
                        ),
                      ),
                      onAction: onRestoreAccount,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: OSpace.xl),
              Container(
                padding: const EdgeInsets.all(OSpace.m),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 20,
                      color: c.success,
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Text(
                        data.footerNote,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Widget _tile(Widget tile) => Padding(
    padding: const EdgeInsets.only(bottom: OSpace.m),
    child: tile,
  );
}
