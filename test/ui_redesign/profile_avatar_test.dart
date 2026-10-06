import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/profile_avatar.dart';

Widget _host(Widget child) {
  return MaterialApp(
    theme: Aether.theme(),
    home: Scaffold(body: Center(child: child)),
  );
}

BoxDecoration _ringDecoration(WidgetTester tester) {
  final container = tester.widget<Container>(
    find.descendant(
      of: find.byType(ProfileAvatar),
      matching: find.byType(Container),
    ),
  );
  return container.decoration! as BoxDecoration;
}

void main() {
  testWidgets('renders circular Aether ring with hairline border', (
    tester,
  ) async {
    // Fails if the polish ring is dropped from ProfileAvatar.build.
    await tester.pumpWidget(_host(const ProfileAvatar(radius: 22)));
    final decoration = _ringDecoration(tester);
    expect(decoration.shape, BoxShape.circle);
    expect(decoration.color, Aether.surfaceRaised);
    final border = decoration.border! as Border;
    expect(border.top.color, Aether.hairlineStrong);
    expect(border.top.width, 1);
    expect(decoration.boxShadow, isNotEmpty);

    final size = tester.getSize(find.byType(ProfileAvatar));
    expect(size, const Size(44, 44));
  });

  testWidgets('shows deterministic initial glyph when displayName given', (
    tester,
  ) async {
    // Fails if the initials fallback reverts to the person icon.
    await tester.pumpWidget(
      _host(const ProfileAvatar(displayName: 'ada lovelace')),
    );
    final glyph = tester.widget<Text>(find.text('A'));
    expect(glyph.style!.fontWeight, FontWeight.w700);
    expect(glyph.style!.color, Aether.textMuted);
    expect(find.byIcon(Icons.person), findsNothing);
  });

  testWidgets('initial skips leading non-letters and uppercases', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const ProfileAvatar(displayName: '1ada')));
    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('all-numeric name falls back to first rune', (tester) async {
    await tester.pumpWidget(_host(const ProfileAvatar(displayName: '42')));
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('null or blank displayName keeps legacy person icon', (
    tester,
  ) async {
    // Fails if legacy call sites lose the generic person fallback.
    await tester.pumpWidget(_host(const ProfileAvatar()));
    expect(find.byIcon(Icons.person), findsOneWidget);

    await tester.pumpWidget(_host(const ProfileAvatar(displayName: '   ')));
    expect(find.byIcon(Icons.person), findsOneWidget);
  });

  testWidgets('non-https photoUrl renders fallback, no network image', (
    tester,
  ) async {
    // Fails if URL validation stops gating Image.network.
    await tester.pumpWidget(
      _host(
        const ProfileAvatar(
          photoUrl: 'http://insecure.example/p.png',
          displayName: 'ada',
        ),
      ),
    );
    expect(find.byType(Image), findsNothing);
    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('valid https photoUrl loads image, fallback on error', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const ProfileAvatar(
          photoUrl: ' https://example.com/p.png ',
          displayName: 'ada',
        ),
      ),
    );
    expect(find.byType(Image), findsOneWidget);
    // flutter_test HTTP override fails the load; errorBuilder -> fallback.
    await tester.pumpAndSettle();
    expect(find.text('A'), findsOneWidget);
  });

  testWidgets('exposes Profile image semantics label', (tester) async {
    await tester.pumpWidget(_host(const ProfileAvatar()));
    expect(
      find.bySemanticsLabel('Profile image'),
      findsOneWidget,
    );
  });
}
