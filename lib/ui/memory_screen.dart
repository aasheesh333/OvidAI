import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/memory_store.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Plain-text Markdown memory editor, rebuilt on the Aether primitives.
///
/// Memory content is treated as untrusted plain text: nothing here renders
/// Markdown as HTML or executes any uploaded script. Imports create a new file
/// under a name the user confirms rather than overwriting an existing one. The
/// underlying [MemoryStore] enforces the per-file 32 KiB and per-scope 32-file
/// caps no matter what the UI attempts.
///
/// The legacy widget keys and visible labels (`memory-content`, `Save`,
/// `Add file`, `Add`, `Import .md`, `memory-filename`, `Cancel`) are preserved
/// so `test/memory_screen_test.dart` keeps asserting the same real behavior.
///
/// Note on pinning/deletion/export: the [MemoryStore] has no pin, per-file
/// delete, or export API. The pin glyph reflects the one fact the store does
/// model — `MEMORY.md` is the fixed, always-present entrypoint of a scope — and
/// the overflow Delete stays disabled for that entrypoint rather than pretending
/// a removal happened. These gaps are called out in the wave report.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});
  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  final _content = TextEditingController();
  MemoryStore? _store;
  String? _sessionId;
  String? _owner;
  String _file = 'MEMORY.md';
  String _revision = '';
  String _loaded = '';
  String? _error;
  List<String> _files = ['MEMORY.md'];
  bool _busy = false;

  bool get _dirty => _content.text != _loaded;
  bool get _enabled => _store != null && !_busy;
  String get _scopeCaption => _owner == null ? 'Global memory' : 'Session memory';

  @override
  void initState() {
    super.initState();
    _sessionId = AppState.I.activeSessionId;
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() => _error = null);
    try {
      final store = await AppState.I.prepareMemory();
      if (!mounted) return;
      _store = store;
      _load();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _checkOwner() {
    if (_owner != null && AppState.I.memoryOwner(_sessionId!) != _owner) {
      throw StateError('The owning chat was deleted or changed.');
    }
  }

  void _load() {
    try {
      _checkOwner();
      final doc = _store!.read(_owner, _file);
      _files = _store!.list(_owner);
      _revision = doc.revision;
      _loaded = doc.content;
      _content.text = doc.content;
      setState(() => _error = null);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<bool> _discard() async =>
      !_dirty ||
      await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Discard unsaved changes?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Keep editing'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Discard'),
                ),
              ],
            ),
          ) ==
          true;

  void _save() {
    try {
      _checkOwner();
      final doc = _store!.save(
        _owner,
        _file,
        _content.text,
        mode: 'replace',
        revision: _revision,
      );
      _revision = doc.revision;
      _loaded = doc.content;
      AppState.I.refresh();
      setState(() => _error = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Memory saved')));
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _add({
    String content = '',
    String suggested = 'notes.md',
  }) async {
    if (!await _discard() || !mounted) return;
    final added = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _MemoryFileSheet(
        suggested: suggested,
        create: (name) {
          _checkOwner();
          _store!.save(_owner, name, content, mode: 'create');
        },
      ),
    );
    if (!mounted) return;
    if (added != null) {
      _file = added;
      _load();
      AppState.I.refresh();
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['md'],
        allowMultiple: false,
        withData: false,
      );
      if (picked == null || !mounted) return;
      final file = picked.files.single;
      MemoryStore.validateName(file.name);
      if (file.size > MemoryStore.maxFileBytes) {
        throw const FormatException('Memory file exceeds 32 KiB.');
      }
      List<int> bytes;
      if (file.path != null) {
        final handle = File(file.path!).openSync();
        try {
          bytes = handle.readSync(MemoryStore.maxFileBytes + 1);
        } finally {
          handle.closeSync();
        }
      } else if (file.bytes != null) {
        bytes = file.bytes!;
      } else {
        throw const FormatException('Could not read selected file.');
      }
      if (bytes.length > MemoryStore.maxFileBytes) {
        throw const FormatException('Memory file exceeds 32 KiB.');
      }
      final text = utf8.decode(bytes);
      MemoryStore.validateContent(text);
      // Reading is complete; the confirm sheet now waits on the user, not I/O,
      // so the indeterminate "Importing memory" bar must stop before it opens.
      if (mounted) setState(() => _busy = false);
      await _add(
        content: text,
        suggested: file.name == 'MEMORY.md' ? 'imported-memory.md' : file.name,
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Future<void> _selectFile(String name) async {
    if (name == _file) return;
    if (!await _discard() || !mounted) return;
    _file = name;
    _load();
  }

  Future<void> _switchScope(String value) async {
    if (!await _discard() || !mounted) return;
    try {
      _owner = value == 'session'
          ? AppState.I.memoryOwner(_sessionId!)
          : null;
      _file = 'MEMORY.md';
      _load();
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _reload() async {
    if (await _discard() && mounted) _load();
  }

  void _notifyDeleteUnsupported(String name) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Delete not supported'),
        content: Text(
          'Removing "$name" is not supported by the memory store. Clear its '
          'contents and save to leave the file empty, or ask an operator to '
          'remove the file off-device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scopeValue = _owner == null ? 'global' : 'session';
    final showSessionOption = _sessionId != null;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop && await _discard() && mounted) {
          setState(() => _loaded = _content.text);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop();
          });
        }
      },
      child: Scaffold(
        backgroundColor: Aether.bg,
        appBar: AppBar(title: const Text('Memories')),
        body: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(
            AetherSpacing.space4,
            AetherSpacing.space4,
            AetherSpacing.space4,
            AetherSpacing.space4,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
            const AetherSectionTitle(
              eyebrow: 'Memories',
              subtitle:
                  'Global memory is shared across your chats. Session memory '
                  'belongs to this chat and its child agents. 32 files per '
                  'scope · 32 KiB per file.',
            ),
            const SizedBox(height: AetherSpacing.space4),
            if (showSessionOption) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Global'),
                      avatar: const Icon(Icons.public, size: 16),
                      selected: scopeValue == 'global',
                      onSelected: _enabled ? (_) => _switchScope('global') : null,
                    ),
                    ChoiceChip(
                      label: const Text('Session'),
                      avatar: const Icon(Icons.chat_bubble_outline, size: 16),
                      selected: scopeValue == 'session',
                      onSelected: _enabled ? (_) => _switchScope('session') : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AetherSpacing.space4),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AetherSpacing.space3),
                child: Text(_error!, style: TextStyle(color: Aether.dangerC)),
              ),
            if (_store == null && _error == null)
              const Padding(
                padding: EdgeInsets.only(bottom: AetherSpacing.space3),
                child: LinearProgressIndicator(),
              ),
            if (_store == null && _error != null)
              AetherSecondaryButton(label: 'Retry', onPressed: _initialize),
            if (_busy)
              const LinearProgressIndicator(semanticsLabel: 'Importing memory'),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: AetherSpacing.space2,
                runSpacing: AetherSpacing.space2,
                children: [
                  AetherSecondaryButton(
                    label: 'Add file',
                    icon: Icons.note_add_outlined,
                    onPressed: _enabled ? () => _add() : null,
                  ),
                  AetherSecondaryButton(
                    label: 'Import .md',
                    icon: Icons.file_upload_outlined,
                    onPressed: _enabled ? _import : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AetherSpacing.space3),
            _buildFileList(),
            if (_files.isNotEmpty) ...[
              const SizedBox(height: AetherSpacing.space4),
              _buildEditorCard(),
            ],
            ],
          ),
        ),
        bottomNavigationBar: _files.isEmpty
            ? null
            : SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    AetherSpacing.space4,
                    AetherSpacing.space2,
                    AetherSpacing.space4,
                    AetherSpacing.space3 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                   child: Wrap(
                     spacing: AetherSpacing.space2,
                     runSpacing: AetherSpacing.space2,
                     children: [
                      AetherPrimaryButton(
                        label: 'Save',
                        icon: Icons.check,
                        onPressed: _enabled ? _save : null,
                      ),
                      AetherGhostButton(
                        label: 'Reload',
                        onPressed: _enabled ? _reload : null,
                      ),
                      AetherPrimaryButton(
                        label: 'Add memory',
                        icon: Icons.add,
                        onPressed: _enabled ? () => _add() : null,
                      ),
                    ],
                  ),
                ),
              ),
        floatingActionButton: _files.isEmpty
            ? AetherPrimaryButton(
                label: 'Add memory',
                icon: Icons.add,
                onPressed: _enabled ? () => _add() : null,
              )
            : null,
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      ),
    );
  }

  Widget _buildFileList() {
    if (_files.isEmpty) {
      return AetherEmptyState(
        icon: Icons.note_alt_outlined,
        title: 'No memories yet',
        message: 'Add a Markdown note to seed your personal memory.',
        action: AetherPrimaryButton(
          label: 'Add memory',
          icon: Icons.add,
          onPressed: _enabled ? () => _add() : null,
        ),
      );
    }
    final rows = <Widget>[];
    for (var i = 0; i < _files.length; i++) {
      if (i > 0) {
        rows.add(const SizedBox(height: AetherSpacing.space2));
      }
      final name = _files[i];
      final isEntry = name == 'MEMORY.md';
      rows.add(
        _MemoryFileRow(
          name: name,
          selected: name == _file,
          pinned: isEntry,
          sourceCaption: _scopeCaption,
          onTap: _enabled ? () => _selectFile(name) : null,
          onEdit: _enabled ? () => _selectFile(name) : null,
          onDelete: isEntry || !_enabled
              ? null
              : () => _notifyDeleteUnsupported(name),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }

  Widget _buildEditorCard() {
    // Let the filename and editor grow with text scale inside the page scroll.
    return Container(
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(AetherRadius.rLg),
        border: Border.all(color: Aether.hairline),
        boxShadow: AetherShadows.shadowS,
      ),
      padding: const EdgeInsets.all(AetherSpacing.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(
                Icons.description_outlined,
                size: 16,
                color: Aether.textMuted,
              ),
              Text(_file, style: AetherType.title),
              AetherPill(
                label: _owner == null ? 'global' : 'session',
                color: Aether.textMuted,
                filled: false,
              ),
            ],
          ),
          const SizedBox(height: AetherSpacing.space3),
          Divider(height: 1, thickness: 1, color: Aether.hairline),
          const SizedBox(height: AetherSpacing.space3),
          TextField(
              key: const Key('memory-content'),
              controller: _content,
              enabled: _enabled,
              minLines: 6,
              maxLines: 12,
              textAlignVertical: TextAlignVertical.top,
              onChanged: (_) => setState(() {}),
              style: AetherType.body.copyWith(fontFamily: 'JetBrainsMono'),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintText: 'Markdown memory',
                hintStyle: TextStyle(color: Aether.textFaint, fontSize: 14),
              ),
          ),
        ],
      ),
    );
  }
}

/// One memory file rendered as an [AetherCard] list item.
///
/// Anatomy: `[pin glyph]  filename  /  source caption` with an overflow menu
/// offering Edit (selects the file into the editor) and Delete (disabled for
/// the pinned entrypoint and for anything the store cannot delete).
class _MemoryFileRow extends StatelessWidget {
  final String name;
  final bool selected;
  final bool pinned;
  final String sourceCaption;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  const _MemoryFileRow({
    required this.name,
    required this.selected,
    required this.pinned,
    required this.sourceCaption,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AetherSpacing.space4,
        vertical: AetherSpacing.space3,
      ),
      color: selected ? Aether.surfaceRaised : Aether.surface,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AetherRadius.rMd),
        child: Row(
          children: [
            Tooltip(
              message: pinned
                  ? 'MEMORY.md is the pinned entry point for this scope'
                  : 'Pinning additional files is not supported yet',
              child: Icon(
                pinned ? Icons.push_pin : Icons.push_pin_outlined,
                size: 16,
                color: pinned ? Aether.accentC : Aether.textFaint,
              ),
            ),
            const SizedBox(width: AetherSpacing.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: AetherType.body.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sourceCaption,
                    style: AetherType.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AetherSpacing.space2),
            PopupMenuButton<String>(
              tooltip: 'More actions',
              icon: Icon(Icons.more_vert, size: 18, color: Aether.textMuted),
              onSelected: (value) => switch (value) {
                'edit' => onEdit?.call(),
                'delete' => onDelete?.call(),
                _ => null,
              },
              itemBuilder: (context) => [
                PopupMenuItem<String>(
                  value: 'edit',
                  enabled: onEdit != null,
                  child: const Text('Edit'),
                ),
                PopupMenuItem<String>(
                  value: 'delete',
                  enabled: onDelete != null,
                  child: Text(
                    'Delete',
                    style: TextStyle(
                      color: onDelete == null
                          ? Aether.textFaint
                          : Aether.dangerC,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// AetherSheet asking for the new memory filename.
class _MemoryFileSheet extends StatefulWidget {
  final String suggested;
  final void Function(String name) create;
  const _MemoryFileSheet({required this.suggested, required this.create});
  @override
  State<_MemoryFileSheet> createState() => _MemoryFileSheetState();
}

class _MemoryFileSheetState extends State<_MemoryFileSheet> {
  late final _name = TextEditingController(text: widget.suggested);
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: AetherSheet(
      title: 'Add memory file',
      actions: [
        AetherGhostButton(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context),
        ),
        AetherPrimaryButton(
          label: 'Add',
          onPressed: () {
            try {
              widget.create(_name.text);
              Navigator.pop(context, _name.text);
            } catch (e) {
              setState(() => _error = '$e');
            }
          },
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Filename', style: AetherType.label),
          const SizedBox(height: 6),
          TextField(
            key: const Key('memory-filename'),
            controller: _name,
            autofocus: true,
            style: AetherType.body,
            decoration: InputDecoration(
              filled: true,
              fillColor: Aether.surfaceAlt,
              hintText: 'notes.md',
              hintStyle: TextStyle(color: Aether.textFaint, fontSize: 14),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 12,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AetherRadius.rMd),
                borderSide: BorderSide(
                  color: _error != null ? Aether.danger : Aether.hairline,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AetherRadius.rMd),
                borderSide: BorderSide(
                  color: _error != null ? Aether.danger : Aether.accent,
                  width: 1.2,
                ),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AetherRadius.rMd),
                borderSide: BorderSide(
                  color: _error != null ? Aether.danger : Aether.hairline,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(fontSize: 12, color: Aether.dangerC),
            )
          else
            Text(
              'Plain .md name; MEMORY.md is the fixed entrypoint.',
              style: AetherType.caption,
            ),
        ],
      ),
        ),
      ),
    );
  }
}
