import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/app_lock.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_motion.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/a11y/live_region.dart';
import 'package:ovid_ai/ui/v2/app/app_lock_gate.dart';
import 'package:ovid_ai/ui/v2/chat/chat_page.dart';
import 'package:ovid_ai/ui/v2/chat/live_chat_page.dart';
import 'package:ovid_ai/ui/v2/settings/settings_hub.dart';
import 'package:ovid_ai/ui/v2/sidebar/sidebar.dart';
import 'package:ovid_ai/ui/v2/v2_registry.dart';
import 'package:ovid_ai/ui/v2/v2_screen_entry.dart';

/// TalkBack semantics gate for every registered UI v2 screen.
///
/// For each screen, in light and dark at the smallest supported width
/// (320 dp) with 200 % text, this walks the whole semantics tree and checks:
///
///  * every interactive node has an accessible name;
///  * every interactive node announces an enabled state (true or false);
///  * every disabled control announces disabled, not just greyed;
///  * every toggle/switch announces its checked/toggled state;
///  * headings are marked as headers (section labels, app-bar titles and
///    large page titles);
///  * no single node repeats the same label segment;
///  * two different actions never expose the same label on one screen;
///  * every image node has a label and decorative images are excluded.
///
/// Interactive means a control flag (button, link, text field, slider,
/// toggled/checked/selected) or a manipulation action (tap, long press,
/// increase/decrease). Read-only progress bars and decorative text are not
/// controls.
///
/// Accessible names may be inherited from a labelled interactive ancestor.
/// Shared primitives such as `OButton` emit an outer labelled `Semantics` node
/// plus an inner tap target; the inner node has no text of its own but is
/// announced with the outer name. Inheriting the name anchors the check on what
/// TalkBack reads, while still failing any control whose branch has no name at
/// all.
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

        await _pumpScreen(tester, entry, dark: dark);

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

        _checkHeadings(tester, nodes, violations);
        _checkToggles(tester, violations);
        _checkDisabledControls(tester, nodes, violations);
        _checkDecorativeImages(tester, violations);
        _checkDuplicateActions(nodes, violations, skipOrFlag);

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

  group('TalkBack reading order', () {
    testWidgets('chat reads top bar → content → composer', (tester) async {
      await _pump(
        tester,
        const V2ChatPage(data: V2ChatPageData()),
      );
      final order = _readingOrder(tester);
      _expectOrder(order, <String>[
        'Ovid Si',
        'What should we build?',
        'Build a landing page',
        'Add attachment or action',
        'Send',
      ]);
    });

    testWidgets('sidebar reads profile → actions → content → footer', (
      tester,
    ) async {
      await _pump(
        tester,
        const Sidebar(data: V2SidebarData(name: 'Ovid user')),
      );
      final order = _readingOrder(tester);
      _expectOrder(order, <String>[
        'Profile, Ovid user, Free plan',
        'New chat',
        'Search',
        'No chats yet',
        'Settings',
      ]);
    });

    testWidgets('settings hub reads app bar → profile → sections → log out', (
      tester,
    ) async {
      await _pump(
        tester,
        SettingsHubPage(
          data: V2SettingsHubData(
            profile: const V2SettingsProfile(
              name: 'Ovid user',
              email: 'ovid@example.com',
            ),
            account: V2SettingsSection(
              title: 'Account',
              items: <V2SettingsItem>[
                V2SettingsItem(
                  id: 'account',
                  label: 'Account',
                  icon: Icons.person_outline_rounded,
                  onTap: () {},
                ),
              ],
            ),
            chat: V2SettingsSection(
              title: 'Chat',
              items: <V2SettingsItem>[
                V2SettingsItem(
                  id: 'appearance',
                  label: 'Appearance',
                  icon: Icons.palette_outlined,
                  onTap: () {},
                ),
              ],
            ),
            models: V2SettingsSection(
              title: 'Models',
              items: <V2SettingsItem>[
                V2SettingsItem(
                  id: 'connectors',
                  label: 'Connectors',
                  icon: Icons.extension_outlined,
                  onTap: () {},
                ),
              ],
            ),
            dataControl: V2SettingsSection(
              title: 'Data control',
              items: <V2SettingsItem>[
                V2SettingsItem(
                  id: 'storage',
                  label: 'Storage',
                  icon: Icons.storage_outlined,
                  onTap: () {},
                ),
              ],
            ),
            advanced: V2SettingsSection(
              title: 'Advanced',
              items: <V2SettingsItem>[
                V2SettingsItem(
                  id: 'about',
                  label: 'About',
                  icon: Icons.info_outline_rounded,
                  onTap: () {},
                ),
              ],
            ),
            onSignOut: () {},
            onProfileTap: () {},
          ),
        ),
      );
      final order = _readingOrder(tester);
      // The profile replaces the separate "Account" destination, so it reads
      // under the ACCOUNT heading; sign out is the short label.
      _expectOrder(order, <String>[
        'Settings',
        'ACCOUNT',
        'Ovid user profile photo',
        'CHAT',
        'Appearance',
        'MODELS',
        'Connectors',
        'DATA CONTROL',
        'Storage',
        'ADVANCED',
        'About',
        'Sign out',
      ]);
    });
  });

  group('Audit detectors', () {
    testWidgets('duplicate-action detector flags two same-labelled controls', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        Scaffold(
          body: Column(
            children: <Widget>[
              OIconButton(
                icon: Icons.add_rounded,
                semanticLabel: 'Add',
                onPressed: () {},
              ),
              OIconButton(
                icon: Icons.add_rounded,
                semanticLabel: 'Add',
                onPressed: () {},
              ),
            ],
          ),
        ),
      );
      final root = tester.binding.renderViews.first.owner?.semanticsOwner
          ?.rootSemanticsNode;
      final nodes = <_AuditNode>[];
      if (root != null) _flatten(_AuditNode(root, null), nodes);
      final violations = <String>[];
      _checkDuplicateActions(
        nodes,
        violations,
        (kind, label, data, message) => violations.add(message),
      );
      handle.dispose();
      expect(
        violations.any((v) => v.contains('different actions share the label')),
        isTrue,
        reason: violations.join('\n'),
      );
    });

    testWidgets('decorative image detector flags an exposed unlabelled Image', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        Scaffold(
          body: Image(
            image: const AssetImage('assets/does-not-exist.png'),
            errorBuilder: (context, error, stack) => const SizedBox.shrink(),
          ),
        ),
      );
      final violations = <String>[];
      _checkDecorativeImages(tester, violations);
      handle.dispose();
      expect(violations, isNotEmpty);
    });
  });

  group('Control semantics', () {
    V2SettingsHubData hub({ValueChanged<bool>? onReasoningChanged}) =>
        V2SettingsHubData(
          chat: V2SettingsSection(
            title: 'Chat',
            items: <V2SettingsItem>[
              const V2SettingsItem(
                id: 'show_reasoning',
                label: 'Show reasoning',
                subtitle: 'Explain each step',
                icon: Icons.psychology_outlined,
              ),
            ],
          ),
          showReasoning: true,
          onReasoningChanged: onReasoningChanged,
        );

    testWidgets('a switch announces its checked state and enabled state', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, SettingsHubPage(data: hub(onReasoningChanged: (_) {})));
      final semantics = tester.getSemantics(find.byType(Switch));
      final flags = semantics.getSemanticsData().flagsCollection;
      expect(flags.isToggled, ui.Tristate.isTrue);
      expect(flags.isEnabled, ui.Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('a toggle without a handler is not rendered', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, SettingsHubPage(data: hub()));
      // A switch the host never wired cannot act, so the hub removes the row
      // instead of leaving a dead control on screen.
      expect(find.byType(Switch), findsNothing);
      expect(find.text('Show reasoning'), findsNothing);
      handle.dispose();
    });

    testWidgets('a temporarily disabled switch announces disabled', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        SettingsHubPage(
          data: V2SettingsHubData(
            chat: const V2SettingsSection(
              title: 'Chat',
              items: <V2SettingsItem>[
                V2SettingsItem(
                  id: 'show_reasoning',
                  label: 'Show reasoning',
                  icon: Icons.psychology_outlined,
                  enabled: false,
                ),
              ],
            ),
            onReasoningChanged: (_) {},
          ),
        ),
      );
      final semantics = tester.getSemantics(find.byType(Switch));
      final flags = semantics.getSemanticsData().flagsCollection;
      expect(flags.isToggled, ui.Tristate.isTrue);
      expect(flags.isEnabled, ui.Tristate.isFalse);
      handle.dispose();
    });

    testWidgets('icon-only controls expose their label', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, SettingsHubPage(data: hub()));
      expect(find.bySemanticsLabel('Search settings'), findsOneWidget);
      handle.dispose();
    });
  });

  group('Lock screen privacy', () {
    testWidgets('locked semantics never expose the protected content', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: AppLockGate(
            lock: _StubLock(locked: true),
            child: const Scaffold(
              body: Center(child: Text('TOP SECRET CHAT CONTENT')),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final labels = _semanticsLabels(tester);
      handle.dispose();

      expect(labels, contains('App locked'));
      expect(labels, contains('PIN entry, 0 of 6 digits'));
      expect(
        labels.any((label) => label.contains('TOP SECRET')),
        isFalse,
        reason: 'the locked screen leaked protected content: $labels',
      );
      expect(
        labels.any((label) => label.contains('CHAT CONTENT')),
        isFalse,
        reason: 'the locked screen leaked protected content: $labels',
      );
    });

    testWidgets('unlocked semantics do expose the content', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: AppLockGate(
            lock: _StubLock(locked: false),
            child: const Scaffold(
              body: Center(child: Text('TOP SECRET CHAT CONTENT')),
            ),
          ),
        ),
      );
      await tester.pump();

      final labels = _semanticsLabels(tester);
      handle.dispose();

      expect(labels.any((label) => label.contains('TOP SECRET')), isTrue);
      expect(labels, isNot(contains('App locked')));
    });
  });

  group('Live-region announcements', () {
    testWidgets('queued message and sent message are announced', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      Widget page({required int queued, ValueChanged<String>? onSend}) =>
          MaterialApp(
            theme: OTheme.light(),
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 640),
                textScaler: TextScaler.linear(2),
              ),
              child: V2ChatPage(
                data: V2ChatPageData(queuedCount: queued),
                onSend: onSend,
              ),
            ),
          );

      await tester.pumpWidget(page(queued: 0));
      await tester.pump();
      expect(
        tester.widget<OLiveRegion>(find.byType(OLiveRegion)).message,
        isEmpty,
      );

      await tester.pumpWidget(page(queued: 1));
      await tester.pump();
      expect(
        tester.widget<OLiveRegion>(find.byType(OLiveRegion)).message,
        'Message queued',
      );

      // The dock itself is a live region, so a queue that appears while the
      // screen is already open is announced too.
      final dock = tester.getSemantics(find.text('1 queued'));
      expect(dock.getSemanticsData().flagsCollection.isLiveRegion, isTrue);

      await tester.pumpWidget(page(queued: 0, onSend: (_) {}));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Send$')));
      await tester.pump();

      expect(
        tester.widget<OLiveRegion>(find.byType(OLiveRegion)).message,
        'Message sent',
      );
      handle.dispose();
    });

    testWidgets('a finished run is announced', (tester) async {
      final handle = tester.ensureSemantics();
      Widget page({required bool running}) => MaterialApp(
        theme: OTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: V2LiveChatPage(
            data: V2LiveChatData(
              running: running,
              items: const <V2LiveChatItem>[
                V2LiveUserMessage(id: 'u1', text: 'Build a page'),
              ],
            ),
          ),
        ),
      );

      await tester.pumpWidget(page(running: true));
      await tester.pump();
      await tester.pumpWidget(page(running: false));
      await tester.pump();

      expect(
        tester.widget<OLiveRegion>(find.byType(OLiveRegion)).message,
        'Run finished',
      );
      handle.dispose();
    });
  });
}

Future<void> _pumpScreen(
  WidgetTester tester,
  V2ScreenEntry entry, {
  required bool dark,
}) async {
  Widget child = Builder(builder: entry.builder);
  if (entry.isSheet) {
    child = Scaffold(body: child);
  }
  await _pump(tester, child, dark: dark);
}

Future<void> _pump(WidgetTester tester, Widget child, {bool dark = false}) async {
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
}

void _checkHeadings(
  WidgetTester tester,
  List<_AuditNode> nodes,
  List<String> violations,
) {
  final headers = nodes
      .where(
        (n) =>
            n.data.flagsCollection.isHeader && n.data.label.trim().isNotEmpty,
      )
      .toList();
  if (headers.isEmpty) {
    violations.add('no heading is marked as a header');
  }

  // Every section label rendered by the shared primitive must be a header.
  for (final section in tester.widgetList<OSectionHeader>(
    find.byType(OSectionHeader),
  )) {
    final label = section.label.toUpperCase();
    final labelled = nodes
        .where((n) => n.data.label.trim().startsWith(label))
        .toList();
    // A section below the fold at 320 dp / 200 % may not contribute a
    // semantics node yet; there is nothing to read, so nothing to mark.
    if (labelled.isEmpty) continue;
    if (!labelled.any((n) => n.data.flagsCollection.isHeader)) {
      violations.add('section heading "$label" is not marked as a header');
    }
  }

  // The standard app bar title is the screen heading.
  for (final appBar in tester.widgetList<OAppBar>(find.byType(OAppBar))) {
    final marked = headers.any(
      (n) => n.data.label.trim().startsWith(appBar.title),
    );
    if (!marked) {
      violations.add(
        'app bar title "${appBar.title}" is not marked as a header',
      );
    }
  }

  // Large (h1-sized) page titles are headings wherever they appear.
  for (final element in tester.allElements) {
    final widget = element.widget;
    if (widget is! Text) continue;
    final size = widget.style?.fontSize;
    final text = widget.data?.trim() ?? '';
    if (size == null || size < 24 || text.isEmpty) continue;
    // Big numeric readouts ("2 min", "50M tokens") use the display style but
    // are values, not headings.
    if (RegExp(r'^[\d₹$]').hasMatch(text)) continue;
    if (!_hasHeaderAncestor(element)) {
      violations.add('page title "$text" is not marked as a header');
    }
  }
}

bool _hasHeaderAncestor(Element element) {
  var marked = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Semantics && (widget.properties.header ?? false)) {
      marked = true;
      return false;
    }
    return true;
  });
  return marked;
}

bool _isToggleControl(Widget widget) =>
    widget is Switch ||
    widget is Checkbox ||
    widget is Radio ||
    widget is SwitchListTile ||
    widget is CheckboxListTile ||
    widget is RadioListTile;


/// Nearest ancestor semantics node that carries a toggle state. Used when a
/// control is merged into a labelled row.
SemanticsNode? _mergedToggleNode(Element element) {
  SemanticsNode? found;
  element.visitAncestorElements((ancestor) {
    final node = ancestor.renderObject?.debugSemantics;
    if (node != null) {
      final flags = node.getSemanticsData().flagsCollection;
      if (flags.isToggled != ui.Tristate.none ||
          flags.isChecked != ui.CheckedState.none) {
        found = node;
        return false;
      }
    }
    return true;
  });
  return found;
}

/// True when the element is laid out and its box intersects the viewport.
bool _isOnScreen(Element element) {
  final box = element.renderObject;
  if (box is! RenderBox || !box.attached || !box.hasSize) return false;
  final origin = box.localToGlobal(Offset.zero);
  final rect = origin & box.size;
  final view = box.owner?.semanticsOwner?.rootSemanticsNode?.rect.size;
  final screen = view ?? const Size(320, 640);
  return rect.overlaps(Offset.zero & screen);
}

void _checkToggles(WidgetTester tester, List<String> violations) {
  for (final element in tester.allElements) {
    if (!_isToggleControl(element.widget)) continue;
    // A switch inside MergeSemantics is deliberately folded into one node
    // with its label, so the state is announced by that ancestor node. Walk
    // up before calling it a violation.
    final semantics = _semanticsFor(tester, element) ?? _mergedToggleNode(element);
    if (semantics == null) {
      // Rows outside the viewport are built but not compiled into the
      // semantics tree, so there is nothing to inspect until they scroll in.
      if (!_isOnScreen(element)) continue;
      violations.add('${_widgetName(element.widget)} has no semantics node');
      continue;
    }
    final flags = semantics.getSemanticsData().flagsCollection;
    if (flags.isToggled == ui.Tristate.none &&
        flags.isChecked == ui.CheckedState.none) {
      violations.add(
        '${_widgetName(element.widget)} does not announce its state '
        '(label "${semantics.getSemanticsData().label}")',
      );
    }
  }
}

void _checkDisabledControls(
  WidgetTester tester,
  List<_AuditNode> nodes,
  List<String> violations,
) {
  for (final element in tester.allElements) {
    final widget = element.widget;

    // Shared primitives are checked against the node they actually emit. A
    // widget-level lookup would land on the inner render object and miss the
    // labelled outer node.
    if (widget is OListRow) {
      // `enabled: true` with no handler is an informational row, not a
      // control; only an explicitly disabled row must announce disabled.
      if (widget.enabled) continue;
      final label = widget.subtitle == null
          ? widget.title
          : '${widget.title}, ${widget.subtitle}';
      _expectDisabledNode(nodes, label, 'OListRow', violations);
      continue;
    }
    if (widget is OButton) {
      if (widget.onPressed != null && !widget.loading) continue;
      _expectDisabledNode(
        nodes,
        widget.semanticLabel ?? widget.label,
        'OButton',
        violations,
      );
      continue;
    }
    if (widget is OIconButton) {
      if (widget.onPressed != null) continue;
      _expectDisabledNode(
        nodes,
        widget.semanticLabel,
        'OIconButton',
        violations,
      );
      continue;
    }
    if (widget is OPressable) {
      if (widget.onTap != null || widget.onLongPress != null) continue;
      final label = widget.semanticLabel;
      if (label == null || label.isEmpty) continue;
      _expectDisabledNode(nodes, label, 'OPressable', violations);
      continue;
    }

    if (!_isDisabledControl(widget)) continue;
    // A control below the fold is built but not compiled into the semantics
    // tree until it scrolls in; there is nothing to announce yet.
    if (!_isOnScreen(element)) continue;
    final semantics = _semanticsFor(tester, element);
    if (semantics == null) {
      violations.add('disabled ${_widgetName(widget)} has no semantics node');
      continue;
    }
    final flags = semantics.getSemanticsData().flagsCollection;
    if (flags.isEnabled != ui.Tristate.isFalse) {
      violations.add(
        'disabled ${_widgetName(widget)} does not announce disabled '
        '(label "${semantics.getSemanticsData().label}")',
      );
    }
  }
}

void _expectDisabledNode(
  List<_AuditNode> nodes,
  String label,
  String kind,
  List<String> violations,
) {
  _AuditNode? match;
  for (final node in nodes) {
    final value = node.data.label.trim();
    if (value == label ||
        value.startsWith('$label,') ||
        value.startsWith('$label\n')) {
      match = node;
      break;
    }
  }
  if (match == null) {
    violations.add('disabled $kind "$label" has no semantics node');
    return;
  }
  if (match.data.flagsCollection.isEnabled != ui.Tristate.isFalse) {
    violations.add(
      'disabled $kind "$label" does not announce disabled',
    );
  }
}

bool _isDisabledControl(Widget widget) {
  if (widget is IconButton) return widget.onPressed == null;
  if (widget is ButtonStyleButton) return widget.onPressed == null;
  if (widget is Switch) return widget.onChanged == null;
  if (widget is Checkbox) return widget.onChanged == null;
  return false;
}

void _checkDecorativeImages(WidgetTester tester, List<String> violations) {
  for (final element in tester.allElements) {
    final widget = element.widget;
    if (widget is! Image) continue;
    final label = widget.semanticLabel?.trim() ?? '';
    if (!widget.excludeFromSemantics && label.isEmpty) {
      violations.add(
        'decorative Image is exposed without a label; set '
        'excludeFromSemantics: true',
      );
    }
  }
}

void _checkDuplicateActions(
  List<_AuditNode> nodes,
  List<String> violations,
  void Function(_GapKind, String, SemanticsData, String) skipOrFlag,
) {
  final byName = <String, List<_AuditNode>>{};
  for (final n in nodes) {
    if (!n.isInteractive) continue;
    final name = n.accessibleName;
    if (name.isEmpty) continue;
    // Only a node that owns its name can collide with another action; an
    // unlabelled inner tap target is the same action as its labelled wrapper.
    if (n._ownName.isEmpty) continue;
    byName.putIfAbsent(name, () => <_AuditNode>[]).add(n);
  }
  for (final entry in byName.entries) {
    final group = entry.value;
    if (group.length < 2) continue;
    final distinct = <_AuditNode>[];
    for (final node in group) {
      final sameAction = distinct.any(
        (other) => _isAncestor(node, other) || _isAncestor(other, node),
      );
      if (!sameAction) distinct.add(node);
    }
    if (distinct.length < 2) continue;
    final ids = distinct.map((n) => '#${n.node.id}').join(', ');
    skipOrFlag(
      _GapKind.duplicateAction,
      entry.key,
      distinct.first.data,
      'different actions share the label "${entry.key}" ($ids)',
    );
  }
}

bool _isAncestor(_AuditNode ancestor, _AuditNode node) {
  for (var p = node.parent; p != null; p = p.parent) {
    if (identical(p, ancestor)) return true;
  }
  return false;
}

SemanticsNode? _semanticsFor(WidgetTester tester, Element element) {
  try {
    return tester.getSemantics(
      find.byElementPredicate((candidate) => candidate == element),
    );
  } catch (_) {
    return null;
  }
}

String _widgetName(Widget widget) {
  final name = widget.runtimeType.toString();
  return name.startsWith('_') ? name.substring(1) : name;
}

List<String> _semanticsLabels(WidgetTester tester) {
  final root = tester.binding.renderViews.first.owner?.semanticsOwner
      ?.rootSemanticsNode;
  final nodes = <_AuditNode>[];
  if (root != null) _flatten(_AuditNode(root, null), nodes);
  return <String>[
    for (final node in nodes)
      if (node.data.label.trim().isNotEmpty) node.data.label.trim(),
  ];
}

List<String> _readingOrder(WidgetTester tester) {
  final root = tester.binding.renderViews.first.owner?.semanticsOwner
      ?.rootSemanticsNode;
  final nodes = <_AuditNode>[];
  if (root != null) _flattenOrdered(_AuditNode(root, null), nodes);
  return <String>[
    for (final node in nodes)
      if (node.data.label.trim().isNotEmpty) node.data.label.trim(),
  ];
}

/// Flattens in the order the platform receives: children are sorted by their
/// [SemanticsSortKey] within contiguous compatible groups, exactly like
/// `SemanticsNode` does before sending a tree update to TalkBack.
void _flattenOrdered(_AuditNode node, List<_AuditNode> out) {
  out.add(node);
  final children = List<_AuditNode>.of(node.children);
  var start = 0;
  while (start < children.length) {
    final key = children[start].node.sortKey;
    var end = start + 1;
    while (end < children.length) {
      final other = children[end].node.sortKey;
      if (other.runtimeType != key.runtimeType) break;
      if (key != null && other?.name != key.name) break;
      end++;
    }
    final group = children.sublist(start, end);
    if (key != null) {
      group.sort((a, b) => a.node.sortKey!.compareTo(b.node.sortKey!));
    }
    for (final child in group) {
      _flattenOrdered(child, out);
    }
    start = end;
  }
}

/// Asserts each anchor appears and that the anchors appear in the given order.
void _expectOrder(List<String> labels, List<String> anchors) {
  final indices = <int>[];
  for (final anchor in anchors) {
    final index = labels.indexWhere((label) => label.contains(anchor));
    expect(
      index,
      isNot(-1),
      reason: 'reading order is missing "$anchor". Labels: $labels',
    );
    indices.add(index);
  }
  for (var i = 1; i < indices.length; i++) {
    expect(
      indices[i],
      greaterThan(indices[i - 1]),
      reason:
          'TalkBack order is ${indices.join(' → ')} for '
          '${anchors.join(' → ')}. Labels: $labels',
    );
  }
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
    if (flags.isHeader) 'header',
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

enum _GapKind { unlabeled, enabled, duplicate, duplicateAction }

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

/// A lock stub that renders the locked or unlocked gate without touching
/// secure storage.
class _StubLock extends AppLock {
  _StubLock({required this.locked});

  @override
  final bool locked;

  @override
  bool get loaded => true;

  @override
  bool get enabled => true;

  @override
  Future<void> load() async {}
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
  _KnownGap(
    'add_connector',
    _GapKind.unlabeled,
    null,
    'Keyboard-dismiss bridge (no visible target).',
    signature: _GapSignature.tapWrapper,
  ),

  // Inline switch in a labelled OListRow; the row owns the name, the switch
  // node is emitted separately with no name.

  // OSelectable does not set hasEnabledState on sheet tiles.
];
