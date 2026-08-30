import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../core/theme.dart';
import '../core/agent_service.dart';

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
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => BrowserScreen(openUrl: url)));
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
        active.controller?.loadRequest(Uri.parse(widget.openUrl!));
      } else {
        agent.newBrowserTab(widget.openUrl!);
      }
    }
    agent.addListener(_onAgentChanged);
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
    if (tab != null && !_editingUrl && _url.text != tab.url) {
      _url.text = tab.url;
    }
    setState(() {});
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
    _activeTab?.controller?.loadRequest(Uri.parse(u));
  }

  @override
  Widget build(BuildContext context) {
    final agent = _agent;
    final tab = _activeTab;
    final controller = tab == null ? null : agent.controllerForTab(tab);
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
                                  GestureDetector(
                                    onTap: () {
                                      agent.closeBrowserTab(i);
                                      setState(() {});
                                    },
                                    child: Icon(
                                      Icons.close,
                                      size: 12,
                                      color: Aether.textFaint,
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
                    onPressed: () => controller?.reload(),
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
                        onSubmitted: _nav,
                        onTap: () => setState(() => _editingUrl = true),
                        onTapOutside: (_) =>
                            setState(() => _editingUrl = false),
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
                            (tab?.url ?? '').startsWith('https')
                                ? Icons.lock_outline
                                : Icons.public,
                            size: 12,
                            color: (tab?.url ?? '').startsWith('https')
                                ? Aether.success
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
            // WebView — IndexedStack keeps every tab's platform view alive
            Expanded(
              child: IndexedStack(
                index: agent.activeTabIndex,
                children: [
                  for (final t in agent.browserTabs)
                    WebViewWidget(controller: agent.controllerForTab(t)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _tabLabel(BrowserTab t) {
    final host = Uri.tryParse(t.url)?.host ?? '';
    return t.title?.isNotEmpty == true
        ? t.title!
        : (host.isNotEmpty ? host : t.url);
  }
}

/// Agent-activity status dot (DSH StateDot semantics):
/// blue = agent actively driving the browser, green = ready.
class _AgentDot extends StatelessWidget {
  final bool busy;
  const _AgentDot({required this.busy});

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Aether.accent,
          shape: BoxShape.circle,
        ),
      );
    }
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: Aether.success, shape: BoxShape.circle),
    );
  }
}
