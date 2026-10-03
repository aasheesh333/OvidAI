import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

class ImageStudioError implements Exception {
  const ImageStudioError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The only image inference contract exposed to the app is Ovid's public alias.
/// Local operations use Flutter's image codec/canvas and require no cloud key.
class ImageStudio {
  ImageStudio({http.Client? client})
    : _client = client; // ignore: prefer_initializing_formals
  static final I = ImageStudio();
  final http.Client? _client;
  static const alias = 'ovid-image';
  static const maxBytes = 16 * 1024 * 1024;
  static const sizes = ['1024x1024', '1536x1024', '1024x1536', '2048x2048'];
  static const _base = 'https://cloud.dhanuksoftwares.com/v1/images';
  Map<String, List<String>> _operations = {};
  DateTime? _refreshed;

  List<String> supportedSizes(String operation) =>
      _refreshed != null &&
          DateTime.now().difference(_refreshed!) < const Duration(minutes: 5)
      ? _operations[operation] ?? const []
      : const [];

  void clearCapabilities() {
    _operations = {};
    _refreshed = null;
  }

  Future<void> refresh(Map<String, String> headers) async {
    clearCapabilities();
    if (headers.isEmpty) return;
    try {
      final body = await _request(
        'GET',
        'capabilities',
        headers,
        null,
        maxResponse: 16384,
      );
      if (body['model'] != alias || body['operations'] is! Map) return;
      for (final op in ['generate', 'edit']) {
        final values = (body['operations'] as Map)[op];
        if (values is List) {
          _operations[op] = values
              .whereType<String>()
              .where(sizes.contains)
              .toSet()
              .toList();
        }
      }
      _refreshed = DateTime.now();
    } catch (_) {
      clearCapabilities();
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String endpoint,
    Map<String, String> headers,
    Map<String, dynamic>? body, {
    int maxResponse = maxBytes * 4 ~/ 3 + 65536,
  }) async {
    final client = _client ?? http.Client();
    try {
      return await (() async {
        final request = http.Request(method, Uri.parse('$_base/$endpoint'));
        request.followRedirects = false;
        request.headers.addAll({
          ...headers,
          'Content-Type': 'application/json',
        });
        if (body != null) request.body = jsonEncode(body);
        final response = await client.send(request);
        if (response.statusCode != 200) {
          if (response.statusCode == 401 || response.statusCode == 403) {
            clearCapabilities();
            throw const ImageStudioError(
              'Image access requires a current Ovid Cloud sign-in and image permission.',
            );
          }
          if (response.statusCode == 402) {
            throw const ImageStudioError('Image usage limit reached.');
          }
          if (response.statusCode == 409) {
            throw const ImageStudioError(
              'Image request is pending or already recorded. Do not submit a new paid request; retry with the same request_id.',
            );
          }
          throw const ImageStudioError(
            'Ovid image service is unavailable or rejected this request.',
          );
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxResponse) {
            throw const ImageStudioError(
              'Image response exceeds the size limit.',
            );
          }
          bytes.add(chunk);
        }
        return jsonDecode(utf8.decode(bytes.takeBytes()))
            as Map<String, dynamic>;
      })().timeout(
        method == 'GET'
            ? const Duration(seconds: 15)
            : const Duration(seconds: 120),
      );
    } on ImageStudioError {
      rethrow;
    } catch (_) {
      throw const ImageStudioError(
        'Image request could not be confirmed. Retry with the same request_id to avoid another paid job.',
      );
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<Uint8List> infer({
    required String prompt,
    required String size,
    Uint8List? input,
    required Map<String, String> headers,
    required String requestId,
  }) async {
    final operation = input == null ? 'generate' : 'edit';
    if (!supportedSizes(operation).contains(size)) {
      throw const ImageStudioError(
        'This image operation or size is currently unavailable.',
      );
    }
    if (prompt.trim().isEmpty ||
        prompt.length > 8000 ||
        !RegExp(r'^[A-Za-z0-9_.:-]{8,128}$').hasMatch(requestId)) {
      throw const ImageStudioError(
        'Supply a prompt (1–8000 characters) and request_id (8–128 letters, digits, dots, colons, underscores or hyphens).',
      );
    }
    final inputInfo = input == null ? null : await inspect(input);
    final response = await _request(
      'POST',
      input == null ? 'generations' : 'edits',
      {...headers, 'Idempotency-Key': requestId},
      {
        'model': alias,
        'prompt': prompt,
        'size': size,
        if (input != null)
          'image': 'data:${inputInfo!.mime};base64,${base64Encode(input)}',
      },
    );
    try {
      if (response['model'] != alias) throw const FormatException();
      final data = response['data'] as List;
      if (data.length != 1) throw const FormatException();
      final encoded = (data.single as Map)['b64_json'] as String;
      if (encoded.length > (maxBytes + 2) ~/ 3 * 4) {
        throw const FormatException();
      }
      final bytes = base64Decode(encoded);
      final info = await inspect(bytes);
      if ((data.single as Map)['mime_type'] != info.mime) {
        throw const FormatException();
      }
      return bytes;
    } catch (_) {
      throw const ImageStudioError(
        'The image service returned invalid image content. Retry only with the same request_id.',
      );
    }
  }

  static Future<({int width, int height, String mime})> inspect(
    Uint8List bytes,
  ) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const ImageStudioError('Image must be at most 16 MiB.');
    }
    String mime;
    if (bytes.length >= 8 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71) {
      mime = 'image/png';
    } else if (bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255) {
      mime = 'image/jpeg';
    } else if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      mime = 'image/webp';
    } else {
      throw const ImageStudioError('Supply an actual PNG, JPEG or WebP image.');
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width < 1 ||
          descriptor.height < 1 ||
          descriptor.width > 4096 ||
          descriptor.height > 4096) {
        throw const ImageStudioError(
          'Images must be within 4096 × 4096 pixels.',
        );
      }
      codec = await descriptor.instantiateCodec();
      if (codec.frameCount != 1) {
        throw const ImageStudioError('Animated images are unsupported.');
      }
      image = (await codec.getNextFrame()).image;
      return (width: image.width, height: image.height, mime: mime);
    } on ImageStudioError {
      rethrow;
    } catch (_) {
      throw const ImageStudioError('Image content could not be decoded.');
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static Future<Uint8List> readInput(File file) async {
    // Stream limit protects against a file growing after its length is checked.
    if (await file.length() > maxBytes) {
      throw const ImageStudioError('Image must be at most 16 MiB.');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (builder.length + chunk.length > maxBytes) {
        throw const ImageStudioError('Image must be at most 16 MiB.');
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    await inspect(bytes);
    return bytes;
  }

  static Future<Uint8List> transform(
    Uint8List bytes, {
    required int width,
    required int height,
    int? x,
    int? y,
  }) async {
    final info = await inspect(bytes);
    if (width < 1 ||
        height < 1 ||
        width > 4096 ||
        height > 4096 ||
        (x == null) != (y == null) ||
        (x != null &&
            (x < 0 ||
                y! < 0 ||
                x + width > info.width ||
                y + height > info.height))) {
      throw const ImageStudioError(
        'Invalid size or crop rectangle; crop must fit inside the source image.',
      );
    }
    final codec = await ui.instantiateImageCodec(bytes);
    final source = (await codec.getNextFrame()).image;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      source,
      x == null
          ? ui.Rect.fromLTWH(
              0,
              0,
              info.width.toDouble(),
              info.height.toDouble(),
            )
          : ui.Rect.fromLTWH(
              x.toDouble(),
              y!.toDouble(),
              width.toDouble(),
              height.toDouble(),
            ),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final picture = recorder.endRecording();
    ui.Image? output;
    try {
      output = await picture.toImage(width, height);
      final result = (await output.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      if (result.length > maxBytes) {
        throw const ImageStudioError('Output exceeds 16 MiB.');
      }
      return result;
    } finally {
      output?.dispose();
      picture.dispose();
      source.dispose();
      codec.dispose();
    }
  }

  static Future<File> save(Uint8List bytes, Directory workspace) async {
    final info = await inspect(bytes);
    final extension = switch (info.mime) {
      'image/jpeg' => 'jpg',
      'image/webp' => 'webp',
      _ => 'png',
    };
    // A private random directory avoids overwrite and pre-existing symlink targets.
    final directory = await workspace.createTemp('image-');
    final file = File('${directory.path}/output.$extension');
    try {
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  List<Map<String, dynamic>> get tools => [
    for (final op in ['generate', 'edit'])
      if (supportedSizes(op).isNotEmpty)
        _schema(
          '${op}_image',
          op == 'edit'
              ? 'Edit an existing image through Ovid Cloud. Use the exact attachment or returned file path. No masks or multiple inputs supported.'
              : 'Generate one image through Ovid Cloud. Returns a saved local image path and displays it in chat.',
          {
            'prompt': {'type': 'string', 'minLength': 1, 'maxLength': 8000},
            'size': {'type': 'string', 'enum': supportedSizes(op)},
            'request_id': {
              'type': 'string',
              'description':
                  'Stable unique ID for this image job, 8–128 characters. Reuse it for retries; never change it after an uncertain outcome.',
            },
            if (op == 'edit') 'path': _path,
          },
          ['prompt', 'size', 'request_id', if (op == 'edit') 'path'],
        ),
    for (final op in ['resize', 'crop'])
      _schema(
        '${op}_image',
        op == 'resize'
            ? 'Resize locally to exact dimensions; may change aspect ratio. Returns a new PNG path.'
            : 'Crop locally using a top-left pixel rectangle inside the source. Returns a new PNG path.',
        {
          'path': _path,
          'width': _dimension,
          'height': _dimension,
          if (op == 'crop') ...{
            'x': {'type': 'integer', 'minimum': 0},
            'y': {'type': 'integer', 'minimum': 0},
          },
        },
        [
          'path',
          'width',
          'height',
          if (op == 'crop') ...['x', 'y'],
        ],
      ),
  ];

  static const _path = {
    'type': 'string',
    'description':
        'Exact existing image path, including attachment subdirectories. Never guess a basename.',
  };
  static const _dimension = {'type': 'integer', 'minimum': 1, 'maximum': 4096};
  static Map<String, dynamic> _schema(
    String name,
    String description,
    Map<String, dynamic> properties,
    List<String> required,
  ) => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': properties,
        'required': required,
      },
    },
  };
}
