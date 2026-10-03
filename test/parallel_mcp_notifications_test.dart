import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/mcp_service.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stdio notification storm coalesces and refreshes every catalog page', () async {
    // A real process emits a burst before answering the first refresh. The
    // tool call barrier reports exactly how many list requests reached it.
    final process = await Process.start('python3', ['-u', '-c', r'''
import json, sys
pages = 0
def send(x):
    print(json.dumps(x), flush=True)
for line in sys.stdin:
    m = json.loads(line)
    method = m.get('method')
    if method == 'tools/call':
        if m['params']['name'] == 'trigger':
            for i in range(100):
                send({'jsonrpc':'2.0','method':'notifications/tools/list_changed'})
        send({'jsonrpc':'2.0','id':m['id'],'result':{'content':[{'type':'text','text':str(pages)}]}})
    elif method == 'tools/list':
        pages += 1
        second = m.get('params', {}).get('cursor') == 'second'
        result = {'tools':[{'name':'second' if second else 'first'}]}
        if not second:
            result['nextCursor'] = 'second'
        send({'jsonrpc':'2.0','id':m['id'],'result':result})
''']);
    final server = McpServer(name: 'parallel-notifications', author: 'test',
        description: '', category: 'Custom', command: 'python3');
    addTearDown(() async {
      await McpService.I.disconnect(server.canonicalId);
      process.kill();
    });
    await McpService.I.attachStdioForTest(server, process);
    await McpService.I.callTool(server.canonicalId, 'trigger', {});
    // Poll through the real tool interface rather than relying on one sleep.
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    var pages = 0;
    while (DateTime.now().isBefore(deadline)) {
      pages = int.parse(await McpService.I.callTool(server.canonicalId, 'barrier', {}));
      if (pages >= 2) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(McpService.I.connectedTools[server.canonicalId]!.map((t) => t.name),
        ['first', 'second']);
    expect(pages, lessThanOrEqualTo(4), reason: 'one active refresh plus one coalesced follow-up');
  });
}
