import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:ovid_ai/core/plugin_registry.dart';
import 'package:ovid_ai/core/plugin_runtime.dart';
import 'package:ovid_ai/core/plugin_source_resolver.dart';
import 'package:ovid_ai/core/grant_store.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/permissions_screen.dart';
import 'package:ovid_ai/ui/plugin_permission_sheet.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';

/// PR-5 — plugin trust, secrets and permissions (F-104 … F-110).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    PluginPermissionStore.resetDeclinedCacheForTest();
    final app = AppState.createForTest();
    app.plugins.clear();
    app.mcpServers.clear();
  });

  tearDown(() {
    PluginPermissionStore.resetDeclinedCacheForTest();
    AppState.resetTestInstance();
  });

  const id = 'acme/trust-kit';

  NormalizedPluginManifest manifest({
    List<PluginHook> hooks = const [],
    List<PluginMcpServer> mcpServers = const [],
    List<PluginDependency> deps = const [],
  }) => NormalizedPluginManifest(
    id: id,
    name: 'Trust Kit',
    version: '1.0.0',
    format: PluginFormat.claudeCode,
    rootPath: '/tmp/$id',
    hooks: hooks,
    mcpServers: mcpServers,
    dependencies: PluginDependencies(packages: deps),
  );

  const commandHook = PluginHook(
    pluginId: id,
    event: 'pre_tool',
    ordinal: 0,
    type: 'command',
    payload: 'echo hi',
    path: 'hooks/hooks.json',
  );
  const httpServer = PluginMcpServer(
    pluginId: id,
    name: 'remote',
    transport: 'http',
    url: 'https://mcp.example.com/mcp',
    envNames: ['MCP_TOKEN'],
    path: '.mcp.json',
  );

  Future<Future<bool?>> openSheet(
    WidgetTester tester,
    NormalizedPluginManifest m, {
    PluginSourceProvenance? provenance,
    Future<bool> Function(Uri)? openUrl,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late Future<bool?> result;
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                result = showPluginPermissionSheet(
                  context,
                  manifest: m,
                  provenance: provenance,
                  openUrl: openUrl,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return result;
  }

  group('approval sheet (F-104, F-105, F-106)', () {
    testWidgets('shellExecute + one npm dependency renders the install-scripts '
        'row, off by default', (tester) async {
      final result = await openSheet(
        tester,
        manifest(
          hooks: const [commandHook],
          deps: const [PluginDependency(name: 'left-pad')],
        ),
      );
      expect(find.byKey(const ValueKey('plugin-install-scripts')), findsOne);
      expect(find.text('Runs install scripts from 1 package'), findsOneWidget);
      final toggle = tester.widget<Switch>(
        find.byKey(const ValueKey('plugin-install-scripts-switch')),
      );
      expect(toggle.value, isFalse);

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      final grant = await PluginPermissionStore().loadAny(id);
      expect(grant!.capabilities, contains(PluginCapability.shellExecute));
      // The hook's shell grant does NOT imply dependency scripts.
      expect(grant.allowDependencyScripts, isFalse);
    });

    testWidgets('opting into install scripts persists the separate opt-in', (
      tester,
    ) async {
      final result = await openSheet(
        tester,
        manifest(deps: const [PluginDependency(name: 'left-pad')]),
      );
      await tester.tap(
        find.byKey(const ValueKey('plugin-install-scripts-switch')),
      );
      await tester.pump();
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(
        (await PluginPermissionStore().loadAny(id))!.allowDependencyScripts,
        isTrue,
      );
    });

    testWidgets('GitHub inspection renders repo, ref, revision, origin and '
        'an unverified warning with a tappable repo', (tester) async {
      final staging = Directory.systemTemp.createTempSync('pr5-prov-');
      addTearDown(() => staging.deleteSync(recursive: true));
      final provenance = PluginSourceProvenance.fromResolved(
        ResolvedPluginSource.forTest(
          source: const GithubPluginSource(owner: 'acme', repo: 'tools'),
          stagingDir: staging,
          fileCount: 12,
          githubRepo: 'acme/tools',
          resolvedRef: 'main',
          revision: '1234567890abcdef',
        ),
      );
      final opened = <Uri>[];
      await openSheet(
        tester,
        manifest(),
        provenance: provenance,
        openUrl: (u) async {
          opened.add(u);
          return true;
        },
      );
      expect(find.text('SOURCE'), findsOneWidget);
      expect(find.text('acme/tools@main (tree 1234567)'), findsOneWidget);
      expect(find.textContaining('Direct from GitHub'), findsOneWidget);
      expect(find.textContaining('12 files'), findsOneWidget);
      expect(find.byKey(const ValueKey('plugin-source-unverified')), findsOne);
      await tester.tap(find.byKey(const ValueKey('plugin-source-open-repo')));
      await tester.pump();
      expect(opened, [Uri.parse('https://github.com/acme/tools')]);
    });

    testWidgets('a marketplace source names the marketplace and is not '
        'flagged unverified', (tester) async {
      final staging = Directory.systemTemp.createTempSync('pr5-prov-');
      addTearDown(() => staging.deleteSync(recursive: true));
      final provenance = PluginSourceProvenance.fromResolved(
        ResolvedPluginSource.forTest(
          source: const MarketplacePluginSource(
            catalogName: 'acme/market',
            declaredSource: 'acme/tools',
          ),
          stagingDir: staging,
          githubRepo: 'acme/tools',
          resolvedRef: 'main',
        ),
      );
      await openSheet(tester, manifest(), provenance: provenance);
      expect(find.text('Marketplace: acme/market'), findsOneWidget);
      expect(find.byKey(const ValueKey('plugin-source-unverified')), findsNothing);
    });

    testWidgets('declining one capability persists the subset and the grant '
        'stays complete', (tester) async {
      final m = manifest(
        hooks: const [commandHook],
        mcpServers: const [httpServer],
      );
      final result = await openSheet(tester, m);
      // Non-declinable capabilities carry no switch.
      expect(
        find.byKey(const ValueKey('plugin-capability-environmentRead')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('plugin-capability-networkConnect')),
      );
      await tester.pump();
      expect(find.textContaining('Declined'), findsOneWidget);
      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      expect(await result, isTrue);

      final grant = (await PluginPermissionStore().loadAny(id))!;
      expect(
        grant.capabilities,
        isNot(contains(PluginCapability.networkConnect)),
      );
      expect(grant.declinedCapabilities, {PluginCapability.networkConnect});
      expect(grant.capabilities, contains(PluginCapability.hooksBlock));

      // A decided (declined) capability completes the approval: the plugin
      // still activates, without the declined contribution.
      final effective = await PluginPermissionStore().effectiveRuntimeGrant(
        pluginId: id,
        manifest: m,
      );
      expect(effective, isNotNull);
      expect(PluginPermissionStore.declinedCapabilitiesFor(id), {
        PluginCapability.networkConnect,
      });
    });
  });

  group('declined capabilities at runtime (F-106)', () {
    test('registry disables just the contributions that need a declined '
        'capability', () {
      final registry = PluginContributionRegistry(
        declinedCapabilities: (_) => {PluginCapability.networkConnect},
      );
      registry.register(
        manifest(hooks: const [commandHook], mcpServers: const [httpServer]),
        activation: PluginActivation.globalActive,
      );
      expect(
        registry.declinedCapabilityForMcpServer(id, 'remote'),
        PluginCapability.networkConnect,
      );
      expect(registry.mcpServersForSession('s1'), isEmpty);
      expect(registry.declinedCapabilityForHook(id, commandHook), isNull);

      final noBlocking = PluginContributionRegistry(
        declinedCapabilities: (_) => {PluginCapability.hooksBlock},
      );
      expect(
        noBlocking.declinedCapabilityForHook(id, commandHook),
        PluginCapability.hooksBlock,
      );
    });

    test('a declined non-declinable capability never completes a grant', () {
      final grant = PluginPermissionGrant(
        pluginId: id,
        manifestDigest: 'sha256:x',
        capabilities: const {},
        declinedCapabilities: const {PluginCapability.workspaceRead},
        approvedAt: DateTime.utc(2026),
      );
      expect(grantCoversRequested(grant, {PluginCapability.workspaceRead}), isFalse);
      final ok = PluginPermissionGrant(
        pluginId: id,
        manifestDigest: 'sha256:x',
        capabilities: const {PluginCapability.mcpRegister},
        declinedCapabilities: const {PluginCapability.networkConnect},
        approvedAt: DateTime.utc(2026),
      );
      expect(
        grantCoversRequested(ok, {
          PluginCapability.mcpRegister,
          PluginCapability.networkConnect,
        }),
        isTrue,
      );
    });

    test('grant JSON round-trips declined capabilities and the scripts '
        'opt-in; legacy JSON fails closed', () {
      final grant = PluginPermissionGrant(
        pluginId: id,
        manifestDigest: 'sha256:x',
        capabilities: const {PluginCapability.hooksObserve},
        declinedCapabilities: const {PluginCapability.deviceControl},
        allowDependencyScripts: true,
        approvedAt: DateTime.utc(2026),
      );
      final back = PluginPermissionGrant.fromJson(
        jsonDecode(jsonEncode(grant.toJson())) as Map<String, dynamic>,
      );
      expect(back.declinedCapabilities, {PluginCapability.deviceControl});
      expect(back.allowDependencyScripts, isTrue);
      final legacy = PluginPermissionGrant.fromJson({
        'pluginId': id,
        'manifestDigest': 'sha256:x',
        'capabilities': ['shellExecute'],
        'approvedAt': '2026-01-01T00:00:00Z',
      });
      expect(legacy.allowDependencyScripts, isFalse);
      expect(legacy.declinedCapabilities, isEmpty);
    });
  });

  testWidgets('Accept, then a forced install failure leaves no effective '
      'grant', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final staging = Directory.systemTemp.createTempSync('pr5-install-');
    PluginRuntimeManager.stagingRootOverrideForTest = staging;
    PluginRuntimeManager.runtimeRootOverrideForTest = staging;
    PluginRuntimeManager.failRenameForTest = true;
    addTearDown(() {
      PluginRuntimeManager.stagingRootOverrideForTest = null;
      PluginRuntimeManager.runtimeRootOverrideForTest = null;
      PluginRuntimeManager.failRenameForTest = false;
      inspectResultsForTest.clear();
      staging.deleteSync(recursive: true);
    });
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: Aether.theme(),
        home: Builder(
          builder: (context) {
            ctx = context;
            return const Scaffold();
          },
        ),
      ),
    );
    late Future<PluginInstallResult?> install;
    await tester.runAsync(() async {
      install = startPluginInstallForTest(
        AppState.I,
        null,
        approvalContext: ctx,
        source: PastedConfigPluginSource(
          label: 'failing',
          rawConfig: jsonEncode({
            'mcpServers': {
              'fixture': {'command': 'node'},
            },
          }),
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (inspectResultsForTest.isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(find.text('Grant plugin access'), findsOneWidget);
    final inspected = inspectResultsForTest.single;
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    // The forced commit failure surfaces as a failed result or a thrown
    // runtime error (the screen reports it as "Install crashed").
    final result = await tester.runAsync(
      () => install.then<Object?>((r) => r, onError: (Object e) => e),
    );
    expect(
      result is PluginRuntimeException ||
          (result is PluginInstallResult &&
              result.status == PluginInstallStatus.failed),
      isTrue,
      reason: '$result',
    );
    final grant = await tester.runAsync(
      () => PluginPermissionStore().effectiveGrant(
        pluginId: inspected.id,
        manifest: inspected,
      ),
    );
    expect(grant, isNull);
    expect(
      await tester.runAsync(() => PluginPermissionStore().loadAny(inspected.id)),
      isNull,
    );
  });

  group('plugin settings storage (F-107, F-108)', () {
    const fields = [
      NativePluginConfigField(key: 'api_token', label: 'Token', secret: true),
      NativePluginConfigField(key: 'endpoint', label: 'Endpoint'),
    ];

    test('namespace keys differ for acme/foo-bar vs acme-foo/bar and from '
        'the native namespace', () {
      final a = NativePluginConfigStore.storageKeyFor('acme/foo-bar', 'k');
      final b = NativePluginConfigStore.storageKeyFor('acme-foo/bar', 'k');
      expect(a, isNot(b));
      expect(a, startsWith('plugin_cfg_'));
      final native = NativePluginConfigStore.storageKeyFor('Acme Foo Bar', 'k');
      expect(native, 'native_plugin_acme_foo_bar__k');
      expect(a, isNot(native));
    });

    test('one plugin cannot read a colliding plugin\'s secret', () async {
      final store = NativePluginConfigStore();
      await store.save(
        pluginName: 'acme/foo-bar',
        fields: fields,
        values: {'api_token': 'sk-victim'},
      );
      expect(
        await store.readAll(pluginName: 'acme-foo/bar', fields: fields),
        isEmpty,
      );
    });

    test('uninstalling a plugin with a saved secret clears it: readAll '
        'returns {}', () async {
      const runtimeId = 'acme/settings-kit';
      final store = NativePluginConfigStore.I;
      await store.save(
        pluginName: runtimeId,
        fields: fields,
        values: {'api_token': 'sk-1', 'endpoint': 'https://x'},
      );
      expect(
        await store.readAll(pluginName: runtimeId, fields: fields),
        hasLength(2),
      );
      final row = PluginItem(
        name: 'Settings Kit',
        author: 'acme',
        description: 'fixture',
        version: '1',
        category: 'Tool',
        installed: true,
      )..runtimeId = runtimeId;
      AppState.I.plugins.add(row);
      await AppState.I.uninstallPlugin(row);
      expect(
        await store.readAll(pluginName: runtimeId, fields: fields),
        <String, String>{},
      );
    });

    test('legacy slug-namespace values migrate once, only when uncontested', () async {
      SharedPreferences.setMockInitialValues({
        'native_plugin_acme_solo__endpoint': 'https://solo',
        'native_plugin_acme_foo_bar__endpoint': 'https://contested',
      });
      FlutterSecureStorage.setMockInitialValues({
        'native_plugin_acme_solo__api_token': 'sk-solo',
      });
      final store = NativePluginConfigStore();
      final moved = await store.migrateLegacyInstalledSettings(
        pluginName: 'acme/solo',
        fields: fields,
        installedPluginIds: const ['acme/solo', 'acme/other'],
      );
      expect(moved, 2);
      expect(await store.readAll(pluginName: 'acme/solo', fields: fields), {
        'api_token': 'sk-solo',
        'endpoint': 'https://solo',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('native_plugin_acme_solo__endpoint'), isNull);

      // Two installed plugins slugify to acme_foo_bar: ownership is
      // ambiguous, so nothing moves.
      final contested = await store.migrateLegacyInstalledSettings(
        pluginName: 'acme/foo-bar',
        fields: fields,
        installedPluginIds: const ['acme/foo-bar', 'acme-foo/bar'],
      );
      expect(contested, 0);
      expect(
        await store.readAll(pluginName: 'acme/foo-bar', fields: fields),
        isEmpty,
      );
    });
  });

  group('catalog_add_mcp stdio approval (security M5)', () {
    late ChatSession session;
    setUp(() {
      session = ChatSession(
        id: 'pr5-m5',
        title: 'Full access chat',
        model: 'm',
        mode: 'drive',
      );
      AppState.I.sessions.insert(0, session);
      AppState.I.activeSessionId = session.id;
      AgentService.setRunSessionForTest(session.id);
      AgentService.I.debugPauseScheduleTimerForTest(true);
    });
    tearDown(() {
      AgentService.I.approve(false);
      AgentService.I.dropSessionRun(session.id);
      AgentService.setRunSessionForTest('');
      AgentService.I.debugPauseScheduleTimerForTest(false);
    });

    for (final allow in [false, true]) {
      test('a stdio server asks even in Full Access (${allow ? 'approve' : 'deny'})', () async {
        final prompted = Completer<void>();
        void listener() {
          if (AgentService.I.pendingApproval != null && !prompted.isCompleted) {
            prompted.complete();
          }
        }

        AgentService.I.addListener(listener);
        addTearDown(() => AgentService.I.removeListener(listener));
        final result = AgentService.I.dispatchForTest('catalog_add_mcp', {
          'name': 'pr5-local',
          'command': 'node',
          'args': ['server.js'],
        });
        await prompted.future.timeout(const Duration(seconds: 3));
        expect(AgentService.I.pendingApproval!.detail, contains('node server.js'));
        AgentService.I.approve(allow);
        final out = await result;
        final added = AppState.I.mcpServers.any((m) => m.name == 'pr5-local');
        expect(added, allow);
        if (!allow) expect(out, contains('DENIED'));
      });
    }

    test('an http server in Full Access adds without a prompt', () async {
      final out = await AgentService.I.dispatchForTest('catalog_add_mcp', {
        'name': 'pr5-remote',
        'url': 'https://mcp.example.com/mcp',
      });
      expect(out, contains('added'));
      expect(AgentService.I.pendingApproval, isNull);
    });
  });

  group('Permissions screen (F-109, F-110)', () {
    Future<void> pumpScreen(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(theme: Aether.theme(), home: const PermissionsScreen()),
      );
      await tester.pump();
    }

    testWidgets('two sessions with host grants are both listed by chat', (
      tester,
    ) async {
      final app = AppState.I;
      final a = ChatSession(id: 'pr5-a', title: 'Alpha chat', model: 'm');
      final b = ChatSession(id: 'pr5-b', title: 'Beta chat', model: 'm');
      a.grants.add(PermissionGrant.host('alpha.example', sessionId: a.id));
      b.grants.add(PermissionGrant.host('beta.example', sessionId: b.id));
      app.sessions.addAll([a, b]);
      app.activeSessionId = a.id;
      await pumpScreen(tester);
      expect(find.text('Alpha chat'), findsOneWidget);
      expect(find.text('Beta chat'), findsOneWidget);
      expect(find.text('host alpha.example'), findsOneWidget);
      expect(find.text('host beta.example'), findsOneWidget);
      expect(find.textContaining('current chat'), findsOneWidget);
      expect(find.byKey(const ValueKey('open-chat-pr5-b')), findsOneWidget);

      // Per-chat Revoke all clears only that chat.
      await tester.tap(find.byKey(const ValueKey('revoke-chat-pr5-b')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke').last);
      await tester.pumpAndSettle();
      expect(b.grants, isEmpty);
      expect(a.grants, hasLength(1));
      expect(find.text('Beta chat'), findsNothing);
    });

    testWidgets('an always-allowed tool is listed, can be revoked, and the '
        'next call asks again', (tester) async {
      final app = AppState.I;
      final s = ChatSession(id: 'pr5-tools', title: 'Tools chat', model: 'm');
      app.sessions.add(s);
      app.activeSessionId = s.id;
      addTearDown(() => AgentService.I.dropSessionRun(s.id));
      AgentService.I.rememberAlwaysAllowForTest(s.id, 'run_shell');
      expect(AgentService.I.isToolAlwaysAllowedForTest(s.id, 'run_shell'), isTrue);
      await pumpScreen(tester);
      expect(find.text('Tools chat'), findsOneWidget);
      expect(find.text('run_shell'), findsOneWidget);
      expect(find.text('Always allowed · until the app closes'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('revoke-tool-pr5-tools-run_shell')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke').last);
      await tester.pumpAndSettle();
      expect(AgentService.I.isToolAlwaysAllowedForTest(s.id, 'run_shell'), isFalse);
      expect(AgentService.I.alwaysAllowedToolsFor(s.id), isEmpty);
      expect(find.text('run_shell'), findsNothing);
    });

    testWidgets('global Revoke all clears every chat', (tester) async {
      final app = AppState.I;
      final a = ChatSession(id: 'pr5-g1', title: 'One', model: 'm');
      final b = ChatSession(id: 'pr5-g2', title: 'Two', model: 'm');
      a.grants.add(PermissionGrant.host('one.example', sessionId: a.id));
      app.sessions.addAll([a, b]);
      addTearDown(() => AgentService.I.dropSessionRun(b.id));
      AgentService.I.rememberAlwaysAllowForTest(b.id, 'web_fetch');
      await pumpScreen(tester);
      await tester.tap(find.byKey(const ValueKey('revoke-all-decisions')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke').last);
      await tester.pumpAndSettle();
      expect(a.grants, isEmpty);
      expect(AgentService.I.alwaysAllowedToolsFor(b.id), isEmpty);
      expect(
        find.textContaining('No remembered decisions in any chat yet'),
        findsOneWidget,
      );
    });
  });
}
