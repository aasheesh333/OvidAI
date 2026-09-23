// Real, provider-measured per-model context limits.
//
// Every number in this file came out of a provider itself. Two sources:
//
//  * model metadata the gateway serves on `/v1/models` — Inferhub
//    (`input_token_limit`, `max_output_tokens`, `modality`) and KiraAi
//    (`input_limit`, `output_limit`, `input_types`);
//  * ceilings the API spelled out in a 400 body while it was probed live
//    with an oversized prompt or an absurd `max_tokens` — Nvidia NIM
//    (`maximum context length is N`), Experiential Labs (`largest context
//    window on this model route is N`), Apinex (`maximum output limit of
//    N`), Fiqstr (`maximum context length is 990,000`).
//
// Probes were run 2026-09-23 against the keys in the provider catalog.
//
// Anything NOT observed is deliberately absent. A model id missing here
// falls through to `AgentService._contextWindows` and then to
// `defaultContextWindow`, so an unmeasured model can never be credited
// with capacity nobody confirmed. Where two gateways publish different
// numbers for the same bare id (`glm-5.2` is 990,000 tokens on Fiqstr and
// 1,000,000 on Inferhub), each gateway gets its own row and the shared
// table only keeps values they agree on.
class ModelLimits {
  const ModelLimits._();

  /// (input window, max output, accepts images) keyed by exact model id.
  /// A null slot means no gateway told us that number.
  static const Map<String, (int?, int?, bool?)> _measured = {
    'ag/claude-opus-4-6-thinking': (1000000, 128000, true),
    'ag/claude-sonnet-4-6': (1000000, 64000, true),
    'ag/gemini-3.6-flash-high': (1000000, 65536, true),
    'ag/gemini-3.7-flash-high': (1000000, 65536, true),
    'ag/gemini-3.8-flash-high': (1000000, 65536, true),
    'ag/gemini-pro-agent': (1000000, 65536, true),
    'ali/deepseek-v4-flash-0731': (1000000, 393216, false),
    'ali/deepseek-v4-pro-0813': (1000000, 393216, false),
    'ali/deepseek-v4.1-flash': (1000000, 393216, true),
    'ali/glm-5.2': (1000000, 128000, false),
    'ali/glm-5.3': (1000000, 128000, false),
    'ali/kimi-k2.7-code': (262144, null, true),
    'ali/kimi-k3': (1000000, null, true),
    'ali/qwen3.8-flash': (1000000, 131072, true),
    'ali/qwen3.8-max': (1000000, 131072, true),
    'ali/qwen3.8-max-0902': (1000000, 131072, true),
    'ali/qwen3.8-omni-flash': (1000000, 131072, true),
    'cb/claude-opus-4.6': (1000000, 128000, true),
    'cb/claude-opus-4.7-1m': (1000000, 128000, true),
    'cb/claude-opus-5': (1000000, 128000, true),
    'cb/deepseek-v4.1-flash': (1000000, 393216, true),
    'cb/gemini-2.5-flash-image': (null, null, true),
    'cb/gemini-3.0-pro-image': (null, null, true),
    'cb/gemini-3.1-flash-image': (null, null, true),
    'cb/gemini-3.1-pro': (1000000, 65536, true),
    'cb/glm-5.2': (1000000, 128000, false),
    'cb/glm-5.3': (1000000, 128000, false),
    'cb/gpt-5.3-codex': (272000, 128000, true),
    'cb/gpt-5.4': (272000, 128000, true),
    'cb/gpt-5.5': (272000, 128000, true),
    'cb/gpt-5.6-luna': (272000, 128000, true),
    'cb/gpt-5.6-sol': (272000, 128000, true),
    'cb/gpt-5.6-terra': (272000, 128000, true),
    'cb/gpt-6-astra': (272000, 128000, true),
    'cb/gpt-image-2': (null, null, true),
    'cb/hy4-preview': (1000000, 64000, true),
    'cb/kimi-k3': (1000000, null, true),
    'cb/minimax-m3': (1000000, 262144, true),
    'cbcn/deepseek-v4-flash': (1000000, 393216, true),
    'cbcn/deepseek-v4-pro': (1000000, 393216, true),
    'cbcn/deepseek-v4.1-flash': (1000000, 393216, true),
    'cbcn/glm-5.2': (1000000, 128000, true),
    'cbcn/glm-5.3': (1000000, 128000, true),
    'cbcn/glm-5.3-flash': (1000000, 128000, true),
    'cbcn/hy4-preview': (1000000, 64000, true),
    'cbcn/kimi-k2.6': (262144, null, true),
    'cbcn/kimi-k2.7': (262144, null, true),
    'cbcn/kimi-k3': (1000000, null, true),
    'cbcn/minimax-m2.7': (1000000, null, true),
    'cbcn/minimax-m3': (1000000, 262144, true),
    'cc/claude-fable-5': (null, 128000, true),
    'cc/claude-fable-5-1': (null, 128000, true),
    'cc/claude-haiku-4-5': (200000, 64000, true),
    'cc/claude-opus-4-6': (1000000, 128000, true),
    'cc/claude-opus-4-7': (1000000, 128000, true),
    'cc/claude-opus-4-8': (1000000, 128000, true),
    'cc/claude-opus-5': (1000000, 128000, true),
    'cc/claude-opus-5-5': (1000000, 128000, true),
    'cc/claude-sonnet-4-5': (200000, 64000, true),
    'cc/claude-sonnet-4-6': (1000000, 64000, true),
    'cc/claude-sonnet-5': (1000000, 64000, true),
    'claude-fable-5.1': (null, 1048576, null),
    'claude-opus-5': (null, 1048576, null),
    'claude-opus-5.5': (1000000, null, null),
    'claude-sonnet-5': (null, 1048576, null),
    'cmc/deepseek/deepseek-v4-flash': (1000000, 393216, false),
    'cmc/deepseek/deepseek-v4-pro': (1000000, 393216, false),
    'cmc/meta/muse-spark-1.2': (1000000, null, false),
    'cmc/meta/muse-spark-1.2-contributor': (1000000, null, false),
    'cmc/meta/muse-spark-1.3': (1000000, null, false),
    'cmc/meta/muse-spark-1.3-contributor': (1000000, null, false),
    'cmc/minimaxai/minimax-m2.5': (1000000, null, false),
    'cmc/minimaxai/minimax-m2.7': (1000000, null, false),
    'cmc/moonshotai/kimi-k2.6': (262144, null, false),
    'cmc/moonshotai/kimi-k2.7-code': (262144, null, false),
    'cmc/moonshotai/kimi-k3': (1000000, null, false),
    'cmc/qwen/qwen3.6-max-preview': (1000000, 131072, false),
    'cmc/xai/grok-4.5': (500000, null, false),
    'cmc/xai/grok-4.6': (500000, null, false),
    'cmc/z-ai/glm-5.3-flash': (1000000, 128000, false),
    'cmc/zai-org/glm-5.1': (1000000, 128000, false),
    'cmc/zai-org/glm-5.2': (1000000, 128000, false),
    'coding-mimo-v2.6-flash': (1000000, 128000, true),
    'cp/cline-pass/deepseek-v4-flash': (1000000, 393216, false),
    'cp/cline-pass/deepseek-v4-pro': (1000000, 393216, false),
    'cp/cline-pass/deepseek-v4.1-flash': (1000000, 393216, true),
    'cp/cline-pass/glm-5.2': (1000000, 128000, true),
    'cp/cline-pass/glm-5.3': (1000000, 128000, false),
    'cp/cline-pass/kimi-k2.6': (262144, null, false),
    'cp/cline-pass/kimi-k2.7-code': (262144, null, true),
    'cp/cline-pass/kimi-k3': (1000000, null, true),
    'cp/cline-pass/mimo-v2.5': (1000000, 131072, true),
    'cp/cline-pass/mimo-v2.5-pro': (1000000, 131072, false),
    'cp/cline-pass/minimax-m3': (1000000, 262144, true),
    'cp/cline-pass/qwen3.7-max': (1000000, 131072, false),
    'cp/cline-pass/qwen3.7-plus': (1000000, 131072, true),
    'cp/cline-pass/qwen3.8-max': (1000000, 131072, true),
    'cp/xai/grok-4.5': (500000, null, true),
    'cp/xai/grok-4.6': (500000, null, true),
    'cp/zai/glm-5.3-flash': (1000000, 128000, true),
    'cx/gpt-5.5': (272000, 128000, true),
    'cx/gpt-5.6-luna': (272000, 128000, true),
    'cx/gpt-5.6-sol': (272000, 128000, true),
    'cx/gpt-5.6-terra': (272000, 128000, true),
    'cx/gpt-6-astra': (272000, 128000, true),
    'cx/gpt-6-luna': (272000, 128000, true),
    'cx/gpt-6-sol': (272000, 128000, true),
    'deepseek-v4-flash': (null, null, false),
    'deepseek-v4-flash-0731': (1000000, 128000, false),
    'deepseek-v4-flash-vision-exp': (1000000, 128000, true),
    'deepseek-v4-pro': (100000, null, false),
    'deepseek-v4.1-flash': (null, null, true),
    'dots-3-note-preview': (512000, 128000, false),
    'gemini-3.1-pro': (null, 1048576, null),
    'gemini-3.8-flash': (null, 1048576, null),
    'glm-4.7-flash': (198000, 4000, false),
    'glm-5.2': (null, 128000, false),
    'glm-5.3': (1000000, null, false),
    'glm-5.3-flash': (1000000, null, true),
    'glm-5.3-flashx': (1000000, 128000, true),
    'google/diffusiongemma-26b-a4b-it': (250000, null, null),
    'gpt-5.4-nano': (400000, 65000, true),
    'gpt-5.6-luna': (1050000, 128000, true),
    'gpt-5.6-sol': (1050000, 128000, true),
    'gpt-5.6-terra': (1050000, null, true),
    'gpt-6-astra': (1000000, null, true),
    'gpt-6-luna': (1050000, 1048576, null),
    'gpt-6-sol': (1050000, 1048576, null),
    'gpt-oss-120b': (128000, 16384, false),
    'grok-4.5': (500000, 128000, true),
    'grok-4.6': (500000, 128000, true),
    'grok-4.7': (500000, null, true),
    'hy3': (131070, 131070, false),
    'hy4': (1000000, 64000, false),
    'kimi-k2.8-preview': (1000000, 128000, true),
    'kimi-k3': (1000000, null, true),
    'kira-2.5-flash': (128000, 56000, false),
    'kira-2.5-pro': (128000, 8192, false),
    'kira-3.5-flash': (128000, 65536, false),
    'kira-3.5-flash-pdf': (1000000, 65536, true),
    'kira-3.5-pro': (128000, 65536, false),
    'kira-flash': (153600, 50000, false),
    'kira-mini-1.0': (128000, 50000, false),
    'ling-3.0-flash': (256000, 32000, false),
    'mercury-2': (128000, 50000, false),
    'mercury-2.5': (128000, 50000, false),
    'meta/llama-3.2-11b-vision-instruct': (131072, null, true),
    'meta/llama-3.2-90b-vision-instruct': (128000, null, true),
    'meta/llama-guard-4-12b': (65536, null, null),
    'meta/muse-glimmer-30b': (1048576, null, null),
    'mimo-v2.5': (262000, 131072, true),
    'mimo-v2.5-pro': (256000, 8192, false),
    'mimo-v2.6-flash': (1000000, 128000, true),
    'mimo-v2.6-pro': (1000000, 128000, true),
    'minimax-m2.7': (1000000, 512000, true),
    'minimax-m3': (1000000, 512000, true),
    'mistralai/mistral-nemotron': (128000, null, null),
    'nvidia/ising-calibration-1.5-31b': (131072, null, null),
    'nvidia/llama-3.1-nemoguard-8b-content-safety': (131072, null, null),
    'nvidia/llama-3.1-nemoguard-8b-topic-control': (131072, null, null),
    'nvidia/llama-3.1-nemotron-safety-guard-8b-v3': (131072, null, null),
    'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning': (1000000, null, null),
    'nvidia/nemotron-3-super-120b-a12b': (1000000, null, null),
    'nvidia/nemotron-3-ultra-550b-a55b': (1048576, null, null),
    'nvidia/nemotron-3.5-content-safety': (131072, null, null),
    'nvidia/nemotron-3.5-lightning-30b-a3b': (1000000, null, null),
    'nvidia/nemotron-parse-2.0': (4096, null, null),
    'nvidia/riva-translate-4b-instruct-v1.1': (8192, null, null),
    'nvidia/riva-translate-4b-instruct-v2': (8192, null, null),
    'ocg/deepseek-v4-flash': (1000000, 393216, false),
    'ocg/deepseek-v4.1-flash': (1000000, 393216, true),
    'ocg/glm-5.3': (1000000, 128000, false),
    'ocg/glm-5.3-flash': (1000000, 128000, false),
    'ocg/gpt-5.6-luna': (272000, 128000, false),
    'ocg/grok-4.5': (500000, null, false),
    'ocg/kimi-k2.7-code': (262144, null, false),
    'ocg/kimi-k3': (1000000, null, true),
    'ocg/mimo-v2.5-pro': (1000000, 131072, false),
    'ocg/minimax-m2.7': (1000000, null, false),
    'ocg/minimax-m3': (1000000, 262144, true),
    'ocg/qwen3.7-plus': (1000000, 131072, true),
    'ocg/qwen3.8-flash': (1000000, 131072, true),
    'ocg/qwen3.8-max': (1000000, 131072, true),
    'ox-alpha': (1000000, 131000, true),
    'poolside/laguna-xs-2.1': (262144, null, null),
    'qwen3.5-flash': (100000, 8192, false),
    'qwen3.5-omni-plus': (100000, 8192, false),
    'qwen3.6-flash': (100000, 8192, false),
    'qwen3.7-max': (100000, 8192, false),
    'qwen3.7-plus': (100000, 8192, false),
    'qwen3.8-27b': (1000000, 128000, false),
    'qwen3.8-flash': (1000000, 131072, true),
    'qwen3.8-max': (1000000, 128000, true),
    'z-ai/glm-5.3': (1048576, null, null),
    'z-ai/glm-5.3-flash': (1048576, null, null),
    'zai/glm-4.6v': (200000, 128000, true),
    'zai/glm-5.3': (1000000, 128000, false),
    'zai/glm-5.3-flash': (1000000, 128000, true),
  };

  /// Gateways whose own numbers differ from [_measured] for a model id,
  /// keyed by provider id. Consulted first when the request is going to
  /// that provider.
  static const Map<String, Map<String, (int?, int?, bool?)>> _byProvider = {
    // Apinex
    'custom-apinex': {
      'deepseek-v4-flash': (null, 1048576, null),
      'deepseek-v4-pro': (null, 393216, null),
      'deepseek-v4.1-flash': (null, 1048576, null),
      'glm-5.3': (null, 1048576, null),
      'glm-5.3-flash': (null, 1048576, null),
      'gpt-5.6-terra': (null, 1048576, null),
      'gpt-6-astra': (null, 1048576, null),
      'gpt-6-luna': (null, 1048576, null),
      'gpt-6-sol': (null, 1048576, null),
      'grok-4.7': (null, 1048576, null),
      'kimi-k3': (null, 1048576, null),
    },
    // Experiential Labs
    'custom-experiential-labs': {
      'deepseek-v4-flash': (1048576, null, null),
      'deepseek-v4.1-flash': (1048576, null, null),
      'gpt-5.6-luna': (1050000, null, null),
      'gpt-6-luna': (1050000, null, null),
      'gpt-6-sol': (1050000, null, null),
      'grok-4.7': (500000, null, null),
      'qwen3.8-27b': (1000000, null, null),
    },
    // Fiqstr
    'custom-fiqstr': {
      'glm-5.2': (990000, null, null),
    },
    // KiraAi
    'custom-kiraai': {
      'deepseek-v4-flash': (1000000, 128000, false),
      'deepseek-v4-pro': (100000, 384000, false),
      'deepseek-v4.1-flash': (1000000, 384000, true),
      'glm-5.2': (1000000, 128000, false),
      'glm-5.3': (1000000, 128000, false),
      'glm-5.3-flash': (1000000, 131000, true),
      'gpt-5.6-terra': (1050000, 128000, true),
      'gpt-6-astra': (1000000, 128000, true),
      'grok-4.7': (500000, 128000, true),
      'kimi-k3': (1000000, 128000, true),
    },
  };

  /// Family fallbacks for ids that no gateway described with any metadata
  /// (an unversioned alias, a hand-typed route). Longest key wins. Values
  /// are the Nvidia NIM ceilings read straight out of its own 400 bodies.
  static const List<(String, int?, int?, bool?)> _families = [
    ('nemotron-3-super', 1000000, null, null),
    ('nemotron-3-ultra', 1048576, null, null),
    ('nemotron-3.5-lightning', 1000000, null, null),
    ('nemotron-3-nano', 1000000, null, null),
    ('nemotron-parse', 4096, null, null),
    ('riva-translate', 8192, null, null),
    ('ising-calibration', 131072, null, null),
    ('llama-guard', 65536, null, null),
    ('content-safety', 131072, null, null),
    ('safety-guard', 131072, null, null),
    ('nemoguard', 131072, null, null),
    ('diffusiongemma', 250000, null, null),
    ('muse-glimmer', 1048576, null, null),
    ('llama-3.2-11b-vision', 131072, null, true),
    ('llama-3.2-90b-vision', 128000, null, true),
    ('laguna', 262144, null, null),
  ];

  /// Strip the `· Effort` variant suffix a session model carries and
  /// normalise for lookup.
  static String _base(String model) =>
      model.split('\u00b7').first.trim().toLowerCase();

  /// The measured row for [model]. Pass [providerId] when the request is
  /// bound for a known gateway so that gateway's own numbers win over a
  /// different vendor's route with the same name.
  static (int?, int?, bool?)? lookup(String model, [String? providerId]) {
    final m = _base(model);
    if (m.isEmpty) return null;
    if (providerId != null) {
      final mine = _byProvider[providerId]?[m];
      if (mine != null) return mine;
    }
    final exact = _measured[m];
    if (exact != null) return exact;
    for (final (key, input, output, vision) in _families) {
      if (m.contains(key)) return (input, output, vision);
    }
    return null;
  }

  /// Total context window (prompt + completion) in tokens, if measured.
  static int? inputTokens(String model, [String? providerId]) =>
      lookup(model, providerId)?.$1;

  /// Maximum completion tokens the endpoint accepts, if measured.
  static int? maxOutputTokens(String model, [String? providerId]) =>
      lookup(model, providerId)?.$2;

  /// Whether the gateway says the model takes image input.
  static bool? acceptsImages(String model, [String? providerId]) =>
      lookup(model, providerId)?.$3;

  /// True when this file knows anything about [model].
  static bool isKnown(String model, [String? providerId]) =>
      lookup(model, providerId) != null;

  /// Tight chip label for the providers screen: `1M/128K`, or null when
  /// nothing was measured.
  static String? compactLabel(String model, [String? providerId]) {
    final (input, output, _) = lookup(model, providerId) ?? (null, null, null);
    if (input == null && output == null) return null;
    return '${input == null ? '?' : _short(input)}'
        '/${output == null ? '?' : _short(output)}';
  }

  /// Spaced label: `1M in \u00b7 128K out`.
  static String? label(String model, [String? providerId]) {
    final (input, output, _) = lookup(model, providerId) ?? (null, null, null);
    if (input == null && output == null) return null;
    final parts = <String>[];
    if (input != null) parts.add('${_short(input)} in');
    if (output != null) parts.add('${_short(output)} out');
    return parts.join(' \u00b7 ');
  }

  static String _short(int n) => n >= 1000000
      ? '${(n / 1000000).toStringAsFixed(n % 1000000 == 0 ? 0 : 2)}M'
      : n >= 1000
          ? '${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}K'
          : '$n';
}
