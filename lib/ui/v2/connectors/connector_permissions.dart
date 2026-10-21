import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';
import 'connector_models.dart';
import 'connector_store.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2ConnectorPermissionsStatus { loading, content, empty, error }

/// The kind of access a permission grants. Groups are rendered in this order.
enum V2ConnectorPermissionScope { read, write, admin }

/// How much damage a permission could do if it were misused.
enum V2ConnectorPermissionRisk { low, medium, high }

/// One permission Ovid is asking for. [granted] is the live grant state;
/// [tools] lists the tool ids that stop working when it is revoked.
@immutable
class V2ConnectorPermissionItem {
  const V2ConnectorPermissionItem({
    required this.id,
    required this.name,
    required this.scope,
    this.description = '',
    this.risk = V2ConnectorPermissionRisk.low,
    this.granted = true,
    this.toolIds = const <String>[],
  });

  final String id;
  final String name;
  final V2ConnectorPermissionScope scope;
  final String description;
  final V2ConnectorPermissionRisk risk;
  final bool granted;
  final List<String> toolIds;
}

/// One tool the connector exposes to Ovid. A tool is blocked while the
/// permission in [permissionId] is revoked.
@immutable
class V2ConnectorPermissionTool {
  const V2ConnectorPermissionTool({
    required this.id,
    required this.name,
    required this.scope,
    this.description = '',
    this.permissionId,
    this.enabled = true,
  });

  final String id;
  final String name;
  final V2ConnectorPermissionScope scope;
  final String description;
  final String? permissionId;

  /// The per-tool switch. A disabled tool stays listed but Ovid may not call
  /// it even when the permission above is granted.
  final bool enabled;
}

/// Immutable data for the per-connector permissions screen.
@immutable
class V2ConnectorPermissionsData {
  const V2ConnectorPermissionsData({
    required this.connectorId,
    required this.connectorName,
    this.connectorDescription = '',
    this.connectorIcon = Icons.extension_outlined,
    this.accountLabel = '',
    this.permissions = const <V2ConnectorPermissionItem>[],
    this.tools = const <V2ConnectorPermissionTool>[],
    this.canDo = const <String>[],
    this.cannotDo = const <String>[],
    this.status = V2ConnectorPermissionsStatus.content,
    this.errorMessage = 'We could not load this connector’s permissions.',
    this.revokeNote = '',
  });

  final String connectorId;
  final String connectorName;
  final String connectorDescription;
  final IconData connectorIcon;
  final String accountLabel;
  final List<V2ConnectorPermissionItem> permissions;
  final List<V2ConnectorPermissionTool> tools;

  /// Plain-language things Ovid may do with this connector.
  final List<String> canDo;

  /// Plain-language limits. Ovid must never cross these.
  final List<String> cannotDo;

  final V2ConnectorPermissionsStatus status;
  final String errorMessage;
  final String revokeNote;

  List<V2ConnectorPermissionItem> forScope(V2ConnectorPermissionScope scope) =>
      permissions.where((item) => item.scope == scope).toList(growable: false);
}

/// Read / Write / Admin access for one connector, with the tools it exposes,
/// plain-language limits, and a revoke action for every grant.
///
/// Presentational only: the page never reads app state or the network. The
/// live adapter passes [V2ConnectorPermissionsData] and the callbacks.
class ConnectorPermissionsPage extends StatefulWidget {
  const ConnectorPermissionsPage({
    super.key,
    required this.data,
    this.onBack,
    this.onRevokePermission,
    this.onRevokeAll,
    this.onToolChanged,
    this.onRetry,
    this.store,
  });

  final V2ConnectorPermissionsData data;
  final VoidCallback? onBack;

  /// Called with the permission id after the person confirms the revoke.
  final ValueChanged<String>? onRevokePermission;

  /// Called after the person confirms revoking every permission.
  final VoidCallback? onRevokeAll;

  /// Called with the tool id and its new switch value.
  final void Function(String toolId, bool enabled)? onToolChanged;
  final VoidCallback? onRetry;

  /// Persisted connector state, used when the host does not pass callbacks.
  final V2ConnectorStore? store;

  @override
  State<ConnectorPermissionsPage> createState() =>
      _ConnectorPermissionsPageState();
}

class _ConnectorPermissionsPageState extends State<ConnectorPermissionsPage> {
  /// Optimistic overlay: the row flips immediately while the adapter catches
  /// up. Cleared when a new data object arrives.
  final Set<String> _revoked = <String>{};

  /// Tools the person turned off on this screen, before the host catches up.
  final Set<String> _disabledTools = <String>{};

  V2ConnectorPermissionsData get _data => widget.data;

  V2ConnectorStore get _store => widget.store ?? v2ConnectorStore;

  @override
  void didUpdateWidget(covariant ConnectorPermissionsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _revoked.clear();
      _disabledTools.clear();
    }
  }

  bool _isGranted(V2ConnectorPermissionItem item) =>
      item.granted && !_revoked.contains(item.id);

  bool _isToolEnabled(V2ConnectorPermissionTool tool) =>
      tool.enabled && !_disabledTools.contains(tool.id);

  Future<void> _setToolEnabled(V2ConnectorPermissionTool tool, bool value) async {
    setState(() {
      if (value) {
        _disabledTools.remove(tool.id);
      } else {
        _disabledTools.add(tool.id);
      }
    });
    final external = widget.onToolChanged;
    if (external != null) {
      external(tool.id, value);
      return;
    }
    try {
      await _store.setToolEnabled(_data.connectorId, tool.id, value);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (value) {
          _disabledTools.add(tool.id);
        } else {
          _disabledTools.remove(tool.id);
        }
      });
      showOSnack(context, 'Could not save that tool. Try again.');
    }
  }

  List<V2ConnectorPermissionItem> get _granted =>
      _data.permissions.where(_isGranted).toList(growable: false);

  V2ConnectorPermissionItem? _permissionById(String? id) {
    if (id == null) return null;
    for (final item in _data.permissions) {
      if (item.id == id) return item;
    }
    return null;
  }

  bool _toolBlocked(V2ConnectorPermissionTool tool) {
    final owner = _permissionById(tool.permissionId);
    return owner != null && !_isGranted(owner);
  }

  Future<void> _confirmRevoke(V2ConnectorPermissionItem item) async {
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Revoke “${item.name}”?',
      builder: (sheetContext) => _confirmBody(
        sheetContext,
        message:
            '${item.description.isEmpty ? item.name : item.description} '
            'Ovid stops using it immediately in every chat, project and '
            'subagent. Any tool that needs it is blocked.',
        confirmLabel: 'Revoke permission',
        onConfirm: () => Navigator.of(sheetContext).pop(true),
        onCancel: () => Navigator.of(sheetContext).pop(false),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _revoked.add(item.id));
    final external = widget.onRevokePermission;
    if (external != null) {
      external(item.id);
    } else {
      await _persistRevoke(item.id);
    }
    if (!mounted) return;
    showOSnack(context, '“${item.name}” revoked.');
  }

  Future<void> _persistRevoke(String permissionId) async {
    final kind = V2ConnectorPermissionKind.values
        .where((value) => value.name == permissionId)
        .firstOrNull;
    if (kind == null) return;
    try {
      await _store.setPermission(_data.connectorId, kind, false);
    } catch (_) {
      if (!mounted) return;
      showOSnack(context, 'Could not save that change. Try again.');
    }
  }

  Future<void> _confirmRevokeAll() async {
    if (_granted.isEmpty) return;
    final note = _data.revokeNote.isEmpty
        ? 'Ovid stops using ${_data.connectorName} in every chat, project and '
              'subagent. Tools that depend on it stop working until you grant '
              'access again.'
        : _data.revokeNote;
    final confirmed = await showOSheet<bool>(
      context,
      title: 'Revoke all access to ${_data.connectorName}?',
      builder: (sheetContext) => _confirmBody(
        sheetContext,
        message: note,
        confirmLabel: 'Revoke all access',
        onConfirm: () => Navigator.of(sheetContext).pop(true),
        onCancel: () => Navigator.of(sheetContext).pop(false),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      for (final item in _data.permissions) {
        _revoked.add(item.id);
      }
    });
    final external = widget.onRevokeAll;
    if (external != null) {
      external();
    } else {
      for (final item in _data.permissions) {
        await _persistRevoke(item.id);
      }
    }
    if (!mounted) return;
    showOSnack(context, 'All ${_data.connectorName} access revoked.');
  }

  Widget _confirmBody(
    BuildContext sheetContext, {
    required String message,
    required String confirmLabel,
    required VoidCallback onConfirm,
    required VoidCallback onCancel,
  }) {
    final c = OColors.of(sheetContext);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            message,
            style: OType.bodySm.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.l),
          OButton(
            label: confirmLabel,
            icon: Icons.link_off_rounded,
            variant: OButtonVariant.dangerFill,
            expand: true,
            onPressed: onConfirm,
          ),
          const SizedBox(height: OSpace.s),
          OButton(
            label: 'Keep access',
            variant: OButtonVariant.secondary,
            expand: true,
            onPressed: onCancel,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: OAppBar(
        title: 'Permissions',
        subtitle: _data.connectorName,
        leading: OIconButton(
          icon: Icons.arrow_back_rounded,
          semanticLabel: 'Back',
          onPressed: widget.onBack ?? () => Navigator.maybePop(context),
        ),
      ),
      body: OFadeSlide(child: _body(context)),
    );
  }

  Widget _body(BuildContext context) {
    return switch (_data.status) {
      V2ConnectorPermissionsStatus.loading => const OSkeletonList(rows: 6),
      V2ConnectorPermissionsStatus.error => OErrorState(
        message: _data.errorMessage,
        onRetry: widget.onRetry,
      ),
      V2ConnectorPermissionsStatus.empty => _empty(context),
      V2ConnectorPermissionsStatus.content =>
        _data.permissions.isEmpty ? _empty(context) : _content(context),
    };
  }

  Widget _empty(BuildContext context) {
    return OEmptyState(
      icon: Icons.verified_user_outlined,
      title: 'No permissions to review',
      message:
          '${_data.connectorName} has not asked for anything yet. When it is '
          'connected, Ovid lists exactly what it can use here.',
      action: OButton(
        label: 'Back to connector',
        icon: Icons.arrow_back_rounded,
        onPressed: widget.onBack,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    final groups = <V2ConnectorPermissionScope>[
      V2ConnectorPermissionScope.read,
      V2ConnectorPermissionScope.write,
      V2ConnectorPermissionScope.admin,
    ].where((scope) => _data.forScope(scope).isNotEmpty);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.xl,
      ),
      children: [
        _summary(context),
        const SizedBox(height: OSpace.m),
        for (final scope in groups) ...[
          _group(context, scope),
          const SizedBox(height: OSpace.m),
        ],
        _toolsCard(context),
        const SizedBox(height: OSpace.m),
        _abilityCards(context),
        const SizedBox(height: OSpace.m),
        _revokeAllCard(context),
        const SizedBox(height: OSpace.m),
        Text(
          'Revoking access never deletes your ${_data.connectorName} data. '
          'It only stops Ovid from using it.',
          textAlign: TextAlign.center,
          style: OType.caption.copyWith(color: c.textFaint),
        ),
      ],
    );
  }

  Widget _summary(BuildContext context) {
    final c = OColors.of(context);
    final total = _data.permissions.length;
    final granted = _granted.length;
    final fraction = total == 0 ? 0.0 : granted / total;

    return OCard(
      key: const ValueKey('connector-permissions-summary'),
      padding: const EdgeInsets.all(OSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.l),
                  border: Border.all(color: c.hairline),
                ),
                child: Icon(_data.connectorIcon, size: 28, color: c.text),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _data.connectorName,
                      style: OType.h2.copyWith(color: c.text),
                    ),
                    if (_data.connectorDescription.isNotEmpty) ...[
                      const SizedBox(height: OSpace.xs),
                      Text(
                        _data.connectorDescription,
                        style: OType.bodySm.copyWith(color: c.textMuted),
                      ),
                    ],
                    if (_data.accountLabel.isNotEmpty) ...[
                      const SizedBox(height: OSpace.xs),
                      Text(
                        _data.accountLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: OType.caption.copyWith(color: c.textFaint),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.l),
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '$granted of $total granted',
                style: OType.bodyStrong.copyWith(color: c.text),
              ),
              OPill(
                label: granted == 0
                    ? 'No access'
                    : (granted == total ? 'Full access' : 'Limited access'),
                tone: granted == 0
                    ? OPillTone.danger
                    : (granted == total ? OPillTone.warn : OPillTone.neutral),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Semantics(
            label: '$granted of $total permissions granted',
            child: ExcludeSemantics(
              child: OProgressBar(value: fraction),
            ),
          ),
          const SizedBox(height: OSpace.m),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.bolt_rounded, size: 17, color: c.textMuted),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  'These are the only things Ovid can do with '
                  '${_data.connectorName}. Changes apply to every chat, '
                  'project and subagent immediately.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _group(BuildContext context, V2ConnectorPermissionScope scope) {
    final c = OColors.of(context);
    final items = _data.forScope(scope);
    final granted = items.where(_isGranted).length;
    final risk = _highestRisk(items);
    final tint = _scopeColor(scope, c);

    return Column(
      key: ValueKey('connector-permissions-group-${scope.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(ORadius.s),
              ),
              child: Icon(_scopeIcon(scope), size: 16, color: tint),
            ),
            const SizedBox(width: OSpace.s),
            Expanded(
              child: Text(
                _scopeLabel(scope),
                style: OType.h3.copyWith(color: c.text),
              ),
            ),
          ],
        ),
        const SizedBox(height: OSpace.xs),
        Wrap(
          spacing: OSpace.s,
          runSpacing: OSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '$granted of ${items.length} granted',
              style: OType.caption.copyWith(color: c.textMuted),
            ),
            _riskBadge(context, risk),
          ],
        ),
        const SizedBox(height: OSpace.s),
        OCard(
          padding: EdgeInsets.zero,
          child: OStagger(
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) Divider(color: c.hairline, height: 1),
                _permissionRow(context, items[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _permissionRow(
    BuildContext context,
    V2ConnectorPermissionItem item,
  ) {
    final c = OColors.of(context);
    final granted = _isGranted(item);
    final tint = _scopeColor(item.scope, c);

    return Padding(
      key: ValueKey('connector-permission-${item.id}'),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.l,
        vertical: OSpace.m,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: c.surfaceAlt,
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(
                  _scopeIcon(item.scope),
                  size: 19,
                  color: granted ? tint : c.textFaint,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: OType.bodyStrong.copyWith(
                        color: granted ? c.text : c.textMuted,
                      ),
                    ),
                    if (item.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        item.description,
                        style: OType.bodySm.copyWith(color: c.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.s,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _riskBadge(context, item.risk),
              OPill(
                label: granted ? 'Granted' : 'Revoked',
                tone: granted ? OPillTone.success : OPillTone.neutral,
                dot: true,
              ),
              if (granted)
                OButton(
                  key: ValueKey('connector-permission-revoke-${item.id}'),
                  label: 'Revoke',
                  semanticLabel: 'Revoke ${item.name}',
                  variant: OButtonVariant.danger,
                  onPressed: () => _confirmRevoke(item),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _toolsCard(BuildContext context) {
    final c = OColors.of(context);
    final count = _data.tools.length;

    return OCard(
      key: const ValueKey('connector-permissions-tools'),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              OSpace.l,
              OSpace.l,
              OSpace.l,
              OSpace.s,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tools Ovid can call',
                  style: OType.h3.copyWith(color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  count == 0
                      ? 'No tools exposed'
                      : '$count ${count == 1 ? 'tool' : 'tools'} exposed',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          Divider(color: c.hairline, height: 1),
          if (count == 0)
            Padding(
              padding: const EdgeInsets.all(OSpace.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Ovid uses only the permissions above. This connector '
                    'does not expose any named tools.',
                    style: OType.bodySm.copyWith(color: c.textMuted),
                  ),
                  const SizedBox(height: OSpace.s),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OButton(
                      label: 'Back to connector',
                      icon: Icons.arrow_back_rounded,
                      variant: OButtonVariant.ghost,
                      onPressed: widget.onBack,
                    ),
                  ),
                ],
              ),
            )
          else
            OStagger(
              children: [
                for (var i = 0; i < _data.tools.length; i++) ...[
                  if (i > 0) Divider(color: c.hairline, height: 1),
                  _toolRow(context, _data.tools[i]),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _toolRow(BuildContext context, V2ConnectorPermissionTool tool) {
    final c = OColors.of(context);
    final blocked = _toolBlocked(tool);
    final enabled = _isToolEnabled(tool) && !blocked;
    final tint = _scopeColor(tool.scope, c);

    return MergeSemantics(
      child: Padding(
        key: ValueKey('connector-permissions-tool-${tool.id}'),
        padding: const EdgeInsets.symmetric(
          horizontal: OSpace.l,
          vertical: OSpace.m,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tool.name,
                    style: OType.mono.copyWith(
                      color: enabled ? c.text : c.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: OSpace.xs),
                  Wrap(
                    spacing: OSpace.s,
                    runSpacing: OSpace.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      OPill(
                        label: _scopeLabel(tool.scope),
                        tone: _scopeTone(tool.scope),
                      ),
                      if (blocked)
                        const OPill(
                          label: 'Blocked',
                          tone: OPillTone.danger,
                          dot: true,
                        )
                      else if (!enabled)
                        const OPill(label: 'Off', tone: OPillTone.neutral)
                      else
                        Icon(
                          Icons.check_circle_outline_rounded,
                          size: 15,
                          color: tint,
                        ),
                    ],
                  ),
                  if (tool.description.isNotEmpty) ...[
                    const SizedBox(height: OSpace.xs),
                    Text(
                      blocked
                          ? '${tool.description} Needs a revoked permission.'
                          : enabled
                          ? tool.description
                          : '${tool.description} Ovid will not call this tool.',
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: OSpace.s),
            SizedBox(
              height: OSpace.touch,
              child: Switch(
                key: ValueKey('connector-permissions-tool-switch-${tool.id}'),
                value: enabled,
                onChanged: blocked
                    ? null
                    : (value) => _setToolEnabled(tool, value),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _abilityCards(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final can = _abilityCard(
          context,
          key: const ValueKey('connector-permissions-can-do'),
          title: 'What Ovid can do',
          icon: Icons.check_circle_outline_rounded,
          tone: OColors.of(context).success,
          items: _data.canDo,
          emptyLabel: 'Nothing yet. Grant a permission above.',
        );
        final cannot = _abilityCard(
          context,
          key: const ValueKey('connector-permissions-cannot-do'),
          title: 'What Ovid cannot do',
          icon: Icons.block_rounded,
          tone: OColors.of(context).danger,
          items: _data.cannotDo,
          emptyLabel: 'No limits are listed for this connector.',
        );
        if (constraints.maxWidth >= 560) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: can),
              const SizedBox(width: OSpace.m),
              Expanded(child: cannot),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            can,
            const SizedBox(height: OSpace.m),
            cannot,
          ],
        );
      },
    );
  }

  Widget _abilityCard(
    BuildContext context, {
    required Key key,
    required String title,
    required IconData icon,
    required Color tone,
    required List<String> items,
    required String emptyLabel,
  }) {
    final c = OColors.of(context);
    return OCard(
      key: key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(ORadius.s),
                ),
                child: Icon(icon, size: 18, color: tone),
              ),
              const SizedBox(width: OSpace.s),
              Expanded(
                child: Text(
                  title,
                  style: OType.h3.copyWith(color: c.text),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.m),
          if (items.isEmpty)
            Text(
              emptyLabel,
              style: OType.bodySm.copyWith(color: c.textMuted),
            )
          else
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) const SizedBox(height: OSpace.s),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, size: 16, color: tone),
                  ),
                  const SizedBox(width: OSpace.s),
                  Expanded(
                    child: Text(
                      items[i],
                      style: OType.bodySm.copyWith(color: c.text),
                    ),
                  ),
                ],
              ),
            ],
        ],
      ),
    );
  }

  Widget _revokeAllCard(BuildContext context) {
    final c = OColors.of(context);
    final granted = _granted.length;
    final note = _data.revokeNote.isEmpty
        ? 'Ovid loses every permission listed above. Tools that depend on '
              'them stop working until you grant access again.'
        : _data.revokeNote;
    return OCard(
      key: const ValueKey('connector-permissions-revoke-all-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.danger.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(ORadius.m),
                ),
                child: Icon(
                  Icons.link_off_rounded,
                  size: 20,
                  color: c.danger,
                ),
              ),
              const SizedBox(width: OSpace.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Revoke access',
                      style: OType.h3.copyWith(color: c.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      note,
                      style: OType.bodySm.copyWith(color: c.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.l),
          OButton(
            key: const ValueKey('connector-permissions-revoke-all'),
            label: 'Revoke all access',
            semanticLabel: granted == 0
                ? 'Revoke all access, no permissions granted'
                : 'Revoke all access to ${_data.connectorName}',
            icon: Icons.link_off_rounded,
            variant: OButtonVariant.dangerFill,
            expand: true,
            onPressed: granted == 0 ? null : _confirmRevokeAll,
          ),
        ],
      ),
    );
  }

  Widget _riskBadge(BuildContext context, V2ConnectorPermissionRisk risk) {
    return Semantics(
      label: _riskLabel(risk),
      container: true,
      child: ExcludeSemantics(
        child: OPill(label: _riskLabel(risk), tone: _riskTone(risk)),
      ),
    );
  }

  V2ConnectorPermissionRisk _highestRisk(
    List<V2ConnectorPermissionItem> items,
  ) {
    var risk = V2ConnectorPermissionRisk.low;
    for (final item in items) {
      if (item.risk.index > risk.index) risk = item.risk;
    }
    return risk;
  }

  String _scopeLabel(V2ConnectorPermissionScope scope) => switch (scope) {
    V2ConnectorPermissionScope.read => 'Read',
    V2ConnectorPermissionScope.write => 'Write',
    V2ConnectorPermissionScope.admin => 'Admin',
  };

  IconData _scopeIcon(V2ConnectorPermissionScope scope) => switch (scope) {
    V2ConnectorPermissionScope.read => Icons.visibility_outlined,
    V2ConnectorPermissionScope.write => Icons.edit_note_rounded,
    V2ConnectorPermissionScope.admin => Icons.admin_panel_settings_outlined,
  };

  Color _scopeColor(V2ConnectorPermissionScope scope, OColors c) =>
      switch (scope) {
        V2ConnectorPermissionScope.read => c.accent,
        V2ConnectorPermissionScope.write => c.warn,
        V2ConnectorPermissionScope.admin => c.danger,
      };

  OPillTone _scopeTone(V2ConnectorPermissionScope scope) => switch (scope) {
    V2ConnectorPermissionScope.read => OPillTone.accent,
    V2ConnectorPermissionScope.write => OPillTone.warn,
    V2ConnectorPermissionScope.admin => OPillTone.danger,
  };

  String _riskLabel(V2ConnectorPermissionRisk risk) => switch (risk) {
    V2ConnectorPermissionRisk.low => 'Low risk',
    V2ConnectorPermissionRisk.medium => 'Medium risk',
    V2ConnectorPermissionRisk.high => 'High risk',
  };

  OPillTone _riskTone(V2ConnectorPermissionRisk risk) => switch (risk) {
    V2ConnectorPermissionRisk.low => OPillTone.neutral,
    V2ConnectorPermissionRisk.medium => OPillTone.warn,
    V2ConnectorPermissionRisk.high => OPillTone.danger,
  };
}
