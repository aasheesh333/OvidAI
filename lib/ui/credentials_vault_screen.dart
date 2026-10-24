import 'dart:async';

import 'package:flutter/material.dart';

import '../core/cloud/cloud_rest.dart';
import '../core/cloud/credentials.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Wave 6 W4 — the browser Credentials Vault.
///
/// Owner-scoped saved logins for the cloud browser. The server seals the
/// password/token with AES-256-GCM and NEVER sends it back: this screen only
/// ever shows metadata. The agent can use an entry to fill a login form
/// server-side, without the secret entering chat, events or logs.
class CredentialsVaultScreen extends StatefulWidget {
  const CredentialsVaultScreen({super.key, this.api});

  /// Test seam; production uses the authenticated gateway client.
  final CredentialsApi? api;

  @override
  State<CredentialsVaultScreen> createState() => _CredentialsVaultScreenState();
}

class _CredentialsVaultScreenState extends State<CredentialsVaultScreen> {
  late final CredentialsApi _api = widget.api ?? CloudCredentialsApi();
  List<BrowserCredential>? _items;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final items = await _api.list();
      if (!mounted) return;
      setState(() {
        _items = items;
        _busy = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err;
        _busy = false;
      });
    }
  }

  String _errorText(Object err) {
    if (err is CloudApiException) return err.message;
    return "Couldn't reach the credentials vault. Try again.";
  }

  Future<void> _add() async {
    final draft = await showDialog<_CredentialDraft>(
      context: context,
      builder: (_) => const _CredentialEditor(),
    );
    if (draft == null) return;
    try {
      await _api.create(
        label: draft.label,
        site: draft.site,
        username: draft.username,
        secret: draft.secret,
        secretKind: draft.secretKind,
        notes: draft.notes,
      );
      await _load();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(_errorText(err))));
    }
  }

  Future<void> _edit(BrowserCredential entry) async {
    final draft = await showDialog<_CredentialDraft>(
      context: context,
      builder: (_) => _CredentialEditor(existing: entry),
    );
    if (draft == null) return;
    try {
      await _api.update(
        entry.id,
        label: draft.label,
        site: draft.site,
        username: draft.username,
        // Empty means "keep the stored secret" — it is never prefilled.
        secret: draft.secret.isEmpty ? null : draft.secret,
        secretKind: draft.secretKind,
        notes: draft.notes,
        clearNotes: draft.clearNotes,
      );
      await _load();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(_errorText(err))));
    }
  }

  Future<void> _delete(BrowserCredential entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete credential?'),
        content: Text(
          '"${entry.label}" will be removed. The agent will no longer be able '
          'to sign in with it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('credentials-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _api.remove(entry.id);
      await _load();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(_errorText(err))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Credentials vault'),
        actions: [
          IconButton(
            key: const ValueKey('credentials-add'),
            tooltip: 'Add credential',
            icon: const Icon(Icons.add),
            onPressed: _add,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          children: [
            const AetherSectionTitle(eyebrow: 'BROWSER'),
            const SizedBox(height: 8),
            Text(
              'Saved logins the agent can use in the cloud browser. Secrets '
              'are encrypted on the server and are never shown here or in chat.',
              style: TextStyle(fontSize: 12, color: Aether.textMuted),
            ),
            const SizedBox(height: 14),
            if (_busy && items == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null && items == null)
              _ErrorCard(
                message: _errorText(_error!),
                onRetry: _load,
              )
            else if (items == null || items.isEmpty)
              const _EmptyCard()
            else
              AetherCard(
                padding: EdgeInsets.zero,
                child: Column(
                  key: const ValueKey('credentials-list'),
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) Divider(height: 1, color: Aether.hairline),
                      _CredentialTile(
                        key: ValueKey('credential-${items[i].id}'),
                        entry: items[i],
                        onEdit: () => _edit(items[i]),
                        onDelete: () => _delete(items[i]),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CredentialTile extends StatelessWidget {
  const _CredentialTile({
    super.key,
    required this.entry,
    required this.onEdit,
    required this.onDelete,
  });

  final BrowserCredential entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        entry.secretKind == 'token'
            ? Icons.key_outlined
            : Icons.password_outlined,
        size: 20,
        color: Aether.textMuted,
      ),
      title: Text(entry.label, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        [
          entry.site,
          if (entry.username.isNotEmpty) entry.username,
          entry.secretKind == 'token' ? 'token' : 'password',
        ].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.5, color: Aether.textFaint),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined, size: 19),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline, size: 19),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard();

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      child: Padding(
        key: const ValueKey('credentials-empty'),
        padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 16),
        child: Column(
          children: [
            Icon(Icons.lock_outline, size: 30, color: Aether.textMuted),
            const SizedBox(height: 10),
            const Text(
              'No saved credentials yet',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Add a login once, and the agent can use it on that site without '
              'ever seeing the secret.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Aether.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Column(
          children: [
            Icon(Icons.cloud_off, size: 26, color: Aether.textMuted),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const ValueKey('credentials-retry'),
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CredentialDraft {
  const _CredentialDraft({
    required this.label,
    required this.site,
    required this.username,
    required this.secret,
    required this.secretKind,
    required this.notes,
    required this.clearNotes,
  });

  final String label;
  final String site;
  final String username;
  final String secret;
  final String secretKind;
  final String notes;
  final bool clearNotes;
}

class _CredentialEditor extends StatefulWidget {
  const _CredentialEditor({this.existing});

  final BrowserCredential? existing;

  @override
  State<_CredentialEditor> createState() => _CredentialEditorState();
}

class _CredentialEditorState extends State<_CredentialEditor> {
  late final TextEditingController _label =
      TextEditingController(text: widget.existing?.label ?? '');
  late final TextEditingController _site =
      TextEditingController(text: widget.existing?.site ?? '');
  late final TextEditingController _username =
      TextEditingController(text: widget.existing?.username ?? '');
  final TextEditingController _secret = TextEditingController();
  final TextEditingController _notes = TextEditingController();
  late String _kind = widget.existing?.secretKind ?? 'password';
  bool _clearNotes = false;
  String? _validation;

  @override
  void dispose() {
    _label.dispose();
    _site.dispose();
    _username.dispose();
    _secret.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    final label = _label.text.trim();
    final site = _site.text.trim();
    if (label.isEmpty || site.isEmpty) {
      setState(() => _validation = 'A label and a site are required.');
      return;
    }
    final editing = widget.existing != null;
    if (!editing && _secret.text.isEmpty) {
      setState(() => _validation = 'Enter a password or token.');
      return;
    }
    Navigator.of(context).pop(
      _CredentialDraft(
        label: label,
        site: site,
        username: _username.text.trim(),
        secret: _secret.text,
        secretKind: _kind,
        notes: _notes.text.trim(),
        clearNotes: _clearNotes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return AlertDialog(
      title: Text(editing ? 'Edit credential' : 'Add credential'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('credential-label'),
              controller: _label,
              decoration: const InputDecoration(labelText: 'Label'),
            ),
            TextField(
              key: const ValueKey('credential-site'),
              controller: _site,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Site',
                hintText: 'example.com',
              ),
            ),
            TextField(
              key: const ValueKey('credential-username'),
              controller: _username,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Username or e-mail'),
            ),
            TextField(
              key: const ValueKey('credential-secret'),
              controller: _secret,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: _kind == 'token' ? 'Token' : 'Password',
                hintText: editing ? 'Leave blank to keep the current secret' : null,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: const ValueKey('credential-kind'),
              initialValue: _kind,
              items: const [
                DropdownMenuItem(value: 'password', child: Text('Password')),
                DropdownMenuItem(value: 'token', child: Text('Token')),
              ],
              onChanged: (v) => setState(() => _kind = v ?? 'password'),
              decoration: const InputDecoration(labelText: 'Kind'),
            ),
            TextField(
              key: const ValueKey('credential-notes'),
              controller: _notes,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: 'Notes (optional)',
                hintText: editing && widget.existing!.hasNotes
                    ? 'Saved notes are hidden; type to replace them'
                    : null,
              ),
            ),
            if (editing && widget.existing!.hasNotes)
              CheckboxListTile(
                key: const ValueKey('credential-clear-notes'),
                value: _clearNotes,
                onChanged: (v) => setState(() => _clearNotes = v == true),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  'Delete the saved notes',
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
            if (_validation != null) ...[
              const SizedBox(height: 8),
              Text(
                _validation!,
                style: TextStyle(fontSize: 12, color: Aether.warn),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('credential-save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
