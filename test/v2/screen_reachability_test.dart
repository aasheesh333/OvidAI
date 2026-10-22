// Every screen the design sheet shows must be a screen the app can reach.
//
// This test exists because two screens slipped through: the gallery registry
// (which the Figma sheet mirrors) is a separate list from the app's real
// navigation, so a screen could pass every design audit — contrast, responsive,
// semantics, no-dead-controls, all of which iterate the registry — and still be
// impossible for a user to open.
//
// The map below is the contract: registry id → the widget that must be reachable
// from `lib/ui/v2/app/` (directly, or through a screen that the app layer opens).
// Adding a screen to the registry without wiring it fails here.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One row per registry screen: the id, and the widget file that must be
/// reachable from the real navigation layer.
///
/// `reachableVia` names the app-layer file that imports it, or `null` when the
/// screen is opened by another screen rather than a route.
const Map<String, ({String file, String? via})> _screens = {
  'splash': (file: 'onboarding/splash_page.dart', via: 'v2_onboarding_gate.dart'),
  'sign_in': (file: 'onboarding/sign_in_page.dart', via: 'v2_onboarding_gate.dart'),
  'welcome': (file: 'onboarding/onboarding_welcome.dart', via: 'v2_onboarding_gate.dart'),
  'language_goal': (file: 'onboarding/language_goal_page.dart', via: 'v2_onboarding_gate.dart'),
  'paywall': (file: 'onboarding/paywall_page.dart', via: 'v2_onboarding_gate.dart'),
  'chat': (file: 'chat/chat_page.dart', via: 'v2_app_shell.dart'),
  'live_chat': (file: 'chat/live_chat_page.dart', via: 'v2_app_shell.dart'),
  'model_picker': (file: 'chat/model_picker_sheet.dart', via: 'v2_app_shell.dart'),
  // The chip popover is the top bar's quick switch; the shell opens it.
  'model_chip': (file: 'chat/model_chip_menu.dart', via: 'v2_app_shell.dart'),
  // System states is a settings destination, not a gallery-only illustration.
  'system_states': (file: 'states/system_states_page.dart', via: 'v2_settings_routes.dart'),
  'sidebar': (file: 'sidebar/sidebar.dart', via: 'v2_app_shell.dart'),
  'projects': (file: 'sidebar/projects_page.dart', via: 'v2_app_shell.dart'),
  'session_actions': (file: 'sidebar/session_actions_sheet.dart', via: 'v2_app_shell.dart'),
  'repo_picker': (file: 'studio/repo_picker_page.dart', via: 'v2_studio_routes.dart'),
  'studio_workspace': (file: 'studio/studio_workspace_page.dart', via: 'v2_studio_routes.dart'),
  'branch_picker': (file: 'studio/branch_picker_sheet.dart', via: 'v2_studio_routes.dart'),
  'changes': (file: 'studio/changes_page.dart', via: 'v2_studio_routes.dart'),
  'live_preview': (file: 'studio/live_preview_page.dart', via: 'v2_studio_routes.dart'),
  // The shipped browser is the live one; the static `browser_page.dart` is a
  // gallery illustration and must not be what the app mounts.
  'browser': (file: 'browser/browser_live_page.dart', via: 'v2_work_routes.dart'),
  'take_control': (file: 'browser/take_control_sheet.dart', via: null),
  'connectors': (file: 'connectors/connectors_page.dart', via: 'v2_work_routes.dart'),
  'connector_detail': (file: 'connectors/connector_detail_page.dart', via: null),
  'add_connector': (file: 'connectors/add_connector_page.dart', via: null),
  'artifacts': (file: 'library/artifacts_page.dart', via: 'v2_work_routes.dart'),
  'artifact_detail': (file: 'library/artifact_detail_page.dart', via: 'v2_work_routes.dart'),
  'schedules': (file: 'schedules/schedules_flow.dart', via: 'v2_work_routes.dart'),
  'schedule_editor': (file: 'schedules/schedules_flow.dart', via: 'v2_work_routes.dart'),
  'schedule_runs': (file: 'schedules/schedules_flow.dart', via: 'v2_work_routes.dart'),
  'share_chat': (file: 'share/share_chat_sheet.dart', via: 'v2_app_shell.dart'),
  'collab_live': (file: 'collab/collab_live_page.dart', via: 'v2_collab_routes.dart'),
  'collab_members': (file: 'collab/collab_members_page.dart', via: 'v2_collab_routes.dart'),
  'trajectory': (file: 'runs/run_trajectory_page.dart', via: 'v2_run_routes.dart'),
  'subagent': (file: 'runs/subagent_page.dart', via: 'v2_run_routes.dart'),
  'settings': (file: 'settings/settings_hub.dart', via: 'v2_app_shell.dart'),
  'account': (file: 'settings/account_page.dart', via: 'v2_settings_routes.dart'),
  'plan_billing': (file: 'settings/plan_billing_page.dart', via: 'v2_settings_routes.dart'),
  'usage': (file: 'settings/usage_page.dart', via: 'v2_settings_routes.dart'),
  'memory': (file: 'settings/memory_page.dart', via: 'v2_settings_routes.dart'),
  'data_control': (file: 'settings/data_control_page.dart', via: 'v2_settings_routes.dart'),
  'storage': (file: 'settings/storage_page.dart', via: 'v2_settings_routes.dart'),
  'appearance': (file: 'settings/appearance_page.dart', via: 'v2_settings_routes.dart'),
  'credentials': (file: 'settings/credentials_page.dart', via: 'v2_settings_routes.dart'),
  'account_health': (file: 'settings/account_health_page.dart', via: 'v2_settings_routes.dart'),
  'about': (file: 'settings_extra/about_page.dart', via: 'v2_settings_routes.dart'),
  'notifications': (file: 'settings_extra/notifications_page.dart', via: 'v2_settings_routes.dart'),
  'presets': (file: 'settings_extra/agent_presets_page.dart', via: 'v2_settings_routes.dart'),
  'response_wait': (file: 'settings_extra/response_wait_page.dart', via: 'v2_settings_routes.dart'),
  'permissions': (file: 'settings_extra/permissions_page.dart', via: 'v2_settings_routes.dart'),
  'memory_files': (file: 'settings_extra/memory_files_page.dart', via: 'v2_settings_routes.dart'),
};

/// App-layer files that own navigation.
const _appLayerFiles = <String>[
  'v2_app_shell.dart',
  'v2_onboarding_gate.dart',
  'v2_settings_routes.dart',
  'v2_studio_routes.dart',
  'v2_work_routes.dart',
  'v2_run_routes.dart',
  'v2_collab_routes.dart',
];

String _read(String path) => File(path).readAsStringSync();

Set<String> _importsOf(String path) {
  final imports = <String>{};
  for (final match in RegExp(r"""import '([^']+)'""").allMatches(_read(path))) {
    final target = match.group(1)!.split('/').last;
    imports.add(target);
  }
  return imports;
}

void main() {
  test('the registry has exactly the screens this contract knows about', () {
    final source = _read('lib/ui/v2/v2_registry.dart');
    // Only ids on a `V2ScreenEntry`, not `id:` fields inside preview data.
    final ids = RegExp(r"V2ScreenEntry\(([\s\S]*?)\n  \),")
        .allMatches(source)
        .map((block) => RegExp(r"id: '([^']+)'").firstMatch(block.group(1)!))
        .whereType<RegExpMatch>()
        .map((match) => match.group(1)!)
        .toSet();

    // The floor guards against the regex silently matching nothing. It is the
    // current count, so adding a screen is fine and losing entries fails.
    expect(ids.length, equals(_screens.length));
    expect(ids.length, greaterThanOrEqualTo(49));
    expect(
      ids,
      equals(_screens.keys.toSet()),
      reason:
          'A screen was added to or removed from the registry without updating '
          'the reachability contract in this test.',
    );
  });

  test('every registry screen is reachable from the real app layer', () {
    final appImports = <String>{};
    for (final file in _appLayerFiles) {
      appImports.addAll(_importsOf('lib/ui/v2/app/$file'));
    }

    final unreachable = <String>[];
    for (final entry in _screens.entries) {
      final file = entry.value.file.split('/').last;
      final via = entry.value.via;

      final fileExists = File('lib/ui/v2/${entry.value.file}').existsSync();
      if (!fileExists) {
        unreachable.add('${entry.key}: ${entry.value.file} does not exist');
        continue;
      }

      if (via != null) {
        // A named app-layer owner must import it.
        if (!appImports.contains(file)) {
          unreachable.add(
            '${entry.key}: ${entry.value.file} is not imported by $via',
          );
        }
        continue;
      }

      // No route owns it directly, so some screen that IS reachable must open
      // it. Check every screen file that the app layer imports.
      final reachableFiles = appImports.where((name) => name.endsWith('.dart'));
      var opened = false;
      for (final owner in reachableFiles) {
        final matches = Directory('lib/ui/v2')
            .listSync(recursive: true)
            .whereType<File>()
            .where((candidate) => candidate.path.endsWith('/$owner'));
        for (final candidate in matches) {
          if (_read(candidate.path).contains(file)) {
            opened = true;
            break;
          }
        }
        if (opened) break;
      }
      if (!opened) {
        unreachable.add(
          '${entry.key}: ${entry.value.file} is not opened by any screen the '
          'app layer imports',
        );
      }
    }

    expect(unreachable, isEmpty, reason: unreachable.join('\n'));
  });

  test('the gallery composes the shipped browser body, not a mock', () {
    // `BrowserPage` is the presentational body; `BrowserLivePage` composes it
    // and owns the stream. The gallery builds `BrowserPage` with preview data,
    // which is only honest while the shipped screen renders the same widget.
    // If the live page ever stops composing it, the gallery is showing a mock
    // of a screen that no longer exists.
    final live = _read('lib/ui/v2/browser/browser_live_page.dart');
    expect(
      live.contains('BrowserPage('),
      isTrue,
      reason:
          'BrowserLivePage no longer composes BrowserPage, so the gallery entry '
          'for `browser` now shows a widget the app does not mount.',
    );

    // And the app layer must mount the live one.
    final appImports = <String>{};
    for (final file in _appLayerFiles) {
      appImports.addAll(_importsOf('lib/ui/v2/app/$file'));
    }
    expect(appImports.contains('browser_live_page.dart'), isTrue);
  });
}
