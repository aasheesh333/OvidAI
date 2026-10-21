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
  VoidCallback? onRetry,
}) {
  return V2PermissionsPageData(
    status: status,
    permissions: permissions,
    onRequest: onRequest,
    onOpenSettings: onOpenSettings,
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
  testWidgets('renders every permission with a status in light', (
    tester,
  ) async {
    await _pump(tester, _data());

    expect(find.text('Permissions'), findsOneWidget);
    expect(
      find.text('Ovid only asks when it needs something.'),
      findsOneWidget,
    );
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Granted'), findsNWidgets(2));
    expect(find.text('Not asked'), findsNWidgets(2));
    expect(find.text('Blocked'), findsOneWidget);
  });

  testWidgets('renders in dark', (tester) async {
    await _pump(tester, _data(), dark: true);

    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Open Android settings'), findsOneWidget);
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
      _data(onRequest: (_) {}, onOpenSettings: () {}),
      dark: true,
    );

    expect(find.text('Permissions'), findsOneWidget);
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

  testWidgets('requests a permission', (tester) async {
    String? requested;
    await _pump(tester, _data(onRequest: (id) => requested = id));

    final request = find.text('Request').first;
    await tester.ensureVisible(request);
    await tester.tap(request);
    await tester.pumpAndSettle();

    expect(requested, 'camera');
  });

  testWidgets('announces a disabled request button', (tester) async {
    final handle = tester.ensureSemantics();

    await _pump(tester, _data());

    final request = tester.getSemantics(find.text('Request').first);
    expect(request, isSemantics(isButton: true, isEnabled: false));

    handle.dispose();
  });

  testWidgets('names the permission in each row action label', (tester) async {
    await _pump(tester, _data(onRequest: (_) {}, onOpenSettings: () {}));

    final buttons = tester.widgetList<OButton>(find.byType(OButton)).toList();
    final request = buttons.firstWhere((button) => button.label == 'Request');
    expect(request.semanticLabel, 'Request Camera access');

    final settings = buttons.firstWhere(
      (button) => button.label == 'Open settings',
    );
    expect(settings.semanticLabel, 'Open settings for Microphone');
  });

  testWidgets('opens Android settings from the footer', (tester) async {
    var opens = 0;
    await _pump(tester, _data(onOpenSettings: () => opens++));

    final button = find.text('Open Android settings');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(opens, 1);
  });

  testWidgets('keeps every button at least 48dp tall', (tester) async {
    await _pump(tester, _data(onRequest: (_) {}, onOpenSettings: () {}));

    final buttons = find
        .byWidgetPredicate((widget) => widget is ButtonStyleButton)
        .evaluate();
    expect(buttons, isNotEmpty);
    for (final element in buttons) {
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

    expect(
      find.text('Ovid only asks when it needs something.'),
      findsOneWidget,
    );
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Blocked'), findsOneWidget);
    expect(find.text('Open Android settings'), findsOneWidget);
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
    await tester.tap(find.text('Open Android settings'));
    await tester.pumpAndSettle();

    expect(opens, 1);
  });
}
