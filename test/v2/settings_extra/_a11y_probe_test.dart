import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/about_page.dart';
import 'package:ovid_ai/ui/v2/settings_extra/agent_presets_page.dart';
import 'package:ovid_ai/ui/v2/settings_extra/memory_files_page.dart';
import 'package:ovid_ai/ui/v2/settings_extra/notifications_page.dart';
import 'package:ovid_ai/ui/v2/settings_extra/permissions_page.dart';
import 'package:ovid_ai/ui/v2/settings_extra/response_wait_page.dart';

const _permissions = <V2PermissionItem>[
  V2PermissionItem(
    id: 'camera',
    name: 'Camera',
    reason: 'To take a photo you want to send.',
    status: V2PermissionAccess.notAsked,
    icon: Icons.photo_camera_outlined,
  ),
  V2PermissionItem(
    id: 'photos',
    name: 'Photos',
    reason: 'To attach images from your gallery.',
    status: V2PermissionAccess.blocked,
    icon: Icons.photo_library_outlined,
  ),
];

const _presets = <V2AgentPreset>[
  V2AgentPreset(
    id: 'general',
    name: 'General',
    description: 'Balanced help for everyday tasks.',
    modelLabel: 'Ovid Auto',
    builtIn: true,
    icon: Icons.bolt_rounded,
  ),
  V2AgentPreset(
    id: 'reviewer',
    name: 'Code reviewer',
    description: 'Checks changes for bugs and gaps.',
    modelLabel: 'Ovid Pro',
    icon: Icons.rate_review_outlined,
  ),
];

const _files = <V2MemoryFileEntry>[
  V2MemoryFileEntry(
    id: 'g',
    name: 'global.md',
    group: V2MemoryFileGroup.global,
    sizeLabel: '12 KB',
    updatedLabel: '2 hours ago',
    preview: 'Prefers short answers and code samples.',
  ),
];

final _screens = <String, Widget>{
  'about': const AboutPage(data: V2AboutPageData()),
  'notifications': const NotificationsPage(
    data: V2NotificationsPageData(notificationsBlocked: true),
  ),
  'presets': const AgentPresetsPage(
    data: V2AgentPresetsPageData(presets: _presets, selectedId: 'general'),
  ),
  'wait': const ResponseWaitPage(data: V2ResponseWaitPageData(seconds: 120)),
  'permissions': const PermissionsPage(
    data: V2PermissionsPageData(permissions: _permissions),
  ),
  'memory': const MemoryFilesPage(
    data: V2MemoryFilesPageData(files: _files, totalSizeLabel: '12 KB'),
  ),
};

void main() {
  for (final entry in _screens.entries) {
    for (final dark in [false, true]) {
      testWidgets('${entry.key} at 320dp 200% (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final errors = <FlutterErrorDetails>[];
        final previous = FlutterError.onError;
        FlutterError.onError = errors.add;
        addTearDown(() => FlutterError.onError = previous);

        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? OTheme.dark() : OTheme.light(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: entry.value,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        FlutterError.onError = previous;
        for (final error in errors) {
          debugPrint(error.toString());
        }
        expect(errors, isEmpty);
      });
    }
  }
}
