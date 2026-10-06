import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'plugin_install_progress.dart';

/// Shared "integration detail" scaffold used by BOTH the plugin detail and
/// the MCP server detail (see `plugins_screen.dart`). One chrome, one
/// section flow:
///
///   header (icon, name, enable switch, ⋯ actions)
///   → primary action (Install / Enable / Connect) → banners
///   → Overview
///   → Config (settings form / mcp.json / environment)
///   → Status (ONE durable health line — never an inferred binary)
///   → extra sections (plugin diagnostics)
///   → Logs (shared [ProgressLogView] over the durable record's scrubbed,
///     capped diagnostic lines — empty reads as the honest waiting state)
///   → trailing sections (changelog / runtime)
///
/// The scaffold owns layout only. Every behavior — enable/disable,
/// install/uninstall, connect, credential grants, secret handling — stays
/// inside the caller-provided widgets, unchanged.
class IntegrationDetailScaffold extends StatelessWidget {
  const IntegrationDetailScaffold({
    super.key,
    required this.icon,
    required this.name,
    required this.overview,
    this.subtitle,
    this.badge,
    this.enableSwitch,
    this.headerActions = const [],
    this.primaryAction,
    this.banners = const [],
    this.configSections = const [],
    this.statusLine,
    this.extraSections = const [],
    this.logs = const [],
    this.trailingSections = const [],
  });

  /// Header icon (plugin category / MCP connector glyph).
  final IconData icon;

  /// Integration name — AppBar title and header headline.
  final String name;

  /// Meta line under the name (author · version · installs).
  final String? subtitle;

  /// Optional badge row under the meta line (category/format/activation).
  final Widget? badge;

  /// Enable/connect switch, first in the AppBar actions when present.
  final Widget? enableSwitch;

  /// The "⋯" — secondary AppBar actions (edit config, OAuth, delete).
  final List<Widget> headerActions;

  /// Primary lifecycle action(s): Install / Enable / Connect + secondary
  /// lifecycle buttons, rendered directly under the header.
  final Widget? primaryAction;

  /// Honesty banners (unsupported on this device / needs setup).
  final List<Widget> banners;

  /// Overview body (pre-padded by the caller).
  final Widget overview;

  /// Config sections: declarative settings form, environment, mcp.json.
  final List<Widget> configSections;

  /// The ONE health line: the durable canonical status (or null for the
  /// neutral no-record copy). Never duplicated elsewhere on the screen.
  final Widget? statusLine;

  /// Caller-specific sections between Status and Logs (plugin diagnostics).
  final List<Widget> extraSections;

  /// Scrubbed durable log lines for the shared [ProgressLogView].
  final List<String> logs;

  /// Sections after Logs (changelog / runtime).
  final List<Widget> trailingSections;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(name),
        actions: [
          if (enableSwitch != null) ...[enableSwitch!, const SizedBox(width: 4)],
          ...headerActions,
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
                child: Icon(icon, size: 26, color: Aether.textMuted),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
                      ),
                    ],
                    if (badge != null) ...[
                      const SizedBox(height: 6),
                      badge!,
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (primaryAction != null) ...[
            const SizedBox(height: 16),
            primaryAction!,
          ],
          for (final banner in banners) ...[
            const SizedBox(height: 8),
            banner,
          ],
          const SectionHeader('Overview'),
          overview,
          ...configSections,
          const SectionHeader('Status'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: statusLine ??
                Text(
                  'Not started',
                  style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
                ),
          ),
          ...extraSections,
          const SectionHeader('Logs'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ProgressLogView(lines: logs, height: 150),
          ),
          ...trailingSections,
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}
