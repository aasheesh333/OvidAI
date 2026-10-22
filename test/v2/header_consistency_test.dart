import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/app_lock.dart';
import 'package:ovid_ai/ui/design/o_components.dart';
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/app/app_lock_gate.dart';
import 'package:ovid_ai/ui/v2/v2_registry.dart';
import 'package:ovid_ai/ui/v2/v2_screen_entry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Header contract gate for every registered UI v2 screen.
///
/// The contract is `docs/design/MINIMAL_UI_CONTRACT.md` §2. For every screen
/// this test renders the real widget and checks:
///
///  * exactly one header — `OAppBar`/`AppBar` for a page, `OSheetHeader` (or
///    the hand-rolled title row) for a sheet;
///  * the header title is non-empty and at most three words;
///  * the header title is not repeated in the body as a *heading* (a button
///    label that happens to match the title is not a second heading);
///  * the leading control matches the screen kind — menu on a drawer root tab,
///    back on a pushed page, close on a sheet;
///  * at most two header actions.
///
/// The kind is derived from the registry entry *and* how the screen is really
/// presented. A bottom-nav destination that the shell pushes as a route
/// (`Browser`, `Library`, `Studio workspace`) is a pushed page in this gate,
/// because that is the header its builder draws. `Settings` is a root tab but
/// deliberately has no menu: it is a destination, not a drawer host, and its
/// one action is search. `Sidebar` is drawer chrome, not a page, so it has no
/// page header. `Model chip` is a popover menu registered with `isSheet`
/// (it needs a Material host) but it is not a modal sheet and takes no close.
///
/// Current violations are listed in [_knownGaps] so the suite stays green
/// while the owning screens are fixed. Every entry must still be live: once a
/// screen is fixed its entry has to be deleted here, and a stale entry fails.
/// That is the same ratchet the semantics audit uses.
void main() {
  final facts = <String, _Facts>{};

  for (final entry in v2Screens) {
    testWidgets('${entry.id} header contract', (tester) async {
      final kind = _kindOf(entry);
      await _pump(tester, entry, kind);
      final actual = _inspect(tester, entry, kind);
      facts[entry.id] = actual;

      final issues = actual.issues;
      final known = _knownGaps[entry.id] ?? const <String>{};

      final unexpected = issues.difference(known).toList()..sort();
      final stale = known.difference(issues).toList()..sort();

      expect(
        unexpected,
        isEmpty,
        reason:
            '${entry.id} (${kind.name}) violates the header contract: '
            '${unexpected.join(', ')}',
      );
      expect(
        stale,
        isEmpty,
        reason:
            '${entry.id} is listed in _knownGaps for ${stale.join(', ')} but '
            'no longer has that problem. Delete the stale entry.',
      );
    });
  }

  testWidgets('lock screen has no header', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: AppLockGate(lock: _StubLock(), child: const SizedBox.shrink()),
      ),
    );
    await tester.pump();

    expect(
      find.byType(AppBar),
      findsNothing,
      reason: 'the lock screen is a full-screen state and takes no header',
    );
    expect(find.text('App locked'), findsWidgets);
  });

  test('header table', () {
    for (final entry in v2Screens) {
      final f = facts[entry.id];
      if (f == null) {
        // ignore: avoid_print
        print('${entry.id} | (not rendered)');
        continue;
      }
      // ignore: avoid_print
      print(
        '${entry.id} | ${f.headerCount == 1 ? 'yes' : 'no (${f.headerCount})'} '
        '| ${f.duplicateTitle ? 'yes' : 'no'} '
        '| ${f.leadingOk ? 'no' : 'yes (${f.leading.name})'} '
        '| ${f.actions}',
      );
    }
  });
}

// ───────────────────────────────────────────────────────────────────────────
// Screen kinds
// ───────────────────────────────────────────────────────────────────────────

enum _Kind { rootTab, pushed, onboarding, sheet, menu, chrome, fullScreen }

/// Root tabs that host the drawer: their leading control is a menu.
const _rootTabs = <String>{'chat', 'live_chat', 'settings'};

/// Root tabs that deliberately carry no menu. Settings is a destination, not
/// a drawer host; its header is `Settings` plus one search icon.
const _menuLessRootTabs = <String>{'settings'};

/// Screens whose top bar carries three actions by product requirement.
const _chatTopBar = <String>{'chat', 'live_chat'};

/// Tour steps. A back arrow is only correct when the host supplied one.
const _onboarding = <String>{'welcome', 'language_goal', 'sign_in', 'paywall'};

/// Full-screen states: no page header at all (§2, last row).
const _fullScreen = <String>{'splash'};

/// Popover menus registered as sheets because they need a Material host. They
/// have a title row but are not modal sheets, so they take no close control.
const _menus = <String>{'model_chip'};

/// Drawer chrome: a navigation surface, not a page. It has no page header.
const _chrome = <String>{'sidebar'};

_Kind _kindOf(V2ScreenEntry entry) {
  if (_chrome.contains(entry.id)) return _Kind.chrome;
  if (_fullScreen.contains(entry.id)) return _Kind.fullScreen;
  if (_menus.contains(entry.id)) return _Kind.menu;
  if (entry.isSheet) return _Kind.sheet;
  if (_onboarding.contains(entry.id)) return _Kind.onboarding;
  if (_rootTabs.contains(entry.id)) return _Kind.rootTab;
  return _Kind.pushed;
}

// ───────────────────────────────────────────────────────────────────────────
// Rendering
// ───────────────────────────────────────────────────────────────────────────

Future<void> _pump(
  WidgetTester tester,
  V2ScreenEntry entry,
  _Kind kind,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final navigator = GlobalKey<NavigatorState>();

  Widget app(Widget home) => MaterialApp(
    theme: OTheme.light(),
    navigatorKey: navigator,
    home: home,
  );

  if (kind == _Kind.pushed || kind == _Kind.sheet) {
    // Push the screen so `Navigator.canPop` is true, which is the only
    // situation in which a back arrow (or a sheet close) is allowed.
    await tester.pumpWidget(app(const Scaffold(body: SizedBox.shrink())));
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          // A modal sheet is hosted by showModalBottomSheet: Material
          // ancestor, bottom-aligned, bounded width. Reproduce that so the
          // screen is inspected in the shape a user actually sees.
          builder: kind == _Kind.sheet
              ? (context) => Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: entry.builder(context),
                    ),
                  ),
                )
              : entry.builder,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  } else {
    Widget child = Builder(builder: entry.builder);
    if (kind == _Kind.menu) {
      child = Scaffold(body: child);
    }
    await tester.pumpWidget(app(child));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Inspection
// ───────────────────────────────────────────────────────────────────────────

enum _Leading { menu, back, close, other, none }

class _Facts {
  _Facts({
    required this.id,
    required this.kind,
    required this.headerCount,
    required this.appBars,
    required this.title,
    required this.leading,
    required this.actions,
    required this.duplicateTitle,
    required this.closeEnabled,
  });

  final String id;
  final _Kind kind;
  final int headerCount;
  final int appBars;
  final String? title;
  final _Leading leading;
  final int actions;
  final bool duplicateTitle;
  final bool closeEnabled;

  int get titleWords =>
      title == null || title!.trim().isEmpty
      ? 0
      : title!.trim().split(RegExp(r'\s+')).length;

  bool get leadingOk => switch (kind) {
    // A root tab shows the drawer menu when the host wires one. The gallery
    // renders these screens without callbacks, and a menu glyph with a null
    // handler is a dead control, so `none` is the correct shape there too.
    // The production assertion (every tab has a working menu) lives in
    // test/v2/app/navigation surfaces.
    _Kind.rootTab =>
      _menuLessRootTabs.contains(id)
          ? leading == _Leading.none
          : leading == _Leading.menu || leading == _Leading.none,
    _Kind.pushed => leading == _Leading.back,
    _Kind.sheet => leading == _Leading.close && closeEnabled,
    _Kind.onboarding => leading == _Leading.none || leading == _Leading.close,
    _Kind.menu => leading == _Leading.none,
    _Kind.chrome => leading == _Leading.none,
    _Kind.fullScreen => leading == _Leading.none,
  };

  Set<String> get issues {
    final out = <String>{};
    if (kind == _Kind.chrome || kind == _Kind.fullScreen) {
      if (headerCount != 0) out.add('header-present');
      return out;
    }
    if (kind == _Kind.sheet) {
      if (headerCount != 1) out.add('headers:$headerCount');
      if (appBars != 0) out.add('sheet-appbar:$appBars');
    } else if (headerCount != 1) {
      out.add('headers:$headerCount');
    }
    if (title == null || title!.trim().isEmpty) {
      out.add('title-empty');
    } else if (titleWords > 3) {
      out.add('title-words:$titleWords');
    }
    if (duplicateTitle) out.add('duplicate-title');
    if (!leadingOk) {
      out.add('leading:${leading.name}->${_expectedLeading(kind, id).name}');
    }
    // The chat top bar is specified as menu · model · title · Studio ·
    // Browser · ⋮, so the two-action budget does not apply to it.
    final actionBudget = _chatTopBar.contains(id) ? 3 : 2;
    if (kind != _Kind.sheet && actions > actionBudget) {
      out.add('actions:$actions');
    }
    if (kind == _Kind.sheet && !closeEnabled) {
      out.add(leading == _Leading.none ? 'close-missing' : 'close-disabled');
    }
    return out;
  }
}

_Leading _expectedLeading(_Kind kind, String id) => switch (kind) {
  _Kind.rootTab =>
    _menuLessRootTabs.contains(id) ? _Leading.none : _Leading.menu,
  _Kind.pushed => _Leading.back,
  _Kind.sheet => _Leading.close,
  _Kind.onboarding => _Leading.none,
  _Kind.menu => _Leading.none,
  _Kind.chrome => _Leading.none,
  _Kind.fullScreen => _Leading.none,
};

_Facts _inspect(WidgetTester tester, V2ScreenEntry entry, _Kind kind) {
  final root = tester.element(find.byType(MaterialApp));
  final all = _elements(root);
  final appBarElements = find.byType(AppBar).evaluate().toList();
  final appBars = appBarElements.length;

  if (kind == _Kind.sheet || kind == _Kind.menu) {
    final headers = tester
        .widgetList<OSheetHeader>(find.byType(OSheetHeader))
        .toList();

    String? title;
    Element? titleElement;
    var headerCount = headers.length;

    if (headers.isNotEmpty) {
      title = headers.first.title?.trim();
      final headerElement = find.byType(OSheetHeader).evaluate().first;
      titleElement = _firstTextElement(headerElement);
    } else {
      // A hand-rolled sheet title row: the first header-semantics text.
      titleElement = _firstHeaderElement(root);
      title = titleElement == null ? null : _textOf(titleElement)?.trim();
      headerCount = titleElement == null ? 0 : 1;
    }

    final closeEnabled =
        (headers.isNotEmpty && headers.first.onClose != null) ||
        _hasEnabledControl(all, Icons.close_rounded) ||
        _hasEnabledControl(all, Icons.cancel_rounded);

    final leading = kind == _Kind.sheet
        ? (closeEnabled ? _Leading.close : _Leading.none)
        : _Leading.none;

    final duplicateTitle =
        title != null &&
        title.isNotEmpty &&
        _headingTexts(all)
            .where(
              (node) =>
                  node.$1 != titleElement &&
                  !_hasAncestor(node.$1, OSheetHeader),
            )
            .any((node) => node.$2.trim() == title);

    return _Facts(
      id: entry.id,
      kind: kind,
      headerCount: headerCount,
      appBars: appBars,
      title: title,
      leading: leading,
      actions: 0,
      duplicateTitle: duplicateTitle,
      closeEnabled: closeEnabled,
    );
  }

  final oAppBars = tester.widgetList<OAppBar>(find.byType(OAppBar)).toList();
  final AppBar? appBar = appBars == 0
      ? null
      : tester.widget<AppBar>(find.byType(AppBar).first);

  // Title: OAppBar exposes it directly. A hand-rolled AppBar marks its title
  // with `Semantics(header: true)`; the browser's address pill has no heading
  // semantics, so fall back to the first text in the bar.
  String? title;
  if (oAppBars.isNotEmpty) {
    title = oAppBars.first.title.trim();
  } else if (appBar != null) {
    final appBarElement = appBarElements.first;
    title =
        _firstHeaderText(appBarElement)?.trim() ??
        _firstText(appBarElement)?.trim();
  }

  final leading = _leadingKind(appBar?.leading);

  int actions = 0;
  if (oAppBars.isNotEmpty) {
    actions = _countActions(oAppBars.first.actions);
  } else if (appBar != null) {
    actions = _countActions(appBar.actions ?? const <Widget>[]);
  }

  // Duplicate title: another *heading* with the same text. A button label or
  // a row title that happens to match is not a second heading.
  final duplicateTitle =
      title != null &&
      title.isNotEmpty &&
      _headingTexts(all)
          .where((node) => !_hasAncestor(node.$1, AppBar))
          .any((node) => node.$2.trim() == title);

  return _Facts(
    id: entry.id,
    kind: kind,
    headerCount: appBars,
    appBars: appBars,
    title: title,
    leading: leading,
    actions: actions,
    duplicateTitle: duplicateTitle,
    closeEnabled: false,
  );
}

/// Header actions are the controls in the bar, not the trailing gap that keeps
/// the last icon off the screen edge.
int _countActions(List<Widget> actions) =>
    actions.where((action) => action is! SizedBox && action is! Spacer).length;

List<Element> _elements(Element root) {
  final out = <Element>[];
  void visit(Element e) {
    out.add(e);
    e.visitChildren(visit);
  }

  visit(root);
  return out;
}

bool _hasAncestor(Element element, Type type) {
  var found = false;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget.runtimeType == type) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

bool _hasHeadingAncestor(Element element) {
  var found = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Semantics && (widget.properties.header ?? false)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Every `Text` that is announced as a heading, with its element so callers
/// can exclude the header itself.
Iterable<(Element, String)> _headingTexts(List<Element> elements) sync* {
  for (final element in elements) {
    final widget = element.widget;
    if (widget is! Text) continue;
    final data = widget.data;
    if (data == null || !_hasHeadingAncestor(element)) continue;
    yield (element, data);
  }
}

Element? _firstHeaderElement(Element root) {
  Element? found;
  void visit(Element e) {
    if (found != null) return;
    final widget = e.widget;
    if (widget is Semantics && (widget.properties.header ?? false)) {
      found = _firstTextElement(e);
      if (found != null) return;
    }
    e.visitChildren(visit);
  }

  visit(root);
  return found;
}

String? _firstHeaderText(Element root) =>
    _textOf(_firstHeaderElement(root));

String? _textOf(Element? element) =>
    element == null ? null : (element.widget as Text).data;

Element? _firstTextElement(Element root) {
  if (root.widget is Text) return root;
  Element? found;
  root.visitChildren((child) {
    found ??= _firstTextElement(child);
  });
  return found;
}

String? _firstText(Element root) => _textOf(_firstTextElement(root));

_Leading _leadingKind(Widget? widget) {
  if (widget == null) return _Leading.none;
  if (widget is OIconButton) {
    if (widget.icon == Icons.menu_rounded) return _Leading.menu;
    if (widget.icon == Icons.arrow_back_rounded) return _Leading.back;
    if (widget.icon == Icons.close_rounded) return _Leading.close;
    return _Leading.other;
  }
  if (widget is IconButton) {
    final icon = widget.icon;
    if (icon is Icon) {
      if (icon.icon == Icons.menu_rounded) return _Leading.menu;
      if (icon.icon == Icons.arrow_back_rounded) return _Leading.back;
      if (icon.icon == Icons.close_rounded) return _Leading.close;
    }
    return _Leading.other;
  }
  if (widget is BackButton) return _Leading.back;
  if (widget is CloseButton) return _Leading.close;
  return _Leading.other;
}

/// True when the tree contains an enabled close affordance. A close button
/// with a null handler is a dead control, so it does not count.
bool _hasEnabledControl(List<Element> elements, IconData icon) {
  for (final element in elements) {
    final widget = element.widget;
    if (widget is OIconButton) {
      if (widget.icon == icon && widget.onPressed != null) return true;
    } else if (widget is IconButton) {
      final child = widget.icon;
      if (child is Icon && child.icon == icon && widget.onPressed != null) {
        return true;
      }
    }
  }
  return false;
}

// ───────────────────────────────────────────────────────────────────────────
// Known gaps — owner files fix these, then delete the entry.
// ───────────────────────────────────────────────────────────────────────────

const Map<String, Set<String>> _knownGaps = <String, Set<String>>{};

/// Lock stub so the lock screen renders without touching real storage.
class _StubLock extends AppLock {
  _StubLock();

  @override
  bool get loaded => true;

  @override
  bool get locked => true;

  @override
  bool get enabled => true;

  @override
  Future<void> load() async {}

  @override
  Future<bool> unlock(String pin) async => false;
}
