import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core/cloud/studio_remote_client.dart';
import '../core/state.dart';
import '../core/studio_drafts.dart';
import '../core/theme.dart';
import 'studio_layout.dart';
import 'studio_errors.dart';
import 'widgets/aether_primitives.dart';

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
  const StudioEditorTabs({super.key, this.sessionId});

  /// Test seam / explicit binding. Production callers pass the active server
  /// session id; null falls back to [AppState].
  final String? sessionId;

  String get _sid => sessionId ?? AppState.I.activeSession?.id ?? '';

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
    StudioRemoteClient.I.newStudioFile(_sid, ok);
  }

  @override
  Widget build(BuildContext context) {
    // Only tab-list / active-tab changes rebuild the strip, not every agent
    // notification.
    return ValueListenableBuilder<StudioTabsState>(
      valueListenable: StudioRemoteClient.I.tabsFor(_sid),
      builder: (context, studio, _) {
        final tabs = studio.openFiles;
        final active = studio.activePath;
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
                            for (final p in tabs)
                              _tab(
                                context,
                                p,
                                p == active,
                                StudioRemoteClient.I.isStudioFileDirty(_sid, p),
                              ),
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

  Widget _tab(BuildContext context, String path, bool selected, bool dirty) {
    final name = path.split('/').last;
    return StudioTapTarget(
      onTap: () => StudioRemoteClient.I.selectStudioFile(_sid, path),
      label: '$name, tab${dirty ? ', unsaved changes' : ''}'
          '${selected ? ', active' : ''}',
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
            if (dirty) ...[
              const SizedBox(width: 6),
              ExcludeSemantics(
                child: Icon(Icons.circle, size: 7, color: Aether.warnLight),
              ),
            ],
            StudioIconButton(
              icon: Icons.close,
              tooltip: 'Close tab $name',
              iconSize: 14,
              onPressed: () => closeStudioTab(context, path, sessionId: _sid),
            ),
          ],
        ),
      ),
    );
  }
}

/// Choice in the unsaved-changes dialogs.
enum StudioUnsavedChoice { save, discard, cancel }

/// Asks what to do with unsaved drafts. [paths] are the files affected.
Future<StudioUnsavedChoice> showStudioUnsavedDialog(
  BuildContext context,
  List<String> paths, {
  required String title,
  String saveLabel = 'Save',
}) async {
  final names = paths.map((p) => p.split('/').last).toList();
  final shown = names.take(3).join(', ');
  final more = names.length > 3 ? ' and ${names.length - 3} more' : '';
  final choice = await showDialog<StudioUnsavedChoice>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 15)),
      content: Text(
        paths.length == 1
            ? '$shown has changes that are not saved to the workspace.'
            : '${paths.length} files have changes that are not saved to the '
                'workspace: $shown$more.',
        style: const TextStyle(fontSize: 12.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d, StudioUnsavedChoice.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, StudioUnsavedChoice.discard),
          child: Text('Discard', style: TextStyle(color: Aether.danger)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(d, StudioUnsavedChoice.save),
          child: Text(saveLabel),
        ),
      ],
    ),
  );
  return choice ?? StudioUnsavedChoice.cancel;
}

/// Closes a tab, asking first when it holds an unsaved draft (F-071).
Future<void> closeStudioTab(BuildContext context, String path,
    {String? sessionId}) async {
  final sid = sessionId ?? AppState.I.activeSession?.id ?? '';
  final remote = StudioRemoteClient.I;
  if (!remote.isStudioFileDirty(sid, path)) {
    remote.closeStudioFile(sid, path);
    return;
  }
  final choice = await showStudioUnsavedDialog(
    context,
    [path],
    title: 'Close ${path.split('/').last}?',
  );
  switch (choice) {
    case StudioUnsavedChoice.cancel:
      return;
    case StudioUnsavedChoice.discard:
      remote.discardStudioDraft(sid, path);
      remote.closeStudioFile(sid, path);
    case StudioUnsavedChoice.save:
      final text = remote.fileBuffer(sid)[path];
      if (text == null || remote.conflicts(sid)[path] != null) {
        if (context.mounted) {
          showStudioToast(
            context,
            'Resolve the external change before saving',
            error: true,
          );
        }
        return;
      }
      try {
        await remote.saveStudioFile(sid, path);
      } catch (error) {
        if (context.mounted) {
          showStudioToast(context, StudioFailure.of(error).message, error: true);
        }
        return;
      }
      remote.closeStudioFile(sid, path);
  }
}

class _NoTabsHint extends StatelessWidget {
  const _NoTabsHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SingleChildScrollView(
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
  const StudioEditor({super.key, this.sessionId});

  /// Explicit server-session binding (tests); null falls back to [AppState].
  final String? sessionId;

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
  String get _sid => widget.sessionId ?? AppState.I.activeSession?.id ?? '';
  StudioRemoteClient get _remote => StudioRemoteClient.I;

  /// One controller per open file, so a tab switch preserves that file's text,
  /// caret and scroll position instead of re-deriving them from the buffer.
  ///
  /// Dirty flags, baselines and conflicts are NOT kept here: they live in the
  /// session's Studio bucket in the Studio client so they survive this widget
  /// (Android back, folder-panel toggle, tree taps — F-071/F-072).
  final Map<_BufferKey, TextEditingController> _buffers = {};
  final Map<_BufferKey, String?> _cacheContents = {};
  final Map<_BufferKey, String?> _seenConflicts = {};
  final Map<_BufferKey, int> _edits = {};
  final Map<_BufferKey, UndoHistoryController> _undoControllers = {};
  final Map<_BufferKey, VoidCallback> _bufferListeners = {};

  /// Large files the user chose to edit despite the size warning.
  final Set<_BufferKey> _editAnyway = {};
  _BufferKey? _boundKey;
  final TextEditingController _findCtrl = TextEditingController();
  UndoHistoryController? get _undoCtrl => _undoControllers[_boundKey];

  String? _boundPath;
  bool get _dirty {
    final key = _boundKey;
    return key != null && _remote.isStudioFileDirty(_sid, key.$2);
  }

  bool get _conflict {
    final key = _boundKey;
    return key != null && _remote.conflicts(_sid)[key.$2] != null;
  }

  bool _applyingExternal = false;
  bool _initializing = true;

  bool _findOpen = false;
  List<TextRange> _matches = const [];
  int _matchIndex = 0;
  String _lastQuery = '';

  TextEditingController? get _ctrl => _buffers[_boundKey];

  /// What [_bind] reads, as of the last bind. Notifications that change none
  /// of it (streamed tokens, tool events, unrelated refreshes) skip the bind,
  /// the find recompute and the rebuild entirely.
  List<Object?>? _bindInputs;

  List<Object?> _currentBindInputs(StudioTabsState studio) {
    final path = studio.activePath;
    return [
      studio,
      path == null ? null : _remote.fileBuffer(_sid)[path],
      _sid,
    ];
  }

  @override
  void initState() {
    super.initState();
    _remote.tabsFor(_sid).addListener(_onServiceChanged);
    AppState.I.addListener(_onServiceChanged);
    _findCtrl.addListener(_onQueryChanged);
    _bind(notify: false);
    _initializing = false;
  }

  @override
  void dispose() {
    _remote.tabsFor(_sid).removeListener(_onServiceChanged);
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
    // May publish a studioTabs change (and re-enter here) for a session
    // switch that only notified AppState; the input check below dedupes.
    final studio = _remote.tabsState(_sid);
    final inputs = _currentBindInputs(studio);
    if (_bindInputs != null && listEquals(inputs, _bindInputs)) return;
    _bind(notify: true);
  }

  void _onUndoChanged() => _refresh();

  void _onControllerChanged(_BufferKey key) {
    final ctrl = _buffers[key];
    if (ctrl != null && !_applyingExternal && key.$1[key.$2] != ctrl.text) {
      _edits[key] = (_edits[key] ?? 0) + 1;
      _remote.updateStudioDraft(_sid, key.$2, ctrl.text);
    }
    if (_findOpen) _recomputeMatches();
    _refresh();
  }

  /// True when [key] is shown as an editable text field.
  bool _editable(_BufferKey key) {
    if (_remote.guardFor(_sid, key.$2) != null) return false;
    final text = key.$1[key.$2] ?? '';
    if (looksBinaryText(text)) return false;
    return text.length <= kStudioViewerThreshold || _editAnyway.contains(key);
  }

  /// Drops controllers for files that are no longer open in the active
  /// bucket (F-077). A closed tab that still holds a draft keeps its
  /// controller so caret and undo come back with it.
  void _prune() {
    final buffer = _remote.fileBuffer(_sid);
    final open = _remote.openFiles(_sid).toSet();
    final stale = [
      for (final key in _buffers.keys)
        if (!identical(key.$1, buffer) ||
            !(open.contains(key.$2) ||
                _remote.isStudioFileDirty(_sid, key.$2)) ||
            _remote.guardFor(_sid, key.$2) != null)
          key,
    ];
    if (stale.isEmpty) return;
    final retired = <ChangeNotifier>[];
    for (final key in stale) {
      final ctrl = _buffers.remove(key)!;
      ctrl.removeListener(_bufferListeners.remove(key)!);
      final undo = _undoControllers.remove(key)!..removeListener(_onUndoChanged);
      retired..add(ctrl)..add(undo);
      _cacheContents.remove(key);
      _seenConflicts.remove(key);
      _edits.remove(key);
      _editAnyway.remove(key);
    }
    // The fields still reference these until the next build replaces them.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      for (final notifier in retired) {
        notifier.dispose();
      }
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// Re-points the editor at the active remote file.
  ///
  /// Never called from `build` — that was the source of the "controller mutated
  /// during build" and "caret dumped at EOF" pair of bugs.
  void _bind({required bool notify}) {
    final studio = _remote.tabsState(_sid);
    _bindInputs = _currentBindInputs(studio);
    final path = studio.activePath;
    _prune();

    if (path == null) {
      _boundPath = null;
      _boundKey = null;
      if (notify) _refresh();
      return;
    }

    final key = (studio.buffer, path);
    final switched = _boundKey != key;
    _boundPath = path;
    _boundKey = key;
    if (_remote.guardFor(_sid, path) != null) {
      if (notify) _refresh();
      return;
    }

    final initial = _remote.fileBuffer(_sid)[path] ?? '';
    _remote.ensureStudioBaseline(_sid, path, initial);
    final ctrl = _bufferFor(key, initial);
    final cached = _remote.fileBuffer(_sid)[path];
    if (cached != _cacheContents[key]) {
      _cacheContents[key] = cached;
      if (cached != null && cached != ctrl.text) {
        // The remote bucket changed under a clean buffer (server-side agent
        // write or a conflict resolution): adopt it. A dirty buffer keeps
        // its draft and renders the conflict bar instead.
        if (!_dirty) {
          final previous = ctrl.selection.isValid ? ctrl.selection.start : 0;
          _applyText(ctrl, cached, math.min(previous, cached.length));
          _edits[key] = (_edits[key] ?? 0) + 1;
        }
      }
    }
    final conflict = studio.conflicts[path];
    if (conflict != _seenConflicts[key]) {
      // A save admitted before this conflict must not publish.
      _seenConflicts[key] = conflict;
      _edits[key] = (_edits[key] ?? 0) + 1;
    }
    if (switched) {
      // A freshly opened file starts at the TOP. Caret-at-EOF made every open
      // look like the file had been scrolled to the end by someone else.
      _matchIndex = 0;
    }
    final content = key.$1[path] ?? '';
    if (ctrl.text != content) {
      // Something else rewrote the bound buffer (agent file_write, live
      // reload, "Use external", discard). Keep the caret where the user put
      // it, clamped into the new range.
      final previous = ctrl.selection.isValid ? ctrl.selection.start : 0;
      _applyText(ctrl, content, math.min(previous, content.length));
      _edits[key] = (_edits[key] ?? 0) + 1;
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
    _cacheContents[key] = _remote.fileBuffer(_sid)[key.$2];
    _seenConflicts[key] = _remote.tabsState(_sid).conflicts[key.$2];
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
    if (path == null || ctrl == null || key == null || _conflict) return;
    final edit = _edits[key];
    try {
      // The PUT carries the sha256 baseline captured at open time. A 409
      // records the conflict in the remote bucket, which renders the
      // resolution bar above.
      await _remote.saveStudioFile(_sid, path);
    } catch (error) {
      if (mounted) {
        showStudioToast(context, StudioFailure.of(error).message, error: true);
      }
      return;
    }
    if (!mounted) return;
    if (key != _boundKey || edit != _edits[key]) return;
    showStudioToast(context, 'Saved ${path.split('/').last} to the workspace');
  }

  // ── layout ──────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // No AnimatedBuilder here: [_bind] already refreshes this state when the
    // bound file changes, and every other notification is filtered out.
    return Builder(
      builder: (context) {
        final path = _boundPath;
        final key = _boundKey;
        if (path == null || key == null) return const _NoFileView();
        final editable = _editable(key);
        final ctrl = editable ? _ctrl : null;
        if (editable && ctrl == null) return const _NoFileView();
        // Only editable buffers get a field; the active non-editable file
        // (binary, too large, large read-only) gets a placeholder/viewer
        // as an extra keyed child so the other fields keep their state.
        final fields = [
          for (final entry in _buffers.entries)
            if (entry.key == key || _editable(entry.key)) entry,
        ];
        final children = <Widget>[
          for (final entry in fields)
            if (entry.key != key || editable)
              KeyedSubtree(
                key: ValueKey(entry.key),
                child: _field(
                  entry.key.$2,
                  entry.value,
                  _undoControllers[entry.key]!,
                ),
              ),
          if (!editable)
            KeyedSubtree(
              key: ValueKey(('viewer', key)),
              child: _placeholder(key),
            ),
        ];
        final index = editable
            ? fields.indexWhere((entry) => entry.key == key)
            : children.length - 1;
        return CallbackShortcuts(
          // Escape is only bound while the find bar is open — swallowing it
          // permanently would stop it reaching dialogs and the IME.
          bindings: <ShortcutActivator, VoidCallback>{
            if (editable) ...{
              const SingleActivator(LogicalKeyboardKey.keyF, control: true):
                  _openFind,
              const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                  _openFind,
            },
            if (_findOpen)
              const SingleActivator(LogicalKeyboardKey.escape): _closeFind,
          },
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            child: Material(
              type: MaterialType.canvas,
              color: Aether.bg,
              child: StudioPaneViewport(
                chrome: [
                  _header(path, ctrl),
                  if (_conflict) _conflictBar(),
                  if (_findOpen && ctrl != null) _findBar(ctrl),
                ],
                // Only the active field is laid out (F-077): IndexedStack
                // laid out every open file's full text on each resize.
                child: _ActiveChildStack(index: index, children: children),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Placeholder for a file that is not edited as text.
  Widget _placeholder(_BufferKey key) {
    final path = key.$2;
    final guard = _remote.guardFor(_sid, path);
    final text = key.$1[path] ?? '';
    if (guard?.kind == StudioFileGuardKind.tooLarge) {
      return _TooLargeView(path: path, bytes: guard!.bytes);
    }
    if (guard != null || looksBinaryText(text)) {
      return _BinaryFileView(path: path);
    }
    return _LargeFileViewer(
      key: ValueKey(('large', key)),
      path: path,
      text: text,
      onEditAnyway: text.length <= kStudioEditHardCap
          ? () {
              if (_findOpen) _closeFind();
              setState(() => _editAnyway.add(key));
              _bind(notify: true);
            }
          : null,
    );
  }

  Widget _conflictBar() => MaterialBanner(
    content: const Text('This file changed externally. Your draft has been kept.'),
    actions: [
      TextButton(onPressed: () {
        final key = _boundKey!;
        _edits[key] = (_edits[key] ?? 0) + 1;
        _seenConflicts[key] = null;
        _remote.resolveStudioConflict(_sid, key.$2, keepDraft: true);
      }, child: const Text('Keep draft')),
      TextButton(onPressed: () {
        final key = _boundKey!;
        _edits[key] = (_edits[key] ?? 0) + 1;
        _seenConflicts[key] = null;
        // The bucket swaps the buffer; _bind applies it to the controller
        // with the caret clamped.
        _remote.resolveStudioConflict(_sid, key.$2, keepDraft: false);
      }, child: const Text('Use external')),
    ],
  );

  Widget _header(String path, TextEditingController? ctrl) {
    final pos = ctrl == null ? null : _positionOf(ctrl);
    final conflict = _conflict;
    final guard = _remote.guardFor(_sid, path);
    final binary = guard?.binary == true ||
        (ctrl == null &&
            looksBinaryText(_remote.fileBuffer(_sid)[path] ?? ''));
    final name = path.split('/').last;
    final dir = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '';
    // Mode pill reflects the editor's state of this tab: conflict > unsaved
    // draft > clean. Rendered through AetherPill so Studio's chrome shares the
    // monochrome + accent language used elsewhere in the app.
    final undo = _undoCtrl;
    final AetherPill pill;
    if (ctrl == null) {
      pill = AetherPill(
        label: binary
            ? 'BINARY'
            : guard != null
                ? 'TOO LARGE'
                : 'READ-ONLY',
        icon: Icons.lock_outline,
        color: Aether.textMuted,
      );
    } else if (conflict) {
      pill = AetherPill(
        label: 'CONFLICT',
        icon: Icons.sync_problem_outlined,
        color: Aether.danger,
      );
    } else if (_dirty) {
      pill = AetherPill(
        label: 'UNSAVED',
        icon: Icons.circle,
        color: Aether.warn,
      );
    } else {
      pill = AetherPill(
        label: 'SAVED',
        icon: Icons.check_circle,
        color: Aether.success,
      );
    }
    return Container(
      constraints: BoxConstraints(
        minHeight: kStudioTapTarget +
            4 * (MediaQuery.textScalerOf(context).scale(1.0) - 1).clamp(0, 2),
      ),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        border: Border(bottom: BorderSide(color: Aether.hairline)),
      ),
      padding: const EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
      child: LayoutBuilder(
        builder: (context, c) {
          final scale = MediaQuery.textScalerOf(context).scale(1.0);
          final roomy = c.maxWidth >= 760 * math.max(1.0, scale);
          final identity = Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 15,
                color: _dirty ? Aether.warn : Aether.accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  header: true,
                  label: 'Editing $path',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          overflow: TextOverflow.ellipsis,
                          style: AetherType.title.copyWith(
                            fontSize: 13.5,
                            color: Aether.text,
                          ),
                        ),
                      ),
                      if (dir.isNotEmpty && roomy) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            dir,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: Aether.mono,
                              fontFamilyFallback: kStudioMonoFallback,
                              fontSize: kStudioMinFontSize,
                              color: Aether.textFaint,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              pill,
            ],
          );
          final actions = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (roomy && pos != null) ...[
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
                onPressed: ctrl == null
                    ? null
                    : _findOpen
                        ? _closeFind
                        : _openFind,
              ),
              StudioIconButton(
                icon: Icons.undo,
                tooltip: 'Undo',
                iconSize: 18,
                onPressed: ctrl != null && undo!.value.canUndo ? undo.undo : null,
              ),
              StudioIconButton(
                icon: Icons.redo,
                tooltip: 'Redo',
                iconSize: 18,
                onPressed: ctrl != null && undo!.value.canRedo ? undo.redo : null,
              ),
              StudioIconButton(
                icon: Icons.save_outlined,
                tooltip: 'Save changes',
                iconSize: 18,
                color: _dirty ? Aether.accent : null,
                onPressed:
                    ctrl != null && _dirty && !conflict ? _save : null,
              ),
            ],
          );
          if (roomy) {
            return Row(children: [
              Expanded(child: identity),
              const SizedBox(width: 8),
              actions,
            ]);
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              identity,
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: actions,
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
          final roomy = c.maxWidth >= 420 * math.max(1.0,
              MediaQuery.textScalerOf(context).scale(1.0));
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

  // Line-start index of the text last measured. Rebuilt only when the text
  // object changes; a caret move or any other rebuild is a binary search.
  String? _lineIndexText;
  List<int> _lineStarts = const [0];

  _EditorPosition _positionOf(TextEditingController ctrl) {
    final text = ctrl.text;
    if (!identical(text, _lineIndexText)) {
      assert(() {
        StudioEditorDebug.lineIndexBuilds++;
        return true;
      }());
      final starts = <int>[0];
      for (var i = text.indexOf('\n'); i >= 0; i = text.indexOf('\n', i + 1)) {
        starts.add(i + 1);
      }
      _lineIndexText = text;
      _lineStarts = starts;
    }
    final offset = ctrl.selection.isValid
        ? ctrl.selection.start.clamp(0, text.length)
        : 0;
    // Last line start <= offset.
    var lo = 0, hi = _lineStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_lineStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return _EditorPosition(lo + 1, offset - _lineStarts[lo] + 1, _lineStarts.length);
  }
}

/// Editor work counters for rebuild-scope tests (debug builds only).
@visibleForTesting
abstract final class StudioEditorDebug {
  /// Full-text line index scans behind the line/column readout.
  static int lineIndexBuilds = 0;
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
      child: SingleChildScrollView(
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

/// An [IndexedStack] that re-lays out ONLY the displayed child.
///
/// Every open file is a full-text `TextField`; IndexedStack laid all of them
/// out against the live constraints, i.e. on every resize and keyboard
/// animation (F-077). Inactive children stay mounted (their undo history
/// lives in the field's state) but keep frozen constraints, and are not
/// painted, hit-tested or focusable.
class _ActiveChildStack extends MultiChildRenderObjectWidget {
  _ActiveChildStack({required this.index, required List<Widget> children})
      : super(
          children: [
            for (var i = 0; i < children.length; i++)
              ExcludeFocus(
                // Keyed like the child so a closed tab never shifts state
                // onto its neighbour.
                key: children[i].key,
                excluding: i != index,
                child: children[i],
              ),
          ],
        );

  final int index;

  @override
  RenderIndexedStack createRenderObject(BuildContext context) =>
      _RenderActiveChildStack(index: index);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderIndexedStack renderObject,
  ) {
    renderObject.index = index;
  }

  @override
  MultiChildRenderObjectElement createElement() =>
      _ActiveChildStackElement(this);
}

class _ActiveChildStackElement extends MultiChildRenderObjectElement {
  _ActiveChildStackElement(_ActiveChildStack super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    final index = (widget as _ActiveChildStack).index;
    if (index >= 0 && index < children.length) {
      visitor(children.elementAt(index));
    }
  }
}

class _RenderActiveChildStack extends RenderIndexedStack {
  _RenderActiveChildStack({super.index})
      : super(
          alignment: Alignment.topLeft,
          textDirection: TextDirection.ltr,
        );

  RenderBox? get _active {
    final index = this.index;
    if (index == null || index < 0) return null;
    var child = firstChild;
    for (var i = 0; i < index && child != null; i++) {
      child = childAfter(child);
    }
    return child;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _active?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _active?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      _active?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _active?.getMaxIntrinsicHeight(width) ?? 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = _active;
    if (child == null) return constraints.smallest;
    return constraints.constrain(child.getDryLayout(constraints.loosen()));
  }

  /// The constraints each child last had while it was displayed.
  final Expando<BoxConstraints> _frozen = Expando();

  @override
  void performLayout() {
    final active = _active;
    var child = firstChild;
    while (child != null) {
      final parentData = child.parentData! as StackParentData;
      parentData.offset = Offset.zero;
      if (identical(child, active)) {
        final loose = constraints.loosen();
        _frozen[child] = loose;
        child.layout(loose, parentUsesSize: true);
      } else {
        // Hidden children keep the constraints they were last shown with, so
        // a resize or keyboard animation does not re-lay out their text:
        // with unchanged constraints and no edits, layout is a no-op. They
        // are relayout boundaries, so their own edits stay local.
        child.layout(_frozen[child] ?? constraints.loosen());
      }
      child = parentData.nextSibling;
    }
    size = active == null
        ? constraints.smallest
        : constraints.constrain(active.size);
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes bytes';
}

class _CenteredNotice extends StatelessWidget {
  const _CenteredNotice({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Aether.bg,
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: Aether.textMuted),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: AetherType.title.copyWith(fontSize: 14, color: Aether.text),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.5, color: Aether.textMuted),
            ),
            if (action != null) ...[const SizedBox(height: 12), action!],
          ],
        ),
      ),
    );
  }
}

/// Binary files are never decoded into the editor (F-075): an edit + Save
/// would commit U+FFFD soup over the real bytes.
class _BinaryFileView extends StatelessWidget {
  const _BinaryFileView({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) => _CenteredNotice(
        icon: Icons.block_outlined,
        title: 'Binary file — not editable',
        body: '${path.split('/').last} is not a text file, so Studio will not '
            'open it for editing.',
      );
}

/// Above the on-device cap the file is never loaded (F-076).
class _TooLargeView extends StatelessWidget {
  const _TooLargeView({required this.path, required this.bytes});

  final String path;
  final int bytes;

  @override
  Widget build(BuildContext context) {
    final command = "less '${path.replaceAll("'", r"'\''")}'";
    return _CenteredNotice(
      icon: Icons.description_outlined,
      title: 'Too large to open on device',
      body: '${path.split('/').last}${bytes > 0 ? ' is ${_formatBytes(bytes)}' : ''}. '
          'Studio edits files up to ${_formatBytes(kStudioEditHardCap)}. '
          'Open it in the terminal instead:\n$command',
      action: OutlinedButton.icon(
        icon: const Icon(Icons.copy, size: 16),
        label: const Text('Copy terminal command'),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: command));
          showStudioToast(context, 'Command copied');
        },
      ),
    );
  }
}

/// Read-only, virtualised viewer for large text files (F-076): one lazily
/// built row per line instead of one paragraph for the whole file.
class _LargeFileViewer extends StatefulWidget {
  const _LargeFileViewer({
    super.key,
    required this.path,
    required this.text,
    required this.onEditAnyway,
  });

  final String path;
  final String text;
  final VoidCallback? onEditAnyway;

  @override
  State<_LargeFileViewer> createState() => _LargeFileViewerState();
}

class _LargeFileViewerState extends State<_LargeFileViewer> {
  /// Longest slice of one line that is laid out (minified bundles are a
  /// single multi-megabyte line).
  static const int _maxLineChars = 2000;
  late List<String> _lines = widget.text.split('\n');

  @override
  void didUpdateWidget(_LargeFileViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.text, widget.text)) {
      _lines = widget.text.split('\n');
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: Aether.mono,
      fontFamilyFallback: kStudioMonoFallback,
      fontSize: kStudioEditorFontSize,
      height: kStudioEditorLineHeight,
      color: Aether.text,
    );
    return Container(
      color: Aether.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            color: Aether.surface,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Large file (${_formatBytes(widget.text.length)}) — '
                    'opened read-only to keep Studio responsive.',
                    style: TextStyle(fontSize: 12, color: Aether.textMuted),
                  ),
                ),
                TextButton(
                  onPressed: widget.onEditAnyway,
                  child: Text(
                    widget.onEditAnyway == null ? 'Too large to edit' : 'Edit anyway',
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Semantics(
              label: 'Read-only viewer for ${widget.path}',
              child: SelectionArea(
                child: ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _lines.length,
                  itemBuilder: (context, i) {
                    final line = _lines[i];
                    return Text(
                      line.length > _maxLineChars
                          ? '${line.substring(0, _maxLineChars)} …'
                          : line,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: style,
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
