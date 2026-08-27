import 'package:flutter/foundation.dart';
import 'sandbox_service.dart';

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

/// MCP server entry — separate from plugins because lifecycle is different
/// (running process, JSON-RPC over stdin/stdout, on-demand connect).
class McpServer {
  final String name;
  final String author;
  final String description;
  final String category; // Official / Community / Custom
  final String command; // e.g. npx
  final List<String> args; // e.g. ['-y', '@modelcontextprotocol/server-filesystem']
  final String? envHint; // env var needed, e.g. 'GITHUB_TOKEN'
  final String source; // registry.modelcontextprotocol.io | mcp.so | custom
  bool connected;
  bool custom;

  McpServer({
    required this.name,
    required this.author,
    required this.description,
    required this.category,
    required this.command,
    this.args = const [],
    this.envHint,
    this.source = 'registry.modelcontextprotocol.io',
    this.connected = false,
    this.custom = false,
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
  bool sandboxInstalled = false; // proot Ubuntu sandbox on-device

  final List<ProviderConfig> providers = [];
  final List<PluginItem> plugins = [];
  final List<McpServer> mcpServers = [];
  final List<String> marketplaces = []; // user-added git marketplaces (Claude Code style)
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
      model: defaultProvider.selectedModel ?? 'Select a provider',
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
    notifyListeners();
  }

  void receiveDemoReply(String text) {
    final s = activeSession;
    if (s == null) return;
    s.messages.add(Message(
      role: 'assistant',
      kind: MsgKind.reasoning,
      thinking: true,
      content: 'Analyzing intent, planning tool usage, drafting response…',
    ));
    s.messages.add(Message(
      role: 'assistant',
      content: '''Here is a demo reply from Ovid.

**What just happened**
- Your prompt was received: "$text"
- A reasoning step ran first (you can toggle it in Settings)
- Once you add a key in **Settings → Providers**, replies stream live from the real model

**Try next**
1. Open the model picker (top) and pick an effort variant
2. Tap `</>` for Studio or 🌐 for Browser
3. Paste an API key — everything stays on-device''',
    ));
    notifyListeners();
  }

  void removeModel(String provider, String model) {
    final p = providers.firstWhere((p) => p.name == provider);
    p.models.remove(model);
    if (p.selectedModel == model) p.selectedModel = null;
    refresh();
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

  /// ---------- Marketplaces (Claude Code style git repos) ----------

  void sandboxReady() {
    sandboxInstalled = SandboxService.I.isInstalled;
    refresh();
  }

  bool addMarketplace(String repo) {
    final r = repo.trim();
    if (r.isEmpty) return false;
    // Normalize: accept full URL or owner/repo
    String normalized = r
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'^www\.'), '')
        .replaceFirst(RegExp(r'^github\.com/'), '')
        .replaceFirst(RegExp(r'\.git$'), '');
    if (marketplaces.contains(normalized)) return false;
    marketplaces.add(normalized);
    refresh();
    return true;
  }

  void removeMarketplace(String repo) {
    marketplaces.remove(repo);
    refresh();
  }

  /// ---------- MCP servers ----------

  void toggleMcpServer(McpServer s) {
    s.connected = !s.connected;
    refresh();
  }

  void addCustomMcpServer({
    required String name,
    required String command,
    List<String> args = const [],
    String? envHint,
  }) {
    mcpServers.add(McpServer(
      name: name.trim(),
      author: 'you',
      description: 'Custom MCP server — connects on demand.',
      category: 'Custom',
      command: command.trim(),
      args: args,
      envHint: envHint,
      source: 'custom',
      custom: true,
    ));
    refresh();
  }

  void removeMcpServer(McpServer s) {
    mcpServers.remove(s);
    refresh();
  }

  /// ---------- Dummy content ----------
  void _seed() {
    providers.addAll([
      ProviderConfig(
        name: 'OpenAI',
        description: 'GPT-5, o4 and the full OpenAI platform.',
        baseUrl: 'https://api.openai.com/v1',
        models: ['gpt-5.2', 'o4-mini'],
      ),
      ProviderConfig(
        name: 'Anthropic',
        description: 'Claude Opus, Sonnet and Haiku family.',
        baseUrl: 'https://api.anthropic.com/v1',
        models: ['claude-opus-4-6', 'claude-sonnet-4-6'],
      ),
      ProviderConfig(
        name: 'Google Gemini',
        description: 'Gemini 2.5 series via AI Studio (free tier available).',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        models: ['gemini-2.5-pro', 'gemini-2.5-flash'],
      ),
      ProviderConfig(
        name: 'DeepSeek',
        description: 'DeepSeek chat & reasoner, direct API.',
        baseUrl: 'https://api.deepseek.com/v1',
        models: ['deepseek-chat', 'deepseek-reasoner'],
      ),
      ProviderConfig(
        name: 'xAI',
        description: 'Grok family from xAI.',
        baseUrl: 'https://api.x.ai/v1',
        models: ['grok-4', 'grok-4-fast'],
      ),
      ProviderConfig(
        name: 'Mistral AI',
        description: 'Mistral Large, Codestral and open weights.',
        baseUrl: 'https://api.mistral.ai/v1',
        models: ['mistral-large-latest', 'codestral-latest'],
      ),
      ProviderConfig(
        name: 'NVIDIA NIM',
        description:
            'Free credits for hosted open models: Llama, DeepSeek, Qwen, Mistral on build.nvidia.com.',
        baseUrl: 'https://integrate.api.nvidia.com/v1',
        isFree: true,
        models: [
          'meta/llama-3.3-70b-instruct',
          'deepseek-ai/deepseek-r1',
          'qwen/qwen2.5-coder-32b-instruct',
          'mistralai/mistral-nemotron',
        ],
      ),
      ProviderConfig(
        name: 'Groq',
        description: 'Ultra-fast LPU inference. Free tier available.',
        baseUrl: 'https://api.groq.com/openai/v1',
        isFree: true,
        models: ['llama-3.3-70b-versatile', 'openai/gpt-oss-120b'],
      ),
      ProviderConfig(
        name: 'Cerebras',
        description: 'Wafer-scale speed. Free tier available.',
        baseUrl: 'https://api.cerebras.ai/v1',
        isFree: true,
        models: ['llama-3.3-70b'],
      ),
      ProviderConfig(
        name: 'GitHub Models',
        description: 'Free tier models with a GitHub token.',
        baseUrl: 'https://models.github.ai/inference',
        isFree: true,
        models: ['gpt-4.1', 'DeepSeek-R1'],
      ),
      ProviderConfig(
        name: 'Mistral AI',
        description: 'Mistral Large, Codestral and open weights. Free experiment tier.',
        baseUrl: 'https://api.mistral.ai/v1',
        models: ['mistral-large-latest', 'codestral-latest'],
      ),
      ProviderConfig(
        name: 'OpenRouter',
        description: 'One key, 300+ models including free variants.',
        baseUrl: 'https://openrouter.ai/api/v1',
        models: ['deepseek/deepseek-chat-v3.1', 'meta-llama/llama-4-maverick'],
      ),
      ProviderConfig(
        name: 'Together AI',
        description: 'Fast inference for open models.',
        baseUrl: 'https://api.together.xyz/v1',
        models: [],
      ),
      ProviderConfig(
        name: 'Fireworks AI',
        description: 'Serverless open-model inference.',
        baseUrl: 'https://api.fireworks.ai/inference/v1',
        models: [],
      ),
      ProviderConfig(
        name: 'Perplexity',
        description: 'Sonar models with live web access.',
        baseUrl: 'https://api.perplexity.ai',
        models: ['sonar-pro', 'sonar'],
      ),
      ProviderConfig(
        name: 'Cohere',
        description: 'Command and Embed models.',
        baseUrl: 'https://api.cohere.com/v2',
        models: [],
      ),
      ProviderConfig(
        name: 'Ollama (local)',
        description: 'Models fully on-device or LAN, no key needed.',
        baseUrl: 'http://localhost:11434/v1',
        models: [],
      ),
    ]);

    plugins.addAll([
      // --- Core tools (DeepSeek web style: everything works out of the box) ---
      PluginItem(
          name: 'Web Search',
          author: 'ovidai',
          description:
              'Live web results with citations inside every chat. Free, no key.',
          version: '1.4.0',
          category: 'Tool',
          installed: true,
          enabled: true,
          installs: 482000),
      PluginItem(
          name: 'DeepThink Reasoning',
          author: 'ovidai',
          description:
              'Chain-of-thought mode — model thinks step-by-step before replying, shown as collapsible reasoning.',
          version: '1.2.1',
          category: 'Tool',
          installed: true,
          enabled: true,
          installs: 368000),
      PluginItem(
          name: 'Image Studio',
          author: 'ovidai',
          description:
              'In-chat image generation and edit via free endpoints (Pollinations / HF Spaces).',
          version: '1.2.0',
          category: 'Tool',
          installed: true,
          enabled: true,
          installs: 419000),
      PluginItem(
          name: 'File Reader',
          author: 'ovidai',
          description:
              'Attach PDFs, docs, code files, CSVs — ask questions about them in chat.',
          version: '1.0.9',
          category: 'Tool',
          installed: true,
          enabled: true,
          installs: 301000),
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
          installs: 345000),
      PluginItem(
          name: 'Web Fetch & Reader',
          author: 'ovidai',
          description:
              'Turn any URL into clean markdown for the model — articles, docs, threads.',
          version: '1.0.6',
          category: 'Tool',
          installed: true,
          installs: 517000),
      PluginItem(
          name: 'Voice Input',
          author: 'ovidai',
          description:
              'Dictate prompts hands-free, on-device speech recognition.',
          version: '0.9.8',
          category: 'Tool',
          installs: 66000),
      PluginItem(
          name: 'Multi-Model Compare',
          author: 'ovidai',
          description:
              'Send one prompt to up to 3 models side-by-side, pick the best answer.',
          version: '0.7.2',
          category: 'Tool',
          installs: 128000),
      PluginItem(
          name: 'RAG Memory',
          author: 'ovidai',
          description:
              'Long-term vector memory — the agent remembers your projects and prefs.',
          version: '1.3.0',
          category: 'Tool',
          installs: 228000),
      PluginItem(
          name: 'Code Runner',
          author: 'sandbox',
          description:
              'Run python/js snippets in chat with output preview — powered by sandbox.',
          version: '1.1.4',
          category: 'Runtime',
          installs: 154000),
      PluginItem(
          name: 'Git Workbench',
          author: 'ovidai',
          description:
              'Clone, branch, commit and push from the Studio IDE.',
          version: '0.8.3',
          category: 'Tool',
          installs: 93000),
      PluginItem(
          name: 'PR Reviewer',
          author: 'ovidai',
          description:
              'Auto-review GitHub PRs with inline fix suggestions.',
          version: '1.0.2',
          category: 'Agent',
          installs: 151000),
      PluginItem(
          name: 'Web Clipper',
          author: 'ovidai',
          description:
              'Save pages, snippets and notes to a searchable knowledge base.',
          version: '1.1.0',
          category: 'Tool',
          installs: 87000),
      PluginItem(
          name: 'Translate Pro',
          author: 'ovidai',
          description:
              'Document translation with layout preserved, 100+ languages.',
          version: '2.0.1',
          category: 'Tool',
          installs: 264000),
      PluginItem(
          name: 'PDF Tools',
          author: 'ovidai',
          description:
              'Merge, split, compress, summarize PDFs right in chat.',
          version: '1.5.2',
          category: 'Tool',
          installs: 198000),
      PluginItem(
          name: 'Data Analyst',
          author: 'ovidai',
          description:
              'Upload CSV/Excel, get charts, trends and insights automatically.',
          version: '1.2.8',
          category: 'Tool',
          installs: 176000),
      PluginItem(
          name: 'Study Mode',
          author: 'ovidai',
          description:
              'Turn any chat into flashcards, quizzes and spaced-repetition decks.',
          version: '0.9.1',
          category: 'Tool',
          installs: 143000),
      PluginItem(
          name: 'Meeting Notes',
          author: 'ovidai',
          description:
              'Record or upload audio, get clean minutes and action items.',
          version: '1.1.6',
          category: 'Tool',
          installs: 118000),
      PluginItem(
          name: 'Prompt Library',
          author: 'ovidai',
          description:
              'Community prompts with one-tap use — sorted by task.',
          version: '1.6.0',
          category: 'Tool',
          installs: 231000),
      PluginItem(
          name: 'Screen Awareness',
          author: 'ovidai',
          description:
              'Ask about anything on your screen — share a screenshot into chat.',
          version: '0.8.5',
          category: 'Tool',
          installs: 74000),
      PluginItem(
          name: 'Calendar & Tasks',
          author: 'ovidai',
          description:
              'Plan, schedule and get reminders from plain-language chat.',
          version: '1.0.7',
          category: 'Tool',
          installs: 102000),
    ]);

    // community library (dummy bulk)
    const extra = <(String, String, String, String, int)>[
      ('Puppeteer MCP', 'mcp-community', 'Headless browser automation for agents.', 'MCP', 18200),
      ('Postgres Tools', 'mcp-community', 'Query and inspect Postgres databases.', 'MCP', 9400),
      ('Figma Bridge', 'figma', 'Read design frames and tokens.', 'MCP', 12600),
      ('Slack Notify', 'community', 'Send agent updates to Slack channels.', 'Tool', 5100),
      ('Docker-in-Sandbox', 'sandbox', 'OCI containers inside the sandbox.', 'Runtime', 7700),
      ('Shell History', 'ovidai', 'Searchable sandbox terminal history.', 'Tool', 3400),
      ('Rust Toolchain', 'sandbox', 'cargo + rustc prebuilt for the sandbox.', 'Runtime', 4100),
      ('Go Toolchain', 'sandbox', 'Go 1.23 toolchain, one tap install.', 'Runtime', 3900),
      ('Linear Sync', 'community', 'Create and update Linear issues from chat.', 'Tool', 2800),
      ('Sentry Watch', 'community', 'Pull errors into chat and let agents fix them.', 'Tool', 3300),
      ('Stripe MCP', 'stripe', 'Payments, invoices and customers via MCP.', 'MCP', 5400),
      ('Vercel Deploy', 'vercel', 'Ship previews straight from the sandbox.', 'Tool', 11300),
      ('DB Designer', 'community', 'Draw and migrate schemas in chat.', 'Tool', 4700),
      ('Audio Notes', 'community', 'Transcribe meetings into sessions.', 'Tool', 3600),
      ('Tailwind Helper', 'community', 'Tailwind-aware UI generation.', 'Tool', 9800),
      ('Terraform MCP', 'hashicorp', 'Plan and apply infra safely.', 'MCP', 2500),
      ('Notion Sync', 'community', 'Two-way sync with Notion databases.', 'Tool', 8600),
      ('WhatsApp Bridge', 'community', 'Let the agent reply on WhatsApp via template.', 'Tool', 6200),
      ('YouTube Summarizer', 'community', 'Paste a link, get a summary + chapters.', 'Tool', 14700),
      ('Email Drafts', 'community', 'Generate and queue emails from chat.', 'Tool', 7900),
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

    // --- MCP servers (official registry + community) ---
    mcpServers.addAll([
      McpServer(
        name: 'Filesystem',
        author: 'modelcontextprotocol',
        description:
            'Read, write and search files in folders you share with the agent.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-filesystem'],
      ),
      McpServer(
        name: 'GitHub',
        author: 'modelcontextprotocol',
        description:
            'Repos, issues, PRs and actions — full GitHub access for your agent.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-github'],
        envHint: 'GITHUB_TOKEN',
      ),
      McpServer(
        name: 'Fetch',
        author: 'modelcontextprotocol',
        description:
            'Fetch web pages and convert them to clean markdown for the model.',
        category: 'Official',
        command: 'uvx',
        args: ['mcp-server-fetch'],
      ),
      McpServer(
        name: 'Memory',
        author: 'modelcontextprotocol',
        description:
            'Long-term memory graph — the agent remembers across sessions.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-memory'],
      ),
      McpServer(
        name: 'Puppeteer',
        author: 'modelcontextprotocol',
        description:
            'Headless browser automation — click, scroll, screenshot, scrape.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-puppeteer'],
      ),
      McpServer(
        name: 'Postgres',
        author: 'modelcontextprotocol',
        description:
            'Read-only schema inspection and safe queries on your database.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@modelcontextprotocol/server-postgres'],
        envHint: 'DATABASE_URL',
      ),
      McpServer(
        name: 'Brave Search',
        author: 'smithery-ai',
        description: 'Live web search results straight into the chat.',
        category: 'Community',
        command: 'npx',
        args: ['-y', '@smithery/brave-search'],
        envHint: 'BRAVE_API_KEY',
      ),
      McpServer(
        name: 'Slack',
        author: 'community',
        description: 'Send and read Slack messages from your workspace.',
        category: 'Community',
        command: 'npx',
        args: ['-y', '@smithery/slack-mcp'],
        envHint: 'SLACK_TOKEN',
      ),
    ]);

    // user-added marketplaces (Claude Code style)
    marketplaces.addAll([
      'ovidai/ovid-plugins',
    ]);

    // --- dummy sessions ---
    final s1 = ChatSession(
      id: 's1',
      title: 'Refactor auth middleware',
      model: 'deepseek-chat',
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
      model: 'gemini-2.5-flash',
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
