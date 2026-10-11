import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/startup_coordinator.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/startup_progress_panel.dart';

final class _Task implements StartupTask {
  _Task(this.id, this.result);

  @override
  final String id;
  final StartupItemStatus Function(String id) result;

  @override
  StartupItemKind get kind => StartupItemKind.plugin;
  @override
  String get label => 'Item $id';
  @override
  Duration get timeout => const Duration(seconds: 15);
  @override
  StartupDisable? get onDisable => null;
  @override
  Future<StartupItemStatus> run() async => result(id);
}

StartupItemStatus _ready(String id) =>
    StartupItemStatus.ready(id, StartupItemKind.plugin, 'Item $id');
StartupItemStatus _unsupported(String id) => StartupItemStatus.unsupported(
  id,
  StartupItemKind.plugin,
  'Item $id',
  reason: 'No compatible runtime',
);
StartupItemStatus _failed(String id) => StartupItemStatus.failed(
  id,
  StartupItemKind.plugin,
  'Item $id',
  reason: 'Installed content is missing',
);

Future<StartupCoordinator> _run(List<StartupTask> tasks) async {
  final c = StartupCoordinator.forTest(deadline: const Duration(seconds: 30));
  unawaited(c.start(tasks));
  return c;
}

Future<void> _pump(WidgetTester tester, StartupCoordinator c) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: Aether.theme(),
      home: Scaffold(body: StartupProgressPanel(coordinator: c)),
    ),
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('one unsupported item with the rest ready hides the panel', (
    tester,
  ) async {
    final c = await _run([
      _Task('a', _ready),
      _Task('b', _ready),
      _Task('u', _unsupported),
    ]);
    await _pump(tester, c);
    expect(c.snapshot.readinessComplete, isTrue);
    expect(find.byKey(const ValueKey('startup-panel-toggle')), findsNothing);
  });

  testWidgets('dismiss hides the strip until the problems change', (
    tester,
  ) async {
    final c = await _run([_Task('a', _ready), _Task('f', _failed)]);
    await _pump(tester, c);
    expect(find.byKey(const ValueKey('startup-panel-toggle')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('startup-panel-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('startup-panel-dismiss')));
    await tester.pump();
    expect(find.byKey(const ValueKey('startup-panel-toggle')), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ovid_startup_panel_dismissed'), 'f:failed');

    // Same problem set on the next launch stays hidden; a new one shows.
    final c2 = await _run([_Task('f', _failed)]);
    await _pump(tester, c2);
    expect(find.byKey(const ValueKey('startup-panel-toggle')), findsNothing);
    final c3 = await _run([_Task('f', _failed), _Task('g', _failed)]);
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, c3);
    expect(find.byKey(const ValueKey('startup-panel-toggle')), findsOneWidget);
  });
}
