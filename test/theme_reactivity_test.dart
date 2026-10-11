import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Mirrors `OvidApp`: theme + darkTheme + themeMode, and [Aether.rebuildAll]
/// after flipping [Aether.dark].
class _Host extends StatefulWidget {
  const _Host();
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  void toggle() {
    Aether.dark = !Aether.dark;
    setState(() {});
    Aether.rebuildAll(context);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: Aether.themeFor(dark: false),
    darkTheme: Aether.themeFor(dark: true),
    themeMode: Aether.dark ? ThemeMode.dark : ThemeMode.light,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showAetherSheet<void>(
              context: context,
              builder: (_) => const AetherSheet(
                title: 'Sheet',
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _StaticPaletteBox(),
                    AetherCard(child: Text('x')),
                  ],
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

/// A const widget that reads the static palette, like most screens do.
class _StaticPaletteBox extends StatelessWidget {
  const _StaticPaletteBox();
  @override
  Widget build(BuildContext context) => Material(
    key: const Key('static-box'),
    color: Aether.surfaceAlt,
    child: const SizedBox(width: 10, height: 10),
  );
}

void main() {
  tearDown(() {
    Aether.dark = false;
    Aether.resetThemeCacheForTest();
  });

  testWidgets('toggling the theme with a sheet open repaints the sheet', (
    tester,
  ) async {
    Aether.dark = false;
    await tester.pumpWidget(const _Host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    Color staticBox() =>
        tester.widget<Material>(find.byKey(const Key('static-box'))).color!;
    Color card() => tester
        .widget<Material>(
          find.descendant(
            of: find.byType(AetherCard),
            matching: find.byType(Material),
          ),
        )
        .color!;
    Color sheet() => tester
        .widget<Material>(find.byKey(const ValueKey('aether-sheet-surface')))
        .color!;

    expect(staticBox(), AetherColors.light.surfaceAlt);
    expect(card(), AetherColors.light.surface);
    expect(sheet(), AetherColors.light.surface);

    tester.state<_HostState>(find.byType(_Host)).toggle();
    await tester.pumpAndSettle();

    expect(staticBox(), AetherColors.dark.surfaceAlt);
    expect(card(), AetherColors.dark.surface);
    expect(sheet(), AetherColors.dark.surface);
  });
}
