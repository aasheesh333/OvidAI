import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/permissions_page.dart';

const _permissions = <V2PermissionItem>[
  V2PermissionItem(
    id: 'camera',
    name: 'Camera',
    reason: 'To take a photo you want to send.',
    status: V2PermissionAccess.notAsked,
    icon: Icons.photo_camera_outlined,
  ),
  V2PermissionItem(
    id: 'microphone',
    name: 'Microphone',
    reason: 'To hear your voice messages.',
    status: V2PermissionAccess.granted,
    icon: Icons.mic_none_rounded,
  ),
  V2PermissionItem(
    id: 'photos',
    name: 'Photos',
    reason: 'To attach images from your gallery.',
    status: V2PermissionAccess.blocked,
    icon: Icons.photo_library_outlined,
  ),
  V2PermissionItem(
    id: 'notifications',
    name: 'Notifications',
    reason: 'To tell you when a run finishes.',
    status: V2PermissionAccess.notAsked,
    icon: Icons.notifications_none_rounded,
  ),
  V2PermissionItem(
    id: 'files',
    name: 'Files',
    reason: 'To open a document you choose.',
    status: V2PermissionAccess.granted,
    icon: Icons.folder_outlined,
  ),
];

V2PermissionsPageData _data({
  V2PermissionsStatus status = V2PermissionsStatus.ready,
  List<V2PermissionItem> permissions = _permissions,
  ValueChanged<String>? onRequest,
  VoidCallback? onOpenSettings,
  ValueChanged<String>? onOpenSettingsFor,
  VoidCallback? onRefresh,
  VoidCallback? onRetry,
}) {
  return V2PermissionsPageData(
    status: status,
    permissions: permissions,
    onRequest: onRequest,
    onOpenSettings: onOpenSettings,
    onOpenSettingsFor: onOpenSettingsFor,
    onRefresh: onRefresh,
    onRetry: onRetry,
  );
}

Future<void> _pump(
  WidgetTester tester,
  V2PermissionsPageData data, {
  bool dark = false,
  Size size = const Size(420, 1000),
  double textScale = 1,
  bool reduceMotion = false,
  bool settle = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? OTheme.dark() : OTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
        child: PermissionsPage(data: data),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// Pumps the screen and fails on any framework error (overflow, layout, etc.).
Future<void> _pumpClean(
  WidgetTester tester,
  V2PermissionsPageData data, {
  required bool dark,
}) async {
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  addTearDown(() => FlutterError.onError = previous);

  await _pump(
    tester,
    data,
    dark: dark,
    size: const Size(320, 640),
    textScale: 2,
  );

  FlutterError.onError = previous;
  expect(
    errors,
    isEmpty,
    reason: errors.map((error) => error.toString()).join('\n'),
  );
}

void main() {
  testWidgets('renders five permission rows, each with its status', (
    tester,
  ) async {
    await _pump(tester, _data());

    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Granted'), findsNWidgets(2));
    expect(find.text('Not asked'), findsNWidgets(2));
    expect(find.text('Blocked'), findsOneWidget);
    // The explainer, the per-row reason, the reset control and the footer
    // are gone; the row itself is the one action.
    expect(
      find.text('Ovid only asks when it needs something.'),
      findsNothing,
    );
    expect(find.text('To take a photo you want to send.'), findsNothing);
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Reset all permissions'), findsNothing);
    expect(find.text('Open Android settings'), findsNothing);
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, _data(onRefresh: () {}), dark: true);

    expect(find.text('Photos'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('permissions-refresh')),
      findsOneWidget,
    );
  });

  testWidgets('fits 320dp at 200% text in light without overflow', (
    tester,
  ) async {
    await _pumpClean(
      tester,
      _data(onRequest: (_) {}, onOpenSettings: () {}),
      dark: false,
    );

    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Blocked'), findsOneWidget);
  });

  testWidgets('fits 320dp at 200% text in dark without overflow', (
    tester,
  ) async {
    await _pumpClean(
      tester,
      _data(onRequest: (_) {}, onOpenSettings: () {}, onRefresh: () {}),
      dark: true,
    );

    expect(find.text('Permissions'), findsOneWidget);
    expect(find.byKey(const ValueKey('permissions-refresh')), findsOneWidget);
  });

  testWidgets('shows a loading skeleton', (tester) async {
    await _pump(
      tester,
      _data(status: V2PermissionsStatus.loading),
      settle: false,
    );

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Camera'), findsNothing);
    expect(find.text('No permissions to review'), findsNothing);
  });

  testWidgets('shows the error state and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      _data(status: V2PermissionsStatus.error, onRetry: () => retries++),
    );

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('We could not load your permissions.'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(retries, 1);
  });

  testWidgets('tapping a not-asked row requests the permission', (
    tester,
  ) async {
    String? requested;
    await _pump(tester, _data(onRequest: (id) => requested = id));

    final row = find.byKey(const ValueKey('permission-request-camera'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(requested, 'camera');
  });

  testWidgets('announces a request row with no handler as disabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await _pump(tester, _data());

    final row = tester.getSemantics(
      find.byKey(const ValueKey('permission-request-camera')),
    );
    expect(row, isSemantics(hasEnabledState: true, isEnabled: false));

    handle.dispose();
  });

  testWidgets('refreshes from the header', (tester) async {
    var refreshes = 0;
    await _pump(tester, _data(onRefresh: () => refreshes++));

    final refresh = find.byKey(const ValueKey('permissions-refresh'));
    await tester.tap(refresh);
    await tester.pumpAndSettle();

    expect(refreshes, 1);
  });

  testWidgets('keeps every row at least 48dp tall', (tester) async {
    await _pump(tester, _data(onRequest: (_) {}, onOpenSettings: () {}));

    final rows = find.byType(OListRow).evaluate();
    expect(rows, isNotEmpty);
    for (final element in rows) {
      final box = element.renderObject! as RenderBox;
      expect(box.size.height, greaterThanOrEqualTo(48.0));
    }
  });

  testWidgets('reduced motion still shows all content', (tester) async {
    await _pump(
      tester,
      _data(onRequest: (_) {}, onOpenSettings: () {}),
      reduceMotion: true,
    );

    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Blocked'), findsOneWidget);
    expect(find.text('Not asked'), findsNWidgets(2));
  });

  testWidgets('shows the empty state and opens settings', (tester) async {
    var opens = 0;
    await _pump(
      tester,
      _data(
        status: V2PermissionsStatus.empty,
        permissions: const [],
        onOpenSettings: () => opens++,
      ),
    );

    expect(find.text('No permissions to review'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    expect(opens, 1);
  });

  testWidgets('centres the list at 600 dp', (tester) async {
    await _pump(tester, _data(), size: const Size(600, 1000));

    final row = find.byType(OListRow).first;
    expect(tester.getSize(row).width, lessThanOrEqualTo(640));
    expect(tester.getCenter(row).dx, closeTo(300, 0.5));
  });

  testWidgets('each row opens its own Android settings page', (tester) async {
    String? opened;
    await _pump(tester, _data(onOpenSettingsFor: (id) => opened = id));

    final row = find.byKey(const ValueKey('permission-settings-microphone'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(opened, 'microphone');
  });

  testWidgets('falls back to the app settings page when no per-row target', (
    tester,
  ) async {
    var opens = 0;
    await _pump(tester, _data(onOpenSettings: () => opens++));

    final row = find.byKey(const ValueKey('permission-settings-microphone'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(opens, 1);
  });

  testWidgets('requesting a permission reloads the real state', (tester) async {
    String? requested;
    var refreshes = 0;
    await _pump(
      tester,
      _data(onRequest: (id) => requested = id, onRefresh: () => refreshes++),
    );

    final row = find.byKey(const ValueKey('permission-request-camera'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(requested, 'camera');
    expect(refreshes, 1);
  });

  testWidgets('returning from Android settings reloads the real state', (
    tester,
  ) async {
    var refreshes = 0;
    await _pump(tester, _data(onRefresh: () => refreshes++));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(refreshes, 1);
  });
}
