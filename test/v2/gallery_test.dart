import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/v2_gallery.dart';
import 'package:ovid_ai/ui/v2/v2_registry.dart';

V2ScreenEntry _entry(String id, String title, String group) {
  return V2ScreenEntry(
    id: id,
    title: title,
    group: group,
    summary: '$title summary',
    builder: (_) => OScaffold(body: Center(child: Text('$title screen'))),
  );
}

void main() {
  final original = v2Screens;

  setUp(() {
    v2Screens = [
      _entry('chat', 'Chat', 'Chat'),
      _entry('studio', 'Studio', 'Work'),
      _entry('settings', 'Settings', 'Settings'),
    ];
  });

  tearDown(() {
    v2Screens = original;
  });

  Widget app() => MaterialApp(
    theme: OTheme.light(),
    home: const V2GalleryPage(),
  );

  testWidgets('gallery groups every registered screen', (tester) async {
    await tester.pumpWidget(app());
    expect(find.text('CHAT'), findsOneWidget);
    expect(find.text('WORK'), findsOneWidget);
    expect(find.text('SETTINGS'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);
  });

  testWidgets('search filters by title and clears', (tester) async {
    await tester.pumpWidget(app());
    await tester.enterText(find.byType(TextField), 'studio');
    await tester.pump();
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Chat'), findsNothing);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(find.text('Chat'), findsOneWidget);
  });

  testWidgets('tapping a row opens the screen and flips preview theme', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    expect(find.text('Chat screen'), findsOneWidget);
    expect(find.byIcon(Icons.dark_mode_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.dark_mode_outlined));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.light_mode_outlined), findsOneWidget);
  });

  testWidgets('empty registry offers a refresh action', (tester) async {
    v2Screens = const <V2ScreenEntry>[];
    await tester.pumpWidget(app());
    expect(find.text('Screens are still landing'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
  });
}
