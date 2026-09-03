import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'agent_service.dart';
import 'presets.dart';
import 'session_ledger.dart';
import 'state.dart';

/// ── Composer command system ──────────────────────────────────────────────
/// Slash commands are first-class actions parsed from the composer input.
/// A command either:
///   • executes immediately (returns a result the UI displays), or
///   • rewrites the user input into a prompt handed to the agent.
///   • opens an overlay picker instead of replying with text (popupSelect).
class CommandResult {
  final String? prompt; // when set, send this to the agent instead
  final String? feedback; // user-visible confirmation/error
  final bool clearInput;

  /// popupSelect (DSH parity): 'model' or 'permission' — the UI opens the
  /// matching overlay picker instead of showing feedback text.
  final String? popup;
  const CommandResult({
    this.prompt,
    this.feedback,
    this.clearInput = true,
    this.popup,
  });
}

class AgentCommand {
  final String name;
  final String description;
  final String hint;
  final Future<CommandResult> Function(String args) handler;
  AgentCommand({
    required this.name,
    required this.description,
    this.hint = '',
    required this.handler,
  });
}

class CommandService {
  CommandService._();
  static final CommandService I = CommandService._();

  final Map<String, AgentCommand> _commands = {};

  void register(AgentCommand command) {
    _commands[command.name.toLowerCase()] = command;
  }

  AgentCommand? find(String name) => _commands[name.toLowerCase()];

  List<AgentCommand> get commands => _commands.values.toList();

  /// Parse a composer line. Returns null when the line is not a command.
  /// Command grammar: slash at byte 0, name [a-z0-9_-]+, then raw args.
  static ({String name, String args})? parse(String line) {
    if (!line.startsWith('/')) return null;
    final body = line.substring(1);
    final match = RegExp(r'^[a-z0-9_-]+').firstMatch(body);
    if (match == null) return null;
    final name = match.group(0)!;
    final args = body.substring(match.end).trim();
    return (name: name, args: args);
  }

  Future<CommandResult?> execute(String line) async {
    final parsed = parse(line);
    if (parsed == null) return null;
    final cmd = find(parsed.name);
    if (cmd == null) return null;
    return cmd.handler(parsed.args);
  }

  /// Register the built-in commands (called once from AgentService ctor).
  void registerBuiltins() {
    register(
      AgentCommand(
        name: 'help',
        description: 'List all commands',
        handler: (args) async {
          final buf = StringBuffer('**Commands**\n');
          for (final c in _commands.values) {
            buf.writeln(
              '/${c.name}'
              '${c.hint.isEmpty ? '' : ' ${c.hint}'} — ${c.description}',
            );
          }
          return CommandResult(feedback: buf.toString());
        },
      ),
    );

    register(
      AgentCommand(
        name: 'new',
        description: 'Start a new session',
        handler: (args) async {
          AppState.I.newSession();
          return CommandResult(feedback: 'New session started.');
        },
      ),
    );

    register(
      AgentCommand(
        name: 'clear',
        description: 'Clear the current session messages',
        handler: (args) async {
          final s = AppState.I.activeSession;
          if (s == null) return CommandResult(feedback: 'No active session.');
          AppState.I.deleteMessagesFrom(s.id, 0);
          return CommandResult(feedback: 'Session cleared.');
        },
      ),
    );

    register(
      AgentCommand(
        name: 'compact',
        description: 'Summarize the current session now',
        handler: (args) async {
          final s = AppState.I.activeSession;
          final p = AppState.I.providerForSession(s);
          if (s == null || p == null) {
            return const CommandResult(
              feedback: 'Select a provider and model first.',
            );
          }
          // PR26/C5: DSH /compact is idle-only (busy|changed error codes)
          // — compacting under a live run would race the loop's own
          // compaction + rewrite history it is iterating.
          if (AgentService.I.busyFor(s.id)) {
            return const CommandResult(
              feedback: 'Session is busy — /compact runs on an idle chat '
                  '(queue it as a message instead).',
            );
          }
          // PR29: compactNow returns an HONEST status line — the old
          // forceCompact path silently did nothing on short/already-
          // compacted chats while the command claimed success.
          final status = await AgentService.I.compactNow(s, p);
          return CommandResult(feedback: status);
        },
      ),
    );

    register(
      AgentCommand(
        name: 'plan',
        hint: '[message|off]',
        description: 'Enter plan mode; /plan off exits',
        handler: (args) async {
          final agent = AgentService.I;
          if (args.trim().toLowerCase() == 'off') {
            agent.planMode = false;
            return const CommandResult(feedback: 'Plan mode off.');
          }
          agent.planMode = true;
          final msg = args.trim().isEmpty
              ? 'Plan the next step. Explore first, then call exit_plan_mode with your plan.'
              : args.trim();
          return CommandResult(prompt: msg, feedback: 'Plan mode on.');
        },
      ),
    );

    register(
      AgentCommand(
        name: 'preset',
        hint: '[standard|minimal|studio|code]',
        description: 'Show or switch this chat\'s agent preset',
        handler: (args) async {
          final app = AppState.I;
          final s = app.activeSession;
          if (s == null) return const CommandResult(feedback: 'No active session.');
          final q = args.trim().toLowerCase();
          if (q.isEmpty) {
            final buf = StringBuffer('**Presets** (current: ${s.presetId})\n');
            for (final p in PresetRegistry.all) {
              buf.writeln('- ${p.id} (${p.label}) — ${p.description}');
            }
            return CommandResult(feedback: buf.toString());
          }
          final match = PresetRegistry.all
              .where((p) => p.id == q)
              .firstOrNull;
          if (match == null) {
            return CommandResult(
              feedback: 'Unknown preset "$q". Options: '
                  '${PresetRegistry.all.map((p) => p.id).join(', ')}.',
            );
          }
          if (s.messages.isNotEmpty) {
            return const CommandResult(
              feedback: 'This chat already has messages — switch presets on '
                  'a blank session (/new) or use a fresh chat, DSH-style.',
            );
          }
          s.presetId = match.id;
          app.persistSessions();
          app.refresh();
          return CommandResult(
            feedback: 'Preset → ${match.id} (${match.label}) — '
                '${match.description}',
          );
        },
      ),
    );

    register(
      AgentCommand(
        name: 'model',
        hint: '[name]',
        description: 'Show or switch the model for this chat',
        handler: (args) async {
          final app = AppState.I;
          final s = app.activeSession;
          if (s == null) return const CommandResult(feedback: 'No active session.');
          final q = args.trim();
          if (q.isEmpty) {
            // popupSelect: bare /model opens the picker overlay (DSH).
            return const CommandResult(popup: 'model');
          }
          // Match on the model id, case-insensitively, across configured
          // providers; a substring match is enough to be useful on mobile.
          final needle = q.toLowerCase();
          for (final p in app.providers.where((p) => p.isConfigured)) {
            for (final m in p.models) {
              final lower = m.toLowerCase();
              if (lower == needle || lower.contains(needle)) {
                app.setModel(p.id, m);
                return CommandResult(feedback: 'Model → $m (${p.name})');
              }
            }
          }
          return CommandResult(
            feedback:
                'No configured model matches "$q". Run `/model` to list them.',
          );
        },
      ),
    );

    register(
      AgentCommand(
        name: 'permission',
        hint: '[read-only|general|studio|full-access]',
        description: 'Show or set what the agent may do in this chat',
        handler: (args) async {
          final agent = AgentService.I;
          final raw = args.trim().toLowerCase().replaceAll('_', '-');
          // First token is the preset; anything after it is a flag
          // (currently only `confirm` for full access).
          final parts = raw.split(RegExp(r'\s+')).where((e) => e.isNotEmpty);
          final q = parts.isEmpty ? '' : parts.first;
          final flags = parts.skip(1).toSet();
          if (q.isEmpty) {
            // popupSelect: bare /permission opens the mode sheet (DSH).
            return const CommandResult(popup: 'permission');
          }
          final target = AgentMode.values.firstWhere(
            (m) => _permName(m) == q || m.name == q,
            orElse: () => agent.mode,
          );
          if (_permName(target) != q && target.name != q) {
            return CommandResult(
              feedback:
                  'Unknown preset "$q". Options: '
                  '${AgentMode.values.map(_permName).join(', ')}.',
            );
          }
          if (target == AgentMode.drive && !flags.contains('confirm')) {
            // Full access removes every confirmation, so it is opt-in with an
            // explicit acknowledgement rather than a single word.
            return const CommandResult(
              feedback:
                  'Full Access lets the agent run anything with no '
                  'confirmation, including destructive commands and repo '
                  'pushes. Re-run `/permission full-access confirm` to '
                  'accept that risk.',
            );
          }
          agent.mode = target;
          return CommandResult(feedback: 'Permission → ${target.label}');
        },
      ),
    );

    register(
      AgentCommand(
        name: 'export',
        description: 'Export all sessions as a ZIP (sessions, ledgers, spill)',
        handler: (args) async {
          try {
            final file = await _exportSessionsZip();
            return CommandResult(feedback: 'Exported to:\n${file.path}');
          } catch (e) {
            return CommandResult(feedback: 'Export failed: $e');
          }
        },
      ),
    );

    register(
      AgentCommand(
        name: 'feedback',
        hint: '<text>',
        description: 'Record feedback for this build',
        handler: (args) async {
          if (args.trim().isEmpty) {
            return const CommandResult(feedback: 'Feedback needs text.');
          }
          try {
            final dir = await getApplicationDocumentsDirectory();
            final file = File('${dir.path}/feedback.log');
            await file.writeAsString(
              '${DateTime.now().toIso8601String()} $args\n',
              mode: FileMode.append,
            );
            return CommandResult(feedback: 'Feedback recorded. Thank you.');
          } catch (e) {
            return CommandResult(feedback: 'Could not record feedback: $e');
          }
        },
      ),
    );
  }

  /// Kebab-case preset name for `/permission` (Read-Only → read-only).
  static String _permName(AgentMode m) =>
      m.label.toLowerCase().replaceAll(' ', '-');

  /// Test seam: fixed directory for exports (no path_provider channel in
  /// unit tests). When set, [getTemporaryDirectory] is never called.
  @visibleForTesting
  static String? exportDirOverrideForTest;

  /// DSH session-log-export parity: a streamed ZIP containing
  ///   sessions.json          — every session with full messages
  ///   ledgers/`<id>`.jsonl   — the append-only event ledger per session
  /// plus a manifest. Descendants (subagent children) are inside their
  /// parent's session JSON by construction (lineage fields).
  Future<File> _exportSessionsZip() async {
    final app = AppState.I;
    final outDir = exportDirOverrideForTest ??
        (await getTemporaryDirectory()).path;
    final file = File(
      '$outDir/ovid-export-${DateTime.now().millisecondsSinceEpoch}.zip',
    );
    final archive = Archive();

    void addText(String path, String text) {
      archive.addFile(ArchiveFile.string(path, text));
    }

    // Manifest first — a reader knows the shape before parsing anything.
    addText(
      'manifest.json',
      const JsonEncoder.withIndent('  ').convert({
        'exportedAt': DateTime.now().toIso8601String(),
        'format': 'ovid-session-export/1',
        'sessions': app.sessions.length,
        'contents': [
          'sessions.json — every session (messages, lineage, goals, todos)',
          'ledgers/<id>.jsonl — append-only event ledger per session',
        ],
      }),
    );

    addText(
      'sessions.json',
      const JsonEncoder.withIndent('  ').convert({
        'exportedAt': DateTime.now().toIso8601String(),
        'sessions': app.sessions.map((s) => s.toJson()).toList(),
      }),
    );

    // Event ledgers (best-effort per session).
    for (final s in app.sessions) {
      final events = await SessionLedger.I.read(s.id);
      if (events.isEmpty) continue;
      final lines = events
          .map((e) => jsonEncode(e))
          .join('\n');
      addText('ledgers/${s.id}.jsonl', lines);
    }

    final bytes = ZipEncoder().encode(archive);
    await file.writeAsBytes(bytes);
    return file;
  }
}
