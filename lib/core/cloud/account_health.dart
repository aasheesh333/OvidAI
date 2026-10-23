import 'package:flutter/foundation.dart';

import 'cloud_rest.dart';

/// `GET /cloud/v1/account/health` — one honest aggregate for the Account
/// Health screen.
///
/// The route answers only from state the server owns: the artifact vault
/// ledger, the `run_usage` token ledger, the stored plan and the ban/deletion
/// rows. It does **not** know the mint's USD window, so `remainingUsd` is
/// always null there. This client keeps that distinction: a field the server
/// did not send (or sent as null) parses to `null` — "unknown" — and is never
/// coerced to `0`, which would read as a real measurement.
///
/// Every parser accepts `Object?` and degrades to `null` on a missing,
/// wrongly-typed or unrepresentable value. The only throw in this file is the
/// shared [CloudRestClient] error path.

int? _int(Object? raw) {
  final value = _number(raw);
  if (value == null) return null;
  final whole = value.toInt();
  return whole < 0 ? null : whole;
}

num? _number(Object? raw) {
  if (raw is! num || !raw.isFinite) return null;
  return raw;
}

double? _usd(Object? raw) {
  final value = _number(raw);
  if (value == null) return null;
  final amount = value.toDouble();
  return amount < 0 ? null : amount;
}

bool? _bool(Object? raw) => raw is bool ? raw : null;

String? _text(Object? raw) {
  if (raw is! String) return null;
  final text = raw.trim();
  return text.isEmpty ? null : text;
}

DateTime? _date(Object? raw) {
  if (raw is! String) return null;
  return DateTime.tryParse(raw.trim());
}

Map<String, dynamic>? _map(Object? raw) {
  if (raw is! Map) return null;
  return <String, dynamic>{
    for (final entry in raw.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

/// The plan's enforced limits, as the server resolves them for the stored
/// tier. A missing limit is unknown, not zero.
@immutable
class AccountHealthPlanLimits {
  const AccountHealthPlanLimits({
    this.storageBytes,
    this.customConnectors,
    this.projectFiles,
    this.manualModels,
    this.autoMultiplier,
    this.uploads,
  });

  final int? storageBytes;
  final int? customConnectors;
  final int? projectFiles;
  final bool? manualModels;
  final num? autoMultiplier;
  final AccountHealthUploads? uploads;

  bool get isEmpty =>
      storageBytes == null &&
      customConnectors == null &&
      projectFiles == null &&
      manualModels == null &&
      autoMultiplier == null &&
      uploads == null;

  static AccountHealthPlanLimits? tryParse(Object? raw) {
    final json = _map(raw);
    if (json == null) return null;
    final limits = AccountHealthPlanLimits(
      storageBytes: _int(json['storageBytes']),
      customConnectors: _int(json['customConnectors']),
      projectFiles: _int(json['projectFiles']),
      manualModels: _bool(json['manualModels']),
      autoMultiplier: _number(json['autoMultiplier']),
      uploads: AccountHealthUploads.tryParse(json['uploads']),
    );
    return limits.isEmpty ? null : limits;
  }
}

/// The upload window the plan enforces (`80 files / 3 h`).
@immutable
class AccountHealthUploads {
  const AccountHealthUploads({this.count, this.windowHours});

  final int? count;
  final int? windowHours;

  bool get isEmpty => count == null && windowHours == null;

  static AccountHealthUploads? tryParse(Object? raw) {
    final json = _map(raw);
    if (json == null) return null;
    final uploads = AccountHealthUploads(
      count: _int(json['count']),
      windowHours: _int(json['windowHours']),
    );
    return uploads.isEmpty ? null : uploads;
  }
}

/// The stored tier (verbatim, so a legacy `7x` stays `7x`), the plan it
/// resolves to and the limits that plan actually enforces.
@immutable
class AccountHealthPlan {
  const AccountHealthPlan({
    this.tier,
    this.id,
    this.name,
    this.expiresAt,
    this.limits,
  });

  final String? tier;
  final String? id;
  final String? name;

  /// Paid-tier expiry; null when the plan does not expire or the server did
  /// not report it.
  final DateTime? expiresAt;
  final AccountHealthPlanLimits? limits;

  bool get isEmpty =>
      tier == null &&
      id == null &&
      name == null &&
      expiresAt == null &&
      limits == null;

  static AccountHealthPlan? tryParse(Object? raw) {
    final json = _map(raw);
    if (json == null) return null;
    final plan = AccountHealthPlan(
      tier: _text(json['tier']),
      id: _text(json['id']),
      name: _text(json['name']),
      expiresAt: _date(json['expiresAt']),
      limits: AccountHealthPlanLimits.tryParse(json['limits']),
    );
    return plan.isEmpty ? null : plan;
  }
}

/// The vault ledger against the plan quota. `remainingBytes` is the server's
/// clamped value; a local fraction is only derived when both sides are known
/// and the quota is positive.
@immutable
class AccountHealthStorage {
  const AccountHealthStorage({
    this.usedBytes,
    this.quotaBytes,
    this.remainingBytes,
  });

  final int? usedBytes;
  final int? quotaBytes;
  final int? remainingBytes;

  bool get isEmpty =>
      usedBytes == null && quotaBytes == null && remainingBytes == null;

  /// 0..1, or null when either side is unknown (including a zero quota, where
  /// the ratio would be meaningless).
  double? get usedFraction {
    final used = usedBytes;
    final quota = quotaBytes;
    if (used == null || quota == null || quota <= 0) return null;
    return (used / quota).clamp(0.0, 1.0).toDouble();
  }

  static AccountHealthStorage? tryParse(Object? raw) {
    final json = _map(raw);
    if (json == null) return null;
    final storage = AccountHealthStorage(
      usedBytes: _int(json['usedBytes']),
      quotaBytes: _int(json['quotaBytes']),
      remainingBytes: _int(json['remainingBytes']),
    );
    return storage.isEmpty ? null : storage;
  }
}

/// One `used` object from the run ledger. Tokens are `input + output`; a bare
/// number is accepted too, because the screen only needs the total.
@immutable
class AccountHealthUsage {
  const AccountHealthUsage({
    this.runs,
    this.modelCalls,
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.total,
  });

  final int? runs;
  final int? modelCalls;
  final int? inputTokens;
  final int? outputTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;

  /// Set only when the server answered a bare token count.
  final int? total;

  bool get isEmpty =>
      runs == null &&
      modelCalls == null &&
      inputTokens == null &&
      outputTokens == null &&
      cacheReadTokens == null &&
      cacheWriteTokens == null &&
      total == null;

  /// Tokens actually recorded. Null when either half of the split is unknown:
  /// a half-known total would be a guess, not a measurement.
  int? get totalTokens {
    final reported = total;
    if (reported != null) return reported;
    final input = inputTokens;
    final output = outputTokens;
    if (input == null || output == null) return null;
    return input + output;
  }

  static AccountHealthUsage? tryParse(Object? raw) {
    if (raw is num) {
      final total = _int(raw);
      return total == null ? null : AccountHealthUsage(total: total);
    }
    final json = _map(raw);
    if (json == null) return null;
    final used = AccountHealthUsage(
      runs: _int(json['runs']),
      modelCalls: _int(json['modelCalls']),
      inputTokens: _int(json['inputTokens']),
      outputTokens: _int(json['outputTokens']),
      cacheReadTokens: _int(json['cacheReadTokens']),
      cacheWriteTokens: _int(json['cacheWriteTokens']),
    );
    return used.isEmpty ? null : used;
  }
}

/// Today's or this month's window.
@immutable
class AccountHealthUsageWindow {
  const AccountHealthUsageWindow({
    this.since,
    this.until,
    this.used,
    this.remainingUsd,
  });

  final DateTime? since;
  final DateTime? until;
  final AccountHealthUsage? used;

  /// Mint/LiteLLM state. The gateway cannot read it, so it answers null —
  /// never `0`, which would claim the allowance is exhausted.
  final double? remainingUsd;

  int? get usedTokens => used?.totalTokens;

  bool get isEmpty =>
      since == null && until == null && used == null && remainingUsd == null;

  static AccountHealthUsageWindow? tryParse(Object? raw) {
    final json = _map(raw);
    if (json == null) return null;
    final window = AccountHealthUsageWindow(
      since: _date(json['since']),
      until: _date(json['until']),
      used: AccountHealthUsage.tryParse(json['used']),
      remainingUsd: _usd(json['remainingUsd']),
    );
    return window.isEmpty ? null : window;
  }
}

/// The two token windows the gateway reports.
@immutable
class AccountHealthUsageSummary {
  const AccountHealthUsageSummary({this.today, this.month});

  final AccountHealthUsageWindow? today;
  final AccountHealthUsageWindow? month;

  bool get isEmpty => today == null && month == null;

  static AccountHealthUsageSummary? tryParse(Object? raw) {
    final json = _map(raw);
    if (json == null) return null;
    final usage = AccountHealthUsageSummary(
      today: AccountHealthUsageWindow.tryParse(json['today']),
      month: AccountHealthUsageWindow.tryParse(json['month']),
    );
    return usage.isEmpty ? null : usage;
  }
}

/// The caller's own deletion row, projected to the three fields the screen
/// needs. `pending` is the server's verdict, not a state-name guess.
@immutable
class AccountHealthDeletion {
  const AccountHealthDeletion({this.state, this.pending, this.deleteAfter});

  final String? state;
  final bool? pending;
  final DateTime? deleteAfter;

  bool get isEmpty => state == null && pending == null && deleteAfter == null;

  static AccountHealthDeletion? tryParse(Object? raw) {
    final json = _map(raw);
    if (json == null) return null;
    final deletion = AccountHealthDeletion(
      state: _text(json['state']),
      pending: _bool(json['pending']),
      deleteAfter: _date(json['deleteAfter']),
    );
    return deletion.isEmpty ? null : deletion;
  }
}

/// The account's standing: the ban flag and the deletion row.
@immutable
class AccountHealthStanding {
  const AccountHealthStanding({
    this.banned,
    this.bannedAt,
    this.bannedReason,
    this.multiIpFlags,
    this.deletion,
  });

  final bool? banned;
  final DateTime? bannedAt;
  final String? bannedReason;

  /// The spec's multi-IP flag. The gateway has no detector or column, so it
  /// answers null. `false` would claim the account was checked and came back
  /// clean.
  final int? multiIpFlags;
  final AccountHealthDeletion? deletion;

  bool get isEmpty =>
      banned == null &&
      bannedAt == null &&
      bannedReason == null &&
      multiIpFlags == null &&
      deletion == null;

  static AccountHealthStanding? tryParse(Object? raw) {
    final json = _map(raw);
    if (json == null) return null;
    final standing = AccountHealthStanding(
      banned: _bool(json['banned']),
      bannedAt: _date(json['bannedAt']),
      bannedReason: _text(json['bannedReason']),
      multiIpFlags: _int(json['multiIpFlags']),
      deletion: AccountHealthDeletion.tryParse(json['deletion']),
    );
    return standing.isEmpty ? null : standing;
  }
}

/// The whole answer. An envelope with no readable section is [isEmpty] — the
/// screen then shows its empty state instead of four dashes that look like a
/// failed read.
@immutable
class AccountHealth {
  const AccountHealth({this.plan, this.storage, this.usage, this.standing});

  final AccountHealthPlan? plan;
  final AccountHealthStorage? storage;
  final AccountHealthUsageSummary? usage;
  final AccountHealthStanding? standing;

  bool get isEmpty =>
      plan == null && storage == null && usage == null && standing == null;

  factory AccountHealth.fromJson(Map<String, dynamic> json) => AccountHealth(
    plan: AccountHealthPlan.tryParse(json['plan']),
    storage: AccountHealthStorage.tryParse(json['storage']),
    usage: AccountHealthUsageSummary.tryParse(json['usage']),
    standing: AccountHealthStanding.tryParse(json['standing']),
  );
}

/// Reads `GET /account/health` through the shared [CloudRestClient] (auth
/// headers, one 401 retry, typed errors and the request ceiling).
class AccountHealthClient {
  AccountHealthClient({CloudRestClient? rest, int Function()? utcOffsetMinutes})
    : _rest = rest ?? CloudRestClient.I,
      _offset =
          utcOffsetMinutes ?? (() => DateTime.now().timeZoneOffset.inMinutes);

  /// The gateway's accepted range; anything else is a 400.
  static const int maxOffsetMinutes = 840;

  final CloudRestClient _rest;
  final int Function() _offset;

  /// "Today" and "this month" are the caller's calendar, so the offset goes
  /// with the request. The gateway rejects anything outside ±840 minutes.
  Future<AccountHealth> fetch() async {
    final offset = _offset().clamp(-maxOffsetMinutes, maxOffsetMinutes);
    final json = await _rest.getJson(
      '/account/health',
      query: <String, String>{'utcOffsetMinutes': '$offset'},
    );
    return AccountHealth.fromJson(json);
  }
}
