import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/native_plugins/data_utilities.dart';
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

  group('SQL protected tokens', () {
    final sql = SqlFormatterCapability();
    for (final literal in [
      "'from  where\nand ''or'''",
      '"from  where"',
      '`from  where`',
      '[from  where]',
      r'$tag$from  where$tag$',
    ]) {
      test('preserves $literal', () async {
        final out = await sql.callTool('format', {
          'sql': 'select $literal from t',
        });
        expect(out, contains(literal));
      });
    }
    test('preserves comment contents and terminating newline', () async {
      final out = await sql.callTool('format', {
        'sql': "select 1 -- where  ' (\nfrom t /* select  ) */ where a=1",
      });
      expect(out, contains("-- where  ' (\n"));
      expect(out, contains('/* select  ) */'));
      final result = jsonDecode(await sql.callTool('validate', {'sql': out}));
      expect(result['valid'], true);
    });
    for (final text in [
      'select from',
      'select 1 nonsense garbage',
      'create totally invalid',
      'select 1; delete from t',
      'select /* unclosed',
    ]) {
      test('never certifies unsupported or malformed $text', () async {
        final result = jsonDecode(
          await sql.callTool('validate', {'sql': text}),
        );
        expect(result['valid'], isNot(true));
        expect(result['errors'], isNotEmpty);
      });
    }
    test('SQLite executes formatted string/comment/operator corpus', () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      const source = "select 'a  b\nc''d' as \"from  x\", 1+2 as n -- keep\n";
      final formatted = await sql.callTool('format', {'sql': source});
      expect(db.select(formatted).single, db.select(source).single);
    });
    test(
      'formatter preserves SQL with no whitespace, operators, and comments',
      () async {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        for (final source in [
          'select(1+2)',
          'select 1-- note\n+2',
          "select x'4142' as hex_value, 1/*ok*/+2 as total",
          'select 1||2 as joined',
        ]) {
          final output = await sql.callTool('format', {'sql': source});
          expect(
            db.select(output).single,
            db.select(source).single,
            reason: 'Source: $source; formatted: $output',
          );
        }
      },
    );
    test(
      'formatter never joins a leading keyword to preceding token',
      () async {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        for (final source in [
          'select 1 union select 2',
          "select 'a' as x from (select 'a' as x)",
          'select 1 --comment\nunion select 2',
          'select 1/* note */union select 2',
        ]) {
          final output = await sql.callTool('format', {'sql': source});
          expect(
            db.select(output).map((r) => r.values.toList()).toList(),
            db.select(source).map((r) => r.values.toList()).toList(),
            reason: 'Source: $source; formatted: $output',
          );
        }
      },
    );
    test(
      'validate rejects invalid projection and dialect-only syntax',
      () async {
        for (final source in [
          "select 1 2",
          'select (1)',
          'select * from [table]',
        ]) {
          final result = jsonDecode(
            await sql.callTool('validate', {
              'sql': source,
              'dialect': 'postgres',
            }),
          );
          expect(result['valid'], false, reason: source);
        }
      },
    );
    test(
      'validate does not certify a literal masquerading as a clause',
      () async {
        for (final source in [
          'select \'FROM\' as "WHERE"',
          'select 1/* FROM t */',
          'select 1 where 1 = 1',
        ]) {
          final result = jsonDecode(
            await sql.callTool('validate', {'sql': source}),
          );
          expect(result['valid'], true, reason: source);
          expect(result['scope'], 'select_subset_syntax_only');
        }
        final invalid = jsonDecode(
          await sql.callTool('validate', {
            'sql': 'select 1; drop table customers',
          }),
        );
        expect(invalid['valid'], false);
      },
    );
    test(
      'SQL supported grammar does not claim syntactic support for missing source',
      () async {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        for (final source in [
          'SELECT id FROM nonexistent',
          'SELECT a WHERE b = 1',
        ]) {
          final result = jsonDecode(
            await sql.callTool('validate', {'sql': source}),
          );
          expect(result['scope'], 'select_subset_syntax_only');
          expect(() => db.select(source), throwsA(isA<SqliteException>()));
        }
      },
    );
    test(
      'validation rejects unsupported identifier escapes in PostgreSQL',
      () async {
        for (final source in [
          'select 1 as `named`',
          'select 1 as [named]',
          "select E'it\\'s'",
          'select 1 where 1 is null',
        ]) {
          final result = jsonDecode(
            await sql.callTool('validate', {
              'sql': source,
              'dialect': 'postgres',
            }),
          );
          expect(result['valid'], false, reason: source);
        }
      },
    );
    test('validation schema exposes the actual supported dialect selector', () {
      final tool = sql.tools.singleWhere((t) => t.name == 'validate');
      expect((tool.inputSchema['properties'] as Map).keys, contains('dialect'));
    });
    test(
      'SQL formatter does not change comment placement around operations',
      () async {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        for (final source in [
          'select 2/* keep  */+3 as n',
          'select 1-- keep\n+2 as n',
          'select "from" from (select 42 as "from")',
        ]) {
          final formatted = await sql.callTool('format', {'sql': source});
          expect(
            db.select(formatted).single.values.toList(),
            db.select(source).single.values.toList(),
            reason: source,
          );
        }
      },
    );
    test(
      'SQL formatter keeps comments adjacent to names from becoming identifiers',
      () async {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        const source = 'select 1 as a/* boundary */from (select 1 as a)';
        final output = await sql.callTool('format', {'sql': source});
        expect(
          db.select(output).single.values.toList(),
          db.select(source).single.values.toList(),
        );
      },
    );
    test(
      'validator does not treat quoted FROM or comment SELECT as statement start',
      () async {
        final valid = jsonDecode(
          await sql.callTool('validate', {
            'sql': "-- prefix SELECT\nSELECT 'FROM' AS \"SELECT\" FROM t",
          }),
        );
        expect(valid['valid'], true);
        final invalid = jsonDecode(
          await sql.callTool('validate', {'sql': "'SELECT' -- only a comment"}),
        );
        expect(invalid['valid'], false);
      },
    );
    test('formatter preserves double-quoted escaped identifiers', () async {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      const source = 'select 7 as "a"" FROM b" -- x\n';
      final formatted = await sql.callTool('format', {'sql': source});
      expect(formatted, contains('"a"" FROM b"'));
      expect(
        db.select(formatted).single.keys.toList(),
        db.select(source).single.keys.toList(),
      );
    });
    test('SQL format declines unterminated protected regions', () async {
      for (final source in [
        "select 'x",
        'select "x',
        'select /* x',
        'select `x',
        'select [x',
        r'select $tag$x',
      ]) {
        await expectLater(
          sql.callTool('format', {'sql': source}),
          throwsFormatException,
          reason: source,
        );
      }
    });
    test(
      'SQL validator rejects unsupported dollar strings as valid SELECT subset',
      () async {
        final result = jsonDecode(
          await sql.callTool('validate', {
            'sql': r'SELECT $tag$something$tag$',
            'dialect': 'postgres',
          }),
        );
        expect(result['valid'], false);
        expect(result['scope'], 'select_subset_syntax_only');
      },
    );
    test(
      'SQL formatter preserves separate statements without merging tokens',
      () async {
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        const source = 'select 1; select 2';
        final formatted = await sql.callTool('format', {'sql': source});
        expect(formatted, contains(';'));
        expect(
          db.select(formatted).first.values.toList(),
          db.select(source).first.values.toList(),
        );
        final validated = jsonDecode(
          await sql.callTool('validate', {'sql': formatted}),
        );
        expect(validated['valid'], false);
      },
    );
    test(
      'SQL validator never certifies unbalanced parentheses hidden by comments',
      () async {
        for (final source in [
          'SELECT 1 /* ( */ )',
          'SELECT (1',
          'SELECT 1 -- )\n)',
        ]) {
          final result = jsonDecode(
            await sql.callTool('validate', {'sql': source}),
          );
          expect(result['valid'], false, reason: source);
        }
      },
    );
    test('SQL validator has a bounded maximum nesting depth', () async {
      final source = 'select ${'(' * 65}1${')' * 65}';
      final result = jsonDecode(
        await sql.callTool('validate', {'sql': source}),
      );
      expect(result['valid'], false);
      expect(result['errors'], isNotEmpty);
    });
  });

  group('cron', () {
    final cron = CronDesignerCapability();
    Future<Map<String, dynamic>> runs(
      String expression,
      String start, {
      int count = 1,
      String timezone = 'UTC',
      int horizon = 2928,
    }) async =>
        jsonDecode(
              await cron.callTool('next_runs', {
                'expression': expression,
                'start_time': start,
                'count': count,
                'timezone': timezone,
                'horizon_days': horizon,
              }),
            )
            as Map<String, dynamic>;

    test('monthly accepts day 31', () async {
      expect(
        await cron.callTool('build', {
          'frequency': 'monthly',
          'days': [15, 31],
          'time': '10:30',
        }),
        '30 10 15,31 * *',
      );
    });
    test('restricted DOM/DOW uses OR in matching and explanation', () async {
      expect(
        (await runs('0 0 13 * 1', '2026-01-11T00:00:00Z', count: 2))['runs'],
        ['2026-01-12T00:00:00.000Z', '2026-01-13T00:00:00.000Z'],
      );
      expect(
        await cron.callTool('explain', {'expression': '0 0 13 * 1'}),
        contains(' or '),
      );
    });
    test('wildcard-step DOM retains cron AND semantics', () async {
      expect((await runs('0 0 */2 * 1', '2026-01-11T00:00:00Z'))['runs'], [
        '2026-01-19T00:00:00.000Z',
      ]);
    });
    test('leap occurrence beyond one year', () async {
      expect((await runs('0 0 29 2 *', '2025-03-01T00:00:00Z'))['runs'], [
        '2028-02-29T00:00:00.000Z',
      ]);
    });
    test('impossible date reports horizon exhaustion', () async {
      final result = await runs(
        '0 0 31 2 *',
        '2026-01-01T00:00:00Z',
        horizon: 366,
      );
      expect(result['runs'], isEmpty);
      expect(result['complete'], false);
      expect(result['reason'], 'horizon_exhausted');
    });
    test('fixed offset and exclusive start instant', () async {
      expect(
        (await runs(
          '0 9 * * *',
          '2026-01-01T09:00:00+05:30',
          timezone: '+05:30',
        ))['runs'],
        ['2026-01-02T03:30:00.000Z'],
      );
    });
    test(
      'exclusive instant preserves seconds and avoids same-minute matches',
      () async {
        expect(
          (await runs('* * * * *', '2026-01-01T00:00:15Z', count: 2))['runs'],
          ['2026-01-01T00:01:00.000Z', '2026-01-01T00:02:00.000Z'],
        );
        expect(
          (await runs('* * * * *', '2026-01-01T00:00:59Z', horizon: 1))['runs'],
          ['2026-01-01T00:01:00.000Z'],
        );
      },
    );
    test(
      'explicit horizon includes only instants within start plus days',
      () async {
        final result = await runs(
          '0 0 * * *',
          '2026-01-01T00:00:30Z',
          count: 2,
          horizon: 1,
        );
        expect(result['runs'], ['2026-01-02T00:00:00.000Z']);
        expect(result['complete'], false);
      },
    );
    test('unsupported and invalid timezone offsets are explicit', () async {
      for (final zone in ['Europe/Berlin', '+14:30', '+25:00', '-03:99']) {
        await expectLater(
          runs('0 0 * * *', '2026-01-01T00:00:00Z', timezone: zone),
          throwsA(anyOf(isA<FormatException>(), isA<UnsupportedError>())),
        );
      }
    });
    test('Sunday alias 7 matches and fixed offset midnight boundary', () async {
      expect(
        (await runs(
          '0 0 * * 7',
          '2026-01-03T00:00:00Z',
          timezone: '+05:30',
        ))['runs'],
        ['2026-01-03T18:30:00.000Z'],
      );
    });
    test(
      'weekday step 0/2 retains Sunday alias without inventing Tuesdays',
      () async {
        final result = await runs(
          '0 0 * * 0/2',
          '2026-01-03T00:00:00Z',
          count: 3,
        );
        expect(result['runs'], [
          '2026-01-04T00:00:00.000Z',
          '2026-01-06T00:00:00.000Z',
          '2026-01-08T00:00:00.000Z',
        ]);
      },
    );
    test(
      'restricted DOM list with wildcard item follows wildcard DOM/DOW rule',
      () async {
        final result = await runs(
          '0 0 *,13 * 1',
          '2026-01-11T00:00:00Z',
          count: 2,
        );
        expect(result['runs'], [
          '2026-01-12T00:00:00.000Z',
          '2026-01-19T00:00:00.000Z',
        ]);
      },
    );
    test(
      'wildcard step in a non-leading list item still restricts both days',
      () async {
        final result = await runs(
          '0 0 13,*/2 * 1',
          '2026-01-11T00:00:00Z',
          count: 2,
        );
        expect(result['runs'], [
          '2026-01-19T00:00:00.000Z',
          '2026-02-09T00:00:00.000Z',
        ]);
      },
    );
    test('build rejects fractional weekday and monthly day values', () async {
      for (final frequency in ['weekly', 'monthly']) {
        await expectLater(
          cron.callTool('build', {
            'frequency': frequency,
            'days': [1.5],
          }),
          throwsFormatException,
        );
      }
    });
    test('cron rejects invalid field bounds and zero step', () async {
      for (final expression in [
        '60 * * * *',
        '0 24 * * *',
        '0 0 0 * *',
        '0 0 * 13 *',
        '0 0 * * 8',
        '*/0 * * * *',
        '0 0 * * 6-1',
      ]) {
        await expectLater(
          cron.callTool('explain', {'expression': expression}),
          throwsFormatException,
          reason: expression,
        );
      }
    });
    test('cron does not silently clamp invalid count or horizon', () async {
      for (final pair in [
        {'count': 0},
        {'count': 101},
        {'horizon_days': 0},
        {'horizon_days': 2929},
      ]) {
        await expectLater(
          cron.callTool('next_runs', {'expression': '* * * * *', ...pair}),
          throwsFormatException,
          reason: '$pair',
        );
      }
    });
    test('explain lists only actual stepped weekdays', () async {
      final explanation = await cron.callTool('explain', {
        'expression': '0 9 * * 1/2',
      });
      expect(explanation, contains('Monday, Wednesday, Friday'));
      expect(explanation, isNot(contains('Tuesday, Thursday')));
    });
    test('rejects unsupported named zones and naive instants', () async {
      await expectLater(
        runs('* * * * *', '2026-01-01T00:00:00Z', timezone: 'Mars/Base'),
        throwsA(isA<UnsupportedError>()),
      );
      await expectLater(
        runs('* * * * *', '2026-01-01T00:00:00'),
        throwsFormatException,
      );
    });
    test(
      'explains stepped month without crashing or dropping the step',
      () async {
        expect(
          await cron.callTool('explain', {'expression': '0 0 * */2 *'}),
          contains('January, March'),
        );
      },
    );
    test(
      'explain reports OR for restricted days and AND for stepped wildcard',
      () async {
        final restricted = await cron.callTool('explain', {
          'expression': '0 0 13 * 1',
        });
        final stepped = await cron.callTool('explain', {
          'expression': '0 0 */2 * 1',
        });
        expect(restricted, contains('or on Monday'));
        expect(stepped, contains('and on Monday'));
      },
    );
  });

  group('DDL', () {
    final designer = DbDesignerCapability();
    Map<String, dynamic> schema(List<Map<String, dynamic>> columns) => {
      'tables': [
        {'name': 'order', 'columns': columns},
      ],
    };
    test(
      'composite primary key executes and enforces uniqueness/nullability',
      () async {
        final ddl = await designer.callTool('generate_ddl', {
          'dialect': 'sqlite',
          'schema': schema([
            {'name': 'a', 'type': 'INTEGER', 'primary_key': true},
            {'name': 'b', 'type': 'TEXT', 'primary_key': true},
            {'name': 'label', 'type': 'VARCHAR(20)', 'default': "'it''s ok'"},
          ]),
        });
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        db.execute(ddl);
        db.execute('INSERT INTO "order" (a,b) VALUES (1,\'x\')');
        expect(
          db.select('SELECT label FROM "order"').single['label'],
          "it's ok",
        );
        expect(
          () => db.execute('INSERT INTO "order" (a,b) VALUES (1,\'x\')'),
          throwsA(isA<SqliteException>()),
        );
        expect(
          () => db.execute('INSERT INTO "order" (a,b) VALUES (2,NULL)'),
          throwsA(isA<SqliteException>()),
        );
      },
    );
    test('reserved and mixed-case foreign references execute', () async {
      final ddl = await designer.callTool('generate_ddl', {
        'dialect': 'sqlite',
        'schema': {
          'tables': [
            {
              'name': 'order',
              'columns': [
                {'name': 'Key', 'type': 'INTEGER', 'primary_key': true},
              ],
            },
            {
              'name': 'child',
              'columns': [
                {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                {
                  'name': 'parent',
                  'type': 'INTEGER',
                  'references': 'order(Key)',
                },
              ],
            },
          ],
        },
      });
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      db.execute('PRAGMA foreign_keys=ON');
      db.execute(ddl);
      db.execute('INSERT INTO "order" VALUES (1)');
      db.execute('INSERT INTO child VALUES (1,1)');
      expect(
        () => db.execute('INSERT INTO child VALUES (2,2)'),
        throwsA(isA<SqliteException>()),
      );
    });
    for (final column in [
      {'type': 'VARCHAR(2)); DROP TABLE x; --'},
      {'type': 'INTEGER(2)'},
      {'type': 'DECIMAL(2,3)'},
      {'type': 'TEXT', 'default': "'x'); DROP TABLE x; --"},
      {'type': 'INTEGER', 'default': 'random()'},
    ]) {
      test('rejects unsupported type/default $column', () async {
        await expectLater(
          designer.callTool('generate_ddl', {
            'schema': schema([
              {'name': 'id', 'primary_key': true, ...column},
            ]),
          }),
          throwsFormatException,
        );
      });
    }
    test(
      'Postgres maps supported aliases and rejects implicit unsupported types',
      () async {
        final ddl = await designer.callTool('generate_ddl', {
          'schema': schema([
            {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
            {'name': 'payload', 'type': 'BLOB'},
            {'name': 'score', 'type': 'DOUBLE'},
          ]),
        });
        expect(ddl, contains('BYTEA'));
        expect(ddl, contains('DOUBLE PRECISION'));
      },
    );
    test(
      'SQLite executes numeric, date and boolean defaults with supported types',
      () async {
        final ddl = await designer.callTool('generate_ddl', {
          'dialect': 'sqlite',
          'schema': schema([
            {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
            {'name': 'ratio', 'type': 'DECIMAL(6,2)', 'default': '2.50'},
            {'name': 'active', 'type': 'BOOLEAN', 'default': 'TRUE'},
            {'name': 'date', 'type': 'DATE', 'default': "'2024-02-29'"},
            {
              'name': 'timestamp',
              'type': 'TIMESTAMP',
              'default': 'CURRENT_TIMESTAMP',
            },
          ]),
        });
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        db.execute(ddl);
        db.execute('INSERT INTO "order" (id) VALUES (1)');
        final row = db
            .select('SELECT ratio,active,date,timestamp FROM "order"')
            .single;
        expect(row['ratio'], 2.5);
        expect(row['active'], 1);
        expect(row['date'], '2024-02-29');
        expect(row['timestamp'], isNotNull);
      },
    );
    test(
      'SQLite rejects a false unique constraint reference at validation',
      () async {
        await expectLater(
          designer.callTool('generate_ddl', {
            'dialect': 'sqlite',
            'schema': {
              'tables': [
                {
                  'name': 'parent',
                  'columns': [
                    {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                    {'name': 'nonunique', 'type': 'INTEGER'},
                  ],
                },
                {
                  'name': 'child',
                  'columns': [
                    {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                    {
                      'name': 'ref',
                      'type': 'INTEGER',
                      'references': 'parent(nonunique)',
                    },
                  ],
                },
              ],
            },
          }),
          throwsFormatException,
        );
      },
    );
    test('Postgres orders referenced tables before dependent tables', () async {
      final ddl = await designer.callTool('generate_ddl', {
        'schema': {
          'tables': [
            {
              'name': 'child',
              'columns': [
                {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                {
                  'name': 'parent_id',
                  'type': 'INTEGER',
                  'references': 'parent(id)',
                },
              ],
            },
            {
              'name': 'parent',
              'columns': [
                {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
              ],
            },
          ],
        },
      });
      expect(
        ddl.indexOf('CREATE TABLE "parent"'),
        lessThan(ddl.indexOf('CREATE TABLE "child"')),
      );
    });
    test(
      'Postgres table ordering produces stable deterministic statements',
      () async {
        final definition = {
          'tables': [
            {
              'name': 'c',
              'columns': [
                {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                {'name': 'b_id', 'type': 'INTEGER', 'references': 'b(id)'},
              ],
            },
            {
              'name': 'b',
              'columns': [
                {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                {'name': 'a_id', 'type': 'INTEGER', 'references': 'a(id)'},
              ],
            },
            {
              'name': 'a',
              'columns': [
                {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
              ],
            },
          ],
        };
        final first = await designer.callTool('generate_ddl', {
          'schema': definition,
        });
        final second = await designer.callTool('generate_ddl', {
          'schema': definition,
        });
        expect(first, second);
        expect(
          first.indexOf('CREATE TABLE "a"'),
          lessThan(first.indexOf('CREATE TABLE "b"')),
        );
        expect(
          first.indexOf('CREATE TABLE "b"'),
          lessThan(first.indexOf('CREATE TABLE "c"')),
        );
      },
    );
    test(
      'Postgres rejects cyclic foreign key dependencies explicitly',
      () async {
        await expectLater(
          designer.callTool('generate_ddl', {
            'schema': {
              'tables': [
                {
                  'name': 'left_table',
                  'columns': [
                    {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                    {
                      'name': 'other',
                      'type': 'INTEGER',
                      'references': 'right_table(id)',
                    },
                  ],
                },
                {
                  'name': 'right_table',
                  'columns': [
                    {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                    {
                      'name': 'other',
                      'type': 'INTEGER',
                      'references': 'left_table(id)',
                    },
                  ],
                },
              ],
            },
          }),
          throwsFormatException,
        );
      },
    );
    test(
      'SQLite enforces a unique foreign-key target independently of declaration order',
      () async {
        final ddl = await designer.callTool('generate_ddl', {
          'dialect': 'sqlite',
          'schema': {
            'tables': [
              {
                'name': 'child',
                'columns': [
                  {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                  {
                    'name': 'parent_code',
                    'type': 'TEXT',
                    'references': 'parent(code)',
                  },
                ],
              },
              {
                'name': 'parent',
                'columns': [
                  {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                  {'name': 'code', 'type': 'TEXT', 'unique': true},
                ],
              },
            ],
          },
        });
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        db.execute('PRAGMA foreign_keys=ON');
        db.execute(ddl);
        db.execute("INSERT INTO parent(id,code) VALUES (1,'key')");
        db.execute("INSERT INTO child(id,parent_code) VALUES (1,'key')");
        expect(
          () => db.execute(
            "INSERT INTO child(id,parent_code) VALUES (2,'missing')",
          ),
          throwsA(isA<SqliteException>()),
        );
      },
    );
    test(
      'SQLite accepts all advertised column types in executable DDL',
      () async {
        const types = [
          'SMALLINT',
          'BIGINT',
          'SERIAL',
          'BIGSERIAL',
          'TEXT',
          'VARCHAR(8)',
          'CHAR(3)',
          'CLOB',
          'BOOLEAN',
          'REAL',
          'FLOAT',
          'DOUBLE',
          'NUMERIC(5,2)',
          'DECIMAL(5,2)',
          'TIMESTAMP',
          'DATE',
          'TIME',
          'BLOB',
          'BYTEA',
          'UUID',
          'JSON',
          'JSONB',
        ];
        final ddl = await designer.callTool('generate_ddl', {
          'dialect': 'sqlite',
          'schema': schema([
            {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
            for (var i = 0; i < types.length; i++)
              {'name': 'c$i', 'type': types[i]},
          ]),
        });
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        db.execute(ddl);
        expect(
          db.select('PRAGMA table_info("order")'),
          hasLength(types.length + 1),
        );
      },
    );
    test(
      'SQLite rejects duplicated case-insensitive table or column names',
      () async {
        for (final definition in [
          {
            'tables': [
              {
                'name': 'Items',
                'columns': [
                  {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                ],
              },
              {
                'name': 'items',
                'columns': [
                  {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                ],
              },
            ],
          },
          schema([
            {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
            {'name': 'ID', 'type': 'TEXT'},
          ]),
        ]) {
          await expectLater(
            designer.callTool('generate_ddl', {
              'schema': definition,
              'dialect': 'sqlite',
            }),
            throwsFormatException,
          );
        }
      },
    );
    test(
      'schema validator rejects unknown dialect instead of claiming success',
      () async {
        await expectLater(
          designer.callTool('generate_ddl', {
            'schema': schema([
              {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
            ]),
            'dialect': 'mysql',
          }),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
    test(
      'Postgres serial primary key uses type and generated default correctly',
      () async {
        final ddl = await designer.callTool('generate_ddl', {
          'schema': schema([
            {'name': 'id', 'type': 'SERIAL', 'primary_key': true},
          ]),
        });
        expect(ddl, contains('"id" SERIAL PRIMARY KEY'));
        expect(ddl, isNot(contains('DEFAULT')));
      },
    );
    test(
      'SQLite serial primary key autogenerates a new integer rowid',
      () async {
        final ddl = await designer.callTool('generate_ddl', {
          'dialect': 'sqlite',
          'schema': schema([
            {'name': 'id', 'type': 'SERIAL', 'primary_key': true},
          ]),
        });
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        db.execute(ddl);
        db.execute('INSERT INTO "order" DEFAULT VALUES');
        db.execute('INSERT INTO "order" DEFAULT VALUES');
        expect(
          db.select('SELECT id FROM "order" ORDER BY id').map((r) => r['id']),
          [1, 2],
        );
      },
    );
    test(
      'SQLite BIGSERIAL primary key does not promise autoincrement',
      () async {
        final ddl = await designer.callTool('generate_ddl', {
          'dialect': 'sqlite',
          'schema': schema([
            {'name': 'id', 'type': 'BIGSERIAL', 'primary_key': true},
          ]),
        });
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        db.execute(ddl);
        db.execute('INSERT INTO "order" DEFAULT VALUES');
        expect(db.select('SELECT id FROM "order"').single['id'], 1);
      },
    );
    test('SQLite date default rejects impossible leap day', () async {
      await expectLater(
        designer.callTool('generate_ddl', {
          'dialect': 'sqlite',
          'schema': schema([
            {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
            {'name': 'created', 'type': 'DATE', 'default': "'2025-02-29'"},
          ]),
        }),
        throwsFormatException,
      );
    });
    test('SQLite reference cannot target a composite-key component', () async {
      final definition = {
        'tables': [
          {
            'name': 'parent',
            'columns': [
              {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
              {'name': 'tenant', 'type': 'INTEGER', 'primary_key': true},
            ],
          },
          {
            'name': 'child',
            'columns': [
              {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
              {
                'name': 'parent_id',
                'type': 'INTEGER',
                'references': 'parent(id)',
              },
            ],
          },
        ],
      };
      await expectLater(
        designer.callTool('generate_ddl', {
          'schema': definition,
          'dialect': 'sqlite',
        }),
        throwsFormatException,
      );
    });
    test('SQLite enforces TEXT primary key not-null constraint', () async {
      final ddl = await designer.callTool('generate_ddl', {
        'schema': schema([
          {'name': 'code', 'type': 'TEXT', 'primary_key': true},
        ]),
        'dialect': 'sqlite',
      });
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      db.execute(ddl);
      expect(
        () => db.execute('INSERT INTO "order" DEFAULT VALUES'),
        throwsA(isA<SqliteException>()),
      );
    });
    test(
      'SQLite single-column foreign key value type matches referenced type',
      () async {
        final definition = {
          'tables': [
            {
              'name': 'parent',
              'columns': [
                {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
              ],
            },
            {
              'name': 'child',
              'columns': [
                {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
                {
                  'name': 'parent_id',
                  'type': 'TEXT',
                  'references': 'parent(id)',
                },
              ],
            },
          ],
        };
        await expectLater(
          designer.callTool('generate_ddl', {
            'schema': definition,
            'dialect': 'sqlite',
          }),
          throwsFormatException,
        );
      },
    );
    test(
      'SQLite preserves a quoted literal default with doubled quotes',
      () async {
        final ddl = await designer.callTool('generate_ddl', {
          'dialect': 'sqlite',
          'schema': schema([
            {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
            {'name': 'message', 'type': 'TEXT', 'default': "'it''s fine'"},
          ]),
        });
        final db = sqlite3.openInMemory();
        addTearDown(db.dispose);
        db.execute(ddl);
        db.execute('INSERT INTO "order" (id) VALUES (1)');
        expect(
          db.select('SELECT message FROM "order"').single['message'],
          "it's fine",
        );
      },
    );
    test(
      'schema validation returns invalid on syntactically unsupported type or field',
      () async {
        for (final column in [
          {'name': 'id', 'type': 'INTEGER(2)', 'primary_key': true},
          {
            'name': 'id',
            'type': 'INTEGER',
            'primary_key': true,
            'deferrable': true,
          },
        ]) {
          final result = jsonDecode(
            await designer.callTool('validate_schema', {
              'schema': schema([column]),
            }),
          );
          expect(result['valid'], false, reason: '$column');
        }
      },
    );
    for (final column in [
      {'type': 'DATE', 'default': "'not-a-date'"},
      {'type': 'DATE', 'default': 'CURRENT_TIME'},
      {'type': 'SMALLINT', 'default': '999999'},
      {'type': 'VARCHAR(2)', 'default': "'long'"},
      {'type': 'TEXT', 'nullable': 'maybe'},
      {'type': 'TEXT', 'check': 'length(id)>0'},
    ]) {
      test(
        'rejects incompatible defaults or silently ignored constraints $column',
        () async {
          await expectLater(
            designer.callTool('generate_ddl', {
              'schema': schema([
                {'name': 'id', 'primary_key': true, ...column},
              ]),
            }),
            throwsFormatException,
          );
        },
      );
    }
  });
}
