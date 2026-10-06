import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/auth_identity.dart';
import 'package:ovid_ai/core/auth_providers.dart';
import 'package:ovid_ai/core/firebase_service.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:ovid_ai/core/memory_store.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/settings_actions.dart';
import 'package:ovid_ai/core/state.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

import 'auth_provider_flow_test.dart' show TestAuth, TestUser;

class _Paths extends PathProviderPlatform {
  _Paths(this.directory);
  final Directory directory;

  @override
  Future<String> getApplicationSupportPath() async => directory.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final images = ImageStudio.I;
  late Directory directory;
  late PathProviderPlatform originalPaths;
  late AppState app;
  late TestUser user;
  late TestAuth auth;
  late FirebaseService service;

  setUpAll(() {
    open.overrideFor(
      OperatingSystem.linux,
      () => ffi.DynamicLibrary.open('libsqlite3.so.0'),
    );
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('reset-account-signout-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory);
    SessionSearch.dbPathOverrideForTest = '${directory.path}/search.db';
    app = AppState.createForTest(memoryStore: MemoryStore(directory));
    app.suspendCoalescedPersistenceForTest = true;
    images.bindAccount(null);
    user = TestUser('alice', ['google.com']);
    auth = TestAuth()..currentUser = user;
    service = FirebaseService.forTest(
      initializeApp: () async {},
      configure: () async {},
      identity: AuthIdentity(
        auth: () => auth,
        providers: AuthProviders(),
        googleCredential: () async => null,
      ),
      initialUser: user,
    );
    await service.initialize();
    expect(service.isSignedIn, isTrue);
    expect(app.sessionAccountId, 'firebase:alice');
    expect(images.accountId, 'alice');
  });

  tearDown(() async {
    service.dispose();
    images.bindAccount(null);
    await app.awaitPendingSessionWritesForTest();
    await SessionSearch.I.close();
    SessionSearch.dbPathOverrideForTest = null;
    AppState.resetTestInstance();
    PathProviderPlatform.instance = originalPaths;
    await directory.delete(recursive: true);
  });

  test(
    'signOutLocal clears local account state inside the settings barrier '
    'that signOut would deadlock on',
    () async {
      // AppState is on a firebase account, so a guest transition takes the full
      // handoff path that captures and awaits the in-progress settings barrier.
      expect(app.sessionAccountId, 'firebase:alice');

      final entered = Completer<void>();
      final release = Completer<void>();
      final write = SettingsActions.persist('reset-account-block', true, () async {
        entered.complete();
        await release.future;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('reset-account-block', true);
      });
      await entered.future;

      expect(SettingsActions.resetAll, isNotNull);
      final reset = SettingsActions.resetAll!();
      // The barrier fenced producers and is draining the pending write.
      expect(app.sessionAccountReady, isFalse);

      final generation = images.accountGeneration;
      await service.signOutLocal().timeout(const Duration(seconds: 5));

      expect(service.isSignedIn, isFalse);
      expect(service.user, isNull);
      expect(service.accountError, isNull);
      expect(images.accountId, isNull);
      expect(images.accountGeneration, greaterThan(generation));
      // Purely local: the AppState session owner is untouched by the service.
      expect(app.sessionAccountId, 'firebase:alice');

      release.complete();
      await write;
      await reset;
    },
  );

  test('signOut still hands the AppState session back to guest', () async {
    // Outside the barrier the public sign-out keeps its existing behavior: it
    // awaits the AppState transition before touching the SDK.
    await expectLater(service.signOut(), throwsA(anything));
    expect(app.sessionAccountId, 'guest');
    expect(service.isSignedIn, isFalse);
    expect(images.accountId, isNull);
  });
}
