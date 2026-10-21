import 'package:flutter/material.dart';

import '../../design/o_components.dart';
import '../../design/o_motion.dart';
import '../../design/o_tokens.dart';

// TODO(l10n): move user-facing copy to the ARB files in the next wave.

enum V2ConnectorAuth { oauth, apiKey, none }

enum V2ConnectorPermissionKind { read, write, execute }

enum V2AddConnectorStatus { loading, content, error }

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
  });

  final String name;
  final String url;
  final V2ConnectorAuth auth;
  final String apiKey;
  final bool read;
  final bool write;
  final bool execute;
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
    this.planNote = '',
    this.planLimitReached = false,
    this.planLimitMessage =
        'You have used all custom connectors on the Free plan.',
    this.authRequiredMessage =
        'This app needs a sign-in. You will sign in after you save.',
    this.errorMessage = 'The catalog did not load.',
  });

  final List<V2ConnectorSuggestion> suggestions;
  final V2ConnectorAuth auth;
  final bool read;
  final bool write;
  final bool execute;
  final V2AddConnectorStatus status;
  final bool testing;

  /// Null until the person tests the connection; true when it worked.
  final bool? testResult;

  /// Plan hint from the billing layer. Empty hides the row.
  final String planNote;
  final bool planLimitReached;
  final String planLimitMessage;
  final String authRequiredMessage;
  final String errorMessage;
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

  @override
  State<AddConnectorPage> createState() => _AddConnectorPageState();
}

class _AddConnectorPageState extends State<AddConnectorPage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();
  final TextEditingController _key = TextEditingController();
  final TextEditingController _catalogSearch = TextEditingController();

  late V2ConnectorAuth _auth = widget.data.auth;
  late bool _read = widget.data.read;
  late bool _write = widget.data.write;
  late bool _execute = widget.data.execute;
  bool _showKey = false;
  String _query = '';

  bool get _canSave =>
      !widget.data.planLimitReached &&
      _name.text.trim().isNotEmpty &&
      _url.text.trim().isNotEmpty;

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
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    _catalogSearch.dispose();
    super.dispose();
  }

  V2CustomConnectorDraft _draft() {
    return V2CustomConnectorDraft(
      name: _name.text.trim(),
      url: _url.text.trim(),
      auth: _auth,
      apiKey: _key.text,
      read: _read,
      write: _write,
      execute: _execute,
    );
  }

  void _save() => widget.onSave?.call(_draft());

  void _test() => widget.onTestConnection?.call(_draft());

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
        child: OFadeSlide(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              OSpace.l,
              OSpace.s,
              OSpace.l,
              OSpace.xl,
            ),
            children: [
              _catalogSection(context),
              const SizedBox(height: OSpace.xl),
              _customForm(context),
              const SizedBox(height: OSpace.xl),
              _permissions(context),
              const SizedBox(height: OSpace.l),
              _trustWarning(context),
              if (widget.data.planLimitReached) ...[
                const SizedBox(height: OSpace.l),
                _PlanLimitBanner(
                  message: widget.data.planLimitMessage,
                  onUpgrade: widget.onUpgrade,
                ),
              ],
              if (widget.data.planNote.isNotEmpty) ...[
                const SizedBox(height: OSpace.l),
                _planNote(context),
              ],
            ],
          ),
        ),
      ),
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
                key: const Key('add-connector-url'),
                controller: _url,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                onChanged: (_) => setState(() {}),
                style: OType.bodySm.copyWith(color: c.text),
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'https://api.internal.company.com/v1',
                ),
              ),
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
                onPressed: _test,
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

  Widget _trustWarning(BuildContext context) {
    final c = OColors.of(context);
    return Container(
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
              color: c.warn.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.shield_outlined, size: 18, color: c.warn),
          ),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Text(
              'Custom connectors can act on your behalf. Only add servers '
              'you trust.',
              style: OType.caption.copyWith(color: c.textMuted),
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

class _PlanLimitBanner extends StatelessWidget {
  const _PlanLimitBanner({required this.message, this.onUpgrade});

  final String message;
  final VoidCallback? onUpgrade;

  @override
  Widget build(BuildContext context) {
    final c = OColors.of(context);
    return Container(
      padding: const EdgeInsets.all(OSpace.m),
      decoration: BoxDecoration(
        color: c.warn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(ORadius.l),
        border: Border.all(color: c.warn.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline_rounded, size: 18, color: c.warn),
          const SizedBox(width: OSpace.m),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Plan limit reached',
                  style: OType.label.copyWith(color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: OType.caption.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          OButton(
            label: 'Upgrade',
            variant: OButtonVariant.ghost,
            onPressed: onUpgrade,
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
