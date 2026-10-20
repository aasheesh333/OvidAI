import 'package:flutter/foundation.dart';

import '../chat_integration_ports.dart';
import '../chat_pins.dart';
import '../state.dart';
import 'cloud_rest.dart';
import 'models.dart';

/// W1 Projects controller — the sidebar's source of truth for project rows.
///
/// It owns only server-backed project state: the list (with live session and
/// memory-file counts), create/rename/delete, and moving a chat in or out of
/// a project. Moving a chat also updates the local [ChatSession.projectId] so
/// the sidebar regroups immediately, before the next reconciliation.
class ProjectsController extends ChangeNotifier {
  ProjectsController({CloudRestClient? rest})
      : _rest = rest ?? CloudRestClient.I;

  final CloudRestClient _rest;

  static ProjectsController? _instance;

  /// Process-wide default (the sidebar's controller). Installing the chat
  /// integration port here is what makes the composer `@project:` rows and
  /// `CloudTurnOptions.projectRefs` live; W9's chat surface reads the port.
  static ProjectsController get I {
    final controller = _instance ??= ProjectsController();
    ProjectsPort.instance ??= ProjectsPortAdapter(controller);
    return controller;
  }

  @visibleForTesting
  static void installForTest(ProjectsController controller) =>
      _instance = controller;

  @visibleForTesting
  static void resetForTest() => _instance = null;

  List<ProjectDto> _projects = const <ProjectDto>[];
  bool _loading = false;
  bool _loadedOnce = false;
  bool _serverTurnProjectRefs = false;
  String? _error;

  List<ProjectDto> get projects => List<ProjectDto>.unmodifiable(_projects);
  bool get loading => _loading;
  bool get loadedOnce => _loadedOnce;
  String? get error => _error;

  /// True only after a successful `GET /projects` whose payload advertises
  /// `capabilities.turnProjectRefs`. Defaults to false: an older gateway (or
  /// an offline start) never receives `projectRefs`, so its strict send body
  /// cannot 400 a chat send.
  bool get serverSupportsTurnProjectRefs => _serverTurnProjectRefs;

  ProjectDto? byId(String id) {
    for (final project in _projects) {
      if (project.id == id) return project;
    }
    return null;
  }

  /// Re-reads `GET /projects`. A failure keeps the last good list and
  /// exposes [error]; it never throws into the sidebar.
  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final payload = await _rest.listProjectsPayload();
      _projects = payload.items;
      _serverTurnProjectRefs = payload.turnProjectRefs;
      _loadedOnce = true;
    } on CloudApiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = 'Could not load projects.';
      debugPrint('projects.refresh: $e');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<ProjectDto?> create(String name) async {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 80) {
      _error = 'Project names must be 1–80 characters.';
      notifyListeners();
      return null;
    }
    try {
      final created = await _rest.createProject(clean);
      _projects = <ProjectDto>[..._projects, created];
      _error = null;
      notifyListeners();
      return created;
    } on CloudApiException catch (e) {
      _error = e.message;
      notifyListeners();
      return null;
    }
  }

  Future<bool> rename(String id, String name) async {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 80) {
      _error = 'Project names must be 1–80 characters.';
      notifyListeners();
      return false;
    }
    try {
      final updated = await _rest.renameProject(id, clean);
      _projects = <ProjectDto>[
        for (final p in _projects) p.id == id ? updated : p,
      ];
      _error = null;
      notifyListeners();
      return true;
    } on CloudApiException catch (e) {
      _error = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Deletes the project. Chats are detached (history stays) and their local
  /// `projectId` is cleared so the sidebar regroups immediately.
  Future<bool> delete(String id) async {
    try {
      await _rest.deleteProject(id);
      _projects = _projects.where((p) => p.id != id).toList(growable: false);
      for (final session in AppState.I.sessions) {
        if (session.projectId == id) session.projectId = null;
      }
      AppState.I.notifyListeners();
      _error = null;
      notifyListeners();
      return true;
    } on CloudApiException catch (e) {
      _error = e.message;
      notifyListeners();
      return false;
    }
  }

  /// Moves [sessionId] into [projectId], or out of every project with null.
  /// Returns false (with [error]) when the server rejects the move.
  Future<bool> moveSession(String sessionId, String? projectId) async {
    try {
      final session = AppState.I.sessionById(sessionId);
      final previousProjectId = session?.projectId;
      final updated = await _rest.moveSessionToProject(sessionId, projectId);
      if (session != null) {
        session.projectId = updated.projectId;
        AppState.I.notifyListeners();
      }
      // Keep the visible counts honest without a full reload.
      _projects = <ProjectDto>[
        for (final p in _projects)
          if (p.id == previousProjectId && previousProjectId != projectId)
            _withSessionCount(p, p.sessionCount - 1)
          else if (p.id == projectId && previousProjectId != projectId)
            _withSessionCount(p, p.sessionCount + 1)
          else
            p,
      ];
      _error = null;
      notifyListeners();
      return true;
    } on CloudApiException catch (e) {
      _error = e.message;
      notifyListeners();
      return false;
    }
  }

  static ProjectDto _withSessionCount(ProjectDto p, int count) => ProjectDto(
        id: p.id,
        name: p.name,
        createdAt: p.createdAt,
        updatedAt: p.updatedAt,
        sessionCount: count < 0 ? 0 : count,
        fileCount: p.fileCount,
        fileCap: p.fileCap,
        fileBytes: p.fileBytes,
        fileBreakdown: p.fileBreakdown,
      );
}

/// W1 → W9 bridge: exposes [ProjectsController] through the chat integration
/// port so `chat_screen.dart` can offer `@project:` rows and send
/// `projectRefs` without W1 editing the chat surface.
///
/// [supportsTurnProjectRefs] follows the SERVER's advertised capability
/// (`GET /projects` → `capabilities.turnProjectRefs`), not a hard-coded
/// constant: a client that ships before the gateway must not send a field a
/// strict body would reject. `ProjectsPort.projectRefsIn` (base, shared) does
/// the lenient token parsing — malformed/unknown ids dropped, duplicates
/// collapsed, capped at 5 — so a stale composer token cannot turn an
/// otherwise valid send into a 400. The SERVER still validates every ref for
/// direct API callers.
class ProjectsPortAdapter extends ProjectsPort {
  ProjectsPortAdapter(this._controller) {
    _controller.addListener(_onControllerChanged);
    _syncOptions();
  }

  final ProjectsController _controller;

  List<ProjectOption> _options = const <ProjectOption>[];

  void _onControllerChanged() {
    _syncOptions();
    notifyListeners();
  }

  void _syncOptions() {
    _options = <ProjectOption>[
      for (final p in _controller.projects)
        ProjectOption(
          id: p.id,
          name: p.name,
          sessionCount: p.sessionCount,
          fileCount: p.fileCount,
          fileCap: p.fileCap,
        ),
    ];
  }

  @override
  bool get ready => _controller.loadedOnce;

  /// True only once the gateway advertised support (see class docs).
  @override
  bool get supportsTurnProjectRefs => _controller.serverSupportsTurnProjectRefs;

  @override
  List<ProjectOption> get projects => _options;

  /// Pins are backed by W9's account-scoped local store, so they survive a
  /// restart and the chat header glyph reads the same state.
  @override
  bool get supportsPin => true;

  @override
  bool isPinned(String sessionId) => ChatPinsStore.I.isPinned(sessionId);

  @override
  Future<void> setPinned(String sessionId, bool pinned) =>
      ChatPinsStore.I.setPinned(sessionId, pinned);

  @override
  Future<void> addSessionToProject(String sessionId, String? projectId) async {
    await _controller.moveSession(sessionId, projectId);
  }
}
