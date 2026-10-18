import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ovid_ai/core/cloud/cloud_ws.dart';
import 'package:ovid_ai/core/cloud/studio_pty.dart';
import 'package:ovid_ai/core/cloud/studio_remote_client.dart';
import 'package:ovid_ai/core/github_service.dart';
import 'package:ovid_ai/core/state.dart';
import 'package:ovid_ai/core/studio_drafts.dart';
import 'package:ovid_ai/core/theme.dart';
import 'package:ovid_ai/ui/studio_layout.dart';
import 'package:ovid_ai/ui/studio_screen.dart';
import 'package:ovid_ai/ui/studio_terminal_tabs.dart';

import 'support/studio_fake_gateway.dart';

/// Studio accessibility, re-pointed at the P7 workspace API.
///
/// The screen-level invariants survive the thin-client move: every interactive
/// control is at least 44dp and labelled, the auth badge is not colour-only,
/// and the main regions are exposed to screen readers. The removed local-sync
/// progress live region (RepoCache) is not tested.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStudioGateway fake;
  late StudioRemoteClient remote;

  WsMultiplexer idleWs() => WsMultiplexer(
        mintTicket: () async => 'ticket',
        heartbeatInterval: const Duration(hours: 1),
        pongTimeout: const Duration(hours: 1),
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppState.resetTestInstance();
    StudioDraftStore.I.disableForTest();
    studioLoginPromptOverrideForTest = (_) {};
    studioPtyChannelFactoryOverrideForTest = (sessionId, tabId) =>
        CloudPtyChannel(
          sessionId: sessionId,
          tabId: tabId,
          ws: idleWs(),
          rawFramesOverride: const Stream<Map<String, dynamic>>.empty(),
          sendOverride: (_) async {},
        );
    final app = AppState.createForTest();
    app.sessions.add(ChatSession(
      id: kFakeStudioSession,
      title: 'Studio',
      model: 'gpt-4o',
    ));
    app.activeSessionId = kFakeStudioSession;
    await GitHubService.I.initialize();
    GitHubService.I.setTokenForTest('tok');

    fake = FakeStudioGateway(
      files: {
        'lib/a.dart': 'void a() {}',
        'README.md': '# hi',
      },
      roots: [
        FakeNode.dir('lib', [FakeNode.file('lib/a.dart')]),
        FakeNode.file('README.md'),
      ],
    );
    remote = installFakeStudio(fake);
    await remote.openStudioFile(kFakeStudioSession, 'lib/a.dart');
  });

  tearDown(() async {
    studioLoginPromptOverrideForTest = null;
    studioPtyChannelFactoryOverrideForTest = null;
    remote.clearAll();
    StudioDraftStore.I.disableForTest();
    await GitHubService.I.signOut();
    AppState.resetTestInstance();
  });

  void setSurface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpStudio(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(theme: Aether.theme(), home: const StudioScreen()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
  }

  /// Measures every element a finder resolves to.
  void expectTargets(
    WidgetTester tester,
    Finder finder,
    String what, {
    String Function(Element e)? describe,
  }) {
    final elements = finder.evaluate().toList();
    expect(elements, isNotEmpty, reason: '$what: nothing to measure');
    for (final e in elements) {
      final box = e.renderObject;
      expect(box, isA<RenderBox>(), reason: '$what has no render box');
      final size = (box! as RenderBox).size;
      final who = describe == null ? what : '$what ${describe(e)}';
      expect(size.width, greaterThanOrEqualTo(kStudioTapTarget),
          reason: '$who is ${size.width}px wide');
      expect(size.height, greaterThanOrEqualTo(kStudioTapTarget),
          reason: '$who is ${size.height}px tall');
    }
  }

  String buttonName(Element e) {
    final w = e.widget;
    if (w is StudioIconButton) return '"${w.tooltip}"';
    final tip = e.findAncestorWidgetOfExactType<Tooltip>();
    return tip == null ? '' : '"${tip.message}"';
  }

  List<String> semanticLabels(WidgetTester tester) => tester
      .widgetList<Semantics>(find.byType(Semantics))
      .map((s) => s.properties.label ?? '')
      .where((l) => l.isNotEmpty)
      .toList();

  group('44dp tap targets', () {
    testWidgets('every icon button on the screen clears 44dp', (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);
      expectTargets(tester, find.byType(StudioIconButton), 'icon button',
          describe: buttonName);
    });

    testWidgets('every icon button carries a label', (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);
      final buttons = tester
          .widgetList<StudioIconButton>(find.byType(StudioIconButton))
          .toList();
      expect(buttons, isNotEmpty);
      for (final b in buttons) {
        expect(b.tooltip.trim(), isNotEmpty,
            reason: 'an unlabelled icon button is invisible to TalkBack');
      }
    });

    testWidgets('editor tabs and their close buttons clear 44dp',
        (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);
      expectTargets(tester, find.byType(StudioTapTarget), 'tap target');
      expectTargets(
        tester,
        find.byTooltip('Close tab a.dart'),
        'tab close button',
      );
    });

    testWidgets('file-tree rows clear 44dp', (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);
      final row = find.text('README.md');
      expect(row, findsOneWidget);
      final box = tester.renderObject<RenderBox>(
        find.ancestor(of: row, matching: find.byType(StudioTapTarget)).first,
      );
      expect(box.size.height, greaterThanOrEqualTo(kStudioTapTarget),
          reason: 'tree rows measured ~25dp');
    });

    testWidgets('the terminal strip and its close buttons clear 44dp',
        (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);
      final strip = tester.getSize(find.byKey(studioTerminalHandleKey));
      expect(strip.height, greaterThanOrEqualTo(kStudioTapTarget),
          reason: 'the terminal strip was a fixed 30px');
      expectTargets(
        tester,
        find.byTooltip('Close terminal 1'),
        'terminal close button',
        describe: buttonName,
      );
    });

    testWidgets('the account chip clears 44dp', (tester) async {
      setSurface(tester, const Size(360, 640));
      await pumpStudio(tester);
      expectTargets(
        tester,
        find.byTooltip('GitHub account'),
        'account chip',
        describe: buttonName,
      );
    });

    testWidgets('targets still clear 44dp on a phone', (tester) async {
      setSurface(tester, const Size(360, 640));
      await pumpStudio(tester);
      expectTargets(tester, find.byType(StudioIconButton), 'icon button',
          describe: buttonName);
      expectTargets(tester, find.byType(StudioTapTarget), 'tap target');
    });
  });

  group('the auth badge is not colour-only', () {
    Finder badgeIcon(String tooltip, IconData icon) => find.descendant(
          of: find.byTooltip(tooltip),
          matching: find.byIcon(icon),
        );

    testWidgets('signed in: its own shape and a semantics label',
        (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);

      expect(badgeIcon('Signed in to GitHub', Icons.check_circle),
          findsOneWidget);
      expect(semanticLabels(tester), contains('Signed in to GitHub'));
    });

    testWidgets('signed out: a different shape, not just a different colour',
        (tester) async {
      GitHubService.I.setTokenForTest(null);
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);

      expect(badgeIcon('Not signed in to GitHub', Icons.cancel),
          findsOneWidget);
      expect(badgeIcon('Not signed in to GitHub', Icons.check_circle),
          findsNothing);
      expect(semanticLabels(tester), contains('Not signed in to GitHub'));
    });
  });

  group('screen-reader coverage', () {
    testWidgets('the main regions are labelled', (tester) async {
      setSurface(tester, const Size(1200, 900));
      await pumpStudio(tester);

      final labels = semanticLabels(tester);
      expect(labels.any((l) => l.startsWith('Terminal panel')), isTrue);
      expect(labels.any((l) => l.contains('Editing lib/a.dart')), isTrue);
      expect(labels, contains('Signed in to GitHub'));
    });
  });

  group('type floor', () {
    test('no Studio text renders below 12px', () {
      for (final path in const [
        'lib/ui/studio_screen.dart',
        'lib/ui/studio_layout.dart',
        'lib/ui/studio_editor.dart',
        'lib/ui/studio_file_tree.dart',
        'lib/ui/github_login_sheet.dart',
      ]) {
        final src = File(path).readAsStringSync();
        for (final m in RegExp(r'fontSize:\s*([0-9.]+)').allMatches(src)) {
          final size = double.parse(m.group(1)!);
          expect(size, greaterThanOrEqualTo(kStudioMinFontSize),
              reason: '$path renders ${m.group(1)}px at offset ${m.start}');
        }
      }
    });

    test('every monospace style carries a real monospace fallback', () {
      for (final path in const [
        'lib/ui/studio_screen.dart',
        'lib/ui/studio_editor.dart',
        'lib/ui/studio_file_tree.dart',
        'lib/ui/studio_terminal_tabs.dart',
      ]) {
        final src = File(path).readAsStringSync();
        final mono = 'fontFamily: Aether.mono'.allMatches(src).length;
        final fallback = 'fontFamilyFallback: kStudioMonoFallback'
            .allMatches(src)
            .length;
        expect(fallback, mono,
            reason: '$path has $mono monospace styles but $fallback fallbacks '
                '(Aether.mono is not bundled in pubspec.yaml)');
        expect(mono, greaterThan(0), reason: '$path lost its mono styles');
      }
    });

    test('the login sheet stopped leaking poll infra detail', () {
      final src = File('lib/ui/github_login_sheet.dart').readAsStringSync();
      expect(src, isNot(contains('poll #')));
    });
  });

  group('responsive and accessible by construction', () {
    test('the screen resolves its layout from the viewport', () {
      final src = File('lib/ui/studio_screen.dart').readAsStringSync();
      expect(src, contains('LayoutBuilder('));
      expect(src, contains('MediaQuery.'));
      expect(src, contains('StudioMetrics.of('));
      expect(src, contains('Semantics('),
          reason: 'the screen had zero Semantics widgets');
    });

    test('the code editor refuses IME "help"', () {
      final src = File('lib/ui/studio_editor.dart').readAsStringSync();
      expect(src, contains('autocorrect: false'));
      expect(src, contains('enableSuggestions: false'));
      expect(src, contains('SmartQuotesType.disabled'));
      expect(src, contains('SmartDashesType.disabled'));
    });
  });

  group('duplication and error copy', () {
    test('the picker is gone and sheets/toasts go through the helpers', () {
      final src = File('lib/ui/studio_screen.dart').readAsStringSync();
      expect(src, isNot(contains('getDirectoryPath')));
      expect(src, isNot(contains('Radius.circular(18)')),
          reason: 'sheets were 18 in two places and 20 in two others');
      expect(src, isNot(contains('showModalBottomSheet')),
          reason: 'every sheet must go through showStudioSheet');
      expect(src, isNot(contains('ScaffoldMessenger')),
          reason: 'inline snackbars bypassed the toast helper');
    });

    test('raw exception strings never reach a headline', () {
      final src = File('lib/ui/studio_screen.dart').readAsStringSync();
      for (final banned in [
        r'Repo sync failed: $e',
        r'Clone failed: $e',
        r'Repo list failed: $e',
        r'Branch list failed: $e',
        r'Sync failed: $_syncError',
      ]) {
        expect(src, isNot(contains(banned)), reason: 'raw "$banned" survived');
      }
      expect(src, contains('StudioFailure.of('));
    });
  });
}
