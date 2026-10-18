/// BYOK escrow client (P8 Task 18).
///
/// The contract is the BUILT P9 gateway, not the plan sketch:
///   cloud/apps/gateway/src/routes/byok.ts
///   cloud/packages/db/src/schema.ts (byok_keys)
///
/// There is NO `fingerprint` field. The server projects only
/// `{id, providerId, endpoint, label, status, lastTestAt, lastTestOk,
/// createdAt}`; the ciphertext columns never leave the DB. This client has no
/// key field on its DTO and never logs, caches or persists the raw key.
library;

import 'package:flutter/foundation.dart';

import 'cloud_rest.dart';

/// One escrowed key as the server projects it. Never contains key material.
@immutable
class ByokKeyDto {
  const ByokKeyDto({
    required this.id,
    required this.providerId,
    required this.endpoint,
    required this.status,
    required this.createdAt,
    this.label,
    this.lastTestAt,
    this.lastTestOk,
  });

  factory ByokKeyDto.fromJson(Map<String, dynamic> j) => ByokKeyDto(
        id: j['id'] as String,
        providerId: j['providerId'] as String,
        endpoint: j['endpoint'] as String,
        label: j['label'] as String?,
        status: j['status'] as String? ?? 'untested',
        lastTestAt: j['lastTestAt'] is String
            ? DateTime.tryParse(j['lastTestAt'] as String)
            : null,
        lastTestOk: j['lastTestOk'] as bool?,
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  final String id;
  final String providerId;

  /// Canonical provider endpoint validated by `validateEndpoint`.
  final String endpoint;
  final String? label;

  /// Server status (`untested` on create; the test route updates it).
  final String status;
  final DateTime? lastTestAt;
  final bool? lastTestOk;
  final DateTime createdAt;
}

/// The answer of `POST /byok/:id/test`.
@immutable
class ByokTestResult {
  const ByokTestResult({required this.ok, this.error});

  factory ByokTestResult.fromJson(Map<String, dynamic> j) => ByokTestResult(
        ok: j['ok'] == true,
        error: j['error'] as String?,
      );

  final bool ok;
  final String? error;
}

/// Thin client over the escrow routes. A 401 self-heals through
/// [CloudRestClient]'s one-shot refresh; everything else surfaces as
/// [CloudApiException].
class ByokClient {
  ByokClient({CloudRestClient? rest}) : _rest = rest ?? CloudRestClient.I;

  final CloudRestClient _rest;

  static ByokClient? _instance;

  /// Process-wide default.
  static ByokClient get I => _instance ??= ByokClient();

  /// Test wiring only.
  @visibleForTesting
  static void installForTest(ByokClient client) => _instance = client;

  @visibleForTesting
  static void resetForTest() => _instance = null;

  /// GET /byok → metadata only.
  Future<List<ByokKeyDto>> list() async {
    final json = await _rest.getJson('/byok');
    return [
      for (final item in (json['items'] as List? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>())
        ByokKeyDto.fromJson(item),
    ];
  }

  /// POST /byok — the route's `.strict()` body. `endpoint` is REQUIRED and is
  /// validated server-side. The raw [apiKey] is sent once and is never kept
  /// by this client.
  Future<ByokKeyDto> upload({
    required String providerId,
    required String endpoint,
    required String apiKey,
    String? label,
  }) async {
    final trimmedLabel = label?.trim();
    final json = await _rest.postJson(
      '/byok',
      body: <String, Object?>{
        'providerId': providerId,
        'endpoint': endpoint,
        'apiKey': apiKey,
        if (trimmedLabel != null && trimmedLabel.isNotEmpty)
          'label': trimmedLabel,
      },
    );
    return ByokKeyDto.fromJson(json);
  }

  /// DELETE /byok/:id → 204. Unknown id and wrong owner are the same 404.
  Future<void> revoke(String id) => _rest.delete('/byok/$id');

  /// POST /byok/:id/test — validates the target and probes `<endpoint>/models`
  /// (10 s server-side). Cheap enough to expose as a row action.
  Future<ByokTestResult> test(String id) async =>
      ByokTestResult.fromJson(await _rest.postJson('/byok/$id/test'));
}
