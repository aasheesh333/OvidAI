import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/message_search.dart';

/// Message search against `GET /cloud/v1/search/messages`.
///
/// The wire half is one GET with only the documented keys: the gateway clamps
/// its own limit/offset, answers an empty page for a blank `q`, and scopes
/// every row from the bearer token. The pure half decides what a keystroke
/// means and turns `ts_headline`'s `→…←` markers into text segments — never
/// HTML. The controller half owns the four settled states and the offline
/// fallback to the on-device index.
void main() {
  group('snippet markers', () {
    test('a marked phrase becomes highlighted segments', () {
      final segments = parseSnippet('before →needle← after');
      expect(
        [for (final s in segments) (s.text, s.highlight)],
        [('before ', false), ('needle', true), (' after', false)],
      );
    });

    test('whitespace collapses because a drawer row is one line', () {
      final segments = parseSnippet('one\n  two\t→hit←\nthree');
      expect(
        [for (final s in segments) (s.text, s.highlight)],
        [('one two ', false), ('hit', true), (' three', false)],
      );
      expect(parseSnippet('   \n\t '), isEmpty);
    });

    test('unpaired markers are dropped rather than drawn as arrows', () {
      // An opener with no closer highlights the rest, as ts_headline intends.
      expect(
        [for (final s in parseSnippet('a →b')) (s.text, s.highlight)],
        [('a ', false), ('b', true)],
      );
      // A stray closer closes nothing and is not text.
      expect(
        [for (final s in parseSnippet('a ←b')) (s.text, s.highlight)],
        [('a ', false), ('b', false)],
      );
    });

    test('markup in a message stays text, never markup', () {
      // The snippet is a person's own message. Parsing yields plain segments;
      // nothing here is an HTML string that a renderer could execute.
      expect(
        [for (final s in parseSnippet('<b>→x←</b>')) (s.text, s.highlight)],
        [('<b>', false), ('x', true), ('</b>', false)],
      );
    });

    test('a local index uses its own marker pair', () {
      final segments = parseSnippet(
        'a\u0001hit\u0002b',
        open: '\u0001',
        close: '\u0002',
      );
      expect(
        [for (final s in segments) (s.text, s.highlight)],
        [('a', false), ('hit', true), ('b', false)],
      );
    });
  });

  group('wire contract', () {
    test('a search is one GET with only the documented keys', () async {
      final rest = _FakeRest(
        (path, query) async => {
          'items': [
            {
              'messageId': 'msg-1',
              'sessionId': 'sess-1',
              'role': 'assistant',
              'rank': 0.5,
              'snippet': 'before →needle← after',
            },
          ],
          'total': 1,
          'limit': 30,
          'offset': 0,
        },
      );
      final page = await MessageSearchClient(rest: rest).search('red fox');

      expect(rest.calls, hasLength(1));
      expect(rest.calls.single.path, '/search/messages');
      expect(rest.calls.single.query, {'q': 'red fox'});
      expect(page.total, 1);
      expect(page.items.single.messageId, 'msg-1');
      expect(page.items.single.snippetText, 'before needle after');
    });

    test('limit, offset and sessionId are sent only when provided', () async {
      final rest = _FakeRest(
        (path, query) async => {
          'items': <Object>[],
          'total': 0,
          'limit': 10,
          'offset': 20,
        },
      );
      final client = MessageSearchClient(rest: rest);
      const sessionId = '11111111-1111-4111-8111-111111111111';

      await client.search(
        'needle',
        limit: 10,
        offset: 20,
        sessionId: sessionId,
      );
      expect(rest.calls.single.query, {
        'q': 'needle',
        'limit': '10',
        'offset': '20',
        'sessionId': sessionId,
      });

      await client.search('needle');
      expect(rest.calls.last.query, {'q': 'needle'});
    });

    test('an empty sessionId is omitted', () async {
      final rest = _FakeRest(
        (path, query) async => {'items': <Object>[], 'total': 0},
      );
      await MessageSearchClient(rest: rest).search('needle', sessionId: '');
      expect(rest.calls.single.query, {'q': 'needle'});
    });

    test('a blank query answers an empty page without a request', () async {
      final rest = _FakeRest(
        (path, query) async => throw StateError('no request expected'),
      );
      final page = await MessageSearchClient(rest: rest).search('   \n\t ');
      expect(rest.calls, isEmpty);
      expect(page.items, isEmpty);
      expect(page.total, 0);
    });

    test('the client never sends a uid — ownership is the token', () async {
      final rest = _FakeRest(
        (path, query) async => {'items': <Object>[], 'total': 0},
      );
      await MessageSearchClient(
        rest: rest,
      ).search('needle', sessionId: 'sess-1');
      final query = rest.calls.single.query!;
      expect(query.containsKey('uid'), isFalse);
      expect(query.containsKey('userId'), isFalse);
      expect(query.containsKey('user_id'), isFalse);
    });

    test(
      'a session the caller does not own is an empty page, not an error',
      () async {
        // The ownership join answers zero rows; the client must read that as
        // "nothing found", never as a failure.
        final rest = _FakeRest(
          (path, query) async => {
            'items': <Object>[],
            'total': 0,
            'limit': 20,
            'offset': 0,
          },
        );
        final page = await MessageSearchClient(
          rest: rest,
        ).search('zebra', sessionId: '22222222-2222-4222-8222-222222222222');
        expect(page.items, isEmpty);
        expect(page.total, 0);
      },
    );
  });

  group('parsing a page', () {
    test('unknown values stay unknown, never zero', () {
      final page = MessageSearchPage.fromJson({
        'items': [
          {'sessionId': 'sess-1', 'role': 'user', 'snippet': '→x←'},
        ],
      });
      expect(page.total, isNull);
      expect(page.limit, isNull);
      expect(page.offset, isNull);
      expect(page.items.single.rank, isNull);
      expect(page.items.single.messageId, isNull);
      expect(page.items.single.sessionId, 'sess-1');
    });

    test('a non-numeric total is unknown, not zero', () {
      final page = MessageSearchPage.fromJson({
        'items': <Object>[],
        'total': '12',
        'limit': -1,
      });
      expect(page.total, isNull);
      expect(page.limit, isNull);
    });

    test('roles read as people; an unknown role still reads as a message', () {
      expect(messageRoleLabel('user'), 'You');
      expect(messageRoleLabel('assistant'), 'Assistant');
      expect(messageRoleLabel('system'), 'System');
      expect(messageRoleLabel('tool'), 'Tool');
      expect(messageRoleLabel('narrator'), 'Message');
      expect(messageRoleLabel(null), 'Message');
    });

    test('blank is idle, a searched zero is empty, hits are content', () {
      expect(shouldSearchMessages(''), isFalse);
      expect(shouldSearchMessages('   \n\t '), isFalse);
      expect(shouldSearchMessages(' a '), isTrue);
      expect(normalizeMessageSearchQuery('  red fox  '), 'red fox');
    });
  });

  group('controller', () {
    test('content comes from the server in its own order', () async {
      final source = _FakeSource(
        (query, {limit, offset, sessionId}) async => MessageSearchPage(
          items: [
            _hit(messageId: 'm2'),
            _hit(messageId: 'm1'),
          ],
          total: 2,
          limit: limit,
          offset: offset,
        ),
      );
      final controller = MessageSearchController(
        source: source,
        debounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      controller.query('needle');
      expect(controller.state.status, MessageSearchStatus.loading);
      await _flush();

      expect(controller.state.status, MessageSearchStatus.content);
      expect(controller.state.hits.map((h) => h.messageId), ['m2', 'm1']);
      expect(controller.state.total, 2);
      expect(controller.state.local, isFalse);
      expect(source.calls.single.query, 'needle');
      expect(source.calls.single.limit, 20);
    });

    test('a searched zero is empty; a blank box is idle and silent', () async {
      final source = _FakeSource(
        (query, {limit, offset, sessionId}) async =>
            const MessageSearchPage(items: [], total: 0),
      );
      final controller = MessageSearchController(
        source: source,
        debounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      controller.query('needle');
      await _flush();
      expect(controller.state.status, MessageSearchStatus.empty);
      expect(controller.state.error, isNull);

      controller.query('   ');
      await _flush();
      expect(controller.state.status, MessageSearchStatus.idle);
      expect(controller.state.error, isNull);
      expect(source.calls, hasLength(1), reason: 'a blank box sends nothing');
    });

    test('a failed search is the error state and keeps the query', () async {
      final source = _FakeSource(
        (query, {limit, offset, sessionId}) async => throw CloudApiException(
          status: 500,
          code: 'internal',
          message: 'boom',
        ),
      );
      final controller = MessageSearchController(
        source: source,
        debounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      controller.query('needle');
      await _flush();
      expect(controller.state.status, MessageSearchStatus.error);
      expect(controller.state.query, 'needle');
      expect(controller.state.error, isNotNull);
      expect(controller.state.local, isFalse);
    });

    test('an unreachable gateway falls back to the on-device index', () async {
      final source = _FakeSource(
        (query, {limit, offset, sessionId}) async => throw CloudApiException(
          status: 0,
          code: 'unreachable',
          message: 'offline',
        ),
      );
      final local = _FakeLocal([_hit(messageId: null)]);
      final controller = MessageSearchController(
        source: source,
        localSearch: local.search,
        debounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      controller.query('needle');
      await _flush();

      expect(controller.state.status, MessageSearchStatus.content);
      expect(controller.state.local, isTrue);
      expect(controller.state.hits, hasLength(1));
      expect(controller.state.total, isNull);
      expect(local.calls.single, 'needle');
    });

    test(
      'offline with nothing on the device is empty, still marked local',
      () async {
        final source = _FakeSource(
          (query, {limit, offset, sessionId}) async => throw CloudApiException(
            status: 0,
            code: 'timeout',
            message: 'slow',
          ),
        );
        final local = _FakeLocal(const []);
        final controller = MessageSearchController(
          source: source,
          localSearch: local.search,
          debounce: Duration.zero,
        );
        addTearDown(controller.dispose);

        controller.query('needle');
        await _flush();

        expect(controller.state.status, MessageSearchStatus.empty);
        expect(controller.state.local, isTrue);
        expect(controller.state.error, isNull);
      },
    );

    test('a server error is not hidden behind the local index', () async {
      final source = _FakeSource(
        (query, {limit, offset, sessionId}) async => throw CloudApiException(
          status: 403,
          code: 'forbidden',
          message: 'no',
        ),
      );
      final local = _FakeLocal([_hit()]);
      final controller = MessageSearchController(
        source: source,
        localSearch: local.search,
        debounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      controller.query('needle');
      await _flush();

      expect(controller.state.status, MessageSearchStatus.error);
      expect(local.calls, isEmpty);
    });

    test('a stale answer cannot land under a newer query', () async {
      final first = Completer<MessageSearchPage>();
      final second = Completer<MessageSearchPage>();
      final source = _FakeSource(
        (query, {limit, offset, sessionId}) =>
            query == 'first' ? first.future : second.future,
      );
      final controller = MessageSearchController(
        source: source,
        debounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      controller.query('first');
      await _flush();
      controller.query('second');
      await _flush();

      second.complete(
        MessageSearchPage(items: [_hit(messageId: 'new')], total: 1),
      );
      await _flush();
      first.complete(
        MessageSearchPage(items: [_hit(messageId: 'old')], total: 1),
      );
      await _flush();

      expect(controller.state.query, 'second');
      expect(controller.state.hits.single.messageId, 'new');
    });

    test('retry asks again for the same query', () async {
      var attempts = 0;
      final source = _FakeSource((query, {limit, offset, sessionId}) async {
        attempts++;
        if (attempts == 1) {
          throw CloudApiException(
            status: 500,
            code: 'internal',
            message: 'boom',
          );
        }
        return MessageSearchPage(items: [_hit()], total: 1);
      });
      final controller = MessageSearchController(
        source: source,
        debounce: Duration.zero,
      );
      addTearDown(controller.dispose);

      controller.query('needle');
      await _flush();
      expect(controller.state.status, MessageSearchStatus.error);

      await controller.retry();
      await _flush();
      expect(controller.state.status, MessageSearchStatus.content);
      expect(source.calls.map((c) => c.query), ['needle', 'needle']);
    });
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

MessageSearchHit _hit({
  String? messageId = 'm1',
  String sessionId = 'sess-1',
  String role = 'assistant',
  String snippet = 'before →needle← after',
}) => MessageSearchHit(
  messageId: messageId,
  sessionId: sessionId,
  role: role,
  rank: 0.5,
  snippet: parseSnippet(snippet),
);

/// A [CloudRestClient] whose one network call is answered in-process, so the
/// request shape is asserted without a socket.
class _FakeRest extends CloudRestClient {
  _FakeRest(this._respond) : super(restBase: 'https://example.test/cloud/v1');

  final Future<Map<String, dynamic>> Function(
    String path,
    Map<String, String>? query,
  )
  _respond;
  final List<({String path, Map<String, String>? query})> calls = [];

  @override
  Future<Map<String, dynamic>> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) {
    calls.add((path: path, query: query));
    return _respond(path, query);
  }
}

class _FakeSource implements MessageSearchSource {
  _FakeSource(this._onSearch);

  final Future<MessageSearchPage> Function(
    String query, {
    int? limit,
    int? offset,
    String? sessionId,
  })
  _onSearch;
  final List<({String query, int? limit, int? offset, String? sessionId})>
  calls = [];

  @override
  Future<MessageSearchPage> search(
    String query, {
    int? limit,
    int? offset,
    String? sessionId,
  }) {
    calls.add((
      query: query,
      limit: limit,
      offset: offset,
      sessionId: sessionId,
    ));
    return _onSearch(query, limit: limit, offset: offset, sessionId: sessionId);
  }
}

class _FakeLocal {
  _FakeLocal(this.hits);

  final List<MessageSearchHit> hits;
  final List<String> calls = [];

  Future<List<MessageSearchHit>> search(String query, {int limit = 20}) async {
    calls.add(query);
    return hits;
  }
}
