import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design/o_components.dart';
import '../../design/o_tokens.dart';
import 'connector_models.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

/// Android application id, mirrored from `play_billing.dart` so this screen
/// stays free of the native billing imports (the web preview compiles it).
const String _playPackage = 'com.dhanuk.ovidai';

/// Opens the real upgrade path for connector slots.
///
/// The app cannot sell a subscription from this screen without the billing
/// stack, so this explains the allowance and hands the person to the Play
/// listing where the plans are actually sold. Every button either opens the
/// store or says why it could not — never "coming soon".
Future<void> v2ShowConnectorUpgrade(
  BuildContext context,
  V2ConnectorPlan plan,
) async {
  final openStore = await showOSheet<bool>(
    context,
    title: 'More connector slots',
    builder: (sheetContext) {
      final c = OColors.of(sheetContext);
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'You are on ${plan.label}. Connector slots come with the plan:',
              style: OType.bodySm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: OSpace.m),
            for (final option in V2ConnectorPlan.values)
              Padding(
                padding: const EdgeInsets.only(bottom: OSpace.s),
                child: Row(
                  children: [
                    Icon(
                      option == plan
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: option == plan ? c.accent : c.textFaint,
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Text(
                        option.label,
                        style: OType.bodySm.copyWith(color: c.text),
                      ),
                    ),
                    Text(
                      option.connectorLimit == 0
                          ? 'No connectors'
                          : '${option.connectorLimit} connectors',
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: OSpace.s),
            OButton(
              label: 'Open Google Play',
              icon: Icons.open_in_new_rounded,
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(true),
            ),
            const SizedBox(height: OSpace.s),
            OButton(
              label: 'Not now',
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(false),
            ),
          ],
        ),
      );
    },
  );
  if (openStore != true || !context.mounted) return;
  final uri = Uri.https('play.google.com', '/store/apps/details', {
    'id': _playPackage,
  });
  var launched = false;
  try {
    launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    launched = false;
  }
  if (!context.mounted) return;
  if (!launched) {
    showOSnack(
      context,
      'Could not open Google Play. Search for Ovid AI in the Play Store to '
      'change plans.',
    );
  }
}
