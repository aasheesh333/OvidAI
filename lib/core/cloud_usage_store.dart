import 'dart:async';

import 'package:flutter/widgets.dart';

import 'ovid_cloud_service.dart';
import 'state.dart';

/// One live allowance projection per AppState, shared by all mounted consumers.
/// AppState notifications are noisy (including streaming tokens); only completed
/// usage-row revisions and cloud configuration changes invalidate this cache.
class CloudUsageStore extends ChangeNotifier with WidgetsBindingObserver {
  CloudUsageStore._(this.app) {
    _identity = service.accountIdentity;
    _revision = _readRevision();
    _configuration = _readConfiguration();
    app.addListener(_onChange);
    service.addListener(_onChange);
    WidgetsBinding.instance.addObserver(this);
    refresh();
  }

  static final _stores = Expando<CloudUsageStore>();
  static CloudUsageStore acquire(AppState app) {
    final store = _stores[app] ??= CloudUsageStore._(app);
    store._consumers++;
    return store;
  }

  final AppState app;
  final OvidCloudService service = OvidCloudService.I;
  int _consumers = 0;
  bool _disposed = false;
  bool _notifyScheduled = false;
  late Object _identity;
  late Object _revision;
  late Object _configuration;
  int _generation = 0;
  bool _inFlight = false;
  bool _pending = false;
  Timer? _scheduled;
  Timer? _cooldown;

  OvidUsage? usage;
  String? error;
  bool loading = false;
  bool stale = true;

  Object _readRevision() => (app.usageLog.length, app.usageLog.lastOrNull);

  Object _readConfiguration() {
    final provider = app.providerById(AppState.ovidCloudProviderId);
    return (
      provider,
      provider?.cleanApiKey,
      provider?.baseUrl,
      app.ovidCloudTier,
      service.allowanceRevision,
    );
  }

  void _onChange() {
    final identity = service.accountIdentity;
    final revision = _readRevision();
    final configuration = _readConfiguration();
    final changedAccount = identity != _identity;
    final changedConfiguration = configuration != _configuration;
    if (!changedAccount && !changedConfiguration && revision == _revision) {
      return;
    }
    _identity = identity;
    _revision = revision;
    _configuration = configuration;
    if (changedAccount || changedConfiguration) {
      // A previous account/plan/key snapshot must never override a new one.
      _generation++;
      _inFlight = false;
      usage = null;
      error = null;
      _cooldown?.cancel();
      _cooldown = null;
    }
    refresh();
  }

  /// Explicit retry and resume use the same throttle/single-flight path.
  void refresh() {
    if (_disposed) return;
    stale = true;
    _pending = true;
    _publish();
    _schedule();
  }

  void _schedule() {
    if (_disposed ||
        !_pending ||
        _inFlight ||
        _cooldown != null ||
        _scheduled != null) {
      return;
    }
    _scheduled = Timer(Duration.zero, () {
      _scheduled = null;
      unawaited(_fetch());
    });
  }

  Future<void> _fetch() async {
    if (_disposed) return;
    final generation = _generation;
    final identity = _identity;
    final revision = _revision;
    _pending = false;
    _inFlight = true;
    loading = true;
    error = null;
    _publish();
    _cooldown = Timer(const Duration(seconds: 2), () {
      _cooldown = null;
      _schedule();
    });
    try {
      final result = await service.fetchUsage(throwOnError: true);
      if (_disposed ||
          generation != _generation ||
          identity != service.accountIdentity) {
        return;
      }
      usage = result;
      stale = revision != _revision;
    } catch (e) {
      if (_disposed ||
          generation != _generation ||
          identity != service.accountIdentity) {
        return;
      }
      error = e is CloudUsageException
          ? e.message
          : 'Cloud allowance unavailable. Retry to refresh.';
      stale = true;
    } finally {
      if (!_disposed && generation == _generation) {
        _inFlight = false;
        loading = false;
        _publish();
        _schedule();
      }
    }
  }

  // Never notify synchronously from acquisition/build or an AppState listener.
  void _publish() {
    if (_disposed || _notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  void release() {
    if (--_consumers == 0) {
      _stores[app] = null;
      dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _scheduled?.cancel();
    _cooldown?.cancel();
    app.removeListener(_onChange);
    service.removeListener(_onChange);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
