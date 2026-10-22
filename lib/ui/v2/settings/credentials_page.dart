import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/diag.dart';
import '../../../core/secure_store.dart';
import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the localization pass.

enum V2CredentialKind { google, github, token }

/// Reads and writes credential secrets in the platform secure store.
///
/// The page only ever reads a secret to derive a mask; the plaintext never
/// leaves this seam and is never put into [V2CredentialsPageData].
abstract class V2CredentialKeyStore {
  Future<String?> read(String id);
  Future<void> write(String id, String value);
  Future<void> delete(String id);
}

/// Production store over the same hardened [FlutterSecureStorage] used for
/// provider keys. Ids are stable (`personal`, `github`) and the prefix keeps
/// credential rows separate from the provider-key rows in `AppState`.
class V2SecureCredentialKeyStore implements V2CredentialKeyStore {
  V2SecureCredentialKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? ovidSecureStorage();

  static const String prefix = 'ovid_credential_key_';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String id) => _storage.read(key: '$prefix$id');

  @override
  Future<void> write(String id, String value) =>
      _storage.write(key: '$prefix$id', value: value);

  @override
  Future<void> delete(String id) => _storage.delete(key: '$prefix$id');
}

/// One connected credential.
@immutable
class V2Credential {
  const V2Credential({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    this.connected = true,
  });

  final String id;
  final V2CredentialKind kind;
  final String title;
  final String subtitle;
  final bool connected;
}

/// A site login the agent can use in the browser.
///
/// The password is write-only from the UI's point of view: the screen only
/// ever renders it masked, and the agent receives it through the credential
/// helper at run time, never through the transcript.
@immutable
class V2BrowserCredential {
  const V2BrowserCredential({
    required this.id,
    required this.site,
    required this.username,
    required this.password,
  });

  final String id;
  final String site;
  final String username;
  final String password;

  V2BrowserCredential copyWith({
    String? id,
    String? site,
    String? username,
    String? password,
  }) {
    return V2BrowserCredential(
      id: id ?? this.id,
      site: site ?? this.site,
      username: username ?? this.username,
      password: password ?? this.password,
    );
  }
}

/// Injected state for the Credentials screen.
@immutable
class V2CredentialsPageData {
  const V2CredentialsPageData({
    this.google,
    this.github,
    this.token,
    this.browserCredentials = const [],
    this.githubOAuthConnected,
    this.githubPatAdded = false,
    this.cloudKeyStatusLabel = 'Cloud key active',
    this.cloudKeyStatusDetail =
        'Encrypted on this device. The full key is never shown.',
    this.cloudKeyActive = true,
    this.loading = false,
    this.errorMessage,
    this.onConnectGoogle,
    this.onConnectGithub,
    this.onAddToken,
    this.onSaveToken,
    this.onRemoveToken,
    this.onAddBrowserCredential,
    this.onEditBrowserCredential,
    this.onDeleteBrowserCredential,
    this.onConnectGithubOAuth,
    this.onDisconnectGithubOAuth,
    this.onAddGithubPat,
    this.onSaveGithubPat,
    this.onRemoveGithubPat,
    this.onRevokeAll,
    this.onManageCloudKey,
    this.onCredentialTap,
    this.onRetry,
  });

  final V2Credential? google;
  final V2Credential? github;
  final V2Credential? token;

  /// Site logins used by the browser. Passwords are only rendered masked.
  final List<V2BrowserCredential> browserCredentials;

  /// OAuth state. When null it is derived from [github].
  final bool? githubOAuthConnected;

  /// Whether a GitHub personal access token is stored.
  final bool githubPatAdded;
  final String cloudKeyStatusLabel;
  final String cloudKeyStatusDetail;
  final bool cloudKeyActive;
  final bool loading;
  final String? errorMessage;

  final VoidCallback? onConnectGoogle;
  final VoidCallback? onConnectGithub;

  /// Legacy host-owned "add token" flow. New hosts use [onSaveToken], which
  /// receives the entered key and can write it to the provider store.
  final VoidCallback? onAddToken;

  /// Receives the entered provider key. When null the page writes it to
  /// [V2CredentialKeyStore] itself (secure storage by default).
  final ValueChanged<String>? onSaveToken;
  final VoidCallback? onRemoveToken;
  final ValueChanged<V2BrowserCredential>? onAddBrowserCredential;
  final ValueChanged<V2BrowserCredential>? onEditBrowserCredential;
  final ValueChanged<V2BrowserCredential>? onDeleteBrowserCredential;
  final VoidCallback? onConnectGithubOAuth;
  final VoidCallback? onDisconnectGithubOAuth;

  /// Legacy host-owned GitHub PAT flows. When null the page collects the token
  /// and stores it through [V2CredentialKeyStore].
  final VoidCallback? onAddGithubPat;
  final ValueChanged<String>? onSaveGithubPat;
  final VoidCallback? onRemoveGithubPat;
  final VoidCallback? onRevokeAll;
  final VoidCallback? onManageCloudKey;
  final ValueChanged<String>? onCredentialTap;
  final VoidCallback? onRetry;

  List<V2Credential> get credentials => <V2Credential>[
    ?google,
    ?github,
    ?token,
  ];

  bool get isEmpty =>
      credentials.isEmpty && browserCredentials.isEmpty && !githubPatAdded;

  bool get githubOAuthActive =>
      githubOAuthConnected ?? (github?.connected ?? false);
}

/// Connected accounts and personal keys used by Ovid.
///
/// Secrets are write-only from this screen's point of view: the add/replace
/// sheet collects a key, hands it to the store, and the page keeps only a
/// mask for display.
class CredentialsPage extends StatefulWidget {
  const CredentialsPage({super.key, required this.data, this.keyStore});

  final V2CredentialsPageData data;

  /// Test/host seam. Defaults to the hardened platform secure store.
  final V2CredentialKeyStore? keyStore;

  @override
  State<CredentialsPage> createState() => _CredentialsPageState();
}

class _CredentialsPageState extends State<CredentialsPage> {
  late final V2CredentialKeyStore _store =
      widget.keyStore ?? V2SecureCredentialKeyStore();

  /// Masks only. The raw secret is never retained after the save call.
  String? _tokenMask;
  String? _githubPatMask;

  V2CredentialsPageData get data => widget.data;

  @override
  void initState() {
    super.initState();
    _loadSecrets();
  }

  Future<void> _loadSecrets() async {
    String? token;
    String? pat;
    // An unreadable keystore must not crash the screen; the row simply reads
    // "Not added yet" until the platform answers again.
    try {
      token = await _store.read('personal');
    } catch (error, stack) {
      Diag.swallow('credentials.readPersonal', error, stack);
    }
    try {
      pat = await _store.read('github');
    } catch (error, stack) {
      Diag.swallow('credentials.readGithub', error, stack);
    }
    if (!mounted) return;
    setState(() {
      _tokenMask = _maskSecret(token);
      _githubPatMask = _maskSecret(pat);
    });
  }

  bool get _tokenSaved =>
      _tokenMask != null || (data.token?.connected ?? false);

  bool get _githubPatSaved => _githubPatMask != null || data.githubPatAdded;

  String get _tokenSubtitle {
    if (_tokenMask != null) return _tokenMask!;
    final token = data.token;
    if (token != null && token.connected) return _maskedToken(token.subtitle);
    return 'Not added yet';
  }

  bool get _hasAnyCredential =>
      data.credentials.any(
        (c) => c.kind == V2CredentialKind.token ? _tokenSaved : c.connected,
      ) ||
      data.browserCredentials.isNotEmpty ||
      _githubPatSaved;

  Future<void> _saveSecret({required String id, required String value}) async {
    await _store.write(id, value);
    await _loadSecrets();
  }

  Future<void> _editToken() async {
    final key = await showOSheet<String>(
      context,
      title: _tokenSaved ? 'Replace provider key' : 'Add provider key',
      builder: (_) => _SecretForm(
        fieldLabel: 'Provider API key',
        helper: 'Encrypted on this device. Never shown again.',
        replacing: _tokenSaved,
      ),
    );
    if (key == null || !mounted) return;
    final host = data.onSaveToken;
    if (host != null) {
      host(key);
    } else {
      try {
        await _saveSecret(id: 'personal', value: key);
        if (mounted) _snack('Provider key saved.');
      } catch (_) {
        if (mounted) _snack('Could not save the key. Try again.');
      }
    }
  }

  Future<void> _removeToken() async {
    final confirmed = await _confirmSecretRemoval(
      title: 'Remove provider key?',
      body:
          'Ovid will stop using this key for custom providers. The saved key '
          'is deleted from this device.',
      action: 'Remove key',
    );
    if (confirmed != true) return;
    final host = data.onRemoveToken;
    if (host != null) {
      host();
      return;
    }
    try {
      await _store.delete('personal');
      await _loadSecrets();
      if (mounted) _snack('Provider key removed.');
    } catch (_) {
      if (mounted) _snack('Could not remove the key. Try again.');
    }
  }

  Future<void> _editGithubPat() async {
    final host = data.onAddGithubPat;
    if (host != null) {
      host();
      return;
    }
    final token = await showOSheet<String>(
      context,
      title: _githubPatSaved ? 'Replace GitHub token' : 'Add GitHub token',
      builder: (_) => _SecretForm(
        fieldLabel: 'GitHub personal access token',
        helper: 'Used for git clone and push. Never shown again.',
        replacing: _githubPatSaved,
      ),
    );
    if (token == null || !mounted) return;
    final save = data.onSaveGithubPat;
    if (save != null) {
      save(token);
    } else {
      try {
        await _saveSecret(id: 'github', value: token);
        if (mounted) _snack('GitHub token saved.');
      } catch (_) {
        if (mounted) _snack('Could not save the token. Try again.');
      }
    }
  }

  Future<void> _removeGithubPat() async {
    final host = data.onRemoveGithubPat;
    if (host != null) {
      host();
      return;
    }
    final confirmed = await _confirmSecretRemoval(
      title: 'Remove GitHub token?',
      body:
          'Studio will no longer be able to clone or push with this token. '
          'It is deleted from this device.',
      action: 'Remove token',
    );
    if (confirmed != true) return;
    try {
      await _store.delete('github');
      await _loadSecrets();
      if (mounted) _snack('GitHub token removed.');
    } catch (_) {
      if (mounted) _snack('Could not remove the token. Try again.');
    }
  }

  Future<bool?> _confirmSecretRemoval({
    required String title,
    required String body,
    required String action,
  }) {
    return showOSheet<bool>(
      context,
      title: title,
      builder: (sheetContext) {
        final c = OColors.of(sheetContext);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(body, style: OType.bodySm.copyWith(color: c.textMuted)),
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Keep key',
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(false),
              ),
              const SizedBox(height: OSpace.s),
              OButton(
                key: const ValueKey<String>('credential-confirm-remove'),
                label: action,
                variant: OButtonVariant.dangerFill,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(true),
              ),
            ],
          ),
        );
      },
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Credentials',
      actions: [
        if (data.onAddBrowserCredential != null)
          OIconButton(
            key: const ValueKey<String>('credential-add-login'),
            icon: Icons.add_rounded,
            semanticLabel: 'Add login',
            tooltip: 'Add login',
            onPressed: () => _editBrowserCredential(context),
          ),
      ],
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.loading) return const OSkeletonList(rows: 6);
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    if (data.isEmpty) {
      return OEmptyState(
        icon: Icons.key_off_outlined,
        title: 'No credentials yet',
        message: 'Connect Google or GitHub to continue.',
        action: data.onConnectGoogle == null
            ? null
            : OButton(
                label: 'Connect Google',
                icon: Icons.mail_outline_rounded,
                onPressed: data.onConnectGoogle,
              ),
      );
    }

    final c = OColors.of(context);
    final rows = _rows(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var index = 0; index < rows.length; index++) ...[
                  if (index > 0) Divider(height: 1, color: c.hairline),
                  rows[index],
                ],
              ],
            ),
          ),
          if (data.onRevokeAll != null) ...[
            const SizedBox(height: OSpace.l),
            OButton(
              label: 'Revoke all credentials',
              icon: Icons.warning_amber_rounded,
              variant: OButtonVariant.danger,
              expand: true,
              onPressed: _hasAnyCredential
                  ? () => _confirmRevoke(context)
                  : null,
            ),
          ],
        ],
      ),
    );
  }

  /// Every credential is one row: name, masked value, one control. Secrets are
  /// only ever rendered as a mask.
  List<Widget> _rows(BuildContext context) {
    final rows = <Widget>[];

    void add(Widget row) => rows.add(row);

    final google = data.google;
    final googleOn = google?.connected ?? false;
    add(
      OListRow(
        icon: Icons.mail_outline_rounded,
        title: 'Google',
        subtitle: googleOn ? google!.subtitle : 'Not connected',
        showChevron: false,
        onTap: googleOn
            ? (data.onCredentialTap == null
                  ? null
                  : () => data.onCredentialTap!(google!.id))
            : data.onConnectGoogle,
      ),
    );

    final oauth = data.githubOAuthActive;
    add(
      OListRow(
        icon: Icons.terminal_rounded,
        title: 'GitHub',
        subtitle: oauth ? 'Connected' : 'Not connected',
        showChevron: false,
        onTap: oauth ? data.onDisconnectGithubOAuth : data.onConnectGithubOAuth,
      ),
    );

    add(
      OListRow(
        icon: Icons.key_rounded,
        title: 'GitHub token',
        subtitle: _githubPatSaved
            ? (_githubPatMask ?? _maskedToken(''))
            : 'Not added',
        showChevron: false,
        onTap: _editGithubPat,
        trailing: _githubPatSaved
            ? OIconButton(
                icon: Icons.delete_outline_rounded,
                semanticLabel: 'Remove GitHub token',
                tooltip: 'Remove GitHub token',
                onPressed: _removeGithubPat,
              )
            : null,
      ),
    );

    add(
      OListRow(
        icon: Icons.vpn_key_outlined,
        title: 'Provider key',
        subtitle: _tokenSubtitle,
        showChevron: false,
        trailing: _tokenActions(context),
      ),
    );

    add(
      OListRow(
        icon: Icons.cloud_outlined,
        title: 'Cloud key',
        subtitle: data.cloudKeyActive ? 'Active' : 'Off',
        showChevron: false,
        trailing: data.onManageCloudKey == null
            ? null
            : OIconButton(
                icon: Icons.settings_outlined,
                semanticLabel: 'Manage cloud key',
                tooltip: 'Manage',
                onPressed: data.onManageCloudKey,
              ),
      ),
    );

    for (final credential in data.browserCredentials) {
      final edit = data.onEditBrowserCredential == null
          ? null
          : () => _editBrowserCredential(context, existing: credential);
      add(
        OListRow(
          icon: Icons.language_rounded,
          title: credential.site,
          subtitle:
              '${credential.username} · ${_maskedPassword(credential.password)}',
          showChevron: false,
          onTap: edit,
          trailing: data.onDeleteBrowserCredential == null
              ? null
              : OIconButton(
                  icon: Icons.delete_outline_rounded,
                  semanticLabel: 'Delete ${credential.site}',
                  tooltip: 'Delete ${credential.site}',
                  onPressed: () =>
                      _deleteBrowserCredential(context, credential),
                ),
        ),
      );
    }

    return rows;
  }

  Future<void> _editBrowserCredential(
    BuildContext context, {
    V2BrowserCredential? existing,
  }) async {
    final saved = await showOSheet<V2BrowserCredential>(
      context,
      title: existing == null ? 'Add browser login' : 'Edit browser login',
      builder: (_) => _BrowserCredentialForm(existing: existing),
    );
    if (saved == null) return;
    if (existing == null) {
      data.onAddBrowserCredential?.call(saved);
    } else {
      data.onEditBrowserCredential?.call(saved);
    }
  }

  Future<void> _deleteBrowserCredential(
    BuildContext context,
    V2BrowserCredential credential,
  ) async {
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Delete login?',
      builder: (sheetContext) {
        final c = OColors.of(sheetContext);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Ovid will no longer be able to sign in to ${credential.site}.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Keep login',
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(false),
              ),
              const SizedBox(height: OSpace.s),
              OButton(
                label: 'Delete login',
                variant: OButtonVariant.dangerFill,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(true),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed == true) data.onDeleteBrowserCredential?.call(credential);
  }

  /// Add/Replace/Remove for the provider key row. Icons keep the trailing
  /// control narrow enough for a 320 dp phone at 200 % text.
  Widget _tokenActions(BuildContext context) {
    if (!_tokenSaved) {
      return OButton(
        key: const ValueKey<String>('provider-key-add'),
        label: 'Add',
        variant: OButtonVariant.ghost,
        onPressed: _editToken,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OIconButton(
          key: const ValueKey<String>('provider-key-replace'),
          icon: Icons.edit_rounded,
          semanticLabel: 'Replace provider key',
          tooltip: 'Replace provider key',
          onPressed: _editToken,
        ),
        OIconButton(
          key: const ValueKey<String>('provider-key-remove'),
          icon: Icons.delete_outline_rounded,
          semanticLabel: 'Remove provider key',
          tooltip: 'Remove provider key',
          onPressed: _removeToken,
        ),
      ],
    );
  }

  Future<void> _confirmRevoke(BuildContext context) async {
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Revoke all credentials?',
      builder: (context) {
        final c = OColors.of(context);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'This disconnects Google, GitHub, and your personal token. Active tasks will stop.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Keep active',
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: () => Navigator.of(context).pop(false),
              ),
              const SizedBox(height: OSpace.s),
              OButton(
                label: 'Revoke now',
                variant: OButtonVariant.dangerFill,
                expand: true,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed == true) {
      // Revoking also removes the secrets this screen owns.
      try {
        await _store.delete('personal');
        await _store.delete('github');
      } catch (error, stack) {
        Diag.swallow('credentials.revokeAll', error, stack);
      }
      await _loadSecrets();
      data.onRevokeAll?.call();
    }
  }
}

/// Add/edit form for a browser login. Owns its controllers so they outlive the
/// sheet's dismissal animation.
class _BrowserCredentialForm extends StatefulWidget {
  const _BrowserCredentialForm({this.existing});

  final V2BrowserCredential? existing;

  @override
  State<_BrowserCredentialForm> createState() => _BrowserCredentialFormState();
}

class _BrowserCredentialFormState extends State<_BrowserCredentialForm> {
  late final TextEditingController _site = TextEditingController(
    text: widget.existing?.site ?? '',
  );
  late final TextEditingController _username = TextEditingController(
    text: widget.existing?.username ?? '',
  );
  final _password = TextEditingController();

  @override
  void dispose() {
    _site.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _save() {
    final existing = widget.existing;
    Navigator.of(context).pop(
      V2BrowserCredential(
        id: existing?.id ?? 'browser-${DateTime.now().microsecondsSinceEpoch}',
        site: _site.text.trim(),
        username: _username.text.trim(),
        password: _password.text.isEmpty && existing != null
            ? existing.password
            : _password.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('browser-site-field'),
            controller: _site,
            autofocus: existing == null,
            textInputAction: TextInputAction.next,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Site',
              hintText: 'example.com',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: OSpace.m),
          TextField(
            key: const ValueKey('browser-username-field'),
            controller: _username,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Username',
              hintText: 'you@example.com',
            ),
          ),
          const SizedBox(height: OSpace.m),
          TextField(
            key: const ValueKey('browser-password-field'),
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Password',
              hintText: existing == null
                  ? 'Stored encrypted on this device'
                  : 'Leave blank to keep the saved password',
            ),
          ),
          const SizedBox(height: OSpace.l),
          OButton(
            label: existing == null ? 'Save login' : 'Save changes',
            expand: true,
            onPressed: _site.text.trim().isEmpty ? null : _save,
          ),
          const SizedBox(height: OSpace.s),
          OButton(
            label: 'Cancel',
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// A stored secret is only ever represented by its mask. Null means "nothing
/// saved" so the row can say so instead of showing an empty mask.
String? _maskSecret(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : _maskedToken(trimmed);
}

/// One-way secret editor. The entered value is handed to the caller and never
/// pre-filled or rendered again; the field stays obscured.
class _SecretForm extends StatefulWidget {
  const _SecretForm({
    required this.fieldLabel,
    required this.helper,
    required this.replacing,
  });

  final String fieldLabel;
  final String helper;
  final bool replacing;

  @override
  State<_SecretForm> createState() => _SecretFormState();
}

class _SecretFormState extends State<_SecretForm> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey<String>('provider-key-field'),
            controller: _controller,
            autofocus: true,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(
              labelText: widget.fieldLabel,
              helperText: widget.helper,
              helperMaxLines: 2,
            ),
          ),
          const SizedBox(height: OSpace.l),
          OButton(
            key: const ValueKey<String>('provider-key-save'),
            label: widget.replacing ? 'Replace key' : 'Save key',
            expand: true,
            onPressed: _controller.text.trim().isEmpty ? null : _save,
          ),
          const SizedBox(height: OSpace.s),
          OButton(
            label: 'Cancel',
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// Tokens are only ever rendered in a masked form. If a caller passes a raw
/// value by mistake, everything except the last four characters is hidden.
String _maskedToken(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '••••';
  if (trimmed.contains('•') || trimmed.contains('*')) return trimmed;
  if (trimmed.length <= 4) return '••••';
  return '••••••${trimmed.substring(trimmed.length - 4)}';
}

/// Browser passwords are stricter than tokens: no characters of the stored
/// value are rendered, so a screenshot or shoulder-surfer learns nothing.
String _maskedPassword(String value) =>
    value.trim().isEmpty ? 'No password saved' : '••••••••';
