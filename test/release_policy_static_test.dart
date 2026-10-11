import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level release guards for Play policy and shipped copy.
void main() {
  Iterable<File> dartSources(String root) => Directory(root)
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'));

  test('no redaction placeholder such as [OI] ships in lib/', () {
    final offenders = <String>[];
    for (final file in dartSources('lib')) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('[OI]')) offenders.add('${file.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty);
  });

  test('working-folder flows never request All Files Access', () {
    for (final path in ['lib/ui/chat_screen.dart', 'lib/ui/studio_screen.dart']) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('requestAllFilesAccess')), reason: path);
      expect(source, isNot(contains('manageExternalStorage')), reason: path);
    }
  });
}
