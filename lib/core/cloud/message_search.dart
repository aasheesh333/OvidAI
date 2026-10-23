/// Message search over the gateway — `GET /cloud/v1/search/messages`.
///
/// The gateway owns the whole search: the FTS match, the cover-density
/// ranking, the `ts_headline` snippet, the limit/offset clamps, and — the part
/// this client must never recreate — the `sessions.user_id` join that scopes
/// every row to the bearer token. So this file is a thin reader of that page,
/// not a second search engine.
///
/// Three gateway behaviours shape the callers:
///
///   - a blank `q` answers an empty page, never an error. The sidebar still
///     sends nothing while the box is empty, because a request that can only
///     return nothing is not worth sending.
///   - a `sessionId` the caller does not own answers an empty page, not a 404.
///     Existence is not leaked, so it is not distinguished here either.
///   - `limit` and `offset` are clamped by the server. This client sends them
///     only when a caller asks, so the gateway's own defaults apply rather
///     than a page size guessed on the device.
///
/// The snippet arrives as Postgres `ts_headline` output: each matched run sits
/// between `→` and `←`, and everything around it is the message's own text.
/// [parseSnippet] turns that into plain segments — never an HTML string — so a
/// message containing markup is still drawn as text.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cloud_rest.dart';

/// The snippet markers `@ovid/db` passes to `ts_headline`.
const String kSnippetOpen = '→';
const String kSnippetClose = '←';

/// The gateway's own default page size, kept here for documentation only:
/// callers omit `limit` and let the server decide.
const int messageSearchDefaultLimit = 30;

/// The gateway's clamp. A caller asking for more gets 100 rows, never an error.
const int messageSearchMaxLimit = 100;

/// One settled search per pause, not one per keystroke.
const Duration messageSearchDebounce = Duration(milliseconds: 300);

/// Outer whitespace is not a search term. Inner spacing is left alone: a
/// quoted phrase (`"red  fox"`) is gateway syntax.
String normalizeMessageSearchQuery(String raw) => raw.trim();

/// Whether this query is worth a request. A blank box is idle, not "no
/// results".
bool shouldSearchMessages(String raw) =>
    normalizeMessageSearchQuery(raw).isNotEmpty;

/// The four roles the gateway's message table writes, as a person reads them.
/// An unknown role still reads as a message; inventing one would claim
/// something the gateway did not say.
String messageRoleLabel(String? role) => switch (role) {
  'user' => 'You',
  'assistant' => 'Assistant',
  'system' => 'System',
  'tool' => 'Tool',
  _ => 'Message',
};

/// One run of snippet text. [highlight] is true for the words the server
/// wrapped in the marker pair.
@immutable
class SnippetSegment {
  const SnippetSegment(this.text, {required this.highlight});

  final String text;
  final bool highlight;

  @override
  bool operator ==(Object other) =>
      other is SnippetSegment &&
      other.text == text &&
      other.highlight == highlight;

  @override
  int get hashCode => Object.hash(text, highlight);

  @override
  String toString() => 'SnippetSegment(${highlight ? '+' : '-'}$text)';
}

/// Turn one `ts_headline` snippet into text segments.
///
/// Whitespace is collapsed first: the server preserves the message's own
/// newlines and a drawer row is one line. A marker with no partner is dropped
/// rather than rendered — the server should pair them, but a malformed snippet
/// must not put a stray arrow in someone's search result.
///
/// [open] and [close] exist for the on-device index, which uses its own marker
/// pair; the default is the gateway's.
List<SnippetSegment> parseSnippet(
  String raw, {
  String open = kSnippetOpen,
  String close = kSnippetClose,
}) {
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return const <SnippetSegment>[];
  if (open.isEmpty || close.isEmpty) {
    return <SnippetSegment>[SnippetSegment(text, highlight: false)];
  }
  final openRune = open.runes.first;
  final closeRune = close.runes.first;
  final segments = <SnippetSegment>[];
  final buffer = StringBuffer();
  var highlight = false;

  void flush() {
    if (buffer.isEmpty) return;
    segments.add(SnippetSegment(buffer.toString(), highlight: highlight));
    buffer.clear();
  }

  for (final rune in text.runes) {
    if (rune == openRune || rune == closeRune) {
      flush();
      highlight = rune == openRune;
      continue;
    }
    buffer.writeCharCode(rune);
  }
  flush();
  return segments;
}

/// One ranked message, already parsed for rendering.
///
/// [messageId], [sessionId], [rank] and the page's counts are nullable on
/// purpose: an on-device hit has no server id and no server ranking, and a
/// malformed answer may omit a field. Unknown values render as `—`; they are
/// never coerced to zero.
@immutable
class MessageSearchHit {
  const MessageSearchHit({
    this.messageId,
    this.sessionId,
    this.role,
    this.rank,
    this.snippet = const <SnippetSegment>[],
  });

  factory MessageSearchHit.fromJson(Map<String, dynamic> json) {
    final rawSnippet = json['snippet'];
    final rawRank = json['rank'];
    return MessageSearchHit(
      messageId: _string(json['messageId']),
      sessionId: _string(json['sessionId']),
      role: _string(json['role']),
      rank: rawRank is num && rawRank.isFinite ? rawRank.toDouble() : null,
      snippet: parseSnippet(rawSnippet is String ? rawSnippet : ''),
    );
  }

  final String? messageId;
  final String? sessionId;
  final String? role;
  final double? rank;
  final List<SnippetSegment> snippet;

  /// The plain text of the snippet, for a spoken label.
  String get snippetText => snippet.map((segment) => segment.text).join();

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// One page exactly as the route sends it. `total` is the count over the same
/// filter; it is null when the answer did not carry a usable number.
@immutable
class MessageSearchPage {
  const MessageSearchPage({
    this.items = const <MessageSearchHit>[],
    this.total,
    this.limit,
    this.offset,
  });

  /// The blank-query answer: an empty page, never an error.
  const MessageSearchPage.empty({this.limit, this.offset})
    : items = const <MessageSearchHit>[],
      total = 0;

  factory MessageSearchPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return MessageSearchPage(
      items: <MessageSearchHit>[
        if (rawItems is List)
          for (final item in rawItems)
            if (item is Map)
              MessageSearchHit.fromJson(Map<String, dynamic>.from(item)),
      ],
      total: _count(json['total']),
      limit: _count(json['limit']),
      offset: _count(json['offset']),
    );
  }

  final List<MessageSearchHit> items;
  final int? total;
  final int? limit;
  final int? offset;

  /// A count is known only when the answer carried a non-negative number.
  static int? _count(Object? value) {
    if (value is! num || !value.isFinite) return null;
    if (value < 0) return null;
    return value.toInt();
  }
}

/// The one thing a controller needs from the wire, so tests can answer without
/// a socket.
abstract class MessageSearchSource {
  Future<MessageSearchPage> search(
    String query, {
    int? limit,
    int? offset,
    String? sessionId,
  });
}

/// Reads one page from the gateway.
///
/// There is deliberately no `userId` parameter anywhere: the route scopes the
/// search from the bearer token. A client-supplied owner would be a transcript
/// leak with extra steps.
class MessageSearchClient implements MessageSearchSource {
  MessageSearchClient({CloudRestClient? rest})
    : _rest = rest ?? CloudRestClient.I;

  final CloudRestClient _rest;

  @override
  Future<MessageSearchPage> search(
    String query, {
    int? limit,
    int? offset,
    String? sessionId,
  }) async {
    final normalized = normalizeMessageSearchQuery(query);
    // The gateway treats this as an empty page; not sending it at all keeps a
    // blank box from becoming traffic.
    if (normalized.isEmpty) {
      return MessageSearchPage.empty(limit: limit, offset: offset);
    }
    final json = await _rest.getJson(
      '/search/messages',
      query: <String, String>{
        'q': normalized,
        if (limit != null) 'limit': '$limit',
        if (offset != null) 'offset': '$offset',
        if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      },
    );
    return MessageSearchPage.fromJson(json);
  }
}

/// The settled states of one search.
///
/// [idle] and [empty] are deliberately distinct: a blank box has asked no
/// question, so the drawer shows no "no results" line at all; a real query
/// that matched nothing gets one.
enum MessageSearchStatus { idle, loading, empty, error, content }

/// What the drawer draws for the current query.
@immutable
class MessageSearchState {
  const MessageSearchState({
    required this.status,
    this.query = '',
    this.hits = const <MessageSearchHit>[],
    this.total,
    this.local = false,
    this.error,
  });

  static const MessageSearchState idle = MessageSearchState(
    status: MessageSearchStatus.idle,
  );

  final MessageSearchStatus status;

  /// The query the gateway (or the device index) actually answered, not what
  /// is in the box while the debounce is still running.
  final String query;
  final List<MessageSearchHit> hits;

  /// The server's total, or null when unknown (an on-device page has none).
  final int? total;

  /// True when [hits] came from the on-device index because the gateway could
  /// not be reached. The drawer says so.
  final bool local;

  /// Short, already-human copy for [MessageSearchStatus.error].
  final String? error;
}

/// A device-index search: same shape as the server page, no network.
typedef LocalMessageSearch =
    Future<List<MessageSearchHit>> Function(String query, {int limit});

/// Runs one debounced search per settled query and owns the four states.
///
/// The server is always tried first. Only a transport failure (`status: 0` —
/// no HTTP answer at all) falls back to [localSearch]; a real server answer,
/// including 4xx/5xx, is reported as an error rather than hidden behind
/// possibly-stale device rows.
class MessageSearchController extends ChangeNotifier {
  MessageSearchController({
    MessageSearchSource? source,
    this.localSearch,
    this.debounce = messageSearchDebounce,
    this.limit = 20,
  }) : _source = source ?? MessageSearchClient();

  final MessageSearchSource _source;

  /// The on-device fallback, used only when no HTTP answer arrived at all.
  final LocalMessageSearch? localSearch;
  final Duration debounce;

  /// The page size asked of the gateway (which clamps it).
  final int limit;

  MessageSearchState _state = MessageSearchState.idle;
  MessageSearchState get state => _state;

  Timer? _timer;
  int _generation = 0;

  /// Feed every keystroke here. A blank value clears at once and fences any
  /// in-flight answer, so a stale page can never land under an empty box.
  void query(String raw) {
    final normalized = normalizeMessageSearchQuery(raw);
    _timer?.cancel();
    final generation = ++_generation;
    if (normalized.isEmpty) {
      _set(MessageSearchState.idle);
      return;
    }
    _set(
      MessageSearchState(
        status: MessageSearchStatus.loading,
        query: normalized,
      ),
    );
    _timer = Timer(debounce, () => _run(normalized, generation));
  }

  /// Ask again for the query the error state kept.
  Future<void> retry() async {
    final query = _state.query;
    if (query.isEmpty) return;
    _timer?.cancel();
    final generation = ++_generation;
    _set(MessageSearchState(status: MessageSearchStatus.loading, query: query));
    await _run(query, generation);
  }

  Future<void> _run(String query, int generation) async {
    try {
      final page = await _source.search(query, limit: limit);
      if (generation != _generation) return;
      _set(
        MessageSearchState(
          status: page.items.isEmpty
              ? MessageSearchStatus.empty
              : MessageSearchStatus.content,
          query: query,
          hits: page.items,
          total: page.total,
        ),
      );
    } on CloudApiException catch (error) {
      if (generation != _generation) return;
      final fallback = localSearch;
      if (error.status == 0 && fallback != null) {
        try {
          final hits = await fallback(query, limit: limit);
          if (generation != _generation) return;
          _set(
            MessageSearchState(
              status: hits.isEmpty
                  ? MessageSearchStatus.empty
                  : MessageSearchStatus.content,
              query: query,
              hits: hits,
              local: true,
            ),
          );
          return;
        } catch (_) {
          // The device index failed too; the error below is the honest answer.
        }
      }
      if (generation != _generation) return;
      _set(
        MessageSearchState(
          status: MessageSearchStatus.error,
          query: query,
          error: error.status == 0
              ? "Couldn't reach Ovid Cloud."
              : 'Messages did not load.',
        ),
      );
    } catch (_) {
      if (generation != _generation) return;
      _set(
        MessageSearchState(
          status: MessageSearchStatus.error,
          query: query,
          error: 'Messages did not load.',
        ),
      );
    }
  }

  void _set(MessageSearchState next) {
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Fence every pending answer before the listener list goes away.
    _generation++;
    super.dispose();
  }
}
