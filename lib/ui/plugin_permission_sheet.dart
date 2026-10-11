import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/diag.dart';
import '../core/plugin_manifest.dart';
import '../core/plugin_permissions.dart';
import '../core/plugin_source_resolver.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// One consolidated capability + dependency approval per plugin install
/// (design spec §5.1): shows where the plugin comes from ([provenance] —
/// repo, ref, revision, marketplace, with a warning for unverified
/// sources), lists every inferred capability with its reason and source
/// path, the dependency packages it wants installed, and Accept/Cancel.
///
/// Independently enforceable capabilities
/// ([kDeclinablePluginCapabilities]) carry a switch: switching one off
/// records it as DECLINED, and the runtime skips just the contributions
/// that need it. Dependency install scripts are a separate opt-in, off by
/// default — never implied by a hook's shell grant.
///
/// Accept persists the [PluginPermissionGrant] for the manifest's digest
/// via [PluginPermissionStore] and returns true; Cancel returns false and
/// leaves NO state (nothing granted — the caller aborts the install).
///
/// This is a per-install(-update) approval, never a per-action prompt:
/// after a grant, normal session mode and the approval policy apply
/// unchanged.
Future<bool?> showPluginPermissionSheet(
  BuildContext context, {
  required NormalizedPluginManifest manifest,
  PluginSourceProvenance? provenance,
  Future<bool> Function(Uri uri)? openUrl,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => _PluginPermissionSheet(
      manifest: manifest,
      provenance: provenance,
      openUrl: openUrl ?? _openExternal,
    ),
  );
}

Future<bool> _openExternal(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Dependency packages whose installers can run code at install time
/// (npm lifecycle scripts, Python source builds).
List<PluginDependency> scriptCapableDependencies(
  NormalizedPluginManifest manifest,
) => [
  for (final d in manifest.dependencies.packages)
    if (d.kind == PluginDependencyKind.npm ||
        d.kind == PluginDependencyKind.python)
      d,
];

class _PluginPermissionSheet extends StatefulWidget {
  final NormalizedPluginManifest manifest;
  final PluginSourceProvenance? provenance;
  final Future<bool> Function(Uri uri) openUrl;

  const _PluginPermissionSheet({
    required this.manifest,
    required this.provenance,
    required this.openUrl,
  });

  @override
  State<_PluginPermissionSheet> createState() => _PluginPermissionSheetState();
}

class _PluginPermissionSheetState extends State<_PluginPermissionSheet> {
  bool _saving = false;
  String? _error;

  /// Capabilities the user switched off (only declinable ones).
  final Set<PluginCapability> _declined = {};

  /// Separate opt-in for dependency install scripts — off by default.
  bool _allowScripts = false;

  Future<void> _accept() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    // One consolidated grant per manifest digest (spec §5.1): the inferred
    // capability set split into granted and declined, plus
    // environment-read names — non-secret data only; secret VALUES stay in
    // secure storage, never here.
    final requested = inferRequestedCapabilities(widget.manifest);
    final declined = _declined
        .intersection(requested)
        .intersection(kDeclinablePluginCapabilities);
    try {
      await PluginPermissionStore().save(
        PluginPermissionGrant(
          pluginId: widget.manifest.id,
          manifestDigest: pluginManifestDigest(widget.manifest),
          capabilities: requested.difference(declined),
          declinedCapabilities: declined,
          allowDependencyScripts:
              _allowScripts &&
              scriptCapableDependencies(widget.manifest).isNotEmpty,
          environmentReadNames: {
            ...widget.manifest.environmentReadNames,
            for (final s in widget.manifest.mcpServers) ...s.envNames,
          },
          approvedAt: DateTime.now(),
          // H2: bind consent to the exact files on screen, not just the
          // manifest — changed code under the same manifest re-prompts.
          contentTreeHash: PluginPermissionStore.contentTreeHashFor(
            widget.manifest.rootPath,
            reverify: true,
          ),
        ),
      );
    } catch (e) {
      // Surface the failure in-sheet instead of stranding the spinner.
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save the grant: $e';
        });
      }
      return;
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _openRepo(Uri uri) async {
    try {
      if (await widget.openUrl(uri)) return;
    } catch (e) {
      Diag.swallow('plugin_permission_sheet.open_repo', e);
    }
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text("Couldn't open ${uri.toString()}")),
    );
  }

  @override
  Widget build(BuildContext context) {
    final explanations = explainCapabilities(widget.manifest);
    final deps = widget.manifest.dependencies.packages;
    final scriptDeps = scriptCapableDependencies(widget.manifest);
    final version = widget.manifest.version;
    final id = widget.manifest.id;

    return PopScope(
      canPop: !_saving,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        // Scroll the chrome too: a keyboard and large text can leave less
        // room than the title and actions alone need.
        child: SingleChildScrollView(
          child: MediaQuery.removeViewInsets(
            context: context,
            removeBottom: true,
          child: AetherSheet(
        title: 'Grant plugin access',
        actions: [
          AetherGhostButton(
            label: 'Cancel',
            onPressed: _saving ? null : () => Navigator.pop(context, false),
          ),
          AetherPrimaryButton(
            label: 'Accept',
            loading: _saving,
            onPressed: _saving ? null : _accept,
          ),
        ],
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Aether.surfaceAlt,
                      borderRadius: BorderRadius.circular(AetherRadius.rMd),
                      border: Border.all(color: Aether.hairlineStrong),
                    ),
                    child: Icon(
                      Icons.privacy_tip_outlined,
                      size: 22,
                      color: Aether.text,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.manifest.name, style: AetherType.title),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (version.isNotEmpty) 'v$version',
                            if (id.isNotEmpty) id,
                          ].join(' · '),
                          style: AetherType.caption,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (widget.provenance != null) ...[
                const SizedBox(height: 16),
                _SourceCard(
                  provenance: widget.provenance!,
                  onOpenRepo: _openRepo,
                ),
              ],
              const SizedBox(height: 16),
              if (explanations.isEmpty)
                AetherCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.verified_outlined,
                        size: 18,
                        color: Aether.successLight,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'This plugin requests no special capabilities.',
                          style: AetherType.body,
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                AetherSectionTitle(eyebrow: 'Capabilities'),
                const SizedBox(height: 8),
                for (final e in explanations)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _CapabilityRow(
                      explanation: e,
                      declinable: kDeclinablePluginCapabilities.contains(
                        e.capability,
                      ),
                      allowed: !_declined.contains(e.capability),
                      onChanged: _saving
                          ? null
                          : (allow) => setState(() {
                              if (allow) {
                                _declined.remove(e.capability);
                              } else {
                                _declined.add(e.capability);
                              }
                            }),
                    ),
                  ),
              ],
              if (deps.isNotEmpty) ...[
                const SizedBox(height: 10),
                AetherSectionTitle(eyebrow: 'Dependencies'),
                const SizedBox(height: 8),
                AetherCard(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < deps.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              deps[i].required
                                  ? Icons.download_outlined
                                  : Icons.download_done_outlined,
                              size: 16,
                              color: Aether.textMuted,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(
                                      text: deps[i].name,
                                      style: AetherType.body.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    TextSpan(
                                      text:
                                          ' ${deps[i].versionSpec} '
                                          '(${deps[i].kind.name}'
                                          '${deps[i].required ? '' : ', optional'})',
                                      style: AetherType.bodyMuted,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (scriptDeps.isNotEmpty) ...[
                const SizedBox(height: 8),
                _InstallScriptsRow(
                  packageCount: scriptDeps.length,
                  allowed: _allowScripts,
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _allowScripts = v),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'Approve once for this exact plugin version. Secrets stay in secure storage; you can revoke anytime from plugin settings.',
                style: AetherType.caption.copyWith(height: 1.5),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Semantics(
                  liveRegion: true,
                  label: _error,
                  child: AetherCard(
                    color: Aether.danger.withValues(alpha: 0.08),
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.error_outline, color: Aether.danger),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: AetherType.body.copyWith(color: Aether.dangerC),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              AetherCard(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline, size: 18, color: Aether.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Access summary: this grant applies to ${explanations.length} '
                        'capabilit${explanations.length == 1 ? 'y' : 'ies'} and '
                        '${widget.manifest.mcpServers.length} MCP server(s). '
                        'Each item below shows the manifest path that requested it.',
                        style: AetherType.bodyMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
        ),
      ),
          ),
        ),
      ),
    );
  }
}

class _CapabilityRow extends StatelessWidget {
  final CapabilityExplanation explanation;

  /// Whether the runtime can skip this capability's contributions on its
  /// own — only then is there a switch.
  final bool declinable;
  final bool allowed;
  final ValueChanged<bool>? onChanged;

  const _CapabilityRow({
    required this.explanation,
    this.declinable = false,
    this.allowed = true,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final e = explanation;
    return AetherCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Aether.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AetherRadius.rSm),
            ),
            child: Icon(_iconFor(e.capability), size: 16, color: Aether.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.capability.name,
                  style: AetherType.body.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(e.reason, style: AetherType.bodyMuted),
                if (e.environmentNames.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'variables: ${e.environmentNames.join(', ')}',
                      style: AetherType.caption,
                    ),
                  ),
                if (e.sourcePath.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      e.sourcePath,
                      style: AetherType.mono.copyWith(color: Aether.textFaint),
                    ),
                  ),
                if (declinable && !allowed)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Declined — parts of the plugin that need this are '
                      'disabled',
                      style: AetherType.caption.copyWith(
                        color: Aether.warnLight,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (declinable)
            Semantics(
              label: 'Allow ${pluginCapabilityTitle(e.capability)}',
              child: Switch(
                key: ValueKey('plugin-capability-${e.capability.name}'),
                value: allowed,
                onChanged: onChanged,
              ),
            ),
        ],
      ),
    );
  }

  static IconData _iconFor(PluginCapability cap) => switch (cap) {
    PluginCapability.workspaceRead => Icons.folder_outlined,
    PluginCapability.workspaceWrite => Icons.edit_outlined,
    PluginCapability.shellExecute => Icons.terminal_outlined,
    PluginCapability.networkConnect => Icons.language_outlined,
    PluginCapability.processSpawn => Icons.play_circle_outline,
    PluginCapability.environmentRead => Icons.key_outlined,
    PluginCapability.mcpRegister => Icons.hub_outlined,
    PluginCapability.hooksObserve => Icons.visibility_outlined,
    PluginCapability.hooksBlock => Icons.block_outlined,
    PluginCapability.sessionRead => Icons.chat_bubble_outline,
    PluginCapability.sessionWrite => Icons.rate_review_outlined,
    PluginCapability.deviceControl => Icons.phonelink_setup_outlined,
  };
}

/// Where the plugin comes from (F-105): repo@ref (tree), marketplace or
/// "Direct from GitHub", a warning for unverified remote sources, and a
/// tappable repository link.
class _SourceCard extends StatelessWidget {
  final PluginSourceProvenance provenance;
  final ValueChanged<Uri> onOpenRepo;

  const _SourceCard({required this.provenance, required this.onOpenRepo});

  @override
  Widget build(BuildContext context) {
    final p = provenance;
    final url = p.repoUrl;
    final owner = p.repo?.split('/').first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AetherSectionTitle(eyebrow: 'Source'),
        const SizedBox(height: 8),
        AetherCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                p.label,
                key: const ValueKey('plugin-source-label'),
                style: AetherType.mono.copyWith(color: Aether.text),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  p.origin,
                  if (p.fileCount != null && p.fileCount! > 0)
                    '${p.fileCount} file${p.fileCount == 1 ? '' : 's'}',
                ].join(' · '),
                style: AetherType.caption,
              ),
              if (url != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('plugin-source-open-repo'),
                    onPressed: () => onOpenRepo(url),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('View repository'),
                  ),
                ),
            ],
          ),
        ),
        if (p.unverified) ...[
          const SizedBox(height: 8),
          Semantics(
            container: true,
            child: AetherCard(
              key: const ValueKey('plugin-source-unverified'),
              color: Aether.warn.withValues(alpha: 0.10),
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: Aether.warnLight,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Unverified source. Ovid has not reviewed this plugin. '
                      'Install it only if you trust '
                      '${owner == null ? 'its author' : '"$owner"'} — a '
                      'look-alike name can hide a different author.',
                      style: AetherType.body,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The install-scripts disclosure and opt-in (F-104): npm lifecycle
/// scripts and Python source builds run arbitrary code while installing.
class _InstallScriptsRow extends StatelessWidget {
  final int packageCount;
  final bool allowed;
  final ValueChanged<bool>? onChanged;

  const _InstallScriptsRow({
    required this.packageCount,
    required this.allowed,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final noun = 'package${packageCount == 1 ? '' : 's'}';
    return AetherCard(
      key: const ValueKey('plugin-install-scripts'),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.terminal_outlined, size: 18, color: Aether.warnLight),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Runs install scripts from $packageCount $noun',
                  style: AetherType.body.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  allowed
                      ? 'Package install scripts (npm postinstall, Python '
                            'setup) can run any code on this device while '
                            'installing.'
                      : 'Off: packages install without running their '
                            'install scripts. Some packages may not work.',
                  style: AetherType.bodyMuted,
                ),
              ],
            ),
          ),
          Semantics(
            label: 'Allow install scripts',
            child: Switch(
              key: const ValueKey('plugin-install-scripts-switch'),
              value: allowed,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
