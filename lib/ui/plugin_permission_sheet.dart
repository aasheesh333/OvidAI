import 'package:flutter/material.dart';
import '../core/plugin_manifest.dart';
import '../core/plugin_permissions.dart';
import '../core/theme.dart';

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
    backgroundColor: Aether.surface,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
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

  Future<void> _accept() async {
    if (_saving) return;
    setState(() => _saving = true);
    // One consolidated grant per manifest digest (spec §5.1): the full
    // inferred capability set + environment-read names, non-secret data
    // only — secret VALUES stay in secure storage, never here.
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
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final explanations = explainCapabilities(widget.manifest);
    final deps = widget.manifest.dependencies.packages;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          18,
          20,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Aether.surfaceAlt,
                      borderRadius: BorderRadius.circular(13),
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
                        Text(
                          'Grant plugin access',
                          style: TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${widget.manifest.name} ${widget.manifest.version.isEmpty ? '' : '· ${widget.manifest.version}'}'
                          '${widget.manifest.id.isEmpty ? '' : ' · ${widget.manifest.id}'}',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: Aether.textFaint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (explanations.isEmpty)
                        Text(
                          'This plugin requests no special capabilities.',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Aether.textMuted,
                          ),
                        )
                      else ...[
                        Text(
                          'CAPABILITIES',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                            color: Aether.textFaint,
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (final e in explanations)
                          _CapabilityRow(explanation: e),
                      ],
                      if (deps.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(
                          'DEPENDENCIES',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                            color: Aether.textFaint,
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (final d in deps)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  d.required
                                      ? Icons.download_outlined
                                      : Icons.download_done_outlined,
                                  size: 14,
                                  color: Aether.textFaint,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(
                                          text: d.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        TextSpan(
                                          text:
                                              ' ${d.versionSpec.isEmpty ? '' : d.versionSpec} '
                                              '(${d.kind.name}'
                                              '${d.required ? '' : ', optional'})',
                                          style: TextStyle(
                                            color: Aether.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                    style: const TextStyle(fontSize: 12.5),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        'Approve once for this exact plugin version. Secrets '
                        'stay in secure storage; you can revoke anytime from '
                        'plugin settings.',
                        style: TextStyle(
                          fontSize: 11,
                          color: Aether.textFaint,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Aether.text,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        side: BorderSide(color: Aether.hairlineStrong),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontSize: 13.5),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Aether.accent,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _saving ? null : _accept,
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                              ),
                            )
                          : const Text(
                              'Accept',
                              style: TextStyle(fontSize: 13.5),
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
}

class _CapabilityRow extends StatelessWidget {
  final CapabilityExplanation explanation;

  const _CapabilityRow({required this.explanation});

  @override
  Widget build(BuildContext context) {
    final e = explanation;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Aether.surfaceAlt,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: Aether.hairline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _iconFor(e.capability),
              size: 16,
              color: Aether.accent,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.capability.name,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    e.reason,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Aether.textMuted,
                    ),
                  ),
                  if (e.environmentNames.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'variables: ${e.environmentNames.join(', ')}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Aether.textMuted,
                        ),
                      ),
                    ),
                  if (e.sourcePath.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        e.sourcePath,
                        style: TextStyle(
                          fontFamily: Aether.mono,
                          fontSize: 10.5,
                          color: Aether.textFaint,
                        ),
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
