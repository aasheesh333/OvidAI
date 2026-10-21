import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/v2_registry.dart';

/// TalkBack semantics gate for every registered UI v2 screen.
///
/// For each screen, in light and dark at the smallest supported width
/// (320 dp) with 200 % text, this walks the whole semantics tree and checks:
///
///  * every interactive node has an accessible name;
///  * every interactive node announces an enabled state (true or false);
///  * no single node repeats the same label segment;
///  * every image node has a label.
///
/// Interactive means a control flag (button, link, text field, slider,
/// toggled/checked/selected) or a manipulation action (tap, long press,
/// increase/decrease). Read-only progress bars and decorative text are not
/// controls.
///
/// Accessible names may be inherited from a labelled interactive ancestor.
/// Shared primitives such as `OButton` currently emit an outer labelled `Semantics` node plus an
/// inner tap target; the inner node has no text of its own but is announced
/// with the outer name. Inheriting the name anchors the check on what TalkBack
/// reads, while still failing any control whose branch has no name at all.
///
/// Known gaps are explicit and must stay live: an unused entry fails the gate,
/// so fixing a screen forces its debt to be removed here. See
/// `docs/qa/TALKBACK_CHECKLIST.md` for the rationale and owner of each gap.
void main() {
  for (final entry in v2Screens) {
    for (final dark in [false, true]) {
      final theme = dark ? 'dark' : 'light';
      testWidgets('${entry.id} semantics ($theme)', (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final handle = tester.ensureSemantics();

        Widget child = Builder(builder: entry.builder);
        if (entry.isSheet) {
          child = Scaffold(body: child);
        }
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? OTheme.dark() : OTheme.light(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: child,
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        final root = tester.binding.renderViews.first.owner?.semanticsOwner
            ?.rootSemanticsNode;
        final nodes = <_AuditNode>[];
        if (root != null) {
          _flatten(_AuditNode(root, null), nodes);
        }
        handle.dispose();

        expect(
          root,
          isNotNull,
          reason: '${entry.id} ($theme) did not build a semantics tree',
        );

        final usedSkips = <_KnownGap>{};
        final violations = <String>[];

        void skipOrFlag(
          _GapKind kind,
          String label,
          SemanticsData data,
          String message,
        ) {
          final gap = _skipFor(entry.id, kind, label, data);
          if (gap != null) {
            usedSkips.add(gap);
            return;
          }
          violations.add(message);
        }

        for (final n in nodes) {
          final data = n.data;
          final label = data.label.trim();

          if (data.flagsCollection.isImage && label.isEmpty) {
            violations.add(
              'image without a label: node #${n.node.id} '
              '(${_describe(data)})',
            );
          }

          if (n.isInteractive) {
            if (n.accessibleName.isEmpty) {
              skipOrFlag(
                _GapKind.unlabeled,
                label,
                data,
                'unlabelled interactive node: #${n.node.id} '
                    '(${_describe(data)})',
              );
            }
            if (!n.announcesEnabled) {
              skipOrFlag(
                _GapKind.enabled,
                label,
                data,
                'interactive node does not announce enabled state: '
                    '#${n.node.id} "$label" (${_describe(data)})',
              );
            }
          }

          final duplicate = _duplicateSegment(data.label);
          if (duplicate != null) {
            skipOrFlag(
              _GapKind.duplicate,
              data.label,
              data,
              'node #${n.node.id} repeats "$duplicate" in its label: '
                  '"${data.label.replaceAll('\n', r'\n')}"',
            );
          }
        }

        for (final gap in _knownGaps.where((g) => g.screen == entry.id)) {
          if (!usedSkips.contains(gap)) {
            violations.add(
              'stale skip for ${gap.kind.name} "${gap.label ?? '<structural>'}" '
              '— ${gap.reason} The gap is fixed or the match is wrong.',
            );
          }
        }

        expect(
          violations,
          isEmpty,
          reason:
              '${entry.title} (${entry.id}) at 320 dp / 200 % in $theme:\n'
              '${violations.map((v) => '• $v').join('\n')}',
        );
      });
    }
  }

  test('duplicate label detector catches repeated segments', () {
    expect(_duplicateSegment('Search\nSearch'), 'Search');
    expect(_duplicateSegment('Privacy policy\nTerms of service'), isNull);
    expect(_duplicateSegment('Ready\n•\n•'), '•');
    expect(_duplicateSegment(''), isNull);
  });
}

void _flatten(_AuditNode node, List<_AuditNode> out) {
  out.add(node);
  for (final child in node.children) {
    _flatten(child, out);
  }
}

String? _duplicateSegment(String label) {
  final seen = <String>{};
  for (final raw in label.split('\n')) {
    final segment = raw.trim();
    if (segment.isEmpty) continue;
    if (!seen.add(segment)) return segment;
  }
  return null;
}

_KnownGap? _skipFor(
  String screen,
  _GapKind kind,
  String label,
  SemanticsData data,
) {
  for (final gap in _knownGaps) {
    if (gap.screen != screen) continue;
    if (gap.kind != kind) continue;
    if (gap.label == null) {
      if (label.isEmpty && gap.signature.matches(data)) return gap;
      continue;
    }
    if (gap.label == label) return gap;
  }
  return null;
}

String _describe(SemanticsData data) {
  final flags = data.flagsCollection;
  final parts = <String>[
    if (flags.isButton) 'button',
    if (flags.isLink) 'link',
    if (flags.isTextField) 'textField',
    if (flags.isSlider) 'slider',
    if (flags.isImage) 'image',
    if (flags.isToggled != ui.Tristate.none) 'toggled=${flags.isToggled.name}',
    if (flags.isChecked != ui.CheckedState.none)
      'checked=${flags.isChecked.name}',
    if (flags.isSelected != ui.Tristate.none)
      'selected=${flags.isSelected.name}',
    if (flags.isEnabled != ui.Tristate.none)
      'enabled=${flags.isEnabled.name}',
    if (data.hasAction(SemanticsAction.tap)) 'tap',
    if (data.hasAction(SemanticsAction.longPress)) 'longPress',
  ];
  return parts.isEmpty ? 'no flags' : parts.join(', ');
}

class _AuditNode {
  _AuditNode(this.node, this.parent) : data = node.getSemanticsData() {
    node.visitChildren((child) {
      children.add(_AuditNode(child, this));
      return true;
    });
  }

  final SemanticsNode node;
  final _AuditNode? parent;
  final List<_AuditNode> children = <_AuditNode>[];
  final SemanticsData data;

  bool get isInteractive {
    final f = data.flagsCollection;
    return f.isButton ||
        f.isLink ||
        f.isTextField ||
        f.isSlider ||
        f.isToggled != ui.Tristate.none ||
        f.isChecked != ui.CheckedState.none ||
        f.isSelected != ui.Tristate.none ||
        f.isInMutuallyExclusiveGroup ||
        data.hasAction(SemanticsAction.tap) ||
        data.hasAction(SemanticsAction.longPress) ||
        data.hasAction(SemanticsAction.increase) ||
        data.hasAction(SemanticsAction.decrease);
  }

  String get _ownName {
    final label = data.label.trim();
    if (label.isNotEmpty) return label;
    return data.tooltip.trim();
  }

  String get accessibleName {
    if (_ownName.isNotEmpty) return _ownName;
    // Only an interactive ancestor can lend its name: that is the shared
    // primitive's outer labelled Semantics node wrapping an inner tap target.
    for (var p = parent; p != null; p = p.parent) {
      if (p._ownName.isNotEmpty && p.isInteractive) return p._ownName;
    }
    return '';
  }

  bool get _ownEnabled => data.flagsCollection.isEnabled != ui.Tristate.none;

  bool get announcesEnabled =>
      _ownEnabled || _ancestorEnabled || _descendantEnabled;

  bool get _ancestorEnabled {
    var p = parent;
    while (p != null) {
      if (p._ownEnabled) return true;
      p = p.parent;
    }
    return false;
  }

  bool get _descendantEnabled =>
      children.any((c) => c._ownEnabled || c._descendantEnabled);
}

enum _GapKind { unlabeled, enabled, duplicate }

/// Shape check for structural skip entries. A null label alone is too broad:
/// a new nameless control in the same screen would be silently skipped.
enum _GapSignature {
  none,
  tapWrapper,
  toggle;

  bool matches(SemanticsData data) {
    final f = data.flagsCollection;
    final hasToggleState =
        f.isToggled != ui.Tristate.none || f.isChecked != ui.CheckedState.none;
    switch (this) {
      case _GapSignature.none:
        return false;
      case _GapSignature.tapWrapper:
        return !f.isButton &&
            !f.isLink &&
            !f.isTextField &&
            !f.isSlider &&
            f.isSelected == ui.Tristate.none &&
            !hasToggleState &&
            !f.isInMutuallyExclusiveGroup &&
            data.hasAction(SemanticsAction.tap);
      case _GapSignature.toggle:
        return hasToggleState;
    }
  }
}

/// Documented exceptions. Each entry must be observed by the test; an unused
/// entry fails so the debt cannot silently outlive the fix.
class _KnownGap {
  const _KnownGap(
    this.screen,
    this.kind,
    this.label,
    this.reason, {
    this.signature = _GapSignature.none,
  });

  final String screen;
  final _GapKind kind;

  /// Exact node label, or `null` for an empty structural wrapper.
  final String? label;
  final String reason;

  /// Required shape when [label] is null.
  final _GapSignature signature;
}

const _knownGaps = <_KnownGap>[
  // Full-screen tap bridge that dismisses the keyboard. It is not a visible
  // control and has no label or enabled state of its own.
  _KnownGap(
    'sign_in',
    _GapKind.unlabeled,
    null,
    'Keyboard-dismiss bridge (no visible target).',
    signature: _GapSignature.tapWrapper,
  ),
  _KnownGap(
    'add_connector',
    _GapKind.unlabeled,
    null,
    'Keyboard-dismiss bridge (no visible target).',
    signature: _GapSignature.tapWrapper,
  ),

  // Inline switch in a labelled OListRow; the row owns the name, the switch
  // node is emitted separately with no name.
  _KnownGap(
    'session_actions',
    _GapKind.unlabeled,
    null,
    'Pin switch has no name of its own; the row carries the label.',
    signature: _GapSignature.toggle,
  ),

  // OSelectable does not set hasEnabledState on sheet tiles.
  _KnownGap(
    'model_chip',
    _GapKind.enabled,
    'Auto, Included free',
    'OSelectable does not announce enabled; selected is announced.',
  ),
  _KnownGap(
    'model_chip',
    _GapKind.enabled,
    'Manage models',
    'OSelectable does not announce enabled; selected is announced.',
  ),
  _KnownGap(
    'model_chip',
    _GapKind.enabled,
    'Compare plans, From \$18/mo',
    'OSelectable does not announce enabled; selected is announced.',
  ),

  // OListRow merges its label with the child text, so TalkBack repeats it.
  _KnownGap(
    'sidebar',
    _GapKind.duplicate,
    'Profile, Ovid user, Free plan\nOvid user\nOU\nOvid user\nFree plan',
    'OListRow merges label and child text (profile row).',
  ),
  _KnownGap(
    'session_actions',
    _GapKind.duplicate,
    'Rename chat\nRename chat',
    'OListRow merges label and child text.',
  ),
  _KnownGap(
    'session_actions',
    _GapKind.duplicate,
    'Move to project\nMove to project',
    'OListRow merges label and child text.',
  ),
  _KnownGap(
    'session_actions',
    _GapKind.duplicate,
    'Duplicate chat\nDuplicate chat\nBranch',
    'OListRow merges label and child text.',
  ),
  _KnownGap(
    'repo_picker',
    _GapKind.duplicate,
    'G\nG',
    'Avatar initials are merged with the avatar label.',
  ),
  _KnownGap(
    'browser',
    _GapKind.duplicate,
    'Action log\nAction log',
    'OListRow merges label and child text.',
  ),
  _KnownGap(
    'artifact_detail',
    _GapKind.duplicate,
    'Ready\n•\n•',
    'Decorative status bullets are merged into the status label.',
  ),
  _KnownGap(
    'account_health',
    _GapKind.duplicate,
    'Email verification\nEmail verification\nVerified',
    'Row title is merged with the status chip text.',
  ),
  _KnownGap(
    'about',
    _GapKind.duplicate,
    'Privacy policy\nPrivacy policy',
    'OListRow merges label and child text.',
  ),
  _KnownGap(
    'about',
    _GapKind.duplicate,
    'Terms of service\nTerms of service',
    'OListRow merges label and child text.',
  ),
  _KnownGap(
    'about',
    _GapKind.duplicate,
    'Open-source licences\nOpen-source licences',
    'OListRow merges label and child text.',
  ),
];
