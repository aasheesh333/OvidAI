import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'diag.dart';
import 'image_receipt_store.dart';

export 'image_receipt_store.dart' show ImageReceipt, ImageRequestRecord;

class ImageStudioError implements Exception {
  const ImageStudioError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Exact accounting and actual output are independent. Result recovery only
/// exposes bytes accompanied by matching authenticated terminal accounting.
class ImageStudioResult {
  const ImageStudioResult({
    required this.record,
    required this.receiptPersisted,
    this.bytes,
    this.notice,
  });
  final ImageRequestRecord record;
  final bool receiptPersisted;
  final Uint8List? bytes;
  final String? notice;
  ImageReceipt? get receipt => record.receipt;
  bool get imageAvailable => bytes != null;
}

class _ImageHttpResponse {
  const _ImageHttpResponse(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
}

/// The only image inference contract exposed to the app is Ovid's public alias.
/// Local operations use Flutter's image codec/canvas and require no cloud key.
class ImageStudio extends ChangeNotifier {
  ImageStudio({http.Client? client, ImageReceiptStore? receiptStore})
    : _client = client, // ignore: prefer_initializing_formals
      _store = receiptStore ?? ImageReceiptStore();
  static final I = ImageStudio();
  final http.Client? _client;
  final ImageReceiptStore _store;
  String? _accountId;
  int _generation = 0;
  int _capabilityGeneration = 0;
  List<ImageRequestRecord> _receipts = const [];
  List<ImageRequestRecord> get receipts => _receipts;
  String? get accountId => _accountId;
  int get accountGeneration => _generation;
  int _receiptLoadGeneration = 0;
  bool _receiptsLoading = false;
  bool get receiptsLoading => _receiptsLoading;
  String? _receiptLoadError;
  String? get receiptLoadError => _receiptLoadError;

  /// Call synchronously at every auth/account-readiness boundary, including
  /// sign-out and same-UID reauthentication. Bind null while not account-ready.
  void bindAccount(String? accountId) {
    _generation++;
    _accountId = accountId;
    _receipts = const [];
    _receiptsLoading = false;
    _receiptLoadError = null;
    clearCapabilities();
    notifyListeners();
  }

  bool _current(String account, int generation) =>
      _accountId == account && _generation == generation;

  void _checkCurrent(String account, int generation) {
    if (!_current(account, generation)) {
      throw const ImageStudioError(
        'Image account changed. Reopen receipts under the original account.',
      );
    }
  }

  static String newRequestId() =>
      'image-${base64UrlEncode(List.generate(24, (_) => Random.secure().nextInt(256))).replaceAll('=', '')}';

  Future<void> loadReceipts() async {
    final account = _accountId;
    final generation = _generation;
    if (account == null) return;
    final loadGeneration = ++_receiptLoadGeneration;
    _receiptsLoading = true;
    _receiptLoadError = null;
    notifyListeners();
    try {
      final rows = await _store.list(account);
      _checkCurrent(account, generation);
      if (loadGeneration == _receiptLoadGeneration) _receipts = rows;
    } catch (_) {
      if (_current(account, generation) &&
          loadGeneration == _receiptLoadGeneration) {
        _receiptLoadError =
            'Image receipts could not be loaded. Retry loading before starting new image work.';
      }
      rethrow;
    } finally {
      if (_current(account, generation) &&
          loadGeneration == _receiptLoadGeneration) {
        _receiptsLoading = false;
        notifyListeners();
      }
    }
  }

  /// Invoke before account cleanup; invalidates in-flight publication immediately.
  /// Keep the journal key during prefs reset/restore. It contains dedup fences.
  Future<void> clearAccountData(
    String accountId, {
    bool deleted = false,
  }) async {
    if (_accountId == accountId) bindAccount(null);
    await _store.redactAccount(accountId, deleted: deleted);
  }

  static const alias = 'ovid-image';
  static const maxBytes = 16 * 1024 * 1024;
  static const sizes = ['1024x1024', '1536x1024', '1024x1536', '2048x2048'];
  static const _base = 'https://api.ovidsi.com/v1/images';
  Map<String, List<String>> _operations = {};
  DateTime? _refreshed;

  List<String> supportedSizes(String operation) =>
      _refreshed != null &&
          DateTime.now().difference(_refreshed!) < const Duration(minutes: 5)
      ? _operations[operation] ?? const []
      : const [];

  void clearCapabilities() {
    _capabilityGeneration++;
    _operations = {};
    _refreshed = null;
  }

  Future<void> refresh(Map<String, String> headers) async {
    clearCapabilities();
    final account = _accountId;
    final generation = _generation;
    final capabilityGeneration = _capabilityGeneration;
    if (headers.isEmpty || account == null) return;
    try {
      final response = await _request(
        'GET',
        'capabilities',
        headers,
        null,
        maxResponse: 16384,
      );
      if (!_current(account, generation) ||
          capabilityGeneration != _capabilityGeneration) {
        return;
      }
      final body = response.body;
      if (response.status != 200) return;
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
      if (_current(account, generation) &&
          capabilityGeneration == _capabilityGeneration) {
        clearCapabilities();
      }
    }
  }

  Future<_ImageHttpResponse> _request(
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
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxResponse) {
            throw const ImageStudioError(
              'Image response exceeds the size limit.',
            );
          }
          bytes.add(chunk);
        }
        final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
        if (decoded is! Map<String, dynamic>) throw const FormatException();
        return _ImageHttpResponse(response.statusCode, decoded);
      })().timeout(
        method == 'GET'
            ? const Duration(seconds: 15)
            : const Duration(seconds: 120),
      );
    } on ImageStudioError {
      rethrow;
    } catch (_) {
      throw const ImageStudioError(
        'Image request could not be confirmed. Check the existing receipt; do not submit another paid job.',
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
    final result = await inferResult(
      prompt: prompt,
      size: size,
      input: input,
      headers: headers,
      requestId: requestId,
    );
    if (result.bytes != null) return result.bytes!;
    throw ImageStudioError(
      result.notice ??
          'Image bytes are unavailable. Check the existing receipt; do not submit another paid job.',
    );
  }

  /// Compatibility [infer] delegates here; callers needing accounting must use
  /// this result. Reusing an admitted ID is ALWAYS a read-only GET, never POST.
  Future<ImageStudioResult> inferResult({
    required String prompt,
    required String size,
    Uint8List? input,
    required Map<String, String> headers,
    String? requestId,
  }) async {
    final account = _accountId;
    final generation = _generation;
    if (account == null || headers.isEmpty) {
      throw const ImageStudioError(
        'Image access requires a current account-bound Ovid Cloud sign-in.',
      );
    }
    // Freeze caller-owned mutable values before the first await.
    headers = Map<String, String>.of(headers);
    input = input == null ? null : Uint8List.fromList(input);
    requestId ??= newRequestId();
    final operation = input == null ? 'generate' : 'edit';
    if (prompt.trim().isEmpty ||
        prompt.runes.length > 8000 ||
        !sizes.contains(size) ||
        !validImageRequestId(requestId)) {
      throw const ImageStudioError(
        'Supply a prompt (1–8000 characters) and request_id (8–128 letters, digits, dots, colons, underscores or hyphens).',
      );
    }
    final inputInfo = input == null ? null : await inspect(input);
    _checkCurrent(account, generation);
    // Sorted keys + Python ensure_ascii=True semantics match baseline7839d52.
    final body = <String, dynamic>{
      if (input != null)
        'image': 'data:${inputInfo!.mime};base64,${base64Encode(input)}',
      'model': alias,
      'prompt': prompt,
      'size': size,
    };
    final fingerprint = sha256
        .convert(utf8.encode(_serverJson([operation, body])))
        .toString();
    final candidate = ImageRequestRecord(
      accountId: account,
      requestId: requestId,
      fingerprint: fingerprint,
    );
    late ({ImageRequestRecord record, bool created}) admission;
    try {
      admission = await _store.reserve(
        candidate,
        isCurrent: () => _current(account, generation),
        canSubmit: () => supportedSizes(operation).contains(size),
      );
    } on ImageAdmissionError catch (error) {
      _checkCurrent(account, generation);
      throw ImageStudioError(switch (error.reason) {
        ImageAdmissionReason.accountUnavailable =>
          'Image access is unavailable for this account. Sign in to an active Ovid Cloud account.',
        ImageAdmissionReason.identityConflict =>
          'Request ${error.record!.requestId} is already saved with different image content. '
              'Check its receipt in Usage → Image receipts before starting another job.',
        ImageAdmissionReason.capabilityUnavailable =>
          'Image generation or editing at this size is currently unavailable. '
              'Refresh Ovid Cloud image availability and try again. No new image request was submitted.',
        ImageAdmissionReason.unresolved =>
          'Image request ${error.record!.requestId} has an unresolved outcome. '
              'Open Usage → ⋮ → Image receipts → Check status for this request. '
              'No new image request was submitted.',
      });
    } catch (_) {
      _checkCurrent(account, generation);
      throw const ImageStudioError(
        'Image receipt storage could not be read or saved. No new image request was submitted. '
        'Open Usage → ⋮ → Image receipts and retry loading receipts.',
      );
    }
    _checkCurrent(account, generation);
    if (!admission.created) {
      return _recover(admission.record, headers, generation);
    }
    _publish(admission.record);
    _checkCurrent(account, generation);
    _ImageHttpResponse? response;
    try {
      response = await _request(
        'POST',
        input == null ? 'generations' : 'edits',
        {...headers, 'Idempotency-Key': requestId},
        body,
      );
    } catch (_) {
      // Durable admission already protects retries even if updating unknown fails.
    }
    _checkCurrent(account, generation);
    return _finish(admission.record, response, generation, allowImage: true);
  }

  /// Quota-independent status recovery. No capability refresh or POST needed.
  Future<ImageStudioResult> recover({
    required String requestId,
    required Map<String, String> headers,
    bool retrieveImage = false,
  }) async {
    final account = _accountId;
    final generation = _generation;
    if (account == null || headers.isEmpty || !validImageRequestId(requestId)) {
      throw const ImageStudioError(
        'Sign in to the original image account to check this receipt.',
      );
    }
    headers = Map<String, String>.of(headers);
    final rows = await _store.list(account);
    _checkCurrent(account, generation);
    final record = rows.where((r) => r.requestId == requestId).firstOrNull;
    if (record == null) {
      throw const ImageStudioError(
        'No saved request identity for this account.',
      );
    }
    return _recover(record, headers, generation, retrieveImage: retrieveImage);
  }

  Future<ImageStudioResult> _recover(
    ImageRequestRecord record,
    Map<String, String> headers,
    int generation, {
    bool retrieveImage = false,
  }) async {
    _checkCurrent(record.accountId, generation);
    _ImageHttpResponse? response;
    try {
      response = await _request(
        'GET',
        'requests/${Uri.encodeComponent(record.requestId)}',
        headers,
        null,
        maxResponse: 16384,
      );
    } catch (e) {
      Diag.swallow('image_studio.recover_status', e);
    }
    _checkCurrent(record.accountId, generation);
    final status = await _finish(
      record,
      response,
      generation,
      allowImage: false,
    );
    if (!retrieveImage || response?.status != 200 || !status.receiptPersisted) {
      return status;
    }
    // A local terminal row alone is not proof of current authenticated access.
    // Require the fresh ownership-scoped GET to agree with durable accounting.
    ImageReceipt? verified;
    try {
      verified = ImageReceipt.parse(response!.body['receipt']);
    } catch (e) {
      Diag.swallow('image_studio.recover_receipt', e);
    }
    if (verified?.state != 'confirmed' ||
        !_sameReceipt(verified, status.receipt)) {
      return status;
    }
    _checkCurrent(record.accountId, generation);
    _ImageHttpResponse? replay;
    try {
      replay = await _request(
        'GET',
        'requests/${Uri.encodeComponent(record.requestId)}/result',
        headers,
        null,
      );
    } catch (e) {
      Diag.swallow('image_studio.recover_replay', e);
    }
    _checkCurrent(record.accountId, generation);
    // Missing, foreign, or conflicting result receipts never inherit a saved
    // confirmation. Keep exact accounting even when replay expires or fails.
    ImageReceipt? replayReceipt;
    try {
      replayReceipt = ImageReceipt.parse(replay?.body['receipt']);
    } catch (e) {
      Diag.swallow('image_studio.replay_receipt', e);
    }
    if (replay?.status == 200 && _sameReceipt(verified, replayReceipt)) {
      return _finish(status.record, replay, generation, allowImage: true);
    }
    if (replay?.status == 401 || replay?.status == 403) clearCapabilities();
    return ImageStudioResult(
      record: status.record,
      receiptPersisted: status.receiptPersisted,
      notice: switch (replay?.status) {
        410 =>
          'Image result expired. Saved exact accounting is retained; no replacement job was submitted.',
        401 || 403 =>
          'Sign in to the original account with current image permission to recover this image.',
        200 =>
          'The image result receipt did not match the verified receipt. Saved exact accounting is retained; no replacement job was submitted.',
        _ =>
          'Image bytes are unavailable. Saved exact accounting is retained; retry recovery without submitting a new paid job.',
      },
    );
  }

  static bool _sameReceipt(ImageReceipt? a, ImageReceipt? b) =>
      a != null &&
      b != null &&
      a.accountId == b.accountId &&
      a.requestId == b.requestId &&
      a.fingerprint == b.fingerprint &&
      a.state == b.state &&
      a.charged == b.charged;

  Future<ImageStudioResult> _finish(
    ImageRequestRecord original,
    _ImageHttpResponse? response,
    int generation, {
    required bool allowImage,
  }) async {
    var record = original.unknown;
    Uint8List? bytes;
    ImageReceipt? returnedReceipt;
    String? notice;
    if (response?.status == 401 || response?.status == 403) clearCapabilities();
    try {
      if (response?.body['receipt'] != null) {
        returnedReceipt = ImageReceipt.parse(response!.body['receipt']);
        record = original.withReceipt(returnedReceipt);
      }
    } catch (_) {
      notice =
          'The returned receipt did not match the saved request. Check the existing receipt; do not resubmit.';
    }
    if (allowImage &&
        response?.status == 200 &&
        returnedReceipt != null &&
        record.state == 'confirmed' &&
        notice == null) {
      try {
        bytes = await _decodeImage(response!.body);
      } catch (_) {
        notice =
            'Charge confirmed, but the returned image could not be decoded. No replacement job was submitted.';
      }
    }
    _checkCurrent(original.accountId, generation);
    var persisted = false;
    try {
      record = await _store.update(
        record,
        isCurrent: () => _current(original.accountId, generation),
      );
      persisted = true;
    } on ImageReceiptConflict catch (conflict) {
      record = conflict.record;
      persisted = true;
      bytes = null;
      notice =
          'The returned receipt conflicts with saved accounting. The saved exact charge is retained; no replacement job was submitted.';
    } catch (_) {
      // Recovery may have read terminal accounting before storage became
      // unavailable. A stale/uncommitted response cannot replace that evidence.
      if (!original.unresolved) {
        record = original;
        bytes = null;
      }
      notice =
          'Receipt update could not be saved. The original request identity is retained; check it before any new paid job.';
    }
    _checkCurrent(original.accountId, generation);
    if (bytes != null && !_sameReceipt(returnedReceipt, record.receipt)) {
      bytes = null;
    }
    _publish(record);
    _checkCurrent(original.accountId, generation);
    notice ??= switch (response?.status) {
      410 =>
        'Server image replay or receipt retention expired. Saved accounting is retained; image bytes are unavailable.',
      404 =>
        'The server did not find this request. Its outcome remains uncertain; no new paid submission is allowed.',
      401 || 403 =>
        'Sign in to the original account with current image permission to check this receipt.',
      _ when record.state == 'failed' =>
        'Image request failed; exact charge ${record.receipt?.charged ?? 'unavailable'}. '
            'This receipt is resolved. You may start a new image request when image service is available.',
      _ =>
        bytes != null
            ? null
            : record.state == 'confirmed'
            ? 'Charge confirmed. Image bytes are unavailable from receipt recovery.'
            : 'Image outcome ${record.state}. Check this receipt; do not submit a replacement paid job.',
    };
    return ImageStudioResult(
      record: record,
      receiptPersisted: persisted,
      bytes: bytes,
      notice: notice,
    );
  }

  void _publish(ImageRequestRecord record) {
    _receipts = List.unmodifiable([
      ..._receipts.where((r) => r.requestId != record.requestId),
      record,
    ]);
    notifyListeners();
  }

  static String _serverJson(Object value) {
    final json = jsonEncode(value);
    final buffer = StringBuffer();
    for (final unit in json.codeUnits) {
      if (unit >= 0x7f) {
        buffer.write('\\u${unit.toRadixString(16).padLeft(4, '0')}');
      } else {
        buffer.writeCharCode(unit);
      }
    }
    return buffer.toString();
  }

  static Future<Uint8List> _decodeImage(Map<String, dynamic> response) async {
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
        'The image service returned invalid image content. Check the existing receipt; do not resubmit.',
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
