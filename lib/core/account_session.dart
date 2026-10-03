/// Prevents a late server response from admitting a signed-out/different user.
class AccountSession {
  int _generation = 0;
  String? uid;
  bool ready = false;
  String? error;

  void clear() {
    _generation++;
    uid = null;
    ready = false;
    error = null;
  }

  Future<void> bind(
    String identity,
    Future<void> Function() acknowledge,
  ) async {
    final generation = ++_generation;
    uid = identity;
    ready = false;
    error = null;
    try {
      await acknowledge();
      if (generation == _generation) ready = true;
    } catch (e) {
      if (generation == _generation) error = e.toString();
    }
  }
}
