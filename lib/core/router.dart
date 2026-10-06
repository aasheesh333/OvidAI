// Central navigation route table for Ovid.
//
// Today navigation is scattered imperative `Navigator.push(MaterialPageRoute)`
// calls across `chat_screen.dart`, `sidebar.dart`, `sandbox_setup.dart`,
// `settings_screen.dart`, … This module is the single typed replacement:
//
//   • [OvidRoutes] — stable deep-link path constants,
//   • [OvidRouteSpec] — typed destinations (path + screen builder),
//   • [resolveOvidRoute] — deep-link path → destination parser,
//   • [determineStudioRoute] — the ONE resolver every Studio entry uses,
//   • `pushX(context, …)` — helpers that push the right screen.
//
// NOTHING here is wired into `main.dart` or the screens yet — adopters
// (sidebar, chat header, `openStudio`, settings rows) swap their inline
// `MaterialPageRoute` pushes for these helpers one call site at a time.

import 'package:flutter/material.dart';

import '../ui/auth_screen.dart';
import '../ui/billing_screen.dart';
import '../ui/browser_screen.dart';
import '../ui/memory_screen.dart';
import '../ui/permissions_screen.dart';
import '../ui/plugins_screen.dart';
import '../ui/providers_screen.dart';
import '../ui/sandbox_setup.dart';
import '../ui/schedule_screen.dart';
import '../ui/settings_action_widgets.dart';
import '../ui/settings_backup_screen.dart';
import '../ui/settings_health_screen.dart';
import '../ui/settings_screen.dart';
import '../ui/shell.dart';
import '../ui/studio_screen.dart';
import '../ui/subagent_screen.dart';
import '../ui/trajectory_screen.dart';
import '../ui/usage_screen.dart';

/// Deep-link path constants. Keep stable: external links may rely on them.
abstract final class OvidRoutes {
  /// Chat root — the shell IS the chat.
  static const String chat = '/';

  /// Studio (code & terminal). Gated — see [determineStudioRoute].
  static const String studio = '/studio';

  /// Activity — per-session event ledger. Navigable only with a session:
  /// `/activity/<sessionId>` (see [activitySession]).
  static const String activity = '/activity';

  /// Background-job schedule. Navigable only with a session:
  /// `/schedule/<sessionId>` (see [scheduleSession]).
  static const String schedule = '/schedule';

  /// Library — the agent's saved memory.
  static const String library = '/library';

  /// Money — plan & billing.
  static const String money = '/money';

  /// Money sub-page — provider usage & receipts.
  static const String moneyUsage = '/money/usage';

  /// Plugins & MCP servers. Optional `?focus=<canonicalId>` deep link.
  static const String plugins = '/plugins';

  /// Settings root; sub-pages live at `/settings/<name>`
  /// (see [SettingsSubPage]).
  static const String settings = '/settings';
  static const String settingsProviders = '/settings/providers';
  static const String settingsMemory = '/settings/memory';
  static const String settingsSkills = '/settings/skills';
  static const String settingsBackup = '/settings/backup';
  static const String settingsReset = '/settings/reset';
  static const String settingsHealth = '/settings/health';
  static const String settingsPermissions = '/settings/permissions';
  static const String settingsAccount = '/settings/account';

  /// In-app browser. Optional `?url=<target>` deep link.
  static const String browser = '/browser';

  /// Subagent transcript. Navigable only with a session:
  /// `/subagent/<sessionId>` (see [subagentSession]).
  static const String subagent = '/subagent';

  /// `/subagent/<sessionId>` with the id path-encoded.
  static String subagentSession(String sessionId) =>
      '$subagent/${Uri.encodeComponent(sessionId)}';

  /// `/activity/<sessionId>` with the id path-encoded.
  static String activitySession(String sessionId) =>
      '$activity/${Uri.encodeComponent(sessionId)}';

  /// `/schedule/<sessionId>` with the id path-encoded.
  static String scheduleSession(String sessionId) =>
      '$schedule/${Uri.encodeComponent(sessionId)}';
}

// ---------------------------------------------------------------------------
// Studio gate — the single resolver used by every Studio entry point
// (chat header, sidebar, sandbox hand-off). Pure: callers gather the three
// inputs from AppState / StudioSetupCoordinator / SandboxService and the
// decision is deterministic for a given triple.
// ---------------------------------------------------------------------------

/// Where a Studio entry lands.
enum StudioRoute {
  /// Sandbox is ready — open the studio itself.
  studio,

  /// First Studio open ever: approval + full install flow
  /// (`SandboxSetupScreen(studioFirstOpen: true)`).
  setupFirstOpen,

  /// A previous install needs attention (failed/partial/in progress).
  setupAttention,

  /// Sandbox not on disk: (re)install flow.
  setupInstall,
}

/// The ONE Studio gate resolver. Mirrors the truth table `openStudio`
/// applies today:
///
///   1. first open not done        → [StudioRoute.setupFirstOpen]
///   2. setup needs attention      → [StudioRoute.setupAttention]
///   3. sandbox not installed      → [StudioRoute.setupInstall]
///   4. otherwise                  → [StudioRoute.studio]
StudioRoute determineStudioRoute({
  required bool firstOpenDone,
  required bool needsAttention,
  required bool sandboxInstalled,
}) {
  if (!firstOpenDone) return StudioRoute.setupFirstOpen;
  if (needsAttention) return StudioRoute.setupAttention;
  if (!sandboxInstalled) return StudioRoute.setupInstall;
  return StudioRoute.studio;
}

/// Screen a resolved [StudioRoute] pushes.
Widget studioScreenFor(StudioRoute route) => switch (route) {
  StudioRoute.studio => const StudioScreen(),
  StudioRoute.setupFirstOpen => const SandboxSetupScreen(
    studioFirstOpen: true,
  ),
  StudioRoute.setupAttention => const SandboxSetupScreen(),
  StudioRoute.setupInstall => const SandboxSetupScreen(),
};

// ---------------------------------------------------------------------------
// Typed destinations — the route table.
// ---------------------------------------------------------------------------

/// A typed, deep-linkable destination: its canonical [path] plus the screen
/// it pushes. Parse paths back into specs with [resolveOvidRoute].
sealed class OvidRouteSpec {
  const OvidRouteSpec();

  /// Canonical deep-link path for this destination.
  String get path;

  /// The screen this destination pushes.
  Widget buildScreen();
}

/// Chat root (`/`) — the shell.
final class ChatRouteSpec extends OvidRouteSpec {
  const ChatRouteSpec();

  @override
  String get path => OvidRoutes.chat;

  @override
  Widget buildScreen() => const OvidShell();
}

/// Studio (`/studio`). Carries the gate decision — compute it with
/// [determineStudioRoute] before pushing.
final class StudioRouteSpec extends OvidRouteSpec {
  const StudioRouteSpec(this.gate);

  /// The gate decision from [determineStudioRoute].
  final StudioRoute gate;

  @override
  String get path => OvidRoutes.studio;

  @override
  Widget buildScreen() => studioScreenFor(gate);
}

/// Activity — a session's event ledger (`/activity/<sessionId>`).
final class ActivityRouteSpec extends OvidRouteSpec {
  const ActivityRouteSpec({required this.sessionId});

  final String sessionId;

  @override
  String get path => OvidRoutes.activitySession(sessionId);

  @override
  Widget buildScreen() => TrajectoryScreen(sessionId: sessionId);
}

/// Background-job schedule (`/schedule/<sessionId>`).
final class ScheduleRouteSpec extends OvidRouteSpec {
  const ScheduleRouteSpec({required this.sessionId});

  final String sessionId;

  @override
  String get path => OvidRoutes.scheduleSession(sessionId);

  @override
  Widget buildScreen() => ScheduleScreen(sessionId: sessionId);
}

/// Library (`/library`) — the agent's saved memory.
final class LibraryRouteSpec extends OvidRouteSpec {
  const LibraryRouteSpec();

  @override
  String get path => OvidRoutes.library;

  @override
  Widget buildScreen() => const MemoryScreen();
}

/// Money (`/money`) — plan & billing.
final class MoneyRouteSpec extends OvidRouteSpec {
  const MoneyRouteSpec();

  @override
  String get path => OvidRoutes.money;

  @override
  Widget buildScreen() => const BillingScreen();
}

/// Money → usage (`/money/usage`).
final class MoneyUsageRouteSpec extends OvidRouteSpec {
  const MoneyUsageRouteSpec();

  @override
  String get path => OvidRoutes.moneyUsage;

  @override
  Widget buildScreen() => const UsageScreen();
}

/// Plugins (`/plugins`, optional `?focus=<canonicalId>`).
final class PluginsRouteSpec extends OvidRouteSpec {
  const PluginsRouteSpec({this.focusCanonicalId});

  /// Plugin to highlight, matching `PluginsScreen.focusCanonicalId`.
  final String? focusCanonicalId;

  @override
  String get path {
    final focus = focusCanonicalId;
    if (focus == null) return OvidRoutes.plugins;
    return '${OvidRoutes.plugins}?focus=${Uri.encodeComponent(focus)}';
  }

  @override
  Widget buildScreen() => PluginsScreen(focusCanonicalId: focusCanonicalId);
}

/// Settings sub-pages, mirroring the rows in `SettingsScreen`.
enum SettingsSubPage {
  providers,
  memory,
  skills,
  backup,
  reset,
  health,
  permissions,
  account,
}

/// Screen a [SettingsSubPage] pushes — the exact targets the settings menu
/// rows use today.
Widget settingsSubScreenFor(SettingsSubPage subPage) => switch (subPage) {
  SettingsSubPage.providers => const ProvidersScreen(),
  SettingsSubPage.memory => const MemoryScreen(),
  SettingsSubPage.skills => const SkillsScreen(),
  SettingsSubPage.backup => const SettingsBackupScreen(),
  SettingsSubPage.reset => const SettingsResetScreen(),
  SettingsSubPage.health => const SettingsHealthScreen(),
  SettingsSubPage.permissions => const PermissionsScreen(),
  SettingsSubPage.account => const AuthScreen(),
};

/// Settings (`/settings`, optional `/settings/<subPage>`).
final class SettingsRouteSpec extends OvidRouteSpec {
  const SettingsRouteSpec([this.subPage]);

  /// `null` is the settings root.
  final SettingsSubPage? subPage;

  @override
  String get path => subPage == null
      ? OvidRoutes.settings
      : '${OvidRoutes.settings}/${subPage!.name}';

  @override
  Widget buildScreen() =>
      subPage == null ? const SettingsScreen() : settingsSubScreenFor(subPage!);
}

/// Browser (`/browser`, optional `?url=<target>`).
final class BrowserRouteSpec extends OvidRouteSpec {
  const BrowserRouteSpec({this.openUrl});

  /// URL the browser navigates to on open, like `BrowserScreen.openUrl`.
  final String? openUrl;

  @override
  String get path {
    final url = openUrl;
    if (url == null) return OvidRoutes.browser;
    return '${OvidRoutes.browser}?url=${Uri.encodeComponent(url)}';
  }

  @override
  Widget buildScreen() => BrowserScreen(openUrl: openUrl);
}

/// Subagent transcript (`/subagent/<sessionId>`).
final class SubagentRouteSpec extends OvidRouteSpec {
  const SubagentRouteSpec({required this.sessionId});

  final String sessionId;

  @override
  String get path => OvidRoutes.subagentSession(sessionId);

  @override
  Widget buildScreen() => SubagentScreen(sessionId: sessionId);
}

// ---------------------------------------------------------------------------
// Deep-link resolution.
// ---------------------------------------------------------------------------

/// Parse a deep-link [rawPath] into a typed [OvidRouteSpec].
///
/// Returns `null` for unknown paths and for parameterized roots without
/// their parameter (`/activity`, `/schedule`, `/subagent` need a session id).
/// Matching is strict (no trailing-slash normalization, case-sensitive).
///
/// `/studio` needs the gate decision: pass [studioGate] from
/// [determineStudioRoute]; when omitted the bare studio is assumed (deep
/// links normally arrive on an installed app).
OvidRouteSpec? resolveOvidRoute(String rawPath, {StudioRoute? studioGate}) {
  if (rawPath.isEmpty) return null;
  final uri = Uri.tryParse(rawPath);
  if (uri == null) return null;

  // Static routes first — a two-segment static path (`/money/usage`,
  // `/settings/<sub>`) must win over the parameterized patterns below.
  switch (uri.path) {
    case OvidRoutes.chat:
      return const ChatRouteSpec();
    case OvidRoutes.studio:
      return StudioRouteSpec(studioGate ?? StudioRoute.studio);
    case OvidRoutes.library:
      return const LibraryRouteSpec();
    case OvidRoutes.money:
      return const MoneyRouteSpec();
    case OvidRoutes.moneyUsage:
      return const MoneyUsageRouteSpec();
    case OvidRoutes.plugins:
      return PluginsRouteSpec(
        focusCanonicalId: uri.queryParameters['focus'],
      );
    case OvidRoutes.browser:
      return BrowserRouteSpec(openUrl: uri.queryParameters['url']);
    case OvidRoutes.settings:
      return const SettingsRouteSpec();
    case OvidRoutes.settingsProviders:
      return const SettingsRouteSpec(SettingsSubPage.providers);
    case OvidRoutes.settingsMemory:
      return const SettingsRouteSpec(SettingsSubPage.memory);
    case OvidRoutes.settingsSkills:
      return const SettingsRouteSpec(SettingsSubPage.skills);
    case OvidRoutes.settingsBackup:
      return const SettingsRouteSpec(SettingsSubPage.backup);
    case OvidRoutes.settingsReset:
      return const SettingsRouteSpec(SettingsSubPage.reset);
    case OvidRoutes.settingsHealth:
      return const SettingsRouteSpec(SettingsSubPage.health);
    case OvidRoutes.settingsPermissions:
      return const SettingsRouteSpec(SettingsSubPage.permissions);
    case OvidRoutes.settingsAccount:
      return const SettingsRouteSpec(SettingsSubPage.account);
  }

  // Parameterized routes: `/subagent/<id>`, `/activity/<id>`,
  // `/schedule/<id>`. `pathSegments` are already percent-decoded.
  final segments = uri.pathSegments;
  if (segments.length != 2 || segments[1].isEmpty) return null;
  final id = segments[1];
  return switch (segments.first) {
    'subagent' => SubagentRouteSpec(sessionId: id),
    'activity' => ActivityRouteSpec(sessionId: id),
    'schedule' => ScheduleRouteSpec(sessionId: id),
    _ => null,
  };
}

// ---------------------------------------------------------------------------
// Push helpers — one per destination. Each pushes the spec's screen on a
// named MaterialPageRoute (the name is the deep-link path, so the route
// stack stays inspectable) and returns the navigation future.
// ---------------------------------------------------------------------------

/// Push [spec]'s screen. The route name is the spec's deep-link path.
Future<T?> pushOvidRoute<T>(BuildContext context, OvidRouteSpec spec) {
  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      builder: (_) => spec.buildScreen(),
      settings: RouteSettings(name: spec.path),
    ),
  );
}

/// Chat root (`/`).
Future<T?> pushChat<T>(BuildContext context) =>
    pushOvidRoute(context, const ChatRouteSpec());

/// Studio — gated. Gather the three inputs from live state
/// (`AppState.studioFirstOpenDone`, `StudioSetupCoordinator.needsAttention`,
/// `SandboxService.checkExisting()`) exactly once per entry, then let
/// [determineStudioRoute] decide.
Future<T?> pushStudio<T>(
  BuildContext context, {
  required bool firstOpenDone,
  required bool needsAttention,
  required bool sandboxInstalled,
}) {
  final gate = determineStudioRoute(
    firstOpenDone: firstOpenDone,
    needsAttention: needsAttention,
    sandboxInstalled: sandboxInstalled,
  );
  return pushOvidRoute(context, StudioRouteSpec(gate));
}

/// Activity — the session's event ledger (`/activity/<sessionId>`).
Future<T?> pushActivity<T>(BuildContext context, {required String sessionId}) =>
    pushOvidRoute(context, ActivityRouteSpec(sessionId: sessionId));

/// Background-job schedule (`/schedule/<sessionId>`).
Future<T?> pushSchedule<T>(BuildContext context, {required String sessionId}) =>
    pushOvidRoute(context, ScheduleRouteSpec(sessionId: sessionId));

/// Library (`/library`).
Future<T?> pushLibrary<T>(BuildContext context) =>
    pushOvidRoute(context, const LibraryRouteSpec());

/// Money — plan & billing (`/money`).
Future<T?> pushMoney<T>(BuildContext context) =>
    pushOvidRoute(context, const MoneyRouteSpec());

/// Money → usage (`/money/usage`).
Future<T?> pushMoneyUsage<T>(BuildContext context) =>
    pushOvidRoute(context, const MoneyUsageRouteSpec());

/// Plugins (`/plugins`), optionally focusing [focusCanonicalId].
Future<T?> pushPlugins<T>(BuildContext context, {String? focusCanonicalId}) =>
    pushOvidRoute(context, PluginsRouteSpec(focusCanonicalId: focusCanonicalId));

/// Settings root, or a [subPage] (`/settings/<subPage>`).
Future<T?> pushSettings<T>(
  BuildContext context, {
  SettingsSubPage? subPage,
}) =>
    pushOvidRoute(context, SettingsRouteSpec(subPage));

/// Browser, optionally navigating to [openUrl].
Future<T?> pushBrowser<T>(BuildContext context, {String? openUrl}) =>
    pushOvidRoute(context, BrowserRouteSpec(openUrl: openUrl));

/// Subagent transcript (`/subagent/<sessionId>`).
Future<T?> pushSubagent<T>(BuildContext context, {required String sessionId}) =>
    pushOvidRoute(context, SubagentRouteSpec(sessionId: sessionId));
