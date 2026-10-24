import '../background_notifications.dart';

/// Converts the worker's explicit FCM data contract into the existing local
/// notification model. Missing or contradictory metadata is dropped rather
/// than silently turning every event into a generic agent completion.
class PushPayloadMapper {
  const PushPayloadMapper._();

  static OvidNotification? fromData(Map<String, dynamic> data) {
    final rawKind = data['kind'];
    final rawChannel = data['channel'];
    if (rawKind is! String || rawChannel is! String) return null;

    OvidNotificationKind? kind;
    for (final candidate in OvidNotificationKind.values) {
      if (candidate.name == rawKind) {
        kind = candidate;
        break;
      }
    }
    if (kind == null || kind.channel.key != rawChannel) return null;

    final sessionId = _sessionId(data['sessionId']);
    final needsSession =
        kind != OvidNotificationKind.jobDone &&
        kind != OvidNotificationKind.backgroundStatus;
    if (needsSession && sessionId == null) return null;
    if (data['sessionId'] != null && sessionId == null) return null;

    final route = _route(data['route']);
    if (route == null) return null;
    if (needsSession) {
      final expected = switch (kind) {
        OvidNotificationKind.scheduleSucceeded ||
        OvidNotificationKind.scheduleFailed => NotificationRoutes.schedule(
          sessionId!,
        ),
        _ => NotificationRoutes.chat(sessionId!),
      };
      if (route != expected) return null;
    }

    return OvidNotification(
      kind: kind,
      title: _text(data['title']) ?? 'Ovid Si',
      body: _text(data['body']) ?? '',
      route: route,
      sessionId: sessionId,
    );
  }

  static String? _sessionId(Object? value) {
    if (value is! String) return null;
    if (value != value.trim() || value.isEmpty) return null;
    if (value.contains(RegExp(r'[\s/?#]'))) return null;
    return value;
  }

  static String? _route(Object? value) {
    if (value is! String) return null;
    if (value != value.trim() ||
        value.isEmpty ||
        value.length > 200 ||
        !value.startsWith('/') ||
        value.startsWith('//') ||
        value.contains(RegExp(r'\s'))) {
      return null;
    }
    return value;
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }
}
