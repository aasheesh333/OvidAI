import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move welcome copy to the ARB files.

@immutable
class V2OnboardingWelcomeData {
  const V2OnboardingWelcomeData({
    this.version = 'Ovid 2.4',
    this.language = 'English',
  });

  final String version;
  final String language;
}

class OnboardingWelcomePage extends StatelessWidget {
  const OnboardingWelcomePage({
    super.key,
    this.data = const V2OnboardingWelcomeData(),
    this.onGetStarted,
    this.onSignIn,
    this.onLanguageTap,
    this.onClose,
    this.busy = false,
    this.error,
  });

  final V2OnboardingWelcomeData data;
  final VoidCallback? onGetStarted;
  final VoidCallback? onSignIn;
  final VoidCallback? onLanguageTap;
  final VoidCallback? onClose;

  /// True while the gate is persisting the first-run choice. Both actions are
  /// then disabled (and announced as disabled) and a saving line is shown.
  final bool busy;

  /// Set when persisting the choice failed. The gate lets the user retry by
  /// tapping the same action again.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OScaffold(
      appBar: OAppBar(
        title: 'Welcome',
        // Welcome is the first route of the tour: the default back arrow would
        // have nothing to pop, so it is suppressed unless a host wires one.
        showBack: false,
        actions: [
          if (onClose != null)
            OIconButton(
              icon: Icons.close_rounded,
              semanticLabel: 'Close',
              onPressed: onClose,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          OSpace.screen,
          OSpace.s,
          OSpace.screen,
          OSpace.xl,
        ),
        child: OFadeSlide(
          child: Column(
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: OSpace.s,
                runSpacing: OSpace.s,
                children: [
                  _VersionPill(label: data.version),
                  _LanguagePill(
                    key: const Key('welcome-language'),
                    label: data.language,
                    onTap: onLanguageTap,
                  ),
                ],
              ),
              const SizedBox(height: OSpace.xl),
              const _WelcomeOrb(),
              const SizedBox(height: OSpace.xl),
              const _EnginePill(),
              const SizedBox(height: OSpace.l),
              Semantics(
                container: true,
                header: true,
                child: Text(
                  'Your always-on personal agent.',
                  textAlign: TextAlign.center,
                  style: OType.h1.copyWith(color: c.text),
                ),
              ),
              const SizedBox(height: OSpace.m),
              Text(
                'Chat. Code. Create. Ovid keeps working while you live your life.',
                textAlign: TextAlign.center,
                style: OType.body.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.xxl),
              OButton(
                key: const Key('welcome-get-started'),
                label: 'Get started',
                icon: Icons.arrow_forward_rounded,
                expand: true,
                loading: busy,
                onPressed: busy ? null : onGetStarted,
              ),
              const SizedBox(height: OSpace.m),
              OButton(
                key: const Key('welcome-sign-in'),
                label: 'I already have an account',
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: busy ? null : onSignIn,
              ),
              if (busy) ...[
                const SizedBox(height: OSpace.m),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'Saving your choice…',
                    textAlign: TextAlign.center,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: OSpace.m),
                Semantics(
                  liveRegion: true,
                  child: Container(
                    padding: const EdgeInsets.all(OSpace.m),
                    decoration: BoxDecoration(
                      color: c.danger.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(ORadius.m),
                      border: Border.all(
                        color: c.danger.withValues(alpha: 0.40),
                      ),
                    ),
                    child: Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: OType.bodySm.copyWith(color: c.danger),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: OSpace.xl),
              Text(
                'By continuing you agree to our Terms and Privacy Policy.',
                textAlign: TextAlign.center,
                style: OType.caption.copyWith(color: c.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomeOrb extends StatelessWidget {
  const _WelcomeOrb();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      label: 'Ovid agent orb',
      image: true,
      child: SizedBox(
        width: 248,
        height: 248,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 248,
              height: 248,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.accent.withValues(alpha: 0.06),
              ),
            ),
            Container(
              width: 190,
              height: 190,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.accent.withValues(alpha: 0.10),
                border: Border.all(color: c.hairline),
              ),
            ),
            Container(
              width: 132,
              height: 132,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.surfaceAlt,
                border: Border.all(color: c.hairline),
              ),
            ),
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: c.accentFill,
              ),
              child: Icon(
                Icons.psychology_alt_rounded,
                size: 42,
                color: c.onAccent,
              ),
            ),
            Positioned(
              top: 26,
              right: 36,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.success,
                  border: Border.all(color: c.bg, width: 2),
                ),
              ),
            ),
            Positioned(
              bottom: 48,
              left: 46,
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.accent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EnginePill extends StatelessWidget {
  const _EnginePill();

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 28),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(ORadius.pill),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_rounded, size: 14, color: c.accent),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'Autonomous Engine',
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Accent pill that mirrors `OPill` but grows with the text scale instead of
/// clipping at a fixed 24 dp height.
class _VersionPill extends StatelessWidget {
  const _VersionPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: c.accentSoft,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: c.accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: OType.caption.copyWith(
                color: c.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LanguagePill extends StatelessWidget {
  const _LanguagePill({super.key, required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OPressable(
      onTap: onTap,
      semanticLabel: 'Language, $label',
      child: ExcludeSemantics(
        child: Container(
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          padding: const EdgeInsets.symmetric(horizontal: OSpace.m),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(ORadius.pill),
            border: Border.all(color: c.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.language_rounded, size: 18, color: c.textMuted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: OType.caption.copyWith(color: c.text),
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: 4),
                Icon(Icons.expand_more_rounded, size: 16, color: c.textFaint),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
