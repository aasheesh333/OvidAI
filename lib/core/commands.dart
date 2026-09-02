import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'agent_service.dart';
import 'state.dart';

/// ── Composer command system ──────────────────────────────────────────────
/// Slash commands are first-class actions parsed from the composer input.
/// A command either:
///   • executes immediately (returns a result the UI displays), or
///   • rewrites the user input into a prompt handed to the agent.
class CommandResult {
  final String? prompt; // when set, send this to the agent instead
  final String? feedback; // user-visible confirmation/error
  final bool clearInput;
  const CommandResult({this.prompt, this.feedback, this.clearInput = true});
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
          await AgentService.I.forceCompact(s, p);
          return CommandResult(feedback: 'Session compacted.');
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
        name: 'model',
        hint: '[name]',
        description: 'Show or switch the model for this chat',
        handler: (args) async {
          final app = AppState.I;
          final s = app.activeSession;
          if (s == null) return const CommandResult(feedback: 'No active session.');
          final q = args.trim();
          if (q.isEmpty) {
            final buf = StringBuffer('**Model** — ${s.model}\n\n');
            var any = false;
            for (final p in app.providers.where((p) => p.isConfigured)) {
              if (p.models.isEmpty) continue;
              any = true;
              buf.writeln('${p.name}: ${p.models.join(', ')}');
            }
            if (!any) {
              buf.writeln(
                'No configured providers yet — add an API key in '
                'Settings → Providers.',
              );
            } else {
              buf.writeln('\nSwitch with `/model <name>`.');
            }
            return CommandResult(feedback: buf.toString());
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
            final buf = StringBuffer(
              '**Permission** — ${agent.mode.label}\n\n',
            );
            for (final m in AgentMode.values) {
              buf.writeln(
                '${_permName(m)}${m == agent.mode ? ' (current)' : ''} — '
                '${m.hint}',
              );
            }
            buf.writeln('\nSet with `/permission <preset>`.');
            return CommandResult(feedback: buf.toString());
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
        description: 'Export all sessions as JSON',
        handler: (args) async {
          try {
            final file = await _exportSessions();
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

  Future<File> _exportSessions() async {
    final app = AppState.I;
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/ovid-sessions-${DateTime.now().millisecondsSinceEpoch}.json',
    );
    final payload = {
      'exportedAt': DateTime.now().toIso8601String(),
      'sessions': app.sessions.map((s) => s.toJson()).toList(),
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    return file;
  }
}
