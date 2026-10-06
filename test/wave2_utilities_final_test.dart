import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugins/data_utilities.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';
import 'package:ovid_ai/core/native_plugins/web_and_db_utilities.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  setUpAll(
    () => open.overrideFor(
      OperatingSystem.linux,
      () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
    ),
  );

  test('SELECT subset rejects aliased star rejected by SQLite', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    db.execute('CREATE TABLE t (id INTEGER)');
    const source = 'SELECT * AS alias FROM t';
    expect(() => db.select(source), throwsA(isA<SqliteException>()));
    final result = jsonDecode(
      await SqlFormatterCapability().callTool('validate', {'sql': source}),
    );
    expect(result['valid'], false);
  });

  test(
    'SELECT subset rejects SQLite bracket escaping and nested comments',
    () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      for (final source in [
        'SELECT 1 AS [a]]b]',
        'SELECT 1 /* outer /* inner */ tail */',
      ]) {
        expect(() => db.select(source), throwsA(isA<SqliteException>()));
        final result = jsonDecode(
          await SqlFormatterCapability().callTool('validate', {'sql': source}),
        );
        expect(result['valid'], false, reason: source);
      }
    },
  );

  test('cron refuses normalized invalid calendar dates and offsets', () async {
    for (final start in [
      '2025-02-29T00:00:00Z',
      '2026-13-01T00:00:00Z',
      '2026-01-01T24:00:00Z',
      '2026-01-01T00:00:00+01:99',
    ]) {
      await expectLater(
        CronDesignerCapability().callTool('next_runs', {
          'expression': '* * * * *',
          'start_time': start,
        }),
        throwsFormatException,
        reason: start,
      );
    }
  });

  test(
    'cron explains a wildcard month list without integer parse errors',
    () async {
      final out = await CronDesignerCapability().callTool('explain', {
        'expression': '0 0 * 1,* *',
      });
      expect(out, contains('January'));
      expect(out, contains('December'));
    },
  );

  test('DDL rejects impossible timestamp defaults', () async {
    await expectLater(
      DbDesignerCapability().callTool('generate_ddl', {
        'schema': {
          'tables': [
            {
              'name': 't',
              'columns': [
                {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                {
                  'name': 'created',
                  'type': 'TIMESTAMP',
                  'default': "'2025-02-29T00:00:00Z'",
                },
              ],
            },
          ],
        },
      }),
      throwsFormatException,
    );
  });

  test('DDL CHARACTER alias retains fixed length semantics', () async {
    final ddl = await DbDesignerCapability().callTool('generate_ddl', {
      'schema': {
        'tables': [
          {
            'name': 't',
            'columns': [
              {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
              {'name': 'code', 'type': 'CHARACTER(3)'},
            ],
          },
        ],
      },
    });
    expect(ddl, contains('"code" CHAR(3)'));
  });

  test(
    'JSON output expansion reaches the output limit rather than input cap',
    () async {
      // 64 containers; tiny raw JSON, but deep indentation amplifies each item.
      final raw = '${'[' * 63}[${List.filled(3000, '0').join(',')}]${']' * 63}';
      expect(raw.length, lessThan(262144));
      await expectLater(
        JsonVisualizerCapability().callTool('format', {
          'json_string': raw,
          'indent': 8,
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'limit',
            contains('output limit'),
          ),
        ),
      );
    },
  );

  test('input and output bounds accept boundary and reject next code unit', () {
    checkUtilityInput('x' * 262144);
    expect(() => checkUtilityInput('x' * 262145), throwsFormatException);
    expect(checkUtilityOutput('x' * 1048576).length, 1048576);
    expect(() => checkUtilityOutput('x' * 1048577), throwsFormatException);
  });
}
