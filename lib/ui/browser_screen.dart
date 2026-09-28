import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

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

  /// Reload the active tab exactly like the refresh button does: a
  /// local preview reloads its file, anything else reloads the page.
  void _reloadActiveTab() {
    final t = _activeTab;
    final lp = t?.localPreviewPath;
    if (t != null && lp != null) {
      t.controller?.loadFile(lp);
    } else {
      t?.controller?.reload();
    }
    setState(() {});
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
            // Google sign-in cannot complete inside an embedded WebView, so say
            // so and offer the real browser instead of leaving the user staring
            // at "this browser or app may not be secure".
            if (tab != null)
              _ExternalSignInNotice(
                url: tab.url,
                onReload: () => _reloadActiveTab(),
              ),
            // Held popups (window.open / target=_blank clicks captured
            // for the agent): without this chip such a click looked
            // like a dead UI. Desktop browsers show a blocked-popup
            // bar; this is the same thing, with Open / Dismiss.
            if (tab != null)
              _PopupNotice(
                tab: tab,
                onOpen: () {
                  final opened = _agent.openBrowserPopup(tab);
                  if (opened == null) {
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(
                        content: Text(
                          'That popup link is empty or not a web '
                          'address - nothing to open.',
                        ),
                      ),
                    );
                  }
                },
                onDismiss: () => _agent.dismissBrowserPopups(tab),
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
    // FILL THE HEIGHT (2026-09-25). `BoxFit.contain` scaled to the WIDTH, so on
    // a phone the 1280×800 frame came out ~225dp tall inside a much taller
    // parent: a desktop page rendered as a postage stamp with dead space below
    // it. Scaling to the height instead makes the page occupy the full browser
    // area — ~70-80% of the device screen once the app bar, tab strip and
    // omnibar are accounted for — and the leftover width scrolls sideways, the
    // way a tall/tablet viewport reads a desktop layout.
    //
    // The inner SizedBox stays exactly 1280×800: that is what makes
    // `width=device-width` resolve to a real desktop width. Only the PAINT is
    // scaled, never the layout.
    return LayoutBuilder(
      builder: (context, c) {
        if (!c.maxHeight.isFinite || c.maxHeight <= 0) return child;
        final scale = c.maxHeight / desktopHeight;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: desktopWidth * scale,
            height: c.maxHeight,
            child: FittedBox(
              fit: BoxFit.contain,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: desktopWidth,
                height: desktopHeight,
                child: child,
              ),
            ),
          ),
        );
      },
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


/// Hosts whose sign-in flow refuses to run inside an embedded WebView.
///
/// Google is the one users actually hit. Stripping the `; wv` token from the
/// User-Agent (which [BrowserTab.mobileUserAgent] already does) is not enough:
/// Android WebView also sends `X-Requested-With: <package>` on every request and
/// there is no supported way to remove it, so Google still identifies the
/// embedded browser and answers "this browser or app may not be secure". Rather
/// than let that look like an Ovid bug, name the cause and offer the escape
/// hatch — the same reason GitHub's device flow opens externally.
/// Identity providers that refuse to sign a user in from an embedded WebView.
///
/// These are not Ovid bugs and cannot be fixed by spoofing harder. Each of them
/// detects the embedded browser through signals the app does not control —
/// Android WebView sends `X-Requested-With: <package>` on every request and
/// there is no supported way to remove it — and then answers "this browser or
/// app may not be secure", "disallowed_useragent", or a blank redirect loop.
/// Stripping the `; wv` token from the User-Agent (which
/// [BrowserTab.mobileUserAgent] already does) is necessary but not sufficient.
///
/// So name the provider, say plainly why it will not work here, and offer the
/// real browser. GitHub already does the equivalent thing by using the device
/// flow with `LaunchMode.externalApplication`.
const Map<String, String> _alwaysExternalSignInHosts = {
  'accounts.google.com': 'Google',
  'accounts.youtube.com': 'Google',
  'login.microsoftonline.com': 'Microsoft',
  'login.live.com': 'Microsoft',
  'login.microsoft.com': 'Microsoft',
  'appleid.apple.com': 'Apple',
  'id.apple.com': 'Apple',
};

/// General-purpose origins that are a sign-in surface ONLY on their auth
/// paths. Listing bare `facebook.com` / `x.com` / `linkedin.com` /
/// `twitter.com` as always-sign-in fired the "provider blocks embedded
/// sign-in" banner over ordinary timelines, profiles and posts — a false
/// warning on pages that load perfectly well in a WebView.
const Map<String, String> _pathGatedSignInHosts = {
  'facebook.com': 'Facebook',
  'm.facebook.com': 'Facebook',
  'www.facebook.com': 'Facebook',
  'linkedin.com': 'LinkedIn',
  'www.linkedin.com': 'LinkedIn',
  'x.com': 'X',
  'twitter.com': 'X',
};

/// Path/query markers that make a gated host a real sign-in surface.
const List<String> _signInPathMarkers = [
  '/login',
  'login.php',
  '/signin',
  '/sign-in',
  '/sign_in',
  '/signup',
  '/register',
  '/oauth',
  '/authorize',
  '/sso',
  '/cas/login',
  '/account/login',
  'dialog/oauth',
  'checkpoint',
];

/// The provider name when [url] is a sign-in page that will not complete inside
/// an embedded WebView, else null.
///
/// Suffix matching is exact-host-or-dot-boundary only: `accounts.google.com` and
/// `mail.accounts.google.com` match, while `accounts.google.com.evil.example`
/// must not.
@visibleForTesting
String? externalSignInProvider(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return null;
  final h = u.host.toLowerCase();
  if (h.isEmpty) return null;
  final always = _hostProvider(h, _alwaysExternalSignInHosts);
  if (always != null) return always;
  final gated = _hostProvider(h, _pathGatedSignInHosts);
  if (gated == null) return null;
  return _isSignInSurface(u) ? gated : null;
}

String? _hostProvider(String host, Map<String, String> table) {
  final direct = table[host];
  if (direct != null) return direct;
  for (final entry in table.entries) {
    if (host.endsWith('.${entry.key}')) return entry.value;
  }
  return null;
}

bool _isSignInSurface(Uri u) {
  final haystack = '${u.path}?${u.query}'.toLowerCase();
  for (final marker in _signInPathMarkers) {
    if (haystack.contains(marker)) return true;
  }
  return false;
}

@visibleForTesting
bool isExternalSignInUrl(String url) => externalSignInProvider(url) != null;

class _ExternalSignInNotice extends StatelessWidget {
  const _ExternalSignInNotice({required this.url, this.onReload});

  final String url;

  /// Reloads this tab after the user finished signing in in the real
  /// browser. Some providers complete the SSO step in this profile's
  /// cookie jar too, so one reload tap is worth trying before
  /// abandoning the tab.
  final VoidCallback? onReload;

  @override
  Widget build(BuildContext context) {
    final provider = externalSignInProvider(url);
    if (provider == null) return const SizedBox.shrink();
    return MaterialBanner(
      backgroundColor: Aether.surfaceAlt,
      leading: const Icon(Icons.gpp_maybe_outlined),
      content: Text(
        '$provider blocks sign-in inside an embedded browser — this is the '
        'provider\'s own rule, not an Ovid setting. Open it in your real '
        'browser to finish. This tab keeps a separate cookie jar, so the '
        'sign-in will not carry back into it automatically.',
        style: const TextStyle(fontSize: 12.5, height: 1.4),
      ),
      actions: [
        TextButton(
          key: const ValueKey('external-signin-open'),
          onPressed: () async {
            final messenger = ScaffoldMessenger.maybeOf(context);
            var launched = false;
            try {
              launched = await launchUrl(
                Uri.parse(url),
                mode: LaunchMode.externalApplication,
              );
            } catch (_) {
              launched = false;
            }
            if (launched) return;
            // The user pressed a button and nothing happened. `launchUrl`
            // returns false (no handler) or throws (malformed/blocked) and
            // the old `catch (_) {}` swallowed both — so say plainly that it
            // failed and hand over the URL instead.
            await Clipboard.setData(ClipboardData(text: url));
            messenger?.showSnackBar(
              SnackBar(
                content: const Text(
                  'Could not open your browser — the link is copied. '
                  'Paste it into Chrome to finish signing in.',
                ),
                action: SnackBarAction(
                  label: 'Copy link',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: url)),
                ),
              ),
            );
          },
          child: const Text('Open in browser'),
        ),
        TextButton(
          key: const ValueKey('external-signin-reload'),
          onPressed: onReload,
          child: const Text('Reload - I signed in'),
        ),
      ],
    );
  }
}

/// Held popups for the active tab, surfaced like a desktop browser's blocked
/// popup bar: names what was held and offers Open / Dismiss. The JS bridge in
/// AgentService captures `window.open` and `target="_blank"` clicks for the
/// agent; this chip is how the USER sees the same events instead of staring
/// at a tap that did nothing.
class _PopupNotice extends StatelessWidget {
  const _PopupNotice({
    required this.tab,
    required this.onOpen,
    required this.onDismiss,
  });

  final BrowserTab tab;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final pending = tab.popupRequests;
    if (pending.isEmpty) return const SizedBox.shrink();
    final last = pending.last;
    final host = Uri.tryParse(last)?.host ?? last;
    final label = pending.length == 1
        ? 'Popup held: $host'
        : '${pending.length} popups held - newest: $host';
    return Container(
      key: const ValueKey('popup-notice'),
      color: Aether.surfaceAlt,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          const Icon(Icons.block_outlined, size: 14, color: Aether.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5, color: Aether.textMuted),
            ),
          ),
          TextButton(
            key: const ValueKey('popup-open'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: onOpen,
            child: const Text('Open'),
          ),
          TextButton(
            key: const ValueKey('popup-dismiss'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: onDismiss,
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
  }
}
