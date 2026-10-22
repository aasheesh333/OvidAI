import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_info.dart';
import '../../../core/legal_links.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'legal_page.dart';

// TODO(l10n): move the English copy in this screen to the ARB files.

/// Health of the Ovid service, as reported by the caller. The screen never
/// checks it itself.
enum V2SystemStatus { unknown, checking, operational, degraded, error }

/// The three legal documents the About screen can open in-app.
///
/// The copy mirrors the published policy and terms in `docs/legal/` at the
/// date shown on each page. It is injected as data so the screen never loads a
/// file or the network itself.
@immutable
class V2AboutLegalDocuments {
  const V2AboutLegalDocuments({
    required this.privacyPolicy,
    required this.terms,
    required this.licences,
  });

  final V2LegalPageData privacyPolicy;
  final V2LegalPageData terms;
  final V2LegalPageData licences;

  /// The shipped documents. Callers that want the external URLs can keep
  /// passing [V2AboutPageData.onPrivacyPolicy] and friends instead.
  static const standard = V2AboutLegalDocuments(
    privacyPolicy: _privacyPolicy,
    terms: _terms,
    licences: _licences,
  );

  static const _privacyPolicy = V2LegalPageData(
    title: 'Privacy policy',
    icon: Icons.privacy_tip_outlined,
    updatedAt: '21 October 2026',
    summary:
        'Ovid Si is provided by Dhanuk Softwares. This policy explains what we '
        'collect, why we collect it, who processes it, how long we keep it and '
        'how you can delete it.',
    sections: <V2LegalSection>[
      V2LegalSection(
        heading: 'The short version',
        bullets: <String>[
          'We collect what we need to run your account and the assistant: your '
              'sign-in identifier, chats, attached files, workspace files, '
              'usage and purchase status.',
          'Crash reports, diagnostics and usage analytics are collected only if '
              'you turn them on.',
          'We do not sell your data, show ads, use an advertising ID, or use '
              'your chats or files to train our own models.',
          'Your prompts, files and relevant chat context are sent to the model '
              'providers that generate the answer.',
          'You can export your data, turn off crash reports and delete your '
              'account in the app. Deletion has a 24-hour grace period.',
          'Ovid Si is for adults (18+). It is not directed at children.',
        ],
      ),
      V2LegalSection(
        heading: 'Who is responsible for your data',
        body:
            'Dhanuk Softwares is the data controller for the account and content '
            'data described in this policy. Contact us about privacy at '
            'support@ovidsi.com with "Privacy" in the subject line.',
      ),
      V2LegalSection(
        heading: 'What we collect',
        body:
            'We collect the data needed to run the service. Some of it is '
            'required to use chat; files, connectors, browser activity and '
            'notifications are collected only when you choose to use them.',
        bullets: <String>[
          'Account and sign-in: email address or phone number, Firebase user ID '
              'and the display name or photo your provider shares.',
          'Chats and memory: prompts, replies, agent activity, session and '
              'project memory, titles and the search index.',
          'Files and workspace: attachments, generated images, code, Studio '
              'repository files, downloads and artifacts.',
          'Browser activity: pages the agent opens, text typed into forms, '
              'downloads, cookies and saved logins.',
          'Studio and connectors: the repository and branch you choose, '
              'commits, connector accounts and credentials you add.',
          'Usage and plan: token counts, runs, storage, model choice, limits '
              'and timestamps.',
          'Purchases: plan, entitlement, store transaction ID and refund status. '
              'Google Play handles your card details.',
          'Device and push: Firebase Cloud Messaging token, platform and app '
              'version, only if you allow notifications.',
          'Optional crash reports and usage analytics, technical and security '
              'data, and the messages you send to support.',
        ],
      ),
      V2LegalSection(
        heading: 'What we do not collect',
        body:
            'The app does not ask for or read these from your device. Voice '
            'input is turned into text on your device and only the text is sent.',
        bullets: <String>[
          'Your location, contacts, calendar, SMS, call logs, health or fitness '
              'data.',
          'Your whole photo or video library; only the file you pick is '
              'uploaded.',
          'Your advertising ID, and we do not show ads.',
          'Biometric data; app lock asks Android for the result of the check, '
              'not the fingerprint or face itself.',
        ],
      ),
      V2LegalSection(
        heading: 'Why we use your data',
        body:
            'We use your data to provide the service, process payments, keep the '
            'service safe, support you, improve reliability from reports you turn '
            'on, and meet the law. In the EEA, the UK and Switzerland our legal '
            'bases are contract performance, legal obligation, legitimate '
            'interests and, for optional analytics and notifications, consent.',
      ),
      V2LegalSection(
        heading: 'AI processing and model providers',
        body:
            'Ovid Si does not run a model on your phone. We send the prompt, '
            'relevant recent conversation, attached files or images and relevant '
            'memory through our LiteLLM gateway to the model provider that '
            'generates the answer. Providers include Anthropic, Google and other '
            'models shown in the app, or the BYOK provider you choose. We do not '
            'use your chats or files to train our own models, and we do not sell '
            'them. AI output can be wrong, so check it before you rely on it.',
      ),
      V2LegalSection(
        heading: 'Who processes your data',
        bullets: <String>[
          'Google Firebase: sign-in, push notifications, optional crash reports '
              'and analytics, and app verification.',
          'Google Play and RevenueCat: subscriptions, payments and entitlements.',
          'Cloudflare and R2: CDN, security and encrypted file storage.',
          'LiteLLM and model providers: routing and generating replies.',
          'GitHub and the connectors you add: the repository and services you '
              'choose.',
        ],
      ),
      V2LegalSection(
        heading: 'When you choose to share',
        body:
            'Share links are public snapshots at an unguessable URL for up to 30 '
            'days, or until you revoke them. A recipient can fork a snapshot into '
            'their own account and that copy belongs to them. Collab members can '
            'see the session messages and included files; the creator pays for '
            'storage and the owner can remove members. We cannot delete a copy '
            'someone else has already saved.',
      ),
      V2LegalSection(
        heading: 'Cookies, ads and tracking',
        body:
            'The app has no advertising SDKs, does not use an advertising ID and '
            'does not track you across other apps or websites. Firebase uses app '
            'instance identifiers for notifications, verification and, with your '
            'consent, crash and usage data. Our public policy pages are plain '
            'HTML; Cloudflare may set a security cookie.',
      ),
      V2LegalSection(
        heading: 'Where your data is stored',
        body:
            'Our servers and those of our providers may be in Canada, the United '
            'States, the European Union, India or other countries. Where the law '
            'requires it we use contractual and organisational safeguards for '
            'these transfers. We do not store full payment card details.',
      ),
      V2LegalSection(
        heading: 'How long we keep your data',
        bullets: <String>[
          'Account and profile: until you delete your account, plus the 24-hour '
              'grace period, then a minimal deletion record.',
          'Chats, memory, files and workspace: while your account is open and '
              'until you delete them; residual copies may remain in encrypted '
              'backups until they expire.',
          'Live run events: 24 hours. Technical run archive: up to 30 days.',
          'Crash reports, diagnostics and analytics: normally up to 90 days, and '
              'only if you turned them on.',
          'Share links: up to 30 days. Reports: up to 180 days. Security logs: '
              'normally no more than 30 days. Backups: up to 14 days.',
        ],
      ),
      V2LegalSection(
        heading: 'How we protect your data',
        body:
            'Data is encrypted in transit with HTTPS and WSS. Sensitive data at '
            'rest, such as provider keys and browser profiles, is encrypted. We '
            'use per-user workspaces, access controls, rate limits, App Check and '
            'monitoring, and our application logs are designed not to contain '
            'passwords, keys, prompts or file contents.',
      ),
      V2LegalSection(
        heading: 'Your choices and rights',
        bullets: <String>[
          'Export your chats and data from Settings.',
          'Correct your account details, or delete a chat or file in the app.',
          'Turn crash reports and usage analytics on or off in Settings; they '
              'are off by default.',
          'Turn notifications off, withdraw consent, or object to processing.',
          'Ask for access, correction, deletion, portability or restriction by '
              'emailing support@ovidsi.com.',
        ],
      ),
      V2LegalSection(
        heading: 'Deleting your account and your data',
        body:
            'Open Settings -> Account -> Delete account and confirm. Your account '
            'is scheduled for deletion with a 24-hour grace period. During that '
            'time, sign in again and choose Restore account. After the grace '
            'period deletion cannot be undone. You can also request deletion at '
            'ovidsi.com/delete-account.',
        bullets: <String>[
          'We delete your account record, chats, memory, files, workspace, '
              'artifacts, browser state, schedules, share links, Collab '
              'memberships, credentials and push tokens.',
          'Encrypted backups expire within 14 days. We keep a minimal deletion '
              'record and billing records the law requires.',
          'Other people\'s forks and Collab copies belong to their accounts and '
              'are not deleted with yours.',
          'Deleting your account does not cancel a Google Play subscription. '
              'Cancel it in Google Play.',
        ],
      ),
      V2LegalSection(
        heading: 'Children',
        body:
            'Ovid Si is for adults. You must be at least 18 years old to use it. '
            'We do not knowingly collect personal data from anyone under 18, and '
            'we will delete an account if we learn a child created it.',
      ),
      V2LegalSection(
        heading: 'Regional privacy rights',
        bullets: <String>[
          'EEA, UK and Switzerland: access, correction, deletion, restriction, '
              'objection, portability, withdrawing consent and complaining to '
              'your supervisory authority.',
          'India: access, correction, erasure, grievance redressal, withdrawing '
              'consent and nominating someone under the DPDP Act, 2023.',
          'California and other US states: know, access, delete, correct, opt '
              'out of sale or sharing, limit sensitive data and non-discrimination. '
              'We do not sell personal information.',
        ],
      ),
      V2LegalSection(
        heading: 'Changes and contact',
        body:
            'We may update this policy when the service or the law changes and '
            'will change the date above. For privacy requests, support or '
            'complaints, email support@ovidsi.com. Ask us at that address for our '
            'current business address.',
      ),
    ],
  );

  static const _terms = V2LegalPageData(
    title: 'Terms of service',
    icon: Icons.gavel_rounded,
    updatedAt: '21 October 2026',
    summary:
        'These Terms are a contract between you and Dhanuk Softwares for the '
        'Ovid Si app and cloud service. By creating an account or using Ovid Si, '
        'you agree to them and to the Privacy Policy.',
    sections: <V2LegalSection>[
      V2LegalSection(
        heading: 'The short version',
        bullets: <String>[
          'You must be 18 or older and use Ovid Si lawfully.',
          'Ovid Si is an AI assistant. It can be wrong and is not a lawyer, '
              'doctor, financial adviser or emergency service.',
          'You keep ownership of your content and give us permission to process '
              'it to run the service, including sending it to model providers.',
          'Do not use Ovid Si for illegal, harmful or abusive content, to break '
              'into systems, or to violate other people\'s rights.',
          'Paid plans are monthly subscriptions sold through Google Play. Cancel '
              'in Google Play, not by deleting the app.',
          'You can delete your account in the app. There is a 24-hour grace '
              'period, after which deletion cannot be undone.',
        ],
      ),
      V2LegalSection(
        heading: 'Who we are',
        body:
            'Ovid Si is operated by Dhanuk Softwares. "Ovid Si" and "the Service" '
            'mean the Android app, the cloud agent runtime, the website at '
            'ovidsi.com and related features. Ovid Si is not affiliated with or '
            'endorsed by Anthropic, Google, GitHub or RevenueCat.',
      ),
      V2LegalSection(
        heading: 'Accepting these Terms',
        body:
            'By creating an account or using the Service you confirm that you '
            'have read and agree to these Terms and the Privacy Policy, that you '
            'are at least 18 and legally able to enter this contract, that you '
            'are not barred from using the Service, and that the information you '
            'give us is accurate. If you do not agree, do not use the Service.',
      ),
      V2LegalSection(
        heading: 'Your account',
        body:
            'You can sign in with Google or a phone number. You are responsible '
            'for keeping your device, Google account and phone number secure, for '
            'all activity through your account, and for telling us promptly at '
            'support@ovidsi.com if you think someone else has access. Do not '
            'impersonate anyone, evade a suspension, or sell or transfer your '
            'account without our written permission.',
      ),
      V2LegalSection(
        heading: 'What Ovid Si does',
        body:
            'Ovid Si is an always-on personal AI agent that runs in the cloud, '
            'not on your phone. Depending on what you ask and the permissions you '
            'choose, it can:',
        bullets: <String>[
          'Chat and remember useful context in session, project and global '
              'memory.',
          'Run an agent with up to 50 subagents in a session, each with its full '
              'log in the session workspace.',
          'Work in a cloud workspace connected to a GitHub repository, edit '
              'files, run commands, show a live preview and commit or push.',
          'Browse the web in a cloud browser, including live view, take control, '
              'uploads and downloads.',
          'Create schedules, images, documents, code and other artifacts.',
          'Share a read-only snapshot or run a Collab session with other people.',
        ],
      ),
      V2LegalSection(
        heading: 'Plans, payments and subscriptions',
        body:
            'Free costs \$0 and includes 3 GB with Auto models only. Go is \$5 or '
            '₹499 per month with 5 GB and Auto models. Plus is \$18 or ₹1,799 per '
            'month with 15 GB and manual models. Pro is \$99 or ₹9,999 per month '
            'with 75 GB and manual models. Paid plans are sold through Google '
            'Play, which is the merchant and handles card details; RevenueCat '
            'keeps entitlements in sync. Subscriptions renew automatically until '
            'cancelled in Google Play. Deleting the app or your account does not '
            'cancel a Google Play subscription.',
      ),
      V2LegalSection(
        heading: 'AI output and your content',
        body:
            'Ovid Si uses third-party models. Output may be inaccurate, '
            'incomplete, biased or out of date, may contain insecure code, and is '
            'not professional advice. You are responsible for what you do with '
            'it. You keep ownership of the content you submit and give us a '
            'worldwide, non-exclusive, royalty-free licence to host, store, '
            'process, transmit and back it up only to provide, secure and support '
            'the Service. We do not train our own models on it. You may use '
            'output for lawful purposes, subject to third-party rights. Feedback '
            'may be used without obligation or payment.',
      ),
      V2LegalSection(
        heading: 'Acceptable use',
        body:
            'Use Ovid Si lawfully and respectfully. Do not use it to break the '
            'law, commit fraud or infringe rights; create or share objectionable '
            'content, including child sexual abuse material, non-consensual '
            'intimate imagery, hate speech, harassment, threats or graphic '
            'violence; stalk, dox, impersonate or harm anyone; distribute malware, '
            'phishing links or spam; break into or disrupt systems; evade '
            'paywalls, access controls, rate limits or security checks; mine '
            'cryptocurrency or run denial-of-service attacks; resell Ovid Si '
            'without written agreement; or violate a provider\'s terms. You are '
            'responsible for the instructions you give and the actions the agent '
            'takes for you.',
      ),
      V2LegalSection(
        heading: 'Sharing, Collab and public links',
        body:
            'A share link is viewable by anyone with the link for up to 30 days '
            'unless revoked. A recipient can fork a snapshot into their own '
            'account. Collab members can see session messages and included files; '
            'the owner can remove members and members can leave, but messages '
            'already sent may remain. The creator pays for storage. You must have '
            'permission to share the content you put into a share link or Collab '
            'session. We may remove a share or end a session that distributes '
            'objectionable content.',
      ),
      V2LegalSection(
        heading: 'Reporting and moderation',
        body:
            'We do not tolerate objectionable content or abusive users. Where the '
            'app shows a Report action, use it. You can also email '
            'support@ovidsi.com with a link or description and the session ID if '
            'you have it. We aim to review reports within 24 to 48 hours and may '
            'remove content, end a share or Collab session, limit features, '
            'suspend or terminate an account, preserve evidence, report illegal '
            'content, or block one account from another. If you think we made a '
            'mistake, email us and we will review it.',
      ),
      V2LegalSection(
        heading: 'Studio, GitHub and third-party services',
        body:
            'To use Studio you connect GitHub by OAuth or a personal access token, '
            'then choose a repository and branch. You confirm you have the right '
            'to access it and let Ovid clone, edit, commit and push to it. We use '
            'the credential only for the operations you ask for and never write '
            'it into the repository\'s .git/config. You are responsible for your '
            'repository\'s licences, secrets, branch protections and backups. '
            'Other services, including Firebase, Google Play, Cloudflare, '
            'RevenueCat, GitHub and model providers, have their own terms and '
            'privacy policies.',
      ),
      V2LegalSection(
        heading: 'Privacy',
        body:
            'The Privacy Policy explains what we collect, how we use it, who '
            'processes it, how long we keep it and how to delete it. It is part '
            'of these Terms. Do not send passwords, full payment card numbers, '
            'government identifiers or other people\'s sensitive information in a '
            'chat.',
      ),
      V2LegalSection(
        heading: 'Deleting your account, suspension and termination',
        body:
            'Delete your account in the app or at ovidsi.com/delete-account. '
            'Deletion has a 24-hour grace period; sign in again and choose '
            'Restore account to cancel it. After that it cannot be undone. '
            'Deleting your account does not cancel a Google Play subscription. We '
            'may suspend or end access if you break these Terms or the law, '
            'create a security, legal or safety risk, do not pay, or if the law '
            'requires it. Where reasonable and safe we will explain why and give '
            'you a chance to appeal at support@ovidsi.com.',
      ),
      V2LegalSection(
        heading: 'Disclaimers and liability',
        body:
            'The Service is provided on an "as is" and "as available" basis to '
            'the extent the law allows. We do not promise uninterrupted or '
            'error-free service, and we are not liable for indirect, incidental '
            'or consequential loss. Nothing in these Terms limits rights that '
            'consumer law does not allow us to limit. You agree to indemnify us '
            'for claims arising from your misuse of the Service or your content.',
      ),
      V2LegalSection(
        heading: 'Changes, governing law and contact',
        body:
            'We may change the Service and these Terms. Material changes will be '
            'notified in the app or by email before they take effect. These Terms '
            'are governed by the laws of India, and disputes are subject to the '
            'courts there. Sections about ownership, the content licence, '
            'disclaimers, liability, indemnity and governing law survive the end '
            'of your account. Contact support@ovidsi.com with any questions.',
      ),
    ],
  );

  static const _licences = V2LegalPageData(
    title: 'Open-source licences',
    icon: Icons.code_rounded,
    updatedAt: '21 October 2026',
    summary:
        'Ovid Si is built with Flutter and open-source packages. Each package '
        'stays under its own licence; the notices file that ships with the app '
        'lists every package and version.',
    sections: <V2LegalSection>[
      V2LegalSection(
        heading: 'Flutter and the Dart SDK',
        body:
            'Ovid Si is built with Flutter. Flutter and the Dart SDK are '
            'distributed under the BSD 3-Clause licence.',
        bullets: <String>['Flutter — BSD 3-Clause', 'Dart — BSD 3-Clause'],
      ),
      V2LegalSection(
        heading: 'Dart and Flutter packages',
        body:
            'These packages are used to talk to services, store settings, show '
            'web content, handle files and keep the app secure. They are '
            'distributed under the licences declared in their packages.',
        bullets: <String>[
          'http — BSD 3-Clause',
          'flutter_markdown_plus and markdown — BSD 3-Clause and MIT',
          'path_provider and shared_preferences — BSD 3-Clause',
          'webview_flutter — BSD 3-Clause',
          'flutter_secure_storage — BSD 3-Clause',
          'crypto and cryptography — BSD 3-Clause and Apache 2.0',
          'file_picker, permission_handler and url_launcher — MIT and BSD '
              '3-Clause',
          'Firebase, Google Sign-In, in_app_purchase and purchases_flutter — '
              'Apache 2.0 and BSD 3-Clause',
        ],
      ),
      V2LegalSection(
        heading: 'Fonts',
        body:
            'Inter and JetBrains Mono are bundled with the app under the SIL Open '
            'Font License 1.1.',
      ),
      V2LegalSection(
        heading: 'Written offer',
        body:
            'If a licence requires source code for a bundled component, email '
            'support@ovidsi.com and we will send it.',
      ),
      V2LegalSection(
        heading: 'Full notices',
        body:
            'The complete licence notices are generated from the packages in the '
            'app build and included with the app. If a notice is missing or a '
            'version is unclear, contact support@ovidsi.com.',
      ),
    ],
  );
}

/// Injected state for the About screen. Every row reports through a callback;
/// the screen never opens a URL, copies to the clipboard or reads the package
/// itself.
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
    this.legalDocuments,
    this.openExternal,
  });

  /// The build's real version and build number. They default to
  /// `kAppVersion`/`kAppBuildNumber` (`core/app_info.dart`), so a caller that
  /// does not inject them still shows the shipped build, never a demo string.
  final String version;
  final String build;

  /// Retained for callers; the minimal About screen has no hero or tagline.
  final String tagline;
  final V2SystemStatus systemStatus;

  /// When supplied, the legal rows open the in-app [LegalPage] with these
  /// documents. Null keeps the row wired to the legacy callbacks below.
  final V2AboutLegalDocuments? legalDocuments;

  final VoidCallback? onCopyVersion;
  final VoidCallback? onPrivacyPolicy;
  final VoidCallback? onTerms;
  final VoidCallback? onLicences;

  /// Retained for hosts. The minimal About screen shows only the build and
  /// the three legal documents; support lives in Account.
  final VoidCallback? onContactSupport;

  /// Opens the full status page.
  final VoidCallback? onSystemStatus;

  /// Used by the failed status check; falls back to [onSystemStatus].
  final VoidCallback? onRetrySystemStatus;

  /// Opens the account deletion flow. The flow owns the confirmation; this
  /// row only names the consequence.
  final VoidCallback? onDeleteAccount;

  /// Opens an external destination. Defaults to the real platform launcher;
  /// injectable so a test can assert the exact URL without a plugin.
  final Future<bool> Function(Uri uri)? openExternal;

  /// The build's real version, from `--dart-define` or the pubspec defaults.
  /// Callers can override it, but the default is never a demo string.
  bool get hasVersion => version.trim().isNotEmpty;

  String get versionLabel =>
      build.trim().isEmpty ? 'v$version' : 'v$version ($build)';

  String get buildLabel =>
      build.trim().isEmpty ? version : '$version · build $build';
}

/// About Ovid Si: the build and the legal documents. No hero, no support row,
/// and no status tile unless the caller wired a real status.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, required this.data});

  final V2AboutPageData data;

  @override
  Widget build(BuildContext context) {
    final statusTap = _statusTap;
    return OScreen(
      title: 'About',
      child: OFadeSlide(
        child: ListView(
          padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
          children: [
            if (data.hasVersion) _build(context),
            _legal(context),
            if (statusTap != null) _status(context, statusTap),
          ],
        ),
      ),
    );
  }

  /// The real version and build of this app, with the one copy action.
  Widget _build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: OSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const OSectionTitle(title: 'Build'),
          OCard(
            padding: EdgeInsets.zero,
            child: OListRow(
              icon: Icons.info_outline_rounded,
              title: 'Version',
              subtitle: data.buildLabel,
              showChevron: false,
              trailing: OIconButton(
                icon: Icons.copy_rounded,
                semanticLabel: 'Copy version info',
                tooltip: 'Copy version info',
                onPressed: () => _copyVersion(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legal(BuildContext context) {
    final docs = data.legalDocuments;
    final privacyTap = _legalTap(
      context,
      docs?.privacyPolicy,
      data.onPrivacyPolicy,
      // Published policy: the same URL Play reviewers open.
      fallback: () => _openUrl(context, LegalLinks.privacyPolicy),
    );
    final termsTap = _legalTap(
      context,
      docs?.terms,
      data.onTerms,
      fallback: () => _openUrl(context, LegalLinks.terms),
    );
    final licencesTap = _legalTap(
      context,
      docs?.licences,
      data.onLicences,
      // Real licence registry from the packages in this build.
      fallback: () => showLicensePage(
        context: context,
        applicationName: 'Ovid Si',
        applicationVersion: data.buildLabel,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OSectionTitle(title: 'Legal'),
        OCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _legalRow(
                icon: Icons.shield_outlined,
                title: 'Privacy policy',
                onTap: privacyTap,
              ),
              const Divider(height: 1, thickness: 1),
              _legalRow(
                icon: Icons.description_outlined,
                title: 'Terms of service',
                onTap: termsTap,
              ),
              const Divider(height: 1, thickness: 1),
              _legalRow(
                icon: Icons.code_rounded,
                title: 'Open-source licences',
                onTap: licencesTap,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// A legal row is always actionable, so it announces its enabled state
  /// explicitly (`OListRow` only sets it for disabled rows).
  Widget _legalRow({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return Semantics(
      container: true,
      enabled: true,
      child: OListRow(icon: icon, title: title, onTap: onTap),
    );
  }

  /// An injected document opens in-app; otherwise the injected callback wins
  /// and a real URL (or the licence registry) is the default, so no legal row
  /// is ever a disabled placeholder.
  VoidCallback _legalTap(
    BuildContext context,
    V2LegalPageData? document,
    VoidCallback? callback, {
    required VoidCallback fallback,
  }) {
    if (document != null) return () => _openLegal(context, document);
    return callback ?? fallback;
  }

  void _openLegal(BuildContext context, V2LegalPageData document) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => LegalPage(data: document)));
  }

  Future<void> _openUrl(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    var opened = false;
    try {
      opened = await (data.openExternal?.call(uri) ??
          launchUrl(uri, mode: LaunchMode.externalApplication));
    } catch (_) {
      opened = false;
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the link.')),
      );
    }
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

  String get _statusLabel => switch (data.systemStatus) {
    V2SystemStatus.unknown => '',
    V2SystemStatus.checking => 'Checking…',
    V2SystemStatus.operational => 'Operational',
    V2SystemStatus.degraded => 'Some issues',
    V2SystemStatus.error => 'Could not check',
  };

  /// A failed check retries; otherwise the row opens the status page. With no
  /// handler at all there is no row: a status tile that cannot do anything is
  /// chrome.
  VoidCallback? get _statusTap {
    if (data.systemStatus == V2SystemStatus.error) {
      return data.onRetrySystemStatus ?? data.onSystemStatus;
    }
    return data.onSystemStatus;
  }

  Widget _status(BuildContext context, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.only(top: OSpace.xl),
      child: OCard(
        padding: EdgeInsets.zero,
        child: OListRow(
          icon: Icons.monitor_heart_outlined,
          title: 'System status',
          subtitle: _statusLabel.isEmpty ? null : _statusLabel,
          showChevron: onTap != null,
          onTap: onTap,
        ),
      ),
    );
  }
}
