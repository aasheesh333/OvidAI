import 'package:flutter/foundation.dart';

import 'plan_mode.dart';

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

  /// G3: optional model pin for this preset's runs. When set, the run uses
  /// this model instead of the session's, so the `plan` preset can research on
  /// a cheap fast model without changing the user's chat model. Null = use the
  /// session's model (the previous behaviour).
  final String? model;

  /// G3: optional sampling temperature for this preset's runs. Null = let the
  /// provider default decide (never a synthetic default injected). Skipped on
  /// Anthropic runs that enable a thinking budget, which rejects it.
  final double? temperature;

  /// G5: the preset's OWN plan-mode allowlist. When non-empty it REPLACES the
  /// built-in [PlanModePolicy.allowedTools] while this preset is planning, so
  /// the plan policy becomes user-authorable through the existing custom
  /// preset plumbing instead of a hardcoded set. Empty = built-in policy.
  final List<String> planAllowedTools;

  const AgentPreset({
    required this.id,
    required this.label,
    required this.description,
    this.allowedTools = const [],
    this.deniedTools = const [],
    this.persona = '',
    this.model,
    this.temperature,
    this.planAllowedTools = const [],
  });

  factory AgentPreset.fromJson(Map<String, dynamic> json) {
    return AgentPreset(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? json['id'] as String? ?? '',
      description: json['description'] as String? ?? '',
      allowedTools: (json['allowedTools'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      deniedTools: (json['deniedTools'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      persona: json['persona'] as String? ?? '',
      model: (json['model'] as String? ?? '').trim().isEmpty
          ? null
          : (json['model'] as String).trim(),
      temperature: (json['temperature'] as num?)?.toDouble(),
      planAllowedTools:
          (json['planAllowedTools'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'description': description,
    'allowedTools': allowedTools,
    'deniedTools': deniedTools,
    'persona': persona,
    if (model != null) 'model': model,
    if (temperature != null) 'temperature': temperature,
    if (planAllowedTools.isNotEmpty) 'planAllowedTools': planAllowedTools,
  };

  AgentPreset copyWith({
    String? id,
    String? label,
    String? description,
    List<String>? allowedTools,
    List<String>? deniedTools,
    String? persona,
    String? model,
    double? temperature,
    List<String>? planAllowedTools,
    bool clearModel = false,
    bool clearTemperature = false,
  }) {
    return AgentPreset(
      id: id ?? this.id,
      label: label ?? this.label,
      description: description ?? this.description,
      allowedTools: allowedTools ?? this.allowedTools,
      deniedTools: deniedTools ?? this.deniedTools,
      persona: persona ?? this.persona,
      model: clearModel ? null : (model ?? this.model),
      temperature: clearTemperature
          ? null
          : (temperature ?? this.temperature),
      planAllowedTools: planAllowedTools ?? this.planAllowedTools,
    );
  }
}

/// Central registry. IDs are stable (persisted on sessions as
/// `presetId`); unknown ids fall back to standard.
class PresetRegistry {
  /// Shared result-format guidance appended to every built-in persona: the
  /// final message is what the user SEES — lead with the answer, keep
  /// results as a visible markdown block, never bury them in reasoning.
  static const resultFormatGuidance =
      ' Lead with the answer. Present results as a visible markdown block '
      '(short bullets or code), never buried inside reasoning or tool '
      'narration.';

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
    persona:
        'You are a lean agent: prefer direct answers and small file '
        'edits. Do not open browsers or spawn subagents.$resultFormatGuidance',
  );

  /// Studio authoring preset: generation-heavy, wide access, persona
  /// tuned for long-form deliverables in the workspace.
  static const studio = AgentPreset(
    id: 'studio',
    label: 'Studio',
    description: 'Authoring preset — images, web research, files, with a '
        'deliverables-first persona.',
    allowedTools: [],
    persona:
        'You are a studio author. Always end a turn by writing the '
        'deliverable (report/image/code) into the shared workspace, then '
        'summarize what changed and where it lives.$resultFormatGuidance',
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
    persona:
        'You are a coding agent inside the user\'s repository. '
        'Read before editing, keep changes minimal, and never touch '
        'files outside the workspace.$resultFormatGuidance',
  );

  /// Plan preset: the research-first planning policy (opencode `plan`
  /// agent parity). Selecting it turns on plan mode (and the Read-Only
  /// coupling). G4: the dispatch gate and the model-visible roster now read
  /// the SAME policy object — while plan mode is on, `AgentService._tools`
  /// withholds everything [PlanModePolicy] refuses, so the model is never
  /// offered a tool the gate would reject. G5: set [planAllowedTools] on a
  /// custom preset to author your own plan policy.
  static const plan = AgentPreset(
    id: 'plan',
    label: 'Plan',
    description: 'Read-only planning — research the workspace, then propose.',
    allowedTools: [],
    deniedTools: [],
    persona:
        'You are the plan agent, in the READ-ONLY planning phase. Research '
        'the current directory thoroughly BEFORE proposing anything: read '
        'files, glob and grep, inspect git history and diffs, and run '
        'read-only shell commands (ls, cat, find, wc, tree, git log/diff/'
        'status). You may NOT modify anything — no file writes, no edits, no '
        'commits, no commands that change state. When you understand the '
        'problem, write the plan out as a normal message in numbered steps, '
        'then call exit_plan_mode to offer switching to the build agent.$resultFormatGuidance',
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

  static const List<AgentPreset> _builtIn = [
    standard,
    minimal,
    studio,
    code,
    plan,
  ];

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
  /// they are the harness itself, not a capability being gated. G7: the set
  /// now has exactly ONE definition — [PlanModePolicy.harnessTools] — so the
  /// preset roster and the plan-mode roster can never drift apart.
  static const Set<String> _alwaysAllowed = PlanModePolicy.harnessTools;

  /// Test seam (G7): the harness set, which now has exactly one definition.
  @visibleForTesting
  static Set<String> get harnessToolsForTest => _alwaysAllowed;

  /// G5: the plan-mode allowlist in force for [preset]. A preset that declares
  /// its own `planAllowedTools` replaces the built-in policy; otherwise
  /// [PlanModePolicy.allowedTools] applies. ONE resolution point, shared by the
  /// dispatch gate and the roster projection.
  static Set<String> planPolicyFor(AgentPreset preset) =>
      preset.planAllowedTools.isEmpty
      ? PlanModePolicy.allowedTools
      : preset.planAllowedTools.toSet();
}
