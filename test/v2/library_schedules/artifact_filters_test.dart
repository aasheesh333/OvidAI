import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/design/o_tokens.dart';
import 'package:ovid_ai/ui/v2/library/artifact_filters.dart';

const _sessions = <V2ArtifactSession>[
  V2ArtifactSession(id: 's1', title: 'Landing page redesign', count: 2),
  V2ArtifactSession(id: 's2', title: 'Q2 market review', count: 1),
];

const _summary = V2ArtifactSizeSummary(totalBytes: 2481561, totalCount: 4);

const _sourceKey = ValueKey<String>('artifact-filter-source');
const _sessionKey = ValueKey<String>('artifact-filter-session');
const _dateKey = ValueKey<String>('artifact-filter-date');
const _sortKey = ValueKey<String>('artifact-filter-sort');
const _clearKey = ValueKey<String>('artifact-filter-clear');

ValueKey<String> _typeKey(String name) =>
    ValueKey<String>('artifact-type-$name');

/// Owns the filter state the way the library page will, so every test exercises
/// the controlled contract instead of widget-internal state.
class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.initial,
    required this.summary,
    required this.sessions,
    required this.enabled,
  });

  final V2ArtifactFilters initial;
  final V2ArtifactSizeSummary summary;
  final List<V2ArtifactSession> sessions;
  final bool enabled;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late V2ArtifactFilters filters = widget.initial;
  V2ArtifactFilters? last;

  @override
  Widget build(BuildContext context) {
    return ArtifactFilterBar(
      filters: filters,
      summary: widget.summary,
      sessions: widget.sessions,
      enabled: widget.enabled,
      onChanged: (next) {
        setState(() {
          last = next;
          filters = next;
        });
      },
    );
  }
}

Widget _app(Widget home, {bool dark = false, double textScale = 1}) {
  return MaterialApp(
    theme: dark ? OTheme.dark() : OTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: home,
  );
}

Future<GlobalKey<_HostState>> _pump(
  WidgetTester tester, {
  V2ArtifactFilters initial = const V2ArtifactFilters(),
  V2ArtifactSizeSummary summary = _summary,
  List<V2ArtifactSession> sessions = _sessions,
  bool enabled = true,
  bool dark = false,
  double textScale = 1,
  Size size = const Size(430, 932),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(
    _app(
      Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(OSpace.screen),
            child: _Host(
              key: key,
              initial: initial,
              summary: summary,
              sessions: sessions,
              enabled: enabled,
            ),
          ),
        ),
      ),
      dark: dark,
      textScale: textScale,
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

Future<void> _tapChip(WidgetTester tester, String name) async {
  final finder = find.byKey(_typeKey(name));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The bar is one scrolling row, so a picker may start off-screen.
Future<void> _tapPicker(WidgetTester tester, ValueKey<String> key) async {
  final finder = find.byKey(key);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  group('renders', () {
    testWidgets('one row: type chips then the pickers', (tester) async {
      await _pump(tester);

      for (final label in ['All', 'Image', 'Page', 'Code', 'Doc', 'Other']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.byKey(_sourceKey), findsOneWidget);
      expect(find.text('Any source'), findsOneWidget);
      expect(find.text('All chats'), findsOneWidget);
      expect(find.text('Any time'), findsOneWidget);
      expect(find.text('Newest first'), findsOneWidget);

      // The count summary is gone.
      expect(find.text('4 files · 2.4 MB'), findsNothing);

      // Every chip and picker shares one row.
      final chip = tester.getTopLeft(find.byKey(_typeKey('image')));
      for (final key in [_sourceKey, _sessionKey, _dateKey, _sortKey]) {
        expect(
          tester.getTopLeft(find.byKey(key)).dy,
          closeTo(chip.dy, 1),
          reason: '$key sits on the chip row',
        );
      }

      // Nothing is filtered yet, so there is nothing to clear.
      expect(find.byKey(_clearKey), findsNothing);
    });

    testWidgets('renders in dark mode', (tester) async {
      await _pump(tester, dark: true);

      expect(find.text('Image'), findsOneWidget);
      expect(find.text('Any source'), findsOneWidget);
      expect(find.text('4 files · 2.4 MB'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every chip and trigger is a 48 dp target', (tester) async {
      await _pump(tester);

      for (final type in V2ArtifactTypeFilter.values) {
        final size = tester.getSize(find.byKey(_typeKey(type.name)));
        expect(size.height, greaterThanOrEqualTo(48), reason: type.name);
        expect(size.width, greaterThanOrEqualTo(48), reason: type.name);
      }
      for (final key in [_sourceKey, _sessionKey, _dateKey, _sortKey]) {
        final size = tester.getSize(find.byKey(key));
        expect(size.height, greaterThanOrEqualTo(48), reason: '$key');
      }
    });
  });

  group('type chips', () {
    testWidgets('selecting a type reports it and marks the chip selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final key = await _pump(tester);

      await _tapChip(tester, 'code');

      expect(key.currentState!.last?.type, V2ArtifactTypeFilter.code);
      expect(
        tester.getSemantics(find.text('Code')),
        matchesSemantics(
          label: 'Code',
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );

      // Back to All.
      await _tapChip(tester, 'all');
      expect(key.currentState!.filters.type, V2ArtifactTypeFilter.all);
      handle.dispose();
    });

    testWidgets('selecting one type replaces the previous one', (tester) async {
      final key = await _pump(tester);

      await _tapChip(tester, 'image');
      await _tapChip(tester, 'doc');

      expect(key.currentState!.filters.type, V2ArtifactTypeFilter.doc);
      expect(key.currentState!.filters.source, V2ArtifactSourceFilter.all);
    });
  });

  group('source', () {
    testWidgets('sheet lists every source and applies Uploaded', (
      tester,
    ) async {
      final key = await _pump(tester);

      await _tapPicker(tester, _sourceKey);
      await tester.pumpAndSettle();

      expect(find.text('Source'), findsOneWidget);
      expect(find.text('Generated and uploaded'), findsOneWidget);
      expect(find.text('Made by Ovid'), findsOneWidget);
      expect(find.text('Added by you'), findsOneWidget);

      await tester.tap(find.text('Uploaded'));
      await tester.pumpAndSettle();

      expect(key.currentState!.last?.source, V2ArtifactSourceFilter.uploaded);
      expect(find.text('Uploaded'), findsOneWidget);
      expect(find.text('Source'), findsNothing);
    });

    testWidgets('Any source clears the filter', (tester) async {
      final key = await _pump(
        tester,
        initial: const V2ArtifactFilters(
          source: V2ArtifactSourceFilter.generated,
        ),
      );

      await _tapPicker(tester, _sourceKey);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Any source').last);
      await tester.pumpAndSettle();

      expect(key.currentState!.filters.source, V2ArtifactSourceFilter.all);
      expect(find.text('Any source'), findsOneWidget);
    });
  });

  group('session', () {
    testWidgets('sheet lists sessions with counts and applies one', (
      tester,
    ) async {
      final key = await _pump(tester);

      await _tapPicker(tester, _sessionKey);
      await tester.pumpAndSettle();

      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('Every chat and upload'), findsOneWidget);
      expect(find.text('Landing page redesign'), findsOneWidget);
      expect(find.text('2 files'), findsOneWidget);
      expect(find.text('Q2 market review'), findsOneWidget);

      await tester.tap(find.text('Landing page redesign'));
      await tester.pumpAndSettle();

      expect(key.currentState!.last?.sessionId, 's1');
      expect(find.text('Landing page redesign'), findsOneWidget);
    });

    testWidgets('All chats clears the chat filter', (tester) async {
      final key = await _pump(
        tester,
        initial: const V2ArtifactFilters(sessionId: 's2'),
      );

      await _tapPicker(tester, _sessionKey);
      await tester.pumpAndSettle();
      await tester.tap(find.text('All chats').last);
      await tester.pumpAndSettle();

      expect(key.currentState!.filters.sessionId, isNull);
      expect(find.text('All chats'), findsOneWidget);
    });

    testWidgets('an unknown session id falls back to a neutral label', (
      tester,
    ) async {
      await _pump(tester, initial: const V2ArtifactFilters(sessionId: 'gone'));

      expect(find.text('Chat'), findsOneWidget);
    });
  });

  group('date', () {
    testWidgets('sheet lists every range and applies Today', (tester) async {
      final key = await _pump(tester);

      await _tapPicker(tester, _dateKey);
      await tester.pumpAndSettle();

      expect(find.text('Added'), findsOneWidget);
      for (final date in V2ArtifactDateFilter.values) {
        expect(find.text(date.label), findsWidgets);
      }
      expect(find.text('Added since midnight'), findsOneWidget);

      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();

      expect(key.currentState!.last?.date, V2ArtifactDateFilter.today);
      expect(find.text('Today'), findsOneWidget);

      final clear = find.byKey(_clearKey);
      await tester.ensureVisible(clear);
      await tester.pumpAndSettle();
      expect(clear, findsOneWidget);
    });

    testWidgets('Any time clears the date filter', (tester) async {
      final key = await _pump(
        tester,
        initial: const V2ArtifactFilters(date: V2ArtifactDateFilter.week),
      );

      await _tapPicker(tester, _dateKey);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Any time').last);
      await tester.pumpAndSettle();

      expect(key.currentState!.filters.date, V2ArtifactDateFilter.all);
      expect(find.text('Any time'), findsOneWidget);
    });
  });

  group('sort', () {
    testWidgets('sheet lists all orders and applies Largest first', (
      tester,
    ) async {
      final key = await _pump(tester);

      await _tapPicker(tester, _sortKey);
      await tester.pumpAndSettle();

      expect(find.text('Sort by'), findsOneWidget);
      for (final sort in V2ArtifactSort.values) {
        expect(find.text(sort.label), findsWidgets);
      }

      await tester.tap(find.text('Largest first'));
      await tester.pumpAndSettle();

      expect(key.currentState!.last?.sort, V2ArtifactSort.largest);
      expect(find.text('Largest first'), findsOneWidget);
    });

    testWidgets('name sort is reported', (tester) async {
      final key = await _pump(tester);

      await _tapPicker(tester, _sortKey);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Name A–Z'));
      await tester.pumpAndSettle();

      expect(key.currentState!.filters.sort, V2ArtifactSort.name);
      expect(find.text('Name A–Z'), findsOneWidget);
    });
  });

  group('size summary', () {
    // The bar no longer renders the count: a host may still pass the totals,
    // but nothing shows them.
    testWidgets('a supplied summary is not rendered', (tester) async {
      await _pump(
        tester,
        summary: const V2ArtifactSizeSummary(
          totalBytes: 2481561,
          totalCount: 4,
          visibleCount: 1,
          sizeLabel: '3.1 GB',
          storageLimitLabel: '5 GB',
        ),
      );

      expect(find.textContaining('files'), findsNothing);
      expect(find.textContaining('GB'), findsNothing);
      expect(find.bySemanticsLabel('Size summary: 4 files · 2.4 MB'),
          findsNothing);
    });
  });

  group('clear', () {
    testWidgets('clears type, source, date, session and sort together', (
      tester,
    ) async {
      final key = await _pump(
        tester,
        initial: const V2ArtifactFilters(
          type: V2ArtifactTypeFilter.image,
          source: V2ArtifactSourceFilter.uploaded,
          date: V2ArtifactDateFilter.month,
          sessionId: 's1',
          sort: V2ArtifactSort.oldest,
        ),
      );

      final clear = find.byKey(_clearKey);
      await tester.ensureVisible(clear);
      await tester.pumpAndSettle();
      expect(clear, findsOneWidget);

      await tester.tap(clear);
      await tester.pumpAndSettle();

      expect(key.currentState!.filters, const V2ArtifactFilters());
      expect(key.currentState!.last, const V2ArtifactFilters());
      expect(find.byKey(_clearKey), findsNothing);
      expect(find.text('Any source'), findsOneWidget);
      expect(find.text('All chats'), findsOneWidget);
      expect(find.text('Any time'), findsOneWidget);
      expect(find.text('Newest first'), findsOneWidget);
    });

    testWidgets('is not shown for a sort that is still the default', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.byKey(_clearKey), findsNothing);
    });
  });

  group('disabled', () {
    testWidgets('controls are announced as disabled and do nothing', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final key = await _pump(
        tester,
        initial: const V2ArtifactFilters(sort: V2ArtifactSort.oldest),
        enabled: false,
      );

      final source = find.byKey(_sourceKey);
      // The row scrolls: the key resolves to the scroll view's semantics node
      // from below, so the flags check goes through the picker's label node.
      final sourceNode = find.bySemanticsLabel('Source: Any source');
      expect(sourceNode, findsOneWidget);
      expect(
        tester
            .getSemantics(sourceNode)
            .getSemanticsData()
            .flagsCollection
            .isEnabled,
        Tristate.isFalse,
      );

      await tester.tap(source);
      await tester.pumpAndSettle();
      expect(find.text('Source'), findsNothing);
      expect(key.currentState!.last, isNull);

      // The sort is not the default but the bar is disabled, so no Clear.
      expect(find.byKey(_clearKey), findsNothing);

      final size = tester.getSize(source);
      expect(size.height, greaterThanOrEqualTo(48));
      handle.dispose();
    });

    testWidgets('type chips do not fire while disabled', (tester) async {
      final key = await _pump(tester, enabled: false);

      await tester.tap(find.byKey(_typeKey('image')));
      await tester.pumpAndSettle();

      expect(key.currentState!.last, isNull);
      expect(key.currentState!.filters.type, V2ArtifactTypeFilter.all);
    });
  });

  group('small screens', () {
    testWidgets('fits 320 dp at 200 % text in light', (tester) async {
      await _pump(tester, size: const Size(320, 640), textScale: 2);

      expect(tester.takeException(), isNull);
      expect(find.text('Any source'), findsOneWidget);
      expect(find.text('Other'), findsOneWidget);
      // One scrolling row: nothing overflows even when it runs off the edge.
      expect(find.text('4 files · 2.4 MB'), findsNothing);
    });

    testWidgets('fits 320 dp at 200 % text in dark', (tester) async {
      await _pump(tester, size: const Size(320, 640), textScale: 2, dark: true);

      expect(tester.takeException(), isNull);
      expect(find.text('Newest first'), findsOneWidget);
    });

    testWidgets('a long session title truncates instead of overflowing', (
      tester,
    ) async {
      await _pump(
        tester,
        size: const Size(320, 640),
        textScale: 2,
        sessions: const <V2ArtifactSession>[
          V2ArtifactSession(
            id: 'long',
            title:
                'A very long session name that cannot possibly fit on one line',
          ),
        ],
        initial: const V2ArtifactFilters(sessionId: 'long'),
      );

      expect(tester.takeException(), isNull);
      expect(find.textContaining('A very long session name'), findsOneWidget);
      // The picker caps at the page's content width (320 − 2×16 gutter).
      expect(
        tester.getSize(find.byKey(_sessionKey)).width,
        lessThanOrEqualTo(288),
      );
    });

    testWidgets('the filter sheet stays usable at 320 dp and 200 % text', (
      tester,
    ) async {
      await _pump(tester, size: const Size(320, 640), textScale: 2);

      await _tapPicker(tester, _sourceKey);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Generated and uploaded'), findsOneWidget);
      expect(find.text('Added by you'), findsOneWidget);
    });
  });

  group('model', () {
    test('formatArtifactBytes scales units', () {
      expect(formatArtifactBytes(0), isEmpty);
      expect(formatArtifactBytes(900), '900 B');
      expect(formatArtifactBytes(1536), '1.5 KB');
      expect(formatArtifactBytes(2048), '2.0 KB');
      expect(formatArtifactBytes(40 * 1024 * 1024), '40 MB');
      expect(formatArtifactBytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('isActive tracks every filter', () {
      expect(const V2ArtifactFilters().isActive, isFalse);
      expect(
        const V2ArtifactFilters(type: V2ArtifactTypeFilter.image).isActive,
        isTrue,
      );
      expect(
        const V2ArtifactFilters(
          source: V2ArtifactSourceFilter.uploaded,
        ).isActive,
        isTrue,
      );
      expect(const V2ArtifactFilters(sessionId: 's1').isActive, isTrue);
      expect(
        const V2ArtifactFilters(date: V2ArtifactDateFilter.today).isActive,
        isTrue,
      );
      expect(
        const V2ArtifactFilters(sort: V2ArtifactSort.oldest).isActive,
        isTrue,
      );
    });

    test('copyWith keeps values and can clear the session explicitly', () {
      const base = V2ArtifactFilters(
        type: V2ArtifactTypeFilter.code,
        source: V2ArtifactSourceFilter.generated,
        date: V2ArtifactDateFilter.week,
        sessionId: 's1',
        sort: V2ArtifactSort.name,
      );

      final same = base.copyWith();
      expect(same, base);

      final cleared = base.copyWith(sessionId: null);
      expect(cleared.sessionId, isNull);
      expect(cleared.type, V2ArtifactTypeFilter.code);
      expect(cleared.date, V2ArtifactDateFilter.week);
      expect(cleared.sort, V2ArtifactSort.name);

      final next = base.copyWith(
        type: V2ArtifactTypeFilter.doc,
        date: V2ArtifactDateFilter.month,
        sessionId: 's2',
      );
      expect(next, isNot(base));
      expect(next.type, V2ArtifactTypeFilter.doc);
      expect(next.date, V2ArtifactDateFilter.month);
      expect(next.sessionId, 's2');
    });

    test('summary text composes counts, size and limit', () {
      expect(
        const V2ArtifactSizeSummary(totalBytes: 2481561, totalCount: 4).text,
        '4 files · 2.4 MB',
      );
      expect(
        const V2ArtifactSizeSummary(
          totalBytes: 2481561,
          totalCount: 4,
          visibleCount: 2,
        ).text,
        '2 of 4 files · 2.4 MB',
      );
      expect(
        const V2ArtifactSizeSummary(
          totalCount: 1,
          sizeLabel: '4.0 MB',
          storageLimitLabel: '3 GB',
        ).text,
        '1 file · 4.0 MB of 3 GB',
      );
    });
  });
}
