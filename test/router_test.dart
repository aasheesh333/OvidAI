import 'package:flutter_test/flutter_test.dart';

import 'package:ovid_ai/core/router.dart';
import 'package:ovid_ai/ui/auth_screen.dart';
import 'package:ovid_ai/ui/billing_screen.dart';
import 'package:ovid_ai/ui/browser_screen.dart';
import 'package:ovid_ai/ui/memory_screen.dart';
import 'package:ovid_ai/ui/permissions_screen.dart';
import 'package:ovid_ai/ui/plugins_screen.dart';
import 'package:ovid_ai/ui/providers_screen.dart';
import 'package:ovid_ai/ui/sandbox_setup.dart';
import 'package:ovid_ai/ui/schedule_screen.dart';
import 'package:ovid_ai/ui/settings_action_widgets.dart';
import 'package:ovid_ai/ui/settings_backup_screen.dart';
import 'package:ovid_ai/ui/settings_health_screen.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:ovid_ai/ui/shell.dart';
import 'package:ovid_ai/ui/studio_screen.dart';
import 'package:ovid_ai/ui/subagent_screen.dart';
import 'package:ovid_ai/ui/trajectory_screen.dart';
import 'package:ovid_ai/ui/usage_screen.dart';

void main() {
  group('OvidRoutes path constants', () {
    test('top-level constants are stable', () {
      expect(OvidRoutes.chat, '/');
      expect(OvidRoutes.studio, '/studio');
      expect(OvidRoutes.activity, '/activity');
      expect(OvidRoutes.schedule, '/schedule');
      expect(OvidRoutes.library, '/library');
      expect(OvidRoutes.money, '/money');
      expect(OvidRoutes.moneyUsage, '/money/usage');
      expect(OvidRoutes.plugins, '/plugins');
      expect(OvidRoutes.settings, '/settings');
      expect(OvidRoutes.browser, '/browser');
      expect(OvidRoutes.subagent, '/subagent');
    });

    test('settings sub-page constants are stable', () {
      expect(OvidRoutes.settingsProviders, '/settings/providers');
      expect(OvidRoutes.settingsMemory, '/settings/memory');
      expect(OvidRoutes.settingsSkills, '/settings/skills');
      expect(OvidRoutes.settingsBackup, '/settings/backup');
      expect(OvidRoutes.settingsReset, '/settings/reset');
      expect(OvidRoutes.settingsHealth, '/settings/health');
      expect(OvidRoutes.settingsPermissions, '/settings/permissions');
      expect(OvidRoutes.settingsAccount, '/settings/account');
    });

    test('parameterized path builders encode segments', () {
      expect(OvidRoutes.subagentSession('abc'), '/subagent/abc');
      expect(OvidRoutes.subagentSession('a/b'), '/subagent/a%2Fb');
      expect(OvidRoutes.activitySession('s 1'), '/activity/s%201');
      expect(OvidRoutes.scheduleSession('s1'), '/schedule/s1');
    });

    test('all constant paths are unique', () {
      const paths = [
        OvidRoutes.chat,
        OvidRoutes.studio,
        OvidRoutes.activity,
        OvidRoutes.schedule,
        OvidRoutes.library,
        OvidRoutes.money,
        OvidRoutes.moneyUsage,
        OvidRoutes.plugins,
        OvidRoutes.settings,
        OvidRoutes.settingsProviders,
        OvidRoutes.settingsMemory,
        OvidRoutes.settingsSkills,
        OvidRoutes.settingsBackup,
        OvidRoutes.settingsReset,
        OvidRoutes.settingsHealth,
        OvidRoutes.settingsPermissions,
        OvidRoutes.settingsAccount,
        OvidRoutes.browser,
        OvidRoutes.subagent,
      ];
      expect(paths.toSet().length, paths.length);
    });
  });

  group('determineStudioRoute', () {
    test('first open wins over every other signal', () {
      for (final attention in [true, false]) {
        for (final installed in [true, false]) {
          expect(
            determineStudioRoute(
              firstOpenDone: false,
              needsAttention: attention,
              sandboxInstalled: installed,
            ),
            StudioRoute.setupFirstOpen,
          );
        }
      }
    });

    test('attention beats install state once first open is done', () {
      for (final installed in [true, false]) {
        expect(
          determineStudioRoute(
            firstOpenDone: true,
            needsAttention: true,
            sandboxInstalled: installed,
          ),
          StudioRoute.setupAttention,
        );
      }
    });

    test('missing sandbox routes to install setup', () {
      expect(
        determineStudioRoute(
          firstOpenDone: true,
          needsAttention: false,
          sandboxInstalled: false,
        ),
        StudioRoute.setupInstall,
      );
    });

    test('healthy state routes to the studio itself', () {
      expect(
        determineStudioRoute(
          firstOpenDone: true,
          needsAttention: false,
          sandboxInstalled: true,
        ),
        StudioRoute.studio,
      );
    });

    test('studioScreenFor maps each route to the right screen', () {
      expect(studioScreenFor(StudioRoute.studio), isA<StudioScreen>());

      final firstOpen =
          studioScreenFor(StudioRoute.setupFirstOpen) as SandboxSetupScreen;
      expect(firstOpen.studioFirstOpen, isTrue);
      expect(firstOpen.gateMode, isFalse);

      final attention =
          studioScreenFor(StudioRoute.setupAttention) as SandboxSetupScreen;
      expect(attention.studioFirstOpen, isFalse);

      final install =
          studioScreenFor(StudioRoute.setupInstall) as SandboxSetupScreen;
      expect(install.studioFirstOpen, isFalse);
    });
  });

  group('resolveOvidRoute (deep links)', () {
    test('chat root maps to the shell', () {
      final spec = resolveOvidRoute('/');
      expect(spec, isA<ChatRouteSpec>());
      expect(spec!.path, '/');
      expect(spec.buildScreen(), isA<OvidShell>());
    });

    test('studio maps through the supplied gate decision', () {
      final setup = resolveOvidRoute(
        '/studio',
        studioGate: StudioRoute.setupFirstOpen,
      );
      expect(setup, isA<StudioRouteSpec>());
      expect((setup! as StudioRouteSpec).gate, StudioRoute.setupFirstOpen);
      expect(setup.buildScreen(), isA<SandboxSetupScreen>());

      final ready = resolveOvidRoute(
        '/studio',
        studioGate: StudioRoute.studio,
      );
      expect(ready!.buildScreen(), isA<StudioScreen>());
    });

    test('activity and schedule carry the session id', () {
      final activity = resolveOvidRoute('/activity/sess-9');
      expect(activity, isA<ActivityRouteSpec>());
      expect((activity! as ActivityRouteSpec).sessionId, 'sess-9');
      expect(activity.path, '/activity/sess-9');
      expect(activity.buildScreen(), isA<TrajectoryScreen>());
      expect(
        (activity.buildScreen() as TrajectoryScreen).sessionId,
        'sess-9',
      );

      final schedule = resolveOvidRoute('/schedule/sess-9');
      expect(schedule, isA<ScheduleRouteSpec>());
      expect((schedule! as ScheduleRouteSpec).sessionId, 'sess-9');
      expect(schedule.buildScreen(), isA<ScheduleScreen>());

      // Bare parameterized roots are not navigable on their own.
      expect(resolveOvidRoute('/activity'), isNull);
      expect(resolveOvidRoute('/schedule'), isNull);
    });

    test('library, money and plugins map to their screens', () {
      final library = resolveOvidRoute('/library');
      expect(library, isA<LibraryRouteSpec>());
      expect(library!.buildScreen(), isA<MemoryScreen>());

      final money = resolveOvidRoute('/money');
      expect(money, isA<MoneyRouteSpec>());
      expect(money!.buildScreen(), isA<BillingScreen>());

      final usage = resolveOvidRoute('/money/usage');
      expect(usage, isA<MoneyUsageRouteSpec>());
      expect(usage!.buildScreen(), isA<UsageScreen>());

      final plugins = resolveOvidRoute('/plugins');
      expect(plugins, isA<PluginsRouteSpec>());
      expect((plugins! as PluginsRouteSpec).focusCanonicalId, isNull);
      expect(plugins.buildScreen(), isA<PluginsScreen>());

      final focused = resolveOvidRoute(
        '/plugins?focus=${Uri.encodeComponent('ovid.web')}',
      );
      expect(focused, isA<PluginsRouteSpec>());
      expect((focused! as PluginsRouteSpec).focusCanonicalId, 'ovid.web');
      final focusedRoundTrip = resolveOvidRoute(focused.path);
      expect(
        (focusedRoundTrip! as PluginsRouteSpec).focusCanonicalId,
        'ovid.web',
      );
    });

    test('settings root and every sub-page map', () {
      final root = resolveOvidRoute('/settings');
      expect(root, isA<SettingsRouteSpec>());
      expect((root! as SettingsRouteSpec).subPage, isNull);
      expect(root.buildScreen(), isA<SettingsScreen>());

      final expected = <String, SettingsSubPage>{
        '/settings/providers': SettingsSubPage.providers,
        '/settings/memory': SettingsSubPage.memory,
        '/settings/skills': SettingsSubPage.skills,
        '/settings/backup': SettingsSubPage.backup,
        '/settings/reset': SettingsSubPage.reset,
        '/settings/health': SettingsSubPage.health,
        '/settings/permissions': SettingsSubPage.permissions,
        '/settings/account': SettingsSubPage.account,
      };
      expected.forEach((path, subPage) {
        final spec = resolveOvidRoute(path);
        expect(spec, isA<SettingsRouteSpec>(), reason: path);
        expect((spec! as SettingsRouteSpec).subPage, subPage, reason: path);
        expect(spec.path, path, reason: path);
      });
    });

    test('settings sub-page screens match the settings menu targets', () {
      final screens = <SettingsSubPage, Type>{
        SettingsSubPage.providers: ProvidersScreen,
        SettingsSubPage.memory: MemoryScreen,
        SettingsSubPage.skills: SkillsScreen,
        SettingsSubPage.backup: SettingsBackupScreen,
        SettingsSubPage.reset: SettingsResetScreen,
        SettingsSubPage.health: SettingsHealthScreen,
        SettingsSubPage.permissions: PermissionsScreen,
        SettingsSubPage.account: AuthScreen,
      };
      screens.forEach((subPage, type) {
        final spec = SettingsRouteSpec(subPage);
        expect(spec.buildScreen().runtimeType, type, reason: subPage.name);
        expect(
          resolveOvidRoute(spec.path)!.buildScreen().runtimeType,
          type,
          reason: spec.path,
        );
      });
    });

    test('browser maps with an optional url query parameter', () {
      final plain = resolveOvidRoute('/browser');
      expect(plain, isA<BrowserRouteSpec>());
      expect((plain! as BrowserRouteSpec).openUrl, isNull);
      expect(plain.buildScreen(), isA<BrowserScreen>());

      final linked = resolveOvidRoute(
        '/browser?url=${Uri.encodeComponent('https://example.com/x')}',
      );
      expect(linked, isA<BrowserRouteSpec>());
      expect((linked! as BrowserRouteSpec).openUrl, 'https://example.com/x');
      // Round trip: the spec's canonical path resolves back to the same url.
      final roundTrip = resolveOvidRoute(linked.path);
      expect((roundTrip! as BrowserRouteSpec).openUrl, 'https://example.com/x');
    });

    test('subagent deep link maps and round-trips', () {
      final spec = resolveOvidRoute('/subagent/sess-1');
      expect(spec, isA<SubagentRouteSpec>());
      expect((spec! as SubagentRouteSpec).sessionId, 'sess-1');
      expect(spec.path, '/subagent/sess-1');

      final screen = spec.buildScreen();
      expect(screen, isA<SubagentScreen>());
      expect((screen as SubagentScreen).sessionId, 'sess-1');

      // Encoded segments survive the round trip.
      final encoded = resolveOvidRoute(OvidRoutes.subagentSession('a/b'));
      expect(encoded, isA<SubagentRouteSpec>());
      expect((encoded! as SubagentRouteSpec).sessionId, 'a/b');
      expect(encoded.path, '/subagent/a%2Fb');
    });

    test('unknown paths do not map', () {
      expect(resolveOvidRoute('/nope'), isNull);
      expect(resolveOvidRoute('/settings/nope'), isNull);
      expect(resolveOvidRoute(''), isNull);
    });
  });
}
