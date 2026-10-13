// Pure image-task policy: header sizes, ratios, nearest size, model choice,
// the preservation clause, the restore plan and the agent guidance text.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ovid_ai/core/image_capabilities.dart';
import 'package:ovid_ai/core/image_task.dart';

const flash25 = 'ovid-image:img-flash25';
const flash31 = 'ovid-image:img-flash31';
const gpt2 = 'ovid-image:img-gptimg2';
const sizes = ['1024x1024', '1536x1024', '1024x1536', '2048x2048'];

Map<String, dynamic> card(
  String slug, {
  Map<String, dynamic> ops = const {'generate': {}, 'edit': {}},
  List<String> sizes = sizes,
  String cost = 'low',
  String speed = 'fast',
  String text = 'ok',
  String quality = 'med',
  Map<String, dynamic> extra = const {},
}) => {
  'slug': slug,
  'operations': ops,
  'sizes': sizes,
  'aspect_ratios': ['1:1', '2:3', '3:2'],
  'input': {'max_images': 1},
  'text_rendering': text,
  'quality': quality,
  'speed': speed,
  'cost_tier': cost,
  'verified': true,
  ...extra,
};

/// The production catalogue shape: three edit+generate models.
ImageCapabilities gatewayCaps({List<Map<String, dynamic>>? models}) =>
    ImageCapabilities.parse({
      'model': 'ovid-image',
      'models':
          models ??
          [
            card(flash25),
            card(flash31, cost: 'med', quality: 'high'),
            card(
              gpt2,
              ops: {'generate': {}, 'edit': {}, 'transparent_output': {}},
              cost: 'high',
              speed: 'medium',
              text: 'good',
              quality: 'high',
            ),
          ],
    });

Uint8List pngHeader(int w, int h) {
  final b = Uint8List(33);
  b.setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  b.setAll(8, [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  final d = ByteData.sublistView(b);
  d.setUint32(16, w);
  d.setUint32(20, h);
  return b;
}

Uint8List jpegHeader(int w, int h, {int? orientation}) {
  final out = BytesBuilder();
  out.add([0xFF, 0xD8]);
  if (orientation != null) {
    // APP1 Exif, big-endian TIFF, one IFD entry (0x0112).
    final tiff = <int>[
      0x4D, 0x4D, 0, 42, 0, 0, 0, 8, // header, IFD at 8
      0, 1, // one entry
      0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, orientation, 0, 0,
      0, 0, 0, 0,
    ];
    final payload = [...'Exif'.codeUnits, 0, 0, ...tiff];
    final len = payload.length + 2;
    out.add([0xFF, 0xE1, len >> 8, len & 0xff, ...payload]);
  }
  out.add([0xFF, 0xDB, 0, 4, 0, 0]); // a dummy DQT
  out.add([0xFF, 0xC0, 0, 17, 8, h >> 8, h & 0xff, w >> 8, w & 0xff, 3]);
  out.add(List.filled(9, 0));
  return out.takeBytes();
}

void main() {
  group('header sizes and ratios', () {
    test('PNG, JPEG (with EXIF rotation) and WebP headers', () {
      expect(
        imageHeaderSize(pngHeader(1080, 1350)),
        const PixelSize(1080, 1350),
      );
      expect(
        imageHeaderSize(jpegHeader(4032, 3024)),
        const PixelSize(4032, 3024),
      );
      expect(
        imageHeaderSize(jpegHeader(4032, 3024, orientation: 6)),
        const PixelSize(3024, 4032),
        reason: 'orientation 6 is displayed rotated 90°',
      );
      final webp = Uint8List(30)
        ..setAll(0, 'RIFF'.codeUnits)
        ..setAll(8, 'WEBPVP8X'.codeUnits)
        ..setAll(24, [0x37, 0x04, 0x00, 0x45, 0x05, 0x00]); // 1080x1350
      expect(imageHeaderSize(webp), const PixelSize(1080, 1350));
      expect(imageHeaderSize(Uint8List.fromList('hello'.codeUnits)), isNull);
    });

    test('aspect labels', () {
      expect(aspectLabel(1080, 1350), '4:5');
      expect(aspectLabel(1920, 1080), '16:9');
      expect(aspectLabel(1001, 1000), '1:1');
      expect(aspectLabel(1536, 1024), '3:2');
      expect(aspectLabel(1234, 567), '2.18:1');
      expect(parseRatio('4:5'), closeTo(0.8, 1e-9));
      expect(parseRatio('nope'), isNull);
    });

    test('nearest size by ratio, covering size among equal ratios', () {
      expect(nearestSize(sizes, const PixelSize(1080, 1350)), '1024x1536');
      expect(nearestSize(sizes, const PixelSize(1920, 1080)), '1536x1024');
      expect(nearestSize(sizes, const PixelSize(800, 800)), '1024x1024');
      expect(nearestSize(sizes, const PixelSize(1500, 1500)), '2048x2048');
      expect(nearestSize(sizes, const PixelSize(3000, 3000)), '2048x2048');
    });
  });

  group('model selection', () {
    test('edits use only edit-capable models; cheapest/fastest by default', () {
      final caps = gatewayCaps(
        models: [
          card(flash25, ops: {'generate': {}}),
          card(flash31, cost: 'med'),
          card(gpt2, cost: 'high'),
        ],
      );
      final c = chooseImageModel(
        caps,
        operation: 'edit',
        target: const PixelSize(1080, 1350),
      )!;
      expect(c.card.slug, flash31, reason: 'flash25 cannot edit');
      expect(c.size, '1024x1536');
      expect(c.nativeRatio, isFalse);
      expect(c.rationale, contains('edit-capable'));
      expect(c.rationale, contains('nearest ratio 2:3 to 4:5'));
      expect(c.requestModel, isNull, reason: 'gateway keeps failover');
      final reqs = taskRequirements(null, operation: 'edit', choice: c)!;
      expect(reqs, {'operation': 'edit'}, reason: '4:5 is not native anywhere');
    });

    test('native aspect ratio wins over cost', () {
      final caps = gatewayCaps(
        models: [
          card(flash25, sizes: ['1024x1024']),
          card(flash31, cost: 'high', sizes: ['1024x1024', '1024x1536']),
        ],
      );
      final c = chooseImageModel(
        caps,
        operation: 'edit',
        target: const PixelSize(1024, 1536),
      )!;
      expect(c.card.slug, flash31);
      expect(c.nativeRatio, isTrue);
      expect(c.rationale, contains('native 2:3'));
      expect(
        taskRequirements(null, operation: 'edit', choice: c)!['aspect_ratio'],
        '2:3',
      );
    });

    test('transparent background requires transparent_output', () {
      final c = chooseImageModel(
        gatewayCaps(),
        operation: 'edit',
        target: const PixelSize(1000, 1000),
        transparent: true,
      )!;
      expect(c.card.slug, gpt2);
      expect(c.rationale, contains('transparent'));
      String? why;
      expect(
        chooseImageModel(
          gatewayCaps(models: [card(flash25)]),
          operation: 'edit',
          transparent: true,
          onRefusal: (r) => why = r,
        ),
        isNull,
      );
      expect(why, contains('transparent'));
    });

    test('text-in-image prefers text rendering good', () {
      final c = chooseImageModel(
        gatewayCaps(),
        operation: 'generate',
        text: true,
      )!;
      expect(c.card.slug, gpt2);
      expect(c.rationale, contains('good text rendering'));
    });

    test('otherwise cheapest/fastest; quality preference flips it', () {
      expect(
        chooseImageModel(gatewayCaps(), operation: 'generate')!.card.slug,
        flash25,
      );
      expect(
        chooseImageModel(
          gatewayCaps(),
          operation: 'generate',
          preference: 'quality',
        )!.card.slug,
        flash31,
        reason: 'high quality, then cheaper than gpt2',
      );
    });

    test('never picks an unpriced model; honours a valid requested one', () {
      final caps = gatewayCaps(
        models: [
          card(flash25, extra: {'priced': false}),
          card(flash31, cost: 'med'),
        ],
      );
      expect(chooseImageModel(caps, operation: 'edit')!.card.slug, flash31);
      expect(
        chooseImageModel(
          caps,
          operation: 'edit',
          requested: flash25,
        )!.card.slug,
        flash31,
        reason: 'an unpriced request is ignored',
      );
      final forced = chooseImageModel(
        gatewayCaps(),
        operation: 'edit',
        requested: gpt2,
      )!;
      expect(forced.card.slug, gpt2);
      expect(forced.requestModel, gpt2);
      String? why;
      expect(
        chooseImageModel(
          gatewayCaps(
            models: [
              card(flash25, extra: {'priced': false}),
            ],
          ),
          operation: 'edit',
          onRefusal: (r) => why = r,
        ),
        isNull,
      );
      expect(why, contains('priced'));
    });
  });

  group('faithful edits', () {
    test('preservation prompt keeps the instruction verbatim', () {
      final p = preservationPrompt('remove the text.');
      expect(
        p,
        'Change ONLY: remove the text. Keep everything else identical: '
        'composition, subjects, colours, text, lighting, framing, aspect '
        'ratio. Do not add, remove, restyle or enhance anything that was not '
        'requested.',
      );
      expect(preservationPrompt('x' * 9000).length, lessThanOrEqualTo(8000));
    });

    test(
      'restore plan: resize when ratios match, else cover + centre crop',
      () {
        final same = restorePlan(
          const PixelSize(1024, 1024),
          const PixelSize(1080, 1080),
        );
        expect(same.crops, isFalse);
        final plan = restorePlan(
          const PixelSize(1024, 1536),
          const PixelSize(1080, 1350),
        );
        expect(plan.crops, isTrue);
        // Full width kept, height trimmed symmetrically to 4:5.
        expect(plan.srcWidth, closeTo(1024, 1e-6));
        expect(plan.srcHeight, closeTo(1280, 1e-6));
        expect(plan.srcY, closeTo(128, 1e-6));
        expect(plan.srcX, closeTo(0, 1e-6));
        expect(plan.srcWidth / plan.srcHeight, closeTo(1080 / 1350, 1e-9));
      },
    );

    test('generation target crops to exactly the requested ratio', () {
      expect(
        generationTarget(const PixelSize(1024, 1536), ratio: 4 / 5),
        const PixelSize(1024, 1280),
      );
      expect(
        generationTarget(const PixelSize(1536, 1024), ratio: 16 / 9),
        const PixelSize(1536, 864),
      );
      expect(
        generationTarget(const PixelSize(1024, 1024), width: 1200, height: 628),
        const PixelSize(1200, 628),
      );
    });
  });

  group('guidance', () {
    test('system guidance carries the image-task rules and examples', () {
      for (final rule in [
        'attached image(s) + an instruction = an image task',
        'CALL THE IMAGE TOOLS',
        'never ask the user to re-upload',
        'ONE edit_images call listing EVERY path',
        'Never merge, collage or combine images unless the user explicitly asks',
        'pass the user\'s instruction verbatim',
        'Never add styles, objects',
        'preserve: true',
        'Leave model and size unset for edits',
        'transparent_background',
        'aspect_ratio',
        'edit_images(paths=[img1,img2,img3], prompt="make the background white")',
        'edit_image(path=img1, prompt="remove the text")',
      ]) {
        expect(imageTaskGuidance, contains(rule), reason: rule);
      }
    });

    test('edit tools: size optional, preserve flag, batch tool exposed', () {
      final tools = gatewayCaps().cloudTools(
        schema: (name, description, properties, required) => {
          'name': name,
          'description': description,
          'properties': properties,
          'required': required,
        },
        pathProperty: const {'type': 'string'},
      );
      Map<String, dynamic> named(String n) =>
          tools.firstWhere((t) => t['name'] == n);
      final edit = named('edit_image');
      expect(edit['required'], isNot(contains('size')));
      expect((edit['properties'] as Map).containsKey('preserve'), isTrue);
      expect(edit['description'], contains('verbatim'));
      final batch = named('edit_images');
      expect(batch['required'], ['paths', 'prompt', 'request_id']);
      expect(batch['description'], contains('independently'));
      expect(batch['description'], contains('Never merges'));
      expect(
        ((batch['properties'] as Map)['paths'] as Map)['maxItems'],
        maxBatchImages,
      );
      final gen = named('generate_image');
      expect(
        (gen['properties'] as Map).keys,
        containsAll(['aspect_ratio', 'width', 'height']),
      );
    });
  });
}
