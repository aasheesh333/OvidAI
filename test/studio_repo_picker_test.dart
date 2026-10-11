import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_screen.dart';

/// F-172: users with more than one page of repos (every org member) can
/// find and pick any of them; the picker builds tiles lazily.
void main() {
  final all = [
    for (var i = 0; i < 120; i++)
      <String, dynamic>{'full_name': 'acme/repo-$i', 'language': 'Dart'},
  ];

  Future<List<Map<String, dynamic>>> page(int p) async =>
      all.skip((p - 1) * 100).take(100).toList();

  Future<void> pumpSheet(
    WidgetTester tester, {
    Future<List<Map<String, dynamic>>> Function(String q)? search,
    List<int>? pages,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Scaffold(
          body: SizedBox(
            height: 600,
            child: StudioRepoSheet(
              pageLoader: (p) {
                pages?.add(p);
                return page(p);
              },
              search: search,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('searching the 110th repo finds it; tiles are built lazily', (
    tester,
  ) async {
    final queries = <String>[];
    await pumpSheet(
      tester,
      search: (q) async {
        queries.add(q);
        return all
            .where((r) => (r['full_name'] as String).contains(q))
            .toList();
      },
    );

    final built = find.textContaining('acme/repo-').evaluate().length;
    expect(built, greaterThan(0));
    expect(built, lessThan(60), reason: 'only visible tiles are built');

    await tester.enterText(find.byKey(studioPickerSearchKey), 'repo-110');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(queries, ['repo-110']);
    expect(find.text('acme/repo-110'), findsOneWidget);

    await tester.tap(find.text('acme/repo-110'));
    await tester.pump();
  });

  testWidgets('local search filters loaded repos instantly', (tester) async {
    await pumpSheet(tester);
    await tester.enterText(find.byKey(studioPickerSearchKey), 'repo-42');
    await tester.pump();
    expect(find.text('acme/repo-42'), findsOneWidget);
    expect(find.text('acme/repo-41'), findsNothing);
  });

  testWidgets('scrolling to the end loads the next page', (tester) async {
    final pages = <int>[];
    await pumpSheet(tester, pages: pages);
    expect(pages, [1]);
    await tester.drag(find.byType(ListView), const Offset(0, -20000));
    await tester.pump();
    await tester.pump();
    expect(pages, [1, 2]);
    await tester.drag(find.byType(ListView), const Offset(0, -20000));
    await tester.pump();
    expect(find.text('acme/repo-119'), findsOneWidget);
    expect(pages, [1, 2], reason: 'a short page is the last one');
  });
}
