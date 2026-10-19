import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'cloud_app_check.dart';
import 'firebase_service.dart';

/// What is being reported. The server keeps the same closed set.
enum ContentReportKind {
  /// An AI-generated reply (text or image) in the user's own chat.
  aiOutput('ai_output'),

  /// A read-only shared conversation opened from a link.
  sharedConversation('shared_conversation'),

  /// A message posted in a live Collab session by another participant.
  collabMessage('collab_message'),

  /// A Collab participant (name/behaviour).
  collabParticipant('collab_participant');

  const ContentReportKind(this.wire);
  final String wire;
}

/// Report reasons, aligned with Play's Generative AI / UGC restricted content.
enum ContentReportReason {
  sexual('sexual', 'Sexual content'),
  childSafety('child_safety', 'Child safety concern'),
  hate('hate', 'Hateful or harassing'),
  violence('violence', 'Violent or dangerous'),
  selfHarm('self_harm', 'Self-harm or suicide'),
  illegal('illegal', 'Illegal activity'),
  misleading('misleading', 'False or misleading'),
  privacy('privacy', 'Personal information'),
  spam('spam', 'Spam or scam'),
  other('other', 'Something else');

  const ContentReportReason(this.wire, this.label);
  final String wire;
  final String label;
}

class ContentReport {
  ContentReport({
    required this.kind,
    required this.reason,
    this.details = '',
    this.excerpt = '',
    this.targetId,
    this.model,
    String? requestId,
  }) : requestId = requestId ?? newRequestId();

  final ContentReportKind kind;
  final ContentReportReason reason;
  final String details;
  final String excerpt;
  final String? targetId;
  final String? model;
  final String requestId;

  static const maxDetails = 1000;
  static const maxExcerpt = 4000;

  static String newRequestId() {
    final random = Random.secure();
    return base64UrlEncode(
      List.generate(24, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }

  static String _clip(String value, int max) {
    final trimmed = value.trim();
    return trimmed.length <= max ? trimmed : trimmed.substring(0, max);
  }

  Map<String, dynamic> toJson() => {
    'request_id': requestId,
    'kind': kind.wire,
    'reason': reason.wire,
    'details': _clip(details, maxDetails),
    'excerpt': _clip(excerpt, maxExcerpt),
    if (targetId != null && targetId!.isNotEmpty)
      'target_id': _clip(targetId!, 128),
    if (model != null && model!.isNotEmpty) 'model': _clip(model!, 128),
  };
}

class ContentReportException implements Exception {
  const ContentReportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Sends in-app reports of offensive AI output and user-generated content to
/// the Ovid safety queue (`POST {base}/v1/reports`, server/reports).
///
/// Required by Play's AI-Generated Content policy (in-app reporting without
/// leaving the app) and User Generated Content policy (in-app reporting).
class ContentReportService {
  ContentReportService({
    this.baseUrl = const String.fromEnvironment(
      'OVID_REPORT_BASE_URL',
      defaultValue: String.fromEnvironment('OVID_SHARE_BASE_URL'),
    ),
    required this.idToken,
    this.appCheck,
    this.client,
  });

  factory ContentReportService.production() => ContentReportService(
    idToken: () => FirebaseService.I.getIdToken(),
    // Null unless OVID_APPCHECK=true: no header and no requirement.
    appCheck: CloudAppCheck.shared.provider,
  );

  final String baseUrl;
  final Future<String?> Function() idToken;
  final Future<String?> Function()? appCheck;
  final http.Client? client;

  Uri? get _endpoint {
    final uri = Uri.tryParse(baseUrl.replaceFirst(RegExp(r'/+$'), ''));
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return uri.replace(path: '${uri.path}/v1/reports');
  }

  bool get available => _endpoint != null;

  Future<void> submit(ContentReport report) async {
    final endpoint = _endpoint;
    if (endpoint == null) {
      throw const ContentReportException(
        'Reporting is not configured in this build.',
      );
    }
    final transport = client ?? http.Client();
    try {
      final token = await idToken().timeout(const Duration(seconds: 20));
      if (token == null || token.trim().isEmpty) {
        throw const ContentReportException('Sign in to send a report.');
      }
      String? attestation;
      if (appCheck != null) {
        attestation = await appCheck!().timeout(const Duration(seconds: 20));
        if (attestation == null || attestation.trim().isEmpty) {
          throw const ContentReportException(
            'App verification is unavailable. Please retry.',
          );
        }
      }
      final request = http.Request('POST', endpoint)..followRedirects = false;
      request.headers.addAll({
        'Authorization': 'Bearer $token',
        'X-Firebase-AppCheck': ?attestation,
        'Content-Type': 'application/json',
      });
      request.body = jsonEncode(report.toJson());
      final response = await transport
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20));
      // 201 created, 200 idempotent replay of the same request id.
      if (response.statusCode == 201 || response.statusCode == 200) return;
      throw ContentReportException(switch (response.statusCode) {
        401 => 'Sign in again to send a report.',
        429 => 'Too many reports today. Try again tomorrow.',
        _ => 'Could not send the report. Please retry.',
      });
    } on ContentReportException {
      rethrow;
    } catch (_) {
      throw const ContentReportException(
        'Could not send the report. Check your connection and retry.',
      );
    } finally {
      if (client == null) transport.close();
    }
  }
}
