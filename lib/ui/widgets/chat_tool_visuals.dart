import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/l10n.dart';

/// Row presentation per tool — icon + how to title it. Moved verbatim from
/// the retired local service (P8 Task 19); the server's tool names are the
/// contract this taxonomy describes.
String toolIconFor(String toolName) {
  if (toolName.startsWith('fs_') || toolName.startsWith('file_')) {
    return toolName.contains('edit') || toolName.contains('write')
        ? 'edit'
        : 'read';
  }
  return switch (toolName) {
    'multi_edit' || 'notebook_edit' => 'edit',
    'run_shell' => 'terminal',
    'run_code' => 'code',
    'job_start' || 'job_kill' || 'job_list' || 'job_output' => 'terminal',
    'web_search' ||
    'fs_grep' ||
    'fs_glob' ||
    'session_search' ||
    'memory_search' => 'search',
    'fetch_url' => 'web',
    'generate_image' ||
    'edit_image' ||
    'edit_images' ||
    'resize_image' ||
    'crop_image' => 'sparkle',
    'render_html' => 'code',
    'dispatch_agent' => 'agent',
    'workflow' => 'workflow',
    'ralph' => 'loop',
    'commit' || 'repo_sync' || 'repo_tree' => 'git',
    'create_goal' || 'update_goal' || 'get_goal' => 'goal',
    'memory_save' => 'memory',
    'read_attachment' => 'read',
    _ => 'api',
  };
}

/// Claude-Code-style tool-row visuals: one glyph per tool family and a
/// status badge (spinner / check / cross) at the end of the row.
///
/// The family comes from [toolIconFor] (the agent's own taxonomy)
/// with two UI refinements it does not distinguish: image tools get an image
/// glyph instead of the generic sparkle, and MCP / plugin tools get a plug.
String chatToolFamily(String toolName) {
  if (toolName.startsWith('mcp__') || toolName.startsWith('mcp_')) {
    return 'mcp';
  }
  if (toolName.startsWith('plugin__') ||
      toolName.startsWith('plugin:') ||
      toolName.startsWith('plugin_')) {
    return 'plugin';
  }
  if (toolName == 'read_image' || toolName == 'screenshot') return 'image';
  // The agent buckets every `fs_*` tool as read/edit; grep/glob are searches.
  if (toolName == 'fs_grep' || toolName == 'fs_glob') return 'search';
  final kind = toolIconFor(toolName);
  if (kind == 'sparkle') return 'image';
  return kind;
}

IconData chatToolIcon(String toolName) => switch (chatToolFamily(toolName)) {
  'read' => Icons.description_outlined,
  'edit' => Icons.edit_note_rounded,
  'terminal' => Icons.terminal_rounded,
  'code' => Icons.code_rounded,
  'search' => Icons.search_rounded,
  'web' => Icons.public_rounded,
  'image' => Icons.image_outlined,
  'mcp' => Icons.power_outlined,
  'plugin' => Icons.extension_outlined,
  'agent' => Icons.account_tree_outlined,
  'workflow' => Icons.alt_route_rounded,
  'loop' => Icons.loop_rounded,
  'git' => Icons.commit_rounded,
  'goal' => Icons.flag_outlined,
  'schedule' => Icons.schedule_outlined,
  'memory' => Icons.psychology_outlined,
  _ => Icons.bolt_outlined,
};

/// Trailing status glyph of a tool row: a small spinner while running, a
/// check when done, a cross on error, a stop glyph when stopped.
class ToolStatusBadge extends StatelessWidget {
  const ToolStatusBadge({super.key, required this.state, this.size = 14});

  /// running | ok | error | stopped | unknown
  final String state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (Widget glyph, String label) = switch (state) {
      'running' => (
        SizedBox(
          width: size - 2,
          height: size - 2,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            color: Aether.accent,
          ),
        ),
        l10n.toolStatusRunning,
      ),
      'error' => (
        Icon(Icons.close_rounded, size: size, color: Aether.danger),
        l10n.toolStatusFailed,
      ),
      'stopped' => (
        Icon(Icons.stop_circle_outlined, size: size, color: Aether.warn),
        l10n.toolStatusStopped,
      ),
      'unknown' => (
        Icon(Icons.help_outline_rounded, size: size, color: Aether.textFaint),
        l10n.toolStatusUnknown,
      ),
      _ => (
        Icon(Icons.check_rounded, size: size, color: Aether.success),
        l10n.toolStatusDone,
      ),
    };
    return Semantics(
      label: label,
      child: SizedBox(
        key: ValueKey('chat-tool-status-$state'),
        width: size + 2,
        height: size + 2,
        child: Center(child: glyph),
      ),
    );
  }
}
