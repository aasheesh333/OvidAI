import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2ConnectorAuth { oauth, apiKey, none }

enum V2ConnectorPermissionKind { read, write, execute }

enum V2AddConnectorStatus { loading, content, error, blocked }

/// A custom connector can point at a server URL or run a command. The command
/// form is still checked against the safe-install policy below.
enum V2ConnectorTarget { url, command }

/// The custom-connector allowance that comes with each plan.
enum V2ConnectorPlan {
  free('Free', 0),
  go('Go', 5),
  plus('Plus', 20),
  pro('Pro', 20);

  const V2ConnectorPlan(this.label, this.customConnectorLimit);

  final String label;
  final int customConnectorLimit;
}

/// True when text is large enough that a trailing action has to move to its
/// own line on a narrow phone.
bool _stacksActions(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(14) >= 14 * 1.3;

/// The safe-install rules for a custom connector.
///
/// A custom entry may not carry shell metacharacters, and any path it names
/// must stay inside the session workspace. This is deliberately a pure
/// function so the screen and the wiring layer share one rule.
abstract final class V2ConnectorSafety {
  static const workspaceRoot = '/workspace';

  static const _shellMessage =
      'Remove shell characters like ; & | \$ ` > < from the URL or command.';
  static const _pathMessage =
      'Use a path inside your workspace. Paths like ../ or /etc are not allowed.';

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

      for (final match in RegExp(r'''(^|\s)("[^"]*"|'[^']*'|[^\s]+)''').allMatches(text)) {
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
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return 'Use a full URL that starts with https://.';
    }
    if (uri.host.isEmpty) {
      return 'Enter a full server URL, like https://api.example.com.';
    }
    if (uri.path.contains('..')) return _pathMessage;
    return null;
  }
}

/// Convenience wrapper for callers that prefer a top-level function.
String? validateConnectorEndpoint({
  required String value,
  required V2ConnectorTarget target,
}) => V2ConnectorSafety.validateEndpoint(value: value, target: target);

/// A catalog suggestion shown above the custom form.
@immutable
class V2ConnectorSuggestion {
  const V2ConnectorSuggestion({
    required this.id,
    required this.name,
    required this.description,
    this.icon = Icons.extension_outlined,
  });

  final String id;
  final String name;
  final String description;
  final IconData icon;
}

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

  String get endpoint =>
      target == V2ConnectorTarget.command ? command : url;
}

/// Injected state for the add-connector screen.
@immutable
class V2AddConnectorData {
  const V2AddConnectorData({
    this.suggestions = const <V2ConnectorSuggestion>[],
    this.auth = V2ConnectorAuth.apiKey,
    this.read = true,
    this.write = true,
    this.execute = false,
    this.status = V2AddConnectorStatus.content,
    this.testing = false,
    this.testResult,
    this.plan = V2ConnectorPlan.free,
    this.customConnectorsUsed = 0,
    this.target = V2ConnectorTarget.url,
    this.planNote = '',
    bool? planLimitReached,
    this.planLimitMessage = '',
    this.authRequiredMessage =
        'This app needs a sign-in. You will sign in after you save.',
    this.errorMessage = 'The catalog did not load.',
    this.chatBlockMessage =
        'Ovid never installs plugins or connectors from a chat message. '
        'You add them here, and only you can turn them on.',
    // ignore: prefer_initializing_formals
  }) : _planLimitReached = planLimitReached;

  final List<V2ConnectorSuggestion> suggestions;
  final V2ConnectorAuth auth;
  final bool read;
  final bool write;
  final bool execute;
  final V2AddConnectorStatus status;
  final bool testing;

  /// Null until the person tests the connection; true when it worked.
  final bool? testResult;

  /// Plan hint from the billing layer. Empty hides the extra note row.
  final String planNote;

  /// The person's plan and how many custom connectors they already have.
  final V2ConnectorPlan plan;
  final int customConnectorsUsed;

  /// Which custom form is open first.
  final V2ConnectorTarget target;

  /// A legacy override. When null the limit comes from [plan] and
  /// [customConnectorsUsed].
  final bool? _planLimitReached;

  final String planLimitMessage;
  final String authRequiredMessage;
  final String errorMessage;
  final String chatBlockMessage;

  int get customLimit => plan.customConnectorLimit;

  bool get planLimitReached =>
      _planLimitReached ?? customConnectorsUsed >= customLimit;

  String get planSummary => switch (plan) {
    V2ConnectorPlan.free =>
      'Custom connectors are not available on the Free plan.',
    V2ConnectorPlan.go =>
      '$customConnectorsUsed of 5 custom connectors used on Go.',
    V2ConnectorPlan.plus =>
      '$customConnectorsUsed of 20 custom connectors used on Plus.',
    V2ConnectorPlan.pro =>
      '$customConnectorsUsed of 20 custom connectors used on Pro.',
  };

  String get resolvedPlanLimitMessage {
    if (planLimitMessage.isNotEmpty) return planLimitMessage;
    return switch (plan) {
      V2ConnectorPlan.free =>
        'Custom connectors are not available on the Free plan. '
            'Upgrade to Go to add up to 5.',
      V2ConnectorPlan.go =>
        'You have used all 5 custom connectors on the Go plan.',
      V2ConnectorPlan.plus || V2ConnectorPlan.pro =>
        'You have used all 20 custom connectors on your plan.',
    };
  }
}

/// Add a connector from the catalog or define a custom one.
class AddConnectorPage extends StatefulWidget {
  const AddConnectorPage({
    super.key,
    required this.data,
    this.onSave,
    this.onTestConnection,
    this.onAddSuggested,
    this.onPermissionChanged,
    this.onAuthChanged,
    this.onUpgrade,
    this.onRetry,
    this.onSearchChanged,
    this.onMenu,
    this.onBack,
  });

  final V2AddConnectorData data;
  final ValueChanged<V2CustomConnectorDraft>? onSave;
  final ValueChanged<V2CustomConnectorDraft>? onTestConnection;
  final ValueChanged<String>? onAddSuggested;
  final void Function(V2ConnectorPermissionKind kind, bool value)?
  onPermissionChanged;
  final ValueChanged<V2ConnectorAuth>? onAuthChanged;
  final VoidCallback? onUpgrade;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onSearchChanged;
  final VoidCallback? onMenu;
  final VoidCallback? onBack;

  @override
  State<AddConnectorPage> createState() => _AddConnectorPageState();
}

class _AddConnectorPageState extends State<AddConnectorPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();
  final TextEditingController _command = TextEditingController();
  final TextEditingController _key = TextEditingController();
  final TextEditingController _catalogSearch = TextEditingController();

  late V2ConnectorAuth _auth = widget.data.auth;
  late bool _read = widget.data.read;
  late bool _write = widget.data.write;
  late bool _execute = widget.data.execute;
  late V2ConnectorTarget _target = widget.data.target;
  bool _showKey = false;
  bool _submitted = false;
  String _query = '';

  String get _endpoint => _target == V2ConnectorTarget.command
      ? _command.text.trim()
      : _url.text.trim();

  String? get _endpointError => V2ConnectorSafety.validateEndpoint(
    value: _endpoint,
    target: _target,
  );

  bool get _showEndpointError =>
      (_submitted || _endpoint.isNotEmpty) && _endpointError != null;

  bool get _canSave =>
      !widget.data.planLimitReached &&
      _name.text.trim().isNotEmpty &&
      _endpointError == null;

  bool get _canTest => !widget.data.planLimitReached && _endpointError == null;

  /// True when the app bar cannot hold the labelled "Save" pill next to the
  /// title: narrow phones, or text at 1.3× or more.
  bool _compactAppBar(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 380 ||
      MediaQuery.textScalerOf(context).scale(14) > 18;

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
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _command.dispose();
    _key.dispose();
    _catalogSearch.dispose();
    super.dispose();
  }

  V2CustomConnectorDraft _draft() {
    final command = _target == V2ConnectorTarget.command
        ? _command.text.trim()
        : '';
    final url = _target == V2ConnectorTarget.url ? _url.text.trim() : '';
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
    );
  }

  void _save() {
    setState(() => _submitted = true);
    if (!_canSave) return;
    widget.onSave?.call(_draft());
  }

  void _test() {
    setState(() => _submitted = true);
    if (!_canTest) return;
    widget.onTestConnection?.call(_draft());
  }

  void _addSuggestion(V2ConnectorSuggestion suggestion) {
    if (_name.text.trim().isEmpty) {
      setState(() => _name.text = suggestion.name);
    }
    widget.onAddSuggested?.call(suggestion.id);
  }

  void _setQuery(String value) {
    setState(() => _query = value.trim().toLowerCase());
    widget.onSearchChanged?.call(value);
  }

  void _clearSearch() {
    _catalogSearch.clear();
    _setQuery('');
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

  void _setTarget(V2ConnectorTarget target) {
    if (_target == target) return;
    setState(() => _target = target);
  }

  @override
  Widget build(BuildContext context) {
    return OScaffold(
      appBar: OAppBar(
        title: 'Add connector',
        actions: [
          // The labelled Save pill leaves no room for the title on a 320 dp
          // screen at large text sizes, which clipped "Add connector". Fall
          // back to the icon control: same action, same 48 dp target, same
          // label for screen readers.
          if (_compactAppBar(context))
            OIconButton(
              icon: Icons.check_rounded,
              semanticLabel: 'Save',
              onPressed: _canSave ? _save : null,
            )
          else
            OButton(
              label: 'Save',
              variant: OButtonVariant.ghost,
              onPressed: _canSave ? _save : null,
            ),
        ],
      ),
      body: ODismissKeyboard(
        child: OFadeSlide(child: _body(context)),
      ),
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

  Widget _blockedState() {
    return OEmptyState(
      icon: Icons.shield_outlined,
      title: 'Plugins are added here, not in chat',
      message: widget.data.chatBlockMessage,
      action: OButton(
        label: 'Back to connectors',
        icon: Icons.arrow_back_rounded,
        onPressed: widget.onBack,
      ),
    );
  }

  Widget _content(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        OSpace.l,
        OSpace.s,
        OSpace.l,
        OSpace.xl,
      ),
      children: [
        _PlanBanner(data: widget.data, onUpgrade: widget.onUpgrade),
        const SizedBox(height: OSpace.m),
        _ChatInstallBlocked(message: widget.data.chatBlockMessage),
        const SizedBox(height: OSpace.xl),
        _catalogSection(context),
        const SizedBox(height: OSpace.xl),
        _customForm(context),
        const SizedBox(height: OSpace.xl),
        _permissions(context),
        const SizedBox(height: OSpace.l),
        _safeInstallNote(context),
        if (widget.data.planNote.isNotEmpty) ...[
          const SizedBox(height: OSpace.l),
          _planNote(context),
        ],
      ],
    );
  }

  Widget _catalogSection(BuildContext context) {
    final c = OColors.of(context);
    final suggestions = widget.data.suggestions.where((suggestion) {
      if (_query.isEmpty) return true;
      return suggestion.name.toLowerCase().contains(_query) ||
          suggestion.description.toLowerCase().contains(_query);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OSectionHeader(
          label: 'From the catalog',
          padding: const EdgeInsets.only(bottom: OSpace.s),
        ),
        OSearchField(
          controller: _catalogSearch,
          hint: 'Search the catalog…',
          onChanged: _setQuery,
          trailing: _query.isEmpty
              ? null
              : OIconButton(
                  icon: Icons.close_rounded,
                  semanticLabel: 'Clear search',
                  onPressed: _clearSearch,
                ),
        ),
        const SizedBox(height: OSpace.m),
        switch (widget.data.status) {
          V2AddConnectorStatus.loading => const SizedBox(
            height: 220,
            child: OSkeletonList(rows: 3),
          ),
          V2AddConnectorStatus.error => SizedBox(
            height: 300,
            child: OErrorState(
              message: widget.data.errorMessage,
              onRetry: widget.onRetry,
            ),
          ),
          V2AddConnectorStatus.blocked => const SizedBox.shrink(),
          V2AddConnectorStatus.content =>
            suggestions.isEmpty
                ? OEmptyState(
                    compact: true,
                    icon: Icons.search_off_rounded,
                    title: 'No suggestions',
                    message:
                        'Try another search, or add a custom connector '
                        'below.',
                    action: OButton(
                      label: 'Clear search',
                      variant: OButtonVariant.secondary,
                      onPressed: _clearSearch,
                    ),
                  )
                : Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(ORadius.l),
                      border: Border.all(color: c.hairline),
                    ),
                    child: OStagger(
                      children: [
                        for (var i = 0; i < suggestions.length; i++) ...[
                          if (i > 0) Divider(color: c.hairline, height: 1),
                          _SuggestionRow(
                            suggestion: suggestions[i],
                            onAdd: () => _addSuggestion(suggestions[i]),
                          ),
                        ],
                      ],
                    ),
                  ),
        },
      ],
    );
  }

  Widget _customForm(BuildContext context) {
    final c = OColors.of(context);
    final isCommand = _target == V2ConnectorTarget.command;
    final blocked = widget.data.planLimitReached;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OSectionHeader(
          label: 'Custom connector',
          padding: const EdgeInsets.only(bottom: OSpace.s),
        ),
        OCard(
          padding: const EdgeInsets.all(OSpace.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'How should Ovid reach it?',
                style: OType.label.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.s),
              _TargetSelector(selected: _target, onChanged: _setTarget),
              const SizedBox(height: OSpace.m),
              TextField(
                key: const Key('add-connector-name'),
                controller: _name,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                style: OType.bodySm.copyWith(color: c.text),
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Internal Analytics API',
                ),
              ),
              const SizedBox(height: OSpace.m),
              TextField(
                key: Key(
                  isCommand ? 'add-connector-command' : 'add-connector-url',
                ),
                controller: isCommand ? _command : _url,
                keyboardType: isCommand
                    ? TextInputType.text
                    : TextInputType.url,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                style: OType.bodySm.copyWith(color: c.text),
                decoration: InputDecoration(
                  labelText: isCommand ? 'Command' : 'Server URL',
                  hintText: isCommand
                      ? 'node /workspace/server.js'
                      : 'https://api.internal.company.com/v1',
                ),
              ),
              const SizedBox(height: OSpace.s),
              Text(
                isCommand
                    ? 'Use a command and paths inside your workspace.'
                    : 'Use a full https:// URL. No shell characters.',
                style: OType.caption.copyWith(color: c.textMuted),
              ),
              if (_showEndpointError) ...[
                const SizedBox(height: OSpace.s),
                _FieldError(
                  key: const Key('custom-connector-error'),
                  message: _endpointError!,
                ),
              ],
              const SizedBox(height: OSpace.l),
              Text(
                'Authentication',
                style: OType.label.copyWith(color: c.textMuted),
              ),
              const SizedBox(height: OSpace.s),
              _AuthSelector(
                selected: _auth,
                onChanged: (auth) {
                  setState(() => _auth = auth);
                  widget.onAuthChanged?.call(auth);
                },
              ),
              if (_auth == V2ConnectorAuth.apiKey) ...[
                const SizedBox(height: OSpace.m),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const Key('add-connector-key'),
                        controller: _key,
                        obscureText: !_showKey,
                        style: OType.bodySm.copyWith(color: c.text),
                        decoration: const InputDecoration(
                          labelText: 'API key',
                          hintText: 'Paste the key from that app',
                        ),
                      ),
                    ),
                    const SizedBox(width: OSpace.s),
                    OIconButton(
                      icon: _showKey
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      semanticLabel: _showKey ? 'Hide key' : 'Show key',
                      onPressed: () => setState(() => _showKey = !_showKey),
                    ),
                  ],
                ),
                const SizedBox(height: OSpace.s),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.key_outlined, size: 15, color: c.textMuted),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Text(
                        'This connector needs an API key before it can '
                        'connect.',
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
              if (_auth == V2ConnectorAuth.oauth) ...[
                const SizedBox(height: OSpace.m),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 15,
                      color: c.textMuted,
                    ),
                    const SizedBox(width: OSpace.s),
                    Expanded(
                      child: Text(
                        widget.data.authRequiredMessage,
                        style: OType.caption.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: OSpace.l),
              OButton(
                label: 'Test connection',
                icon: Icons.sync_rounded,
                variant: OButtonVariant.secondary,
                expand: true,
                loading: widget.data.testing,
                onPressed: blocked || !_canTest ? null : _test,
              ),
              if (widget.data.testResult != null) ...[
                const SizedBox(height: OSpace.m),
                _TestResult(ok: widget.data.testResult!),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _permissions(BuildContext context) {
    final c = OColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OSectionHeader(
          label: 'Permissions',
          padding: const EdgeInsets.only(bottom: OSpace.s),
        ),
        OCard(
          child: Column(
            children: [
              _PermissionSwitchRow(
                title: 'Read data',
                description: 'Query schemas, view records, inspect tables',
                value: _read,
                onChanged: (value) =>
                    _setPermission(V2ConnectorPermissionKind.read, value),
              ),
              Divider(color: c.hairline, height: 1),
              _PermissionSwitchRow(
                title: 'Write & update',
                description: 'Insert objects and update existing records',
                value: _write,
                onChanged: (value) =>
                    _setPermission(V2ConnectorPermissionKind.write, value),
              ),
              Divider(color: c.hairline, height: 1),
              _PermissionSwitchRow(
                title: 'Execute actions',
                description: 'Trigger webhooks and run batch jobs',
                value: _execute,
                onChanged: (value) =>
                    _setPermission(V2ConnectorPermissionKind.execute, value),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _safeInstallNote(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      key: const Key('safe-install-note'),
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
              color: c.success.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.verified_user_outlined, size: 18, color: c.success),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Safe install',
                  style: OType.label.copyWith(color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  'We check every custom connector before it is saved: no '
                  'shell characters, no paths outside your workspace, and a '
                  'connection test first. Only add servers you trust.',
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _planNote(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
        OSpace.m,
        OSpace.s,
        OSpace.s,
        OSpace.s,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(ORadius.m),
        border: Border.all(color: c.hairline),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: c.textMuted),
          const SizedBox(width: OSpace.s),
          Expanded(
            child: Text(
              widget.data.planNote,
              style: OType.caption.copyWith(color: c.textMuted),
            ),
          ),
          OButton(
            label: 'Upgrade',
            variant: OButtonVariant.ghost,
            onPressed: widget.onUpgrade,
          ),
        ],
      ),
    );
  }
}

class _PlanBanner extends StatelessWidget {
  const _PlanBanner({required this.data, this.onUpgrade});

  final V2AddConnectorData data;
  final VoidCallback? onUpgrade;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    final blocked = data.planLimitReached;
    final color = blocked ? c.warn : c.accent;
    final message = blocked ? data.resolvedPlanLimitMessage : data.planSummary;
    final upgrade = OButton(
      label: 'Upgrade',
      variant: OButtonVariant.ghost,
      onPressed: onUpgrade,
    );
    final copy = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          blocked ? 'Plan limit reached' : 'Custom connectors',
          style: OType.label.copyWith(color: c.text),
        ),
        const SizedBox(height: 2),
        Text(message, style: OType.caption.copyWith(color: c.textMuted)),
        if (!blocked && data.plan != V2ConnectorPlan.free) ...[
          const SizedBox(height: 2),
          Text(
            '${data.customLimit - data.customConnectorsUsed} slots left.',
            style: OType.caption.copyWith(color: c.textMuted),
          ),
        ],
      ],
    );
    return Container(
      key: const Key('connector-plan-banner'),
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: _stacksActions(context)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      blocked
                          ? Icons.lock_outline_rounded
                          : Icons.tune_rounded,
                      size: 18,
                      color: color,
                    ),
                    const SizedBox(width: OSpace.m),
                    Expanded(child: copy),
                  ],
                ),
                if (blocked || data.plan == V2ConnectorPlan.free) ...[
                  const SizedBox(height: OSpace.s),
                  Align(alignment: Alignment.centerRight, child: upgrade),
                ],
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  blocked ? Icons.lock_outline_rounded : Icons.tune_rounded,
                  size: 18,
                  color: color,
                ),
                const SizedBox(width: OSpace.m),
                Expanded(child: copy),
                if (blocked || data.plan == V2ConnectorPlan.free) ...[
                  const SizedBox(width: OSpace.s),
                  upgrade,
                ],
              ],
            ),
    );
  }
}

class _ChatInstallBlocked extends StatelessWidget {
  const _ChatInstallBlocked({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      key: const Key('chat-install-blocked'),
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
              color: c.accentSoft,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.forum_outlined, size: 18, color: c.accent),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You add plugins here, not in chat',
                  style: OType.label.copyWith(color: c.text),
                ),
                const SizedBox(height: 2),
                Text(message, style: OType.caption.copyWith(color: c.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TargetSelector extends StatelessWidget {
  const _TargetSelector({required this.selected, required this.onChanged});

  final V2ConnectorTarget selected;
  final ValueChanged<V2ConnectorTarget> onChanged;

  static String _label(V2ConnectorTarget target) => switch (target) {
    V2ConnectorTarget.url => 'Server address',
    V2ConnectorTarget.command => 'Command',
  };

  static IconData _icon(V2ConnectorTarget target) => switch (target) {
    V2ConnectorTarget.url => Icons.link_rounded,
    V2ConnectorTarget.command => Icons.terminal_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Two segments fit on a normal phone; at large text they stack so the
        // labels stay readable instead of clipping.
        final wideEnough =
            constraints.maxWidth >= 240 &&
            MediaQuery.textScalerOf(context).scale(14) <= 18;
        final segment = wideEnough
            ? (constraints.maxWidth - OSpace.s) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: OSpace.s,
          runSpacing: OSpace.s,
          children: [
            for (final target in V2ConnectorTarget.values)
              SizedBox(
                width: segment,
                child: _TargetChoice(
                  key: Key('target-${target.name}'),
                  label: _label(target),
                  icon: _icon(target),
                  selected: selected == target,
                  onTap: () => onChanged(target),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TargetChoice extends StatelessWidget {
  const _TargetChoice({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      selected: selected,
      child: OPressable(
        onTap: onTap,
        semanticLabel: label,
        child: AnimatedContainer(
          duration: OMotion.fast,
          curve: OMotion.standard,
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.s,
            vertical: OSpace.s,
          ),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? c.accentSoft : c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: selected ? c.accentFill : c.hairline),
          ),
          child: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: selected ? c.accent : c.textMuted),
                const SizedBox(width: OSpace.xs),
                Flexible(
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: OType.label.copyWith(
                      color: selected ? c.accent : c.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
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

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({required this.suggestion, required this.onAdd});

  final V2ConnectorSuggestion suggestion;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
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
              border: Border.all(color: c.hairline),
            ),
            child: Icon(suggestion.icon, size: 18, color: c.textMuted),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  suggestion.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.bodyStrong.copyWith(color: c.text),
                ),
                Text(
                  suggestion.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: OSpace.s),
          OButton(
            label: 'Add',
            icon: Icons.add_rounded,
            variant: OButtonVariant.secondary,
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}

class _AuthSelector extends StatelessWidget {
  const _AuthSelector({required this.selected, required this.onChanged});

  final V2ConnectorAuth selected;
  final ValueChanged<V2ConnectorAuth> onChanged;

  static String _label(V2ConnectorAuth auth) => switch (auth) {
    V2ConnectorAuth.oauth => 'OAuth',
    V2ConnectorAuth.apiKey => 'API key',
    V2ConnectorAuth.none => 'None',
  };

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Three segments side by side is the reference layout, but on a narrow
        // phone at large text sizes a segment is too narrow for "API key" and
        // the label would be cut. Stack the choices full width instead.
        final wideEnough =
            constraints.maxWidth >= 240 &&
            MediaQuery.textScalerOf(context).scale(14) <= 18;
        final segment = wideEnough
            ? (constraints.maxWidth - OSpace.s * 2) / 3
            : constraints.maxWidth;
        return Wrap(
          spacing: OSpace.s,
          runSpacing: OSpace.s,
          children: [
            for (final auth in V2ConnectorAuth.values)
              SizedBox(
                width: segment,
                child: _AuthChoice(
                  label: _label(auth),
                  selected: selected == auth,
                  onTap: () => onChanged(auth),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _AuthChoice extends StatelessWidget {
  const _AuthChoice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Semantics(
      selected: selected,
      child: OPressable(
        onTap: onTap,
        semanticLabel: label,
        child: AnimatedContainer(
          duration: OMotion.fast,
          curve: OMotion.standard,
          constraints: const BoxConstraints(minHeight: OSpace.touch),
          padding: const EdgeInsets.symmetric(
            horizontal: OSpace.s,
            vertical: OSpace.s,
          ),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? c.accentSoft : c.surfaceAlt,
            borderRadius: BorderRadius.circular(ORadius.m),
            border: Border.all(color: selected ? c.accentFill : c.hairline),
          ),
          child: ExcludeSemantics(
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: OType.label.copyWith(
                color: selected ? c.accent : c.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PermissionSwitchRow extends StatelessWidget {
  const _PermissionSwitchRow({
    required this.title,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: OSpace.s),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: OType.bodyStrong.copyWith(color: c.text)),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: OSpace.m),
          Semantics(
            label: title,
            child: SizedBox(
              height: OSpace.touch,
              child: Switch(value: value, onChanged: onChanged),
            ),
          ),
        ],
      ),
    );
  }
}

class _TestResult extends StatelessWidget {
  const _TestResult({required this.ok});

  final bool ok;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
          size: 18,
          color: ok ? c.success : c.danger,
        ),
        const SizedBox(width: OSpace.s),
        Expanded(
          child: Text(
            ok
                ? 'Connection works. You can save this connector.'
                : 'Could not reach that server. Check the URL and try again.',
            style: OType.caption.copyWith(color: ok ? c.success : c.danger),
          ),
        ),
      ],
    );
  }
}
