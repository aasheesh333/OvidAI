import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sandbox_service.dart';
import 'state.dart';

typedef SetupPhaseCallback =
    void Function(int phase, double progress, String line);

enum StudioSetupStatus { idle, running, ready, partial, failed, unsupported }

class _SetupPersistenceException implements Exception {
  const _SetupPersistenceException(this.cause);
  final Object cause;

  @override
  String toString() =>
      'Could not save Studio setup status. Retry setup. ($cause)';
}

/// App-owned setup job. Routes subscribe to this notifier; leaving a route
/// neither cancels the job nor drops its completion bookkeeping. This is an
/// in-process job, not an OS background worker or a process-death checkpoint.
class StudioSetupCoordinator extends ChangeNotifier {
  static final _instance = StudioSetupCoordinator();
  static StudioSetupCoordinator get I => overrideForTest ?? _instance;

  @visibleForTesting
  static StudioSetupCoordinator? overrideForTest;

  StudioSetupCoordinator({
    Future<bool> Function()? checkExisting,
    Future<void> Function(SetupPhaseCallback, bool)? install,
    Future<bool> Function(SetupPhaseCallback)? installRuntimes,
    Future<bool> Function()? verifyCore,
    Future<bool> Function()? verifyRuntimes,
  }) : _checkExisting = checkExisting ?? SandboxService.I.checkExisting,
       _install =
           install ??
           ((onPhase, full) => SandboxService.I.install(
             onPhase: onPhase,
             includeRuntimes: full,
           )),
       _installRuntimes =
           installRuntimes ?? SandboxService.I.installCoreRuntimes,
       _verifyCore = verifyCore ?? (() => _runs('bash --version')),
       _verifyRuntimes =
           verifyRuntimes ??
           (() => _runs(
             'node --version && npm --version && npx --version && '
             'python --version && pip --version && uv --version && '
             'uvx --version && git --version && curl --version',
           ));

  final Future<bool> Function() _checkExisting;
  final Future<void> Function(SetupPhaseCallback, bool) _install;
  final Future<bool> Function(SetupPhaseCallback) _installRuntimes;
  final Future<bool> Function() _verifyCore;
  final Future<bool> Function() _verifyRuntimes;

  static Future<bool> _runs(String command) async {
    try {
      final (code, _) = await SandboxService.I
          .execChecked(['bash', '-c', command])
          .timeout(const Duration(seconds: 60));
      return code == 0;
    } catch (_) {
      return false;
    }
  }

  StudioSetupStatus _status = StudioSetupStatus.idle;
  StudioSetupStatus get status => _status;
  bool get running => _status == StudioSetupStatus.running;
  bool get needsAttention =>
      running ||
      _status == StudioSetupStatus.partial ||
      _status == StudioSetupStatus.failed ||
      _status == StudioSetupStatus.unsupported;
  bool _coreOnly = false;
  bool get coreOnly => _coreOnly;
  bool _coreReady = false;
  bool get coreReady => _coreReady;
  final _log = <String>[];
  List<String> get log => List.unmodifiable(_log);
  int _phase = 0;
  int get phase => _phase;
  double _phaseProgress = 0;
  double get phaseProgress => _phaseProgress;
  String? _error;
  String? get error => _error;
  DateTime? _startedAt;
  DateTime? get startedAt => _startedAt;
  DateTime? _finishedAt;
  Duration get elapsed => _startedAt == null
      ? Duration.zero
      : (_finishedAt ?? DateTime.now()).difference(_startedAt!);
  Future<void>? _job;

  /// The chat banner is shared with generic runtime repair. An unfinished
  /// approved Studio setup must keep its job, verification and persistence
  /// owner; a generic banner must not implicitly approve full Studio setup.
  Future<void> retryFromRuntimeBanner() {
    if (!_coreOnly && needsAttention) return start();
    return AppState.I.retryBackgroundRuntimeInstall();
  }

  /// Called only after approval (or the Health screen's explicit hard reset).
  /// Install's own lock queues full installs; this guard instead JOINS a job.
  Future<void> start({bool coreOnly = false}) {
    if (_job != null) return _job!;
    final completion = Completer<void>();
    _job = completion.future;
    _coreOnly = coreOnly;
    _coreReady = false;
    _status = StudioSetupStatus.running;
    _error = null;
    _phase = 0;
    _phaseProgress = 0;
    _log.clear();
    _startedAt = DateTime.now();
    _finishedAt = null;
    _publish();
    unawaited(
      _run().whenComplete(() {
        _job = null;
        completion.complete();
      }),
    );
    return completion.future;
  }

  /// A completed job is not proof that a subsequently wiped core still exists.
  void forgetCompleted() {
    if (running) return;
    _status = StudioSetupStatus.idle;
    _coreReady = false;
    _error = null;
    _log.clear();
    notifyListeners();
  }

  void _onPhase(int phase, double progress, String line) {
    _phase = phase;
    _phaseProgress = progress.clamp(0.0, 1.0);
    _log.add(line);
    if (_log.length > 1000) _log.removeAt(0);
    _publish();
  }

  /// Same key consumed by AppState.loadStudioFirstOpenFlag. Its existing
  /// setter is best-effort; setup needs a confirmed commit before proceeding.
  Future<void> _saveCompletion(bool value) async {
    const key = 'studio_first_open_done';
    final app = AppState.I;
    final previous = app.studioFirstOpenDone;
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(key, value)) {
        throw StateError('Preferences rejected the write');
      }
    } catch (e) {
      // Both Dart and Android caches can mutate before a failed commit.
      // Restore the prior value, not a reload of that unconfirmed snapshot.
      // Rollback is best-effort and never turns the failed write into success.
      if (prefs != null) {
        try {
          await prefs.setBool(key, previous);
        } catch (_) {
          // Storage is still unavailable; keep app memory at its prior value.
        }
      }
      throw _SetupPersistenceException(e);
    }
    app.studioFirstOpenDone = value;
    app.refresh();
  }

  Future<void> _run() async {
    try {
      // A historical success cannot certify this attempt (including a wiped
      // core or Health reset). Persist invalidation before any install work so
      // interruption/relaunch cannot mistake a partial toolchain for completion.
      await _saveCompletion(false);
      _onPhase(0, 0, 'Checking existing sandbox…');
      final existing = await _checkExisting();
      if (!existing) {
        await _install(_onPhase, !_coreOnly);
      }
      // checkExisting checks files, not native execution. A failed native
      // check must not turn an existing user prefix into a destructive reinstall.
      if (!await _verifyCore()) {
        AppState.I.sandboxInstalled = false;
        throw StateError(
          'Sandbox core could not run. Check sandbox Health for repair.',
        );
      }
      _coreReady = true;
      AppState.I.sandboxReady();
      AppState.I.sandboxInstalled = true;
      await AppState.I.setSandboxSkipped(false);

      if (_coreOnly) {
        _status = StudioSetupStatus.ready;
      } else {
        if (existing && !await _verifyRuntimes()) {
          _onPhase(7, 0, 'Keeping existing core; installing missing runtimes…');
          await _installRuntimes(_onPhase);
        }
        // The installer deliberately swallows runtime failures. Verify actual
        // execution, including npx/uvx, before calling the whole setup ready.
        final verified = await _verifyRuntimes();
        if (verified) {
          await _saveCompletion(true);
          _status = StudioSetupStatus.ready;
        } else {
          _status = StudioSetupStatus.partial;
          _error =
              'Sandbox core is ready, but some runtime tools are unavailable. '
              'Retry runtime setup when connected.';
        }
      }
    } catch (e) {
      _error = '$e';
      _status = e is _SetupPersistenceException
          ? StudioSetupStatus.failed
          : e is SandboxUnsupportedException
          ? StudioSetupStatus.unsupported
          : _coreReady
          ? StudioSetupStatus.partial
          : StudioSetupStatus.failed;
    } finally {
      _finishedAt = DateTime.now();
      _publish();
    }
  }

  void _publish() {
    final app = AppState.I;
    if (!_coreOnly) {
      app.runtimeInstallState = running
          ? RuntimeInstallState.running
          : _status == StudioSetupStatus.ready
          ? RuntimeInstallState.done
          : RuntimeInstallState.failed;
      app.runtimeInstallLine =
          _error ?? (_log.isEmpty ? 'Preparing sandbox…' : _log.last);
      app.runtimeInstallProgress = running
          ? -1
          : _status == StudioSetupStatus.ready
          ? 1
          : -1;
    }
    app.refresh();
    notifyListeners();
  }
}
