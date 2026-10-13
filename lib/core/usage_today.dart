import 'image_receipt_store.dart';
import 'ovid_cloud_service.dart';
import 'usage_attempt.dart';

/// Where the "today" counters on the Usage header came from.
enum UsageTodaySource {
  /// The server's `today` object (every device on the account).
  server,

  /// This device's attempt journal + image receipts (older servers, offline).
  device,
}

/// Today's Ovid Cloud activity as shown on the Usage header.
///
/// With [tokensEstimated] set, the token counts include local estimates for
/// requests whose provider sent no usage block.
class UsageToday {
  const UsageToday({
    required this.source,
    required this.requests,
    required this.inputTokens,
    required this.outputTokens,
    required this.images,
    this.autoRequests = 0,
    this.tokensEstimated = false,
  });

  final UsageTodaySource source;
  final int requests;
  final int inputTokens;
  final int outputTokens;
  final int images;

  /// Requests sent in Auto mode (already included in [requests]).
  final int autoRequests;
  final bool tokensEstimated;

  /// Counts this device's Ovid Cloud activity for the local calendar day of
  /// [now]. Auto-mode requests count like any other: they are served by the
  /// same manual models. Only requests that completed successfully count;
  /// pending, failed and cancelled attempts were not served.
  static UsageToday fromDevice({
    required Iterable<UsageAttempt> attempts,
    required Iterable<ImageRequestRecord> receipts,
    required String provider,
    DateTime? now,
  }) {
    final local = (now ?? DateTime.now()).toLocal();
    final today = DateTime(local.year, local.month, local.day);
    bool isToday(DateTime at) {
      final l = at.toLocal();
      return DateTime(l.year, l.month, l.day) == today;
    }

    var requests = 0;
    var autoRequests = 0;
    var input = 0;
    var output = 0;
    var estimated = false;
    for (final a in attempts) {
      if (a.provider != provider ||
          a.outcome != UsageOutcome.succeeded ||
          !isToday(a.startedAt)) {
        continue;
      }
      requests++;
      if (a.requestedModel.trim().toLowerCase() == 'auto') autoRequests++;
      final i = a.inputTokens;
      if (i?.value != null) {
        input += i!.value!;
        if (i.provenance != UsageProvenance.providerReported) estimated = true;
      }
      final o = a.outputTokens;
      if (o?.value != null) {
        output += o!.value!;
        if (o.provenance != UsageProvenance.providerReported) estimated = true;
      }
    }
    var images = 0;
    for (final r in receipts) {
      final at = r.createdAt;
      if (r.state == 'confirmed' && at != null && isToday(at)) images++;
    }
    return UsageToday(
      source: UsageTodaySource.device,
      requests: requests,
      inputTokens: input,
      outputTokens: output,
      images: images,
      autoRequests: autoRequests,
      tokensEstimated: estimated,
    );
  }

  /// Server counters win when the server sends `today`. Older servers only
  /// send `requests_today`, which some deployments never populate (always 0),
  /// so the device journal is used instead — never a misleading zero.
  static UsageToday resolve(OvidUsage? usage, UsageToday device) {
    final t = usage?.today;
    if (t != null) {
      return UsageToday(
        source: UsageTodaySource.server,
        requests: t.requests,
        inputTokens: t.inputTokens,
        outputTokens: t.outputTokens,
        images: t.images,
        autoRequests: device.autoRequests,
      );
    }
    final legacy = usage?.requestsToday ?? 0;
    if (legacy > device.requests) {
      return UsageToday(
        source: UsageTodaySource.server,
        requests: legacy,
        inputTokens: device.inputTokens,
        outputTokens: device.outputTokens,
        images: device.images,
        autoRequests: device.autoRequests,
        tokensEstimated: device.tokensEstimated,
      );
    }
    return device;
  }
}
