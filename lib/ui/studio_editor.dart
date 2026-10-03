import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core/agent_service.dart';
import '../core/repo_cache.dart';
import '../core/sandbox_service.dart';
import '../core/state.dart';
import '../core/workspace_files.dart';
import '../core/theme.dart';
import 'studio_layout.dart';
import 'studio_errors.dart';

// ── Studio editor ───────────────────────────────────────────────────────────
// Extracted from studio_screen.dart and fixed (2026-09-30 audit):
//  * `autocorrect` / `enableSuggestions` were left ON for a CODE editor, so the
//    soft keyboard rewrote identifiers as you typed. Both are off, smart
//    quotes/dashes are disabled, and the field asks for a newline action.
//  * `_bind` dumped the caret at end of file on every fresh open and mutated
//    the controller from inside `build`. Binding now happens in a listener,
//    a fresh open starts at offset 0, and a background rewrite (agent
//    file_write) keeps the user's caret instead of moving it.
//  * There was no find, no position readout and no undo. All three exist now.

/// Stable key for the code field (tests and the find bar both target it).
const Key studioEditorFieldKey = Key('studio-editor-field');

/// Key for the in-file find field.
const Key studioFindFieldKey = Key('studio-find-field');

/// Editor monospace size. The screen shipped 12.5px here and 9.5–10.5px in the
/// surrounding chrome; everything is now at or above [kStudioMinFontSize].
const double kStudioEditorFontSize = 13;

/// Line height multiplier for the code field.
const double kStudioEditorLineHeight = 1.55;

/// Height of the accent bar drawn over the selected tab. Added to the strip
/// height so the 44dp tap target survives it.
const double kStudioTabAccent = 2;

/// The open-file tab strip.
class StudioEditorTabs extends StatelessWidget {
  const StudioEditorTabs({super.key});

  Future<void> _askNewFile(BuildContext context) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('New file', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          // It is a path in a code repository — no autocorrect, no suggestions.
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          style: const TextStyle(fontFamily: Aether.mono, fontFamilyFallback: kStudioMonoFallback, fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'path/to/file.dart',
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.pop(d, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, ctrl.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (ok == null || ok.isEmpty) return;
    AgentService.I.newStudioFile(ok);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (context, _) {
        final tabs = AgentService.I.studioOpenFiles;
        final active = AgentService.I.activeFilePath;
        // A horizontal ListView needs a bounded cross axis, and the strip has
        // to grow with the OS text scale rather than clip it — hence a computed
        // height instead of the old fixed 38px. The selected tab's 2px accent
        // border is added on top so it cannot eat into the 44dp target.
        final scale = MediaQuery.textScalerOf(context).scale(1.0);
        return Material(
          type: MaterialType.canvas,
          color: Aether.surface,
          child: SizedBox(
            height: math.max(kStudioTapTarget, kStudioTapTarget * scale) +
                kStudioTabAccent,
            child: Row(
              children: [
                Expanded(
                  child: tabs.isEmpty
                      ? const _NoTabsHint()
                      : ListView(
                          scrollDirection: Axis.horizontal,
                          padding: EdgeInsets.zero,
                          children: [
                            for (final p in tabs) _tab(p, p == active),
                          ],
                        ),
                ),
                StudioIconButton(
                  icon: Icons.add,
                  tooltip: 'New file',
                  iconSize: 18,
                  onPressed: () => _askNewFile(context),
                ),
                const SizedBox(width: 2),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _tab(String path, bool selected) {
    final name = path.split('/').last;
    return StudioTapTarget(
      onTap: () => AgentService.I.selectStudioFile(path),
      label: '$name, tab${selected ? ', active' : ''}',
      selected: selected,
      minWidth: 0,
      child: Container(
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(
          color: selected ? Aether.bg : Colors.transparent,
          border: Border(
            right: BorderSide(color: Aether.hairline),
            top: BorderSide(
              color: selected ? Aether.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 14,
              color: selected ? Aether.text : Aether.textFaint,
            ),
            const SizedBox(width: 6),
            Text(
              name,
              style: TextStyle(
                fontSize: 12,
                fontFamily: Aether.mono,
                fontFamilyFallback: kStudioMonoFallback,
                color: selected ? Aether.text : Aether.textMuted,
              ),
            ),
            StudioIconButton(
              icon: Icons.close,
              tooltip: 'Close tab $name',
              iconSize: 14,
              onPressed: () => AgentService.I.closeStudioFile(path),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoTabsHint extends StatelessWidget {
  const _NoTabsHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'No open files — tap a file in the tree or +',
          style: TextStyle(fontSize: 12, color: Aether.textFaint),
        ),
      ),
    );
  }
}

/// The active file's editor: path header, find bar, and the code field.
class StudioEditor extends StatefulWidget {
  const StudioEditor({super.key});

  @override
  State<StudioEditor> createState() => _StudioEditorState();
}

class _EditorPosition {
  const _EditorPosition(this.line, this.column, this.lines);
  final int line;
  final int column;
  final int lines;
}

typedef _BufferKey = (Map<String, String>, String);

class _StudioEditorState extends State<StudioEditor> {
  /// One controller per open file, so a tab switch preserves that file's text,
  /// caret and scroll position instead of re-deriving them from the buffer.
  final Map<_BufferKey, TextEditingController> _buffers = {};
  final Map<_BufferKey, String> _baselines = {};
  final Map<_BufferKey, String?> _cacheContents = {};
  final Map<_BufferKey, String> _conflicts = {};
  final Set<_BufferKey> _dirtyBuffers = {};
  final Map<_BufferKey, int> _edits = {};
  final Map<_BufferKey, UndoHistoryController> _undoControllers = {};
  final Map<_BufferKey, VoidCallback> _bufferListeners = {};
  _BufferKey? _boundKey;
  final TextEditingController _findCtrl = TextEditingController();
  UndoHistoryController get _undoCtrl => _undoControllers[_boundKey]!;

  String? _boundPath;
  bool get _dirty => _dirtyBuffers.contains(_boundKey);
  bool _applyingExternal = false;
  bool _initializing = true;

  bool _findOpen = false;
  List<TextRange> _matches = const [];
  int _matchIndex = 0;
  String _lastQuery = '';

  TextEditingController? get _ctrl => _buffers[_boundKey];

  @override
  void initState() {
    super.initState();
    AgentService.I.addListener(_onServiceChanged);
    RepoCache.I.addListener(_onServiceChanged);
    AppState.I.addListener(_onServiceChanged);
    _findCtrl.addListener(_onQueryChanged);
    _bind(notify: false);
    _initializing = false;
  }

  @override
  void dispose() {
    AgentService.I.removeListener(_onServiceChanged);
    RepoCache.I.removeListener(_onServiceChanged);
    AppState.I.removeListener(_onServiceChanged);
    _findCtrl.removeListener(_onQueryChanged);
    for (final entry in _buffers.entries) {
      entry.value
        ..removeListener(_bufferListeners[entry.key]!)
        ..dispose();
    }
    for (final undo in _undoControllers.values) {
      undo..removeListener(_onUndoChanged)..dispose();
    }
    _findCtrl.dispose();
    super.dispose();
  }

  /// `setState` that survives being called from a notifier that fires during
  /// the build/layout phase (UndoHistory reports its state from there).
  void _refresh() {
    if (!mounted || _initializing) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  void _onServiceChanged() {
    if (!mounted) return;
    _bind(notify: true);
  }

  void _onUndoChanged() => _refresh();

  void _onControllerChanged(_BufferKey key) {
    final ctrl = _buffers[key];
    if (ctrl != null && !_applyingExternal) {
      if (key.$1[key.$2] != ctrl.text && !_conflicts.containsKey(key)) {
        key.$1[key.$2] = ctrl.text;
        _dirtyBuffers.add(key);
        _edits[key] = (_edits[key] ?? 0) + 1;
      } else if (_conflicts.containsKey(key)) {
        _dirtyBuffers.add(key);
        _edits[key] = (_edits[key] ?? 0) + 1;
      }
    }
    if (_findOpen) _recomputeMatches();
    _refresh();
  }

  /// Re-points the editor at [AgentService.activeFilePath].
  ///
  /// Never called from `build` — that was the source of the "controller mutated
  /// during build" and "caret dumped at EOF" pair of bugs.
  void _bind({required bool notify}) {
    final a = AgentService.I;
    final path = a.activeFilePath;

    if (path == null) {
      _boundPath = null;
      _boundKey = null;
      if (notify) _refresh();
      return;
    }

    var content = a.fileBuffer[path] ?? RepoCache.I.read(path) ?? '';
    final key = (a.fileBuffer, path);
    final switched = _boundKey != key;
    _boundPath = path;
    _boundKey = key;

    final ctrl = _bufferFor(key, content);
    final cache = RepoCache.I;
    final session = AppState.I.activeSession;
    if (cache.boundSessionId == session?.id &&
        cache.workspaceFolder == session?.workspaceFolder &&
        (session?.repo == null || cache.repoFull == session?.repo) &&
        (session?.branch == null || cache.defaultBranch == session?.branch)) {
      final cached = cache.files[path];
      if (cached != _cacheContents[key]) {
        _cacheContents[key] = cached;
        if (cached != null && cached != ctrl.text) {
          content = cached;
          if (!_dirtyBuffers.contains(key)) key.$1[path] = cached;
        }
      }
    }
    if (switched) {
      // A freshly opened file starts at the TOP. Caret-at-EOF made every open
      // look like the file had been scrolled to the end by someone else.
      _matchIndex = 0;
    }
    if (ctrl.text != content && _dirtyBuffers.contains(key)) {
      // A reopen at the known baseline is not a new external edit.
      if (content != _baselines[key] && _conflicts[key] != content) {
        _conflicts[key] = content;
        _edits[key] = (_edits[key] ?? 0) + 1;
      }
      key.$1[path] = ctrl.text;
    } else if (ctrl.text != content) {
      // Something else rewrote the bound file (agent file_write, live reload).
      // Keep the caret where the user put it, clamped into the new range.
      final previous = ctrl.selection.isValid ? ctrl.selection.start : 0;
      _applyText(ctrl, content, math.min(previous, content.length));
      _edits[key] = (_edits[key] ?? 0) + 1;
      _baselines[key] = content;
    }
    _recomputeMatches();
    if (notify) _refresh();
  }

  TextEditingController _bufferFor(_BufferKey key, String content) {
    final existing = _buffers[key];
    if (existing != null) return existing;
    final ctrl = TextEditingController(text: content);
    // An invalid selection (-1) makes EditableText park the caret at EOF once
    // the field gains focus — set a real offset before it is ever attached.
    ctrl.selection = const TextSelection.collapsed(offset: 0);
    void listener() => _onControllerChanged(key);
    ctrl.addListener(listener);
    _bufferListeners[key] = listener;
    _undoControllers[key] = UndoHistoryController()..addListener(_onUndoChanged);
    _buffers[key] = ctrl;
    _baselines[key] = content;
    _cacheContents[key] = RepoCache.I.files[key.$2];
    return ctrl;
  }

  void _applyText(TextEditingController ctrl, String text, int caret) {
    _applyingExternal = true;
    try {
      ctrl.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(
          offset: caret.clamp(0, text.length),
        ),
      );
    } finally {
      _applyingExternal = false;
    }
  }

  // ── find ────────────────────────────────────────────────────────────────
  void _onQueryChanged() {
    if (_lastQuery == _findCtrl.text) return;
    _lastQuery = _findCtrl.text;
    _matchIndex = 0;
    _recomputeMatches();
    if (_matches.isNotEmpty) _selectMatch(_matchIndex);
    _refresh();
  }

  void _recomputeMatches() {
    final query = _findCtrl.text;
    final ctrl = _ctrl;
    if (!_findOpen || query.isEmpty || ctrl == null) {
      _matches = const [];
      _matchIndex = 0;
      return;
    }
    _matches = _findAll(ctrl.text, query);
    if (_matchIndex >= _matches.length) _matchIndex = 0;
  }

  void _selectMatch(int index) {
    final ctrl = _ctrl;
    if (ctrl == null || _matches.isEmpty) return;
    final range = _matches[index % _matches.length];
    // EditableText scrolls the new selection into view on Android/iOS, so
    // "next match" also moves the viewport.
    ctrl.selection = TextSelection(
      baseOffset: range.start,
      extentOffset: range.end,
    );
  }

  void _nextMatch() {
    if (_matches.isEmpty) return;
    _matchIndex = (_matchIndex + 1) % _matches.length;
    _selectMatch(_matchIndex);
    _refresh();
  }

  void _previousMatch() {
    if (_matches.isEmpty) return;
    _matchIndex = (_matchIndex - 1 + _matches.length) % _matches.length;
    _selectMatch(_matchIndex);
    _refresh();
  }

  void _openFind() {
    if (_findOpen) return;
    setState(() {
      _findOpen = true;
      // Seed the query with the current selection — the usual "find this".
      final sel = _ctrl?.selection;
      if (sel != null && sel.isValid && !sel.isCollapsed) {
        _findCtrl.text = _ctrl!.text.substring(sel.start, sel.end);
      }
      _recomputeMatches();
    });
  }

  void _closeFind() {
    if (!_findOpen) return;
    setState(() {
      _findOpen = false;
      _matches = const [];
      _matchIndex = 0;
      final ctrl = _ctrl;
      if (ctrl != null && ctrl.selection.isValid) {
        _applyText(
          ctrl,
          ctrl.text,
          ctrl.selection.start,
        );
      }
    });
  }

  // ── save / undo ─────────────────────────────────────────────────────────
  Future<void> _save() async {
    final path = _boundPath;
    final key = _boundKey;
    final ctrl = _ctrl;
    if (path == null || ctrl == null || key == null || _conflicts.containsKey(key)) return;
    final text = ctrl.text;
    final edit = _edits[key];
    final binding = RepoCache.I.bindingGeneration;
    try {
      // Freeze ownership before resolving the root. Disk write and publication
      // then share one turn; an obsolete resolver cannot target another owner.
      final session = AppState.I.activeSession;
      if (session == null || !identical(key.$1, AgentService.I.fileBuffer)) return;
      final pinned = session.workspaceFolder;
      final root = pinned != null && Directory(pinned).existsSync()
          ? Directory(pinned)
          : await SandboxService.I.workDirFor(session.sandboxId ?? session.id);
      if (!mounted || binding != RepoCache.I.bindingGeneration ||
          key != _boundKey || edit != _edits[key] ||
          _conflicts.containsKey(key) || ctrl.text != text ||
          !identical(key.$1, AgentService.I.fileBuffer)) {
        return;
      }
      final safe = workspaceFilePath(root, path);
      if (safe == null) throw StateError('Path escapes workspace or uses a symlink: $path');
      final file = File(safe);
      file.parent.createSync(recursive: true);
      if (workspaceFilePath(root, path) != safe) throw StateError('Workspace path changed while saving');
      file.writeAsStringSync(text);
      final cache = RepoCache.I;
      if (binding == cache.bindingGeneration &&
          (cache.boundSessionId == null || cache.boundSessionId == session.id) &&
          (session.repo == null || cache.repoFull == session.repo) &&
          (session.branch == null || cache.defaultBranch == session.branch) &&
          (cache.workspaceFolder == null || cache.workspaceFolder == session.workspaceFolder) &&
          (cache.repoFull != null || cache.files.containsKey(path))) {
        cache.write(path, text);
        cache.didSaveWorkspaceFile(path, text);
      }
      key.$1[path] = text;
    } catch (error) {
      if (mounted) {
        showStudioToast(context, StudioFailure.of(error).message, error: true);
      }
      return;
    }
    if (!mounted) return;
    if (binding != RepoCache.I.bindingGeneration || key != _boundKey || edit != _edits[key]) return;
    setState(() { _dirtyBuffers.remove(key); _baselines[key] = text; });
    showStudioToast(context, 'Saved ${path.split('/').last} to the workspace');
  }

  // ── layout ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AgentService.I,
      builder: (context, _) {
        final path = _boundPath;
        final ctrl = _ctrl;
        if (path == null || ctrl == null) return const _NoFileView();
        return CallbackShortcuts(
          // Escape is only bound while the find bar is open — swallowing it
          // permanently would stop it reaching dialogs and the IME.
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                _openFind,
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                _openFind,
            if (_findOpen)
              const SingleActivator(LogicalKeyboardKey.escape): _closeFind,
          },
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            child: Material(
              type: MaterialType.canvas,
              color: Aether.bg,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(path, ctrl),
                  if (_conflicts.containsKey(_boundKey)) _conflictBar(),
                  if (_findOpen) _findBar(ctrl),
                  Expanded(child: IndexedStack(
                    index: _buffers.keys.toList().indexOf(_boundKey!),
                    children: [for (final entry in _buffers.entries)
                      KeyedSubtree(key: ValueKey(entry.key),
                        child: _field(entry.key.$2, entry.value, _undoControllers[entry.key]!)),
                    ],
                  )),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _conflictBar() => MaterialBanner(
    content: const Text('This file changed externally. Your draft has been kept.'),
    actions: [
      TextButton(onPressed: () {
        final key = _boundKey!;
        _edits[key] = (_edits[key] ?? 0) + 1;
        setState(() { _baselines[key] = _conflicts.remove(key)!; });
      }, child: const Text('Keep draft')),
      TextButton(onPressed: () {
        final key = _boundKey!;
        _edits[key] = (_edits[key] ?? 0) + 1;
        final text = _conflicts.remove(key)!;
        _applyText(_ctrl!, text, _ctrl!.selection.start);
        key.$1[key.$2] = text;
        setState(() { _baselines[key] = text; _dirtyBuffers.remove(key); });
      }, child: const Text('Use external')),
    ],
  );

  Widget _header(String path, TextEditingController ctrl) {
    final pos = _positionOf(ctrl);
    return Container(
      constraints: const BoxConstraints(minHeight: kStudioTapTarget),
      color: Aether.surfaceAlt,
      padding: const EdgeInsets.only(left: 10, right: 2),
      child: LayoutBuilder(
        builder: (context, c) {
          final roomy = c.maxWidth >= 520;
          return Row(
            children: [
              Semantics(
                label: _dirty ? 'Unsaved changes' : 'No unsaved changes',
                child: Icon(
                  _dirty ? Icons.circle : Icons.edit_note,
                  size: 13,
                  color: _dirty ? Aether.warnLight : Aether.accent,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Semantics(
                  header: true,
                  label: 'Editing $path',
                  child: Text(
                    path,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: Aether.mono,
                      fontFamilyFallback: kStudioMonoFallback,
                      fontSize: 12,
                      color: Aether.textMuted,
                    ),
                  ),
                ),
              ),
              if (roomy) ...[
                Semantics(
                  liveRegion: true,
                  label:
                      'Line ${pos.line}, column ${pos.column} of ${pos.lines} lines',
                  child: Text(
                    'Ln ${pos.line}, Col ${pos.column} · ${pos.lines} lines',
                    style: TextStyle(fontSize: 12, color: Aether.textFaint),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              StudioIconButton(
                icon: _findOpen ? Icons.search_off : Icons.search,
                tooltip: 'Find in file',
                iconSize: 18,
                onPressed: _findOpen ? _closeFind : _openFind,
              ),
              StudioIconButton(
                icon: Icons.undo,
                tooltip: 'Undo',
                iconSize: 18,
                onPressed: _undoCtrl.value.canUndo ? _undoCtrl.undo : null,
              ),
              StudioIconButton(
                icon: Icons.redo,
                tooltip: 'Redo',
                iconSize: 18,
                onPressed: _undoCtrl.value.canRedo ? _undoCtrl.redo : null,
              ),
              StudioIconButton(
                icon: Icons.save_outlined,
                tooltip: 'Save changes',
                iconSize: 18,
                color: _dirty ? Aether.accent : null,
                onPressed: _dirty && !_conflicts.containsKey(_boundKey) ? _save : null,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _findBar(TextEditingController ctrl) {
    final count = _matches.isEmpty
        ? 'No matches'
        : '${_matchIndex + 1} / ${_matches.length}';
    return Container(
      constraints: const BoxConstraints(minHeight: kStudioTapTarget + 4),
      padding: const EdgeInsets.only(left: 10, right: 2),
      decoration: BoxDecoration(
        color: Aether.surface,
        border: Border(bottom: BorderSide(color: Aether.hairline)),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          final roomy = c.maxWidth >= 420;
          return Row(
            children: [
              Icon(Icons.search, size: 16, color: Aether.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  key: studioFindFieldKey,
                  controller: _findCtrl,
                  autofocus: true,
                  // A search query for source code: no autocorrect, no
                  // suggestions, no smart punctuation.
                  autocorrect: false,
                  enableSuggestions: false,
                  smartQuotesType: SmartQuotesType.disabled,
                  smartDashesType: SmartDashesType.disabled,
                  textInputAction: TextInputAction.search,
                  keyboardType: TextInputType.text,
                  style: const TextStyle(
                    fontFamily: Aether.mono,
                    fontFamilyFallback: kStudioMonoFallback,
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Find in file',
                    hintStyle: TextStyle(
                      fontFamily: Aether.mono,
                      fontFamilyFallback: kStudioMonoFallback,
                      fontSize: 13,
                      color: Aether.textFaint,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                  onSubmitted: (_) => _nextMatch(),
                ),
              ),
              const SizedBox(width: 8),
              if (roomy)
                Semantics(
                  liveRegion: true,
                  label: _matches.isEmpty
                      ? 'No matches'
                      : 'Match ${_matchIndex + 1} of ${_matches.length}',
                  child: Text(
                    count,
                    style: TextStyle(fontSize: 12, color: Aether.textMuted),
                  ),
                ),
              StudioIconButton(
                icon: Icons.keyboard_arrow_up,
                tooltip: 'Previous match',
                iconSize: 20,
                onPressed: _matches.isEmpty ? null : _previousMatch,
              ),
              StudioIconButton(
                icon: Icons.keyboard_arrow_down,
                tooltip: 'Next match',
                iconSize: 20,
                onPressed: _matches.isEmpty ? null : _nextMatch,
              ),
              StudioIconButton(
                icon: Icons.close,
                tooltip: 'Close find',
                iconSize: 16,
                onPressed: _closeFind,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _field(String path, TextEditingController ctrl, UndoHistoryController undo) {
    return Semantics(
      label: 'Code editor for $path',
      textField: true,
      child: TextField(
        key: studioEditorFieldKey,
        controller: ctrl,
        undoController: undo,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        keyboardType: TextInputType.multiline,
        textInputAction: TextInputAction.newline,
        // A code editor must never be "helped" by the IME: autocorrect and
        // suggestions rewrite identifiers, and smart punctuation turns `'` and
        // `--` into characters that do not compile.
        autocorrect: false,
        enableSuggestions: false,
        smartQuotesType: SmartQuotesType.disabled,
        smartDashesType: SmartDashesType.disabled,
        enableInteractiveSelection: true,
        style: TextStyle(
          fontFamily: Aether.mono,
          fontFamilyFallback: kStudioMonoFallback,
          fontSize: kStudioEditorFontSize,
          height: kStudioEditorLineHeight,
          color: Aether.text,
        ),
        decoration: InputDecoration(
          contentPadding: const EdgeInsets.all(12),
          isDense: true,
          filled: true,
          fillColor: Aether.bg,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }

  _EditorPosition _positionOf(TextEditingController ctrl) {
    final text = ctrl.text;
    final offset = ctrl.selection.isValid
        ? ctrl.selection.start.clamp(0, text.length)
        : 0;
    final before = text.substring(0, offset);
    final lastBreak = before.lastIndexOf('\n');
    return _EditorPosition(
      '\n'.allMatches(before).length + 1,
      offset - lastBreak,
      '\n'.allMatches(text).length + 1,
    );
  }
}

/// Case-insensitive, non-overlapping match scan.
List<TextRange> _findAll(String haystack, String needle) {
  if (needle.isEmpty) return const [];
  final lowerHay = haystack.toLowerCase();
  final lowerNeedle = needle.toLowerCase();
  final out = <TextRange>[];
  var from = 0;
  while (from <= lowerHay.length) {
    final i = lowerHay.indexOf(lowerNeedle, from);
    if (i < 0) break;
    out.add(TextRange(start: i, end: i + needle.length));
    from = i + needle.length;
  }
  return out;
}

class _NoFileView extends StatelessWidget {
  const _NoFileView();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Aether.bg,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Semantics(
            label: 'No file open',
            child: Text(
              'Ovid Studio\n\n• Pick a file from the tree, or + to create one\n'
              '• Ask the AI in chat to read/edit files — they open here as tabs\n'
              '• Terminal below runs inside the native Linux sandbox',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.7,
                color: Aether.textFaint,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
