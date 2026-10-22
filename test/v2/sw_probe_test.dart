import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/connectors/connectors_page.dart';

void main() {
  testWidgets('connectors tap nodes without enabled', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      theme: OTheme.light(),
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 640),
          textScaler: TextScaler.linear(2),
        ),
        child: Builder(builder: (_) => const ConnectorsPage(data: V2ConnectorsData())),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final root = tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
    void walk(SemanticsNode n) {
      final d = n.getSemanticsData();
      final f = d.flagsCollection;
      if (d.hasAction(SemanticsAction.tap) && f.isEnabled == ui.Tristate.none) {
        // ignore: avoid_print
        print('NODE #${n.id} label="${d.label}" button=${f.isButton} enabled=${f.isEnabled} toggled=${f.isToggled} rect=${n.rect}');
        final own = n;
        for (final e in tester.allElements) {
          final ro = e.renderObject;
          if (ro != null && ro.debugSemantics?.id == own.id) {
            // ignore: avoid_print
            print('   widget: ${e.widget.runtimeType}');
          }
        }
      }
      n.visitChildren((c) { walk(c); return true; });
    }
    if (root != null) walk(root);
    handle.dispose();
  });
}
