import 'package:flutter/material.dart';

import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to ARB keys in the localization pass.

/// The two kinds of context a composer can reference with `@`.
enum V2MentionKind { session, project }

/// One row in the `@` suggestion list.
///
/// [token] is what gets inserted into the draft: `@[Title] ` for a chat and
/// `@project:<id> ` for a project (the same wire format the legacy composer
/// and the gateway already understand).
@immutable
class V2MentionCandidate {
  const V2MentionCandidate.session({
    required this.id,
    required this.title,
    required this.subtitle,
  }) : kind = V2MentionKind.session;

  const V2MentionCandidate.project({
    required this.id,
    required this.title,
    this.subtitle = 'Project',
  }) : kind = V2MentionKind.project;

  final V2MentionKind kind;
  final String id;
  final String title;
  final String subtitle;

  bool get isProject => kind == V2MentionKind.project;

  IconData get icon =>
      isProject ? Icons.folder_outlined : Icons.chat_bubble_outline_rounded;

  String get token => isProject
      ? '@project:$id '
      : '@[${V2MentionTokens.sanitizeTitle(title)}] ';
}

/// Token parsing and formatting shared by the menu and the send path.
abstract final class V2MentionTokens {
  /// Titles travel inside `@[...]`, so brackets and newlines cannot survive.
  static String sanitizeTitle(String title) => title
      .replaceAll(RegExp(r'[\[\]\r\n]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static final RegExp sessionTag = RegExp(r'@\[([^\]\n]{1,120})\]');
  static final RegExp sessionIdTag = RegExp(r'@session:([A-Za-z0-9_\-]{1,80})');
  static final RegExp projectIdTag = RegExp(r'@project:([A-Za-z0-9_\-]{1,80})');

  /// Whether [text] still contains the session tag inserted for [title].
  static bool containsSessionTitle(String text, String title) {
    final clean = sanitizeTitle(title).toLowerCase();
    if (clean.isEmpty) return false;
    for (final match in sessionTag.allMatches(text)) {
      if (match.group(1)!.trim().toLowerCase() == clean) return true;
    }
    return false;
  }
}

/// The `@token` currently under the caret, if any.
@immutable
class V2ActiveMention {
  const V2ActiveMention({
    required this.start,
    required this.end,
    required this.query,
  });

  /// Offset of the `@` in the draft.
  final int start;

  /// Caret offset (exclusive end of the query).
  final int end;

  /// Text between `@` and the caret.
  final String query;
}

/// Finds the `@` token under a collapsed [selection].
V2ActiveMention? v2ActiveMention(String text, TextSelection selection) {
  if (!selection.isValid || !selection.isCollapsed) return null;
  return v2ActiveMentionAt(text, selection.baseOffset);
}

/// Finds the `@` token that ends at [caret].
///
/// A token starts at an `@` that is the first character or follows whitespace,
/// and runs to the caret without any whitespace. Anything longer than
/// [maxQueryLength] is treated as ordinary prose, not a mention.
V2ActiveMention? v2ActiveMentionAt(
  String text,
  int caret, {
  int maxQueryLength = 60,
}) {
  if (caret < 0 || caret > text.length) return null;
  var index = caret - 1;
  while (index >= 0) {
    final char = text[index];
    if (char == '@') {
      final atBoundary = index == 0 || _isWhitespace(text[index - 1]);
      if (!atBoundary) return null;
      final query = text.substring(index + 1, caret);
      if (query.length > maxQueryLength) return null;
      return V2ActiveMention(start: index, end: caret, query: query);
    }
    if (_isWhitespace(char)) return null;
    index--;
  }
  return null;
}

bool _isWhitespace(String char) => char.trim().isEmpty;

/// Supplies the rows for the `@` menu.
///
/// The production default ([V2AppMentionSource]) reads the live root sessions
/// and projects. Tests inject [V2StaticMentionSource] (or any fake) so the
/// composer stays deterministic.
abstract class V2MentionSource {
  /// Rows matching [query], at most [limit] (the composer caps at five).
  List<V2MentionCandidate> search(String query, {int limit = 5});

  /// Resolves a manually typed `@[Title]` back to a session id.
  String? sessionIdForTitle(String title) => null;
}

/// The live source is installed by `lib/ui/v2/app/mention_source_live.dart`
/// (or by a test) so this library has no `core/` import and can compile for
/// web. When null, typing `@` simply shows no suggestions.
V2MentionSource? v2DefaultMentionSource;

/// Maps a chat's local id to the id the gateway accepts.
///
/// Root chats are keyed locally (`ChatSession.id`), but `runTask` forwards
/// `sessionRefs` to the server, which only knows the cloud session id. The host
/// installs this alongside [v2DefaultMentionSource] (for example
/// `CloudSessionStore.I.knownServerIdFor`). Null keeps ids unchanged so
/// previews and widget tests stay deterministic.
String Function(String localSessionId)? v2SessionRefResolver;

/// Used when no source is installed: no suggestions, no typed-title lookup.
class V2EmptyMentionSource implements V2MentionSource {
  const V2EmptyMentionSource();

  @override
  List<V2MentionCandidate> search(String query, {int limit = 5}) => const [];

  @override
  String? sessionIdForTitle(String title) => null;
}

/// Deterministic source for tests and previews.
class V2StaticMentionSource implements V2MentionSource {
  V2StaticMentionSource({
    List<V2MentionCandidate> sessions = const [],
    List<V2MentionCandidate> projects = const [],
  }) : _sessions = List.unmodifiable(sessions),
       _projects = List.unmodifiable(projects);

  final List<V2MentionCandidate> _sessions;
  final List<V2MentionCandidate> _projects;

  @override
  List<V2MentionCandidate> search(String query, {int limit = 5}) =>
      rankV2Mentions(_sessions, _projects, query, limit: limit);

  @override
  String? sessionIdForTitle(String title) {
    final wanted = V2MentionTokens.sanitizeTitle(title).toLowerCase();
    for (final session in _sessions) {
      if (V2MentionTokens.sanitizeTitle(session.title).toLowerCase() ==
          wanted) {
        return session.id;
      }
    }
    return null;
  }
}

/// Ranks sessions and projects for [query].
///
/// * `@project:foo` searches projects only.
/// * An empty query shows the three newest chats plus up to two projects, so
///   projects stay discoverable.
/// * Any other query matches titles/names by prefix first, then substring,
///   with chats ahead of projects on ties.
List<V2MentionCandidate> rankV2Mentions(
  List<V2MentionCandidate> sessions,
  List<V2MentionCandidate> projects,
  String query, {
  int limit = 5,
}) {
  final cap = limit < 1 ? 1 : limit;
  final raw = query.trim();
  final lower = raw.toLowerCase();
  final wantsProjects = lower.startsWith('project:');
  if (wantsProjects) {
    final projectQuery = raw.substring('project:'.length).trim().toLowerCase();
    return _matches(projects, projectQuery, cap);
  }
  if (lower.isEmpty) {
    // Three newest chats, then projects, then the rest of the chats. This
    // keeps chats first while leaving project rows visible without scrolling.
    final out = <V2MentionCandidate>[
      ...sessions.take(3),
      ...projects.take(cap - (sessions.length < 3 ? sessions.length : 3)),
      ...sessions.skip(3),
    ];
    return out.take(cap).toList(growable: false);
  }
  final scored = <({int score, int order, V2MentionCandidate candidate})>[];
  var order = 0;
  void add(V2MentionCandidate candidate) {
    final score = _score(candidate.title, lower);
    if (score == null) return;
    scored.add((score: score, order: order++, candidate: candidate));
  }

  for (final session in sessions) {
    add(session);
  }
  for (final project in projects) {
    add(project);
  }
  scored.sort((a, b) {
    final byScore = a.score.compareTo(b.score);
    return byScore != 0 ? byScore : a.order.compareTo(b.order);
  });
  return [for (final row in scored.take(cap)) row.candidate];
}

List<V2MentionCandidate> _matches(
  List<V2MentionCandidate> rows,
  String query,
  int cap,
) {
  final scored = <({int score, int order, V2MentionCandidate candidate})>[];
  var order = 0;
  for (final row in rows) {
    final score = _score(row.title, query);
    if (score == null) continue;
    scored.add((score: score, order: order++, candidate: row));
  }
  scored.sort((a, b) {
    final byScore = a.score.compareTo(b.score);
    return byScore != 0 ? byScore : a.order.compareTo(b.order);
  });
  return [for (final row in scored.take(cap)) row.candidate];
}

/// Lower is better; null means "no match".
int? _score(String title, String query) {
  final lower = title.toLowerCase();
  if (query.isEmpty) return 0;
  if (lower.startsWith(query)) return 0;
  final at = lower.indexOf(query);
  if (at < 0) return null;
  return 1 + at;
}

/// Compact suggestion list shown directly above the composer.
class V2MentionSuggestions extends StatelessWidget {
  const V2MentionSuggestions({
    super.key,
    required this.candidates,
    required this.onSelect,
  });

  final List<V2MentionCandidate> candidates;
  final ValueChanged<V2MentionCandidate> onSelect;

  /// Tall enough for ~4 rows at 200 % text, short enough to leave the
  /// transcript room on a 320 × 640 screen.
  static const double maxHeight = 264;

  @override
  Widget build(BuildContext context) {
    if (candidates.isEmpty) return const SizedBox.shrink();
    final c = OColors.of(context);
    // Keep the menu compact on short screens so it never hides the whole
    // transcript; it scrolls inside the cap at 200 % text.
    final screenHeight = MediaQuery.sizeOf(context).height;
    final height = (screenHeight * 0.3).clamp(160.0, maxHeight).toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.xs),
      child: Container(
        constraints: BoxConstraints(maxHeight: height),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(ORadius.xl),
          border: Border.all(color: c.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          container: true,
          label: 'Mention suggestions',
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: OSpace.xs),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final candidate in candidates)
                  _MentionRow(
                    key: ValueKey(
                      'mention-${candidate.kind.name}-${candidate.id}',
                    ),
                    candidate: candidate,
                    onTap: () => onSelect(candidate),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MentionRow extends StatelessWidget {
  const _MentionRow({super.key, required this.candidate, required this.onTap});

  final V2MentionCandidate candidate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: 'Mention ${candidate.title}. ${candidate.subtitle}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: OSpace.touch),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: OSpace.m,
                vertical: OSpace.s,
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: c.surfaceAlt,
                      borderRadius: BorderRadius.circular(ORadius.s),
                    ),
                    child: Icon(candidate.icon, size: 18, color: c.accent),
                  ),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          candidate.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.bodySm.copyWith(
                            color: c.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          candidate.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: OSpace.s),
                  Icon(Icons.add_rounded, size: 18, color: c.textFaint),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Session/project ids referenced by a draft.
@immutable
class V2MentionRefs {
  const V2MentionRefs({
    this.sessionRefs = const [],
    this.projectRefs = const [],
  });

  final List<String> sessionRefs;
  final List<String> projectRefs;

  static const int maxRefs = 5;
}

/// Resolves the ids a draft references.
///
/// Picked rows are remembered in [pickedSessionIds] (lower-case title → id)
/// and [pickedProjectIds]; manually typed tags fall back to [source].
V2MentionRefs v2MentionRefsIn(
  String text, {
  required V2MentionSource source,
  Map<String, String> pickedSessionIds = const {},
  Set<String> pickedProjectIds = const {},
  String? currentSessionId,
}) {
  final sessions = <String>[];
  void addSession(String? id) {
    if (id == null || id.isEmpty) return;
    if (id == currentSessionId) return;
    final resolved = v2SessionRefResolver?.call(id) ?? id;
    if (resolved.isEmpty || resolved == currentSessionId) return;
    if (sessions.contains(resolved)) return;
    if (sessions.length >= V2MentionRefs.maxRefs) return;
    sessions.add(resolved);
  }

  for (final match in V2MentionTokens.sessionIdTag.allMatches(text)) {
    addSession(match.group(1)!.trim());
  }
  for (final match in V2MentionTokens.sessionTag.allMatches(text)) {
    final title = match.group(1)!.trim();
    final key = V2MentionTokens.sanitizeTitle(title).toLowerCase();
    addSession(pickedSessionIds[key] ?? source.sessionIdForTitle(title));
  }
  for (final entry in pickedSessionIds.entries) {
    if (V2MentionTokens.containsSessionTitle(text, entry.key)) {
      addSession(entry.value);
    }
  }

  final projects = <String>[];
  void addProject(String? id) {
    if (id == null || id.isEmpty) return;
    if (projects.contains(id)) return;
    if (projects.length >= V2MentionRefs.maxRefs) return;
    projects.add(id);
  }

  for (final match in V2MentionTokens.projectIdTag.allMatches(text)) {
    addProject(match.group(1)!.trim());
  }
  for (final id in pickedProjectIds) {
    if (text.contains('@project:$id')) addProject(id);
  }
  return V2MentionRefs(
    sessionRefs: List.unmodifiable(sessions),
    projectRefs: List.unmodifiable(projects),
  );
}
