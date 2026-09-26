import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/ui/sandbox_setup.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WS1 — startup on-demand install.
///
/// Covers the removal of the first-launch setup gate and the Studio
/// first-open mandatory install:
///  1. first launch goes straight to the shell (no gate in main.dart),
///  2. the `studio_first_open_done` flag: mandatory full install screen is
///     shown once, skipped afterwards,
///  3. the background runtime job and the boot self-heal never apt-update
///     at startup — the apt path only runs from the Studio first-open
///     install or an explicit user retry.
///
/// NOTE on ordering: the SandboxService singleton is shared across tests in
/// this file, so the "explicit user retry" test (which fakes an installed
/// core and flips `_runtimesRequested`) runs LAST.
/// Deletes a staging dir tolerantly.
///
/// `checkExisting()`/`selfHeal` leave async work that can still be writing when
/// the teardown runs, and a plain `deleteSync(recursive: true)` then fails with
/// "Directory not empty" — a flake that has nothing to do with the behaviour
/// under test. Retry briefly, then give up quietly: the next setUp wipes the
/// same path anyway.
void deleteQuietly(Directory d) {
  for (var i = 0; i < 3; i++) {
    if (!d.existsSync()) return;
    try {
      d.deleteSync(recursive: true);
      return;
    } catch (_) {}
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppState.resetTestInstance();
    AppState.createForTest();
    SandboxService.I.setInstallInFlightForTest(false);
    SandboxService.I.resetCheckExistingForTest();
    SandboxService.execCheckedOverrideForTest = null;
  });

  tearDown(() {
    AppState.resetTestInstance();
    SandboxService.I.setInstallInFlightForTest(false);
    SandboxService.I.resetCheckExistingForTest();
    SandboxService.execCheckedOverrideForTest = null;
    deleteQuietly(Directory('${Directory.systemTemp.path}/sandbox-staging'));
  });

  group('gate removal', () {
    test('first launch goes straight to the shell — no setup gate', () {
      final src = File('lib/main.dart').readAsStringSync();
      expect(src, isNot(contains('FirstLaunchSetupGate')));
      expect(src, isNot(contains('SandboxSetupScreen')));
      expect(src, contains('home: const OvidShell()'));
    });

    test('first-frame init still loads the first-open flag', () {
      final src = File('lib/core/state.dart').readAsStringSync();
      final body = src.substring(
        src.indexOf('Future<void> _initializeForFirstFrame()'),
        src.indexOf('Future<List<StartupTask>> buildReadinessTasks()'),
      );
      expect(body, contains('loadStudioFirstOpenFlag()'));
    });
  });

  group('studio_first_open_done flag', () {
    test('persists across AppState restarts', () async {
      expect(AppState.I.studioFirstOpenDone, isFalse);

      await AppState.I.setStudioFirstOpenDone(true);
      expect(AppState.I.studioFirstOpenDone, isTrue);

      // Simulate an app restart: fresh AppState, same prefs store.
      AppState.resetTestInstance();
      AppState.createForTest();
      expect(AppState.I.studioFirstOpenDone, isFalse);
      await AppState.I.loadStudioFirstOpenFlag();
      expect(AppState.I.studioFirstOpenDone, isTrue);

      // And it clears again.
      await AppState.I.setStudioFirstOpenDone(false);
      AppState.resetTestInstance();
      AppState.createForTest();
      await AppState.I.loadStudioFirstOpenFlag();
      expect(AppState.I.studioFirstOpenDone, isFalse);
    });

    test('prefs key is exactly studio_first_open_done', () async {
      await AppState.I.setStudioFirstOpenDone(true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('studio_first_open_done'), isTrue);
    });
  });

  group('openStudio first-open flow', () {
    /// In widget tests the path_provider channel never resolves (no host
    /// plugin), which hangs both checkExisting() and install(). Point it at
    /// the real temp dir so disk checks run deterministically.
    void mockPathProvider() {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return Directory.systemTemp.path;
        }
        throw MissingPluginException('no handler for ${call.method}');
      });
      addTearDown(() =>
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null));
    }

    Future<void> pumpLauncher(WidgetTester tester) async {
      mockPathProvider();
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      openStudio(captured);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('flag unset → mandatory full install screen (non-dismissible)',
        (tester) async {
      expect(AppState.I.studioFirstOpenDone, isFalse);

      await pumpLauncher(tester);

      final screen =
          tester.widget<SandboxSetupScreen>(find.byType(SandboxSetupScreen));
      expect(screen.studioFirstOpen, isTrue);
      expect(screen.gateMode, isFalse);
      // Non-dismissible while installing: no close affordance.
      expect(find.byIcon(Icons.close), findsNothing);

      // Tear down the route so the screen's ticker/install future can't leak.
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('flag set → mandatory install skipped (manual setup instead)',
        (tester) async {
      await AppState.I.setStudioFirstOpenDone(true);
      // Nothing installed on disk in the test env: the disk check decides.
      SandboxService.I.resetCheckExistingForTest();

      await pumpLauncher(tester);
      // Let the async checkExisting().then(...) push its route.
      await tester.pump(const Duration(milliseconds: 500));

      // Manual (dismissible) setup screen — NOT the mandatory first-open one.
      final screen =
          tester.widget<SandboxSetupScreen>(find.byType(SandboxSetupScreen));
      expect(screen.studioFirstOpen, isFalse);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('background-install guard', () {
    test('returns early while a Studio install is in flight', () async {
      final app = AppState.I;
      app.sandboxInstalled = true;
      SandboxService.I.setInstallInFlightForTest(true);
      SandboxService.execCheckedOverrideForTest = (args, env) async {
        fail('no process may spawn while an install is in flight');
      };

      await app.maybeStartBackgroundRuntimeInstall();

      expect(app.runtimeInstallState, RuntimeInstallState.idle);
      expect(SandboxService.I.runtimesRequested, isFalse);
    });

    test('never apt-updates at startup once the first-open install is done',
        () async {
      final app = AppState.I;
      app.sandboxInstalled = true;
      await app.setStudioFirstOpenDone(true);
      // Runtimes are missing: nothing on disk, and the probe fails.
      SandboxService.execCheckedOverrideForTest =
          (args, env) async => (1, '');

      await app.maybeStartBackgroundRuntimeInstall();

      // Reports failed with a retry affordance instead of apt-installing.
      expect(app.runtimeInstallState, RuntimeInstallState.failed);
      expect(app.runtimeInstallLine, contains('Retry'));
      expect(
        SandboxService.I.runtimesRequested,
        isFalse,
        reason: 'the apt path (installCoreRuntimes) must not run '
            'from a startup trigger',
      );
    });

    test('quiet when first-open has not run yet (Studio owns the retry)',
        () async {
      final app = AppState.I;
      app.sandboxInstalled = true;
      // Flag unset: the mandatory Studio install hasn't happened.
      SandboxService.execCheckedOverrideForTest =
          (args, env) async => (1, '');

      await app.maybeStartBackgroundRuntimeInstall();

      // No banner noise, no apt — opening Studio runs the full install.
      expect(app.runtimeInstallState, RuntimeInstallState.idle);
      expect(SandboxService.I.runtimesRequested, isFalse);
    });

    test('cheap path still marks done when runtimes are present', () async {
      final app = AppState.I;
      app.sandboxInstalled = true;
      await app.setStudioFirstOpenDone(true);
      SandboxService.execCheckedOverrideForTest =
          (args, env) async => (0, ''); // probe succeeds

      await app.maybeStartBackgroundRuntimeInstall();

      expect(app.runtimeInstallState, RuntimeInstallState.done);
      expect(SandboxService.I.runtimesRequested, isFalse);
    });
  });

  group('sandbox.selfHeal wiring', () {
    test('verifies only — never apt-updates at boot', () async {
      SandboxService.execCheckedOverrideForTest =
          (args, env) async => (1, '');

      expect(await AppState.I.verifyRuntimesForStartupSelfHeal(), isFalse);
      expect(
        SandboxService.I.runtimesRequested,
        isFalse,
        reason: 'the boot self-heal must not enter the apt path',
      );
    });

    test('waits out a Studio install in flight, then verifies', () async {
      SandboxService.I.setInstallInFlightForTest(true);
      SandboxService.execCheckedOverrideForTest =
          (args, env) async => (1, '');

      var finished = false;
      final future =
          AppState.I.verifyRuntimesForStartupSelfHeal().then((value) {
        finished = true;
        return value;
      });
      await Future.delayed(const Duration(milliseconds: 200));
      expect(
        finished,
        isFalse,
        reason: 'must wait while the Studio install owns dpkg',
      );

      SandboxService.I.setInstallInFlightForTest(false);
      expect(await future, isFalse);
      expect(SandboxService.I.runtimesRequested, isFalse);
    });
  });

  // Runs last: fakes an installed core and flips _runtimesRequested.
  group('explicit user retry', () {
    test('banner Retry IS the apt path', () async {
      // Fake an installed core on disk so installCoreRuntimes proceeds.
      final sandboxDir = Directory('${Directory.systemTemp.path}/sandbox');
      deleteQuietly(sandboxDir);
      for (final rel in [
        'bin/bash',
        'bin/coreutils',
        'lib/libtermux-exec-direct-ld-preload.so',
      ]) {
        final file = File('${sandboxDir.path}/$rel');
        file.parent.createSync(recursive: true);
        file.createSync();
      }
      addTearDown(() => deleteQuietly(sandboxDir));
      SandboxService.I.resetCheckExistingForTest();
      SandboxService.execCheckedOverrideForTest = null;
      expect(await SandboxService.I.checkExisting(), isTrue);

      final seen = <String>[];
      SandboxService.execCheckedOverrideForTest = (args, env) async {
        final cmd = args.join(' ');
        seen.add(cmd);
        if (cmd.contains('command -v')) return (1, ''); // runtimes missing
        return (0, ''); // apt update / install succeed
      };

      final app = AppState.I;
      app.sandboxInstalled = true;
      await app.setStudioFirstOpenDone(true);
      await app.retryBackgroundRuntimeInstall();

      expect(
        seen.any((c) => c.contains('apt update')),
        isTrue,
        reason: 'explicit retry must reach the apt path',
      );
      expect(seen.any((c) => c.contains('apt install')), isTrue);
      expect(SandboxService.I.runtimesRequested, isTrue);
    });
  });
}
