import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_setup_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
  });
  tearDown(() {
    SandboxService.execCheckedOverrideForTest = null;
    AppState.resetTestInstance();
  });

  test(
    'concurrent approval joins one job through completion bookkeeping',
    () async {
      final barrier = Completer<void>();
      var installs = 0;
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => false,
        install: (onPhase, includeRuntimes) async {
          expect(includeRuntimes, isTrue);
          installs++;
          onPhase(7, .4, 'Downloading runtimes');
          await barrier.future;
        },
        verifyCore: () async => true,
        verifyRuntimes: () async => true,
      );
      addTearDown(coordinator.dispose);

      final first = coordinator.start();
      final second = coordinator.start();
      expect(identical(first, second), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(installs, 1);
      expect(coordinator.status, StudioSetupStatus.running);
      expect(coordinator.log, contains('Downloading runtimes'));
      expect(AppState.I.studioFirstOpenDone, isFalse);

      barrier.complete();
      await first;
      expect(coordinator.status, StudioSetupStatus.ready);
      expect(AppState.I.sandboxInstalled, isTrue);
      expect(AppState.I.runtimeInstallState, RuntimeInstallState.done);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'studio_first_open_done',
        ),
        isTrue,
      );
    },
  );

  test(
    'existing core without first-open flag repairs runtimes without replacing prefix',
    () async {
      var verified = false;
      var repairs = 0;
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => true,
        install: (_, _) async => fail('must preserve existing core'),
        installRuntimes: (onPhase) async {
          repairs++;
          verified = true;
          return true;
        },
        verifyCore: () async => true,
        verifyRuntimes: () async => verified,
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      expect(repairs, 1);
      expect(coordinator.status, StudioSetupStatus.ready);
      expect(AppState.I.studioFirstOpenDone, isTrue);
    },
  );

  test(
    'existing complete toolchain only verifies and records first-open',
    () async {
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => true,
        install: (_, _) async => fail('must not reinstall'),
        installRuntimes: (_) async => fail('must not download'),
        verifyCore: () async => true,
        verifyRuntimes: () async => true,
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      expect(coordinator.status, StudioSetupStatus.ready);
      expect(AppState.I.studioFirstOpenDone, isTrue);
    },
  );

  test(
    'normal installer return with missing runtimes is partial, not success',
    () async {
      var coreExists = false;
      var runtimeReady = false;
      var installs = 0;
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => coreExists,
        install: (_, _) async {
          installs++;
          coreExists = true;
        },
        installRuntimes: (_) async {
          runtimeReady = true;
          return true;
        },
        verifyCore: () async => true,
        verifyRuntimes: () async => runtimeReady,
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      expect(coordinator.status, StudioSetupStatus.partial);
      expect(AppState.I.sandboxInstalled, isTrue);
      expect(AppState.I.studioFirstOpenDone, isFalse);
      expect(AppState.I.runtimeInstallState, RuntimeInstallState.failed);
      await coordinator.start();
      expect(installs, 1);
      expect(coordinator.status, StudioSetupStatus.ready);
    },
  );

  test(
    'unusable existing core is a failure and is never overwritten',
    () async {
      AppState.I.sandboxInstalled = true;
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => true,
        install: (_, _) async => fail('must preserve existing prefix'),
        installRuntimes: (_) async =>
            fail('cannot repair runtimes without bash'),
        verifyCore: () async => false,
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      expect(coordinator.status, StudioSetupStatus.failed);
      expect(AppState.I.studioFirstOpenDone, isFalse);
      expect(AppState.I.sandboxInstalled, isFalse);
    },
  );

  test(
    'unsupported device retains a dismissible failure without success flag',
    () async {
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => false,
        install: (_, _) async =>
            throw const SandboxUnsupportedException('Unsupported ABI'),
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      expect(coordinator.status, StudioSetupStatus.unsupported);
      expect(coordinator.error, contains('Unsupported ABI'));
      expect(AppState.I.studioFirstOpenDone, isFalse);
    },
  );

  test(
    'readiness executes runtime tools and rejects a broken executable',
    () async {
      final commands = <String>[];
      SandboxService.execCheckedOverrideForTest = (args, env) async {
        commands.add(args.last);
        // All binaries could exist while node cannot link its shared libraries.
        return args.last.contains('node --version')
            ? (1, 'CANNOT LINK EXECUTABLE')
            : (0, 'GNU bash');
      };
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => false,
        install: (_, _) async {},
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      expect(coordinator.status, StudioSetupStatus.partial);
      expect(AppState.I.studioFirstOpenDone, isFalse);
      expect(commands, contains('bash --version'));
      expect(
        commands.any(
          (c) => c.contains('npx --version') && c.contains('uvx --version'),
        ),
        isTrue,
      );
    },
  );

  test('Health core-only setup does not claim runtime completion', () async {
    await AppState.I.setStudioFirstOpenDone(true);
    final coordinator = StudioSetupCoordinator(
      checkExisting: () async => false,
      install: (_, full) async => expect(full, isFalse),
      verifyCore: () async => true,
      verifyRuntimes: () async =>
          fail('core-only reset must not verify runtimes'),
    );
    addTearDown(coordinator.dispose);
    await coordinator.start(coreOnly: true);
    expect(coordinator.status, StudioSetupStatus.ready);
    expect(AppState.I.sandboxInstalled, isTrue);
    expect(AppState.I.studioFirstOpenDone, isFalse);
    expect(AppState.I.runtimeInstallState, RuntimeInstallState.idle);
  });

  test(
    'wiped-core reinstall invalidates persisted completion before work and after partial result',
    () async {
      await AppState.I.setStudioFirstOpenDone(true);
      final prefs = await SharedPreferences.getInstance();
      final enteredInstall = Completer<void>();
      final barrier = Completer<void>();
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => false,
        install: (_, full) async {
          expect(full, isTrue);
          enteredInstall.complete();
          await barrier.future;
        },
        verifyCore: () async => true,
        verifyRuntimes: () async => false,
      );
      addTearDown(coordinator.dispose);
      final job = coordinator.start();
      await enteredInstall.future;
      final flagDuringInstall = prefs.getBool('studio_first_open_done');
      barrier.complete();
      await job;
      expect(flagDuringInstall, isFalse);
      expect(coordinator.status, StudioSetupStatus.partial);
      expect(prefs.getBool('studio_first_open_done'), isFalse);
      AppState.resetTestInstance();
      AppState.createForTest();
      await AppState.I.loadStudioFirstOpenFlag();
      expect(AppState.I.studioFirstOpenDone, isFalse);
    },
  );

  test(
    'failed core reinstall revokes an earlier persisted completion',
    () async {
      await AppState.I.setStudioFirstOpenDone(true);
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => false,
        install: (_, _) async => throw StateError('Extraction failed'),
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      expect(coordinator.status, StudioSetupStatus.failed);
      expect(AppState.I.studioFirstOpenDone, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'studio_first_open_done',
        ),
        isFalse,
      );
    },
  );

  test(
    'banner retries join one repair and cannot promote an unverified runtime result',
    () async {
      await AppState.I.setStudioFirstOpenDone(true);
      final barrier = Completer<void>();
      var repairs = 0;
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => true,
        install: (_, _) async => fail('must preserve existing prefix'),
        installRuntimes: (_) async {
          repairs++;
          if (repairs > 1) await barrier.future;
          return true; // Installer success is not executable readiness.
        },
        verifyCore: () async => true,
        verifyRuntimes: () async => false,
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      expect(coordinator.status, StudioSetupStatus.partial);
      expect(AppState.I.studioFirstOpenDone, isFalse);
      final retry = coordinator.retryFromRuntimeBanner();
      expect(identical(retry, coordinator.retryFromRuntimeBanner()), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(repairs, 2);
      barrier.complete();
      await retry;
      expect(coordinator.status, StudioSetupStatus.partial);
      expect(AppState.I.runtimeInstallState, RuntimeInstallState.failed);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'studio_first_open_done',
        ),
        isFalse,
      );
    },
  );
}
