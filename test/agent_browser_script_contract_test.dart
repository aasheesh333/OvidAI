import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
// The platform boundary is replaced; production JS still executes in Node's VM.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _ScriptController extends PlatformWebViewController {
  _ScriptController() : super.implementation(
      const PlatformWebViewControllerCreationParams());
  bool missing = false;
  final scripts = <String>[];
  Map<String, dynamic>? result;

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    if (javaScript == 'location.host') return '';
    scripts.add(javaScript);
    final process = await Process.start('node', ['-e', r'''
const vm = require('node:vm');
let input = '';
process.stdin.on('data', x => input += x);
process.stdin.on('end', () => {
  const {script, missing} = JSON.parse(input);
  const events = [], selectors = [];
  const el = {tagName:'SELECT', value:'', scrollTop:50, scrollHeight:1000,
    focus() {}, closest() {return null;}, scrollIntoView() {},
    scrollBy(o) {this.scrollTop += o.top;},
    scrollTo(o) {this.scrollTop = o.top;},
    getBoundingClientRect() {return {x:0,y:0,width:20,height:10};},
    dispatchEvent(e) {events.push(e.type);}};
  class Event {constructor(type, options) {this.type=type;}}
  const ctx = {document: {body:{innerText:'Hello hello'},
    querySelector(s) {selectors.push(s); return missing ? null : el;},
    elementFromPoint() {return el;}},
    Event, MouseEvent:Event, PointerEvent:Event, DragEvent:Event,
    KeyboardEvent:Event, DataTransfer:class {}, window:{}, injected:false};
  const value = vm.runInNewContext(script, ctx, {timeout:300});
  process.stdout.write(JSON.stringify({value, events, selectors,
    scrollTop:el.scrollTop, selected:el.value, injected:ctx.injected}));
});
''']);
    process.stdin.write(jsonEncode({'script': javaScript, 'missing': missing}));
    await process.stdin.close();
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode;
    if (code != 0) throw StateError(await stderr);
    result = jsonDecode(await stdout) as Map<String, dynamic>;
    return result!['value'] as Object;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ScriptController controller;
  late BrowserTab tab;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final app = AppState.createForTest();
    app.sessions.add(ChatSession(id: 'script-fixture', title: 'Test',
        model: 'm', mode: 'drive'));
    app.activeSessionId = 'script-fixture';
    controller = _ScriptController();
    tab = BrowserTab(url: 'file:///fixture', sessionId: 'script-fixture')
      ..controller = WebViewController.fromPlatform(controller);
    AgentService.I.browserTabs..clear()..add(tab);
  });
  tearDown(() {
    AgentService.I.browserTabs.clear();
    AgentService.I.dropSessionRun('script-fixture');
    AppState.resetTestInstance();
  });

  const selector = '[data-name="O\'Reilly\\line\n</script>雪"]';
  final cases = <String, Map<String, dynamic>>{
    'browser_type': {'selector': selector, 'text': 'hello'},
    'browser_hover': {'selector': selector},
    'browser_scroll': {'selector': selector, 'direction': 'down'},
    'browser_drag': {'from': selector, 'to': '$selector target'},
    'browser_double_click': {'selector': selector},
    'browser_select': {'selector': selector, 'value': 'chosen'},
  };
  for (final entry in cases.entries) {
    for (final missing in [false, true]) {
      test('${entry.key} encodes selectors in ${missing ? 'missing' : 'success'} diagnostics', () async {
        controller.missing = missing;
        final output = await AgentService.I.dispatchForTest(entry.key, entry.value);
        expect(output, isNot(contains('failed:')));
        expect(output, contains(selector));
        expect(controller.result!['selectors'], contains(selector));
        expect(controller.result!['injected'], false);
        if (!missing) {
          if (entry.key == 'browser_type') expect(controller.result!['selected'], 'hello');
          if (entry.key == 'browser_select') expect(controller.result!['selected'], 'chosen');
          if (entry.key == 'browser_double_click') expect(controller.result!['events'], contains('dblclick'));
          if (entry.key == 'browser_drag') expect(controller.result!['events'], contains('drop'));
        }
      });
    }
  }
  for (final entry in {'top': 0, 'bottom': 1000}.entries) {
    test('element scroll ${entry.key} changes scroll position', () async {
      await AgentService.I.dispatchForTest('browser_scroll',
          {'selector': '#panel', 'direction': entry.key});
      expect(controller.result!['scrollTop'], entry.value);
    });
  }
  test('empty browser_find rejects before executing a document script', () async {
    final output = await AgentService.I.dispatchForTest('browser_find', {'text': ''});
    expect(output, contains('non-empty'));
    expect(controller.scripts, isEmpty);
  });
  test('nonempty browser_find still counts case-insensitive matches', () async {
    final output = await AgentService.I.dispatchForTest('browser_find', {'text': 'hello'});
    expect(output, contains('2 match(es)'));
  });
  test('controller recreation drops the old file-selector registration', () async {
    tab.fileSelectorRegistration = Future.value();
    await AgentService.I.recreateControllerForDesktopToggle(tab, reload: false);
    expect(tab.controller, isNull);
    expect(tab.fileSelectorRegistration, isNull);
  });
}
