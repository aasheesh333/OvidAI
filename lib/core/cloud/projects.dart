import 'package:flutter/foundation.dart';

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

  /// Process-wide default (the sidebar's controller).
  static ProjectsController get I => _instance ??= ProjectsController();

  @visibleForTesting
  static void installForTest(ProjectsController controller) =>
      _instance = controller;

  @visibleForTesting
  static void resetForTest() => _instance = null;

  List<ProjectDto> _projects = const <ProjectDto>[];
  bool _loading = false;
  bool _loadedOnce = false;
  String? _error;

  List<ProjectDto> get projects => List<ProjectDto>.unmodifiable(_projects);
  bool get loading => _loading;
  bool get loadedOnce => _loadedOnce;
  String? get error => _error;

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
      _projects = await _rest.listProjects();
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
      );
}
