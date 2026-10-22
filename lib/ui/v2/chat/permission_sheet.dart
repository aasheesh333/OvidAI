import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'composer_sheet.dart';

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

  /// Plain-language explanation of what Ovid may do. The sheet shows one line
  /// per mode, so this is announced rather than drawn.
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
/// Full Access or Studio. One line per mode.
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
            OSheetHeader(
              title: 'Permissions',
              onClose: onClose ?? () => Navigator.maybePop(context),
              closeLabel: 'Close permissions',
              padding: const EdgeInsets.fromLTRB(
                OSpace.l,
                OSpace.s,
                OSpace.s,
                OSpace.xs,
              ),
            ),
            OAnimatedSwap(child: _buildBody(context)),
            const SizedBox(height: OSpace.l),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final data = this.data;

    if (data.loading) {
      return const SizedBox(height: 240, child: OSkeletonList(rows: 4));
    }
    if (data.errorMessage != null) {
      return SizedBox(
        height: 260,
        child: OErrorState(
          title: 'Permissions did not load',
          message: data.errorMessage!,
          onRetry: onRetry,
        ),
      );
    }
    if (data.modes.isEmpty) {
      return SizedBox(
        height: 260,
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
      padding: const EdgeInsets.symmetric(vertical: OSpace.xs),
      child: OStagger(
        children: [
          for (var i = 0; i < data.modes.length; i++) ...[
            // One hairline between rows, indented to the label. Rows
            // themselves sit on the sheet surface — no filled cards.
            if (i > 0) const ODivider(indent: OSpace.huge),
            _ModeRow(
              mode: data.modes[i],
              selected: data.selectedId == data.modes[i].id,
              onTap: () => onSelect(data.modes[i].id),
            ),
          ],
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

    final spoken = StringBuffer('${mode.label}. ${mode.description}');
    if (danger) spoken.write(' No confirmation prompts.');
    return OPressable(
      onTap: onTap,
      selected: selected,
      semanticLabel: spoken.toString(),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: OSpace.touch),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.l,
            vertical: OSpace.s,
          ),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  mode.icon,
                  size: 20,
                  color: danger ? c.danger : c.textMuted,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Text(
                  mode.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodyStrong.copyWith(
                    color: danger ? c.danger : c.text,
                  ),
                ),
              ),
              // The pick is a bare check, not a filled radio circle.
              if (selected) ...[
                const SizedBox(width: OSpace.s),
                Icon(
                  Icons.check_rounded,
                  size: 20,
                  color: danger ? c.danger : c.accent,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The compact permission chip shared by the chat and live-chat composers.
///
/// The chip shows the current mode's name only. The host owns the mode and the
/// sheet; the chip only reports a tap.
class V2PermissionChip extends StatelessWidget {
  const V2PermissionChip({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = onTap != null;
    return Semantics(
      label: 'Permission: $label. Change',
      button: true,
      enabled: enabled,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(ORadius.pill),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            child: Center(
              widthFactor: 1,
              child: Container(
                constraints: const BoxConstraints(minHeight: 32),
                padding: const EdgeInsets.symmetric(
                  horizontal: OSpace.m,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.pill),
                  border: Border.all(color: c.hairline),
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.label.copyWith(
                    color: enabled ? c.textMuted : c.textFaint,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the permission sheet in the shared sheet container and closes it
/// after the caller applies the pick.
Future<void> showV2PermissionSheet(
  BuildContext context, {
  required V2PermissionSheetData data,
  required ValueChanged<String> onSelect,
  VoidCallback? onRetry,
}) {
  return showV2ChatSheet<void>(
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
