import 'package:flutter/material.dart';

import '../core/app_info.dart';
import '../core/cloud/cloud_rest.dart';
import '../core/cloud/models.dart';
import '../core/distribution.dart';
import '../core/theme.dart';
import 'widgets/aether_primitives.dart';

/// Cloud-backed device health.
///
/// The on-device runtime probes (Termux/proot, dpkg, MCP, plugin install)
/// were removed with the local execution stack in P8 Task 13. The only
/// health surface the thin client has is the gateway's public
/// `GET /cloud/v1/health`, whose built body is `{status, checks:{db, redisQ}}`
/// (both the 200-ok and 503-degraded variants carry the same shape). This
/// screen renders that body plus static app/version information.
class SettingsHealthScreen extends StatefulWidget {
  /// Test seam; defaults to the process-wide [CloudRestClient.I].
  final CloudRestClient? rest;

  const SettingsHealthScreen({super.key, this.rest});

  @override
  State<SettingsHealthScreen> createState() => _SettingsHealthScreenState();
}

class _SettingsHealthScreenState extends State<SettingsHealthScreen> {
  late final CloudRestClient _rest = widget.rest ?? CloudRestClient.I;

  CloudHealth? _health;
  CloudApiException? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final health = await _rest.health();
      if (!mounted) return;
      setState(() {
        _health = health;
        _loading = false;
      });
    } on CloudApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = CloudApiException(
          status: 0,
          code: 'internal',
          message: 'Could not reach Ovid Cloud. $e',
        );
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.space5,
        AetherSpacing.space4,
        AetherSpacing.space5,
        AetherSpacing.space8,
      ),
      children: [
        AetherSectionTitle(
          eyebrow: 'Health',
          subtitle: 'Ovid Cloud service status.',
        ),
        const SizedBox(height: AetherSpacing.space4),
        AetherCard(
          title: const Text('Cloud status'),
          // The refresh control NEVER disappears behind a spinner: a hung
          // check used to replace the only retry affordance with an endless
          // loader. The button stays enabled while busy (a re-tap just
          // restarts _check); the busy indicator lives in the body status
          // line below.
          trailing: IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _check,
          ),
          child: _body(),
        ),
        const SizedBox(height: AetherSpacing.space4),
        const _AppInfoCard(),
      ],
    );
  }

  Widget _body() {
    if (_loading && _health == null) {
      return _busyLine('Checking Ovid Cloud…');
    }
    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A refresh over stale data keeps the last answer on screen with
          // the busy line above it.
          if (_loading) ...[
            _busyLine('Checking Ovid Cloud…'),
            const SizedBox(height: AetherSpacing.space4),
          ],
          Row(
            children: [
              AetherStatusDot(color: Aether.danger),
              const SizedBox(width: AetherSpacing.space2),
              Text(
                'Unreachable',
                style: AetherType.title.copyWith(color: Aether.danger),
              ),
            ],
          ),
          const SizedBox(height: AetherSpacing.space2),
          Text(_error!.message, style: AetherType.bodyMuted),
          const SizedBox(height: AetherSpacing.space3),
          AetherSecondaryButton(label: 'Retry', onPressed: _check),
        ],
      );
    }
    final health = _health!;
    final degraded = health.status != 'ok';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A refresh over a healthy answer also keeps the stale body visible
        // under the busy line.
        if (_loading) ...[
          _busyLine('Checking Ovid Cloud…'),
          const SizedBox(height: AetherSpacing.space4),
        ],
        Row(
          children: [
            AetherStatusDot(
              color: degraded ? Aether.warn : Aether.success,
            ),
            const SizedBox(width: AetherSpacing.space2),
            Text(
              degraded ? 'Degraded' : 'All systems operational',
              style: AetherType.title.copyWith(
                color: degraded ? Aether.warn : Aether.success,
              ),
            ),
          ],
        ),
        if (degraded) ...[
          const SizedBox(height: AetherSpacing.space1),
          Text(
            'Some cloud services are degraded. Runs may be delayed.',
            style: AetherType.bodyMuted,
          ),
        ],
        const SizedBox(height: AetherSpacing.space4),
        _CheckRow(
          label: 'Database',
          ok: health.checks.db,
        ),
        const SizedBox(height: AetherSpacing.space2),
        _CheckRow(
          label: 'Redis queue',
          ok: health.checks.redisQ,
        ),
      ],
    );
  }

  /// The trailing status line that owns the busy spinner (the card header's
  /// refresh button never yields its spot to it).
  Widget _busyLine(String label) => Row(
    children: [
      const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      const SizedBox(width: AetherSpacing.space2),
      Expanded(child: Text(label, style: AetherType.bodyMuted)),
    ],
  );
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AetherStatusDot(color: ok ? Aether.success : Aether.danger, size: 7),
        const SizedBox(width: AetherSpacing.space2),
        Expanded(child: Text(label, style: AetherType.body)),
        Text(
          ok ? 'Operational' : 'Unavailable',
          style: AetherType.caption.copyWith(
            color: ok ? Aether.textMuted : Aether.danger,
          ),
        ),
      ],
    );
  }
}

class _AppInfoCard extends StatelessWidget {
  const _AppInfoCard();

  @override
  Widget build(BuildContext context) {
    return AetherCard(
      title: const Text('App'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(label: 'Version', value: kAppVersion),
          const SizedBox(height: AetherSpacing.space2),
          _InfoRow(
            label: 'Channel',
            value: Distribution.play ? 'Google Play' : 'Sideload',
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: AetherType.bodyMuted)),
        Text(value, style: AetherType.body),
      ],
    );
  }
}
