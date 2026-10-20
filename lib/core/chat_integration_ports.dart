/// W9 (chat UX) integration ports.
///
/// `chat_screen.dart` is the single writer surface for the chat composer, the
/// header ⋮ menu and the STUDIO repo/branch gate. Several of those controls
/// are owned by other workstreams:
///
/// * **W1 Projects** owns the `projects` table, project memory and the
///   pinned-session flag.
/// * **W3 Studio GitHub** owns repository/branch discovery, cloning and the
///   "sync latest changes" action.
///
/// W9 must not edit their files, so both features are consumed through the
/// small ports below. A workstream installs its implementation once at boot:
///
/// ```dart
/// ProjectsPort.instance = ProjectsController(...);
/// StudioBindingPort.instance = StudioGitHubController(...);
/// ```
///
/// When a port is not installed the chat surface stays truthful (R4): the
/// project mentions/menu entries are not offered, and the STUDIO send gate
/// stays closed with a "choose a repo" chip instead of pretending a repo is
/// bound.
library;

import 'package:flutter/foundation.dart';

/// One project row shown by the composer `@` menu and the ⋮ "Add to Project"
/// sheet.
@immutable
class ProjectOption {
  const ProjectOption({
    required this.id,
    required this.name,
    this.sessionCount,
    this.fileCount,
    this.fileCap,
  });

  final String id;
  final String name;
  final int? sessionCount;

  /// Project-memory file usage (W1's per-plan cap), when the server reports it.
  final int? fileCount;
  final int? fileCap;
}

/// Port implemented by W1 (Projects).
///
/// The default `instance` is null. Installing an implementation enables the
/// `@project` mention rows, the ⋮ "Add to Project" item and the ⋮
/// "Pin Session"/"Unpin Session" item.
abstract class ProjectsPort extends ChangeNotifier {
  static ProjectsPort? instance;

  /// Test seam: replaces (or clears) the installed port.
  @visibleForTesting
  static void installForTest(ProjectsPort? port) => instance = port;

  /// True once the project list is loaded and the port can answer reads.
  bool get ready;

  /// True when the gateway accepts `projectRefs` on `POST /sessions/:id/messages`.
  ///
  /// W1's adapter returns **false** until the strict server send schema grows
  /// the optional field (and ownership resolution). While false W9 never
  /// inserts `@project:` tokens or sends `projectRefs`, so a strict gateway
  /// cannot 400 a chat send.
  bool get supportsTurnProjectRefs;

  /// True when [setPinned]/[isPinned] persist. When false the chat surface
  /// falls back to its local [ChatPinsStore] so the menu item still works.
  bool get supportsPin => false;

  /// Projects owned by the signed-in user, in display order.
  List<ProjectOption> get projects;

  /// Whether [sessionId] is pinned in the sidebar.
  bool isPinned(String sessionId);

  /// Moves [sessionId] into [projectId] (or removes it when null).
  Future<void> addSessionToProject(String sessionId, String? projectId);

  /// Pins or unpins [sessionId].
  Future<void> setPinned(String sessionId, bool pinned);

  /// The composer token inserted for an explicit project reference.
  String mentionToken(ProjectOption project) => '@project:${project.id} ';

  /// Project ids explicitly tagged in [text] for THIS turn only (R1).
  ///
  /// Fail-safe parsing for the strict server contract (W1b):
  /// * only `@project:<uuid>` tokens are considered (malformed tokens are
  ///   dropped, never forwarded);
  /// * duplicates are collapsed (the server rejects duplicates with a 400);
  /// * the list is capped at [maxTurnProjectRefs] (the server's max);
  /// * ids not in the loaded [projects] list are dropped, so a stale or
  ///   foreign token cannot produce a 400 that would refuse the whole send.
  ///
  /// When [supportsTurnProjectRefs] is false the result is always empty, so
  /// an older gateway never receives the field.
  List<String> projectRefsIn(String text) {
    if (!supportsTurnProjectRefs) return const <String>[];
    final known = {for (final p in projects) p.id};
    if (known.isEmpty) return const <String>[];
    final refs = <String>[];
    for (final match in turnProjectToken.allMatches(text)) {
      final id = match.group(1)!;
      if (!uuidPattern.hasMatch(id)) continue;
      if (!known.contains(id)) continue;
      if (refs.contains(id)) continue;
      refs.add(id);
      if (refs.length >= maxTurnProjectRefs) break;
    }
    return refs;
  }

  /// The server's per-turn project-ref cap (shared/src/rest.ts).
  static const int maxTurnProjectRefs = 5;

  /// `@project:<id>` tokens; the id is validated separately.
  static final RegExp turnProjectToken = RegExp(r'@project:([^\s\[\]()]+)');

  static final RegExp uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
}

/// A resolved repo/branch binding for one chat.
@immutable
class StudioBinding {
  const StudioBinding({required this.repo, required this.branch});

  /// `owner/name` (or a full clone URL).
  final String repo;
  final String branch;

  bool get ready => repo.trim().isNotEmpty && branch.trim().isNotEmpty;
}

/// Port implemented by W3 (Studio GitHub).
///
/// The default `instance` is null. Installing an implementation enables the
/// repo/branch picker and the "Sync latest changes" action; the STUDIO send
/// gate reads [bindingFor].
abstract class StudioBindingPort extends ChangeNotifier {
  static StudioBindingPort? instance;

  /// Test seam: replaces (or clears) the installed port.
  @visibleForTesting
  static void installForTest(StudioBindingPort? port) => instance = port;

  /// True once OAuth/repo discovery is usable.
  bool get ready;

  /// The binding the agent will use for [sessionId], or null when the chat
  /// still needs a repo/branch selection.
  StudioBinding? bindingFor(String sessionId);

  /// Repositories the user can bind (newest/most-used first).
  Future<List<String>> listRepos();

  /// Branches available in [repo].
  Future<List<String>> listBranches(String repo);

  /// Binds [repo] + [branch] to [sessionId] (clone/sync is W3's job).
  Future<void> bind(
    String sessionId, {
    required String repo,
    required String branch,
  });

  /// Runs `git fetch && git status` for the binding before the next task.
  Future<void> syncLatest(String sessionId);

  /// True while [syncLatest] runs for [sessionId].
  bool syncingFor(String sessionId) => false;
}
