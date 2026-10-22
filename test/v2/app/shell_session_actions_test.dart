import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/chat_pins.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/projects.dart';
import 'package:ovid_ai/core/composer_drafts.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/v2_app_shell.dart';
import 'package:ovid_ai/ui/v2/chat/composer_mentions.dart';
import 'package:ovid_ai/ui/v2/sidebar/session_actions_sheet.dart';

/// The shell must drive the rebuilt actions sheet through its async
/// `handlers:`. The legacy callbacks opened a second, shell-owned rename
/// dialog with no empty-name validation and a delete dialog that never named
/// the chat; these assertions pin the production path instead.
class _ActionsRest extends CloudRestClient {
  _ActionsRest()
    : super(headers: CloudHeaders.forTest(), restBase: 'http://test');
}

class _ActionsSocket implements CloudSocket {
  final StreamController<Object> _frames = StreamController<Object>.broadcast();
  final StreamController<void> _closed = StreamController<void>.broadcast();
  int? _closeCode;

  @override
  Stream<Object> get frames => _frames.stream;

  @override
  Stream<void> get closed => _closed.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  void sendText(String frame) {}

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed.isClosed) return;
    _closeCode = code;
    if (!_frames.isClosed) await _frames.close();
    _closed.add(null);
    await _closed.close();
  }
}

class _SilentProjects extends ProjectsController {
  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late WsMultiplexer ws;
  late CloudAgentFacade facade;
  late ChatSession session;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    ws = WsMultiplexer(
      mintTicket: () async => 'ticket',
      socketFactory: (_) async => _ActionsSocket(),
      heartbeatInterval: const Duration(hours: 1),
      pongTimeout: const Duration(hours: 1),
      jitterMs: () => 0,
    );
    facade = CloudAgentFacade(rest: _ActionsRest(), ws: ws, store: null);
    CloudAgentFacade.installForTest(facade);
    ProjectsController.installForTest(_SilentProjects());
    ChatPinsStore.I.clearForTest();
    ComposerDraftStore.I.resetForTest();

    session = ChatSession(
      id: 'actions-chat',
      title: 'Actions chat',
      model: 'auto',
      createdAt: DateTime(2026, 10, 22, 10),
    );
    session.messages.add(
      Message(
        role: 'user',
        content: 'A real prompt',
        time: DateTime(2026, 10, 22, 10),
      ),
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;
  });

  tearDown(() async {
    await ws.disconnect();
    facade.dispose();
    CloudAgentFacade.resetForTest();
    ProjectsController.resetForTest();
    ChatPinsStore.I.clearForTest();
    ComposerDraftStore.I.resetForTest();
    AppState.resetTestInstance();
    v2SessionRefResolver = null;
  });

  Future<void> openActions(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: OTheme.light(), home: const V2AppShell()),
    );
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chat actions'));
    await tester.pumpAndSettle();
    expect(find.byType(SessionActionsSheet), findsOneWidget);
  }

  testWidgets('rename is the sheet editor and rejects an empty name', (
    tester,
  ) async {
    await openActions(tester);

    await tester.tap(find.byKey(const ValueKey('session-action-rename')));
    await tester.pumpAndSettle();

    // The sheet owns the field: the shell's legacy AlertDialog would not
    // exist at all.
    final field = find.byKey(const ValueKey('session-rename-field'));
    expect(field, findsOneWidget);

    await tester.enterText(field, '   ');
    await tester.tap(find.byKey(const ValueKey('session-rename-save')));
    await tester.pump();
    expect(find.text('Enter a name.'), findsOneWidget);
    expect(app.sessionById(session.id)!.title, 'Actions chat');

    await tester.enterText(field, 'Renamed in the sheet');
    await tester.tap(find.byKey(const ValueKey('session-rename-save')));
    await tester.pumpAndSettle();

    expect(app.sessionById(session.id)!.title, 'Renamed in the sheet');
    // The open sheet follows the host, so its header is not stale.
    expect(find.text('Renamed in the sheet'), findsWidgets);
  });

  testWidgets('delete names the chat and removes it through AppState', (
    tester,
  ) async {
    await openActions(tester);

    await tester.tap(find.byKey(const ValueKey('session-action-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Delete “Actions chat”?'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(app.sessionById(session.id), isNull);
    expect(find.byType(SessionActionsSheet), findsNothing);
  });

  testWidgets('pin and the real action rows are wired', (tester) async {
    await openActions(tester);

    expect(find.byKey(const ValueKey('session-action-pin')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-action-project')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-action-share')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('session-action-duplicate')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('session-action-export')), findsOneWidget);
    expect(find.byKey(const ValueKey('session-action-delete')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('session-action-pin')));
    await tester.pumpAndSettle();
    expect(ChatPinsStore.I.isPinned(session.id), isTrue);
  });
}
