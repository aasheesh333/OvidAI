import 'package:flutter/foundation.dart';

/// ---------- Models ----------

class ProviderConfig {
  String name;
  String description;
  String baseUrl;
  String apiKey;
  bool isFree; // ships free out of the box
  bool custom; // user-added provider
  List<String> models;
  String? selectedModel;
  bool connected;

  ProviderConfig({
    required this.name,
    required this.description,
    required this.baseUrl,
    this.apiKey = '',
    this.isFree = false,
    this.custom = false,
    List<String>? models,
    this.selectedModel,
    this.connected = false,
  }) : models = models ?? [];

  bool get hasKey => apiKey.isNotEmpty || isFree;
}

class PluginItem {
  final String name;
  final String author;
  final String description;
  final String version;
  final String category; // Agent, MCP, Tool, Runtime
  bool installed;
  bool enabled;
  final int installs;

  PluginItem({
    required this.name,
    required this.author,
    required this.description,
    required this.version,
    required this.category,
    this.installed = false,
    this.enabled = false,
    required this.installs,
  });
}

enum MsgKind { text, code, imageGen, reasoning }

class Message {
  final String role; // 'user' | 'assistant'
  final MsgKind kind;
  final String content;
  final String? lang; // for code blocks
  final DateTime time;
  final bool thinking;

  Message({
    required this.role,
    this.kind = MsgKind.text,
    this.content = '',
    this.lang,
    this.thinking = false,
    DateTime? time,
  }) : time = time ?? DateTime.now();
}

class ChatSession {
  final String id;
  String title;
  String model;
  final List<Message> messages;
  final DateTime createdAt;

  ChatSession({
    required this.id,
    required this.title,
    required this.model,
    List<Message>? messages,
    DateTime? createdAt,
  })  : messages = messages ?? [],
        createdAt = createdAt ?? DateTime.now();
}

/// ---------- App state (demo, in-memory) ----------

class AppState extends ChangeNotifier {
  /// Singleton — everything is user-side / on-device.
  static final AppState I = AppState._();
  AppState._() {
    _seed();
  }

  int navIndex = 0; // 0 Chat, 1 Studio, 2 Browser, 3 Plugins, 4 Settings

  final List<ProviderConfig> providers = [];
  final List<PluginItem> plugins = [];
  final List<ChatSession> sessions = [];
  String? activeSessionId;

  ChatSession? get activeSession =>
      sessions.where((s) => s.id == activeSessionId).firstOrNull;

  ProviderConfig get defaultProvider => providers.first;

  void setNav(int i) {
    navIndex = i;
    notifyListeners();
  }

  void selectSession(String id) {
    activeSessionId = id;
    notifyListeners();
  }

  void newSession() {
    final s = ChatSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: 'New chat',
      model: defaultProvider.selectedModel ?? 'deepseek-v4-pro',
    );
    sessions.insert(0, s);
    activeSessionId = s.id;
    notifyListeners();
  }

  void deleteSession(String id) {
    sessions.removeWhere((s) => s.id == id);
    if (activeSessionId == id) {
      activeSessionId = sessions.isEmpty ? null : sessions.first.id;
    }
    notifyListeners();
  }

  void renameSession(String id, String title) {
    sessions.firstWhere((s) => s.id == id).title = title;
    notifyListeners();
  }

  void sendMessage(String text) {
    final s = activeSession;
    if (s == null) return;
    s.messages.add(Message(role: 'user', content: text));
    // Auto-name session from first message
    if (s.title == 'New chat') {
      s.title = text.length > 34 ? '${text.substring(0, 34)}…' : text;
    }
    // Demo assistant reply
    s.messages.add(Message(
      role: 'assistant',
      kind: MsgKind.reasoning,
      thinking: true,
      content: 'Analyzing intent, planning tool usage, drafting response…',
    ));
    s.messages.add(Message(
      role: 'assistant',
      content:
          'This is a demo response from OvidAI. Connect a provider API key in Settings → Providers and this reply will come from the real model. Your prompt was:\n\n"$text"',
    ));
    notifyListeners();
  }

  void setModel(String provider, String model) {
    providers.firstWhere((p) => p.name == provider).selectedModel = model;
    final s = activeSession;
    if (s != null) s.model = model;
    notifyListeners();
  }

  void refresh() => notifyListeners();

  String fmtInstalls(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

  /// ---------- Dummy content ----------
  void _seed() {
    providers.addAll([
      ProviderConfig(
        name: 'OpenCode Free',
        description: 'Free open models bundled with the app. No key required.',
        baseUrl: 'https://opencode.ai/zen/v1',
        isFree: true,
        connected: true,
        models: ['deepseek-v4-pro', 'qwen3-coder-480b', 'kimi-k3', 'glm-5'],
        selectedModel: 'deepseek-v4-pro',
      ),
      ProviderConfig(
        name: 'OpenRouter (free tier)',
        description: 'One key, hundreds of models incl. free variants.',
        baseUrl: 'https://openrouter.ai/api/v1',
        isFree: true,
        models: [
          'deepseek/deepseek-r1:free',
          'google/gemini-2.5-flash:free',
          'meta/llama-4-maverick:free',
        ],
        selectedModel: 'deepseek/deepseek-r1:free',
      ),
      ProviderConfig(
        name: 'Google AI Studio',
        description: 'Gemini free tier with generous rate limits.',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        models: ['gemini-2.5-pro', 'gemini-2.5-flash', 'gemini-2.0-flash'],
      ),
      ProviderConfig(
        name: 'OpenAI',
        description: 'GPT-5 and friends.',
        baseUrl: 'https://api.openai.com/v1',
        models: [],
      ),
      ProviderConfig(
        name: 'Anthropic',
        description: 'Claude family.',
        baseUrl: 'https://api.anthropic.com/v1',
        models: [],
      ),
      ProviderConfig(
        name: 'Groq',
        description: 'Ultra-fast LPU inference, free tier available.',
        baseUrl: 'https://api.groq.com/openai/v1',
        isFree: true,
        models: ['llama-3.3-70b-versatile', 'qwen-qwq-32b'],
      ),
      ProviderConfig(
        name: 'DeepSeek',
        description: 'Direct DeepSeek API.',
        baseUrl: 'https://api.deepseek.com/v1',
        models: ['deepseek-chat', 'deepseek-reasoner'],
      ),
    ]);

    plugins.addAll([
      PluginItem(
          name: 'OpenCode Agent',
          author: 'opencode',
          description:
              'Full agentic coding engine. Plan, edit, run tests inside the proot Ubuntu sandbox.',
          version: '0.9.4',
          category: 'Agent',
          installed: true,
          enabled: true,
          installs: 48200),
      PluginItem(
          name: 'Claude Code Bridge',
          author: 'community',
          description:
              'Use the Claude Code CLI harness with your Anthropic key.',
          version: '1.7.2',
          category: 'Agent',
          installs: 21400),
      PluginItem(
          name: 'Gemini CLI',
          author: 'community',
          description: 'Google’s terminal agent wired into OvidAI Studio.',
          version: '0.4.1',
          category: 'Agent',
          installs: 12800),
      PluginItem(
          name: 'Sandbox Runtime',
          author: 'termux',
          description:
              'Full Linux userland on-device: python, node, gcc — isolated and instant.',
          version: '3.1.0',
          category: 'Runtime',
          installed: true,
          enabled: true,
          installs: 90300),
      PluginItem(
          name: 'MCP Server Hub',
          author: 'modelcontextprotocol',
          description:
              'Connect any Model Context Protocol server: filesystem, github, postgres, puppeteer…',
          version: '2.1.0',
          category: 'MCP',
          installs: 34500),
      PluginItem(
          name: 'Web Fetch & Search',
          author: 'ovidai',
          description: 'Let models browse pages and search the web.',
          version: '1.0.6',
          category: 'Tool',
          installed: true,
          installs: 51700),
      PluginItem(
          name: 'Image Studio',
          author: 'ovidai',
          description:
              'In-chat image generation via free endpoints (Pollinations / HF Spaces).',
          version: '1.2.0',
          category: 'Tool',
          installed: true,
          enabled: true,
          installs: 41900),
      PluginItem(
          name: 'Git Workbench',
          author: 'ovidai',
          description:
              'Clone, branch, commit and push from the Studio IDE.',
          version: '0.8.3',
          category: 'Tool',
          installs: 9300),
    ]);


    // community library (dummy bulk)
    const extra = <(String, String, String, String, int)>[
      ('Puppeteer MCP', 'mcp-community', 'Headless browser automation for agents.', 'MCP', 18200),
      ('Postgres Tools', 'mcp-community', 'Query and inspect Postgres databases.', 'MCP', 9400),
      ('Figma Bridge', 'figma', 'Read design frames and tokens.', 'MCP', 12600),
      ('Slack Notify', 'community', 'Send agent updates to Slack channels.', 'Tool', 5100),
      ('RAG Memory', 'ovidai', 'Long-term vector memory for your chats.', 'Tool', 22800),
      ('Docker-in-Sandbox', 'sandbox', 'OCI containers inside the sandbox.', 'Runtime', 7700),
      ('Aider Bridge', 'community', 'Pair-program with the aider CLI.', 'Agent', 8900),
      ('Shell History', 'ovidai', 'Searchable sandbox terminal history.', 'Tool', 3400),
      ('Voice Code', 'community', 'Dictate code and commands hands-free.', 'Tool', 6600),
      ('Rust Toolchain', 'sandbox', 'cargo + rustc prebuilt for the sandbox.', 'Runtime', 4100),
      ('Go Toolchain', 'sandbox', 'Go 1.23 toolchain, one tap install.', 'Runtime', 3900),
      ('Linear Sync', 'community', 'Create and update Linear issues from chat.', 'Tool', 2800),
      ('Sentry Watch', 'community', 'Pull errors into chat and let agents fix them.', 'Tool', 3300),
      ('Stripe MCP', 'stripe', 'Payments, invoices and customers via MCP.', 'MCP', 5400),
      ('Vercel Deploy', 'vercel', 'Ship previews straight from the sandbox.', 'Tool', 11300),
      ('PR Reviewer', 'ovidai', 'Auto-review GitHub PRs with fixes.', 'Agent', 15100),
      ('DB Designer', 'community', 'Draw and migrate schemas in chat.', 'Tool', 4700),
      ('Audio Notes', 'community', 'Transcribe meetings into sessions.', 'Tool', 3600),
      ('Tailwind Helper', 'community', 'Tailwind-aware UI generation.', 'Tool', 9800),
      ('Terraform MCP', 'hashicorp', 'Plan and apply infra safely.', 'MCP', 2500),
    ];
    plugins.addAll([
      for (final (n, a, d, c, i) in extra)
        PluginItem(
            name: n,
            author: a,
            description: d,
            version: '1.${(i % 9) + 0}.${i % 7}',
            category: c,
            installs: i),
    ]);

    // --- dummy sessions ---
    final s1 = ChatSession(
      id: 's1',
      title: 'Refactor auth middleware',
      model: 'deepseek-v4-pro',
      messages: [
        Message(
            role: 'user',
            content: 'Can you refactor my Express auth middleware to use JWT rotation?'),
        Message(
          role: 'assistant',
          kind: MsgKind.reasoning,
          thinking: true,
          content: 'Inspecting middleware chain… identifying token verify step…',
        ),
        Message(
          role: 'assistant',
          kind: MsgKind.code,
          lang: 'javascript',
          content: '''const { verify, sign } = require("jsonwebtoken");

function auth(rotate = true) {
  return async (req, res, next) => {
    const token = req.headers.authorization?.split(" ")[1];
    if (!token) return res.status(401).end();
    const payload = verify(token, process.env.JWT_SECRET);
    req.user = payload;
    if (rotate) {
      res.set("x-refresh-token",
        sign({ sub: payload.sub }, process.env.JWT_SECRET, { expiresIn: "15m" }));
    }
    next();
  };
}''',
        ),
        Message(
            role: 'assistant',
            content:
                'Done. I added rotating refresh tokens via the `x-refresh-token` header and cleaned up the verify step. Want me to write tests next?'),
      ],
    );
    final s2 = ChatSession(
      id: 's2',
      title: 'Neural network diagram',
      model: 'Image Studio',
      messages: [
        Message(
            role: 'user',
            content: 'Generate an image: minimal diagram of a neural network, dark background'),
        Message(
          role: 'assistant',
          kind: MsgKind.imageGen,
          content: 'minimal diagram of a neural network, dark background',
        ),
      ],
    );
    final s3 = ChatSession(
      id: 's3',
      title: 'Weekend trip packing list',
      model: 'qwen3-coder-480b',
      messages: [
        Message(role: 'user', content: 'What should I pack for a 2-day trek?'),
        Message(
            role: 'assistant',
            content:
                'Here is a tight 2-day list:\n\n• 2L water + filter\n• Base layer + fleece + shell\n• Headlamp, power bank\n• First aid, blister kit\n• Trail snacks × 6\n• Sleeping bag rated to expected low\n\nWant me to trim it to ultralight?'),
      ],
    );
    sessions.addAll([s1, s2, s3]);
    activeSessionId = s1.id;
  }
}
