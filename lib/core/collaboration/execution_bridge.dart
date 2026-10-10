import 'models.dart';

/// A typed local observation emitted by [LocalObservationalPublicationAdapter].
sealed class LocalPublication {
  const LocalPublication();
}

/// A locally published private message observation.
class LocalMessagePublication extends LocalPublication {
  const LocalMessagePublication(this.payload);

  final MessagePayload payload;
}

/// A locally published display-safe model status observation.
class LocalStatusPublication extends LocalPublication {
  const LocalStatusPublication(this.payload);

  final ModelStatusPayload payload;
}

/// A locally published usage observation.
class LocalUsagePublication extends LocalPublication {
  const LocalUsagePublication(this.payload);

  final UsagePayload payload;
}

/// Stores observational collaboration publications without executing anything.
///
/// This adapter is deliberately local and inert. It has no provider, client,
/// callback, queue, or runtime dependency; publication only appends a typed
/// observation to the local immutable view.
class LocalObservationalPublicationAdapter {
  final List<LocalPublication> _publications = <LocalPublication>[];

  /// The publications made so far, in publication order.
  List<LocalPublication> get publications => List.unmodifiable(_publications);

  void publishMessage(MessagePayload payload) {
    _publications.add(LocalMessagePublication(payload));
  }

  void publishStatus(ModelStatusPayload payload) {
    _publications.add(LocalStatusPublication(payload));
  }

  void publishUsage(UsagePayload payload) {
    _publications.add(LocalUsagePublication(payload));
  }
}
