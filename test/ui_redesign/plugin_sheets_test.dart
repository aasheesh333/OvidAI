// Premium Aether redesign of the three plugin lifecycle surfaces: the
// consolidated capability-approval sheet, the live install-progress sheet,
// and the schema-driven settings panel. Pins the premium chrome
// ([AetherSheet] title + drag handle, [AetherSectionTitle] eyebrows,
// [AetherCard] rows, [AetherPrimaryButton]/[AetherGhostButton] actions) and
// — more importantly — the preserved callbacks every call site depends on:
// Accept → [PluginPermissionStore.save] + Navigator.pop(true), Cancel →
// Navigator.pop(false), the install sheet's Done/Close actions popping the
// route, and the settings panel saving values through the EXISTING
// [NativePluginConfigStore] (prefs for plain fields, secure storage for
// secrets).
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/native_plugin.dart';
import 'package:ovid_ai/core/plugin_manifest.dart';
import 'package:ovid_ai/core/plugin_permissions.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/plugin_install_progress.dart';
import 'package:ovid_ai/ui/plugin_permission_sheet.dart';
import 'package:ovid_ai/ui/plugin_settings_panel.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';

/// Bounded pump helper: the live install surface shows an indeterminate
/// [CircularProgressIndicator], so `pumpAndSettle` would never settle.
/// Pumping a fixed number of frames drives in-flight async work to
/// completion without waiting on an animation that has no end.
Future<void> pumpFrames(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('showPluginPermissionSheet (consolidated capability approval)', () {
    NormalizedPluginManifest manifest({
      String id = 'acme/approval-kit',
      String name = 'Approval Kit',
      List<PluginCommand> commands = const [],
      List<PluginMcpServer> mcpServers = const [],
      PluginDependencies dependencies = const PluginDependencies(),
    }) => NormalizedPluginManifest(
      id: id,
      name: name,
      version: '1.0.0',
      format: PluginFormat.claudeCode,
      rootPath: '/tmp/$id',
      commands: commands,
      mcpServers: mcpServers,
      dependencies: dependencies,
    );

    /// Opens the sheet. When [onResult] is provided it receives the sheet's
    /// result future synchronously (the opener closure assigns it during
    /// [WidgetTester.tap], before the route resolves).
    Future<void> openSheet(
      WidgetTester tester,
      NormalizedPluginManifest m, {
      void Function(Future<bool?> result)? onResult,
    }) async {
      late Future<bool?> result;
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {
                    result = showPluginPermissionSheet(context, manifest: m);
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      onResult?.call(result);
    }

    testWidgets(
      'renders the premium Aether surface (title, eyebrows, action buttons)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await openSheet(
          tester,
          manifest(
            commands: const [
              PluginCommand(
                pluginId: 'acme/approval-kit',
                name: 'review',
                path: 'commands/review.md',
              ),
            ],
            dependencies: const PluginDependencies(
              packages: [
                PluginDependency(name: 'left-pad', versionSpec: '^1.0.0'),
              ],
            ),
          ),
        );

        // AetherSheet renders the title text (h2) and the premium chrome.
        expect(find.byType(AetherSheet), findsOneWidget);
        expect(find.text('Grant plugin access'), findsOneWidget);
        // Plugin identity: name + id row.
        expect(find.text('Approval Kit'), findsOneWidget);
        // Eyebrow sections (uppercased by AetherSectionTitle):
        expect(find.text('CAPABILITIES'), findsOneWidget);
        expect(find.text('DEPENDENCIES'), findsOneWidget);
        // Dependency row text comes through verbatim.
        expect(find.textContaining('left-pad'), findsOneWidget);
        // Action buttons preserved: Accept (primary) + Cancel (ghost).
        expect(find.widgetWithText(FilledButton, 'Accept'), findsOneWidget);
        expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      },
    );

    testWidgets(
      'empty capabilities render the "no special capabilities" callout',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await openSheet(tester, manifest());

        expect(
          find.text('This plugin requests no special capabilities.'),
          findsOneWidget,
        );
        // No eyebrows when there is nothing to list.
        expect(find.text('CAPABILITIES'), findsNothing);
        expect(find.text('DEPENDENCIES'), findsNothing);
      },
    );

    testWidgets('Accept persists the consolidated grant and returns true', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final m = manifest(
        commands: const [
          PluginCommand(
            pluginId: 'acme/approval-kit',
            name: 'review',
            path: 'commands/review.md',
          ),
        ],
      );
      Future<bool?>? result;
      await openSheet(tester, m, onResult: (r) => result = r);

      await tester.tap(find.widgetWithText(FilledButton, 'Accept'));
      await pumpFrames(tester);

      expect(await result, isTrue);
      // One consolidated grant persisted under the manifest digest; it
      // covers the inferred capability set from the manifest.
      final grant = await PluginPermissionStore().load(
        m.id,
        pluginManifestDigest(m),
      );
      expect(grant, isNotNull);
      expect(grant!.manifestDigest, pluginManifestDigest(m));
      expect(grant.capabilities, containsAll(inferRequestedCapabilities(m)));
    });

    testWidgets('Cancel pops false and persists nothing', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final m = manifest();
      Future<bool?>? result;
      await openSheet(tester, m, onResult: (r) => result = r);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await pumpFrames(tester);

      expect(await result, isFalse);
      final grant = await PluginPermissionStore().loadAny(m.id);
      expect(
        grant,
        isNull,
        reason: 'Cancel must leave no grant behind — the caller aborts',
      );
    });
  });

  group('PluginInstallProgressSheet (live install progress)', () {
    Future<void> pumpSheet(
      WidgetTester tester,
      PluginInstallProgress progress, {
      String? subtitle,
    }) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => PluginInstallProgressSheet(
                    progress: progress,
                    title: 'Installing fixture',
                    subtitle: subtitle,
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets(
      'renders the premium Aether sheet with phase label, progress bar, and log',
      (tester) async {
        final progress = PluginInstallProgress()
          ..setPhase('Fetching sources', 0.4)
          ..line('clone complete')
          ..line('resolving deps');
        addTearDown(progress.dispose);

        await pumpSheet(tester, progress, subtitle: 'from github.com/acme/kit');

        expect(find.byType(AetherSheet), findsOneWidget);
        expect(find.text('Installing fixture'), findsOneWidget);
        expect(find.text('from github.com/acme/kit'), findsOneWidget);
        expect(find.text('Fetching sources'), findsOneWidget);
        // Terminal-style log view with each line.
        expect(find.byType(ProgressLogView), findsOneWidget);
        expect(find.text('clone complete'), findsOneWidget);
        expect(find.text('resolving deps'), findsOneWidget);
        // While mid-install, a ghost "Close — install continues" is shown.
        expect(
          find.widgetWithText(TextButton, 'Close — install continues'),
          findsOneWidget,
        );
      },
    );

    testWidgets('Done button pops the route on success', (tester) async {
      final progress = PluginInstallProgress()
        ..finish(ok: true, summary: 'Installed cleanly.');
      addTearDown(progress.dispose);

      await pumpSheet(tester, progress);

      expect(find.widgetWithText(FilledButton, 'Done'), findsOneWidget);
      expect(find.text('Installed cleanly.'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Done'));
      await pumpFrames(tester);

      expect(find.byType(PluginInstallProgressSheet), findsNothing);
    });

    testWidgets(
      'Close button shows failure summary and pops the route on error',
      (tester) async {
        final progress = PluginInstallProgress()
          ..finish(ok: false, summary: 'Install failed: boom.');
        addTearDown(progress.dispose);

        await pumpSheet(tester, progress);

        expect(find.widgetWithText(FilledButton, 'Close'), findsOneWidget);
        expect(find.text('Install failed: boom.'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Close'));
        await pumpFrames(tester);

        expect(find.byType(PluginInstallProgressSheet), findsNothing);
      },
    );
  });

  group('PluginSettingsPanel (schema-driven settings surface)', () {
    const pluginName = 'acme/settings-kit';
    const endpointPrefsKey = 'native_plugin_acme_settings_kit__endpoint';
    const tokenSecureKey = 'native_plugin_acme_settings_kit__api_token';

    const fields = <NativePluginConfigField>[
      NativePluginConfigField(
        key: 'endpoint',
        label: 'Endpoint',
        hint: 'Base URL',
      ),
      NativePluginConfigField(
        key: 'api_token',
        label: 'API Token',
        secret: true,
        hint: 'From the dashboard',
      ),
    ];

    Future<void> pumpPanel(WidgetTester tester, {VoidCallback? onSaved}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: Aether.theme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PluginSettingsPanel(
                pluginName: pluginName,
                fields: fields,
                onSaved: onSaved,
              ),
            ),
          ),
        ),
      );
      await pumpFrames(tester);
    }

    testWidgets(
      'renders a labeled field per schema entry with the Aether save button',
      (tester) async {
        await pumpPanel(tester);

        // One keyed field per declared schema entry.
        expect(
          find.byKey(const ValueKey('plugin-settings-field-endpoint')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('plugin-settings-field-api_token')),
          findsOneWidget,
        );
        // Human-visible labels (the field label row + the input hint both
        // carry the label text, so each appears twice).
        expect(find.text('Endpoint'), findsNWidgets(2));
        expect(find.text('API Token'), findsNWidgets(2));
        // Secret fields render with a SECRET pill via AetherPill.
        expect(find.byType(AetherPill), findsWidgets);
        expect(find.text('SECRET'), findsOneWidget);
        // Save action is an AetherPrimaryButton.
        expect(
          find.byKey(const ValueKey('plugin-settings-save')),
          findsOneWidget,
        );
        expect(find.byType(AetherPrimaryButton), findsWidgets);
      },
    );

    testWidgets('secret fields obscure text; plain fields do not', (
      tester,
    ) async {
      await pumpPanel(tester);

      final secret = tester.widget<TextField>(
        find.byKey(const ValueKey('plugin-settings-field-api_token')),
      );
      final plain = tester.widget<TextField>(
        find.byKey(const ValueKey('plugin-settings-field-endpoint')),
      );
      expect(secret.obscureText, isTrue);
      expect(plain.obscureText, isFalse);
    });

    testWidgets(
      'Save routes plain fields to prefs and secrets to secure storage',
      (tester) async {
        var savedCallbacks = 0;
        await pumpPanel(tester, onSaved: () => savedCallbacks++);

        await tester.enterText(
          find.byKey(const ValueKey('plugin-settings-field-endpoint')),
          'https://api.example.com',
        );
        await tester.enterText(
          find.byKey(const ValueKey('plugin-settings-field-api_token')),
          'sk-secret-99',
        );
        await tester.tap(find.byKey(const ValueKey('plugin-settings-save')));
        await pumpFrames(tester);

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(endpointPrefsKey), 'https://api.example.com');
        // The secret never lands in prefs — not under its own key, not
        // under any other prefs entry.
        expect(prefs.getString(tokenSecureKey), isNull);
        for (final key in prefs.getKeys()) {
          expect(
            prefs.get(key)?.toString() ?? '',
            isNot(contains('sk-secret-99')),
            reason: 'no prefs entry may hold a secret value',
          );
        }
        const secure = FlutterSecureStorage();
        expect(await secure.read(key: tokenSecureKey), 'sk-secret-99');
        // Honest in-UI save confirmation + onSaved callback fired.
        expect(
          find.byKey(const ValueKey('plugin-settings-saved')),
          findsOneWidget,
        );
        expect(savedCallbacks, 1);
      },
    );
  });
}
