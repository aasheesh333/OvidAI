import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/agent_service.dart';
import '../core/distribution.dart';
import '../core/cloud/byok_client.dart';
import '../core/app_info.dart';
import '../core/native_share.dart';
import '../core/firebase_service.dart';
import '../core/legal_links.dart';
import '../core/model_limits.dart';
import '../core/presets.dart';
import '../core/state.dart';
import '../core/settings_actions.dart';
import 'settings_action_widgets.dart';
import 'settings_backup_screen.dart';
import 'settings_health_screen.dart';
import '../core/theme.dart';
import 'auth_screen.dart';
import 'profile_avatar.dart';
import 'share_actions.dart';
import 'billing_screen.dart';
import 'memory_screen.dart';
import 'permissions_screen.dart';
import 'providers_screen.dart';
import 'usage_screen.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/external_link.dart';
import 'widgets/error_views.dart';
import 'user_error.dart';
import '../core/diag.dart';
import '../l10n/l10n.dart';
import 'widgets/ovid_mark.dart';

/// Settings hub — Aether premium reskin.
///
/// Rows are grouped by what people come to change: Account (plan, usage),
/// Personalization (theme, memory, reasoning), Data controls (export,
/// permissions, telemetry, storage, delete), Models, Studio, Notifications,
/// Advanced (device health, integrity, sync internals) and
/// About. Preference tiles keep their persisted bindings.
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
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          // ── Account ───────────────────────────────────────────────────
          const _SectionGap(),
          const AetherSectionTitle(eyebrow: 'Account'),
          const SizedBox(height: 10),
          AetherCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _accountHeader(context),
                _hairline(),
                _navTile(
                  context,
                  Icons.workspace_premium_outlined,
                  'Plan & Billing',
                  'Your Ovid Cloud plan · usage · upgrade',
                  const BillingScreen(),
                ),
                _hairline(),
                _navTile(
                  context,
                  Icons.bar_chart_rounded,
                  'Usage',
                  'Per-client spend · OvidAI, OpenCode, [CC], Z Code',
                  const UsageScreen(),
                ),
              ],
            ),
          ),

          // ── Personalization ───────────────────────────────────────────
          const _SectionGap(),
          const AetherSectionTitle(
            eyebrow: 'Personalization',
            subtitle: 'Theme, memory and how answers are shown.',
          ),
          const SizedBox(height: 10),
          AetherCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                const _ThemeToggle(),
                _hairline(),
                const _SettingsSwitchTile(
                  icon: Icons.psychology_outlined,
                  title: 'Memory',
                  subtitleOn:
                      'ON — personal and current-chat memory context & tools',
                  subtitleOff: 'OFF — saved memory context & tools disabled',
                  getter: _getMemoryEnabled,
                  setter: _setMemoryEnabled,
                ),
                _hairline(),
                const _ShareMemoryTile(),
                _hairline(),
                _navTile(
                  context,
                  Icons.description_outlined,
                  'Memory files',
                  'View, edit, save, add or import Markdown memory',
                  const MemoryScreen(),
                ),
                _hairline(),
                const _SettingsSwitchTile(
                  icon: Icons.auto_awesome,
                  title: 'Show reasoning',
                  subtitleOn: 'ON — show reasoning before answers',
                  subtitleOff: 'OFF — hide reasoning, answers only',
                  getter: _getShowReasoning,
                  setter: _setShowReasoning,
                ),
              ],
            ),
          ),

          // ── Data controls ─────────────────────────────────────────────
          const _SectionGap(),
          const AetherSectionTitle(
            eyebrow: 'Data controls',
            subtitle:
                'Export, permissions, telemetry, storage and deleting your data.',
          ),
          const SizedBox(height: 10),
          AetherCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _navTileWithAction(
                  context,
                  Icons.inventory_2_outlined,
                  'Export data',
                  'Portable chat backup (ZIP) to save or restore · JSON for other tools',
                  const SettingsBackupScreen(),
                  actionLabel: 'Backup',
                ),
                _hairline(),
                ListTile(
                  leading: const Icon(Icons.key_outlined),
                  title: const Text(
                    'Permissions',
                    style: TextStyle(fontSize: 14),
                  ),
                  subtitle: const Text(
                    'Paths and hosts the agent may always access',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const PermissionsScreen(),
                    ),
                  ),
                ),
                _hairline(),
                _TelemetryTile(),
                _hairline(),
                const _StorageTile(),
                _hairline(),
                _navTile(
                  context,
                  Icons.delete_outline,
                  'Delete all data',
                  SettingsActions.resetAll == null
                      ? 'Unavailable · verified full reset is not connected'
                      : 'Chats, keys and settings · irreversible',
                  SettingsResetScreen(
                    // "Export my chats first" (PR-3b) opens Export data.
                    onExport: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsBackupScreen(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Models ────────────────────────────────────────────────────
          const _SectionGap(),
          const AetherSectionTitle(
            eyebrow: 'Models',
            subtitle:
                'Providers, presets, context window and response wait limit.',
          ),
          const SizedBox(height: 10),
          AetherCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _navTile(
                  context,
                  Icons.key_outlined,
                  'Providers',
                  'BYOK · free & custom providers',
                  const ProvidersScreen(),
                ),
                if (Distribution.cloudByok) ...[
                  _hairline(),
                  _navTile(
                    context,
                    Icons.vpn_key_outlined,
                    'Bring your own keys',
                    'Escrow provider keys · encrypted server-side',
                    const ByokKeysScreen(),
                  ),
                ],
                _hairline(),
                _navTile(
                  context,
                  Icons.tune_outlined,
                  'Agent presets',
                  'Tool rosters & permissions · built-in & custom presets',
                  const _PresetsScreen(),
                ),
                _hairline(),
                _navTile(
                  context,
                  Icons.memory_outlined,
                  'Context & output',
                  'Context window override (per-model auto by default) and max output tokens. Drives auto-compaction + the % context ring.',
                  const _ContextModelScreen(),
                ),
                _hairline(),
                _navTile(
                  context,
                  Icons.timer_outlined,
                  'Response wait limit',
                  'How long to wait for the model to respond (or resume) before giving up.',
                  const _TimeoutScreen(),
                ),
              ],
            ),
          ),

          // ── Notifications ─────────────────────────────────────────────
          const _SectionGap(),
          const AetherSectionTitle(
            eyebrow: 'Notifications',
            subtitle: 'Status notifications and background work.',
          ),
          const SizedBox(height: 10),
          AetherCard(
            padding: EdgeInsets.zero,
            child: const _NotificationsTile(),
          ),

          // ── Advanced ──────────────────────────────────────────────────
          const _SectionGap(),
          const AetherSectionTitle(
            eyebrow: 'Advanced',
            subtitle:
                'Cloud health and device integrity.',
          ),
          const SizedBox(height: 10),
          AetherCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _navTileWithAction(
                  context,
                  Icons.monitor_heart_outlined,
                  'Device health',
                  'Ovid Cloud service status',
                  const SettingsHealthScreen(),
                  actionLabel: 'Health',
                ),
                _hairline(),
                const _DeviceIntegrityTile(),
              ],
            ),
          ),

          // ── About ─────────────────────────────────────────────────────
          const _SectionGap(),
          const AetherSectionTitle(eyebrow: 'About'),
          const SizedBox(height: 10),
          AetherCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: const Text('Share Ovid'),
                  subtitle: const Text('Send the app website'),
                  onTap: () => showNativeShare(context, NativeShare.app),
                ),
                _hairline(),
                _privacyPolicyTile(context),
                _hairline(),
                _navTile(
                  context,
                  Icons.info_outline,
                  'About',
                  'Ovid AI $kAppVersion',
                  const _AboutScreen(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Section-local helpers ───────────────────────────────────────────
  //
  // The row builders below ONLY affect presentation — the targets, labels,
  // subtitles and navigation semantics are the exact same as the pre-Aether
  // layout so persisted preferences and existing finders continue to work.

  Widget _accountHeader(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const AuthScreen())),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: AnimatedBuilder(
          animation: FirebaseService.I,
          builder: (_, _) {
            final fb = FirebaseService.I;
            final signedIn = fb.isSignedIn;
            return Row(
              children: [
                ProfileAvatar(photoUrl: fb.photoUrl),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
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
                            : 'Sign in to your account',
                        style: TextStyle(fontSize: 12, color: Aether.textFaint),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, size: 18, color: Aether.textFaint),
              ],
            );
          },
        ),
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
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        leading: Icon(icon, size: 20, color: Aether.textMuted),
        title: Text(title, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
        ),
        trailing: Icon(Icons.chevron_right, size: 18, color: Aether.textFaint),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => screen)),
      ),
    );
  }

  /// Variant of [_navTile] that also surfaces an [AetherGhostButton] in the
  /// trailing area labelled [actionLabel]. The row itself preserves the
  /// legacy tap-to-push behavior; the button is an additive affordance so
  /// callers (and tests) can locate the row by its short premium verb.
  Widget _navTileWithAction(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    Widget screen, {
    required String actionLabel,
  }) {
    void push() =>
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    return InkWell(
      onTap: push,
      borderRadius: BorderRadius.circular(AetherRadius.rSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: Aether.textMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            AetherGhostButton(label: actionLabel, onPressed: push),
          ],
        ),
      ),
    );
  }

  Widget _hairline() =>
      Divider(height: 1, thickness: 1, color: Aether.hairline);

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
        _displayUrl(LegalLinks.privacyPolicy),
        style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      trailing: Icon(Icons.open_in_new, size: 16, color: Aether.textFaint),
      onTap: () => openExternalLink(context, LegalLinks.privacyPolicy),
    );
  }
}

/// `https://host/path` → `host/path` for row subtitles.
String _displayUrl(String url) =>
    url.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'/$'), '');

/// Fixed-height gap between sections. Keeps the premium rhythm consistent
/// regardless of the content height of the preceding card.
class _SectionGap extends StatelessWidget {
  const _SectionGap();
  @override
  Widget build(BuildContext context) => const SizedBox(height: 24);
}

/// Telemetry consent toggle bound to FirebaseService.
class _TelemetryTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: FirebaseService.I,
      builder: (_, _) {
        final fb = FirebaseService.I;
        return SettingsSwitchTile(
          icon: Icons.insights_outlined,
          title: 'Crash reports & analytics',
          listenable: fb,
          subtitleOn: fb.isAvailable
              ? 'Optional telemetry requested'
              : 'Not configured in this build',
          subtitleOff: fb.isAvailable
              ? 'Optional telemetry disabled'
              : 'Not configured in this build',
          getter: () => fb.consentGiven,
          setter: fb.isAvailable
              ? (v) => SettingsActions.persist(
                  'ovid_telemetry_consent',
                  v ? 'yes' : 'no',
                  () => fb.setConsent(v),
                )
              : null,
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
    return SettingsSwitchTile(
      icon: icon,
      title: title,
      subtitleOn: subtitleOn,
      subtitleOff: subtitleOff,
      listenable: AppState.I,
      getter: getter,
      setter: setter,
    );
  }
}

/// Shows the native device-integrity probe (root / hooking / debugger) and a
/// plain-language status. Tapping re-runs the probe.
class _DeviceIntegrityTile extends StatelessWidget {
  const _DeviceIntegrityTile();

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, _) {
        final s = app.deviceSecurity;
        final compromised = app.deviceEnvironmentCompromised;
        final complete = [
          'isRooted',
          'isHookingFrameworkPresent',
          'isDebuggerAttached',
        ].every((key) => s[key] is bool);
        final String detail;
        if (!app.securityChecked) {
          detail = 'Checking device integrity…';
        } else if (!complete) {
          detail =
              'Integrity check unavailable — this device has not supplied a complete probe result.';
        } else if (!compromised) {
          detail = 'OK — no root, hooking framework, or debugger detected';
        } else {
          final flags = <String>[
            if (s['isRooted'] == true) 'rooted',
            if (s['isHookingFrameworkPresent'] == true) 'hooking framework',
            if (s['isDebuggerAttached'] == true) 'debugger attached',
          ];
          detail = 'At risk — ${flags.join(', ')}. Stored keys can be read.';
        }
        return ListTile(
          dense: true,
          leading: Icon(
            !app.securityChecked || !complete
                ? Icons.help_outline
                : compromised
                ? Icons.gpp_maybe_outlined
                : Icons.verified_user_outlined,
            size: 19,
            color: !app.securityChecked || !complete
                ? Aether.textMuted
                : compromised
                ? Aether.warn
                : Aether.success,
          ),
          title: const Text('Device integrity', style: TextStyle(fontSize: 14)),
          subtitle: Text(
            detail,
            style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
          ),
          onTap: () => app.refreshDeviceSecurity(),
        );
      },
    );
  }
}

// ── Static accessors keep the tile declarations const-friendly ──
bool _getMemoryEnabled() => AppState.I.memoryEnabled;
Future<void> _setMemoryEnabled(bool v) => SettingsActions.persist(
  'ovid_memory_enabled',
  v,
  () => AppState.I.setMemoryEnabled(v),
);
bool _getNotificationsEnabled() => AppState.I.notificationsEnabled;
Future<void> _setNotificationsEnabled(bool v) => SettingsActions.persist(
  'ovid_notifications_enabled',
  v,
  () => AppState.I.setNotificationsEnabled(v),
);

bool _getShowReasoning() => AppState.I.showReasoning;
Future<void> _setShowReasoning(bool v) => SettingsActions.persist(
  'ovid_show_reasoning',
  v,
  () => AppState.I.setShowReasoning(v),
);

Future<void> _savePreference(
  BuildContext context,
  String key,
  Object value,
  Future<void> Function() write,
) async {
  try {
    await SettingsActions.persist(key, value, write);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not save preference. It may be session-only; select it again to retry.',
          ),
        ),
      );
    }
  }
}

/// Human-readable byte counts for the Storage screen. Visible for tests.
String formatStorageBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

/// Recursively sums a directory tree. Visible for tests.
Future<int> dirBytes(Directory dir) async {
  var bytes = 0;
  final stack = <Directory>[dir];
  while (stack.isNotEmpty) {
    final d = stack.removeLast();
    try {
      await for (final e in d.list(followLinks: false)) {
        if (e is File) {
          try {
            bytes += await e.length();
          } catch (e) {
            Diag.swallow('settings_screen', e);
          }
        } else if (e is Directory) {
          stack.add(e);
        }
      }
    } catch (e) {
      Diag.swallow('settings_screen', e);
    }
  }
  return bytes;
}

/// Deletes everything inside [dir] but keeps the dir itself. Returns the
/// measured byte difference; throws if cleanup is incomplete. Visible for tests.
Future<int> clearDirContents(Directory dir) async {
  if (!await dir.exists()) return 0;
  final before = await dirBytes(dir);
  await for (final e in dir.list(followLinks: false)) {
    await e.delete(recursive: true);
  }
  final after = await dirBytes(dir);
  if (await dir.list(followLinks: false).isEmpty != true) {
    throw StateError(
      'Some cache entries remain. Retry after active work finishes.',
    );
  }
  return (before - after).clamp(0, before);
}

/// Storage row: opens the breakdown screen instead of just re-measuring.
class _StorageTile extends StatelessWidget {
  const _StorageTile();
  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(Icons.storage_outlined, size: 19, color: Aether.textMuted),
      title: const Text('Storage', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        'Usage by section · clear cache',
        style: TextStyle(fontSize: 12, color: Aether.textFaint),
      ),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const _StorageScreen())),
    );
  }
}

@visibleForTesting
Widget storageScreenForTest() => const _StorageScreen();

/// Per-section on-device storage with working clear actions.
class _StorageScreen extends StatefulWidget {
  const _StorageScreen();
  @override
  State<_StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<_StorageScreen> {
  bool _measuring = true;
  int _docs = 0;
  int _cache = 0;
  int _support = 0;
  bool _clearing = false;
  UserError? _measureError;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _measuring = true);
    try {
      final results = await Future.wait([
        getApplicationDocumentsDirectory().then(dirBytes),
        getTemporaryDirectory().then(dirBytes),
        getApplicationSupportDirectory().then(dirBytes),
      ]);
      if (!mounted) return;
      setState(() {
        _docs = results[0];
        _cache = results[1];
        _support = results[2];
        _measureError = null;
        _measuring = false;
      });
    } catch (e, st) {
      if (!mounted) return;
      // Never present a failed measurement as "0 B": sizes show "—" and the
      // screen offers a retry.
      setState(() {
        _docs = 0;
        _cache = 0;
        _support = 0;
        _measureError = UserError.from(
          e,
          l10n: context.l10n,
          stack: st,
          log: 'settings_screen.storage_measure',
        );
        _measuring = false;
      });
    }
  }

  String _size(int bytes) => _measureError != null
      ? context.l10n.storageSizeUnknown
      : formatStorageBytes(bytes);

  Future<void> _confirmClearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear cache?'),
        content: Text(
          'Frees ${formatStorageBytes(_cache)} of temporary files. '
          'Chats, settings and downloads are untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      final freed = await clearDirContents(await getTemporaryDirectory());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cache cleared · ${formatStorageBytes(freed)} freed.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Cache cleanup incomplete. Some files may remain; retry after active work finishes.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _clearing = false);
        _refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _docs + _cache + _support;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: const Text('Storage')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SectionHeader('On-device usage'),
          if (_measuring)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            if (_measureError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.error_outline, size: 18, color: Aether.dangerC),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              context.l10n.storageMeasureFailed,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _refresh,
                          child: Text(context.l10n.actionRetry),
                        ),
                      ],
                    ),
                    ErrorDetails(detail: _measureError!.detail),
                  ],
                ),
              ),
            ListTile(
              dense: true,
              leading: Icon(
                Icons.chat_bubble_outline,
                size: 19,
                color: Aether.textMuted,
              ),
              title: const Text(
                'Chats & documents',
                style: TextStyle(fontSize: 14),
              ),
              subtitle: Text(
                'Sessions, workspaces, previews · managed by Export data / Delete all data',
                style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
              ),
              trailing: Text(
                _size(_docs),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            ListTile(
              dense: true,
              leading: Icon(
                Icons.cached_outlined,
                size: 19,
                color: Aether.textMuted,
              ),
              title: const Text('Cache', style: TextStyle(fontSize: 14)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Temporary files · safe to clear',
                    style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
                  ),
                  Text(
                    _size(_cache),
                    style: const TextStyle(fontSize: 13),
                  ),
                  TextButton(
                    onPressed: (_clearing || _cache == 0)
                        ? null
                        : _confirmClearCache,
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
            ListTile(
              dense: true,
              leading: Icon(
                Icons.folder_outlined,
                size: 19,
                color: Aether.textMuted,
              ),
              title: const Text(
                'Support files',
                style: TextStyle(fontSize: 14),
              ),
              subtitle: Text(
                'Required by the app (sandbox, keys) · not deletable here',
                style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
              ),
              trailing: Text(
                _size(_support),
                style: const TextStyle(fontSize: 13),
              ),
            ),
            const Divider(height: 24),
            ListTile(
              dense: true,
              title: const Text(
                'Total',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              trailing: Text(
                _size(total),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Share-session-memory toggle — real, persisted in AppState. OFF by default
/// so each chat session stays isolated (its own sandbox workspace + memory).
/// ON lets the AI search across every chat via the memory_search tool.
///
/// Requires Memory: while Memory is off the switch is disabled and every
/// cross-chat path treats sharing as off ([AppState.effectiveShareSessionMemory]).
class _ShareMemoryTile extends StatelessWidget {
  const _ShareMemoryTile();

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, _) {
        final memoryOn = app.memoryEnabled;
        return SettingsSwitchTile(
          key: ValueKey('share-memory-$memoryOn'),
          icon: Icons.psychology_outlined,
          title: 'Share session memory',
          listenable: app,
          subtitleOn:
              'ON — the AI can search across all chats (memory_search).',
          subtitleOff: memoryOn
              ? 'OFF — cross-chat memory search is disabled.'
              : 'Requires Memory — turn Memory on to share it across chats.',
          getter: () => app.effectiveShareSessionMemory,
          setter: memoryOn
              ? (v) => SettingsActions.persist(
                  'ovid_share_session_memory',
                  v,
                  () => app.setShareSessionMemory(v),
                )
              : null,
        );
      },
    );
  }
}

/// Seam over the OS notification permission so the Settings row can be
/// exercised in tests without the platform channel.
class NotificationPermissionAccess {
  NotificationPermissionAccess._();

  static Future<PermissionStatus> Function() status = () =>
      Permission.notification.status;
  static Future<PermissionStatus> Function() request = () =>
      Permission.notification.request();
  static Future<bool> Function() openSettings = openAppSettings;

  @visibleForTesting
  static void reset() {
    status = () => Permission.notification.status;
    request = () => Permission.notification.request();
    openSettings = openAppSettings;
  }
}

/// Notifications switch that reflects the OS permission, not just the
/// preference: turning it ON asks Android for POST_NOTIFICATIONS, and a
/// switch that is ON while Android blocks notifications says so and offers
/// the system settings page as the fix.
class _NotificationsTile extends StatefulWidget {
  const _NotificationsTile();

  @override
  State<_NotificationsTile> createState() => _NotificationsTileState();
}

class _NotificationsTileState extends State<_NotificationsTile>
    with WidgetsBindingObserver {
  PermissionStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the system settings page: pick up the new grant.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    PermissionStatus? st;
    try {
      st = await NotificationPermissionAccess.status();
    } catch (e) {
      Diag.swallow('settings_screen.notifications', e);
    }
    if (mounted) setState(() => _status = st);
  }

  bool get _blocked =>
      _status != null && (_status!.isDenied || _status!.isPermanentlyDenied);

  Future<void> _set(bool v) async {
    if (v) {
      try {
        final st = await NotificationPermissionAccess.request();
        if (mounted) setState(() => _status = st);
      } catch (e) {
        Diag.swallow('settings_screen.notifications', e);
      }
    }
    await _setNotificationsEnabled(v);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppState.I,
      builder: (_, _) {
        final on = AppState.I.notificationsEnabled;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SettingsSwitchTile(
              icon: Icons.notifications_outlined,
              title: 'Notifications',
              subtitleOn: _blocked
                  ? 'ON — but blocked by Android; no notifications will show'
                  : 'ON — status notifications while Ovid works in the background',
              subtitleOff:
                  'OFF — no status notification; background runs may stop',
              getter: _getNotificationsEnabled,
              setter: _set,
            ),
            if (on && _blocked)
              ListTile(
                key: const ValueKey('notifications-blocked'),
                dense: true,
                leading: Icon(
                  Icons.block_outlined,
                  size: 19,
                  color: Aether.warnLight,
                ),
                title: const Text(
                  'Blocked by Android',
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  'Allow notifications for Ovid in system settings.',
                  style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
                ),
                trailing: TextButton(
                  onPressed: () async {
                    try {
                      await NotificationPermissionAccess.openSettings();
                    } catch (e) {
                      Diag.swallow('settings_screen.notifications', e);
                    }
                  },
                  child: const Text('Open settings'),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Theme mode selector — System / Light / Dark (replaces the old toggle).
///
/// Rebuilt on the Aether primitives: the segmented control is now
/// [AetherSegmentedControl] so the three mode pills (Auto / Light / Dark)
/// match the rest of the premium reskin. The underlying persistence call
/// — [AppState.setThemeMode] via [SettingsActions.persist] — is untouched,
/// so toggling still flips [Aether.dark] exactly as before.
class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context) {
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, _) {
        final mode = app.themeMode;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    mode == 'system'
                        ? Icons.brightness_auto_outlined
                        : mode == 'light'
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                    size: 20,
                    color: Aether.textMuted,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Theme', style: AetherType.body),
                        const SizedBox(height: 2),
                        Text(
                          mode == 'system'
                              ? 'Follow system — ${app.lightTheme ? 'currently light' : 'currently dark'}'
                              : mode == 'light'
                              ? 'Light — bright surfaces'
                              : 'Dark (default)',
                          style: AetherType.caption,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                  void change(String v) => _savePreference(
                    context,
                    'ovid_theme_mode',
                    v,
                    () => app.setThemeMode(v),
                  );
                  if (constraints.maxWidth < 250 * scale) {
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in const [
                          ('system', 'Auto'),
                          ('light', 'Light'),
                          ('dark', 'Dark'),
                        ])
                          ChoiceChip(
                            label: Text(option.$2),
                            selected: mode == option.$1,
                            onSelected: (_) => change(option.$1),
                          ),
                      ],
                    );
                  }
                  return AetherSegmentedControl<String>(
                    value: mode,
                    options: const [
                      (value: 'system', label: 'Auto', icon: null),
                      (value: 'light', label: 'Light', icon: null),
                      (value: 'dark', label: 'Dark', icon: null),
                    ],
                    onChanged: change,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TimeoutScreen extends StatefulWidget {
  const _TimeoutScreen();

  @override
  State<_TimeoutScreen> createState() => _TimeoutScreenState();
}

class _TimeoutScreenState extends State<_TimeoutScreen> {
  /// Slider position while dragging. Persisting (SharedPreferences write,
  /// readback and a whole-[AppState] notify) happens once on release, not on
  /// every drag frame.
  double? _draft;

  Future<void> _commitDraft(double v) async {
    final sec = v.round();
    await _savePreference(
      context,
      'ovid_response_timeout_sec',
      sec,
      () => AppState.I.setResponseTimeout(sec),
    );
    if (mounted) setState(() => _draft = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        toolbarHeight:
            kToolbarHeight * (MediaQuery.textScalerOf(context).scale(20) / 20),
        title: const Text('Response wait limit'),
      ),
      body: AnimatedBuilder(
        animation: AppState.I,
        builder: (_, _) {
          final cur = AppState.I.responseTimeoutSec;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'How long to wait for the model to respond (or resume) '
                'before giving up. This is the longest silence allowed — '
                'the first token, or a pause mid-answer — not a cap on the '
                'total length of a reply. Reasoning models can think quietly '
                'for a minute or more before they start.',
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
                  if (v != null) {
                    _savePreference(
                      context,
                      'ovid_response_timeout_sec',
                      v,
                      () => AppState.I.setResponseTimeout(v),
                    );
                  }
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
                  'Custom values: pick any number of seconds between '
                  '${AppState.minResponseTimeoutSec} s and 60 min.',
                  style: TextStyle(fontSize: 11, color: Aether.textFaint),
                ),
              ),
              if (cur < AppState.responseTimeoutWarnBelowSec)
                Padding(
                  key: const ValueKey('timeout-low-warning'),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'Under a minute: reasoning models that think before '
                    'answering may time out on every turn.',
                    style: TextStyle(fontSize: 11.5, color: Aether.warnLight),
                  ),
                ),
              Slider(
                value: (_draft ?? cur.toDouble()).clamp(
                  AppState.minResponseTimeoutSec.toDouble(),
                  AppState.maxResponseTimeoutSec.toDouble(),
                ),
                min: AppState.minResponseTimeoutSec.toDouble(),
                max: AppState.maxResponseTimeoutSec.toDouble(),
                divisions: 119,
                activeColor: Aether.accent,
                inactiveColor: Aether.surfaceAlt,
                label: '${(_draft ?? cur.toDouble()).round()}s',
                onChanged: (v) => setState(() => _draft = v),
                onChangeEnd: _commitDraft,
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

  /// Same labels as the presets: binary sizes (32768) read as "32K",
  /// decimal ones (128000) as "128K".
  static String _kTokens(int tokens) {
    if (tokens % 1000000 == 0) return '${tokens ~/ 1000000}M';
    if (tokens % 1000 == 0) return '${tokens ~/ 1000}K';
    if (tokens % 1024 == 0) return '${tokens ~/ 1024}K';
    return '${(tokens / 1000).toStringAsFixed(0)}K';
  }

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
          // Provider-scoped: the same model id can be a different route (and
          // a different window) on two gateways, so ask the provider that owns
          // this session first.
          final model = s?.model ?? '';
          // Model window (what "Auto" means) vs the window compaction really
          // uses: the override only ever shrinks it (min(override, model)).
          final autoWindow = AgentService.contextWindowFor(
            model,
            s?.providerId,
          );
          final effectiveWindow = s == null
              ? AgentService.effectiveContextWindow(
                  app.contextWindowOverride,
                  autoWindow,
                )
              : AgentService.contextWindowForSession(s);
          final overrideApplies = s == null
              ? app.contextWindowOverride > 0 &&
                    app.contextWindowOverride < autoWindow
              : AgentService.contextOverrideAppliesTo(s);
          final overrideTooBig = app.contextWindowOverride > autoWindow;
          final measuredLimits = ModelLimits.label(model, s?.providerId);
          final limitSource = measuredLimits == null
              ? 'family table / default \u2014 this model published no limits'
              : 'measured for this provider \u2014 $measuredLimits';
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
                  'Current model: ${s?.model ?? '\u2014'}\n'
                  'Model window: ${_kTokens(autoWindow)} tokens\n'
                  'Window used for compaction: '
                  '${_kTokens(effectiveWindow)} tokens '
                  '${overrideApplies ? '(override)' : '(auto)'}\n'
                  'Source: $limitSource'
                  '${overrideTooBig ? '\nYour override is larger than this model\'s window, so the model window is used.' : ''}',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.55,
                    color: Aether.textFaint,
                  ),
                ),
              ),
              RadioGroup<int>(
                groupValue: app.contextWindowOverride,
                onChanged: (v) => _savePreference(
                  context,
                  'ovid_context_window_override',
                  v ?? 0,
                  () => AppState.I.setContextWindowOverride(v ?? 0),
                ),
                child: Column(
                  children: [
                    for (final (v, label) in _windowPresets)
                      RadioListTile<int>(
                        dense: true,
                        activeColor: Aether.accent,
                        // Larger than the current model's window: it could
                        // never apply, so don't offer it as a choice (the
                        // stored value stays selectable to switch away).
                        enabled:
                            v == 0 ||
                            v <= autoWindow ||
                            v == app.contextWindowOverride,
                        title: Text(
                          label,
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: v > 0 && v > autoWindow
                            ? Text(
                                'Larger than this model\'s window',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Aether.textFaint,
                                ),
                              )
                            : null,
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
                onChanged: (v) => _savePreference(
                  context,
                  'ovid_max_output_tokens',
                  v ?? 0,
                  () => AppState.I.setMaxOutputTokens(v ?? 0),
                ),
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

/// About screen — app name, version, developer, website link.
class _AboutScreen extends StatelessWidget {
  const _AboutScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 24),
          Center(child: OvidLockup(markSize: 72, textSize: 30)),
          const SizedBox(height: 20),
          const SizedBox(height: 6),
          Center(
            child: Text(
              'Version $kAppVersion',
              style: TextStyle(
                fontSize: 14,
                color: Aether.textMuted,
                fontFamily: Aether.mono,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'by Dhanuk Softwares',
              style: TextStyle(fontSize: 13, color: Aether.textFaint),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'AI super-app: chat, agents, plugins & MCP.\n'
              'Chat-first. Agent-native. Free by default.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: Aether.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 32),
          _AboutLinkTile(
            icon: Icons.public,
            iconColor: Aether.accent,
            title: 'Website',
            url: LegalLinks.website,
          ),
          _AboutLinkTile(
            icon: Icons.privacy_tip_outlined,
            title: 'Privacy policy',
            url: LegalLinks.privacyPolicy,
          ),
          _AboutLinkTile(
            icon: Icons.gavel_outlined,
            title: 'Terms of Service',
            url: LegalLinks.terms,
          ),
          ListTile(
            leading: Icon(
              Icons.description_outlined,
              size: 20,
              color: Aether.textMuted,
            ),
            title: const Text(
              'Open-source licenses',
              style: TextStyle(fontSize: 14),
            ),
            subtitle: Text(
              'Third-party software used by Ovid AI',
              style: TextStyle(fontSize: 12, color: Aether.textFaint),
            ),
            trailing: Icon(
              Icons.chevron_right,
              size: 18,
              color: Aether.textFaint,
            ),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Ovid AI',
              applicationVersion: kAppVersion,
              applicationLegalese: '© ${DateTime.now().year} Dhanuk Softwares',
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '© ${DateTime.now().year} Dhanuk Softwares',
              style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
            ),
          ),
        ],
      ),
    );
  }
}

/// About-screen row that opens an external page directly, with a copy-link
/// fallback when no browser can handle it.
class _AboutLinkTile extends StatelessWidget {
  const _AboutLinkTile({
    required this.icon,
    required this.title,
    required this.url,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String url;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 20, color: iconColor ?? Aether.textMuted),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        _displayUrl(url),
        style: TextStyle(fontSize: 12, color: Aether.textFaint),
      ),
      trailing: Icon(Icons.open_in_new, size: 16, color: Aether.textFaint),
      onTap: () => openExternalLink(context, url),
    );
  }
}

class _PresetsScreen extends StatefulWidget {
  const _PresetsScreen();

  @override
  State<_PresetsScreen> createState() => _PresetsScreenState();
}

class _PresetsScreenState extends State<_PresetsScreen> {
  /// One key per preset id so a freshly created preset can be scrolled to.
  final Map<String, GlobalKey> _tileKeys = {};

  /// Preset that was just created: rendered expanded and scrolled into view.
  String? _createdId;

  GlobalKey _keyFor(String id) =>
      _tileKeys.putIfAbsent(id, () => GlobalKey(debugLabel: 'preset-$id'));

  Future<void> _duplicate(AgentPreset preset) async {
    final nameController = TextEditingController(
      text: '${preset.label} (Custom)',
    );
    final route = DialogRoute<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: const Text(
          'Duplicate as custom preset',
          style: TextStyle(fontSize: 16),
        ),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Preset name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Duplicate'),
          ),
        ],
      ),
    );
    final ok = await Navigator.of(context, rootNavigator: true).push(route);
    // A popped route still builds its fields during its exit transition (and
    // keyboard inset changes). Release controllers only after overlay removal.
    await route.completed;
    final nameText = nameController.text.trim();
    nameController.dispose();
    if (ok != true) return;
    // The id is generated, never typed: a typed id could shadow a built-in
    // preset (e.g. `standard`) for every session or overwrite another custom.
    final id = PresetRegistry.newCustomId();
    final label = nameText.isEmpty ? '${preset.label} (Custom)' : nameText;
    final newPreset = AgentPreset(
      id: id,
      label: label,
      description: preset.description,
      allowedTools: List.of(preset.allowedTools),
      deniedTools: List.of(preset.deniedTools),
      persona: preset.persona,
      // G3/G5: a duplicate must carry the run pins and the plan policy,
      // otherwise "Duplicate as custom" silently drops half the preset.
      model: preset.model,
      modelProviderId: preset.modelProviderId,
      temperature: preset.temperature,
    );
    await AppState.I.saveCustomPreset(newPreset);
    if (!mounted) return;
    setState(() => _createdId = id);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text("Created '$label'")));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _tileKeys[id]?.currentContext;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 300),
          alignment: 0.1,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Agent Presets'),
      ),
      body: AnimatedBuilder(
        animation: AppState.I,
        builder: (context, _) {
          final customIds = PresetRegistry.customPresets
              .map((e) => e.id)
              .toSet();
          final allPresets = PresetRegistry.all;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Presets control tool permissions and agent personality. '
                  'Duplicate any preset to customize denied tools.',
                  style: TextStyle(fontSize: 12, color: Aether.textFaint),
                ),
              ),
              for (final preset in allPresets)
                _PresetTile(
                  key: _keyFor(preset.id),
                  preset: preset,
                  isCustom: customIds.contains(preset.id),
                  initiallyExpanded: preset.id == _createdId,
                  onDuplicate: () => _duplicate(preset),
                  onDelete: customIds.contains(preset.id)
                      ? () => _confirmDelete(context, preset)
                      : null,
                  onUpdate: (updated) => AppState.I.saveCustomPreset(updated),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, AgentPreset preset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete custom preset?'),
        content: Text(
          'Delete "${preset.label}"? This removes the saved custom preset. '
          'Built-in presets are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete', style: TextStyle(color: Aether.danger)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await AppState.I.deleteCustomPreset(preset.id);
    }
  }
}

class _PresetTile extends StatefulWidget {
  final AgentPreset preset;
  final bool isCustom;
  final VoidCallback onDuplicate;
  final VoidCallback? onDelete;
  final ValueChanged<AgentPreset>? onUpdate;
  final bool initiallyExpanded;

  const _PresetTile({
    super.key,
    required this.preset,
    required this.isCustom,
    required this.onDuplicate,
    this.onDelete,
    this.onUpdate,
    this.initiallyExpanded = false,
  });

  @override
  State<_PresetTile> createState() => _PresetTileState();
}

class _PresetTileState extends State<_PresetTile> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(_PresetTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initiallyExpanded && !oldWidget.initiallyExpanded) {
      _expanded = true;
    }
  }

  Future<void> _pickModel(AgentPreset p) async {
    final picked =
        await showModalBottomSheet<({String providerId, String model})>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => _PresetModelPickerSheet(
            selectedProviderId: p.modelProviderId,
            selectedModel: p.model,
          ),
        );
    if (picked == null) return;
    widget.onUpdate?.call(
      p.copyWith(model: picked.model, modelProviderId: picked.providerId),
    );
  }

  static const _gatedTools = [
    'render_html',
    'generate_image',
    'edit_image',
    'edit_images',
    'resize_image',
    'crop_image',
    'run_shell',
    'run_code',
    'job_start',
    'file_write',
    'fs_edit',
    'dispatch_agent',
    'workflow',
    'ralph',
  ];

  static String _pinLabel(AgentPreset p) {
    final providerId = p.modelProviderId;
    if (providerId == null) return p.model!;
    final name = AppState.I.providerById(providerId)?.name ?? providerId;
    return '$name · ${p.model}';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.preset;
    final isCustom = widget.isCustom;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Aether.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Aether.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Text(
                  p.label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isCustom
                        ? Aether.accent.withValues(alpha: 0.15)
                        : Aether.surfaceRaised,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    isCustom ? 'custom' : 'built-in',
                    style: TextStyle(
                      fontSize: 10,
                      color: isCustom ? Aether.accent : Aether.textFaint,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (p.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    p.description,
                    style: TextStyle(fontSize: 11.5, color: Aether.textMuted),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  p.deniedTools.isEmpty
                      ? 'All tools allowed'
                      : 'Denied tools: ${p.deniedTools.join(", ")}',
                  style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
                ),
                if (p.model != null ||
                    p.temperature != null ||
                    isCustom) ...[
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (p.model != null) 'model: ${p.model}',
                      if (p.temperature != null) 'temp: ${p.temperature}',
                    ].join(' · '),
                    style: TextStyle(fontSize: 10.5, color: Aether.textFaint),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 4,
              children: [
                IconButton(
                  tooltip: 'Duplicate as custom',
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  onPressed: widget.onDuplicate,
                ),
                if (isCustom && widget.onDelete != null)
                  IconButton(
                    tooltip: 'Delete custom preset',
                    icon: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Aether.danger,
                    ),
                    onPressed: widget.onDelete,
                  ),
                if (isCustom)
                  IconButton(
                    tooltip: _expanded
                        ? 'Hide tools'
                        : 'Configure denied tools',
                    icon: Icon(
                      _expanded ? Icons.expand_less : Icons.tune,
                      size: 18,
                      color: Aether.textMuted,
                    ),
                    onPressed: () => setState(() => _expanded = !_expanded),
                  ),
              ],
            ),
          ),
          if (isCustom && _expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Denied tools (checked = blocked for this preset):',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Aether.textMuted,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final tool in _gatedTools)
                    FilterChip(
                      label: Text(tool, style: const TextStyle(fontSize: 11)),
                      selected: p.deniedTools.contains(tool),
                      selectedColor: Aether.danger.withValues(alpha: 0.2),
                      checkmarkColor: Aether.danger,
                      onSelected: (selected) {
                        final currentDenied = List<String>.from(p.deniedTools);
                        if (selected) {
                          if (!currentDenied.contains(tool)) {
                            currentDenied.add(tool);
                          }
                        } else {
                          currentDenied.remove(tool);
                        }
                        final updated = p.copyWith(deniedTools: currentDenied);
                        widget.onUpdate?.call(updated);
                      },
                    ),
                ],
              ),
            ),
            // ── G3: model + temperature pins for this preset's runs ───────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Text(
                "Model pin (this preset's runs):",
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Aether.textMuted,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text(
                      'Session model',
                      style: TextStyle(fontSize: 11),
                    ),
                    selected: p.model == null,
                    onSelected: (_) =>
                        widget.onUpdate?.call(p.copyWith(clearModel: true)),
                  ),
                  if (p.model != null)
                    InputChip(
                      label: Text(
                        _pinLabel(p),
                        style: const TextStyle(fontSize: 11),
                      ),
                      selected: true,
                      onPressed: () => _pickModel(p),
                    ),
                  TextButton.icon(
                    key: const ValueKey('preset-model-pick'),
                    onPressed: () => _pickModel(p),
                    icon: const Icon(Icons.search, size: 16),
                    label: Text(
                      p.model == null ? 'Choose model…' : 'Change…',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Text(
                "Temperature (this preset's runs):",
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Aether.textMuted,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text(
                      'Provider default',
                      style: TextStyle(fontSize: 11),
                    ),
                    selected: p.temperature == null,
                    onSelected: (_) => widget.onUpdate?.call(
                      p.copyWith(clearTemperature: true),
                    ),
                  ),
                  for (final t in const [0.0, 0.2, 0.5, 1.0])
                    ChoiceChip(
                      label: Text(
                        t.toStringAsFixed(1),
                        style: const TextStyle(fontSize: 11),
                      ),
                      selected: p.temperature == t,
                      onSelected: (_) =>
                          widget.onUpdate?.call(p.copyWith(temperature: t)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

/// Searchable model picker for a preset's model pin. Lists every provider's
/// models lazily, grouped by provider, and returns `(providerId, model)` so
/// the same model id on two gateways stays unambiguous.
class _PresetModelPickerSheet extends StatefulWidget {
  const _PresetModelPickerSheet({this.selectedProviderId, this.selectedModel});

  final String? selectedProviderId;
  final String? selectedModel;

  @override
  State<_PresetModelPickerSheet> createState() =>
      _PresetModelPickerSheetState();
}

class _PresetModelPickerSheetState extends State<_PresetModelPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final rows = <Object>[]; // ProviderConfig header or (provider, model)
    for (final provider in AppState.I.providers) {
      final nameHit = provider.name.toLowerCase().contains(q);
      final models = [
        for (final m in provider.models)
          if (q.isEmpty || nameHit || m.toLowerCase().contains(q)) m,
      ];
      if (models.isEmpty) continue;
      rows.add(provider);
      for (final m in models) {
        rows.add((provider: provider, model: m));
      }
    }
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                key: const ValueKey('preset-model-search'),
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search models or providers',
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                        q.isEmpty
                            ? 'No models yet. Add a provider and fetch its models first.'
                            : 'No models match "$_query".',
                        style: TextStyle(color: Aether.textFaint),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final row = rows[i];
                        if (row is ProviderConfig) {
                          return Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Text(
                              row.name.toUpperCase(),
                              style: AetherType.label,
                            ),
                          );
                        }
                        final item =
                            row as ({ProviderConfig provider, String model});
                        final selected =
                            item.model == widget.selectedModel &&
                            (widget.selectedProviderId == null ||
                                widget.selectedProviderId == item.provider.id);
                        return ListTile(
                          dense: true,
                          title: Text(item.model),
                          trailing: selected
                              ? Icon(Icons.check, color: Aether.accent)
                              : null,
                          onTap: () => Navigator.pop(context, (
                            providerId: item.provider.id,
                            model: item.model,
                          )),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ── BYOK escrow (Settings → Models → Bring your own keys) ────────────────
///
/// Write-once keys: the raw value is sent to `POST /byok` and then dropped.
/// The server never projects it back, so this screen can only ever render
/// providerId + endpoint + label + status (there is no fingerprint field in
/// the built P9 schema). Nothing key-shaped is written to SharedPreferences.
class ByokKeysScreen extends StatefulWidget {
  const ByokKeysScreen({super.key});

  @override
  State<ByokKeysScreen> createState() => _ByokKeysScreenState();
}

class _ByokKeysScreenState extends State<ByokKeysScreen> {
  List<ByokKeyDto> _keys = const [];
  bool _loading = true;
  String? _error;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final keys = await ByokClient.I.list();
      if (!mounted) return;
      setState(() {
        _keys = keys;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  Future<void> _add() async {
    final entry = await showDialog<_ByokEntry>(
      context: context,
      builder: (_) => const _ByokAddDialog(),
    );
    if (entry == null || !mounted) return;
    setState(() => _busy.add('add'));
    try {
      await ByokClient.I.upload(
        providerId: entry.providerId,
        endpoint: entry.endpoint,
        apiKey: entry.apiKey,
        label: entry.label,
      );
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save the key: ${friendlyError(e)}'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy.remove('add'));
    }
  }

  Future<void> _remove(ByokKeyDto key) async {
    setState(() => _busy.add(key.id));
    try {
      await ByokClient.I.revoke(key.id);
      if (!mounted) return;
      setState(() => _keys = _keys.where((k) => k.id != key.id).toList());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not remove the key: ${friendlyError(e)}'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(key.id));
    }
  }

  Future<void> _test(ByokKeyDto key) async {
    setState(() => _busy.add(key.id));
    try {
      final result = await ByokClient.I.test(key.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.ok
                ? '${key.providerId} responded successfully.'
                : 'Test failed${result.error == null ? '' : ': ${result.error}'}.',
          ),
        ),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not test the key: ${friendlyError(e)}'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(key.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Bring your own keys'),
        backgroundColor: Aether.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          const AetherSectionTitle(
            eyebrow: 'Escrow',
            subtitle:
                'Keys are encrypted on the server and never shown again. '
                'Ovid Cloud uses them only for the provider endpoint you '
                'register here.',
          ),
          const SizedBox(height: 12),
          if (_error != null)
            AetherCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Could not load keys', style: AetherType.title),
                  const SizedBox(height: 4),
                  Text(_error!, style: AetherType.bodyMuted),
                  const SizedBox(height: 8),
                  AetherSecondaryButton(label: 'Retry', onPressed: _load),
                ],
              ),
            )
          else if (_loading && _keys.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
            )
          else if (_keys.isEmpty)
            AetherCard(
              key: const ValueKey('byok-empty'),
              padding: const EdgeInsets.all(18),
              child: Text('No keys yet', style: AetherType.bodyMuted),
            )
          else
            for (final key in _keys) ...[
              AetherCard(
                key: ValueKey('byok-row-${key.id}'),
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.vpn_key_outlined,
                            size: 18, color: Aether.accent),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            key.providerId,
                            style: AetherType.title,
                          ),
                        ),
                        AetherPill(label: key.status, color: Aether.textMuted),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(key.endpoint, style: AetherType.bodyMuted),
                    if (key.label != null && key.label!.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(key.label!, style: AetherType.bodyMuted),
                    ],
                    const SizedBox(height: 8),
                    OverflowBar(
                      spacing: 8,
                      overflowSpacing: 4,
                      children: [
                        AetherGhostButton(
                          label: _busy.contains(key.id) ? 'Testing…' : 'Test',
                          icon: Icons.bolt_outlined,
                          onPressed: _busy.contains(key.id)
                              ? null
                              : () => _test(key),
                        ),
                        AetherGhostButton(
                          label: 'Remove',
                          icon: Icons.delete_outline,
                          onPressed: _busy.contains(key.id)
                              ? null
                              : () => _remove(key),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
            ],
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy.contains('add') ? null : _add,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add key'),
          ),
        ],
      ),
    );
  }
}

/// Values returned by the add dialog. Deliberately short-lived: the raw key
/// exists only in the controller and the request body.
class _ByokEntry {
  const _ByokEntry({
    required this.providerId,
    required this.endpoint,
    required this.apiKey,
    this.label,
  });

  final String providerId;
  final String endpoint;
  final String apiKey;
  final String? label;
}

class _ByokAddDialog extends StatefulWidget {
  const _ByokAddDialog();

  @override
  State<_ByokAddDialog> createState() => _ByokAddDialogState();
}

class _ByokAddDialogState extends State<_ByokAddDialog> {
  final _provider = TextEditingController();
  final _endpoint = TextEditingController();
  final _apiKey = TextEditingController();
  final _label = TextEditingController();

  @override
  void dispose() {
    _provider.dispose();
    _endpoint.dispose();
    _apiKey.dispose();
    _label.dispose();
    super.dispose();
  }

  void _save() {
    final provider = _provider.text.trim();
    final endpoint = _endpoint.text.trim();
    final apiKey = _apiKey.text.trim();
    if (provider.isEmpty || endpoint.isEmpty || apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Provider, endpoint and key are all required.'),
        ),
      );
      return;
    }
    Navigator.of(context).pop(
      _ByokEntry(
        providerId: provider,
        endpoint: endpoint,
        apiKey: apiKey,
        label: _label.text.trim().isEmpty ? null : _label.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add provider key'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('byok-provider'),
              controller: _provider,
              decoration: const InputDecoration(
                labelText: 'Provider id',
                hintText: 'anthropic',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('byok-endpoint'),
              controller: _endpoint,
              decoration: const InputDecoration(
                labelText: 'Endpoint',
                hintText: 'https://api.anthropic.com/v1',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('byok-api-key'),
              controller: _apiKey,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'API key',
                helperText: 'Sent once · never shown again',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('byok-label'),
              controller: _label,
              decoration: const InputDecoration(
                labelText: 'Label (optional)',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save key'),
        ),
      ],
    );
  }
}
