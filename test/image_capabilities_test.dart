import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/image_capabilities.dart';
import 'package:ovid_ai/core/image_receipt_store.dart';
import 'package:ovid_ai/core/image_studio.dart';
import 'package:shared_preferences/shared_preferences.dart';

const cheap = 'ovid-image:img-aaaaaa';
const pro = 'ovid-image:img-bbbbbb';
const hash = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';

Map<String, dynamic> card(
  String slug, {
  Map<String, dynamic> ops = const {'generate': {}},
  List<String> sizes = const ['1024x1024'],
  List<String> ratios = const ['1:1'],
  Map<String, dynamic> extra = const {},
}) => {
  'slug': slug,
  'tags': ['fast'],
  'operations': ops,
  'sizes': sizes,
  'aspect_ratios': ratios,
  'max_n': 1,
  'input': {'max_images': ops.containsKey('edit') ? 3 : 0, 'formats': ['png']},
  'text_rendering': 'none',
  'quality': 'med',
  'speed': 'fast',
  'latency_p50_s': 5,
  'cost_tier': 'low',
  'verified': true,
  ...extra,
};

Map<String, dynamic> payload() => <String, dynamic>{
  'model': 'ovid-image',
  'operations': {
    'generate': ['1024x1024', '1792x1024'],
    'edit': ['1024x1024', '1792x1024'],
  },
  'catalog_hash': hash,
  'models': <dynamic>[
    card(cheap),
    card(
      pro,
      ops: {
        'generate': {},
        'edit': {},
        'inpaint': {},
        'multi_image': {'max_inputs': 3},
      },
      sizes: ['1024x1024', '1792x1024'],
      ratios: ['1:1', '16:9'],
      extra: {'quality': 'high', 'text_rendering': 'good', 'cost_tier': 'high'},
    ),
  ],
};

Future<Uint8List> picture() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 8, 6),
    ui.Paint()..color = const ui.Color(0xffff0000),
  );
  final pic = recorder.endRecording();
  final image = await pic.toImage(8, 6);
  final bytes = (await image.toByteData(
    format: ui.ImageByteFormat.png,
  ))!.buffer.asUint8List();
  image.dispose();
  pic.dispose();
  return bytes;
}

Map<String, dynamic> toolNamed(ImageStudio studio, String name) =>
    (studio.tools.firstWhere((t) => (t['function'] as Map)['name'] == name))['function']
        as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const headers = {'Authorization': 'Bearer fixture'};

  group('parsing', () {
    test('parses cards, sizes, hash and etag', () {
      final caps = ImageCapabilities.parse(payload(), legacySizes: ImageStudio.sizes);
      expect(caps.legacy, isFalse);
      expect(caps.models.map((m) => m.slug), [cheap, pro]);
      expect(caps.etag, '"$hash"');
      expect(caps.sizesFor('edit'), ['1024x1024', '1792x1024']);
      expect(caps.sizesFor('edit', model: cheap), isEmpty);
      expect(caps.canServe('generate', '1792x1024', model: cheap), isFalse);
      expect(caps.canServe('generate', '1792x1024'), isTrue);
      expect(caps.models.last.maxInputs, 3);
    });

    test('malformed cards are dropped, never thrown', () {
      final bad = payload();
      (bad['models'] as List<dynamic>)
        ..add({'slug': 'gpt-image-2', 'operations': {'generate': {}}})
        ..add('junk')
        ..add({'slug': 'ovid-image:img-cccccc', 'operations': {}});
      final caps = ImageCapabilities.parse(bad);
      expect(caps.models.length, 2);
    });

    test('old payload without models still yields tools identical to before', () {
      final caps = ImageCapabilities.parse({
        'model': 'ovid-image',
        'operations': {
          'generate': ['1024x1024', '1536x1024'],
          'edit': ['1024x1024'],
        },
      }, legacySizes: ImageStudio.sizes);
      expect(caps.legacy, isTrue);
      expect(caps.sizesFor('generate'), ['1024x1024', '1536x1024']);
      expect(caps.sizesFor('edit'), ['1024x1024']);
    });
  });

  group('studio cache + tools', () {
    ImageStudio studio(MockClientHandler handler) {
      final s = ImageStudio(
        receiptStore: ImageReceiptStore(preferences: SharedPreferences.getInstance),
        client: MockClient(handler),
      );
      s.bindAccount('fixture');
      return s;
    }

    test('old server payload produces the legacy tool schema', () async {
      final s = studio(
        (_) async => http.Response(
          jsonEncode({
            'model': 'ovid-image',
            'operations': {
              'generate': ['1024x1024'],
              'edit': ['1024x1024'],
            },
          }),
          200,
        ),
      );
      await s.refresh(headers);
      final generate = toolNamed(s, 'generate_image');
      final props = (generate['parameters'] as Map)['properties'] as Map;
      expect(props.keys, ['prompt', 'size', 'request_id']);
      expect(generate['description'], isNot(contains('Available models')));
      expect(toolNamed(s, 'edit_image')['description'], contains('No masks'));
    });

    test('tool description carries capability table and local-ops guidance', () async {
      final s = studio((_) async => http.Response(jsonEncode(payload()), 200));
      await s.refresh(headers);
      final edit = toolNamed(s, 'edit_image');
      final text = edit['description'] as String;
      expect(text, contains(pro));
      expect(text, isNot(contains(cheap))); // cheap cannot edit
      expect(text, contains('inpaint'));
      expect(text, contains('multi(3)'));
      expect(text, contains('16:9'));
      expect(text, contains('crop, resize, rotate'));
      expect(text, contains('NEVER an image model'));
      expect(text, contains('omit `model`'));
      expect(text, contains('cheapest/fastest'));
      expect(text, contains('crop_image locally'));
      final props = (edit['parameters'] as Map)['properties'] as Map;
      expect((props['model'] as Map)['enum'], [pro]);
      expect((props['preference'] as Map)['enum'], preferences);
      expect(props.containsKey('mask_path'), isTrue);
      expect(props.containsKey('reference_paths'), isTrue);
      expect(((props['requirements'] as Map)['properties'] as Map).containsKey('aspect_ratio'), isTrue);
      final gen = toolNamed(s, 'generate_image');
      expect(((gen['parameters'] as Map)['properties'] as Map)['model']['enum'], [cheap, pro]);
      expect(((gen['parameters'] as Map)['properties'] as Map)['size']['enum'], ['1024x1024', '1792x1024']);
      // Local tools say they need no model.
      expect(toolNamed(s, 'crop_image')['description'], contains('no image model'));
      expect(toolNamed(s, 'resize_image')['description'], contains('never a cloud model'));
    });

    test('edit tool hides mask_path/reference_paths when no model supports them', () async {
      final p = payload();
      p['models'] = <dynamic>[
        card(
          pro,
          ops: {'generate': {}, 'edit': {}},
          sizes: ['1024x1024'],
          extra: {
            'input': {'max_images': 1, 'formats': ['png']},
          },
        ),
      ];
      final s = studio((_) async => http.Response(jsonEncode(p), 200));
      await s.refresh(headers);
      final edit = toolNamed(s, 'edit_image');
      final props = (edit['parameters'] as Map)['properties'] as Map;
      expect(props.containsKey('mask_path'), isFalse);
      expect(props.containsKey('reference_paths'), isFalse);
      final reqProps = (props['requirements'] as Map)['properties'] as Map;
      expect((reqProps['operation'] as Map)['enum'], ['edit']);
    });

    test('ETag cache: 304 reuses cards and ensureFresh skips the network', () async {
      var gets = 0;
      final conditional = <String?>[];
      final s = studio((r) async {
        gets++;
        conditional.add(r.headers['If-None-Match']);
        if (r.headers['If-None-Match'] == '"$hash"') {
          return http.Response('', 304, headers: {'etag': '"$hash"'});
        }
        return http.Response(jsonEncode(payload()), 200, headers: {'etag': '"$hash"'});
      });
      await s.refresh(headers);
      expect(s.capabilities.models.length, 2);
      await s.ensureFresh(headers);
      await s.ensureFresh(headers);
      expect(gets, 1, reason: 'fresh cache means no per-request discovery');
      await s.refresh(headers); // forced revalidation
      expect(gets, 2);
      expect(conditional, [null, '"$hash"']);
      expect(s.capabilities.models.length, 2, reason: '304 keeps the cards');
    });

    test('changing account drops the cached etag', () async {
      final seen = <String?>[];
      final s = studio((r) async {
        seen.add(r.headers['If-None-Match']);
        return http.Response(jsonEncode(payload()), 200);
      });
      await s.refresh(headers);
      s.bindAccount('someone-else');
      await s.refresh(headers);
      expect(seen, [null, null]);
    });

    test('explicit model slug, preference and requirements reach the server in sorted order', () async {
      final bytes = await picture();
      Map<String, dynamic>? sent;
      String? path;
      final s = studio((r) async {
        if (r.method == 'GET') return http.Response(jsonEncode(payload()), 200);
        path = r.url.path;
        sent = jsonDecode(r.body) as Map<String, dynamic>;
        final pending = (await ImageReceiptStore(
          preferences: SharedPreferences.getInstance,
        ).list('fixture')).single;
        return http.Response(
          jsonEncode({
            'model': 'ovid-image',
            'model_slug': pro,
            'receipt': {
              'account_id': 'fixture',
              'request_id': pending.requestId,
              'fingerprint': pending.fingerprint,
              'state': 'confirmed',
              'charged': '0.030',
              'model': pro,
            },
            'data': [
              {'b64_json': base64Encode(bytes), 'mime_type': 'image/png'},
            ],
          }),
          200,
        );
      });
      await s.refresh(headers);
      final result = await s.inferResult(
        prompt: 'make the sky violet',
        size: '1792x1024',
        input: bytes,
        mask: bytes,
        references: [bytes],
        headers: headers,
        requestId: 'test-request-1234',
        model: pro,
        preference: 'quality',
        requirements: {'transparent_background': true, 'aspect_ratio': '16:9'},
      );
      expect(path, '/v1/images/edits');
      expect(sent!['model'], pro);
      expect(sent!['preference'], 'quality');
      expect(sent!['requirements'], {'aspect_ratio': '16:9', 'transparent_background': true});
      expect(sent!.containsKey('mask'), isTrue);
      expect((sent!['images'] as List).length, 1);
      expect(sent!.keys.toList(), sent!.keys.toList()..sort());
      expect(result.servedModel, pro);
      expect(result.receipt!.modelSlug, pro);
      expect(result.bytes, bytes);
    });

    test('omitted model sends the legacy alias and no routing hints', () async {
      final bytes = await picture();
      Map<String, dynamic>? sent;
      final s = studio((r) async {
        if (r.method == 'GET') return http.Response(jsonEncode(payload()), 200);
        sent = jsonDecode(r.body) as Map<String, dynamic>;
        return http.Response('{}', 503);
      });
      await s.refresh(headers);
      await s.inferResult(
        prompt: 'a cat',
        size: '1024x1024',
        headers: headers,
        requestId: 'test-request-5678',
      );
      expect(sent!.keys.toList(), ['model', 'prompt', 'size']);
      expect(sent!['model'], 'ovid-image');
      expect(bytes, isNotEmpty);
    });

    test('model that cannot serve the operation never reaches the network', () async {
      var posts = 0;
      final s = studio((r) async {
        if (r.method == 'GET') return http.Response(jsonEncode(payload()), 200);
        posts++;
        return http.Response('{}', 503);
      });
      await s.refresh(headers);
      await expectLater(
        s.inferResult(
          prompt: 'x',
          size: '1024x1024',
          input: await picture(),
          headers: headers,
          requestId: 'test-request-9999',
          model: cheap,
        ),
        throwsA(isA<ImageStudioError>()),
      );
      expect(posts, 0);
    });

    test('invalid hints are rejected locally', () async {
      final s = studio((_) async => http.Response(jsonEncode(payload()), 200));
      await s.refresh(headers);
      for (final bad in [
        () => s.inferResult(prompt: 'x', size: '1024x1024', headers: headers, requestId: 'test-request-1111', model: 'gpt-image-2'),
        () => s.inferResult(prompt: 'x', size: '1024x1024', headers: headers, requestId: 'test-request-1111', preference: 'wow'),
        () => s.inferResult(prompt: 'x', size: '1024x1024', headers: headers, requestId: 'test-request-1111', requirements: {'provider': 'x'}),
        () => s.inferResult(prompt: 'x', size: '1024x1024', headers: headers, requestId: 'test-request-1111', mask: Uint8List(1)),
      ]) {
        await expectLater(bad(), throwsA(isA<ImageStudioError>()));
      }
    });

    test('422 surfaces public alternatives for the agent', () async {
      final bytes = await picture();
      final s = studio((r) async {
        if (r.method == 'GET') return http.Response(jsonEncode(payload()), 200);
        return http.Response(
          jsonEncode({
            'error': {
              'code': 'unsupported_image_operation',
              'alternatives': [pro, 'provider/secret-model'],
            },
          }),
          422,
        );
      });
      await s.refresh(headers);
      final result = await s.inferResult(
        prompt: 'x',
        size: '1024x1024',
        headers: headers,
        requestId: 'test-request-2222',
        model: cheap,
        requirements: {'transparent_background': true},
      );
      expect(result.error!.statusCode, 422);
      expect(result.error!.message, contains(pro));
      expect(result.error!.message, isNot(contains('secret-model')));
      expect(bytes, isNotEmpty);
    });
  });

  test('receipt model slug is validated and persisted', () {
    final base = {
      'account_id': 'a',
      'request_id': 'request-1234',
      'fingerprint': 'f' * 64,
      'state': 'confirmed',
      'charged': '0.1',
    };
    expect(ImageReceipt.parse({...base, 'model': pro}).modelSlug, pro);
    expect(ImageReceipt.parse({...base, 'model': 'cb/gpt-image-2'}).modelSlug, isNull);
    expect(ImageReceipt.parse(base).toJson().containsKey('model'), isFalse);
    expect(ImageReceipt.parse({...base, 'model': pro}).toJson()['model'], pro);
  });
}
