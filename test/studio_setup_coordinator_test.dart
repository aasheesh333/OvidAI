import 'dart:async';
import 'dart:io';

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

  for (final aggregate in [false, true]) {
    for (final repaired in [false, true]) {
      test('transaction fence requires repair despite version success (aggregate=$aggregate repaired=$repaired)', () async {
        final root = Directory.systemTemp.createTempSync('coordinator-transaction-');
        final transaction = Directory('${root.path}/var/cache/ovid-pkg/transaction')..createSync(recursive: true);
        File('${transaction.path}/active').writeAsStringSync('');
        SandboxService.I.sandboxPrefixForTest = root;
        addTearDown(() {
          SandboxService.I.sandboxPrefixForTest = null;
          root.deleteSync(recursive: true);
        });
        SandboxService.execCheckedOverrideForTest = (_, _) async => (0, 'working version');
        var repairs = 0;
        final coordinator = StudioSetupCoordinator(
          checkExisting: () async => true,
          verifyCore: () async => true,
          verifyRuntimes: aggregate ? () async => true : null,
          installRuntimes: (_) async {
            repairs++;
            if (repaired) transaction.deleteSync(recursive: true);
            return true;
          },
        );
        addTearDown(coordinator.dispose);
        await coordinator.start();
        expect(repairs, 1);
        expect(coordinator.status, repaired ? StudioSetupStatus.ready : StudioSetupStatus.partial);
        expect(AppState.I.studioFirstOpenDone, repaired);
        if (!repaired) {
          for (final runtime in StudioRuntime.values) {
            expect(coordinator.runtimeVerification(runtime), isNot(RuntimeVerification.verified));
          }
        }
      });
    }
  }

  for (final aggregate in [false, true]) {
    test('transaction appearing during verification revokes success (aggregate=$aggregate)', () async {
      final root = Directory.systemTemp.createTempSync('coordinator-late-transaction-');
      final transaction = Directory('${root.path}/var/cache/ovid-pkg/transaction');
      SandboxService.I.sandboxPrefixForTest = root;
      addTearDown(() {
        SandboxService.I.sandboxPrefixForTest = null;
        root.deleteSync(recursive: true);
      });
      SandboxService.execCheckedOverrideForTest = (_, _) async {
        transaction.createSync(recursive: true);
        return (0, 'working version');
      };
      final coordinator = StudioSetupCoordinator(
        checkExisting: () async => false,
        install: (_, _) async {},
        verifyCore: () async => true,
        verifyRuntimes: aggregate ? () async {
          transaction.createSync(recursive: true);
          return true;
        } : null,
      );
      addTearDown(coordinator.dispose);
      await coordinator.start();
      expect(coordinator.status, StudioSetupStatus.partial);
      expect(AppState.I.studioFirstOpenDone, isFalse);
      for (final runtime in StudioRuntime.values) {
        expect(coordinator.runtimeVerification(runtime), isNot(RuntimeVerification.verified));
      }
    });
  }

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
        commands.any((c) => c.contains('npx --version')),
        isTrue,
      );
      expect(
        commands.any((c) => c.contains('uvx --version')),
        isTrue,
      );
    },
  );

  test('runtime failures are independent evidence and retry restores flags', () async {
    var recovered = false;
    var existing = false;
    SandboxService.execCheckedOverrideForTest = (args, env) async {
      final command = args.last;
      if (!recovered &&
          (command.contains('node --version') ||
              command.contains('python --version') ||
              command.contains('git --version'))) {
        return (127, 'not installed');
      }
      return (0, 'version');
    };
    final coordinator = StudioSetupCoordinator(
      checkExisting: () async => existing,
      install: (onPhase, _) async {
        existing = true;
        onPhase(8, 1, 'Runtime setup finished');
      },
      installRuntimes: (_) async {
        recovered = true;
        return true;
      },
    );
    addTearDown(coordinator.dispose);
    await coordinator.start();
    expect(coordinator.status, StudioSetupStatus.partial);
    expect(coordinator.coreReady, isTrue);
    for (final runtime in [
      StudioRuntime.node,
      StudioRuntime.python,
      StudioRuntime.git,
    ]) {
      expect(
        coordinator.runtimeVerification(runtime),
        RuntimeVerification.unavailable,
      );
    }
    expect(
      coordinator.runtimeVerification(StudioRuntime.curl),
      RuntimeVerification.verified,
    );
    expect(AppState.I.sandboxInstalled, isTrue);
    expect(AppState.I.runtimeInstallState, RuntimeInstallState.failed);
    expect(AppState.I.studioFirstOpenDone, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('studio_first_open_done'), isFalse);

    final retry = coordinator.retryFromRuntimeBanner();
    expect(
      coordinator.runtimeVerification(StudioRuntime.node),
      RuntimeVerification.unknown,
    );
    await retry;
    expect(coordinator.status, StudioSetupStatus.ready);
    for (final runtime in StudioRuntime.values) {
      expect(
        coordinator.runtimeVerification(runtime),
        RuntimeVerification.verified,
      );
    }
    expect(AppState.I.runtimeInstallState, RuntimeInstallState.done);
    expect(AppState.I.studioFirstOpenDone, isTrue);
    expect(prefs.getBool('studio_first_open_done'), isTrue);
    coordinator.forgetCompleted();
    expect(
      coordinator.runtimeVerification(StudioRuntime.node),
      RuntimeVerification.unknown,
    );
  });

  test('aggregate failure without evidence does not accuse individual runtimes', () async {
    final coordinator = StudioSetupCoordinator(
      checkExisting: () async => false,
      install: (onPhase, _) async {
        onPhase(8, 1, 'npm registry ......  ⚠ ping failed/timeout');
      },
      verifyCore: () async => true,
      verifyRuntimes: () async => false,
    );
    addTearDown(coordinator.dispose);
    await coordinator.start();
    expect(coordinator.status, StudioSetupStatus.partial);
    for (final runtime in StudioRuntime.values) {
      expect(
        coordinator.runtimeVerification(runtime),
        RuntimeVerification.unknown,
      );
    }
  });

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
