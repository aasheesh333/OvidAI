import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'sandbox_service.dart';
import 'state.dart';

typedef SetupPhaseCallback =
    void Function(int phase, double progress, String line);

enum StudioSetupStatus { idle, running, ready, partial, failed, unsupported }

enum StudioRuntime { node, python, git, curl }

enum RuntimeVerification { unknown, verified, unavailable }

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
       // Preserve the public named injection with private storage.
       // ignore: prefer_initializing_formals
       _verifyRuntimes = verifyRuntimes;

  final Future<bool> Function() _checkExisting;
  final Future<void> Function(SetupPhaseCallback, bool) _install;
  final Future<bool> Function(SetupPhaseCallback) _installRuntimes;
  final Future<bool> Function() _verifyCore;
  final Future<bool> Function()? _verifyRuntimes;

  final _runtimeVerification = <StudioRuntime, RuntimeVerification>{};
  RuntimeVerification runtimeVerification(StudioRuntime runtime) =>
      _runtimeVerification[runtime] ?? RuntimeVerification.unknown;

  Future<bool> _checkRuntimes() async {
    bool transactionReady() {
      if (SandboxService.I.packageTransactionReady) return true;
      // A pending overlay invalidates certification, but does not identify a
      // broken runtime. Retain unavailable evidence and clear stale successes.
      _runtimeVerification.removeWhere((_, value) => value == RuntimeVerification.verified);
      return false;
    }
    if (!transactionReady()) return false;
    final injected = _verifyRuntimes;
    if (injected != null) {
      final verified = await injected();
      if (!transactionReady()) return false;
      // Keep aggregate fake injection compatible. A negative aggregate result
      // cannot identify which runtime failed; retain only observed evidence.
      for (final runtime in StudioRuntime.values) {
        if (verified) {
          _runtimeVerification[runtime] = RuntimeVerification.verified;
        } else if (runtimeVerification(runtime) == RuntimeVerification.verified) {
          _runtimeVerification.remove(runtime);
        }
      }
      return verified;
    }
    const commands = {
      StudioRuntime.node: 'node --version && npm --version && npx --version',
      StudioRuntime.python:
          'python --version && pip --version && uv --version && uvx --version',
      StudioRuntime.git: 'git --version',
      StudioRuntime.curl: 'curl --version',
    };
    // Run every group: a missing Node must not short-circuit Python/Git checks.
    for (final entry in commands.entries) {
      final ok = await _runs(entry.value);
      _runtimeVerification[entry.key] =
          ok ? RuntimeVerification.verified : RuntimeVerification.unavailable;
      // Logged (not parsed): makes a re-run over an existing sandbox show
      // what was actually executed and verified.
      _log.add('verify ${entry.key.name}: ${entry.value} → ${ok ? 'ok' : 'not ready'}');
      _persistLine(_log.last);
      _publish();
    }
    if (!transactionReady()) return false;
    return StudioRuntime.values.every(
      (runtime) => runtimeVerification(runtime) == RuntimeVerification.verified,
    );
  }

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

  /// Human headline + action for the last failure. Never raw exception text.
  String? get error => _error;
  String? _errorDetail;

  /// The raw first line of the failure, for a collapsed "Details" row and
  /// "Copy log". Null when the failure has no technical detail.
  String? get errorDetail => _errorDetail;

  /// Maps a setup failure to one human sentence with an action.
  @visibleForTesting
  static String friendlyError(Object e) {
    if (e is SandboxUnsupportedException) return e.message;
    if (e is RuntimeSetupException) return e.message;
    if (e is _SetupPersistenceException) {
      return 'Could not save Studio setup status. Retry setup.';
    }
    final raw = '$e'.toLowerCase();
    final fsCode = e is FileSystemException ? e.osError?.errorCode : null;
    if (fsCode == 28 ||
        raw.contains('no space left') ||
        raw.contains('errno = 28') ||
        raw.contains('enospc')) {
      return 'Not enough storage. Free about 600 MB on this device, then '
          'retry.';
    }
    if (e is SocketException ||
        e is http.ClientException ||
        e is HandshakeException ||
        e is TimeoutException ||
        raw.contains('failed host lookup') ||
        raw.contains('connection reset') ||
        raw.contains('connection closed') ||
        raw.contains('network is unreachable')) {
      return 'The download was interrupted. Check your connection (Wi-Fi '
          'recommended), then retry.';
    }
    if (e is StateError && e.message.startsWith('Sandbox core could not run')) {
      return e.message;
    }
    if (fsCode == 13 || raw.contains('permission denied')) {
      return 'Ovid could not write the sandbox files. Restart the app and '
          'retry.';
    }
    return 'Sandbox setup did not finish. Retry, or continue to chat without '
        'the sandbox.';
  }

  static String _firstLine(Object e) {
    final raw = '$e'.trim();
    final line = raw.split('\n').first.trim();
    return line.isEmpty ? raw : line;
  }

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
    _errorDetail = null;
    _phase = 0;
    _phaseProgress = 0;
    _log.clear();
    _runtimeVerification.clear();
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
    _errorDetail = null;
    _log.clear();
    _runtimeVerification.clear();
    notifyListeners();
  }

  void _onPhase(int phase, double progress, String line) {
    _phase = phase;
    _phaseProgress = progress.clamp(0.0, 1.0);
    // These are the service's runtime result lines, not arbitrary apt output
    // or phase numbers. Success is certified by the execution checks above.
    final warning = RegExp(
      r'^(node|python|git(?: exec-path)?|curl)\s+\.+\s+⚠',
    ).firstMatch(line);
    if (warning != null) {
      final name = warning.group(1)!.split(' ').first;
      final runtime = StudioRuntime.values.byName(name);
      _runtimeVerification[runtime] = RuntimeVerification.unavailable;
    }
    _log.add(line);
    if (_log.length > 1000) _log.removeAt(0);
    _persistLine(line);
    _publish();
  }

  // ── Persisted setup log ────────────────────────────────────────────
  // The in-memory log dies with the process (force-stop, crash, OOM kill).
  // Mirror every line to <app support>/studio-setup.log so a failed setup
  // can be exported/shared and the emulator e2e harness can read it
  // (scripts/studio_e2e.sh: `run-as <app> cat files/studio-setup.log`).
  IOSink? _logSink;
  Future<IOSink?>? _logSinkOpening;

  /// File name under the app support dir (`files/` on Android).
  static const setupLogName = 'studio-setup.log';

  @visibleForTesting
  static bool persistLogForTest = !Platform.environment.containsKey('FLUTTER_TEST');

  Future<IOSink?> _openLogSink() async {
    if (!persistLogForTest) return null;
    try {
      final dir = await SandboxService.I.filesRoot();
      final sink = File('${dir.path}/$setupLogName')
          .openWrite(mode: FileMode.writeOnly);
      sink.writeln('# Ovid Studio setup ${DateTime.now().toIso8601String()}');
      return sink;
    } catch (_) {
      return null; // Diagnostics only — never fail setup over the log file.
    }
  }

  void _persistLine(String line) {
    if (!persistLogForTest) return;
    final opening = _logSinkOpening ??= _openLogSink().then((s) => _logSink = s);
    final stamp = DateTime.now().toIso8601String().substring(11, 23);
    final text = '$stamp $line';
    if (_logSink != null) {
      _logSink!.writeln(text);
    } else {
      unawaited(opening.then((s) => s?.writeln(text)));
    }
  }

  Future<void> _closeLog(String summary) async {
    final opening = _logSinkOpening;
    _logSinkOpening = null;
    if (opening == null) return;
    try {
      final sink = await opening;
      sink?.writeln('# result: $summary');
      await sink?.flush();
      await sink?.close();
    } catch (_) {
      // Diagnostics only.
    }
    _logSink = null;
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
        if (existing && !await _checkRuntimes()) {
          _onPhase(7, 0, 'Keeping existing core; installing missing runtimes…');
          await _installRuntimes(_onPhase);
        }
        // The installer deliberately swallows runtime failures. Verify actual
        // execution, including npx/uvx, before calling the whole setup ready.
        final verified = await _checkRuntimes();
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
      _errorDetail = _firstLine(e);
      _error = friendlyError(e);
      if (_coreReady && e is! _SetupPersistenceException) {
        // Core works; only the runtime step failed. Keep the partial copy
        // human and say what still works.
        _error =
            'Sandbox core is ready, but some runtime tools are unavailable. '
            '$_error';
      }
      _status = e is _SetupPersistenceException
          ? StudioSetupStatus.failed
          : e is SandboxUnsupportedException
          ? StudioSetupStatus.unsupported
          : _coreReady
          ? StudioSetupStatus.partial
          : StudioSetupStatus.failed;
    } finally {
      _finishedAt = DateTime.now();
      await _closeLog('${_status.name} in ${elapsed.inSeconds}s'
          '${_error == null ? '' : ' — $_error'}'
          '${_errorDetail == null ? '' : ' [$_errorDetail]'}');
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
