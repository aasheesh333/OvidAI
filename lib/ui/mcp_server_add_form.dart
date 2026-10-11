import 'package:flutter/material.dart';

import '../core/mcp_config_parse.dart';
import '../core/state.dart';
import '../core/theme.dart';

/// How a server is described in [McpServerAddForm].
enum McpAddMode { command, remote, json }

/// Splits a typed command line into tokens, honouring single and double
/// quotes and backslash escapes (`npx -y "@scope/pkg" '/sd card'`).
List<String> splitCommandLine(String input) {
  final out = <String>[];
  final buf = StringBuffer();
  String? quote;
  var inToken = false;
  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (c == r'\' && quote == '"' && i + 1 < input.length) {
        buf.write(input[++i]);
      } else {
        buf.write(c);
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      inToken = true;
    } else if (c == r'\' && i + 1 < input.length) {
      buf.write(input[++i]);
      inToken = true;
    } else if (c.trim().isEmpty) {
      if (inToken) {
        out.add(buf.toString());
        buf.clear();
        inToken = false;
      }
    } else {
      buf.write(c);
      inToken = true;
    }
  }
  if (inToken) out.add(buf.toString());
  return out;
}

/// One editable key/value row (env var or HTTP header).
class _KvRow {
  final TextEditingController key;
  final TextEditingController value;
  _KvRow([String k = '', String v = ''])
    : key = TextEditingController(text: k),
      value = TextEditingController(text: v);
  void dispose() {
    key.dispose();
    value.dispose();
  }
}

/// Manual MCP server entry — Claude Code `claude mcp add` parity:
///   • Command: `claude mcp add <name> -- <command> [args…]` with env rows
///   • Remote: `claude mcp add --transport http|sse <name> <url>` with
///     header rows
///   • Paste JSON: `claude mcp add-json` / a Claude Desktop or `.mcp.json`
///     `mcpServers` block, previewed entry by entry (incl. ignored keys)
///
/// Every mode goes through [AppState.addUserMcpServer] (validation, strict
/// secure-storage writes for env/headers); [onAdded] receives the created
/// servers so the caller can connect them.
class McpServerAddForm extends StatefulWidget {
  final Future<void> Function(List<McpServer> servers) onAdded;
  final McpAddMode initialMode;
  const McpServerAddForm({
    super.key,
    required this.onAdded,
    this.initialMode = McpAddMode.command,
  });

  @override
  State<McpServerAddForm> createState() => _McpServerAddFormState();
}

class _McpServerAddFormState extends State<McpServerAddForm> {
  late McpAddMode _mode = widget.initialMode;
  final _name = TextEditingController();
  final _command = TextEditingController();
  final _url = TextEditingController();
  final _json = TextEditingController();
  String _transport = 'http';
  final List<_KvRow> _env = [];
  final List<_KvRow> _headers = [];
  String? _error;
  bool _busy = false;
  List<ImportedMcp> _preview = const [];
  bool _jsonTouched = false;

  @override
  void dispose() {
    for (final c in [_name, _command, _url, _json]) {
      c.dispose();
    }
    for (final r in [..._env, ..._headers]) {
      r.dispose();
    }
    super.dispose();
  }

  Map<String, String> _rows(List<_KvRow> rows) => {
    for (final r in rows)
      if (r.key.text.trim().isNotEmpty) r.key.text.trim(): r.value.text,
  };

  void _parseJson() {
    setState(() {
      _jsonTouched = true;
      _preview = parseMcpConfig(_json.text);
      _error = null;
    });
  }

  String? _previewProblem(ImportedMcp e) {
    final app = AppState.I;
    if (app.mcpServers.any((s) => s.canonicalId == e.name || s.name == e.name)) {
      return 'already exists';
    }
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(e.name)) return 'invalid name';
    return null;
  }

  Future<void> _submit() async {
    if (_busy) return;
    final app = AppState.I;
    setState(() {
      _busy = true;
      _error = null;
    });
    final added = <McpServer>[];
    final errors = <String>[];
    try {
      switch (_mode) {
        case McpAddMode.command:
          final tokens = splitCommandLine(_command.text.trim());
          final r = await app.addUserMcpServer(
            name: _name.text,
            command: tokens.isEmpty ? '' : tokens.first,
            args: tokens.length > 1 ? tokens.sublist(1) : const [],
            env: _rows(_env),
            transport: 'stdio',
          );
          if (r.server != null) added.add(r.server!);
          if (r.error != null) errors.add(r.error!);
        case McpAddMode.remote:
          final r = await app.addUserMcpServer(
            name: _name.text,
            url: _url.text,
            transport: _transport,
            headers: _rows(_headers),
          );
          if (r.server != null) added.add(r.server!);
          if (r.error != null) errors.add(r.error!);
        case McpAddMode.json:
          final entries = parseMcpConfig(_json.text);
          if (entries.isEmpty) {
            errors.add(
              'No MCP servers found. Paste an "mcpServers" object, e.g. '
              '{"mcpServers": {"name": {"command": "npx", "args": […]}}}.',
            );
          }
          for (final e in entries) {
            final r = await app.addUserMcpServer(
              name: e.name,
              command: e.command,
              args: e.args,
              env: e.env,
              url: e.url,
              transport: e.type,
              headers: e.headers,
              cwd: e.cwd,
              startupTimeoutS: e.startupTimeoutS,
              oauth: e.oauth,
            );
            if (r.server != null) added.add(r.server!);
            if (r.error != null) errors.add('${e.name}: ${r.error}');
          }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (added.isEmpty) {
      setState(() => _error = errors.join('\n'));
      return;
    }
    if (errors.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('Skipped: ${errors.join('; ')}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    await widget.onAdded(added);
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
        color: Aether.textFaint,
      ),
    ),
  );

  Widget _kvEditor(
    List<_KvRow> rows, {
    required String kind,
    required String keyHint,
    required String valueHint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  flex: 4,
                  child: TextField(
                    key: ValueKey('mcp-add-$kind-key-$i'),
                    controller: rows[i].key,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontFamily: Aether.mono,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: keyHint,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 5,
                  child: TextField(
                    key: ValueKey('mcp-add-$kind-value-$i'),
                    controller: rows[i].value,
                    obscureText: true,
                    style: const TextStyle(fontSize: 12.5),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: valueHint,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(() => rows.removeAt(i).dispose()),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: ValueKey('mcp-add-$kind-add-row'),
            icon: const Icon(Icons.add, size: 16),
            label: Text(kind == 'env' ? 'Add variable' : 'Add header'),
            onPressed: () => setState(() => rows.add(_KvRow())),
          ),
        ),
      ],
    );
  }

  Widget _jsonPreview() {
    if (!_jsonTouched) return const SizedBox.shrink();
    if (_preview.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          'No MCP servers found in this text.',
          key: const ValueKey('mcp-add-json-empty'),
          style: TextStyle(fontSize: 12, color: Aether.warnLight),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('PREVIEW · ${_preview.length} SERVER'
            '${_preview.length == 1 ? '' : 'S'}'),
        for (final e in _preview)
          Container(
            key: ValueKey('mcp-add-preview-${e.name}'),
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Aether.surfaceAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Aether.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        e.name,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      e.type,
                      style: TextStyle(fontSize: 11, color: Aether.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  e.url ?? [e.command, ...e.args].join(' '),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: Aether.mono,
                    color: Aether.textMuted,
                  ),
                ),
                if (e.env.isNotEmpty)
                  Text(
                    'env: ${e.env.keys.join(', ')}',
                    style: TextStyle(fontSize: 11, color: Aether.textFaint),
                  ),
                if (e.headers.isNotEmpty)
                  Text(
                    'headers: ${e.headers.keys.join(', ')}',
                    style: TextStyle(fontSize: 11, color: Aether.textFaint),
                  ),
                if (e.ignoredKeys.isNotEmpty)
                  Text(
                    'Ignored keys: ${e.ignoredKeys.join(', ')}',
                    key: ValueKey('mcp-add-ignored-${e.name}'),
                    style: TextStyle(fontSize: 11, color: Aether.warnLight),
                  ),
                if (_previewProblem(e) case final problem?)
                  Text(
                    'Will be skipped: $problem',
                    style: TextStyle(fontSize: 11, color: Aether.dangerC),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final nameField = TextField(
      key: const ValueKey('mcp-add-name'),
      controller: _name,
      style: const TextStyle(fontSize: 13.5, fontFamily: Aether.mono),
      decoration: const InputDecoration(
        isDense: true,
        hintText: 'name (letters, digits, - _ .)',
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Add a server by command, by URL, or paste an "mcpServers" config '
          '(Claude Code, Claude Desktop, .mcp.json). Secrets go to secure '
          'storage on this device; the server connects right after.',
          style: TextStyle(fontSize: 12.5, color: Aether.textMuted),
        ),
        const SizedBox(height: 10),
        SegmentedButton<McpAddMode>(
          key: const ValueKey('mcp-add-modes'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: McpAddMode.command, label: Text('Command')),
            ButtonSegment(value: McpAddMode.remote, label: Text('Remote')),
            ButtonSegment(value: McpAddMode.json, label: Text('Paste JSON')),
          ],
          selected: {_mode},
          onSelectionChanged: (v) => setState(() {
            _mode = v.first;
            _error = null;
          }),
        ),
        if (_mode == McpAddMode.command) ...[
          _label('NAME'),
          nameField,
          _label('COMMAND'),
          TextField(
            key: const ValueKey('mcp-add-command'),
            controller: _command,
            style: const TextStyle(fontSize: 13, fontFamily: Aether.mono),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'npx -y @modelcontextprotocol/server-memory',
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Runs inside the on-device sandbox (Studio).',
              style: TextStyle(fontSize: 11, color: Aether.textFaint),
            ),
          ),
          _label('ENVIRONMENT'),
          _kvEditor(
            _env,
            kind: 'env',
            keyHint: 'API_KEY',
            valueHint: 'value (blank = ask on connect)',
          ),
        ] else if (_mode == McpAddMode.remote) ...[
          _label('NAME'),
          nameField,
          _label('URL'),
          TextField(
            key: const ValueKey('mcp-add-url'),
            controller: _url,
            keyboardType: TextInputType.url,
            style: const TextStyle(fontSize: 13, fontFamily: Aether.mono),
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'https://example.com/mcp',
            ),
          ),
          _label('TRANSPORT'),
          SegmentedButton<String>(
            key: const ValueKey('mcp-add-transport'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'http', label: Text('HTTP (streamable)')),
              ButtonSegment(value: 'sse', label: Text('SSE (legacy)')),
            ],
            selected: {_transport},
            onSelectionChanged: (v) => setState(() => _transport = v.first),
          ),
          _label('HEADERS'),
          _kvEditor(
            _headers,
            kind: 'header',
            keyHint: 'Authorization',
            valueHint: 'Bearer …',
          ),
        ] else ...[
          _label('MCP CONFIG JSON'),
          TextField(
            key: const ValueKey('mcp-add-json'),
            controller: _json,
            minLines: 5,
            maxLines: 12,
            onChanged: (_) {
              if (_jsonTouched) _parseJson();
            },
            style: const TextStyle(fontSize: 12, fontFamily: Aether.mono),
            decoration: const InputDecoration(
              hintText:
                  '{"mcpServers": {"memory": {"command": "npx", "args": '
                  '["-y", "@modelcontextprotocol/server-memory"]}}}',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('mcp-add-json-preview'),
              icon: const Icon(Icons.visibility_outlined, size: 16),
              label: const Text('Preview'),
              onPressed: _parseJson,
            ),
          ),
          _jsonPreview(),
        ],
        if (_error != null && _error!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              _error!,
              key: const ValueKey('mcp-add-error'),
              style: TextStyle(fontSize: 12, color: Aether.dangerC),
            ),
          ),
        const SizedBox(height: 14),
        FilledButton.icon(
          key: const ValueKey('mcp-add-submit'),
          style: FilledButton.styleFrom(
            backgroundColor: Aether.accent,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(11),
            ),
          ),
          icon: _busy
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              : const Icon(Icons.power_settings_new, size: 16),
          label: Text(
            _mode == McpAddMode.json && _preview.length > 1
                ? 'Add ${_preview.length} servers & connect'
                : 'Add & connect',
            style: const TextStyle(fontSize: 13.5),
          ),
          onPressed: _busy ? null : _submit,
        ),
      ],
    );
  }
}
