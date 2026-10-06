import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/global_repo_registry.dart';
import 'package:ovid_ai/core/native_share.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/session_ledger.dart';
import 'package:ovid_ai/core/state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppState app;
  late ChatSession session;
  final agent = AgentService.I;

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('attachment continuation did not settle');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    root = Directory.systemTemp.createTempSync('composer-attachments-');
    SessionLedger.rootOverrideForTest = root;
    app = AppState.createForTest();
    app.suspendCoalescedPersistenceForTest = true;
    final provider = app.providerById('ollama-local')!;
    provider.models = ['gpt-4o'];
    session = ChatSession(
      id: root.path.split('/').last,
      title: 'Attachments',
      providerId: provider.id,
      model: 'gpt-4o',
      mode: 'auto',
      workspaceFolder: Directory('${root.path}/work').createSyncAndReturnPath(),
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;
    agent.debugPauseScheduleTimerForTest(true);
    agent.clearAttachment();
  });

  tearDown(() async {
    await until(() => !agent.busyFor(session.id));
    agent.clearAttachment();
    agent.dropSessionRun(session.id);
    await app.drainSessionLifecycleForTest();
    await app.flushSessionPersistenceForTest();
    await SessionLedger.I.close(session.id);
    AgentService.llmOnceForTest = null;
    AgentNotificationService.I.resetForTest();
    SessionLedger.rootOverrideForTest = null;
    AppState.resetTestInstance();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<String?> attach(String name, [String contents = 'original']) async {
    final source = File('${root.path}/source')..writeAsStringSync(contents);
    return agent.attachFile(source.path, name);
  }

  test('the 21st file is rejected with a limit explanation', () async {
    for (var i = 0; i < 20; i++) {
      expect(await attach('file-$i.txt'), isNull);
    }
    expect(await attach('extra.txt'), contains('20 files'));
    expect(agent.pendingAttachments, hasLength(20));
  });

  test('same-name files keep both contents and stay in the session', () async {
    expect(await attach('photo.png', 'first'), isNull);
    expect(await attach('photo.png', 'second'), isNull);
    final files = agent.pendingAttachments.toList();
    expect(files.map((f) => f.path).toSet(), hasLength(2));
    expect(File(files.first.path).readAsStringSync(), 'first');
    expect(File(files.last.path).readAsStringSync(), 'second');
    app.sessions.add(ChatSession(id: 'other', title: 'Other', model: 'gpt-4o'));
    app.activeSessionId = 'other';
    expect(agent.pendingAttachments, isEmpty);
    app.activeSessionId = session.id;
    expect(agent.pendingAttachments, hasLength(2));
  });

  test('failed provider send preserves composer attachments', () async {
    await attach('notes.txt');
    app.sendMessage('read notes');
    AgentService.llmOnceForTest = (p, msgs, s, tools) async {
      agent.lastError = 'HTTP 401: invalid key';
      return null;
    };
    await agent.runTask('read notes', sessionId: session.id);
    expect(agent.pendingAttachments.single.name, 'notes.txt');
  });

  test('provider setup rejection leaves attachments available', () async {
    await attach('notes.txt');
    session.providerId = null;
    session.model = 'Select a provider';
    await agent.runTask('read notes', sessionId: session.id);
    expect(agent.pendingAttachments.single.name, 'notes.txt');
  });

  test('removing one same-name attachment keeps the other', () async {
    await attach('notes.txt', 'one');
    await attach('notes.txt', 'two');
    agent.removeAttachment(agent.pendingAttachments.first.path);
    expect(agent.pendingAttachments, hasLength(1));
    expect(
      File(agent.pendingAttachments.single.path).readAsStringSync(),
      'two',
    );
  });

  test('cancelled send preserves its attachments', () async {
    await attach('notes.txt');
    app.sendMessage('read notes');
    final entered = Completer<void>();
    final response = Completer<Map<String, dynamic>?>();
    AgentService.llmOnceForTest = (p, msgs, s, tools) {
      entered.complete();
      return response.future;
    };
    final run = agent.runTask('read notes', sessionId: session.id);
    await entered.future;
    agent.stopRequested(sessionId: session.id);
    response.complete(null);
    await run;
    expect(agent.pendingAttachments.single.name, 'notes.txt');
  });

  test('accepted send notifies and clears only the sent snapshot', () async {
    await attach('notes.txt');
    app.sendMessage('read notes');
    final entered = Completer<void>();
    final response = Completer<Map<String, dynamic>?>();
    AgentService.llmOnceForTest = (p, msgs, s, tools) {
      entered.complete();
      return response.future;
    };
    final run = agent.runTask('read notes', sessionId: session.id);
    await entered.future;
    expect(agent.pendingAttachments.map((a) => a.name), ['notes.txt']);
    await attach('next.txt');
    final observed = <List<String>>[];
    void listener() =>
        observed.add(agent.pendingAttachments.map((a) => a.name).toList());
    agent.addListener(listener);
    response.complete({
      'role': 'assistant',
      'content': 'Read.',
      'finish_reason': 'stop',
    });
    await run;
    agent.removeListener(listener);
    expect(agent.pendingAttachments.map((a) => a.name), ['next.txt']);
    expect(observed, contains(equals(['next.txt'])));
  });

  test(
    'concurrent selections reserve slots and cannot overwrite names',
    () async {
      final source = File('${root.path}/source')..writeAsStringSync('content');
      final results = await Future.wait([
        for (var i = 0; i < 25; i++) agent.attachFile(source.path, 'same.txt'),
      ]);
      expect(results.where((r) => r == null), hasLength(20));
      expect(results.whereType<String>(), everyElement(contains('20 files')));
      expect(
        agent.pendingAttachments.map((a) => a.path).toSet(),
        hasLength(20),
      );
    },
  );

  test('picked filename cannot escape the workspace', () async {
    expect(await attach('../../escape.txt'), contains('invalid attachment filename'));
    expect(agent.pendingAttachments, isEmpty);
    expect(File('${root.parent.path}/escape.txt').existsSync(), isFalse);
  });

  test('picker completion stays with its originating session', () async {
    final source = File('${root.path}/source')..writeAsStringSync('content');
    final selected = agent.attachFile(source.path, 'notes.txt');
    app.sessions.add(ChatSession(id: 'other', title: 'Other', model: 'gpt-4o'));
    app.activeSessionId = 'other';
    expect(await selected, isNull);
    expect(agent.pendingAttachments, isEmpty);
    app.activeSessionId = session.id;
    expect(
      agent.pendingAttachments.single.path,
      startsWith('${session.workspaceFolder}/'),
    );
  });

  for (final folderState in ['selected', 'cleared', 'missing']) {
    test('Studio attachment follows cwd with $folderState folder and stale registry', () async {
      session.mode = 'studio';
      final stale = Directory('${root.path}/stale')..createSync();
      final registry = await GlobalRepoRegistry.instance();
      await registry.bindSession(session.id, 'old/repo', 'main', stale.path);
      addTearDown(() => registry.unbindSession(session.id));
      if (folderState == 'cleared') {
        app.setSessionWorkspaceFolder(null, sessionId: session.id);
      } else if (folderState == 'missing') {
        session.workspaceFolder = '${root.path}/missing';
      }
      final cwd = await SandboxService.I.workDirFor(session.id);
      expect(cwd.path, isNot(stale.path));
      if (folderState == 'selected') {
        expect(cwd.path, '${root.path}/work');
      }
      expect((await agent.sessionWorkDirForTest()).path, cwd.path);
      expect(await attach('notes.txt', 'workspace attachment'), isNull);
      final att = agent.pendingAttachments.single;
      expect(att.path, startsWith('${cwd.path}/.attachments/'));
      expect(Directory('${stale.path}/.attachments').existsSync(), isFalse);
      expect(
        await agent.dispatchForTest('read_attachment', {'filename': att.path})
            .timeout(const Duration(seconds: 3)),
        'workspace attachment',
      );
      expect(agent.pendingApproval, isNull);
    });
  }

  test('successful send persists exact paths that tools can resolve', () async {
    await attach('notes.txt', 'edit instructions');
    final att = agent.pendingAttachments.single;
    app.sendMessage('read @notes');
    List<Map<String, dynamic>>? sent;
    AgentService.llmOnceForTest = (p, msgs, s, tools) async {
      sent = List.of(msgs);
      return {'role': 'assistant', 'content': 'Read.', 'finish_reason': 'stop'};
    };
    await agent.runTask(
      'read @notes',
      sessionId: session.id,
      expandRefsFor: session,
    );
    expect(agent.pendingAttachments, isEmpty);
    expect(jsonEncode(sent), contains(att.path));
    final restored = Message.fromJson(
      jsonDecode(jsonEncode(session.messages.first.toJson())),
    );
    expect(restored.attachments.single.path, att.path);
    expect(
      await agent.dispatchForTest('read_attachment', {'filename': att.path}),
      'edit instructions',
    );
  });

  test(
    'attached image path supports vision without raising the image cap',
    () async {
      await attach('photo.png', 'image bytes');
      final path = agent.pendingAttachments.single.path;
      final result = await agent.dispatchForTest('read_image', {'path': path});
      expect(result, contains('attached to the next model request'));
      final messages = <Map<String, dynamic>>[];
      agent.appendPendingVisionMessagesForTest(messages);
      expect(jsonEncode(messages), contains('data:image/png;base64,'));
      expect(jsonEncode(messages), contains(path));

      final large = File('${root.path}/large.png');
      final handle = large.openSync(mode: FileMode.write);
      handle.truncateSync(10 * 1024 * 1024 + 1);
      handle.closeSync();
      expect(await agent.attachFile(large.path, 'large.png'), isNull);
      await agent.dispatchForTest('read_image', {
        'path': agent.pendingAttachments.last.path,
      });
      final capped = <Map<String, dynamic>>[];
      agent.appendPendingVisionMessagesForTest(capped);
      expect(capped, isEmpty);
    },
  );

  test('stored paths survive reload and are visible on later requests', () {
    final restored = Message.fromJson({
      'role': 'user',
      'content': 'edit the photo',
      'attachments': [
        {
          'name': 'photo.png',
          'size': 42,
          'path': '${session.workspaceFolder}/photo.png',
        },
      ],
    });
    session.messages.add(
      Message.fromJson(jsonDecode(jsonEncode(restored.toJson()))),
    );
    session.messages.add(Message(role: 'user', content: 'now crop it'));
    final request = jsonEncode(agent.buildRequestMessages(session, 'system'));
    expect(request, contains('${session.workspaceFolder}/photo.png'));
    expect(request, contains('read_image'));
  });

  test('queued composer references and attachment snapshots travel together', () async {
    app.suspendCoalescedPersistenceForTest = false;
    final referenced = ChatSession(id: 'reference', title: 'Reference', model: 'm',
        messages: [Message(role: 'assistant', content: 'REFERENCE CONTENT')]);
    app.sessions.add(referenced);
    app.sendMessage('first');
    final entered = Completer<void>();
    final release = Completer<Map<String, dynamic>?>();
    final requests = <String>[];
    AgentService.llmOnceForTest = (p, msgs, s, tools) async {
      requests.add(jsonEncode(msgs));
      if (requests.length == 1) {
        entered.complete();
        return release.future;
      }
      return {'role': 'assistant', 'content': 'Done.', 'finish_reason': 'stop'};
    };
    final run = agent.runTask('first', sessionId: session.id);
    await entered.future;
    await attach('first.txt');
    final firstPath = agent.pendingAttachments.single.path;
    agent.enqueueMessage('use @session:reference', sessionId: session.id);
    await attach('second.txt');
    final secondPath = agent.pendingAttachments.last.path;
    // A delegate notice contains reference syntax but must not acquire a grant
    // or inherit the current composer draft when it drains.
    final unreferenced = ChatSession(id: 'private', title: 'Private', model: 'm',
        messages: [Message(role: 'assistant', content: 'PRIVATE CONTENT')]);
    app.sessions.add(unreferenced);
    agent.runBucketForTest(session.id).queue.add('delegate @session:private');
    release.complete({'role': 'assistant', 'content': 'First.', 'finish_reason': 'stop'});
    await run;
    // The internal notice joins the first run; the composer row is admitted
    // separately and expands its reference with its own attachment snapshot.
    await until(() => requests.length == 3 && !agent.busyFor(session.id));
    expect(requests[1], contains('delegate @session:private'));
    expect(requests[1], isNot(contains('REFERENCE CONTENT')));
    expect(requests.last, contains('REFERENCE CONTENT'));
    expect(requests.last, contains(firstPath));
    expect(jsonEncode(requests), isNot(contains(secondPath)));
    expect(jsonEncode(requests), isNot(contains('PRIVATE CONTENT')));
    expect(session.referencedSessionIds, {'reference'});
    expect(session.messages.singleWhere((m) => m.content == 'delegate @session:private').attachments, isEmpty);
    expect(session.messages.singleWhere((m) => m.content == 'use @session:reference').attachments.single.path, firstPath);
    expect(agent.pendingAttachments.single.path, secondPath);
  });

  test('scheduled artifact stays in its workspace and leaves composer draft unsent', () async {
    agent.schedules.stopped = false;
    addTearDown(() => agent.schedules.stopped = false);
    // render_html awaits the coalesced session write. The file-level default
    // suspends it (no wall-clock timers), which leaves that future pending and
    // stalls the tool until its timeout; this test exercises the real write.
    app.suspendCoalescedPersistenceForTest = false;
    await attach('unsent.txt', 'private draft');
    final draftPath = agent.pendingAttachments.single.path;
    final task = agent.schedules.create({
      'prompt': 'Present a report',
      'at': '2020-01-01T00:00:00Z',
    });
    session.schedules.add(task);
    final foreground = ChatSession(id: 'foreground', title: 'Foreground', model: 'm');
    app.sessions.add(foreground);
    app.activeSessionId = foreground.id;
    var calls = 0;
    AgentService.llmOnceForTest = (provider, messages, running, includeTools) async {
      calls++;
      expect(running.id, session.id);
      expect(jsonEncode(messages), isNot(contains(draftPath)));
      expect((await agent.sessionWorkDirForTest()).path, session.workspaceFolder);
      if (calls == 1) {
        return {
          'role': 'assistant',
          'content': '',
          'tool_calls': [{
            'id': 'report-artifact',
            'type': 'function',
            'function': {
              'name': 'render_html',
              'arguments': jsonEncode({'title': 'Scheduled report', 'html': '<p>Report</p>'}),
            },
          }],
        };
      }
      return {'role': 'assistant', 'content': 'Report ready.', 'finish_reason': 'stop'};
    };
    await agent.schedules.tick();
    await agent.schedules.settle();
    expect(task['status'], 'completed');
    expect(calls, 2);
    expect(app.activeSessionId, foreground.id);
    expect(foreground.messages, isEmpty);
    final artifact = session.messages.singleWhere((m) => m.kind == MsgKind.htmlArtifact);
    expect(artifact.htmlArtifact!.sessionId, session.id);
    expect(NativeShare.transcriptText(session), contains('Scheduled report'));
    expect(NativeShare.transcriptText(session), isNot(contains(draftPath)));
    app.activeSessionId = session.id;
    expect(agent.pendingAttachments.single.path, draftPath);
    expect(session.messages.where((m) => m.role == 'user').single.attachments, isEmpty);
  });

  test('path-only metadata updates are written to session storage', () async {
    app.suspendCoalescedPersistenceForTest = false;
    app.sendMessage('read attachment');
    session.messages.first.attachments = [
      MessageAttachment(
        name: 'notes.txt',
        size: 12,
        path: '/work/first/notes.txt',
      ),
    ];
    app.persistSessions();
    await app.flushSessionPersistenceForTest();
    session.messages.first.attachments = [
      MessageAttachment(
        name: 'notes.txt',
        size: 12,
        path: '/work/second/notes.txt',
      ),
    ];
    app.persistSessions();
    await app.flushSessionPersistenceForTest();
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs
        .getStringList('ovid_sessions')!
        .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
        .firstWhere((s) => s['id'] == session.id);
    final restored = ChatSession.fromJson(saved);
    expect(
      restored.messages.first.attachments.single.path,
      '/work/second/notes.txt',
    );
    expect(
      jsonEncode(agent.buildRequestMessages(restored, 'system')),
      contains('/work/second/notes.txt'),
    );
  });

  for (final fails in [false, true]) {
    test(
      'busy send carries attachments; queued provider failure=$fails',
      () async {
        app.sendMessage('first');
        final firstRequest = Completer<void>();
        final firstResponse = Completer<Map<String, dynamic>?>();
        var calls = 0;
        String? queuedRequest;
        AgentService.llmOnceForTest = (p, msgs, s, tools) async {
          calls++;
          if (calls == 1) {
            firstRequest.complete();
            return firstResponse.future;
          }
          queuedRequest = jsonEncode(msgs);
          if (fails) {
            agent.lastError = 'HTTP 401: invalid key';
            return null;
          }
          return {
            'role': 'assistant',
            'content': 'Done.',
            'finish_reason': 'stop',
          };
        };
        final run = agent.runTask('first', sessionId: session.id);
        await firstRequest.future;
        await attach('queued.txt');
        final path = agent.pendingAttachments.single.path;
        agent.enqueueMessage('read queued file', sessionId: session.id);
        firstResponse.complete({
          'role': 'assistant',
          'content': 'First.',
          'finish_reason': 'stop',
        });
        await run;
        await until(() => calls >= 2 && !agent.busyFor(session.id));
        expect(calls, 2);
        expect(queuedRequest, contains(path));
        expect(
          session.messages
              .where((m) => m.content == 'read queued file')
              .single
              .attachments
              .single
              .path,
          path,
        );
        expect(agent.pendingAttachments, hasLength(fails ? 1 : 0));
      },
    );
  }
}

extension on Directory {
  String createSyncAndReturnPath() {
    createSync(recursive: true);
    return path;
  }
}
