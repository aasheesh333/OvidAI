import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/memory_store.dart';
import '../core/state.dart';

/// Plain-text Markdown editor. Uploaded content is never executed or rendered
/// as HTML, and imports always create a new file rather than overwrite edits.
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

  @override
  void initState() {
    super.initState();
    _sessionId = AppState.I.activeSessionId;
    _initialize();
  }

  Future<void> _initialize() async {
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
    final added = await showDialog<String>(
      context: context,
      builder: (context) => _MemoryFileDialog(
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
      await _add(
        content: text,
        suggested: file.name == 'MEMORY.md' ? 'imported-memory.md' : file.name,
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
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
      appBar: AppBar(title: const Text('Memory files')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Global memory is shared across your chats. Session memory belongs to this chat and its child agents. 32 files per scope · 32 KiB per file.',
            ),
            DropdownButton<String>(
              value: _owner == null ? 'global' : 'session',
              items: [
                const DropdownMenuItem(
                  value: 'global',
                  child: Text('Global personal memory'),
                ),
                if (_sessionId != null)
                  const DropdownMenuItem(
                    value: 'session',
                    child: Text('Current chat memory'),
                  ),
              ],
              onChanged: _store == null || _busy
                  ? null
                  : (value) async {
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
                    },
            ),
            DropdownButton<String>(
              value: _file,
              isExpanded: true,
              items: _files
                  .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                  .toList(),
              onChanged: _store == null || _busy
                  ? null
                  : (value) async {
                      if (value == null || !await _discard() || !mounted) {
                        return;
                      }
                      _file = value;
                      _load();
                    },
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _store == null || _busy ? null : () => _add(),
                  child: const Text('Add file'),
                ),
                TextButton(
                  onPressed: _store == null || _busy ? null : _import,
                  child: const Text('Import .md'),
                ),
                TextButton(
                  onPressed: _store == null || _busy
                      ? null
                      : () async {
                          if (await _discard() && mounted) _load();
                        },
                  child: const Text('Reload'),
                ),
                FilledButton(
                  onPressed: _store == null || _busy ? null : _save,
                  child: const Text('Save'),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_store == null && _error == null)
              const LinearProgressIndicator(),
            Expanded(
              child: TextField(
                key: const Key('memory-content'),
                controller: _content,
                enabled: _store != null && !_busy,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Markdown memory',
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MemoryFileDialog extends StatefulWidget {
  final String suggested;
  final void Function(String name) create;
  const _MemoryFileDialog({required this.suggested, required this.create});
  @override
  State<_MemoryFileDialog> createState() => _MemoryFileDialogState();
}

class _MemoryFileDialogState extends State<_MemoryFileDialog> {
  late final _name = TextEditingController(text: widget.suggested);
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add memory file'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('memory-filename'),
          controller: _name,
          decoration: const InputDecoration(labelText: 'Filename (.md)'),
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        onPressed: () {
          try {
            widget.create(_name.text);
            Navigator.pop(context, _name.text);
          } catch (e) {
            setState(() => _error = '$e');
          }
        },
        child: const Text('Add'),
      ),
    ],
  );
}
