import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/notification_permission.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ovid/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    NotificationPermission.resetForTest();
  });
  tearDown(() {
    NotificationPermission.resetForTest();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'reports allowed on non-Android platforms without a channel call',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return false;
      });

      expect(await NotificationPermission.isEnabled(), isTrue);
      expect(calls, isEmpty);
    },
  );

  test('reads the real Android permission state', () async {
    NotificationPermission.androidOverrideForTest = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'notificationsEnabled');
      return false;
    });

    expect(await NotificationPermission.isEnabled(), isFalse);
  });

  test('reports allowed when Android grants the permission', () async {
    NotificationPermission.androidOverrideForTest = true;
    messenger.setMockMethodCallHandler(channel, (call) async => true);

    expect(await NotificationPermission.isEnabled(), isTrue);
  });

  test('a shell without the handler degrades to allowed', () async {
    NotificationPermission.androidOverrideForTest = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException('no handler');
    });

    // The permission_handler fallback has no plugin in a host test either, so
    // the seam must answer "allowed" rather than blocking the banner.
    expect(await NotificationPermission.isEnabled(), isTrue);
  });

  test('openSettings invokes openNotificationSettings on Android', () async {
    NotificationPermission.androidOverrideForTest = true;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });

    expect(await NotificationPermission.openSettings(), isTrue);
    expect(calls, ['openNotificationSettings']);
  });

  test(
    'openSettings falls back to the existing app-settings handler',
    () async {
      NotificationPermission.androidOverrideForTest = true;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'openNotificationSettings') {
          throw MissingPluginException('not implemented');
        }
        return true;
      });

      expect(await NotificationPermission.openSettings(), isTrue);
      expect(calls, ['openNotificationSettings', 'notifyOpenAppSettings']);
    },
  );

  test('openSettings is a no-op off Android', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });

    expect(await NotificationPermission.openSettings(), isFalse);
    expect(calls, isEmpty);
  });
}
