import 'package:shared_preferences/shared_preferences.dart';
import 'settings_backup_service.dart';

class SettingsResetResult {
  final List<String> completed;
  final Map<String, String> failures;
  final bool verifiedComplete;
  const SettingsResetResult({
    this.completed = const [],
    this.failures = const {},
    this.verifiedComplete = false,
  });
  bool get success => verifiedComplete && failures.isEmpty;
}

/// Integration bindings supplied by the state/store owner, never by the UI.
/// Reset must fence producers, await every store, and return an explicit report.
class SettingsActions {
  static Future<SettingsResetResult> Function()? resetAll;
  static SettingsRestorePublisher? _restorePublisher;
  static SettingsRestorePublisher Function()? _restorePublisherFactory;

  /// Capture the account generation when the consumer begins an import,
  /// before archive validation/staging introduces asynchronous boundaries.
  static SettingsRestorePublisher? get restorePublisher =>
      _restorePublisherFactory?.call() ?? _restorePublisher;
  static set restorePublisher(SettingsRestorePublisher? value) {
    _restorePublisherFactory = null;
    _restorePublisher = value;
  }

  static void bindOwner({
    required Future<SettingsResetResult> Function()? reset,
    required SettingsRestorePublisher Function() restore,
  }) {
    resetAll = reset;
    _restorePublisher = null;
    _restorePublisherFactory = restore;
  }

  static Future<void> awaitPendingWrites() async {
    while (_writes.isNotEmpty) {
      await Future.wait(_writes.values.toList());
    }
  }

  static final Map<String, Future<void>> _writes = {};

  /// The current AppState setters swallow storage errors. A fresh readback
  /// exposes that failure without introducing a competing state mutation owner.
  static Future<void> persist(
    String key,
    Object value,
    Future<void> Function() write,
  ) {
    final previous = _writes[key] ?? Future<void>.value();
    final next = previous.then((_) => _persist(key, value, write));
    final settled = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _writes[key] = settled;
    settled.then((_) {
      if (identical(_writes[key], settled)) _writes.remove(key);
    });
    return next;
  }

  static Future<void> _persist(
    String key,
    Object value,
    Future<void> Function() write,
  ) async {
    await write();
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (prefs.get(key) != value) {
      throw StateError(
        'The setting is active in this session but was not saved. Retry before restarting.',
      );
    }
  }
}
