import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    final app = AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.sessions.clear();
    app.sessions.addAll([
      ChatSession(id: 'owner', title: 'Owner', model: 'm', mode: 'auto'),
      ChatSession(id: 'foreground', title: 'Other', model: 'm', mode: 'auto'),
    ]);
    app.activeSessionId = 'foreground';
    AgentService.setRunSessionForTest('owner');
  });

  tearDown(() {
    AgentService.setRunSessionForTest('');
    AppState.resetTestInstance();
  });

  List<String> roster() => AgentService.I
      .toolsForTest()
      .map((t) => (t['function'] as Map)['name'] as String)
      .toList();

  test('unconfigured image generation has no advertised capability', () {
    final image = AppState.I.plugins.firstWhere(
      (p) => p.name == 'Image Studio',
    );
    // Even stale installed flags must not advertise a working backend.
    image.installed = image.enabled = true;
    expect(roster(), isNot(contains('generate_image')));
    expect(AgentService.I.pluginToolNames(image), ['resize_image', 'crop_image']);
    expect(AgentService.builtinPluginHasBacking('Image Studio'), isTrue);
    expect(toolGainsForTest(image), contains('resize_image'));
    expect(roster(), contains('read_image'));
  });

  test(
    'disabled image plugin rejects calls without adding an image',
    () async {
      AppState.I.plugins.firstWhere((p) => p.name == 'Image Studio').enabled = false;
      final out = await AgentService.I.dispatchForTest('generate_image', {});
      expect(out, contains('enable Image Studio'));
      expect(AppState.I.sessionById('owner')!.messages, isEmpty);
    },
  );

  test(
    'render_html is deliberate, routed to running session and persisted',
    () async {
      expect(roster(), contains('render_html'));
      final out = await AgentService.I.dispatchForTest('render_html', {
        'title': 'Counter',
        'html': '<button id="count">0</button>',
        'css': 'button { color: red }',
        'javascript': 'count.onclick = () => count.textContent++;',
        'height': 300,
      });
      expect(out, contains('Counter'));
      final owner = AppState.I.sessionById('owner')!;
      expect(owner.messages, hasLength(1));
      expect(AppState.I.sessionById('foreground')!.messages, isEmpty);
      final json =
          jsonDecode(jsonEncode(owner.toJson())) as Map<String, dynamic>;
      final restored = ChatSession.fromJson(json);
      expect(restored.messages.single.kind.name, 'htmlArtifact');
      final artifact = restored.messages.single.toJson()['htmlArtifact'] as Map;
      expect(artifact['sessionId'], 'owner');
      expect(artifact['html'], '<button id="count">0</button>');
      expect(
        artifact['javascript'],
        'count.onclick = () => count.textContent++;',
      );
      expect(artifact['css'], 'button { color: red }');
      expect(artifact['height'], 300);
      // Replayed model context carries the summary, not executable source.
      expect(restored.messages.single.content, isNot(contains('onclick')));
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs
          .getStringList('ovid_sessions')!
          .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
          .firstWhere((entry) => entry['id'] == 'owner');
      final fromDisk = ChatSession.fromJson(saved);
      expect(fromDisk.messages.single.htmlArtifact!.id, artifact['id']);
      expect(fromDisk.messages.single.htmlArtifact!.sessionId, 'owner');
    },
  );

  test('session artifact count and aggregate bytes are bounded', () async {
    for (var i = 0; i < 16; i++) {
      await AgentService.I.dispatchForTest('render_html', {
        'html': '<p>$i</p>',
      });
    }
    final overflow = await AgentService.I.dispatchForTest('render_html', {
      'html': '<p>extra</p>',
    });
    expect(overflow, startsWith('Error:'));
    final owner = AppState.I.sessionById('owner')!;
    expect(owner.messages, hasLength(16));
    owner.messages.clear();
    for (var i = 0; i < 8; i++) {
      await AgentService.I.dispatchForTest('render_html', {
        'title': 'A',
        'html': 'x' * 65535,
      });
    }
    expect(owner.messages, hasLength(8));
    expect(
      await AgentService.I.dispatchForTest('render_html', {'html': 'x'}),
      startsWith('Error:'),
    );
    expect(owner.messages, hasLength(8));
  });

  test('invalid and oversized render payloads never persist a row', () async {
    for (final args in <Map<String, dynamic>>[
      {},
      {'html': 42},
      {'html': ' '},
      {'html': '<p>ok</p>', 'javascript': []},
      {'html': 'é' * 32769},
      {'html': '<p>ok</p>', 'height': 'huge'},
      {'html': '<p>ok</p>', 'network': true},
    ]) {
      final out = await AgentService.I.dispatchForTest('render_html', args);
      expect(out, startsWith('Error:'), reason: '$args');
    }
    expect(AppState.I.sessionById('owner')!.messages, isEmpty);
  });

  test('plan gate still denies artifact creation', () async {
    AppState.I.sessionById('owner')!.planMode = true;
    expect(roster(), isNot(contains('render_html')));
    final out = await AgentService.I.dispatchForTest('render_html', {
      'html': '<p>x</p>',
    });
    expect(out.toLowerCase(), contains('plan'));
    expect(AppState.I.sessionById('owner')!.messages, isEmpty);
  });

  test('failed persistence never claims the artifact was saved', () async {
    AppState.I.failNextSessionWriteForTest = true;
    final out = await AgentService.I.dispatchForTest('render_html', {
      'html': '<p>unsaved</p>',
    });
    expect(out, startsWith('Error:'));
    expect(out.toLowerCase(), contains('persist'));
  });
}
