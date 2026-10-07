import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/agent_service.dart';
import 'package:ovid_ai/core/health_service.dart';
import 'package:ovid_ai/core/session_search.dart';
import 'package:ovid_ai/core/settings_actions.dart';
import 'package:ovid_ai/core/settings_backup_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/health_screen.dart';
import 'package:ovid_ai/ui/settings_action_widgets.dart';
import 'package:ovid_ai/ui/settings_backup_screen.dart';
import 'package:ovid_ai/ui/settings_health_screen.dart';
import 'package:ovid_ai/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' show open, OperatingSystem;

class _Picker extends FilePicker {
  final Future<FilePickerResult?> Function() pick;
  _Picker(this.pick);
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) => pick();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppState app;
  late File archive;
  const captureKey = ValueKey('settings-overview-capture');

  setUpAll(() {
    open.overrideFor(OperatingSystem.linux,
        () => ffi.DynamicLibrary.open('libsqlite3.so.0'));
  });
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ui-finish-10-');
    SessionSearch.dbPathOverrideForTest = '${root.path}/search.db';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    app = AppState.createForTest();
    app.suspendCoalescedPersistenceForTest = true;
    AgentService.I.debugPauseScheduleTimerForTest(true);
    await app.loadSessions();
    archive = File('${root.path}/backup.zip');
    await archive.writeAsBytes(await SettingsBackupService().export([
      ChatSession(id: 'source', title: 'Imported transcript', model: 'untrusted',
        messages: [Message(role: 'user', content: 'Portable text')]),
    ]));
    FilePicker.platform = _Picker(() async => FilePickerResult([
      PlatformFile(name: 'backup.zip', path: archive.path, size: archive.lengthSync()),
    ]));
    Aether.dark = true;
  });
  tearDown(() async {
    await SettingsActions.awaitPendingWrites();
    await SessionSearch.I.close();
    SessionSearch.dbPathOverrideForTest = null;
    AppState.resetTestInstance();
    SettingsActions.restorePublisher = null;
    SettingsActions.resetAll = null;
    AgentService.I.debugPauseScheduleTimerForTest(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), null,
        );
    await root.delete(recursive: true);
    Aether.dark = true;
  });

  Widget host(Widget screen, {double scale = 1}) => MaterialApp(
    theme: Aether.theme(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: RepaintBoundary(key: captureKey, child: screen),
  );
  void viewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  Future<void> reveal(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(finder, 250,
      scrollable: find.byType(Scrollable).first, maxScrolls: 100);
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  // A target finder must tolerate zero matches while its lazy-list card is
  // off-screen. `.first` throws before scrollUntilVisible can reveal the card.
  Finder pythonRepairCheckbox() => find.descendant(
    of: find.byWidgetPredicate((widget) => widget is Semantics &&
        widget.properties.label == 'Select Python for repair'),
    matching: find.byType(Checkbox),
  );

  for (final scenario in [
    (size: const Size(360, 640), scale: 2.0, dark: true),
    (size: const Size(320, 640), scale: 1.0, dark: false),
    (size: const Size(1024, 768), scale: 1.0, dark: true),
  ]) {
    testWidgets('overview navigation and readback ${scenario.size} ${scenario.scale}x', (tester) async {
      viewport(tester, scenario.size);
      Aether.dark = scenario.dark;
      await tester.pumpWidget(host(const SettingsScreen(), scale: scenario.scale));
      await reveal(tester, find.text('Light'));
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      expect((await SharedPreferences.getInstance()).getString('ovid_theme_mode'), 'light');
      final memory = find.widgetWithText(SettingsSwitchTile, 'Memory');
      await reveal(tester, memory);
      final before = app.memoryEnabled;
      await tester.tap(find.descendant(of: memory, matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect((await SharedPreferences.getInstance()).getBool('ovid_memory_enabled'), !before);
      await reveal(tester, find.text('Backup'));
      await tester.tap(find.text('Backup'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsBackupScreen), findsOneWidget);
      await reveal(tester, find.text('Restore as new sessions'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('restore button publishes through real AppState as inactive new IDs', (tester) async {
    final active = app.activeSessionId;
    final count = app.sessions.length;
    await tester.pumpWidget(host(const SettingsBackupScreen()));
    await reveal(tester, find.text('Restore as new sessions'));
    // Real archive reads, staging and owner publication run outside fake async.
    await tester.runAsync(() async {
      await tester.tap(find.text('Restore as new sessions'));
    });
    // Drain the actual IO operation rather than assuming a fixed wall-clock wait.
    await _finishBackup(tester);
    expect(app.sessions.length, count + 1);
    expect(app.activeSessionId, active);
    final restored = app.sessions.singleWhere((s) => s.title == 'Imported transcript');
    expect(restored.id, startsWith('restored-'));
    expect(restored.messages.single.content, 'Portable text');
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(prefs.getStringList('ovid_sessions')!.join(), contains(restored.id));
    await reveal(tester, find.textContaining('Transcripts restored'));
    expect(find.textContaining('Transcripts restored'), findsOneWidget);
  });

  testWidgets('account change while picker is open cannot redirect restore', (tester) async {
    FilePicker.platform = _Picker(() async {
      await app.transitionSessionAccount('different-account');
      await app.loadSessions();
      return FilePickerResult([
        PlatformFile(name: 'backup.zip', path: archive.path, size: archive.lengthSync()),
      ]);
    });
    await tester.pumpWidget(host(const SettingsBackupScreen()));
    await reveal(tester, find.text('Restore as new sessions'));
    await tester.runAsync(() async => tester.tap(find.text('Restore as new sessions')));
    await _finishBackup(tester);
    expect(app.sessions.any((s) => s.title == 'Imported transcript'), isFalse);
    await reveal(tester, find.textContaining('Operation failed'));
    expect(find.textContaining('Operation failed'), findsOneWidget);
    expect(find.textContaining('Transcripts restored'), findsNothing);
  });

  testWidgets('Import validates the archive without publishing sessions', (tester) async {
    final ids = app.sessions.map((s) => s.id).toList();
    await tester.pumpWidget(host(const SettingsBackupScreen()));
    await reveal(tester, find.text('Import'));
    await tester.runAsync(() async => tester.tap(find.text('Import')));
    await _finishBackup(tester);
    expect(app.sessions.map((s) => s.id), ids);
    await reveal(tester, find.textContaining('Archive valid: 1 transcript(s)'));
    expect(find.textContaining('No data restored'), findsOneWidget);
  });

  testWidgets('reset stays unavailable when unbound and partial result remains truthful at 2x', (tester) async {
    viewport(tester, const Size(360, 640));
    // AppState now binds the verified reset owner on construction; clear it so
    // this case still covers the genuinely-unavailable state, then restore.
    final boundReset = SettingsActions.resetAll;
    addTearDown(() => SettingsActions.resetAll = boundReset);
    SettingsActions.resetAll = null;
    await tester.pumpWidget(host(const SettingsResetScreen(), scale: 2));
    await reveal(tester, find.text('Delete all data'));
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(host(SettingsResetScreen(reset: () async =>
      const SettingsResetResult(completed: ['chats'], failures: {'keys': 'locked'})), scale: 2));
    await reveal(tester, find.text('Delete all data'));
    await tester.tap(find.text('Delete all data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete everything'));
    await tester.pumpAndSettle();
    await reveal(tester, find.textContaining('Incomplete reset'));
    expect(find.textContaining('keys: locked'), findsOneWidget);
    expect(find.text('All data deleted.'), findsNothing);
  });

  testWidgets('targeted repair keeps cancellation pending and errors visible at 2x', (tester) async {
    viewport(tester, const Size(360, 640));
    final release = Completer<void>();
    Set<String>? targets;
    final health = HealthService(
      installed: () async => true,
      exec: (args) async => args.first == 'python' ? (127, 'missing') : (0, 'version'),
      workspace: () async {}, providerConfigured: () => false,
      repairWorker: (ids, cancellation, onLine) async {
        targets = ids;
        onLine('Checking signed package metadata');
        await release.future;
        cancellation.throwIfCancelled();
      },
    );
    await tester.pumpWidget(host(SettingsHealthScreen(service: health), scale: 2));
    await tester.pumpAndSettle();
    await reveal(tester, pythonRepairCheckbox());
    await tester.tap(pythonRepairCheckbox());
    await tester.pump();
    final repairButton = find.widgetWithText(SettingsActionButton, 'Repair selected runtimes');
    await tester.scrollUntilVisible(repairButton, -250,
      scrollable: find.byType(Scrollable).first, maxScrolls: 100);
    await Scrollable.ensureVisible(tester.element(repairButton), alignment: .5);
    await tester.pump();
    await tester.tap(find.text('Repair selected runtimes'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(targets, {'python'});
    await reveal(tester, find.text('Cancel repair'));
    await tester.tap(find.text('Cancel repair'));
    await tester.pump();
    expect(find.text('Waiting for worker to stop…'), findsOneWidget);
    expect(health.repairing, isTrue);
    expect(tester.takeException(), isNull);
    release.complete();
    await tester.pumpAndSettle();
    await reveal(tester, find.textContaining('Repair cancelled'));
    expect(find.text('Selected runtime checks now pass.'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    health.dispose();
  });

  testWidgets('failed preference readback exposes retry instead of saved status', (tester) async {
    viewport(tester, const Size(360, 320));
    final value = ValueNotifier(false);
    addTearDown(value.dispose);
    var canWrite = false;
    await tester.pumpWidget(host(Scaffold(body: ListView(children: [
      SettingsSwitchTile(
        icon: Icons.memory, title: 'Memory', subtitleOn: 'Enabled',
        subtitleOff: 'Disabled', listenable: value, getter: () => value.value,
        setter: (next) => SettingsActions.persist('memory-fixture', next, () async {
          value.value = next;
          if (canWrite) {
            await (await SharedPreferences.getInstance()).setBool('memory-fixture', next);
          }
        }),
      ),
    ])), scale: 2));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not save Memory'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool('memory-fixture'), isNull);
    expect(tester.takeException(), isNull);
    canWrite = true;
    await tester.tap(find.text('Memory'));
    await tester.pumpAndSettle();
    expect((await SharedPreferences.getInstance()).getBool('memory-fixture'), isTrue);
    expect(find.textContaining('Could not save'), findsNothing);
  });

  testWidgets('failed signed repair exposes error without claiming runtime passed', (tester) async {
    final health = HealthService(
      installed: () async => true,
      exec: (args) async => args.first == 'python' ? (127, 'missing') : (0, 'version'),
      workspace: () async {}, providerConfigured: () => true,
      repairWorker: (_, _, _) async => throw StateError('Signed package verification failed'),
    );
    await tester.pumpWidget(host(SettingsHealthScreen(service: health)));
    await tester.pumpAndSettle();
    await reveal(tester, pythonRepairCheckbox());
    await tester.tap(pythonRepairCheckbox());
    await tester.pump();
    final repairButton = find.widgetWithText(SettingsActionButton, 'Repair selected runtimes');
    await tester.scrollUntilVisible(repairButton, -250,
      scrollable: find.byType(Scrollable).first, maxScrolls: 100);
    await Scrollable.ensureVisible(tester.element(repairButton), alignment: .5);
    await tester.pump();
    await tester.tap(find.text('Repair selected runtimes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Signed package verification failed'), findsOneWidget);
    expect(find.text('Selected runtime checks now pass.'), findsNothing);
    expect(health.lastReport!.checks.singleWhere((c) => c.id == 'python').ok, isFalse);
    await tester.pumpWidget(const SizedBox());
    health.dispose();
  });

  testWidgets('general health reports check failures without an endless spinner', (tester) async {
    viewport(tester, const Size(360, 320));
    final health = HealthService(installed: () async => true,
      exec: (_) async => (0, 'version'), workspace: () async {},
      providerConfigured: () => throw StateError('configuration unavailable'));
    await tester.pumpWidget(host(HealthScreen(service: health), scale: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Health checks failed'), findsOneWidget);
    await reveal(tester, find.text('Re-run checks'));
    expect(find.text('Re-run checks'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    health.dispose();
  });

  for (final size in [const Size(360, 640), const Size(320, 640), const Size(1024, 768)]) {
    testWidgets('general health exposes diagnostics and repair at $size', (tester) async {
      viewport(tester, size);
      final health = HealthService(installed: () async => true,
        exec: (_) async => (127, 'missing'), workspace: () async {},
        providerConfigured: () => false);
      await tester.pumpWidget(host(HealthScreen(service: health), scale: size.width == 360 ? 2 : 1));
      await tester.pumpAndSettle();
      expect(find.text('Overall health'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await reveal(tester, find.text('Hard reset the sandbox'));
      expect(find.text('Re-run checks'), findsOneWidget);
      expect(find.text('Repair'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      health.dispose();
    });
  }

  testWidgets('preset duplicate fields and cancel remain reachable above keyboard', (tester) async {
    viewport(tester, const Size(360, 640));
    await tester.pumpWidget(host(const SettingsScreen(), scale: 2));
    await reveal(tester, find.text('Agent presets'));
    await tester.tap(find.text('Agent presets'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Duplicate as custom').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Duplicate as custom').first);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.ensureVisible(find.widgetWithText(TextField, 'Preset ID'));
    await tester.enterText(find.widgetWithText(TextField, 'Preset ID'), 'keyboard_test');
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('settings overview review capture', (tester) async {
    viewport(tester, const Size(360, 640));
    await tester.pumpWidget(host(const SettingsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('UI_REVIEW_CAPTURE')) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/opencode/ui-finish-10.png').writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}

Future<void> _finishBackup(WidgetTester tester) async {
  // Pump in bounded real-IO turns, stopping on the UI operation's settled state.
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    final restore = find.byWidgetPredicate((w) =>
      w is SettingsActionButton && w.label == 'Restore as new sessions');
    if (tester.widget<SettingsActionButton>(restore).onPressed != null) return;
  }
  fail('Backup did not settle within the bounded IO pump budget');
}
