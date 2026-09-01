import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../core/agent_service.dart';
import '../core/firebase_service.dart';
import '../core/skills.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'auth_screen.dart';
import 'health_screen.dart';
import 'providers_screen.dart';
import 'plugins_screen.dart';
import 'usage_screen.dart';

/// Settings hub — DeepSeek/kimi-k3 web style. Providers & Plugins are
/// dedicated screens behind rows; everything else grouped below.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          // Profile header → Account (optional Firebase sign-in)
          InkWell(
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const AuthScreen())),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: AnimatedBuilder(
                animation: FirebaseService.I,
                builder: (_, _) {
                  final fb = FirebaseService.I;
                  final signedIn = fb.isSignedIn;
                  return Row(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: Aether.surfaceRaised,
                        child: Icon(
                          signedIn ? Icons.person : Icons.person_outline,
                          size: 22,
                          color: Aether.textMuted,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            signedIn
                                ? (fb.displayName ?? fb.email ?? 'You')
                                : 'You',
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            signedIn
                                ? (fb.email ?? 'Signed in')
                                : 'Local account · keys stay on device',
                            style: TextStyle(
                              fontSize: 12,
                              color: Aether.textFaint,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      Text(
                        signedIn ? 'Signed in' : 'Sign in',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Aether.accent,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right,
                        size: 18,
                        color: Aether.textFaint,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),

          const SectionHeader('Workspace'),
          _navTile(
            context,
            Icons.key_outlined,
            'Providers',
            'BYOK · free & custom providers',
            const ProvidersScreen(),
          ),
          _navTile(
            context,
            Icons.extension_outlined,
            'Plugins',
            'Agents, MCP servers, tools',
            const PluginsScreen(),
          ),

          const SectionHeader('Workspace stats'),
          _navTile(
            context,
            Icons.bar_chart_rounded,
            'Usage',
            'Per-client spend · OvidAI, OpenCode, Claude Code, Z Code',
            const UsageScreen(),
          ),

          const SectionHeader('Personalization'),
          _navTile(
            context,
            Icons.auto_fix_high_outlined,
            'Skills',
            'Upload .md skill files the agent uses in chat',
            const SkillsScreen(),
          ),
          const _SettingsSwitchTile(
            icon: Icons.psychology_outlined,
            title: 'Memory',
            subtitleOn: 'ON — AI remembers across chats (memory_search)',
            subtitleOff: 'OFF — AI starts fresh every chat',
            getter: _getMemoryEnabled,
            setter: _setMemoryEnabled,
          ),
          const _SettingsSwitchTile(
            icon: Icons.auto_awesome,
            title: 'Reasoning mode',
            subtitleOn: 'ON — show thinking before answers',
            subtitleOff: 'OFF — hide thinking, answers only',
            getter: _getShowReasoning,
            setter: _setShowReasoning,
          ),

          const SectionHeader('Chat'),
          _settingTile(Icons.dark_mode_outlined, 'Appearance', 'Dark (hacker)'),
          _settingTile(Icons.translate, 'Language', 'English'),
          _settingTile(
            Icons.image_outlined,
            'Image generation',
            'Auto · up to 1024px',
          ),
          _settingTile(Icons.mic_none, 'Voice input', 'On'),

          const SectionHeader('Agents & Sandbox'),          _navTile(
            context,
            Icons.monitor_heart_outlined,
            'Device health',
            'Score out of 100 — which packages/capabilities are available, why the score is what it is, and one-tap repair.',
            const HealthScreen(),
          ),
          _navTile(
            context,
            Icons.timer_outlined,
            'AI response timeout',
            'How long the agent may stream. Lower = snappier, higher = no cutoff of long answers.',
            const _TimeoutScreen(),
          ),
          _navTile(
            context,
            Icons.memory_outlined,
            'Context & output',
            'Context window override (per-model auto by default) and max output tokens. Drives auto-compaction + the % context ring.',
            const _ContextModelScreen(),
          ),
          const _ShareMemoryTile(),
          _settingTile(
            Icons.smart_toy_outlined,
            'Default agent',
            'Auto-select by task',
          ),
          _settingTile(
            Icons.public,
            'In-app browser',
            'Agent can browse & log in (ask me)',
          ),
          const _SettingsSwitchTile(
            icon: Icons.folder_shared_outlined,
            title: 'GitHub sync',
            subtitleOn: 'ON — AI edits push to your connected repo',
            subtitleOff: 'OFF — AI edits stay in local workspace only',
            getter: _getGithubSync,
            setter: _setGithubSync,
          ),
          const _SettingsSwitchTile(
            icon: Icons.flash_on,
            title: 'Auto-run safe commands',
            subtitleOn: 'ON — read-only terminal commands run without confirm',
            subtitleOff: 'OFF — every terminal command asks first',
            getter: _getAutoRunSafe,
            setter: _setAutoRunSafe,
          ),
          _settingTile(
            Icons.security_outlined,
            'Sandbox',
            'Ready · isolated on-device',
          ),

          const SectionHeader('Data controls'),
          _navTile(
            context,
            Icons.download_outlined,
            'Export chats',
            'Download all sessions as JSON',
            const _ExportChatsScreen(),
          ),
          _navTile(
            context,
            Icons.delete_outline,
            'Delete all data',
            'Chats, keys and settings · irreversible',
            const _DeleteAllDataScreen(),
          ),
          const _StorageTile(),

          const SectionHeader('Privacy'),
          _TelemetryTile(),
          _privacyPolicyTile(context),

          const SectionHeader('General'),
          const _ThemeToggle(),
          _settingTile(Icons.notifications_outlined, 'Notifications', 'On'),
          _settingTile(Icons.info_outline, 'About', 'Ovid AI 0.1.0-demo'),
        ],
      ),
    );
  }

  Widget _navTile(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    Widget screen,
  ) {
    return ListTile(
      leading: Icon(icon, size: 20, color: Aether.textMuted),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      trailing: Icon(Icons.chevron_right, size: 18, color: Aether.textFaint),
      onTap: () =>
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)),
    );
  }

  Widget _settingTile(IconData icon, String title, String trailing) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 19, color: Aether.textMuted),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      trailing: Text(
        trailing,
        style: TextStyle(fontSize: 12, color: Aether.textFaint),
      ),
      onTap: () {},
    );
  }

  Widget _privacyPolicyTile(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
        Icons.privacy_tip_outlined,
        size: 19,
        color: Aether.textMuted,
      ),
      title: const Text('Privacy policy', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        'dhanuk.page.gd/ovid',
        style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      trailing: Icon(Icons.open_in_new, size: 16, color: Aether.textFaint),
      onTap: () => showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Privacy policy', style: TextStyle(fontSize: 15)),
          content: const Text(
            'View the Ovid AI privacy policy at:\n\nhttps://dhanuk.page.gd/ovid/\n\n'
            'It covers Firebase sign-in, optional crash reports & analytics, and how your API keys stay encrypted on-device.',
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Telemetry consent toggle bound to FirebaseService.
class _TelemetryTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: FirebaseService.I,
      builder: (_, _) {
        final fb = FirebaseService.I;
        return SwitchListTile(
          dense: true,
          secondary: Icon(
            Icons.insights_outlined,
            size: 19,
            color: Aether.textMuted,
          ),
          title: const Text(
            'Crash reports & analytics',
            style: TextStyle(fontSize: 14),
          ),
          subtitle: Text(
            fb.isAvailable
                ? 'Optional · anonymous · helps fix bugs'
                : 'Not configured in this build',
            style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
          ),
          activeTrackColor: Aether.accent,
          value: fb.consentGiven,
          onChanged: fb.isAvailable ? (x) => fb.setConsent(x) : null,
        );
      },
    );
  }
}
/// Real persisted setting toggle — reads/writes AppState (survives app
/// restarts, gates actual features). Replaces the old fake local-state
/// `_SwitchTile` that reset to a hardcoded literal on every reopen.
class _SettingsSwitchTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitleOn;
  final String subtitleOff;
  final bool Function() getter;
  final Future<void> Function(bool)? setter;
  const _SettingsSwitchTile({
    required this.icon,
    required this.title,
    required this.subtitleOn,
    required this.subtitleOff,
    required this.getter,
    this.setter,
  });

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, _) {
        final v = getter();
        return ListTile(
          dense: true,
          leading: Icon(icon, size: 19, color: Aether.textMuted),
          title: Text(title, style: const TextStyle(fontSize: 14)),
          subtitle: Text(
            v ? subtitleOn : subtitleOff,
            style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
          ),
          trailing: SizedBox(
            height: 26,
            child: Switch(
              value: v,
              activeTrackColor: Aether.accent,
              onChanged: setter == null
                  ? null
                  : (x) => setter!(x),
            ),
          ),
          onTap: setter == null ? null : () => setter!(!getter()),
        );
      },
    );
  }
}

// ── Static accessors keep the tile declarations const-friendly ──
bool _getMemoryEnabled() => AppState.I.memoryEnabled;
Future<void> _setMemoryEnabled(bool v) => AppState.I.setMemoryEnabled(v);
bool _getShowReasoning() => AppState.I.showReasoning;
Future<void> _setShowReasoning(bool v) => AppState.I.setShowReasoning(v);
bool _getGithubSync() => AppState.I.githubSync;
Future<void> _setGithubSync(bool v) => AppState.I.setGithubSync(v);
bool _getAutoRunSafe() => AppState.I.autoRunSafeCommands;
Future<void> _setAutoRunSafe(bool v) => AppState.I.setAutoRunSafeCommands(v);

/// Live on-device storage usage (replaces the hardcoded "214 MB" string).
class _StorageTile extends StatefulWidget {
  const _StorageTile();
  @override
  State<_StorageTile> createState() => _StorageTileState();
}

class _StorageTileState extends State<_StorageTile> {
  String _label = 'Calculating…';

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      var bytes = 0;
      // Walk the app documents tree (sessions, workspaces, previews,
      // exported repos — everything that counts against user storage).
      final stack = <Directory>[docs];
      while (stack.isNotEmpty) {
        final dir = stack.removeLast();
        try {
          await for (final e in dir.list(followLinks: false)) {
            if (e is File) {
              try {
                bytes += await e.length();
              } catch (_) {}
            } else if (e is Directory) {
              stack.add(e);
            }
          }
        } catch (_) {}
      }
      final mb = bytes / (1024 * 1024);
      setState(() {
        _label = mb >= 1024
            ? '${(mb / 1024).toStringAsFixed(1)} GB · on-device only'
            : '${mb.toStringAsFixed(0)} MB · on-device only';
      });
    } catch (_) {
      setState(() => _label = 'On-device only');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(Icons.storage_outlined, size: 19, color: Aether.textMuted),
      title: const Text('Storage', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        _label,
        style: TextStyle(fontSize: 12, color: Aether.textFaint),
      ),
      onTap: _measure,
    );
  }
}

/// Share-session-memory toggle — real, persisted in AppState. OFF by default
/// so each chat session stays isolated (its own sandbox workspace + memory).
/// ON lets the AI search across every chat via the memory_search tool.
class _ShareMemoryTile extends StatelessWidget {
  const _ShareMemoryTile();

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, _) => ListTile(
        dense: true,
        leading: Icon(
          Icons.psychology_outlined,
          size: 19,
          color: Aether.textMuted,
        ),
        title: const Text(
          'Share session memory',
          style: TextStyle(fontSize: 14),
        ),
        subtitle: Text(
          app.shareSessionMemory
              ? 'ON — the AI can search across all chats (memory_search).'
              : 'OFF — every chat is isolated; the AI sees only this session.',
          style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
        ),
        trailing: SizedBox(
          height: 26,
          child: Switch(
            value: app.shareSessionMemory,
            activeTrackColor: Aether.accent,
            onChanged: (v) => app.setShareSessionMemory(v),
          ),
        ),
        onTap: () => app.setShareSessionMemory(!app.shareSessionMemory),
      ),
    );
  }
}

/// AI response timeout picker — real, persisted in AppState (responseTimeoutSec).
/// Light/dark theme toggle — flips Aether palette app-wide, persisted.
class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, _) => SwitchListTile(
        dense: true,
        secondary: Icon(
          Icons.light_mode_outlined,
          size: 19,
          color: Aether.textMuted,
        ),
        title: const Text('Light theme', style: TextStyle(fontSize: 14)),
        subtitle: Text(
          app.lightTheme ? 'ON — bright surfaces' : 'OFF — dark (default)',
          style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
        ),
        value: app.lightTheme,
        activeTrackColor: Aether.accent,
        onChanged: (v) => app.setLightTheme(v),
      ),
    );
  }
}

class _TimeoutScreen extends StatelessWidget {
  const _TimeoutScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('AI response timeout'),
      ),
      body: AnimatedBuilder(
        animation: AppState.I,
        builder: (_, _) {
          final cur = AppState.I.responseTimeoutSec;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'How long the agent may stream before being cut off. '
                'Long reasoning chains need a generous budget; casual chat '
                'feels snappier with a short one.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.55,
                  color: Aether.textMuted,
                ),
              ),
              const SizedBox(height: 16),
              RadioGroup<int>(
                groupValue: cur,
                onChanged: (v) {
                  if (v != null) AppState.I.setResponseTimeout(v);
                },
                child: Column(
                  children: [
                    for (final sec in AppState.timeoutPresets)
                      RadioListTile<int>(
                        dense: true,
                        activeColor: Aether.accent,
                        title: Text(
                          sec < 60
                              ? '$sec seconds'
                              : '${sec ~/ 60} minute${sec > 60 ? 's' : ''}',
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: Text(
                          switch (sec) {
                            60 => 'Quick answers',
                            120 => 'Default — balanced',
                            300 => 'Long tasks, web research',
                            _ => 'Heavy multi-tool runs',
                          },
                          style: TextStyle(
                            fontSize: 11,
                            color: Aether.textFaint,
                          ),
                        ),
                        value: sec,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Custom values: pick any number of seconds between 5 s and 60 min.',
                  style: TextStyle(fontSize: 11, color: Aether.textFaint),
                ),
              ),
              Slider(
                value: cur.toDouble().clamp(5.0, 3600.0),
                min: 5,
                max: 3600,
                divisions: 71,
                activeColor: Aether.accent,
                inactiveColor: Aether.surfaceAlt,
                label: '${cur}s',
                onChanged: (v) => AppState.I.setResponseTimeout(v.round()),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Context & output — user control over context window + output caps.
class _ContextModelScreen extends StatelessWidget {
  const _ContextModelScreen();

  static const _windowPresets = <(int, String)>[
    (0, 'Auto (per-model)'),
    (32768, '32K'),
    (65536, '64K'),
    (128000, '128K'),
    (200000, '200K'),
    (262144, '256K'),
    (524288, '512K'),
    (1000000, '1M'),
  ];
  static const _outPresets = <(int, String)>[
    (0, 'Auto (provider default)'),
    (2048, '2K'),
    (4096, '4K'),
    (8192, '8K'),
    (16384, '16K'),
    (32768, '32K'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Context & output'),
      ),
      body: AnimatedBuilder(
        animation: AppState.I,
        builder: (_, _) {
          final app = AppState.I;
          final s = app.activeSession;
          final autoWindow = AgentService.contextWindowFor(s?.model ?? '');
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'The context window drives auto-compaction (at 80% of the '
                'window the oldest messages are folded into a summary) and '
                'the % context ring above the composer. Values are exact '
                'deterministic choices — nothing is guessed or randomized.',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.55,
                  color: Aether.textMuted,
                ),
              ),
              const SizedBox(height: 8),
              const SectionHeader('Context window'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Text(
                  'Current model: ${s?.model ?? '—'}\n'
                  'Auto-detected window: ${(autoWindow / 1000).toStringAsFixed(0)}K tokens',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.55,
                    color: Aether.textFaint,
                  ),
                ),
              ),
              RadioGroup<int>(
                groupValue: app.contextWindowOverride,
                onChanged: (v) => AppState.I.setContextWindowOverride(v ?? 0),
                child: Column(
                  children: [
                    for (final (v, label) in _windowPresets)
                      RadioListTile<int>(
                        dense: true,
                        activeColor: Aether.accent,
                        title: Text(
                          label,
                          style: const TextStyle(fontSize: 14),
                        ),
                        value: v,
                      ),
                  ],
                ),
              ),
              const SectionHeader('Max output tokens'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Text(
                  'Cap the model\'s response length. Auto lets the provider '
                  'decide. Large caps can cost more per turn.',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.5,
                    color: Aether.textFaint,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              RadioGroup<int>(
                groupValue: app.maxOutputTokens,
                onChanged: (v) => AppState.I.setMaxOutputTokens(v ?? 0),
                child: Column(
                  children: [
                    for (final (v, label) in _outPresets)
                      RadioListTile<int>(
                        dense: true,
                        activeColor: Aether.accent,
                        title: Text(
                          label,
                          style: const TextStyle(fontSize: 14),
                        ),
                        value: v,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          );
        },
      ),
    );
  }
}

class _ExportChatsScreen extends StatefulWidget {
  const _ExportChatsScreen();
  @override
  State<_ExportChatsScreen> createState() => _ExportChatsScreenState();
}

class _ExportChatsScreenState extends State<_ExportChatsScreen> {
  bool _busy = false;

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
        '${dir.path}/ovid-sessions-${DateTime.now().millisecondsSinceEpoch}.json',
      );
      final payload = {
        'exportedAt': DateTime.now().toIso8601String(),
        'sessions': AppState.I.sessions.map((s) => s.toJson()).toList(),
      };
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Exported to:\n${file.path}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Export chats')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Exports every session (messages, todos, goals, schedules, '
            'attachments metadata) as a single JSON file saved to the app '
            'documents directory.',
            style: TextStyle(fontSize: 13.5, height: 1.6, color: Aether.textMuted),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _export,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined, size: 18),
            label: Text(_busy ? 'Exporting…' : 'Export all sessions'),
          ),
        ],
      ),
    );
  }
}

class _DeleteAllDataScreen extends StatefulWidget {
  const _DeleteAllDataScreen();
  @override
  State<_DeleteAllDataScreen> createState() => _DeleteAllDataScreenState();
}

class _DeleteAllDataScreenState extends State<_DeleteAllDataScreen> {
  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete ALL data?'),
        content: const Text(
          'This removes every session, saved API key, provider config, '
          'plugin state, and setting. The app will reset to defaults. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete everything',
              style: TextStyle(color: Aether.danger),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await AppState.I.deleteAllData();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('All data deleted.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delete all data')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Deletes every session, all API keys, providers, plugin state, '
            'and app preferences. Sandbox workspaces are removed too.',
            style: TextStyle(fontSize: 13.5, height: 1.6, color: Aether.textMuted),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Aether.danger),
            onPressed: _delete,
            icon: const Icon(Icons.delete_forever_outlined, size: 18),
            label: const Text('Delete all data'),
          ),
        ],
      ),
    );
  }
}

/// ── Skills screen (Settings → Personalization → Skills) ────────────────
/// Upload .md skill files ONLY. Uploaded skills live in a GLOBAL app-docs
/// folder (`<docs>/skills`) that SkillService scans on every run, so the
/// agent can use them in any chat via the `skill` tool, `/skill-name`
/// invocation, or the composer slash menu.
class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key});
  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  List<Skill> _skills = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    await AgentService.I.refreshSkills();
    if (!mounted) return;
    // Show ONLY global user-uploaded skills here — workspace skills are
    // managed by the agent inside each session.
    final docs = await getApplicationDocumentsDirectory();
    final root = '${docs.path}/skills';
    final all = SkillService.I.skills.where((s) => s.path.startsWith(root));
    setState(() {
      _skills = all.toList()..sort((a, b) => a.name.compareTo(b.name));
      _loading = false;
    });
  }

  Future<void> _upload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['md'],
      allowMultiple: true,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/skills');
    dir.createSync(recursive: true);

    var ok = 0;
    final errors = <String>[];
    for (final f in result.files) {
      final src = f.path;
      final name = f.name;
      if (src == null || !name.toLowerCase().endsWith('.md')) {
        errors.add('$name — not a .md file');
        continue;
      }
      try {
        final srcFile = File(src);
        final size = await srcFile.length();
        if (size > 512 * 1024) {
          errors.add('$name — too large (${(size / 1024).toStringAsFixed(0)} KB, max 512 KB)');
          continue;
        }
        // Collision-safe: suffix if a skill with this name already exists.
        var destName = name;
        var dest = File('${dir.path}/$destName');
        var n = 1;
        while (dest.existsSync()) {
          final dot = name.lastIndexOf('.');
          destName = dot > 0
              ? '${name.substring(0, dot)}_$n${name.substring(dot)}'
              : '${name}_$n';
          dest = File('${dir.path}/$destName');
          n++;
        }
        await srcFile.copy(dest.path);
        ok++;
      } catch (e) {
        errors.add('$name — $e');
      }
    }
    await _reload();
    if (!mounted) return;
    final msg = errors.isEmpty
        ? '$ok skill${ok == 1 ? '' : 's'} uploaded — the agent can now use '
              '${ok == 1 ? 'it' : 'them'} in any chat.'
        : '$ok uploaded · ${errors.length} skipped: ${errors.take(2).join(' · ')}';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _delete(Skill s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${s.name}"?', style: const TextStyle(fontSize: 15)),
        content: const Text('The agent will no longer see this skill in chat.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Aether.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final f = File(s.path);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
    await _reload();
  }

  Future<void> _preview(Skill s) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.name, style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              s.content,
              style: TextStyle(fontSize: 12.5, height: 1.5, color: Aether.textMuted),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Skills'),
        actions: [
          IconButton(
            tooltip: 'Upload .md skill',
            onPressed: _upload,
            icon: const Icon(Icons.upload_file_outlined, size: 20),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _skills.isEmpty
          ? _empty(context)
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
              itemCount: _skills.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final s = _skills[i];
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Aether.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Aether.hairline),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.auto_fix_high_outlined,
                        size: 18,
                        color: Aether.accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.name,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (s.description.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                s.description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: Aether.textFaint,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Preview',
                        onPressed: () => _preview(s),
                        icon: Icon(Icons.visibility_outlined, size: 17, color: Aether.textMuted),
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        onPressed: () => _delete(s),
                        icon: Icon(Icons.delete_outline, size: 17, color: Aether.danger),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_fix_high_outlined, size: 40, color: Aether.textFaint),
          const SizedBox(height: 12),
          const Text(
            'No skills yet',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Upload .md skill files. The agent can then call them in any '
              'chat with the skill tool, or you can type /name directly.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: Aether.textFaint,
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _upload,
            icon: const Icon(Icons.upload_file_outlined, size: 18),
            label: const Text('Upload .md skill'),
          ),
        ],
      ),
    );
  }
}
