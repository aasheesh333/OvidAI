import 'dart:async';

import 'chat_integration_ports.dart';
import 'chat_pins.dart';
import 'cloud/projects.dart';
import 'diag.dart';

/// W1 adapter for the chat surface's [ProjectsPort].
///
/// W1 landed `ProjectsController` + `showAddToProjectSheet`; the chat composer
/// only needs a read-only project list plus move/pin calls. This adapter keeps
/// the chat surface on the narrow port while W1 owns the server state.
///
/// * `supportsTurnProjectRefs` follows the gateway's ADVERTISED capability
///   (`GET /projects` → `capabilities.turnProjectRefs`, W1b): a client that
///   ships before the server keeps the feature hidden, so an older strict
///   `sendMessageBodySchema` never sees a `projectRefs` field it would 400.
///   `serverSupportsTurnProjectRefs` is an explicit test override only.
/// * Pinning is still W9-local ([ChatPinsStore]) because W1 does not own a
///   pin flag; `supportsPin` therefore stays false and the overflow menu
///   writes the local store.
class ProjectsControllerPort extends ProjectsPort {
  ProjectsControllerPort({ProjectsController? controller})
      : _controller = controller ?? ProjectsController.I;

  final ProjectsController _controller;

  @override
  bool get ready => _controller.loadedOnce;

  /// Explicit override for tests. `null` (production) follows the gateway's
  /// advertised `capabilities.turnProjectRefs` — never a hard-coded `true`,
  /// so an older server cannot receive a field its strict body rejects.
  static bool? serverSupportsTurnProjectRefs;

  @override
  bool get supportsTurnProjectRefs =>
      serverSupportsTurnProjectRefs ??
      _controller.serverSupportsTurnProjectRefs;

  @override
  List<ProjectOption> get projects => [
    for (final p in _controller.projects)
      ProjectOption(
        id: p.id,
        name: p.name,
        sessionCount: p.sessionCount,
        fileCount: p.fileCount,
        fileCap: p.fileCap,
      ),
  ];

  @override
  bool isPinned(String sessionId) => ChatPinsStore.I.isPinned(sessionId);

  @override
  Future<void> addSessionToProject(String sessionId, String? projectId) async {
    final ok = await _controller.moveSession(sessionId, projectId);
    if (!ok) {
      throw StateError(
        _controller.error ?? 'The chat could not be moved to that project.',
      );
    }
  }

  @override
  Future<void> setPinned(String sessionId, bool pinned) =>
      ChatPinsStore.I.setPinned(sessionId, pinned);

  /// Installs the adapter once and starts the project list loading.
  ///
  /// Safe to call from any screen mount: an explicitly installed port (a
  /// test fake) is never replaced, and the controller's own `refresh` is
  /// idempotent while a load is in flight.
  static ProjectsPort ensureInstalled() {
    final existing = ProjectsPort.instance;
    if (existing != null) return existing;
    final port = ProjectsControllerPort();
    ProjectsPort.instance = port;
    if (!ProjectsController.I.loadedOnce) {
      unawaited(ProjectsController.I.refresh().catchError((Object e) {
        Diag.swallow('chat.projectsBoot', e);
      }));
    }
    return port;
  }
}
