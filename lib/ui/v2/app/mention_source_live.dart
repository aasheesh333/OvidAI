import '../../../core/cloud/projects.dart';
import '../../../core/state.dart';
import '../chat/composer_mentions.dart';

/// Live source: root chats from `AppState` and projects from
/// `ProjectsController`. Installed by the shell.
class V2AppMentionSource implements V2MentionSource {
  const V2AppMentionSource();

  @override
  List<V2MentionCandidate> search(String query, {int limit = 5}) {
    final app = AppState.I;
    final current = app.activeSessionId;
    final sessions = <V2MentionCandidate>[
      for (final session in app.rootSessionsByRecency)
        if (session.id != current && session.title.trim().isNotEmpty)
          V2MentionCandidate.session(
            id: session.id,
            title: session.title,
            subtitle: _modelLabel(session.model),
          ),
    ];
    final projects = <V2MentionCandidate>[
      for (final project in ProjectsController.I.projects)
        V2MentionCandidate.project(
          id: project.id,
          title: project.name,
          subtitle: _projectSubtitle(project.sessionCount),
        ),
    ];
    return rankV2Mentions(sessions, projects, query, limit: limit);
  }

  @override
  String? sessionIdForTitle(String title) {
    final wanted = V2MentionTokens.sanitizeTitle(title).toLowerCase();
    if (wanted.isEmpty) return null;
    for (final session in AppState.I.rootSessionsByRecency) {
      if (V2MentionTokens.sanitizeTitle(session.title).toLowerCase() ==
          wanted) {
        return session.id;
      }
    }
    return null;
  }

  static String _modelLabel(String model) {
    final raw = model.trim();
    if (raw.isEmpty || raw == 'Select a provider') return 'Auto';
    if (raw.toLowerCase() == 'auto') return 'Auto';
    return raw;
  }

  static String _projectSubtitle(int count) =>
      count == 1 ? 'Project · 1 chat' : 'Project · $count chats';
}

