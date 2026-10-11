import 'package:flutter/material.dart';

import '../core/mcp_client_requests.dart';
import 'app_router.dart';

/// MCP `elicitation/create` (protocol 2025-06-18): a server asks the user for
/// structured input. The sheet renders the flat primitive schema (string,
/// number, integer, boolean, enum) and returns `accept` with the values,
/// `decline` (the user refused) or `cancel` (dismissed).
Future<McpElicitationResponse> showMcpElicitationSheet(
  BuildContext context,
  McpElicitationRequest request,
) async {
  final result = await showModalBottomSheet<McpElicitationResponse>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => McpElicitationSheet(request: request),
  );
  return result ?? const McpElicitationResponse.cancel();
}

/// Production elicitor: shows the sheet on the app's root navigator, or
/// cancels when no UI is mounted (background / tests).
Future<McpElicitationResponse> appMcpElicitor(
  McpElicitationRequest request,
) async {
  final context = appNavigatorKey.currentContext;
  if (context == null || !context.mounted) {
    return const McpElicitationResponse.cancel();
  }
  return showMcpElicitationSheet(context, request);
}

class McpElicitationSheet extends StatefulWidget {
  const McpElicitationSheet({super.key, required this.request});

  final McpElicitationRequest request;

  @override
  State<McpElicitationSheet> createState() => _McpElicitationSheetState();
}

class _McpElicitationSheetState extends State<McpElicitationSheet> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, Object?> _values = {};

  @override
  void initState() {
    super.initState();
    for (final f in widget.request.fields) {
      final d = f.defaultValue;
      if (f.type == 'boolean') {
        _values[f.name] = d is bool ? d : false;
      } else if (f.enumValues.isNotEmpty) {
        _values[f.name] = d == null ? null : '$d';
      } else {
        _text[f.name] = TextEditingController(text: d == null ? '' : '$d');
      }
    }
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic> _collect() => {
    for (final f in widget.request.fields)
      f.name: _text.containsKey(f.name) ? _text[f.name]!.text : _values[f.name],
  };

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'MCP server "${r.server}" is asking for information',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(r.message),
            const SizedBox(height: 12),
            for (final f in r.fields) _field(f),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const Key('mcp-elicitation-decline'),
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(const McpElicitationResponse.decline()),
                  child: const Text('Decline'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('mcp-elicitation-accept'),
                  onPressed: () => Navigator.of(
                    context,
                  ).pop(McpElicitationResponse.accept(_collect())),
                  child: const Text('Submit'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(McpElicitationField f) {
    final required = widget.request.required.contains(f.name);
    final label = '${f.label}${required ? ' *' : ''}';
    if (f.type == 'boolean') {
      return SwitchListTile(
        key: Key('mcp-elicitation-${f.name}'),
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: f.description == null ? null : Text(f.description!),
        value: _values[f.name] == true,
        onChanged: (v) => setState(() => _values[f.name] = v),
      );
    }
    if (f.enumValues.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: DropdownButtonFormField<String>(
          key: Key('mcp-elicitation-${f.name}'),
          initialValue: _values[f.name] as String?,
          decoration: InputDecoration(
            labelText: label,
            helperText: f.description,
          ),
          items: [
            for (final v in f.enumValues)
              DropdownMenuItem(value: v, child: Text(v)),
          ],
          onChanged: (v) => setState(() => _values[f.name] = v),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key('mcp-elicitation-${f.name}'),
        controller: _text[f.name],
        keyboardType: f.type == 'string'
            ? TextInputType.text
            : const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          helperText: f.description,
        ),
      ),
    );
  }
}
