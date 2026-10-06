import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/agent_notification_service.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/sandbox_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_setup_coordinator.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/sandbox_setup.dart';
import 'package:ovid_ai/ui/studio_screen.dart';
import 'package:ovid_ai/ui/widgets/aether_primitives.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v2-13 — deterministic Studio onboarding.
///
/// `openStudio` runs through ONE resolver ([resolveStudioDestination]) that
/// lands in exactly one place per state — install/attention/first-open →
/// [SandboxSetupScreen], ready → [StudioScreen] — and pushes it (the stack is
/// never wiped). First-open completion consolidates into a single guided
/// "Connect repo" step: Session clone preselected (the sensible default),
/// Local folder clone under a collapsed Advanced options section, one clear
/// action (Open Studio) that hands off with the post-install GitHub prompt.
///
/// Pumps are bounded throughout; real async (resolver, disk probes) runs via
/// plain `test` / explicit bounded `pump` durations.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferences.getInstance();
    // Signed-out baseline for every test, applied in the REAL zone: awaiting
    // GitHubService sign-out inside a widget test's fake-async zone can wedge
    // on the serialized token-write chain left by a previous test.
    FlutterSecureStorage.setMockInitialValues({});
    await GitHubService.I.signOut();
    AppState.resetTestInstance();
    AppState.createForTest();
    SandboxService.I.setInstallInFlightForTest(false);
    SandboxService.I.resetCheckExistingForTest();
  });

  tearDown(() async {
    StudioSetupCoordinator.overrideForTest?.dispose();
    StudioSetupCoordinator.overrideForTest = null;
    studioLoginPromptOverrideForTest = null;
    studioRepoSyncOverrideForTest = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    AgentNotificationService.I.resetForTest();
    if (GitHubService.I.isLoggedIn) await GitHubService.I.signOut();
    AppState.resetTestInstance();
    SandboxService.I.setInstallInFlightForTest(false);
    SandboxService.I.resetCheckExistingForTest();
    _deleteQuietly(Directory('${Directory.systemTemp.path}/sandbox'));
  });

  /// Idle coordinator: not running, nothing failed — `needsAttention` false.
  StudioSetupCoordinator useCoordinator({
    Future<bool> Function()? checkExisting,
    Future<void> Function(SetupPhaseCallback, bool)? install,
    Future<bool> Function(SetupPhaseCallback)? installRuntimes,
    Future<bool> Function()? verifyCore,
    Future<bool> Function()? verifyRuntimes,
  }) {
    final coordinator = StudioSetupCoordinator(
      checkExisting: checkExisting ?? () async => false,
      install: install ?? (_, _) async {},
      installRuntimes: installRuntimes ?? (_) async => true,
      verifyCore: verifyCore ?? () async => true,
      verifyRuntimes: verifyRuntimes ?? () async => true,
    );
    StudioSetupCoordinator.overrideForTest = coordinator;
    return coordinator;
  }

  Widget host({bool gateMode = false, bool studioFirstOpen = true}) {
    return MaterialApp(
      theme: Aether.theme(),
      home: SandboxSetupScreen(
        gateMode: gateMode,
        studioFirstOpen: studioFirstOpen,
      ),
    );
  }

  /// Tall viewport so every card in the scroll views is laid out and
  /// hit-testable (same pattern as the ui_redesign setup tests).
  void tallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Approve on the (empty) approval state and let the instant test install
  /// run to completion. Bounded: fixed pump count + one 500 ms frame for the
  /// done-view tween — no pumpAndSettle against the pulsing progress dots.
  Future<void> approveAndComplete(WidgetTester tester) async {
    await tester.tap(find.text('Install sandbox'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  group('resolveStudioDestination', () {
    test('returns StudioScreen when the sandbox is installed and ready', () async {
      useCoordinator();
      _fakeInstalledSandbox();
      await AppState.I.setStudioFirstOpenDone(true);

      final destination = await resolveStudioDestination();

      expect(destination, isA<StudioScreen>());
      expect(AppState.I.sandboxInstalled, isTrue);
    });

    test('returns SandboxSetupScreen when the sandbox is not installed', () async {
      useCoordinator();
      // Nothing on disk in the test env: the disk probe decides.
      await AppState.I.setStudioFirstOpenDone(true);

      final destination = await resolveStudioDestination();

      expect(destination, isA<SandboxSetupScreen>());
      expect((destination as SandboxSetupScreen).studioFirstOpen, isFalse);
      expect(AppState.I.sandboxInstalled, isFalse);
    });

    test(
      'returns the first-open setup when the flag is unset, core on disk or not',
      () async {
        useCoordinator();
        _fakeInstalledSandbox();
        // Flag unset (fresh prefs): approval comes before any disk decision.

        final destination = await resolveStudioDestination();

        expect(destination, isA<SandboxSetupScreen>());
        expect((destination as SandboxSetupScreen).studioFirstOpen, isTrue);
      },
    );
  });

  group('openStudio', () {
    /// In widget tests the path_provider channel never resolves (no host
    /// plugin), which hangs checkExisting(). Point it at the real temp dir so
    /// the disk probe runs deterministically.
    void mockPathProvider() {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'getApplicationSupportDirectory') {
              return Directory.systemTemp.path;
            }
            throw MissingPluginException('no handler for ${call.method}');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
    }

    testWidgets(
      'installed and ready pushes exactly one StudioScreen and keeps the stack',
      (tester) async {
        FlutterSecureStorage.setMockInitialValues({
          'ovid_github_token': 'tok',
        });
        studioLoginPromptOverrideForTest = (_) {};
        studioRepoSyncOverrideForTest = () async {};
        AgentService.I.debugPauseScheduleTimerForTest(true);
        AppState.I.seenWelcomeVersion = AppState.welcomeVersion;
        await GitHubService.I.initialize(
          client: MockClient(
            (request) async => request.url.path == '/user'
                ? http.Response(jsonEncode({'login': 'octocat'}), 200)
                : http.Response('{}', 404),
          ),
        );
        useCoordinator();
        _fakeInstalledSandbox();
        mockPathProvider();
        await AppState.I.setStudioFirstOpenDone(true);

        await tester.pumpWidget(
          MaterialApp(
            theme: Aether.theme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => openStudio(context),
                  child: const Text('Launcher: open Studio'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Launcher: open Studio'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        // Exactly one landing place: Studio, no setup screen, no ambiguity.
        expect(find.byType(StudioScreen), findsOneWidget);
        expect(find.byType(SandboxSetupScreen), findsNothing);
        expect(find.text('Connect a repo'), findsOneWidget);

        // The launcher route is still underneath: a pop returns to it, which
        // proves openStudio pushed instead of wiping the stack.
        await tester.binding.handlePopRoute();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(StudioScreen), findsNothing);
        expect(find.text('Launcher: open Studio'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('connect repo step (first-open completion)', () {
    testWidgets('shows Session clone preselected as the default', (
      tester,
    ) async {
      tallViewport(tester);
      useCoordinator();
      await tester.pumpWidget(host());
      await tester.pump();
      await approveAndComplete(tester);

      expect(find.text('Sandbox ready'), findsOneWidget);
      expect(find.text('Connect repo'), findsOneWidget);
      // Session clone is the preselected sensible default.
      expect(find.text('Session clone'), findsOneWidget);
      expect(find.text('Default'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('connectRepo.sessionClone')),
          matching: find.byIcon(Icons.check_circle_rounded),
        ),
        findsOneWidget,
      );
      // Advanced options stay collapsed; one clear action per calm state.
      expect(find.text('Advanced options'), findsOneWidget);
      expect(find.text('Local folder clone'), findsNothing);
      expect(find.text('Open Studio'), findsOneWidget);
      expect(find.text('Back to chat'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'advanced options expand to Local folder clone and selection follows taps',
      (tester) async {
        tallViewport(tester);
        useCoordinator();
        await tester.pumpWidget(host());
        await tester.pump();
        await approveAndComplete(tester);

        await tester.tap(find.text('Advanced options'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Local folder clone'), findsOneWidget);
        // Still unselected: the default did not move just by expanding.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('connectRepo.localClone')),
            matching: find.byIcon(Icons.check_circle_rounded),
          ),
          findsNothing,
        );

        await tester.tap(find.text('Local folder clone'));
        await tester.pump();
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('connectRepo.localClone')),
            matching: find.byIcon(Icons.check_circle_rounded),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('connectRepo.sessionClone')),
            matching: find.byIcon(Icons.check_circle_rounded),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'Open Studio replaces the step with StudioScreen and fires the one-time '
      'post-install GitHub prompt',
      (tester) async {
        // Signed out already (shared setUp) — the post-install prompt must
        // fire exactly once from Studio's side.
        var prompted = 0;
        studioLoginPromptOverrideForTest = (_) => prompted++;
        studioRepoSyncOverrideForTest = () async {};
        AgentService.I.debugPauseScheduleTimerForTest(true);
        AppState.I.seenWelcomeVersion = AppState.welcomeVersion;
        tallViewport(tester);
        useCoordinator();
        await tester.pumpWidget(host());
        await tester.pump();
        await approveAndComplete(tester);

        await tester.tap(find.text('Open Studio'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        final studio = tester.widget<StudioScreen>(find.byType(StudioScreen));
        expect(studio.postInstallGithubPrompt, isTrue);
        expect(find.byType(SandboxSetupScreen), findsNothing);
        expect(prompted, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('error state', () {
    testWidgets(
      'install failure surfaces exactly one retry action, which re-runs the '
      'preserved install flow',
      (tester) async {
        tallViewport(tester);
        var installs = 0;
        var fail = true;
        useCoordinator(
          install: (_, _) async {
            installs++;
            if (fail) throw StateError('simulated download failure');
          },
        );
        await tester.pumpWidget(host());
        await tester.pump();
        await tester.tap(find.text('Install sandbox'));
        await tester.pump();
        await tester.pump();

        expect(find.text('Install interrupted'), findsOneWidget);
        expect(
          find.textContaining('simulated download failure'),
          findsOneWidget,
        );
        // One clear action: a single primary retry.
        final retry = find.widgetWithText(AetherPrimaryButton, 'Retry install');
        expect(retry, findsOneWidget);
        expect(find.byType(AetherPrimaryButton), findsOneWidget);

        fail = false;
        await tester.tap(retry);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(installs, 2);
        // First-open completion lands on the guided Connect repo step.
        expect(find.text('Connect repo'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  group('layout', () {
    for (final (name, size, dpr) in [
      ('360x640 @2x', const Size(720, 1280), 2.0),
      ('wide', const Size(1440, 900), 1.0),
    ]) {
      testWidgets('approval and connect repo states fit $name', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = dpr;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        useCoordinator();
        await tester.pumpWidget(host());
        await tester.pump();

        // Empty (approval) state: one clear action, no overflow.
        expect(find.text('Set up Studio'), findsOneWidget);
        expect(find.text('Install sandbox'), findsOneWidget);

        await approveAndComplete(tester);
        expect(find.text('Connect repo'), findsOneWidget);
        expect(find.text('Session clone'), findsOneWidget);
        expect(find.text('Open Studio'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  });
}

/// Deletes a staging dir tolerantly (same rationale as studio_first_open_test:
/// async self-heal writes can still be landing when teardown runs).
void _deleteQuietly(Directory d) {
  for (var i = 0; i < 3; i++) {
    if (!d.existsSync()) return;
    try {
      d.deleteSync(recursive: true);
      return;
    } catch (_) {}
  }
}

/// Fakes an installed sandbox core on disk so the real
/// `SandboxService.checkExisting` probe certifies it.
void _fakeInstalledSandbox() {
  final sandboxDir = Directory('${Directory.systemTemp.path}/sandbox');
  for (final rel in [
    'bin/bash',
    'bin/coreutils',
    'lib/libtermux-exec-direct-ld-preload.so',
  ]) {
    final file = File('${sandboxDir.path}/$rel');
    file.parent.createSync(recursive: true);
    file.createSync();
  }
  SandboxService.I.resetCheckExistingForTest();
}
