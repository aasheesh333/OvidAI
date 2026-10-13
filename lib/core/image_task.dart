/// Image-task policy shared by the agent's image tools: how an instruction
/// plus attached images becomes faithful, per-image edits.
///
/// Pure Dart (no codec, no network) so every rule here is unit-testable:
/// header-only pixel sizes for the attachment note, aspect-ratio maths,
/// nearest supported size, model selection from capability cards, the
/// preservation clause and the crop/scale plan that restores the original
/// dimensions after an edit.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'image_capabilities.dart';

/// Pixel dimensions of an image.
class PixelSize {
  const PixelSize(this.width, this.height);
  final int width;
  final int height;

  double get ratio => width / height;
  String get label => '${width}x$height';
  String get aspect => aspectLabel(width, height);

  static PixelSize? parse(String size) {
    final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(size);
    if (m == null) return null;
    final w = int.parse(m[1]!);
    final h = int.parse(m[2]!);
    return w < 1 || h < 1 ? null : PixelSize(w, h);
  }

  @override
  bool operator ==(Object other) =>
      other is PixelSize && other.width == width && other.height == height;
  @override
  int get hashCode => Object.hash(width, height);
  @override
  String toString() => label;
}

/// Ratios people name; a size within 1% of one is labelled with it.
const _commonRatios = <(int, int)>[
  (1, 1),
  (4, 5),
  (5, 4),
  (3, 4),
  (4, 3),
  (2, 3),
  (3, 2),
  (9, 16),
  (16, 9),
  (1, 2),
  (2, 1),
  (21, 9),
  (9, 21),
  (5, 7),
  (7, 5),
];

/// Distance between two aspect ratios on a log scale (symmetric for w/h).
double ratioDistance(double a, double b) => (math.log(a) - math.log(b)).abs();

/// Human aspect-ratio label: `1080x1350` → `4:5`, `1000x1001` → `1:1`.
String aspectLabel(int width, int height) {
  final r = width / height;
  for (final (w, h) in _commonRatios) {
    if (ratioDistance(r, w / h) < 0.01) return '$w:$h';
  }
  int gcd(int a, int b) => b == 0 ? a : gcd(b, a % b);
  final g = gcd(width, height);
  final w = width ~/ g, h = height ~/ g;
  if (w <= 50 && h <= 50) return '$w:$h';
  return '${r.toStringAsFixed(2)}:1';
}

/// Parses an `W:H` ratio string to a positive double.
double? parseRatio(String? raw) {
  final m = RegExp(
    r'^\s*(\d+(?:\.\d+)?)\s*[:x/]\s*(\d+(?:\.\d+)?)\s*$',
  ).firstMatch(raw ?? '');
  if (m == null) return null;
  final w = double.parse(m[1]!), h = double.parse(m[2]!);
  return w <= 0 || h <= 0 ? null : w / h;
}

/// Displayed pixel size read from the file header only (PNG, JPEG incl. EXIF
/// orientation, WebP). Null when the format is unknown or truncated.
PixelSize? imageHeaderSize(Uint8List b) {
  int be16(int i) => (b[i] << 8) | b[i + 1];
  int be32(int i) =>
      (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  try {
    // PNG: IHDR is always first.
    if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E) {
      return _valid(be32(16), be32(20));
    }
    // WebP.
    if (b.length >= 30 &&
        String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
      final chunk = String.fromCharCodes(b.sublist(12, 16));
      if (chunk == 'VP8 ') {
        return _valid(
          (b[26] | (b[27] << 8)) & 0x3fff,
          (b[28] | (b[29] << 8)) & 0x3fff,
        );
      }
      if (chunk == 'VP8L') {
        final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
        return _valid((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
      }
      if (chunk == 'VP8X') {
        return _valid(
          1 + (b[24] | (b[25] << 8) | (b[26] << 16)),
          1 + (b[27] | (b[28] << 8) | (b[29] << 16)),
        );
      }
      return null;
    }
    // JPEG: walk segments to the first SOFn; note EXIF orientation on the way.
    if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      var rotated = false;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        if (marker == 0xFF) {
          i++;
          continue;
        }
        if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD9)) {
          i += 2;
          continue;
        }
        final len = be16(i + 2);
        if (marker == 0xE1 && len > 16) {
          rotated = _exifRotated(b, i + 4, math.min(b.length, i + 2 + len));
        }
        if (marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC) {
          final h = be16(i + 5), w = be16(i + 7);
          return rotated ? _valid(h, w) : _valid(w, h);
        }
        i += 2 + len;
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}

PixelSize? _valid(int w, int h) => w > 0 && h > 0 ? PixelSize(w, h) : null;

/// True when the EXIF orientation (tag 0x0112) is 5–8 (a 90° rotation).
bool _exifRotated(Uint8List b, int start, int end) {
  if (end - start < 14 ||
      String.fromCharCodes(b.sublist(start, start + 4)) != 'Exif') {
    return false;
  }
  final tiff = start + 6;
  final little = b[tiff] == 0x49;
  int u16(int i) => little ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1];
  int u32(int i) => little
      ? b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24)
      : (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  final ifd = tiff + u32(tiff + 4);
  if (ifd + 2 > end) return false;
  final count = u16(ifd);
  for (var k = 0; k < count; k++) {
    final entry = ifd + 2 + k * 12;
    if (entry + 12 > end) return false;
    if (u16(entry) == 0x0112) return u16(entry + 8) >= 5;
  }
  return false;
}

/// The supported size whose aspect ratio is closest to [target]. Among equal
/// ratios: the smallest size covering the target's pixels, else the largest.
String? nearestSize(Iterable<String> sizes, PixelSize target) {
  String? best;
  PixelSize? bestSize;
  double? bestDistance;
  for (final s in sizes) {
    final p = PixelSize.parse(s);
    if (p == null) continue;
    final d = ratioDistance(p.ratio, target.ratio);
    if (bestDistance == null || d < bestDistance - 1e-9) {
      (best, bestSize, bestDistance) = (s, p, d);
      continue;
    }
    if ((d - bestDistance).abs() <= 1e-9) {
      final covers = p.width >= target.width && p.height >= target.height;
      final bestCovers =
          bestSize!.width >= target.width && bestSize.height >= target.height;
      final area = p.width * p.height,
          bestArea = bestSize.width * bestSize.height;
      final better = covers && bestCovers
          ? area < bestArea
          : covers || (!bestCovers && area > bestArea);
      if (better) (best, bestSize) = (s, p);
    }
  }
  return best;
}

/// Model + size picked for one image task, with the reason shown to the user.
class ImageModelChoice {
  const ImageModelChoice({
    required this.card,
    required this.size,
    required this.rationale,
    required this.nativeRatio,
    this.sendModel = true,
    this.forced = false,
  });
  final ImageModelCard card;
  final String size;
  final String rationale;

  /// True when [size] has the task's aspect ratio (within 1%).
  final bool nativeRatio;

  /// False for the legacy synthetic card (the server picks).
  final bool sendModel;

  /// True when the agent named this model explicitly. Only then is the slug
  /// pinned in the request; otherwise the gateway routes with the derived
  /// requirements and keeps its failover across equally capable backends.
  final bool forced;

  /// Model field for the request: a pinned slug, or null (gateway auto).
  String? get requestModel => sendModel && forced ? card.slug : null;
}

const _costRank = {'low': 0, 'med': 1, 'high': 2};
const _speedRank = {'fast': 0, 'medium': 1, 'slow': 2, 'unknown': 3};
const _qualityRank = {'high': 0, 'med': 1, 'low': 2};
const _textRank = {'good': 0, 'ok': 1, 'none': 2};

/// Picks the model for one task from the capability cards.
///
/// Rules, in order: the operation must be supported (edit-capable models only
/// for edits) and the card priced; transparent output requires the
/// `transparent_output` operation; legible text prefers `text: good` (then
/// `ok`); models with a native size at the target ratio win, otherwise the
/// nearest ratio; then cheapest, fastest, verified, best quality (quality
/// first when [preference] is `quality`). A valid [requested] slug is honoured.
/// Returns null (with [onRefusal]) when no card can serve the task.
ImageModelChoice? chooseImageModel(
  ImageCapabilities caps, {
  required String operation,
  PixelSize? target,
  bool transparent = false,
  bool text = false,
  String? preference,
  String? requested,
  String? requestedSize,
  void Function(String reason)? onRefusal,
}) {
  var pool = caps
      .modelsFor(operation)
      .where((c) => c.priced && (c.sizes.isNotEmpty || caps.legacy))
      .toList();
  if (caps.legacy) {
    final sizes = caps.sizesFor(operation);
    if (pool.isEmpty || sizes.isEmpty) {
      onRefusal?.call('no model currently supports $operation');
      return null;
    }
    final size = requestedSize != null && sizes.contains(requestedSize)
        ? requestedSize
        : target == null
        ? sizes.first
        : nearestSize(sizes, target)!;
    return ImageModelChoice(
      card: pool.first,
      size: size,
      rationale: 'server-selected $operation model',
      nativeRatio:
          target == null ||
          ratioDistance(PixelSize.parse(size)!.ratio, target.ratio) < 0.01,
      sendModel: false,
    );
  }
  if (pool.isEmpty) {
    onRefusal?.call('no priced model currently supports $operation');
    return null;
  }
  final reasons = <String>['$operation-capable'];
  if (transparent) {
    pool = pool.where((c) => c.supports('transparent_output')).toList();
    if (pool.isEmpty) {
      onRefusal?.call('no $operation model supports a transparent background');
      return null;
    }
    reasons.add('transparent output');
  }
  ImageModelCard? forced;
  if (requested != null) {
    forced = pool.where((c) => c.slug == requested).firstOrNull;
    if (forced == null) {
      reasons.add('requested model cannot serve this task, auto-selected');
    }
  }
  if (forced == null && text) {
    final bestText = pool
        .map((c) => _textRank[c.textRendering] ?? 2)
        .reduce(math.min);
    pool = pool
        .where((c) => (_textRank[c.textRendering] ?? 2) == bestText)
        .toList();
    reasons.add(
      bestText == 0 ? 'good text rendering' : 'best available text rendering',
    );
  }
  double distanceOf(ImageModelCard c) {
    if (target == null) return 0;
    return c.sizes
        .map(PixelSize.parse)
        .whereType<PixelSize>()
        .map((p) => ratioDistance(p.ratio, target.ratio))
        .fold(double.infinity, math.min);
  }

  if (forced == null && target != null) {
    final best = pool.map(distanceOf).reduce(math.min);
    pool = pool.where((c) => distanceOf(c) <= best + 1e-6).toList();
  }
  int cmp(ImageModelCard a, ImageModelCard b) {
    final quality =
        (_qualityRank[a.quality] ?? 1) - (_qualityRank[b.quality] ?? 1);
    if (preference == 'quality' && quality != 0) return quality;
    for (final d in [
      (_costRank[a.costTier] ?? 1) - (_costRank[b.costTier] ?? 1),
      (_speedRank[a.speed] ?? 3) - (_speedRank[b.speed] ?? 3),
      (b.verified ? 1 : 0) - (a.verified ? 1 : 0),
      quality,
    ]) {
      if (d != 0) return d;
    }
    return a.slug.compareTo(b.slug);
  }

  final card = forced ?? (pool..sort(cmp)).first;
  final size = requestedSize != null && card.sizes.contains(requestedSize)
      ? requestedSize
      : target == null
      ? (card.sizes.contains('1024x1024') ? '1024x1024' : card.sizes.first)
      : nearestSize(card.sizes, target)!;
  final sizeRatio = PixelSize.parse(size)!;
  final native =
      target == null || ratioDistance(sizeRatio.ratio, target.ratio) < 0.01;
  if (forced != null) reasons.add('requested model');
  if (target != null) {
    reasons.add(
      native
          ? 'native ${target.aspect}'
          : 'nearest ratio ${sizeRatio.aspect} to ${target.aspect}',
    );
  }
  if (forced == null) {
    reasons.add(
      preference == 'quality'
          ? 'quality ${card.quality}'
          : 'cost ${card.costTier}, speed ${card.speed}',
    );
  }
  return ImageModelChoice(
    card: card,
    size: size,
    rationale: reasons.join('; '),
    nativeRatio: native,
    forced: forced != null,
  );
}

/// Clause appended to every faithful (preserve) edit.
const preservationClause =
    'Keep everything else identical: composition, subjects, colours, text, '
    'lighting, framing, aspect ratio. Do not add, remove, restyle or '
    'enhance anything that was not requested.';

/// The prompt sent for a faithful edit: the user's instruction verbatim,
/// bounded so the whole prompt stays within the 8000-character API limit.
String preservationPrompt(String instruction) {
  var text = instruction.trim();
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  const budget = 8000 - preservationClause.length - 32;
  if (text.runes.length > budget) {
    text = String.fromCharCodes(text.runes.take(budget));
  }
  return 'Change ONLY: $text. $preservationClause';
}

/// How to map a model output back onto the original pixel size without
/// distortion: scale uniformly to cover, centre-crop the overflow.
class RestorePlan {
  const RestorePlan({
    required this.srcX,
    required this.srcY,
    required this.srcWidth,
    required this.srcHeight,
    required this.target,
  });

  /// Source rectangle (output-image pixels) that is scaled onto [target].
  final double srcX, srcY, srcWidth, srcHeight;
  final PixelSize target;

  bool get crops => srcX > 0.5 || srcY > 0.5;

  /// Share of the source discarded by the crop (0 when ratios match).
  double trimmedFraction(PixelSize source) =>
      1 - (srcWidth * srcHeight) / (source.width * source.height);
}

RestorePlan restorePlan(PixelSize source, PixelSize target) {
  // Ratios within 1%: a plain resize is visually distortion-free.
  if (ratioDistance(source.ratio, target.ratio) < 0.01) {
    return RestorePlan(
      srcX: 0,
      srcY: 0,
      srcWidth: source.width.toDouble(),
      srcHeight: source.height.toDouble(),
      target: target,
    );
  }
  final scale = math.max(
    target.width / source.width,
    target.height / source.height,
  );
  final w = target.width / scale, h = target.height / scale;
  return RestorePlan(
    srcX: (source.width - w) / 2,
    srcY: (source.height - h) / 2,
    srcWidth: w,
    srcHeight: h,
    target: target,
  );
}

/// Exact output size for a generation that asked for [ratio] and/or exact
/// [width]×[height]: the largest centred crop of [output] at that ratio, or
/// the exact dimensions when both are given.
PixelSize generationTarget(
  PixelSize output, {
  double? ratio,
  int? width,
  int? height,
}) {
  if (width != null && height != null) return PixelSize(width, height);
  final r = ratio ?? output.ratio;
  if (width != null) return PixelSize(width, math.max(1, (width / r).round()));
  if (height != null) {
    return PixelSize(math.max(1, (height * r).round()), height);
  }
  if (output.ratio > r) {
    return PixelSize(math.max(1, (output.height * r).round()), output.height);
  }
  return PixelSize(output.width, math.max(1, (output.width / r).round()));
}

/// System-prompt rules for image tasks (shown when Image Studio is enabled).
const imageTaskGuidance = '''
IMAGE TASKS — attached image(s) + an instruction = an image task:
• If the user attached images and asks to change, fix, remove, add, recolour, restyle, clean up or otherwise edit them, CALL THE IMAGE TOOLS with the exact attachment paths. Never just describe the image, never ask the user to re-upload, never claim you cannot see it.
• One image → edit_image. Several images + one instruction ("edit all/each of these", "make these …") → ONE edit_images call listing EVERY path in the given order; each image is edited independently. Never merge, collage or combine images unless the user explicitly asks to combine them. Never skip one.
• Do exactly what was asked, nothing more: pass the user's instruction verbatim as prompt (translate only if needed). Never add styles, objects, colour grading, "enhancements" or other changes the user did not request.
• Edits are faithful by default (preserve: true): the app keeps the original size, aspect ratio, framing, subjects and text, and restores the original pixel dimensions. Set preserve: false only when the user asks to change size, ratio or framing, or to reimagine the image.
• Leave model and size unset for edits: the app picks an edit-capable model and the size nearest each input's ratio. For a transparent background set requirements.transparent_background; for legible text set requirements.text_rendering.
• New images → generate_image; when the user names a ratio or size pass aspect_ratio (e.g. "4:5") and/or width+height — the output is cropped to exactly that.
• Plain resize/crop/rotate/convert → local tools (resize_image / crop_image), never a model.
Examples:
  [3 images] "make the background white on all of these" → edit_images(paths=[img1,img2,img3], prompt="make the background white")
  [1 image] "remove the text, keep everything else the same" → edit_image(path=img1, prompt="remove the text")
  [1 image] "make it a 16:9 banner" → edit_image(path=img1, prompt="extend the scene into a 16:9 banner", preserve=false), then crop_image to exactly 16:9 if needed
  [no image] "a 4:5 poster of a red fox" → generate_image(prompt="a poster of a red fox", aspect_ratio="4:5")
Report each result honestly, including any note that something could not be preserved.''';

/// One cloud image call as the agent tools issue it (test seam shape).
class ImageInferRequest {
  const ImageInferRequest({
    required this.prompt,
    required this.size,
    required this.requestId,
    this.input,
    this.model,
    this.preference,
    this.requirements,
    this.mask,
    this.references = const [],
  });
  final String prompt;
  final String size;
  final String requestId;
  final Uint8List? input;
  final String? model;
  final String? preference;
  final Map<String, dynamic>? requirements;
  final Uint8List? mask;
  final List<Uint8List> references;
}

/// Outcome of one cloud image call: bytes, or a public error message.
/// [accounting] always describes what was (or was not) charged.
class ImageInferOutcome {
  const ImageInferOutcome({
    this.bytes,
    this.accounting = '',
    this.error,
    this.servedModel,
  });
  final Uint8List? bytes;
  final String accounting;
  final String? error;
  final String? servedModel;
}

/// Requirements sent with a task: the agent's own hints plus the hard needs
/// the app derived; `aspect_ratio` only when the chosen size is native for it.
Map<String, dynamic>? taskRequirements(
  Map<String, dynamic>? agent, {
  required String operation,
  required ImageModelChoice choice,
}) {
  if (!choice.sendModel) return agent;
  final out = <String, dynamic>{...?agent}..remove('aspect_ratio');
  if (operation == 'edit') out.putIfAbsent('operation', () => 'edit');
  final size = PixelSize.parse(choice.size)!;
  int gcd(int a, int b) => b == 0 ? a : gcd(b, a % b);
  final g = gcd(size.width, size.height);
  final label = '${size.width ~/ g}:${size.height ~/ g}';
  if (choice.nativeRatio && choice.card.aspectRatios.contains(label)) {
    out['aspect_ratio'] = label;
  }
  return out.isEmpty ? null : out;
}
