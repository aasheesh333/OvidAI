import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/profile_avatar.dart';

void main() {
  testWidgets('missing and malformed photos retain a nonblank avatar', (
    tester,
  ) async {
    for (final url in [
      null,
      '',
      '   ',
      'file:///private/image.png',
      'not a url',
    ]) {
      await tester.pumpWidget(MaterialApp(home: ProfileAvatar(photoUrl: url)));
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    }
  });

  testWidgets(
    'failed remote image falls back to person instead of blank circle',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ProfileAvatar(photoUrl: 'https://example.invalid/photo.png'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
