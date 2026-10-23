import 'package:flutter/foundation.dart' show immutable;

import 'cloud_rest.dart';

/// The four canonical plan ids, cheapest first.
const Set<String> canonicalPlanIds = {'free', 'go', 'plus', 'pro'};

/// Legacy spellings the server still resolves to a real tier.
///
/// `3x` / `7x` / `15x` are the aliases the mint stored in `users.tier`;
/// `starter` / `max` are older seeds. The mapping is the same one
/// `@ovid/shared`'s `planFor` applies, so a stale stored tier renders the plan
/// the server would charge for. [test/plan_tier_test.dart] pins the same table
/// for the manual-model gate.
const Map<String, String> legacyPlanIds = {
  'starter': 'go',
  'max': 'pro',
  '3x': 'go',
  '7x': 'plus',
  '15x': 'pro',
};

/// True when [raw] is a canonical id or a legacy spelling of one.
bool isKnownPlanId(String? raw) {
  final key = (raw ?? '').trim().toLowerCase();
  return canonicalPlanIds.contains(key) || legacyPlanIds.containsKey(key);
}

/// The canonical id for [raw] (`3x` → `go`, `starter` → `go`).
///
/// An unknown id is returned trimmed and lower-cased rather than coerced to
/// Free: the server's `planFor` defaults to Free, but a client that does the
/// same would silently show a paying "team" account as Free.
String canonicalPlanId(String? raw) {
  final key = (raw ?? '').trim().toLowerCase();
  if (canonicalPlanIds.contains(key)) return key;
  return legacyPlanIds[key] ?? key;
}

/// A rolling upload allowance: [count] files inside [windowHours] hours.
@immutable
class CloudPlanUploads {
  const CloudPlanUploads({required this.count, required this.windowHours});

  final int count;
  final int windowHours;

  static CloudPlanUploads? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final count = _asInt(raw['count']);
    final windowHours = _asInt(raw['windowHours']);
    if (count == null || windowHours == null) return null;
    return CloudPlanUploads(count: count, windowHours: windowHours);
  }
}

/// One row of `GET /cloud/v1/plans`.
///
/// The gateway merges the owner-editable `plans` row (name, price,
/// multiplier, window) with the structural product table (storage, connectors,
/// project files, uploads). A limit the product table does not describe is
/// `null` — "not known" — never `0`, which would claim the plan grants
/// nothing.
@immutable
class CloudPlan {
  const CloudPlan({
    required this.id,
    required this.tier,
    required this.name,
    this.priceUsd,
    this.priceInr,
    this.mult,
    this.windowHours,
    this.aliases = const [],
    this.manualModels,
    this.storageGb,
    this.customConnectors,
    this.projectFiles,
    this.uploads,
  });

  /// The row's own id (`go`, or an owner-created `team`).
  final String id;

  /// The canonical tier the server says this row means (`starter` → `go`).
  final String tier;

  final String name;
  final num? priceUsd;
  final num? priceInr;
  final num? mult;
  final int? windowHours;
  final List<String> aliases;
  final bool? manualModels;
  final int? storageGb;
  final int? customConnectors;
  final int? projectFiles;
  final CloudPlanUploads? uploads;

  /// The canonical id for this row.
  ///
  /// The row id is preferred because it is what the account's stored tier and
  /// the Play product map use. A row id the mapping does not know (a
  /// `team` plan) stays itself instead of inheriting Free from the server's
  /// `planFor` default.
  String get canonicalId {
    final key = id.trim().toLowerCase();
    return isKnownPlanId(key) ? canonicalPlanId(key) : key;
  }

  static CloudPlan? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = _asString(raw['id']);
    if (id == null) return null;
    final aliases = <String>[
      for (final alias
          in (raw['aliases'] is List ? raw['aliases'] as List : const []))
        if (alias is String && alias.trim().isNotEmpty) alias.trim(),
    ];
    return CloudPlan(
      id: id,
      tier: _asString(raw['tier']) ?? id,
      name: _asString(raw['name']) ?? id,
      priceUsd: _asNum(raw['priceUsd']),
      priceInr: _asNum(raw['priceInr']),
      mult: _asNum(raw['mult']),
      windowHours: _asInt(raw['windowHours']),
      aliases: aliases,
      manualModels: raw['manualModels'] is bool
          ? raw['manualModels'] as bool
          : null,
      storageGb: _asInt(raw['storageGb']),
      customConnectors: _asInt(raw['customConnectors']),
      projectFiles: _asInt(raw['projectFiles']),
      uploads: CloudPlanUploads.tryParse(raw['uploads']),
    );
  }
}

/// Reads the gateway's plan table.
///
/// The plan screen used to carry its own copy of four plans. This is the one
/// source: `GET /cloud/v1/plans` answers `{plans: [...]}` in camelCase.
class PlansClient {
  PlansClient({CloudRestClient? rest}) : _rest = rest ?? CloudRestClient.I;

  final CloudRestClient _rest;

  Future<List<CloudPlan>> fetch() async {
    final json = await _rest.getJson('/plans');
    final raw = json['plans'];
    // A 200 without a list is a contract failure, not "nothing is on sale".
    // The screen must show an error rather than an empty plan table.
    if (raw is! List) {
      throw const FormatException('GET /plans did not return a plans list');
    }
    return [for (final entry in raw) ?CloudPlan.tryParse(entry)];
  }
}

String? _asString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

num? _asNum(Object? value) {
  final parsed = value is num
      ? value
      : value is String
      ? num.tryParse(value.trim())
      : null;
  if (parsed == null || !parsed.isFinite || parsed < 0) return null;
  return parsed;
}

int? _asInt(Object? value) => _asNum(value)?.toInt();
