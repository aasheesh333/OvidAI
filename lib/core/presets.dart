import 'package:flutter/foundation.dart';

/// One named agent preset (the tool gate agent-presets parity): a tool-roster
/// composition plus a persona preamble. A session joins a preset; the
/// tool gate in AgentService consults the roster on every run so the
/// model only ever sees (and bills for) the tools the preset allows.
@immutable
class AgentPreset {
  final String id;
  final String label;
  final String description;

  /// When non-empty this preset is an ALLOWLIST: only these core tools
  /// run (workflow/ralph/report stay available — orchestration is the
  /// harness, not a capability). When empty nothing is denied (standard).
  final List<String> allowedTools;

  /// When non-empty this preset is a DENYLIST instead.
  final List<String> deniedTools;

  /// Extra persona preamble injected above the base system prompt.
  final String persona;

  const AgentPreset({
    required this.id,
    required this.label,
    required this.description,
    this.allowedTools = const [],
    this.deniedTools = const [],
    this.persona = '',
  });

  factory AgentPreset.fromJson(Map<String, dynamic> json) {
    return AgentPreset(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? json['id'] as String? ?? '',
      description: json['description'] as String? ?? '',
      allowedTools: (json['allowedTools'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      deniedTools: (json['deniedTools'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      persona: json['persona'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'description': description,
    'allowedTools': allowedTools,
    'deniedTools': deniedTools,
    'persona': persona,
  };

  AgentPreset copyWith({
    String? id,
    String? label,
    String? description,
    List<String>? allowedTools,
    List<String>? deniedTools,
    String? persona,
  }) {
    return AgentPreset(
      id: id ?? this.id,
      label: label ?? this.label,
      description: description ?? this.description,
      allowedTools: allowedTools ?? this.allowedTools,
      deniedTools: deniedTools ?? this.deniedTools,
      persona: persona ?? this.persona,
    );
  }
}

/// Central registry. IDs are stable (persisted on sessions as
/// `presetId`); unknown ids fall back to standard.
class PresetRegistry {
  static const standard = AgentPreset(
    id: 'standard',
    label: 'Standard',
    description: 'Full tool roster — the default Ovid agent.',
    allowedTools: [],
    deniedTools: [],
    persona: '',
  );

  /// Lean everyday agent: no browser, no image-gen, no orchestration
  /// fan-out. File + search + memory + git stay.
  static const minimal = AgentPreset(
    id: 'minimal',
    label: 'Minimal',
    description: 'Chat + files + search + memory — no browser, images, '
        'or subagent fan-out.',
    deniedTools: [
      'browser_navigate', 'browser_open', 'browser_evaluate',
      'browser_snapshot', 'browser_read', 'browser_scroll',
      'browser_type', 'browser_click', 'browser_press_key',
      'browser_wait_for', 'browser_resize', 'browser_new_tab',
      'browser_switch_tab', 'browser_list_tabs', 'browser_close_tab',
      'browser_close', 'browser_tabs',
      'generate_image', 'image_gen', 'workflow', 'ralph',
    ],
    persona: 'You are a lean agent: prefer direct answers and small file '
        'edits. Do not open browsers or spawn subagents.',
  );

  /// Studio authoring preset: generation-heavy, wide access, persona
  /// tuned for long-form deliverables in the workspace.
  static const studio = AgentPreset(
    id: 'studio',
    label: 'Studio',
    description: 'Authoring preset — images, web research, files, with a '
        'deliverables-first persona.',
    allowedTools: [],
    persona: 'You are a studio author. Always end a turn by writing the '
        'deliverable (report/image/code) into the shared workspace, then '
        'summarize what changed and where it lives.',
  );

  /// Code preset: repo work only — shell, files, git; no browser or
  /// image generation.
  static const code = AgentPreset(
    id: 'code',
    label: 'Code',
    description: 'Repo work — shell, file edits, git. No browser or '
        'image generation.',
    deniedTools: [
      'browser_navigate', 'browser_open', 'browser_evaluate',
      'browser_snapshot', 'browser_read', 'browser_scroll',
      'browser_type', 'browser_click', 'browser_press_key',
      'browser_wait_for', 'browser_resize', 'browser_new_tab',
      'browser_switch_tab', 'browser_list_tabs', 'browser_close_tab',
      'browser_close', 'browser_tabs',
      'generate_image', 'image_gen',
    ],
    persona: 'You are a coding agent inside the user\'s repository. '
        'Read before editing, keep changes minimal, and never touch '
        'files outside the workspace.',
  );

  static final List<AgentPreset> _custom = [];

  static List<AgentPreset> get customPresets => List.unmodifiable(_custom);

  static void clearCustom() => _custom.clear();

  static void saveCustom(AgentPreset p) {
    _custom.removeWhere((e) => e.id == p.id);
    _custom.add(p);
  }

  static void deleteCustom(String id) => _custom.removeWhere((e) => e.id == id);

  static AgentPreset byId(String id) {
    for (final c in _custom) {
      if (c.id == id) return c;
    }
    return all.firstWhere((p) => p.id == id, orElse: () => standard);
  }

  static const List<AgentPreset> _builtIn = [standard, minimal, studio, code];

  static List<AgentPreset> get all => [..._builtIn, ..._custom];

  /// Catalog block for the system prompt so the model knows which
  /// composition it is running under.
  static String catalogBlock() => all
      .map((p) => '- ${p.id} (${p.label}): ${p.description}')
      .join('\n');

  /// Roster decision: true = tool allowed under this preset.
  static bool allows(AgentPreset preset, String tool) {
    if (preset.allowedTools.isNotEmpty) {
      return preset.allowedTools.contains(tool) ||
          _alwaysAllowed.contains(tool);
    }
    return !preset.deniedTools.contains(tool);
  }

  /// Orchestration + session bookkeeping stay available in every preset:
  /// they are the harness itself, not a capability being gated.
  static const _alwaysAllowed = [
    'dispatch_agent',
    'report',
    'update_goal',
    'get_goal',
    'create_goal',
    'memory_save',
  ];
}
