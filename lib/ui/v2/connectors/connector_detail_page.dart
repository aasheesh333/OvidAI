import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2ConnectorDetailStatus { loading, content, error }

/// One permission the connector may use. `granted` is the live switch state.
@immutable
class V2ConnectorPermission {
  const V2ConnectorPermission({
    required this.id,
    required this.name,
    required this.description,
    this.granted = true,
  });

  final String id;
  final String name;
  final String description;
  final bool granted;
}

/// An agent that can use this connector.
@immutable
class V2ConnectorAgent {
  const V2ConnectorAgent({
    required this.id,
    required this.name,
    required this.description,
    required this.accessLabel,
    this.fullAccess = false,
  });

  final String id;
  final String name;
  final String description;
  final String accessLabel;
  final bool fullAccess;
}

/// How much of the connector's allowance the person has used.
@immutable
class V2ConnectorUsage {
  const V2ConnectorUsage({
    required this.calls,
    required this.limit,
    this.periodLabel = 'this week',
    this.resetLabel = '',
  });

  final int calls;
  final int limit;
  final String periodLabel;
  final String resetLabel;

  double get fraction => limit <= 0 ? 0 : (calls / limit).clamp(0.0, 1.0);
}

/// One thing Ovid did with the connector.
@immutable
class V2ConnectorActivity {
  const V2ConnectorActivity({
    required this.id,
    required this.title,
    this.detail = '',
    this.timeLabel = '',
    this.ok = true,
  });

  final String id;
  final String title;
  final String detail;
  final String timeLabel;
  final bool ok;
}

/// Immutable detail model for one connector.
@immutable
class V2ConnectorDetailData {
  const V2ConnectorDetailData({
    required this.id,
    required this.name,
    required this.description,
    this.icon = Icons.extension_outlined,
    this.connected = true,
    this.accountLabel = '',
    this.syncedLabel = '',
    this.accessLabel = '',
    this.permissions = const <V2ConnectorPermission>[],
    this.agents = const <V2ConnectorAgent>[],
    this.usage,
    this.activity = const <V2ConnectorActivity>[],
    this.autoSync = true,
    this.status = V2ConnectorDetailStatus.content,
    this.errorMessage = 'This connector did not load.',
    this.disconnectNote = '',
  });

  final String id;
  final String name;
  final String description;
  final IconData icon;
  final bool connected;
  final String accountLabel;
  final String syncedLabel;
  final String accessLabel;
  final List<V2ConnectorPermission> permissions;
  final List<V2ConnectorAgent> agents;
  final V2ConnectorUsage? usage;
  final List<V2ConnectorActivity> activity;
  final bool autoSync;
  final V2ConnectorDetailStatus status;
  final String errorMessage;
  final String disconnectNote;
}

/// One connector: what it can do, who can use it, and how to disconnect it.
class ConnectorDetailPage extends StatefulWidget {
  const ConnectorDetailPage({
    super.key,
    required this.data,
    this.onBack,
    this.onConnect,
    this.onDisconnect,
    this.onPermissionChanged,
    this.onAutoSyncChanged,
    this.onMenu,
    this.onRetry,
  });

  final V2ConnectorDetailData data;
  final VoidCallback? onBack;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;
  final void Function(String permissionId, bool granted)? onPermissionChanged;
  final ValueChanged<bool>? onAutoSyncChanged;
  final VoidCallback? onMenu;
  final VoidCallback? onRetry;

  @override
  State<ConnectorDetailPage> createState() => _ConnectorDetailPageState();
}

class _ConnectorDetailPageState extends State<ConnectorDetailPage> {
  late Map<String, bool> _granted = _initialGrants();
  late bool _autoSync = widget.data.autoSync;

  Map<String, bool> _initialGrants() {
    return <String, bool>{
      for (final permission in widget.data.permissions)
        permission.id: permission.granted,
    };
  }

  @override
  void didUpdateWidget(covariant ConnectorDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _granted = _initialGrants();
      _autoSync = widget.data.autoSync;
    }
  }

  void _togglePermission(V2ConnectorPermission permission, bool value) {
    setState(() => _granted[permission.id] = value);
    widget.onPermissionChanged?.call(permission.id, value);
  }

  void _toggleAutoSync(bool value) {
    setState(() => _autoSync = value);
    widget.onAutoSyncChanged?.call(value);
  }

  Future<void> _confirmDisconnect() async {
    final data = widget.data;
    final note = data.disconnectNote.isEmpty
        ? 'Ovid will stop using ${data.name} in chats and projects until you '
              'connect it again.'
        : data.disconnectNote;
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Disconnect ${data.name}?',
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              note,
              style: OType.bodySm.copyWith(
                color: OColors.of(sheetContext).textMuted,
              ),
            ),
            const SizedBox(height: OSpace.l),
            OButton(
              label: 'Disconnect ${data.name}',
              icon: Icons.link_off_rounded,
              variant: OButtonVariant.dangerFill,
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(true),
            ),
            const SizedBox(height: OSpace.s),
            OButton(
              label: 'Keep connected',
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop(false),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) widget.onDisconnect?.call();
  }

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: OAppBar(
        title: 'Connector details',
        subtitle: 'Ovid Si',
        leading: OIconButton(
          icon: Icons.arrow_back_rounded,
          semanticLabel: 'Back',
          onPressed: widget.onBack ?? () => Navigator.maybePop(context),
        ),
        actions: [
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'Connector menu',
            onPressed: widget.onMenu,
          ),
        ],
      ),
      body: OFadeSlide(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    return switch (widget.data.status) {
      V2ConnectorDetailStatus.loading => const OSkeletonList(rows: 5),
      V2ConnectorDetailStatus.error => OErrorState(
        message: widget.data.errorMessage,
        onRetry: widget.onRetry,
      ),
      V2ConnectorDetailStatus.content =>
        widget.data.connected ? _content(context) : _notConnected(context),
    };
  }

  Widget _notConnected(BuildContext context) {
    return OEmptyState(
      icon: Icons.link_off_rounded,
      title: 'Not connected',
      message:
          'Connect ${widget.data.name} so Ovid can use it in your chats '
          'and projects.',
      action: OButton(
        label: 'Connect ${widget.data.name}',
        icon: Icons.link_rounded,
        onPressed: widget.onConnect,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.xl,
      ),
      children: [
        OCard(
          padding: const EdgeInsets.all(OSpace.xl),
          child: Column(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  shape: BoxShape.circle,
                  border: Border.all(color: c.hairline),
                ),
                child: Icon(data.icon, size: 34, color: c.text),
              ),
              const SizedBox(height: OSpace.m),
              Text(
                data.name,
                textAlign: TextAlign.center,
                style: OType.h1.copyWith(color: c.text),
              ),
              const SizedBox(height: OSpace.s),
              const OPill(
                label: 'Connected',
                tone: OPillTone.success,
                dot: true,
              ),
              const SizedBox(height: OSpace.m),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Text(
                  data.description,
                  textAlign: TextAlign.center,
                  style: OType.bodySm.copyWith(color: c.textMuted),
                ),
              ),
              const SizedBox(height: OSpace.l),
              if (data.accountLabel.isNotEmpty || data.syncedLabel.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: OSpace.m,
                    vertical: OSpace.s,
                  ),
                  decoration: BoxDecoration(
                    color: c.surfaceAlt,
                    borderRadius: BorderRadius.circular(ORadius.pill),
                  ),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.center,
                    spacing: OSpace.s,
                    runSpacing: OSpace.xs,
                    children: [
                      if (data.accountLabel.isNotEmpty) ...[
                        Icon(
                          Icons.account_circle_outlined,
                          size: 16,
                          color: c.textMuted,
                        ),
                        Text(
                          data.accountLabel,
                          style: OType.caption.copyWith(color: c.text),
                        ),
                      ],
                      if (data.accountLabel.isNotEmpty &&
                          data.syncedLabel.isNotEmpty)
                        Container(
                          width: 3,
                          height: 3,
                          decoration: BoxDecoration(
                            color: c.textFaint,
                            shape: BoxShape.circle,
                          ),
                        ),
                      if (data.syncedLabel.isNotEmpty)
                        Text(
                          data.syncedLabel,
                          style: OType.caption.copyWith(color: c.textMuted),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: OSpace.m),
        OCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Permissions granted',
                      style: OType.h3.copyWith(color: c.text),
                    ),
                  ),
                  if (data.accessLabel.isNotEmpty) ...[
                    Icon(
                      Icons.verified_user_outlined,
                      size: 15,
                      color: c.textMuted,
                    ),
                    const SizedBox(width: OSpace.xs),
                    Flexible(
                      child: Text(
                        data.accessLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: OSpace.s),
              if (data.permissions.isEmpty)
                Text(
                  'No permissions granted yet.',
                  style: OType.caption.copyWith(color: c.textMuted),
                )
              else
                OStagger(
                  children: [
                    for (var i = 0; i < data.permissions.length; i++) ...[
                      if (i > 0) Divider(color: c.hairline, height: 1),
                      _PermissionRow(
                        permission: data.permissions[i],
                        granted: _granted[data.permissions[i].id] ?? false,
                        onChanged: (value) =>
                            _togglePermission(data.permissions[i], value),
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: OSpace.m),
        _UsageCard(usage: data.usage),
        const SizedBox(height: OSpace.m),
        OCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Used by',
                      style: OType.h3.copyWith(color: c.text),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      '${data.agents.length} assigned',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: OSpace.s),
              if (data.agents.isEmpty)
                Text(
                  'No agents can use this connector yet.',
                  style: OType.caption.copyWith(color: c.textMuted),
                )
              else
                OStagger(
                  children: [
                    for (var i = 0; i < data.agents.length; i++) ...[
                      if (i > 0) Divider(color: c.hairline, height: 1),
                      _AgentRow(agent: data.agents[i]),
                    ],
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: OSpace.m),
        _ActivityCard(activity: data.activity),
        const SizedBox(height: OSpace.m),
        OCard(
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.m,
            vertical: OSpace.s,
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(Icons.sync_rounded, size: 19, color: c.textMuted),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Automatic sync',
                      style: OType.bodyStrong.copyWith(color: c.text),
                    ),
                    Text(
                      'Updates when code is pushed or a pull request opens.',
                      style: OType.caption.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: OSpace.s),
              Semantics(
                label: 'Automatic sync',
                child: SizedBox(
                  height: OSpace.touch,
                  child: Switch(value: _autoSync, onChanged: _toggleAutoSync),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: OSpace.xl),
        OButton(
          label: 'Disconnect ${data.name}',
          icon: Icons.link_off_rounded,
          variant: OButtonVariant.danger,
          expand: true,
          onPressed: widget.onDisconnect == null ? null : _confirmDisconnect,
        ),
        const SizedBox(height: OSpace.s),
        Text(
          'Disconnecting pauses sync and stops Ovid from using this connector '
          'in chats and projects.',
          textAlign: TextAlign.center,
          style: OType.caption.copyWith(color: c.textMuted),
        ),
      ],
    );
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({this.usage});

  final V2ConnectorUsage? usage;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final value = usage;
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Usage', style: OType.h3.copyWith(color: c.text)),
              ),
              Flexible(
                child: Text(
                  value?.periodLabel ?? 'this week',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          if (value == null)
            Text(
              'No calls yet. Ovid will count them here.',
              style: OType.caption.copyWith(color: c.textMuted),
            )
          else ...[
            Text(
              '${value.calls} of ${value.limit} calls',
              style: OType.bodySm.copyWith(color: c.text),
            ),
            const SizedBox(height: OSpace.s),
            OProgressBar(value: value.fraction),
            if (value.resetLabel.isNotEmpty) ...[
              const SizedBox(height: OSpace.s),
              Text(
                value.resetLabel,
                style: OType.caption.copyWith(color: c.textMuted),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.activity});

  final List<V2ConnectorActivity> activity;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final shown = activity.take(8).toList();
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Recent activity',
                  style: OType.h3.copyWith(color: c.text),
                ),
              ),
              if (shown.isNotEmpty)
                Flexible(
                  child: Text(
                    '${activity.length} events',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          if (shown.isEmpty)
            Text(
              'No activity yet. Ovid will show what it did here.',
              style: OType.caption.copyWith(color: c.textMuted),
            )
          else
            OStagger(
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0) Divider(color: c.hairline, height: 1),
                  _ActivityRow(activity: shown[i]),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.activity});

  final V2ConnectorActivity activity;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final color = activity.ok ? c.success : c.warn;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OSpace.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              activity.ok ? Icons.check_rounded : Icons.error_outline_rounded,
              size: 15,
              color: color,
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activity.title,
                  style: OType.bodySm.copyWith(color: c.text),
                ),
                if (activity.detail.isNotEmpty)
                  Text(
                    activity.detail,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
              ],
            ),
          ),
          if (activity.timeLabel.isNotEmpty) ...[
            const SizedBox(width: OSpace.s),
            Text(
              activity.timeLabel,
              style: OType.caption.copyWith(color: c.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.permission,
    required this.granted,
    required this.onChanged,
  });

  final V2ConnectorPermission permission;
  final bool granted;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OSpace.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: granted ? c.success.withValues(alpha: 0.12) : c.surfaceAlt,
              shape: BoxShape.circle,
            ),
            child: Icon(
              granted ? Icons.check_rounded : Icons.remove_rounded,
              size: 17,
              color: granted ? c.success : c.textFaint,
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  permission.name,
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  permission.description,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: OSpace.s),
          Semantics(
            label: '${permission.name} permission',
            child: SizedBox(
              height: OSpace.touch,
              child: Switch(value: granted, onChanged: onChanged),
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({required this.agent});

  final V2ConnectorAgent agent;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OSpace.s),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.accentSoft,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(
              agent.fullAccess
                  ? Icons.psychology_outlined
                  : Icons.smart_toy_outlined,
              size: 20,
              color: c.accent,
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  agent.name,
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                Text(
                  agent.description,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: OSpace.s),
          Flexible(
            child: OPill(
              label: agent.accessLabel,
              tone: agent.fullAccess ? OPillTone.accent : OPillTone.neutral,
            ),
          ),
        ],
      ),
    );
  }
}
