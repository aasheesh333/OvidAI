import 'package:flutter/material.dart';

import '../core/cloud/account_settings_client.dart';
import '../core/cloud/cloud_rest.dart';
import '../core/cloud/cloud_session_store.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'user_error.dart';
import 'widgets/aether_confirm.dart';
import 'widgets/aether_primitives.dart';

String? memorySessionIdForTest;

String? _currentMemorySession() {
  if (memorySessionIdForTest != null) return memorySessionIdForTest;
  final localId = AppState.I.activeSession?.id;
  if (localId == null) return null;
  try {
    return CloudSessionStore.I.serverIdFor(localId) ??
        (RegExp(r'^[0-9a-f-]{36}$').hasMatch(localId) ? localId : null);
  } catch (_) {
    return null;
  }
}

String _memoryError(AppLocalizations l, Object e) {
  if (e is CloudApiException) {
    if (e.code == 'no_workspace') return l.memoryNoWorkspace;
    if (e.code == 'baseline_mismatch') return l.memoryConflict;
  }
  return friendlyError(e, l10n: l);
}

/// SE-006 — the agent's memory files on Ovid Cloud (`/memory`). Ovid saves
/// facts you ask it to remember as Markdown files in your cloud workspace;
/// here you can read, edit, add and delete them.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  List<MemoryFileSummary> _files = const [];
  String? _sessionId;
  bool _shared = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessionId = _sessionId ?? _currentMemorySession();
      if (sessionId == null) {
        setState(() { _files = const []; _loading = false; });
        return;
      }
      final listing = await AccountSettingsClient.I.memoryFiles(sessionId);
      if (!mounted) return;
      setState(() {
        _sessionId = sessionId;
        _files = listing.files;
        _shared = listing.shared;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _memoryError(context.l10n, e);
        _loading = false;
      });
    }
  }

  Future<void> _open(String? name) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => MemoryEditorScreen(name: name, sessionId: sessionId)),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _delete(MemoryFileSummary f) async {
    final l = context.l10n;
    final ok = await showAetherConfirmDialog(
      context,
      title: l.memoryDeleteTitle,
      message: l.memoryDeleteBody(f.name),
      confirmLabel: l.memoryDeleteConfirm,
      cancelLabel: l.actionCancel,
    );
    if (!ok || !mounted) return;
    try {
      await AccountSettingsClient.I.deleteMemory(_sessionId!, f.name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.memoryDeleted(f.name))),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_memoryError(l, e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: Text(l.memoryTitle)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Text(_sessionId == null ? l.memoryNeedChat : _shared ? l.memoryScopeShared : l.memoryScopeChat, style: AetherType.bodyMuted),
            const SizedBox(height: 16),
            if (_error != null)
              AetherCard(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_error!, style: AetherType.bodyMuted),
                    const SizedBox(height: 8),
                    AetherSecondaryButton(
                      label: l.actionRetry,
                      onPressed: _load,
                    ),
                  ],
                ),
              )
            else if (_loading && _files.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
              )
            else if (_files.isEmpty)
              AetherCard(
                key: const ValueKey('memory-empty'),
                padding: const EdgeInsets.all(18),
                child: Text(l.memoryEmpty, style: AetherType.bodyMuted),
              )
            else
              AetherCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final f in _files)
                      ListTile(
                        key: ValueKey('memory-${f.name}'),
                        leading: Icon(
                          Icons.description_outlined,
                          color: Aether.textMuted,
                        ),
                        title: Text(f.name),
                        subtitle: Text(l.memorySize(f.sizeBytes)),
                        onTap: () => _open(f.name),
                        trailing: IconButton(
                          tooltip: l.memoryDeleteConfirm,
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(f),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('memory-new'),
              onPressed: _error != null || _sessionId == null ? null : () => _open(null),
              icon: const Icon(Icons.add, size: 18),
              label: Text(l.memoryNew),
            ),
          ],
        ),
      ),
    );
  }
}

/// View/edit one memory file, or create a new one ([name] null). Pops true
/// when something was saved.
class MemoryEditorScreen extends StatefulWidget {
  const MemoryEditorScreen({super.key, this.name, required this.sessionId});
  final String? name;
  final String sessionId;

  @override
  State<MemoryEditorScreen> createState() => _MemoryEditorScreenState();
}

class _MemoryEditorScreenState extends State<MemoryEditorScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _content = TextEditingController();
  String? _revision;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  bool get _isNew => widget.name == null;

  @override
  void initState() {
    super.initState();
    if (!_isNew) {
      _name.text = widget.name!;
      _load();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final f = await AccountSettingsClient.I.readMemory(widget.sessionId, widget.name!);
      if (!mounted) return;
      setState(() {
        _content.text = f.content;
        _revision = f.revision;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _memoryError(context.l10n, e);
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final l = context.l10n;
    var name = _name.text.trim();
    if (_isNew && !name.toLowerCase().endsWith('.md')) name = '$name.md';
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await AccountSettingsClient.I.writeMemory(
        widget.sessionId,
        name,
        _content.text,
        ifRevision: _isNew ? null : _revision,
      );
      if (!mounted) return;
      _revision = saved.revision;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.memorySaved)));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = _memoryError(l, e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const CloseButton(),
        title: Text(_isNew ? l.memoryNew : widget.name!),
        actions: [
          TextButton(
            key: const ValueKey('memory-save'),
            onPressed: (_saving || _loading || (!_isNew && _revision == null)) ? null : _save,
            child: Text(l.memorySave),
          ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_isNew)
                TextFormField(
                  key: const ValueKey('memory-name'),
                  controller: _name,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: l.memoryNameLabel,
                    helperText: l.memoryNameHelper,
                  ),
                  validator: (v) {
                    var n = (v ?? '').trim();
                    if (n.isEmpty) return l.memoryNameInvalid;
                    if (!n.toLowerCase().endsWith('.md')) n = '$n.md';
                    return isValidMemoryName(n) ? null : l.memoryNameInvalid;
                  },
                ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(color: Aether.dangerC, fontSize: 13),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (_loading)
                const Center(child: CircularProgressIndicator(strokeWidth: 1.6))
              else
                TextFormField(
                  key: const ValueKey('memory-content'),
                  controller: _content,
                  minLines: 12,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    labelText: l.memoryContentLabel,
                    alignLabelWithHint: true,
                    border: const OutlineInputBorder(),
                  ),
                  validator: (v) => (v ?? '').length > 32 * 1024
                      ? l.memoryTooLong
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
