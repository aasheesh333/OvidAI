import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/agent_service.dart';
import '../core/diag.dart';
import 'widgets/aether_primitives.dart';
import '../core/github_service.dart';
import '../core/hook_service.dart';
import '../core/mcp_config_parse.dart';
import '../core/mcp_service.dart';
import '../core/native_plugin.dart';
import '../core/plugin_manifest.dart';
import '../core/plugin_permissions.dart';
import '../core/plugin_registry.dart';
import '../core/plugin_runtime.dart';
import '../core/plugin_source_resolver.dart';
import '../core/sandbox_service.dart';
import '../core/startup_coordinator.dart';
import '../core/theme.dart';
import '../core/tool_usage_store.dart';
import '../core/state.dart';
import '../core/secret_scrub.dart';
import 'github_login_sheet.dart';
import 'mcp_oauth_sheet.dart';
import 'mcp_server_add_form.dart';
import 'plugin_install_progress.dart';
import 'plugin_permission_sheet.dart';
import 'plugin_settings_panel.dart';
import 'sandbox_setup.dart';
import 'startup_progress_panel.dart';

/// Agent tools a plugin contributes when installed+enabled — mirrors the
/// `_tools` gate in AgentService so the install snackbar can report what
/// the model actually gained (the plugin registry honest-install parity).
String? _toolGainsFor(PluginItem p) {
  final seed = switch (p.name) {
    'Web Search' => 'web_search',
    'Image Studio' => 'resize_image · crop_image · cloud images when available',
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
    // Same suffix-tolerant gating as the roster's _mcpProxyTool — the
    // proxy tool exists only while the plugin's matching MCP server row
    // does ('Puppeteer MCP' → server 'Puppeteer'). No server row → no
    // claimed gain.
    final hasServer = AgentService.mcpServerForPlugin(p) != null;
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

/// What the Connect action must do for an MCP server: connect directly when
/// nothing is missing, otherwise ask for the required credentials first —
/// never silently flip to a needsSetup label.
enum McpCredentialAsk { connectDirectly, askCredentials }

@visibleForTesting
McpCredentialAsk mcpCredentialAskForTest({required List<String> missing}) =>
    missing.isEmpty
    ? McpCredentialAsk.connectDirectly
    : McpCredentialAsk.askCredentials;

/// Whether the credential sheet should offer the GitHub login as the
/// first-class path: the GitHub server itself, or any server whose declared
/// credential is the GitHub token.
@visibleForTesting
bool mcpOffersGithubLoginForTest(McpServer server) {
  if (server.name.trim().toLowerCase() == 'github') return true;
  return (server.envHint ?? '')
      .split(',')
      .map((e) => e.trim())
      .contains('GITHUB_TOKEN');
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

Future<bool> showDeleteConfirmationDialog(
  BuildContext context, {
  required String title,
  String content = 'This action cannot be undone.',
  String confirmLabel = 'Delete',
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(
            confirmLabel,
            style: TextStyle(color: Aether.danger),
          ),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Confirm, then remove marketplace [repo]. Removal uninstalls every
/// installed plugin from it (grant, secrets, dependency sandbox), so the
/// dialog names them. Returns true when removed.
Future<bool> confirmAndRemoveMarketplace(
  BuildContext context,
  String repo,
) async {
  final app = AppState.I;
  final installed = app.installedPluginsFromMarketplace(repo);
  final names = installed.map((p) => p.name).toList();
  final shown = names.length > 5
      ? '${names.take(5).join(', ')} and ${names.length - 5} more'
      : names.join(', ');
  final ok = await showDeleteConfirmationDialog(
    context,
    title: 'Remove $repo?',
    content: installed.isEmpty
        ? 'Removes this marketplace and its catalog entries. No installed '
              'plugins come from it.'
        : 'Also uninstalls ${installed.length} '
              'plugin${installed.length == 1 ? '' : 's'}: $shown. Their '
              'permissions, saved secrets and dependencies are deleted.',
    confirmLabel: installed.isEmpty ? 'Remove' : 'Remove & uninstall',
  );
  if (!ok) return false;
  await app.removeMarketplace(repo);
  return true;
}

/// The one enable/disable path for the card switch, detail switch and
/// detail button. Enabling reports the real outcome: a runtime/migration
/// failure shows its reason (snackbar + failed status) and success is
/// probed across every contribution kind (tools, hooks, MCP, skills), so
/// hook-only and MCP-only plugins are not marked failed.
Future<bool> setPluginEnabled(
  BuildContext context,
  PluginItem plugin,
  bool enable,
) async {
  final app = AppState.I;
  final messenger = ScaffoldMessenger.maybeOf(context);
  PluginRuntimeCallRecorderForTest.record?.call(enable ? 'enable' : 'disable');
  if (!enable) {
    await app.disablePlugin(plugin);
    app.serviceStatus.remove('plugin:${plugin.name}');
    await app.persistPluginState();
    app.refresh();
    return true;
  }
  final result = await app.enablePlugin(plugin);
  if (!result.ok) {
    final reason = result.error ?? 'activation failed';
    app.updateServiceStatus(
      'plugin:${plugin.name}',
      ServiceHealth.failed,
      detail: reason,
    );
    app.refresh();
    if (messenger != null && messenger.mounted) {
      messenger.showSnackBar(
        SnackBar(
          content: Text("Couldn't enable ${plugin.name}: $reason"),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return false;
  }
  // Task 10: probe-derived, not hardcoded — only stamp working when a real
  // capability resolves.
  await app.probePluginServiceStatus(plugin);
  app.refresh();
  return true;
}

/// Whether an UNINSTALLED [plugin] row may be removed from the list: only
/// rows the user added (no marketplace catalog, not a built-in/native row).
/// Catalog rows would simply vanish until the next marketplace sync.
bool pluginRemovableFromList(PluginItem plugin) =>
    !plugin.installed &&
    plugin.marketplace == null &&
    !(plugin.source?.startsWith('marketplace:') ?? false) &&
    !_isInbuiltPlugin(plugin) &&
    !NativePluginRegistry.I.has(plugin.name);

/// MCP servers [AppState.uninstallPlugin] removes along with [plugin].
List<McpServer> _pluginOwnedServers(PluginItem plugin) {
  final runtimeId = plugin.runtimeId;
  return AppState.I.mcpServers.where((s) {
    if (runtimeId != null && s.ownerPluginId == runtimeId) return true;
    if (s.ownerPluginId != null) return false;
    return s.source == 'plugin:${plugin.name}' ||
        (runtimeId != null && s.source == 'plugin:$runtimeId') ||
        (plugin.source != null &&
            (s.source == 'plugin:${plugin.source}' ||
                s.source == 'plugin:${plugin.source!.replaceAll('/', '_')}'));
  }).toList();
}

/// Confirm, then uninstall [plugin]. The dialog says what is removed. The
/// row stays in the list (as Available). Returns true when uninstalled.
Future<bool> confirmAndUninstallPlugin(
  BuildContext context,
  PluginItem plugin,
) async {
  final app = AppState.I;
  final servers = _pluginOwnedServers(plugin);
  final removed = <String>[
    if (plugin.runtimeId != null) ...[
      'its permission grant',
      'its saved settings and secrets',
      'installed files and dependencies',
    ] else
      'its installed files',
    if (servers.isNotEmpty)
      'its MCP server${servers.length == 1 ? '' : 's'} '
          '(${servers.map((s) => s.name).join(', ')}) with their credentials',
  ];
  final list = removed.length == 1
      ? removed.single
      : '${removed.take(removed.length - 1).join(', ')} and ${removed.last}';
  final ok = await showDeleteConfirmationDialog(
    context,
    title: 'Uninstall ${plugin.name}?',
    content: 'Removes $list from this device. You can install it again later.',
    confirmLabel: 'Uninstall',
  );
  if (!ok || !context.mounted) return false;
  final messenger = ScaffoldMessenger.maybeOf(context);
  PluginRuntimeCallRecorderForTest.record?.call('uninstall');
  await app.uninstallPlugin(plugin);
  app.serviceStatus.remove('plugin:${plugin.name}');
  app.refresh();
  if (messenger != null && messenger.mounted) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('${plugin.name} uninstalled'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  return true;
}

/// Confirm, then drop an uninstalled user-added [plugin] row from the list.
Future<bool> confirmAndRemovePluginRow(
  BuildContext context,
  PluginItem plugin,
) async {
  final app = AppState.I;
  final ok = await showDeleteConfirmationDialog(
    context,
    title: 'Remove ${plugin.name} from the list?',
    content: 'It is not installed; this only removes the entry.',
    confirmLabel: 'Remove',
  );
  if (!ok) return false;
  app.plugins.remove(plugin);
  await app.persistPluginState();
  app.refresh();
  return true;
}

/// "Reset to defaults": confirm, clear the plugin's saved settings, then
/// enable it through [setPluginEnabled] (real mount, migration gate,
/// reported outcome).
Future<void> resetPluginToDefaults(
  BuildContext context,
  PluginItem plugin,
  List<NativePluginConfigField> fields,
) async {
  final ok = await showDeleteConfirmationDialog(
    context,
    title: 'Reset ${plugin.name} to defaults?',
    content: fields.isEmpty
        ? 'Re-enables the plugin with its default configuration.'
        : 'Deletes the settings saved for this plugin (including secrets) '
              'and re-enables it.',
    confirmLabel: 'Reset',
  );
  if (!ok || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final runtimeId = plugin.runtimeId;
  if (fields.isNotEmpty && runtimeId != null) {
    try {
      await NativePluginConfigStore.I.clear(
        pluginName: runtimeId,
        fields: fields,
      );
    } catch (e) {
      Diag.swallow('plugin-reset', e);
      if (messenger != null && messenger.mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text("Couldn't clear saved settings. Try again."),
          ),
        );
      }
      return;
    }
  }
  if (!context.mounted) return;
  final enabled = await setPluginEnabled(context, plugin, true);
  if (enabled && messenger != null && messenger.mounted) {
    messenger.showSnackBar(
      SnackBar(content: Text('${plugin.name} reset to defaults')),
    );
  }
}

/// After a plugin's settings are saved: reconnect its connected MCP servers
/// so their env/headers/url pick up the new `CLAUDE_PLUGIN_OPTION_*` /
/// `${user_config.*}` values (hooks read them on every run).
Future<void> applyPluginSettings(
  BuildContext context,
  PluginItem plugin,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final running = _pluginOwnedServers(
    plugin,
  ).where((s) => s.connected).toList();
  var failed = 0;
  for (final s in running) {
    await AppState.I.toggleMcpServer(s); // disconnect
    final outcome = await AppState.I.toggleMcpServer(s); // reconnect
    if (!outcome.ok) failed++;
  }
  if (running.isEmpty || messenger == null || !messenger.mounted) return;
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        failed == 0
            ? 'Settings applied · restarted ${running.length} MCP '
                  'server${running.length == 1 ? '' : 's'}'
            : 'Settings saved, but $failed MCP '
                  'server${failed == 1 ? '' : 's'} failed to restart',
      ),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// True when [plugin] is an inbuilt (source-less) row that ships with the
/// app and should install directly rather than opening the add sheet.
bool _isInbuiltPlugin(PluginItem plugin) {
  if (plugin.source != null || plugin.marketplace != null) return false;
  const inbuiltAuthors = {
    'ovidai',
    'you',
    'sandbox',
    'termux',
    'modelcontextprotocol',
  };
  return inbuiltAuthors.contains(plugin.author);
}

/// Where the Install button on a catalog row goes. The add-sheet is ONLY
/// for the explicit + button — tapping Install on a row must resolve to a
/// real install path, never open the add sheet as a surprise.
enum PluginInstallKind {
  githubSource,
  builtinDirect,
  mcpServer,
  nativeCapability,
  unsupported,
}

@visibleForTesting
({PluginInstallKind kind, GithubPluginSource? github, McpServer? server})
pluginInstallRouteForTest(PluginItem plugin) {
  if (NativePluginRegistry.I.has(plugin.name)) {
    return (
      kind: PluginInstallKind.nativeCapability,
      github: null,
      server: null,
    );
  }
  final source = plugin.source;
  if (source != null) {
    // Marketplace rows carry a 'marketplace:owner/repo' source — strip the
    // scheme before parsing, otherwise it becomes a bogus GitHub owner.
    final stripped = source.startsWith('marketplace:')
        ? source.substring('marketplace:'.length)
        : source;
    final derived = githubPluginSourceFromSourceString(stripped);
    if (derived != null) {
      return (
        kind: PluginInstallKind.githubSource,
        github: derived,
        server: null,
      );
    }
    return (kind: PluginInstallKind.unsupported, github: null, server: null);
  }
  if (plugin.marketplace != null) {
    // Marketplace-listed row without a direct source: install runs through
    // the marketplace flow, not the GitHub fetch.
    return (kind: PluginInstallKind.unsupported, github: null, server: null);
  }
  // MCP rows that name a real configured server install by connecting it
  // (credential-aware) instead of flipping a flag that later probes red.
  if (plugin.category == 'MCP') {
    final server = AgentService.mcpServerForPlugin(plugin);
    if (server != null) {
      return (kind: PluginInstallKind.mcpServer, github: null, server: server);
    }
    return (kind: PluginInstallKind.unsupported, github: null, server: null);
  }
  if (_isInbuiltPlugin(plugin)) {
    // Direct install ONLY with real backing — flag-flipping a backing-less
    // row is the fake success that probes red on back navigation.
    if (AgentService.builtinPluginHasBacking(plugin.name)) {
      return (
        kind: PluginInstallKind.builtinDirect,
        github: null,
        server: null,
      );
    }
    return (kind: PluginInstallKind.unsupported, github: null, server: null);
  }
  if (plugin.author == 'you') {
    return (kind: PluginInstallKind.builtinDirect, github: null, server: null);
  }
  return (kind: PluginInstallKind.unsupported, github: null, server: null);
}

/// True when a catalog row can NEVER be installed: it routes to `unsupported`
/// AND names no source/marketplace repo to add. Tapping Install on such a row
/// used to advise "add its repo with the + button" — impossible, because there
/// is no repo. These rows must not look installable at all (WS4 honesty,
/// audit 2026-09-25).
@visibleForTesting
bool inbuiltUninstallableForTest(PluginItem plugin) =>
    plugin.source == null &&
    plugin.marketplace == null &&
    pluginInstallRouteForTest(plugin).kind == PluginInstallKind.unsupported;

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
      return Icon(
        Icons.check_circle_outline,
        size: 18,
        color: Aether.success,
      );
    case StartupItemState.queued:
    case StartupItemState.running:
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2, color: Aether.accent),
      );
    case StartupItemState.failed:
    case StartupItemState.unsupported:
      return Tooltip(
        message: tooltip,
        child: Icon(Icons.error_outline, size: 18, color: Aether.danger),
      );
    case StartupItemState.degraded:
    case StartupItemState.skipped:
    case StartupItemState.needsSetup:
    case StartupItemState.migrationRequired:
      return Tooltip(
        message: tooltip,
        child: Icon(Icons.warning_amber, size: 18, color: Aether.accent),
      );
    case StartupItemState.disabled:
      return Icon(Icons.power_settings_new, size: 18, color: Aether.textFaint);
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

/// Task 11 (spec §11): the ONE core transaction behind the GitHub-only UI;
/// core still accepts all [PluginSource] types (marketplace row, GitHub
/// repo, local folder, ZIP, npm, pasted JSON/TOML, stdio, HTTP).
/// Inspect → consolidated approval
/// sheet → atomic install transaction via [AppState.installPlugin].
///
/// Pass a catalog [plugin] row to sync it with the install, or null to
/// install a source the catalog has no row for (the row is created).
/// Returns the transaction result, or null when the user cancelled /
/// no approval (nothing changed — cancel leaves NO state).
///
/// [onProgress] receives line-based install output (dependency
/// installer lines, fetch summaries) for live UI streaming; it is
/// threaded through [AppState.installPlugin] → the runtime → the
/// dependency installer. [sourceProgress] receives the resolver's raw
/// byte progress for the fetch stage (a UI typically wraps it into
/// readable labels with [fetchProgressLabel]).
/// [approvalContext] belongs to this install only; without it, an install
/// needing fresh approval fails closed.
Future<PluginInstallResult?> startPluginInstallForTest(
  AppState app,
  PluginItem? plugin, {
  required PluginSource source,
  BuildContext? approvalContext,
  void Function(String line)? onProgress,
  PluginSourceProgress? sourceProgress,
  VoidCallback? onApproved,
}) async {
  PluginInspection inspection;
  try {
    inspection = await PluginRuntimeManager.I.inspect(
      source,
      onProgress: sourceProgress,
    );
  } catch (e) {
    return PluginInstallResult.failed(error: 'source resolution failed: $e');
  }
  PluginInspectRecorderForTest.record?.call(source, inspection.manifest);
  inspectResultsForTest.add(inspection.manifest);
  // Wrap the resolver's byte counts into one readable fetch summary
  // line for the live log.
  onProgress?.call(
    'Fetched ${source.sourceId}: ${inspection.source.fileCount} files staged',
  );

  // One consolidated capability + dependency approval (Task 5 sheet).
  // An unchanged-digest grant reuses silently; anything else prompts.
  var grant = await AppState.pluginPermissions.effectiveGrant(
    pluginId: inspection.manifest.id,
    manifest: inspection.manifest,
  );
  final scaffoldContext = approvalContext;
  // Set when THIS flow saved a fresh approval: a failed install must not
  // leave consent behind for content that never installed (it would be
  // reused silently by the next install of the same digest).
  var approvedHere = false;
  PluginPermissionGrant? priorGrant;
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
    priorGrant = await AppState.pluginPermissions.loadAny(
      inspection.manifest.id,
    );
    if (!scaffoldContext.mounted) {
      inspection.discard();
      return null;
    }
    // ignore: use_build_context_synchronously
    final accepted = await showPluginPermissionSheet(
      scaffoldContext,
      manifest: inspection.manifest,
      provenance: PluginSourceProvenance.fromResolved(inspection.source),
    );
    if (accepted != true) {
      inspection.discard();
      return null; // cancelled — no state
    }
    approvedHere = true;
    grant = await AppState.pluginPermissions.effectiveGrant(
      pluginId: inspection.manifest.id,
      manifest: inspection.manifest,
    );
  }

  // Approved (fresh or reused grant): only now may the UI say "Installing".
  onApproved?.call();
  PluginItem row = plugin ?? _catalogRowFor(inspection.manifest);
  // Single-inspection flow (review C1): the approved inspection passes
  // straight through — no re-resolve, no second staging. The manager
  // consumes staging on success and discards it on failure, so there is
  // nothing left here to discard either way; a null result (no derivable
  // source) cannot happen for an already-inspected flow.
  Future<void> discardFreshApproval() async {
    if (!approvedHere) return;
    try {
      await AppState.pluginPermissions.discardApproval(
        inspection.manifest.id,
        restore: priorGrant,
      );
    } catch (e) {
      Diag.swallow('plugin-install.discard-approval', e);
    }
  }

  final PluginInstallResult? result;
  try {
    result = await app.installPlugin(
      row,
      inspection: inspection,
      origin: PluginInstallOrigin.pluginsScreen,
      onProgress: onProgress,
    );
  } catch (_) {
    await discardFreshApproval();
    rethrow;
  }
  if (result == null || result.status == PluginInstallStatus.failed) {
    await discardFreshApproval();
  }
  if (result == null) {
    // No row to sync — remember the runtime install anyway.
    inspection.discard();
    return PluginInstallResult.failed(
      error: 'install failed: no catalog row could be derived',
    );
  }
  return result;
}

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

/// Which half of the add sheet opens first.
enum PluginAddTab { plugin, mcp }

/// The single "+" sheet — the one add entry point. Two tabs:
///   • Plugin / marketplace: one repo field (`owner/repo` or URL via
///     [parseGithubSourceInput]) funnels into the single inspection/approval
///     flow ([_runSourceInstall]); the same field adds a marketplace (repo
///     recorded + catalog fetched) with the marketplace list + remove below.
///   • MCP server (Claude Code `claude mcp add` / `add-json` parity): a
///     stdio command, a remote http/sse URL, or a pasted `mcpServers` JSON
///     ([McpServerAddForm]); the server is stored and then connected.
Future<void> showPluginAddSheet(
  BuildContext context, {
  PluginAddTab initialTab = PluginAddTab.plugin,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Aether.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) =>
        _PluginAddSheet(hostContext: context, initialTab: initialTab),
  );
}

/// Test seam: replaces the connect that follows adding an MCP server from
/// the add sheet. Null in production ([connectMcpServer]).
@visibleForTesting
Future<void> Function(BuildContext context, McpServer server)?
mcpAddConnectOverrideForTest;

class _PluginAddSheet extends StatefulWidget {
  /// The screen's context — survives the sheet being popped, so the install
  /// and connect flows can keep reporting after it closes.
  final BuildContext hostContext;
  final PluginAddTab initialTab;
  const _PluginAddSheet({required this.hostContext, required this.initialTab});

  @override
  State<_PluginAddSheet> createState() => _PluginAddSheetState();
}

class _PluginAddSheetState extends State<_PluginAddSheet> {
  final TextEditingController repoC = TextEditingController();
  String? repoError;
  late PluginAddTab _tab = widget.initialTab;

  @override
  void dispose() {
    repoC.dispose();
    super.dispose();
  }

  void _fetchFromGithub() {
    final parsed = parseGithubSourceInput(repoC.text);
    final src = parsed.source;
    if (src == null) {
      setState(() => repoError = parsed.error);
      return;
    }
    final context = widget.hostContext;
    Navigator.pop(this.context);
    _runSourceInstall(context, src, null);
  }

  Future<void> _addMarketplace() async {
    final app = AppState.I;
    final context = widget.hostContext;
    final messenger = ScaffoldMessenger.of(context);
    final added = app.addMarketplaceChecked(repoC.text);
    final repo = added.repo;
    if (repo == null) {
      setState(
        () => repoError = switch (added.error) {
          MarketplaceAddError.duplicate => 'That marketplace is already added.',
          _ => 'Enter a marketplace as owner/repo or a GitHub repository URL.',
        },
      );
      return;
    }
    Navigator.pop(this.context);
    messenger.showSnackBar(
      SnackBar(
        content: Text('Importing $repo…'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    // Registering only records the repo — the catalog has to
    // be fetched for its plugins/MCP servers to show up.
    final msg = await app.fetchMarketplaceCatalog(repo);
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _onMcpAdded(List<McpServer> servers) async {
    final context = widget.hostContext;
    Navigator.pop(this.context);
    final connect = mcpAddConnectOverrideForTest ?? connectMcpServer;
    for (final server in servers) {
      if (!context.mounted) return;
      await connect(context, server);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
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
                    child: Icon(
                      Icons.add,
                      size: 19,
                      color: Aether.accent,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Add plugin, MCP server or marketplace',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close, size: 18, color: Aether.textFaint),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<PluginAddTab>(
                  key: const ValueKey('plugin-add-tabs'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: PluginAddTab.plugin,
                      icon: Icon(Icons.extension_outlined, size: 16),
                      label: Text('Plugin / marketplace'),
                    ),
                    ButtonSegment(
                      value: PluginAddTab.mcp,
                      icon: Icon(Icons.usb_outlined, size: 16),
                      label: Text('MCP server'),
                    ),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (v) => setState(() => _tab = v.first),
                ),
              ),
              const SizedBox(height: 12),
              if (_tab == PluginAddTab.mcp)
                McpServerAddForm(onAdded: _onMcpAdded)
              else
                ..._pluginTab(ctx, app),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _pluginTab(BuildContext ctx, AppState app) => [
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
      textInputAction: TextInputAction.go,
      onSubmitted: (_) => _fetchFromGithub(),
      onChanged: (_) {
        if (repoError != null) setState(() => repoError = null);
      },
      style: const TextStyle(fontSize: 13.5, fontFamily: Aether.mono),
      decoration: InputDecoration(
        hintText: 'owner/repo or https://github.com/owner/repo',
        errorText: repoError,
        errorMaxLines: 4,
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
        onPressed: _fetchFromGithub,
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
        label: const Text('Add marketplace', style: TextStyle(fontSize: 13.5)),
        onPressed: _addMarketplace,
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
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
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
              // Every entry — including the legacy default, which
              // 404s and is no longer seeded — is removable.
              IconButton(
                key: ValueKey('sheet-marketplace-remove-$m'),
                tooltip: 'Remove marketplace',
                // Removal uninstalls its plugins — never one tap.
                onPressed: () => confirmAndRemoveMarketplace(ctx, m),
                icon: Icon(
                  Icons.delete_outline,
                  size: 16,
                  color: Aether.danger,
                ),
              ),
            ],
          ),
        ),
    ],
  ];
}

final _ghSegment = RegExp(r'^[A-Za-z0-9_.-]+$');

/// Parses what a user types into the add sheet's repo field:
///   • `owner/repo`, `owner/repo@ref`, `owner/repo#ref`
///   • `github.com/owner/repo` (with or without `https://`, `www.`, `.git`)
///   • `https://github.com/owner/repo/tree/<ref>/<path>` → ref + subPath
///     (installs that subdirectory, not the repo root)
///   • `git@github.com:owner/repo.git`
/// Anything else after `owner/repo` is rejected with a specific error.
({GithubPluginSource? source, String? error}) parseGithubSourceInput(
  String input,
) {
  const hint =
      'Use owner/repo, owner/repo@ref, or a GitHub URL '
      '(…/tree/<ref>/<folder> installs that folder).';
  var txt = input.trim();
  if (txt.isEmpty) {
    return (source: null, error: 'Enter owner/repo or a GitHub URL.');
  }
  txt = txt.replaceFirst(RegExp(r'^git@github\.com:'), '');
  final hadScheme = RegExp(r'^[a-z]+://').hasMatch(txt);
  txt = txt
      .replaceFirst(RegExp(r'^[a-z]+://'), '')
      .replaceFirst(RegExp(r'^www\.'), '');
  if (txt.startsWith('github.com/')) {
    txt = txt.substring('github.com/'.length);
  } else if (hadScheme || RegExp(r'^[^/]+\.[a-z]{2,}/').hasMatch(txt)) {
    return (
      source: null,
      error: 'Only GitHub repositories are supported here. $hint',
    );
  }
  txt = txt.split('?').first.replaceFirst(RegExp(r'/+$'), '');
  String? ref;
  // `owner/repo@ref` / `owner/repo#ref` (short form).
  final short = RegExp(r'^([^/@#]+)/([^/@#]+)[@#]([^/@#\s]+)$').firstMatch(txt);
  if (short != null) {
    txt = '${short.group(1)}/${short.group(2)}';
    ref = short.group(3);
  } else if (txt.contains('#')) {
    final i = txt.indexOf('#');
    final frag = txt.substring(i + 1);
    txt = txt.substring(0, i);
    if (frag.isNotEmpty) ref = frag;
  }
  final parts = txt.split('/');
  if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) {
    return (source: null, error: 'Enter owner/repo or a GitHub URL. $hint');
  }
  final owner = parts[0];
  final repo = parts[1].replaceFirst(RegExp(r'\.git$'), '');
  if (!_ghSegment.hasMatch(owner) || !_ghSegment.hasMatch(repo)) {
    return (source: null, error: '"$owner/$repo" is not a valid repository.');
  }
  String? subPath;
  if (parts.length > 2) {
    final rest = parts.sublist(2);
    if ((rest[0] == 'tree' || rest[0] == 'blob') &&
        rest.length >= 2 &&
        rest[1].isNotEmpty) {
      ref = rest[1];
      final sub = rest.sublist(2).where((p) => p.isNotEmpty).join('/');
      if (sub.isNotEmpty) {
        if (sub.split('/').any((p) => p == '..' || p == '.')) {
          return (source: null, error: 'The folder path is not valid. $hint');
        }
        subPath = sub;
      }
    } else {
      return (
        source: null,
        error: 'Unexpected "/${rest.join('/')}" after $owner/$repo. $hint',
      );
    }
  }
  return (
    source: GithubPluginSource(
      owner: owner,
      repo: repo,
      ref: ref,
      subPath: subPath,
    ),
    error: null,
  );
}

/// User-facing copy for an install failure — never a raw Dart exception
/// string. The raw text stays available under "Details".
String describeInstallFailure(Object? error) {
  final raw = '${error ?? ''}';
  final lower = raw.toLowerCase();
  if (error is SocketException ||
      error is TimeoutException ||
      lower.contains('socketexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('network is unreachable') ||
      lower.contains('connection refused') ||
      lower.contains('connection timed out') ||
      lower.contains('timed out')) {
    return "You're offline or GitHub can't be reached. Check your "
        'connection and try again.';
  }
  if (lower.contains('rate limit') ||
      lower.contains('http 403') ||
      lower.contains('http 429')) {
    return 'GitHub rate limit reached. Sign in to GitHub (Settings → '
        'GitHub) to raise the limit, then retry.';
  }
  if (lower.contains('http 404') ||
      lower.contains('not found') ||
      lower.contains('tree unreachable')) {
    return "Couldn't find that repository. Check owner/repo — private "
        'repositories need GitHub sign-in.';
  }
  if (lower.contains('no plugin content') ||
      lower.contains('canonical publisher/name') ||
      lower.contains('manifest')) {
    return 'No usable plugin manifest found in this repository '
        '(.claude-plugin/plugin.json, .codex-plugin/plugin.json or .mcp.json).';
  }
  if (lower.contains('required compatibility')) {
    return "This plugin needs features Ovid can't provide on this device.";
  }
  if (lower.contains('dependenc')) {
    return 'A required dependency failed to install. See Details.';
  }
  if (lower.contains('approval required')) {
    return 'This install needs your approval first.';
  }
  if (error is FormatException || lower.contains('formatexception')) {
    return "The plugin's files couldn't be read (invalid format).";
  }
  return 'The install failed. See Details for the technical error.';
}

/// Honest summary of a finished install (outcome + copy + raw details),
/// built from the result's activation record and probe failures.
@visibleForTesting
({InstallOutcome outcome, String summary, String? details})
describeInstallOutcome(PluginInstallResult? result, {Object? crash}) {
  if (crash != null) {
    return (
      outcome: InstallOutcome.failed,
      summary: describeInstallFailure(crash),
      details: '$crash',
    );
  }
  if (result == null) {
    return (
      outcome: InstallOutcome.cancelled,
      summary: 'Install cancelled — nothing was changed.',
      details: null,
    );
  }
  final record = result.record;
  final activation = switch (record?.state) {
    PluginActivation.sessionActive => 'Active in this chat now.',
    PluginActivation.globalActive => 'Enabled everywhere.',
    PluginActivation.pendingGlobal => 'Restart Ovid to enable it everywhere.',
    _ when record?.promoteOnNextBoot ?? false =>
      'Restart Ovid to enable it everywhere.',
    _ => null,
  };
  switch (result.status) {
    case PluginInstallStatus.ok:
      return (
        outcome: InstallOutcome.success,
        summary: activation == null
            ? 'Installed ✓'
            : 'Installed ✓ — $activation',
        details: null,
      );
    case PluginInstallStatus.degraded:
      final warnings = [
        if (result.degradedNames.isNotEmpty)
          'optional dependencies failed (${result.degradedNames.join(', ')})',
        if (result.probeFailures.isNotEmpty)
          'missing files: ${result.probeFailures.join(', ')}',
      ];
      return (
        outcome: InstallOutcome.degraded,
        summary:
            'Installed with warnings'
            '${warnings.isEmpty ? '' : ': ${warnings.join('; ')}'}.'
            '${activation == null ? '' : ' $activation'}',
        details: null,
      );
    case PluginInstallStatus.failed:
      return (
        outcome: InstallOutcome.failed,
        summary: describeInstallFailure(result.error),
        details: result.error,
      );
  }
}

/// Runs one source install to completion with live progress + honest
/// result reporting (never a silent failure).
///
/// A progress sheet streams the resolver's byte progress (wrapped into
/// readable labels) and the dependency installer's line-based output
/// into one terminal-style log with follow-mode auto-scroll. The
/// outcome is also reported via SnackBar, so dismissing the sheet
/// mid-install loses nothing — the install keeps running.
Future<void> _runSourceInstall(
  BuildContext context,
  PluginSource source,
  PluginItem? row,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);

  // WS2 live progress: created before the install starts so no line is
  // lost; the sheet reads the controller's current state when it opens.
  final progress = PluginInstallProgress();
  progress.setPhase('Fetching plugin source…');
  progress.line('Fetching ${source.sourceId}…');

  // Order (F-103): inspect inline → capability approval → only THEN the
  // "Installing" sheet. Declining never leaves a red result behind.
  messenger.showSnackBar(
    SnackBar(
      content: Text('Fetching ${source.sourceId}…'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(minutes: 5),
    ),
  );
  var sheetOpen = false;
  void openSheet() {
    if (sheetOpen || !context.mounted) return;
    sheetOpen = true;
    messenger.hideCurrentSnackBar();
    unawaited(
      showAetherSheet<void>(
        context: context,
        builder: (_) => PluginInstallProgressSheet(
          progress: progress,
          title: 'Installing ${row?.name ?? source.sourceId}',
          subtitle: 'Plugin install — live log',
        ),
      ),
    );
  }

  PluginInstallResult? result;
  Object? crash;
  var depsStarted = false;
  try {
    result = await startPluginInstallForTest(
      AppState.I,
      row,
      source: source,
      approvalContext: context,
      onApproved: () {
        progress.setPhase('Installing…');
        openSheet();
      },
      sourceProgress: (received, total) {
        final value = total == null || total <= 0
            ? null
            : (received / total).clamp(0.0, 1.0);
        progress.setPhase(
          fetchProgressLabel(source.sourceId, received, total),
          value,
        );
      },
      onProgress: (line) {
        // The dependency installer tags its lines `[npm]` / `[python]` /
        // `[native]` — the first such line marks the end of the fetch
        // stage and the start of dependency installation.
        if (!depsStarted && line.startsWith('[')) {
          depsStarted = true;
          progress.setPhase('Installing dependencies…');
        }
        progress.line(line);
      },
    );
  } catch (e) {
    crash = e;
  }
  final described = describeInstallOutcome(result, crash: crash);
  final installedId = result?.manifest?.id;
  final installedRow = installedId == null
      ? null
      : AppState.I.plugins.where((p) => p.runtimeId == installedId).firstOrNull;
  void openPlugin() {
    final target = installedRow ?? row;
    if (target == null) return;
    navigator.push(
      MaterialPageRoute(builder: (_) => PluginDetailScreen(plugin: target)),
    );
  }

  final details = described.details;
  if (details != null) progress.line(details);
  progress.finish(
    outcome: described.outcome,
    summary: described.summary,
    details: details,
    onOpenPlugin: (installedRow ?? row) == null ? null : openPlugin,
  );
  if (!sheetOpen) messenger.hideCurrentSnackBar();
  if (messenger.mounted) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(described.summary),
        behavior: SnackBarBehavior.floating,
        action:
            sheetOpen ||
                described.outcome == InstallOutcome.cancelled ||
                details == null
            ? null
            : SnackBarAction(
                label: 'Details',
                onPressed: () {
                  if (!context.mounted) return;
                  openSheet();
                },
              ),
      ),
    );
  }
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

  void _revealFocus(List<PluginItem> items, Map<PluginItem, String> focusIds) {
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
      // Variable-height cards (large text, long errors, MCP rows) cannot be
      // found by repeatedly jumping to the same fixed-height estimate.
      final estimate = (_revealAttempts == 1
          ? index * _estimatedPluginCardExtent
          : _scroll.offset + _scroll.position.viewportDimension * 0.8).clamp(
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

  /// The last refresh's per-repo outcome (null before the first one).
  MarketplaceSyncReport? _syncReport;

  /// Error of a refresh that threw outright (not a per-repo failure).
  String? _syncCrash;

  Future<void> _syncCatalogs({bool force = false}) async {
    if (!mounted || _syncing) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _syncing = true);
    MarketplaceSyncReport? report;
    String? crash;
    try {
      report = await AppState.I.syncMarketplaceCatalogsReport(force: force);
    } catch (e) {
      // The built-in catalog still renders; say the refresh failed.
      Diag.swallow('plugins-sync', e);
      crash = "Couldn't refresh marketplaces. Try again.";
    }
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _syncReport = report;
      _syncCrash = crash;
    });
    // An explicit Refresh always answers, even when everything worked.
    if (force &&
        crash == null &&
        report != null &&
        report.failures.isEmpty &&
        messenger != null &&
        messenger.mounted) {
      final n = report.fetched;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            n == 0
                ? 'No marketplaces to refresh'
                : 'Refreshed $n marketplace${n == 1 ? '' : 's'}',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// "Couldn't refresh 2 marketplaces · Retry" / offline banner.
  Widget? _syncBanner() {
    final report = _syncReport;
    final failures = report?.failures ?? const <String, String>{};
    if (_syncCrash == null && failures.isEmpty) return null;
    final offline = report?.offline ?? false;
    final text = _syncCrash != null
        ? _syncCrash!
        : offline
        ? "You're offline — showing saved catalogs. Marketplaces will "
              'refresh when you reconnect.'
        : "Couldn't refresh ${failures.length} "
              'marketplace${failures.length == 1 ? '' : 's'}: '
              '${failures.keys.join(', ')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Container(
        key: const ValueKey('marketplace-sync-banner'),
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        decoration: BoxDecoration(
          color: Aether.surfaceAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Aether.warnLight.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(
              offline ? Icons.cloud_off_outlined : Icons.warning_amber,
              size: 16,
              color: Aether.warnLight,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 12, color: Aether.textMuted),
              ),
            ),
            TextButton(
              onPressed: _syncing ? null : () => _syncCatalogs(force: true),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  /// MCP servers matching the search query (name, description, id).
  bool _mcpMatches(McpServer s) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return s.name.toLowerCase().contains(q) ||
        s.description.toLowerCase().contains(q) ||
        s.canonicalId.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    const cats = ['All', 'Agent', 'MCP', 'Tool', 'Runtime'];
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        toolbarHeight: MediaQuery.textScalerOf(context).scale(20) > 28 ? 104 : 64,
        title: const Text('Plugins & marketplaces'),
        actions: [
          if (_syncing)
            Padding(
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
            tooltip: 'Add plugin, MCP server or marketplace',
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
          // Recompute on every notification, including installs and catalog
          // changes. Generate legacy ids before grouping to keep them stable.
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
          final filtered = app.plugins
              .where(
                (p) =>
                    (!migrationOnly ||
                        durablePluginStatus(p)?.state ==
                            StartupItemState.migrationRequired) &&
                    (_cat == 'All' || p.category == _cat) &&
                    (p.name.toLowerCase().contains(_query.toLowerCase()) ||
                        p.description.toLowerCase().contains(
                          _query.toLowerCase(),
                        )),
              )
              .toList();
          // Stable partition: disabled installations still come first, and
          // catalog order within each group is preserved without mutating it.
          final items = [
            ...filtered.where((p) => p.installed),
            ...filtered.where((p) => !p.installed),
          ];
          final installedMcpIds = {
            for (final p in app.plugins.where(
              (p) => p.installed && p.category == 'MCP',
            ))
              if (AgentService.mcpServerForPlugin(p) case final server?)
                server.canonicalId,
          };
          bool configured(McpServer s) =>
              s.custom ||
              (s.ownerPluginId?.isNotEmpty ?? false) ||
              installedMcpIds.contains(s.canonicalId);
          // Search and the category chips filter the MCP section too: it
          // renders only for All/MCP, and only matching servers.
          final showMcp = _cat == 'All' || _cat == 'MCP';
          final visibleServers = app.mcpServers.where(_mcpMatches);
          final servers = [
            ...visibleServers.where(configured),
            ...visibleServers.where((s) => !configured(s)),
          ];
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
                      hintText:
                          'Search ${app.plugins.length} plugins & '
                          '${app.mcpServers.length} MCP servers…',
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
                child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                    children: [
                      for (final c in cats)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(
                              c,
                              style: const TextStyle(fontSize: 12),
                            ),
                            selected: _cat == c,
                            onSelected: (_) => setState(() => _cat = c),
                            showCheckmark: false,
                            selectedColor: Aether.accentSoft,
                            backgroundColor: Aether.surfaceAlt,
                            side: BorderSide(
                              color: _cat == c
                                  ? Aether.accent
                                  : Aether.hairline,
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
              if (_syncBanner() case final banner?)
                SliverToBoxAdapter(child: banner),
              // ── MCP section ──
              if (!migrationOnly && showMcp)
                SliverToBoxAdapter(
                  child: _McpSection(
                    servers: servers,
                    totalServers: app.mcpServers.length,
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
                      style: TextStyle(fontSize: 11.5, color: Aether.textMuted),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20, 12, 20, 2),
                  child: AetherSectionTitle(
                    eyebrow: migrationOnly
                        ? 'Needs re-approval'
                        : items.isEmpty || items.any((p) => p.installed)
                            ? 'Installed'
                            : 'Available',
                    subtitle: migrationOnly
                        ? null
                        : app.plugins.isEmpty
                            ? 'Nothing installed yet'
                            : null,
                  ),
                ),
              ),
              if (items.isEmpty && !migrationOnly)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: AetherEmptyState(
                      key: const ValueKey('plugins-empty-state'),
                      icon: Icons.extension_outlined,
                      title: app.plugins.isEmpty ? 'No plugins installed' : 'No matching plugins',
                      message: app.plugins.isEmpty
                          ? 'Add a plugin from a GitHub repo or a marketplace '
                          'with the + button above — one capability approval, '
                          'then it is yours.'
                          : 'Try another search or category to find your plugins.',
                      action: app.plugins.isEmpty ? AetherPrimaryButton(
                        label: 'Add plugin or marketplace',
                        icon: Icons.add,
                        onPressed: () => showPluginAddSheet(context),
                      ) : null,
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                sliver: SliverList.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final p = items[i];
                    final focusId = focusIds[p];
                    final card = PluginCard(
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
                    if (!migrationOnly && i > 0 && items[i - 1].installed && !p.installed) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 8, bottom: 10),
                            child: AetherSectionTitle(eyebrow: 'Available'),
                          ),
                          card,
                        ],
                      );
                    }
                    return card;
                  },
                ),
              ),
              // ── Marketplaces section (premium redesign) ──
              if (!migrationOnly)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
                    child: AetherSectionTitle(
                      eyebrow: 'Marketplaces',
                      subtitle: app.marketplaces.isEmpty
                          ? 'No marketplaces added yet'
                          : null,
                    ),
                  ),
                ),
              if (!migrationOnly && app.marketplaces.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: AetherEmptyState(
                      key: const ValueKey('marketplaces-empty-state'),
                      icon: Icons.inventory_2_outlined,
                      title: 'No marketplaces yet',
                      message:
                          'Marketplaces are GitHub repositories listing '
                          'plugins and MCP servers. Add one with the + button.',
                      action: AetherSecondaryButton(
                        label: 'Add marketplace',
                        icon: Icons.add,
                        onPressed: () => showPluginAddSheet(context),
                      ),
                    ),
                  ),
                )
              else if (!migrationOnly)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  sliver: SliverList.separated(
                    itemCount: app.marketplaces.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _MarketplaceCard(
                      key: ValueKey(
                        'marketplace-card-${app.marketplaces[i]}',
                      ),
                      repo: app.marketplaces[i],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Premium marketplace repo card: name, remove, and a Browse ghost that
/// routes through the AppState marketplace catalog fetcher so the installed
/// plugin list refreshes without closing this screen.
class _MarketplaceCard extends StatefulWidget {
  final String repo;
  const _MarketplaceCard({super.key, required this.repo});

  @override
  State<_MarketplaceCard> createState() => _MarketplaceCardState();
}

class _MarketplaceCardState extends State<_MarketplaceCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AetherCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Aether.surfaceRaised,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.inventory_2_outlined,
              size: 18,
              color: Aether.textMuted,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                    widget.repo,
                  style: AetherType.title.copyWith(fontSize: 13.5),
                ),
                const SizedBox(height: 2),
                Text(
                  switch ((
                    app.marketplaceSyncErrors[widget.repo],
                    app.marketplaceLastSynced[widget.repo],
                  )) {
                    (final String _, _) =>
                      'GitHub marketplace · last refresh failed',
                    (null, final DateTime at) =>
                      'GitHub marketplace · synced ${usageRelativeTime(at, now: DateTime.now())}',
                    _ => 'GitHub marketplace',
                  },
                  key: ValueKey('marketplace-sync-${widget.repo}'),
                  style: AetherType.caption.copyWith(
                    color: app.marketplaceSyncErrors.containsKey(widget.repo)
                        ? Aether.warnLight
                        : null,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
          AetherGhostButton(
            label: _busy ? 'Browsing…' : 'Browse',
            icon: Icons.open_in_new,
            loading: _busy,
            onPressed: _busy
                ? null
                : () async {
                    final messenger = ScaffoldMessenger.of(context);
                    setState(() => _busy = true);
                    try {
                      final msg = await app.fetchMarketplaceCatalog(widget.repo);
                      if (!mounted) return;
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(msg),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    } catch (e) {
                      Diag.swallow('marketplace-browse', e);
                      if (mounted) {
                        messenger.showSnackBar(
                          const SnackBar(
                            content: Text(
                              "Couldn't load this marketplace. Check your "
                              'connection and try again.',
                            ),
                          ),
                        );
                      }
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
          ),
          const SizedBox(width: 2),
          IconButton(
            key: ValueKey('marketplace-remove-${widget.repo}'),
            tooltip: 'Remove marketplace',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.delete_outline,
              size: 18,
              color: Aether.danger,
            ),
            onPressed: _busy
                ? null
                : () async {
                    await confirmAndRemoveMarketplace(context, widget.repo);
                  },
          ),
            ],
          ),
        ],
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
  /// or Ovid built-in. Rows with a runtime install derive the badge from
  /// their normalized manifest format; catalog-only rows fall back to the
  /// marketplace / category heuristic (MCP-category rows are always MCP).
  static String sourceFormatLabel(PluginItem p) {
    final runtimeId = p.runtimeId;
    final format = runtimeId == null
        ? null
        : PluginContributionRegistry.I.manifestFor(runtimeId)?.format;
    return formatLabelFor(format, _catalogFormatLabel(p));
  }

  /// Maps a normalized manifest [format] to its badge label, falling
  /// back to [catalogLabel] when the row has no runtime manifest.
  @visibleForTesting
  static String formatLabelFor(PluginFormat? format, String catalogLabel) =>
      switch (format) {
        PluginFormat.claudeCode => 'Claude Code',
        PluginFormat.codex => 'Codex',
        PluginFormat.genericMcp => 'MCP',
        null => catalogLabel,
      };

  static String _catalogFormatLabel(PluginItem p) {
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
        key: _keyId == null ? null : ValueKey('plugin-card-$_keyId'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: highlighted ? Aether.accentSoft : Aether.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: highlighted ? Aether.accent : Aether.hairline,
            width: highlighted ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (highlighted)
              Container(
                key: ValueKey('plugin-card-highlight-$_keyId'),
                width: 40,
                height: 3,
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
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      Text(
                        plugin.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Tag(plugin.category.toUpperCase(), filled: true),
                      // Task 11 (spec §11): source/format badge —
                      // Claude Code / Codex / MCP / Ovid built-in.
                      Tag(PluginCard.sourceFormatLabel(plugin), filled: false),
                      // Task 11 (spec §11): activation badge beside the
                      // category tag (This session / Restart to enable
                      // everywhere / Global / Degraded / Failed).
                      ...?switch (pluginActivationBadge(plugin)) {
                        final b? => [b],
                        null => null,
                      },
                      // PR24: hook chips — a plugin with hooks shows which
                      // events it fires (e.g. ON_TURN_START).
                      for (final ev in plugin.hooks.keys)
                        Tag(ev.toUpperCase(), filled: false),
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
                      style: TextStyle(fontSize: 11, color: Aether.textMuted),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    plugin.description,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: Aether.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (plugin.installed) ...[
                      SizedBox(
                        height: 48,
                        child: Switch(
                          key: ValueKey('plugin-switch-${plugin.name}'),
                          value: plugin.enabled,
                          activeTrackColor: Aether.accent,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          onChanged: (val) =>
                              setPluginEnabled(context, plugin, val),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    // One destructive action per row: Uninstall (with
                    // confirmation) on installed rows; "Remove from list"
                    // only for user-added rows. Catalog rows have neither.
                    if (plugin.installed)
                      IconButton(
                        key: ValueKey('plugin-delete-${plugin.name}'),
                        icon: Icon(
                          Icons.delete_outline,
                          size: 18,
                          color: Aether.danger,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        tooltip: 'Uninstall plugin',
                        onPressed: () =>
                            confirmAndUninstallPlugin(context, plugin),
                      )
                    else if (pluginRemovableFromList(plugin))
                      IconButton(
                        key: ValueKey('plugin-remove-${plugin.name}'),
                        icon: Icon(
                          Icons.playlist_remove,
                          size: 18,
                          color: Aether.textMuted,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        tooltip: 'Remove from list',
                        onPressed: () =>
                            confirmAndRemovePluginRow(context, plugin),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Builder(
                  builder: (_) {
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
                        return SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Aether.accent,
                          ),
                        );
                      } else if (status.health == ServiceHealth.working) {
                        return Icon(
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
                            color: Aether.danger,
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
                      plugin.enabled
                          ? Icons.check_circle
                          : Icons.check_circle_outline,
                      size: 18,
                      color: plugin.enabled
                          ? Aether.success
                          : Aether.textFaint,
                    );
                  },
                ),
              ],
            ),
            ),
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
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, ToolUsageStore.I]),
      builder: (context, _) => _buildDetail(context),
    );
  }

  Widget _buildDetail(BuildContext context) {
    final app = AppState.I;
    // Declarative plugin settings UI (audit 2026-09-25): the settings
    // fields an installed plugin's normalized manifest declares. Data-only
    // — [PluginSettingsPanel] renders them; values route through
    // NativePluginConfigStore (secrets → secure storage, never prefs/logs).
    final settingsFields = plugin.installed && plugin.runtimeId != null
        ? PluginContributionRegistry.I.settingsFieldsForPlugin(
            plugin.runtimeId!,
          )
        : const <PluginSettingsField>[];
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(plugin.name),
        actions: [
          if (plugin.installed) ...[
            SizedBox(
              height: 28,
              child: Switch(
                key: ValueKey('plugin-detail-switch-${plugin.name}'),
                value: plugin.enabled,
                activeTrackColor: Aether.accent,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (val) => setPluginEnabled(context, plugin, val),
              ),
            ),
            const SizedBox(width: 4),
          ],
          // Installed rows uninstall from the body's Uninstall button (one
          // action); the app bar only offers "Remove from list" for
          // uninstalled user-added rows.
          if (!plugin.installed && pluginRemovableFromList(plugin))
            IconButton(
              key: ValueKey('plugin-detail-delete-${plugin.name}'),
              tooltip: 'Remove from list',
              icon: Icon(
                Icons.playlist_remove,
                size: 19,
                color: Aether.textMuted,
              ),
              onPressed: () async {
                final removed = await confirmAndRemovePluginRow(
                  context,
                  plugin,
                );
                if (removed && context.mounted) Navigator.pop(context);
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
                      style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        // Task 11 (spec §11): source/format badge beside
                        // the category tag on the detail header.
                        Tag(plugin.category.toUpperCase(), filled: true),
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
                    onPressed: () =>
                        setPluginEnabled(context, plugin, !plugin.enabled),
                  )
                : inbuiltUninstallableForTest(plugin)
                // No Install button for a row nothing can install — an
                // Install that only ever says "can't be installed" is a
                // promise the catalog should not make. Say what it IS.
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 13,
                    ),
                    decoration: BoxDecoration(
                      color: Aether.surfaceRaised,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          plugin.category == 'MCP'
                              ? Icons.hub_outlined
                              : Icons.info_outline,
                          size: 16,
                          color: Aether.textMuted,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            plugin.category == 'MCP'
                                ? 'Managed in the MCP tab — add a server '
                                      'there with the + button.'
                                : 'Not installable — this catalog row has no '
                                      'plugin package behind it.',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Aether.textMuted,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
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
                      // ONE inspection/approval flow for every source.
                      // The add-sheet is ONLY for the explicit + button —
                      // tapping Install on a row must resolve to a real
                      // install path, never open the sheet as a surprise.
                      final route = pluginInstallRouteForTest(plugin);
                      switch (route.kind) {
                        case PluginInstallKind.githubSource:
                          await _runSourceInstall(
                            context,
                            route.github!,
                            plugin,
                          );
                        case PluginInstallKind.mcpServer:
                          // The row IS the server's catalog entry: connect
                          // it (asks credentials first when needed).
                          await connectMcpServer(context, route.server!);
                        case PluginInstallKind.builtinDirect:
                          await app.installBuiltinPlugin(plugin);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '${plugin.name} installed',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            );
                          }
                        case PluginInstallKind.nativeCapability:
                          await app.installBuiltinPlugin(plugin);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '${plugin.name} installed',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            );
                          }
                        case PluginInstallKind.unsupported:
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '"${plugin.name}" can\'t be installed from '
                                  'the catalog — add its repo with the + '
                                  'button instead.',
                                  style: const TextStyle(fontSize: 13),
                                ),
                                behavior: SnackBarBehavior.floating,
                              ),
                            );
                          }
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
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
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
                    // Clears the saved settings, then enables through the
                    // real path (contributions mount; the fail-closed
                    // migration gate applies) and reports the outcome.
                    onPressed: () => resetPluginToDefaults(
                      context,
                      plugin,
                      configFieldsForSettings(settingsFields),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
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
                    // Task 11: uninstall routes through the runtime
                    // manager (registry + content + deps + record + grant +
                    // secrets) via AppState.uninstallPlugin — confirmed.
                    onPressed: () => confirmAndUninstallPlugin(context, plugin),
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
          // ── Declarative settings form (audit 2026-09-25): rendered ONLY
          // from manifest-declared data — no WebView, no JS, no plugin code.
          if (settingsFields.isNotEmpty) ...[
            const SectionHeader(
              'Settings',
              subtitle:
                  'Passed to the plugin as CLAUDE_PLUGIN_OPTION_<KEY> and '
                  r'${user_config.<key>} — secrets stay in secure storage '
                  'on this device',
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: PluginSettingsPanel(
                // A changed field set (Retry activation / update) gets a
                // fresh panel state; didUpdateWidget covers the rest.
                key: ValueKey(
                  '${plugin.runtimeId}|'
                  '${settingsFields.map((f) => f.key).join(',')}',
                ),
                pluginName: plugin.runtimeId!,
                fields: configFieldsForSettings(settingsFields),
                // New values reach hooks on their next run; running MCP
                // servers restart so their env/headers pick them up.
                onSaved: () => applyPluginSettings(context, plugin),
                installedPluginIds: [
                  for (final p in AppState.I.plugins)
                    if (p.runtimeId != null) p.runtimeId!,
                ],
              ),
            ),
          ],
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
          for (final c in tools) _DiagRow('${c.canonicalId} (${c.kindLabel})'),
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
          // Actionable row: open the server (tools, credentials, usage) or
          // set it up / connect inline. Durable-only status text (spec §5.3).
          _OwnedMcpTile(server: s),
          // Driven by the real credential probe, not the declaration:
          // stored credentials read "configured", missing ones are named.
          if (s.envHint != null ||
              s.requiredEnvNames.isNotEmpty ||
              s.requiredHeaderNames.isNotEmpty)
            FutureBuilder<List<String>>(
              future: McpService.I.missingCredentialsFor(s),
              builder: (context, snap) {
                final missing = snap.data;
                if (missing == null) return const SizedBox.shrink();
                if (missing.isEmpty) {
                  return _DiagRow('${s.name}: credentials configured ✓');
                }
                return _DiagRow(
                  'Needs setup: ${missing.join(', ')} '
                  'must be configured (secure storage)',
                  warn: true,
                );
              },
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
            if (!owned.any(
                  (s) => s.canonicalId == '${manifest.id}/${d.name}',
                ) &&
                (d.envNames.isNotEmpty || d.headerNames.isNotEmpty))
              _DiagRow(
                'Needs setup: '
                '${[...d.envNames, ...d.headerNames].join(', ')} '
                'must be configured (secure storage)',
                warn: true,
              ),
        const SectionHeader('Hooks'),
        // WHY THE HOOKS ARE NOT FIRING (audit 2026-09-29). Four causes all
        // look identical from the outside — a screen install awaiting restart,
        // a session-scoped install, a missing sandbox, a tripped breaker — and
        // every one of them used to be silent. Say which it is.
        if (HookService.I.hookBlockerFor(runtimeId) case final blocker?)
          _DiagRow('Hooks not running: $blocker', warn: true),
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
        // Per-plugin counters (this plugin's hooks only), not the
        // process-global totals.
        Builder(
          builder: (_) {
            final stats = HookService.I.statsFor(runtimeId);
            if (stats == null) {
              return const _DiagRow(
                'Last result: none of this plugin\'s hooks ran this boot',
              );
            }
            final fired = stats.lastFiredAt;
            return Column(
              key: ValueKey('plugin-hook-stats-$runtimeId'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DiagRow(
                  'Last result: '
                  '${stats.failed > 0 ? 'failures seen this boot' : 'no failures this boot'} '
                  '(fired ${stats.fired}, failed ${stats.failed}'
                  '${stats.blocked > 0 ? ', blocked ${stats.blocked}' : ''}'
                  ' this boot'
                  '${fired == null ? '' : ' · last fired ${usageRelativeTime(fired, now: DateTime.now())}'})',
                  warn: stats.failed > 0,
                ),
                if (stats.lastError case final err?)
                  _DiagRow('Last error: $err', warn: true),
              ],
            );
          },
        ),
        _DiagRow(
          HookService.I.isPluginTrippedAnySession(runtimeId)
              ? 'Circuit breaker: TRIPPED — this plugin\'s hooks are off '
                    'for the affected session; re-enable the plugin to retry'
              : 'Circuit breaker: closed — ${HookService.breakerThreshold} '
                    'consecutive failures in a session turn this plugin\'s '
                    'hooks off (fail-open — the run continues)',
          warn: HookService.I.isPluginTrippedAnySession(runtimeId),
        ),
        const SectionHeader('Usage', subtitle: 'Last 30 days on this device'),
        Builder(
          builder: (_) {
            final u = ToolUsageStore.I.summary(pluginId: runtimeId);
            if (u.isEmpty) {
              return const _DiagRow(
                'No calls to this plugin\'s commands, skills, agents or MCP '
                'tools yet.',
              );
            }
            final top = ToolUsageStore.I
                .toolSummaries(pluginId: runtimeId)
                .entries
                .take(5);
            return Column(
              key: ValueKey('plugin-usage-$runtimeId'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DiagRow(
                  '${u.calls} call${u.calls == 1 ? '' : 's'} · '
                  '${u.errors} failed · p50 ${u.p50Ms} ms · p95 ${u.p95Ms} ms'
                  '${u.lastUsed == null ? '' : ' · last used ${usageRelativeTime(u.lastUsed!)}'}',
                ),
                for (final e in top)
                  _DiagRow(
                    '${e.key}: ${e.value.calls} call'
                    '${e.value.calls == 1 ? '' : 's'}'
                    '${e.value.errors > 0 ? ' (${e.value.errors} failed)' : ''}',
                  ),
              ],
            );
          },
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

/// A plugin-owned MCP server in the plugin's diagnostics: tap to open its
/// detail screen (tools, credentials, usage); inline Set up / Connect runs
/// [connectMcpServer] with its credential and runtime gates.
class _OwnedMcpTile extends StatelessWidget {
  final McpServer server;
  const _OwnedMcpTile({required this.server});

  @override
  Widget build(BuildContext context) {
    final s = server;
    final durable = durableMcpStatus(s);
    final needsSetup = durable?.state == StartupItemState.needsSetup;
    final connecting = mcpConnecting(s);
    return ListTile(
      key: ValueKey('plugin-owned-mcp-${s.canonicalId}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      dense: true,
      leading: Icon(Icons.usb_outlined, size: 18, color: Aether.textMuted),
      title: Text(
        s.name,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${s.transport} · ${mcpDurableStatusText(s)}',
        style: TextStyle(fontSize: 11.5, color: Aether.textMuted),
      ),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => McpDetailScreen(server: s))),
      trailing: s.connected
          ? const Icon(Icons.chevron_right, size: 18)
          : TextButton(
              key: ValueKey('plugin-owned-mcp-connect-${s.canonicalId}'),
              onPressed: connecting ? null : () => connectMcpServer(context, s),
              child: Text(
                connecting
                    ? 'Connecting…'
                    : needsSetup
                    ? 'Set up'
                    : 'Connect',
              ),
            ),
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
    var busy = false;
    String? revokeError;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          scrollable: true,
          title: const Text(
            'Plugin permissions',
            style: TextStyle(fontSize: 15),
          ),
          content: Text(
            revokeError ??
                (grant == null
                    ? 'No grant is currently effective for this plugin. It will '
                          'request approval on the next install or update.'
                    : 'Granted capabilities:\n'
                          '${grant.capabilities.map((c) => c.name).join(', ')}\n\n'
                          '${grant.declinedCapabilities.isEmpty ? '' : 'Declined (disabled by you):\n${grant.declinedCapabilities.map(pluginCapabilityTitle).join(', ')}\n\n'}'
                          '${grant.allowDependencyScripts ? 'Dependency install scripts: allowed\n\n' : ''}'
                          'Approved ${grant.approvedAt.toIso8601String().substring(0, 10)} '
                          'for digest ${_EffectiveGrantRow.digestSnippetForTest(grant.manifestDigest)}…'),
            style: const TextStyle(fontSize: 12.5, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            if (grant != null)
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Aether.danger),
                onPressed: busy
                    ? null
                    : () async {
                        update(() => busy = true);
                        try {
                          await app.revokePluginGrant(plugin);
                          if (ctx.mounted) Navigator.pop(ctx);
                        } catch (_) {
                          if (ctx.mounted) {
                            update(() {
                              busy = false;
                              revokeError =
                                  'Plugin disabled. Could not save revocation. Retry to finish removing permissions.';
                            });
                          }
                        }
                      },
                child: Text(
                  revokeError == null ? 'Revoke permissions' : 'Retry',
                ),
              ),
          ],
        ),
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
                      : 'Granted: ${g.capabilities.map((c) => c.name).join(', ')}'
                            '${g.declinedCapabilities.isEmpty ? '' : '\nDisabled by you: ${g.declinedCapabilities.map(pluginCapabilityTitle).join(', ')}'}',
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
          Icon(
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
  final List<McpServer> servers;

  /// All configured servers, before search filtering.
  final int totalServers;
  final String? focusCanonicalId;
  final Map<String, GlobalKey>? cardKeys;
  const _McpSection({
    required this.servers,
    required this.totalServers,
    this.focusCanonicalId,
    this.cardKeys,
  });

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
              const SizedBox(width: 8),
              Tag('LIVE', color: Aether.accent, filled: true),
            ],
          ),
        ),
        // The single "+" opens the add sheet; an empty list offers its MCP
        // tab directly, a filtered-out list says nothing matched.
        if (servers.isEmpty && totalServers > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Text(
              'No MCP servers match your search.',
              key: const ValueKey('mcp-section-no-match'),
              style: TextStyle(fontSize: 12, color: Aether.textMuted),
            ),
          )
        else if (servers.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  'No MCP servers yet — add one by command, URL or JSON.',
                  style: TextStyle(fontSize: 12, color: Aether.textMuted),
                ),
                TextButton.icon(
                  key: const ValueKey('mcp-section-add'),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add MCP server'),
                  onPressed: () =>
                      showPluginAddSheet(context, initialTab: PluginAddTab.mcp),
                ),
              ],
            ),
          )
        else
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                for (final s in servers) McpCard(
                  key: cardKeys?.putIfAbsent(s.canonicalId, () => GlobalKey()),
                  server: s,
                  highlighted: s.canonicalId == focusCanonicalId,
                ),
                ],
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
List<
  ({
    String name,
    String command,
    List<String> args,
    Map<String, String> env,
    String? url,
    Map<String, String> headers,
    String type,
    String? cwd,
    List<String> ignoredKeys,
  })
>
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

/// Test seam: overrides the sandbox gate in [connectMcpServer] so widget
/// tests can exercise the credential/runtime sheets without a sandbox.
/// Null in production.
@visibleForTesting
String? Function(McpServer server)? mcpSupportGateForTest;

/// Connect an MCP server, asking for required credentials first.
///
/// Disconnects are instant. A connect with missing credentials opens the
/// credential sheet (GitHub login for GitHub-native servers, secure token
/// fields otherwise) and only then connects — it never silently flips to a
/// needsSetup label.
Future<void> connectMcpServer(BuildContext context, McpServer server) async {
  final app = AppState.I;
  if (server.connected) {
    await app.toggleMcpServer(server);
    return;
  }
  // Sandbox gate first: stdio servers spawn inside it — attempting the
  // connect without it burns the handshake budget and records a timeout.
  // A set test seam fully replaces the gate (including with null).
  final gate = mcpSupportGateForTest;
  final unsupported = gate != null
      ? gate(server)
      : mcpUnsupportedReason(server);
  if (unsupported != null) {
    if (!context.mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: Aether.surface,
        title: const Text('Sandbox needed', style: TextStyle(fontSize: 15.5)),
        content: Text(
          '${server.name} runs inside the on-device sandbox, which is not '
          'installed yet. Install it from Studio first (one-time setup), '
          'then connect.',
          style: TextStyle(fontSize: 13, color: Aether.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Open Studio'),
          ),
        ],
      ),
    );
    if (go == true && context.mounted) openStudio(context);
    return;
  }
  final split = await McpService.I.missingCredentialsSplitFor(server);
  final missing = [...split.env, ...split.headers];
  if (!context.mounted) return;
  if (mcpCredentialAskForTest(missing: missing) !=
      McpCredentialAsk.connectDirectly) {
    final res = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Aether.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
        ),
        child: _McpCredentialSheet(
          server: server,
          missingEnv: split.env,
          missingHeaders: split.headers,
        ),
      ),
    );
    if (!context.mounted) return;
    if (res == 'github-login') {
      showGithubLoginSheet(
        context,
        onConnected: () => AppState.I.toggleMcpServer(server),
      );
      return;
    }
    if (res != 'connected') return;
  }
  // Runtime gate AFTER credentials: installing node/python takes minutes,
  // so offer it explicitly instead of burning the handshake budget and
  // recording a timeout failure.
  final needRuntime = await McpService.I.missingRuntimeFor(server);
  if (!context.mounted) return;
  if (needRuntime != null) {
    final installed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Aether.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
        ),
        child: _McpRuntimeInstallSheet(server: server, kind: needRuntime),
      ),
    );
    if (installed != true || !context.mounted) return;
  }
  // Await the real outcome and say what happened — the switch flipping back
  // silently on failure was the only signal before.
  final messenger = ScaffoldMessenger.maybeOf(context);
  final outcome = await app.toggleMcpServer(server);
  // A remote server that answered 401 gets a direct "Sign in" (F-193),
  // whether or not it ships a hand-written oauth block.
  final needsSignIn =
      !outcome.ok && McpService.I.mcpNeedsOAuthSignIn(server.canonicalId);
  _showMcpConnectOutcome(
    messenger,
    server,
    outcome.ok,
    outcome.detail,
    onSignIn: needsSignIn
        ? () {
            if (context.mounted) unawaited(signInToMcpServer(context, server));
          }
        : null,
  );
}

/// User-facing copy for a finished connect: "Connected · 12 tools",
/// "Needs sign-in", "Timed out", … with the raw detail only as a suffix.
@visibleForTesting
String mcpConnectOutcomeMessage(McpServer server, bool ok, String? detail) {
  if (ok) {
    final n = McpService.I.connectedTools[server.canonicalId]?.length;
    if (n == null) return '${server.name}: Connected';
    return '${server.name}: Connected · $n tool${n == 1 ? '' : 's'}';
  }
  final d = (detail ?? '').trim();
  final lower = d.toLowerCase();
  if (lower.contains('timed out') || lower.contains('timeout')) {
    return '${server.name}: Timed out while connecting';
  }
  if (lower.contains('401') ||
      lower.contains('unauthorized') ||
      lower.contains('sign in') ||
      lower.contains('log in')) {
    return '${server.name}: Needs sign-in';
  }
  if (lower.contains('needs configuration')) {
    return '${server.name}: Needs setup — add its credentials';
  }
  if (lower.contains('needs runtime')) {
    return '${server.name}: Needs a runtime — install it, then retry';
  }
  if (d.isEmpty) return "${server.name}: Couldn't connect";
  final short = d.length > 140 ? '${d.substring(0, 140)}…' : d;
  return "${server.name}: Couldn't connect · $short";
}

void _showMcpConnectOutcome(
  ScaffoldMessengerState? messenger,
  McpServer server,
  bool ok,
  String? detail, {
  VoidCallback? onSignIn,
}) {
  if (messenger == null || !messenger.mounted) return;
  final lower = (detail ?? '').toLowerCase();
  // Setup/runtime failures need the credential or runtime sheet, not a
  // blind reconnect — Retry is offered only for transient failures.
  final retryable =
      !ok &&
      !lower.contains('needs configuration') &&
      !lower.contains('needs runtime');
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(mcpConnectOutcomeMessage(server, ok, detail)),
      behavior: SnackBarBehavior.floating,
      action: onSignIn != null
          ? SnackBarAction(label: 'Sign in', onPressed: onSignIn)
          : !retryable
          ? null
          : SnackBarAction(
              label: 'Retry',
              onPressed: () async {
                if (server.connected) return;
                final again = await AppState.I.toggleMcpServer(server);
                _showMcpConnectOutcome(
                  messenger,
                  server,
                  again.ok,
                  again.detail,
                );
              },
            ),
    ),
  );
}

/// True while [server]'s connect attempt is in flight (busy UI state).
bool mcpConnecting(McpServer server) =>
    AppState.I.serviceStatus['mcp:${server.canonicalId}']?.health ==
    ServiceHealth.connecting;

/// Credential sheet for an MCP server with missing credentials: secure
/// token fields, plus the GitHub login as the first-class path for
/// GitHub-native servers. Pops with 'connected' (saved → caller connects)
/// or 'github-login' (caller opens the GitHub login sheet).
class _McpCredentialSheet extends StatefulWidget {
  final McpServer server;

  /// Missing env var names — saved through [AppState.setMcpEnv].
  final List<String> missingEnv;

  /// Missing HTTP header names (e.g. `Authorization`) — saved through
  /// [AppState.setMcpHeaders], the only store the HTTP transport reads.
  final List<String> missingHeaders;
  /// Edit mode (detail screen "Edit"/"Set"): blank fields keep the stored
  /// value, the sheet pops 'saved' and never connects.
  final bool editing;
  const _McpCredentialSheet({
    required this.server,
    this.missingEnv = const [],
    this.missingHeaders = const [],
    this.editing = false,
  });

  List<String> get missing => [...missingEnv, ...missingHeaders];

  @override
  State<_McpCredentialSheet> createState() => _McpCredentialSheetState();
}

class _McpCredentialSheetState extends State<_McpCredentialSheet> {
  late final Map<String, TextEditingController> _envControllers;
  late final Map<String, TextEditingController> _headerControllers;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _envControllers = {
      for (final k in widget.missingEnv) k: TextEditingController(),
    };
    _headerControllers = {
      for (final k in widget.missingHeaders) k: TextEditingController(),
    };
  }

  @override
  void dispose() {
    for (final c in [..._envControllers.values, ..._headerControllers.values]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Collects trimmed values; null (with [_error] set) when one is empty.
  Map<String, String>? _collect(Map<String, TextEditingController> ctrls) {
    final values = <String, String>{};
    for (final e in ctrls.entries) {
      final v = e.value.text.trim();
      if (v.isEmpty && widget.editing) continue;
      if (v.isEmpty) {
        setState(() => _error = '${e.key} is required.');
        return null;
      }
      values[e.key] = v;
    }
    return values;
  }

  Future<void> _save() async {
    final env = _collect(_envControllers);
    if (env == null) return;
    final headers = _collect(_headerControllers);
    if (headers == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // Merged into what is already stored, strict (a storage failure must
      // not pop "connected"), env and headers each to their own store.
      await AppState.I.saveMcpCredentials(
        widget.server,
        env: env,
        headers: headers,
      );
    } catch (e) {
      Diag.swallow('mcp-credentials', e);
      // Reset the spinner and surface the failure instead of stranding
      // the sheet on a disabled Save button.
      if (mounted) {
        setState(() {
          _saving = false;
          _error = "Couldn't save to secure storage. Try again.";
        });
      }
      return;
    }
    if (!mounted) return;
    Navigator.pop(context, widget.editing ? 'saved' : 'connected');
  }

  Widget _field(String name, TextEditingController controller, {
    required bool header,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(header ? '$name (HTTP header)' : name, style: AetherType.label),
        const SizedBox(height: 6),
        TextField(
          key: ValueKey('mcp-cred-${header ? 'header' : 'env'}-$name'),
          controller: controller,
          enabled: !_saving,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            labelText: name,
            helperText: header ? 'Sent as an HTTP header' : null,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final offerGithub =
        !widget.editing &&
        mcpOffersGithubLoginForTest(widget.server) &&
        !GitHubService.I.isLoggedIn;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.editing
                  ? 'Update ${widget.server.name} credentials'
                  : 'Connect ${widget.server.name}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              widget.editing
                  ? 'Enter a new value to replace the stored one; leave a '
                        'field blank to keep it. Secrets stay in secure '
                        'storage on this device.'
                  : '${widget.server.name} needs ${widget.missing.join(', ')} '
                        'before it can connect. Secrets stay in secure '
                        'storage on this device.',
              style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
            ),
            if (offerGithub) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Aether.accent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.login, size: 16),
                label: Text(
                  GitHubService.I.login == null
                      ? 'Connect GitHub account'
                      : 'Connect as ${GitHubService.I.login}',
                  style: const TextStyle(fontSize: 13.5),
                ),
                onPressed: () => Navigator.pop(context, 'github-login'),
              ),
              const SizedBox(height: 8),
              Text(
                'or paste a token manually:',
                style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
              ),
            ],
            const SizedBox(height: 10),
            for (final e in _envControllers.entries)
              _field(e.key, e.value, header: false),
            for (final e in _headerControllers.entries)
              _field(e.key, e.value, header: true),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: Aether.danger),
                ),
              ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _saving ? Aether.surfaceRaised : Aether.accent,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _saving
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    )
                  : const Icon(Icons.key_outlined, size: 16),
              label: Text(
                _saving
                    ? 'Saving…'
                    : widget.editing
                    ? 'Save'
                    : 'Save & connect',
                style: const TextStyle(fontSize: 13.5),
              ),
              onPressed: _saving ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}

/// Runtime-install sheet for a stdio MCP server whose language runtime
/// (Node.js/Python) is missing. Installs just that runtime with live log
/// lines, then pops true so the caller connects. Pops false/null on
/// cancel or failure — the server row is never flipped optimistically.
class _McpRuntimeInstallSheet extends StatefulWidget {
  final McpServer server;
  final String kind;
  const _McpRuntimeInstallSheet({required this.server, required this.kind});

  @override
  State<_McpRuntimeInstallSheet> createState() =>
      _McpRuntimeInstallSheetState();
}

class _McpRuntimeInstallSheetState extends State<_McpRuntimeInstallSheet> {
  bool _installing = false;
  bool _done = false;
  bool _ok = false;
  final List<String> _log = [];

  String get _label => widget.kind == 'node' ? 'Node.js' : 'Python';

  Future<void> _install() async {
    setState(() {
      _installing = true;
    });
    // Explicit user-tapped runtime install (not a silent one): streams
    // the installer's lines into the follow-mode log below.
    var ok = false;
    try {
      ok = await SandboxService.I.ensureRuntime(
      widget.kind,
      onLine: (line) {
        if (!mounted) return;
        setState(() {
          _log.add(line);
        });
      },
      );
    } catch (e) {
      if (mounted) _log.add('Runtime installation failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _installing = false;
      _done = true;
      _ok = ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.server.name} needs $_label',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'This server runs on $_label, which is not installed in the '
              'on-device sandbox yet. Install it once (one-time download), '
              'then the server connects.',
              style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
            ),
            if (_log.isNotEmpty) ...[
              const SizedBox(height: 10),
              // WS2: follow-mode auto-scroll (ScrollController +
              // jump-to-bottom when near the bottom) replaces the old
              // static 30-line Text — the user always sees the latest
              // installer output and real errors.
              ProgressLogView(lines: List.of(_log), height: 180),
            ],
            const SizedBox(height: 12),
            if (!_done)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _installing
                      ? Aether.surfaceRaised
                      : Aether.accent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: _installing
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      )
                    : const Icon(Icons.download_outlined, size: 16),
                label: Text(
                  _installing ? 'Installing…' : 'Install $_label runtime',
                  style: const TextStyle(fontSize: 13.5),
                ),
                onPressed: _installing ? null : _install,
              )
            else
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _ok ? Aether.accent : Aether.surfaceRaised,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: Icon(_ok ? Icons.check : Icons.close, size: 16),
                label: Text(
                  _ok ? 'Connect server' : 'Close',
                  style: const TextStyle(fontSize: 13.5),
                ),
                onPressed: () => Navigator.pop(context, _ok),
              ),
          ],
        ),
      ),
    );
  }
}

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
      // No long-press removal: deleting kills the process and wipes env,
      // headers and OAuth, so it only runs from the confirmed trash icon.
      child: Container(
        key: ValueKey('mcp-card-${server.canonicalId}'),
        width: MediaQuery.sizeOf(context).width < 600
            ? MediaQuery.sizeOf(context).width - 32
            : 300,
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
                  return Aether.danger.withValues(alpha: 0.45);
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
          mainAxisSize: MainAxisSize.min,
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
                SizedBox(
                  height: 48,
                  child: Switch(
                    key: ValueKey('mcp-switch-${server.canonicalId}'),
                    value: server.connected,
                    activeTrackColor: Aether.accent,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    // Busy while a connect is in flight (no double toggle).
                    onChanged: mcpConnecting(server)
                        ? null
                        : (_) => connectMcpServer(context, server),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: ValueKey('mcp-delete-${server.canonicalId}'),
                  icon: Icon(
                    Icons.delete_outline,
                    size: 16,
                    color: Aether.danger,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  tooltip: 'Delete server',
                  onPressed: () async {
                    final ok = await showDeleteConfirmationDialog(
                      context,
                      title: 'Delete ${server.name}?',
                    );
                    if (!ok) return;
                    await AppState.I.removeMcpServer(server);
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    server.name,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Builder(
                  builder: (_) {
                    final durable = durableMcpStatus(server);
                    if (durable != null) return durableStatusIcon(durable);
                    // No record: neutral, never inferred from serviceStatus
                    // or connected (spec §5.3, Task 3).
                    return Icon(
                      Icons.help_outline,
                      size: 14,
                      color: Aether.textFaint,
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 2),
            Builder(
              builder: (_) {
                final durable = durableMcpStatus(server);
                if (durable != null) {
                  final label = startupItemStateLabel(durable.state);
                  final reason = durable.reason;
                  return Text(
                    reason == null || reason.isEmpty
                        ? label
                        : '$label · $reason',
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
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Production [McpOAuthService] seam: delegates to [McpService.I] without
/// changing its attempt, PKCE, or persistence behavior.
class _LiveMcpOAuthService implements McpOAuthService {
  const _LiveMcpOAuthService();

  @override
  Future<String> beginAuthorization(String serverKey) async =>
      (await McpService.I.beginMcpOAuthAuthorization(
        serverKey,
      )).authorizationUrl;

  @override
  Future<void> completeAuthorization(String serverKey, String callbackUri) =>
      McpService.I.completeMcpOAuthAuthorization(serverKey, callbackUri);

  @override
  void cancelAuthorization(String serverKey) =>
      McpService.I.cancelMcpOAuthAuthorization(serverKey);

  @override
  Future<DateTime?> attemptExpiry(String serverKey) =>
      McpService.I.mcpOAuthAttemptExpiry(serverKey);
}

/// Test seam: replaces the production OAuth service used by the detail
/// screen's Sign in / Re-authenticate buttons.
@visibleForTesting
McpOAuthService? mcpOAuthServiceForTest;

/// Test seam: replaces [connectMcpServer] after a successful sign-in.
@visibleForTesting
Future<void> Function(BuildContext context, McpServer server)?
mcpConnectAfterSignInForTest;

/// Open the MCP sign-in sheet for [server] and act on the result (F-196):
/// on success say so, (re)connect the server so the new token is used, and
/// return true. A cancel returns false without touching the connection.
Future<bool> signInToMcpServer(BuildContext context, McpServer server) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final ok = await showMcpOAuthSheet(
    context,
    serverKey: server.canonicalId,
    serverName: server.name,
    service: mcpOAuthServiceForTest ?? const _LiveMcpOAuthService(),
  );
  if (ok != true) return false;
  if (messenger != null && messenger.mounted) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Signed in to ${server.name}'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  if (!context.mounted) return true;
  final connect = mcpConnectAfterSignInForTest ?? connectMcpServer;
  if (server.connected) {
    // Reconnect so the session is re-established with the new token.
    await AppState.I.toggleMcpServer(server);
    if (!context.mounted) return true;
  }
  await connect(context, server);
  return true;
}

/// "Signed in · expires in 52 min" for a stored token.
@visibleForTesting
String mcpOAuthTokenStatus(McpOAuthToken token, {DateTime? now}) {
  final at = token.expiresAt;
  if (at == null) return 'Signed in';
  final left = at.difference(now ?? DateTime.now());
  if (left.isNegative) {
    return token.canRefresh
        ? 'Signed in · token refreshes on next use'
        : 'Sign-in expired';
  }
  final text = left.inDays >= 1
      ? '${left.inDays} d'
      : left.inHours >= 1
      ? '${left.inHours} h'
      : '${left.inMinutes.clamp(1, 59)} min';
  return 'Signed in · expires in $text';
}

/// MCP detail — connect/disconnect with config preview.
class McpDetailScreen extends StatefulWidget {
  final McpServer server;
  const McpDetailScreen({super.key, required this.server});

  @override
  State<McpDetailScreen> createState() => _McpDetailScreenState();
}

/// Credential snapshot for the MCP detail screen: what the server still
/// needs (per store) and which names are stored (values never loaded into
/// the UI).
class _McpCredState {
  final List<String> missingEnv;
  final List<String> missingHeaders;
  final List<String> storedEnv;
  final List<String> storedHeaders;
  const _McpCredState({
    required this.missingEnv,
    required this.missingHeaders,
    required this.storedEnv,
    required this.storedHeaders,
  });

  bool get isEmpty =>
      missingEnv.isEmpty &&
      missingHeaders.isEmpty &&
      storedEnv.isEmpty &&
      storedHeaders.isEmpty;
}

/// OAuth snapshot for the detail screen's sign-in row.
class _McpAuthState {
  final McpOAuthConfig? config;
  final McpOAuthToken? token;
  const _McpAuthState(this.config, this.token);
}

class _McpDetailScreenState extends State<McpDetailScreen> {
  late Future<_McpCredState> _credFuture;
  late Future<_McpAuthState> _authFuture;

  @override
  void initState() {
    super.initState();
    _credFuture = _loadCreds();
    _authFuture = _loadAuth();
  }

  Future<_McpAuthState> _loadAuth() async {
    final key = widget.server.canonicalId;
    return _McpAuthState(
      await McpService.I.mcpOAuthConfigForAsync(key),
      await McpService.I.mcpOAuthTokenFor(key),
    );
  }

  void _reloadAuth() {
    if (!mounted) return;
    final next = _loadAuth();
    setState(() {
      _authFuture = next;
    });
  }

  /// Sign-in row for remote servers (F-193/F-196): shown when the server
  /// answered 401, ships an oauth block, or already holds a token. Offers
  /// Sign in, or Re-authenticate + Sign out with the token's expiry.
  Widget _authSection(BuildContext context, McpServer s) {
    if (s.transport != 'http' && s.transport != 'sse') {
      return const SizedBox.shrink();
    }
    return FutureBuilder<_McpAuthState>(
      future: _authFuture,
      builder: (context, snap) {
        final auth = snap.data;
        final needsSignIn = McpService.I.mcpNeedsOAuthSignIn(s.canonicalId);
        final token = auth?.token;
        final hasConfig = auth?.config?.isUsable ?? false;
        if (token == null && !needsSignIn && !hasConfig) {
          return const SizedBox.shrink();
        }
        final status = token != null
            ? mcpOAuthTokenStatus(token)
            : needsSignIn
            ? 'Sign-in required — the server rejected the connection'
            : 'Not signed in';
        Future<void> signIn() async {
          final ok = await signInToMcpServer(context, s);
          if (ok) {
            _reloadAuth();
            _reloadCreds();
          }
        }

        return Container(
          key: ValueKey('mcp-auth-${s.canonicalId}'),
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Aether.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Aether.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    token != null
                        ? Icons.verified_user_outlined
                        : Icons.lock_outline,
                    size: 15,
                    color: token != null
                        ? Aether.successLight
                        : Aether.textMuted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      status,
                      key: ValueKey('mcp-auth-status-${s.canonicalId}'),
                      style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      key: ValueKey('mcp-auth-sign-in-${s.canonicalId}'),
                      style: FilledButton.styleFrom(
                        backgroundColor: token == null
                            ? Aether.accent
                            : Aether.surfaceRaised,
                      ),
                      icon: Icon(
                        token == null ? Icons.login : Icons.refresh,
                        size: 16,
                      ),
                      label: Text(
                        token == null ? 'Sign in' : 'Re-authenticate',
                        style: const TextStyle(fontSize: 13),
                      ),
                      onPressed: signIn,
                    ),
                  ),
                  if (token != null) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: ValueKey('mcp-auth-sign-out-${s.canonicalId}'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Aether.textMuted,
                          side: BorderSide(color: Aether.hairlineStrong),
                        ),
                        icon: const Icon(Icons.logout, size: 16),
                        label: const Text(
                          'Sign out',
                          style: TextStyle(fontSize: 13),
                        ),
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          if (s.connected) {
                            await AppState.I.toggleMcpServer(s);
                          }
                          await McpService.I.clearMcpOAuthToken(
                            s.canonicalId,
                          );
                          _reloadAuth();
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text('Signed out of ${s.name}'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void didUpdateWidget(McpDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.server, widget.server)) {
      _credFuture = _loadCreds();
      _authFuture = _loadAuth();
      _catalog = null;
      _catalogConnected = false;
    }
  }

  Future<_McpCredState> _loadCreds() async {
    final s = widget.server;
    final split = await McpService.I.missingCredentialsSplitFor(s);
    final env = await AppState.I.getMcpEnv(s.canonicalId);
    final headers = await AppState.I.getMcpHeaders(s.canonicalId);
    return _McpCredState(
      missingEnv: split.env,
      missingHeaders: split.headers,
      storedEnv: env.keys.toList(),
      storedHeaders: {...headers.keys, ...s.headers.keys}.toList(),
    );
  }

  void _reloadCreds() {
    if (!mounted) return;
    final next = _loadCreds();
    final auth = _loadAuth();
    setState(() {
      _credFuture = next;
      _authFuture = auth;
    });
  }

  static bool _declaresCredentials(McpServer s) =>
      s.requiredEnvNames.isNotEmpty ||
      s.requiredHeaderNames.isNotEmpty ||
      (s.envHint ?? '').trim().isNotEmpty;

  /// Opens the credential sheet in edit mode for [env]/[headers] names;
  /// blank fields keep the stored value.
  Future<void> _editCredentials(
    BuildContext context,
    McpServer s, {
    List<String> env = const [],
    List<String> headers = const [],
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final res = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Aether.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
        ),
        child: _McpCredentialSheet(
          server: s,
          missingEnv: env,
          missingHeaders: headers,
          editing: true,
        ),
      ),
    );
    _reloadCreds();
    if (res == 'saved') {
      messenger.showSnackBar(
        SnackBar(content: Text('${s.name} credentials saved')),
      );
    }
  }

  Widget _needsSetupBanner(
    BuildContext context,
    McpServer s,
    List<String> missing,
  ) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Aether.warnLight.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.key_outlined, size: 15, color: Aether.warnLight),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Needs setup: ${missing.join(', ')} must be configured '
                  '(secure storage) before this server can connect. '
                  'It will not start automatically.',
                  style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Aether.accent,
              padding: const EdgeInsets.symmetric(vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.key_outlined, size: 15),
            label: const Text(
              'Set up & connect',
              style: TextStyle(fontSize: 12.5),
            ),
            onPressed: mcpConnecting(s)
                ? null
                : () async {
                    await connectMcpServer(context, s);
                    _reloadCreds();
                  },
          ),
        ],
      ),
    ),
  );

  Widget _configuredRow(
    BuildContext context,
    McpServer s,
    _McpCredState creds,
  ) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Container(
      key: ValueKey('mcp-credentials-configured-${s.canonicalId}'),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: Aether.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Aether.hairline),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 15, color: Aether.successLight),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Credentials configured',
              style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
            ),
          ),
          TextButton(
            onPressed: () => _editCredentials(
              context,
              s,
              env: creds.storedEnv,
              headers: creds.storedHeaders,
            ),
            child: const Text('Edit'),
          ),
        ],
      ),
    ),
  );

  /// "Environment & headers": stored names with masked values (Edit /
  /// Delete) and declared-but-missing names (Set).
  Widget _credentialsSection(
    BuildContext context,
    McpServer s,
    _McpCredState creds,
  ) {
    Widget row(String name, {required bool header, required bool stored}) {
      return Padding(
        key: ValueKey('mcp-cred-row-${header ? 'header' : 'env'}-$name'),
        padding: const EdgeInsets.only(bottom: 6),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 2, 2, 2),
          decoration: BoxDecoration(
            color: Aether.surfaceAlt,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Aether.hairline),
          ),
          child: Row(
            children: [
              Icon(
                header ? Icons.http : Icons.key_outlined,
                size: 15,
                color: stored ? Aether.textMuted : Aether.warnLight,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      header ? '$name · HTTP header' : name,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontFamily: Aether.mono,
                      ),
                    ),
                    Text(
                      stored ? '••••••••' : 'Not set',
                      style: TextStyle(fontSize: 11, color: Aether.textFaint),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: stored ? 'Edit $name' : 'Set $name',
                icon: Icon(
                  stored ? Icons.edit_outlined : Icons.add,
                  size: 17,
                ),
                onPressed: () => _editCredentials(
                  context,
                  s,
                  env: header ? const [] : [name],
                  headers: header ? [name] : const [],
                ),
              ),
              if (stored)
                IconButton(
                  tooltip: 'Delete $name',
                  icon: Icon(
                    Icons.delete_outline,
                    size: 17,
                    color: Aether.danger,
                  ),
                  onPressed: () async {
                    final ok = await showDeleteConfirmationDialog(
                      context,
                      title: 'Delete $name?',
                      content:
                          'Removes the stored value from this device. '
                          '${s.name} may stop working until it is set again.',
                    );
                    if (!ok || !context.mounted) return;
                    final messenger = ScaffoldMessenger.of(context);
                    try {
                      await AppState.I.deleteMcpCredential(
                        s,
                        name,
                        header: header,
                      );
                    } catch (e) {
                      Diag.swallow('mcp-credentials', e);
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text(
                            "Couldn't update secure storage. Try again.",
                          ),
                        ),
                      );
                    }
                    _reloadCreds();
                  },
                ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          'Environment & headers',
          subtitle: 'Stored in secure storage on this device',
        ),
        for (final n in creds.storedEnv) row(n, header: false, stored: true),
        for (final n in creds.missingEnv)
          if (!creds.storedEnv.contains(n)) row(n, header: false, stored: false),
        for (final n in creds.storedHeaders) row(n, header: true, stored: true),
        for (final n in creds.missingHeaders)
          if (!creds.storedHeaders.contains(n))
            row(n, header: true, stored: false),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Listen to AppState: the connect outcome lands asynchronously, so the
    // real ready/failed state must repaint without leaving the screen.
    // ToolUsageStore: the usage block updates as calls finish.
    return AnimatedBuilder(
      animation: Listenable.merge([AppState.I, ToolUsageStore.I]),
      builder: (context, _) => _buildDetail(context),
    );
  }

  Future<_McpCatalog>? _catalog;
  bool _catalogConnected = false;

  /// Resources/prompts, loaded once per connection (cached, not per build).
  Future<_McpCatalog>? _catalogFor(McpServer s) {
    final connected = McpService.I.isConnected(s.canonicalId);
    if (connected != _catalogConnected) {
      _catalogConnected = connected;
      _catalog = connected ? _loadCatalog(s) : null;
    }
    return _catalog;
  }

  void _reloadCatalog(McpServer s) {
    setState(() {
      _catalog = McpService.I.isConnected(s.canonicalId)
          ? _loadCatalog(s, refresh: true)
          : null;
    });
  }

  static Future<_McpCatalog> _loadCatalog(
    McpServer s, {
    bool refresh = false,
  }) async {
    final caps = McpService.I.capabilitiesFor(s.canonicalId);
    Future<({List<Map<String, dynamic>>? items, String? error})> load(
      String capability,
      Future<List<Map<String, dynamic>>> Function() fetch,
    ) async {
      if (caps[capability] is! Map) return (items: null, error: null);
      try {
        return (items: await fetch(), error: null);
      } catch (e) {
        Diag.swallow('mcp-catalog', e);
        return (items: null, error: "Couldn't load $capability.");
      }
    }

    final resources = await load(
      'resources',
      () => McpService.I.listResources(s.canonicalId, refresh: refresh),
    );
    final prompts = await load(
      'prompts',
      () => McpService.I.listPrompts(s.canonicalId, refresh: refresh),
    );
    return _McpCatalog(
      resources: resources.items,
      resourcesError: resources.error,
      prompts: prompts.items,
      promptsError: prompts.error,
    );
  }

  /// "Tools (N)": each advertised tool with its description, usage and an
  /// input-schema preview (Claude Code `/mcp` per-server tool listing).
  Widget _toolsSection(McpServer s) {
    final tools = McpService.I.connectedTools[s.canonicalId];
    final usage = ToolUsageStore.I.toolSummaries(mcpServerId: s.canonicalId);
    if (tools == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
        child: Text(
          'Connect the server to list its tools.',
          key: ValueKey('mcp-tools-disconnected-${s.canonicalId}'),
          style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
        ),
      );
    }
    return Padding(
      key: ValueKey('mcp-tools-${s.canonicalId}'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: Aether.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Aether.hairline),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: tools.length <= 8,
            title: Text(
              'Tools (${tools.length})',
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              'What the model can call on this server',
              style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
            ),
            children: [
              if (tools.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'This server advertises no tools.',
                    style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                  ),
                ),
              for (final t in tools)
                ExpansionTile(
                  key: ValueKey('mcp-tool-${t.name}'),
                  dense: true,
                  title: Text(
                    t.name,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontFamily: Aether.mono,
                    ),
                  ),
                  subtitle: Text(
                    [
                      if ((t.description ?? '').trim().isNotEmpty)
                        t.description!.trim(),
                      if (usage[t.name] case final u? when !u.isEmpty)
                        '${u.calls} call${u.calls == 1 ? '' : 's'}'
                            '${u.errors > 0 ? ' · ${u.errors} failed' : ''}',
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: Aether.textMuted),
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if ((t.description ?? '').trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: SelectableText(
                          t.description!.trim(),
                          style: TextStyle(fontSize: 12.5, color: Aether.text),
                        ),
                      ),
                    Text(
                      'Input schema',
                      style: TextStyle(fontSize: 11, color: Aether.textFaint),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Aether.codeBg,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: SelectableText(
                        mcpSchemaPreview(t.inputSchema),
                        style: TextStyle(
                          fontFamily: Aether.mono,
                          fontSize: 11,
                          height: 1.45,
                          color: Aether.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _catalogSection(McpServer s) {
    final future = _catalogFor(s);
    if (future == null) return const SizedBox.shrink();
    return FutureBuilder<_McpCatalog>(
      future: future,
      builder: (context, snap) {
        final c = snap.data;
        if (c == null) return const SizedBox.shrink();
        Widget list(
          String title,
          List<Map<String, dynamic>>? items,
          String? error,
          String Function(Map<String, dynamic>) label,
        ) {
          if (items == null && error == null) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionHeader(items == null ? title : '$title (${items.length})'),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          error,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Aether.warnLight,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => _reloadCatalog(s),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                )
              else if (items!.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'None advertised.',
                    style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
                  ),
                )
              else
                for (final item in items.take(50))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                    child: Text(
                      label(item),
                      style: TextStyle(fontSize: 12.5, color: Aether.text),
                    ),
                  ),
            ],
          );
        }

        String describe(Map<String, dynamic> m, String id) {
          final name = '${m[id] ?? m['name'] ?? ''}';
          final d = '${m['description'] ?? ''}'.trim();
          return d.isEmpty ? name : '$name — $d';
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            list(
              'Resources',
              c.resources,
              c.resourcesError,
              (m) => describe(m, 'uri'),
            ),
            list(
              'Prompts',
              c.prompts,
              c.promptsError,
              (m) => describe(m, 'name'),
            ),
          ],
        );
      },
    );
  }

  /// Last error: the durable failure reason, else the live status detail,
  /// plus the server's recent stderr for stdio servers.
  Widget _lastErrorSection(McpServer s) {
    final durable = durableMcpStatus(s);
    final failing =
        durable != null &&
        (durable.state == StartupItemState.failed ||
            durable.state == StartupItemState.degraded ||
            durable.state == StartupItemState.unsupported ||
            durable.state == StartupItemState.needsSetup);
    final live = AppState.I.serviceStatus['mcp:${s.canonicalId}'];
    final reason = failing && (durable.reason ?? '').isNotEmpty
        ? durable.reason!
        : live?.health == ServiceHealth.failed
        ? (live?.detail ?? '')
        : '';
    final usageErr = ToolUsageStore.I.summary(mcpServerId: s.canonicalId);
    final stderr = McpService.I.stderrTail(s.canonicalId, lines: 8);
    if (reason.isEmpty && usageErr.lastError == null && stderr.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      key: ValueKey('mcp-last-error-${s.canonicalId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Last error'),
        if (reason.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: SelectableText(
              'Connection: $reason',
              style: TextStyle(fontSize: 12.5, color: Aether.dangerC),
            ),
          ),
        if (usageErr.lastError case final err?)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: SelectableText(
              'Last failed call'
              '${usageErr.lastErrorAt == null ? '' : ' (${usageRelativeTime(usageErr.lastErrorAt!)})'}'
              ': $err',
              style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
            ),
          ),
        if (stderr.isNotEmpty)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Aether.codeBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              stderr.join('\n'),
              style: TextStyle(
                fontFamily: Aether.mono,
                fontSize: 11,
                color: Aether.textMuted,
              ),
            ),
          ),
      ],
    );
  }

  /// Usage: calls, failures, latency and last use over 30 days, from the
  /// per-server aggregation McpService.callTool feeds.
  Widget _usageSection(McpServer s) {
    final u = ToolUsageStore.I.summary(mcpServerId: s.canonicalId);
    return Column(
      key: ValueKey('mcp-usage-${s.canonicalId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Usage', subtitle: 'Last 30 days on this device'),
        if (u.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'No tool calls yet.',
              style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _runRow('Calls', '${u.calls}'),
                const SizedBox(height: 6),
                _runRow(
                  'Failures',
                  '${u.errors} (${(u.errors * 100 / u.calls).round()}%)',
                ),
                const SizedBox(height: 6),
                _runRow(
                  'Latency',
                  'p50 ${u.p50Ms} ms · p95 ${u.p95Ms} ms · avg ${u.avgMs} ms',
                ),
                if (u.lastUsed != null) ...[
                  const SizedBox(height: 6),
                  _runRow('Last used', usageRelativeTime(u.lastUsed!)),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDetail(BuildContext context) {
    final s = widget.server;
    final connecting = mcpConnecting(s);
    final app = AppState.I;
    // Read-only display: inline credentials in args/url are scrubbed (M4).
    // The editor (below) still round-trips the real values.
    final configJson = _configJsonFor(s, scrubbed: true);

    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(s.name),
        actions: [
          // Pencil — edit the mcp.json config in place (user request).
          // Only user-added servers: plugin-owned rows are managed by their
          // manifest and built-in seeds would not persist the edit.
          if (mcpConfigEditable(s))
            IconButton(
              tooltip: 'Edit config',
              icon: const Icon(Icons.edit_outlined, size: 19),
              onPressed: () => _editConfigJson(context, s),
            ),
          SizedBox(
            height: 28,
            child: Switch(
              key: ValueKey('mcp-detail-switch-${s.canonicalId}'),
              value: s.connected,
              activeTrackColor: Aether.accent,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: connecting
                  ? null
                  : (_) async {
                      await connectMcpServer(context, s);
                      _reloadCreds();
                    },
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: ValueKey('mcp-detail-delete-${s.canonicalId}'),
            tooltip: 'Delete server',
            icon: Icon(
              Icons.delete_outline,
              size: 19,
              color: Aether.danger,
            ),
            onPressed: () async {
              final ok = await showDeleteConfirmationDialog(
                context,
                title: 'Delete ${s.name}?',
              );
              if (!ok) return;
              await app.removeMcpServer(s);
              if (context.mounted) Navigator.pop(context);
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
                    Builder(
                      builder: (_) {
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
                      },
                    ),
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
              icon: connecting
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    )
                  : Icon(
                      s.connected ? Icons.link_off : Icons.power_settings_new,
                      size: 16,
                    ),
              label: Text(
                connecting
                    ? 'Connecting…'
                    : s.connected
                    ? 'Disconnect'
                    : 'Connect server',
                style: const TextStyle(fontSize: 13.5),
              ),
              onPressed: connecting
                  ? null
                  : () async {
                      await connectMcpServer(context, s);
                      _reloadCreds();
                    },
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
                border: Border.all(
                  color: Aether.danger.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  Icon(Icons.block_outlined, size: 15, color: Aether.danger),
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
          // requirements and never auto-spawn until configured. Driven by
          // the real credential probe (missingCredentialsFor), not by the
          // envHint declaration, so stored credentials read "configured".
          FutureBuilder<_McpCredState>(
            future: _credFuture,
            builder: (context, snap) {
              final creds = snap.data;
              if (creds == null) return const SizedBox.shrink();
              final missing = [...creds.missingEnv, ...creds.missingHeaders];
              if (missing.isNotEmpty && !s.connected) {
                return _needsSetupBanner(context, s, missing);
              }
              if (missing.isEmpty && _declaresCredentials(s)) {
                return _configuredRow(context, s, creds);
              }
              return const SizedBox.shrink();
            },
          ),
          _authSection(context, s),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: ValueKey('mcp-reset-credentials-${s.canonicalId}'),
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
                    'Reset credentials',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  onPressed: connecting
                      ? null
                      : () async {
                          final ok = await showDeleteConfirmationDialog(
                            context,
                            title: 'Reset ${s.name} credentials?',
                            content:
                                'Disconnects ${s.name} and deletes its stored '
                                'environment variables, HTTP headers and '
                                'OAuth sign-in from this device. The server '
                                'stays in your list.',
                            confirmLabel: 'Reset',
                          );
                          if (!ok || !context.mounted) return;
                          final messenger = ScaffoldMessenger.of(context);
                          await app.resetMcpServerConfig(s);
                          _reloadCreds();
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                '${s.name} disconnected · credentials deleted',
                              ),
                            ),
                          );
                        },
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const SectionHeader('Overview'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              s.description,
              style: TextStyle(fontSize: 13.5, height: 1.6, color: Aether.text),
            ),
          ),
          FutureBuilder<_McpCredState>(
            future: _credFuture,
            builder: (context, snap) {
              final creds = snap.data;
              if (creds == null || creds.isEmpty) {
                return const SizedBox.shrink();
              }
              return _credentialsSection(context, s, creds);
            },
          ),
          // Claude Code `/mcp` parity: what the server offers, how it has
          // been used, and what went wrong last.
          const SectionHeader('Capabilities'),
          _toolsSection(s),
          _catalogSection(s),
          _usageSection(s),
          _lastErrorSection(s),
          const SectionHeader('Config (standard mcp.json)'),
          if (!mcpConfigEditable(s))
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                switch (mcpManagingPlugin(s)) {
                  final owner? =>
                    'Managed by plugin $owner — read-only here. Update or '
                        'reconfigure the plugin to change it.',
                  null => 'Built-in server — config is read-only.',
                },
                key: ValueKey('mcp-config-readonly-${s.canonicalId}'),
                style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
              ),
            ),
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
                _runRow('Process', scrubCommandLine(s.command, s.args)),
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
  Future<void> _editConfigJson(BuildContext context, McpServer s) async {
    final app = AppState.I;
    Map<String, String> existingEnv;
    Map<String, String> existingHeaders;
    try {
      existingEnv = await app.getMcpEnv(s.canonicalId, strict: true);
      existingHeaders = await app.getMcpHeaders(s.canonicalId, strict: true);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not load credentials. Try again.'),
          ),
        );
      }
      return;
    }
    if (!context.mounted) return;
    final ctrl = TextEditingController(
      text: _configJsonFor(
        s,
        environmentNames: existingEnv.keys,
        headerNames: existingHeaders.keys,
      ),
    );
    await showModalBottomSheet<void>(
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
        child: SingleChildScrollView(
          child: _McpJsonEditorSheet(
            controller: ctrl,
            onSave: (edit) async {
              // The mask means preserve, never a credential value. Read again
              // at save so a credential updated while editing is not reverted.
              final currentEnv = await app.getMcpEnv(
                s.canonicalId,
                strict: true,
              );
              final currentHeaders = {
                ...s.headers,
                ...await app.getMcpHeaders(s.canonicalId, strict: true),
              };
              Map<String, String> unmask(
                Map<String, String> edited,
                Map<String, String> current,
              ) => {
                for (final entry in edited.entries)
                  if (entry.value != _credentialMask)
                    entry.key: entry.value
                  else if (current[entry.key] case final value?
                      when value != _credentialMask)
                    entry.key: value,
              };
              final mergedEnv = unmask(edit.env, currentEnv);
              final mergedHeaders = unmask(edit.headers, currentHeaders);
              // Validate before any write so a rejected edit changes nothing.
              final rejected = app.customMcpEditRejection(
                s,
                command: edit.command,
                args: edit.args,
                url: edit.url,
                transport: edit.transport,
              );
              if (rejected != null) throw _McpEditRejected(rejected);
              // Omitted keys are explicit removals; all existing names were
              // included in the editor, including ones absent from envHint.
              await app.setMcpEnv(s.canonicalId, mergedEnv, strict: true);
              // Always written: an empty map deletes stored headers, so a
              // header removed in the editor is really gone.
              await app.setMcpHeaders(
                s.canonicalId,
                mergedHeaders,
                strict: true,
              );
              final reason = app.updateCustomMcpServer(
                s,
                command: edit.command,
                args: edit.args,
                url: edit.url,
                transport: edit.transport,
                headers: mergedHeaders,
                cwd: edit.cwd,
                startupTimeoutS: edit.startupTimeoutS,
                toolTimeoutS: edit.toolTimeoutS,
              );
              if (reason != null) throw _McpEditRejected(reason);
              if (!ctx.mounted || !context.mounted) return;
              Navigator.pop(ctx);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('mcp.json saved ✓')));
            },
          ),
        ),
      ),
    );
    _reloadCreds();
  }

  static const _credentialMask = '••••••••';

  String _configJsonFor(
    McpServer s, {
    Iterable<String> environmentNames = const [],
    Iterable<String> headerNames = const [],
    bool scrubbed = false,
  }) {
    final names = {
      ...environmentNames,
      ...s.requiredEnvNames,
      for (final name in (s.envHint ?? '').split(','))
        if (name.trim().isNotEmpty) name.trim(),
    };
    final headers = {
      ...headerNames,
      ...s.headers.keys,
      ...s.requiredHeaderNames,
    };
    return jsonEncode({
      'mcpServers': {
        s.name: {
          'command': s.command,
          'args': scrubbed ? scrubArgs(s.args) : s.args,
          'transport': s.transport,
          if (s.url != null) 'url': scrubbed ? scrubUrl(s.url!) : s.url,
          if (s.cwd != null) 'cwd': s.cwd,
          // Round-tripped so an edit never silently resets them.
          'startupTimeoutS': s.startupTimeoutS,
          'toolTimeoutS': s.toolTimeoutS,
          if (names.isNotEmpty)
            'env': {for (final name in names) name: _credentialMask},
          // Masked like env: values stay in secure storage; keep the mask to
          // preserve, replace to rotate, remove the key to delete.
          if (headers.isNotEmpty)
            'headers': {for (final name in headers) name: _credentialMask},
        },
      },
    });
  }
}

/// Resources/prompts a connected server advertised (null = not advertised).
class _McpCatalog {
  final List<Map<String, dynamic>>? resources;
  final String? resourcesError;
  final List<Map<String, dynamic>>? prompts;
  final String? promptsError;
  const _McpCatalog({
    this.resources,
    this.resourcesError,
    this.prompts,
    this.promptsError,
  });
}

/// Compact, readable preview of a tool's JSON input schema: one line per
/// property (`name: type — description`, `*` = required), or the raw JSON
/// when the schema has no `properties`.
String mcpSchemaPreview(Map<String, dynamic>? schema) {
  if (schema == null || schema.isEmpty) return 'No parameters';
  final props = schema['properties'];
  if (props is! Map || props.isEmpty) {
    if (schema['type'] == 'object') return 'No parameters';
    final raw = const JsonEncoder.withIndent('  ').convert(schema);
    return raw.length > 2000 ? '${raw.substring(0, 2000)}…' : raw;
  }
  final required = {
    for (final r in (schema['required'] as List?) ?? const []) '$r',
  };
  final lines = <String>[];
  for (final e in props.entries) {
    final p = e.value is Map ? e.value as Map : const {};
    var type = p['type'];
    if (type is List) type = type.join('|');
    if (type == 'array' && p['items'] is Map) {
      type = '${(p['items'] as Map)['type'] ?? 'any'}[]';
    }
    final enumValues = p['enum'];
    final desc = '${p['description'] ?? ''}'.trim();
    lines.add(
      '${e.key}${required.contains('${e.key}') ? '*' : ''}: ${type ?? 'any'}'
      '${enumValues is List ? ' (${enumValues.join(' | ')})' : ''}'
      '${desc.isEmpty ? '' : ' — $desc'}',
    );
  }
  if (required.isNotEmpty) lines.add('* required');
  return lines.join('\n');
}

/// A config edit rejected by validation — its message is shown verbatim in
/// the editor (it is already user-facing copy).
class _McpEditRejected implements Exception {
  final String message;
  const _McpEditRejected(this.message);
}

/// Owning plugin label when [s] is managed by a plugin (its config comes
/// from the plugin manifest and is not editable here), else null.
String? mcpManagingPlugin(McpServer s) {
  final owner = s.ownerPluginId;
  if (owner != null && owner.isNotEmpty) return owner;
  if (s.source.startsWith('plugin:')) return s.source.substring(7);
  return null;
}

/// Whether the config editor may edit [s]: only user-added (custom) rows
/// that no plugin manages. Built-in seeds and plugin rows would persist the
/// change inconsistently (only custom rows are persisted).
bool mcpConfigEditable(McpServer s) => s.custom && mcpManagingPlugin(s) == null;

/// One parsed config edit from the mcp.json editor.
typedef McpConfigEdit = ({
  String command,
  List<String> args,
  Map<String, String> env,
  String? url,
  String? transport,
  Map<String, String> headers,
  String? cwd,
  int? startupTimeoutS,
  int? toolTimeoutS,
});

/// Bottom-sheet mcp.json editor: multiline TextField + live validation.
/// Save parses the mcpServers.{name} entry and returns command + args +
/// env (values stored in secure storage, passed to the server process).
class _McpJsonEditorSheet extends StatefulWidget {
  final TextEditingController controller;
  final Future<void> Function(McpConfigEdit edit) onSave;
  const _McpJsonEditorSheet({required this.controller, required this.onSave});

  @override
  State<_McpJsonEditorSheet> createState() => _McpJsonEditorSheetState();
}

class _McpJsonEditorSheetState extends State<_McpJsonEditorSheet> {
  String? _error;
  bool _saving = false;

  void _validate() {
    setState(() {
      _error = _parse(widget.controller.text) == null
          ? 'Invalid mcp.json — expected {"mcpServers": {"name": {"command": "...", "args": [...]}}}'
          : null;
    });
  }

  McpConfigEdit? _parse(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final servers = j['mcpServers'] as Map<String, dynamic>?;
      if (servers == null || servers.isEmpty) return null;
      final entry = servers.values.first as Map<String, dynamic>;
      final command = entry['command'] as String?;
      final url = (entry['url'] as String?)?.trim();
      final transport =
          (entry['transport'] as String?) ?? (entry['type'] as String?);
      final isHttp = (url != null && url.isNotEmpty) || transport == 'http';
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
      int? timeout(String key) {
        final v = entry[key];
        if (v == null) return null;
        final n = v is num ? v.toInt() : int.tryParse(v.toString());
        if (n == null || n <= 0) throw const FormatException('timeout');
        return n;
      }

      return (
        command: (command ?? '').trim(),
        args: args,
        env: env,
        url: isHttp ? url : null,
        transport: transport ?? (isHttp ? 'http' : 'stdio'),
        headers: headers,
        cwd: (entry['cwd'] as String?)?.trim(),
        startupTimeoutS: timeout('startupTimeoutS'),
        toolTimeoutS: timeout('toolTimeoutS'),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final sheet = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.edit_outlined, size: 16, color: Aether.textMuted),
            const SizedBox(width: 8),
            const Expanded(child: Text(
              'Edit mcp.json',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            )),
            IconButton(
              tooltip: 'Close',
              icon: const Icon(Icons.close, size: 18),
              onPressed: _saving ? null : () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Edit command, args, env, headers or timeouts. Keep masked values '
          'to preserve credentials; replace a value to update it, or remove '
          'its key to delete it.',
          style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
        ),
        const SizedBox(height: 12),
        SizedBox(
          child: TextField(
            controller: widget.controller,
            readOnly: _saving,
            maxLines: null,
            minLines: 6,
            textAlignVertical: TextAlignVertical.top,
            style: TextStyle(fontFamily: Aether.mono, fontSize: 12),
            decoration: InputDecoration(
              filled: true,
              fillColor: Aether.surfaceAlt,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: Aether.inputBorder),
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
          onPressed: _saving
              ? null
              : () async {
                  final parsed = _parse(widget.controller.text);
                  if (parsed == null) {
                    setState(
                      () => _error =
                          'Invalid mcp.json — check the JSON syntax and try again.',
                    );
                    return;
                  }
                  setState(() => _saving = true);
                  try {
                    await widget.onSave(parsed);
                  } on _McpEditRejected catch (e) {
                    if (mounted) setState(() => _error = e.message);
                  } catch (_) {
                    if (mounted) {
                      setState(
                        () => _error = 'Could not save config. Try again.',
                      );
                    }
                  } finally {
                    if (mounted) setState(() => _saving = false);
                  }
                },
        ),
      ],
    );
    return PopScope(canPop: !_saving, child: sheet);
  }
}
