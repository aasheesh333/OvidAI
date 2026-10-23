import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/message_search.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/sidebar/sidebar.dart';

/// The sidebar's server message search surface.
///
/// Titles still filter locally and instantly. The Messages section is the
/// gateway's ranked page layered under them, and it has exactly four states —
/// loading, empty, error, content — plus idle for a blank box. A blank box
/// never shows an error, an unreachable gateway says its results are local,
/// and an unknown count renders `—` rather than a fabricated zero.
const _landing = V2SidebarSession(
  id: 't1',
  title: 'Landing page copy review',
  modelLabel: 'Auto',
  timeLabel: '2h ago',
);

const _other = V2SidebarSession(
  id: 't2',
  title: 'Synthesize research PDF',
  modelLabel: 'Auto',
  timeLabel: 'Yesterday',
);

V2SidebarData _data([List<V2SidebarSession> today = const [_other]]) =>
    V2SidebarData(name: 'Alex Rivera', today: today);

Widget _app(Widget child) => MaterialApp(
  theme: OTheme.light(),
  home: Scaffold(body: child),
);

MessageSearchHit _hit({
  String? messageId = 'm1',
  String sessionId = 'sess-1',
  String role = 'assistant',
  String snippet = 'Deploy the →zebra42← service on Friday',
}) => MessageSearchHit(
  messageId: messageId,
  sessionId: sessionId,
  role: role,
  rank: 0.5,
  snippet: parseSnippet(snippet),
);

/// Types into the drawer search box and lets the 300 ms debounce elapse.
Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('v2-sidebar-search')), text);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pumpAndSettle();
}

/// The hit row's own text. Scoped to the row so the search field, which also
/// contains the query, is never the match.
Finder _hitText(String text, {String messageId = 'm1'}) => find.descendant(
  of: find.byKey(ValueKey<String>('v2-search-message-sess-1-$messageId')),
  matching: find.textContaining(text, findRichText: true),
);

void main() {
  testWidgets('typing debounces, shows loading, then the server hit', (
    tester,
  ) async {
    final pending = Completer<MessageSearchPage>();
    final source = _FakeSource(
      (query, {limit, offset, sessionId}) => pending.future,
    );
    final controller = MessageSearchController(source: source);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(Sidebar(data: _data(), messageSearch: controller)),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('v2-sidebar-search')),
      'zebra42',
    );
    await tester.pump(const Duration(milliseconds: 100));
    // Inside the debounce: one loading line, no request yet.
    expect(source.calls, isEmpty);
    expect(find.text('Searching messages…'), findsOneWidget);
    expect(find.text('No matches'), findsNothing);

    await tester.pump(const Duration(milliseconds: 250));
    expect(source.calls, hasLength(1));
    expect(source.calls.single.query, 'zebra42');
    expect(source.calls.single.limit, 20);

    pending.complete(
      MessageSearchPage(items: [_hit()], total: 1, limit: 20, offset: 0),
    );
    await tester.pumpAndSettle();

    expect(find.text('MESSAGES'), findsOneWidget);
    expect(_hitText('zebra42'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('Searching messages…'), findsNothing);
  });

  testWidgets('a searched zero with no local match is the empty state', (
    tester,
  ) async {
    final source = _FakeSource(
      (query, {limit, offset, sessionId}) async =>
          const MessageSearchPage(items: [], total: 0),
    );
    final controller = MessageSearchController(source: source);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(Sidebar(data: _data(), messageSearch: controller)),
    );
    await tester.pumpAndSettle();
    await _search(tester, 'zebra42');

    expect(find.text('No matches'), findsOneWidget);
    expect(find.textContaining('did not load'), findsNothing);
  });

  testWidgets('a title match still renders and says messages found nothing', (
    tester,
  ) async {
    final source = _FakeSource(
      (query, {limit, offset, sessionId}) async =>
          const MessageSearchPage(items: [], total: 0),
    );
    final controller = MessageSearchController(source: source);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(Sidebar(data: _data(const [_landing]), messageSearch: controller)),
    );
    await tester.pumpAndSettle();
    await _search(tester, 'landing');

    expect(find.text('Landing page copy review'), findsOneWidget);
    expect(find.text('MESSAGES'), findsOneWidget);
    expect(find.text('No messages match.'), findsOneWidget);
    expect(find.text('No matches'), findsNothing);
  });

  testWidgets('an error shows a retry, and retry reaches content', (
    tester,
  ) async {
    var attempts = 0;
    final source = _FakeSource((query, {limit, offset, sessionId}) async {
      attempts++;
      if (attempts == 1) {
        throw CloudApiException(status: 500, code: 'internal', message: 'boom');
      }
      return MessageSearchPage(items: [_hit()], total: 1);
    });
    final controller = MessageSearchController(source: source);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(Sidebar(data: _data(), messageSearch: controller)),
    );
    await tester.pumpAndSettle();
    await _search(tester, 'zebra42');

    expect(find.text('Messages did not load.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Messages did not load.'), findsNothing);
    expect(_hitText('zebra42'), findsOneWidget);
  });

  testWidgets('offline results come from this device and say so', (
    tester,
  ) async {
    final source = _FakeSource(
      (query, {limit, offset, sessionId}) async => throw CloudApiException(
        status: 0,
        code: 'unreachable',
        message: 'offline',
      ),
    );
    final controller = MessageSearchController(
      source: source,
      localSearch: (query, {limit = 20}) async => [_hit(messageId: null)],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(Sidebar(data: _data(), messageSearch: controller)),
    );
    await tester.pumpAndSettle();
    await _search(tester, 'zebra42');

    expect(
      find.text('Offline — showing matches saved on this device.'),
      findsOneWidget,
    );
    expect(_hitText('zebra42', messageId: 'local'), findsOneWidget);
    // No server total exists offline; the count is unknown, not zero.
    expect(find.text('—'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(find.text('Messages did not load.'), findsNothing);
  });

  testWidgets('offline with nothing saved says empty, never an error', (
    tester,
  ) async {
    final source = _FakeSource(
      (query, {limit, offset, sessionId}) async =>
          throw CloudApiException(status: 0, code: 'timeout', message: 'slow'),
    );
    final controller = MessageSearchController(
      source: source,
      localSearch: (query, {limit = 20}) async => const [],
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(Sidebar(data: _data(), messageSearch: controller)),
    );
    await tester.pumpAndSettle();
    await _search(tester, 'zebra42');

    expect(
      find.text('Offline — showing matches saved on this device.'),
      findsOneWidget,
    );
    expect(find.text('No messages match.'), findsOneWidget);
    expect(find.text('Messages did not load.'), findsNothing);
  });

  testWidgets('clearing the box is idle: no messages surface, no error', (
    tester,
  ) async {
    final source = _FakeSource(
      (query, {limit, offset, sessionId}) async =>
          MessageSearchPage(items: [_hit()], total: 1),
    );
    final controller = MessageSearchController(source: source);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(Sidebar(data: _data(), messageSearch: controller)),
    );
    await tester.pumpAndSettle();
    await _search(tester, 'zebra42');
    expect(find.text('MESSAGES'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('v2-sidebar-search')), '');
    await tester.pumpAndSettle();

    expect(find.text('MESSAGES'), findsNothing);
    expect(find.textContaining('did not load'), findsNothing);
    expect(find.text('Searching messages…'), findsNothing);
    expect(source.calls, hasLength(1), reason: 'a blank box sends nothing');
    expect(controller.state.status, MessageSearchStatus.idle);
  });

  testWidgets('snippet markup is drawn as text, not interpreted', (
    tester,
  ) async {
    final source = _FakeSource(
      (query, {limit, offset, sessionId}) async => MessageSearchPage(
        items: [_hit(snippet: '<b>→zebra42←</b>')],
        total: 1,
      ),
    );
    final controller = MessageSearchController(source: source);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(Sidebar(data: _data(), messageSearch: controller)),
    );
    await tester.pumpAndSettle();
    await _search(tester, 'zebra42');

    expect(_hitText('<b>zebra42</b>'), findsOneWidget);
  });

  testWidgets('tapping a hit opens that chat through the shell callback', (
    tester,
  ) async {
    String? opened;
    final source = _FakeSource(
      (query, {limit, offset, sessionId}) async =>
          MessageSearchPage(items: [_hit()], total: 1),
    );
    final controller = MessageSearchController(source: source);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _app(
        Sidebar(
          data: _data(),
          messageSearch: controller,
          onMessageTap: (sessionId) => opened = sessionId,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _search(tester, 'zebra42');

    await tester.tap(
      find.byKey(const ValueKey<String>('v2-search-message-sess-1-m1')),
    );
    await tester.pump();
    expect(opened, 'sess-1');
  });
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
