import 'health_screen.dart';

/// Source-compatible alias for the merged health surface.
///
/// The two health screens were merged into a single [HealthScreen] (score
/// ring + per-runtime checks + targeted repair + services + the hard reset
/// behind an Advanced disclosure). This subclass preserves the existing
/// call sites — the `/settings/health` deep link in `lib/core/router.dart`
/// and older widget suites — without keeping a second, divergent
/// implementation alive. New code must navigate to [HealthScreen] directly.
class SettingsHealthScreen extends HealthScreen {
  const SettingsHealthScreen({super.key, super.service});
}
