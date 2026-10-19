import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_info.dart';
import '../core/cloud/account_settings_client.dart';
import '../core/cloud/cloud_rest.dart';
import '../core/cloud/push_service.dart';
import '../core/diag.dart';
import '../core/distribution.dart';
import '../core/firebase_service.dart';
import '../core/theme.dart';
import '../l10n/l10n.dart';
import 'widgets/aether_primitives.dart';

/// One row's verdict.
enum StatusLevel { ok, warn, down, checking }

/// Injectable checks (tests replace them; production uses the live clients).
class ServiceStatusProbes {
  const ServiceStatusProbes({
    required this.server,
    required this.account,
    required this.live,
    required this.signedIn,
    required this.pushRegistered,
  });

  /// Production probes.
  factory ServiceStatusProbes.live() => ServiceStatusProbes(
    server: () => AccountSettingsClient.I.serviceStatus(),
    account: () async {
      await CloudRestClient.I.listSessions(limit: 1);
    },
    live: () async {
      await CloudRestClient.I.mintTicket();
    },
    signedIn: () => FirebaseService.I.isSignedIn,
    pushRegistered: () => PushService.I.boundUid != null,
  );

  final Future<ServiceStatus> Function() server;

  /// Authenticated read: sign-in token and app attestation accepted.
  final Future<void> Function() account;

  /// Live-updates ticket: the realtime channel would open.
  final Future<void> Function() live;
  final bool Function() signedIn;
  final bool Function() pushRegistered;
}

/// SE-013 / SE-014 / EM-014 — "Service status": a proper screen (Scaffold,
/// app bar, back) that checks what actually makes chats work: Ovid Cloud's
/// storage, run queue, agent workers and models (public `/health/status`),
/// plus this device's sign-in, live updates and notifications. Errors are
/// shown in plain words; "Copy diagnostics" copies a scrubbed report for
/// support.
class SettingsHealthScreen extends StatefulWidget {
  const SettingsHealthScreen({super.key, this.probes});

  final ServiceStatusProbes? probes;

  @override
  State<SettingsHealthScreen> createState() => _SettingsHealthScreenState();
}

class _SettingsHealthScreenState extends State<SettingsHealthScreen> {
  late final ServiceStatusProbes _probes =
      widget.probes ?? ServiceStatusProbes.live();

  ServiceStatus? _server;
  bool _serverFailed = false;
  StatusLevel _account = StatusLevel.checking;
  StatusLevel _live = StatusLevel.checking;
  bool _loading = true;
  DateTime? _checkedAt;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<StatusLevel> _run(Future<void> Function() probe) async {
    try {
      await probe();
      return StatusLevel.ok;
    } catch (e) {
      Diag.swallow('service_status', e);
      return StatusLevel.down;
    }
  }

  Future<void> _check() async {
    setState(() => _loading = true);
    final signedIn = _probes.signedIn();
    final results = await Future.wait<Object?>([
      _probes.server().then<Object?>((s) => s, onError: (Object e) {
        Diag.swallow('service_status', e);
        return null;
      }),
      signedIn ? _run(_probes.account) : Future.value(StatusLevel.warn),
      signedIn ? _run(_probes.live) : Future.value(StatusLevel.warn),
    ]);
    if (!mounted) return;
    setState(() {
      _server = results[0] as ServiceStatus?;
      _serverFailed = results[0] == null;
      _account = results[1]! as StatusLevel;
      _live = results[2]! as StatusLevel;
      _loading = false;
      _checkedAt = DateTime.now();
    });
  }

  static StatusLevel _level(ServiceCheck c) => switch (c) {
    ServiceCheck.ok => StatusLevel.ok,
    ServiceCheck.degraded || ServiceCheck.unknown => StatusLevel.warn,
    ServiceCheck.down => StatusLevel.down,
  };

  String _headline(AppLocalizations l) {
    if (_loading) return l.statusChecking;
    if (_serverFailed) return l.statusUnreachable;
    final rows = [
      _level(_server!.overall),
      _account,
      _live,
    ];
    if (rows.contains(StatusLevel.down)) return l.statusProblem;
    if (rows.contains(StatusLevel.warn)) return l.statusPartial;
    return l.statusAllGood;
  }

  Future<void> _copyDiagnostics() async {
    final l = context.l10n;
    final s = _server;
    final lines = <String>[
      'Ovid Si $kAppVersionLabel',
      'Distribution: ${Distribution.play ? 'play' : 'sideload'}',
      'Checked: ${_checkedAt?.toUtc().toIso8601String() ?? '-'}',
      if (s != null)
        'Cloud: ${s.overall.name} storage=${s.storage.name} queue=${s.queue.name} '
            'agents=${s.agents.name} models=${s.models.name}'
      else
        'Cloud: unreachable',
      'Account: ${_account.name} Live: ${_live.name} '
          'Push: ${_probes.pushRegistered() ? 'registered' : 'not registered'}',
      'Recent issues:',
      for (final d in Diag.recent().reversed.take(20))
        '  ${d.at.toUtc().toIso8601String()} ${d.context}: ${_scrub(d.error)}',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.statusDiagnosticsCopied)));
    }
  }

  /// Drops anything token- or address-shaped before it leaves the device.
  static String _scrub(String text) {
    var t = text.replaceAll(RegExp(r'[A-Za-z0-9_\-]{24,}'), '<redacted>');
    t = t.replaceAll(RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+'), '<email>');
    return t.length > 200 ? '${t.substring(0, 200)}…' : t;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final s = _server;
    StatusLevel serverRow(ServiceCheck Function(ServiceStatus) pick) =>
        _loading
            ? StatusLevel.checking
            : s == null
            ? StatusLevel.down
            : _level(pick(s));
    return Scaffold(
      backgroundColor: Aether.bg,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(l.statusTitle),
        actions: [
          IconButton(
            tooltip: l.statusRecheck,
            onPressed: _loading ? null : _check,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            Semantics(
              liveRegion: true,
              child: Text(_headline(l), style: AetherType.title),
            ),
            const SizedBox(height: 16),
            AetherSectionTitle(eyebrow: l.statusCloudSection),
            const SizedBox(height: 8),
            AetherCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _row(l.statusStorage, serverRow((x) => x.storage)),
                  _row(l.statusQueue, serverRow((x) => x.queue)),
                  _row(l.statusAgents, serverRow((x) => x.agents)),
                  _row(l.statusModels, serverRow((x) => x.models)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            AetherSectionTitle(eyebrow: l.statusDeviceSection),
            const SizedBox(height: 8),
            AetherCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _row(
                    l.statusAccount,
                    _loading ? StatusLevel.checking : _account,
                    detail: _account == StatusLevel.warn
                        ? l.statusSignedOut
                        : null,
                  ),
                  _row(l.statusLive, _loading ? StatusLevel.checking : _live),
                  _row(
                    l.statusPush,
                    _probes.pushRegistered() ? StatusLevel.ok : StatusLevel.warn,
                    detail: _probes.pushRegistered()
                        ? null
                        : l.statusPushOff,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            AetherCard(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.statusVersion(kAppVersionLabel),
                    style: AetherType.bodyMuted,
                  ),
                  const SizedBox(height: 10),
                  AetherSecondaryButton(
                    label: l.statusCopyDiagnostics,
                    onPressed: _copyDiagnostics,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String title, StatusLevel level, {String? detail}) {
    final l = context.l10n;
    final (icon, color, label) = switch (level) {
      StatusLevel.ok => (Icons.check_circle_outline, Aether.success, l.statusOk),
      StatusLevel.warn => (Icons.error_outline, Aether.warn, l.statusWarn),
      StatusLevel.down => (Icons.cancel_outlined, Aether.dangerC, l.statusDown),
      StatusLevel.checking => (
        Icons.hourglass_empty,
        Aether.textMuted,
        l.statusChecking,
      ),
    };
    return ListTile(
      leading: Icon(icon, color: color, size: 20),
      title: Text(title),
      subtitle: detail == null ? null : Text(detail),
      trailing: Text(label, style: TextStyle(color: color, fontSize: 13)),
    );
  }
}
