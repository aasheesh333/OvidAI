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
          final idx = s.messages.isEmpty ? 0 : 0;
          AppState.I.deleteMessagesFrom(s.id, idx);
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
