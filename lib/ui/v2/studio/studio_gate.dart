import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move this gate's copy to the ARB files in the next wave.

/// The blocked composer state for Studio mode.
///
/// The chat controller embeds this instead of the normal composer until the
/// user has bound a repository **and** a branch. It renders the reason and a
/// single action that opens the repo picker; it owns no state and never sends
/// a message.
class V2StudioGate extends StatelessWidget {
  const V2StudioGate({
    super.key,
    this.onPickFolder,
    this.onPickRepo,
    this.title = 'Pick a folder to start coding',
    this.message =
        'Studio messages are paused until you choose a repository and branch.',
    this.actionLabel = 'Pick a folder',
  });

  /// Opens the repository picker. When null the button is disabled and
  /// announced as such.
  final VoidCallback? onPickFolder;

  /// Alias for [onPickFolder] matching the workspace page's `onPickRepo` name.
  final VoidCallback? onPickRepo;
  final String title;
  final String message;
  final String actionLabel;

  VoidCallback? get _onPick => onPickRepo ?? onPickFolder;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      key: const Key('studio-gate'),
      margin: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.s),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.xl),
        border: Border.all(color: c.hairline),
      ),
      child: SingleChildScrollView(
        primary: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: c.accentSoft,
                    borderRadius: BorderRadius.circular(ORadius.m),
                  ),
                  child: Icon(
                    Icons.folder_open_rounded,
                    size: 19,
                    color: c.accent,
                  ),
                ),
                const SizedBox(width: OSpace.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: OType.bodyStrong.copyWith(color: c.text),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        message,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: OSpace.m),
            OButton(
              key: const Key('studio-gate-pick-folder'),
              label: actionLabel,
              icon: Icons.folder_open_rounded,
              expand: true,
              onPressed: _onPick,
            ),
          ],
        ),
      ),
    );
  }
}
