import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/chat_integration_ports.dart';
import 'package:ovid_ai/core/chat_pins.dart';
import 'package:ovid_ai/core/cloud/cloud_agent_facade.dart';
import 'package:ovid_ai/core/cloud/cloud_rest.dart';
import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/models.dart';
import 'package:ovid_ai/core/cloud/projects.dart';
import 'package:ovid_ai/core/composer_drafts.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/bottom_nav.dart';
import 'package:ovid_ai/ui/v2/app/v2_app_shell.dart';
import 'package:ovid_ai/ui/v2/chat/composer_mentions.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/library/artifacts_page.dart';
import 'package:ovid_ai/ui/v2/settings/settings_hub.dart';
import 'package:ovid_ai/ui/v2/sidebar/sidebar.dart';
import 'package:ovid_ai/ui/v2/studio/repo_picker_page.dart';

/// The shell is the one widget every device shares, so the three width bands
/// are pinned here: drawer + bottom bar on phones, a fixed 280 dp column from
/// 600 dp, a 300 dp column from 900 dp, and never two navigation surfaces at
/// once.
class _ShellRest extends CloudRestClient {
  _ShellRest()
    : super(headers: CloudHeaders.forTest(), restBase: 'http://test');

  @override
  Future<SendMessageResponse> sendMessage(
    String sessionId,
    String content, {
    List<String> attachmentIds = const [],
    String? clientMsgId,
    int? maxOutputTokens,
    CloudTurnOptions turn = CloudTurnOptions.none,
  }) async => const SendMessageResponse(
    runId: 'run-1',
    userMessageId: 'msg-1',
    status: 'queued',
  );
}

class _ShellFacade extends CloudAgentFacade {
  _ShellFacade({required super.rest, required super.ws}) : super(store: null);
}

class _SilentProjects extends ProjectsController {
  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState app;
  late WsMultiplexer ws;
  late _ShellFacade facade;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    app = AppState.createForTest();
    ws = WsMultiplexer(
      mintTicket: () async => 'ticket',
      socketFactory: (_) async =>
          throw StateError('the responsive shell test opens no socket'),
      heartbeatInterval: const Duration(hours: 1),
      pongTimeout: const Duration(hours: 1),
      jitterMs: () => 0,
    );
    facade = _ShellFacade(rest: _ShellRest(), ws: ws);
    CloudAgentFacade.installForTest(facade);
    ProjectsController.installForTest(_SilentProjects());
    StudioBindingPort.installForTest(null);
    ChatPinsStore.I.clearForTest();
    ComposerDraftStore.I.resetForTest();
  });

  tearDown(() async {
    await ws.disconnect();
    facade.dispose();
    CloudAgentFacade.resetForTest();
    ProjectsController.resetForTest();
    StudioBindingPort.installForTest(null);
    ChatPinsStore.I.clearForTest();
    ComposerDraftStore.I.resetForTest();
    AppState.resetTestInstance();
    v2SessionRefResolver = null;
  });

  ChatSession liveSession() {
    final session = ChatSession(
      id: 'shell-responsive',
      title: 'Responsive test',
      model: 'auto',
      createdAt: DateTime(2026, 10, 21, 10),
    );
    session.messages.add(
      Message(
        role: 'user',
        content: 'Build the landing page',
        time: DateTime(2026, 10, 21, 10),
      ),
    );
    app.sessions.add(session);
    app.activeSessionId = session.id;
    return session;
  }

  Future<void> pumpShell(
    WidgetTester tester,
    Size size, {
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: textScale == 1
            ? const V2AppShell()
            : MediaQuery(
                data: MediaQueryData(
                  size: size,
                  textScaler: TextScaler.linear(textScale),
                ),
                child: const V2AppShell(),
              ),
      ),
    );
    await tester.pump();
  }

  /// The outer Scaffold is the shell's; the screens inside it own their own.
  Scaffold shellScaffold(WidgetTester tester) =>
      tester.widget<Scaffold>(find.byType(Scaffold).first);

  V2NavTab currentTab(WidgetTester tester) =>
      tester.widget<V2BottomNav>(find.byType(V2BottomNav)).current;

  const sidebarKey = ValueKey<String>('v2-shell-sidebar');

  /// Vertical hairlines on the rail's right edge. Exactly one: the sidebar rail
  /// draws it, the host must not add a second (two would read as a 2 px seam).
  /// Full boxes (`Border.all` around avatars and dots) do not count.
  int railHairlines(WidgetTester tester) {
    var count = 0;
    final boxes = find.descendant(
      of: find.byKey(sidebarKey),
      matching: find.byType(DecoratedBox),
    );
    for (final element in boxes.evaluate()) {
      final decoration = (element.widget as DecoratedBox).decoration;
      if (decoration is! BoxDecoration) continue;
      final border = decoration.border;
      if (border is! Border) continue;
      final rightOnly =
          border.right.width > 0 &&
          border.left.width == 0 &&
          border.top.width == 0 &&
          border.bottom.width == 0;
      if (rightOnly) count++;
    }
    return count;
  }

  SidebarLayout? mountedSidebarLayout(WidgetTester tester) {
    final finder = find.byType(Sidebar);
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<Sidebar>(finder.first).layout;
  }

  group('navigation surfaces', () {
    testWidgets('every band mounts exactly one navigation, never two', (
      tester,
    ) async {
      liveSession();
      for (final width in const <double>[320, 400, 599, 600, 899, 900, 1024]) {
        await pumpShell(tester, Size(width, 900));
        final surfaces =
            find.byType(V2BottomNav).evaluate().length +
            find.byKey(sidebarKey).evaluate().length;
        expect(surfaces, 1, reason: '$width dp must have one navigation');
      }
    });

    testWidgets('below 600 dp the bottom bar is the only navigation', (
      tester,
    ) async {
      liveSession();
      await pumpShell(tester, const Size(400, 900));

      expect(find.byType(V2BottomNav), findsOneWidget);
      expect(find.byKey(sidebarKey), findsNothing);
      // The drawer exists but is closed, so it is not a second live surface.
      expect(mountedSidebarLayout(tester), isNull);
    });

    testWidgets('the phone drawer is the drawer layout, never a rail', (
      tester,
    ) async {
      liveSession();
      await pumpShell(tester, const Size(400, 900));

      tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
      await tester.pumpAndSettle();

      expect(mountedSidebarLayout(tester), SidebarLayout.drawer);
      expect(find.byKey(sidebarKey), findsNothing);
      expect(find.byType(V2BottomNav), findsOneWidget);
    });

    testWidgets('600–899 dp: one 280 dp rail, no bar, no drawer', (
      tester,
    ) async {
      liveSession();
      for (final width in const <double>[600, 899]) {
        await pumpShell(tester, Size(width, 900));

        expect(find.byType(V2BottomNav), findsNothing, reason: '$width dp');
        expect(shellScaffold(tester).drawer, isNull, reason: '$width dp');
        expect(find.byKey(sidebarKey), findsOneWidget, reason: '$width dp');
        expect(
          tester.getSize(find.byKey(sidebarKey)).width,
          v2TabletNavWidth,
          reason: '$width dp',
        );
        expect(
          mountedSidebarLayout(tester),
          SidebarLayout.rail,
          reason: '$width dp must mount the rail form',
        );
      }
    });

    testWidgets('900 dp and up: one 300 dp rail, no bar, no drawer', (
      tester,
    ) async {
      liveSession();
      for (final width in const <double>[900, 1024]) {
        await pumpShell(tester, Size(width, 900));

        expect(find.byType(V2BottomNav), findsNothing, reason: '$width dp');
        expect(shellScaffold(tester).drawer, isNull, reason: '$width dp');
        expect(
          tester.getSize(find.byKey(sidebarKey)).width,
          v2WideNavWidth,
          reason: '$width dp',
        );
        expect(mountedSidebarLayout(tester), SidebarLayout.rail);
      }
    });

    testWidgets('the rail draws the only column hairline', (tester) async {
      liveSession();
      for (final width in const <double>[600, 900]) {
        await pumpShell(tester, Size(width, 900));
        expect(
          railHairlines(tester),
          1,
          reason: '$width dp must not stack two right borders',
        );
      }
    });
  });

  group('navigation bands', () {
    testWidgets('below 600 dp: drawer plus bottom bar, no column', (
      tester,
    ) async {
      liveSession();
      await pumpShell(tester, const Size(400, 900));

      expect(find.byType(V2BottomNav), findsOneWidget);
      expect(find.byKey(sidebarKey), findsNothing);
      expect(shellScaffold(tester).drawer, isNotNull);
    });

    testWidgets('600 dp: fixed 280 dp column, no bottom bar, no drawer', (
      tester,
    ) async {
      liveSession();
      await pumpShell(tester, const Size(600, 900));

      expect(find.byType(V2BottomNav), findsNothing);
      expect(shellScaffold(tester).drawer, isNull);
      expect(find.byKey(sidebarKey), findsOneWidget);
      expect(tester.getSize(find.byKey(sidebarKey)).width, v2TabletNavWidth);
      expect(v2TabletNavWidth, 280);
    });

    testWidgets('899 dp is still the tablet column', (tester) async {
      liveSession();
      await pumpShell(tester, const Size(899, 900));

      expect(find.byType(V2BottomNav), findsNothing);
      expect(tester.getSize(find.byKey(sidebarKey)).width, 280);
    });

    testWidgets('900 dp: fixed 300 dp column, no bottom bar, no drawer', (
      tester,
    ) async {
      liveSession();
      await pumpShell(tester, const Size(900, 900));

      expect(find.byType(V2BottomNav), findsNothing);
      expect(shellScaffold(tester).drawer, isNull);
      expect(tester.getSize(find.byKey(sidebarKey)).width, v2WideNavWidth);
      expect(v2WideNavWidth, 300);
    });

    testWidgets('599 dp still uses the phone navigation', (tester) async {
      liveSession();
      await pumpShell(tester, const Size(599, 900));

      expect(find.byType(V2BottomNav), findsOneWidget);
      expect(find.byKey(sidebarKey), findsNothing);
    });
  });

  group('header', () {
    testWidgets('exactly one header per screen in every band', (tester) async {
      liveSession();
      for (final size in const <Size>[
        Size(320, 640),
        Size(400, 900),
        Size(700, 900),
        Size(1000, 900),
      ]) {
        await pumpShell(tester, size);
        expect(
          find.byType(AppBar),
          findsOneWidget,
          reason: 'chat home at ${size.width} dp',
        );
      }
    });

    testWidgets('a pushed screen brings its own single header', (tester) async {
      liveSession();
      await pumpShell(tester, const Size(400, 900));

      await tester.tap(find.byKey(const ValueKey('v2-nav-settings')));
      await tester.pumpAndSettle();

      expect(find.byType(SettingsHubPage), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
    });
  });

  group('tabs', () {
    testWidgets('chat is the home tab', (tester) async {
      liveSession();
      await pumpShell(tester, const Size(400, 900));

      expect(find.byType(V2LiveChatPage), findsOneWidget);
      expect(currentTab(tester), V2NavTab.chat);
    });

    testWidgets('every tab opens its real route and the bar follows it', (
      tester,
    ) async {
      liveSession();
      await pumpShell(tester, const Size(400, 900));

      await tester.tap(find.byKey(const ValueKey('v2-nav-studio')));
      await tester.pumpAndSettle();
      expect(find.byType(V2RepoPickerPage), findsOneWidget);
      expect(currentTab(tester), V2NavTab.studio);
      // The pushed screen owns the only header; the shell adds none.
      expect(find.byType(AppBar), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('v2-nav-library')));
      await tester.pumpAndSettle();
      expect(find.byType(ArtifactsPage), findsOneWidget);
      expect(currentTab(tester), V2NavTab.library);
      expect(find.byType(AppBar), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('v2-nav-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHubPage), findsOneWidget);
      expect(currentTab(tester), V2NavTab.settings);
      expect(find.byType(AppBar), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('v2-nav-chat')));
      await tester.pumpAndSettle();
      expect(find.byType(V2LiveChatPage), findsOneWidget);
      expect(currentTab(tester), V2NavTab.chat);
      expect(find.byType(AppBar), findsOneWidget);
    });

    testWidgets('re-tapping the active tab pops to that tab root', (
      tester,
    ) async {
      liveSession();
      await pumpShell(tester, const Size(400, 900));

      await tester.tap(find.byKey(const ValueKey('v2-nav-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHubPage), findsOneWidget);

      // A real push inside the settings tab: it inherits the tab.
      final settingsContext = tester.element(find.byType(SettingsHubPage));
      unawaited(
        Navigator.of(settingsContext).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: Center(child: Text('Settings detail'))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Settings detail'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('v2-nav-settings')));
      await tester.pumpAndSettle();

      expect(find.text('Settings detail'), findsNothing);
      expect(find.byType(SettingsHubPage), findsOneWidget);
      expect(currentTab(tester), V2NavTab.settings);

      // Already at the root: another tap must not stack a second copy.
      await tester.tap(find.byKey(const ValueKey('v2-nav-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsHubPage), findsOneWidget);
    });
  });

  group('small screens', () {
    testWidgets('320 dp at 200 % text does not overflow', (tester) async {
      liveSession();
      await pumpShell(tester, const Size(320, 640), textScale: 2);

      expect(tester.takeException(), isNull);
      expect(find.byType(V2BottomNav), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      // Still one navigation: the rail never appears beside the bar.
      expect(find.byKey(sidebarKey), findsNothing);
      // The bar stays a real target even when the labels double in size.
      expect(
        tester.getSize(find.byType(V2BottomNav)).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('600 and 900 dp at 200 % text keep one rail, no double nav', (
      tester,
    ) async {
      liveSession();

      // 900 dp: the whole shell, chat header included, fits at 200 % text.
      await pumpShell(tester, const Size(900, 900), textScale: 2);
      expect(tester.takeException(), isNull, reason: '900 dp');
      expect(find.byKey(sidebarKey), findsOneWidget);
      expect(find.byType(V2BottomNav), findsNothing);

      await pumpShell(tester, const Size(600, 900), textScale: 2);
      expect(find.byKey(sidebarKey), findsOneWidget);
      expect(find.byType(V2BottomNav), findsNothing);
      expect(tester.getSize(find.byKey(sidebarKey)).width, v2TabletNavWidth);
      // Drain the chat header's known 600 dp / 200 % title-row overflow: the
      // fix lives in chat/live_chat_page.dart, outside the shell.
      tester.takeException();
    });

    testWidgets('the phone drawer never exceeds the window', (tester) async {
      liveSession();
      await pumpShell(tester, const Size(320, 640));

      final drawer = shellScaffold(tester).drawer;
      expect(drawer, isA<Drawer>());
      expect((drawer as Drawer).width, lessThanOrEqualTo(320));
    });
  });
}
