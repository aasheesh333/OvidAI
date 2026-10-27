import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ovid_ai/ui/design/o_theme.dart';
import 'package:ovid_ai/ui/v2/chat/remote_attachment_tile.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'chunked response stops at the byte cap before full buffering',
    () async {
      var generatedChunks = 0;
      Stream<List<int>> chunks() async* {
        for (var i = 0; i < 4; i++) {
          generatedChunks++;
          yield List<int>.filled(8, i);
          await Future<void>.delayed(Duration.zero);
        }
      }

      final client = _ChunkClient(
        http.StreamedResponse(
          chunks(),
          200,
          headers: <String, String>{'content-type': 'image/png'},
        ),
      );
      await expectLater(
        loadBoundedRemoteImage(
          'https://images.example/chunked.png',
          client: client,
          maxBytes: 15,
        ),
        throwsFormatException,
      );
      expect(generatedChunks, 2);
    },
  );

  test(
    'declared oversized content is refused before chunks are consumed',
    () async {
      var emitted = false;
      Stream<List<int>> chunks() async* {
        emitted = true;
        yield List<int>.filled(8, 0);
      }

      final client = _ChunkClient(
        http.StreamedResponse(
          chunks(),
          200,
          contentLength: 1024,
          headers: <String, String>{'content-type': 'image/png'},
        ),
      );
      await expectLater(
        loadBoundedRemoteImage(
          'https://images.example/large.png',
          client: client,
          maxBytes: 16,
        ),
        throwsFormatException,
      );
      expect(emitted, isFalse);
    },
  );

  testWidgets(
    'intrinsic dimensions are bounded before full-resolution decode',
    (tester) async {
      final bytes = _pngWithDimensions(100000, 80000);
      await tester.pumpWidget(
        MaterialApp(
          theme: OTheme.light(),
          home: RemoteTranscriptImage(
            url: 'https://images.example/huge.png',
            alt: 'Huge',
            loader: (_) async => bytes,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Image unavailable'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    },
  );

  testWidgets('valid VP8X uses exact little-endian canvas dimensions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: RemoteTranscriptImage(
          url: 'https://images.example/valid-extended.webp',
          alt: 'Extended WebP',
          loader: (_) async => _validVp8x,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Image unavailable'), findsNothing);
  });

  testWidgets('crafted small legacy offsets cannot bypass VP8X canvas bounds', (
    tester,
  ) async {
    final crafted = Uint8List.fromList(_validVp8x);
    crafted.fillRange(18, 24, 0);
    _writeUint24(crafted, 24, 4999); // Actual canvas width = 5000.
    _writeUint24(crafted, 27, 4999); // Actual canvas height = 5000.

    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: RemoteTranscriptImage(
          url: 'https://images.example/oversize-extended.webp',
          alt: 'Oversize WebP',
          loader: (_) async => crafted,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Image unavailable'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a truncated VP8X header fails closed before decode', (
    tester,
  ) async {
    final truncated = Uint8List.fromList(_validVp8x.sublist(0, 29));
    await tester.pumpWidget(
      MaterialApp(
        theme: OTheme.light(),
        home: RemoteTranscriptImage(
          url: 'https://images.example/truncated-extended.webp',
          alt: 'Truncated WebP',
          loader: (_) async => truncated,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Image unavailable'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  test('ordinary bounded image bytes remain accepted', () async {
    final client = _ChunkClient(
      http.StreamedResponse(
        Stream<List<int>>.fromIterable(<List<int>>[
          _tinyPng.sublist(0, 20),
          _tinyPng.sublist(20),
        ]),
        200,
        headers: <String, String>{'content-type': 'image/png'},
      ),
    );
    final bytes = await loadBoundedRemoteImage(
      'https://images.example/ordinary.png',
      client: client,
      maxBytes: 1024,
    );
    expect(bytes, _tinyPng);
  });
}

class _ChunkClient extends http.BaseClient {
  _ChunkClient(this.response);

  final http.StreamedResponse response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.finalize();
    return response;
  }
}

/// Valid PNG signature/IHDR with deliberately extreme dimensions. It need not
/// contain a full image: bounds are checked before a full-resolution decode.
Uint8List _pngWithDimensions(int width, int height) {
  final bytes = Uint8List.fromList(_tinyPng);
  final data = ByteData.view(bytes.buffer);
  data.setUint32(16, width);
  data.setUint32(20, height);
  return bytes;
}

final Uint8List _validVp8x = base64Decode(
  'UklGRg4CAABXRUJQVlA4WAoAAAAQAAAAAQEAAgIAQUxQSA0AAAABB1DAiAheRERERP8DAFZQOCDaAQAAMDUAnQEqAgEDAj5t'
  'NptJpCMioSAIAIANiWlu4XZ2COAfYD9AJH31ztVIPXzwrP09UzqaEoNW+usu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4y'
  'LvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x'
  '4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi'
  '7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8e'
  'Mi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu'
  '8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvHjIu8eMi7x4yLvBgAA/v+tdvzse4P/'
  'QfEp1D8GXmOLJN5ohn7yaIZ+8miGfvJohnBeQIAA',
);

void _writeUint24(Uint8List bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
  bytes[offset + 2] = (value >> 16) & 0xff;
}

final Uint8List _tinyPng = Uint8List.fromList(const <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
]);
