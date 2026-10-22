import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/settings_extra/permissions_page.dart';

/// One row per state the platform can report.
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
    status: V2PermissionAccess.permanentlyDenied,
    icon: Icons.photo_library_outlined,
  ),
  V2PermissionItem(
    id: 'notifications',
    name: 'Notifications',
    reason: 'To tell you when a run finishes.',
    status: V2PermissionAccess.denied,
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
  String errorMessage = 'We could not load your permissions.',
}) {
  return V2PermissionsPageData(
    status: status,
    permissions: permissions,
    onRequest: onRequest,
    onOpenSettings: onOpenSettings,
    onOpenSettingsFor: onOpenSettingsFor,
    onRefresh: onRefresh,
    onRetry: onRetry,
    errorMessage: errorMessage,
  );
}

/// A page with every action wired, so no row is inert by accident.
V2PermissionsPageData _wired({
  ValueChanged<String>? onRequest,
  ValueChanged<String>? onOpenSettingsFor,
  VoidCallback? onRefresh,
}) {
  return _data(
    onRequest: onRequest ?? (_) {},
    onOpenSettings: () {},
    onOpenSettingsFor: onOpenSettingsFor ?? (_) {},
    onRefresh: onRefresh ?? () {},
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
  Size size = const Size(320, 640),
  double textScale = 2,
}) async {
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  addTearDown(() => FlutterError.onError = previous);

  await _pump(tester, data, dark: dark, size: size, textScale: textScale);

  FlutterError.onError = previous;
  expect(
    errors,
    isEmpty,
    reason: errors.map((error) => error.toString()).join('\n'),
  );
}

void main() {
  testWidgets('shows one row per permission with its real state', (
    tester,
  ) async {
    await _pump(tester, _wired());

    expect(find.text('Permissions'), findsOneWidget);
    for (final name in const [
      'Camera',
      'Microphone',
      'Photos',
      'Notifications',
      'Files',
    ]) {
      expect(find.text(name), findsOneWidget);
    }

    // Four distinct states, each labelled in plain words.
    expect(find.text('Granted'), findsNWidgets(2));
    expect(find.text('Not asked'), findsOneWidget);
    expect(find.text('Denied'), findsOneWidget);
    expect(find.text('Blocked'), findsOneWidget);
  });

  testWidgets('the row is name plus state only — no reason, no subtitle', (
    tester,
  ) async {
    await _pump(tester, _wired());

    expect(find.text('To take a photo you want to send.'), findsNothing);
    expect(find.text('To hear your voice messages.'), findsNothing);
    expect(find.text('Allow'), findsNothing);
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Reset all permissions'), findsNothing);
    expect(find.text('Open Android settings'), findsNothing);
    // One line per row: no subtitle widget is built at all.
    expect(find.byType(OListRow), findsNWidgets(5));
    for (final row in tester.widgetList<OListRow>(find.byType(OListRow))) {
      expect(row.subtitle, isNull);
    }
  });

  testWidgets('a not-asked row requests that permission', (tester) async {
    String? requested;
    await _pump(tester, _wired(onRequest: (id) => requested = id));

    final row = find.byKey(const ValueKey('permission-request-camera'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(requested, 'camera');
  });

  testWidgets('a denied row can ask again', (tester) async {
    String? requested;
    await _pump(tester, _wired(onRequest: (id) => requested = id));

    final row = find.byKey(const ValueKey('permission-request-notifications'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(requested, 'notifications');
  });

  testWidgets('a blocked row opens its own OS settings page', (tester) async {
    String? opened;
    await _pump(tester, _wired(onOpenSettingsFor: (id) => opened = id));

    final row = find.byKey(const ValueKey('permission-settings-photos'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(opened, 'photos');
  });

  testWidgets('a blocked row falls back to the app settings page', (
    tester,
  ) async {
    var opens = 0;
    await _pump(
      tester,
      _data(onRequest: (_) {}, onOpenSettings: () => opens++),
    );

    final row = find.byKey(const ValueKey('permission-settings-photos'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(opens, 1);
  });

  testWidgets('a granted row has no action and no settings shortcut', (
    tester,
  ) async {
    String? requested;
    var opens = 0;
    await _pump(
      tester,
      _wired(onRequest: (id) => requested = id, onOpenSettingsFor: (_) => opens++),
    );

    final row = find.byKey(const ValueKey('permission-status-microphone'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(requested, isNull);
    expect(opens, 0);
  });

  testWidgets('a row with no handler is information, not a disabled button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _data());

    for (final key in const [
      'permission-request-camera',
      'permission-settings-photos',
    ]) {
      final node = tester.getSemantics(find.byKey(ValueKey(key)));
      expect(node, isSemantics(hasTapAction: false, hasEnabledState: false));
    }

    handle.dispose();
  });

  testWidgets('each row announces the permission, its state and its action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _wired());

    expect(
      tester.getSemantics(
        find.byKey(const ValueKey('permission-request-camera')),
      ),
      isSemantics(
        label: 'Camera, not asked',
        hint: 'Requests camera access',
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey('permission-request-notifications')),
      ),
      isSemantics(
        label: 'Notifications, denied',
        hint: 'Requests notifications access',
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey('permission-settings-photos')),
      ),
      isSemantics(
        label: 'Photos, blocked in system settings',
        hint: 'Opens app settings to allow access',
        hasTapAction: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey('permission-status-microphone')),
      ),
      isSemantics(label: 'Microphone, granted'),
    );

    handle.dispose();
  });

  testWidgets('the refresh action is labelled with what it does', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _wired());

    // The label lives on the icon button's own node; the tap action is on the
    // IconButton beneath it, and "refreshes from the header" proves it fires.
    expect(
      tester.getSemantics(find.byKey(const ValueKey('permissions-refresh'))),
      isSemantics(
        label: 'Refresh status',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );

    handle.dispose();
  });

  testWidgets('returning from OS settings re-reads the real state', (
    tester,
  ) async {
    var refreshes = 0;
    await _pump(tester, _wired(onRefresh: () => refreshes++));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(refreshes, 1);
  });

  testWidgets('requesting a permission reloads the real state', (tester) async {
    String? requested;
    var refreshes = 0;
    await _pump(
      tester,
      _wired(onRequest: (id) => requested = id, onRefresh: () => refreshes++),
    );

    final row = find.byKey(const ValueKey('permission-request-camera'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(requested, 'camera');
    expect(refreshes, 1);
  });

  testWidgets('refreshes from the header', (tester) async {
    var refreshes = 0;
    await _pump(tester, _wired(onRefresh: () => refreshes++));

    final refresh = find.byKey(const ValueKey('permissions-refresh'));
    await tester.tap(refresh);
    await tester.pumpAndSettle();

    expect(refreshes, 1);
  });

  testWidgets('shows a loading skeleton', (tester) async {
    await _pump(
      tester,
      _data(status: V2PermissionsStatus.loading),
      settle: false,
    );

    expect(find.byType(OSkeletonList), findsOneWidget);
    expect(find.text('Camera'), findsNothing);
    expect(find.text('No permissions found'), findsNothing);
  });

  testWidgets('shows the error state and retries', (tester) async {
    var retries = 0;
    await _pump(
      tester,
      _data(status: V2PermissionsStatus.error, onRetry: () => retries++),
    );

    expect(find.text('That did not work'), findsOneWidget);
    expect(find.text('We could not load your permissions.'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(retries, 1);
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

    expect(find.text('No permissions found'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    expect(opens, 1);
  });

  testWidgets('a ready page with no rows is the empty state', (tester) async {
    await _pump(tester, _data(permissions: const []));

    expect(find.text('No permissions found'), findsOneWidget);
    expect(find.byType(OListRow), findsNothing);
  });

  testWidgets('reduced motion still shows all content', (tester) async {
    await _pump(tester, _wired(), reduceMotion: true);

    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Blocked'), findsOneWidget);
    expect(find.text('Denied'), findsOneWidget);
    expect(find.text('Not asked'), findsOneWidget);
  });

  testWidgets('keeps every row at least 48dp tall', (tester) async {
    await _pump(tester, _wired());

    final rows = find.byType(OListRow).evaluate();
    expect(rows, isNotEmpty);
    for (final element in rows) {
      final box = element.renderObject! as RenderBox;
      expect(box.size.height, greaterThanOrEqualTo(48.0));
    }
  });

  testWidgets('every width and text scale, light and dark, lays out clean', (
    tester,
  ) async {
    for (final width in const [320.0, 360.0, 412.0, 600.0, 800.0, 1024.0, 1280.0]) {
      for (final scale in const [1.0, 2.0]) {
        for (final dark in const [false, true]) {
          await _pumpClean(
            tester,
            _wired(),
            dark: dark,
            size: Size(width, 900),
            textScale: scale,
          );
        }
      }
    }
  });

  testWidgets('caps the column at 640 dp and centres it', (tester) async {
    for (final width in const [600.0, 800.0, 1024.0, 1280.0]) {
      await _pump(tester, _wired(), size: Size(width, 900));

      final row = find.byType(OListRow).first;
      expect(
        tester.getSize(row).width,
        lessThanOrEqualTo(640),
        reason: 'at $width dp',
      );
      expect(
        tester.getCenter(row).dx,
        closeTo(width / 2, 0.5),
        reason: 'at $width dp the list is centred',
      );
    }
  });

  testWidgets('fits 320dp at 200% text in light and dark', (tester) async {
    await _pumpClean(tester, _wired(), dark: false);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Blocked'), findsOneWidget);

    await _pumpClean(tester, _wired(), dark: true);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.byKey(const ValueKey('permissions-refresh')), findsOneWidget);
  });

  test('the legacy blocked name still means permanently denied', () {
    expect(V2PermissionAccess.blocked, V2PermissionAccess.permanentlyDenied);
  });
}
