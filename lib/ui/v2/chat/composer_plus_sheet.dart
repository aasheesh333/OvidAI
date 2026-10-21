import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// The plan a composer's "+" sheet uses to describe connector availability.
///
/// Free has no custom connectors, Go includes 5, and Plus/Pro include 20. The
/// sheet only displays the plan; the wiring layer owns the real limit checks.
enum V2ComposerPlusPlan {
  free('Free', 0),
  go('Go', 5),
  plus('Plus', 20),
  pro('Pro', 20);

  const V2ComposerPlusPlan(this.label, this.customConnectorLimit);

  final String label;
  final int customConnectorLimit;
}

/// Visual state for one row in the "+" sheet.
enum V2ComposerPlusRowState {
  /// The action works now.
  available,

  /// The action still works but something limits it (plan, permission, or a
  /// used-up allowance).
  limited,

  /// The action cannot run until the person changes something outside the
  /// sheet.
  blocked,
}

/// Immutable view data for [V2ComposerPlusSheet].
///
/// The wiring layer supplies the plan, the current Studio folder and the two
/// device permissions. The sheet never reads app state, opens pickers or
/// changes anything itself.
@immutable
class V2ComposerPlusData {
  const V2ComposerPlusData({
    this.plan = V2ComposerPlusPlan.free,
    this.customConnectorsUsed = 0,
    this.studioFolder,
    this.photoAccessGranted = true,
    this.cameraAvailable = true,
  }) : assert(customConnectorsUsed >= 0, 'Usage cannot be negative');

  final V2ComposerPlusPlan plan;

  /// Custom connectors already added to the account. Built-in apps do not
  /// count toward the plan allowance.
  final int customConnectorsUsed;

  /// The folder picked in Studio, for example `ovid/site`. Null or blank means
  /// Studio chat is still blocked.
  final String? studioFolder;

  /// When false the Photo row stays tappable so the caller can request access.
  final bool photoAccessGranted;

  /// When false the Camera row is disabled with a plain-language reason.
  final bool cameraAvailable;

  bool get hasStudioFolder => (studioFolder?.trim().isNotEmpty ?? false);

  String get studioFolderLabel => (studioFolder ?? '').trim();

  bool get connectorLimitReached =>
      customConnectorsUsed >= plan.customConnectorLimit;

  String get connectorsStateLabel {
    if (plan == V2ComposerPlusPlan.free) return 'Free plan';
    if (connectorLimitReached) return 'Limit reached';
    return '${plan.label} plan';
  }

  String get connectorsSubtitle {
    if (plan == V2ComposerPlusPlan.free) {
      return 'Built-in apps only. Custom connectors start on Go.';
    }
    if (connectorLimitReached) {
      return 'All ${plan.customConnectorLimit} custom connectors are in use.';
    }
    return '${plan.label} includes ${plan.customConnectorLimit} '
        'custom connectors.';
  }
}

/// The "+" menu in the composer: Photo, Camera, File, Studio folder and
/// Connectors, each with a plain-language availability state.
///
/// The Studio row is disabled until [V2ComposerPlusData.studioFolder] is set,
/// because Studio chat is blocked without a folder. The blocked note offers an
/// [onOpenStudio] next action when the caller wires it.
class V2ComposerPlusSheet extends StatelessWidget {
  const V2ComposerPlusSheet({
    super.key,
    required this.data,
    this.onPhoto,
    this.onCamera,
    this.onFile,
    this.onStudioFolder,
    this.onConnectors,
    this.onOpenStudio,
    this.onClose,
  });

  final V2ComposerPlusData data;
  final VoidCallback? onPhoto;
  final VoidCallback? onCamera;
  final VoidCallback? onFile;
  final VoidCallback? onStudioFolder;
  final VoidCallback? onConnectors;

  /// Opens Studio so the person can pick a folder. Shown in the blocked note.
  final VoidCallback? onOpenStudio;

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final studioReady = data.hasStudioFolder;

    return Material(
      color: c.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(onClose: onClose ?? () => Navigator.maybePop(context)),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  OSpace.l,
                  0,
                  OSpace.l,
                  OSpace.l,
                ),
                child: OStagger(
                  children: [
                    _PlusRow(
                      key: const ValueKey('composer-plus-photo'),
                      icon: Icons.photo_library_outlined,
                      title: 'Photo',
                      subtitle: data.photoAccessGranted
                          ? 'Choose a photo from your library.'
                          : 'Photo access is off. Allow it to pick an image.',
                      state: data.photoAccessGranted
                          ? V2ComposerPlusRowState.available
                          : V2ComposerPlusRowState.limited,
                      stateLabel: data.photoAccessGranted
                          ? null
                          : 'Allow access',
                      onTap: onPhoto,
                    ),
                    _PlusRow(
                      key: const ValueKey('composer-plus-camera'),
                      icon: Icons.photo_camera_outlined,
                      title: 'Camera',
                      subtitle: data.cameraAvailable
                          ? 'Take a photo with the camera.'
                          : 'This device does not have a camera.',
                      state: data.cameraAvailable
                          ? V2ComposerPlusRowState.available
                          : V2ComposerPlusRowState.blocked,
                      stateLabel: data.cameraAvailable ? null : 'No camera',
                      onTap: data.cameraAvailable ? onCamera : null,
                    ),
                    _PlusRow(
                      key: const ValueKey('composer-plus-file'),
                      icon: Icons.attach_file_rounded,
                      title: 'File',
                      subtitle: 'Documents, code and images up to 8 MB.',
                      onTap: onFile,
                    ),
                    _PlusRow(
                      key: const ValueKey('composer-plus-studio'),
                      icon: Icons.folder_copy_outlined,
                      title: 'Studio folder',
                      subtitle: studioReady
                          ? 'Use files from ${data.studioFolderLabel}.'
                          : 'Attach files from your Studio folder.',
                      state: studioReady
                          ? V2ComposerPlusRowState.available
                          : V2ComposerPlusRowState.blocked,
                      stateLabel: studioReady ? null : 'Folder needed',
                      onTap: studioReady ? onStudioFolder : null,
                    ),
                    if (!studioReady)
                      _StudioBlockedNote(onOpenStudio: onOpenStudio),
                    _PlusRow(
                      key: const ValueKey('composer-plus-connectors'),
                      icon: Icons.extension_outlined,
                      title: 'Connectors',
                      subtitle: data.connectorsSubtitle,
                      state:
                          data.plan == V2ComposerPlusPlan.free ||
                              data.connectorLimitReached
                          ? V2ComposerPlusRowState.limited
                          : V2ComposerPlusRowState.available,
                      stateLabel: data.connectorsStateLabel,
                      onTap: onConnectors,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens [V2ComposerPlusSheet] in the shared bottom-sheet container.
Future<void> showV2ComposerPlusSheet(
  BuildContext context, {
  required V2ComposerPlusData data,
  VoidCallback? onPhoto,
  VoidCallback? onCamera,
  VoidCallback? onFile,
  VoidCallback? onStudioFolder,
  VoidCallback? onConnectors,
  VoidCallback? onOpenStudio,
}) {
  return showOSheet<void>(
    context,
    builder: (sheetContext) => V2ComposerPlusSheet(
      data: data,
      onPhoto: onPhoto,
      onCamera: onCamera,
      onFile: onFile,
      onStudioFolder: onStudioFolder,
      onConnectors: onConnectors,
      onOpenStudio: onOpenStudio,
      onClose: () => Navigator.maybePop(sheetContext),
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.l,
        OSpace.s,
        OSpace.s,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Add to chat', style: OType.h2.copyWith(color: c.text)),
                const SizedBox(height: 2),
                Text(
                  'Attach a photo, file or connector.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: OSpace.s),
          OIconButton(
            icon: Icons.close_rounded,
            semanticLabel: 'Close add menu',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// One 48 dp-minimum row. [stateLabel] is both the visible pill and part of the
/// spoken label, so the reason a row is limited or blocked is never colour-only.
class _PlusRow extends StatelessWidget {
  const _PlusRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.state = V2ComposerPlusRowState.available,
    this.stateLabel,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final V2ComposerPlusRowState state;
  final String? stateLabel;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final blocked = state == V2ComposerPlusRowState.blocked;
    final enabled = onTap != null && !blocked;
    final fg = enabled ? c.text : c.textFaint;
    final subtitleColor = enabled ? c.textMuted : c.textFaint;
    final label = stateLabel;
    final pill = label == null
        ? null
        : OPill(
            label: label,
            tone: switch (state) {
              V2ComposerPlusRowState.available => OPillTone.neutral,
              V2ComposerPlusRowState.limited => OPillTone.warn,
              V2ComposerPlusRowState.blocked => OPillTone.warn,
            },
          );
    // At large text sizes a trailing pill and a chevron leave too little room
    // for the title, so the pill moves under the subtitle.
    final captionSize = OType.caption.fontSize ?? 12;
    final stackState =
        MediaQuery.textScalerOf(context).scale(captionSize) >=
        captionSize * 1.3;
    final spoken = [title, subtitle, ?label].join(', ');

    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: OSpace.touch),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.s,
        ),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(
                  icon,
                  size: 19,
                  color: blocked ? c.textFaint : c.textMuted,
                ),
              ),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: OType.body.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: OType.caption.copyWith(color: subtitleColor),
                  ),
                  if (stackState && pill != null) ...[
                    const SizedBox(height: OSpace.s),
                    pill,
                  ],
                ],
              ),
            ),
            if (!stackState && pill != null) ...[
              const SizedBox(width: OSpace.s),
              pill,
            ],
            const SizedBox(width: OSpace.xs),
            ExcludeSemantics(
              child: Icon(
                blocked
                    ? Icons.lock_outline_rounded
                    : Icons.chevron_right_rounded,
                size: 20,
                color: c.textFaint,
              ),
            ),
          ],
        ),
      ),
    );

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: spoken,
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(ORadius.m),
          child: content,
        ),
      ),
    );
  }
}

/// Blocked note shown under the Studio row until a folder is picked.
class _StudioBlockedNote extends StatelessWidget {
  const _StudioBlockedNote({this.onOpenStudio});

  final VoidCallback? onOpenStudio;

  static const message = 'Studio chat stays blocked until you pick a folder.';

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final content = Padding(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.s,
        OSpace.s,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 16, color: c.warn),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              message,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          if (onOpenStudio != null) ...[
            const SizedBox(width: OSpace.xs),
            Icon(Icons.chevron_right_rounded, size: 20, color: c.textFaint),
          ],
        ],
      ),
    );

    final box = Container(
      key: const ValueKey('composer-plus-studio-note'),
      margin: const EdgeInsets.only(bottom: OSpace.xs),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.warn.withValues(alpha: 0.22)),
      ),
      child: content,
    );

    if (onOpenStudio == null) {
      return Semantics(
        container: true,
        label: message,
        excludeSemantics: true,
        child: box,
      );
    }
    return Semantics(
      container: true,
      button: true,
      label: '$message Open Studio.',
      excludeSemantics: true,
      onTap: onOpenStudio,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onOpenStudio,
          borderRadius: BorderRadius.circular(ORadius.m),
          child: box,
        ),
      ),
    );
  }
}
