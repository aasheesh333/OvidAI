

import 'cloud/cloud_agent_facade.dart';
import 'cloud/models.dart';
import 'native_share.dart';
import 'presets.dart';
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

  /// popupSelect (the command parser parity): 'model' or 'permission' — the UI opens the
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
  static CommandService? _instance;

  /// The process-wide registry, initialized with the built-in commands on
  /// first use. The retired local service used to do this in its constructor
  /// (P8 Task 19); lazy initialization keeps the registry usable from tests
  /// and from the first composer keystroke without a boot-order dependency.
  static CommandService get I => _instance ??= (CommandService._()..registerBuiltins());

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

  /// Register the built-in commands (called once at app start).
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
        description: 'Start a fresh chat (this one stays in your history)',
        handler: (args) async {
          // CH-025: cloud chats keep their history server-side, so "clear"
          // honestly means a fresh context — a new chat. Nothing is deleted.
          AppState.I.newSession();
          return const CommandResult(
            feedback: 'Started a new chat. The previous one is in your history.',
          );
        },
      ),
    );

    register(
      AgentCommand(
        name: 'compact',
        hint: '[focus instructions]',
        description:
            'Compact the context now (keeps every user message + the work '
            'log); optional focus text steers the summary',
        handler: (args) async {
          final s = AppState.I.activeSession;
          if (s == null) {
            return const CommandResult(feedback: 'No active session.');
          }
          // PR26/C5: /compact is idle-only — compacting under a live run
          // would race the loop's own compaction.
          if (CloudAgentFacade.I.busyFor(s.id)) {
            return const CommandResult(
              feedback:
                  'Session is busy — /compact runs on an idle chat '
                  '(queue it as a message instead).',
            );
          }
          // CH-025: Ovid Cloud implements /compact — forward it verbatim;
          // the server's answer (and its compaction event) is the result.
          final focus = args.trim();
          return CommandResult(
            prompt: focus.isEmpty ? '/compact' : '/compact $focus',
          );
        },
      ),
    );

    register(
      AgentCommand(
        name: 'plan',
        hint: '[message|off]',
        description:
            'Enter plan mode (research-first, read-only); /plan off exits',
        handler: (args) async {
          final agent = CloudAgentFacade.I;
          if (args.trim().toLowerCase() == 'off') {
            // The Plan chip rides every send (CT-001): the server leaves
            // plan mode with the next message.
            agent.planMode = false;
            return const CommandResult(
              feedback: 'Plan mode off — applies to your next message.',
            );
          }
          agent.planMode = true;
          final msg = args.trim().isEmpty
              ? 'Research the current directory first, then write a numbered '
                    'plan and call exit_plan_mode to offer switching to the '
                    'build agent.'
              : args.trim();
          // G6: attachments the user already staged in the composer ride along
          // with this prompt — the command must not be a way to lose them. The
          // count is surfaced so the user can see they were kept.
          final staged = agent.pendingAttachments.length;
          return CommandResult(
            prompt: msg,
            feedback: staged == 0
                ? 'Plan mode on.'
                : 'Plan mode on — $staged attachment'
                      '${staged == 1 ? '' : 's'} will be included.',
          );
        },
      ),
    );

    register(
      AgentCommand(
        name: 'preset',
        hint: '[standard|minimal|studio|code|plan]',
        description: 'Show or switch this chat\'s agent preset',
        handler: (args) async {
          final app = AppState.I;
          final s = app.activeSession;
          if (s == null) {
            return const CommandResult(feedback: 'No active session.');
          }
          final q = args.trim().toLowerCase();
          if (q.isEmpty) {
            // popupSelect (the command parser parity with /model and /permission): bare
            // /preset opens the tappable preset sheet instead of a text
            // dump — the list is right there and picking a row applies it.
            return const CommandResult(popup: 'preset');
          }
          final match = PresetRegistry.all.where((p) => p.id == q).firstOrNull;
          if (match == null) {
            return CommandResult(
              feedback:
                  'Unknown preset "$q". Options: '
                  '${PresetRegistry.all.map((p) => p.id).join(', ')}.',
            );
          }
          // Mid-chat switching is safe: the preset is a UI/session policy
          // applied from the next message. The local tool roster it used to
          // drive died with the local service (P8 Task 19); the cloud
          // roster is server-owned. The `plan` preset still owns plan +
          // read-only; any other preset clears that coupling.
          final agent = CloudAgentFacade.I;
          s.presetId = match.id;
          if (match.id == 'plan') {
            agent.planMode = true;
            if (s.mode != AgentMode.safe.name) s.mode = AgentMode.safe.name;
          } else {
            agent.planMode = false;
          }
          await app.persistSessions();
          app.refresh();
          // The preset rides every send (CT-001); the server validates it
          // against its built-in roster.
          return CommandResult(
            feedback:
                'Preset → ${match.id} (${match.label}) — '
                '${match.description} Applies from your next message.',
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
          if (s == null) {
            return const CommandResult(feedback: 'No active session.');
          }
          final q = args.trim();
          if (q.isEmpty) {
            // popupSelect: bare /model opens the picker overlay (the command parser behavior).
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
        hint: '[general|studio|full-access]',
        description: 'Show or set what the agent may do in this chat',
        handler: (args) async {
          final agent = CloudAgentFacade.I;
          final raw = args.trim().toLowerCase().replaceAll('_', '-');
          // First token is the preset; anything after it is a flag
          // (currently only `confirm` for full access).
          final parts = raw.split(RegExp(r'\s+')).where((e) => e.isNotEmpty);
          final q = parts.isEmpty ? '' : parts.first;
          final flags = parts.skip(1).toSet();
          if (q.isEmpty) {
            // popupSelect: bare /permission opens the mode sheet (the command parser behavior).
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
                  '${modeOptionsForPicker().map(_permName).join(', ')}.',
            );
          }
          if (target == AgentMode.drive && !flags.contains('confirm')) {
            // Strong modes are opt-in with an explicit acknowledgement rather
            // than a single word.
            return CommandResult(
              feedback:
                  '${target.label} grants strong permissions. Re-run '
                  '`/permission ${_permName(target)} confirm` to accept '
                  'that risk.',
            );
          }
          agent.setMode(target);
          return CommandResult(feedback: 'Permission → ${target.label}');
        },
      ),
    );

    register(
      AgentCommand(
        name: 'export',
        description: 'Share this chat as a text transcript',
        handler: (args) async {
          // CH-025: cloud chats live in the server projection, not in
          // `ChatSession.messages` — export what the chat actually shows.
          final s = AppState.I.activeSession;
          if (s == null) {
            return const CommandResult(feedback: 'No active session.');
          }
          final rows = CloudAgentFacade.I.transcriptFor(s.id) ?? s.messages;
          final visible = [
            for (final m in rows)
              if (CloudAgentFacade.pendingClientMsgIdOf(m) == null &&
                  m.content.trim().isNotEmpty)
                m,
          ];
          if (visible.isEmpty) {
            return const CommandResult(feedback: 'This chat has no messages yet.');
          }
          final copy = ChatSession(id: s.id, title: s.title, model: s.model);
          copy.messages.addAll(visible);
          try {
            await NativeShare.transcript(copy);
            return const CommandResult(feedback: 'Opening the share sheet…');
          } catch (_) {
            return const CommandResult(
              feedback: 'Could not open the share sheet on this device.',
            );
          }
        },
      ),
    );

    // `/feedback` was removed (CH-025): it wrote a local file nothing ever
    // uploaded. Report a reply with its flag action instead.
  }

  /// Kebab-case preset name for `/permission` (Read-Only → read-only).
  static String _permName(AgentMode m) =>
      m.label.toLowerCase().replaceAll(' ', '-');
}
