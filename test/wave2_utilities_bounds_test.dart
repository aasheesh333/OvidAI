import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/core/native_plugins/data_utilities.dart';
import 'package:ovid_ai/core/native_plugins/dev_utilities.dart';
import 'package:ovid_ai/core/native_plugins/web_and_db_utilities.dart';
import 'package:ovid_ai/core/native_plugins/misc_utilities.dart';
import 'package:ovid_ai/core/native_plugins/utility_limits.dart';

class BodyClient extends http.BaseClient {
  BodyClient(this.body);
  final Stream<List<int>> body;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(body, 200);
}

class _NeverClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

void main() {
  test(
    'JSON rejects depth before recursive decoding and limits indentation',
    () async {
      final json = JsonVisualizerCapability();
      await expectLater(
        json.callTool('stats', {'json_string': '${'[' * 65}0${']' * 65}'}),
        throwsFormatException,
      );
      await expectLater(
        json.callTool('format', {'json_string': '{}', 'indent': 1000000}),
        throwsFormatException,
      );
      expect(
        jsonDecode(
          await json.callTool('minify', {'json_string': '{"brackets":"[[["}'}),
        ),
        {'brackets': '[[['},
      );
    },
  );
  test('JSON accepts deeply nested delimiters inside strings', () async {
    final raw = jsonEncode({'text': '[' * 80 + ']' * 80});
    expect(
      jsonDecode(
        await JsonVisualizerCapability().callTool('minify', {
          'json_string': raw,
        }),
      ),
      {'text': '[' * 80 + ']' * 80},
    );
  });
  test('cyclic map input fails before isolate send', () async {
    final input = <String, dynamic>{};
    input['self'] = input;
    await expectLater(
      DbDesignerCapability().callTool('validate_schema', {'schema': input}),
      throwsFormatException,
    );
  });
  test(
    'invalid numeric arguments do not allocate unbounded resources',
    () async {
      await expectLater(
        JsonVisualizerCapability().callTool('format', {
          'json_string': '{}',
          'indent': 1e100,
        }),
        throwsFormatException,
      );
      await expectLater(
        CronDesignerCapability().callTool('next_runs', {
          'expression': '* * * * *',
          'count': double.infinity,
        }),
        throwsFormatException,
      );
    },
  );
  test('JSON formatting output budget rejects expansion', () async {
    final input = jsonEncode(
      List.generate(
        3000,
        (i) => {
          'name$i': [
            for (var depth = 0; depth < 10; depth++) {'value$depth': 'v' * 15},
          ],
        },
      ),
    );
    await expectLater(
      JsonVisualizerCapability().callTool('format', {
        'json_string': input,
        'indent': 8,
      }),
      throwsFormatException,
    );
  });
  test(
    'CSV retains Unicode, quoted newlines and precise empty fields under bounds',
    () async {
      const input = '"hé,ader",empty\r\n"one\ntwo",""';
      final out = await FileConverterCapability().callTool('csv_to_json', {
        'csv_text': input,
      });
      expect(jsonDecode(out), [
        {'hé,ader': 'one\ntwo', 'empty': ''},
      ]);
    },
  );
  test('utility HTTP cancellable token aborts in-flight body', () async {
    var cancelled = false;
    final body = StreamController<List<int>>(
      onCancel: () {
        cancelled = true;
      },
    );
    addTearDown(body.close);
    final token = UtilityCancellation();
    final pending = boundedUtilityRequest(
      BodyClient(body.stream),
      'GET',
      Uri.parse('https://example.test'),
      cancellation: token,
    );
    final assertion = expectLater(
      pending,
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'reason',
          contains('cancelled'),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    token.cancel();
    await assertion;
    expect(cancelled, true);
  });
  test('utility HTTP rejects invalid deadline rather than hanging', () async {
    final client = BodyClient(const Stream.empty());
    for (final seconds in [0, -1, double.infinity, double.nan, 301]) {
      await expectLater(
        boundedUtilityRequest(
          client,
          'GET',
          Uri.parse('https://example.test'),
          timeoutSeconds: seconds,
        ),
        throwsFormatException,
        reason: '$seconds',
      );
    }
  });
  test(
    'network result source is limited before JSON decoding or rendering',
    () async {
      final body = Stream.value(List.filled(1048577, 65));
      final client = BodyClient(body);
      await expectLater(
        ApiTesterCapability(
          client: client,
        ).callTool('request', {'url': 'https://example.test'}),
        throwsFormatException,
      );
    },
  );
  test('HTTP timeout includes send() before response headers', () async {
    final hanging = _NeverClient();
    final stopwatch = Stopwatch()..start();
    await expectLater(
      boundedUtilityRequest(
        hanging,
        'GET',
        Uri.parse('https://example.test'),
        timeoutSeconds: 0.05,
      ),
      throwsFormatException,
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });
  test(
    'utility HTTP detects oversized response across separate chunks',
    () async {
      final controller = StreamController<List<int>>();
      addTearDown(controller.close);
      final pending = boundedUtilityRequest(
        BodyClient(controller.stream),
        'GET',
        Uri.parse('https://example.test'),
        maxBytes: 1024,
      );
      final assertion = expectLater(pending, throwsFormatException);
      controller.add(List.filled(600, 65));
      controller.add(List.filled(500, 66));
      await assertion;
    },
  );
  test('HTTP accepts body exactly at configured byte cap', () async {
    final client = BodyClient(Stream.value(List.filled(1024, 65)));
    final response = await boundedUtilityRequest(
      client,
      'GET',
      Uri.parse('https://example.test'),
      maxBytes: 1024,
    );
    expect(response.bodyBytes, hasLength(1024));
  });
  test(
    'HTTP cancellation after success does not invalidate completed result',
    () async {
      final token = UtilityCancellation();
      final client = BodyClient(Stream.value('ok'.codeUnits));
      final response = await boundedUtilityRequest(
        client,
        'GET',
        Uri.parse('https://example.test'),
        cancellation: token,
      );
      token.cancel();
      expect(response.body, 'ok');
    },
  );
  test('pre-cancelled utility HTTP fails before opening connection', () async {
    final token = UtilityCancellation()..cancel();
    await expectLater(
      boundedUtilityRequest(
        _NeverClient(),
        'GET',
        Uri.parse('https://example.test'),
        cancellation: token,
      ),
      throwsFormatException,
    );
  });
  test('scraper match budget rejects large repeated tag inputs', () async {
    final html = List.filled(1001, '<p>x</p>').join();
    await expectLater(
      WebScraperProCapability().callTool('extract', {'html': html}),
      throwsFormatException,
    );
  });
  test('CSV input cap prevents reading oversized record payload', () async {
    await expectLater(
      FileConverterCapability().callTool('csv_to_json', {
        'csv_text': 'header\n${'a' * 262144}',
      }),
      throwsFormatException,
    );
  });
  test(
    'regex remains independently isolated from utility concurrency',
    () async {
      final result = await RegexBuilderCapability().callTool('test', {
        'pattern': 'x+',
        'text': 'xxx',
      });
      final decoded = jsonDecode(result);
      expect(decoded['count'], 1);
    },
  );
  test('JSON output budget leaves caller responsive after rejection', () async {
    final input = jsonEncode(
      List.generate(
        3000,
        (i) => {
          'name$i': [
            for (var j = 0; j < 10; j++) {'value': 'v' * 15},
          ],
        },
      ),
    );
    final json = JsonVisualizerCapability();
    await expectLater(
      json.callTool('format', {'json_string': input, 'indent': 8}),
      throwsFormatException,
    );
    expect(
      await json.callTool('minify', {'json_string': '{"ok":true}'}),
      '{"ok":true}',
    );
  });
  test(
    'database DDL output does not silently truncate large schemas',
    () async {
      final tables = [
        for (var table = 0; table < 64; table++)
          {
            'name': 'table_$table',
            'columns': [
              {'name': 'id', 'type': 'INTEGER', 'primary_key': true},
              for (var i = 0; i < 100; i++)
                {'name': 'column_${i}_${'a' * 40}', 'type': 'VARCHAR(10)'},
            ],
          },
      ];
      await expectLater(
        DbDesignerCapability().callTool('generate_ddl', {
          'schema': {'tables': tables},
          'dialect': 'sqlite',
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'CSV refuses amplification instead of returning oversized output',
    () async {
      final csv = FileConverterCapability();
      final input = '${'a' * 10000}\n${List.filled(500, 'x').join('\n')}';
      await expectLater(
        csv.callTool('csv_to_json', {'csv_text': input}),
        throwsFormatException,
      );
    },
  );
  test('sparse JSON to CSV refuses rectangular amplification', () async {
    final input = jsonEncode(List.generate(1500, (i) => {'c$i': i}));
    await expectLater(
      FileConverterCapability().callTool('json_to_csv', {'json_text': input}),
      throwsFormatException,
    );
  });
  test('SQL and diagram input caps reject before scanning', () async {
    await expectLater(
      SqlFormatterCapability().callTool('format', {'sql': 'x' * 262145}),
      throwsFormatException,
    );
    await expectLater(
      MermaidDiagramsCapability().callTool('validate', {'text': 'x' * 262145}),
      throwsFormatException,
    );
  });
  test('scraper refuses oversized input', () async {
    await expectLater(
      WebScraperProCapability().callTool('extract', {
        'html': '<p>${'x' * 262145}</p>',
      }),
      throwsFormatException,
    );
  });
  test('Excalidraw rejects excessive nested scene data', () async {
    await expectLater(
      ExcalidrawBridgeCapability().callTool('stats', {
        'json_text': '{"elements":[{"x":${'[' * 65}0${']' * 65}}]}',
      }),
      throwsFormatException,
    );
  });
  test(
    'Excalidraw add_text rejects aggregate input above configured limit',
    () async {
      final elements = [
        for (var i = 0; i < 300; i++) {'type': 'text', 'text': 'x' * 400},
      ];
      await expectLater(
        ExcalidrawBridgeCapability().callTool('add_text', {
          'json_text': jsonEncode({'elements': elements}),
          'text': 'z' * 200000,
        }),
        throwsA(isA<FormatException>()),
      );
    },
  );
  test('Excalidraw merge rejects duplicated scene amplification', () async {
    final scene = jsonEncode({
      'elements': [
        {'type': 'text', 'text': 'x' * 120000},
      ],
    });
    final out = await ExcalidrawBridgeCapability().callTool('merge', {
      'a_json': scene,
      'b_json': scene,
    });
    expect(out.length, lessThanOrEqualTo(1048576));
  });
  for (final family in ['mermaid', 'icon', 'font', 'audio']) {
    test(
      '$family refuses oversized response without truncated success',
      () async {
        final client = BodyClient(Stream.value(List.filled(1048577, 65)));
        if (family == 'mermaid') {
          await expectLater(
            MermaidDiagramsCapability(
              client: client,
            ).callTool('render', {'text': 'graph TD;A-->B'}),
            throwsFormatException,
          );
        } else if (family == 'icon') {
          await expectLater(
            IconLibraryCapability(
              client: client,
            ).callTool('search', {'query': 'home'}),
            throwsFormatException,
          );
        } else if (family == 'font') {
          await expectLater(
            FontPreviewCapability(
              client: client,
            ).callTool('search', {'query': 'sans'}),
            throwsFormatException,
          );
        } else {
          // Audio transport uses the same bounded collector; its configured
          // credential/platform-store path is covered by the existing suite.
          await expectLater(
            boundedUtilityRequest(
              client,
              'POST',
              Uri.parse('https://example.test'),
            ),
            throwsFormatException,
          );
        }
      },
    );
  }
  for (final clip in [false, true]) {
    test(
      '${clip ? 'clipper' : 'API'} limits streamed body and cancels source',
      () async {
        var cancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () {
            cancelled = true;
          },
        );
        addTearDown(body.close);
        final client = BodyClient(body.stream);
        final capability = clip
            ? WebClipperCapability(client: client)
            : ApiTesterCapability(client: client);
        final pending = capability.callTool(clip ? 'clip' : 'request', {
          'url': 'https://example.test',
        });
        final assertion = expectLater(pending, throwsFormatException);
        body.add(List.filled(1048577, 65));
        await assertion;
        expect(cancelled, true);
      },
    );
    test(
      '${clip ? 'clipper' : 'API'} times out stalled body and cancels source',
      () async {
        var cancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () {
            cancelled = true;
          },
        );
        addTearDown(body.close);
        final client = BodyClient(body.stream);
        final capability = clip
            ? WebClipperCapability(client: client)
            : ApiTesterCapability(client: client);
        await expectLater(
          capability
              .callTool(clip ? 'clip' : 'request', {
                'url': 'https://example.test',
                'timeout_seconds': 0.05,
              })
              .timeout(const Duration(seconds: 2)),
          throwsFormatException,
        );
        expect(cancelled, true);
      },
    );
  }
}
