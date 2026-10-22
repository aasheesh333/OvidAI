import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';
import 'permission_sheet.dart';

/// The composer's only control row: `+`, permission chip, field, mic, send.
///
/// One row is the whole contract. The field is [Expanded], so it takes every
/// pixel the 48 dp targets leave and grows upward (`minLines: 1`,
/// `maxLines: 3`) instead of pushing a second row onto the screen.
///
/// At 320 dp with 200 % text the chip label plus three 48 dp targets no
/// longer fit on one line. Rather than wrap to a second row, the chip leaves
/// the row and the same action stays reachable from the `+` sheet (the
/// permission row the plus sheet adds when the host wires one). The threshold
/// is measured with the ambient text scaler, not guessed from a width
/// constant.
class V2ComposerRow extends StatelessWidget {
  const V2ComposerRow({
    super.key,
    required this.field,
    required this.send,
    required this.onPlus,
    required this.onMic,
    required this.listening,
    this.permissionLabel,
    this.onPermission,
  });

  /// The text field, already wrapped in its shortcuts and `Expanded` by this
  /// row. Both composers pass their own field so the hint, style and padding
  /// stay with the page that owns the draft.
  final Widget field;

  /// The send (or stop) control. It carries its own enabled state.
  final Widget send;

  final VoidCallback? onPlus;
  final VoidCallback? onMic;
  final bool listening;

  /// The current permission mode. Null, or a null [onPermission], hides the
  /// chip instead of showing a dead control.
  final String? permissionLabel;
  final VoidCallback? onPermission;

  /// The fixed cost of the row: plus, mic and send are 48 dp targets.
  static const double _targets = OSpace.touch * 3;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final label = permissionLabel;
        final chipWidth = label == null || onPermission == null
            ? 0.0
            : _chipWidth(context, label);
        // No minimum field width is reserved: at 320 dp the contract still
        // asks for the chip in the row, and the [Expanded] field can take a
        // sliver without overflowing. The chip only leaves the row when it
        // alone would not fit beside the three targets — the 200 % text case.
        final showChip =
            chipWidth > 0 && constraints.maxWidth >= _targets + chipWidth;
        return Row(
          key: const ValueKey('v2-composer-row'),
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            OIconButton(
              icon: Icons.add_rounded,
              semanticLabel: 'Add attachment or action',
              onPressed: onPlus,
            ),
            if (showChip)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: chipWidth),
                child: V2PermissionChip(label: label!, onTap: onPermission),
              ),
            Expanded(child: field),
            OIconButton(
              icon: listening ? Icons.mic_rounded : Icons.mic_none_rounded,
              semanticLabel: listening ? 'Stop voice input' : 'Voice input',
              active: listening,
              onPressed: onMic,
            ),
            send,
          ],
        );
      },
    );
  }

  /// Lays the chip's label out at the ambient text scale: the fit test has to
  /// follow 200 % text, and a 14 sp label is twice as wide there.
  static double _chipWidth(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: OType.label),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width + OSpace.m * 2;
    painter.dispose();
    return width;
  }
}
