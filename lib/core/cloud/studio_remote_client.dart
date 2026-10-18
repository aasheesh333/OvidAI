import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../studio_drafts.dart';
import 'cloud_rest.dart';
import 'studio_files.dart';

/// One session's Studio tab view — the shape the editor/tree widgets bind to
/// (the `_SessionStudio` field set moved out of AgentService).
@immutable
class StudioTabsState {
  const StudioTabsState({
    required this.openFiles,
    required this.activePath,
    required this.buffer,
    required this.activeContent,
    required this.dirtyPaths,
    required this.conflicts,
    required this.guardedPaths,
  });

  final List<String> openFiles;
  final String? activePath;
  final Map<String, String> buffer;
  final String? activeContent;
  final List<String> dirtyPaths;

  /// path → external content that arrived while the path held a draft.
  final Map<String, String> conflicts;

  final List<String> guardedPaths;

  static const StudioTabsState empty = StudioTabsState(
    openFiles: <String>[],
    activePath: null,
    buffer: <String, String>{},
    activeContent: null,
    dirtyPaths: <String>[],
    conflicts: <String, String>{},
    guardedPaths: <String>[],
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StudioTabsState &&
          listEquals(openFiles, other.openFiles) &&
          activePath == other.activePath &&
          mapEquals(buffer, other.buffer) &&
          activeContent == other.activeContent &&
          listEquals(dirtyPaths, other.dirtyPaths) &&
          mapEquals(conflicts, other.conflicts) &&
          listEquals(guardedPaths, other.guardedPaths);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(openFiles),
        activePath,
        Object.hashAll(buffer.entries),
        activeContent,
        Object.hashAll(dirtyPaths),
        Object.hashAll(conflicts.entries),
        Object.hashAll(guardedPaths),
      );
}

/// `path → (kind, message)` — the conflict view the brief pins.
typedef StudioConflict = ({String kind, String message});

class _SessionStudioState {
  _SessionStudioState(this.sessionId);

  final String sessionId;

  final Map<String, String> fileBuffer = <String, String>{};
  final List<String> openFiles = <String>[];
  String? activeFilePath;

  /// path → sha256 of the bytes last known to be on the server.
  final Map<String, String> baselines = <String, String>{};

  /// path → content last known to be saved (the dirty comparison baseline).
  final Map<String, String> savedContent = <String, String>{};

  final Set<String> dirty = <String>{};

  /// path → external content that arrived while a draft was held.
  final Map<String, String> conflicts = <String, String>{};

  /// path → sha256 of the external content above (when known).
  final Map<String, String> conflictHashes = <String, String>{};

  final Map<String, StudioFileGuard> guards = <String, StudioFileGuard>{};

  final ValueNotifier<StudioTabsState> tabs =
      ValueNotifier<StudioTabsState>(StudioTabsState.empty);

  StudioTreeSnapshot? snapshot;
  bool treeLoading = false;
  String? treeError;

  StudioTabsState compute() {
    final active = activeFilePath;
    return StudioTabsState(
      openFiles: List<String>.unmodifiable(openFiles),
      activePath: active,
      buffer: fileBuffer,
      activeContent: active == null ? null : fileBuffer[active],
      dirtyPaths: List<String>.unmodifiable(
        dirty.where(fileBuffer.containsKey).toList()..sort(),
      ),
      conflicts: conflicts.isEmpty
          ? const <String, String>{}
          : Map<String, String>.unmodifiable(conflicts),
      guardedPaths: guards.isEmpty
          ? const <String>[]
          : List<String>.unmodifiable(guards.keys.toList()..sort()),
    );
  }
}

/// Remote Studio state (P8 Task 15): the `_SessionStudio` bucket moved out of
/// `AgentService` and bound to the P7 workspace file API.
///
/// One bucket per server session id. Buffers, baselines, dirty/conflict state
/// and open tabs live here so the editor, tree and screen can all bind to the
/// same listenable without touching local git or a local repo cache.
class StudioRemoteClient extends ChangeNotifier {
  StudioRemoteClient({StudioFilesClient? files, StudioDraftStore? drafts})
      : _files = files ?? StudioFilesClient(CloudRestClient.I),
        _drafts = drafts ?? StudioDraftStore.I;

  static StudioRemoteClient? _instance;

  static StudioRemoteClient get I => _instance ??= StudioRemoteClient();

  @visibleForTesting
  static void installForTest(StudioRemoteClient client) => _instance = client;

  final StudioFilesClient _files;
  final StudioDraftStore _drafts;
  final Map<String, _SessionStudioState> _sessions =
      <String, _SessionStudioState>{};

  StudioFilesClient get files => _files;

  _SessionStudioState _stateFor(String sessionId) {
    final existing = _sessions[sessionId];
    if (existing != null) return existing;
    final state = _SessionStudioState(sessionId);
    _sessions[sessionId] = state;
    unawaited(_restoreDrafts(state));
    return state;
  }

  ValueListenable<StudioTabsState> tabsFor(String sessionId) =>
      _stateFor(sessionId).tabs;

  StudioTabsState tabsState(String sessionId) =>
      _stateFor(sessionId).tabs.value;

  // -------------------------------------------------------------------------
  // Shape pinned by the brief
  // -------------------------------------------------------------------------

  Map<String, String> fileBuffer(String sessionId) =>
      _stateFor(sessionId).fileBuffer;

  List<String> openFiles(String sessionId) => _stateFor(sessionId).openFiles;

  String? activeFilePath(String sessionId) =>
      _stateFor(sessionId).activeFilePath;

  /// path → server sha256 (the PUT baseline).
  Map<String, String> baselines(String sessionId) =>
      _stateFor(sessionId).baselines;

  bool isStudioFileDirty(String sessionId, String path) {
    final state = _stateFor(sessionId);
    return state.dirty.contains(path) && state.fileBuffer.containsKey(path);
  }

  Map<String, StudioConflict> conflicts(String sessionId) => {
        for (final entry in _stateFor(sessionId).conflicts.entries)
          entry.key: (
            kind: 'baseline',
            message: 'The file changed on the server since it was opened.',
          ),
      };

  StudioFileGuard? guardFor(String sessionId, String path) =>
      _stateFor(sessionId).guards[path];

  FileNode? treeFor(String sessionId) => _stateFor(sessionId).snapshot?.root;

  StudioTreeSnapshot? snapshotFor(String sessionId) =>
      _stateFor(sessionId).snapshot;

  String treeState(String sessionId) =>
      _stateFor(sessionId).snapshot?.state ?? 'unknown';

  bool treeLoading(String sessionId) => _stateFor(sessionId).treeLoading;

  String? treeError(String sessionId) => _stateFor(sessionId).treeError;

  List<String> dirtyFiles(String sessionId) {
    final state = _stateFor(sessionId);
    final paths = [
      for (final path in state.dirty)
        if (state.fileBuffer.containsKey(path)) path,
    ];
    paths.sort((a, b) {
      final ia = state.openFiles.indexOf(a);
      final ib = state.openFiles.indexOf(b);
      return (ia < 0 ? 1 << 30 : ia).compareTo(ib < 0 ? 1 << 30 : ib);
    });
    return paths;
  }

  // -------------------------------------------------------------------------
  // Tree
  // -------------------------------------------------------------------------

  /// Refreshes the workspace tree (`GET …/workspace/tree`).
  Future<StudioTreeSnapshot?> syncStudioTabs(String sessionId) async {
    final state = _stateFor(sessionId);
    state.treeLoading = true;
    state.treeError = null;
    _publish(state);
    try {
      final snapshot = await _files.treeSnapshot(sessionId);
      state.snapshot = snapshot;
      return snapshot;
    } catch (error) {
      state.treeError = error.toString();
      return null;
    } finally {
      state.treeLoading = false;
      _publish(state);
    }
  }

  // -------------------------------------------------------------------------
  // Open / edit / save
  // -------------------------------------------------------------------------

  /// Lazily fetches [path] (one GET) and opens it as a tab.
  Future<void> openStudioFile(String sessionId, String path) async {
    final state = _stateFor(sessionId);
    if (state.fileBuffer.containsKey(path)) {
      _focus(state, path);
      return;
    }
    final read = await _files.readFileDetailed(sessionId, path);
    // A redirect response that exceeded the hard cap was not downloaded
    // (`StudioFilesClient.readFileDetailed`); its declared size still selects
    // the too-large placeholder here.
    final guard = read.sizeBytes > kStudioEditHardCap
        ? StudioFileGuard.tooLarge(read.sizeBytes)
        : _guardForContent(read.content);
    if (guard != null) {
      state.guards[path] = guard;
      state.fileBuffer[path] = '';
      state.savedContent[path] = '';
    } else {
      state.guards.remove(path);
      state.fileBuffer[path] = read.content;
      state.savedContent[path] = read.content;
    }
    state.baselines[path] = read.sha256;
    state.dirty.remove(path);
    state.conflicts.remove(path);
    state.conflictHashes.remove(path);
    _focus(state, path);
  }

  /// Opens [path] as a non-editable placeholder (binary / too large).
  void openStudioPlaceholder(
      String sessionId, String path, StudioFileGuard guard) {
    final state = _stateFor(sessionId);
    if (isStudioFileDirty(sessionId, path)) {
      _focus(state, path);
      return;
    }
    state.guards[path] = guard;
    state.fileBuffer[path] = '';
    state.savedContent[path] = '';
    state.dirty.remove(path);
    state.conflicts.remove(path);
    _focus(state, path);
  }

  void newStudioFile(String sessionId, String path) {
    final state = _stateFor(sessionId);
    state.guards.remove(path);
    state.fileBuffer[path] = '';
    state.savedContent.remove(path);
    state.baselines.remove(path);
    state.dirty.add(path);
    _focus(state, path);
    _scheduleDraftPersist(state);
  }

  /// The editor's keystroke path.
  void updateStudioDraft(String sessionId, String path, String text) {
    final state = _stateFor(sessionId);
    final wasDirty = isStudioFileDirty(sessionId, path);
    state.fileBuffer[path] = text;
    final baseline = state.savedContent[path];
    final dirty = state.conflicts.containsKey(path) ||
        baseline == null ||
        baseline != text;
    if (dirty) {
      state.dirty.add(path);
    } else {
      state.dirty.remove(path);
    }
    // The editor owns the live text; publish only when the dirty flag (the
    // tab strip / guard state) actually changed, so typing does not rebuild
    // the whole screen per keystroke.
    if (wasDirty != dirty) _publish(state);
    if (dirty) _scheduleDraftPersist(state);
  }

  /// Records [content] as the saved state of [path] when nothing is known yet
  /// (a buffer filled without [openStudioFile]).
  void ensureStudioBaseline(String sessionId, String path, String content) {
    final state = _stateFor(sessionId);
    if (state.savedContent.containsKey(path)) return;
    if (!isStudioFileDirty(sessionId, path)) {
      state.savedContent[path] = content;
    }
  }

  /// `PUT …/workspace/file` with the sha256 baseline. A 409/baseline mismatch
  /// records a conflict (the draft stays) and rethrows so the caller can toast.
  Future<void> saveStudioFile(String sessionId, String path) async {
    final state = _stateFor(sessionId);
    final text = state.fileBuffer[path];
    if (text == null) return;
    if (state.guards.containsKey(path)) {
      throw StateError('This file is not editable.');
    }
    try {
      final result = await _files.writeFile(
        sessionId,
        path,
        text,
        baselineHash: state.baselines[path],
      );
      state.baselines[path] = result.sha256;
      state.savedContent[path] = text;
      // A keystroke that landed while the PUT was in flight is still a draft;
      // only clear the dirty state when the buffer is exactly what was saved.
      if (state.fileBuffer[path] == text) {
        state.dirty.remove(path);
        state.conflicts.remove(path);
        state.conflictHashes.remove(path);
      }
      _publish(state);
      _scheduleDraftPersist(state);
    } on CloudApiException catch (error) {
      if (error.status == 409 || error.code == 'baseline_mismatch') {
        String external = '';
        String? hash;
        try {
          final read = await _files.readFileDetailed(sessionId, path);
          external = read.content;
          hash = read.sha256;
        } catch (_) {
          // The refetch is best-effort: the conflict is still recorded, so the
          // editor shows the resolution bar instead of silently losing a save.
        }
        state.conflicts[path] = external;
        if (hash != null) state.conflictHashes[path] = hash;
        _publish(state);
        _scheduleDraftPersist(state);
      }
      rethrow;
    }
  }

  /// Settles a conflict: keep the draft (external content becomes the new
  /// baseline) or take the external content (draft discarded).
  void resolveStudioConflict(
    String sessionId,
    String path, {
    required bool keepDraft,
  }) {
    final state = _stateFor(sessionId);
    final external = state.conflicts.remove(path);
    if (external == null) return;
    state.savedContent[path] = external;
    state.baselines[path] = state.conflictHashes.remove(path) ??
        sha256.convert(utf8.encode(external)).toString();
    if (keepDraft) {
      if (state.fileBuffer[path] == external) state.dirty.remove(path);
    } else {
      state.fileBuffer[path] = external;
      state.dirty.remove(path);
    }
    _publish(state);
    _scheduleDraftPersist(state);
  }

  // -------------------------------------------------------------------------
  // Tabs / drafts
  // -------------------------------------------------------------------------

  void selectStudioFile(String sessionId, String path) {
    final state = _stateFor(sessionId);
    if (!state.openFiles.contains(path)) return;
    state.activeFilePath = path;
    _publish(state);
  }

  void focusStudioFile(String sessionId, String path) {
    final state = _stateFor(sessionId);
    if (!state.fileBuffer.containsKey(path)) return;
    _focus(state, path);
  }

  void closeStudioFile(String sessionId, String path) {
    final state = _stateFor(sessionId);
    state.openFiles.remove(path);
    if (state.activeFilePath == path) {
      state.activeFilePath =
          state.openFiles.isEmpty ? null : state.openFiles.last;
    }
    _publish(state);
  }

  void discardStudioDraft(String sessionId, String path) {
    final state = _stateFor(sessionId);
    final saved = state.conflicts.remove(path) ?? state.savedContent[path];
    if (saved != null) {
      state.fileBuffer[path] = saved;
      state.savedContent[path] = saved;
    }
    state.dirty.remove(path);
    _publish(state);
    _scheduleDraftPersist(state);
  }

  void discardAllStudioDrafts(String sessionId) {
    final state = _stateFor(sessionId);
    for (final path in state.dirty.toList()) {
      final saved = state.conflicts.remove(path) ?? state.savedContent[path];
      if (saved != null) {
        state.fileBuffer[path] = saved;
        state.savedContent[path] = saved;
      }
      state.dirty.remove(path);
    }
    _publish(state);
    _scheduleDraftPersist(state);
  }

  /// Saves every dirty buffer; returns the paths that failed.
  Future<List<String>> saveAllStudioDrafts(String sessionId) async {
    final failed = <String>[];
    for (final path in dirtyFiles(sessionId)) {
      try {
        await saveStudioFile(sessionId, path);
      } catch (_) {
        failed.add(path);
      }
    }
    return failed;
  }

  /// Reset hook: forget every in-memory bucket and its persisted drafts.
  ///
  /// Buckets are reset IN PLACE (the map is not cleared) so widgets that hold
  /// `tabsFor(sessionId)` keep observing the same [ValueNotifier] after a
  /// reset; dropping the map left them listening to a notifier no later
  /// `_stateFor` would ever update again.
  void clearAll() {
    for (final state in _sessions.values) {
      state.fileBuffer.clear();
      state.openFiles.clear();
      state.activeFilePath = null;
      state.baselines.clear();
      state.savedContent.clear();
      state.dirty.clear();
      state.conflicts.clear();
      state.conflictHashes.clear();
      state.guards.clear();
      state.snapshot = null;
      state.treeLoading = false;
      state.treeError = null;
      state.tabs.value = StudioTabsState.empty;
    }
    unawaited(_drafts.deleteAll('editor_'));
    notifyListeners();
  }

  bool get noDrafts => _sessions.values.every(
      (state) => !state.dirty.any(state.fileBuffer.containsKey));

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  /// A placeholder guard for content that must not open as editable text:
  /// binary bytes, or more than [kStudioEditHardCap] characters.
  static StudioFileGuard? _guardForContent(String content) {
    if (content.length > kStudioEditHardCap) {
      return StudioFileGuard.tooLarge(content.length);
    }
    if (looksBinaryText(content)) {
      return StudioFileGuard.binary(bytes: content.length);
    }
    return null;
  }

  void _focus(_SessionStudioState state, String path) {
    if (!state.openFiles.contains(path)) state.openFiles.add(path);
    state.activeFilePath = path;
    _publish(state);
  }

  void _publish(_SessionStudioState state) {
    state.tabs.value = state.compute();
    notifyListeners();
  }

  void _scheduleDraftPersist(_SessionStudioState state) {
    _drafts.schedule(
      StudioDraftStore.recordName('editor', state.sessionId),
      () {
        final files = <String, Object?>{
          for (final path in state.dirty)
            if (state.fileBuffer.containsKey(path))
              path: {
                'draft': state.fileBuffer[path],
                'baseline': state.savedContent[path],
                'hash': state.baselines[path],
              },
        };
        if (files.isEmpty) return (data: null);
        return (
          data: <String, Object?>{
            'v': 2,
            'sessionId': state.sessionId,
            'files': files,
            'open': List<String>.of(state.openFiles),
            'active': state.activeFilePath,
          },
        );
      },
    );
  }

  Future<void> _restoreDrafts(_SessionStudioState state) async {
    if (!_drafts.enabled) return;
    final record = await _drafts.read(
      StudioDraftStore.recordName('editor', state.sessionId),
    );
    if (record == null || record['sessionId'] != state.sessionId) return;
    final files = record['files'];
    if (files is! Map) return;
    var restored = false;
    for (final entry in files.entries) {
      final path = entry.key;
      final value = entry.value;
      if (path is! String || value is! Map) continue;
      final draft = value['draft'];
      if (draft is! String) continue;
      state.fileBuffer[path] = draft;
      final baseline = value['baseline'];
      if (baseline is String) state.savedContent[path] = baseline;
      final hash = value['hash'];
      if (hash is String) state.baselines[path] = hash;
      state.dirty.add(path);
      if (!state.openFiles.contains(path)) state.openFiles.add(path);
      restored = true;
    }
    if (!restored) return;
    final active = record['active'];
    if (active is String && state.openFiles.contains(active)) {
      state.activeFilePath = active;
    }
    state.activeFilePath ??=
        state.openFiles.isEmpty ? null : state.openFiles.first;
    _publish(state);
  }
}
