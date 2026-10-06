import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/session_browser_profiles.dart';

/// The verified all-store reset must be able to READ BACK that the per-session
/// browser profiles are gone. A store that only deletes without proving
/// emptiness can report a false success, and a readback that reads a dead
/// provider as "empty" is worse than none at all. These tests pin the two APIs
/// the reset uses — `profileCount()`/`isEmpty()` (readback) and `deleteAll()`
/// (full clear) — and prove the readback cannot lie when the provider is down.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ovid/webview');
  late List<String> provider;

  void mock(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  /// Simulate a session having browsed: the WebView provider now holds a jar.
  void createProfile(String name) => provider.add(name);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    provider = <String>[];
    mock((call) async {
      switch (call.method) {
        case 'profilesSupported':
          return true;
        case 'listProfiles':
          return List<String>.of(provider);
        case 'deleteProfile':
          provider.remove(call.arguments['profileName']);
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a full clear removes every profile and reads back empty', () async {
    await SessionBrowserProfiles.I.probe(refresh: true);
    createProfile('ovid_s_s1');
    createProfile('ovid_s_s2');

    expect(await SessionBrowserProfiles.I.profileCount(), 2);
    expect(await SessionBrowserProfiles.I.isEmpty(), isFalse);

    await SessionBrowserProfiles.I.deleteAll();

    expect(provider, isEmpty);
    expect(await SessionBrowserProfiles.I.profileCount(), 0);
    expect(await SessionBrowserProfiles.I.isEmpty(), isTrue);
  });

  test('deleteAll also drops every session\'s remembered origins', () async {
    await SessionBrowserProfiles.I.probe(refresh: true);
    createProfile('ovid_s_s1');
    await SessionBrowserProfiles.I.rememberOrigin(
      'https://github.com',
      sessionId: 's1',
    );
    expect(await SessionBrowserProfiles.I.allRememberedOrigins(), isNotEmpty);

    await SessionBrowserProfiles.I.deleteAll();

    expect(await SessionBrowserProfiles.I.allRememberedOrigins(), isEmpty);
  });

  test('the readback throws when the provider is down instead of lying empty',
      () async {
    mock((call) async {
      if (call.method == 'profilesSupported') return true;
      throw PlatformException(code: 'down', message: 'provider died');
    });
    await SessionBrowserProfiles.I.probe(refresh: true);

    await expectLater(
      SessionBrowserProfiles.I.profileCount(),
      throwsA(isA<PlatformException>()),
    );
  });

  test('an unsupported provider truthfully has nothing to clear', () async {
    mock((call) async {
      if (call.method == 'profilesSupported') return false;
      return null;
    });
    await SessionBrowserProfiles.I.probe(refresh: true);

    expect(await SessionBrowserProfiles.I.profileCount(), 0);
    expect(await SessionBrowserProfiles.I.isEmpty(), isTrue);
    await SessionBrowserProfiles.I.deleteAll();
    expect(await SessionBrowserProfiles.I.isEmpty(), isTrue);
  });
}
