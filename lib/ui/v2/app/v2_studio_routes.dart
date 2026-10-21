import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/chat_integration_ports.dart';
import '../../design/o_components.dart';
import '../studio/branch_picker_sheet.dart';
import '../studio/changes_page.dart';
import '../studio/live_preview_page.dart';
import '../studio/studio_workspace_page.dart';

/// Routes for the Studio workspace extras.
///
/// Repository and branch data come from the installed [StudioBindingPort].
/// When no port is installed the screens open in their empty state instead of
/// showing a repository that is not really bound. Changes and live preview
/// have no cloud source yet, so they stay empty rather than inventing diffs or
/// a preview URL.
class V2StudioRoutes {
  const V2StudioRoutes._();

  static Future<void> openWorkspace(
    BuildContext context,
    String repo,
    String branch, {
    String? sessionId,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _StudioWorkspaceHost(
          repo: repo,
          branch: branch,
          sessionId: sessionId,
        ),
      ),
    );
  }

  /// Opens the branch picker sheet for [repo]. [onSelect] receives the branch
  /// name the user picked; null when the port has no branches to offer.
  static Future<void> openBranchPicker(
    BuildContext context,
    String repo,
    String branch,
    ValueChanged<String>? onSelect,
  ) async {
    final port = StudioBindingPort.instance;
    var data = branchPickerDataFor(
      currentBranch: branch,
      branches: const [],
      portReady: port?.ready ?? false,
    );
    if (port != null && port.ready) {
      try {
        final branches = await port.listBranches(repo);
        data = branchPickerDataFor(
          currentBranch: branch,
          branches: branches,
          portReady: true,
        );
      } catch (_) {
        data = branchPickerDataFor(
          currentBranch: branch,
          branches: const [],
          portReady: true,
          failed: true,
        );
      }
    }
    if (!context.mounted) return;
    await showOSheet<void>(
      context,
      builder: (sheetContext) => V2BranchPickerSheet(
        data: data,
        showHandle: false,
        onSelectBranch: (selected) {
          Navigator.of(sheetContext).pop();
          onSelect?.call(selected.name);
        },
      ),
    );
  }

  static Future<void> openChanges(
    BuildContext context,
    String repo,
    String branch,
  ) async {
    final port = StudioBindingPort.instance;
    final data = changesDataFor(
      branch: branch,
      portReady: port?.ready ?? false,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => V2ChangesPage(
          data: data,
          onBack: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }

  static Future<void> openLivePreview(
    BuildContext context,
    String repo,
    String branch,
  ) async {
    final port = StudioBindingPort.instance;
    final data = livePreviewDataFor(
      repo: repo,
      portReady: port?.ready ?? false,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => V2LivePreviewPage(data: data),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Mapping helpers
  // ---------------------------------------------------------------------------

  /// The workspace opens on the bound repo/branch, or empty without a port.
  @visibleForTesting
  static V2StudioWorkspaceData workspaceDataFor({
    required String repo,
    required String branch,
    required bool portReady,
  }) {
    final name = repo.trim();
    if (!portReady || name.isEmpty) {
      return V2StudioWorkspaceData(
        repoName: name,
        branch: '',
        status: V2WorkspaceStatus.empty,
      );
    }
    return V2StudioWorkspaceData(
      repoName: name,
      branch: branch.trim(),
    );
  }

  /// Real branch names when the port can list them, empty otherwise.
  @visibleForTesting
  static V2BranchPickerData branchPickerDataFor({
    required String currentBranch,
    required List<String> branches,
    required bool portReady,
    bool failed = false,
  }) {
    final current = currentBranch.trim();
    if (failed) {
      return V2BranchPickerData(
        status: V2BranchPickerStatus.error,
        current: null,
        branches: const [],
        errorMessage:
            'We could not load branches for this repository. Check your '
            'connection and try again.',
      );
    }
    if (!portReady || branches.isEmpty) {
      return V2BranchPickerData(
        status: V2BranchPickerStatus.empty,
        current: null,
        branches: const [],
      );
    }
    return V2BranchPickerData(
      status: V2BranchPickerStatus.content,
      current: current.isEmpty ? null : V2Branch(name: current),
      branches: [
        for (final name in branches)
          V2Branch(name: name, isCurrent: name == current),
      ],
    );
  }

  /// No diff source exists yet, so the changes screen opens empty with the
  /// bound branch as its only real label.
  @visibleForTesting
  static V2ChangesData changesDataFor({
    required String branch,
    required bool portReady,
  }) {
    final label = portReady ? branch.trim() : '';
    return V2ChangesData(
      status: V2ChangesStatus.empty,
      branchLabel: label.isEmpty ? null : label,
    );
  }

  /// No preview URL source exists yet; the screen opens in its start state.
  @visibleForTesting
  static V2LivePreviewData livePreviewDataFor({
    required String repo,
    required bool portReady,
  }) {
    return V2LivePreviewData(
      status: V2PreviewStatus.empty,
      siteName: portReady ? repo.trim() : '',
    );
  }
}

/// Hosts the workspace page so picking a branch rebuilds it with the chosen
/// branch; the screen itself stays presentational.
class _StudioWorkspaceHost extends StatefulWidget {
  const _StudioWorkspaceHost({
    required this.repo,
    required this.branch,
    this.sessionId,
  });

  final String repo;
  final String branch;
  final String? sessionId;

  @override
  State<_StudioWorkspaceHost> createState() => _StudioWorkspaceHostState();
}

class _StudioWorkspaceHostState extends State<_StudioWorkspaceHost> {
  late String _branch;

  @override
  void initState() {
    super.initState();
    _branch = widget.branch;
  }

  @override
  Widget build(BuildContext context) {
    final port = StudioBindingPort.instance;
    return V2StudioWorkspacePage(
      data: V2StudioRoutes.workspaceDataFor(
        repo: widget.repo,
        branch: _branch,
        portReady: port?.ready ?? false,
      ),
      onBranchTap: () => V2StudioRoutes.openBranchPicker(
        context,
        widget.repo,
        _branch,
        (selected) {
          if (mounted) setState(() => _branch = selected);
        },
      ),
      onSync: () {
        final sessionId = widget.sessionId;
        if (sessionId == null) return;
        final port = StudioBindingPort.instance;
        if (port == null) return;
        unawaited(port.syncLatest(sessionId));
      },
      onCommit: () =>
          V2StudioRoutes.openChanges(context, widget.repo, _branch),
      onPreview: () =>
          V2StudioRoutes.openLivePreview(context, widget.repo, _branch),
    );
  }
}
