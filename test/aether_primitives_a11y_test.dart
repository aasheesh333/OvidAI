import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('primitives meet tap-target, label and text-contrast '
        'guidelines (dark=$dark)', (tester) async {
      Aether.dark = dark;
      addTearDown(() {
        Aether.dark = false;
        Aether.resetThemeCacheForTest();
      });
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.themeFor(dark: false),
          darkTheme: Aether.themeFor(dark: true),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: Scaffold(
            backgroundColor: Aether.bg,
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                AetherCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Title', style: AetherType.title),
                      Text('Muted body', style: AetherType.bodyMuted),
                      Text('Faint caption', style: AetherType.caption),
                      Text(
                        'Accent link',
                        style: TextStyle(color: Aether.accent),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const AetherSectionTitle(eyebrow: 'Section'),
                const SizedBox(height: 12),
                AetherPrimaryButton(label: 'Save', onPressed: () {}),
                AetherSecondaryButton(label: 'Cancel', onPressed: () {}),
                AetherGhostButton(label: 'Skip', onPressed: () {}),
                AetherDangerButton(label: 'Delete', onPressed: () {}),
                Row(
                  children: [
                    AetherPrimaryButton(
                      label: 'Send',
                      iconOnly: true,
                      onPressed: () {},
                    ),
                    AetherGhostButton(
                      label: 'Attach',
                      iconOnly: true,
                      icon: Icons.add,
                      onPressed: () {},
                    ),
                  ],
                ),
                const AetherField(label: 'Name', hint: 'Your name'),
              ],
            ),
          ),
        ),
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  }
}
