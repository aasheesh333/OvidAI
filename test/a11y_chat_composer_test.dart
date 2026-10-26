import 'package:flutter/material.dart';
import 'package:ovid_ai/ui/v2/chat/composer_row.dart';

import 'a11y_support.dart';

class _FakeSend extends StatelessWidget {
  const _FakeSend();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Send',
      button: true,
      enabled: true,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Material(
          color: c.primary,
          shape: const CircleBorder(),
          child: const Icon(Icons.arrow_upward_rounded, size: 22),
        ),
      ),
    );
  }
}

void main() {
  group('V2ComposerRow a11y', () {
    Future<void> pumpComposer(WidgetTester tester, {double textScale = 1.0}) async {
      await pumpA11yScreen(
        tester,
        V2ComposerRow(
          field: const TextField(
            decoration: InputDecoration(hintText: 'Message'),
          ),
          send: const _FakeSend(),
          onPlus: () {},
          onMic: () {},
          listening: false,
          permissionLabel: 'Reasoning',
          onPermission: () {},
        ),
        textScale: textScale,
        size: const Size(600, 400),
      );
    }

    testWidgets('meets a11y guidelines at 1.0, 1.5 and 2.0 text scale',
        (tester) async {
      await expectA11yAtScales(tester, 'V2ComposerRow', (scale) async {
        await pumpComposer(tester, textScale: scale);
      });
    });

    testWidgets('no overflow at 2.0 text scale', (tester) async {
      await pumpComposer(tester, textScale: 2.0);
      expect(tester.takeException(), isNull);
    });
  });
}
