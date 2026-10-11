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
}
