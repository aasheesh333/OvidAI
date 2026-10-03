import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/plugin_install_progress.dart';

void main() {
  testWidgets(
    'short progress sheet scrolls to an accessible completion control',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final progress = PluginInstallProgress()
        ..finish(ok: true, summary: 'Installed successfully. ' * 20);
      addTearDown(progress.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => PluginInstallProgressSheet(
                    progress: progress,
                    title: 'Install fixture',
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Done').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byType(PluginInstallProgressSheet), findsNothing);
    },
  );

  testWidgets(
    'log follows bursts and capped buffer changes but preserves scrolled-up intent',
    (tester) async {
      var lines = List.generate(300, (i) => 'line $i');
      Future<void> render() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ProgressLogView(lines: lines)),
        ),
      );
      await render();
      final list = tester.widget<ListView>(find.byType(ListView));
      final scroll = list.controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      lines = [...lines.skip(1), 'wrapped last line\n' * 20];
      await render();
      await tester.pump();
      expect(scroll.position.extentAfter, lessThan(1));
      scroll.jumpTo(100);
      await tester.pump();
      final before = scroll.offset;
      lines = [...lines.skip(1), 'next'];
      await render();
      await tester.pump();
      expect(scroll.offset, before);
      // A lazy list refines its extent as the last rows enter the viewport.
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      expect(
        scroll.position.extentAfter,
        lessThan(1),
        reason: 'at bottom before burst',
      );
      lines = [...lines, ...List.generate(30, (i) => 'burst $i')];
      await render();
      await tester.pump();
      expect(scroll.position.extentAfter, lessThan(1));
    },
  );
}
