import 'package:flutter/material.dart';

import '../core/plugin_manifest.dart';
import '../core/plugin_permissions.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// One consolidated capability + dependency approval per plugin install
/// (design spec §5.1): lists every inferred capability with its reason
/// and source path, the dependency commands the plugin wants installed,
/// and Accept/Cancel. Accept persists the [PluginPermissionGrant] for the
/// manifest's digest via [PluginPermissionStore] and returns true;
/// Cancel returns false and leaves NO state (nothing granted — the
/// caller aborts the install).
///
/// This is a per-install(-update) approval, never a per-action prompt:
/// after a grant, normal session mode and the approval policy apply
/// unchanged.
Future<bool?> showPluginPermissionSheet(
  BuildContext context, {
  required NormalizedPluginManifest manifest,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    enableDrag: false,
    builder: (_) => _PluginPermissionSheet(manifest: manifest),
  );
}

class _PluginPermissionSheet extends StatefulWidget {
  final NormalizedPluginManifest manifest;

  const _PluginPermissionSheet({required this.manifest});

  @override
  State<_PluginPermissionSheet> createState() => _PluginPermissionSheetState();
}

class _PluginPermissionSheetState extends State<_PluginPermissionSheet> {
  bool _saving = false;
  String? _error;

  Future<void> _accept() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    // One consolidated grant per manifest digest (spec §5.1): the full
    // inferred capability set + environment-read names, non-secret data
    // only — secret VALUES stay in secure storage, never here.
    try {
      await PluginPermissionStore().save(
        PluginPermissionGrant(
          pluginId: widget.manifest.id,
          manifestDigest: pluginManifestDigest(widget.manifest),
          capabilities: inferRequestedCapabilities(widget.manifest),
          environmentReadNames: {
            ...widget.manifest.environmentReadNames,
            for (final s in widget.manifest.mcpServers) ...s.envNames,
          },
          approvedAt: DateTime.now(),
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

  @override
  Widget build(BuildContext context) {
    final explanations = explainCapabilities(widget.manifest);
    final deps = widget.manifest.dependencies.packages;
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
                    child: _CapabilityRow(explanation: e),
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
              const SizedBox(height: 12),
              Text(
                'Approve once for this exact plugin version. Secrets stay in secure storage; you can revoke anytime from plugin settings.',
                style: AetherType.caption.copyWith(height: 1.5),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: AetherType.body.copyWith(color: Aether.dangerC),
                ),
              ],
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

  const _CapabilityRow({required this.explanation});

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
              ],
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
