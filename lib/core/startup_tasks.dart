import 'dart:async';

import 'mcp_service.dart';
import 'sandbox_service.dart';
import 'startup_coordinator.dart';

/// Aggregate outcome of refreshing one marketplace catalog during startup.
///
/// `ready` means the remote catalog was fetched and merged. `degraded` means
/// the remote fetch failed but a previously merged catalog is still available
/// (spec §7: "Marketplace unavailability keeps cached catalog content and
/// becomes Degraded"). `failed` means nothing usable is available.
enum MarketplaceSyncOutcome { ready, degraded, failed }

/// Collapse per-plugin safety states into the single aggregate surfaced by the
/// `localSafety.migrate` startup item. Precedence (worst first):
/// failed > unsupported > migrationRequired > degraded > ready.
StartupItemState aggregateStartupStates(Iterable<StartupItemState> states) {
  var aggregate = StartupItemState.ready;
  for (final state in states) {
    if (state == StartupItemState.failed) return StartupItemState.failed;
    if (state == StartupItemState.unsupported) {
      aggregate = StartupItemState.unsupported;
      continue;
    }
    if (state == StartupItemState.migrationRequired &&
        aggregate != StartupItemState.unsupported) {
      aggregate = StartupItemState.migrationRequired;
      continue;
    }
    if (state == StartupItemState.degraded &&
        aggregate == StartupItemState.ready) {
      aggregate = StartupItemState.degraded;
    }
  }
  return aggregate;
}

/// Registers/activates normalized plugin runtimes for the boot epoch.
///
/// The body is injected by `AppState` so it always runs through the
/// `_runStartupStage('plugin.activate', …)` seam (test delegates short-circuit
/// it). Never throws: a failure becomes a terminal [StartupItemStatus.failed].
///
/// One task is emitted per normalized runtime (spec §5.7). [ownerId] carries
/// the canonical plugin id so the dashboard can deep-link and disable that
/// exact row; [probe] recomputes the truthful per-runtime health after
/// activation. The aggregate boot task (zero runtimes) leaves [ownerId] empty
/// and has no [probe].
class PluginActivationTask implements StartupTask, StartupOwnedTask {
  PluginActivationTask({
    required this.id,
    required this.label,
    required this.timeout,
    required this.activate,
    this.ownerId = '',
    this.probe,
    this.onDisable,
  });

  @override
  final String id;
  @override
  final String label;
  @override
  final Duration timeout;
  final Future<void> Function() activate;

  /// Canonical plugin id this item owns, or empty for the aggregate boot item.
  @override
  final String ownerId;

  /// Recomputes the truthful terminal status for this runtime after
  /// activation. Null for the aggregate boot item.
  final Future<StartupItemStatus> Function()? probe;

  /// Real disable callback for a per-runtime item (null for the aggregate).
  @override
  final StartupDisable? onDisable;

  @override
  StartupItemKind get kind => StartupItemKind.plugin;

  @override
  Future<StartupItemStatus> run() async {
    try {
      await activate();
      final probed = await probe?.call();
      if (probed != null) {
        return StartupItemStatus(
          id: id,
          kind: kind,
          label: label,
          state: probed.state,
          reason: probed.reason,
          ownerId: ownerId.isEmpty ? null : ownerId,
        );
      }
      return StartupItemStatus.ready(
        id,
        kind,
        label,
        ownerId: ownerId.isEmpty ? null : ownerId,
      );
    } catch (error) {
      return StartupItemStatus.failed(
        id,
        kind,
        label,
        reason: '$error',
        ownerId: ownerId.isEmpty ? null : ownerId,
      );
    }
  }
}

/// Refreshes every registered marketplace catalog once per launch.
///
/// One marketplace failing never suppresses the rest; the aggregate is the
/// worst outcome observed. A cached fallback is `degraded`, not `failed`.
class MarketplaceRefreshTask implements StartupTask {
  MarketplaceRefreshTask({
    required this.id,
    required this.label,
    required this.timeout,
    required this.repos,
    required this.refresh,
  });

  @override
  final String id;
  @override
  final String label;
  @override
  final Duration timeout;
  final List<String> Function() repos;
  final Future<MarketplaceSyncOutcome> Function(String repo) refresh;

  @override
  StartupItemKind get kind => StartupItemKind.marketplace;

  @override
  StartupDisable? get onDisable => null;

  @override
  Future<StartupItemStatus> run() async {
    var worst = MarketplaceSyncOutcome.ready;
    final repos = this.repos();
    // One item covers every registered marketplace. Bound each repo by its
    // fair share of the remaining item budget so one slow repo cannot starve
    // the repos queued behind it.
    final deadline = DateTime.now().add(timeout);
    Future<MarketplaceSyncOutcome> guarded(String repo) async {
      try {
        return await refresh(repo);
      } catch (_) {
        return MarketplaceSyncOutcome.failed;
      }
    }

    for (var i = 0; i < repos.length; i++) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        worst = MarketplaceSyncOutcome.failed;
        continue;
      }
      final reposLeft = repos.length - i;
      final slice = Duration(
        microseconds: remaining.inMicroseconds ~/ reposLeft,
      );
      final outcome = await guarded(
        repos[i],
      ).timeout(slice, onTimeout: () => MarketplaceSyncOutcome.failed);
      if (outcome.index > worst.index) worst = outcome;
    }
    return switch (worst) {
      MarketplaceSyncOutcome.ready => StartupItemStatus.ready(id, kind, label),
      MarketplaceSyncOutcome.degraded => StartupItemStatus.degraded(
        id,
        kind,
        label,
        reason: 'Cached marketplace content is being used',
      ),
      MarketplaceSyncOutcome.failed => StartupItemStatus.failed(
        id,
        kind,
        label,
        reason: 'Marketplace catalogs could not be refreshed',
      ),
    };
  }
}

/// Connects one intended MCP server with a single complete-handshake budget.
///
/// The coordinator id is per canonical server (`mcp.connect:<canonicalId>`)
/// while the injected body routes through the base `mcp.connect` stage. The
/// task timeout is the budget plus a one-second safety margin so the task's
/// own truthful status wins over the coordinator's generic timeout.
class McpConnectTask implements StartupTask, StartupOwnedTask {
  McpConnectTask({
    required this.canonicalId,
    required this.label,
    required this.resolveBudget,
    required this.connect,
    required this.isConnected,
    required this.onDisable,
  });

  final String canonicalId;
  @override
  final String label;

  /// Canonical MCP server id this item owns (durable-status attribution).
  @override
  String get ownerId => canonicalId;

  /// Resolves the complete-handshake budget lazily, at run time, so a server
  /// loaded during readiness inventory (custom/marketplace rows) contributes
  /// its real `startupTimeoutS` instead of the pre-hydration default.
  final Duration Function() resolveBudget;
  final Future<McpConnectOutcome> Function(Duration budget) connect;
  final bool Function() isConnected;

  @override
  final StartupDisable? onDisable;

  /// The one complete-handshake budget: `min(startupTimeoutS, 30s)`.
  static Duration budgetFor(int startupTimeoutS) =>
      Duration(seconds: startupTimeoutS < 30 ? startupTimeoutS : 30);

  @override
  String get id => 'mcp.connect:$canonicalId';

  @override
  StartupItemKind get kind => StartupItemKind.mcp;

  @override
  Duration get timeout => resolveBudget() + const Duration(seconds: 1);

  @override
  Future<StartupItemStatus> run() async {
    try {
      final outcome = await connect(resolveBudget());
      if (outcome.kind == McpConnectOutcomeKind.ready && !isConnected()) {
        return StartupItemStatus.failed(
          id,
          kind,
          label,
          reason: 'Handshake reported success but the server is not connected',
        );
      }
      return switch (outcome.kind) {
        McpConnectOutcomeKind.ready => StartupItemStatus.ready(id, kind, label),
        McpConnectOutcomeKind.needsSetup => StartupItemStatus.needsSetup(
          id,
          kind,
          label,
          reason: outcome.reason,
        ),
        McpConnectOutcomeKind.unsupported => StartupItemStatus.unsupported(
          id,
          kind,
          label,
          reason: outcome.reason,
        ),
        McpConnectOutcomeKind.failed => StartupItemStatus.failed(
          id,
          kind,
          label,
          reason: outcome.reason,
        ),
      };
    } catch (error) {
      return StartupItemStatus.failed(id, kind, label, reason: '$error');
    }
  }
}

/// Initializes optional Firebase/telemetry. Firebase is never required for the
/// app to work, so every failure (unconfigured, unavailable, unexpected) maps
/// to a retryable [StartupItemState.degraded] — never `failed`.
class FirebaseStartupTask implements StartupTask {
  FirebaseStartupTask({
    required this.id,
    required this.label,
    required this.timeout,
    required this.initialize,
  });

  @override
  final String id;
  @override
  final String label;
  @override
  final Duration timeout;

  /// Returns whether Firebase became available. May throw.
  final Future<bool> Function() initialize;

  @override
  StartupItemKind get kind => StartupItemKind.firebase;

  @override
  StartupDisable? get onDisable => null;

  @override
  Future<StartupItemStatus> run() async {
    try {
      final available = await initialize();
      if (available) return StartupItemStatus.ready(id, kind, label);
      return StartupItemStatus.degraded(
        id,
        kind,
        label,
        reason: 'Optional services are not configured on this build',
      );
    } catch (error) {
      return StartupItemStatus.degraded(id, kind, label, reason: '$error');
    }
  }
}

/// Background sandbox self-heal and maintenance. Always background-degradable:
/// a missing sandbox is `skipped`, a permanently unsupported device is
/// `unsupported`, and any other failure is `degraded`.
class SandboxMaintenanceTask implements StartupTask {
  SandboxMaintenanceTask({
    required this.id,
    required this.label,
    required this.timeout,
    required this.isInstalled,
    required this.startMaintenance,
    required this.runtimesVerified,
    required this.installCoreRuntimes,
    required this.enforceQuota,
  });

  @override
  final String id;
  @override
  final String label;
  @override
  final Duration timeout;
  final bool Function() isInstalled;
  final Future<void> Function() startMaintenance;
  final Future<bool> Function() runtimesVerified;
  final Future<bool> Function() installCoreRuntimes;
  final Future<void> Function() enforceQuota;

  @override
  StartupItemKind get kind => StartupItemKind.sandbox;

  @override
  StartupDisable? get onDisable => null;

  @override
  Future<StartupItemStatus> run() async {
    if (!isInstalled()) {
      return StartupItemStatus.skipped(
        id,
        kind,
        label,
        reason: 'Sandbox is not installed on this device',
      );
    }
    try {
      await startMaintenance();
      if (!await runtimesVerified()) {
        final installed = await installCoreRuntimes();
        if (!installed) {
          return StartupItemStatus.degraded(
            id,
            kind,
            label,
            reason: 'Core runtimes could not be verified',
          );
        }
      }
      await enforceQuota();
      return StartupItemStatus.ready(id, kind, label);
    } on SandboxUnsupportedException catch (error) {
      return StartupItemStatus.unsupported(
        id,
        kind,
        label,
        reason: error.message,
      );
    } catch (error) {
      return StartupItemStatus.degraded(id, kind, label, reason: '$error');
    }
  }
}
