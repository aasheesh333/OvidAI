import 'package:flutter/material.dart';

import '../../../core/connectors/connector_api.dart';
import '../../../core/connectors/remote_connector_controller.dart';
import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_screen.dart';
import '../../design/o_tokens.dart';
import 'connector_models.dart';
import 'connector_probe.dart';
import 'connector_store.dart';
import 'connector_upgrade.dart';

export 'connector_models.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2AddConnectorStatus { loading, content, error, blocked }

/// The safe-install rules for a custom connector.
///
/// A custom entry may not carry shell metacharacters, and any path it names
/// must stay inside the session workspace. This is deliberately a pure
/// function so the screen and the wiring layer share one rule.
abstract final class V2ConnectorSafety {
  static const workspaceRoot = '/workspace';

  static const _shellMessage = 'Remove shell characters like ; & | \$ ` > <.';
  static const _pathMessage = 'Use a path inside your workspace.';

  static String? validateEndpoint({
    required String value,
    required V2ConnectorTarget target,
  }) {
    final text = value.trim();
    if (text.isEmpty) return 'Enter a server URL or a command.';

    // Control characters (including newlines) can hide a second command.
    if (RegExp(r'[\u0000-\u001f]').hasMatch(text)) return _shellMessage;
    if (RegExp(r'[;&|`$><\\]').hasMatch(text)) return _shellMessage;

    // Path escapes are rejected for both forms, even inside a URL path.
    if (RegExp(r'(^|[\s="\x27])(\.\.(/|\\|$))').hasMatch(text)) {
      return _pathMessage;
    }
    if (RegExp(r'(^|\s)~(?=/|$|\s)').hasMatch(text)) return _pathMessage;
    if (RegExp(r'[A-Za-z]:\\').hasMatch(text)) return _pathMessage;
    if (text.toLowerCase().contains('file://')) return _pathMessage;

    if (target == V2ConnectorTarget.command) {
      // Globs, subshells and history expansion are shell syntax too.
      if (RegExp(r'[(){}*?\[\]!]').hasMatch(text)) return _shellMessage;

      for (final match in RegExp(
        r'''(^|\s)("[^"]*"|'[^']*'|[^\s]+)''',
      ).allMatches(text)) {
        final word = match.group(2)!;
        if (!word.startsWith('/')) continue;
        final path = word.replaceAll(RegExp(r'^["\x27]|["\x27]$'), '');
        if (path != workspaceRoot && !path.startsWith('$workspaceRoot/')) {
          return _pathMessage;
        }
      }
      return null;
    }

    final uri = Uri.tryParse(text);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return 'Use a full https:// URL.';
    }
    if (uri.host.isEmpty) return 'Enter a full server URL.';
    if (uri.path.contains('..')) return _pathMessage;
    return null;
  }
}

/// Convenience wrapper for callers that prefer a top-level function.
String? validateConnectorEndpoint({
  required String value,
  required V2ConnectorTarget target,
}) => V2ConnectorSafety.validateEndpoint(value: value, target: target);

/// The values the form hands to the wiring layer.
@immutable
class V2CustomConnectorDraft {
  const V2CustomConnectorDraft({
    required this.name,
    required this.url,
    required this.auth,
    required this.apiKey,
    required this.read,
    required this.write,
    required this.execute,
    this.target = V2ConnectorTarget.url,
    this.command = '',
    this.catalogId,
    this.category = 'Custom',
    this.description = '',
    this.kind = 'app',
    this.secrets = const <String, String>{},
    this.agentEnabled = false,
    this.approvedSourceId,
    this.approvedDigest,
  });

  final String name;
  final String url;
  final String command;
  final V2ConnectorTarget target;
  final V2ConnectorAuth auth;
  final String apiKey;
  final bool read;
  final bool write;
  final bool execute;

  /// Set when the person is setting up a catalog connector; null for a custom
  /// server they defined. A catalog connector does not use a plan slot.
  final String? catalogId;
  final String category;
  final String description;
  final String kind;

  /// Gateway-bound credential values. They are never persisted in this draft.
  final Map<String, String> secrets;
  final bool agentEnabled;
  final String? approvedSourceId;
  final String? approvedDigest;

  String get endpoint => target == V2ConnectorTarget.command ? command : url;

  bool get isCustom => catalogId == null;

  /// The record this draft becomes once it is saved.
  V2ConnectorConnection toConnection({DateTime? connectedAt}) {
    return V2ConnectorConnection(
      id:
          catalogId ??
          'custom-${(connectedAt ?? DateTime.now()).microsecondsSinceEpoch}',
      name: name,
      description: description.isNotEmpty
          ? description
          : '${target == V2ConnectorTarget.command ? 'Command' : 'Server'} '
                'connector at $endpoint',
      category: category,
      kind: kind,
      endpoint: endpoint,
      target: target,
      auth: auth,
      enabled: true,
      read: read,
      write: write,
      execute: execute,
      custom: isCustom,
      connectedAt: connectedAt ?? DateTime.now(),
    );
  }
}

/// Injected state for the add-connector screen.
@immutable
class V2AddConnectorData {
  const V2AddConnectorData({
    this.auth = V2ConnectorAuth.apiKey,
    this.read = true,
    this.write = true,
    this.execute = false,
    this.status = V2AddConnectorStatus.content,
    this.testing = false,
    this.testResult,
    this.testDetail = '',
    this.plan = V2ConnectorPlan.free,
    this.customConnectorsUsed = 0,
    this.target = V2ConnectorTarget.url,
    bool? planLimitReached,
    this.planLimitMessage = '',
    this.authRequiredMessage = 'Sign in after saving.',
    this.errorMessage = 'The form did not load.',
    this.chatBlockMessage = 'Ovid never installs connectors from chat.',
    this.presetId,
    this.presetName = '',
    this.presetDescription = '',
    this.presetCategory = 'Custom',
    this.presetKind = 'app',
    this.credentialFields = const <ConnectorCredentialField>[],
    this.agentEnabled = false,
    this.approvedSourceId,
    this.approvedDigest,
    // ignore: prefer_initializing_formals
  }) : _planLimitReached = planLimitReached;

  final V2ConnectorAuth auth;
  final bool read;
  final bool write;
  final bool execute;
  final V2AddConnectorStatus status;
  final bool testing;

  /// Null until the person tests the connection; true when it worked.
  final bool? testResult;

  /// Why the test failed (or what it found). Shown under [testResult].
  final String testDetail;

  /// The person's plan and how many custom connectors they already have.
  final V2ConnectorPlan plan;
  final int customConnectorsUsed;

  /// Which form is open first.
  final V2ConnectorTarget target;

  /// A legacy override. When null the limit comes from [plan] and
  /// [customConnectorsUsed].
  final bool? _planLimitReached;

  final String planLimitMessage;
  final String authRequiredMessage;
  final String errorMessage;
  final String chatBlockMessage;

  /// Catalog connector being set up, when the screen was opened from a row.
  final String? presetId;
  final String presetName;
  final String presetDescription;
  final String presetCategory;
  final String presetKind;
  final List<ConnectorCredentialField> credentialFields;
  final bool agentEnabled;
  final String? approvedSourceId;
  final String? approvedDigest;

  bool get isApprovedCustom =>
      presetId != null && approvedSourceId != null && approvedDigest != null;

  bool get isCatalogSetup => presetId != null && !isApprovedCustom;

  int get customLimit => plan.connectorLimit;

  /// Whether the plan allowance applies to this form. Setting up a catalog
  /// connector does not consume a custom slot.
  bool get capApplies => !isCatalogSetup;

  bool get planLimitReached =>
      capApplies && (_planLimitReached ?? customConnectorsUsed >= customLimit);

  /// One line for the cap, with the allowance numbers the product spec sets.
  String get capMessage {
    if (planLimitMessage.isNotEmpty) return planLimitMessage;
    return switch (plan) {
      V2ConnectorPlan.free => 'No custom connectors on Free.',
      V2ConnectorPlan.go => 'All 5 custom slots used on Go.',
      V2ConnectorPlan.plus => 'All 20 custom slots used on Plus.',
      V2ConnectorPlan.pro => 'All 20 custom slots used on Pro.',
    };
  }
}

/// Add a custom connector, or finish setting up a catalog one.
class AddConnectorPage extends StatefulWidget {
  const AddConnectorPage({
    super.key,
    required this.data,
    this.onSave,
    this.onTestConnection,
    this.onPermissionChanged,
    this.onUpgrade,
    this.onRetry,
    this.onBack,
    this.store,
    this.secrets,
    this.probe,
    this.controller,
  });

  final V2AddConnectorData data;
  final ValueChanged<V2CustomConnectorDraft>? onSave;
  final ValueChanged<V2CustomConnectorDraft>? onTestConnection;
  final void Function(V2ConnectorPermissionKind kind, bool value)?
  onPermissionChanged;
  final VoidCallback? onUpgrade;
  final VoidCallback? onRetry;
  final VoidCallback? onBack;

  /// Persisted connector state. Defaults to the app-wide store.
  final V2ConnectorStore? store;
  final V2ConnectorSecrets? secrets;

  /// Optional legacy preview probe. Remote connections use server health only.
  final V2ConnectorProbe? probe;

  final RemoteConnectorController? controller;

  @override
  State<AddConnectorPage> createState() => _AddConnectorPageState();
}

class _AddConnectorPageState extends State<AddConnectorPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();
  final TextEditingController _command = TextEditingController();
  final TextEditingController _key = TextEditingController();
  final Map<String, TextEditingController> _credentialControllers =
      <String, TextEditingController>{};

  late V2ConnectorAuth _auth = widget.data.auth;
  late bool _read = widget.data.read;
  late bool _write = widget.data.write;
  late bool _execute = widget.data.execute;
  late V2ConnectorTarget _target = widget.data.target;
  late bool _agentEnabled = widget.data.agentEnabled;
  bool _submitted = false;

  /// Result of the last real connection test run from this screen.
  V2ConnectorTestReport? _report;
  bool _testing = false;
  bool _saving = false;
  String? _saveError;

  String get _endpoint => _target == V2ConnectorTarget.command
      ? _command.text.trim()
      : _url.text.trim();

  @override
  void initState() {
    super.initState();
    if (widget.data.presetName.isNotEmpty) _name.text = widget.data.presetName;
    if (widget.data.presetId != null) _target = V2ConnectorTarget.url;
    for (final field in widget.data.credentialFields) {
      _credentialControllers[field.key] = TextEditingController();
    }
  }

  bool get _remote => widget.controller != null;

  String? get _endpointError =>
      V2ConnectorSafety.validateEndpoint(value: _endpoint, target: _target);

  bool get _showEndpointError =>
      (_submitted || _endpoint.isNotEmpty) && _endpointError != null;

  String? get _nameError =>
      _name.text.trim().isEmpty ? 'Give this connector a name.' : null;

  String? get _keyError {
    if (_auth != V2ConnectorAuth.apiKey) return null;
    return _key.text.trim().isEmpty
        ? 'Paste the API key this server expects.'
        : null;
  }

  String? get _credentialError {
    for (final field in widget.data.credentialFields) {
      final optional =
          field.label.toLowerCase().contains('optional') ||
          (field.hint?.toLowerCase().contains('empty means') ?? false);
      if (optional) continue;
      if ((_credentialControllers[field.key]?.text.trim() ?? '').isEmpty) {
        return 'Enter ${field.label}.';
      }
    }
    return null;
  }

  /// Save is only disabled when nothing can be saved: the plan cap, or a save
  /// already in flight. Missing fields are explained inline by [_save].
  bool get _saveEnabled => !widget.data.planLimitReached && !_saving;

  /// The connection test is not an install: it stays available at the plan cap
  /// so the person can prove the server answers before upgrading.
  bool get _canTest => _endpointError == null && !_testing;

  V2ConnectorStore get _store => widget.store ?? v2ConnectorStore;
  V2ConnectorSecrets? get _secrets => widget.secrets;

  void _openUpgrade() {
    final external = widget.onUpgrade;
    if (external != null) {
      external();
      return;
    }
    v2ShowConnectorUpgrade(context, widget.data.plan);
  }

  @override
  void didUpdateWidget(covariant AddConnectorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data.auth != widget.data.auth) {
      _auth = widget.data.auth;
    }
    if (oldWidget.data.read != widget.data.read) _read = widget.data.read;
    if (oldWidget.data.write != widget.data.write) _write = widget.data.write;
    if (oldWidget.data.execute != widget.data.execute) {
      _execute = widget.data.execute;
    }
    if (oldWidget.data.target != widget.data.target) {
      _target = widget.data.target;
    }
    if (oldWidget.data.agentEnabled != widget.data.agentEnabled) {
      _agentEnabled = widget.data.agentEnabled;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _command.dispose();
    _key.dispose();
    for (final controller in _credentialControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  V2CustomConnectorDraft _draft() {
    final command = _target == V2ConnectorTarget.command
        ? _command.text.trim()
        : '';
    final url = _target == V2ConnectorTarget.url ? _url.text.trim() : '';
    final credentials = <String, String>{
      for (final field in widget.data.credentialFields)
        field.key: _credentialControllers[field.key]?.text ?? '',
    };
    return V2CustomConnectorDraft(
      name: _name.text.trim(),
      target: _target,
      url: url,
      command: command,
      auth: _auth,
      apiKey: _key.text,
      read: _read,
      write: _write,
      execute: _execute,
      catalogId: widget.data.presetId,
      category: widget.data.presetCategory,
      description: widget.data.presetDescription,
      kind: widget.data.presetKind,
      secrets: credentials,
      agentEnabled: _agentEnabled,
      approvedSourceId: widget.data.approvedSourceId,
      approvedDigest: widget.data.approvedDigest,
    );
  }

  Future<void> _save() async {
    setState(() {
      _submitted = true;
      _saveError = null;
    });
    if (!_saveEnabled) return;
    if (_nameError != null ||
        (!_remote && (_endpointError != null || _keyError != null)) ||
        (_remote && _credentialError != null)) {
      return;
    }
    final draft = _draft();
    final external = widget.onSave;
    if (external != null) {
      external(draft);
      return;
    }
    setState(() => _saving = true);
    try {
      if (_remote) {
        final controller = widget.controller!;
        final providerId = draft.catalogId;
        if (providerId == null) throw StateError('Provider required.');
        if (widget.data.isApprovedCustom) {
          await controller.createCustomConnection(
            providerId: providerId,
            name: draft.name,
            approvedSourceId: widget.data.approvedSourceId!,
            approvedDigest: widget.data.approvedDigest!,
            secrets: draft.secrets,
            agentEnabled: draft.agentEnabled,
          );
        } else {
          await controller.createConnection(
            providerId: providerId,
            name: draft.name,
            secrets: draft.secrets,
            agentEnabled: draft.agentEnabled,
          );
        }
      } else {
        final connection = draft.toConnection();
        final secrets = _secrets;
        if (draft.apiKey.isNotEmpty) {
          if (secrets == null) throw StateError('Secret store unavailable.');
          await secrets.write(connection.id, draft.apiKey);
        }
        await _store.save(connection);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = 'Could not save this connector.';
      });
      return;
    }
    if (!mounted) return;
    _key.clear();
    for (final controller in _credentialControllers.values) {
      controller.clear();
    }
    setState(() => _saving = false);
    showOSnack(context, '${_name.text.trim()} saved.');
    Navigator.of(context).maybePop();
  }

  Future<void> _test() async {
    setState(() {
      _submitted = true;
      _report = null;
    });
    if (!_canTest) return;
    final draft = _draft();
    final external = widget.onTestConnection;
    if (external != null) {
      external(draft);
      return;
    }
    setState(() => _testing = true);
    final probe = widget.probe;
    final report = probe == null
        ? const V2ConnectorTestReport(
            ok: false,
            unsupported: true,
            message:
                'Health checks are available after saving through Ovid Cloud.',
          )
        : await probe.test(draft.toConnection(), apiKey: draft.apiKey);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _report = report;
    });
  }

  /// A test result only describes the values that were tested, so editing any
  /// of them clears it instead of leaving a stale green line on screen.
  void _fieldChanged() {
    setState(() => _report = null);
  }

  void _setPermission(V2ConnectorPermissionKind kind, bool value) {
    setState(() {
      switch (kind) {
        case V2ConnectorPermissionKind.read:
          _read = value;
        case V2ConnectorPermissionKind.write:
          _write = value;
        case V2ConnectorPermissionKind.execute:
          _execute = value;
      }
    });
    widget.onPermissionChanged?.call(kind, value);
  }

  @override
  Widget build(BuildContext context) {
    return OScreen(
      title: 'Add connector',
      maxWidth: 640,
      subtitle: widget.data.isCatalogSetup
          ? 'Setting up ${widget.data.presetName}'
          : null,
      actions: [
        if (!_remote ||
            widget.data.isCatalogSetup ||
            widget.data.isApprovedCustom)
          OIconButton(
            key: const Key('connector-save'),
            icon: Icons.check_rounded,
            semanticLabel: 'Save',
            onPressed: _saveEnabled ? _save : null,
          ),
      ],
      child: ODismissKeyboard(child: OFadeSlide(child: _body(context))),
    );
  }

  Widget _body(BuildContext context) {
    return switch (widget.data.status) {
      V2AddConnectorStatus.loading => const OSkeletonList(rows: 5),
      V2AddConnectorStatus.error => OErrorState(
        message: widget.data.errorMessage,
        onRetry: widget.onRetry,
      ),
      V2AddConnectorStatus.blocked => _blockedState(),
      V2AddConnectorStatus.content => _content(context),
    };
  }

  /// The way back to the list. Null when there is nowhere to go, so the
  /// blocked state never renders a disabled button.
  VoidCallback? get _close {
    final external = widget.onBack;
    if (external != null) return external;
    return Navigator.of(context).canPop()
        ? () => Navigator.of(context).maybePop()
        : null;
  }

  Widget _blockedState() {
    final close = _close;
    return OEmptyState(
      icon: Icons.shield_outlined,
      title: 'Add connectors here',
      message: widget.data.chatBlockMessage,
      action: close == null
          ? null
          : OButton(
              label: 'Back to connectors',
              icon: Icons.arrow_back_rounded,
              onPressed: close,
            ),
    );
  }

  Widget _content(BuildContext context) {
    if (_remote) return _remoteContent(context);
    final c = OColors.of(context);
    final isCommand = _target == V2ConnectorTarget.command;
    final blocked = widget.data.planLimitReached;
    return ListView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      children: [
        if (blocked) ...[
          _CapLine(message: widget.data.capMessage, onUpgrade: _openUpgrade),
          const SizedBox(height: OSpace.l),
        ],
        TextField(
          key: const Key('add-connector-name'),
          controller: _name,
          textInputAction: TextInputAction.next,
          onChanged: (_) => _fieldChanged(),
          style: OType.bodySm.copyWith(color: c.text),
          decoration: InputDecoration(
            labelText: 'Name',
            hintText: 'Internal API',
            errorText: _submitted ? _nameError : null,
          ),
        ),
        const SizedBox(height: OSpace.m),
        TextField(
          key: Key(isCommand ? 'add-connector-command' : 'add-connector-url'),
          controller: isCommand ? _command : _url,
          keyboardType: isCommand ? TextInputType.text : TextInputType.url,
          textInputAction: TextInputAction.next,
          onChanged: (_) => _fieldChanged(),
          style: OType.bodySm.copyWith(color: c.text),
          decoration: InputDecoration(
            labelText: isCommand ? 'Command' : 'Server URL',
            hintText: isCommand
                ? 'node /workspace/server.js'
                : 'https://api.example.com',
          ),
        ),
        if (_showEndpointError) ...[
          const SizedBox(height: OSpace.s),
          _FieldError(
            key: const Key('custom-connector-error'),
            message: _endpointError!,
          ),
        ],
        if (_auth == V2ConnectorAuth.apiKey) ...[
          const SizedBox(height: OSpace.m),
          TextField(
            key: const Key('add-connector-key'),
            controller: _key,
            // The key is only ever shown masked: there is no reveal control.
            // It lives in the platform keystore, never in preferences or a log.
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            onChanged: (_) => _fieldChanged(),
            style: OType.bodySm.copyWith(color: c.text),
            decoration: InputDecoration(
              labelText: 'API key',
              hintText: 'Paste key',
              errorText: _submitted ? _keyError : null,
            ),
          ),
          const SizedBox(height: OSpace.xs),
          Text(
            'Stored on this device.',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ] else if (_auth == V2ConnectorAuth.oauth) ...[
          const SizedBox(height: OSpace.s),
          Text(
            widget.data.authRequiredMessage,
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ],
        const SizedBox(height: OSpace.l),
        OSectionTitle(title: 'Permissions'),
        OCard(
          child: Column(
            children: [
              for (final kind in V2ConnectorPermissionKind.values) ...[
                if (kind != V2ConnectorPermissionKind.read)
                  Divider(color: c.hairline, height: 1),
                _PermissionSwitchRow(
                  key: Key('connector-permission-${kind.name}'),
                  title: kind.title,
                  value: switch (kind) {
                    V2ConnectorPermissionKind.read => _read,
                    V2ConnectorPermissionKind.write => _write,
                    V2ConnectorPermissionKind.execute => _execute,
                  },
                  onChanged: (value) => _setPermission(kind, value),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: OSpace.l),
        OButton(
          label: 'Test connection',
          icon: Icons.sync_rounded,
          variant: OButtonVariant.secondary,
          expand: true,
          loading: widget.data.testing || _testing,
          onPressed: _canTest ? _test : null,
        ),
        if (_report != null) ...[
          const SizedBox(height: OSpace.m),
          _TestResult(
            ok: _report!.ok,
            message: _report!.message,
            neutral: _report!.unsupported,
          ),
        ] else if (widget.data.testResult != null) ...[
          const SizedBox(height: OSpace.m),
          _TestResult(
            ok: widget.data.testResult!,
            message: widget.data.testDetail,
          ),
        ],
        if (_saveError != null) ...[
          const SizedBox(height: OSpace.m),
          _FieldError(
            key: const Key('connector-save-error'),
            message: _saveError!,
          ),
        ],
      ],
    );
  }

  Widget _remoteContent(BuildContext context) {
    if (!widget.data.isCatalogSetup && !widget.data.isApprovedCustom) {
      final close = _close;
      return OEmptyState(
        icon: Icons.verified_outlined,
        title: 'Approved source required',
        message: 'Custom connectors can only be added from an approved source.',
        action: close == null
            ? null
            : OButton(
                label: 'Back to connectors',
                icon: Icons.arrow_back_rounded,
                onPressed: close,
              ),
      );
    }
    final c = OColors.of(context);
    return ListView(
      padding: const EdgeInsets.only(top: OSpace.l, bottom: OSpace.xxl),
      children: [
        if (widget.data.planLimitReached) ...[
          _CapLine(message: widget.data.capMessage, onUpgrade: _openUpgrade),
          const SizedBox(height: OSpace.l),
        ],
        TextField(
          key: const Key('add-connector-name'),
          controller: _name,
          textInputAction: TextInputAction.next,
          style: OType.bodySm.copyWith(color: c.text),
          decoration: InputDecoration(
            labelText: 'Name',
            errorText: _submitted ? _nameError : null,
          ),
        ),
        if (widget.data.isApprovedCustom) ...[
          const SizedBox(height: OSpace.m),
          Text(
            'Approved source ${widget.data.approvedSourceId}',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
          Text(
            'Digest ${widget.data.approvedDigest}',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ],
        for (final field in widget.data.credentialFields) ...[
          const SizedBox(height: OSpace.m),
          TextField(
            key: Key('connector-credential-${field.key}'),
            controller: _credentialControllers[field.key],
            obscureText: field.secret,
            enableSuggestions: !field.secret,
            autocorrect: false,
            onChanged: (_) => _fieldChanged(),
            style: OType.bodySm.copyWith(color: c.text),
            decoration: InputDecoration(
              labelText: field.label,
              hintText: field.hint,
              errorText:
                  _submitted &&
                      (_credentialControllers[field.key]?.text.trim() ?? '')
                          .isEmpty &&
                      !field.label.toLowerCase().contains('optional')
                  ? 'Enter ${field.label}.'
                  : null,
            ),
          ),
        ],
        if (widget.controller!.capabilities.createAgentEnabled) ...[
          const SizedBox(height: OSpace.l),
          OCard(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Use in agent runs',
                    style: OType.bodyStrong.copyWith(color: c.text),
                  ),
                ),
                Switch(
                  key: const Key('connector-agent-opt-in'),
                  value: _agentEnabled,
                  onChanged: (value) => setState(() => _agentEnabled = value),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: OSpace.s),
        Text(
          widget.controller!.capabilities.createAgentEnabled
              ? 'Off by default. Credentials are sent only to Ovid Cloud.'
              : 'Credentials are sent only to Ovid Cloud.',
          style: OType.caption.copyWith(color: c.textMuted),
        ),
        if (_saveError != null) ...[
          const SizedBox(height: OSpace.m),
          _FieldError(
            key: const Key('connector-save-error'),
            message: _saveError!,
          ),
        ],
      ],
    );
  }
}

/// The plan cap: one line, one upgrade action.
class _CapLine extends StatelessWidget {
  const _CapLine({required this.message, required this.onUpgrade});

  final String message;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      key: const Key('connector-cap-notice'),
      padding: const EdgeInsets.symmetric(
        horizontal: OSpace.m,
        vertical: OSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.warn.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: c.warn),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(message, style: OType.caption.copyWith(color: c.text)),
          ),
          OTextAction(
            key: const Key('connector-cap-upgrade'),
            label: 'Upgrade',
            onPressed: onUpgrade,
          ),
        ],
      ),
    );
  }
}

class _FieldError extends StatelessWidget {
  const _FieldError({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 16, color: c.danger),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              message,
              style: OType.caption.copyWith(color: c.danger),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionSwitchRow extends StatelessWidget {
  const _PermissionSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: OSpace.s),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: OType.bodyStrong.copyWith(color: c.text),
              ),
            ),
            const SizedBox(width: OSpace.m),
            SizedBox(
              height: OSpace.touch,
              child: Switch(value: value, onChanged: onChanged),
            ),
          ],
        ),
      ),
    );
  }
}

class _TestResult extends StatelessWidget {
  const _TestResult({
    required this.ok,
    required this.message,
    this.neutral = false,
  });

  final bool ok;
  final String message;

  /// A truthful "we cannot test this from here" result, shown in muted text
  /// instead of red or green.
  final bool neutral;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final color = neutral ? c.textMuted : (ok ? c.success : c.danger);
    final icon = neutral
        ? Icons.info_outline_rounded
        : (ok
              ? Icons.check_circle_outline_rounded
              : Icons.error_outline_rounded);
    final text = message.isNotEmpty
        ? message
        : ok
        ? 'Connection works.'
        : 'Could not reach that server.';
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(text, style: OType.caption.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}
