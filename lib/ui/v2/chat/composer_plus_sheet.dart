import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'composer_sheet.dart';

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
    this.cameraUnavailableReason = 'This device does not have a camera.',
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

  /// When false the Camera row is disabled.
  final bool cameraAvailable;

  /// Why Camera is disabled. The composer passes a build-accurate reason so a
  /// device that does have a camera is never told otherwise.
  final String cameraUnavailableReason;

  bool get hasStudioFolder => (studioFolder?.trim().isNotEmpty ?? false);

  String get studioFolderLabel => (studioFolder ?? '').trim();

  bool get connectorLimitReached =>
      customConnectorsUsed >= plan.customConnectorLimit;

  String get connectorsStateLabel {
    if (plan == V2ComposerPlusPlan.free) return 'Free plan';
    if (connectorLimitReached) return 'Limit reached';
    return '${plan.label} plan';
  }
}

/// The "+" menu in the composer: File, Photo, Camera and Studio folder.
///
/// One row, one line each: icon and label. Availability is carried by colour
/// and the spoken label, never by a second line of description.
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
    this.onPermission,
    this.permissionLabel,
    this.onClose,
  });

  /// The reason the composer's own menu shows for Camera: there is no capture
  /// implementation in this build, so the row must not claim a missing device.
  static const String cameraBuildReason =
      'Camera capture is not available in this build.';

  final V2ComposerPlusData data;
  final VoidCallback? onPhoto;
  final VoidCallback? onCamera;
  final VoidCallback? onFile;
  final VoidCallback? onStudioFolder;
  final VoidCallback? onConnectors;

  /// Opens Studio so the person can pick a folder. The Studio row reports it
  /// as blocked until then.
  final VoidCallback? onOpenStudio;

  /// Opens the permission sheet. The composer's row keeps the chip at normal
  /// text sizes; at 320 dp with 200 % text the chip cannot fit beside three
  /// 48 dp targets, so this row is where it stays reachable instead of
  /// becoming a second composer row.
  final VoidCallback? onPermission;

  /// The current mode, shown on the permission row so the sheet still says
  /// what the chip would have said.
  final String? permissionLabel;

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
            OSheetHeader(
              title: 'Add to chat',
              onClose: onClose ?? () => Navigator.maybePop(context),
              closeLabel: 'Close add menu',
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  OSpace.s,
                  0,
                  OSpace.s,
                  OSpace.l,
                ),
                child: OStagger(
                  children: [
                    _PlusRow(
                      key: const ValueKey('composer-plus-file'),
                      icon: Icons.attach_file_rounded,
                      title: 'File',
                      onTap: onFile,
                    ),
                    _PlusRow(
                      key: const ValueKey('composer-plus-photo'),
                      icon: Icons.photo_library_outlined,
                      title: 'Photo',
                      note: data.photoAccessGranted ? null : 'Allow access',
                      onTap: onPhoto,
                    ),
                    _PlusRow(
                      key: const ValueKey('composer-plus-camera'),
                      icon: Icons.photo_camera_outlined,
                      title: 'Camera',
                      note: data.cameraAvailable
                          ? null
                          : data.cameraUnavailableReason,
                      onTap: data.cameraAvailable ? onCamera : null,
                    ),
                    _PlusRow(
                      key: const ValueKey('composer-plus-studio'),
                      icon: Icons.folder_copy_outlined,
                      title: 'Studio folder',
                      note: studioReady ? null : 'Folder needed',
                      onTap: studioReady
                          ? (onStudioFolder ?? onOpenStudio)
                          : onOpenStudio,
                    ),
                    if (onPermission != null)
                      _PlusRow(
                        key: const ValueKey('composer-plus-permission'),
                        icon: Icons.shield_outlined,
                        title: permissionLabel == null
                            ? 'Permission'
                            : 'Permission: $permissionLabel',
                        onTap: onPermission,
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

/// Opens [V2ComposerPlusSheet] in the shared sheet container.
///
/// Every action closes the sheet first, so the picker or route it opens is not
/// stacked behind a menu that looks stuck.
Future<void> showV2ComposerPlusSheet(
  BuildContext context, {
  required V2ComposerPlusData data,
  VoidCallback? onPhoto,
  VoidCallback? onCamera,
  VoidCallback? onFile,
  VoidCallback? onStudioFolder,
  VoidCallback? onConnectors,
  VoidCallback? onOpenStudio,
  VoidCallback? onPermission,
  String? permissionLabel,
}) {
  return showV2ChatSheet<void>(
    context,
    builder: (sheetContext) {
      VoidCallback? run(VoidCallback? action) {
        if (action == null) return null;
        return () {
          Navigator.maybePop(sheetContext);
          action();
        };
      }

      return V2ComposerPlusSheet(
        data: data,
        onPhoto: run(onPhoto),
        onCamera: run(onCamera),
        onFile: run(onFile),
        onStudioFolder: run(onStudioFolder),
        onConnectors: run(onConnectors),
        onOpenStudio: run(onOpenStudio),
        onPermission: run(onPermission),
        permissionLabel: permissionLabel,
        onClose: () => Navigator.maybePop(sheetContext),
      );
    },
  );
}

/// One 48 dp-minimum row: icon, label, nothing else.
///
/// [note] is never drawn; it is added to the spoken label so a blocked row
/// still explains itself to a screen reader.
class _PlusRow extends StatelessWidget {
  const _PlusRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.note,
  });

  final IconData icon;
  final String title;
  final String? note;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final enabled = onTap != null;
    final fg = enabled ? c.text : c.textFaint;
    final spoken = note == null ? title : '$title. $note';

    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: spoken,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(ORadius.m),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.m,
                vertical: OSpace.s,
              ),
              child: Row(
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      icon,
                      size: 20,
                      color: enabled ? c.textMuted : c.textFaint,
                    ),
                  ),
                  const SizedBox(width: OSpace.m),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.body.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
