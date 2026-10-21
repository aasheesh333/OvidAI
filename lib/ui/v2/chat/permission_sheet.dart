import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// One agent access mode in the chat permission sheet.
///
/// The ids mirror the server's `AgentMode` names (`safe`, `auto`, `drive`,
/// `studio`) so the live adapter can map a pick straight onto the facade.
@immutable
class V2PermissionMode {
  const V2PermissionMode({
    required this.id,
    required this.label,
    required this.description,
    required this.icon,
    this.danger = false,
  });

  final String id;
  final String label;

  /// Plain-language explanation of what Ovid may do. Avoid jargon: this is
  /// the only place a user can see the consequence before picking a mode.
  final String description;
  final IconData icon;

  /// Full Access is deliberately the only red row. It runs without stopping
  /// for approval, so the picker must not make it look ordinary.
  final bool danger;
}

/// The four modes the product offers, in escalation order.
const v2PermissionModes = <V2PermissionMode>[
  V2PermissionMode(
    id: 'safe',
    label: 'Read-Only',
    description:
        'Ovid can look through your files and chats, but asks before '
        'changing anything.',
    icon: Icons.visibility_outlined,
  ),
  V2PermissionMode(
    id: 'auto',
    label: 'General',
    description:
        'Ovid runs commands and uses the browser, and asks before '
        'changing files or pushing code.',
    icon: Icons.tune_outlined,
  ),
  V2PermissionMode(
    id: 'drive',
    label: 'Full Access',
    description:
        'Ovid works without stopping for approval. It can change '
        'files and push code on its own.',
    icon: Icons.rocket_launch_outlined,
    danger: true,
  ),
  V2PermissionMode(
    id: 'studio',
    label: 'Studio',
    description:
        'For coding in a connected repo. Ovid edits files, runs the '
        'terminal, and syncs, and asks before committing or publishing.',
    icon: Icons.code_rounded,
  ),
];

/// Everything the permission sheet needs to render. Selection and every
/// action are owned by the caller.
@immutable
class V2PermissionSheetData {
  const V2PermissionSheetData({
    this.modes = v2PermissionModes,
    this.selectedId = 'auto',
    this.loading = false,
    this.errorMessage,
  });

  final List<V2PermissionMode> modes;

  /// Id of the mode currently in force for this chat.
  final String selectedId;

  final bool loading;

  /// When set, the list is replaced by the shared error state with a retry.
  final String? errorMessage;

  V2PermissionMode? get selectedMode {
    for (final mode in modes) {
      if (mode.id == selectedId) return mode;
    }
    return null;
  }
}

/// Bottom sheet for choosing what Ovid may do in a chat: Read-Only, General,
/// Full Access or Studio.
///
/// Presentational only. Tapping a row reports its id through [onSelect]; the
/// caller decides whether to apply it. [showV2PermissionSheet] also closes the
/// sheet after the callback, matching the other chat pickers.
class V2PermissionSheet extends StatelessWidget {
  const V2PermissionSheet({
    super.key,
    required this.data,
    required this.onSelect,
    this.onClose,
    this.onRetry,
  });

  final V2PermissionSheetData data;
  final ValueChanged<String> onSelect;
  final VoidCallback? onClose;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);

    return Material(
      color: c.surface,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OSpace.l,
                OSpace.l,
                OSpace.s,
                0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Permissions',
                          style: OType.h2.copyWith(color: c.text),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Choose what Ovid may do in this chat.',
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: OSpace.s),
                  OIconButton(
                    icon: Icons.close_rounded,
                    semanticLabel: 'Close permissions',
                    onPressed: onClose ?? () => Navigator.maybePop(context),
                  ),
                ],
              ),
            ),
            OAnimatedSwap(child: _buildBody(context)),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                OSpace.l,
                OSpace.s,
                OSpace.l,
                OSpace.l,
              ),
              child: const _PushNote(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final data = this.data;

    if (data.loading) {
      return const SizedBox(height: 280, child: OSkeletonList(rows: 4));
    }
    if (data.errorMessage != null) {
      return SizedBox(
        height: 300,
        child: OErrorState(
          title: 'Permissions did not load',
          message: data.errorMessage!,
          onRetry: onRetry,
        ),
      );
    }
    if (data.modes.isEmpty) {
      return SizedBox(
        height: 300,
        child: OEmptyState(
          icon: Icons.verified_user_outlined,
          title: 'No permission modes',
          message: 'Close this sheet and try again.',
          action: OButton(
            label: 'Close',
            variant: OButtonVariant.secondary,
            onPressed: onClose ?? () => Navigator.maybePop(context),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.m,
        OSpace.l,
        OSpace.xs,
      ),
      child: OStagger(
        children: [
          for (final mode in data.modes)
            Padding(
              padding: const EdgeInsets.only(bottom: OSpace.s),
              child: _ModeRow(
                mode: mode,
                selected: data.selectedId == mode.id,
                onTap: () => onSelect(mode.id),
              ),
            ),
        ],
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  const _ModeRow({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final V2PermissionMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final danger = mode.danger;
    final tint = danger ? c.danger : c.accentFill;

    final row = Container(
      constraints: const BoxConstraints(minHeight: OSpace.listRow),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: danger
            ? c.danger.withValues(alpha: selected ? 0.10 : 0.05)
            : selected
            ? c.accentSoft
            : c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(
          color: selected
              ? tint
              : danger
              ? c.danger.withValues(alpha: 0.35)
              : c.hairline,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: danger ? c.danger.withValues(alpha: 0.12) : c.surfaceAlt,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(
              mode.icon,
              size: 20,
              color: danger ? c.danger : c.textMuted,
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: OSpace.s,
                  runSpacing: OSpace.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      mode.label,
                      style: OType.bodyStrong.copyWith(
                        color: danger ? c.danger : c.text,
                      ),
                    ),
                    if (danger) const _NoPromptsTag(),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  mode.description,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: OSpace.s),
          _SelectionMark(selected: selected, danger: danger),
        ],
      ),
    );

    final spoken = StringBuffer('${mode.label}. ${mode.description}');
    if (danger) spoken.write(' No confirmation prompts.');
    return OPressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: spoken.toString(),
      child: row,
    );
  }
}

class _SelectionMark extends StatelessWidget {
  const _SelectionMark({required this.selected, required this.danger});

  final bool selected;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected
            ? (danger ? c.danger : c.accentFill)
            : Colors.transparent,
        border: Border.all(
          color: selected
              ? (danger ? c.danger : c.accentFill)
              : c.hairlineStrong,
        ),
      ),
      child: selected
          ? Icon(
              Icons.check_rounded,
              size: 16,
              color: danger ? c.onDanger : c.onAccent,
            )
          : null,
    );
  }
}

/// Danger pill on the Full Access row. It grows with the text scale instead
/// of pinning its height, so 200 % text never clips.
class _NoPromptsTag extends StatelessWidget {
  const _NoPromptsTag();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: c.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              'No prompts',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(
                color: c.danger,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The safety promise under the list. Full Access is the one exception, and
/// the note says so instead of pretending otherwise.
class _PushNote extends StatelessWidget {
  const _PushNote();

  @override
  Widget build(BuildContext context) {
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
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: c.surfaceRaised,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.shield_outlined, size: 15, color: c.textMuted),
          ),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Ovid asks before pushing',
                  style: OType.bodySm.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: OSpace.xs),
                Text(
                  'Commits, publishes, and anything that leaves your workspace '
                  'wait for your OK — Full Access skips these prompts.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the permission sheet in the shared bottom-sheet container and closes
/// it after the caller applies the pick.
Future<void> showV2PermissionSheet(
  BuildContext context, {
  required V2PermissionSheetData data,
  required ValueChanged<String> onSelect,
  VoidCallback? onRetry,
}) {
  return showOSheet<void>(
    context,
    builder: (sheetContext) => V2PermissionSheet(
      data: data,
      onSelect: (id) {
        Navigator.of(sheetContext).maybePop();
        onSelect(id);
      },
      onClose: () => Navigator.of(sheetContext).maybePop(),
      onRetry: onRetry,
    ),
  );
}
