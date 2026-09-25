import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/theme.dart';
import '../core/agent_service.dart';

@visibleForTesting
Widget Function(BrowserTab tab)? browserWebViewBuilderForTest;

/// In-app browser — persistent tabs (state survives screen open/close),
/// omnibar, back/forward/refresh, agent robot indicator.
///
/// The WebViewController is owned by [AgentService.browserTabs], NOT by this
/// screen. Opening/closing the screen never reloads pages; the agent's
/// current page is always what the user sees.
class BrowserScreen extends StatefulWidget {
  final String? openUrl;
  final bool agentControlled;
  const BrowserScreen({super.key, this.openUrl, this.agentControlled = true});

  /// Push the browser, optionally navigating the active tab to [url].
  static Future<void> open(BuildContext context, {String? url}) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => BrowserScreen(openUrl: url)));
  }

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final _agent = AgentService.I;
  final TextEditingController _url = TextEditingController();
  bool _editingUrl = false;

  @override
  void initState() {
    super.initState();
    final agent = _agent;
    // Route openUrl: same domain → navigate active tab; new domain → new tab.
    if (widget.openUrl != null) {
      final active = agent.browserTabs.isNotEmpty
          ? agent.browserTabs[agent.activeTabIndex]
          : null;
      if (active == null) {
        agent.newBrowserTab(widget.openUrl!);
      } else if (_sameHost(active.url, widget.openUrl!)) {
        unawaited(agent.navigateTab(active, widget.openUrl!));
      } else {
        agent.newBrowserTab(widget.openUrl!);
      }
    }
    agent.addListener(_onAgentChanged);
    // Omnibar initial value.
    final t = agent.browserTabs.isNotEmpty
        ? agent.browserTabs[agent.activeTabIndex]
        : null;
    if (t != null) _url.text = _omnibarText(t);
  }

  static bool _sameHost(String a, String b) {
    final ha = Uri.tryParse(a)?.host ?? '';
    final hb = Uri.tryParse(b)?.host ?? '';
    return ha.isNotEmpty && ha == hb;
  }

  void _onAgentChanged() {
    if (!mounted) return;
    // Keep the omnibar synced with the active tab (agent navigations too).
    final tab = _activeTab;
    if (tab != null && !_editingUrl && _url.text != _omnibarText(tab)) {
      _url.text = _omnibarText(tab);
    }
    setState(() {});
  }

  String _omnibarText(BrowserTab tab) {
    if (tab.localPreviewPath != null) return 'Live preview';
    final title = tab.title?.trim();
    return title == null || title.isEmpty ? tab.url : title;
  }

  void _beginUrlEditing() {
    final tab = _activeTab;
    if (tab == null) return;
    setState(() {
      _editingUrl = true;
      _url
        ..text = tab.url
        ..selection = TextSelection.collapsed(offset: tab.url.length);
    });
  }

  void _endUrlEditing() {
    setState(() {
      _editingUrl = false;
      final tab = _activeTab;
      if (tab != null) _url.text = _omnibarText(tab);
    });
  }

  BrowserTab? get _activeTab =>
      _agent.activeTabIndex < _agent.browserTabs.length
      ? _agent.browserTabs[_agent.activeTabIndex]
      : null;

  @override
  void dispose() {
    _agent.removeListener(_onAgentChanged);
    _url.dispose();
    super.dispose();
  }

  void _nav(String url) {
    var u = url.trim();
    if (u.isEmpty) return;
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://www.google.com/search?q=${Uri.encodeComponent(u)}';
    }
    final tab = _activeTab;
    if (tab == null) return;
    unawaited(_agent.navigateTab(tab, u));
  }

  @override
  Widget build(BuildContext context) {
    final agent = _agent;
    final tab = _activeTab;
    final controller = tab == null || browserWebViewBuilderForTest != null
        ? tab?.controller
        : agent.controllerForTab(tab);
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Browser'),
        actions: [
          // Agent-activity indicator: blue pulsing while agent drives.
          AnimatedBuilder(
            animation: agent,
            builder: (_, _) => Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Center(
                child: _AgentDot(busy: agent.browserBusy || agent.busy),
              ),
            ),
          ),
          IconButton(
            tooltip: tab?.desktopMode == true
                ? 'Switch to mobile view'
                : 'Switch to desktop view',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              tab?.desktopMode == true
                  ? Icons.phone_android_outlined
                  : Icons.desktop_windows_outlined,
              size: 19,
            ),
            onPressed: tab == null
                ? null
                : () async {
                    await agent.setTabDesktopMode(tab, !tab.desktopMode);
                    setState(() {});
                  },
          ),
          IconButton(
            tooltip: 'New tab',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add, size: 19),
            onPressed: () {
              agent.newBrowserTab();
              setState(() {});
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Tab strip
            if (agent.browserTabs.length > 1)
              Container(
                height: 36,
                color: Aether.surfaceAlt,
                child: Row(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: agent.browserTabs.length,
                        itemBuilder: (_, i) {
                          final t = agent.browserTabs[i];
                          final selected = i == agent.activeTabIndex;
                          return GestureDetector(
                            onTap: () {
                              agent.selectBrowserTab(i);
                              setState(() {});
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              margin: const EdgeInsets.fromLTRB(6, 5, 0, 5),
                              decoration: BoxDecoration(
                                color: selected
                                    ? Aether.surface
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                                border: selected
                                    ? Border.all(color: Aether.hairline)
                                    : null,
                              ),
                              alignment: Alignment.center,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 110,
                                    ),
                                    child: Text(
                                      _tabLabel(t),
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: selected
                                            ? Aether.text
                                            : Aether.textMuted,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  // Was a bare 12x12dp Icon in a
                                  // GestureDetector, sitting ~5px from the tab
                                  // body: the easiest mis-tap in the app was
                                  // closing the wrong tab, and TalkBack had
                                  // nothing to announce. The hit area is now
                                  // opaque and labelled.
                                  Semantics(
                                    button: true,
                                    label: 'Close tab',
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        agent.closeBrowserTab(i);
                                        setState(() {});
                                      },
                                      child: SizedBox(
                                        width: 32,
                                        height: 32,
                                        child: Center(
                                          child: Icon(
                                            Icons.close,
                                            size: 12,
                                            color: Aether.textFaint,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            // Omnibar
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.arrow_back_ios,
                      size: 15,
                      color: Aether.textMuted,
                    ),
                    onPressed: () async {
                      if (await controller?.canGoBack() ?? false) {
                        await controller!.goBack();
                      }
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.arrow_forward_ios,
                      size: 15,
                      color: Aether.textMuted,
                    ),
                    onPressed: () async {
                      if (await controller?.canGoForward() ?? false) {
                        await controller!.goForward();
                      }
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.refresh,
                      size: 17,
                      color: Aether.textMuted,
                    ),
                    onPressed: () {
                      final t = _activeTab;
                      final lp = t?.localPreviewPath;
                      if (t != null && lp != null) {
                        t.controller?.loadFile(lp);
                      } else {
                        controller?.reload();
                      }
                    },
                  ),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Aether.surfaceAlt,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Aether.hairline),
                      ),
                      child: TextField(
                        controller: _url,
                        style: const TextStyle(fontSize: 12.5),
                        textInputAction: TextInputAction.go,
                        onSubmitted: (value) {
                          _nav(value);
                          _endUrlEditing();
                        },
                        onTap: _beginUrlEditing,
                        onTapOutside: (_) => _endUrlEditing(),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 9,
                          ),
                          hintText: 'Search or type URL',
                          hintStyle: TextStyle(
                            fontSize: 12,
                            color: Aether.textFaint,
                          ),
                          prefixIcon: Icon(
                            tab?.localPreviewPath != null
                                ? Icons.preview_outlined
                                : (tab?.url ?? '').startsWith('https')
                                ? Icons.lock_outline
                                : Icons.public,
                            size: 12,
                            color: tab?.localPreviewPath != null
                                ? Aether.accent
                                : (tab?.url ?? '').startsWith('https')
                                ? Aether.successLight
                                : Aether.textFaint,
                          ),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 28,
                          ),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.open_in_browser,
                      size: 17,
                      color: Aether.textMuted,
                    ),
                    onPressed: () => _nav(_url.text),
                  ),
                ],
              ),
            ),
            // Progress bar
            if (tab?.loading ?? false)
              LinearProgressIndicator(
                value: tab!.progress > 0 && tab.progress < 100
                    ? tab.progress / 100
                    : null,
                minHeight: 2,
                backgroundColor: Aether.hairline,
                color: Aether.accent,
              ),
            // WebView — IndexedStack keeps every tab's platform view alive.
            //
            // DESKTOP MODE (2026-09-24): a desktop tab is now laid out at REAL
            // desktop dimensions and scaled to fit, instead of being squeezed
            // into the phone screen and asked to *pretend*. See
            // [_SizedBrowserView] for why the old approach could never work.
            Expanded(
              child: IndexedStack(
                index: agent.activeTabIndex,
                children: [
                  for (final t in agent.browserTabs)
                    _SizedBrowserView(
                      // Key on the tab's STABLE id, not its URL:
                      // in-page navigation (t.url changes constantly)
                      // must not tear down and recreate the platform
                      // view. desktopMode stays in the key because the
                      // controller is intentionally recreated on toggle.
                      key: ValueKey('tab_${t.id}_${t.desktopMode}'),
                      tab: t,
                      child:
                          browserWebViewBuilderForTest?.call(t) ??
                          WebViewWidget(
                            controller: agent.controllerForTab(t),
                          ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _tabLabel(BrowserTab t) {
    if (t.localPreviewPath != null) return 'Preview';
    if (t.url == 'ovid://preview') return 'Preview';
    if (t.title?.isNotEmpty == true) return t.title!;
    final host = Uri.tryParse(t.url)?.host ?? '';
    return host.isNotEmpty ? host : t.url;
  }
}

/// Agent-activity status dot (the browser status indicator StateDot semantics):
/// blue = agent actively driving the browser, green = ready.
/// Lays a desktop-mode tab out at REAL desktop dimensions and scales it to fit;
/// a mobile tab fills the available space unchanged.
///
/// WHY THIS EXISTS (2026-09-24). Desktop mode used to leave the WebView
/// hard-constrained to the phone screen (a bare `Expanded` above) and instead
/// tried to *convince* the page it was on a desktop: a Windows UA, client hints,
/// a JS shim faking `innerWidth`/`screen.*`, and an injected
/// `<meta name=viewport content=width=1280>`. None of that can work:
///
///   • CSS media queries, `vw`/`vh`, container queries and `visualViewport`
///     read the REAL layout viewport. JS getters cannot fake it, so the shim was
///     cosmetic.
///   • Chromium's rule is *last meta wins* — the page's own
///     `width=device-width` is parsed after a document-start injection and beats
///     it. The injected meta was then shadowed by a first-match `querySelector`,
///     so every "repair" re-ran the same no-op and reported success.
///   • Height was never forced at all.
///
/// Giving the native view genuine 1280×800 logical pixels makes
/// `width=device-width` resolve to 1280, so every one of those signals becomes
/// truly desktop with no fakery.
///
/// `FittedBox` (not `Transform.scale`) is the correct primitive: it lays the
/// child out with unbounded constraints at its own size and then scales the
/// paint, so a 1280-wide child inside a 360-wide parent is not a layout
/// overflow. `InteractiveViewer` restores pinch-zoom and panning, which the
/// shrink-to-fit would otherwise make unusable on a phone screen.
class _SizedBrowserView extends StatelessWidget {
  const _SizedBrowserView({
    super.key,
    required this.tab,
    required this.child,
  });

  final BrowserTab tab;
  final Widget child;

  /// CSS pixels a desktop tab is laid out at. Kept in lockstep with
  /// [BrowserTab.desktopLogicalWidth]/[BrowserTab.desktopLogicalHeight], which
  /// are what the native viewport override advertises — the geometry and the
  /// reported size must agree or the page's own layout logic contradicts the
  /// metrics it reads back.
  static const double desktopWidth = 1280;
  static const double desktopHeight = 800;

  @override
  Widget build(BuildContext context) {
    if (!tab.desktopMode) return child;
    return InteractiveViewer(
      minScale: 0.9,
      maxScale: 5,
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: desktopWidth,
          height: desktopHeight,
          child: child,
        ),
      ),
    );
  }
}

/// Test seam: the desktop geometry this screen applies, so a widget test can
/// assert real dimensions rather than a source string.
@visibleForTesting
const browserDesktopLogicalSize = Size(
  _SizedBrowserView.desktopWidth,
  _SizedBrowserView.desktopHeight,
);

class _AgentDot extends StatelessWidget {
  final bool busy;
  const _AgentDot({required this.busy});

  @override
  Widget build(BuildContext context) {
    // State was encoded by COLOUR ALONE on a 10px dot: colour-blind users could
    // not tell "agent is driving this tab" from "idle", and a screen reader had
    // nothing to announce. The label travels with the dot now.
    final label = busy
        ? 'Agent is driving this tab'
        : 'Agent idle on this tab';
    return Semantics(
      label: label,
      child: Tooltip(
        message: label,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: busy ? Aether.accent : Aether.successLight,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
