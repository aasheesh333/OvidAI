import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'diag.dart';
import 'image_capabilities.dart';
import 'image_receipt_store.dart';
import 'image_task.dart';

export 'image_capabilities.dart'
    show ImageCapabilities, ImageModelCard, localOpsGuidance, maxBatchImages;
export 'image_receipt_store.dart'
    show ImageReceipt, ImageRequestRecord, imageChargeSummary;

class ImageStudioError implements Exception {
  const ImageStudioError(
    this.message, {
    this.statusCode,
    this.code,
    this.retryAfter,
  });
  final String message;
  final int? statusCode;
  final String? code;
  final Duration? retryAfter;
  bool get isCapacity => code == 'image_capacity_unavailable';

  // These exact public pairs are emitted before provider dispatch by the
  // images API. Never infer nonacceptance from status alone, a GET, an unknown
  // code, or an ambiguous image_unavailable response.
  bool get _preDispatchRejection => switch ((statusCode, code)) {
    (401, 'sign_in_required') ||
    (403, 'image_access_denied') ||
    (402, 'image_limit_reached') ||
    (400, 'invalid_request_id' || 'invalid_image_request' || 'invalid_image') ||
    (413, 'image_too_large') ||
    (415, 'invalid_image_request') ||
    (422, 'unsupported_image_operation') => true,
    _ => false,
  };
  @override
  String toString() => message;

  static const _codes = {
    'image_capacity_unavailable',
    'image_unavailable',
    'sign_in_required',
    'image_access_denied',
    'image_limit_reached',
    'invalid_request_id',
    'invalid_image_request',
    'invalid_image',
    'image_too_large',
    'unsupported_image_operation',
    'idempotency_conflict',
    'image_request_pending',
    'image_request_failed',
    'image_request_not_found',
    'image_receipt_expired',
    'image_replay_expired',
    'image_account_deleted',
    'invalid_image_response',
  };

  static ImageStudioError? _fromResponse(_ImageHttpResponse? response) {
    if (response == null || response.status == 200) return null;
    final value = response.body['error'];
    // Public alternatives on a 422 (slugs only), so the agent can retry.
    final rawAlt = value is Map ? value['alternatives'] : null;
    final alternatives = rawAlt is List
        ? rawAlt
              .whereType<String>()
              .where(RegExp(r'^ovid-image:[A-Za-z0-9_-]{3,40}$').hasMatch)
              .take(8)
              .toList()
        : <String>[];
    final rawCode = value is Map ? value['code'] : null;
    final code = rawCode is String && _codes.contains(rawCode) ? rawCode : null;
    final rawRetry = value is Map ? value['retryAfterSeconds'] : null;
    final seconds =
        (rawRetry is int ? rawRetry : int.tryParse('$rawRetry')) ??
        int.tryParse(response.retryAfter ?? '');
    final retry = code == 'image_capacity_unavailable'
        ? Duration(
            seconds: (seconds == null || seconds < 0 ? 30 : seconds).clamp(1, 120),
          )
        : null;
    final message = switch (code) {
      'image_capacity_unavailable' =>
        'Image service capacity is temporarily unavailable. Stop image attempts in this run. '
        'You may manually try later after ${retry!.inSeconds} seconds. '
        'Report this capacity error; do not infer an allowance problem.',
      'image_limit_reached' =>
        'The server reports the image allowance limit was reached.',
      'sign_in_required' => 'Sign in to Ovid Cloud again to access images.',
      'image_access_denied' => 'The server denied image access for this account.',
      'unsupported_image_operation' =>
        'The server rejected the image arguments or requested operation: the chosen model '
            'cannot do it.${alternatives.isEmpty ? ' No available model can; use a local tool or tell the user.' : ' Retry with model set to one of: ${alternatives.join(", ")} (or omit model).'}',
      'invalid_request_id' ||
      'invalid_image_request' ||
      'invalid_image' ||
      'image_too_large' =>
        'The server rejected the image arguments or requested operation.',
      _ => 'The image service could not complete this request.',
    };
    return ImageStudioError(
      message,
      statusCode: response.status,
      code: code,
      retryAfter: retry,
    );
  }
}

/// Exact accounting and actual output are independent. Result recovery only
/// exposes bytes accompanied by matching authenticated terminal accounting.
class ImageStudioResult {
  const ImageStudioResult({
    required this.record,
    required this.receiptPersisted,
    this.bytes,
    this.notice,
    this.error,
  });
  final ImageRequestRecord record;
  final bool receiptPersisted;
  final Uint8List? bytes;
  final String? notice;
  final ImageStudioError? error;
  ImageReceipt? get receipt => record.receipt;

  /// Public slug of the model that served this request, when reported.
  String? get servedModel => record.receipt?.modelSlug;
  bool get imageAvailable => bytes != null;
}

class _ImageHttpResponse {
  const _ImageHttpResponse(
    this.status,
    this.body, {
    this.retryAfter,
    this.etag,
  });
  final int status;
  final Map<String, dynamic> body;
  final String? retryAfter;
  final String? etag;
}

/// The only image inference contract exposed to the app is Ovid's public alias.
/// Local operations use Flutter's image codec/canvas and require no cloud key.
class ImageStudio extends ChangeNotifier {
  ImageStudio({
    http.Client? client,
    ImageReceiptStore? receiptStore,
    DateTime Function()? clock,
  }) : _client = client, // ignore: prefer_initializing_formals
      _clock = clock ?? DateTime.now,
      _store = receiptStore ?? ImageReceiptStore();
  static final I = ImageStudio();
  final http.Client? _client;
  final ImageReceiptStore _store;
  final DateTime Function() _clock;
  final Map<String, ({DateTime until, ImageStudioError error})> _capacity = {};
  ImageStudioError? _capabilityError;

  ImageStudioError? get capacityError {
    final entry = _capacity[_accountId];
    return entry != null && _clock().isBefore(entry.until) ? entry.error : null;
  }

  void _rememberCapacity(ImageStudioError? error) {
    if (error?.isCapacity == true && _accountId != null) {
      _capacity.removeWhere((_, entry) => !_clock().isBefore(entry.until));
      _capacity[_accountId!] = (
        until: _clock().add(error!.retryAfter!),
        error: error,
      );
    }
  }

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
    _cached = null;
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
  static const _capabilityTtl = Duration(minutes: 5);
  ImageCapabilities _caps = ImageCapabilities.empty;
  DateTime? _refreshed;

  // Last good payload per account, kept across clearCapabilities() so the next
  // refresh can be a cheap conditional GET (If-None-Match -> 304).
  ({String account, ImageCapabilities caps})? _cached;

  /// Current public model cards (empty when stale or unavailable).
  ImageCapabilities get capabilities => _fresh ? _caps : ImageCapabilities.empty;

  bool get _fresh =>
      _refreshed != null &&
      DateTime.now().difference(_refreshed!) < _capabilityTtl;

  List<String> supportedSizes(String operation) =>
      _fresh ? _caps.sizesFor(operation) : const [];

  void clearCapabilities() {
    _capabilityGeneration++;
    _caps = ImageCapabilities.empty;
    _refreshed = null;
    _capabilityError = null;
  }

  /// Use the cached cards while fresh; hit the network only when stale. This is
  /// what keeps model selection off the per-request path.
  Future<void> ensureFresh(Map<String, String> headers) async {
    if (_fresh && !_caps.isEmpty) return;
    await refresh(headers);
  }

  Future<void> refresh(Map<String, String> headers) async {
    final account = _accountId;
    final cached = _cached != null && _cached!.account == account
        ? _cached!.caps
        : null;
    clearCapabilities();
    final generation = _generation;
    final capabilityGeneration = _capabilityGeneration;
    if (headers.isEmpty || account == null) return;
    try {
      final response = await _request(
        'GET',
        'capabilities',
        {
          ...headers,
          if (cached?.etag != null) 'If-None-Match': cached!.etag!,
        },
        null,
        maxResponse: 65536,
      );
      if (!_current(account, generation) ||
          capabilityGeneration != _capabilityGeneration) {
        return;
      }
      final body = response.body;
      if (response.status == 304 && cached != null) {
        _caps = cached;
        _refreshed = DateTime.now();
        return;
      }
      if (response.status == 401 || response.status == 403) _cached = null;
      if (response.status != 200) {
        _capabilityError = ImageStudioError._fromResponse(response);
        _rememberCapacity(_capabilityError);
        return;
      }
      if (body['model'] != alias) return;
      final parsed = ImageCapabilities.parse(body, legacySizes: sizes);
      if (parsed.isEmpty) return;
      _caps = parsed;
      _cached = (account: account, caps: parsed);
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
        Map<String, dynamic> responseBody = const {};
        try {
          final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
          if (decoded is Map<String, dynamic>) responseBody = decoded;
        } catch (_) {
          // Keep the HTTP status, never expose proxy HTML or provider text.
        }
        return _ImageHttpResponse(
          response.statusCode,
          responseBody,
          retryAfter: response.headers.entries
              .where((entry) => entry.key.toLowerCase() == 'retry-after')
              .firstOrNull?.value,
          etag: response.headers.entries
              .where((entry) => entry.key.toLowerCase() == 'etag')
              .firstOrNull?.value,
        );
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
      statusCode: result.error?.statusCode,
      code: result.error?.code,
      retryAfter: result.error?.retryAfter,
    );
  }

  /// Compatibility [infer] delegates here; callers needing accounting must use
  /// this result. Reusing an admitted ID is ALWAYS a read-only GET, never POST.
  ///
  /// [model] is an optional public slug from [capabilities] (null/omitted =
  /// server picks). [preference], [requirements], [mask] and [references]
  /// are routing hints the server hard-filters on.
  Future<ImageStudioResult> inferResult({
    required String prompt,
    required String size,
    Uint8List? input,
    required Map<String, String> headers,
    String? requestId,
    String? sessionId,
    String? model,
    String? preference,
    Map<String, dynamic>? requirements,
    Uint8List? mask,
    List<Uint8List> references = const [],
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
    final cleanRequirements = _requirements(requirements);
    if (prompt.trim().isEmpty ||
        prompt.runes.length > 8000 ||
        !(sizes.contains(size) || _sizeRe.hasMatch(size)) ||
        !validImageRequestId(requestId) ||
        (model != null && !_slugRe.hasMatch(model)) ||
        (preference != null && !preferences.contains(preference)) ||
        cleanRequirements == null ||
        (input == null && (mask != null || references.isNotEmpty)) ||
        references.length > 7) {
      throw const ImageStudioError(
        'Supply a prompt (1–8000 characters) and request_id (8–128 letters, digits, dots, colons, underscores or hyphens).',
      );
    }
    final inputInfo = input == null ? null : await inspect(input);
    final maskInfo = mask == null ? null : await inspect(mask);
    final referenceInfo = [for (final r in references) await inspect(r)];
    _checkCurrent(account, generation);
    String dataUrl(String mime, Uint8List bytes) =>
        'data:$mime;base64,${base64Encode(bytes)}';
    // Sorted keys (nested too) + Python ensure_ascii=True semantics: the
    // server fingerprints this exact body, so key order is part of the contract.
    final body = <String, dynamic>{
      if (input != null) 'image': dataUrl(inputInfo!.mime, input),
      if (references.isNotEmpty)
        'images': [
          for (var i = 0; i < references.length; i++)
            dataUrl(referenceInfo[i].mime, references[i]),
        ],
      if (mask != null) 'mask': dataUrl(maskInfo!.mime, mask),
      'model': model ?? alias,
      'preference': ?preference,
      'prompt': prompt,
      if (cleanRequirements.isNotEmpty) 'requirements': cleanRequirements,
      'size': size,
    };
    final fingerprint = sha256
        .convert(utf8.encode(_serverJson([operation, body])))
        .toString();
    final candidate = ImageRequestRecord(
      accountId: account,
      requestId: requestId,
      fingerprint: fingerprint,
      createdAt: DateTime.now().toUtc(),
      sessionId: sessionId,
    );
    late ({ImageRequestRecord record, bool created}) admission;
    try {
      admission = await _store.reserve(
        candidate,
        isCurrent: () => _current(account, generation),
        canSubmit: () =>
            capacityError == null &&
            _fresh &&
            _caps.canServe(operation, size, model: _legacyModel(model)),
      );
    } on ImageAdmissionError catch (error) {
      _checkCurrent(account, generation);
      if (error.reason == ImageAdmissionReason.capabilityUnavailable) {
        final failure = capacityError ?? _capabilityError;
        if (failure != null) throw failure;
      }
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
    return _finish(
      admission.record,
      response,
      generation,
      allowImage: true,
      initialSubmission: true,
    );
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
      error: ImageStudioError._fromResponse(replay),
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
    bool initialSubmission = false,
  }) async {
    var record = original.unknown;
    final error = ImageStudioError._fromResponse(response);
    _rememberCapacity(error);
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
    if (initialSubmission &&
        response?.body['receipt'] == null &&
        error?._preDispatchRejection == true) {
      // Resolve the local admission fence, but do not invent a server receipt
      // or a zero charge. Reusing this identity remains GET-only forever.
      record = original.rejectedBeforeDispatch;
      notice =
          'The server rejected this submission before image execution. '
          'No charge receipt was returned. A later manual request may use a new ID.';
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
      404 when record.unresolved =>
        'The server did not find this request. Its outcome remains uncertain; no new paid submission is allowed.',
      404 =>
        'The server did not find this request. Saved terminal status is retained.',
      401 || 403 =>
        'Sign in to the original account with current image permission to check this receipt.',
      _ when record.state == 'failed' =>
        'Image request failed (${imageChargeSummary(record.state, record.receipt?.charged).toLowerCase()}). '
            'This receipt is resolved. ${error?.isCapacity == true ? 'No automatic retry will be submitted.' : 'You may start a new image request when image service is available.'}',
      _ =>
        bytes != null
            ? null
            : record.state == 'confirmed'
            ? 'Charge confirmed. Image bytes are unavailable from receipt recovery.'
            : 'Image outcome ${record.state}. Check this receipt; do not submit a replacement paid job.',
    };
    if (error != null) notice = '${error.message} ${notice ?? ''}'.trim();
    return ImageStudioResult(
      record: record,
      receiptPersisted: persisted,
      bytes: bytes,
      notice: notice,
      error: error,
    );
  }

  void _publish(ImageRequestRecord record) {
    _receipts = List.unmodifiable([
      ..._receipts.where((r) => r.requestId != record.requestId),
      record,
    ]);
    notifyListeners();
  }

  static final _sizeRe = RegExp(r'^[1-9][0-9]{2,3}x[1-9][0-9]{2,3}$');
  static final _slugRe = RegExp(r'^ovid-image:[A-Za-z0-9_-]{3,40}$');

  // Legacy gateways expose one synthetic card slugged "ovid-image"; an explicit
  // slug can never match it, so only pass the model through when it exists.
  String? _legacyModel(String? model) =>
      model != null && _caps.models.any((m) => m.slug == model) ? model : null;

  /// Whitelisted, key-sorted routing requirements; null = invalid.
  static Map<String, dynamic>? _requirements(Map<String, dynamic>? raw) {
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    const allowed = {
      'aspect_ratio',
      'operation',
      'text_rendering',
      'transparent_background',
    };
    if (raw.keys.any((k) => !allowed.contains(k))) return null;
    final out = <String, dynamic>{};
    for (final key in raw.keys.toList()..sort()) {
      final v = raw[key];
      switch (key) {
        case 'aspect_ratio':
          if (v is! String || !RegExp(r'^[1-9][0-9]?:[1-9][0-9]?$').hasMatch(v)) {
            return null;
          }
        case 'operation':
          if (v is! String ||
              !['edit', ...advancedEditOperations, 'variations'].contains(v)) {
            return null;
          }
        default:
          if (v is! bool) return null;
      }
      out[key] = v;
    }
    return out;
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

  /// Restores [bytes] to exactly [width]×[height] without distortion: a
  /// plain resize when the aspect ratios already match (within 1%), else a
  /// uniform scale-to-cover plus centre crop ([restorePlan]). Returns the
  /// input untouched when it already has those dimensions (format kept);
  /// otherwise a PNG, since Flutter's codec only encodes PNG losslessly.
  static Future<Uint8List> fitTo(
    Uint8List bytes, {
    required int width,
    required int height,
  }) async {
    final info = await inspect(bytes);
    if (info.width == width && info.height == height) return bytes;
    if (width < 1 || height < 1 || width > 4096 || height > 4096) {
      throw const ImageStudioError('Invalid target size.');
    }
    final plan = restorePlan(
      PixelSize(info.width, info.height),
      PixelSize(width, height),
    );
    final codec = await ui.instantiateImageCodec(bytes);
    final source = (await codec.getNextFrame()).image;
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      source,
      ui.Rect.fromLTWH(plan.srcX, plan.srcY, plan.srcWidth, plan.srcHeight),
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
    ...capabilities.cloudTools(schema: _schema, pathProperty: _path),
    for (final op in ['resize', 'crop'])
      _schema(
        '${op}_image',
        op == 'resize'
            ? 'Resize locally to exact dimensions (no image model, free, instant); may change aspect ratio. '
                  'Use this - never a cloud model - to scale an image to a target size. Returns a new PNG path.'
            : 'Crop locally using a top-left pixel rectangle inside the source (no image model, free, instant). '
                  'Use this to trim a generated image to the wanted aspect ratio. Returns a new PNG path.',
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
