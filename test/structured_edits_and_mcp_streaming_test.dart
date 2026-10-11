import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/hook_service.dart';
import 'package:ovid_ai/core/mcp_client_requests.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/structured_edits.dart';
import 'package:ovid_ai/core/subagent_tools.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.directory);
  final Directory directory;
  @override
  Future<String?> getApplicationDocumentsPath() async => directory.path;
  @override
  Future<String?> getApplicationSupportPath() async => directory.path;
  @override
  Future<String?> getTemporaryPath() async => directory.path;
}

const _notebook = {
  'cells': [
    {
      'cell_type': 'markdown',
      'id': 'intro',
      'metadata': {
        'tags': ['title'],
      },
      'source': ['# Title\n', 'text'],
    },
    {
      'cell_type': 'code',
      'id': 'calc',
      'metadata': {'collapsed': false},
      'execution_count': 3,
      'outputs': [
        {
          'output_type': 'stream',
          'name': 'stdout',
          'text': ['2\n'],
        },
      ],
      'source': ['print(1 + 1)'],
    },
  ],
  'metadata': {
    'kernelspec': {'name': 'python3', 'display_name': 'Python 3'},
  },
  'nbformat': 4,
  'nbformat_minor': 5,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MultiEdit core', () {
    test('applies edits sequentially, each on the previous result', () {
      final out = applyMultiEdit('a b c', const [
        TextEdit(oldString: 'a', newString: 'x'),
        TextEdit(oldString: 'x b', newString: 'y'),
      ]);
      expect(out, 'y c');
    });

    test('is atomic: a failing edit throws and nothing is returned', () {
      expect(
        () => applyMultiEdit('one two', const [
          TextEdit(oldString: 'one', newString: '1'),
          TextEdit(oldString: 'missing', newString: '?'),
        ]),
        throwsA(
          isA<StructuredEditException>().having(
            (e) => e.message,
            'message',
            contains('edit 2'),
          ),
        ),
      );
    });

    test('uniqueness unless replace_all; identical strings refused', () {
      expect(
        () => applyMultiEdit('x x', const [
          TextEdit(oldString: 'x', newString: 'y'),
        ]),
        throwsA(
          isA<StructuredEditException>().having(
            (e) => e.message,
            'm',
            contains('matches 2 times'),
          ),
        ),
      );
      expect(
        applyMultiEdit('x x', const [
          TextEdit(oldString: 'x', newString: 'y', replaceAll: true),
        ]),
        'y y',
      );
      expect(
        () => applyMultiEdit('x', const [
          TextEdit(oldString: 'x', newString: 'x'),
        ]),
        throwsA(isA<StructuredEditException>()),
      );
    });

    test('creates a missing file only via an empty first old_string', () {
      expect(
        applyMultiEdit(null, const [
          TextEdit(oldString: '', newString: 'hello world'),
          TextEdit(oldString: 'world', newString: 'there'),
        ]),
        'hello there',
      );
      expect(
        () => applyMultiEdit(null, const [
          TextEdit(oldString: 'a', newString: 'b'),
        ]),
        throwsA(isA<StructuredEditException>()),
      );
    });
  });

  group('NotebookEdit core', () {
    final src = jsonEncode(_notebook);

    test('replace keeps metadata, id and outputs', () {
      final out =
          jsonDecode(
                applyNotebookEdit(src, cellId: 'calc', newSource: 'x = 2\nx'),
              )
              as Map;
      final cell = (out['cells'] as List)[1] as Map;
      expect(cell['source'], ['x = 2\n', 'x']);
      expect(cell['id'], 'calc');
      expect(cell['outputs'], (_notebook['cells'] as List)[1]['outputs']);
      expect(cell['metadata'], {'collapsed': false});
      expect(out['metadata'], _notebook['metadata']);
      expect(out['nbformat_minor'], 5);
    });

    test('insert after a cell / at the start, delete — round trip', () {
      var nb = applyNotebookEdit(
        src,
        cellId: 'intro',
        newSource: 'import os',
        cellType: 'code',
        mode: NotebookEditMode.insert,
      );
      var cells = (jsonDecode(nb) as Map)['cells'] as List;
      expect(cells.map((c) => c['cell_type']), ['markdown', 'code', 'code']);
      final newId = cells[1]['id'] as String;
      expect(newId, isNotEmpty);
      expect(cells[1]['outputs'], isEmpty);
      nb = applyNotebookEdit(
        nb,
        newSource: 'first',
        cellType: 'markdown',
        mode: NotebookEditMode.insert,
      );
      cells = (jsonDecode(nb) as Map)['cells'] as List;
      expect(cells.first['source'], ['first']);
      expect(cells.first.containsKey('outputs'), isFalse);
      nb = applyNotebookEdit(
        nb,
        cellId: newId,
        newSource: '',
        mode: NotebookEditMode.delete,
      );
      nb = applyNotebookEdit(
        nb,
        cellId: 'cell-0',
        newSource: '',
        mode: NotebookEditMode.delete,
      );
      expect(jsonDecode(nb), jsonDecode(src), reason: 'round trip restores');
    });

    test('errors: unknown cell, insert without type, bad JSON', () {
      expect(
        () => applyNotebookEdit(src, cellId: 'nope', newSource: 'x'),
        throwsA(isA<StructuredEditException>()),
      );
      expect(
        () => applyNotebookEdit(
          src,
          newSource: 'x',
          mode: NotebookEditMode.insert,
        ),
        throwsA(isA<StructuredEditException>()),
      );
      expect(
        () => applyNotebookEdit('{', cellId: 'calc', newSource: 'x'),
        throwsA(isA<StructuredEditException>()),
      );
    });
  });

  group('agent tools', () {
    late Directory docs;
    late PathProviderPlatform original;
    late ChatSession s;
    late Directory ws;

    setUp(() async {
      docs = await Directory.systemTemp.createTemp('structured-edits-');
      original = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TestPaths(docs);
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      HookService.I.resetForTest();
      ws = Directory('${docs.path}/ws')..createSync();
      s = ChatSession(
        id: 'se1',
        title: 'S',
        model: 'm',
        mode: 'auto',
        workspaceFolder: ws.path,
      );
      app.sessions.add(s);
      app.activeSessionId = s.id;
      AgentService.setRunSessionForTest(s.id);
    });

    tearDown(() async {
      AgentService.setRunSessionForTest('');
      HookService.I.resetForTest();
      AppState.resetTestInstance();
      PathProviderPlatform.instance = original;
      await docs.delete(recursive: true);
    });

    Future<String> read(String path) =>
        AgentService.I.dispatchForTest('file_read', {'path': path});

    test(
      'multi_edit: read-before-write, atomic rollback, success + diff',
      () async {
        final f = File('${ws.path}/m.txt')..writeAsStringSync('alpha\nbeta\n');
        expect(
          await AgentService.I.dispatchForTest('multi_edit', {
            'file_path': 'm.txt',
            'edits': [
              {'old_string': 'alpha', 'new_string': 'A'},
            ],
          }),
          contains('FS_NOT_OBSERVED'),
        );
        await read('m.txt');
        final failed = await AgentService.I.dispatchForTest('multi_edit', {
          'file_path': 'm.txt',
          'edits': [
            {'old_string': 'alpha', 'new_string': 'A'},
            {'old_string': 'zzz', 'new_string': 'Z'},
          ],
        });
        expect(failed, contains('nothing was changed'));
        expect(f.readAsStringSync(), 'alpha\nbeta\n', reason: 'rolled back');
        AgentService.I.armToolCardForTest('multi_edit');
        final ok = await AgentService.I.dispatchForTest('multi_edit', {
          'file_path': 'm.txt',
          'edits': [
            {'old_string': 'alpha', 'new_string': 'A'},
            {'old_string': 'beta', 'new_string': 'B'},
          ],
        });
        expect(ok, contains('edited'));
        expect(f.readAsStringSync(), 'A\nB\n');
        final card = s.messages.where((m) => m.toolName == 'multi_edit').last;
        expect(card.toolDetail, contains('+A'));
        expect(card.toolDetail, contains('-alpha'));
      },
    );

    test('notebook_edit edits a real .ipynb', () async {
      final f = File('${ws.path}/n.ipynb')
        ..writeAsStringSync(jsonEncode(_notebook));
      await read('n.ipynb');
      final res = await AgentService.I.dispatchForTest('notebook_edit', {
        'notebook_path': 'n.ipynb',
        'cell_id': 'calc',
        'new_source': 'print(42)',
      });
      expect(res, contains('edited'));
      final nb = jsonDecode(f.readAsStringSync()) as Map;
      expect((nb['cells'] as List)[1]['source'], ['print(42)']);
      expect(nb['metadata'], _notebook['metadata']);
      expect(
        await AgentService.I.dispatchForTest('notebook_edit', {
          'notebook_path': 'n.txt',
          'new_source': 'x',
        }),
        contains('not a .ipynb'),
      );
    });

    test(
      'registered: roster, Read-Only refusal, CC matchers, subagent scope',
      () async {
        final names = AgentService.I
            .toolsForTest()
            .map((t) => (t['function'] as Map)['name'])
            .toList();
        expect(names, containsAll(['multi_edit', 'notebook_edit']));
        s.mode = 'safe';
        expect(
          await AgentService.I.dispatchForTest('multi_edit', {
            'file_path': 'x',
            'edits': [],
          }),
          contains('READ-ONLY'),
        );
        expect(
          SubagentToolPolicy.fromStored(['MultiEdit']).allows('multi_edit'),
          isTrue,
        );
        expect(
          SubagentToolPolicy.fromStored(['Edit']).allows('multi_edit'),
          isFalse,
        );

        // A [CC] PreToolUse hook matching `MultiEdit` sees the CC name.
        s.mode = 'auto';
        const pid = 'acme/me';
        PluginContributionRegistry.I.register(
          NormalizedPluginManifest(
            id: pid,
            name: 'me',
            version: '1',
            format: PluginFormat.claudeCode,
            rootPath: '/plugin',
            hooks: [
              PluginHook(
                pluginId: pid,
                event: 'pre_tool',
                ordinal: 0,
                type: 'command',
                payload: 'deny',
                matcher: 'MultiEdit|NotebookEdit',
              ),
            ],
          ),
          activation: PluginActivation.sessionActive,
          immediateSessionId: s.id,
        );
        addTearDown(() => PluginContributionRegistry.I.unregisterPlugin(pid));
        final seen = <String>[];
        HookService.I.stdinExecutorForTest = (cmd, env, stdin) async {
          seen.add((jsonDecode(stdin) as Map)['tool_name'] as String);
          return (2, 'blocked by test hook');
        };
        HookService.I.gateExecutorForTest = null;
        final denied = await AgentService.I.dispatchForTest('multi_edit', {
          'file_path': 'm.txt',
          'edits': [
            {'old_string': 'a', 'new_string': 'b'},
          ],
        });
        expect(denied, contains('DENIED by hook'));
        await AgentService.I.dispatchForTest('notebook_edit', {
          'notebook_path': 'n.ipynb',
          'new_source': 'x',
        });
        expect(seen, ['MultiEdit', 'NotebookEdit']);
      },
    );
  });

  group('Streamable HTTP: incremental SSE', () {
    test('parser handles split chunks, CRLF and multi-line data', () {
      final p = McpSseParser();
      expect(p.add('event: message\r\ndata: {"a"'), isEmpty);
      expect(p.add(':1}\r\n\r\ndata: x\ndata: y\n\n'), ['{"a":1}', 'x\ny']);
      expect(p.add('data: tail'), isEmpty);
      expect(p.close(), ['tail']);
    });

    test('server requests and progress mid-stream are answered before the '
        'result; the result still resolves the call', () async {
      SharedPreferences.setMockInitialValues({});
      AppState.resetTestInstance();
      final app = AppState.createForTest();
      addTearDown(AppState.resetTestInstance);
      final client = McpClientRequests.I;
      client.resetForTest();
      addTearDown(client.resetForTest);
      var approvals = 0;
      client.samplingApprover = (_) async {
        approvals++;
        return true;
      };
      client.sampler = (r) async => {
        'role': 'assistant',
        'content': {'type': 'text', 'text': 'sampled'},
        'model': 'm',
        'stopReason': 'endTurn',
      };
      client.elicitor = (_) async =>
          const McpElicitationResponse.accept({'name': 'Ada'});

      final server = McpServer(
        name: 'stream',
        author: 't',
        description: 'd',
        category: 'Custom',
        command: '',
        custom: true,
        transport: 'http',
        url: 'https://mcp.test/rpc',
      );
      app.mcpServers.add(server);
      final answers = <String, Map<String, dynamic>>{};
      final bothAnswered = Completer<void>();
      String? sessionOnAnswer;
      Map<String, dynamic>? callParams;
      McpService.I.httpClientForTest = MockClient.streaming((
        request,
        bodyStream,
      ) async {
        final raw = await bodyStream.bytesToString();
        final body = jsonDecode(raw) as Map<String, dynamic>;
        final method = body['method'];
        if (method == null) {
          // Our answer to a server request.
          answers['${body['id']}'] = body;
          sessionOnAnswer = request.headers['Mcp-Session-Id'];
          if (answers.length == 2 && !bothAnswered.isCompleted) {
            bothAnswered.complete();
          }
          return http.StreamedResponse(const Stream.empty(), 202);
        }
        if (method == 'tools/call') {
          callParams = body['params'] as Map<String, dynamic>;
          final token = (callParams!['_meta'] as Map)['progressToken'];
          final out = StreamController<List<int>>();
          void send(Map<String, dynamic> m) =>
              out.add(utf8.encode('data: ${jsonEncode(m)}\n\n'));
          () async {
            send({
              'jsonrpc': '2.0',
              'method': 'notifications/progress',
              'params': {
                'progressToken': token,
                'progress': 1,
                'total': 2,
                'message': 'halfway',
              },
            });
            send({
              'jsonrpc': '2.0',
              'id': 'srv-1',
              'method': 'sampling/createMessage',
              'params': {
                'messages': [
                  {
                    'role': 'user',
                    'content': {'type': 'text', 'text': 'q'},
                  },
                ],
                'maxTokens': 5,
              },
            });
            send({
              'jsonrpc': '2.0',
              'id': 'srv-2',
              'method': 'elicitation/create',
              'params': {
                'message': 'name?',
                'requestedSchema': {
                  'type': 'object',
                  'properties': {
                    'name': {'type': 'string'},
                  },
                },
              },
            });
            // The server only finishes once both answers arrived — a
            // buffered client would deadlock here.
            await bothAnswered.future.timeout(const Duration(seconds: 5));
            send({
              'jsonrpc': '2.0',
              'id': body['id'],
              'result': {
                'content': [
                  {'type': 'text', 'text': 'STREAMED RESULT'},
                ],
              },
            });
            await out.close();
          }();
          return http.StreamedResponse(
            out.stream,
            200,
            headers: {
              'content-type': 'text/event-stream',
              'mcp-session-id': 'sess-1',
            },
          );
        }
        final result = switch (method) {
          'initialize' => {
            'protocolVersion': '2025-06-18',
            'capabilities': {'tools': {}},
          },
          'tools/list' => {
            'tools': [
              {
                'name': 'slow',
                'inputSchema': {'type': 'object', 'properties': {}},
              },
            ],
          },
          _ => <String, dynamic>{},
        };
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'jsonrpc': '2.0',
                'id': body['id'],
                'result': result,
              }),
            ),
          ),
          200,
          headers: {
            'content-type': 'application/json',
            'mcp-session-id': 'sess-1',
          },
        );
      });
      addTearDown(() async {
        await McpService.I.disconnect('stream');
        McpService.I.httpClientForTest = null;
      });
      expect(await McpService.I.connect(server), contains('connected'));
      final progress = <McpProgress>[];
      final out = await McpService.I.callTool(
        'stream',
        'slow',
        {},
        onProgress: progress.add,
      );
      expect(out, contains('STREAMED RESULT'));
      expect(approvals, 1);
      expect(answers['srv-1']!['result']['content']['text'], 'sampled');
      expect(answers['srv-2']!['result'], {
        'action': 'accept',
        'content': {'name': 'Ada'},
      });
      expect(sessionOnAnswer, 'sess-1');
      expect(progress.single.message, 'halfway');
      expect(progress.single.total, 2);
      expect(
        (callParams!['_meta'] as Map)['progressToken'],
        startsWith('ovid-'),
      );
    });
  });
}
