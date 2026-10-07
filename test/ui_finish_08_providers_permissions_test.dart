import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/grant_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/permissions_screen.dart';
import 'package:ovid_ai/ui/providers_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _longName = 'Research team international inference gateway';
const _longModel = 'research-team/very-long-model-identifier-with-version-2026-10';
const _longPath = '/research/projects/international-team/private/dataset.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppState app;
  late bool previousDark;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    previousDark = Aether.dark;
    app = AppState.createForTest();
    AgentService.I.debugPauseScheduleTimerForTest(true);
    app.providers.removeWhere((p) => p.id != AppState.ovidCloudProviderId);
  });

  tearDown(() {
    fetchProviderModelsForTest = null;
    removeCustomProviderForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AppState.resetTestInstance();
    Aether.dark = previousDark;
  });

  ProviderConfig populate() {
    final provider = ProviderConfig(
      id: 'finish-08',
      name: _longName,
      description: 'Research gateway',
      baseUrl: 'https://inference.example.test/v1',
      custom: true,
      models: [_longModel, 'research-chat'],
    );
    app.providers.add(provider);
    return provider;
  }

  Future<void> host(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(360, 640),
    double scale = 2,
    bool dark = true,
    GlobalKey? captureKey,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    Aether.dark = dark;
    await tester.pumpWidget(MaterialApp(
      theme: Aether.theme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: RepaintBoundary(key: captureKey, child: screen),
    ));
    await tester.pump();
  }

  Future<void> reveal(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        160,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 50,
      );
    }
    await tester.ensureVisible(finder);
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull);
  }

  for (final config in [
    (size: const Size(360, 640), scale: 2.0),
    (size: const Size(320, 640), scale: 1.0),
    (size: const Size(1024, 768), scale: 1.0),
  ]) {
    for (final dark in [true, false]) {
      testWidgets('providers and edit sheet readable ${config.size} ${config.scale} dark=$dark', (tester) async {
        final provider = populate();
        await host(tester, const ProvidersScreen(), size: config.size, scale: config.scale, dark: dark);
        expect(tester.takeException(), isNull);
        await reveal(tester, find.text('Manage plan'));
        await reveal(tester, find.text(_longName));
        final title = tester.widget<Text>(find.text(_longName));
        expect(title.overflow, isNot(TextOverflow.ellipsis));
        await reveal(tester, find.text(_longModel));
        await reveal(tester, find.byTooltip('More actions'));
        await tester.tap(find.byTooltip('More actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final url = find.byType(TextField);
        await reveal(tester, url);
        await tester.enterText(url, 'not-an-absolute-url');
        await tester.tap(find.byTooltip('Save base URL'));
        await tester.pumpAndSettle();
        expect(provider.baseUrl, 'https://inference.example.test/v1');
        await reveal(tester, find.text('Enter a valid absolute base URL.'));
        await reveal(tester, url);
        await tester.enterText(url, 'https://updated.example.test/v1');
        await tester.tap(find.byTooltip('Save base URL'));
        await tester.pumpAndSettle();
        expect(provider.baseUrl, 'https://updated.example.test/v1');
        await reveal(tester, find.text('[OI]-compatible'));
        await reveal(tester, find.text('Anthropic'));
        await tester.tap(find.text('Anthropic'));
        await tester.pumpAndSettle();
        expect(provider.effectiveApiFormat, ApiFormat.anthropic);
        await reveal(tester, find.byTooltip('Remove model $_longModel'));
        await tester.tap(find.byTooltip('Remove model $_longModel'));
        await tester.pumpAndSettle();
        expect(provider.models, ['research-chat']);
        await reveal(tester, find.text('Done'));
      });

      testWidgets('permission details and revoke ${config.size} ${config.scale} dark=$dark', (tester) async {
        final session = ChatSession(id: 'finish-08-session', title: 'Research', model: 'research-chat');
        session.grants.addAll([
          PermissionGrant.path(_longPath, sessionId: session.id),
          PermissionGrant.path('/research/shared', sessionId: session.id, recursive: true),
          PermissionGrant.host('research.example.test', sessionId: session.id, decision: PermissionGrant.decisionDeny),
        ]);
        app.sessions.add(session);
        app.activeSessionId = session.id;
        app.globalPermissionGrants = [PermissionGrant.path('/legacy/archive', global: true)];
        await host(tester, const PermissionsScreen(), size: config.size, scale: config.scale, dark: dark);
        expect(tester.takeException(), isNull);
        await reveal(tester, find.text('path $_longPath'));
        expect(find.textContaining('Exact path'), findsWidgets);
        expect(find.textContaining('Directory and descendants'), findsOneWidget);
        expect(find.textContaining('all ports and paths'), findsOneWidget);
        await reveal(tester, find.textContaining('Directory and descendants'));
        await reveal(tester, find.textContaining('all ports and paths'));
        final revoke = find.byKey(ValueKey('revoke-session-path-$_longPath'));
        await reveal(tester, revoke);
        await tester.tap(revoke);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(session.grants.length, 3);
        await tester.tap(revoke);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Revoke').last);
        await tester.pumpAndSettle();
        expect(session.grants.map((g) => g.value), isNot(contains(_longPath)));
        expect(app.globalPermissionGrants.length, 1);
        await reveal(tester, find.text('Approval prompts appear in chat'));
        expect(find.widgetWithText(TextButton, 'Allow'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Deny'), findsNothing);
        expect(find.text('No pending requests'), findsNothing);
      });
    }
  }

  testWidgets('legacy revoke removes only inert entry and explains its effect', (tester) async {
    final legacy = PermissionGrant.path(_longPath, global: true);
    app.globalPermissionGrants = [legacy];
    await host(tester, const PermissionsScreen());
    final revoke = find.byKey(ValueKey('revoke-global-path-$_longPath'));
    await reveal(tester, revoke);
    await tester.tap(revoke);
    await tester.pumpAndSettle();
    expect(find.textContaining('already ignored at runtime'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Revoke').last);
    await tester.pumpAndSettle();
    expect(app.globalPermissionGrants, isEmpty);
    expect(find.text('path $_longPath'), findsNothing);
  });

  testWidgets('agent grant notifications refresh the visible permission decisions', (tester) async {
    final session = ChatSession(id: 'notify-08', title: 'Research', model: 'research-chat');
    final grant = PermissionGrant.host('research.example.test', sessionId: session.id);
    session.grants.add(grant);
    app.sessions.add(session);
    app.activeSessionId = session.id;
    await host(tester, const PermissionsScreen());
    expect(find.text('host research.example.test'), findsOneWidget);
    await AgentService.I.revokeSessionPermissionGrant(grant);
    await tester.pump();
    expect(find.text('host research.example.test'), findsNothing);
    expect(find.textContaining('No decisions for this session yet'), findsOneWidget);
  });

  testWidgets('open revoke confirmation cannot remove another conversation decision', (tester) async {
    final first = ChatSession(id: 'first-08', title: 'First', model: 'research-chat');
    final second = ChatSession(id: 'second-08', title: 'Second', model: 'research-chat');
    first.grants.add(PermissionGrant.path(_longPath, sessionId: first.id));
    second.grants.add(PermissionGrant.path(_longPath, sessionId: second.id));
    app.sessions.addAll([first, second]);
    app.activeSessionId = first.id;
    await host(tester, const PermissionsScreen());
    final revoke = find.byKey(ValueKey('revoke-session-path-$_longPath'));
    await reveal(tester, revoke);
    await tester.tap(revoke);
    await tester.pumpAndSettle();
    app.activeSessionId = second.id;
    app.refresh();
    await tester.pump();
    await tester.tap(find.text('Revoke').last);
    await tester.pumpAndSettle();
    expect(first.grants.length, 1);
    expect(second.grants.length, 1);
    expect(find.text('This decision is no longer in the current session.'), findsOneWidget);
  });

  testWidgets('built-in free provider and empty add sheet remain readable at large text', (tester) async {
    app.providers.add(ProviderConfig(
      id: 'free-08', name: _longName, description: 'Free tier',
      baseUrl: 'https://example.test/v1', isFree: true,
    ));
    await host(tester, const ProvidersScreen());
    await reveal(tester, find.text('Free tier — key required'));
    expect(find.text('FREE'), findsWidgets);
    await reveal(tester, find.byTooltip('More actions'));
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsNothing);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await reveal(tester, find.textContaining('No models yet'));
    await reveal(tester, find.text('Done'));
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    app.providers.removeWhere((p) => p.id != AppState.ovidCloudProviderId);
    app.refresh();
    await tester.pump();
    await reveal(tester, find.text('Add provider'));
    await tester.tap(find.text('Add provider'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('API key (optional)'));
    await reveal(tester, find.text('Add'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('key sheet scrolls above keyboard and saves and clears secure key', (tester) async {
    // Create the credential queue in the same fake-async zone as its UI
    // callbacks so pumps can drain its initial Future and chained writes.
    app = AppState.createForTest();
    app.providers.removeWhere((p) => p.id != AppState.ovidCloudProviderId);
    final provider = populate();
    await host(tester, const ProvidersScreen());
    await reveal(tester, find.widgetWithText(TextButton, 'API key'));
    await tester.tap(find.widgetWithText(TextButton, 'API key'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    expect(tester.takeException(), isNull);
    final field = find.byType(TextField);
    await reveal(tester, field);
    expect(tester.widget<TextField>(field).obscureText, isTrue);
    await tester.enterText(field, ' sk- test\nkey ');
    await reveal(tester, find.text('Save'));
    expect(find.text('Save').hitTestable(), findsOneWidget);
    const storage = FlutterSecureStorage();
    const storageKey = 'ovid_provider_key_finish-08';
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(provider.apiKey, 'sk-testkey');
    expect(find.text('$_longName API key'), findsNothing);
    expect(await storage.read(key: storageKey), 'sk-testkey');
    tester.view.resetViewInsets();
    await tester.pump();
    await reveal(tester, find.widgetWithText(TextButton, 'API key'));
    await tester.tap(find.widgetWithText(TextButton, 'API key'));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Clear'));
    expect(find.text('Clear').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(provider.hasKey, isFalse);
    expect(await storage.read(key: storageKey), isNull);
  });

  testWidgets('fetch disables duplicate requests and exposes failure and retry result', (tester) async {
    final provider = populate();
    final pending = Completer<String?>();
    var calls = 0;
    fetchProviderModelsForTest = (_) { calls++; return pending.future; };
    await host(tester, const ProvidersScreen());
    await reveal(tester, find.text('Fetch models'));
    await tester.tap(find.text('Fetch models'));
    await tester.pump();
    final busy = find.widgetWithText(TextButton, 'Fetching models…');
    expect(tester.widget<TextButton>(busy).onPressed, isNull);
    expect(calls, 1);
    pending.complete('Failed: HTTP 401 — check key/URL');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await reveal(tester, find.text('Failed: HTTP 401 — check key/URL'));
    fetchProviderModelsForTest = (_) async {
      provider.models.add('new-research-model');
      return null;
    };
    await reveal(tester, find.text('Fetch models'));
    await tester.tap(find.text('Fetch models'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await reveal(tester, find.text('3 models fetched ✓'));
    await reveal(tester, find.text('new-research-model'));
  });

  testWidgets('capture populated providers screen', (tester) async {
    populate();
    final key = GlobalKey();
    await host(tester, const ProvidersScreen(), size: const Size(1024, 768), scale: 1, captureKey: key);
    expect(find.text(_longName), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('UI_REVIEW_CAPTURE')) {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/opencode/ui-finish-08.png').writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
  });

  testWidgets('empty model response remains actionable and thrown fetch can retry', (tester) async {
    final provider = populate();
    provider.models.clear();
    fetchProviderModelsForTest = (_) async => throw const FormatException('Invalid response');
    await host(tester, const ProvidersScreen());
    await reveal(tester, find.text('Fetch models'));
    await tester.tap(find.text('Fetch models'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await reveal(tester, find.textContaining('Fetch failed:'));
    fetchProviderModelsForTest = (_) async => null;
    await reveal(tester, find.text('Fetch models'));
    await tester.tap(find.text('Fetch models'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await reveal(tester, find.textContaining('No models returned.'));
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Fetch models')).onPressed, isNotNull);
    expect(provider.models, isEmpty);
  });
}
