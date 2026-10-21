import 'package:flutter/material.dart';

import '../../../core/cloud/artifact_vault.dart';
import '../../../core/cloud/schedule_client.dart';
import '../../../core/chat_integration_ports.dart';
import '../../../core/state.dart';
import '../../../core/session_artifacts.dart';
import '../browser/browser_page.dart';
import '../connectors/connectors_page.dart';
import '../library/artifact_detail_page.dart';
import '../library/artifacts_page.dart';
import '../schedules/schedule_runs_page.dart';
import '../schedules/schedules_page.dart';
import '../studio/repo_picker_page.dart';
import 'v2_settings_actions.dart';
import 'v2_studio_routes.dart';

/// Routes for the work surfaces (Studio, Browser, Artifacts, Schedules,
/// Connectors). Reads live state; every screen stays presentational.
class V2WorkRoutes {
  const V2WorkRoutes._();

  static Future<void> openStudio(
    BuildContext context,
    V2SettingsActions actions,
  ) async {
    final port = StudioBindingPort.instance;
    final repos = <V2Repo>[];
    if (port != null && port.ready) {
      try {
        final list = await port.listRepos();
        for (final fullName in list) {
          final parts = fullName.split('/');
          repos.add(
            V2Repo(
              id: fullName,
              name: parts.length > 1 ? parts.last : fullName,
              owner: parts.length > 1 ? parts.first : '',
            ),
          );
        }
      } catch (_) {
        // Fall through to the empty state.
      }
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => V2RepoPickerPage(
          data: V2RepoPickerData(
            status: repos.isEmpty
                ? V2RepoPickerStatus.empty
                : V2RepoPickerStatus.content,
            repos: repos,
            githubConnected: port != null && port.ready,
            accountLabel: null,
          ),
          onConnectGithub: () => actions.notReady(context, 'GitHub sign-in'),
          onOpenToken: () => actions.notReady(context, 'Personal token'),
          onSelectRepo: (repo) async {
            final sessionId = AppState.I.activeSessionId;
            final binding = StudioBindingPort.instance;
            if (sessionId != null && binding != null && binding.ready) {
              try {
                await binding.bind(sessionId, repo: repo.id, branch: 'main');
              } catch (_) {
                // The workspace still opens; sync will report the failure.
              }
            }
            if (!context.mounted) return;
            await V2StudioRoutes.openWorkspace(
              context,
              repo.id,
              'main',
              sessionId: sessionId,
            );
          },
        ),
      ),
    );
  }

  static Future<void> openBrowser(
    BuildContext context,
    V2SettingsActions actions,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const BrowserPage(data: V2BrowserData()),
      ),
    );
  }

  static Future<void> openArtifacts(
    BuildContext context,
    V2SettingsActions actions,
  ) async {
    final controller = ArtifactVaultController(
      client: ArtifactVaultClient(),
    );
    await controller.reload();
    final items = controller.items;
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ArtifactsPage(
          data: V2ArtifactsData(
            status: items.isEmpty
                ? V2ArtifactsStatus.empty
                : V2ArtifactsStatus.content,
            artifacts: [
              for (final artifact in items)
                V2ArtifactItem(
                  id: artifact.id,
                  name: artifact.name,
                  kind: _kindOf(artifact.kind),
                  createdAt: artifact.time,
                  sizeLabel: _bytes(artifact.size ?? 0),
                ),
            ],
          ),
          onArtifactTap: (item) {
            final artifact = items.where((a) => a.id == item.id).firstOrNull;
            if (artifact == null) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ArtifactDetailPage(
                  data: V2ArtifactDetailData(
                    name: artifact.name,
                    typeLabel: artifact.kind.name,
                    sizeLabel: _bytes(artifact.size ?? 0),
                    sourceChatTitle: artifact.sessionTitle,
                    details: [
                      V2ArtifactDetailRow(
                        label: 'Source',
                        value: artifact.origin.name,
                      ),
                      if (artifact.path != null)
                        V2ArtifactDetailRow(
                          label: 'Path',
                          value: artifact.path!,
                        ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static Future<void> openSchedules(
    BuildContext context,
    V2SettingsActions actions,
  ) async {
    final client = ScheduleClient.I;
    List<ScheduleDto> schedules = const [];
    try {
      schedules = await client.list();
    } catch (_) {
      // Empty state below.
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SchedulesPage(
          data: V2SchedulesData(
            status: schedules.isEmpty
                ? V2SchedulesStatus.empty
                : V2SchedulesStatus.content,
            schedules: [
              for (final schedule in schedules)
                V2ScheduleItem(
                  id: schedule.id,
                  title: schedule.title,
                  description: schedule.description,
                  rule: schedule.trigger.describe(),
                  nextRun: schedule.nextRunAt == null
                      ? null
                      : _timeLabel(schedule.nextRunAt!),
                  enabled: schedule.status == 'active',
                  lastRunFailed: schedule.lastResult?.status == 'failed',
                ),
            ],
          ),
          onCreate: () => actions.notReady(context, 'New schedule'),
          onScheduleTap: (item) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ScheduleRunsPage(
                data: V2ScheduleRunsData(),
              ),
            ),
          ),
          onToggle: (item, value) =>
              actions.notReady(context, 'Schedule toggle'),
          onRetryRun: (item) => actions.notReady(context, 'Run now'),
        ),
      ),
    );
  }

  static Future<void> openConnectors(
    BuildContext context,
    V2SettingsActions actions,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConnectorsPage(
          data: const V2ConnectorsData(
            status: V2ConnectorsStatus.content,
            connectors: [],
          ),
          onAddCustom: () => actions.notReady(context, 'Custom connectors'),
          onBrowseConnectors: () =>
              actions.notReady(context, 'Connector catalog'),
        ),
      ),
    );
  }

  static V2ArtifactKind _kindOf(ArtifactKind kind) => switch (kind) {
    ArtifactKind.image => V2ArtifactKind.image,
    ArtifactKind.html => V2ArtifactKind.document,
    ArtifactKind.code => V2ArtifactKind.code,
    ArtifactKind.document => V2ArtifactKind.document,
    ArtifactKind.other => V2ArtifactKind.data,
  };

  static String _bytes(int value) {
    if (value <= 0) return '';
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _timeLabel(DateTime at) {
    final local = at.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (!local.isBefore(today)) {
      final h = local.hour.toString().padLeft(2, '0');
      final m = local.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    return '${local.day}/${local.month}';
  }
}
