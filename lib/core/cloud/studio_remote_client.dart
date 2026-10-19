import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../studio_drafts.dart';
import 'cloud_rest.dart';
import 'studio_files.dart';

/// One Studio bucket's tab view — the shape the editor/tree widgets bind to.
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
    this.savingPaths = const <String>[],
  });

  final List<String> openFiles;
  final String? activePath;
  final Map<String, String> buffer;
  final String? activeContent;
  final List<String> dirtyPaths;

  /// path → external content that arrived while the path held a draft.
  final Map<String, String> conflicts;

  final List<String> guardedPaths;

  /// Paths with a PUT in flight (ST-014): Save is disabled while listed.
  final List<String> savingPaths;

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
          listEquals(guardedPaths, other.guardedPaths) &&
          listEquals(savingPaths, other.savingPaths);

  @override
  int get hashCode => Object.hash(
        Object.hashAll(openFiles),
        activePath,
        Object.hashAll(buffer.entries),
        activeContent,
        Object.hashAll(dirtyPaths),
        Object.hashAll(conflicts.entries),
        Object.hashAll(guardedPaths),
        Object.hashAll(savingPaths),
      );
}

/// `path → (kind, message)` — the conflict view the brief pins.
typedef StudioConflict = ({String kind, String message});

/// What "New file" did with the requested path (ST-005).
enum StudioNewFileOutcome {
  /// A new, empty, unsaved buffer: its first save is create-only.
  created,

  /// The path was already open (its draft kept) or exists on the server
  /// (opened with its real content) — never replaced by an empty buffer.
  openedExisting,

  /// A folder already has that path.
  isFolder,

  /// Not a usable workspace path (empty, absolute, `..`, trailing `/`).
  invalid,
}

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

  /// Created in Studio and never saved: the first PUT is create-only.
  final Set<String> newFiles = <String>{};

  /// PUTs in flight (ST-014).
  final Set<String> saving = <String>{};

  /// Saves the server accepted with 202 while the workspace was waking; they
  /// are retried once it is warm (ST-013).
  final Set<String> pendingSaves = <String>{};

  final ValueNotifier<StudioTabsState> tabs =
      ValueNotifier<StudioTabsState>(StudioTabsState.empty);

  StudioTreeSnapshot? snapshot;
  bool treeLoading = false;

  /// The typed failure of the last tree load (mapped to copy by the UI —
  /// never stringified, ST-009).
  Object? treeFailure;

  /// The single in-flight refresh (ST-019: no concurrent tree GETs).
  Future<StudioTreeSnapshot?>? refreshing;

  /// Waking a cold workspace (ST-013).
  bool waking = false;
  bool wakeTimedOut = false;
  Timer? wakeTimer;
  DateTime? wakeStartedAt;

  Timer? agentRefreshTimer;

  final Set<String> subtreeLoading = <String>{};
  final Set<String> subtreeLoaded = <String>{};

  bool restored = false;

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
      savingPaths: saving.isEmpty
          ? const <String>[]
          : List<String>.unmodifiable(saving.toList()..sort()),
    );
  }

  void cancelTimers() {
    wakeTimer?.cancel();
    wakeTimer = null;
    agentRefreshTimer?.cancel();
    agentRefreshTimer = null;
  }
}

/// Remote Studio state: the user's cloud workspace bound to the P7 workspace
/// file API.
///
/// Buckets are keyed by a Studio key — production uses ONE bucket,
/// [kStudioWorkspaceKey], because the agent workspace is per user and shared
/// by every chat (R2). Buffers, baselines, dirty/conflict state and open tabs
/// live here so the editor, tree and screen bind to the same listenable.
class StudioRemoteClient extends ChangeNotifier {
  StudioRemoteClient({
    StudioFilesClient? files,
    StudioDraftStore? drafts,
    this.wakePollInterval = const Duration(seconds: 2),
    this.wakeTimeout = const Duration(minutes: 2),
    this.agentRefreshDebounce = const Duration(milliseconds: 800),
  })  : _files = files ?? StudioFilesClient(CloudRestClient.I),
        _drafts = drafts ?? StudioDraftStore.I;

  static StudioRemoteClient? _instance;

  static StudioRemoteClient get I => _instance ??= StudioRemoteClient();

  @visibleForTesting
  static void installForTest(StudioRemoteClient client) => _instance = client;

  /// How often a waking workspace's tree is polled until it is warm.
  final Duration wakePollInterval;

  /// When a waking workspace gives up and shows the timed-out state.
  final Duration wakeTimeout;

  /// Coalesces a burst of agent file events into one refresh.
  final Duration agentRefreshDebounce;

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
  // Read accessors
  // -------------------------------------------------------------------------

  Map<String, String> fileBuffer(String sessionId) =>
      _stateFor(sessionId).fileBuffer;

  List<String> openFiles(String sessionId) => _stateFor(sessionId).openFiles;

  String? activeFilePath(String sessionId) =>
      _stateFor(sessionId).activeFilePath;

  /// path → server sha256 (the PUT `ifMatchSha256` precondition).
  Map<String, String> baselines(String sessionId) =>
      _stateFor(sessionId).baselines;

  bool isStudioFileDirty(String sessionId, String path) {
    final state = _stateFor(sessionId);
    return state.dirty.contains(path) && state.fileBuffer.containsKey(path);
  }

  /// True while a save of [path] is in flight (ST-014).
  bool isSaving(String sessionId, String path) =>
      _stateFor(sessionId).saving.contains(path);

  /// True while [path] waits for a waking workspace to be saved (ST-013).
  bool isSavePending(String sessionId, String path) =>
      _stateFor(sessionId).pendingSaves.contains(path);

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

  /// The typed failure of the last tree load, or null. Map it with
  /// `StudioFailure.forTree` — never show `toString()` (ST-009).
  Object? treeFailure(String sessionId) => _stateFor(sessionId).treeFailure;

  /// True when there is no server session to address the workspace through
  /// yet (ST-002) — a clear empty state, not an error.
  bool hasNoWorkspace(String sessionId) =>
      _stateFor(sessionId).treeFailure is StudioNoWorkspaceException;

  /// True while a cold workspace is being woken (ST-013).
  bool isWaking(String sessionId) => _stateFor(sessionId).waking;

  /// True when waking took longer than [wakeTimeout].
  bool wakeTimedOut(String sessionId) => _stateFor(sessionId).wakeTimedOut;

  bool subtreeLoading(String sessionId, String path) =>
      _stateFor(sessionId).subtreeLoading.contains(path);

  bool subtreeLoaded(String sessionId, String path) =>
      _stateFor(sessionId).subtreeLoaded.contains(path);

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

  /// Dirty buffers at [path] or inside it (a folder) — the delete/rename
  /// confirmations name them.
  List<String> dirtyFilesUnder(String sessionId, String path) => [
        for (final p in dirtyFiles(sessionId))
          if (p == path || p.startsWith('$path/')) p,
      ];

  // -------------------------------------------------------------------------
  // Tree + freshness (ST-006, ST-013, ST-019)
  // -------------------------------------------------------------------------

  /// Reloads the workspace from the server: the tree, then every open file
  /// (clean buffers adopt the server bytes; a draft whose file changed gets a
  /// conflict). A cold workspace is woken and polled until warm.
  ///
  /// Single-flight: a refresh requested while one is running joins it, so
  /// the several refresh triggers (app bar, agent events, resume, wake poll)
  /// never race each other's GETs.
  Future<StudioTreeSnapshot?> refreshWorkspace(String sessionId) {
    final state = _stateFor(sessionId);
    final running = state.refreshing;
    if (running != null) return running;
    final future = _refresh(state);
    state.refreshing = future;
    return future.whenComplete(() {
      if (identical(state.refreshing, future)) state.refreshing = null;
    });
  }

  Future<StudioTreeSnapshot?> _refresh(_SessionStudioState state) async {
    state.treeLoading = true;
    _publish(state);
    try {
      final snapshot = await _files.treeSnapshot(state.sessionId);
      state.snapshot = snapshot;
      state.treeFailure = null;
      state.subtreeLoaded.clear();
      if (snapshot.state == 'warm') {
        _stopWaking(state);
        await _refreshOpenFiles(state);
        _retryPendingSaves(state);
      } else {
        _startWaking(state, callHydrate: snapshot.state == 'cold');
      }
      return snapshot;
    } catch (error) {
      state.treeFailure = error;
      if (error is StudioNoWorkspaceException) state.snapshot = null;
      return null;
    } finally {
      state.treeLoading = false;
      _publish(state);
    }
  }

  /// Re-reads every open, editable file. Best-effort: a failed read leaves
  /// the buffer as it was.
  Future<void> _refreshOpenFiles(_SessionStudioState state) async {
    var changed = false;
    for (final path in List<String>.of(state.openFiles)) {
      if (state.guards.containsKey(path) || state.newFiles.contains(path)) {
        continue;
      }
      if (state.saving.contains(path)) continue;
      StudioFileRead read;
      try {
        read = await _files.readFileDetailed(state.sessionId, path);
      } on CloudApiException catch (error) {
        if (error.status == 404 && error.code != 'no_workspace') {
          // The agent (or another device) deleted it.
          if (isStudioFileDirty(state.sessionId, path)) {
            // Keep the draft; its next save re-creates the file.
            state.baselines.remove(path);
            state.newFiles.add(path);
          } else {
            _forget(state, path);
          }
          changed = true;
        }
        continue;
      } catch (_) {
        continue;
      }
      if (read.sha256 == state.baselines[path]) continue;
      if (read.sizeBytes > kStudioEditHardCap ||
          looksBinaryText(read.content)) {
        continue; // never adopt bytes the editor would refuse
      }
      if (isStudioFileDirty(state.sessionId, path)) {
        if (!state.conflicts.containsKey(path)) {
          state.conflicts[path] = read.content;
          state.conflictHashes[path] = read.sha256;
          changed = true;
        }
      } else {
        state.fileBuffer[path] = read.content;
        state.savedContent[path] = read.content;
        state.baselines[path] = read.sha256;
        changed = true;
      }
    }
    if (changed) {
      _publish(state);
      _scheduleDraftPersist(state);
    }
  }

  /// Wakes a cold workspace (`POST …/hydrate`) and polls the tree until it is
  /// warm, then the pending saves are retried (ST-013).
  void _startWaking(_SessionStudioState state, {required bool callHydrate}) {
    if (!state.waking) {
      state.waking = true;
      state.wakeTimedOut = false;
      state.wakeStartedAt = DateTime.now();
    }
    if (callHydrate) {
      unawaited(_files.hydrate(state.sessionId).then<void>((_) {},
          onError: (Object _) {
        // The poll below still notices a workspace that warms on its own;
        // a hydrate the server refused simply times out into the
        // "taking longer" state.
      }));
    }
    state.wakeTimer ??= Timer.periodic(wakePollInterval, (_) {
      final started = state.wakeStartedAt;
      if (started != null &&
          DateTime.now().difference(started) > wakeTimeout) {
        _stopWaking(state, timedOut: true);
        _publish(state);
        return;
      }
      unawaited(refreshWorkspace(state.sessionId));
    });
  }

  void _stopWaking(_SessionStudioState state, {bool timedOut = false}) {
    state.wakeTimer?.cancel();
    state.wakeTimer = null;
    state.waking = false;
    state.wakeTimedOut = timedOut;
    state.wakeStartedAt = null;
  }

  /// Wakes the workspace on request (the timed-out state's "Try again").
  Future<void> wakeWorkspace(String sessionId) async {
    final state = _stateFor(sessionId);
    _stopWaking(state);
    _startWaking(state, callHydrate: true);
    _publish(state);
  }

  void _retryPendingSaves(_SessionStudioState state) {
    for (final path in state.pendingSaves.toList()) {
      if (!isStudioFileDirty(state.sessionId, path)) {
        state.pendingSaves.remove(path);
        continue;
      }
      unawaited(saveStudioFile(state.sessionId, path).then<void>((_) {},
          onError: (Object _) {
        // A conflict or failure is recorded on the bucket; the editor shows it.
      }));
    }
  }

  /// Agent events that can change workspace files (ST-006). Tools that write
  /// files, shells, repo syncs, subagents — and every run end, which covers
  /// MCP/plugin tools whose effects Studio cannot know.
  static const Set<String> _fileTools = <String>{
    'write_file',
    'edit_file',
    'run_shell',
    'repo_sync',
    'dispatch_agent',
  };

  /// Feeds one session event (any of the user's chats — they share the
  /// workspace). File-changing events schedule ONE debounced refresh.
  void noteAgentEvent(String sessionId, String type,
      [Map<String, dynamic> payload = const <String, dynamic>{}]) {
    final relevant = switch (type) {
      'tool_completed' => _fileTools.contains(payload['name']),
      'run_completed' ||
      'run_failed' ||
      'run_cancelled' ||
      'subagent_completed' ||
      'workspace_hydrated' =>
        true,
      _ => false,
    };
    if (!relevant) return;
    final state = _stateFor(sessionId);
    state.agentRefreshTimer?.cancel();
    state.agentRefreshTimer = Timer(agentRefreshDebounce, () {
      state.agentRefreshTimer = null;
      unawaited(refreshWorkspace(sessionId));
    });
  }

  /// Lists a pruned folder from the live workspace and merges it into the
  /// tree (ST-015). A sleeping workspace is woken first (409 `not_warm`).
  Future<void> loadStudioSubtree(String sessionId, String dirPath) async {
    final state = _stateFor(sessionId);
    if (!state.subtreeLoading.add(dirPath)) return;
    _publish(state);
    try {
      final sub = await _files.treeSnapshot(sessionId, subPath: dirPath);
      final current = state.snapshot;
      if (current != null) {
        state.snapshot = StudioTreeSnapshot(
          sessionId: current.sessionId,
          state: current.state,
          generation: current.generation,
          source: current.source,
          truncated: current.truncated,
          root: _withChildren(current.root, dirPath, sub.root.children),
          fileCount: current.fileCount,
          dirCount: current.dirCount,
          totalBytes: current.totalBytes,
        );
      }
      state.subtreeLoaded.add(dirPath);
    } on CloudApiException catch (error) {
      if (error.status == 409 && error.code == 'not_warm') {
        _startWaking(state, callHydrate: true);
      }
      rethrow;
    } finally {
      state.subtreeLoading.remove(dirPath);
      _publish(state);
    }
  }

  static FileNode _withChildren(
      FileNode node, String path, List<FileNode> children) {
    if (node.path == path && node.isDir) {
      return FileNode(
        name: node.name,
        path: node.path,
        kind: node.kind,
        size: node.size,
        mtime: node.mtime,
        children: children,
        files: node.files,
        bytes: node.bytes,
        dirs: node.dirs,
      );
    }
    if (!node.isDir || (node.path.isNotEmpty && !path.startsWith('${node.path}/'))) {
      return node;
    }
    return FileNode(
      name: node.name,
      path: node.path,
      kind: node.kind,
      size: node.size,
      mtime: node.mtime,
      children: [
        for (final child in node.children) _withChildren(child, path, children),
      ],
      omitted: node.omitted,
      files: node.files,
      bytes: node.bytes,
      dirs: node.dirs,
    );
  }

  // -------------------------------------------------------------------------
  // Open / edit / save
  // -------------------------------------------------------------------------

  /// Lazily fetches [path] (one GET) and opens it as a tab. A path that is
  /// already open is only focused — its buffer (and any draft) is kept;
  /// freshness comes from [refreshWorkspace].
  Future<void> openStudioFile(String sessionId, String path) async {
    final state = _stateFor(sessionId);
    if (state.fileBuffer.containsKey(path)) {
      _focus(state, path);
      return;
    }
    final read = await _files.readFileDetailed(sessionId, path);
    // A draft restored or typed while the read was in flight wins.
    if (state.fileBuffer.containsKey(path)) {
      _focus(state, path);
      return;
    }
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
    state.newFiles.remove(path);
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

  /// "New file" (ST-005). Never replaces an open buffer and never opens an
  /// existing server file as empty: an open path is focused, an existing
  /// file is opened with its real content, and only a genuinely new path
  /// gets an empty buffer — whose first save is create-only on the server.
  Future<StudioNewFileOutcome> newStudioFile(
      String sessionId, String rawPath) async {
    final path = normalizeStudioPath(rawPath);
    if (path == null) return StudioNewFileOutcome.invalid;
    final state = _stateFor(sessionId);
    if (state.fileBuffer.containsKey(path)) {
      _focus(state, path);
      return StudioNewFileOutcome.openedExisting;
    }
    final known = _findNode(state.snapshot?.root, path);
    if (known != null && known.isDir) return StudioNewFileOutcome.isFolder;
    // The manifest can be pruned, so its silence proves nothing: ask the
    // server. Only a 404 means the path is free.
    try {
      await openStudioFile(sessionId, path);
      return StudioNewFileOutcome.openedExisting;
    } on CloudApiException catch (error) {
      if (error.status != 404 || error.code == 'no_workspace') rethrow;
    }
    if (state.fileBuffer.containsKey(path)) {
      _focus(state, path);
      return StudioNewFileOutcome.openedExisting;
    }
    state.guards.remove(path);
    state.fileBuffer[path] = '';
    state.savedContent.remove(path);
    state.baselines.remove(path);
    state.dirty.add(path);
    state.newFiles.add(path);
    _focus(state, path);
    _scheduleDraftPersist(state);
    return StudioNewFileOutcome.created;
  }

  static FileNode? _findNode(FileNode? node, String path) {
    if (node == null) return null;
    for (final child in node.children) {
      if (child.path == path) return child;
      if (child.isDir && path.startsWith('${child.path}/')) {
        return _findNode(child, path);
      }
    }
    return null;
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

  /// `PUT …/workspace/file` guarded by the server-side precondition: the
  /// sha256 baseline (`ifMatchSha256`) for a file opened from the server, or
  /// create-only (`ifNoneMatch`) for a file created in Studio.
  ///
  /// * A second save while one is in flight is a no-op (ST-014).
  /// * 409 `baseline_mismatch` / `already_exists` records a conflict with the
  ///   server's current bytes (the draft stays) and rethrows.
  /// * 202 (the workspace is waking) queues the save; it is retried
  ///   automatically once the workspace is warm (ST-013), then rethrows so
  ///   the caller can say so.
  Future<void> saveStudioFile(String sessionId, String path) async {
    final state = _stateFor(sessionId);
    final text = state.fileBuffer[path];
    if (text == null) return;
    if (state.guards.containsKey(path)) {
      throw StateError('This file is not editable.');
    }
    if (!state.saving.add(path)) return;
    _publish(state);
    final createOnly = state.newFiles.contains(path);
    try {
      final result = await _files.writeFile(
        sessionId,
        path,
        text,
        baselineHash: createOnly ? null : state.baselines[path],
        createOnly: createOnly,
      );
      state.baselines[path] = result.sha256;
      state.savedContent[path] = text;
      state.newFiles.remove(path);
      state.pendingSaves.remove(path);
      // A keystroke that landed while the PUT was in flight is still a draft;
      // only clear the dirty state when the buffer is exactly what was saved.
      if (state.fileBuffer[path] == text) {
        state.dirty.remove(path);
        state.conflicts.remove(path);
        state.conflictHashes.remove(path);
      }
      _scheduleDraftPersist(state);
      // A newly created file must show up in the tree without a manual
      // refresh (ST-008).
      if (createOnly) unawaited(_refreshTreeQuietly(state));
    } on StudioFileHydratingException {
      state.pendingSaves.add(path);
      _startWaking(state, callHydrate: false);
      rethrow;
    } on CloudApiException catch (error) {
      if (error.status == 409 &&
          (error.code == 'baseline_mismatch' ||
              error.code == 'already_exists')) {
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
        // The path exists on the server now: the next save is a normal
        // guarded overwrite of THOSE bytes, never another create.
        state.newFiles.remove(path);
        state.conflicts[path] = external;
        if (hash != null) state.conflictHashes[path] = hash;
        _scheduleDraftPersist(state);
      }
      rethrow;
    } finally {
      state.saving.remove(path);
      _publish(state);
    }
  }

  Future<void> _refreshTreeQuietly(_SessionStudioState state) async {
    try {
      await refreshWorkspace(state.sessionId);
    } catch (_) {
      // The tree's own error surface reports a failed refresh.
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
    state.newFiles.remove(path);
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
  // File management (ST-008)
  // -------------------------------------------------------------------------

  /// Deletes a file, or a folder and everything in it ([isFolder]). Open
  /// tabs under it close and their buffers (drafts included — the caller
  /// confirmed) are dropped.
  Future<void> deleteStudioPath(String sessionId, String path,
      {bool isFolder = false}) async {
    final state = _stateFor(sessionId);
    await _files.deletePath(sessionId, path, recursive: isFolder);
    for (final p in _pathsUnder(state, path)) {
      _forget(state, p);
    }
    _publish(state);
    _scheduleDraftPersist(state);
    await _refreshTreeQuietly(state);
  }

  /// Renames/moves a file or folder on the server; open tabs and drafts
  /// follow it. Returns false (no request) for an unusable [toRaw].
  Future<bool> renameStudioPath(
      String sessionId, String from, String toRaw) async {
    final to = normalizeStudioPath(toRaw);
    if (to == null || to == from) return false;
    final state = _stateFor(sessionId);
    await _files.movePath(sessionId, from, to);
    String moved(String p) => p == from ? to : '$to${p.substring(from.length)}';
    for (final p in _pathsUnder(state, from)) {
      _rekey(state, p, moved(p));
    }
    _publish(state);
    _scheduleDraftPersist(state);
    await _refreshTreeQuietly(state);
    return true;
  }

  /// Creates a folder. Returns false (no request) for an unusable path.
  Future<bool> createStudioFolder(String sessionId, String rawPath) async {
    final path = normalizeStudioPath(rawPath, allowTrailingSlash: true);
    if (path == null) return false;
    final state = _stateFor(sessionId);
    await _files.makeDir(sessionId, path);
    await _refreshTreeQuietly(state);
    return true;
  }

  Set<String> _pathsUnder(_SessionStudioState state, String path) => {
        for (final p in <String>{
          ...state.fileBuffer.keys,
          ...state.openFiles,
          ...state.dirty,
        })
          if (p == path || p.startsWith('$path/')) p,
      };

  void _forget(_SessionStudioState state, String path) {
    state.fileBuffer.remove(path);
    state.openFiles.remove(path);
    state.baselines.remove(path);
    state.savedContent.remove(path);
    state.dirty.remove(path);
    state.conflicts.remove(path);
    state.conflictHashes.remove(path);
    state.guards.remove(path);
    state.newFiles.remove(path);
    state.pendingSaves.remove(path);
    if (state.activeFilePath == path) {
      state.activeFilePath =
          state.openFiles.isEmpty ? null : state.openFiles.last;
    }
  }

  void _rekey(_SessionStudioState state, String from, String to) {
    void move<V>(Map<String, V> map) {
      if (map.containsKey(from)) map[to] = map.remove(from) as V;
    }

    void moveSet(Set<String> set) {
      if (set.remove(from)) set.add(to);
    }

    move(state.fileBuffer);
    move(state.baselines);
    move(state.savedContent);
    move(state.conflicts);
    move(state.conflictHashes);
    move(state.guards);
    moveSet(state.dirty);
    moveSet(state.newFiles);
    moveSet(state.pendingSaves);
    final index = state.openFiles.indexOf(from);
    if (index >= 0) state.openFiles[index] = to;
    if (state.activeFilePath == from) state.activeFilePath = to;
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

  /// Closes a tab. A clean buffer is dropped, so reopening the file reads the
  /// server's current bytes (ST-006); a draft keeps its buffer.
  void closeStudioFile(String sessionId, String path) {
    final state = _stateFor(sessionId);
    state.openFiles.remove(path);
    if (state.activeFilePath == path) {
      state.activeFilePath =
          state.openFiles.isEmpty ? null : state.openFiles.last;
    }
    if (!isStudioFileDirty(sessionId, path)) _forget(state, path);
    _publish(state);
  }

  void discardStudioDraft(String sessionId, String path) {
    final state = _stateFor(sessionId);
    if (state.newFiles.contains(path)) {
      // Nothing on the server to fall back to: the unsaved file goes away.
      _forget(state, path);
      _publish(state);
      _scheduleDraftPersist(state);
      return;
    }
    final saved = state.conflicts.remove(path) ?? state.savedContent[path];
    if (saved != null) {
      state.fileBuffer[path] = saved;
      state.savedContent[path] = saved;
    }
    state.dirty.remove(path);
    state.pendingSaves.remove(path);
    _publish(state);
    _scheduleDraftPersist(state);
  }

  void discardAllStudioDrafts(String sessionId) {
    final state = _stateFor(sessionId);
    for (final path in state.dirty.toList()) {
      if (state.newFiles.contains(path)) {
        _forget(state, path);
        continue;
      }
      final saved = state.conflicts.remove(path) ?? state.savedContent[path];
      if (saved != null) {
        state.fileBuffer[path] = saved;
        state.savedContent[path] = saved;
      }
      state.dirty.remove(path);
      state.pendingSaves.remove(path);
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
      state.cancelTimers();
      state.fileBuffer.clear();
      state.openFiles.clear();
      state.activeFilePath = null;
      state.baselines.clear();
      state.savedContent.clear();
      state.dirty.clear();
      state.conflicts.clear();
      state.conflictHashes.clear();
      state.guards.clear();
      state.newFiles.clear();
      state.saving.clear();
      state.pendingSaves.clear();
      state.snapshot = null;
      state.treeLoading = false;
      state.treeFailure = null;
      state.waking = false;
      state.wakeTimedOut = false;
      state.wakeStartedAt = null;
      state.subtreeLoading.clear();
      state.subtreeLoaded.clear();
      state.tabs.value = StudioTabsState.empty;
    }
    unawaited(_drafts.deleteAll('editor_'));
    notifyListeners();
  }

  bool get noDrafts => _sessions.values.every(
      (state) => !state.dirty.any(state.fileBuffer.containsKey));

  @override
  void dispose() {
    for (final state in _sessions.values) {
      state.cancelTimers();
    }
    super.dispose();
  }

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
                if (state.newFiles.contains(path)) 'new': true,
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
      // ST-017: a buffer opened or typed while the restore was reading the
      // disk is newer than the persisted draft — never clobber it.
      if (state.fileBuffer.containsKey(path)) continue;
      state.fileBuffer[path] = draft;
      final baseline = value['baseline'];
      if (baseline is String) state.savedContent[path] = baseline;
      final hash = value['hash'];
      if (hash is String) state.baselines[path] = hash;
      if (value['new'] == true) state.newFiles.add(path);
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
