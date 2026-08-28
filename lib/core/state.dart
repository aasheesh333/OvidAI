import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'mcp_service.dart';
import 'sandbox_service.dart';

/// ---------- Models ----------

class ProviderConfig {
  final String id;
  String name;
  String description;
  String baseUrl;
  String apiKey;
  bool isFree; // ships free out of the box
  bool custom; // user-added provider
  List<String> models;
  String? selectedModel;
  bool connected;
  final bool requiresApiKey;

  ProviderConfig({
    String? id,
    required this.name,
    required this.description,
    required this.baseUrl,
    this.apiKey = '',
    this.isFree = false,
    this.custom = false,
    List<String>? models,
    this.selectedModel,
    this.connected = false,
    this.requiresApiKey = true,
  }) : id = id ?? _slug(name),
       models = models ?? [];

  bool get hasKey => apiKey.trim().isNotEmpty;
  bool get isConfigured => !requiresApiKey || hasKey;

  Map<String, dynamic> toPersistedJson() => {
    'id': id,
    'name': name,
    'description': description,
    'baseUrl': baseUrl,
    'isFree': isFree,
    'custom': custom,
    'models': models,
    'requiresApiKey': requiresApiKey,
  };
}

String _slug(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

String _baseModel(String value) => value.split('·').first.trim();

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
  String name;
  final String author;
  final String description;
  final String category; // Official / Community / Custom
  String command; // e.g. npx
  List<String> args; // e.g. ['-y', '@modelcontextprotocol/server-filesystem']
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
  MsgKind kind; // mutable — reasoning → text promote
  String content; // mutable — live streaming updates
  final String? lang; // for code blocks
  final DateTime time;
  bool thinking; // mutable — live state

  Message({
    required this.role,
    this.kind = MsgKind.text,
    this.content = '',
    this.lang,
    this.thinking = false,
    DateTime? time,
  }) : time = time ?? DateTime.now();

  factory Message.fromJson(Map<String, dynamic> j) => Message(
    role: j['role'] as String? ?? 'user',
    kind: MsgKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => MsgKind.text,
    ),
    content: j['content'] as String? ?? '',
    lang: j['lang'] as String?,
    thinking: j['thinking'] as bool? ?? false,
    time: j['time'] != null ? DateTime.tryParse(j['time'] as String) : null,
  );

  Map<String, dynamic> toJson() => {
    'role': role,
    'kind': kind.name,
    'content': content,
    if (lang != null) 'lang': lang,
    if (thinking) 'thinking': thinking,
    'time': time.toIso8601String(),
  };
}

class ChatSession {
  final String id;
  String title;
  String model;
  String? providerId;
  final List<Message> messages;
  final DateTime createdAt;

  ChatSession({
    required this.id,
    required this.title,
    required this.model,
    this.providerId,
    List<Message>? messages,
    DateTime? createdAt,
  }) : messages = messages ?? [],
       createdAt = createdAt ?? DateTime.now();

  factory ChatSession.fromJson(Map<String, dynamic> j) => ChatSession(
    id: j['id'] as String,
    title: j['title'] as String? ?? 'New chat',
    model: j['model'] as String? ?? 'Select a provider',
    providerId: j['providerId'] as String?,
    messages:
        (j['messages'] as List?)
            ?.map((m) => Message.fromJson(m as Map<String, dynamic>))
            .toList() ??
        [],
    createdAt: j['createdAt'] != null
        ? DateTime.tryParse(j['createdAt'] as String) ?? DateTime.now()
        : DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'model': model,
    if (providerId != null) 'providerId': providerId,
    'messages': messages.map((m) => m.toJson()).toList(),
    'createdAt': createdAt.toIso8601String(),
  };
}

/// ---------- App state ----------

class AppState extends ChangeNotifier {
  /// Singleton — everything is user-side / on-device.
  static final AppState I = AppState._();
  AppState._() {
    _seed();
    _ensureActiveSession();
  }

  static const _secureStorage = FlutterSecureStorage();
  static const _providerKeyPrefix = 'ovid_provider_key_';
  Future<void>? _initialization;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    await loadProviderState();
    await loadProviderCredentials();
    await loadSessions();
    await _loadLastSelection();
    // Check if the sandbox was installed on a previous launch so the
    // user is never asked to re-install the ~200 MB rootfs.
    if (await SandboxService.I.checkExisting()) {
      sandboxInstalled = true;
    }
  }

  /// Last model the user picked — carried into new sessions (DSH-style
  /// default model) and restored across app restarts.
  String lastSelectedModel = '';
  String? lastSelectedProviderId;

  Future<void> _loadLastSelection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      lastSelectedModel = prefs.getString(_kLastModel) ?? '';
      lastSelectedProviderId = prefs.getString(_kLastProvider);
      // Backfill from the currently-restored active session if nothing
      // was persisted yet (upgrade path for existing installs).
      if (lastSelectedModel.isEmpty) {
        final s = activeSession;
        if (s != null && s.model != 'Select a provider') {
          lastSelectedModel = s.model;
          lastSelectedProviderId = s.providerId;
        }
      }
    } catch (_) {}
  }

  Future<void> _persistLastSelection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (lastSelectedModel.isNotEmpty) {
        await prefs.setString(_kLastModel, lastSelectedModel);
      }
      if (lastSelectedProviderId != null) {
        await prefs.setString(_kLastProvider, lastSelectedProviderId!);
      }
    } catch (_) {}
  }

  static const _kSessions = 'ovid_sessions';
  static const _kActive = 'ovid_active_session';
  static const _kProviders = 'ovid_provider_configs_v1';
  static const _kLastModel = 'ovid_last_model';
  static const _kLastProvider = 'ovid_last_provider';
  Future<void> _providerWrite = Future<void>.value();
  Future<void> _credentialWrite = Future<void>.value();

  Future<void> loadProviderState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kProviders);
      if (raw == null || raw.isEmpty) return;
      final stored = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      for (final entry in stored) {
        final id = entry['id'] as String?;
        if (id == null || id.isEmpty) continue;
        final existing = providerById(id);
        final hasStoredModels = entry.containsKey('models');
        final models =
            (entry['models'] as List?)
                ?.whereType<String>()
                .where((model) => model.isNotEmpty)
                .toList() ??
            <String>[];
        if (existing != null) {
          existing
            ..baseUrl = entry['baseUrl'] as String? ?? existing.baseUrl
            ..models = hasStoredModels ? models : existing.models;
          continue;
        }
        if (entry['custom'] != true) continue;
        providers.add(
          ProviderConfig(
            id: id,
            name: entry['name'] as String? ?? 'Custom provider',
            description:
                entry['description'] as String? ??
                'Custom OpenAI-compatible provider',
            baseUrl: entry['baseUrl'] as String? ?? '',
            custom: true,
            isFree: entry['isFree'] as bool? ?? false,
            models: models,
            requiresApiKey: entry['requiresApiKey'] as bool? ?? true,
          ),
        );
      }
    } catch (_) {
      // Invalid provider metadata must not prevent the app from starting.
    }
  }

  Future<void> persistProviderState() async {
    final encoded = jsonEncode(
      providers.map((provider) => provider.toPersistedJson()).toList(),
    );
    _providerWrite = _providerWrite.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kProviders, encoded);
      } catch (_) {}
    });
    await _providerWrite;
  }

  Future<void> loadProviderCredentials() async {
    try {
      final credentials = await _secureStorage.readAll();
      for (final provider in providers) {
        provider.apiKey =
            credentials['$_providerKeyPrefix${provider.id}']?.trim() ?? '';
      }
      notifyListeners();
    } catch (_) {
      // A device keystore failure must not prevent the app from starting.
    }
  }

  Future<void> loadSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kSessions);
      if (raw != null && raw.isNotEmpty) {
        final loaded = raw
            .map(
              (session) => ChatSession.fromJson(
                jsonDecode(session) as Map<String, dynamic>,
              ),
            )
            .toList();
        sessions
          ..clear()
          ..addAll(loaded);
      }
      activeSessionId = prefs.getString(_kActive);
      if (!sessions.any((s) => s.id == activeSessionId)) {
        activeSessionId = sessions.isEmpty ? null : sessions.first.id;
      }
      for (final session in sessions) {
        session.providerId ??= _inferProviderId(session.model);
      }
      _restoreSelectedModel();
      notifyListeners();
    } catch (_) {
      _ensureActiveSession();
    }
  }

  Future<void> persistSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _kSessions,
        sessions.map((s) => jsonEncode(s.toJson())).toList(),
      );
      if (activeSessionId != null) {
        await prefs.setString(_kActive, activeSessionId!);
      } else {
        await prefs.remove(_kActive);
      }
    } catch (_) {}
  }

  int navIndex = 0; // 0 Chat, 1 Studio, 2 Browser, 3 Plugins, 4 Settings
  bool sandboxInstalled = false; // proot Ubuntu sandbox on-device

  final List<ProviderConfig> providers = [];
  final List<PluginItem> plugins = [];
  final List<McpServer> mcpServers = [];
  final List<String> marketplaces =
      []; // user-added git marketplaces (Claude Code style)
  final List<ChatSession> sessions = [];
  String? activeSessionId;

  ChatSession? get activeSession =>
      sessions.where((s) => s.id == activeSessionId).firstOrNull;

  ProviderConfig get defaultProvider => providers.first;

  ProviderConfig? providerById(String? id) {
    if (id == null) return null;
    for (final provider in providers) {
      if (provider.id == id) return provider;
    }
    return null;
  }

  ProviderConfig? providerForSession([ChatSession? session]) =>
      providerById((session ?? activeSession)?.providerId);

  String? _inferProviderId(String model) {
    final modelId = model.split('·').first.trim();
    if (modelId.isEmpty || modelId == 'Select a provider') return null;
    for (final provider in providers) {
      if (provider.models.contains(modelId)) return provider.id;
    }
    return null;
  }

  void _restoreSelectedModel() {
    final session = activeSession;
    final provider = providerForSession(session);
    if (session != null && provider != null) {
      provider.selectedModel = session.model;
    }
  }

  ChatSession _ensureActiveSession() {
    final existing = activeSession;
    if (existing != null) return existing;
    final session = ChatSession(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: 'New chat',
      model: lastSelectedModel.isEmpty ? 'Select a provider' : lastSelectedModel,
    );
    if (lastSelectedModel.isNotEmpty) {
      session.providerId =
          lastSelectedProviderId ?? _inferProviderId(lastSelectedModel);
    }
    sessions.insert(0, session);
    activeSessionId = session.id;
    return session;
  }

  void setNav(int i) {
    navIndex = i;
    notifyListeners();
  }

  void selectSession(String id) {
    activeSessionId = id;
    notifyListeners();
    persistSessions();
  }

  void newSession() {
    final s = ChatSession(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: 'New chat',
      model: lastSelectedModel.isEmpty ? 'Select a provider' : lastSelectedModel,
    );
    if (lastSelectedModel.isNotEmpty) {
      s.providerId =
          lastSelectedProviderId ?? _inferProviderId(lastSelectedModel);
    }
    sessions.insert(0, s);
    activeSessionId = s.id;
    // Restore the selected-model pointer on the provider.
    if (s.providerId != null) {
      final p = providerById(s.providerId);
      if (p != null) p.selectedModel = s.model;
    }
    notifyListeners();
    persistSessions();
  }

  void deleteSession(String id) {
    sessions.removeWhere((s) => s.id == id);
    if (activeSessionId == id) {
      activeSessionId = sessions.isEmpty ? null : sessions.first.id;
    }
    notifyListeners();
    persistSessions();
  }

  void renameSession(String id, String title) {
    sessions.firstWhere((s) => s.id == id).title = title;
    notifyListeners();
    persistSessions();
  }

  void sendMessage(String text) {
    final s = _ensureActiveSession();
    s.messages.add(Message(role: 'user', content: text));
    // Auto-name session from first message (smart: strip markdown/prompt fluff)
    if (s.title == 'New chat' || s.title.isEmpty) {
      s.title = _autoTitle(text);
    }
    notifyListeners();
    persistSessions();
  }

  static String _autoTitle(String text) {
    var t = text.trim();
    // strip markdown headers, code fences, common prefixes
    t = t.replaceAll(RegExp(r'^[#>`*\-\s]+'), '');
    t = t.replaceFirst(
      RegExp(
        r'^(hey|hi|hello|please|plz|can you|could you|help me|i want|i need|write|make|build|create|generate|explain)\b[,: ]*',
        caseSensitive: false,
      ),
      '',
    );
    t = t.trim();
    if (t.isEmpty) return 'New chat';
    final words = t.split(RegExp(r'\s+'));
    final take = words.take(6).join(' ');
    final title = take.length > 40 ? '${take.substring(0, 40)}…' : take;
    return words.length > 6 && !title.endsWith('…') ? '$title…' : title;
  }

  void removeModel(String providerId, String model) {
    final p = providerById(providerId);
    if (p == null) return;
    p.models.remove(model);
    if (p.selectedModel != null && _baseModel(p.selectedModel!) == model) {
      p.selectedModel = null;
    }
    for (final session in sessions) {
      if (session.providerId == providerId &&
          _baseModel(session.model) == model) {
        session
          ..providerId = null
          ..model = 'Select a provider';
      }
    }
    refresh();
    persistProviderState();
    persistSessions();
  }

  void reconcileProviderModels(String providerId) {
    final provider = providerById(providerId);
    if (provider == null) return;
    if (provider.selectedModel != null &&
        !provider.models.contains(_baseModel(provider.selectedModel!))) {
      provider.selectedModel = null;
    }
    for (final session in sessions) {
      if (session.providerId == providerId &&
          !provider.models.contains(_baseModel(session.model))) {
        session
          ..providerId = null
          ..model = 'Select a provider';
      }
    }
    refresh();
    persistProviderState();
    persistSessions();
  }

  void setModel(String providerId, String model) {
    final provider = providerById(providerId);
    if (provider == null) return;
    provider.selectedModel = model;
    final s = _ensureActiveSession();
    s
      ..providerId = providerId
      ..model = model;
    // Remember as the default for future sessions + restarts.
    lastSelectedModel = model;
    lastSelectedProviderId = providerId;
    _persistLastSelection();
    notifyListeners();
    persistSessions();
  }

  Future<String?> addCustomProvider({
    required String name,
    required String baseUrl,
    String apiKey = '',
  }) async {
    final normalizedName = name.trim();
    final normalizedUrl = baseUrl.trim();
    if (normalizedName.isEmpty) return 'Provider name is required.';
    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return 'Enter a valid absolute base URL.';
    }
    final id = 'custom-${_slug(normalizedName)}';
    if (providers.any((provider) => provider.id == id)) {
      return 'A provider with this name already exists.';
    }
    final provider = ProviderConfig(
      id: id,
      name: normalizedName,
      description: 'Custom OpenAI-compatible provider',
      baseUrl: normalizedUrl,
      apiKey: apiKey.trim(),
      custom: true,
      requiresApiKey: apiKey.trim().isNotEmpty,
    );
    try {
      await updateProviderApiKey(provider, provider.apiKey);
    } catch (_) {
      return 'The API key could not be stored securely on this device.';
    }
    providers.add(provider);
    refresh();
    await persistProviderState();
    return null;
  }

  void updateProviderBaseUrl(ProviderConfig provider, String value) {
    provider.baseUrl = value.trim();
    persistProviderState();
  }

  /// Remove a custom provider by id. Returns an error string on failure,
  /// null on success.
  Future<String?> removeCustomProvider(String providerId) async {
    final p = providerById(providerId);
    if (p == null) return 'Provider not found: $providerId';
    if (!p.custom) {
      return '"${p.name}" is a built-in provider — it cannot be removed, '
          'only its API key can be cleared.';
    }
    // Clean up the stored API key.
    try {
      await _secureStorage.delete(key: '$_providerKeyPrefix${p.id}');
    } catch (_) {}
    // Clear the model from any session using it.
    for (final s in sessions) {
      if (s.providerId == p.id) {
        s
          ..providerId = null
          ..model = 'Select a provider';
      }
    }
    providers.remove(p);
    refresh();
    await persistProviderState();
    await persistSessions();
    return null;
  }

  Future<void> updateProviderApiKey(
    ProviderConfig provider,
    String value,
  ) async {
    provider.apiKey = value.trim();
    refresh();
    final key = '$_providerKeyPrefix${provider.id}';
    final secret = provider.apiKey;
    final write = _credentialWrite.then((_) async {
      if (secret.isEmpty) {
        await _secureStorage.delete(key: key);
      } else {
        await _secureStorage.write(key: key, value: secret);
      }
    });
    _credentialWrite = write.then<void>((_) {}, onError: (_) {});
    await write;
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

  /// Fetch a marketplace.json from a GitHub repo (raw.githubusercontent.com)
  /// and merge any plugin/MCP entries into the catalog. Returns a message
  /// describing what was imported.
  ///
  /// Schema (flexible — any subset of keys):
  /// ```json
  /// {"plugins":[{"name":"...","author":"...","description":"...",
  ///   "version":"1.0","category":"Tool","command":"...","args":[...]}],
  ///  "mcpServers":[{"name":"...","command":"...","args":[...],...}]}
  /// ```
  Future<String> fetchMarketplaceCatalog(String repo) async {
    final normalized = repo.trim();
    if (normalized.isEmpty) return 'Repository name is empty';
    final parts = normalized.split('/');
    if (parts.length < 2) {
      return 'Expected owner/repo (e.g. ovidai/ovid-plugins)';
    }
    final owner = parts[0];
    final name = parts[1];
    final urls = [
      'https://raw.githubusercontent.com/$owner/$name/main/marketplace.json',
      'https://raw.githubusercontent.com/$owner/$name/master/marketplace.json',
      'https://raw.githubusercontent.com/$owner/$name/main/plugins.json',
      'https://raw.githubusercontent.com/$owner/$name/master/plugins.json',
    ];
    for (final url in urls) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final req = await client.getUrl(Uri.parse(url)).timeout(
              const Duration(seconds: 15),
            );
        final res = await req.close().timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) continue;
        // Bounded read (2 MB cap) — marketplace files are small.
        final builder = BytesBuilder();
        await for (final chunk in res) {
          builder.add(chunk);
          if (builder.length > 2 * 1024 * 1024) {
            throw Exception('marketplace.json too large');
          }
        }
        final j =
            jsonDecode(utf8.decode(builder.takeBytes())) as Map<String, dynamic>;
        var importedPlugins = 0;
        var importedMcps = 0;
        final pluginList = j['plugins'] as List?;
        if (pluginList != null) {
          for (final p in pluginList) {
            if (p is! Map) continue;
            final pname = p['name'] as String?;
            if (pname == null) continue;
            if (plugins.any((e) => e.name == pname)) continue;
            plugins.add(PluginItem(
              name: pname,
              author: p['author'] as String? ?? owner,
              description: p['description'] as String? ?? '',
              version: p['version'] as String? ?? '1.0',
              category: p['category'] as String? ?? 'Tool',
              installed: false,
              enabled: false,
              installs: p['installs'] as int? ?? 0,
            ));
            importedPlugins++;
          }
        }
        final mcpList = j['mcpServers'] as List?;
        if (mcpList != null) {
          for (final m in mcpList) {
            if (m is! Map) continue;
            final mname = m['name'] as String?;
            if (mname == null) continue;
            if (mcpServers.any((e) => e.name == mname)) continue;
            mcpServers.add(McpServer(
              name: mname,
              author: m['author'] as String? ?? owner,
              description: m['description'] as String? ?? '',
              category: m['category'] as String? ?? 'Community',
              command: m['command'] as String? ?? 'npx',
              args: (m['args'] as List?)
                      ?.whereType<String>()
                      .toList() ??
                  const [],
              envHint: m['envHint'] as String?,
              source: 'marketplace:$owner/$name',
              custom: true,
            ));
            importedMcps++;
          }
        }
        refresh();
        return 'Imported $importedPlugins plugin(s) and $importedMcps MCP server(s) from $owner/$name';
      } catch (_) {
        continue;
      } finally {
        client.close(force: true);
      }
    }
    return 'No marketplace.json found in $owner/$name (tried main, master, plugins.json)';
  }

  /// ---------- MCP servers ----------
  void toggleMcpServer(McpServer s) {
    s.connected = !s.connected;
    if (s.connected) {
      // Spawn the real MCP server process in the sandbox.
      unawaited(
        McpService.I.connect(s).then((msg) {
          s.connected = McpService.I.isConnected(s.name);
          refresh();
        }),
      );
    } else {
      unawaited(McpService.I.disconnect(s.name));
    }
    refresh();
  }

  void addCustomMcpServer({
    required String name,
    required String command,
    List<String> args = const [],
    String? envHint,
  }) {
    mcpServers.add(
      McpServer(
        name: name.trim(),
        author: 'you',
        description: 'Custom MCP server — connects on demand.',
        category: 'Custom',
        command: command.trim(),
        args: args,
        envHint: envHint,
        source: 'custom',
        custom: true,
      ),
    );
    refresh();
  }

  void removeMcpServer(McpServer s) {
    mcpServers.remove(s);
    refresh();
  }

  /// Update an existing custom MCP server's command/args from edited JSON.
  void updateCustomMcpServer(McpServer s, {
    required String command,
    required List<String> args,
  }) {
    s.command = command;
    s.args = args;
    refresh();
  }

  /// ---------- Built-in catalog ----------
  void _seed() {
    providers.addAll([
      ProviderConfig(
        name: 'OpenAI',
        description: 'GPT and o-series models from the OpenAI platform.',
        baseUrl: 'https://api.openai.com/v1',
        models: ['gpt-4o', 'gpt-4o-mini', 'o3-mini'],
      ),
      ProviderConfig(
        name: 'Anthropic',
        description: 'Claude Opus, Sonnet and Haiku family.',
        baseUrl: 'https://api.anthropic.com/v1',
        models: ['claude-sonnet-4-20250514', 'claude-opus-4-20250514', 'claude-3-7-sonnet-20250219', 'claude-3-5-haiku-20241022'],
      ),
      ProviderConfig(
        name: 'Google Gemini',
        description: 'Gemini series via AI Studio (free tier available).',
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        isFree: true, // AI Studio free tier — bas API key daalo
        models: ['gemini-2.5-pro', 'gemini-2.5-flash', 'gemini-2.0-flash'],
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
        models: ['grok-3', 'grok-3-mini'],
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
        name: 'OpenRouter',
        description: 'One key, 300+ models including free variants.',
        baseUrl: 'https://openrouter.ai/api/v1',
        isFree: true, // :free suffix models — free tier available
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
        baseUrl: 'https://api.cohere.ai/compatibility/v1',
        models: [],
      ),
      ProviderConfig(
        name: 'Ollama (local)',
        description: 'Models fully on-device or LAN, no key needed.',
        baseUrl: 'http://localhost:11434/v1',
        requiresApiKey: false,
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
        installs: 482000,
      ),
      PluginItem(
        name: 'DeepThink Reasoning',
        author: 'ovidai',
        description:
            'Chain-of-thought mode — model thinks step-by-step before replying, shown as collapsible reasoning.',
        version: '1.2.1',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 368000,
      ),
      PluginItem(
        name: 'Image Studio',
        author: 'ovidai',
        description:
            'In-chat image generation and edit via free endpoints (Pollinations / HF Spaces).',
        version: '1.2.0',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 419000,
      ),
      PluginItem(
        name: 'File Reader',
        author: 'ovidai',
        description:
            'Attach PDFs, docs, code files, CSVs — ask questions about them in chat.',
        version: '1.0.9',
        category: 'Tool',
        installed: true,
        enabled: true,
        installs: 301000,
      ),
      PluginItem(
        name: 'Sandbox Runtime',
        author: 'termux',
        description:
            'Full Linux userland on-device: python, node, gcc — isolated and instant.',
        version: '3.1.0',
        category: 'Runtime',
        installed: true,
        enabled: true,
        installs: 90300,
      ),
      PluginItem(
        name: 'MCP Server Hub',
        author: 'modelcontextprotocol',
        description:
            'Connect any Model Context Protocol server: filesystem, github, postgres, puppeteer…',
        version: '2.1.0',
        category: 'MCP',
        installs: 345000,
      ),
      PluginItem(
        name: 'Web Fetch & Reader',
        author: 'ovidai',
        description:
            'Turn any URL into clean markdown for the model — articles, docs, threads.',
        version: '1.0.6',
        category: 'Tool',
        installed: true,
        installs: 517000,
      ),
      PluginItem(
        name: 'Voice Input',
        author: 'ovidai',
        description:
            'Dictate prompts hands-free, on-device speech recognition.',
        version: '0.9.8',
        category: 'Tool',
        installs: 66000,
      ),
      PluginItem(
        name: 'Multi-Model Compare',
        author: 'ovidai',
        description:
            'Send one prompt to up to 3 models side-by-side, pick the best answer.',
        version: '0.7.2',
        category: 'Tool',
        installs: 128000,
      ),
      PluginItem(
        name: 'RAG Memory',
        author: 'ovidai',
        description:
            'Long-term vector memory — the agent remembers your projects and prefs.',
        version: '1.3.0',
        category: 'Tool',
        installs: 228000,
      ),
      PluginItem(
        name: 'Code Runner',
        author: 'sandbox',
        description:
            'Run python/js snippets in chat with output preview — powered by sandbox.',
        version: '1.1.4',
        category: 'Runtime',
        installs: 154000,
      ),
      PluginItem(
        name: 'Git Workbench',
        author: 'ovidai',
        description: 'Clone, branch, commit and push from the Studio IDE.',
        version: '0.8.3',
        category: 'Tool',
        installs: 93000,
      ),
      PluginItem(
        name: 'PR Reviewer',
        author: 'ovidai',
        description: 'Auto-review GitHub PRs with inline fix suggestions.',
        version: '1.0.2',
        category: 'Agent',
        installs: 151000,
      ),
      PluginItem(
        name: 'Web Clipper',
        author: 'ovidai',
        description:
            'Save pages, snippets and notes to a searchable knowledge base.',
        version: '1.1.0',
        category: 'Tool',
        installs: 87000,
      ),
      PluginItem(
        name: 'Translate Pro',
        author: 'ovidai',
        description:
            'Document translation with layout preserved, 100+ languages.',
        version: '2.0.1',
        category: 'Tool',
        installs: 264000,
      ),
      PluginItem(
        name: 'PDF Tools',
        author: 'ovidai',
        description: 'Merge, split, compress, summarize PDFs right in chat.',
        version: '1.5.2',
        category: 'Tool',
        installs: 198000,
      ),
      PluginItem(
        name: 'Data Analyst',
        author: 'ovidai',
        description:
            'Upload CSV/Excel, get charts, trends and insights automatically.',
        version: '1.2.8',
        category: 'Tool',
        installs: 176000,
      ),
      PluginItem(
        name: 'Study Mode',
        author: 'ovidai',
        description:
            'Turn any chat into flashcards, quizzes and spaced-repetition decks.',
        version: '0.9.1',
        category: 'Tool',
        installs: 143000,
      ),
      PluginItem(
        name: 'Meeting Notes',
        author: 'ovidai',
        description:
            'Record or upload audio, get clean minutes and action items.',
        version: '1.1.6',
        category: 'Tool',
        installs: 118000,
      ),
      PluginItem(
        name: 'Prompt Library',
        author: 'ovidai',
        description: 'Community prompts with one-tap use — sorted by task.',
        version: '1.6.0',
        category: 'Tool',
        installs: 231000,
      ),
      PluginItem(
        name: 'Screen Awareness',
        author: 'ovidai',
        description:
            'Ask about anything on your screen — share a screenshot into chat.',
        version: '0.8.5',
        category: 'Tool',
        installs: 74000,
      ),
      PluginItem(
        name: 'Calendar & Tasks',
        author: 'ovidai',
        description:
            'Plan, schedule and get reminders from plain-language chat.',
        version: '1.0.7',
        category: 'Tool',
        installs: 102000,
      ),
    ]);

    // community library (dummy bulk)
    const extra = <(String, String, String, String, int)>[
      // ── Top CLI-used plugins/MCP ──
      (
        'Puppeteer MCP',
        'mcp-community',
        'Headless browser automation for agents.',
        'MCP',
        18200,
      ),
      (
        'Postgres Tools',
        'mcp-community',
        'Query and inspect Postgres databases.',
        'MCP',
        9400,
      ),
      ('Figma Bridge', 'figma', 'Read design frames and tokens.', 'MCP', 12600),
      (
        'Slack Notify',
        'community',
        'Send agent updates to Slack channels.',
        'Tool',
        5100,
      ),
      (
        'Docker-in-Sandbox',
        'sandbox',
        'OCI containers inside the sandbox.',
        'Runtime',
        7700,
      ),
      (
        'Shell History',
        'ovidai',
        'Searchable sandbox terminal history.',
        'Tool',
        3400,
      ),
      (
        'Rust Toolchain',
        'sandbox',
        'cargo + rustc prebuilt for the sandbox.',
        'Runtime',
        4100,
      ),
      (
        'Go Toolchain',
        'sandbox',
        'Go 1.23 toolchain, one tap install.',
        'Runtime',
        3900,
      ),
      (
        'Linear Sync',
        'community',
        'Create and update Linear issues from chat.',
        'Tool',
        2800,
      ),
      (
        'Sentry Watch',
        'community',
        'Pull errors into chat and let agents fix them.',
        'Tool',
        3300,
      ),
      (
        'Stripe MCP',
        'stripe',
        'Payments, invoices and customers via MCP.',
        'MCP',
        5400,
      ),
      (
        'Vercel Deploy',
        'vercel',
        'Ship previews straight from the sandbox.',
        'Tool',
        11300,
      ),
      (
        'DB Designer',
        'community',
        'Draw and migrate schemas in chat.',
        'Tool',
        4700,
      ),
      (
        'Audio Notes',
        'community',
        'Transcribe meetings into sessions.',
        'Tool',
        3600,
      ),
      (
        'Tailwind Helper',
        'community',
        'Tailwind-aware UI generation.',
        'Tool',
        9800,
      ),
      (
        'Terraform MCP',
        'hashicorp',
        'Plan and apply infra safely.',
        'MCP',
        2500,
      ),
      (
        'Notion Sync',
        'community',
        'Two-way sync with Notion databases.',
        'Tool',
        8600,
      ),
      (
        'WhatsApp Bridge',
        'community',
        'Let the agent reply on WhatsApp via template.',
        'Tool',
        6200,
      ),
      (
        'YouTube Summarizer',
        'community',
        'Paste a link, get a summary + chapters.',
        'Tool',
        14700,
      ),
      (
        'Email Drafts',
        'community',
        'Generate and queue emails from chat.',
        'Tool',
        7900,
      ),
      // ── Batch 2: More popular tools/MCP ──
      (
        'Exa Search MCP',
        'exa',
        'Semantic web search — find docs, APIs, papers.',
        'MCP',
        22100,
      ),
      (
        'Playwright MCP',
        'playwright',
        'Modern browser automation with smart waiting.',
        'MCP',
        19800,
      ),
      (
        'Discord MCP',
        'discord-mcp',
        'Read/send Discord messages, manage servers.',
        'MCP',
        8900,
      ),
      (
        'Telegram MCP',
        'telegram',
        'Bot API — send messages, listen to channels.',
        'MCP',
        7200,
      ),
      (
        'Obsidian MCP',
        'obsidian',
        'Read/write Obsidian vault notes.',
        'MCP',
        6600,
      ),
      (
        'Firebase MCP',
        'firebase',
        'Firestore, Auth, Storage — full Firebase access.',
        'MCP',
        5800,
      ),
      (
        'Supabase MCP',
        'supabase',
        'Postgres + Auth + Storage from Supabase.',
        'MCP',
        9100,
      ),
      (
        'Airtable MCP',
        'airtable',
        'Read/write Airtable bases and tables.',
        'MCP',
        4700,
      ),
      (
        'Google Drive MCP',
        'google',
        'Search, read, and upload files to Drive.',
        'MCP',
        12300,
      ),
      (
        'GitLab MCP',
        'gitlab',
        'GitLab repos, MRs, issues — full DevOps.',
        'MCP',
        6100,
      ),
      (
        'Jira MCP',
        'atlassian',
        'Create and update Jira issues and sprints.',
        'MCP',
        8400,
      ),
      (
        'Trello MCP',
        'atlassian',
        'Boards, cards, lists — Trello automation.',
        'MCP',
        3900,
      ),
      (
        'Redis MCP',
        'redis',
        'Key-value store operations and pub/sub.',
        'MCP',
        2100,
      ),
      (
        'MongoDB MCP',
        'mongodb',
        'Document queries, aggregations, indexes.',
        'MCP',
        5400,
      ),
      (
        'S3 MCP',
        'aws',
        'S3 buckets — upload, list, download, presigned URLs.',
        'MCP',
        7600,
      ),
      (
        'Cloudflare MCP',
        'cloudflare',
        'Workers, KV, R2, DNS — edge compute.',
        'MCP',
        4800,
      ),
      (
        'Docker MCP',
        'docker',
        'Manage containers, images, volumes, networks.',
        'MCP',
        9200,
      ),
      (
        'Kubernetes MCP',
        'k8s',
        'Pods, services, deployments — cluster control.',
        'MCP',
        6800,
      ),
      (
        'OpenAI DALL·E MCP',
        'openai',
        'Image generation via DALL·E 3.',
        'MCP',
        11200,
      ),
      (
        'ElevenLabs MCP',
        'elevenlabs',
        'Text-to-speech with realistic voices.',
        'MCP',
        7100,
      ),
      (
        'LangChain MCP',
        'langchain',
        'Chains, agents, memory — full LangChain.',
        'MCP',
        4400,
      ),
      (
        'AutoGPT Bridge',
        'agpt',
        'Chain multiple agents for complex tasks.',
        'MCP',
        3800,
      ),
      (
        'Vector DB MCP',
        'pinecone',
        'Pinecone/Weaviate — vector search & memory.',
        'MCP',
        5200,
      ),
      (
        'Appwrite MCP',
        'appwrite',
        'Auth, DB, storage, functions — backend suite.',
        'MCP',
        3600,
      ),
      (
        'PocketBase MCP',
        'pocketbase',
        'Lightweight backend in a single binary.',
        'MCP',
        2900,
      ),
      (
        'Cal.com MCP',
        'cal',
        'Scheduling, bookings, calendar management.',
        'MCP',
        4100,
      ),
      (
        'Zapier MCP',
        'zapier',
        'Trigger zaps and read automation results.',
        'MCP',
        6300,
      ),
      (
        'Make.com MCP',
        'make',
        'Run Make.com scenarios from agent.',
        'MCP',
        3400,
      ),
      (
        'Bitbucket MCP',
        'atlassian',
        'Repos, PRs, pipelines for Bitbucket.',
        'MCP',
        4200,
      ),
      (
        'Vercel MCP',
        'vercel',
        'Deploy, manage projects, domains via API.',
        'MCP',
        8100,
      ),
      (
        'Railway MCP',
        'railway',
        'Deploy and manage Railway services.',
        'MCP',
        3200,
      ),
      (
        'Heroku MCP',
        'heroku',
        'Dyno management, config vars, addons.',
        'MCP',
        2600,
      ),
      (
        'DigitalOcean MCP',
        'digitalocean',
        'Droplets, App Platform, Spaces, DNS.',
        'MCP',
        5700,
      ),
      (
        'Twilio MCP',
        'twilio',
        'SMS, calls, WhatsApp — messaging APIs.',
        'MCP',
        5100,
      ),
      (
        'Discord Bot Builder',
        'discord-mcp',
        'Build and deploy Discord bots from chat.',
        'Agent',
        7800,
      ),
      (
        'Web Scraper Pro',
        'ovidai',
        'Visual CSS selector → structured data.',
        'Tool',
        12500,
      ),
      (
        'API Tester',
        'ovidai',
        'Build and test REST APIs from chat.',
        'Tool',
        8900,
      ),
      (
        'Regex Builder',
        'ovidai',
        'Natural language → regex with tests.',
        'Tool',
        6700,
      ),
      (
        'SQL Formatter',
        'ovidai',
        'Pretty-print and optimize SQL queries.',
        'Tool',
        5400,
      ),
      (
        'JSON Visualizer',
        'ovidai',
        'Paste JSON → interactive tree explorer.',
        'Tool',
        7600,
      ),
      (
        'Env Manager',
        'ovidai',
        'Manage .env files across repos safely.',
        'Tool',
        4300,
      ),
      (
        'Log Analyzer',
        'ovidai',
        'Parse and explain log files with patterns.',
        'Tool',
        5100,
      ),
      (
        'Git Diff Explain',
        'ovidai',
        'AI explanation of what a diff actually does.',
        'Tool',
        6800,
      ),
      (
        'File Converter',
        'ovidai',
        'Convert between formats: CSV/JSON/YAML/XML.',
        'Tool',
        8200,
      ),
      (
        'QR Generator',
        'ovidai',
        'Generate QR codes for URLs, WiFi, contact cards.',
        'Tool',
        9700,
      ),
      (
        'Password Vault',
        'ovidai',
        'Secure local password manager with autofill.',
        'Tool',
        11400,
      ),
      (
        'SSH Key Manager',
        'ovidai',
        'Generate and manage SSH keys for servers.',
        'Tool',
        5600,
      ),
      (
        'Cron Designer',
        'ovidai',
        'Visual cron schedule builder and explainer.',
        'Tool',
        4600,
      ),
      (
        'Markdown Editor',
        'ovidai',
        'Live-preview markdown editor with export.',
        'Tool',
        6900,
      ),
      (
        'Mermaid Diagrams',
        'ovidai',
        'Flowcharts, sequence diagrams from text.',
        'Tool',
        10300,
      ),
      (
        'Excalidraw Bridge',
        'excalidraw',
        'Draw diagrams in Excalidraw, sync to repo.',
        'Tool',
        4800,
      ),
      (
        'Color Palette Gen',
        'ovidai',
        'Generate accessible color palettes from descriptions.',
        'Tool',
        7900,
      ),
      (
        'Icon Library',
        'ovidai',
        'Search 200k+ icons (Lucide, Material, Feather).',
        'Tool',
        6200,
      ),
      (
        'Font Preview',
        'ovidai',
        'Preview Google Fonts with custom text.',
        'Tool',
        5500,
      ),
      (
        'Code Review AI',
        'ovidai',
        'AI-powered code review with fix suggestions.',
        'Agent',
        13800,
      ),
      (
        'Test Writer',
        'ovidai',
        'Generate unit tests for any function/class.',
        'Agent',
        9400,
      ),
      (
        'README Writer',
        'ovidai',
        'Auto-generate professional README files.',
        'Agent',
        8700,
      ),
      (
        'Changelog Gen',
        'ovidai',
        'Generate changelog from git history.',
        'Agent',
        4500,
      ),
      (
        'Commit Msg Helper',
        'ovidai',
        'AI commit messages following Conventional Commits.',
        'Agent',
        7300,
      ),
      (
        'Issue Triager',
        'ovidai',
        'Categorize and prioritize GitHub issues.',
        'Agent',
        5600,
      ),
      (
        'Release Notes',
        'ovidai',
        'Draft release notes from merged PRs.',
        'Agent',
        6100,
      ),
    ];
    plugins.addAll([
      for (final (n, a, d, c, i) in extra)
        PluginItem(
          name: n,
          author: a,
          description: d,
          version: '1.${(i % 9) + 0}.${i % 7}',
          category: c,
          installs: i,
        ),
    ]);

    // --- MCP servers (official registry + community) ---
    mcpServers.addAll([
      McpServer(
        name: 'Chrome DevTools',
        author: 'ovidai',
        description:
            'Browser automation for the inbuilt browser — navigate, click, type, evaluate JS, read pages. Powers agent web browsing.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@ovidai/chrome-devtools-mcp'],
        connected: true,
      ),
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
      McpServer(
        name: 'Playwright',
        author: 'playwright',
        description:
            'Modern browser automation with smart waiting — faster than Puppeteer.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@playwright/mcp'],
      ),
      McpServer(
        name: 'GitLab',
        author: 'gitlab',
        description: 'GitLab repos, merge requests, CI pipelines.',
        category: 'Community',
        command: 'npx',
        args: ['-y', '@smithery/gitlab-mcp'],
        envHint: 'GITLAB_TOKEN',
      ),
      McpServer(
        name: 'Google Drive',
        author: 'google',
        description: 'Search, read, and upload files to Google Drive.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@google/mcp-drive'],
        envHint: 'GOOGLE_TOKEN',
      ),
      McpServer(
        name: 'Firebase',
        author: 'firebase',
        description: 'Firestore, Auth, Storage — full Firebase SDK access.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@firebase/mcp'],
        envHint: 'FIREBASE_CONFIG',
      ),
      McpServer(
        name: 'Supabase',
        author: 'supabase',
        description: 'Postgres + Auth + Storage from Supabase.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@supabase/mcp'],
        envHint: 'SUPABASE_URL,SUPABASE_KEY',
      ),
      McpServer(
        name: 'Vercel',
        author: 'vercel',
        description: 'Deploy, manage projects, domains via Vercel API.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@vercel/mcp'],
        envHint: 'VERCEL_TOKEN',
      ),
      McpServer(
        name: 'Docker',
        author: 'docker',
        description: 'Manage containers, images, volumes, networks.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@docker/mcp'],
      ),
      McpServer(
        name: 'Kubernetes',
        author: 'k8s',
        description: 'Pods, services, deployments — cluster control.',
        category: 'Community',
        command: 'npx',
        args: ['-y', '@k8s/mcp'],
      ),
      McpServer(
        name: 'MongoDB',
        author: 'mongodb',
        description: 'Document queries, aggregations, indexes.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@mongodb/mcp'],
        envHint: 'MONGODB_URI',
      ),
      McpServer(
        name: 'Redis',
        author: 'redis',
        description: 'Key-value store operations and pub/sub.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@redis/mcp'],
        envHint: 'REDIS_URL',
      ),
      McpServer(
        name: 'S3',
        author: 'aws',
        description: 'S3 buckets — upload, list, download, presigned URLs.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@aws/mcp-s3'],
        envHint: 'AWS_ACCESS_KEY,AWS_SECRET_KEY',
      ),
      McpServer(
        name: 'Notion',
        author: 'notion',
        description: 'Two-way sync with Notion databases and pages.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@notion/mcp'],
        envHint: 'NOTION_TOKEN',
      ),
      McpServer(
        name: 'Linear',
        author: 'linear',
        description: 'Create and update Linear issues and projects.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@linear/mcp'],
        envHint: 'LINEAR_API_KEY',
      ),
      McpServer(
        name: 'Figma',
        author: 'figma',
        description: 'Read design frames, tokens, and export assets.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@figma/mcp'],
        envHint: 'FIGMA_TOKEN',
      ),
      McpServer(
        name: 'OpenAI DALL·E',
        author: 'openai',
        description: 'Image generation via DALL·E 3.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@openai/mcp-dalle'],
        envHint: 'OPENAI_API_KEY',
      ),
      McpServer(
        name: 'ElevenLabs',
        author: 'elevenlabs',
        description: 'Text-to-speech with realistic AI voices.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@elevenlabs/mcp'],
        envHint: 'ELEVENLABS_API_KEY',
      ),
      McpServer(
        name: 'Twilio',
        author: 'twilio',
        description: 'SMS, calls, WhatsApp — messaging APIs.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@twilio/mcp'],
        envHint: 'TWILIO_ACCOUNT_SID,TWILIO_AUTH_TOKEN',
      ),
      McpServer(
        name: 'Discord',
        author: 'discord',
        description: 'Read/send Discord messages, manage servers.',
        category: 'Community',
        command: 'npx',
        args: ['-y', '@discord/mcp'],
        envHint: 'DISCORD_TOKEN',
      ),
      McpServer(
        name: 'Jira',
        author: 'atlassian',
        description: 'Create and update Jira issues and sprints.',
        category: 'Official',
        command: 'npx',
        args: ['-y', '@atlassian/mcp-jira'],
        envHint: 'JIRA_TOKEN',
      ),
      McpServer(
        name: 'Obsidian',
        author: 'obsidian',
        description: 'Read/write Obsidian vault notes.',
        category: 'Community',
        command: 'npx',
        args: ['-y', '@obsidian/mcp'],
      ),
    ]);

    // user-added marketplaces (Claude Code style)
    marketplaces.addAll(['ovidai/ovid-plugins']);
  }
}
