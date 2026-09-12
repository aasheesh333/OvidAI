import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../core/agent_service.dart';
import '../core/hook_service.dart';
import '../core/mcp_config_parse.dart';
import '../core/plugin_manifest.dart';
import '../core/plugin_registry.dart';
import '../core/plugin_runtime.dart';
import '../core/plugin_source_resolver.dart';
import '../core/sandbox_service.dart';
import '../core/startup_coordinator.dart';
import '../core/theme.dart';
import '../core/state.dart';
import 'plugin_permission_sheet.dart';
import 'startup_progress_panel.dart';

/// Agent tools a plugin contributes when installed+enabled — mirrors the
/// `_tools` gate in AgentService so the install snackbar can report what
/// the model actually gained (the plugin registry honest-install parity).
String? _toolGainsFor(PluginItem p) {
  final seed = switch (p.name) {
    'Web Search' => 'web_search',
    'Image Studio' => 'generate_image',
    'File Reader' => 'read_attachment',
    'Web Fetch & Reader' => 'fetch_url',
    'Code Runner' => 'run_code',
    'RAG Memory' => 'memory_search, memory_save',
    'DeepThink Reasoning' => 'reasoning display',
    'Sandbox Runtime' => 'run_shell, fs tools',
    _ => null,
  };
  if (seed != null) return seed;
  if (p.category == 'MCP') {
    // Fix round 1 (Task 10 finding 1): same gating as the roster's
    // _mcpProxyTool — the proxy tool exists only while the plugin's
    // matching MCP server row does. No server row → no claimed gain.
    final hasServer = AppState.I.mcpServers.any(
      (s) => s.name.toLowerCase() == p.name.toLowerCase(),
    );
    return hasServer ? 'mcp (proxy)' : null;
  }
  final tools = AgentService.I.pluginToolNames(p);
  if (tools.isNotEmpty) {
    return tools.join(', ');
  }
  return null;
}

@visibleForTesting
String? toolGainsForTest(PluginItem p) => _toolGainsFor(p);

/// Task 10 (spec §10): why an MCP server cannot run on this device right
/// now, or null when nothing structurally blocks it. Displayed as
/// `Unsupported on this device: <reason>` on the MCP cards — never a
/// binary connected/not-connected. Deep runtime probing (node/python
/// present) is connect()'s job; this is the structural Android gate.
String? mcpUnsupportedReason(McpServer s) {
  if (s.transport == 'stdio' && !SandboxService.I.isInstalled) {
    final needs = s.command == 'npx' || s.command == 'node'
        ? 'nodejs+npm'
        : s.command == 'uvx' || s.command == 'uv'
        ? 'python+uv'
        : 'a Linux runtime';
    return 'sandbox not installed — stdio MCP servers spawn inside the '
        'on-device sandbox and need $needs there';
  }
  return null;
}

/// Durable canonical startup status for a runtime plugin row, or null when
/// the row has no normalized runtime id. The Plugins screen consumes this
/// instead of inferring readiness from `installed`/`enabled`.
///
/// Legacy (`runtimeId`-null) rows are not stored under the canonical status
/// store, so a row carrying the persisted `migrationRequired` marker surfaces
/// its own state + scrubbed reason here. This is a direct read of the stored
/// marker, never an inference from `installed`/`enabled`.
PluginRuntimeStatus? durablePluginStatus(PluginItem p) {
  final runtimeId = p.runtimeId;
  if (runtimeId != null) return AppState.I.statusFor(runtimeId);
  if (!p.migrationRequired) return null;
  final identity = p.source ?? p.marketplace ?? p.name;
  return PluginRuntimeStatus(
    pluginId: 'legacy:$identity',
    state: StartupItemState.migrationRequired,
    reason: p.runtimeReason,
  );
}

/// Durable canonical startup status for an MCP server, or null.
PluginRuntimeStatus? durableMcpStatus(McpServer s) =>
    AppState.I.statusFor(s.canonicalId);

/// Durable-only status copy for an MCP server (spec §5.3, Task 3): the
/// persisted canonical label · reason, or the neutral no-record copy.
/// Never reads serviceStatus or connected.
String mcpDurableStatusText(McpServer s) {
  final durable = durableMcpStatus(s);
  if (durable == null) return 'Not started';
  final label = startupItemStateLabel(durable.state);
  final reason = durable.reason;
  return reason == null || reason.isEmpty ? label : '$label · $reason';
}

/// Trailing status icon for a durable record (spec §6.2). A durable `Ready`
/// is the only source of a green check for runtime rows.
Widget durableStatusIcon(PluginRuntimeStatus status) {
  final label = startupItemStateLabel(status.state);
  final tooltip = status.reason == null || status.reason!.isEmpty
      ? label
      : '$label · ${status.reason}';
  switch (status.state) {
    case StartupItemState.ready:
      return const Icon(
        Icons.check_circle_outline,
        size: 18,
        color: Aether.success,
      );
    case StartupItemState.queued:
    case StartupItemState.running:
      return const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Aether.accent,
        ),
      );
    case StartupItemState.failed:
    case StartupItemState.unsupported:
      return Tooltip(
        message: tooltip,
        child: Icon(
          Icons.error_outline,
          size: 18,
          color: Aether.dangerC,
        ),
      );
    case StartupItemState.degraded:
    case StartupItemState.skipped:
    case StartupItemState.needsSetup:
    case StartupItemState.migrationRequired:
      return Tooltip(
        message: tooltip,
        child: const Icon(
          Icons.warning_amber,
          size: 18,
          color: Aether.accent,
        ),
      );
    case StartupItemState.disabled:
      return Icon(
        Icons.power_settings_new,
        size: 18,
        color: Aether.textFaint,
      );
  }
}

// ── Task 11 test seams ──────────────────────────────────────────────

/// Test seam: observes every (source, manifest) pair the UI's single
/// install flow inspects. Null in production.
@visibleForTesting
class PluginInspectRecorderForTest {
  /// Recorded by the production install flow's inspection hop:
  /// (source, manifest) per call.
  static void Function(PluginSource source, NormalizedPluginManifest? manifest)?
  record;
}

/// Inspected manifests captured by the production flow for test
/// assertions (cleared per test in setUp/tearDown).
@visibleForTesting
final List<NormalizedPluginManifest> inspectResultsForTest = [];

/// Test seam: records runtime-manager operations invoked from the
/// Plugins UI ('retry' / 'disable' / 'uninstall' / 'edit-grants').
@visibleForTesting
class PluginRuntimeCallRecorderForTest {
  static void Function(String op)? record;
}

/// Task 11 (spec §11): the ONE production install flow behind every
/// entry point (marketplace row, GitHub repo, local folder, ZIP, npm,
/// pasted JSON/TOML, stdio, HTTP). Inspect → consolidated approval
/// sheet → atomic install transaction via [AppState.installPlugin].
///
/// Pass a catalog [plugin] row to sync it with the install, or null to
/// install a source the catalog has no row for (the row is created).
/// Returns the transaction result, or null when the user cancelled /
/// no approval (nothing changed — cancel leaves NO state).
Future<PluginInstallResult?> startPluginInstallForTest(
  AppState app,
  PluginItem? plugin, {
  required PluginSource source,
}) async {
  PluginInspection inspection;
  try {
    inspection = await PluginRuntimeManager.I.inspect(source);
  } catch (e) {
    return PluginInstallResult.failed(error: 'source resolution failed: $e');
  }
  PluginInspectRecorderForTest.record?.call(source, inspection.manifest);
  inspectResultsForTest.add(inspection.manifest);

  // One consolidated capability + dependency approval (Task 5 sheet).
  // An unchanged-digest grant reuses silently; anything else prompts.
  var grant = await AppState.pluginPermissions.effectiveGrant(
    pluginId: inspection.manifest.id,
    manifest: inspection.manifest,
  );
  final scaffoldContext = _pluginInstallSheetContext;
  if (grant == null) {
    if (scaffoldContext == null) {
      // No UI context (agent/test path): fail closed, never auto-approve.
      inspection.discard();
      return PluginInstallResult.failed(
        error: 'capability approval required before install',
      );
    }
    if (!scaffoldContext.mounted) {
      inspection.discard();
      return null;
    }
    // ignore: use_build_context_synchronously
    final accepted = await showPluginPermissionSheet(
      scaffoldContext,
      manifest: inspection.manifest,
    );
    if (accepted != true) {
      inspection.discard();
      return null; // cancelled — no state
    }
    grant = await AppState.pluginPermissions.effectiveGrant(
      pluginId: inspection.manifest.id,
      manifest: inspection.manifest,
    );
  }

  PluginItem row = plugin ?? _catalogRowFor(inspection.manifest);
  // Single-inspection flow (review C1): the approved inspection passes
  // straight through — no re-resolve, no second staging. The manager
  // consumes staging on success and discards it on failure, so there is
  // nothing left here to discard either way; a null result (no derivable
  // source) cannot happen for an already-inspected flow.
  final result = await app.installPlugin(
    row,
    inspection: inspection,
    origin: PluginInstallOrigin.pluginsScreen,
  );
  if (result == null) {
    // No row to sync — remember the runtime install anyway.
    inspection.discard();
    return PluginInstallResult.failed(
      error: 'install failed: no catalog row could be derived',
    );
  }
  return result;
}

/// The BuildContext hosting the install flow's approval sheet. Assigned
/// by the detail-screen install button before starting the flow (the
/// sheet needs a context that outlives the button's onPressed frame).
BuildContext? _pluginInstallSheetContext;

/// Find (or create) the catalog row for an inspected manifest so the
/// runtime install is visible in the Plugins list.
PluginItem _catalogRowFor(NormalizedPluginManifest manifest) {
  final app = AppState.I;
  final existing = app.plugins
      .where((p) => p.runtimeId == manifest.id)
      .firstOrNull;
  if (existing != null) return existing;
  final row = PluginItem(
    name: manifest.name.isEmpty ? manifest.id : manifest.name,
    author: manifest.id.contains('/') ? manifest.id.split('/').first : '',
    description: 'Installed from ${manifest.format.name} source',
    version: manifest.version,
    category: 'Tool',
    source: null,
  );
  app.plugins.add(row);
  return row;
}

/// Task 11 (spec §11): the activation badge — This session, Restart to
/// enable everywhere, Global, Degraded, Failed, Disabled. Returns null
/// when the row carries no runtime activation (legacy flag-flip rows
/// keep their existing chips).
Widget? pluginActivationBadge(PluginItem plugin) {
  if (plugin.runtimeId == null) return null;
  final (String?, Color?) badgeSpec = switch (plugin.activation) {
    PluginActivation.sessionActive => ('This session', Aether.accent),
    PluginActivation.pendingGlobal => (
      'Restart to enable everywhere',
      Aether.warn,
    ),
    PluginActivation.globalActive => ('Global', Aether.success),
    PluginActivation.degraded => ('Degraded', Aether.warn),
    PluginActivation.failed => ('Failed', Aether.danger),
    PluginActivation.disabled => (null, null),
  };
  final label = badgeSpec.$1;
  if (label == null) return null;
  return Tag(label, color: badgeSpec.$2 ?? Aether.textFaint, filled: true);
}

/// Task 2 (contraction spec §5.2): the single "+" sheet — the one add
/// entry point for sources the catalog doesn't already cover AND for
/// marketplaces (themselves GitHub repos). One repo field
/// (`owner/repo` or URL via [_githubSourceFromInput]) funnels into the
/// single inspection/approval flow ([_runSourceInstall]), and the same
/// field adds a marketplace (repo recorded + catalog fetched) with the
/// existing marketplace list + remove below.
Future<void> showPluginAddSheet(BuildContext context) {
  final app = AppState.I;
  final repoC = TextEditingController();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Aether.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => AnimatedBuilder(
      animation: app,
      builder: (ctx, _) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Aether.accentSoft,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.add,
                      size: 19,
                      color: Aether.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Add plugin or marketplace',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close, size: 18, color: Aether.textFaint),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Fetch a plugin from GitHub, or add a marketplace (itself '
                'a GitHub repo with a marketplace.json). Every repo is '
                'inspected and asks for one capability approval before '
                'anything installs.',
                style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
              ),
              const SizedBox(height: 14),
              Text(
                'GITHUB REPO',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.4,
                  color: Aether.textFaint,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: repoC,
                autofocus: true,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontFamily: Aether.mono,
                ),
                decoration: const InputDecoration(
                  hintText: 'owner/repo or https://github.com/owner/repo',
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Aether.accent,
                    side: BorderSide(color: Aether.accent.withValues(alpha: .4)),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  icon: const Icon(Icons.code, size: 16),
                  label: const Text('Fetch from GitHub'),
                  onPressed: () {
                    final txt = repoC.text.trim();
                    if (txt.isEmpty) return;
                    Navigator.pop(ctx);
                    final src = _githubSourceFromInput(txt);
                    if (src == null) return;
                    _runSourceInstall(context, src, null);
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Aether.accent,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(11),
                    ),
                  ),
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text(
                    'Add marketplace',
                    style: TextStyle(fontSize: 13.5),
                  ),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    final added = app.addMarketplace(repoC.text);
                    if (added == null) {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Enter owner/repo (or a GitHub URL) that is not '
                            'already added.',
                          ),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                      return;
                    }
                    Navigator.pop(ctx);
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text('Importing $added…'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                    // Registering only records the repo — the catalog has to
                    // be fetched for its plugins/MCP servers to show up.
                    final msg = await app.fetchMarketplaceCatalog(added);
                    if (!context.mounted) return;
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(msg),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
                ),
              ),
              if (app.marketplaces.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  'YOUR MARKETPLACES',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color: Aether.textFaint,
                  ),
                ),
                const SizedBox(height: 6),
                for (final m in app.marketplaces)
                  Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: Aether.surfaceAlt,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Aether.hairline),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.inventory_2_outlined,
                          size: 14,
                          color: Aether.textMuted,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            m,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontFamily: Aether.mono,
                            ),
                          ),
                        ),
                        if (m == 'ovidai/ovid-plugins')
                          const Tag(
                            'DEFAULT',
                            color: Aether.success,
                            filled: true,
                          )
                        else
                          GestureDetector(
                            onTap: () => app.removeMarketplace(m),
                            child: const Icon(
                              Icons.delete_outline,
                              size: 16,
                              color: Aether.danger,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// `owner/repo` / full GitHub URL → [GithubPluginSource]. Null when the
/// input names no usable repo.
GithubPluginSource? _githubSourceFromInput(String input) {
  var txt = input.trim();
  final m = RegExp(
    r'^https?://github\.com/([^/]+)/([^/#?]+)',
  ).firstMatch(txt);
  if (m != null) {
    return GithubPluginSource(owner: m.group(1)!, repo: m.group(2)!);
  }
  final parts = txt.split('/');
  if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
  return GithubPluginSource(owner: parts[0], repo: parts[1]);
}

/// Runs one source install to completion with progress + honest result
/// reporting (never a silent failure).
Future<void> _runSourceInstall(
  BuildContext context,
  PluginSource source,
  PluginItem? row,
) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(
      content: Text('Inspecting plugin source…'),
      behavior: SnackBarBehavior.floating,
    ),
  );
  _pluginInstallSheetContext = context;
  final result = await startPluginInstallForTest(AppState.I, row,
      source: source);
  _pluginInstallSheetContext = null;
  final msg = result == null
      ? 'Install cancelled — nothing was changed.'
      : switch (result.status) {
          PluginInstallStatus.ok =>
            'Installed ✓ — restart Ovid to enable it everywhere '
            '(this session: contributions pending restart).',
          PluginInstallStatus.degraded =>
            'Installed with degraded dependencies: '
            '${result.degradedNames.join(', ')} — restart to enable.',
          PluginInstallStatus.failed =>
            'Install failed: ${result.error ?? 'unknown error'}',
        };
  messenger.showSnackBar(
    SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
  );
  AppState.I.refresh();
}

/// Plugins library — Claude-Code-extensions style: trending banner carousel,
/// search, category chips, thousands of community plugins, detail pages.
class PluginsScreen extends StatefulWidget {
  const PluginsScreen({super.key, this.focusCanonicalId});

  /// Deep-link target from the startup dashboard's `Open Plugins` action:
  /// the canonical plugin/MCP id whose card should be highlighted.
  final String? focusCanonicalId;

  @override
  State<PluginsScreen> createState() => _PluginsScreenState();
}

class _PluginsScreenState extends State<PluginsScreen> {
  String _query = '';
  String _cat = 'All';

  /// True while registered marketplace catalogs are being merged.
  bool _syncing = false;

  /// Vertical scroll for the catalog; used to bring a deep-linked startup row
  /// into view even when it is outside the lazily-built window.
  final ScrollController _scroll = ScrollController();

  /// Stable keys for the canonical rows so `Open Plugins` can reveal them.
  final Map<String, GlobalKey> _pluginCardKeys = {};
  final Map<String, GlobalKey> _mcpCardKeys = {};
  bool _focusRevealed = false;
  int _revealAttempts = 0;

  static const double _estimatedPluginCardExtent = 132;

  @override
  void initState() {
    super.initState();
    // Registered marketplaces were never fetched anywhere in the UI, so the
    // catalog stayed at the built-in list and "Add marketplace" appeared to
    // do nothing. Merge them once when the library opens.
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncCatalogs());
  }

  @override
  void didUpdateWidget(PluginsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusCanonicalId != widget.focusCanonicalId) {
      _focusRevealed = false;
      _revealAttempts = 0;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Brings the deep-linked canonical row into view. The sliver builds rows
  /// lazily, so an off-screen target is first approached by an estimated
  /// offset and then `ensureVisible`d once it exists in the tree.
  void _scheduleFocusReveal(
    List<PluginItem> items,
    Map<PluginItem, String> focusIds,
  ) {
    final focus = widget.focusCanonicalId;
    if (focus == null || _focusRevealed) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _revealFocus(items, focusIds),
    );
  }

  void _revealFocus(
    List<PluginItem> items,
    Map<PluginItem, String> focusIds,
  ) {
    if (!mounted || _focusRevealed) return;
    final focus = widget.focusCanonicalId;
    if (focus == null) return;
    final targetContext =
        _pluginCardKeys[focus]?.currentContext ??
        _mcpCardKeys[focus]?.currentContext;
    if (targetContext != null) {
      _focusRevealed = true;
      Scrollable.ensureVisible(
        targetContext,
        alignment: 0.08,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
      return;
    }
    // The migration sentinel focuses a filtered list, so reveal its first row.
    final index = focus == kMigrationRequiredFocusId
        ? (items.isEmpty ? -1 : 0)
        : items.indexWhere((p) => focusIds[p] == focus);
    if (index >= 0 && _scroll.hasClients && _revealAttempts < 24) {
      _revealAttempts++;
      final estimate = (index * _estimatedPluginCardExtent).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      );
      if ((_scroll.offset - estimate).abs() > 1) {
        _scroll.jumpTo(estimate);
      }
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _revealFocus(items, focusIds),
      );
    }
  }

  Future<void> _syncCatalogs({bool force = false}) async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await AppState.I.syncMarketplaceCatalogs(force: force);
    } catch (_) {
      // Offline / bad repo — the built-in catalog still renders.
    }
    if (mounted) setState(() => _syncing = false);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    const cats = ['All', 'Agent', 'MCP', 'Tool', 'Runtime'];
    // Stable per-row focus ids: canonical runtime id, or the synthetic legacy
    // id (same ordinal scheme reconcile uses) so a same-name legacy row is
    // never confused with its sibling.
    final focusIds = <PluginItem, String>{};
    var legacyOrdinal = 0;
    for (final p in app.plugins) {
      if (p.runtimeId != null) {
        focusIds[p] = p.runtimeId!;
      } else if (p.migrationRequired) {
        focusIds[p] = legacyPluginFocusId(p, legacyOrdinal++);
      }
    }
    final migrationOnly =
        widget.focusCanonicalId == kMigrationRequiredFocusId;
    final items = app.plugins
        .where(
          (p) =>
              (!migrationOnly ||
                  durablePluginStatus(p)?.state ==
                      StartupItemState.migrationRequired) &&
              (_cat == 'All' || p.category == _cat) &&
              (p.name.toLowerCase().contains(_query.toLowerCase()) ||
                  p.description.toLowerCase().contains(_query.toLowerCase())),
        )
        .toList();

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Plugins'),
        actions: [
          if (_syncing)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: Aether.accent,
                ),
              ),
            )
          else
            IconButton(
              tooltip: 'Refresh marketplaces',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: () => _syncCatalogs(force: true),
            ),
          // Task 2 (contraction spec §5.2): exactly one "+" — the single
          // add sheet (GitHub fetch + marketplace add).
          IconButton(
            tooltip: 'Add plugin or marketplace',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add, size: 22),
            onPressed: () => showPluginAddSheet(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AnimatedBuilder(
        animation: app,
        builder: (_, _) {
          _scheduleFocusReveal(items, focusIds);
          return CustomScrollView(
            controller: _scroll,
            slivers: [
            // ── Search bar ON TOP ──
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search 4,800+ community plugins…',
                    prefixIcon: Icon(
                      Icons.search,
                      size: 16,
                      color: Aether.textFaint,
                    ),
                    isDense: true,
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (final c in cats)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(c, style: const TextStyle(fontSize: 12)),
                          selected: _cat == c,
                          onSelected: (_) => setState(() => _cat = c),
                          showCheckmark: false,
                          selectedColor: Aether.accentSoft,
                          backgroundColor: Aether.surfaceAlt,
                          side: BorderSide(
                            color: _cat == c ? Aether.accent : Aether.hairline,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // ── MCP section ──
            if (!migrationOnly)
              SliverToBoxAdapter(
                child: _McpSection(
                  app: app,
                  focusCanonicalId: widget.focusCanonicalId,
                  cardKeys: _mcpCardKeys,
                ),
              ),
            if (migrationOnly)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
                  child: Text(
                    'Plugins needing re-approval show the exact reason '
                    'below.',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Aether.textMuted,
                    ),
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 2),
                child: Text(
                  migrationOnly ? 'NEEDS RE-APPROVAL' : 'ALL PLUGINS',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color: Aether.textFaint,
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              sliver: SliverList.separated(
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final p = items[i];
                  final focusId = focusIds[p];
                  return PluginCard(
                    key: focusId == null
                        ? null
                        : _pluginCardKeys.putIfAbsent(
                            focusId,
                            () => GlobalKey(),
                          ),
                    plugin: p,
                    focusId: focusId,
                    highlighted: migrationOnly
                        ? durablePluginStatus(p)?.state ==
                              StartupItemState.migrationRequired
                        : focusId != null &&
                              focusId == widget.focusCanonicalId,
                  );
                },
              ),
            ),
          ],
        );
        },
      ),
    );
  }

}

class PluginCard extends StatelessWidget {
  final PluginItem plugin;

  /// Deep-link target: renders an accent border when this row matches the
  /// canonical id a startup `Open Plugins` action asked to focus.
  final bool highlighted;

  /// Stable focus identity for this row. Defaults to the canonical runtime id;
  /// legacy (`runtimeId`-null) rows pass their synthetic focus id so the
  /// dashboard and this screen agree on exactly which row to reveal.
  final String? focusId;
  const PluginCard({
    super.key,
    required this.plugin,
    this.highlighted = false,
    this.focusId,
  });

  String? get _keyId => plugin.runtimeId ?? focusId;

  /// Task 11 (spec §11) + Task 10 copy pass: honest install/availability
  /// state for rows with NO runtime activation. `installed && !enabled`
  /// (the Web Fetch & Reader half-state) reads "Installed · disabled" —
  /// never "Available", never a broken-looking error.
  static String availabilityLabel(PluginItem p) => p.installed
      ? (p.enabled ? 'Installed · enabled' : 'Installed · disabled')
      : 'Available';

  /// Task 11 (spec §11): source/format badge — Claude Code, Codex, MCP,
  /// or Ovid built-in. Catalog rows derive it from `marketplaceId` /
  /// category; MCP-category rows are always MCP.
  static String sourceFormatLabel(PluginItem p) {
    if (p.category == 'MCP') return 'MCP';
    if (p.author == 'ovidai' || p.author == 'you') return 'Ovid built-in';
    if (p.marketplace != null || p.source != null) return 'Claude Code';
    return 'Codex';
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PluginDetailScreen(plugin: plugin)),
      ),
      child: Container(
        key: _keyId == null
            ? null
            : ValueKey('plugin-card-$_keyId'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: highlighted ? Aether.accentSoft : Aether.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: highlighted ? Aether.accent : Aether.hairline,
            width: highlighted ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (highlighted)
              Container(
                key: ValueKey('plugin-card-highlight-$_keyId'),
                width: 3,
                height: 40,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: Aether.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Aether.surfaceRaised,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                switch (plugin.category) {
                  'Agent' => Icons.smart_toy_outlined,
                  'MCP' => Icons.hub_outlined,
                  'Runtime' => Icons.memory,
                  _ => Icons.build_outlined,
                },
                size: 19,
                color: Aether.textMuted,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          plugin.name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tag(plugin.category.toUpperCase(), filled: true),
                      // Task 11 (spec §11): source/format badge —
                      // Claude Code / Codex / MCP / Ovid built-in.
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Tag(
                          PluginCard.sourceFormatLabel(plugin),
                          filled: false,
                        ),
                      ),
                      // Task 11 (spec §11): activation badge beside the
                      // category tag (This session / Restart to enable
                      // everywhere / Global / Degraded / Failed).
                      if (pluginActivationBadge(plugin) case final b?)
                        Padding(padding: const EdgeInsets.only(left: 4), child: b),
                      // PR24: hook chips — a plugin with hooks shows which
                      // events it fires (e.g. ON_TURN_START).
                      for (final ev in plugin.hooks.keys)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Tag(ev.toUpperCase(), filled: false),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    plugin.installsKnown && plugin.installs > 0
                        ? '${plugin.author} · v${plugin.version} · ${app.fmtInstalls(plugin.installs)} installs'
                        : '${plugin.author} · v${plugin.version}',
                    style: TextStyle(fontSize: 11, color: Aether.textFaint),
                  ),
                  // Task 10 copy pass (spec §10): honest availability —
                  // installed-but-disabled rows (Web Fetch & Reader) read
                  // "Installed · disabled"; uninstalled rows "Available".
                  Text(
                    PluginCard.availabilityLabel(plugin),
                    style: TextStyle(fontSize: 11, color: Aether.textFaint),
                  ),
                  // Task 8 (spec §5.8/§6.2): the durable canonical startup
                  // status + short reason, never inferred from booleans.
                  if (durablePluginStatus(plugin) case final durable?
                      when durable.state != StartupItemState.ready) ...[
                    const SizedBox(height: 2),
                    Text(
                      durable.reason == null || durable.reason!.isEmpty
                          ? startupItemStateLabel(durable.state)
                          : '${startupItemStateLabel(durable.state)} · '
                                '${durable.reason}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: Aether.textMuted),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    plugin.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: Aether.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Builder(builder: (_) {
              if (!plugin.installed) {
                return Icon(
                  Icons.download_outlined,
                  size: 18,
                  color: Aether.textFaint,
                );
              }
              final durable = durablePluginStatus(plugin);
              if (durable != null) {
                return durableStatusIcon(durable);
              }
              final status = app.serviceStatus['plugin:${plugin.name}'];
              if (status != null) {
                if (status.health == ServiceHealth.connecting) {
                  return const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Aether.accent,
                    ),
                  );
                } else if (status.health == ServiceHealth.working) {
                  return const Icon(
                    Icons.check_circle_outline,
                    size: 18,
                    color: Aether.success,
                  );
                } else if (status.health == ServiceHealth.failed) {
                  return Tooltip(
                    message: status.detail,
                    child: Icon(
                      Icons.error_outline,
                      size: 18,
                      color: Aether.dangerC,
                    ),
                  );
                }
              }
              // Runtime rows without a durable record are honestly unknown —
              // never a green check derived from installed/enabled flags.
              if (plugin.runtimeId != null) {
                return Icon(
                  Icons.help_outline,
                  size: 18,
                  color: Aether.textFaint,
                );
              }
              return Icon(
                plugin.enabled ? Icons.check_circle : Icons.check_circle_outline,
                size: 18,
                color: plugin.enabled ? Aether.success : Aether.textFaint,
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// Plugin detail — Claude Code extension page style.
class PluginDetailScreen extends StatelessWidget {
  final PluginItem plugin;
  const PluginDetailScreen({super.key, required this.plugin});

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: Text(plugin.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Aether.surfaceRaised,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(Icons.extension, size: 26, color: Aether.textMuted),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plugin.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      plugin.installsKnown && plugin.installs > 0
                          ? '${plugin.author} · v${plugin.version} · ${app.fmtInstalls(plugin.installs)} installs'
                          : '${plugin.author} · v${plugin.version}',
                      style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
                    ),
                    // Task 10 copy pass (spec §10): honest availability on
                    // the detail header too — installed-but-disabled rows
                    // (Web Fetch & Reader) read "Installed · disabled";
                    // uninstalled rows read "Available".
                    Text(
                      PluginCard.availabilityLabel(plugin),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Aether.textFaint,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        // Task 11 (spec §11): source/format badge beside
                        // the category tag on the detail header.
                        Tag(plugin.category.toUpperCase(), filled: true),
                        const SizedBox(width: 4),
                        Tag(
                          PluginCard.sourceFormatLabel(plugin),
                          filled: false,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Task 11 (spec §11): the activation badge — This
                    // session / Restart to enable everywhere / Global /
                    // Degraded / Failed. Legacy flag-flip rows (no
                    // runtimeId) render no badge. When a durable canonical
                    // status exists it is authoritative (M5) and the badge is
                    // suppressed so the two signals never conflict.
                    if (durablePluginStatus(plugin) == null)
                      if (pluginActivationBadge(plugin) case final badge?) ...[
                        badge,
                      ],
                  ],
                ),
              ),
            ],
          ),
          // Task 8 (spec §5.8/§6.2): the durable canonical startup status +
          // short reason, persisted across restarts by Task 7.
          if (durablePluginStatus(plugin) case final durable?) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Aether.surfaceAlt,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Aether.hairline),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  durableStatusIcon(durable),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          startupItemStateLabel(durable.state),
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (durable.reason != null &&
                            durable.reason!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            durable.reason!,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Aether.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: plugin.installed
                ? FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: plugin.enabled
                          ? Aether.surfaceRaised
                          : Aether.accent,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: Icon(
                      plugin.enabled
                          ? Icons.power_settings_new
                          : Icons.play_arrow,
                      size: 16,
                    ),
                    label: Text(
                      plugin.enabled ? 'Disable' : 'Enable',
                      style: const TextStyle(fontSize: 13.5),
                    ),
                    onPressed: () async {
                      PluginRuntimeCallRecorderForTest.record?.call(
                        plugin.enabled ? 'disable' : 'enable',
                      );
                      if (plugin.enabled) {
                        await app.disablePlugin(plugin);
                        app.serviceStatus.remove('plugin:${plugin.name}');
                        await app.persistPluginState();
                      } else {
                        await app.enablePlugin(plugin);
                        // Task 10: probe-derived, not hardcoded — only
                        // stamp working when real capability resolves.
                        final tools = AgentService.I.pluginToolNames(plugin);
                        if (tools.isNotEmpty) {
                          app.updateServiceStatus(
                            'plugin:${plugin.name}',
                            ServiceHealth.working,
                            detail: 'probe ok · tools: ${tools.join(', ')}',
                          );
                        } else {
                          app.updateServiceStatus(
                            'plugin:${plugin.name}',
                            ServiceHealth.failed,
                            detail:
                                'probe failed: contributes no agent tools, '
                                'skills, hooks, or MCP servers',
                          );
                        }
                      }
                    },
                  )
                : FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Aether.accent,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.download_outlined, size: 16),
                    label: const Text(
                      'Install',
                      style: TextStyle(fontSize: 13.5),
                    ),
                    onPressed: () async {
                      // Task 11 (spec §11): ONE inspection/approval flow
                      // for every source. Catalog rows with a derivable
                      // source install straight through it; everything
                      // else opens the single add sheet (Task 2 §5.2).
                      final derived = plugin.source != null
                          ? githubPluginSourceFromSourceString(plugin.source!)
                          : null;
                      if (derived != null) {
                        await _runSourceInstall(context, derived, plugin);
                      } else {
                        await showPluginAddSheet(context);
                      }
                    },
                  ),
          ),
          if (plugin.installed &&
              plugin.runtimeId != null &&
              (plugin.activation == PluginActivation.failed ||
                  plugin.activation == PluginActivation.degraded)) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Aether.textMuted,
                      side: BorderSide(color: Aether.hairlineStrong),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.refresh, size: 15),
                    label: const Text(
                      'Retry activation',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    onPressed: () async {
                      // Task 11 (spec §11 Retry action) — re-probe and
                      // re-mount through the runtime manager; a retry
                      // never re-runs the install transaction.
                      PluginRuntimeCallRecorderForTest.record?.call('retry');
                      await app.retryPlugin(plugin);
                    },
                  ),
                ),
              ],
            ),
          ],
          if (plugin.installed) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Aether.textMuted,
                      side: BorderSide(color: Aether.hairlineStrong),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.settings_backup_restore, size: 15),
                    label: const Text(
                      'Reset to defaults',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    onPressed: () {
                      plugin.enabled = true;
                      app.persistPluginState();
                      app.refresh();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Plugin reset to defaults'),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Aether.danger,
                      side: BorderSide(
                        color: Aether.danger.withValues(alpha: 0.4),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 15),
                    label: const Text(
                      'Uninstall',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    onPressed: () async {
                      // Task 11: uninstall routes through the runtime
                      // manager (registry + content + deps + record +
                      // grant + secrets) via AppState.uninstallPlugin.
                      PluginRuntimeCallRecorderForTest.record?.call('uninstall');
                      await app.uninstallPlugin(plugin);
                    },
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 18),
          const SectionHeader('Overview'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              plugin.description,
              style: TextStyle(fontSize: 13.5, height: 1.6, color: Aether.text),
            ),
          ),
          // ── Task 11 (spec §11): the diagnostics sections. Runtime
          // rows (runtimeId set) render the full production surface;
          // legacy flag-flip rows keep the minimal sections only.
          if (plugin.runtimeId != null) ...[
            _PluginDiagnostics(plugin: plugin),
          ] else ...[
            const SectionHeader('Permissions'),
            if (plugin.hooks.isNotEmpty)
              _Perm('Declared hooks: ${plugin.hooks.keys.join(', ')}')
            else
              const _Perm('Declared by plugin manifest'),
          ],
          const SectionHeader('Changelog'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'v${plugin.version} — declared by plugin manifest.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: Aether.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

/// Task 11 (spec §11): the production diagnostics surface for a
/// runtime-installed plugin — namespaced contributions, alias
/// conflicts, MCP connection state + credentials, hook events with
/// breaker state, dependencies, compatibility warnings (required vs
/// optional), the effective capability grant (+ edit), and the
/// install/runtime log.
class _PluginDiagnostics extends StatelessWidget {
  final PluginItem plugin;
  const _PluginDiagnostics({required this.plugin});

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    final runtimeId = plugin.runtimeId!;
    final manifest = PluginContributionRegistry.I.manifestFor(runtimeId);
    // Roster-tool contributions of THIS plugin (honest install report).
    final tools = PluginContributionRegistry.I.toolContributionsForPlugin(
      runtimeId,
    );
    // §4.4 honest alias view: each roster contribution's bare name →
    // how it resolves roster-wide (unique → canonical id; ambiguous →
    // the exact option list; never a silent shadow).
    final aliases = <Widget>[];
    for (final c in tools) {
      final res = PluginContributionRegistry.I.resolveAlias(c.name);
      final line = res.isAmbiguous
          ? '${c.name} → ambiguous: ${res.options.join(', ')}'
          : res.isUnique
          ? '${c.name} → ${res.unique!.canonicalId}'
          : '${c.name} → ${c.canonicalId} (unregistered)';
      aliases.add(_DiagRow(line, warn: res.isAmbiguous));
    }
    if (aliases.isEmpty) {
      aliases.add(
        const _DiagRow('No commands, skills, or agents contributed.'),
      );
    }
    // Alias conflicts roster-wide that mention this plugin's canonical
    // ids — the exact chooser list, not a silent overwrite.
    final conflictIds = <String>{};
    for (final c in tools) {
      final res = PluginContributionRegistry.I.resolveAlias(c.name);
      if (res.isAmbiguous) {
        for (final m in res.matches) {
          conflictIds.add(
            'conflict: ${m.canonicalId} shares the name "${c.name}" '
            '(${res.options.length} claimants) — call by canonical id',
          );
        }
      }
    }
    final conflicts = conflictIds.map((t) => _DiagRow(t)).toList();

    // Plugin-owned MCP rows (Task 9 canonical ids `plugin:<id>/mcp:<name>`
    // owned via `ownerPluginId`; legacy `plugin:<name>` rows included).
    final owned = app.mcpServers.where((s) {
      if (s.ownerPluginId == runtimeId) return true;
      if (s.ownerPluginId != null) return false;
      return s.source == 'plugin:$runtimeId' ||
          s.source == 'plugin:${plugin.name}';
    }).toList();

    // Hook section data: the ordered normalized hook list plus the
    // manifest's declared rows (event · type · payload/matcher), and the
    // Task 8 breaker/failure state (boot-global counters for this boot
    // plus per-session settled breakers note).
    final hooks = manifest?.hooks ?? const <PluginHook>[];

    // Compatibility: manifest findings (required findings can never
    // reach an install — inspect fails them — so persisted rows show
    // optional ones; row-level warnings carry over too).
    final compat = <CompatibilityIssue>[
      ...?manifest?.compatibility.where(
        (c) => c.severity == CompatibilitySeverity.optional,
      ),
      ...plugin.compatibilityWarnings,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader('Contributions'),
        if (tools.isEmpty)
          const _DiagRow('This plugin contributes no roster tools.')
        else
          for (final c in tools)
            _DiagRow('${c.canonicalId} (${c.kindLabel})'),
        const SectionHeader('Aliases'),
        ...aliases,
        if (conflicts.isNotEmpty) ...[
          const SectionHeader(
            'Alias conflicts',
            subtitle: 'Shared bare names — call by canonical id',
          ),
          ...conflicts,
        ],
        const SectionHeader('MCP servers'),
        if (owned.isEmpty && (manifest == null || manifest.mcpServers.isEmpty))
          const _DiagRow('No MCP servers declared.'),
        for (final s in owned) ...[
          // Durable-only status (spec §5.3, Task 3): canonical label ·
          // reason, or neutral "Not started" — never a binary
          // Connected/Not connected inference.
          _DiagRow(
            '${s.canonicalId} · ${s.transport} · '
            '${mcpDurableStatusText(s)}',
          ),
          if (s.envHint != null ||
              s.requiredEnvNames.isNotEmpty ||
              s.requiredHeaderNames.isNotEmpty)
            _DiagRow(
              'Needs setup: '
              '${s.requiredEnvNames.isNotEmpty ? s.requiredEnvNames.join(', ') : s.envHint ?? s.requiredHeaderNames.join(', ')} '
              'must be configured (secure storage)',
              warn: true,
            ),
          if (mcpUnsupportedReason(s) != null)
            _DiagRow(
              'Unsupported on this device: ${mcpUnsupportedReason(s)}',
              warn: true,
            ),
        ],
        // Declared-but-not-mounted servers (mount deferred/failed):
        // the manifest is the source of truth, never silent. A mounted
        // plugin server's McpServer.canonicalId is `<ownerPluginId>/
        // <name>` (state.dart), NOT the declaration's
        // `plugin:<id>/mcp:<name>` — compare against the mounted form.
        if (manifest != null)
          for (final d in manifest.mcpServers)
            if (!owned.any((s) => s.canonicalId == '${manifest.id}/${d.name}'))
              _DiagRow(
                '${d.canonicalId} · ${d.transport} · '
                'declared (not mounted)',
                warn: true,
              ),
        if (manifest != null)
          for (final d in manifest.mcpServers)
            if (!owned.any((s) => s.canonicalId == '${manifest.id}/${d.name}') &&
                (d.envNames.isNotEmpty || d.headerNames.isNotEmpty))
              _DiagRow(
                'Needs setup: '
                '${[...d.envNames, ...d.headerNames].join(', ')} '
                'must be configured (secure storage)',
                warn: true,
              ),
        const SectionHeader('Hooks'),
        if (hooks.isEmpty)
          const _DiagRow('No hooks declared.')
        else
          for (final h in hooks)
            _DiagRow(
              '${h.event} · ${h.type} · '
              '${h.matcher != null ? 'matcher ${h.matcher} · ' : ''}'
              '${h.payload.isEmpty ? '' : h.payload}',
            ),
        if (plugin.pluginHooks.isNotEmpty &&
            (manifest == null || manifest.hooks.isEmpty))
          for (final h in plugin.pluginHooks)
            _DiagRow(
              '${h.event} · ${h.type} · '
              '${h.matcher != null ? 'matcher ${h.matcher} · ' : ''}'
              '${h.payload.isEmpty ? '' : h.payload}',
            ),
        _DiagRow(
          'Last result: '
          '${HookService.I.failed > 0 ? 'failures seen this boot' : 'no failures this boot'} '
          '(fired ${HookService.I.fired}, failed ${HookService.I.failed} this boot)',
        ),
        _DiagRow(
          'Circuit breaker: ${HookService.breakerThreshold} consecutive '
          'failures in a session disable this plugin\'s hooks '
          '(fail-open — the run continues)',
        ),
        const SectionHeader('Dependencies'),
        if (manifest == null || manifest.dependencies.packages.isEmpty)
          const _DiagRow('No dependencies declared.')
        else
          for (final d in manifest.dependencies.packages)
            _DiagRow(
              '${d.name} ${d.versionSpec} (${d.kind.name}'
              '${d.required ? '' : ', optional'})',
            ),
        SectionHeader(
          'Compatibility',
          subtitle: 'Required failures block install · optional degrades',
        ),
        if (compat.isEmpty)
          const _DiagRow('No compatibility findings.')
        else
          for (final c in compat)
            _DiagRow(
              '${c.severity.name}: ${c.message} '
              '[${c.fields.join(', ')}]',
              warn: c.severity != CompatibilitySeverity.optional,
            ),
        SectionHeader(
          'Permissions',
          subtitle: 'Granted capabilities for this exact version',
        ),
        _EffectiveGrantRow(plugin: plugin),
        const SectionHeader('Install log'),
        _InstallLogRow(plugin: plugin),
      ],
    );
  }
}

class _DiagRow extends StatelessWidget {
  final String text;
  final bool warn;
  const _DiagRow(this.text, {this.warn = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            warn ? Icons.warning_amber_outlined : Icons.check_circle_outline,
            size: 14,
            color: warn ? Aether.warn : Aether.textFaint,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                fontFamily: Aether.mono,
                color: warn ? Aether.text : Aether.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The effective grant with the Task 11 Edit-permissions entry: shows
/// the granted capabilities (or the honest "no grant") and opens the
/// revoke/refresh sheet.
class _EffectiveGrantRow extends StatelessWidget {
  final PluginItem plugin;
  const _EffectiveGrantRow({required this.plugin});

  static String digestSnippetForTest(String digest) =>
      digest.length <= 19 ? digest : digest.substring(0, 19);

  Future<void> _openEditor(BuildContext context) async {
    PluginRuntimeCallRecorderForTest.record?.call('edit-grants');
    final app = AppState.I;
    final grant = await app.effectivePluginGrant(plugin);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Plugin permissions', style: TextStyle(fontSize: 15)),
        content: Text(
          grant == null
              ? 'No grant is currently effective for this plugin. It will '
                    'request approval on the next install or update.'
              : 'Granted capabilities:\n'
                    '${grant.capabilities.map((c) => c.name).join(', ')}\n\n'
                    'Approved ${grant.approvedAt.toIso8601String().substring(0, 10)} '
                    'for digest ${_EffectiveGrantRow.digestSnippetForTest(grant.manifestDigest)}…',
          style: const TextStyle(fontSize: 12.5, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          if (grant != null)
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Aether.danger),
              onPressed: () async {
                Navigator.pop(ctx);
                // Revoke: grant + owned secrets removed, plugin
                // disabled immediately (Task 5 semantics).
                await app.revokePluginGrant(plugin);
                app.refresh();
              },
              child: const Text('Revoke permissions'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
            child: FutureBuilder<PluginPermissionGrant?>(
              future: AppState.I.effectivePluginGrant(plugin),
              builder: (_, snap) {
                final g = snap.data;
                return Text(
                  g == null
                      ? 'No effective grant (approval required on next '
                            'install)'
                      : 'Granted: ${g.capabilities.map((c) => c.name).join(', ')}',
                  style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                );
              },
            ),
          ),
          IconButton(
            tooltip: 'Edit permissions',
            icon: Icon(Icons.lock_outline, size: 16, color: Aether.textMuted),
            onPressed: () => _openEditor(context),
          ),
        ],
      ),
    );
  }
}

/// The install/runtime log: the persisted activation record's provenance
/// plus the transaction log lines captured at install time.
class _InstallLogRow extends StatelessWidget {
  final PluginItem plugin;
  const _InstallLogRow({required this.plugin});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PluginActivationRecord?>(
      future: PluginRuntimeManager.I.recordFor(plugin.runtimeId!),
      builder: (_, snap) {
        final rec = snap.data;
        if (rec == null) {
          return const _DiagRow('No install record found.');
        }
        final lines = <String>[
          'installed at boot epoch ${rec.installedBootEpoch}',
          'staged → committed → probed (activation ${rec.state.name})',
          if (rec.promoteOnNextBoot)
            'promotes globally on next restart'
          else
            'activation settled',
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final l in lines) _DiagRow(l)],
        );
      },
    );
  }
}

class _Perm extends StatelessWidget {
  final String text;
  const _Perm(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(
        children: [
          const Icon(
            Icons.verified_user_outlined,
            size: 14,
            color: Aether.success,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// MCP servers section — separate from plugins because lifecycle is different
/// (running process + JSON-RPC, not a downloaded package).
class _McpSection extends StatelessWidget {
  final AppState app;
  final String? focusCanonicalId;
  final Map<String, GlobalKey>? cardKeys;
  const _McpSection({required this.app, this.focusCanonicalId, this.cardKeys});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 12, 2),
          child: Row(
            children: [
              Icon(Icons.usb_outlined, size: 15, color: Aether.textFaint),
              SizedBox(width: 8),
              Flexible(
                child: Text(
                  'CONNECTED TOOLS · MCP SERVERS',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.4,
                    color: Aether.textFaint,
                  ),
                ),
              ),
              const Spacer(),
              const Tag('LIVE', color: Aether.accent, filled: true),
            ],
          ),
        ),
        // Task 2 (contraction spec §5.2): no add-tile — the single "+"
        // opens the add sheet. An empty list hints at it instead.
        if (app.mcpServers.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text(
              'Use + to add from GitHub',
              style: TextStyle(fontSize: 12, color: Aether.textMuted),
            ),
          )
        else
          SizedBox(
            height: 132,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: app.mcpServers.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final s = app.mcpServers[i];
                return McpCard(
                  key: cardKeys?.putIfAbsent(s.canonicalId, () => GlobalKey()),
                  server: s,
                  highlighted: s.canonicalId == focusCanonicalId,
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Parse a pasted MCP config into entries — delegates to the shared core
/// parser in `core/mcp_config_parse.dart` so the UI and the plugin
/// compatibility adapters cannot drift apart.
List<ImportedMcp> _parseMcpConfig(String raw) => parseMcpConfig(raw);

/// Public test seam for [_parseMcpConfig] — same shared core parser, no
/// dialog. Returns a record list (public shape) so the parser's own value
/// type never leaks into this screen's public API.
@visibleForTesting
List<({
  String name,
  String command,
  List<String> args,
  Map<String, String> env,
  String? url,
  Map<String, String> headers,
  String type,
  String? cwd,
  List<String> ignoredKeys,
})>
parseMcpConfigForTest(String raw) => [
      for (final e in _parseMcpConfig(raw))
        (
          name: e.name,
          command: e.command,
          args: e.args,
          env: e.env,
          url: e.url,
          headers: e.headers,
          type: e.type,
          cwd: e.cwd,
          ignoredKeys: e.ignoredKeys,
        ),
    ];

/// Compact horizontal card for an MCP server.
class McpCard extends StatelessWidget {
  final McpServer server;

  /// Deep-link target: accent border when the startup `Open Plugins` action
  /// asked to focus this canonical server.
  final bool highlighted;
  const McpCard({super.key, required this.server, this.highlighted = false});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => McpDetailScreen(server: server)),
      ),
      onLongPress: server.custom
          ? () => AppState.I.removeMcpServer(server)
          : null,
      child: Container(
        key: ValueKey('mcp-card-${server.canonicalId}'),
        width: 196,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Aether.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            width: highlighted ? 1.5 : 1,
            color: () {
              if (highlighted) return Aether.accent;
              // Durable-only border (spec §5.3, Task 3): no record reads
              // neutral, never serviceStatus or connected.
              switch (durableMcpStatus(server)?.state) {
                case StartupItemState.ready:
                  return Aether.accent.withValues(alpha: 0.45);
                case StartupItemState.failed:
                case StartupItemState.unsupported:
                  return Aether.dangerC.withValues(alpha: 0.45);
                case StartupItemState.needsSetup:
                case StartupItemState.degraded:
                case StartupItemState.migrationRequired:
                case StartupItemState.skipped:
                  return Aether.warn.withValues(alpha: 0.45);
                case StartupItemState.disabled:
                case StartupItemState.queued:
                case StartupItemState.running:
                case null:
                  return Aether.hairline;
              }
            }(),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Aether.surfaceRaised,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.usb_outlined,
                    size: 15,
                    color: Aether.textMuted,
                  ),
                ),
                const Spacer(),
                Builder(builder: (_) {
                  final durable = durableMcpStatus(server);
                  if (durable != null) return durableStatusIcon(durable);
                  // No record: neutral, never inferred from serviceStatus
                  // or connected (spec §5.3, Task 3).
                  return Icon(
                    Icons.help_outline,
                    size: 14,
                    color: Aether.textFaint,
                  );
                }),
              ],
            ),
            const Spacer(),
            Text(
              server.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Builder(builder: (_) {
              final durable = durableMcpStatus(server);
              if (durable != null) {
                final label = startupItemStateLabel(durable.state);
                final reason = durable.reason;
                return Text(
                  reason == null || reason.isEmpty ? label : '$label · $reason',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: durable.state == StartupItemState.ready
                        ? Aether.success
                        : Aether.textMuted,
                  ),
                );
              }
              // No record: neutral "Not started", never inferred from
              // serviceStatus, connected, or structural guards — those stay
              // on the detail screen banners (spec §5.3, Task 3).
              return Text(
                'Not started',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// MCP detail — connect/disconnect with config preview.
class McpDetailScreen extends StatefulWidget {
  final McpServer server;
  const McpDetailScreen({super.key, required this.server});

  @override
  State<McpDetailScreen> createState() => _McpDetailScreenState();
}

class _McpDetailScreenState extends State<McpDetailScreen> {
  @override
  Widget build(BuildContext context) {
    final s = widget.server;
    final app = AppState.I;
    final argsJson = s.args.isEmpty
        ? '[]'
        : '[${s.args.map((a) => '"$a"').join(', ')}]';
    final configJson =
        '{\n'
        '  "mcpServers": {\n'
        '    "${s.name.toLowerCase()}": {\n'
        '      "command": "${s.command}",\n'
        '      "args": $argsJson'
        '${s.envHint != null ? ',\n      "env": { "${s.envHint!}": "••••••••" }' : ''}\n'
        '    }\n'
        '  }\n'
        '}';

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(s.name),
        actions: [
          // Pencil — edit the mcp.json config in place (user request).
          IconButton(
            tooltip: 'Edit config',
            icon: const Icon(Icons.edit_outlined, size: 19),
            onPressed: () => _editConfigJson(context, s),
          ),
          if (s.custom)
            IconButton(
              tooltip: 'Remove server',
              icon: const Icon(
                Icons.delete_outline,
                size: 19,
                color: Aether.danger,
              ),
              onPressed: () {
                app.removeMcpServer(s);
                Navigator.pop(context);
              },
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Aether.surfaceRaised,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.usb_outlined,
                  size: 24,
                  color: Aether.textMuted,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${s.author} · ${s.category} · via ${s.source}',
                      style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
                    ),
                    // Durable-only header status (spec §5.3, Task 3): the
                    // canonical label · reason, or neutral "Not started" —
                    // never serviceStatus or connected. The live
                    // Connect/Disconnect toggle below stays as-is.
                    const SizedBox(height: 3),
                    Builder(builder: (_) {
                      final durable = durableMcpStatus(s);
                      if (durable == null) {
                        return Text(
                          'Not started',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Aether.textFaint,
                          ),
                        );
                      }
                      final label = startupItemStateLabel(durable.state);
                      final reason = durable.reason;
                      return Text(
                        reason == null || reason.isEmpty
                            ? label
                            : '$label · $reason',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: durable.state == StartupItemState.ready
                              ? Aether.success
                              : Aether.textMuted,
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: s.connected
                    ? Aether.surfaceRaised
                    : Aether.accent,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                side: BorderSide(
                  color: s.connected ? Aether.hairline : Colors.transparent,
                ),
              ),
              icon: Icon(
                s.connected ? Icons.link_off : Icons.power_settings_new,
                size: 16,
              ),
              label: Text(
                s.connected ? 'Disconnect' : 'Connect server',
                style: const TextStyle(fontSize: 13.5),
              ),
              onPressed: () => app.toggleMcpServer(s),
            ),
          ),
          // Task 10 (spec §10): Android-incompatible desktop servers show
          // `Unsupported on this device` with the missing runtime/ABI
          // reason — never a silent connect failure.
          if (mcpUnsupportedReason(s) != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Aether.surfaceAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Aether.dangerC.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.block_outlined,
                    size: 15,
                    color: Aether.dangerC,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Unsupported on this device: ${mcpUnsupportedReason(s)}',
                      style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ],
          // Task 10 (spec §10): credential-dependent MCPs show their setup
          // requirements and never auto-spawn until configured.
          if (s.envHint != null && !s.connected) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Aether.surfaceAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Aether.warn.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.key_outlined, size: 15, color: Aether.warn),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Needs setup: ${s.envHint} must be configured (secure '
                      'storage) before this server can connect. It will not '
                      'start automatically.',
                      style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (s.connected) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Aether.textMuted,
                      side: BorderSide(color: Aether.hairlineStrong),
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.settings_backup_restore, size: 15),
                    label: const Text(
                      'Reset config',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    onPressed: () {
                      // Reset = disconnect + clear any custom env
                      if (s.connected) app.toggleMcpServer(s);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('MCP server config reset'),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 18),
          const SectionHeader('Overview'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              s.description,
              style: TextStyle(fontSize: 13.5, height: 1.6, color: Aether.text),
            ),
          ),
          if (s.envHint != null) ...[
            const SectionHeader('Environment'),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Aether.surfaceAlt,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Aether.hairline),
              ),
              child: Row(
                children: [
                  const Icon(Icons.key_outlined, size: 15, color: Aether.warn),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${s.envHint} will be requested when connecting.',
                      style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SectionHeader('Config (standard mcp.json)'),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: Aether.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Aether.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  color: Aether.surfaceAlt,
                  child: Text(
                    'mcp.json',
                    style: TextStyle(fontSize: 11, color: Aether.textMuted),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    configJson,
                    style: TextStyle(
                      fontFamily: Aether.mono,
                      fontSize: 11.5,
                      height: 1.55,
                      color: Aether.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SectionHeader('Runtime'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _runRow('Process', '${s.command} ${s.args.join(' ')}'),
                const SizedBox(height: 6),
                _runRow('Protocol', 'JSON-RPC over stdio'),
                const SizedBox(height: 6),
                _runRow('Sandbox', 'Isolated · ask before network'),
              ],
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _runRow(String k, String v) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 78,
        child: Text(k, style: TextStyle(fontSize: 12, color: Aether.textFaint)),
      ),
      Expanded(
        child: Text(
          v,
          style: TextStyle(
            fontFamily: Aether.mono,
            fontSize: 11.5,
            color: Aether.textMuted,
          ),
        ),
      ),
    ],
  );

  /// Opens the mcp.json editor sheet — validates JSON, parses the
  /// mcpServers entry, and updates the server command/args on save.
  void _editConfigJson(BuildContext context, McpServer s) {
    final app = AppState.I;
    final ctrl = TextEditingController(text: _configJsonFor(s));
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Aether.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(ctx).viewInsets.bottom,
        ),
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.62,
          child: _McpJsonEditorSheet(
            controller: ctrl,
            onSave: (command, args, env, url, transport, headers, cwd) {
              app.updateCustomMcpServer(
                s,
                command: command,
                args: args,
                url: url,
                transport: transport,
                headers: headers,
                cwd: cwd,
              );
              // Env values (API keys) → secure storage, passed to the
              // server process at connect time.
               unawaited(app.setMcpEnv(s.canonicalId, env));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('mcp.json saved ✓')));
            },
          ),
        ),
      ),
    );
  }

  String _configJsonFor(McpServer s) {
    final argsJson = s.args.isEmpty
        ? '[]'
        : '[${s.args.map((a) => '"$a"').join(', ')}]';
    final envJson = s.envHint != null
        ? ',\n      "env": { "${s.envHint!}": "••••••••" }'
        : '';
    final isHttp = s.transport == 'http';
    final urlJson = s.url != null
        ? ',\n      "url": "${s.url}"'
        : '';
    final cwdJson = s.cwd != null ? ',\n      "cwd": "${s.cwd}"' : '';
    final transportJson = ',\n      "transport": "${s.transport}"';
    return '{\n'
        '  "mcpServers": {\n'
        '    "${s.name.toLowerCase()}": {\n'
        '      "command": "${s.command}",\n'
        '      "args": $argsJson'
        '$urlJson'
        '$cwdJson'
        '${isHttp ? transportJson : ''}'
        '$envJson\n'
        '    }\n'
        '  }\n'
        '}';
  }
}

/// Bottom-sheet mcp.json editor: multiline TextField + live validation.
/// Save parses the mcpServers.{name} entry and returns command + args +
/// env (values stored in secure storage, passed to the server process).
class _McpJsonEditorSheet extends StatefulWidget {
  final TextEditingController controller;
  final void Function(
    String command,
    List<String> args,
    Map<String, String> env,
    String? url,
    String? transport,
    Map<String, String> headers,
    String? cwd,
  )
  onSave;
  const _McpJsonEditorSheet({required this.controller, required this.onSave});

  @override
  State<_McpJsonEditorSheet> createState() => _McpJsonEditorSheetState();
}

class _McpJsonEditorSheetState extends State<_McpJsonEditorSheet> {
  String? _error;

  void _validate() {
    setState(() {
      _error = _parse(widget.controller.text) == null
          ? 'Invalid mcp.json — expected {"mcpServers": {"name": {"command": "...", "args": [...]}}}'
          : null;
    });
  }

  ({
    String command,
    List<String> args,
    Map<String, String> env,
    String? url,
    String? transport,
    Map<String, String> headers,
    String? cwd,
  })?
  _parse(
    String raw,
  ) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final servers = j['mcpServers'] as Map<String, dynamic>?;
      if (servers == null || servers.isEmpty) return null;
      final entry = servers.values.first as Map<String, dynamic>;
      final command = entry['command'] as String?;
      final url = (entry['url'] as String?)?.trim();
      final transport = (entry['transport'] as String?) ??
          (entry['type'] as String?);
      final isHttp =
          (url != null && url.isNotEmpty) || transport == 'http';
      if ((command == null || command.trim().isEmpty) && !isHttp) {
        return null;
      }
      final args =
          (entry['args'] as List?)?.whereType<String>().toList() ?? <String>[];
      final env =
          (entry['env'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          ) ??
          <String, String>{};
      final headers =
          (entry['headers'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          ) ??
          <String, String>{};
      return (
        command: (command ?? '').trim(),
        args: args,
        env: env,
        url: isHttp ? url : null,
        transport: transport ?? (isHttp ? 'http' : 'stdio'),
        headers: headers,
        cwd: (entry['cwd'] as String?)?.trim(),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.edit_outlined, size: 16, color: Aether.textMuted),
            const SizedBox(width: 8),
            const Text(
              'Edit mcp.json',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Edit the server command, args, or env. Saved config is used when the server connects.',
          style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: TextField(
            controller: widget.controller,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: TextStyle(fontFamily: Aether.mono, fontSize: 12),
            decoration: InputDecoration(
              filled: true,
              fillColor: Aether.surfaceAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Aether.hairline),
              ),
            ),
            onChanged: (_) => _validate(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(fontSize: 11, color: Aether.danger)),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Aether.accent,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Save config'),
          onPressed: () {
            final parsed = _parse(widget.controller.text);
            if (parsed == null) {
              setState(
                () => _error =
                    'Invalid mcp.json — check the JSON syntax and try again.',
              );
              return;
            }
            widget.onSave(
              parsed.command,
              parsed.args,
              parsed.env,
              parsed.url,
              parsed.transport,
              parsed.headers,
              parsed.cwd,
            );
          },
        ),
      ],
    );
  }
}
