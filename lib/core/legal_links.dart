/// Public legal, policy and support destinations shown in the app.
///
/// Play reviewers must be able to open the privacy policy, terms and the
/// account-deletion request page without signing in, so each URL must serve a
/// plain HTML document (no JS challenge). Each value can be overridden per
/// build with `--dart-define`.
///
/// TODO(owner): publish plain-HTML pages at [privacyPolicy], [terms] and
/// [accountDeletionRequest], confirm [supportEmail] is monitored, and enter
/// the deletion URL as the Play Console "Delete account URL".
class LegalLinks {
  const LegalLinks._();

  /// Marketing site. Not a policy document.
  static const website = String.fromEnvironment(
    'OVID_WEBSITE_URL',
    defaultValue: 'https://dhanuk.page.gd/ovid',
  );

  static const privacyPolicy = String.fromEnvironment(
    'OVID_PRIVACY_URL',
    defaultValue: 'https://ovidsi.com/privacy',
  );

  static const terms = String.fromEnvironment(
    'OVID_TERMS_URL',
    defaultValue: 'https://ovidsi.com/terms',
  );

  /// Web form that accepts an account-deletion request without the app.
  static const accountDeletionRequest = String.fromEnvironment(
    'OVID_ACCOUNT_DELETION_URL',
    defaultValue: 'https://ovidsi.com/delete-account',
  );

  static const supportEmail = String.fromEnvironment(
    'OVID_SUPPORT_EMAIL',
    defaultValue: 'support@ovidsi.com',
  );

  /// Prefilled deletion request mail. The UID lets support find the account
  /// without asking the user for anything else.
  static Uri accountDeletionMail({String? uid}) => Uri(
    scheme: 'mailto',
    path: supportEmail,
    query: _encodeQuery({
      'subject': 'Ovid account deletion request',
      'body':
          'Please delete my Ovid account and its associated cloud data.\n\n'
          'User ID: ${uid ?? '(not signed in)'}\n',
    }),
  );

  // `Uri(queryParameters:)` encodes spaces as `+`, which mail clients show
  // literally. Encode as %20 instead.
  static String _encodeQuery(Map<String, String> params) => params.entries
      .map(
        (e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
      )
      .join('&');
}
