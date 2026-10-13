/// Public image-model capability cards served by the Ovid image gateway, and
/// the agent tool definitions built from them.
///
/// The gateway fills each card automatically (static metadata + background
/// probes); the app only reads them. A cached payload (ETag) is reused, so
/// choosing a model never costs a discovery round trip at request time.
/// Cards carry no provider names, base URLs or prices - only opaque slugs,
/// tags and relative tiers.
library;

const _alias = 'ovid-image';
final _slugRe = RegExp(r'^ovid-image:[A-Za-z0-9_-]{3,40}$');
final _sizeRe = RegExp(r'^[1-9][0-9]{2,3}x[1-9][0-9]{2,3}$');
final _ratioRe = RegExp(r'^[1-9][0-9]?:[1-9][0-9]?$');

/// Operations an `edit_image` call may be asked to perform beyond plain edit.
const advancedEditOperations = [
  'inpaint',
  'outpaint',
  'reference_style',
  'multi_image',
  'remove_background',
  'upscale',
];

const preferences = ['balanced', 'quality', 'speed', 'cost'];

/// Most images one `edit_images` call accepts (matches the attachment cap).
const maxBatchImages = 20;

/// Rules repeated in both edit tool descriptions.
const editRules =
    'Pass the user\'s instruction verbatim as prompt; never add changes they '
    'did not ask for. Leave model and size unset: the app picks an '
    'edit-capable model and the size nearest the input ratio, and with '
    'preserve (default true) keeps everything else identical and restores the '
    'original pixel dimensions.';

const preserveProperty = {
  'type': 'boolean',
  'description':
      'Default true: change only what the prompt asks and keep the original '
      'size, aspect ratio, framing and content. Set false only when the user '
      'asks to change size, ratio or framing, or to reimagine the image.',
};

/// Guidance the agent sees in every cloud image tool description.
const localOpsGuidance =
    'LOCAL operations need NO model, cost nothing and are instant: crop, resize, '
    'rotate, flip, format conversion (png/jpg/webp). Use crop_image / resize_image '
    'for those; for rotate/convert use a local script or tool - NEVER an image model. '
    'Aspect ratio: use a model whose table lists that ratio natively; otherwise '
    'generate at the nearest listed size and crop_image locally. '
    'Choose the cheapest/fastest model that satisfies the task unless the user '
    'asks for top quality (preference "quality"); omit `model` to let the server '
    'pick automatically (recommended).';

class ImageModelCard {
  const ImageModelCard({
    required this.slug,
    this.tags = const [],
    this.operations = const {},
    this.sizes = const [],
    this.aspectRatios = const [],
    this.maxN = 1,
    this.maxInputs = 1,
    this.textRendering = 'none',
    this.quality = 'med',
    this.speed = 'unknown',
    this.latencyP50S,
    this.costTier = 'med',
    this.verified = false,
    this.priced = true,
  });

  final String slug;
  final List<String> tags;

  /// Supported operation -> extra details (`max_inputs`, `max_n`, `confidence`).
  final Map<String, Map<String, dynamic>> operations;
  final List<String> sizes;
  final List<String> aspectRatios;
  final int maxN;
  final int maxInputs;
  final String textRendering;
  final String quality;
  final String speed;
  final int? latencyP50S;
  final String costTier;
  final bool verified;

  /// False when the gateway marks the model unpriced (it could never be
  /// settled); such a card is never selected.
  final bool priced;

  bool supports(String op) => operations.containsKey(op);

  /// Strict, defensive parse. Anything malformed drops that card, never throws.
  static ImageModelCard? parse(Object? raw) {
    if (raw is! Map) return null;
    final slug = raw['slug'];
    if (slug is! String || !_slugRe.hasMatch(slug)) return null;
    List<String> strings(Object? v, RegExp re) => v is List
        ? v.whereType<String>().where(re.hasMatch).toSet().toList()
        : <String>[];
    final ops = <String, Map<String, dynamic>>{};
    final rawOps = raw['operations'];
    if (rawOps is Map) {
      rawOps.forEach((k, v) {
        if (k is String && RegExp(r'^[a-z_]{2,32}$').hasMatch(k)) {
          ops[k] = v is Map ? Map<String, dynamic>.from(v) : {};
        }
      });
    }
    if (!ops.containsKey('generate') && !ops.containsKey('edit')) return null;
    String oneOf(Object? v, List<String> allowed, String fallback) =>
        v is String && allowed.contains(v) ? v : fallback;
    final input = raw['input'];
    final inputs = input is Map && input['max_images'] is int
        ? (input['max_images'] as int).clamp(0, 16)
        : (ops.containsKey('edit') ? 1 : 0);
    final latency = raw['latency_p50_s'];
    return ImageModelCard(
      slug: slug,
      tags: strings(raw['tags'], RegExp(r'^[a-z_]{2,24}$')),
      operations: ops,
      sizes: strings(raw['sizes'], _sizeRe),
      aspectRatios: strings(raw['aspect_ratios'], _ratioRe),
      maxN: raw['max_n'] is int ? (raw['max_n'] as int).clamp(1, 16) : 1,
      maxInputs: inputs,
      textRendering: oneOf(raw['text_rendering'], const [
        'none',
        'ok',
        'good',
      ], 'none'),
      quality: oneOf(raw['quality'], const ['low', 'med', 'high'], 'med'),
      speed: oneOf(raw['speed'], const [
        'fast',
        'medium',
        'slow',
        'unknown',
      ], 'unknown'),
      latencyP50S: latency is int && latency >= 0 ? latency : null,
      costTier: oneOf(raw['cost_tier'], const ['low', 'med', 'high'], 'med'),
      verified: raw['verified'] == true,
      priced:
          raw['priced'] != false &&
          !(raw['tags'] is List && (raw['tags'] as List).contains('unpriced')),
    );
  }

  /// One compact table row for the tool description.
  String row() {
    final ops = [
      for (final op in operations.keys)
        switch (op) {
          'multi_image' => 'multi($maxInputs)',
          'transparent_output' => 'transparent',
          'remove_background' => 'rm-bg',
          'reference_style' => 'style-ref',
          _ => op,
        },
    ].join(',');
    final ratios = aspectRatios.isEmpty ? '' : ' ratios ${aspectRatios.join(",")}';
    final latency = latencyP50S == null ? '' : ' ~${latencyP50S}s';
    return '- $slug: ops $ops; sizes ${sizes.join(",")}$ratios; '
        'speed ${speed == "unknown" ? "?" : speed}$latency, cost $costTier, '
        'quality $quality, text $textRendering'
        '${verified ? "" : " (estimated)"}';
  }
}

class ImageCapabilities {
  const ImageCapabilities({
    this.models = const [],
    this.catalogHash,
    this.legacy = false,
    this.legacyGenerate = const [],
    this.legacyEdit = const [],
  });

  static const empty = ImageCapabilities();

  final List<ImageModelCard> models;

  /// Server `catalog_hash`; also the HTTP ETag (quoted).
  final String? catalogHash;

  /// True when the server predates cards (old `operations` map only).
  final bool legacy;

  /// Legacy per-operation size lists (old gateways only).
  final List<String> legacyGenerate;
  final List<String> legacyEdit;

  bool get isEmpty => models.isEmpty;
  String? get etag => catalogHash == null ? null : '"$catalogHash"';

  /// Parse a /capabilities body. Old payloads yield one synthetic card so the
  /// rest of the app does not care which gateway version it talks to.
  factory ImageCapabilities.parse(
    Map<String, dynamic> body, {
    List<String> legacySizes = const [],
  }) {
    final rawModels = body['models'];
    if (rawModels is List) {
      final cards = rawModels
          .map(ImageModelCard.parse)
          .whereType<ImageModelCard>()
          .toList();
      final hash = body['catalog_hash'];
      return ImageCapabilities(
        models: cards,
        catalogHash: hash is String && RegExp(r'^[a-f0-9]{16,64}$').hasMatch(hash)
            ? hash
            : null,
      );
    }
    final ops = body['operations'];
    if (ops is! Map) return empty;
    List<String> sizesOf(String op) {
      final v = ops[op];
      return v is List
          ? v
                .whereType<String>()
                .where(legacySizes.contains)
                .toSet()
                .toList()
          : <String>[];
    }

    final generate = sizesOf('generate');
    final edit = sizesOf('edit');
    return ImageCapabilities(
      legacy: true,
      legacyGenerate: generate,
      legacyEdit: edit,
      models: [
        ImageModelCard(
          slug: _alias,
          operations: {
            if (generate.isNotEmpty) 'generate': const {},
            if (edit.isNotEmpty) 'edit': const {},
          },
          sizes: {...generate, ...edit}.toList(),
        ),
      ],
    );
  }

  List<ImageModelCard> modelsFor(String op) =>
      models.where((m) => m.supports(op)).toList();

  List<String> sizesFor(String op, {String? model}) {
    if (legacy) return op == 'edit' ? legacyEdit : legacyGenerate;
    final cards = modelsFor(op).where((m) => model == null || m.slug == model);
    final out = <String>[];
    for (final card in cards) {
      for (final size in card.sizes) {
        if (!out.contains(size)) out.add(size);
      }
    }
    return out;
  }

  /// Whether some (or the named) model advertises this operation at `size`.
  bool canServe(String op, String size, {String? model}) =>
      sizesFor(op, model: model).contains(size);

  bool anySupports(String op) => models.any((m) => m.supports(op));

  List<String> get ratios => {
    for (final m in models) ...m.aspectRatios,
  }.toList();

  String table(String op) =>
      modelsFor(op).map((m) => m.row()).join('\n');

  /// Tool definitions for generate/edit; empty when no model serves the op.
  /// [schema] builds the OpenAI function schema (shared with ImageStudio).
  List<Map<String, dynamic>> cloudTools({
    required Map<String, dynamic> Function(
      String name,
      String description,
      Map<String, dynamic> properties,
      List<String> required,
    )
    schema,
    required Map<String, dynamic> pathProperty,
  }) {
    final tools = <Map<String, dynamic>>[];
    for (final op in const ['generate', 'edit']) {
      final sizes = sizesFor(op);
      if (sizes.isEmpty) continue;
      final cards = modelsFor(op);
      final canMask = anySupports('inpaint');
      final canRefs = anySupports('multi_image');
      final properties = <String, dynamic>{
        'prompt': {'type': 'string', 'minLength': 1, 'maxLength': 8000},
        'size': {
          'type': 'string',
          'enum': sizes,
          if (op == 'edit')
            'description':
                'Optional; leave unset. With preserve the app requests the size '
                'nearest the input ratio and restores the original dimensions.'
          else if (!legacy)
            'description':
                'Output size. Pick the entry matching the wanted aspect ratio.',
        },
        'request_id': {
          'type': 'string',
          'description':
              'Stable unique ID for this image job, 8–128 characters. Reuse it for retries; never change it after an uncertain outcome.',
        },
        if (op == 'edit') 'path': pathProperty,
        if (op == 'edit') 'preserve': preserveProperty,
      };
      if (op == 'generate' && !legacy) {
        properties['aspect_ratio'] = {
          'type': 'string',
          'pattern': r'^[1-9][0-9]?:[1-9][0-9]?$',
          'description':
              'Exact output ratio the user asked for, e.g. "4:5" or "16:9". '
              'A model with that native ratio is preferred; otherwise the '
              'nearest size is generated and centre-cropped to exactly it.',
        };
        properties['width'] = {
          'type': 'integer',
          'minimum': 16,
          'maximum': 4096,
          'description': 'Exact output width in pixels, only when the user asked for one.',
        };
        properties['height'] = {
          'type': 'integer',
          'minimum': 16,
          'maximum': 4096,
          'description': 'Exact output height in pixels, only when the user asked for one.',
        };
      }
      if (!legacy) {
        properties['model'] = {
          'type': 'string',
          'enum': [for (final c in cards) c.slug],
          'description':
              'Optional. Omit for automatic selection (recommended). Only set it to force one model from the table.',
        };
        properties['preference'] = {
          'type': 'string',
          'enum': preferences,
          'description':
              'cost/speed = cheapest/fastest capable model; quality = best output; default balanced.',
        };
        properties['requirements'] = {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            if (ratios.isNotEmpty)
              'aspect_ratio': {
                'type': 'string',
                'enum': ratios,
                'description':
                    'Only models with this NATIVE ratio are considered; if none, generate at the nearest size and crop locally.',
              },
            'transparent_background': {
              'type': 'boolean',
              'description': 'Require alpha/transparent output (PNG).',
            },
            'text_rendering': {
              'type': 'boolean',
              'description':
                  'Set when legible text inside the image matters (prefers text:good).',
            },
            if (op == 'edit')
              'operation': {
                'type': 'string',
                'enum': [
                  'edit',
                  ...advancedEditOperations.where(anySupports),
                ],
                'description':
                    'Specific edit kind; routes only to models verified for it.',
              },
          },
        };
        if (op == 'edit' && canMask) {
          properties['mask_path'] = {
            'type': 'string',
            'description':
                'Optional exact path of a mask PNG (inpaint): transparent pixels mark the area to repaint.',
          };
        }
        if (op == 'edit' && canRefs) {
          properties['reference_paths'] = {
            'type': 'array',
            'maxItems': 7,
            'items': {'type': 'string'},
            'description':
                'Optional extra exact image paths (style reference / multi-image compose).',
          };
        }
      }
      final head = op == 'edit'
          ? 'Edit ONE existing image through Ovid Cloud. Use the exact attachment or returned file path. '
                '$editRules'
          : 'Generate one image through Ovid Cloud. Returns a saved local image path and displays it in chat.';
      final description = legacy
          ? '$head ${op == "edit" ? "No masks or multiple inputs supported." : ""}'
                .trim()
          : '$head\n$localOpsGuidance\nAvailable models:\n${table(op)}';
      tools.add(
        schema(
          '${op}_image',
          description,
          properties,
          ['prompt', if (op == 'generate') 'size', 'request_id', if (op == 'edit') 'path'],
        ),
      );
      if (op == 'edit') {
        tools.add(
          schema(
            'edit_images',
            'Apply ONE instruction to SEVERAL images, each edited independently '
                '(one edit per image, outputs in input order, per-image errors '
                'never abort the rest). Use it whenever the user says "edit '
                'all/each of these" or attaches several images with one '
                'instruction. Never merges or combines the images. $editRules',
            {
              'paths': {
                'type': 'array',
                'minItems': 1,
                'maxItems': maxBatchImages,
                'items': pathProperty,
                'description':
                    'Every image to edit, exact paths, in the order the user gave them.',
              },
              'prompt': properties['prompt'],
              'request_id': {
                'type': 'string',
                'description':
                    'Stable unique batch ID, 8–120 characters; per-image IDs derive from it. Reuse it for retries.',
              },
              'preserve': preserveProperty,
              if (!legacy) ...{
                'preference': properties['preference'],
                'requirements': properties['requirements'],
              },
            },
            ['paths', 'prompt', 'request_id'],
          ),
        );
      }
    }
    return tools;
  }
}
