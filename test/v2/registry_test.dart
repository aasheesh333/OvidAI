import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/v2/v2_preview_data.dart';
import 'package:ovid_ai/ui/v2/v2_registry.dart';

void main() {
  test('every screen id is unique', () {
    final ids = v2Screens.map((s) => s.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('the gallery covers every approved area', () {
    expect(v2Screens.length, greaterThanOrEqualTo(50));
    final groups = v2Screens.map((s) => s.group).toSet();
    expect(
      groups,
      containsAll(<String>[
        'Identity',
        'Chat',
        'Navigation',
        'Work',
        'Connectors',
        'Library',
        'Schedules',
        'Sharing',
        'Runs',
        'Settings',
      ]),
    );
  });

  test('every entry has a title and a summary', () {
    for (final entry in v2Screens) {
      expect(entry.title.trim(), isNotEmpty, reason: entry.id);
      expect(entry.summary.trim(), isNotEmpty, reason: entry.id);
    }
  });

  test('sheet bodies are flagged so the harness can host them', () {
    final sheets = v2Screens.where((s) => s.isSheet).map((s) => s.id).toSet();
    expect(
      sheets,
      containsAll(<String>[
        'model_picker',
        'model_chip',
        'session_actions',
        'branch_picker',
        'take_control',
        'share_sheet',
        'share_chat',
      ]),
    );
  });

  test('settings previews carry content state, not loading shells', () {
    expect(previewResponseWaitData().seconds, isNotNull);
    expect(previewRunTrajectoryData().steps, isNotEmpty);
    expect(previewProjectsData().projects, isNotEmpty);
    expect(previewNotificationsData().activity, isNotEmpty);
    expect(previewPresetsData().presets, isNotEmpty);
  });

  test('permission preview lists only the manifest permissions', () {
    final ids = previewPermissionsData().permissions
        .map((permission) => permission.id)
        .toList();

    expect(ids, <String>['microphone', 'notifications']);
  });
}
