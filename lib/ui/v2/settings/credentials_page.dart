import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/diag.dart';
import '../../../core/secure_store.dart';
import '../../design/o_components.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'settings_rows.dart';

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
/// mask for display. There is no reveal control and no copy control.
class CredentialsPage extends StatefulWidget {
  const CredentialsPage({super.key, required this.data, this.keyStore});

  final V2CredentialsPageData data;

  /// Test/host seam. Defaults to the hardened platform secure store.
  final V2CredentialKeyStore? keyStore;

  @override
  State<CredentialsPage> createState() => _CredentialsPageState();
}

class _CredentialsPageState extends State<CredentialsPage> {
  static const String _personalId = 'personal';
  static const String _githubId = 'github';

  late final V2CredentialKeyStore _store =
      widget.keyStore ?? V2SecureCredentialKeyStore();

  /// Masks only. The raw secret is never retained after the save call.
  String? _tokenMask;
  String? _githubPatMask;

  /// The first store read, and a failed read that must be retried, not hidden.
  bool _reading = true;
  bool _readFailed = false;

  /// One in-flight operation at a time. Each id owns its own row spinner.
  String? _savingId;
  String? _removingId;
  bool _revoking = false;

  V2CredentialsPageData get data => widget.data;

  bool get _busy => _savingId != null || _removingId != null || _revoking;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSecrets());
  }

  Future<void> _loadSecrets({bool showLoading = false}) async {
    if (showLoading && mounted) {
      setState(() {
        _reading = true;
        _readFailed = false;
      });
    }
    String? tokenMask;
    String? patMask;
    var failed = false;
    // An unreadable keystore must not crash the screen; it becomes a retryable
    // error state instead of a row that quietly says "Not added yet".
    try {
      tokenMask = _maskSecret(await _store.read(_personalId));
    } catch (error, stack) {
      failed = true;
      Diag.swallow('credentials.readPersonal', error, stack);
    }
    try {
      patMask = _maskSecret(await _store.read(_githubId));
    } catch (error, stack) {
      failed = true;
      Diag.swallow('credentials.readGithub', error, stack);
    }
    if (!mounted) return;
    setState(() {
      _tokenMask = tokenMask;
      _githubPatMask = patMask;
      _reading = false;
      _readFailed = failed;
    });
  }

  bool get _tokenSaved =>
      _tokenMask != null || (data.token?.connected ?? false);

  bool get _githubPatSaved => _githubPatMask != null || data.githubPatAdded;

  String get _tokenHint {
    if (_tokenMask != null) return _tokenMask!;
    final token = data.token;
    if (token != null && token.connected) return _maskedToken(token.subtitle);
    return 'Not added yet';
  }

  bool get _hasAnyCredential =>
      (data.google?.connected ?? false) ||
      (data.github?.connected ?? false) ||
      _tokenSaved ||
      _githubPatSaved ||
      data.browserCredentials.isNotEmpty;

  Future<bool> _storeSecret({
    required String id,
    required String value,
    required ValueChanged<String>? host,
    required String savedMessage,
  }) async {
    if (!mounted) return false;
    setState(() => _savingId = id);
    try {
      if (host != null) {
        host(value);
      } else {
        await _store.write(id, value);
        await _loadSecrets();
      }
      _snack(savedMessage);
      return true;
    } catch (error, stack) {
      Diag.swallow('credentials.save.$id', error, stack);
      _snack('Could not save the key. Try again.');
      return false;
    } finally {
      if (mounted) setState(() => _savingId = null);
    }
  }

  Future<void> _editToken() async {
    if (_busy) return;
    final saved = _tokenSaved;
    await showOSheet<bool>(
      context,
      title: saved ? 'Replace provider key' : 'Add provider key',
      builder: (_) => _SecretForm(
        fieldLabel: 'Provider API key',
        helper: 'Encrypted on this device. Never shown again.',
        replacing: saved,
        onSave: (value) => _storeSecret(
          id: _personalId,
          value: value,
          host: data.onSaveToken,
          savedMessage: 'Provider key saved.',
        ),
      ),
    );
  }

  Future<void> _removeToken() async {
    if (_busy) return;
    final hint = _tokenMask ?? _maskedToken(data.token?.subtitle ?? '');
    final confirmed = await _confirmSecretRemoval(
      title: 'Remove provider key?',
      body: hint == '••••'
          ? 'This key is deleted from this device.'
          : '$hint is deleted from this device.',
      action: 'Remove key',
    );
    if (confirmed != true || !mounted) return;
    await _deleteStored(
      _personalId,
      'Provider key',
      host: data.onRemoveToken,
    );
  }

  Future<void> _editGithubPat() async {
    if (_busy) return;
    final host = data.onAddGithubPat;
    if (host != null) {
      host();
      return;
    }
    final saved = _githubPatSaved;
    await showOSheet<bool>(
      context,
      title: saved ? 'Replace GitHub token' : 'Add GitHub token',
      builder: (_) => _SecretForm(
        fieldLabel: 'GitHub personal access token',
        helper: 'Used for git clone and push. Never shown again.',
        replacing: saved,
        onSave: (value) => _storeSecret(
          id: _githubId,
          value: value,
          host: data.onSaveGithubPat,
          savedMessage: 'GitHub token saved.',
        ),
      ),
    );
  }

  Future<void> _removeGithubPat() async {
    if (_busy) return;
    final hint = _githubPatMask ?? '••••';
    final confirmed = await _confirmSecretRemoval(
      title: 'Remove GitHub token?',
      body: '$hint is deleted from this device.',
      action: 'Remove token',
      cancelLabel: 'Keep token',
    );
    if (confirmed != true || !mounted) return;
    await _deleteStored(
      _githubId,
      'GitHub token',
      host: data.onRemoveGithubPat,
    );
  }

  Future<void> _deleteStored(
    String id,
    String label, {
    VoidCallback? host,
  }) async {
    if (!mounted) return;
    setState(() => _removingId = id);
    try {
      if (host != null) {
        host();
      } else {
        await _store.delete(id);
      }
      await _loadSecrets();
      _snack('$label removed.');
    } catch (error, stack) {
      Diag.swallow('credentials.delete.$id', error, stack);
      _snack('Could not remove the key. Try again.');
    } finally {
      if (mounted) setState(() => _removingId = null);
    }
  }

  Future<bool?> _confirmSecretRemoval({
    required String title,
    required String body,
    required String action,
    String cancelLabel = 'Keep key',
    Key confirmKey = const ValueKey<String>('credential-confirm-remove'),
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
                label: cancelLabel,
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(false),
              ),
              const SizedBox(height: OSpace.s),
              OButton(
                key: confirmKey,
                label: action,
                semanticLabel: '$action, destructive',
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
      // One column, never a stretched tablet row. The contract's cap for this
      // settings surface is 640 dp at every width above the phone band.
      maxWidth: 640,
      actions: [
        if (data.onAddBrowserCredential != null)
          OIconButton(
            key: const ValueKey<String>('credential-add-login'),
            icon: Icons.add_rounded,
            semanticLabel: 'Add login',
            tooltip: 'Add login',
            onPressed: _busy ? null : () => unawaited(_editBrowserCredential()),
          ),
      ],
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (data.loading || _reading) return const OSkeletonList(rows: 6);
    if (data.errorMessage != null) {
      return OErrorState(message: data.errorMessage!, onRetry: data.onRetry);
    }
    if (_readFailed) {
      return OErrorState(
        message: 'Could not read saved keys.',
        onRetry: () => unawaited(_loadSecrets(showLoading: true)),
      );
    }
    if (data.isEmpty) return _emptyState();

    final rows = _rows(context);
    return SingleChildScrollView(
      key: const ValueKey<String>('credentials-scroll'),
      padding: const EdgeInsets.only(top: OSpace.s, bottom: OSpace.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          V2SettingsRowList(rows: rows),
          if (_hasAnyCredential) ...[
            const SizedBox(height: OSpace.l),
            OButton(
              key: const ValueKey<String>('credential-revoke-all'),
              label: 'Revoke all credentials',
              semanticLabel: 'Revoke all credentials, destructive',
              icon: Icons.warning_amber_rounded,
              variant: OButtonVariant.danger,
              expand: true,
              loading: _revoking,
              onPressed: _busy ? null : () => unawaited(_confirmRevoke()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emptyState() {
    final connect = data.onConnectGoogle;
    return OEmptyState(
      icon: Icons.key_off_outlined,
      title: 'No credentials yet',
      message: 'Connect an account or add a key.',
      action: connect != null
          ? OButton(
              label: 'Connect Google',
              icon: Icons.mail_outline_rounded,
              onPressed: connect,
            )
          : OButton(
              key: const ValueKey<String>('credential-empty-add'),
              label: 'Add key',
              icon: Icons.add_rounded,
              onPressed: _busy ? null : () => unawaited(_editToken()),
            ),
    );
  }

  /// Every credential is one row: name, masked value, one control. Secrets are
  /// only ever rendered as a mask.
  List<Widget> _rows(BuildContext context) {
    final rows = <Widget>[];

    final google = data.google;
    final googleOn = google?.connected ?? false;
    rows.add(
      V2SettingsRow(
        key: const ValueKey<String>('credential-row-google'),
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
    rows.add(
      V2SettingsRow(
        key: const ValueKey<String>('credential-row-github'),
        icon: Icons.terminal_rounded,
        title: 'GitHub',
        subtitle: oauth ? 'Connected' : 'Not connected',
        showChevron: false,
        onTap: oauth
            ? data.onDisconnectGithubOAuth
            : data.onConnectGithubOAuth,
      ),
    );

    Widget? githubTrailing;
    if (_savingId == _githubId) {
      githubTrailing = _busyIndicator(_githubId, 'Saving token');
    } else if (_removingId == _githubId) {
      githubTrailing = _busyIndicator(_githubId, 'Removing token');
    } else if (_githubPatSaved) {
      githubTrailing = OIconButton(
        icon: Icons.delete_outline_rounded,
        semanticLabel: 'Remove GitHub token, destructive',
        tooltip: 'Remove GitHub token',
        onPressed: _busy ? null : () => unawaited(_removeGithubPat()),
      );
    }
    rows.add(
      V2SettingsRow(
        key: const ValueKey<String>('credential-row-github-token'),
        icon: Icons.key_rounded,
        title: 'GitHub token',
        subtitle: _githubPatSaved ? (_githubPatMask ?? '••••') : 'Not added',
        showChevron: false,
        onTap: _busy ? null : () => unawaited(_editGithubPat()),
        trailing: githubTrailing,
      ),
    );

    rows.add(
      V2SettingsRow(
        key: const ValueKey<String>('credential-row-provider-key'),
        icon: Icons.vpn_key_outlined,
        title: 'Provider key',
        subtitle: _tokenHint,
        showChevron: false,
        trailing: _tokenActions(),
      ),
    );

    rows.add(
      V2SettingsRow(
        key: const ValueKey<String>('credential-row-cloud-key'),
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
          : () => unawaited(_editBrowserCredential(existing: credential));
      rows.add(
        V2SettingsRow(
          key: ValueKey<String>('credential-row-browser-${credential.id}'),
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
                  semanticLabel: 'Delete ${credential.site}, destructive',
                  tooltip: 'Delete ${credential.site}',
                  onPressed: () =>
                      unawaited(_deleteBrowserCredential(credential)),
                ),
        ),
      );
    }

    return rows;
  }

  Widget _busyIndicator(String id, String label) {
    return Semantics(
      key: ValueKey<String>('credential-busy-$id'),
      label: label,
      liveRegion: true,
      child: const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  Future<void> _editBrowserCredential({V2BrowserCredential? existing}) async {
    final saved = await showOSheet<V2BrowserCredential>(
      context,
      title: existing == null ? 'Add browser login' : 'Edit browser login',
      builder: (_) => _BrowserCredentialForm(existing: existing),
    );
    if (saved == null || !mounted) return;
    if (existing == null) {
      data.onAddBrowserCredential?.call(saved);
      _snack('Login saved.');
    } else {
      data.onEditBrowserCredential?.call(saved);
      _snack('Login updated.');
    }
  }

  Future<void> _deleteBrowserCredential(
    V2BrowserCredential credential,
  ) async {
    final confirmed = await _confirmSecretRemoval(
      title: 'Delete ${credential.site}?',
      body: 'Ovid will no longer sign in to ${credential.site}.',
      action: 'Delete login',
      cancelLabel: 'Keep login',
      confirmKey: const ValueKey<String>('credential-confirm-delete-browser'),
    );
    if (confirmed != true || !mounted) return;
    final host = data.onDeleteBrowserCredential;
    if (host == null) return;
    try {
      host(credential);
      _snack('Login deleted.');
    } catch (error, stack) {
      Diag.swallow('credentials.deleteBrowser', error, stack);
      _snack('Could not delete the login. Try again.');
    }
  }

  /// Add/Replace/Remove for the provider key row. Icons keep the trailing
  /// control narrow enough for a 320 dp phone at 200 % text.
  Widget _tokenActions() {
    if (_savingId == _personalId) {
      return _busyIndicator(_personalId, 'Saving key');
    }
    if (_removingId == _personalId) {
      return _busyIndicator(_personalId, 'Removing key');
    }
    if (!_tokenSaved) {
      return OButton(
        key: const ValueKey<String>('provider-key-add'),
        label: 'Add',
        variant: OButtonVariant.ghost,
        onPressed: _busy ? null : () => unawaited(_editToken()),
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
          onPressed: _busy ? null : () => unawaited(_editToken()),
        ),
        OIconButton(
          key: const ValueKey<String>('provider-key-remove'),
          icon: Icons.delete_outline_rounded,
          semanticLabel: 'Remove provider key, destructive',
          tooltip: 'Remove provider key',
          onPressed: _busy ? null : () => unawaited(_removeToken()),
        ),
      ],
    );
  }

  Future<void> _confirmRevoke() async {
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Revoke all credentials?',
      builder: (sheetContext) {
        final c = OColors.of(sheetContext);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Every saved key and login is removed. Active tasks stop.',
                style: OType.bodySm.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Keep active',
                variant: OButtonVariant.secondary,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(false),
              ),
              const SizedBox(height: OSpace.s),
              OButton(
                key: const ValueKey<String>('credential-confirm-revoke'),
                label: 'Revoke now',
                semanticLabel: 'Revoke now, destructive',
                variant: OButtonVariant.dangerFill,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop(true),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await _revokeEverything();
  }

  /// Revokes every credential this screen can reach: the two secrets it owns,
  /// each host-owned browser login, and finally the host's own revoke (the
  /// Google/GitHub session). Every failure is reported, never swallowed.
  Future<void> _revokeEverything() async {
    setState(() => _revoking = true);
    var failed = false;

    Future<void> revokeLocal(String id, VoidCallback? host) async {
      try {
        if (host != null) {
          host();
        } else {
          await _store.delete(id);
        }
      } catch (error, stack) {
        failed = true;
        Diag.swallow('credentials.revokeAll.$id', error, stack);
      }
    }

    await revokeLocal(_personalId, data.onRemoveToken);
    await revokeLocal(_githubId, data.onRemoveGithubPat);

    final deleteBrowser = data.onDeleteBrowserCredential;
    if (deleteBrowser != null) {
      for (final credential in data.browserCredentials) {
        try {
          deleteBrowser(credential);
        } catch (error, stack) {
          failed = true;
          Diag.swallow('credentials.revokeAllBrowser', error, stack);
        }
      }
    }

    try {
      data.onRevokeAll?.call();
    } catch (error, stack) {
      failed = true;
      Diag.swallow('credentials.revokeAllHost', error, stack);
    }

    await _loadSecrets();
    if (!mounted) return;
    setState(() => _revoking = false);
    _snack(
      failed
          ? 'Some credentials could not be revoked.'
          : 'All credentials revoked.',
    );
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
    final entered = _password.text;
    // Never keep the typed password in the controller once it is handed over.
    _password.clear();
    Navigator.of(context).pop(
      V2BrowserCredential(
        id: existing?.id ?? 'browser-${DateTime.now().microsecondsSinceEpoch}',
        site: _site.text.trim(),
        username: _username.text.trim(),
        password: entered.isEmpty && existing != null
            ? existing.password
            : entered,
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
/// pre-filled or rendered again; the field stays obscured and is cleared the
/// moment the save succeeds.
class _SecretForm extends StatefulWidget {
  const _SecretForm({
    required this.fieldLabel,
    required this.helper,
    required this.replacing,
    required this.onSave,
  });

  final String fieldLabel;
  final String helper;
  final bool replacing;

  /// Writes the value to the real store. False keeps the sheet open so the
  /// person can retry without retyping the key.
  final Future<bool> Function(String value) onSave;

  @override
  State<_SecretForm> createState() => _SecretFormState();
}

class _SecretFormState extends State<_SecretForm> {
  final _controller = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (value.isEmpty || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final saved = await widget.onSave(value);
    if (!mounted) return;
    if (!saved) {
      setState(() {
        _saving = false;
        _error = 'Could not save. Try again.';
      });
      return;
    }
    // The key must not survive the successful save in this widget.
    _controller.clear();
    Navigator.of(context).pop(true);
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
            enabled: !_saving,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => unawaited(_save()),
            decoration: InputDecoration(
              labelText: widget.fieldLabel,
              helperText: widget.helper,
              helperMaxLines: 2,
              errorText: _error,
            ),
          ),
          const SizedBox(height: OSpace.l),
          OButton(
            key: const ValueKey<String>('provider-key-save'),
            label: widget.replacing ? 'Replace key' : 'Save key',
            expand: true,
            loading: _saving,
            onPressed: _saving || _controller.text.trim().isEmpty
                ? null
                : () => unawaited(_save()),
          ),
          const SizedBox(height: OSpace.s),
          OButton(
            label: 'Cancel',
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

/// Tokens are only ever rendered in a masked form. Everything except the last
/// four characters is hidden, whether the caller passed a raw key or an
/// already-masked hint. A value that is too short to have a safe tail renders
/// as a full mask instead.
String _maskedToken(String value) {
  final trimmed = value.trim();
  if (trimmed.length <= 4) return '••••';
  return '••••••${trimmed.substring(trimmed.length - 4)}';
}

/// Browser passwords are stricter than tokens: no characters of the stored
/// value are rendered, so a screenshot or shoulder-surfer learns nothing.
String _maskedPassword(String value) =>
    value.trim().isEmpty ? 'No password saved' : '••••••••';
