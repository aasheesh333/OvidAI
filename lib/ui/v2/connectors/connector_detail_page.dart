import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'add_connector_page.dart';
import 'catalog_data.dart';
import 'connector_permissions.dart' as permissions;
import 'connector_probe.dart';
import 'connector_store.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2ConnectorDetailStatus { loading, content, error }

/// How broadly a grant applies. Mirrors the permissions screen so the detail
/// page can group grants without exposing that screen's model everywhere.
enum V2ConnectorPermissionScope { read, write, admin }

/// Blast radius of a grant if it is misused.
enum V2ConnectorPermissionRisk {
  low('Low'),
  medium('Medium'),
  high('High');

  const V2ConnectorPermissionRisk(this.label);

  final String label;
}

/// One permission the connector may use. `granted` is the live switch state.
@immutable
class V2ConnectorPermission {
  const V2ConnectorPermission({
    required this.id,
    required this.name,
    required this.description,
    this.granted = true,
    this.scope = V2ConnectorPermissionScope.read,
    this.risk = V2ConnectorPermissionRisk.low,
  });

  final String id;
  final String name;
  final String description;
  final bool granted;
  final V2ConnectorPermissionScope scope;
  final V2ConnectorPermissionRisk risk;
}

/// One tool the connector exposes. `write` tools can change data.
@immutable
class V2ConnectorTool {
  const V2ConnectorTool({
    required this.id,
    required this.name,
    this.description = '',
    this.write = false,
  });

  final String id;
  final String name;
  final String description;
  final bool write;
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
    this.connected = false,
    this.enabled = true,
    this.endpoint = '',
    this.target = V2ConnectorTarget.url,
    this.accountLabel = '',
    this.syncedLabel = '',
    this.accessLabel = '',
    this.permissions = const <V2ConnectorPermission>[],
    this.tools = const <V2ConnectorTool>[],
    this.agents = const <V2ConnectorAgent>[],
    this.usage,
    this.activity = const <V2ConnectorActivity>[],
    this.autoSync = true,
    this.builtIn = true,
    this.safetyNote = '',
    this.authLabel = '',
    this.risk = V2ConnectorPermissionRisk.low,
    this.status = V2ConnectorDetailStatus.content,
    this.errorMessage = 'This connector did not load.',
    this.disconnectNote = '',
    this.disabledTools = const <String>{},
  });

  final String id;
  final String name;
  final String description;
  final IconData icon;
  final bool connected;

  /// The connector switch. A connected but paused connector stays saved and
  /// keeps its grants; Ovid just does not call it.
  final bool enabled;

  /// The server URL or command behind this connection. Empty for a catalog
  /// row that has never been set up — the detail page then offers no test.
  final String endpoint;
  final V2ConnectorTarget target;

  final String accountLabel;
  final String syncedLabel;
  final String accessLabel;
  final List<V2ConnectorPermission> permissions;
  final List<V2ConnectorTool> tools;
  final List<V2ConnectorAgent> agents;
  final V2ConnectorUsage? usage;
  final List<V2ConnectorActivity> activity;
  final bool autoSync;
  final bool builtIn;
  final String safetyNote;

  /// Primary credential the catalog says this integration needs, e.g. OAuth.
  final String authLabel;

  /// Blast radius of the whole connector.
  final V2ConnectorPermissionRisk risk;

  final V2ConnectorDetailStatus status;
  final String errorMessage;
  final String disconnectNote;

  /// Tools the person turned off on the permissions screen.
  final Set<String> disabledTools;
}

/// One connector: its status, its grants, and one way to disconnect it.
class ConnectorDetailPage extends StatefulWidget {
  const ConnectorDetailPage({
    super.key,
    required this.data,
    this.onBack,
    this.onConnect,
    this.onDisconnect,
    this.onEnabledChanged,
    this.onPermissionChanged,
    this.onOpenPermissions,
    this.onMenu,
    this.onRetry,
    this.store,
    this.secrets,
    this.probe,
    this.plan,
  });

  final V2ConnectorDetailData data;
  final VoidCallback? onBack;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;

  /// Reports the new connector switch value.
  final ValueChanged<bool>? onEnabledChanged;

  final void Function(String permissionId, bool granted)? onPermissionChanged;

  /// Optional override for the wiring layer. When omitted the detail page
  /// opens [permissions.ConnectorPermissionsPage] with mapped grants itself.
  final VoidCallback? onOpenPermissions;
  final VoidCallback? onMenu;
  final VoidCallback? onRetry;

  final V2ConnectorStore? store;
  final V2ConnectorSecrets? secrets;
  final V2ConnectorProbe? probe;

  /// Plan used when the not-connected state opens the add flow.
  final V2ConnectorPlan? plan;

  @override
  State<ConnectorDetailPage> createState() => _ConnectorDetailPageState();
}

class _ConnectorDetailPageState extends State<ConnectorDetailPage> {
  late Map<String, bool> _granted = _initialGrants();
  late bool _enabled = widget.data.enabled;
  V2ConnectorTestReport? _report;
  bool _testing = false;
  String? _actionError;

  V2ConnectorStore get _store => widget.store ?? v2ConnectorStore;
  V2ConnectorSecrets get _secrets => widget.secrets ?? v2ConnectorSecrets;
  V2ConnectorProbe get _probe => widget.probe ?? V2HttpConnectorProbe();

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
      _enabled = widget.data.enabled;
    }
  }

  void _togglePermission(V2ConnectorPermission permission, bool value) {
    setState(() {
      _granted[permission.id] = value;
      _actionError = null;
    });
    final external = widget.onPermissionChanged;
    if (external != null) {
      external(permission.id, value);
      return;
    }
    _persistPermission(permission.id, value);
  }

  Future<void> _persistPermission(String permissionId, bool value) async {
    final kind = V2ConnectorPermissionKind.values
        .where((item) => item.name == permissionId)
        .firstOrNull;
    if (kind == null) {
      // No persisted grant can carry an unknown id: put the switch back rather
      // than showing a change that was never saved.
      if (mounted) {
        setState(() {
          _granted[permissionId] = !value;
          _actionError = 'Could not save that permission.';
        });
      }
      return;
    }
    try {
      await _store.setPermission(widget.data.id, kind, value);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _granted[permissionId] = !value;
        _actionError = 'Could not save that permission.';
      });
    }
  }

  void _toggleEnabled(bool value) {
    setState(() {
      _enabled = value;
      _actionError = null;
    });
    final external = widget.onEnabledChanged;
    if (external != null) {
      external(value);
      return;
    }
    _persistEnabled(value);
  }

  Future<void> _persistEnabled(bool value) async {
    try {
      await _store.setEnabled(widget.data.id, value);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _enabled = !value;
        _actionError = 'Could not save that change.';
      });
    }
  }

  /// Runs the real test. Never reports success without a server answer.
  Future<void> _testConnection() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _report = null;
      _actionError = null;
    });
    String? key;
    if (widget.data.authLabel.toLowerCase().contains('key') ||
        widget.data.authLabel.toLowerCase().contains('token')) {
      try {
        key = await _secrets.read(widget.data.id);
      } catch (_) {
        key = null;
      }
    }
    final connection = V2ConnectorConnection(
      id: widget.data.id,
      name: widget.data.name,
      endpoint: widget.data.endpoint,
      target: widget.data.target,
      auth: key == null || key.isEmpty
          ? V2ConnectorAuth.none
          : V2ConnectorAuth.apiKey,
    );
    final report = await _probe.test(connection, apiKey: key);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _report = report;
    });
  }

  bool _isGranted(V2ConnectorPermission permission) =>
      _granted[permission.id] ?? permission.granted;

  permissions.V2ConnectorPermissionScope _scopeOf(
    V2ConnectorPermissionScope scope,
  ) => switch (scope) {
    V2ConnectorPermissionScope.read =>
      permissions.V2ConnectorPermissionScope.read,
    V2ConnectorPermissionScope.write =>
      permissions.V2ConnectorPermissionScope.write,
    V2ConnectorPermissionScope.admin =>
      permissions.V2ConnectorPermissionScope.admin,
  };

  permissions.V2ConnectorPermissionRisk _riskOf(
    V2ConnectorPermissionRisk risk,
  ) => switch (risk) {
    V2ConnectorPermissionRisk.low => permissions.V2ConnectorPermissionRisk.low,
    V2ConnectorPermissionRisk.medium =>
      permissions.V2ConnectorPermissionRisk.medium,
    V2ConnectorPermissionRisk.high =>
      permissions.V2ConnectorPermissionRisk.high,
  };

  V2ConnectorPermissionRisk _effectiveRisk(V2ConnectorPermission permission) =>
      permission.risk.index >= widget.data.risk.index
      ? permission.risk
      : widget.data.risk;

  String? _permissionIdFor(V2ConnectorTool tool) {
    final wanted = tool.write
        ? V2ConnectorPermissionScope.write
        : V2ConnectorPermissionScope.read;
    for (final permission in widget.data.permissions) {
      if (permission.scope == wanted) return permission.id;
    }
    return widget.data.permissions.isEmpty
        ? null
        : widget.data.permissions.first.id;
  }

  /// The detail page owns the live switch state, so map it (plus the tool and
  /// agent wiring) into the standalone permissions screen when the menu opens.
  permissions.V2ConnectorPermissionsData _permissionsScreenData() {
    final data = widget.data;
    final granted = data.permissions.where(_isGranted).toList();
    final revoked = data.permissions
        .where((permission) => !_isGranted(permission))
        .toList();
    return permissions.V2ConnectorPermissionsData(
      connectorId: data.id,
      connectorName: data.name,
      connectorDescription: data.description,
      connectorIcon: data.icon,
      accountLabel: data.accountLabel,
      permissions: [
        for (final permission in data.permissions)
          permissions.V2ConnectorPermissionItem(
            id: permission.id,
            name: permission.name,
            scope: _scopeOf(permission.scope),
            description: permission.description,
            risk: _riskOf(_effectiveRisk(permission)),
            granted: _isGranted(permission),
            toolIds: [
              for (final tool in data.tools)
                if (_permissionIdFor(tool) == permission.id) tool.id,
            ],
          ),
      ],
      tools: [
        for (final tool in data.tools)
          permissions.V2ConnectorPermissionTool(
            id: tool.id,
            name: tool.name,
            scope: tool.write
                ? permissions.V2ConnectorPermissionScope.write
                : permissions.V2ConnectorPermissionScope.read,
            description: tool.description,
            permissionId: _permissionIdFor(tool),
            enabled: !data.disabledTools.contains(tool.id),
          ),
      ],
      canDo: [
        for (final permission in granted) permission.name,
        if (granted.isNotEmpty && data.authLabel.isNotEmpty)
          'Use the ${data.authLabel} you approved.',
      ],
      cannotDo: [
        for (final permission in revoked)
          '${permission.name} until you grant it again.',
        if (!data.builtIn)
          'Use an unreviewed third-party server without your say.',
      ],
      status: data.permissions.isEmpty
          ? permissions.V2ConnectorPermissionsStatus.empty
          : permissions.V2ConnectorPermissionsStatus.content,
      revokeNote: data.disconnectNote,
    );
  }

  Future<void> _openPermissions() async {
    final external = widget.onOpenPermissions;
    if (external != null) {
      external();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => permissions.ConnectorPermissionsPage(
          data: _permissionsScreenData(),
          onRevokePermission: _revokePermission,
          onRevokeAll: _revokeAll,
          onToolChanged: _setToolEnabled,
        ),
      ),
    );
  }

  void _revokePermission(String permissionId) {
    if (!widget.data.permissions.any((item) => item.id == permissionId)) {
      return;
    }
    setState(() => _granted[permissionId] = false);
    final external = widget.onPermissionChanged;
    if (external != null) {
      external(permissionId, false);
      return;
    }
    _persistPermission(permissionId, false);
  }

  void _revokeAll() {
    setState(() {
      for (final permission in widget.data.permissions) {
        _granted[permission.id] = false;
      }
    });
    for (final permission in widget.data.permissions) {
      final external = widget.onPermissionChanged;
      if (external != null) {
        external(permission.id, false);
      } else {
        _persistPermission(permission.id, false);
      }
    }
  }

  Future<void> _setToolEnabled(String toolId, bool enabled) async {
    try {
      await _store.setToolEnabled(widget.data.id, toolId, enabled);
    } catch (_) {
      if (!mounted) return;
      setState(() => _actionError = 'Could not save that tool.');
    }
  }

  Future<void> _confirmDisconnect() async {
    final data = widget.data;
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
              data.disconnectNote.isEmpty
                  ? 'Ovid stops using it until you connect again.'
                  : data.disconnectNote,
              style: OType.bodySm.copyWith(
                color: OColors.of(sheetContext).textMuted,
              ),
            ),
            const SizedBox(height: OSpace.l),
            OButton(
              label: 'Disconnect',
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
    if (confirmed != true || !mounted) return;
    final external = widget.onDisconnect;
    if (external != null) {
      external();
      return;
    }
    try {
      await _store.remove(widget.data.id);
      await _secrets.delete(widget.data.id);
    } catch (_) {
      if (!mounted) return;
      setState(() => _actionError = 'Could not disconnect.');
      return;
    }
    if (!mounted) return;
    showOSnack(context, '${widget.data.name} disconnected.');
    Navigator.of(context).maybePop();
  }

  /// The overflow menu. Destructive actions stay at the bottom of the page.
  Future<void> _openMenu() async {
    final external = widget.onMenu;
    if (external != null) {
      external();
      return;
    }
    final action = await showOSheet<String>(
      context,
      title: 'Options',
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
        child: OButton(
          label: 'Review permissions',
          icon: Icons.verified_user_outlined,
          variant: OButtonVariant.secondary,
          expand: true,
          onPressed: () => Navigator.of(sheetContext).pop('permissions'),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'permissions') await _openPermissions();
  }

  /// Opens the real setup form for a connector that is not connected yet.
  Future<void> _connect() async {
    final external = widget.onConnect;
    if (external != null) {
      external();
      return;
    }
    final plan = widget.plan ?? await v2LoadConnectorPlan();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AddConnectorPage(
          data: V2AddConnectorData(
            plan: plan,
            presetId: widget.data.id,
            presetName: widget.data.name,
            presetDescription: widget.data.description,
            presetKind: 'app',
          ),
          store: _store,
          secrets: _secrets,
          probe: widget.probe,
        ),
      ),
    );
    if (!mounted) return;
    final saved = await _store.find(widget.data.id);
    if (!mounted || saved == null) return;
    showOSnack(context, '${saved.name} connected.');
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: widget.data.name,
      maxWidth: 640,
      leading: widget.onBack == null
          ? null
          : OIconButton(
              icon: Icons.arrow_back_rounded,
              semanticLabel: 'Back',
              onPressed: widget.onBack,
            ),
      actions: [
        // The menu only leads to the permissions review, so it is absent when
        // there is nothing to review (a connector that was never set up).
        if (widget.onMenu != null || widget.data.permissions.isNotEmpty)
          OIconButton(
            icon: Icons.more_vert_rounded,
            semanticLabel: 'Connector menu',
            onPressed: _openMenu,
          ),
      ],
      child: OFadeSlide(child: _body(context)),
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
      message: 'Connect ${widget.data.name} to use it.',
      action: OButton(
        label: 'Connect',
        semanticLabel: 'Connect ${widget.data.name}',
        icon: Icons.link_rounded,
        onPressed: _connect,
      ),
    );
  }

  Widget _content(BuildContext context) {
    final c = OColors.of(context);
    final data = widget.data;
    final permissions = data.permissions.take(3).toList();
    return ListView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      children: [
        // Status is the one line the page leads with; the switch is the only
        // control beside it.
        Row(
          key: const Key('connector-enabled-card'),
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: OPill(
                  label: _enabled ? 'Connected' : 'Paused',
                  tone: _enabled ? OPillTone.success : OPillTone.neutral,
                  dot: _enabled,
                ),
              ),
            ),
            const SizedBox(width: OSpace.s),
            MergeSemantics(
              child: Semantics(
                label: '${data.name} connector',
                child: SizedBox(
                  height: OSpace.touch,
                  child: Switch(
                    key: const Key('connector-enabled-switch'),
                    value: _enabled,
                    onChanged: _toggleEnabled,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (data.endpoint.isNotEmpty) ...[
          const SizedBox(height: OSpace.l),
          OButton(
            key: const Key('connector-test-card'),
            label: 'Test connection',
            icon: Icons.sync_rounded,
            variant: OButtonVariant.secondary,
            expand: true,
            loading: _testing,
            onPressed: _testing ? null : _testConnection,
          ),
          if (_report != null) ...[
            const SizedBox(height: OSpace.s),
            _ReportLine(report: _report!),
          ],
        ],
        if (_actionError != null) ...[
          const SizedBox(height: OSpace.s),
          Semantics(
            liveRegion: true,
            child: Text(
              _actionError!,
              key: const Key('connector-action-error'),
              style: OType.caption.copyWith(color: c.danger),
            ),
          ),
        ],
        if (permissions.isNotEmpty) ...[
          const SizedBox(height: OSpace.xl),
          OSectionTitle(title: 'Permissions'),
          for (var i = 0; i < permissions.length; i++) ...[
            if (i > 0) Divider(color: c.hairline, height: 1),
            _PermissionRow(
              permission: permissions[i],
              granted: _isGranted(permissions[i]),
              onChanged: (value) => _togglePermission(permissions[i], value),
            ),
          ],
        ],
        const SizedBox(height: OSpace.xxl),
        OButton(
          label: 'Disconnect',
          semanticLabel: 'Disconnect ${data.name}',
          icon: Icons.link_off_rounded,
          variant: OButtonVariant.danger,
          expand: true,
          onPressed: _confirmDisconnect,
        ),
      ],
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
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: OSpace.s),
        child: Row(
          children: [
            Expanded(
              child: Text(
                permission.name,
                style: OType.bodyStrong.copyWith(color: c.text),
              ),
            ),
            const SizedBox(width: OSpace.m),
            Semantics(
              label: '${permission.name} permission',
              child: SizedBox(
                height: OSpace.touch,
                child: Switch(
                  key: ValueKey('connector-permission-switch-${permission.id}'),
                  value: granted,
                  onChanged: onChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The real result of the last test, in one line plus its reason.
class _ReportLine extends StatelessWidget {
  const _ReportLine({required this.report});

  final V2ConnectorTestReport report;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final color = report.unsupported
        ? c.textMuted
        : report.ok
        ? c.success
        : c.danger;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            report.unsupported
                ? Icons.info_outline_rounded
                : report.ok
                ? Icons.check_circle_outline_rounded
                : Icons.error_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              report.message,
              style: OType.caption.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Builds the detail model for a catalog row plus the connection behind it.
///
/// A row with no saved connection is *not* connected: the page then offers the
/// real setup form instead of a "Connected" badge with nothing behind it.
V2ConnectorDetailData v2ConnectorDetailForRow(
  V2Connector row, {
  V2ConnectorConnection? connection,
}) {
  final saved = connection;
  final risk = saved != null && saved.custom
      ? V2ConnectorPermissionRisk.high
      : switch (row.risk) {
          V2CatalogRisk.high => V2ConnectorPermissionRisk.high,
          V2CatalogRisk.medium => V2ConnectorPermissionRisk.medium,
          V2CatalogRisk.low => V2ConnectorPermissionRisk.low,
        };
  return V2ConnectorDetailData(
    id: row.id,
    name: row.name,
    description: row.description,
    icon: row.icon,
    connected: saved != null,
    enabled: saved?.enabled ?? false,
    endpoint: saved?.endpoint ?? '',
    target: saved?.target ?? V2ConnectorTarget.url,
    builtIn: row.builtIn,
    authLabel: saved?.auth.label ?? row.auth.label,
    risk: risk,
    autoSync: saved?.autoSync ?? false,
    disabledTools: saved?.disabledTools ?? const <String>{},
    permissions: saved == null
        ? const <V2ConnectorPermission>[]
        : [
            for (final kind in V2ConnectorPermissionKind.values)
              V2ConnectorPermission(
                id: kind.name,
                name: kind.title,
                description: kind.description,
                granted: saved.permissionGranted(kind),
                scope: switch (kind) {
                  V2ConnectorPermissionKind.read =>
                    V2ConnectorPermissionScope.read,
                  V2ConnectorPermissionKind.write ||
                  V2ConnectorPermissionKind.execute =>
                    V2ConnectorPermissionScope.write,
                },
                risk: risk,
              ),
          ],
  );
}
