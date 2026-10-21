import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

/// Health of the Ovid service, as reported by the caller. The screen never
/// checks it itself.
enum V2SystemStatus { unknown, checking, operational, degraded, error }

/// Injected state for the About screen. Every row reports through a callback;
/// the screen never opens a URL, copies to the clipboard or reads the package
/// itself.
@immutable
class V2AboutPageData {
  const V2AboutPageData({
    this.version = '',
    this.build = '',
    this.tagline = 'Chat. Code. Create.',
    this.systemStatus = V2SystemStatus.unknown,
    this.onCopyVersion,
    this.onPrivacyPolicy,
    this.onTerms,
    this.onLicences,
    this.onContactSupport,
    this.onSystemStatus,
    this.onRetrySystemStatus,
  });

  final String version;
  final String build;
  final String tagline;
  final V2SystemStatus systemStatus;

  final VoidCallback? onCopyVersion;
  final VoidCallback? onPrivacyPolicy;
  final VoidCallback? onTerms;
  final VoidCallback? onLicences;
  final VoidCallback? onContactSupport;

  /// Opens the full status page.
  final VoidCallback? onSystemStatus;

  /// Used by the failed status check; falls back to [onSystemStatus].
  final VoidCallback? onRetrySystemStatus;

  /// Nothing is shown until the wiring knows a real version.
  bool get hasVersion => version.trim().isNotEmpty;

  String get versionLabel =>
      build.trim().isEmpty ? 'v$version' : 'v$version ($build)';

  String get buildLabel =>
      build.trim().isEmpty ? version : '$version · build $build';
}

/// About Ovid Si: the app mark, legal links, support links and build details.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.data});

  final V2AboutPageData data;

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: const OAppBar(title: 'About'),
      body: OFadeSlide(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            OSpace.screen,
            OSpace.xl,
            OSpace.screen,
            OSpace.xxl,
          ),
          child: OStagger(
            children: [
              _hero(context),
              _legal(context),
              _support(context),
              _about(context),
              _footer(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hero(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: Column(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(ORadius.xl),
            ),
            child: Icon(Icons.bolt_rounded, size: 46, color: c.onAccent),
          ),
          const SizedBox(height: OSpace.l),
          Text('Ovid Si', style: OType.h1.copyWith(color: c.text)),
          const SizedBox(height: OSpace.s),
          if (data.hasVersion) ...[
            _pill(
              label: data.versionLabel,
              foreground: c.accent,
              background: c.accentSoft,
            ),
            const SizedBox(height: OSpace.m),
          ],
          Text(
            data.tagline,
            textAlign: TextAlign.center,
            style: OType.body.copyWith(color: c.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _legal(BuildContext context) {
    return _section(
      context,
      title: 'Legal',
      rows: [
        OListRow(
          icon: Icons.shield_outlined,
          title: 'Privacy policy',
          onTap: data.onPrivacyPolicy,
          enabled: data.onPrivacyPolicy != null,
        ),
        OListRow(
          icon: Icons.description_outlined,
          title: 'Terms of service',
          onTap: data.onTerms,
          enabled: data.onTerms != null,
        ),
        OListRow(
          icon: Icons.code_rounded,
          title: 'Open-source licences',
          onTap: data.onLicences,
          enabled: data.onLicences != null,
        ),
      ],
    );
  }

  Widget _support(BuildContext context) {
    final c = OColors.of(context);
    final status = data.systemStatus;
    final statusLabel = switch (status) {
      V2SystemStatus.unknown => '',
      V2SystemStatus.checking => 'Checking…',
      V2SystemStatus.operational => 'Operational',
      V2SystemStatus.degraded => 'Some issues',
      V2SystemStatus.error => 'Could not check',
    };
    final retry = status == V2SystemStatus.error;
    final statusTap = retry
        ? (data.onRetrySystemStatus ?? data.onSystemStatus)
        : data.onSystemStatus;
    final baseSubtitle = switch (status) {
      V2SystemStatus.checking => 'Checking the latest status.',
      V2SystemStatus.error =>
        'We could not reach the status page. Tap to try again.',
      _ => 'Check if Ovid is working normally.',
    };
    // The row lays its trailing widget out at full width before the title, so a
    // pill in a narrow row or at large text would squeeze the title to nothing.
    // Fall back to plain words in the subtitle, which wraps inside the row.
    final narrow =
        MediaQuery.sizeOf(context).width < 360 ||
        MediaQuery.textScalerOf(context).scale(14) > 18;
    final showPill = statusLabel.isNotEmpty && !narrow;
    return _section(
      context,
      title: 'Support',
      rows: [
        OListRow(
          icon: Icons.support_agent_rounded,
          title: 'Contact support',
          subtitle: 'We usually reply within a day.',
          onTap: data.onContactSupport,
          enabled: data.onContactSupport != null,
        ),
        OListRow(
          icon: Icons.monitor_heart_outlined,
          title: 'System status',
          subtitle: showPill || statusLabel.isEmpty
              ? baseSubtitle
              : '$statusLabel · $baseSubtitle',
          onTap: statusTap,
          enabled: statusTap != null,
          trailing: showPill
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _pill(
                      label: statusLabel,
                      foreground: _statusColor(c, status),
                      background: _statusColor(
                        c,
                        status,
                      ).withValues(alpha: 0.12),
                      dot: status != V2SystemStatus.checking,
                    ),
                    const SizedBox(width: OSpace.xs),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: c.textFaint,
                    ),
                  ],
                )
              : null,
        ),
      ],
    );
  }

  Color _statusColor(OColors c, V2SystemStatus status) => switch (status) {
    V2SystemStatus.operational => c.success,
    V2SystemStatus.checking => c.textMuted,
    V2SystemStatus.unknown => c.textMuted,
    V2SystemStatus.degraded => c.warn,
    V2SystemStatus.error => c.warn,
  };

  Widget _about(BuildContext context) {
    if (!data.hasVersion) return const SizedBox.shrink();
    return _section(
      context,
      title: 'About',
      rows: [
        OListRow(
          icon: Icons.info_outline_rounded,
          title: 'Version and build',
          subtitle: data.buildLabel,
          showChevron: false,
          trailing: OIconButton(
            icon: Icons.copy_rounded,
            semanticLabel: 'Copy version info',
            tooltip: 'Copy version info',
            onPressed: data.onCopyVersion,
          ),
        ),
      ],
    );
  }

  Widget _footer(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: OSpace.s),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.android_rounded, size: 16, color: c.textFaint),
          const SizedBox(width: OSpace.xs),
          Flexible(
            child: Text(
              'Made for Android',
              textAlign: TextAlign.center,
              style: OType.caption.copyWith(color: c.textFaint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pill({
    required String label,
    required Color foreground,
    required Color background,
    bool dot = false,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: OSpace.xs),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(ORadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: foreground,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.caption.copyWith(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required List<Widget> rows,
  }) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OSectionHeader(
            label: title,
            padding: const EdgeInsets.only(bottom: OSpace.s),
          ),
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(color: c.hairline, height: 1),
                  rows[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
