/// The subset of `GET /cloud/v1/models` the client needs to gate manual picks.
///
/// The route returns `{auto, models, tier, manualModelsAllowed, known}` on a
/// gateway that has the flag. [manualModelsAllowed] is deliberately nullable:
/// an older gateway omits the field, and "not reported" must fall back to the
/// local plan table rather than be read as false.
library;

class CloudModelAccess {
  const CloudModelAccess({
    this.tier,
    this.manualModelsAllowed,
    this.models = const <String>[],
    this.known = false,
  });

  /// The account's tier as the server reported it (canonical or legacy).
  final String? tier;

  /// True when the plan may pin a model. Null when the gateway predates the
  /// field, which is different from the server saying no.
  final bool? manualModelsAllowed;

  /// Model ids the catalog advertised; empty is "not known yet", not "none".
  final List<String> models;

  /// True when the catalog was readable.
  final bool known;

  factory CloudModelAccess.fromJson(Map<String, dynamic> json) {
    final tier = json['tier'];
    final allowed = json['manualModelsAllowed'];
    final models = json['models'];
    final known = json['known'];
    return CloudModelAccess(
      tier: tier is String && tier.trim().isNotEmpty ? tier.trim() : null,
      // A malformed value is treated as absent: the fallback decides.
      manualModelsAllowed: allowed is bool ? allowed : null,
      models: models is List
          ? models.whereType<String>().toList(growable: false)
          : const <String>[],
      known: known is bool && known,
    );
  }
}
