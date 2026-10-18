import 'ovid_cloud_service.dart';

/// Where the "today" counters on the Usage header came from.
enum UsageTodaySource {
  /// The server's `today` object (every device on the account).
  server,

  /// A local fallback. Device-local accounting died with the agent-core
  /// satellite strip (P8 Task 18), so this only ever carries zeroes now.
  device,
}

/// Today's Ovid Cloud activity as shown on the Usage header.
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

  /// The empty device baseline. Local attempt journals were removed, so the
  /// header must never imply local knowledge it no longer has.
  static const empty = UsageToday(
    source: UsageTodaySource.device,
    requests: 0,
    inputTokens: 0,
    outputTokens: 0,
    images: 0,
  );

  /// Server counters win when the server sends `today`. Older servers only
  /// send `requests_today`, which some deployments never populate (always 0),
  /// so the empty baseline is used instead — never a misleading zero.
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
