import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ovid_ai/core/image_studio.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local resize/crop decode real content and enforce bounds', () async {
    final bytes = await picture();
    final resized = await ImageStudio.transform(bytes, width: 4, height: 3);
    final info = await ImageStudio.inspect(resized);
    expect((info.width, info.height, info.mime), (4, 3, 'image/png'));
    final crop = await ImageStudio.transform(
      bytes,
      width: 2,
      height: 2,
      x: 6,
      y: 4,
    );
    expect((await ImageStudio.inspect(crop)).width, 2);
    await expectLater(
      ImageStudio.transform(bytes, width: 3, height: 2, x: 6, y: 4),
      throwsA(isA<ImageStudioError>()),
    );
    await expectLater(
      ImageStudio.transform(bytes, width: 0, height: 2),
      throwsA(isA<ImageStudioError>()),
    );
    await expectLater(
      ImageStudio.inspect(Uint8List.fromList(utf8.encode('<html>bad</html>'))),
      throwsA(isA<ImageStudioError>()),
    );
  });

  test(
    'edits send exact staged bytes and only public alias; returned bytes saved as actual type',
    () async {
      final bytes = await picture();
      final dir = await Directory.systemTemp.createTemp('image-studio-');
      addTearDown(() => dir.delete(recursive: true));
      final studio = ImageStudio(
        client: MockClient((request) async {
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'model': 'ovid-image',
                'operations': {
                  'generate': ['1024x1024'],
                  'edit': ['1024x1024'],
                },
              }),
              200,
            );
          }
          expect(request.url.path, '/v1/images/edits');
          final body = jsonDecode(request.body) as Map;
          expect(body['image'], 'data:image/png;base64,${base64Encode(bytes)}');
          expect(body['model'], 'ovid-image');
          expect(request.headers['idempotency-key'], 'test-request-1234');
          return http.Response(
            jsonEncode({
              'model': 'ovid-image',
              'data': [
                {'b64_json': base64Encode(bytes), 'mime_type': 'image/png'},
              ],
            }),
            200,
          );
        }),
      );
      await studio.refresh({'Authorization': 'Bearer fixture'});
      final output = await studio.infer(
        prompt: 'edit',
        size: '1024x1024',
        input: bytes,
        headers: {'Authorization': 'Bearer fixture'},
        requestId: 'test-request-1234',
      );
      final saved = await ImageStudio.save(output, dir);
      expect(saved.path.endsWith('.png'), isTrue);
      expect(await saved.readAsBytes(), bytes);
    },
  );

  test(
    'unavailable capabilities never advertise generation and redact raw errors',
    () async {
      final studio = ImageStudio(
        client: MockClient(
          (_) async => http.Response('secret backend-id price key', 503),
        ),
      );
      await studio.refresh({'Authorization': 'Bearer fixture'});
      expect(studio.tools.map((t) => (t['function'] as Map)['name']), [
        'resize_image',
        'crop_image',
      ]);
      await expectLater(
        studio.infer(
          prompt: 'x',
          size: '1024x1024',
          headers: {},
          requestId: 'request-1234',
        ),
        throwsA(
          isA<ImageStudioError>().having(
            (e) => e.toString(),
            'redacted',
            isNot(contains('backend-id')),
          ),
        ),
      );
    },
  );

  test(
    'reject URL responses and edit requests without edit capability',
    () async {
      var posts = 0;
      final studio = ImageStudio(
        client: MockClient((r) async {
          if (r.method == 'GET') {
            return http.Response(
              jsonEncode({
                'model': 'ovid-image',
                'operations': {
                  'generate': ['1024x1024'],
                  'edit': [],
                },
              }),
              200,
            );
          }
          posts++;
          return http.Response(
            jsonEncode({
              'model': 'ovid-image',
              'data': [
                {'url': 'http://localhost/private'},
              ],
            }),
            200,
          );
        }),
      );
      await studio.refresh({'Authorization': 'Bearer fixture'});
      await expectLater(
        studio.infer(
          prompt: 'x',
          size: '1024x1024',
          input: await picture(),
          headers: {},
          requestId: 'request-1234',
        ),
        throwsA(isA<ImageStudioError>()),
      );
      expect(posts, 0);
      await expectLater(
        studio.infer(
          prompt: 'x',
          size: '1024x1024',
          headers: {},
          requestId: 'request-1234',
        ),
        throwsA(isA<ImageStudioError>()),
      );
    },
  );
}
