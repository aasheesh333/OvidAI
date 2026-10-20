import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/app_info.dart';
import '../core/cloud/account_settings_client.dart';
import '../core/diag.dart';
import '../core/distribution.dart';
import '../core/firebase_service.dart';
import '../core/legal_links.dart';
import '../core/native_share.dart';
import '../core/notification_permission.dart';
import '../core/settings_actions.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'auth_screen.dart';
import 'billing_screen.dart';
import 'credentials_vault_screen.dart';
import 'history_import_sheet.dart' show ImportLocalChatsTile;
import 'memory_screen.dart';
import 'profile_avatar.dart';
import 'settings_action_widgets.dart';
import 'settings_backup_screen.dart';
import 'settings_health_screen.dart';
import 'settings_keys_screen.dart';
import 'settings_presets_screen.dart';
import 'settings_responses_screen.dart';
import 'share_actions.dart';
import 'usage_screen.dart';
import 'user_error.dart';
import 'widgets/aether_confirm.dart';
import 'widgets/aether_primitives.dart';
import 'widgets/error_views.dart';
import 'widgets/external_link.dart';
import 'widgets/ovid_mark.dart';

export '../core/notification_permission.dart' show NotificationPermissionAccess;

/// Settings hub (SE-019). Every row works end to end against Ovid Cloud or
/// the device it names (owner rule R4). Groups:
///
///  - Account: profile (sign out, delete account), plan, usage
///  - Chat: theme, show reasoning, memory, shared memory, memory files
///  - Models & keys: your API keys, agent presets, responses
///  - Notifications
///  - Data & privacy: export & import, import from device, telemetry,
///    storage, clear this device, delete account
///  - Help & about: service status, device integrity, share, privacy, about
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: Text(l.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          // ── Account ─────────────────────────────────────────────────
          const _SectionGap(),
          AetherSectionTitle(eyebrow: l.settingsAccount),
          const SizedBox(height: 10),
          AetherCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                const _AccountHeader(),
                _hairline(),
                _NavTile(
                  icon: Icons.workspace_premium_outlined,
                  title: l.settingsPlan,
                  subtitle: l.settingsPlanSubtitle,
                  builder: (_) => const BillingScreen(),
                ),
                _hairline(),
                _NavTile(
                  icon: Icons.bar_chart_rounded,
                  title: l.settingsUsage,
                  subtitle: l.settingsUsageSubtitle,
                  builder: (_) => const UsageScreen(),
                ),
                _hairline(),
                // Wave 6 W4: the cloud browser's saved logins.
                _NavTile(
                  icon: Icons.password_outlined,
                  title: l.credentialsVault,
                  subtitle: l.credentialsVaultSubtitle,
                  builder: (_) => const CredentialsVaultScreen(),
                ),
              ],
            ),
          ),

          // ── Chat ────────────────────────────────────────────────────
          const _SectionGap(),
          AetherSectionTitle(eyebrow: l.settingsChat),
          const SizedBox(height: 10),
          AetherCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                const _ThemeToggle(),
                _hairline(),
                _SettingsSwitchTile(
                  icon: Icons.auto_awesome,
                  title: l.settingsShowReasoning,
                  subtitleOn: l.settingsShowReasoningOn,
                  subtitleOff: l.settingsShowReasoningOff,
                  getter: _getShowReasoning,
                  setter: _setShowReasoning,
                ),
                _hairline(),
                _SettingsSwitchTile(
                  icon: Icons.psychology_outlined,
                  title: l.settingsMemory,
                  subtitleOn: l.settingsMemoryOn,
                  subtitleOff: l.settingsMemoryOff,
                  getter: _getMemoryEnabled,
                  setter: _setMemoryEnabled,
                ),
                _hairline(),
                const _ShareMemoryTile(),
                _hairline(),
                _NavTile(
                  icon: Icons.description_outlined,
                  title: l.settingsMemoryFiles,
                  subtitle: l.settingsMemoryFilesSubtitle,
                  builder: (_) => const MemoryScreen(),
                ),
              ],
            ),
          ),

          // ── Models & keys ───────────────────────────────────────────
          const _SectionGap(),
          AetherSectionTitle(eyebrow: l.settingsModels),
          const SizedBox(height: 10),
          AetherCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                if (Distribution.cloudByok) ...[
                  _NavTile(
                    icon: Icons.vpn_key_outlined,
                    title: l.keysTitle,
                    subtitle: l.settingsKeysSubtitle,
                    builder: (_) => const KeysScreen(),
                  ),
                  _hairline(),
                ],
                _NavTile(
                  icon: Icons.tune_outlined,
                  title: l.presetsTitle,
                  subtitle: l.settingsPresetsSubtitle,
                  builder: (_) => const PresetsScreen(),
                ),
                _hairline(),
                _NavTile(
                  icon: Icons.short_text_rounded,
                  title: l.responsesTitle,
                  subtitle: l.settingsResponsesSubtitle,
                  builder: (_) => const ResponsesScreen(),
                ),
              ],
            ),
          ),

          // ── Notifications ───────────────────────────────────────────
          const _SectionGap(),
          AetherSectionTitle(eyebrow: l.settingsNotifications),
          const SizedBox(height: 10),
          const AetherCard(
            padding: EdgeInsets.zero,
            child: _NotificationsTile(),
          ),

          // ── Data & privacy ──────────────────────────────────────────
          const _SectionGap(),
          AetherSectionTitle(eyebrow: l.settingsData),
          const SizedBox(height: 10),
          AetherCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _NavTile(
                  icon: Icons.import_export_rounded,
                  title: l.settingsExport,
                  subtitle: l.settingsExportSubtitle,
                  builder: (_) => const SettingsBackupScreen(),
                ),
                // Reopens the history import after "Not now" (SE-015); only
                // shown while device-only chats exist.
                const ImportLocalChatsTile(),
                _hairline(),
                const _TelemetryTile(),
                _hairline(),
                _NavTile(
                  icon: Icons.storage_outlined,
                  title: l.settingsStorage,
                  subtitle: l.settingsStorageSubtitle,
                  builder: (_) => const _StorageScreen(),
                ),
                _hairline(),
                _NavTile(
                  icon: Icons.phonelink_erase_outlined,
                  title: l.settingsClearDevice,
                  subtitle: SettingsActions.resetAll == null
                      ? l.settingsUnavailable
                      : l.settingsClearDeviceSubtitle,
                  builder: (context) => SettingsResetScreen(
                    onExport: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsBackupScreen(),
                      ),
                    ),
                    onDeleteAccount: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AuthScreen(),
                      ),
                    ),
                  ),
                ),
                _hairline(),
                _NavTile(
                  icon: Icons.person_remove_outlined,
                  title: l.settingsDeleteAccount,
                  subtitle: l.settingsDeleteAccountSubtitle,
                  builder: (_) => const AuthScreen(),
                ),
              ],
            ),
          ),

          // ── Help & about ────────────────────────────────────────────
          const _SectionGap(),
          AetherSectionTitle(eyebrow: l.settingsHelp),
          const SizedBox(height: 10),
          AetherCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _NavTile(
                  icon: Icons.monitor_heart_outlined,
                  title: l.statusTitle,
                  subtitle: l.settingsStatusSubtitle,
                  builder: (_) => const SettingsHealthScreen(),
                ),
                _hairline(),
                const _DeviceIntegrityTile(),
                _hairline(),
                ListTile(
                  leading: Icon(
                    Icons.share_outlined,
                    size: 20,
                    color: Aether.textMuted,
                  ),
                  title: Text(l.settingsShare),
                  subtitle: Text(_displayUrl(LegalLinks.website)),
                  onTap: () => showNativeShare(context, NativeShare.app),
                ),
                _hairline(),
                _LinkTile(
                  icon: Icons.privacy_tip_outlined,
                  title: l.settingsPrivacy,
                  url: LegalLinks.privacyPolicy,
                ),
                _hairline(),
                _NavTile(
                  icon: Icons.info_outline,
                  title: l.settingsAbout,
                  subtitle: l.settingsAboutSubtitle(kAppVersion),
                  builder: (_) => const _AboutScreen(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _hairline() => Divider(height: 1, thickness: 1, color: Aether.hairline);

/// `https://host/path` → `host/path` for row subtitles.
String _displayUrl(String url) =>
    url.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'/$'), '');

class _SectionGap extends StatelessWidget {
  const _SectionGap();
  @override
  Widget build(BuildContext context) => const SizedBox(height: 24);
}

/// One tap target per row (SE-019): the whole row pushes [builder].
class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        leading: Icon(icon, size: 20, color: Aether.textMuted),
        title: Text(title, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
        ),
        trailing: Icon(Icons.chevron_right, size: 18, color: Aether.textFaint),
        onTap: () =>
            Navigator.of(context).push(MaterialPageRoute(builder: builder)),
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.icon, required this.title, required this.url});
  final IconData icon;
  final String title;
  final String url;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 20, color: Aether.textMuted),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        _displayUrl(url),
        style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      trailing: Icon(Icons.open_in_new, size: 16, color: Aether.textFaint),
      onTap: () => openExternalLink(context, url),
    );
  }
}

class _AccountHeader extends StatelessWidget {
  const _AccountHeader();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
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
                        signedIn ? fb.accountLabel : l.settingsYou,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        signedIn ? fb.accountDetail : l.settingsSignInPrompt,
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
}

/// Telemetry consent toggle bound to FirebaseService (SE-030 copy).
class _TelemetryTile extends StatelessWidget {
  const _TelemetryTile();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AnimatedBuilder(
      animation: FirebaseService.I,
      builder: (_, _) {
        final fb = FirebaseService.I;
        return SettingsSwitchTile(
          icon: Icons.insights_outlined,
          title: l.settingsTelemetry,
          listenable: fb,
          subtitleOn: fb.isAvailable
              ? l.settingsTelemetryOn
              : l.settingsTelemetryUnavailable,
          subtitleOff: fb.isAvailable
              ? l.settingsTelemetryOff
              : l.settingsTelemetryUnavailable,
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

/// Persisted AppState toggle.
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

/// Device integrity (SE-031 / EM-018): honest about what the basic probe can
/// tell — an emulator cannot vouch for itself, and a clean result is "no
/// signs of", never "OK". Tapping re-runs the probe and confirms.
class _DeviceIntegrityTile extends StatelessWidget {
  const _DeviceIntegrityTile();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, _) {
        final s = app.deviceSecurity;
        final compromised = app.deviceEnvironmentCompromised;
        final emulator = s['isEmulator'] == true;
        final complete = [
          'isRooted',
          'isHookingFrameworkPresent',
          'isDebuggerAttached',
        ].every((key) => s[key] is bool);
        final String detail;
        final bool warn;
        if (!app.securityChecked) {
          detail = l.integrityChecking;
          warn = false;
        } else if (!complete) {
          detail = l.integrityUnavailable;
          warn = false;
        } else if (compromised) {
          final flags = <String>[
            if (s['isRooted'] == true) l.integrityFlagRooted,
            if (s['isHookingFrameworkPresent'] == true) l.integrityFlagHooking,
            if (s['isDebuggerAttached'] == true) l.integrityFlagDebugger,
          ];
          detail = l.integrityAtRisk(flags.join(', '));
          warn = true;
        } else if (emulator) {
          detail = l.integrityEmulator;
          warn = true;
        } else {
          detail = l.integrityClean;
          warn = false;
        }
        return ListTile(
          key: const ValueKey('device-integrity'),
          leading: Icon(
            !app.securityChecked || !complete
                ? Icons.help_outline
                : warn
                ? Icons.gpp_maybe_outlined
                : Icons.verified_user_outlined,
            size: 20,
            color: !app.securityChecked || !complete
                ? Aether.textMuted
                : warn
                ? Aether.warn
                : Aether.success,
          ),
          title: Text(l.integrityTitle, style: const TextStyle(fontSize: 14)),
          subtitle: Text(
            detail,
            style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
          ),
          onTap: () async {
            await app.refreshDeviceSecurity();
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(SnackBar(content: Text(l.integrityRechecked)));
            }
          },
        );
      },
    );
  }
}

bool _getMemoryEnabled() => AppState.I.memoryEnabled;
Future<void> _setMemoryEnabled(bool v) => SettingsActions.persist(
  'ovid_memory_enabled',
  v,
  () => AppState.I.setMemoryEnabled(v),
);

bool _getShowReasoning() => AppState.I.showReasoning;
Future<void> _setShowReasoning(bool v) => SettingsActions.persist(
  'ovid_show_reasoning',
  v,
  () => AppState.I.setShowReasoning(v),
);

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

@visibleForTesting
Widget storageScreenForTest() => const _StorageScreen();

/// On-device storage (SE-024): trailing sizes, one clear-cache button, and
/// copy that matches the thin client (an offline chat cache, not workspaces).
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
    final l = context.l10n;
    final ok = await showAetherConfirmDialog(
      context,
      title: l.storageClearTitle,
      message: l.storageClearBody(formatStorageBytes(_cache)),
      confirmLabel: l.storageClearConfirm,
      cancelLabel: l.actionCancel,
      destructive: false,
    );
    if (!ok || !mounted) return;
    setState(() => _clearing = true);
    try {
      final freed = await clearDirContents(await getTemporaryDirectory());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.storageCleared(formatStorageBytes(freed)))),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.storageClearIncomplete)));
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
    await _refresh();
  }

  Widget _row(IconData icon, String title, String subtitle, int bytes) {
    return ListTile(
      leading: Icon(icon, size: 20, color: Aether.textMuted),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
      ),
      trailing: Text(_size(bytes), style: const TextStyle(fontSize: 13)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final total = _docs + _cache + _support;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(l.settingsStorage),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          AetherSectionTitle(
            eyebrow: l.storageOnDevice,
            subtitle: l.storageIntro,
          ),
          const SizedBox(height: 8),
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
                        Icon(
                          Icons.error_outline,
                          size: 18,
                          color: Aether.dangerC,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              l.storageMeasureFailed,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _refresh,
                          child: Text(l.actionRetry),
                        ),
                      ],
                    ),
                    ErrorDetails(detail: _measureError!.detail),
                  ],
                ),
              ),
            AetherCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _row(
                    Icons.chat_bubble_outline,
                    l.storageChats,
                    l.storageChatsSubtitle,
                    _docs,
                  ),
                  _row(
                    Icons.cached_outlined,
                    l.storageCache,
                    l.storageCacheSubtitle,
                    _cache,
                  ),
                  _row(
                    Icons.folder_outlined,
                    l.storageApp,
                    l.storageAppSubtitle,
                    _support,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    title: Text(
                      l.storageTotal,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
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
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              key: const ValueKey('storage-clear-cache'),
              onPressed: (_clearing || _cache == 0 || _measureError != null)
                  ? null
                  : _confirmClearCache,
              icon: const Icon(Icons.cleaning_services_outlined, size: 18),
              label: Text(l.storageClearConfirm),
            ),
          ],
        ],
      ),
    );
  }
}

/// Share session memory — persisted, enforced server-side (Wave 1a). Off by
/// default so each chat stays isolated; requires Memory.
class _ShareMemoryTile extends StatelessWidget {
  const _ShareMemoryTile();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final app = AppState.I;
    return AnimatedBuilder(
      animation: app,
      builder: (_, _) {
        final memoryOn = app.memoryEnabled;
        return SettingsSwitchTile(
          key: ValueKey('share-memory-$memoryOn'),
          icon: Icons.hub_outlined,
          title: l.settingsShareMemory,
          listenable: app,
          subtitleOn: l.settingsShareMemoryOn,
          subtitleOff: memoryOn
              ? l.settingsShareMemoryOff
              : l.settingsShareMemoryNeedsMemory,
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

/// Test seam for the server push preference.
@visibleForTesting
Future<void> Function(bool enabled)? setCloudNotificationsForTest;

/// Notifications (SE-010): the switch controls Ovid Cloud push for this
/// account (`PATCH /settings notificationsEnabled`) — off means the server
/// sends nothing to any of your devices. It also reflects Android's
/// permission: turning it on asks for it, and a blocked permission is shown
/// with a way to fix it.
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
    _syncFromCloud();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  /// The server is the source of truth (another device may have changed it).
  Future<void> _syncFromCloud() async {
    if (setCloudNotificationsForTest != null) return;
    try {
      final s = await AccountSettingsClient.I.getSettings();
      if (s.notificationsEnabled != AppState.I.notificationsEnabled) {
        await AppState.I.setNotificationsEnabled(s.notificationsEnabled);
      }
    } catch (e) {
      Diag.swallow('settings_screen.notifications', e);
    }
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
    final cloud =
        setCloudNotificationsForTest ??
        (bool on) => AccountSettingsClient.I.setNotificationsEnabled(on);
    // Server first: if it fails the switch stays put and says so.
    await cloud(v);
    await SettingsActions.persist(
      'ovid_notifications_enabled',
      v,
      () => AppState.I.setNotificationsEnabled(v),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AnimatedBuilder(
      animation: AppState.I,
      builder: (_, _) {
        final on = AppState.I.notificationsEnabled;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SettingsSwitchTile(
              icon: Icons.notifications_outlined,
              title: l.settingsNotifications,
              subtitleOn: _blocked
                  ? l.notificationsOnBlocked
                  : l.notificationsOn,
              subtitleOff: l.notificationsOff,
              getter: () => AppState.I.notificationsEnabled,
              setter: _set,
            ),
            if (on && _blocked)
              ListTile(
                key: const ValueKey('notifications-blocked'),
                leading: Icon(
                  Icons.block_outlined,
                  size: 20,
                  color: Aether.warnLight,
                ),
                title: Text(
                  l.notificationsBlockedTitle,
                  style: const TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  l.notificationsBlockedBody,
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
                  child: Text(l.notificationsOpenSettings),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Theme mode selector — Auto (default, follows the OS) / Light / Dark.
class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  Future<void> _save(BuildContext context, AppState app, String v) async {
    try {
      await SettingsActions.persist(
        'ovid_theme_mode',
        v,
        () => app.setThemeMode(v),
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.settingsSaveFailed)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
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
                        Text(l.themeTitle, style: AetherType.body),
                        const SizedBox(height: 2),
                        Text(
                          mode == 'system'
                              ? (app.lightTheme
                                    ? l.themeAutoLight
                                    : l.themeAutoDark)
                              : mode == 'light'
                              ? l.themeLight
                              : l.themeDark,
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
                  final options = [
                    ('system', l.themeOptionAuto),
                    ('light', l.themeOptionLight),
                    ('dark', l.themeOptionDark),
                  ];
                  if (constraints.maxWidth < 250 * scale) {
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in options)
                          ChoiceChip(
                            label: Text(option.$2),
                            selected: mode == option.$1,
                            onSelected: (_) => _save(context, app, option.$1),
                          ),
                      ],
                    );
                  }
                  return AetherSegmentedControl<String>(
                    value: mode,
                    options: [
                      for (final option in options)
                        (value: option.$1, label: option.$2, icon: null),
                    ],
                    onChanged: (v) => _save(context, app, v),
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

/// About — name, version (with build), maker, links.
class _AboutScreen extends StatelessWidget {
  const _AboutScreen();

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final year = DateTime.now().year;
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(leading: const BackButton(), title: Text(l.settingsAbout)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 24),
          Center(child: OvidLockup(markSize: 72, textSize: 30)),
          const SizedBox(height: 20),
          Center(
            child: Text(
              l.aboutVersion(kAppVersionLabel),
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
              l.aboutMaker,
              style: TextStyle(fontSize: 13, color: Aether.textFaint),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              l.aboutTagline,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: Aether.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 32),
          _LinkTile(
            icon: Icons.public,
            title: l.aboutWebsite,
            url: LegalLinks.website,
          ),
          _LinkTile(
            icon: Icons.privacy_tip_outlined,
            title: l.settingsPrivacy,
            url: LegalLinks.privacyPolicy,
          ),
          _LinkTile(
            icon: Icons.gavel_outlined,
            title: l.aboutTerms,
            url: LegalLinks.terms,
          ),
          ListTile(
            leading: Icon(
              Icons.description_outlined,
              size: 20,
              color: Aether.textMuted,
            ),
            title: Text(l.aboutLicenses, style: const TextStyle(fontSize: 14)),
            subtitle: Text(
              l.aboutLicensesSubtitle,
              style: TextStyle(fontSize: 12, color: Aether.textFaint),
            ),
            trailing: Icon(
              Icons.chevron_right,
              size: 18,
              color: Aether.textFaint,
            ),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Ovid Si',
              applicationVersion: kAppVersionLabel,
              applicationLegalese: l.aboutCopyright(year),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              l.aboutCopyright(year),
              style: TextStyle(fontSize: 11.5, color: Aether.textFaint),
            ),
          ),
        ],
      ),
    );
  }
}
