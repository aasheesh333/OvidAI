import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/app_info.dart';
import '../../../core/theme.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import '../settings/settings_rows.dart';
import 'legal_page.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

/// Health of the Ovid service, as reported by the caller. The screen never
/// checks it itself and the minimal About screen does not render it.
enum V2SystemStatus { unknown, checking, operational, degraded, error }

/// Injected state for the About screen. Host callbacks can override any legal
/// destination; otherwise the screen opens the bundled documents and the real
/// licence registry itself. It never performs a network check.
@immutable
class V2AboutPageData {
  const V2AboutPageData({
    this.version = kAppVersion,
    this.build = kAppBuildNumber,
    this.tagline = 'Chat. Code. Create.',
    this.systemStatus = V2SystemStatus.unknown,
    this.onCopyVersion,
    this.onPrivacyPolicy,
    this.onTerms,
    this.onLicences,
    this.onContactSupport,
    this.onSystemStatus,
    this.onRetrySystemStatus,
    this.onDeleteAccount,
  });

  /// The build's real version and build number. They default to
  /// `kAppVersion`/`kAppBuildNumber` (`core/app_info.dart`), so a caller that
  /// does not inject them still shows the shipped build, never a demo string.
  final String version;
  final String build;

  /// Retained for callers; the minimal About screen has no hero or tagline.
  final String tagline;
  final V2SystemStatus systemStatus;

  final VoidCallback? onCopyVersion;
  final VoidCallback? onPrivacyPolicy;
  final VoidCallback? onTerms;
  final VoidCallback? onLicences;

  /// Retained for hosts. The minimal About screen shows only the build and
  /// the three legal documents; support lives in Account.
  final VoidCallback? onContactSupport;

  /// Opens the full status page. Retained for hosts; the minimal About screen
  /// does not render a status row.
  final VoidCallback? onSystemStatus;

  /// Used by the failed status check; falls back to [onSystemStatus].
  final VoidCallback? onRetrySystemStatus;

  /// Opens the account deletion flow. Retained for hosts; the minimal About
  /// screen does not render a delete row.
  final VoidCallback? onDeleteAccount;

  /// The build's real version, from `--dart-define` or the pubspec defaults.
  /// Callers can override it, but the default is never a demo string.
  bool get hasVersion => version.trim().isNotEmpty;

  String get buildLabel =>
      build.trim().isEmpty ? version : '$version (build $build)';
}

/// About Ovid Si: the build and the three legal documents. No hero, no
/// support row, no status tile.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.data});

  final V2AboutPageData data;

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'About',
      child: OFadeSlide(
        child: ListView(
          padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
          children: [_identity(context), _rows(context)],
        ),
      ),
    );
  }

  /// App name and the real build, then three one-line rows. This is the whole
  /// screen: no marketing copy, no duplicated version row.
  Widget _identity(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xl),
      child: Column(
        children: [
          Text(
            Aether.brandName,
            textAlign: TextAlign.center,
            style: OType.h2.copyWith(color: c.text),
          ),
          if (data.hasVersion) ...[
            const SizedBox(height: OSpace.xs),
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: OSpace.xs,
              children: [
                Text(
                  data.buildLabel,
                  textAlign: TextAlign.center,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
                OIconButton(
                  icon: Icons.copy_rounded,
                  semanticLabel: 'Copy version info',
                  tooltip: 'Copy version info',
                  onPressed: () => _copyVersion(context),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _rows(BuildContext context) {
    return V2SettingsRowList(
      rows: [
        _legalRow(
          icon: Icons.shield_outlined,
          title: 'Privacy policy',
          // A host callback opens the published URL; without one the reader
          // renders the policy bundled with this build.
          external: data.onPrivacyPolicy != null,
          onTap:
              data.onPrivacyPolicy ??
              () => _openDocument(
                context,
                V2LegalDocument.asset(
                  assetPath: 'docs/legal/PRIVACY.md',
                  title: 'Privacy policy',
                  icon: Icons.shield_outlined,
                ),
              ),
        ),
        _legalRow(
          icon: Icons.description_outlined,
          title: 'Terms of service',
          external: data.onTerms != null,
          onTap:
              data.onTerms ??
              () => _openDocument(
                context,
                V2LegalDocument.asset(
                  assetPath: 'docs/legal/TERMS.md',
                  title: 'Terms of service',
                  icon: Icons.description_outlined,
                ),
              ),
        ),
        _legalRow(
          icon: Icons.code_rounded,
          title: 'Open-source licences',
          external: data.onLicences != null,
          onTap: data.onLicences ?? () => _openLicences(context),
        ),
      ],
    );
  }

  /// A legal row is always actionable, so it is announced as a button. An
  /// external row also says that following it leaves the app.
  Widget _legalRow({
    required IconData icon,
    required String title,
    required bool external,
    required VoidCallback onTap,
  }) {
    return MergeSemantics(
      child: Semantics(
        hint: external ? 'Opens in your browser' : null,
        child: V2SettingsRow(icon: icon, title: title, onTap: onTap),
      ),
    );
  }

  void _openDocument(BuildContext context, V2LegalDocument document) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LegalPage.document(document: document),
      ),
    );
  }

  void _openLicences(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const LicencesPage()));
  }

  /// Copies the real build label. The injected callback (if any) still runs,
  /// so a host can add its own confirmation. A clipboard failure is reported
  /// instead of claiming the copy happened.
  Future<void> _copyVersion(BuildContext context) async {
    var copied = false;
    try {
      await Clipboard.setData(ClipboardData(text: data.buildLabel));
      copied = true;
    } catch (_) {
      copied = false;
    }
    if (!context.mounted) return;
    if (!copied) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Could not copy.')));
      return;
    }
    final callback = data.onCopyVersion;
    if (callback != null) {
      callback();
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Version copied.')));
  }
}
