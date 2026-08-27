import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../core/theme.dart';
import '../core/agent_service.dart';

/// In-app browser — real WebView (Chrome engine on Android), default Google.com.
/// Agent can drive it via browser_open; user navigates via omnibar.
class BrowserScreen extends StatefulWidget {
  final String initialUrl;
  final bool agentControlled;
  const BrowserScreen({
    super.key,
    this.initialUrl = 'https://www.google.com',
    this.agentControlled = true,
  });
  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late final WebViewController _c;
  final TextEditingController _url = TextEditingController();
  String? _currentUrl;
  bool _loading = true;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() {
              _loading = true;
              _currentUrl = url;
              _url.text = url;
            });
          },
          onProgress: (p) => setState(() => _progress = p),
          onPageFinished: (url) {
            setState(() {
              _loading = false;
              _currentUrl = url;
              _url.text = url;
            });
            AgentService.I.browserUrl = url;
          },
          onWebResourceError: (err) {
            setState(() => _loading = false);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.initialUrl));

    if (widget.agentControlled) AgentService.I.bindWebView(_c);
  }

  @override
  void dispose() {
    if (widget.agentControlled) AgentService.I.unbindWebView(_c);
    _url.dispose();
    super.dispose();
  }

  void _nav(String url) {
    var u = url.trim();
    if (u.isEmpty) return;
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://www.google.com/search?q=${Uri.encodeComponent(u)}';
    }
    _c.loadRequest(Uri.parse(u));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Browser'),
        actions: [
          AnimatedBuilder(
            animation: AgentService.I,
            builder: (_, _) => IconButton(
              tooltip: 'Agent browsing',
              icon: Icon(
                AgentService.I.busy
                    ? Icons.smart_toy
                    : Icons.smart_toy_outlined,
                size: 18,
                color: AgentService.I.busy ? Aether.accent : Aether.textMuted,
              ),
              onPressed: () {},
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Omnibar
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.arrow_back_ios,
                      size: 15,
                      color: Aether.textMuted,
                    ),
                    onPressed: () async {
                      if (await _c.canGoBack()) await _c.goBack();
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.arrow_forward_ios,
                      size: 15,
                      color: Aether.textMuted,
                    ),
                    onPressed: () async {
                      if (await _c.canGoForward()) await _c.goForward();
                    },
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(
                      Icons.refresh,
                      size: 17,
                      color: Aether.textMuted,
                    ),
                    onPressed: () => _c.reload(),
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
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 9,
                          ),
                          hintText: 'Search or type URL',
                          hintStyle: const TextStyle(
                            fontSize: 12,
                            color: Aether.textFaint,
                          ),
                          prefixIcon: Icon(
                            _currentUrl?.startsWith('https') ?? false
                                ? Icons.lock_outline
                                : Icons.public,
                            size: 12,
                            color: _currentUrl?.startsWith('https') ?? false
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
                    icon: const Icon(
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
            if (_loading)
              LinearProgressIndicator(
                value:
                    _progress > 0 && _progress < 100 ? _progress / 100 : null,
                minHeight: 2,
                backgroundColor: Aether.hairline,
                color: Aether.accent,
              ),
            // WebView
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(12),
                ),
                child: WebViewWidget(controller: _c),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
