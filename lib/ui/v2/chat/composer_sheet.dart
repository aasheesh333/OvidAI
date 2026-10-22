import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

/// Shows a composer sheet: a bottom sheet on phones, a centred dialog from
/// 600 dp up.
///
/// The minimal contract asks for both: sheets stay thumb-reachable on a phone
/// and stop stretching across a tablet. The max width matches the contract's
/// 560 dp dialog cap.
Future<T?> showV2ChatSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double maxWidth = 560,
}) {
  final size = MediaQuery.sizeOf(context);
  if (!OBreakpoints.isTablet(size.width)) {
    return showOSheet<T>(context, builder: builder);
  }

  final c = OColors.of(context);
  return showDialog<T>(
    context: context,
    barrierColor: c.scrim,
    builder: (dialogContext) => Dialog(
      backgroundColor: c.surface,
      insetPadding: const EdgeInsets.all(OSpace.xl),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ORadius.xl),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.85,
        ),
        child: builder(dialogContext),
      ),
    ),
  );
}
