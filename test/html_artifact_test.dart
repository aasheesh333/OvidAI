import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/html_artifact.dart';

void main() {
  test('payload bounds count UTF-8 across all source fields', () {
    final a = HtmlArtifact.create('owner', {'title': 'A', 'html': 'x' * 65535});
    expect(a.payloadBytes, 65536);
    expect(
      () => HtmlArtifact.create('owner', {
        'title': 'A',
        'html': 'x' * 65535,
        'css': 'x',
      }),
      throwsFormatException,
    );
    expect(
      () => HtmlArtifact.create('owner', {'title': 'A', 'html': 'é' * 32768}),
      throwsFormatException,
    );
  });

  test('height is bounded and source survives durable encoding exactly', () {
    final a = HtmlArtifact.create('owner', {
      'html': '<p>é & "hi"</p>',
      'height': 999999,
    });
    expect(a.height, 640);
    final restored = HtmlArtifact.tryFromJson(
      jsonDecode(jsonEncode(a.toJson())),
    )!;
    expect(restored.id, a.id);
    expect(restored.html, '<p>é & "hi"</p>');
    expect(restored.sessionId, 'owner');
    expect(
      HtmlArtifact.create('owner', {'html': 'x', 'height': -4}).height,
      160,
    );
  });

  test('invalid persisted artifacts fail closed', () {
    final a = HtmlArtifact.create('owner', {'html': '<b>ok</b>'}).toJson();
    for (final changed in [
      {...a, 'version': 2},
      {...a, 'id': '../../other'},
      {...a, 'sessionId': ''},
      {...a, 'html': 'x' * 65537},
      {...a, 'html': 1},
    ]) {
      expect(HtmlArtifact.tryFromJson(changed), isNull);
    }
  });
}
