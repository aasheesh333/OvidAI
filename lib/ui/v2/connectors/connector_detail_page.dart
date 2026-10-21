import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
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
  /// row that has never been set up — the detail page then says there is
  /// nothing to test instead of offering a test that cannot work.
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

  /// Blast radius of the whole connector. Individual grants can be at least
  /// this risky; the permissions screen shows the higher of the two.
  final V2ConnectorPermissionRisk risk;

  final V2ConnectorDetailStatus status;
  final String errorMessage;
  final String disconnectNote;

  /// Tools the person turned off on the permissions screen.
  final Set<String> disabledTools;
}

/// One connector: what it can do, who can use it, and how to disconnect it.
class ConnectorDetailPage extends StatefulWidget {
  const ConnectorDetailPage({
    super.key,
    required this.data,
    this.onBack,
    this.onConnect,
    this.onDisconnect,
    this.onEnabledChanged,
    this.onPermissionChanged,
    this.onAutoSyncChanged,
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
  final ValueChanged<bool>? onAutoSyncChanged;

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
  late bool _autoSync = widget.data.autoSync;
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
      _autoSync = widget.data.autoSync;
      _enabled = widget.data.enabled;
    }
  }

  void _togglePermission(V2ConnectorPermission permission, bool value) {
    setState(() => _granted[permission.id] = value);
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
    if (kind == null) return;
    try {
      await _store.setPermission(widget.data.id, kind, value);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _actionError =
            'Could not save that permission. Check your connection and try '
            'again.',
      );
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
        _actionError =
            'Could not save that change. Check your connection and try again.';
      });
    }
  }

  void _toggleAutoSync(bool value) {
    setState(() => _autoSync = value);
    final external = widget.onAutoSyncChanged;
    if (external != null) {
      external(value);
      return;
    }
    _store.setAutoSync(widget.data.id, value).catchError((Object _) {
      if (!mounted) return;
      setState(
        () => _actionError =
            'Could not save automatic sync. Check your connection and try '
            'again.',
      );
    });
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
  /// agent wiring) into the standalone permissions screen when the row opens.
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
      setState(
        () => _actionError =
            'Could not save that tool. Check your connection and try again.',
      );
    }
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
      setState(
        () => _actionError =
            'Could not disconnect. Check your connection and try again.',
      );
      return;
    }
    if (!mounted) return;
    showOSnack(context, '${widget.data.name} disconnected.');
    Navigator.of(context).maybePop();
  }

  /// The overflow menu, with the actions this screen can really perform.
  Future<void> _openMenu() async {
    final external = widget.onMenu;
    if (external != null) {
      external();
      return;
    }
    final action = await showOSheet<String>(
      context,
      title: widget.data.name,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(OSpace.l, 0, OSpace.l, OSpace.l),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            OButton(
              label: 'Review permissions',
              icon: Icons.verified_user_outlined,
              variant: OButtonVariant.secondary,
              expand: true,
              onPressed: () => Navigator.of(sheetContext).pop('permissions'),
            ),
            if (widget.data.connected) ...[
              const SizedBox(height: OSpace.s),
              OButton(
                label: 'Disconnect ${widget.data.name}',
                icon: Icons.link_off_rounded,
                variant: OButtonVariant.danger,
                expand: true,
                onPressed: () => Navigator.of(sheetContext).pop('disconnect'),
              ),
            ],
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'permissions') {
      await _openPermissions();
    } else if (action == 'disconnect') {
      await _confirmDisconnect();
    }
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
            onPressed: _openMenu,
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
        onPressed: _connect,
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
              OPill(
                label: _enabled ? 'Connected' : 'Connected · paused',
                tone: _enabled ? OPillTone.success : OPillTone.neutral,
                dot: _enabled,
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
        _ConnectorSwitchCard(
          enabled: _enabled,
          name: data.name,
          onChanged: _toggleEnabled,
        ),
        const SizedBox(height: OSpace.m),
        _ConnectionTestCard(
          endpoint: data.endpoint,
          target: data.target,
          testing: _testing,
          report: _report,
          onTest: data.endpoint.isEmpty ? null : _testConnection,
        ),
        if (_actionError != null) ...[
          const SizedBox(height: OSpace.s),
          Text(
            _actionError!,
            key: const Key('connector-action-error'),
            style: OType.caption.copyWith(color: c.danger),
          ),
        ],
        const SizedBox(height: OSpace.m),
        _SafetyNote(note: data.safetyNote, builtIn: data.builtIn),
        const SizedBox(height: OSpace.m),
        _PermissionsEntry(
          connectorName: data.name,
          granted: data.permissions.where(_isGranted).length,
          total: data.permissions.length,
          onTap: _openPermissions,
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
        _ToolsCard(tools: data.tools),
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
                  child: Switch(
                    key: const Key('connector-autosync-switch'),
                    value: _autoSync,
                    onChanged: _toggleAutoSync,
                  ),
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
          onPressed: _confirmDisconnect,
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

/// Row that opens the grouped permissions screen. Kept separate from the
/// compact switches below so the person can review risk, tools, and revoke
/// every grant in one place.
class _PermissionsEntry extends StatelessWidget {
  const _PermissionsEntry({
    required this.connectorName,
    required this.granted,
    required this.total,
    required this.onTap,
  });

  final String connectorName;
  final int granted;
  final int total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      key: const Key('connector-permissions-entry'),
      padding: const EdgeInsets.all(OSpace.m),
      onTap: onTap,
      semanticLabel: 'Review permissions for $connectorName',
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(ORadius.m),
              border: Border.all(color: c.hairline),
            ),
            child: Icon(
              Icons.verified_user_outlined,
              size: 20,
              color: c.textMuted,
            ),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Permissions',
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  total == 0
                      ? 'Review grants, tools and risk'
                      : '$granted of $total granted · review tools and risk',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: OSpace.s),
          Icon(Icons.chevron_right_rounded, size: 22, color: c.textMuted),
        ],
      ),
    );
  }
}

class _SafetyNote extends StatelessWidget {
  const _SafetyNote({required this.note, required this.builtIn});

  final String note;
  final bool builtIn;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final color = builtIn ? c.success : c.warn;
    final text = note.isNotEmpty
        ? note
        : builtIn
        ? 'This connector is built in and reviewed by Ovid. Ovid only uses '
              'the permissions you turn on, and it never installs plugins '
              'from a chat message.'
        : 'This is a custom connector. Ovid did not review it, so only add '
              'servers you trust. Ovid never installs plugins from a chat '
              'message.';
    return Container(
      key: const Key('connector-safety-note'),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.shield_outlined, size: 18, color: color),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  builtIn ? 'Built-in safety' : 'Custom connector safety',
                  style: OType.label.copyWith(color: c.text),
                ),
                const SizedBox(height: 2),
                Text(text, style: OType.caption.copyWith(color: c.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolsCard extends StatelessWidget {
  const _ToolsCard({required this.tools});

  final List<V2ConnectorTool> tools;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Tools', style: OType.h3.copyWith(color: c.text)),
              ),
              Flexible(
                child: Text(
                  '${tools.length} available',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(height: OSpace.s),
          if (tools.isEmpty)
            Text(
              'No tools yet. Ovid will list them here.',
              style: OType.caption.copyWith(color: c.textMuted),
            )
          else
            OStagger(
              children: [
                for (var i = 0; i < tools.length; i++) ...[
                  if (i > 0) Divider(color: c.hairline, height: 1),
                  _ToolRow(tool: tools[i]),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.tool});

  final V2ConnectorTool tool;

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
              color: c.surfaceAlt,
              borderRadius: BorderRadius.circular(ORadius.m),
            ),
            child: Icon(Icons.terminal_rounded, size: 17, color: c.textMuted),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tool.name,
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                if (tool.description.isNotEmpty)
                  Text(
                    tool.description,
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
              ],
            ),
          ),
          const SizedBox(width: OSpace.s),
          Flexible(
            child: OPill(
              label: tool.write ? 'Can change' : 'Read only',
              tone: tool.write ? OPillTone.warn : OPillTone.neutral,
            ),
          ),
        ],
      ),
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
              child: Switch(
                key: ValueKey('connector-permission-switch-${permission.id}'),
                value: granted,
                onChanged: onChanged,
              ),
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

/// The connector switch, separate from the permission switches: pausing keeps
/// the grants but stops Ovid from calling the connector at all.
class _ConnectorSwitchCard extends StatelessWidget {
  const _ConnectorSwitchCard({
    required this.enabled,
    required this.name,
    required this.onChanged,
  });

  final bool enabled;
  final String name;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return OCard(
      key: const Key('connector-enabled-card'),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.s,
      ),
      child: MergeSemantics(
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.surfaceAlt,
                borderRadius: BorderRadius.circular(ORadius.m),
              ),
              child: Icon(
                enabled ? Icons.power_settings_new_rounded : Icons.pause_rounded,
                size: 19,
                color: enabled ? c.success : c.textMuted,
              ),
            ),
            const SizedBox(width: OSpace.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Enabled',
                    style: OType.bodyStrong.copyWith(color: c.text),
                  ),
                  Text(
                    enabled
                        ? 'Ovid can call $name in chats and projects.'
                        : 'Saved, but Ovid will not call $name until you turn '
                              'it back on.',
                    style: OType.caption.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: OSpace.s),
            SizedBox(
              height: OSpace.touch,
              child: Switch(value: enabled, onChanged: onChanged),
            ),
          ],
        ),
      ),
    );
  }
}

/// Real connection test: the button runs an HTTP probe and the card shows what
/// came back, including the reason when it failed.
class _ConnectionTestCard extends StatelessWidget {
  const _ConnectionTestCard({
    required this.endpoint,
    required this.target,
    required this.testing,
    required this.report,
    required this.onTest,
  });

  final String endpoint;
  final V2ConnectorTarget target;
  final bool testing;
  final V2ConnectorTestReport? report;
  final VoidCallback? onTest;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final report = this.report;
    final color = report == null
        ? c.textMuted
        : report.unsupported
        ? c.textMuted
        : report.ok
        ? c.success
        : c.danger;
    return OCard(
      key: const Key('connector-test-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A Wrap, not a Row: at 200 % text the pill no longer fits beside
          // the title on a 320 dp phone and moves to its own line.
          Wrap(
            spacing: OSpace.s,
            runSpacing: OSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Connection', style: OType.h3.copyWith(color: c.text)),
              if (target == V2ConnectorTarget.command)
                const OPill(label: 'Command', tone: OPillTone.neutral)
              else if (endpoint.isNotEmpty)
                const OPill(label: 'Server URL', tone: OPillTone.neutral),
            ],
          ),
          const SizedBox(height: OSpace.s),
          Text(
            endpoint.isEmpty
                ? 'No server address is saved for this connector, so there is '
                      'nothing to test yet.'
                : endpoint,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: OType.mono.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: OSpace.m),
          OButton(
            label: 'Test connection',
            icon: Icons.sync_rounded,
            variant: OButtonVariant.secondary,
            expand: true,
            loading: testing,
            onPressed: testing ? null : onTest,
          ),
          if (report != null) ...[
            const SizedBox(height: OSpace.m),
            Semantics(
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
            ),
          ],
        ],
      ),
    );
  }
}

/// Builds the detail model for a catalog row plus the connection behind it.
///
/// A row with no saved connection is *not* connected: the page then offers the
/// real setup form instead of a "Connected" badge with nothing behind it.
/// Permissions only exist once a connection was saved, and their copy comes
/// from [V2ConnectorPermissionKind] so it matches what the connector does.
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
