import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/a11y/live_region.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/library/artifact_detail_page.dart';
import 'package:ovid_ai/ui/v2/onboarding/language_goal_page.dart';
import 'package:ovid_ai/ui/v2/onboarding/phone_auth_sheet.dart';
import 'package:ovid_ai/ui/v2/onboarding/sign_in_page.dart';
import 'package:ovid_ai/ui/v2/schedules/schedule_editor_page.dart';
import 'package:ovid_ai/ui/v2/schedules/schedule_runs_page.dart';
import 'package:ovid_ai/ui/v2/studio/branch_picker_sheet.dart';
import 'package:ovid_ai/ui/v2/v2_registry.dart';
import 'package:ovid_ai/ui/v2/v2_screen_entry.dart';

/// Wiring gate for every registered UI v2 screen.
///
/// Contract §8: a control is allowed only when it reaches real state. For each
/// screen this walks the whole semantics tree and fails when a node that
/// presents itself as a button, switch, chip or tap target is enabled but
/// carries no tap/long-press action. A control that cannot act must be
/// explicitly disabled (`enabled: false`) so TalkBack says so.
///
/// The second group pins the no-op handlers that cannot be seen from the
/// semantics tree alone: a handler that exists but only clears the composer,
/// shows a reason, or drops the call on the floor. Each of those controls is
/// now disabled when its owner is missing; these tests keep it that way.
void main() {
  group('registry screens have no enabled control without an action', () {
    for (final entry in v2Screens) {
      testWidgets(entry.id, (tester) async {
        tester.view.physicalSize = const Size(420, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final handle = tester.ensureSemantics();
        await _pumpScreen(tester, entry);
        final root = tester.binding.renderViews.first.owner?.semanticsOwner
            ?.rootSemanticsNode;
        final nodes = <_DeadNode>[];
        if (root != null) _flatten(_DeadNode(root, null), nodes);
        handle.dispose();

        expect(root, isNotNull, reason: '${entry.id} built no semantics tree');

        final violations = <String>[];
        for (final node in nodes) {
          final data = node.data;
          final f = data.flagsCollection;
          final hasTap = data.hasAction(SemanticsAction.tap);
          final hasLong = data.hasAction(SemanticsAction.longPress);

          // Text fields and sliders are edited, not tapped.
          if (f.isTextField || f.isSlider) continue;

          final isButton = f.isButton;
          final isLink = f.isLink;
          final isToggle =
              f.isToggled != ui.Tristate.none ||
              f.isChecked != ui.CheckedState.none;
          final isControl =
              isButton || isLink || isToggle || hasTap || hasLong;
          if (!isControl) continue;

          final label = data.label.trim().isEmpty
              ? data.tooltip.trim()
              : data.label.trim();
          final name = label.isEmpty ? 'node #${node.node.id}' : '"$label"';

          if (f.isEnabled == ui.Tristate.isFalse) {
            // Explicitly disabled: allowed, but it must not still advertise
            // an action that does nothing.
            if (hasTap || hasLong) {
              violations.add(
                'disabled control $name still exposes a tap action',
              );
            }
            continue;
          }

          // A selected-only chip is a label (the active filter, a plan badge),
          // not an action. A button or toggle must always act.
          if (!isButton && !isLink && !isToggle) {
            if (f.isSelected != ui.Tristate.none) continue;
          }

          // Shared primitives often put the label on an outer Semantics node
          // and the real InkWell/IconButton one level below. The control is
          // wired when any node in its own branch owns the gesture.
          if (!_subtreeHasAction(node)) {
            final kind = isButton
                ? 'button'
                : isLink
                ? 'link'
                : isToggle
                ? 'toggle'
                : 'tap target';
            violations.add('enabled $kind $name has no action');
          }
        }

        expect(
          violations,
          isEmpty,
          reason:
              '${entry.title} (${entry.id}) has dead controls:\n'
              '${violations.map((v) => '• $v').join('\n')}',
        );
      });
    }
  });

  group('no-op handlers are gated', () {
    testWidgets('chat send stays disabled without a send owner', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const V2ChatPage(data: V2ChatPageData()));
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();

      final send = find.bySemanticsLabel(RegExp(r'^Send$'));
      expect(send, findsOneWidget);
      expect(
        tester.getSemantics(send).getSemanticsData().flagsCollection.isEnabled,
        ui.Tristate.isFalse,
      );

      await tester.tap(send);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'hello',
        reason: 'a disabled send must not clear the draft',
      );
      expect(
        tester.widget<OLiveRegion>(find.byType(OLiveRegion)).message,
        isEmpty,
        reason: 'a disabled send must not announce "Message sent"',
      );
      handle.dispose();
    });

    testWidgets('live chat send stays disabled without a send owner', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        const V2LiveChatPage(
          data: V2LiveChatData(
            items: <V2LiveChatItem>[
              V2LiveUserMessage(id: 'u1', text: 'Build a page'),
            ],
          ),
        ),
      );
      final field = find.byType(TextField).last;
      await tester.enterText(field, 'hello');
      await tester.pump();

      final send = find.bySemanticsLabel(RegExp(r'^Send$'));
      expect(send, findsOneWidget);
      expect(
        tester.getSemantics(send).getSemanticsData().flagsCollection.isEnabled,
        ui.Tristate.isFalse,
      );

      await tester.tap(send);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, 'hello');
      handle.dispose();
    });

    testWidgets('language Continue is disabled without onContinue', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const LanguageGoalPage());
      final button = find.byKey(const Key('language-goal-continue'));
      expect(
        tester
            .getSemantics(button)
            .getSemanticsData()
            .flagsCollection
            .isEnabled,
        ui.Tristate.isFalse,
      );
      handle.dispose();
    });

    testWidgets('schedule Save is disabled without onSave', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        const ScheduleEditorPage(
          data: V2ScheduleEditorData(prompt: 'Check the news'),
        ),
      );
      final button = find.widgetWithText(OButton, 'Save');
      expect(button, findsOneWidget);
      expect(
        tester
            .getSemantics(button)
            .getSemanticsData()
            .flagsCollection
            .isEnabled,
        ui.Tristate.isFalse,
      );
      handle.dispose();
    });

    testWidgets('sign-in Continue is disabled without onSubmit', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const SignInPage());
      final button = find.byKey(const Key('sign-in-submit'));
      expect(
        tester
            .getSemantics(button)
            .getSemanticsData()
            .flagsCollection
            .isEnabled,
        ui.Tristate.isFalse,
      );
      handle.dispose();
    });

    testWidgets('phone Send is disabled without onSendCode', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        const Scaffold(body: V2PhoneAuthSheet(showHandle: false)),
      );
      await tester.enterText(
        find.byKey(const Key('phone-auth-phone')),
        '9876543210',
      );
      await tester.pump();
      final button = find.byKey(const Key('phone-auth-send'));
      expect(button, findsOneWidget);
      expect(
        tester
            .getSemantics(button)
            .getSemanticsData()
            .flagsCollection
            .isEnabled,
        ui.Tristate.isFalse,
      );
      handle.dispose();
    });

    testWidgets('branch rows are disabled without onSelectBranch', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        const Scaffold(
          body: V2BranchPickerSheet(
            data: V2BranchPickerData(
              current: V2Branch(name: 'main'),
              branches: <V2Branch>[V2Branch(name: 'release')],
            ),
            showHandle: false,
          ),
        ),
      );
      final row = find.bySemanticsLabel(RegExp(r'^release'));
      expect(row, findsOneWidget);
      final data = tester.getSemantics(row).getSemanticsData();
      expect(data.flagsCollection.isEnabled, ui.Tristate.isFalse);
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      handle.dispose();
    });

    testWidgets('artifact share does not claim a copy the host did not make', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        ArtifactDetailPage(
          data: const V2ArtifactDetailData(name: 'report.pdf'),
          onShareLink: () {},
        ),
      );
      await tester.tap(find.bySemanticsLabel('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Share link'));
      await tester.pumpAndSettle();
      expect(find.text('Link copied'), findsNothing);
      handle.dispose();
    });

    testWidgets('run retry and artifact stay disabled without owners', (
      tester,
    ) async {      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        const ScheduleRunsPage(
          data: V2ScheduleRunsData(
            groups: <V2RunGroup>[
              V2RunGroup(
                label: 'Today',
                runs: <V2ScheduleRun>[
                  V2ScheduleRun(
                    id: 'r1',
                    timeLabel: '9:00 AM',
                    status: V2RunStatus.failed,
                    summary: 'Fetch failed.',
                    artifactName: 'digest.md',
                    error: 'Timeout',
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      final retry = find.widgetWithText(OButton, 'Retry run');
      expect(retry, findsOneWidget);
      expect(
        tester
            .getSemantics(retry)
            .getSemanticsData()
            .flagsCollection
            .isEnabled,
        ui.Tristate.isFalse,
      );
      final artifact = find.bySemanticsLabel(RegExp(r'digest\.md'));
      expect(artifact, findsOneWidget);
      expect(
        tester
            .getSemantics(artifact)
            .getSemanticsData()
            .flagsCollection
            .isEnabled,
        ui.Tristate.isFalse,
      );
      handle.dispose();
    });
  });

  test('production sources contain no known dead-control patterns', () {
    // Gallery and preview adapters are test harnesses: their callbacks exist
    // only to make the component visible and are never shipped.
    const harness = <String>{
      'v2_registry.dart',
      'v2_registry_web.dart',
      'v2_preview_data.dart',
      'v2_gallery.dart',
    };
    final forbidden = <String, RegExp>{
      'null pressed handler': RegExp(r'\bonPressed\s*:\s*null\b'),
      'empty closure handler': RegExp(
        r'\b(onPressed|onTap|onChanged|onSelected|onPrimary)\s*:\s*'
        r'(?:\([^)]*\)\s*)?(?:async\s*)?\{\s*\}',
      ),
      'optional receiver in handler': RegExp(
        r'\bon(?:Pressed|Tap|Changed|Selected|Primary)\s*:\s*'
        r'\([^)]*\)\s*=>[^\n]*\?\.',
      ),
      'notReady placeholder': RegExp(r'\bnotReady\b'),
      'unavailable snackbar': RegExp(
        r'SnackBar\s*\([^)]*(?:not available|unavailable|coming soon)',
        caseSensitive: false,
        dotAll: true,
      ),
    };

    final violations = <String>[];
    final files = Directory('lib/ui/v2')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      if (harness.contains(name)) continue;
      final source = file.readAsStringSync();
      for (final entry in forbidden.entries) {
        for (final match in entry.value.allMatches(source)) {
          final line = '\n'.allMatches(source.substring(0, match.start)).length;
          violations.add(
            '${file.path}:${line + 1}: ${entry.key}: '
            '${match.group(0)!.replaceAll('\n', ' ')}',
          );
        }
      }
    }

    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}

Future<void> _pumpScreen(WidgetTester tester, V2ScreenEntry entry) async {
  Widget child = Builder(builder: entry.builder);
  if (entry.isSheet) child = Scaffold(body: child);
  await _pump(tester, child);
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: OTheme.light(),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(420, 900)),
        child: child,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void _flatten(_DeadNode node, List<_DeadNode> out) {
  out.add(node);
  for (final child in node.children) {
    _flatten(child, out);
  }
}

bool _subtreeHasAction(_DeadNode node) {
  if (node.data.hasAction(SemanticsAction.tap) ||
      node.data.hasAction(SemanticsAction.longPress)) {
    return true;
  }
  return node.children.any(_subtreeHasAction);
}

class _DeadNode {
  _DeadNode(this.node, this.parent) : data = node.getSemanticsData() {
    node.visitChildren((child) {
      children.add(_DeadNode(child, this));
      return true;
    });
  }

  final SemanticsNode node;
  final _DeadNode? parent;
  final List<_DeadNode> children = <_DeadNode>[];
  final SemanticsData data;
}
