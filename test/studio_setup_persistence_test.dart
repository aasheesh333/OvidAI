import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_setup_coordinator.dart';

const _key = 'studio_first_open_done';
const _nativeKey = 'flutter.$_key';

/// Models Android's native-memory mutation before commit, separately from disk.
class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.withData({_nativeKey: true});

  final durable = <String, Object>{_nativeKey: true};
  Future<bool> Function(bool)? write;
  bool mutateBeforeResult = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == _nativeKey) {
      if (mutateBeforeResult) await super.setValue(valueType, key, value);
      if (write != null && !await write!(value as bool)) return false;
    }
    await super.setValue(valueType, key, value);
    durable
      ..clear()
      ..addAll(await getAll());
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Preferences backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    backend = _Preferences();
    SharedPreferencesStorePlatform.instance = backend;
    AppState.resetTestInstance();
    AppState.createForTest();
    await AppState.I.loadStudioFirstOpenFlag();
    expect(AppState.I.studioFirstOpenDone, isTrue);
  });

  tearDown(() {
    AppState.resetTestInstance();
    SharedPreferences.setMockInitialValues({});
  });

  for (final throwsError in [false, true]) {
    for (final mutate in [false, true]) {
      test(
        'invalidation ${throwsError ? 'exception' : 'false'} (native mutation $mutate) blocks install and permits retry',
        () async {
          backend.mutateBeforeResult = mutate;
          backend.write = (_) async {
            if (throwsError) throw StateError('disk unavailable');
            return false;
          };
          var installs = 0;
          final coordinator = StudioSetupCoordinator(
            checkExisting: () async => false,
            install: (_, _) async {
              installs++;
            },
            verifyCore: () async => true,
            verifyRuntimes: () async => true,
          );
          addTearDown(coordinator.dispose);
          await coordinator.start();
          expect(installs, 0);
          expect(coordinator.status, StudioSetupStatus.failed);
          expect(coordinator.needsAttention, isTrue);
          expect(coordinator.error, contains('save'));
          expect(AppState.I.studioFirstOpenDone, isTrue);
          expect(backend.durable[_nativeKey], isTrue);
          // Failed native/cache mutation is not confirmation, even after reload.
          final prefs = await SharedPreferences.getInstance();
          await prefs.reload();
          expect(prefs.getBool(_key), isTrue);

          backend.write = null;
          await coordinator.retryFromRuntimeBanner();
          expect(installs, 1);
          expect(coordinator.status, StudioSetupStatus.ready);
          expect(AppState.I.studioFirstOpenDone, isTrue);
          expect(backend.durable[_nativeKey], isTrue);
        },
      );
    }

    test(
      'completion save ${throwsError ? 'exception' : 'false'} stays retryable despite native mutation',
      () async {
        backend.mutateBeforeResult = true;
        backend.write = (value) async {
          if (!value) return true;
          if (throwsError) throw StateError('disk unavailable');
          return false;
        };
        var coreExists = false;
        var installs = 0;
        final coordinator = StudioSetupCoordinator(
          checkExisting: () async => coreExists,
          install: (_, _) async {
            installs++;
            coreExists = true;
          },
          installRuntimes: (_) async =>
              fail('verified runtimes need no repair'),
          verifyCore: () async => true,
          verifyRuntimes: () async => true,
        );
        addTearDown(coordinator.dispose);
        await coordinator.start();
        expect(installs, 1);
        expect(coordinator.status, StudioSetupStatus.failed);
        expect(coordinator.coreReady, isTrue);
        expect(coordinator.error, contains('save'));
        expect(AppState.I.studioFirstOpenDone, isFalse);
        expect(AppState.I.runtimeInstallState, RuntimeInstallState.failed);
        expect(backend.durable[_nativeKey], isFalse);
        backend.write = null;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('unrelated', true);
        await prefs.reload();
        expect(prefs.getBool(_key), isFalse);
        expect(backend.durable[_nativeKey], isFalse);
        AppState.resetTestInstance();
        AppState.createForTest();
        await AppState.I.loadStudioFirstOpenFlag();
        expect(AppState.I.studioFirstOpenDone, isFalse);

        await coordinator.retryFromRuntimeBanner();
        expect(installs, 1);
        expect(coordinator.status, StudioSetupStatus.ready);
        expect(AppState.I.studioFirstOpenDone, isTrue);
        expect(backend.durable[_nativeKey], isTrue);
      },
    );
  }

  test(
    'pending writes do not update app memory or start work before confirmation',
    () async {
      final invalidate = Completer<bool>();
      final complete = Completer<bool>();
      backend.mutateBeforeResult = true;
      backend.write = (value) => value ? complete.future : invalidate.future;
      var installs = 0;
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => false,
        install: (_, _) async {
          installs++;
        },
        verifyCore: () async => true,
        verifyRuntimes: () async => true,
      );
      addTearDown(coordinator.dispose);
      final job = coordinator.start();
      await Future<void>.delayed(Duration.zero);
      expect(installs, 0);
      expect(AppState.I.studioFirstOpenDone, isTrue);
      invalidate.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(installs, 1);
      expect(AppState.I.studioFirstOpenDone, isFalse);
      expect(coordinator.status, StudioSetupStatus.running);
      complete.complete(true);
      await job;
      expect(AppState.I.studioFirstOpenDone, isTrue);
      expect(coordinator.status, StudioSetupStatus.ready);
    },
  );
}
