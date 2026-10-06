import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:sqlite3/open.dart';

typedef SearchSession = ({
  String id,
  String model,
  List<({String role, String content})> rows,
});

SearchSession session(String id, String body) => (
  id: id,
  model: 'm',
  rows: [(role: 'user', content: body)],
);

void main() {
  if (Platform.isLinux) {
    open.overrideFor(
      OperatingSystem.linux,
      () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
    );
  }
  late Directory root;
  late String path;
  final search = SessionSearch.I;

  setUp(() {
    root = Directory.systemTemp.createTempSync('reset-search-');
    path = '${root.path}/search.db';
    SessionSearch.dbPathOverrideForTest = path;
  });

  tearDown(() async {
    await search.close();
    SessionSearch.dbPathOverrideForTest = null;
    root.deleteSync(recursive: true);
  });

  test('storedRowCount reflects indexed rows and isEmpty is false', () async {
    await search.reindex([
      session('a', 'alpha'),
      session('b', 'beta'),
    ]);
    expect(await search.storedRowCount(), 2);
    expect(await search.isEmpty(), isFalse);
  });

  test('clear drives storedRowCount to zero and isEmpty true', () async {
    await search.reindex([session('a', 'alpha')]);
    expect(await search.storedRowCount(), 1);
    await search.clear();
    expect(await search.storedRowCount(), 0);
    expect(await search.isEmpty(), isTrue);
  });

  test('missing database reports zero without throwing', () async {
    SessionSearch.dbPathOverrideForTest = '${root.path}/absent.db';
    expect(await search.storedRowCount(), 0);
    expect(await search.isEmpty(), isTrue);
  });
}
