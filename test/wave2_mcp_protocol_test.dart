import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';

// The same wire corpus runs through actual HTTP sockets, legacy SSE sockets,
// and a Python stdio process. No service RPC/parser shortcuts.
class ProtocolFixture {
  final String transport;
  HttpServer? listener;
  HttpResponse? events;
  Process? process;
  int revision = 0;
  String? fault;
  String? faultMethod;
  bool inlineNotification = false;
  bool notifyDuringList = false;
  bool notifyAfterFirstPage = false;
  final requests = <Map<String, dynamic>>[];
  ProtocolFixture(this.transport);

  Map<String, dynamic> result(String method, Map params) {
    final cursor = params['cursor'];
    final page = cursor == null ? 'first' : 'second';
    final malformed = params['name'] == 'malformed' || params['uri'] == 'fixture:malformed';
    final Map<String, dynamic> response = switch (method) {
      'initialize' => {'protocolVersion': '2024-11-05', 'capabilities': {
        'tools': {'listChanged': true}, 'prompts': {'listChanged': true},
        'resources': {'listChanged': true},
      }},
      'tools/list' => {'tools': [{'name': 'tool-$revision', 'inputSchema': {'type': 'object'}}]},
      'prompts/list' => {'prompts': [{'name': '$page-$revision', 'arguments': [{'name': 'topic', 'required': true}]}], if (cursor == null) 'nextCursor': 'next'},
      'resources/list' => {'resources': [{'name': page, 'uri': 'fixture:$page-$revision'}], if (cursor == null) 'nextCursor': 'next'},
      'resources/templates/list' => {'resourceTemplates': [{'name': page, 'uriTemplate': 'fixture:$page-$revision/{id}'}], if (cursor == null) 'nextCursor': 'next'},
      'prompts/get' => malformed ? {'messages': [{'role': 'system', 'content': {'type': 'text', 'text': 7}}]} : {'messages': [{'role': 'user', 'content': {'type': 'text', 'text': 'hello'}}]},
      'resources/read' => malformed ? {'contents': [{'uri': 'fixture:malformed', 'text': 7}]} : {'contents': [{'uri': params['uri'], 'text': 'resource text'}, {'uri': '${params['uri']}/binary', 'blob': 'YQ==', 'mimeType': 'application/octet-stream'}]},
      _ => {},
    };
    if (faultMethod == method) {
      final field = method == 'prompts/list' ? 'prompts' : method == 'resources/list' ? 'resources' : 'resourceTemplates';
      switch (fault) {
        case 'missing': response.remove(field);
        case 'null': response[field] = null;
        case 'object': response[field] = {};
        case 'member': response[field] = [7];
        case 'identity': response[field] = [{'name': 7}];
        case 'duplicate': response[field] = [response[field]![0], response[field]![0]];
        case 'cursor': response['nextCursor'] = 7;
        case 'null-cursor': response['nextCursor'] = null;
        case 'repeat': response['nextCursor'] = 'next';
      }
    }
    return response;
  }

  Future<McpServer> start() async {
    if (transport == 'stdio') {
      McpService.spawnProcessForTest = (argv, {env, hostWorkDir}) async {
        process = await Process.start('python3', ['-u', '-c', _python, fault ?? '', faultMethod ?? '']);
        return process!;
      };
    } else {
      listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      listener!.listen((request) async {
        if (request.method == 'GET') {
          events = request.response;
          events!.headers.contentType = ContentType('text', 'event-stream');
          events!.bufferOutput = false;
          events!.write('event: endpoint\ndata: /message\n\n');
          await events!.flush();
          return;
        }
        final message = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
        requests.add(message);
        if (message.containsKey('id')) {
          final response = {'jsonrpc': '2.0', 'id': message['id'],
            'result': result(message['method'] as String, message['params'] as Map)};
          if (transport == 'sse') {
            if (notifyDuringList && message['method'] == 'prompts/list') {
              events!.write('data: {"jsonrpc":"2.0","method":"notifications/prompts/list_changed"}\n\n');
            }
            if (notifyAfterFirstPage && message['method'] == 'resources/list' &&
                !(message['params'] as Map).containsKey('cursor')) {
              events!.write('data: {"jsonrpc":"2.0","method":"notifications/resources/list_changed"}\n\n');
            }
            events!.write('data: ${jsonEncode(response)}\n\n');
            await events!.flush();
          } else {
            if (inlineNotification && message['method'] == 'resources/read') {
              revision++;
              request.response.headers.contentType = ContentType('text', 'event-stream');
              request.response.write('data: ${jsonEncode(response)}\n\n');
              for (final kind in ['prompts', 'resources']) {
                request.response.write('data: {"jsonrpc":"2.0","method":"notifications/$kind/list_changed"}\n\n');
              }
            } else {
              request.response.headers.contentType = ContentType.json;
              request.response.write(jsonEncode(response));
            }
          }
        }
        if (transport == 'sse') request.response.statusCode = 202;
        await request.response.close();
      });
    }
    return McpServer(name: 'wave2-$transport', author: 'fixture', description: '',
        category: 'Custom', command: transport == 'stdio' ? 'python3' : '',
        transport: transport, url: listener == null ? null : 'http://127.0.0.1:${listener!.port}/mcp');
  }

  Future<void> notify() async {
    revision++;
    for (final method in ['tools', 'prompts', 'resources']) {
      for (var i = 0; i < 20; i++) {
        events!.write('data: ${jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/$method/list_changed'})}\n\n');
      }
    }
    await events!.flush();
  }

  Future<void> close() async {
    process?.kill();
    await listener?.close(force: true);
    McpService.spawnProcessForTest = null;
  }
}

const _python = r'''
import sys,json
for line in sys.stdin:
 q=json.loads(line)
 if 'id' not in q: continue
 m=q['method']; p=q.get('params',{}); page='second' if 'cursor' in p else 'first'
 r={}
 if m=='initialize': r={'protocolVersion':'2024-11-05','capabilities':{'prompts':{},'resources':{},'tools':{}}}
 if m=='tools/list': r={'tools':[{'name':'tool-0','inputSchema':{'type':'object'}}]}
 if m=='prompts/list': r={'prompts':[{'name':page+'-0','arguments':[{'name':'topic','required':True}]}]}
 if m=='resources/list': r={'resources':[{'name':page,'uri':'fixture:'+page+'-0'}]}
 if m=='resources/templates/list': r={'resourceTemplates':[{'name':page,'uriTemplate':'fixture:'+page+'-0/{id}'}]}
 if m in ['prompts/list','resources/list','resources/templates/list'] and 'cursor' not in p: r['nextCursor']='next'
 if m=='prompts/get': r={'messages':[{'role':'user','content':{'type':'text','text':'hello'}}]} if p['name']!='malformed' else {'messages':[{'role':'system','content':{'type':'text','text':7}}]}
 if m=='resources/read': r={'contents':[{'uri':p['uri'],'text':'resource text'},{'uri':p['uri']+'/binary','blob':'YQ==','mimeType':'application/octet-stream'}]} if p['uri']!='fixture:malformed' else {'contents':[{'uri':p['uri'],'text':7}]}
 if m==sys.argv[2]:
  f=sys.argv[1]; k={'prompts/list':'prompts','resources/list':'resources','resources/templates/list':'resourceTemplates'}[m]
  if f=='missing': r.pop(k,None)
  if f=='null': r[k]=None
  if f=='object': r[k]={}
  if f=='member': r[k]=[7]
  if f=='identity': r[k]=[{'name':7}]
  if f=='duplicate': r[k]=[r[k][0],r[k][0]]
  if f=='cursor': r['nextCursor']=7
  if f=='null-cursor': r['nextCursor']=None
  if f=='repeat': r['nextCursor']='next'
 print(json.dumps({'jsonrpc':'2.0','id':q['id'],'result':r}),flush=True)
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);
  for (final transport in ['http', 'sse', 'stdio']) {
    for (final method in ['prompts/list', 'resources/list', 'resources/templates/list']) {
      for (final fault in ['missing', 'null', 'object', 'member', 'identity', 'duplicate', 'cursor', 'null-cursor', 'repeat']) {
        test('$transport $method rejects $fault without publishing partial data', () async {
          SharedPreferences.setMockInitialValues({});
          FlutterSecureStorage.setMockInitialValues({});
          AppState.createForTest();
          final fixture = ProtocolFixture(transport)..fault = fault..faultMethod = method;
          final server = await fixture.start();
          final svc = McpService.I;
          addTearDown(() async {
            await svc.disconnect(server.canonicalId);
            await fixture.close();
            AppState.resetTestInstance();
          });
          expect((await svc.connectOutcome(server, handshakeBudget: const Duration(seconds: 5))).isReady, isTrue);
          Future<List<Map<String, dynamic>>> list() => switch (method) {
            'prompts/list' => svc.listPrompts(server.canonicalId),
            'resources/list' => svc.listResources(server.canonicalId),
            _ => svc.listResourceTemplates(server.canonicalId),
          };
          await expectLater(list(), throwsFormatException);
          await expectLater(list(), throwsFormatException);
          expect(svc.isConnected(server.canonicalId), isTrue);
        });
      }
    }
    test('$transport paginated prompts resources templates and typed get/read', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      AppState.createForTest();
      final fixture = ProtocolFixture(transport);
      final server = await fixture.start();
      final svc = McpService.I;
      addTearDown(() async {
        await svc.disconnect(server.canonicalId);
        await fixture.close();
        AppState.resetTestInstance();
      });
      expect((await svc.connectOutcome(server, handshakeBudget: const Duration(seconds: 5))).isReady, isTrue);
      final prompts = await svc.listPrompts(server.canonicalId);
      expect(prompts.map((p) => p['name']), ['first-0', 'second-0']);
      final resources = await svc.listResources(server.canonicalId);
      expect(resources.map((p) => p['uri']), ['fixture:first-0', 'fixture:second-0']);
      final templates = await svc.listResourceTemplates(server.canonicalId);
      expect(templates.map((p) => p['uriTemplate']), ['fixture:first-0/{id}', 'fixture:second-0/{id}']);
      final prompt = await svc.getPrompt(server.canonicalId, 'first-0', arguments: <String, String>{'topic': 'test'});
      expect(prompt['messages'][0]['content']['text'], 'hello');
      final read = await svc.readResource(server.canonicalId, 'fixture:first-0');
      expect(read['contents'][0]['text'], 'resource text');
      expect(read['contents'][1]['blob'], 'YQ==');
      if (transport == 'http') {
        fixture.inlineNotification = true;
        await svc.readResource(server.canonicalId, 'fixture:first-0');
        expect((await svc.listPrompts(server.canonicalId)).first['name'], 'first-1');
        expect((await svc.listResources(server.canonicalId)).first['uri'], 'fixture:first-1');
        expect((await svc.listResourceTemplates(server.canonicalId)).first['uriTemplate'], 'fixture:first-1/{id}');
      }
      await expectLater(svc.getPrompt(server.canonicalId, 'malformed'), throwsFormatException);
      await expectLater(svc.readResource(server.canonicalId, 'fixture:malformed'), throwsFormatException);
      if (transport == 'sse') {
        await fixture.notify();
        final until = DateTime.now().add(const Duration(seconds: 3));
        while (svc.connectedTools[server.canonicalId]!.single.name != 'tool-1' && DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(svc.connectedTools[server.canonicalId]!.single.name, 'tool-1');
        expect((await svc.listPrompts(server.canonicalId)).first['name'], 'first-1');
        expect((await svc.listResources(server.canonicalId)).first['uri'], 'fixture:first-1');
        expect((await svc.listResourceTemplates(server.canonicalId)).first['uriTemplate'], 'fixture:first-1/{id}');
        expect(fixture.requests.where((r) => r['method'] == 'tools/list').length, lessThanOrEqualTo(3));
        fixture.notifyDuringList = true;
        await expectLater(svc.listPrompts(server.canonicalId, refresh: true), throwsStateError);
        fixture.notifyDuringList = false;
        expect((await svc.listPrompts(server.canonicalId)).first['name'], 'first-1');
      }
    });
    if (transport == 'sse') {
      test('SSE list change between pages cannot publish a mixed resource catalog', () async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({});
        AppState.createForTest();
        final fixture = ProtocolFixture('sse')..notifyAfterFirstPage = true;
        final server = await fixture.start();
        final svc = McpService.I;
        addTearDown(() async {
          await svc.disconnect(server.canonicalId);
          await fixture.close();
          AppState.resetTestInstance();
        });
        expect((await svc.connectOutcome(server, handshakeBudget: const Duration(seconds: 5))).isReady, isTrue);
        await expectLater(svc.listResources(server.canonicalId), throwsStateError);
        fixture.notifyAfterFirstPage = false;
        expect((await svc.listResources(server.canonicalId)).map((r) => r['uri']),
            ['fixture:first-0', 'fixture:second-0']);
      });
    }
  }
}
