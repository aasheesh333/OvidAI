/// Prevents a late server response from admitting a signed-out/different user.
class AccountSession {
  int _generation = 0;
  Future<void>? _inFlight;
  String? _inFlightUid;
  String? uid;
  bool ready = false;
  String? error;

  void clear() {
    _generation++;
    _inFlight = null;
    _inFlightUid = null;
    uid = null;
    ready = false;
    error = null;
  }

  Future<void> bind(
    String identity,
    Future<void> Function() acknowledge,
  ) async {
    if (_inFlight != null && _inFlightUid == identity) return _inFlight!;
    final generation = ++_generation;
    uid = identity;
    ready = false;
    error = null;
    late final Future<void> operation;
    operation = _bind(generation, acknowledge);
    _inFlight = operation;
    _inFlightUid = identity;
    operation.then(
      (_) {
        if (identical(_inFlight, operation)) {
          _inFlight = null;
          _inFlightUid = null;
        }
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_inFlight, operation)) {
          _inFlight = null;
          _inFlightUid = null;
        }
      },
    );
    return operation;
  }

  Future<void> _bind(
    int generation,
    Future<void> Function() acknowledge,
  ) async {
    try {
      await acknowledge();
      if (generation == _generation) ready = true;
    } catch (e) {
      if (generation == _generation) error = e.toString();
    }
  }
}
