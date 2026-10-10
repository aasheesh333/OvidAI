/// Authenticated, bounded transport for the private-sync HTTP API.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'canonical.dart';
import 'dto.dart';
import 'protocol.dart';

const int maxCompressedBytes = 1024 * 1024;
const int maxBatchBytes = 8 * 1024 * 1024;
const int maxRecordBytes = 256 * 1024;
const int maxCursorBytes = 512;

const _safeErrorMessages = <String, String>{
  'invalid_request': 'The request is malformed.',
  'unauthenticated': 'Authentication is required.',
  'device_revoked': 'This device is no longer authorized for private sync.',
  'account_fenced': 'This account is not currently available for sync.',
  'not_found': 'The requested resource was not found.',
  'integrity_conflict':
      'The record conflicts with the stored canonical record.',
  'payload_too_large': 'The request or record exceeds the allowed size.',
  'schema_version_unsupported': 'The schema version is not supported.',
  'invalid_record': 'The record does not match the sync contract.',
  'endpoint_rejected':
      'The provider endpoint is not an allowed endpoint identity.',
  'rate_limited': 'Too many requests. Retry later.',
  'quota_exhausted': 'The sync quota is exhausted.',
  'temporarily_unavailable': 'The sync service is temporarily unavailable.',
  'reset_required': 'The sync state must be reset.',
};

typedef IdTokenProvider = Future<String?> Function(bool forceRefresh);
typedef AppCheckProvider = Future<String?> Function();

/// Safe, fixed-shape failure from the sync transport or protocol.
class SyncClientException implements Exception {
  const SyncClientException(this.code, this.message, {this.retryAfterSeconds});

  final String code;
  final String message;
  final int? retryAfterSeconds;

  @override
  String toString() => 'SyncClientException($code): $message';
}

class PrivateSyncClient {
  PrivateSyncClient({
    required this.baseUri,
    required this.httpClient,
    required this.idToken,
    required this.appCheckToken,
    this.deviceId,
    this.generation,
  });

  final Uri baseUri;
  final http.Client httpClient;
  final IdTokenProvider idToken;
  final AppCheckProvider appCheckToken;
  final String? deviceId;
  final int Function()? generation;

  Future<SyncBatchResult> upload(
    String idempotencyKey,
    List<SyncUploadRecord> records, {
    bool forceRefresh = false,
  }) async {
    _requestId(idempotencyKey);
    if (records.length > 100) {
      throw const SyncClientException(
        'payload_too_large',
        'The request or record exceeds the allowed size.',
      );
    }
    for (final record in records) {
      if (record.canonicalBytes().length > maxRecordBytes) {
        throw const SyncClientException(
          'payload_too_large',
          'The request or record exceeds the allowed size.',
        );
      }
    }
    final body = <String, Object?>{
      'schemaVersion': 1,
      'idempotencyKey': idempotencyKey,
      'records': records.map((record) => record.toWire()).toList(),
    };
    final canonicalBody = canonicalSyncBytes(body);
    if (canonicalBody.length > maxBatchBytes) {
      throw const SyncClientException(
        'payload_too_large',
        'The request or record exceeds the allowed size.',
      );
    }
    final response = await _send(
      'POST',
      '/sync/v1/records',
      forceRefresh: forceRefresh,
      body: gzip.encode(canonicalBody),
      extraHeaders: {'Content-Encoding': 'gzip'},
    );
    return _parseBatch(_json(response));
  }

  Future<SyncChangePage> changes({
    String cursor = '',
    int limit = 100,
    bool forceRefresh = false,
  }) async {
    if (utf8.encode(cursor).length > maxCursorBytes ||
        limit < 1 ||
        limit > 100) {
      throw const SyncClientException(
        'invalid_request',
        'The request is malformed.',
      );
    }
    final response = await _send(
      'GET',
      '/sync/v1/changes',
      forceRefresh: forceRefresh,
      query: {'cursor': cursor, 'limit': '$limit'},
    );
    return _parseChanges(_json(response));
  }

  Future<SyncStatePage> state({String cursor = '', int limit = 100, bool forceRefresh = false}) async {
    if (utf8.encode(cursor).length > maxCursorBytes || limit < 1 || limit > 100) {
      throw const SyncClientException('invalid_request', 'The request is malformed.');
    }
    final response = await _send(
      'GET',
      '/sync/v1/state',
      forceRefresh: forceRefresh,
      query: {'cursor': cursor, 'limit': '$limit'},
    );
    return _parseState(_json(response));
  }

  Future<SyncEnrollment> enroll({
    required String deviceName,
    required String idempotencyKey,
    bool forceRefresh = false,
  }) async {
    _requestId(idempotencyKey);
    if (deviceName.isEmpty || deviceName.runes.length > 128 ||
        deviceName.runes.any((r) => r >= 0xD800 && r <= 0xDFFF)) {
      throw const SyncClientException('invalid_request', 'The request is malformed.');
    }
    final response = await _send(
      'POST',
      '/sync/v1/devices',
      forceRefresh: forceRefresh,
      jsonBody: {
        'consent': true,
        'deviceName': deviceName,
        'idempotencyKey': idempotencyKey,
      },
    );
    return _parseEnrollment(_json(response));
  }

  Future<void> revoke(
    String deviceId, {
    required String idempotencyKey,
    bool forceRefresh = false,
  }) async {
    _requestId(deviceId);
    _requestId(idempotencyKey);
    await _send(
      'DELETE',
      '/sync/v1/devices/${Uri.encodeComponent(deviceId)}',
      forceRefresh: forceRefresh,
      extraHeaders: {'X-Sync-Idempotency-Key': idempotencyKey},
    );
  }

  Future<http.Response> _send(
    String method,
    String path, {
    required bool forceRefresh,
    Map<String, String>? query,
    List<int>? body,
    Map<String, Object?>? jsonBody,
    Map<String, String>? extraHeaders,
  }) async {
    final enrolling = method == 'POST' && path == '/sync/v1/devices';
    if (!enrolling && deviceId == null) {
      throw const SyncClientException('unauthenticated', 'Authentication is required.');
    }
    if (deviceId != null) _requestId(deviceId!);
    final startGeneration = generation?.call();
    final token = await idToken(forceRefresh);
    final appCheck = await appCheckToken();
    if (token == null || token.isEmpty) {
      throw const SyncClientException(
        'unauthenticated',
        'Authentication is required.',
      );
    }
    if (generation?.call() != startGeneration) {
      throw const SyncClientException(
        'stale_generation',
        'The account session changed.',
      );
    }
    final uri = baseUri.resolve(path).replace(queryParameters: query);
    final requestBody =
        body ?? (jsonBody == null ? null : utf8.encode(jsonEncode(jsonBody)));
    if (requestBody != null && requestBody.length > maxCompressedBytes) {
      throw const SyncClientException(
        'payload_too_large',
        'The request or record exceeds the allowed size.',
      );
    }
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
      'Cache-Control': 'no-store',
      'X-Sync-Device-Id': ?deviceId,
      if (jsonBody != null) 'Content-Type': 'application/json',
      if (appCheck != null && appCheck.isNotEmpty)
        'X-Firebase-AppCheck': appCheck,
      ...?extraHeaders,
    };
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (requestBody != null) request.bodyBytes = requestBody;
    final http.Response response;
    try {
      final streamed = await httpClient.send(request);
      final bytes = _BoundedBytes(maxCompressedBytes);
      await for (final chunk in streamed.stream) {
        bytes.add(chunk);
      }
      response = http.Response.bytes(bytes.bytes, streamed.statusCode,
          headers: streamed.headers, request: request);
    } on SyncClientException {
      rethrow;
    } catch (_) {
      throw const SyncClientException('temporarily_unavailable',
          'The sync service is temporarily unavailable.');
    }
    if (response.headers['cache-control']?.toLowerCase() != 'no-store') {
      throw const SyncClientException(
        'invalid_response',
        'The sync response was invalid.',
      );
    }
    if (generation?.call() != startGeneration) {
      throw const SyncClientException(
        'stale_generation',
        'The account session changed.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _parseError(response);
    }
    return response;
  }

  Object _json(http.Response response) {
    final bytes = _decodedBytes(response);
    try {
      final value = decodeStrictJsonUtf8(bytes);
      if (value is! Map<String, dynamic>) throw const FormatException();
      return value;
    } on SyncResetRequired {
      rethrow;
    } catch (_) {
      throw const SyncClientException(
        'invalid_response',
        'The sync response was invalid.',
      );
    }
  }

  List<int> _decodedBytes(http.Response response) {
    if (response.bodyBytes.length > maxCompressedBytes) {
      throw const SyncClientException(
        'payload_too_large',
        'The request or record exceeds the allowed size.',
      );
    }
    try {
      final output = _BoundedBytes(maxBatchBytes);
      if (response.headers['content-encoding']?.toLowerCase() == 'gzip') {
        final decoder = gzip.decoder.startChunkedConversion(output);
        decoder.add(response.bodyBytes);
        decoder.close();
      } else {
        output.add(response.bodyBytes);
      }
      final decoded = output.bytes;
      if (decoded.length > maxBatchBytes) {
        throw const SyncClientException(
          'payload_too_large',
          'The request or record exceeds the allowed size.',
        );
      }
      return decoded;
    } on SyncClientException {
      rethrow;
    } on SyncResetRequired {
      rethrow;
    } catch (_) {
      throw const SyncClientException(
        'invalid_response',
        'The sync response was invalid.',
      );
    }
  }

  SyncClientException _parseError(http.Response response) {
    try {
      final value = decodeStrictJsonUtf8(_decodedBytes(response));
      final code = value is Map<String, dynamic> ? value['code'] : null;
      final message = value is Map<String, dynamic> ? value['message'] : null;
      final retry = value is Map<String, dynamic>
          ? value['retryAfterSeconds']
          : null;
      if (value is Map<String, dynamic> &&
          value.length == 4 && value.containsKey('retryAfterSeconds') &&
          value['schemaVersion'] == 1 &&
          code is String &&
          _safeErrorMessages[code] == message &&
          (retry == null || retry is int && retry >= 0 && retry <= 86400)) {
        if (code == 'reset_required') throw const SyncResetRequired();
        return SyncClientException(
          code,
          _safeErrorMessages[code]!,
          retryAfterSeconds: retry as int?,
        );
      }
    } on SyncResetRequired {
      rethrow;
    } catch (_) {
      // Deliberately map malformed or non-JSON responses to a fixed error.
    }
    return const SyncClientException(
      'invalid_response',
      'The sync response was invalid.',
    );
  }
}

void _requestId(String value) {
  if (value.isEmpty || value.length > 128 ||
      value.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
    throw const SyncClientException('invalid_request', 'The request is malformed.');
  }
}

class _BoundedBytes extends ByteConversionSink {
  _BoundedBytes(this.limit);
  final int limit;
  final List<int> bytes = [];
  @override
  void add(List<int> chunk) {
    if (bytes.length + chunk.length > limit) {
      throw const SyncClientException('payload_too_large',
          'The request or record exceeds the allowed size.');
    }
    bytes.addAll(chunk);
  }
  @override
  void close() {}
}

SyncBatchResult _parseBatch(Object value) {
  try {
    return SyncBatchResult.fromWire(value);
  } on SyncDtoException {
    throw const SyncClientException(
      'invalid_response',
      'The sync response was invalid.',
    );
  }
}

SyncChangePage _parseChanges(Object value) {
  try {
    return SyncChangePage.fromWire(value);
  } on SyncDtoException {
    throw const SyncClientException(
      'invalid_response',
      'The sync response was invalid.',
    );
  }
}

SyncStatePage _parseState(Object value) {
  try {
    return SyncStatePage.fromWire(value);
  } on SyncDtoException {
    throw const SyncClientException(
      'invalid_response',
      'The sync response was invalid.',
    );
  }
}

SyncEnrollment _parseEnrollment(Object value) {
  try {
    return SyncEnrollment.fromWire(value);
  } on SyncDtoException {
    throw const SyncClientException(
      'invalid_response',
      'The sync response was invalid.',
    );
  }
}
